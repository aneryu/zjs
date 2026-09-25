//! String builtins, coercion/concatenation, and RegExp-string integration.
//!
//! String/value inputs are borrowed; returned JSValues and temporary concat or
//! capture values carry explicit ownership and must be freed or transferred.
//! The large alias wall keeps extracted RegExp, object, array, and error-stack
//! seams source-compatible; it does not make their implementations one module.
//! Preserve the measured `ctx`/`output`/`global`/caller-function/caller-frame
//! ABI and keep benchmark-hot string/RegExp arms out of shared cold bodies.
//! Algorithm coordinates live beside each implementation, including QuickJS
//! concatenation at quickjs.c and replacement at quickjs.c.

const std = @import("std");
const iterator_slots = @import("iterator_ops.zig");

const bytecode = @import("../bytecode.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const core = @import("../core/root.zig");
const method_ids = core.host_function.builtin_method_ids;
const string_id_lookup = core.host_function.builtin_method_id_lookup.string;
const regexp_adapter = @import("regexp_ops.zig");
const unicode_lib = @import("../libs/unicode.zig");
const call_mod = @import("call.zig");
const exception_ops = @import("exception_ops.zig");
const frame_mod = @import("frame.zig");
const iterator_ops = @import("iterator_ops.zig");
const property_ops = @import("property_ops.zig");
const value_ops = @import("value_ops.zig");

const concat_inline_part_limit = 32;

const call_runtime = @import("call_runtime.zig");
const call_site_mod = @import("call_site.zig");
const array_ops = @import("array_ops.zig");
const builtin_glue = @import("builtin_glue.zig");
const coercion_ops = @import("value_ops.zig");
const error_stack_ops = @import("exception_ops.zig");
const object_ops = @import("object_ops.zig");
const regexp_fastpath = @import("regexp_ops.zig");
const RegExpCapture = call_runtime.RegExpCapture;
const ValueSliceRoot = array_ops.ValueSliceRoot;
const appendBacktraceFunctionName = error_stack_ops.appendBacktraceFunctionName;
const appendCallSiteFileName = error_stack_ops.appendCallSiteFileName;
const appendCallSiteFunctionName = error_stack_ops.appendCallSiteFunctionName;
const appendNamedCaptureSubstitution = regexp_fastpath.appendNamedCaptureSubstitution;
const arrayFirstIndexStart = array_ops.arrayFirstIndexStart;
const arrayLastIndexStart = array_ops.arrayLastIndexStart;
const arrayMethodTypedArrayLength = array_ops.arrayMethodTypedArrayLength;
const arrayPrototypeFromGlobal = array_ops.arrayPrototypeFromGlobal;
const arrayPrototypeRecordId = array_ops.arrayPrototypeRecordId;
const arrayCopyPresentIndex = array_ops.arrayCopyPresentIndex;
const arraySpeciesCreate = array_ops.arraySpeciesCreate;
const arraySpeciesOriginalIsArray = array_ops.arraySpeciesOriginalIsArray;
const backtraceFunctionNameEql = error_stack_ops.backtraceFunctionNameEql;
const bytecodeFunctionObjectTag = object_ops.bytecodeFunctionObjectTag;
const callObjectToPrimitiveMethod = object_ops.callObjectToPrimitiveMethod;
const callValueOrBytecodeRoot = call_runtime.callValueOrBytecodeRoot;
const CallSite = call_site_mod.CallSite;
const callableObjectFromValue = object_ops.callableObjectFromValue;
const clearRegExpLegacySlot = regexp_fastpath.clearRegExpLegacySlot;
const constructValueOrBytecode = call_runtime.constructValueOrBytecode;

const createDataPropertyOrThrow = object_ops.createDataPropertyOrThrow;
const createIteratorResult = iterator_ops.createIteratorResult;
const createRegExpIndicesArray = array_ops.createRegExpIndicesArray;
const defineFreshNonIndexDataProperty = object_ops.defineFreshNonIndexDataProperty;
const populateRegExpGroupsFromCaptureValues = object_ops.populateRegExpGroupsFromCaptureValues;
const errorStackTraceLimit = error_stack_ops.errorStackTraceLimit;
const getIteratorMethod = call_runtime.getIteratorMethod;
const getValueProperty = object_ops.getValueProperty;
const hasValueProperty = object_ops.hasValueProperty;
const isArrayPrototypeRecord = array_ops.isArrayPrototypeRecord;
const isCallableValue = call_runtime.isCallableValue;
const isRegExpObservable = regexp_fastpath.isRegExpObservable;
const isRegExpValue = regexp_fastpath.isRegExpValue;
const isTypedArrayPrototypeMethod = array_ops.isTypedArrayPrototypeMethod;
const lengthIndexValue = array_ops.lengthIndexValue;
const objectFromValue = object_ops.objectFromValue;
const ownDataOrAutoInitPropertyValue = object_ops.ownDataOrAutoInitPropertyValue;
const primitiveObjectForAccess = object_ops.primitiveObjectForAccess;
const propertyAtomFromLengthIndex = object_ops.propertyAtomFromLengthIndex;
const proxyTargetIsCallableObject = object_ops.proxyTargetIsCallableObject;
const arrayLastIndexSparseLarge = array_ops.arrayLastIndexSparseLarge;
const iteratorPrototype = object_ops.iteratorPrototype;
const regExpConstructCall = regexp_fastpath.regExpConstructCall;
const regExpExecGeneric = regexp_fastpath.regExpExecGeneric;
const regExpSpeciesConstructor = regexp_fastpath.regExpSpeciesConstructor;
const regExpFlagsAreFullUnicode = regexp_fastpath.regExpFlagsAreFullUnicode;
const setRegExpLastIndexZero = regexp_fastpath.setRegExpLastIndexZero;
const setValueProperty = object_ops.setValueProperty;
const setValuePropertyStrict = object_ops.setValuePropertyStrict;

const throwRangeErrorMessage = exception_ops.throwRangeErrorMessage;
const throwTypeErrorMessage = exception_ops.throwTypeErrorMessage;
const toLengthIndex = coercion_ops.toLengthIndex;
const toLengthNumber = coercion_ops.toLengthNumber;
const toNumberLikeArgument = builtin_glue.toNumberLikeArgument;
const toPrimitiveForNumber = coercion_ops.toPrimitiveForNumber;
const toUint16CodeUnit = coercion_ops.toUint16CodeUnit;
const toUint32Number = coercion_ops.toUint32Number;
const uint32NumberValue = coercion_ops.uint32NumberValue;
const valueTruthy = coercion_ops.valueTruthy;
const valuesStrictEqual = value_ops.valuesStrictEqual;

pub fn toStringForAnnexB(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    // qjs `JS_ToString` on a symbol throws TypeError "cannot convert symbol to
    // string" (JS_ToStringInternal quickjs.c).
    if (value.is(.symbol)) return throwTypeErrorMessage(ctx, global, "cannot convert symbol to string");
    if (value.isString()) return value;
    const primitive = if (value.is(.object))
        try toPrimitiveForString(ctx, output, global, value, caller_function, caller_frame)
    else
        value;
    if (primitive.is(.symbol)) return throwTypeErrorMessage(ctx, global, "cannot convert symbol to string");
    if (primitive.isString()) return primitive;
    return value_ops.toStringValue(ctx.runtime, primitive);
}

/// qjs `JS_ToStringCheckObject`: a null/undefined receiver
/// throws TypeError "null or undefined are forbidden" in the callee realm;
/// everything else is `JS_ToString`d. This is the exact `this`-coercion the
/// String.prototype method bodies open with (`js_string_charCodeAt` etc.,
/// quickjs.c). Exposed so the self-contained builtin bodies can perform
/// it inline and be reached directly by the record — mirroring qjs's per-method
/// dispatch — instead of routing through the exec `stringPrototypeMethod`
/// coercion tower.
pub fn toStringCheckObject(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (value.is(.null_value) or value.is(.undefined_value))
        return throwTypeErrorMessage(ctx, global, "null or undefined are forbidden");
    return toStringForAnnexB(ctx, output, global, value, caller_function, caller_frame);
}

pub fn toPrimitiveForString(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (!value.is(.object)) return value;
    const symbol_to_primitive = (comptime core.atom.predefinedId("Symbol.toPrimitive", .symbol)) orelse
        return toOrdinaryPrimitiveString(ctx, output, global, value, caller_function, caller_frame);
    const method = try getValueProperty(ctx, output, global, value, symbol_to_primitive, caller_function, caller_frame);
    if (!method.is(.undefined_value) and !method.is(.null_value)) {
        // JS_ToPrimitiveInternal (quickjs.c JS_CallFree): a non-callable
        // Symbol.toPrimitive is still called and reports "not a function"; an
        // object return value throws "toPrimitive".
        if (!isCallableValue(method)) return throwTypeErrorMessage(ctx, global, "not a function");
        const hint = try value_ops.createStringValue(ctx.runtime, "string");
        const primitive = try call_runtime.callValueOrBytecodeSyncInternalOutlined(ctx, output, global, value, method, &.{hint}, caller_function, caller_frame);
        if (primitive.is(.object)) {
            return throwTypeErrorMessage(ctx, global, "toPrimitive");
        }
        return primitive;
    }
    return toOrdinaryPrimitiveString(ctx, output, global, value, caller_function, caller_frame);
}

pub fn toOrdinaryPrimitiveString(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (try callObjectToPrimitiveMethod(ctx, output, global, value, core.atom.ids.toString, caller_function, caller_frame)) |primitive| return primitive;
    if (try callObjectToPrimitiveMethod(ctx, output, global, value, core.atom.ids.valueOf, caller_function, caller_frame)) |primitive| return primitive;
    // JS_ToPrimitiveInternal: no primitive from toString/valueOf.
    return throwTypeErrorMessage(ctx, global, "toPrimitive");
}

pub fn stringFunctionCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (args.len == 0) return value_ops.createStringValue(ctx.runtime, "");
    if (args[0].is(.symbol)) return value_ops.toStringValue(ctx.runtime, args[0]);
    if (!args[0].is(.object)) return value_ops.toStringValue(ctx.runtime, args[0]);
    return toStringForAnnexB(ctx, output, global, args[0], caller_function, caller_frame);
}

// Construct records the string ops route through (Phase 6b-3 STEP 4) instead
// of naming `builtins.{string,regexp}.constructWithPrototype` directly: the
// observable coercion stays here and the coerced primitives + resolved
// prototype are threaded to the record. Both construct branches read only
// `args`/`new_target`, so no constructor function object is threaded.
const string_construct_ref = core.function.NativeBuiltinRef{
    .domain = .string,
    .id = @intFromEnum(method_ids.string.ConstructorMethod.call),
};
const regexp_construct_ref = core.function.NativeBuiltinRef{
    .domain = .regexp,
    .id = @intFromEnum(method_ids.regexp.ConstructorMethod.construct),
};

pub fn stringConstructWithPrototype(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    prototype: ?*core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const string_value = if (args.len == 0)
        try value_ops.createStringValue(ctx.runtime, "")
    else
        try toStringForAnnexB(ctx, output, global, args[0], caller_function, caller_frame);
    return (try builtin_dispatch.callConstructRecord(ctx, output, global, &.{}, null, string_construct_ref, prototype, &.{string_value}, caller_function, caller_frame)) orelse error.TypeError;
}

pub fn stringConcat(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return stringConcatRooted(ctx, output, global, this_value, args, caller_function, caller_frame) catch |err| switch (err) {
        error.RootGenerationExhausted => error.OutOfMemory,
        error.RootAlreadyActive, error.RootMutationDuringCollection, error.WrongRuntime, error.InactiveRoot, error.InvalidRootIndex, error.ExpectedString => std.debug.panic("stringConcat value contract: {s}", .{@errorName(err)}),
        else => |other| other,
    };
}

fn stringConcatRooted(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (this_value.is(.null_value) or this_value.is(.undefined_value))
        return throwTypeErrorMessage(ctx, global, "null or undefined are forbidden");
    const rt = ctx.runtime;
    var global_roots = core.runtime.ExactValueRoots(1){};
    try global_roots.activate(rt);
    defer global_roots.deactivate();
    const global_root = try global_roots.ref(0);
    try global_root.set(rt, global.value());

    const part_count = std.math.add(usize, args.len, 1) catch return error.OutOfMemory;
    var inline_parts: [concat_inline_part_limit]core.JSValue = undefined;
    var parts = if (part_count <= inline_parts.len)
        inline_parts[0..part_count]
    else
        try rt.nativeAllocator().alloc(core.JSValue, part_count);
    defer if (part_count > inline_parts.len) rt.nativeAllocator().free(parts);
    // Native allocation above cannot collect. Snapshot every original
    // argument before any ToString callback, then convert its rooted slot
    // in place. No caller slice or raw heap view crosses a callback.
    parts[0] = this_value;
    @memcpy(parts[1..], args);
    var root = ValueSliceRoot{};
    root.init(rt, &parts);
    defer root.deinit();
    for (0..parts.len) |index| {
        parts[index] = try toStringForAnnexB(ctx, output, try expectObject(try global_root.get(rt)), parts[index], caller_function, caller_frame);
    }
    if (parts.len == 1) return parts[0];
    return (try core.string.String.createConcatParts(rt, parts)).value();
}

pub fn stringReplace(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return stringReplaceCore(ctx, output, global, this_value, args, false, caller_function, caller_frame);
}

/// js_string_replace (quickjs.c, magic: 0 = replace / 1 = replaceAll).
/// After the @@replace delegation, works directly on the flat string
/// representations: string_indexof over the source, the narrow-first
/// StringBuffer accumulator, and the string-search GetSubstitution shape.
/// A first-round search miss returns the source string unchanged.
/// `noinline`: the body is large; letting it inline through the thin
/// replace/replaceAll wrappers into the prototype-method dispatcher evicts
/// the hot NumericArgs bodies from the dispatcher's inline budget
/// (measured +4.6% on charCodeAt).
noinline fn stringReplaceCore(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    is_replace_all: bool,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return stringReplaceCoreRooted(ctx, output, global, this_value, args, is_replace_all, caller_function, caller_frame) catch |err| switch (err) {
        error.RootGenerationExhausted => error.OutOfMemory,
        // All refs are local to this active scope; ToString supplies strings.
        error.RootAlreadyActive, error.RootMutationDuringCollection, error.WrongRuntime, error.InactiveRoot, error.InvalidRootIndex, error.ExpectedString => std.debug.panic("stringReplaceCore value contract: {s}", .{@errorName(err)}),
        else => |other| other,
    };
}

fn stringReplaceCoreRooted(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    is_replace_all: bool,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    // js_string_replace: nullish receiver -> "cannot convert to object".
    if (this_value.is(.null_value) or this_value.is(.undefined_value)) {
        return throwTypeErrorMessage(ctx, global, "cannot convert to object");
    }
    const rt = ctx.runtime;
    var roots = core.runtime.ExactValueRoots(7){};
    try roots.activate(rt);
    defer roots.deactivate();
    const receiver = try roots.ref(0);
    const search_input = try roots.ref(1);
    const replacement_input = try roots.ref(2);
    const source = try roots.ref(3);
    const search_root = try roots.ref(4);
    const replacement = try roots.ref(5);
    const temporary = try roots.ref(6);
    try receiver.set(rt, this_value);
    try search_input.set(rt, if (args.len >= 1) args[0] else core.JSValue.undefinedValue());
    try replacement_input.set(rt, if (args.len >= 2) args[1] else core.JSValue.undefinedValue());

    if ((try search_input.get(rt)).is(.object)) {
        if (is_replace_all) {
            // check_regexp_g_flag: undefined/null flags throw
            // TypeError "cannot convert to object"; a flags string without 'g'
            // throws TypeError "regexp must have the 'g' flag".
            if (try isRegExpObservable(ctx, output, global, try search_input.get(rt), caller_function, caller_frame)) {
                const flags_atom = (comptime core.atom.predefinedId("flags", .string)) orelse return error.TypeError;
                try temporary.set(rt, try getValueProperty(ctx, output, global, try search_input.get(rt), flags_atom, caller_function, caller_frame));
                const flags = try temporary.get(rt);
                if (flags.is(.null_value) or flags.is(.undefined_value))
                    return throwTypeErrorMessage(ctx, global, "cannot convert to object");
                try temporary.set(rt, try toStringForAnnexB(ctx, output, global, flags, caller_function, caller_frame));
                var bytes = std.ArrayList(u8).empty;
                defer bytes.deinit(ctx.runtime.nativeAllocator());
                try value_ops.appendRawString(ctx.runtime, &bytes, try temporary.get(rt));
                if (std.mem.indexOfScalar(u8, bytes.items, 'g') == null)
                    return throwTypeErrorMessage(ctx, global, "regexp must have the 'g' flag");
            }
        }
        if (try callStringReplaceMethod(ctx, output, global, try receiver.get(rt), try search_input.get(rt), try replacement_input.get(rt), caller_function, caller_frame)) |value| return value;
    }

    try source.set(rt, try toStringForAnnexB(ctx, output, global, try receiver.get(rt), caller_function, caller_frame));
    try search_root.set(rt, try toStringForAnnexB(ctx, output, global, try search_input.get(rt), caller_function, caller_frame));
    const functional_replace = isCallableValue(try replacement_input.get(rt));
    if (!functional_replace)
        try replacement.set(rt, try toStringForAnnexB(ctx, output, global, try replacement_input.get(rt), caller_function, caller_frame));

    // Complete all potentially collecting materialization before borrowing
    // any units. Reborrow from these roots after each user callback.
    try core.string.ensureFlat(rt, source.readOnly(), source);
    try core.string.ensureFlat(rt, search_root.readOnly(), search_root);
    if (!functional_replace) try core.string.ensureFlat(rt, replacement.readOnly(), replacement);
    const search_len = core.string.stringValueLenUnchecked(try search_root.get(rt));

    var b = StringBuffer{ .allocator = ctx.runtime.nativeAllocator() };
    defer b.deinit();

    var end_of_last_match: usize = 0;
    var is_first = true;
    while (true) {
        const sp_data = core.string.asFlat(try source.get(rt)).?.resolveData();
        const search_data = core.string.asFlat(try search_root.get(rt)).?.resolveData();
        const maybe_pos: ?usize = if (search_len == 0) blk: {
            if (is_first) break :blk 0;
            if (end_of_last_match >= sp_data.len()) break :blk null;
            break :blk end_of_last_match + 1;
        } else stringIndexOfData(sp_data, search_data, end_of_last_match);
        const pos = maybe_pos orelse {
            if (is_first) return source.get(rt);
            break;
        };

        try b.appendUnits(sp_data, end_of_last_match, pos - end_of_last_match);

        if (functional_replace) {
            var replacement_call = CallSite.initInternal(ctx, output, global, core.JSValue.undefinedValue(), try replacement_input.get(rt), caller_function, caller_frame);
            replacement_call.activateRoots();
            defer replacement_call.deinit();
            try temporary.set(rt, try replacement_call.call(&.{ try search_root.get(rt), core.JSValue.int32(@intCast(pos)), try source.get(rt) }));
            try temporary.set(rt, try toStringForAnnexB(ctx, output, global, try temporary.get(rt), caller_function, caller_frame));
            try core.string.ensureFlat(rt, temporary.readOnly(), temporary);
            const repl_data = core.string.asFlat(try temporary.get(rt)).?.resolveData();
            try b.appendUnits(repl_data, 0, repl_data.len());
        } else {
            const rep_data = core.string.asFlat(try replacement.get(rt)).?.resolveData();
            try appendSubstitutionStringSearch(rt, &b, try search_root.get(rt), sp_data, pos, search_len, rep_data);
        }

        end_of_last_match = pos + search_len;
        is_first = false;
        if (!is_replace_all) break;
    }
    const tail_data = core.string.asFlat(try source.get(rt)).?.resolveData();
    try b.appendUnits(tail_data, end_of_last_match, tail_data.len() - end_of_last_match);
    return b.finish(ctx.runtime);
}

fn resolvedCodeUnitAt(data: core.string.String.ResolvedData, index: usize) u16 {
    return switch (data) {
        .latin1 => |bytes| bytes[index],
        .utf16 => |units| units[index],
    };
}

/// string_indexof_char: first index of code unit `c` at or
/// after `from`; a narrow string can never contain a unit > 0xFF.
fn stringIndexOfCharData(data: core.string.String.ResolvedData, c: u16, from: usize) ?usize {
    return switch (data) {
        .latin1 => |bytes| blk: {
            if (c > 0xff) break :blk null;
            break :blk std.mem.indexOfScalarPos(u8, bytes, from, @intCast(c));
        },
        .utf16 => |units| std.mem.indexOfScalarPos(u16, units, from, c),
    };
}

/// string_indexof: naive first-char scan plus tail compare.
fn stringIndexOfData(
    haystack: core.string.String.ResolvedData,
    needle: core.string.String.ResolvedData,
    from: usize,
) ?usize {
    const len1 = haystack.len();
    const len2 = needle.len();
    if (len2 == 0) return from;
    const c = resolvedCodeUnitAt(needle, 0);
    var i = from;
    while (i + len2 <= len1) {
        const j = stringIndexOfCharData(haystack, c, i) orelse return null;
        if (j + len2 > len1) return null;
        var k: usize = 1;
        const matched = while (k < len2) : (k += 1) {
            if (resolvedCodeUnitAt(haystack, j + k) != resolvedCodeUnitAt(needle, k)) break false;
        } else true;
        if (matched) return j;
        i = j + 1;
    }
    return null;
}

/// js_string_GetSubstitution in its string-search shape:
/// captures == NULL, captures_val/namedCaptures == undefined, so `$N` and
/// `$<name>` take the norep path verbatim and only $$ $& $` $' substitute.
fn appendSubstitutionStringSearch(
    rt: *core.JSRuntime,
    b: *StringBuffer,
    matched_value: core.JSValue,
    sp_data: core.string.String.ResolvedData,
    position: usize,
    matched_len: usize,
    rep_data: core.string.String.ResolvedData,
) !void {
    const len = rep_data.len();
    var i: usize = 0;
    while (true) {
        const j = stringIndexOfCharData(rep_data, '$', i) orelse break;
        if (j + 1 >= len) break;
        try b.appendUnits(rep_data, i, j - i);
        const j0 = j;
        var scan = j + 1;
        const c = resolvedCodeUnitAt(rep_data, scan);
        scan += 1;
        if (c == '$') {
            try b.putc8('$');
        } else if (c == '&') {
            try b.appendStringValue(rt, matched_value);
        } else if (c == '`') {
            try b.appendUnits(sp_data, 0, position);
        } else if (c == '\'') {
            const tail_start = position + matched_len;
            try b.appendUnits(sp_data, tail_start, sp_data.len() - tail_start);
        } else {
            // norep: captures_len == 0 rejects $0-$99 and namedCaptures is
            // undefined, so `$c` is copied through verbatim.
            try b.appendUnits(rep_data, j0, scan - j0);
        }
        i = scan;
    }
    try b.appendUnits(rep_data, i, len - i);
}

pub fn callStringReplaceMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    search_value: core.JSValue,
    replace_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (!search_value.is(.object)) return null;
    const replace_atom = (comptime core.atom.predefinedId("Symbol.replace", .symbol)) orelse return error.TypeError;
    const replacer = try getValueProperty(ctx, output, global, search_value, replace_atom, caller_function, caller_frame);
    if (replacer.is(.undefined_value) or replacer.is(.null_value)) return null;
    if (!isCallableValue(replacer)) return error.TypeError;
    // TGC R1-c: NOT rooted. The sync-internal boundary does require rooted
    // inputs -- its `pollInterrupt` is a full collection point reached while
    // `args` still borrows this array, and nothing copies it first -- but
    // both slots are already covered one frame up: `this_value` and
    // `replace_value` are copies of `args[0]`/`args[1]` in the builtin
    // window that `callTypedInternalRecordDirect` roots with
    // `.slices = .{ .borrowed = args }`, and `search_value` is `args[0]`
    // as well. A `.slices` root here measured no drop on this frame
    // (candidate 234 -> 218, inside run noise) and would have added a
    // production frame link for nothing. The one slot with no second owner
    // is `replacer`, reachable only as the @@replace property of the rooted
    // `search_value`; a getter that mints a fresh callable would leave it
    // bare, which is a gap the census cannot sample.
    const replace_args = [_]core.JSValue{ this_value, replace_value };
    return try call_runtime.callValueOrBytecodeSyncInternalOutlined(
        ctx,
        output,
        global,
        search_value,
        replacer,
        &replace_args,
        caller_function,
        caller_frame,
    );
}

const ErrorStackStringKind = enum { live, captured };

/// Leftover error-stack at-line format. candidate106 still compiles
/// `buildErrorStackStringValue` (6378) / `formatCapturedErrorStackStringValue`
/// (5891, extra 5891, 5.2% match). The leftover is ArrayList + `"    at "` +
/// name + native-or-`allocPrint(" ({s}:{}:{})")` + trailing newline +
/// createStringValue. Comptime identity is live backtrace+skip vs captured
/// CallSite array. Take that at runtime. Public names stay `inline` and
/// pass only the kind — no leftover setup at the wrapper (knives 94/98).
/// Does not replace leftover `allocPrint` with slice joins (knife 77).
/// Does not retry leftover `{d}` through formatInt (knives 66/76).
noinline fn errorStackStringValue(
    ctx: *core.JSContext,
    global: ?*core.Object,
    skip_name: ?[]const u8,
    sites_value: core.JSValue,
    site_count: usize,
    kind: ErrorStackStringKind,
) !core.JSValue {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(ctx.runtime.nativeAllocator());
    var emitted: usize = 0;

    switch (kind) {
        .live => {
            const realm = global.?;
            const limit = errorStackTraceLimit(ctx.runtime, realm);
            if (limit == 0) return value_ops.createStringValue(ctx.runtime, "");

            const frames = try ctx.snapshotBacktraceFrames();
            defer ctx.freeBacktraceFrameSnapshot(frames);
            var idx = frames.len;
            var skipping = skip_name != null;
            while (idx > 0) {
                idx -= 1;
                _ = exception_ops.resolveBacktraceFunctionName(ctx, &frames[idx]);
                if (skipping) {
                    if (backtraceFunctionNameEql(ctx, frames[idx], skip_name.?)) skipping = false;
                    continue;
                }
                if (emitted >= limit) break;
                const entry = frames[idx];
                if (bytes.items.len != 0) try bytes.append(ctx.runtime.nativeAllocator(), '\n');
                try bytes.appendSlice(ctx.runtime.nativeAllocator(), "    at ");
                try appendBacktraceFunctionName(ctx, &bytes, entry.function_name, entry.filename);
                if (entry.is_native) {
                    try bytes.appendSlice(ctx.runtime.nativeAllocator(), " (native)");
                    emitted += 1;
                    continue;
                }
                const filename = ctx.runtime.atoms.name(entry.filename) orelse "<anonymous>";
                const location = entry.location();
                const line_num = if (location.line_num > 0) location.line_num else 1;
                const col_num = if (location.col_num > 0) location.col_num else 1;
                const suffix = try std.fmt.allocPrint(ctx.runtime.nativeAllocator(), " ({s}:{}:{})", .{ filename, line_num, col_num });
                defer ctx.runtime.nativeAllocator().free(suffix);
                try bytes.appendSlice(ctx.runtime.nativeAllocator(), suffix);
                emitted += 1;
            }
        },
        .captured => {
            const sites = objectFromValue(sites_value) orelse return value_ops.createStringValue(ctx.runtime, "");
            const current_length: usize = if (sites.isArray()) @intCast(sites.arrayLength()) else 0;
            const length = @min(current_length, site_count);
            for (0..length) |index| {
                if (index > std.math.maxInt(u32)) break;
                const site_value = try sites.getProperty(core.Atom.taggedInt(@intCast(index)));
                const site = objectFromValue(site_value) orelse continue;
                if (!site.isCallSite()) continue;
                if (bytes.items.len != 0) try bytes.append(ctx.runtime.nativeAllocator(), '\n');
                try bytes.appendSlice(ctx.runtime.nativeAllocator(), "    at ");
                try appendCallSiteFunctionName(ctx.runtime, &bytes, site);
                if (site.callSiteIsNative()) {
                    try bytes.appendSlice(ctx.runtime.nativeAllocator(), " (native)");
                    emitted += 1;
                    continue;
                }

                var filename_bytes: std.ArrayList(u8) = .empty;
                defer filename_bytes.deinit(ctx.runtime.nativeAllocator());
                try appendCallSiteFileName(ctx.runtime, &filename_bytes, site);
                const suffix = try std.fmt.allocPrint(
                    ctx.runtime.nativeAllocator(),
                    " ({s}:{}:{})",
                    .{ filename_bytes.items, site.callSiteLine(), site.callSiteColumn() },
                );
                defer ctx.runtime.nativeAllocator().free(suffix);
                try bytes.appendSlice(ctx.runtime.nativeAllocator(), suffix);
                emitted += 1;
            }
        },
    }
    if (emitted != 0) try bytes.append(ctx.runtime.nativeAllocator(), '\n');
    return value_ops.createStringValue(ctx.runtime, bytes.items);
}

pub inline fn buildErrorStackStringValue(ctx: *core.JSContext, global: *core.Object, skip_name: ?[]const u8) !core.JSValue {
    return errorStackStringValue(ctx, global, skip_name, core.JSValue.undefinedValue(), 0, .live);
}

pub inline fn formatCapturedErrorStackStringValue(ctx: *core.JSContext, sites_value: core.JSValue, site_count: usize) !core.JSValue {
    return errorStackStringValue(ctx, null, null, sites_value, site_count, .captured);
}

pub fn stringFromCodePoint(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    var units = std.ArrayList(u16).empty;
    defer units.deinit(ctx.runtime.nativeAllocator());
    for (args) |value| {
        const primitive = try toPrimitiveForNumber(ctx, output, global, value);
        const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
        const number = value_ops.numberValue(number_value) orelse std.math.nan(f64);
        // js_string_fromCodePoint: out-of-range/non-integer
        // code point -> RangeError "invalid code point".
        if (std.math.isNan(number) or !std.math.isFinite(number) or number < 0 or number > 0x10ffff or @trunc(number) != number) {
            return throwRangeErrorMessage(ctx, global, "invalid code point");
        }
        const code_point: u32 = @intFromFloat(number);
        try appendUtf16CodePoint(ctx.runtime, &units, code_point);
    }
    return (try core.string.String.createUtf16(ctx.runtime, units.items)).value();
}

pub fn stringRaw(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const template_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const cooked = try toObjectForStringRaw(ctx, global, template_value);

    const raw_atom = core.atom.ids.raw;
    const raw_candidate = try getValueProperty(ctx, output, global, cooked, raw_atom, caller_function, caller_frame);
    const raw = try toObjectForStringRaw(ctx, global, raw_candidate);

    const length_value = try getValueProperty(ctx, output, global, raw, core.atom.ids.length, caller_function, caller_frame);
    const length = try toLengthIndex(ctx, output, global, length_value);

    var out = std.ArrayList(u16).empty;
    defer out.deinit(ctx.runtime.nativeAllocator());

    for (0..length) |index| {
        if (index > std.math.maxInt(u32)) return error.RangeError;
        const raw_part = try getValueProperty(ctx, output, global, raw, core.Atom.taggedInt(@intCast(index)), caller_function, caller_frame);
        const raw_string = try toStringForAnnexB(ctx, output, global, raw_part, caller_function, caller_frame);
        try appendStringValueUnits(ctx.runtime, &out, raw_string);

        if (index + 1 < length and index + 1 < args.len) {
            const substitution = try toStringForAnnexB(ctx, output, global, args[index + 1], caller_function, caller_frame);
            try appendStringValueUnits(ctx.runtime, &out, substitution);
        }
    }

    return (try core.string.String.createUtf16(ctx.runtime, out.items)).value();
}

pub fn toObjectForStringRaw(ctx: *core.JSContext, global: *core.Object, value: core.JSValue) !core.JSValue {
    // JS_ToObject on undefined/null (js_string_raw -> quickjs.c) throws
    // TypeError "cannot convert to object".
    if (value.is(.null_value) or value.is(.undefined_value)) return throwTypeErrorMessage(ctx, global, "cannot convert to object");
    if (objectFromValue(value)) |_| return value;
    return primitiveObjectForAccess(ctx.runtime, global, value);
}

pub fn stringFromCharCode(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len == 1) {
        if (args[0].as(.int)) |code| {
            const unit: u16 = @intCast(@as(u32, @bitCast(code)) & 0xffff);
            if (unit <= 0xff) return (try ctx.runtime.singleByteString(@intCast(unit))).value();
            return (try core.string.String.createUtf16(ctx.runtime, &.{unit})).value();
        }
    }
    if (args.len == 2) {
        if (args[0].as(.int)) |first_code| {
            if (args[1].as(.int)) |second_code| {
                const cached = try ctx.runtime.recentTwoUnitString(
                    @intCast(@as(u32, @bitCast(first_code)) & 0xffff),
                    @intCast(@as(u32, @bitCast(second_code)) & 0xffff),
                );
                return cached.value();
            }
        }
    }
    var units: []u16 = &.{};
    if (args.len != 0) units = try ctx.runtime.nativeAllocator().alloc(u16, args.len);
    defer if (units.len != 0) ctx.runtime.nativeAllocator().free(units);
    for (args, 0..) |value, index| {
        const primitive = try toPrimitiveForNumber(ctx, output, global, value);
        if (primitive.isBigInt()) return error.TypeError;
        const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
        const number = value_ops.numberValue(number_value) orelse std.math.nan(f64);
        units[index] = toUint16CodeUnit(number);
    }
    return (try core.string.String.createUtf16(ctx.runtime, units)).value();
}

pub fn regExpNativeBuiltinMatches(value: core.JSValue, expected_id: u32) bool {
    const function_object = objectFromValue(value) orelse return false;
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionId()) orelse return false;
    return native_ref.domain == .regexp and native_ref.id == expected_id;
}

pub fn regExpAutoInitBuiltinMatches(info: core.property.AutoInit, expected_id: u32) bool {
    if (info.kind != .native_function) return false;
    const native_ref = core.function.decodeNativeBuiltinId(info.native_builtin_id) orelse return false;
    return native_ref.domain == .regexp and native_ref.id == expected_id;
}

pub fn regExpToString(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (!this_value.is(.object)) return error.TypeError;

    const source_atom = core.atom.ids.source;
    const source_value = try getValueProperty(ctx, output, global, this_value, source_atom, caller_function, caller_frame);
    const source_string = try toStringForAnnexB(ctx, output, global, source_value, caller_function, caller_frame);

    const flags_atom = comptime core.atom.predefinedId("flags", .string).?;
    const flags_value = try getValueProperty(ctx, output, global, this_value, flags_atom, caller_function, caller_frame);
    const flags_string = try toStringForAnnexB(ctx, output, global, flags_value, caller_function, caller_frame);

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(ctx.runtime.nativeAllocator());
    try bytes.append(ctx.runtime.nativeAllocator(), '/');
    try value_ops.appendRawString(ctx.runtime, &bytes, source_string);
    try bytes.append(ctx.runtime.nativeAllocator(), '/');
    try value_ops.appendRawString(ctx.runtime, &bytes, flags_string);
    return value_ops.createStringValue(ctx.runtime, bytes.items);
}

pub fn regexpInternalStringValue(rt: *core.JSRuntime, object: *core.Object, source: bool) !core.JSValue {
    if (source) {
        return (object.regexpSource() orelse return error.TypeError);
    }
    return regexp_adapter.flagsStringValueFromBytecode(rt, object.regexpCompiledBytecode());
}

pub fn regExpSymbolSearch(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    return regExpStringInputEntry(regExpSymbolSearchGeneric, ctx, output, global, this_value, args, caller_function, caller_frame);
}

pub fn regExpSymbolMatch(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    return regExpStringInputEntry(regExpSymbolMatchGeneric, ctx, output, global, this_value, args, caller_function, caller_frame);
}

fn regExpStringInputEntry(
    comptime driver: anytype,
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (!this_value.is(.object)) return error.TypeError;
    var values = [_]core.JSValue{ global.value(), this_value, if (args.len >= 1) args[0] else core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    values[2] = try toStringForAnnexB(ctx, output, objectFromValue(values[0]).?, values[2], caller_function, caller_frame);
    return try driver(ctx, output, objectFromValue(values[0]).?, values[1], values[2], caller_function, caller_frame);
}

pub fn regExpSymbolMatchAll(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    return regExpSymbolMatchAllRooted(ctx, output, global, this_value, args, caller_function, caller_frame) catch |err| switch (err) {
        error.RootGenerationExhausted => error.OutOfMemory,
        error.RootAlreadyActive, error.RootMutationDuringCollection, error.WrongRuntime, error.InactiveRoot, error.InvalidRootIndex => std.debug.panic("regExpSymbolMatchAll value contract: {s}", .{@errorName(err)}),
        else => |other| other,
    };
}

fn regExpSymbolMatchAllRooted(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (!this_value.is(.object)) return error.TypeError;
    const rt = ctx.runtime;
    var roots = core.runtime.ExactValueRoots(7){};
    try roots.activate(rt);
    defer roots.deactivate();
    const realm = try roots.ref(0);
    const receiver = try roots.ref(1);
    const source = try roots.ref(2);
    const constructor = try roots.ref(3);
    const flags = try roots.ref(4);
    const matcher = try roots.ref(5);
    const temporary = try roots.ref(6);
    try realm.set(rt, global.value());
    try receiver.set(rt, this_value);
    try source.set(rt, if (args.len >= 1) args[0] else core.JSValue.undefinedValue());
    try source.set(rt, try toStringForAnnexB(ctx, output, objectFromValue(try realm.get(rt)).?, try source.get(rt), caller_function, caller_frame));
    try constructor.set(rt, try regExpSpeciesConstructor(ctx, output, objectFromValue(try realm.get(rt)).?, try receiver.get(rt), caller_function, caller_frame));
    try flags.set(rt, try getRegExpFlagsString(ctx, output, objectFromValue(try realm.get(rt)).?, try receiver.get(rt), caller_function, caller_frame));
    const global_flag = try stringValueContainsByte(rt, try flags.get(rt), 'g');
    const unicode_flag = try regExpFlagsAreFullUnicode(rt, try flags.get(rt));
    const construct_args = [_]core.JSValue{ try receiver.get(rt), try flags.get(rt) };
    try matcher.set(rt, try constructValueOrBytecode(ctx, output, objectFromValue(try realm.get(rt)).?, try constructor.get(rt), &construct_args, caller_function, caller_frame));
    try temporary.set(rt, try getValueProperty(ctx, output, objectFromValue(try realm.get(rt)).?, try receiver.get(rt), core.atom.ids.lastIndex, caller_function, caller_frame));
    const last_index = try toLengthIndex(ctx, output, objectFromValue(try realm.get(rt)).?, try temporary.get(rt));
    try setValuePropertyStrict(ctx, output, objectFromValue(try realm.get(rt)).?, try matcher.get(rt), core.atom.ids.lastIndex, uint32NumberValue(toUint32Number(@floatFromInt(last_index))), caller_function, caller_frame);

    try temporary.set(rt, (try regExpStringIteratorPrototype(rt, objectFromValue(try realm.get(rt)).?)).value());
    try temporary.set(rt, (try core.Object.create(rt, core.class.ids.regexp_string_iterator, objectFromValue(try temporary.get(rt)).?)).value());
    const iterator = objectFromValue(try temporary.get(rt)).?;
    // No allocating step follows these owner-aware barrier writes.
    try iterator.setOptionalValueSlot(rt, iterator.iteratorTargetSlot(), try matcher.get(rt));
    try iterator.setOptionalValueSlot(rt, iterator.iteratorDataSlot(), try source.get(rt));
    iterator_slots.setRegExpStringIteratorFlags(iterator, .{ .global = global_flag, .unicode = unicode_flag });
    iterator.iteratorIndexSlot().* = 0;
    return try temporary.get(rt);
}

pub fn stringMatchAll(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    // Snapshot arguments before getters/coercions can reenter or collect.
    var values = [_]core.JSValue{ global.value(), this_value, if (args.len >= 1) args[0] else core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    // Slots: realm, receiver/source, pattern/constructed regexp, method, flags.
    if (this_value.is(.null_value) or this_value.is(.undefined_value)) return throwTypeErrorMessage(ctx, global, "cannot convert to object");
    const match_all_atom = (comptime core.atom.predefinedId("Symbol.matchAll", .symbol)) orelse return error.TypeError;
    if (values[2].is(.object)) {
        if (try isRegExpObservable(ctx, output, objectFromValue(values[0]).?, values[2], caller_function, caller_frame)) {
            // check_regexp_g_flag: undefined/null flags
            // -> "cannot convert to object"; missing 'g' -> "regexp must have the 'g' flag".
            const flags_atom = (comptime core.atom.predefinedId("flags", .string)) orelse return error.TypeError;
            values[4] = try getValueProperty(ctx, output, objectFromValue(values[0]).?, values[2], flags_atom, caller_function, caller_frame);
            if (values[4].is(.undefined_value) or values[4].is(.null_value))
                return throwTypeErrorMessage(ctx, objectFromValue(values[0]).?, "cannot convert to object");
            values[4] = try toStringForAnnexB(ctx, output, objectFromValue(values[0]).?, values[4], caller_function, caller_frame);
            if (!try stringValueContainsByte(ctx.runtime, values[4], 'g'))
                return throwTypeErrorMessage(ctx, objectFromValue(values[0]).?, "regexp must have the 'g' flag");
        }
        values[3] = try getValueProperty(ctx, output, objectFromValue(values[0]).?, values[2], match_all_atom, caller_function, caller_frame);
        if (!values[3].is(.undefined_value) and !values[3].is(.null_value)) {
            return callValueOrBytecodeRoot(ctx, output, objectFromValue(values[0]).?, values[2], values[3], &.{values[1]}, caller_function, caller_frame);
        }
    }

    values[1] = try toStringForAnnexB(ctx, output, objectFromValue(values[0]).?, values[1], caller_function, caller_frame);
    // RegExpCreate uses RegExpInitialize, without another IsRegExp lookup.
    if (!values[2].is(.undefined_value))
        values[2] = try toStringForAnnexB(ctx, output, objectFromValue(values[0]).?, values[2], caller_function, caller_frame);
    values[4] = try value_ops.createStringValue(ctx.runtime, "g");
    const regexp_args = [_]core.JSValue{ values[2], values[4] };
    values[2] = (try builtin_dispatch.callConstructRecord(ctx, output, objectFromValue(values[0]).?, &.{}, null, regexp_construct_ref, ctx.classPrototypeObject(core.class.ids.regexp), &regexp_args, caller_function, caller_frame)) orelse return error.TypeError;
    values[3] = try getValueProperty(ctx, output, objectFromValue(values[0]).?, values[2], match_all_atom, caller_function, caller_frame);
    return callValueOrBytecodeRoot(ctx, output, objectFromValue(values[0]).?, values[2], values[3], &.{values[1]}, caller_function, caller_frame);
}

pub fn regExpStringIteratorPrototype(rt: *core.JSRuntime, global: *core.Object) !*core.Object {
    var values = [_]core.JSValue{ global.value(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    values[1] = (try iteratorPrototype(rt, objectFromValue(values[0]).?, "RegExp String Iterator")).value();
    values[2] = try core.function.nativeFunctionForGlobal(rt, objectFromValue(values[0]).?, "next", 0);
    try objectFromValue(values[1]).?.defineOwnProperty(rt, (comptime core.atom.predefinedId("next", .string)).?, core.Descriptor.data(values[2], .method));
    return objectFromValue(values[1]).?;
}

pub fn regExpSymbolReplace(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (!this_value.is(.object)) return error.TypeError;
    var values = [_]core.JSValue{ global.value(), this_value, if (args.len >= 1) args[0] else core.JSValue.undefinedValue(), if (args.len >= 2) args[1] else core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    values[2] = try toStringForAnnexB(ctx, output, objectFromValue(values[0]).?, values[2], caller_function, caller_frame);
    return try regExpSymbolReplaceGeneric(ctx, output, objectFromValue(values[0]).?, values[1], values[2], values[3], caller_function, caller_frame);
}

pub fn regExpSymbolSplit(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    return regExpSymbolSplitEntryRooted(ctx, output, global, this_value, args, caller_function, caller_frame) catch |err| switch (err) {
        error.RootGenerationExhausted => error.OutOfMemory,
        error.RootAlreadyActive, error.RootMutationDuringCollection, error.WrongRuntime, error.InactiveRoot, error.InvalidRootIndex => std.debug.panic("regExpSymbolSplit entry contract: {s}", .{@errorName(err)}),
        else => |other| other,
    };
}

fn regExpSymbolSplitEntryRooted(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (!this_value.is(.object)) return error.TypeError;
    const rt = ctx.runtime;
    var roots = core.runtime.ExactValueRoots(7){};
    try roots.activate(rt);
    defer roots.deactivate();
    const realm = try roots.ref(0);
    const receiver = try roots.ref(1);
    const source = try roots.ref(2);
    const limit_input = try roots.ref(3);
    const constructor = try roots.ref(4);
    const flags = try roots.ref(5);
    const splitter = try roots.ref(6);
    try realm.set(rt, global.value());
    try receiver.set(rt, this_value);
    // Snapshot both arguments before ToString can reenter and reuse storage.
    try source.set(rt, if (args.len >= 1) args[0] else core.JSValue.undefinedValue());
    try limit_input.set(rt, if (args.len >= 2) args[1] else core.JSValue.undefinedValue());
    try source.set(rt, try toStringForAnnexB(ctx, output, objectFromValue(try realm.get(rt)).?, try source.get(rt), caller_function, caller_frame));
    try constructor.set(rt, try regExpSpeciesConstructor(ctx, output, objectFromValue(try realm.get(rt)).?, try receiver.get(rt), caller_function, caller_frame));
    try flags.set(rt, try regExpSplitFlags(ctx, output, objectFromValue(try realm.get(rt)).?, try receiver.get(rt), caller_function, caller_frame));
    const unicode_matching = try regExpFlagsAreFullUnicode(rt, try flags.get(rt));
    const construct_args = [_]core.JSValue{ try receiver.get(rt), try flags.get(rt) };
    try splitter.set(rt, try constructValueOrBytecode(ctx, output, objectFromValue(try realm.get(rt)).?, try constructor.get(rt), &construct_args, caller_function, caller_frame));

    var limit: u32 = std.math.maxInt(u32);
    if (!(try limit_input.get(rt)).is(.undefined_value)) {
        try limit_input.set(rt, try toPrimitiveForNumber(ctx, output, objectFromValue(try realm.get(rt)).?, try limit_input.get(rt)));
        if ((try limit_input.get(rt)).isBigInt()) return error.TypeError;
        const number_value = try value_ops.toNumberValue(rt, try limit_input.get(rt));
        const number = value_ops.numberValue(number_value) orelse std.math.nan(f64);
        limit = toUint32Number(number);
    }
    return try regExpSymbolSplitGeneric(ctx, output, objectFromValue(try realm.get(rt)).?, try splitter.get(rt), try source.get(rt), limit, unicode_matching, caller_function, caller_frame);
}

pub fn regExpSplitFlags(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const flags_string = try getRegExpFlagsString(ctx, output, global, rx, caller_function, caller_frame);
    if (stringValueContainsUnitByte(flags_string, 'y')) return flags_string;

    // js_regexp_Symbol_split uses JS_ConcatString3(ctx, "", flags, "y"):
    // consume the flags string and allocate the final payload once, without a
    // separate temporary JSString for the literal suffix.
    return value_ops.appendAsciiSuffixOwned(ctx.runtime, flags_string, "y");
}

pub fn stringValueContainsByte(rt: *core.JSRuntime, string_value: core.JSValue, needle: u8) !bool {
    // All RegExp callers have already applied ToString. Match QuickJS's
    // string_indexof_char by inspecting Latin-1/UTF-16 leaves without
    // materializing ropes; retain the generic non-string conversion fallback.
    if (string_value.isString()) return stringValueContainsUnitByte(string_value, needle);
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try value_ops.appendRawString(rt, &bytes, string_value);
    return std.mem.indexOfScalar(u8, bytes.items, needle) != null;
}

pub fn regExpSymbolSplitGeneric(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    splitter: core.JSValue,
    string_value: core.JSValue,
    limit: u32,
    unicode_matching: bool,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return regExpSymbolSplitRooted(ctx, output, global, splitter, string_value, limit, unicode_matching, caller_function, caller_frame) catch |err| switch (err) {
        error.RootGenerationExhausted => error.OutOfMemory,
        error.RootAlreadyActive, error.RootMutationDuringCollection, error.WrongRuntime, error.InactiveRoot, error.InvalidRootIndex => std.debug.panic("regExpSymbolSplit value contract: {s}", .{@errorName(err)}),
        else => |other| other,
    };
}

fn regExpSymbolSplitRooted(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    splitter: core.JSValue,
    string_value: core.JSValue,
    limit: u32,
    unicode_matching: bool,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (!string_value.isString()) return error.TypeError;
    const rt = ctx.runtime;
    var roots = core.runtime.ExactValueRoots(6){};
    try roots.activate(rt);
    defer roots.deactivate();
    const realm = try roots.ref(0);
    const source = try roots.ref(1);
    const separator = try roots.ref(2);
    const out = try roots.ref(3);
    const result = try roots.ref(4);
    const temporary = try roots.ref(5);
    try realm.set(rt, global.value());
    try source.set(rt, string_value);
    try separator.set(rt, splitter);
    const input_len = core.string.stringValueLen(string_value);
    try out.set(rt, (try core.Object.createArray(rt, arrayPrototypeFromGlobal(rt, objectFromValue(try realm.get(rt)).?))).value());
    var out_index: u32 = 0;
    if (limit == 0) return out.get(rt);

    if (input_len == 0) {
        try result.set(rt, try regExpExecGeneric(ctx, output, objectFromValue(try realm.get(rt)).?, try separator.get(rt), try source.get(rt), caller_function, caller_frame));
        if ((try result.get(rt)).is(.null_value)) try defineSplitValueElement(rt, objectFromValue(try out.get(rt)).?, out_index, try source.get(rt));
        return out.get(rt);
    }

    var start: usize = 0;
    var pos: usize = 0;
    while (pos < input_len) {
        try setValuePropertyStrict(ctx, output, objectFromValue(try realm.get(rt)).?, try separator.get(rt), core.atom.ids.lastIndex, core.JSValue.int32(@intCast(pos)), caller_function, caller_frame);
        try result.set(rt, try regExpExecGeneric(ctx, output, objectFromValue(try realm.get(rt)).?, try separator.get(rt), try source.get(rt), caller_function, caller_frame));
        if ((try result.get(rt)).is(.null_value)) {
            pos = advanceStringIndexValue(try source.get(rt), pos, unicode_matching);
            continue;
        }

        try temporary.set(rt, try getValueProperty(ctx, output, objectFromValue(try realm.get(rt)).?, try separator.get(rt), core.atom.ids.lastIndex, caller_function, caller_frame));
        var end = try toLengthIndex(ctx, output, objectFromValue(try realm.get(rt)).?, try temporary.get(rt));
        if (end > input_len) end = input_len;
        if (end == start) {
            pos = advanceStringIndexValue(try source.get(rt), pos, unicode_matching);
            continue;
        }

        try temporary.set(rt, try stringSliceValue(rt, try source.get(rt), start, pos - start));
        try defineSplitValueElementOwned(rt, objectFromValue(try out.get(rt)).?, out_index, try temporary.get(rt));
        out_index += 1;
        if (out_index >= limit) return out.get(rt);
        start = end;

        try temporary.set(rt, try getValueProperty(ctx, output, objectFromValue(try realm.get(rt)).?, try result.get(rt), core.atom.ids.length, caller_function, caller_frame));
        const capture_limit = try toLengthIndex(ctx, output, objectFromValue(try realm.get(rt)).?, try temporary.get(rt));
        var capture_index: usize = 1;
        while (capture_index < capture_limit) : (capture_index += 1) {
            try temporary.set(rt, try getValueProperty(ctx, output, objectFromValue(try realm.get(rt)).?, try result.get(rt), core.Atom.taggedInt(@intCast(capture_index)), caller_function, caller_frame));
            // CreateDataProperty consumes the capture value as-is. Custom exec
            // methods may return non-string captures, and QuickJS does not
            // coerce them in @@split.
            try defineSplitValueElementOwned(rt, objectFromValue(try out.get(rt)).?, out_index, try temporary.get(rt));
            out_index += 1;
            if (out_index >= limit) return out.get(rt);
        }
        pos = start;
    }

    const tail_start = @min(start, input_len);
    try temporary.set(rt, try stringSliceValue(rt, try source.get(rt), tail_start, input_len - tail_start));
    try defineSplitValueElementOwned(rt, objectFromValue(try out.get(rt)).?, out_index, try temporary.get(rt));
    return out.get(rt);
}

fn advanceStringIndexValue(value: core.JSValue, index: usize, unicode: bool) usize {
    if (!unicode or index + 1 >= core.string.stringValueLen(value)) return index + 1;
    const first = core.string.stringValueCodeUnitAtUnchecked(value, index);
    if (!isHighSurrogateUnit(first)) return index + 1;
    const second = core.string.stringValueCodeUnitAtUnchecked(value, index + 1);
    return if (isLowSurrogateUnit(second)) index + 2 else index + 1;
}

pub fn advanceStringIndexBody(string: *const core.string.String, index: usize, unicode: bool) usize {
    if (!unicode or index + 1 >= string.len()) return index + 1;
    const first = string.codeUnitAt(index);
    if (!isHighSurrogateUnit(first)) return index + 1;
    const second = string.codeUnitAt(index + 1);
    return if (isLowSurrogateUnit(second)) index + 2 else index + 1;
}

pub fn advanceStringIndexUnits(units: []const u16, index: usize, unicode: bool) usize {
    if (!unicode or index + 1 >= units.len) return index + 1;
    const first = units[index];
    if (!isHighSurrogateUnit(first)) return index + 1;
    const second = units[index + 1];
    return if (isLowSurrogateUnit(second)) index + 2 else index + 1;
}

pub fn regExpSymbolSearchGeneric(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    string_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return regExpSymbolSearchRooted(ctx, output, global, rx, string_value, caller_function, caller_frame) catch |err| switch (err) {
        error.RootGenerationExhausted => error.OutOfMemory,
        error.RootAlreadyActive, error.RootMutationDuringCollection, error.WrongRuntime, error.InactiveRoot, error.InvalidRootIndex => std.debug.panic("regExpSymbolSearch value contract: {s}", .{@errorName(err)}),
        else => |other| other,
    };
}

fn regExpSymbolSearchRooted(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    string_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const rt = ctx.runtime;
    var roots = core.runtime.ExactValueRoots(5){};
    try roots.activate(rt);
    defer roots.deactivate();
    const realm = try roots.ref(0);
    const receiver = try roots.ref(1);
    const source = try roots.ref(2);
    const previous = try roots.ref(3);
    const result = try roots.ref(4);
    try realm.set(rt, global.value());
    try receiver.set(rt, rx);
    try source.set(rt, string_value);
    try previous.set(rt, try getValueProperty(ctx, output, objectFromValue(try realm.get(rt)).?, try receiver.get(rt), core.atom.ids.lastIndex, caller_function, caller_frame));
    if (!(try previous.get(rt)).sameValue(core.JSValue.int32(0))) {
        try setValuePropertyStrict(ctx, output, objectFromValue(try realm.get(rt)).?, try receiver.get(rt), core.atom.ids.lastIndex, core.JSValue.int32(0), caller_function, caller_frame);
    }

    try result.set(rt, try regExpExecGeneric(ctx, output, objectFromValue(try realm.get(rt)).?, try receiver.get(rt), try source.get(rt), caller_function, caller_frame));

    const current = try getValueProperty(ctx, output, objectFromValue(try realm.get(rt)).?, try receiver.get(rt), core.atom.ids.lastIndex, caller_function, caller_frame);
    if (!current.sameValue(try previous.get(rt))) {
        try setValuePropertyStrict(ctx, output, objectFromValue(try realm.get(rt)).?, try receiver.get(rt), core.atom.ids.lastIndex, try previous.get(rt), caller_function, caller_frame);
    }

    if ((try result.get(rt)).is(.null_value)) return core.JSValue.int32(-1);
    if (!(try result.get(rt)).is(.object)) return error.TypeError;
    const index_atom = (comptime core.atom.predefinedId("index", .string)) orelse return error.TypeError;
    return getValueProperty(ctx, output, objectFromValue(try realm.get(rt)).?, try result.get(rt), index_atom, caller_function, caller_frame);
}

pub fn regExpSymbolMatchGeneric(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    string_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return regExpSymbolMatchRooted(ctx, output, global, rx, string_value, caller_function, caller_frame) catch |err| switch (err) {
        error.RootGenerationExhausted => error.OutOfMemory,
        error.RootAlreadyActive, error.RootMutationDuringCollection, error.WrongRuntime, error.InactiveRoot, error.InvalidRootIndex => std.debug.panic("regExpSymbolMatch value contract: {s}", .{@errorName(err)}),
        else => |other| other,
    };
}

fn regExpSymbolMatchRooted(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    string_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const rt = ctx.runtime;
    var roots = core.runtime.ExactValueRoots(6){};
    try roots.activate(rt);
    defer roots.deactivate();
    const realm = try roots.ref(0);
    const receiver = try roots.ref(1);
    const source = try roots.ref(2);
    const out = try roots.ref(3);
    const result = try roots.ref(4);
    const temporary = try roots.ref(5);
    try realm.set(rt, global.value());
    try receiver.set(rt, rx);
    try source.set(rt, string_value);
    try temporary.set(rt, try getRegExpFlagsString(ctx, output, objectFromValue(try realm.get(rt)).?, try receiver.get(rt), caller_function, caller_frame));

    if (!stringValueContainsUnitByte(try temporary.get(rt), 'g')) {
        return regExpExecGeneric(ctx, output, objectFromValue(try realm.get(rt)).?, try receiver.get(rt), try source.get(rt), caller_function, caller_frame);
    }

    const full_unicode = try regExpFlagsAreFullUnicode(rt, try temporary.get(rt));
    try setValuePropertyStrict(ctx, output, objectFromValue(try realm.get(rt)).?, try receiver.get(rt), core.atom.ids.lastIndex, core.JSValue.int32(0), caller_function, caller_frame);

    try out.set(rt, (try core.Object.createArray(rt, arrayPrototypeFromGlobal(rt, objectFromValue(try realm.get(rt)).?))).value());
    var count: u32 = 0;
    while (true) {
        try result.set(rt, try regExpExecGeneric(ctx, output, objectFromValue(try realm.get(rt)).?, try receiver.get(rt), try source.get(rt), caller_function, caller_frame));
        if ((try result.get(rt)).is(.null_value)) break;
        try temporary.set(rt, try getValueProperty(ctx, output, objectFromValue(try realm.get(rt)).?, try result.get(rt), core.Atom.taggedInt(0), caller_function, caller_frame));
        if (!(try temporary.get(rt)).isString()) try temporary.set(rt, try toStringForAnnexB(ctx, output, objectFromValue(try realm.get(rt)).?, try temporary.get(rt), caller_function, caller_frame));
        const is_empty = isEmptyStringValue(rt, try temporary.get(rt));
        try defineSplitValueElementOwned(rt, objectFromValue(try out.get(rt)).?, count, try temporary.get(rt));
        count += 1;
        if (is_empty) {
            try temporary.set(rt, try getValueProperty(ctx, output, objectFromValue(try realm.get(rt)).?, try receiver.get(rt), core.atom.ids.lastIndex, caller_function, caller_frame));
            const next = try advanceStringIndexNumber(ctx, output, objectFromValue(try realm.get(rt)).?, try source.get(rt), try temporary.get(rt), full_unicode);
            try setValuePropertyStrict(ctx, output, objectFromValue(try realm.get(rt)).?, try receiver.get(rt), core.atom.ids.lastIndex, next, caller_function, caller_frame);
        }
    }
    // Unpublished arrays are reclaimed by GC when the roots leave scope.
    if (count == 0) return core.JSValue.nullValue();
    return out.get(rt);
}

pub const ReplaceMatch = struct {
    result: core.JSValue,
    matched: core.JSValue,
    index: usize,
    captures: []core.JSValue,
    groups: core.JSValue,
};

/// Precise root for the match list `regExpSymbolReplaceGeneric` builds
/// before it runs a single replacement (spec step 14 "results"). The list
/// lives on the Zig heap and its values are scattered inside structs, so
/// neither a `ValueRootSlice` nor the conservative stack scan sees them;
/// the replacer callback (or a user `exec`) runs JS with every earlier
/// match's `groups` / captures unrooted. Found by test262
/// `RegExp/named-groups/functional-replace-global.js` under
/// `ZJS_GC_STRESS=1`: the minor condemned `groups` and the replacer then
/// read a freed cell.
const ReplaceMatchRoots = struct {
    runtime: *core.JSRuntime,
    list: *std.ArrayList(ReplaceMatch),
    registered: bool = false,

    fn traceRoots(context: *anyopaque, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
        const self: *ReplaceMatchRoots = @ptrCast(@alignCast(context));
        for (self.list.items) |*match| {
            try visitor.value(&match.result);
            try visitor.value(&match.matched);
            try visitor.values(match.captures);
            try visitor.value(&match.groups);
        }
    }

    fn provider(self: *ReplaceMatchRoots) core.runtime.RootProvider {
        return .{ .context = @ptrCast(self), .trace = traceRoots };
    }

    fn activate(self: *ReplaceMatchRoots) !void {
        if (comptime !core.runtime.value_root_frames_enabled) return;
        try self.runtime.registerRootProvider(self.provider());
        self.registered = true;
    }

    fn deactivate(self: *ReplaceMatchRoots) void {
        if (!self.registered) return;
        self.runtime.unregisterRootProvider(self.provider());
        self.registered = false;
    }
};

pub fn regExpSymbolReplaceGeneric(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    string_value: core.JSValue,
    replace_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var values = [_]core.JSValue{ global.value(), rx, string_value, replace_value, core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    // Realm, receiver, source, replacer, replacement string, temporary, result.
    const functional_replace = isCallableValue(values[3]);
    values[4] = if (functional_replace)
        core.JSValue.undefinedValue()
    else
        try toStringForAnnexB(ctx, output, objectFromValue(values[0]).?, values[3], caller_function, caller_frame);

    // Standard-regexp fast path (QuickJS js_is_standard_regexp -> js_regexp_replace),
    // probed BEFORE observing the flags getter -- exactly like QuickJS. The guard
    // is fully side-effect-free (never invokes exec/flags/global/unicode), so a
    // non-standard regexp falls through to the generic path which observes those
    // getters in spec order. The fast path drives matching on the compiled
    // bytecode with a single reused capture buffer and no per-match array object.
    if (!functional_replace) {
        if (objectFromValue(values[1])) |rx_object| {
            if (object_ops.regExpIsStandard(ctx.runtime, rx_object)) {
                if (try regExpReplaceFast(ctx, output, objectFromValue(values[0]).?, values[1], values[2], values[4], caller_function, caller_frame)) |res| {
                    return res;
                }
            }
        }
    }

    values[5] = try getRegExpFlagsStringForReplace(ctx, output, objectFromValue(values[0]).?, values[1], caller_function, caller_frame);
    const is_global = try stringValueContainsByte(ctx.runtime, values[5], 'g');
    const full_unicode = try regExpFlagsAreFullUnicode(ctx.runtime, values[5]);
    if (is_global) {
        try setValuePropertyStrict(ctx, output, objectFromValue(values[0]).?, values[1], core.atom.ids.lastIndex, core.JSValue.int32(0), caller_function, caller_frame);
    }

    var matches = std.ArrayList(ReplaceMatch).empty;
    defer matches.deinit(ctx.runtime.nativeAllocator());
    defer {
        freeReplaceMatches(ctx.runtime, matches.items);
    }
    var match_roots = ReplaceMatchRoots{ .runtime = ctx.runtime, .list = &matches };
    try match_roots.activate();
    defer match_roots.deactivate();

    while (true) {
        values[6] = try regExpExecGeneric(ctx, output, objectFromValue(values[0]).?, values[1], values[2], caller_function, caller_frame);
        if (values[6].is(.null_value)) {
            break;
        }
        if (!values[6].is(.object)) {
            return error.TypeError;
        }
        const match = try captureReplaceMatch(ctx, output, objectFromValue(values[0]).?, values[6], values[2], caller_function, caller_frame);
        matches.append(ctx.runtime.nativeAllocator(), match) catch |err| {
            if (match.captures.len != 0) ctx.runtime.nativeAllocator().free(match.captures);
            return err;
        };
        if (!is_global) break;
        if (isEmptyStringValue(ctx.runtime, match.matched)) {
            values[5] = try getValueProperty(ctx, output, objectFromValue(values[0]).?, values[1], core.atom.ids.lastIndex, caller_function, caller_frame);
            const next = try advanceStringIndexNumber(ctx, output, objectFromValue(values[0]).?, values[2], values[5], full_unicode);
            try setValuePropertyStrict(ctx, output, objectFromValue(values[0]).?, values[1], core.atom.ids.lastIndex, next, caller_function, caller_frame);
        }
    }
    if (matches.items.len == 0) return values[2];

    const replacement_is_empty = !functional_replace and (try stringLengthIndex(ctx.runtime, values[4]) == 0);
    const replacement_is_literal = !functional_replace and !replacement_is_empty and !stringValueContainsUnitByte(values[4], '$');

    var source_units = std.ArrayList(u16).empty;
    defer source_units.deinit(ctx.runtime.nativeAllocator());
    try appendStringValueUnits(ctx.runtime, &source_units, values[2]);

    var out = std.ArrayList(u16).empty;
    defer out.deinit(ctx.runtime.nativeAllocator());
    var next_source_position: usize = 0;
    for (matches.items) |match| {
        const matched_len = try stringLengthIndex(ctx.runtime, match.matched);
        const position = @min(match.index, source_units.items.len);
        if (position < next_source_position) continue;
        try out.appendSlice(ctx.runtime.nativeAllocator(), source_units.items[next_source_position..position]);

        const replacement = if (functional_replace) blk: {
            // Rebuild from updated roots after earlier callbacks and collections.
            var replacer_call = CallSite.initInternal(ctx, output, objectFromValue(values[0]).?, core.JSValue.undefinedValue(), values[3], caller_function, caller_frame);
            replacer_call.activateRoots();
            defer replacer_call.deinit();
            break :blk try callReplaceFunction(ctx, output, objectFromValue(values[0]).?, &replacer_call, match, values[2], caller_function, caller_frame);
        } else if (replacement_is_empty and match.groups.is(.undefined_value))
            core.JSValue.undefinedValue()
        else if (replacement_is_literal and match.groups.is(.undefined_value))
            values[4]
        else
            try getSubstitutionString(ctx, output, objectFromValue(values[0]).?, match, values[2], values[4], caller_function, caller_frame);
        if (!replacement_is_empty) try appendStringValueUnits(ctx.runtime, &out, replacement);
        next_source_position = @min(source_units.items.len, position + matched_len);
    }
    try out.appendSlice(ctx.runtime.nativeAllocator(), source_units.items[next_source_position..]);
    return (try core.string.String.createUtf16(ctx.runtime, out.items)).value();
}

// Faithful port of QuickJS `js_regexp_replace` (quickjs.c) -- the "simple cases"
// fast path taken by `js_regexp_Symbol_replace` when the replacement is a plain
// string (non-functional) and the regexp is standard (default `exec`). Drives
// matching directly on the compiled bytecode + a single reused capture buffer,
// substituting `$` patterns straight from the source units. NO per-match JS
// array object, NO property reads, NO per-match allocation -- this is the whole
// reason QuickJS is ~18x faster here. Returns null to bail to the generic
// driver when preconditions fail (non-RegExp receiver, missing bytecode,
// coercible lastIndex required, or named groups present).
pub fn regExpReplaceFast(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    string_value: core.JSValue,
    replacement_string: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    return regExpReplaceFastRooted(ctx, output, global, rx, string_value, replacement_string, caller_function, caller_frame) catch |err| switch (err) {
        error.RootGenerationExhausted => error.OutOfMemory,
        error.RootAlreadyActive, error.RootMutationDuringCollection, error.WrongRuntime, error.InactiveRoot, error.InvalidRootIndex, error.ExpectedString => std.debug.panic("regExpReplaceFast value contract: {s}", .{@errorName(err)}),
        else => |other| other,
    };
}

fn regExpReplaceFastRooted(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    string_value: core.JSValue,
    replacement_string: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    var rx_object = objectFromValue(rx) orelse return null;
    if (rx_object.class_id != core.class.ids.regexp) return null;
    if (!regexp_fastpath.regExpLastIndexCanSkipCoercion(rx_object)) return null;
    const cached_bytecode = rx_object.regexpCompiledBytecode();
    if (cached_bytecode.len == 0) return null;
    var compiled = regexp_adapter.Compiled{ .bytecode = @constCast(cached_bytecode) };
    const re_flags = compiled.flags();
    // QuickJS bails on group names (the generic driver handles `$<name>`).
    if (re_flags.named_groups) return null;
    // Read flags straight from the compiled bytecode -- like QuickJS's
    // js_regexp_replace -- instead of observing the (potentially overridden)
    // flags getter. Safe because the caller already confirmed `exec` is default.
    const is_global = re_flags.global;
    const is_sticky = re_flags.sticky;
    const full_unicode = re_flags.fullUnicode();
    if (!string_value.isString() or !replacement_string.isString()) return null;
    const rt = ctx.runtime;
    var roots = core.runtime.ExactValueRoots(4){};
    try roots.activate(rt);
    defer roots.deactivate();
    const regexp = try roots.ref(0);
    const source = try roots.ref(1);
    const replacement = try roots.ref(2);
    const realm = try roots.ref(3);
    try regexp.set(rt, rx);
    try source.set(rt, string_value);
    try replacement.set(rt, replacement_string);
    try realm.set(rt, global.value());
    // QuickJS resets lastIndex to 0 up front for global regexps.
    if (is_global) try setRegExpLastIndexZero(ctx.runtime, rx_object);

    // Complete both fallible materializations before acquiring any borrowed
    // data. Reacquire the regexp owner and compiled payload after collection.
    try core.string.ensureFlat(rt, source.readOnly(), source);
    try core.string.ensureFlat(rt, replacement.readOnly(), replacement);
    rx_object = objectFromValue(try regexp.get(rt)).?;
    compiled = .{ .bytecode = @constCast(rx_object.regexpCompiledBytecode()) };
    var borrow = core.runtime.NoGcScope{};
    borrow.activate(rt);
    defer borrow.deactivate();
    const sp = core.string.asFlat(try source.get(rt)).?;
    const sp_data = sp.resolveData();
    const source_len = sp_data.len();
    const rp = core.string.asFlat(try replacement.get(rt)).?;
    const rep_data = rp.resolveData();

    const alloc_count = compiled.allocCount();
    const capture_count = compiled.captureCount();
    var inline_capture_slots: [regexp_adapter.small_exec_slots]usize = undefined;
    var heap_capture_slots: []usize = &.{};
    defer if (heap_capture_slots.len != 0) ctx.runtime.nativeAllocator().free(heap_capture_slots);
    const capture = if (alloc_count <= inline_capture_slots.len)
        inline_capture_slots[0..alloc_count]
    else capture: {
        heap_capture_slots = try ctx.runtime.nativeAllocator().alloc(usize, alloc_count);
        break :capture heap_capture_slots;
    };

    var b = StringBuffer{ .allocator = ctx.runtime.nativeAllocator() };
    defer b.deinit();

    // lastIndex: the caller already reset it to 0 for global regexps. Sticky
    // (non-global) reads it; otherwise matching starts at 0 (qjs js_regexp_replace).
    var last_index: usize = 0;
    if (!is_global and is_sticky) {
        last_index = regexp_fastpath.regexpLastIndex(ctx.runtime, rx_object);
    }
    var next_src: usize = 0;
    while (true) {
        if (last_index > source_len) {
            if (is_global or is_sticky) try setRegExpLastIndexZero(ctx.runtime, rx_object);
            break;
        }
        const result = regexp_adapter.execCaptureSlotsOnResolvedStringFromIndex(ctx.runtime, compiled, sp_data, last_index, capture) catch |err| switch (err) {
            error.BytecodeCorrupt, error.Timeout => return null,
            else => return err,
        };
        if (result != .match) {
            if (is_global or is_sticky) try setRegExpLastIndexZero(ctx.runtime, rx_object);
            break;
        }
        const match_start = regexp_adapter.captureSlotValue(capture[0]) orelse 0;
        const match_end = regexp_adapter.captureSlotValue(capture[1]) orelse match_start;
        if (next_src < match_start) try b.appendUnits(sp_data, next_src, match_start - next_src);
        if (rep_data.len() != 0) {
            try appendRegExpSubstitutionFromSlots(&b, sp_data, match_start, match_end, capture, capture_count, rep_data);
        }
        next_src = match_end;
        if (!is_global) {
            if (is_sticky) {
                const next_value = if (match_end <= @as(usize, @intCast(std.math.maxInt(i32))))
                    core.JSValue.int32(@intCast(match_end))
                else
                    core.JSValue.float64(@floatFromInt(match_end));
                try regexp_fastpath.setRegExpLastIndexStrict(ctx, output, objectFromValue(try realm.get(rt)).?, try regexp.get(rt), rx_object, next_value, caller_function, caller_frame);
            }
            break;
        }
        last_index = if (match_end == match_start)
            advanceStringIndexData(sp_data, match_end, full_unicode)
        else
            match_end;
    }
    if (next_src < source_len) try b.appendUnits(sp_data, next_src, source_len - next_src);
    borrow.deactivate();
    return try b.finish(ctx.runtime);
}

/// string_advance_index over a resolved flat body: a narrow
/// string can hold no surrogate pair, so only wide data consults the pair.
fn advanceStringIndexData(data: core.string.String.ResolvedData, index: usize, unicode: bool) usize {
    return switch (data) {
        .latin1 => index + 1,
        .utf16 => |units| advanceStringIndexUnits(units, index, unicode),
    };
}

pub fn appendStringValueUnits(rt: *core.JSRuntime, out: *std.ArrayList(u16), value: core.JSValue) !void {
    if (!value.isString()) {
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(rt.nativeAllocator());
        try value_ops.appendRawString(rt, &bytes, value);
        for (bytes.items) |byte| try out.append(rt.nativeAllocator(), byte);
        return;
    }
    // nativeAllocator may fail but cannot collect or call JS. The borrowed
    // iterator and leaf slices therefore stay valid throughout this copy.
    var iterator = core.string.StringValueIterator.init(value);
    while (iterator.next()) |data| {
        switch (data) {
            .latin1 => |bytes| for (bytes) |byte| try out.append(rt.nativeAllocator(), byte),
            .utf16 => |units| try out.appendSlice(rt.nativeAllocator(), units),
        }
    }
}

pub fn stringValueContainsUnitByte(value: core.JSValue, needle: u8) bool {
    if (!value.isString()) return false;
    var iterator = core.string.StringValueIterator.init(value);
    while (iterator.next()) |data| switch (data) {
        .latin1 => |bytes| if (std.mem.indexOfScalar(u8, bytes, needle) != null) return true,
        .utf16 => |units| for (units) |unit| {
            if (unit == needle) return true;
        },
    };
    return false;
}

pub fn stringValueUnitsEqualBytes(value: core.JSValue, expected: []const u8) bool {
    if (!value.isString() or core.string.stringValueLenUnchecked(value) != expected.len) return false;
    var iterator = core.string.StringValueIterator.init(value);
    var offset: usize = 0;
    while (iterator.next()) |data| {
        const bytes = expected[offset..][0..data.len()];
        switch (data) {
            .latin1 => |units| if (!std.mem.eql(u8, units, bytes)) return false,
            .utf16 => |units| for (units, bytes) |unit, byte| {
                if (unit != byte) return false;
            },
        }
        offset += data.len();
    }
    return true;
}

pub fn getRegExpFlagsStringForReplace(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return getRegExpFlagsString(ctx, output, global, rx, caller_function, caller_frame);
}

pub fn getRegExpFlagsString(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const flags_atom = comptime core.atom.predefinedId("flags", .string).?;
    var values = [_]core.JSValue{ global.value(), rx, core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    values[2] = try getValueProperty(ctx, output, objectFromValue(values[0]).?, values[1], flags_atom, caller_function, caller_frame);
    return toStringForAnnexB(ctx, output, objectFromValue(values[0]).?, values[2], caller_function, caller_frame);
}

pub fn captureReplaceMatch(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    result: core.JSValue,
    string_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !ReplaceMatch {
    return captureReplaceMatchRooted(ctx, output, global, result, string_value, caller_function, caller_frame) catch |err| switch (err) {
        // Generation identities are a finite Runtime resource, like storage.
        error.RootGenerationExhausted => error.OutOfMemory,
        // This function owns all refs in one active scope on ctx.runtime.
        // Violations are engine contract bugs, not JavaScript exceptions.
        error.RootAlreadyActive, error.RootMutationDuringCollection, error.WrongRuntime, error.InactiveRoot, error.InvalidRootIndex => std.debug.panic("captureReplaceMatch root contract: {s}", .{@errorName(err)}),
        else => |other| other,
    };
}

fn captureReplaceMatchRooted(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    result: core.JSValue,
    string_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !ReplaceMatch {
    // Property access and coercion can call JS. Keep the actual slots visible
    // through every callback, including the final groups getter.
    const rt = ctx.runtime;
    var live = core.runtime.ExactValueRoots(5){};
    try live.activate(rt);
    defer live.deactivate();
    const result_root = try live.ref(0);
    const source_root = try live.ref(1);
    const matched_root = try live.ref(2);
    const temporary = try live.ref(3);
    const realm = try live.ref(4);
    try realm.set(rt, global.value());
    try result_root.set(rt, result);
    try source_root.set(rt, string_value);
    try matched_root.set(rt, try getValueProperty(ctx, output, objectFromValue(try realm.get(rt)).?, try result_root.get(rt), core.Atom.taggedInt(0), caller_function, caller_frame));
    try matched_root.set(rt, try toStringForAnnexB(ctx, output, objectFromValue(try realm.get(rt)).?, try matched_root.get(rt), caller_function, caller_frame));

    const index_atom = (comptime core.atom.predefinedId("index", .string)) orelse return error.TypeError;
    try temporary.set(rt, try getValueProperty(ctx, output, objectFromValue(try realm.get(rt)).?, try result_root.get(rt), index_atom, caller_function, caller_frame));
    const string_len = try stringLengthIndex(rt, try source_root.get(rt));
    const index = @min(try toLengthIndex(ctx, output, objectFromValue(try realm.get(rt)).?, try temporary.get(rt)), string_len);

    try temporary.set(rt, try getValueProperty(ctx, output, objectFromValue(try realm.get(rt)).?, try result_root.get(rt), core.atom.ids.length, caller_function, caller_frame));
    const length = try toLengthIndex(ctx, output, objectFromValue(try realm.get(rt)).?, try temporary.get(rt));
    const capture_count = if (length == 0) 0 else length - 1;
    var captures: []core.JSValue = &.{};
    errdefer if (captures.len != 0) ctx.runtime.nativeAllocator().free(captures);
    var rooted_captures: []core.JSValue = &.{};
    var captures_root = ValueSliceRoot{};
    captures_root.init(ctx.runtime, &rooted_captures);
    defer captures_root.deinit();
    if (capture_count != 0) {
        captures = try ctx.runtime.nativeAllocator().alloc(core.JSValue, capture_count);
        var initialized: usize = 0;
        while (initialized < capture_count) {
            const capture_index = initialized;
            captures[capture_index] = try getValueProperty(ctx, output, objectFromValue(try realm.get(rt)).?, try result_root.get(rt), core.Atom.taggedInt(@intCast(capture_index + 1)), caller_function, caller_frame);
            initialized += 1;
            rooted_captures = captures[0..initialized];
            if (!captures[capture_index].is(.undefined_value)) {
                const capture_string = try toStringForAnnexB(ctx, output, objectFromValue(try realm.get(rt)).?, captures[capture_index], caller_function, caller_frame);
                captures[capture_index] = capture_string;
            }
        }
    }

    const groups_atom = (comptime core.atom.predefinedId("groups", .string)) orelse return error.TypeError;
    const groups = try getValueProperty(ctx, output, objectFromValue(try realm.get(rt)).?, try result_root.get(rt), groups_atom, caller_function, caller_frame);
    return .{ .result = try result_root.get(rt), .matched = try matched_root.get(rt), .index = index, .captures = captures, .groups = groups };
}

pub fn freeReplaceMatches(rt: *core.JSRuntime, matches: []ReplaceMatch) void {
    for (matches) |match| {
        if (match.captures.len != 0) rt.nativeAllocator().free(match.captures);
    }
}

pub fn callReplaceFunction(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    replacer_call: *CallSite,
    match: ReplaceMatch,
    string_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var values = [_]core.JSValue{ global.value(), core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    const extra: usize = if (match.groups.is(.undefined_value)) 2 else 3;
    const arg_count = 1 + match.captures.len + extra;
    const args = try ctx.runtime.nativeAllocator().alloc(core.JSValue, arg_count);
    defer ctx.runtime.nativeAllocator().free(args);
    args[0] = match.matched;
    for (match.captures, 0..) |capture, index| args[index + 1] = capture;
    args[1 + match.captures.len] = core.JSValue.int32(@intCast(match.index));
    args[2 + match.captures.len] = string_value;
    if (!match.groups.is(.undefined_value)) args[3 + match.captures.len] = match.groups;
    values[1] = try replacer_call.call(args);
    return toStringForAnnexB(ctx, output, objectFromValue(values[0]).?, values[1], caller_function, caller_frame);
}

pub fn getSubstitutionString(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    match: ReplaceMatch,
    string_value: core.JSValue,
    replacement_string: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var values = [_]core.JSValue{ global.value(), match.groups, string_value, match.matched, replacement_string, core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const captures = match.captures;
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .mutable = &captures } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    values[5] = if (values[1].is(.undefined_value))
        core.JSValue.undefinedValue()
    else if (values[1].is(.null_value))
        return error.TypeError
    else if (values[1].is(.object))
        values[1]
    else
        try primitiveObjectForAccess(ctx.runtime, objectFromValue(values[0]).?, values[1]);

    var source = std.ArrayList(u16).empty;
    defer source.deinit(ctx.runtime.nativeAllocator());
    try appendStringValueUnits(ctx.runtime, &source, values[2]);
    var matched = std.ArrayList(u16).empty;
    defer matched.deinit(ctx.runtime.nativeAllocator());
    try appendStringValueUnits(ctx.runtime, &matched, values[3]);
    var replacement = std.ArrayList(u16).empty;
    defer replacement.deinit(ctx.runtime.nativeAllocator());
    try appendStringValueUnits(ctx.runtime, &replacement, values[4]);

    var out = std.ArrayList(u16).empty;
    defer out.deinit(ctx.runtime.nativeAllocator());
    var index: usize = 0;
    while (index < replacement.items.len) : (index += 1) {
        if (replacement.items[index] != '$' or index + 1 >= replacement.items.len) {
            try out.append(ctx.runtime.nativeAllocator(), replacement.items[index]);
            continue;
        }
        const next = replacement.items[index + 1];
        switch (next) {
            '$' => {
                try out.append(ctx.runtime.nativeAllocator(), '$');
                index += 1;
            },
            '&' => {
                try out.appendSlice(ctx.runtime.nativeAllocator(), matched.items);
                index += 1;
            },
            '`' => {
                try out.appendSlice(ctx.runtime.nativeAllocator(), source.items[0..@min(match.index, source.items.len)]);
                index += 1;
            },
            '\'' => {
                const tail_start = @min(source.items.len, match.index + matched.items.len);
                try out.appendSlice(ctx.runtime.nativeAllocator(), source.items[tail_start..]);
                index += 1;
            },
            '0'...'9' => {
                const capture = replacementCaptureUnits(match, replacement.items, &index) orelse {
                    try out.append(ctx.runtime.nativeAllocator(), '$');
                    continue;
                };
                if (!capture.is(.undefined_value)) try appendStringValueUnits(ctx.runtime, &out, capture);
            },
            '<' => {
                if (try appendNamedCaptureSubstitution(ctx, output, objectFromValue(values[0]).?, values[5], replacement.items, &index, &out, caller_function, caller_frame)) continue;
                try out.append(ctx.runtime.nativeAllocator(), '$');
            },
            else => try out.append(ctx.runtime.nativeAllocator(), '$'),
        }
    }
    return (try core.string.String.createUtf16(ctx.runtime, out.items)).value();
}

pub fn replacementCaptureUnits(match: ReplaceMatch, replacement: []const u16, index: *usize) ?core.JSValue {
    const first = replacement[index.* + 1];
    if (!isAsciiDigitUnit(first)) return null;
    if (first == '0') {
        if (index.* + 2 >= replacement.len or !isAsciiDigitUnit(replacement[index.* + 2])) return null;
        const two_digit: usize = @intCast(replacement[index.* + 2] - '0');
        if (two_digit == 0 or two_digit > match.captures.len) return null;
        index.* += 2;
        return match.captures[two_digit - 1];
    }
    var capture_index: usize = @intCast(first - '0');
    var consumed: usize = 1;
    if (index.* + 2 < replacement.len and isAsciiDigitUnit(replacement[index.* + 2])) {
        const two_digit = capture_index * 10 + @as(usize, @intCast(replacement[index.* + 2] - '0'));
        if (two_digit >= 1 and two_digit <= match.captures.len) {
            capture_index = two_digit;
            consumed = 2;
        }
    }
    if (capture_index == 0 or capture_index > match.captures.len) return null;
    index.* += consumed;
    return match.captures[capture_index - 1];
}

// Parse a `$n`/`$nn` capture reference at `replacement[index+1..]` against a
// match with `capture_count` slots (group 0 included). Mirrors
// `replacementCaptureUnits` but yields the one-based group number + consumed
// digit count instead of a materialized JSValue. `null` => not a valid
// reference (emit a literal `$`).
const SlotCaptureRef = struct { group: usize, consumed: usize };
fn parseSlotCaptureRefData(rep_data: core.string.String.ResolvedData, index: usize, capture_count: usize) ?SlotCaptureRef {
    if (capture_count == 0) return null;
    const max_group = capture_count - 1; // valid groups are 1..max_group
    if (max_group == 0) return null;
    const rep_len = rep_data.len();
    const first = resolvedCodeUnitAt(rep_data, index + 1);
    if (!isAsciiDigitUnit(first)) return null;
    if (first == '0') {
        if (index + 2 >= rep_len) return null;
        const second = resolvedCodeUnitAt(rep_data, index + 2);
        if (!isAsciiDigitUnit(second)) return null;
        const two: usize = @intCast(second - '0');
        if (two == 0 or two > max_group) return null;
        return .{ .group = two, .consumed = 2 };
    }
    var group: usize = @intCast(first - '0');
    var consumed: usize = 1;
    if (index + 2 < rep_len) {
        const second = resolvedCodeUnitAt(rep_data, index + 2);
        if (isAsciiDigitUnit(second)) {
            const two = group * 10 + @as(usize, @intCast(second - '0'));
            if (two >= 1 and two <= max_group) {
                group = two;
                consumed = 2;
            }
        }
    }
    if (group == 0 or group > max_group) return null;
    return .{ .group = group, .consumed = consumed };
}

// Faithful port of QuickJS `js_string_GetSubstitution` operating directly on the
// raw capture-slot buffer (no per-match array object). `$&`/`` $` ``/`$'`/`$$`
// and `$n`/`$nn` are all slices of the source units; an unmatched group expands
// to empty. Group-name (`$<name>`) substitution is intentionally NOT handled
// here -- the fast path bails to the generic driver when the pattern has named
// groups, exactly as QuickJS does.
/// js_string_GetSubstitution in its raw-capture shape
/// (`captures != NULL`): `$&`/`$\``/`$'`/`$N` substitute directly from the
/// source body slices held by the reused capture-slot buffer; no per-capture
/// string materialization.
fn appendRegExpSubstitutionFromSlots(
    b: *StringBuffer,
    sp_data: core.string.String.ResolvedData,
    match_start: usize,
    match_end: usize,
    capture: []const usize,
    capture_count: usize,
    rep_data: core.string.String.ResolvedData,
) !void {
    const rep_len = rep_data.len();
    var index: usize = 0;
    while (index < rep_len) : (index += 1) {
        const unit = resolvedCodeUnitAt(rep_data, index);
        if (unit != '$' or index + 1 >= rep_len) {
            try b.appendUnits(rep_data, index, 1);
            continue;
        }
        switch (resolvedCodeUnitAt(rep_data, index + 1)) {
            '$' => {
                try b.putc8('$');
                index += 1;
            },
            '&' => {
                try b.appendUnits(sp_data, match_start, match_end - match_start);
                index += 1;
            },
            '`' => {
                try b.appendUnits(sp_data, 0, match_start);
                index += 1;
            },
            '\'' => {
                try b.appendUnits(sp_data, match_end, sp_data.len() - match_end);
                index += 1;
            },
            '0'...'9' => {
                if (parseSlotCaptureRefData(rep_data, index, capture_count)) |ref| {
                    index += ref.consumed;
                    if (regexp_adapter.captureSlotValue(capture[2 * ref.group])) |cstart| {
                        const cend = regexp_adapter.captureSlotValue(capture[2 * ref.group + 1]) orelse cstart;
                        try b.appendUnits(sp_data, cstart, cend - cstart);
                    }
                } else {
                    try b.putc8('$');
                }
            },
            else => try b.putc8('$'),
        }
    }
}

pub fn stringLengthIndex(rt: *core.JSRuntime, string_value: core.JSValue) !usize {
    _ = rt;
    return core.string.stringValueLen(string_value);
}

pub fn isEmptyStringValue(rt: *core.JSRuntime, value: core.JSValue) bool {
    // String and rope headers both carry the length; this branch needs no
    // materialization. Non-string callers retain the legacy conversion path.
    if (value.isString()) return core.string.stringValueLenUnchecked(value) == 0;
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    value_ops.appendRawString(rt, &bytes, value) catch return false;
    return bytes.items.len == 0;
}

pub fn advanceStringIndexNumber(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    string_value: core.JSValue,
    index_value: core.JSValue,
    unicode: bool,
) !core.JSValue {
    var values = [_]core.JSValue{ global.value(), string_value, index_value };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    const index_number = try toLengthNumber(ctx, output, objectFromValue(values[0]).?, values[2]);
    if (!unicode or index_number >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) {
        return value_ops.numberToValue(index_number + 1);
    }
    const index: usize = @intFromFloat(index_number);
    if (!values[1].isString() or index + 1 >= core.string.stringValueLenUnchecked(values[1])) return value_ops.numberToValue(index_number + 1);
    const first = core.string.stringValueCodeUnitAtUnchecked(values[1], index);
    const second = core.string.stringValueCodeUnitAtUnchecked(values[1], index + 1);
    if (isHighSurrogateUnit(first) and isLowSurrogateUnit(second)) {
        return value_ops.numberToValue(index_number + 2);
    }
    return value_ops.numberToValue(index_number + 1);
}

pub fn replaceRegExpLegacySlot(rt: *core.JSRuntime, owner: *core.Object, slot: *?core.JSValue, value: core.JSValue) !void {
    if (slot.*) |old| {
        if (old.same(value)) return;
    }
    const next_value = value;
    // NOT `setOptionalValueSlot`: that remembers the receiver, and the
    // receiver here is the global object while the slot lives in the REALM's
    // `regexp_legacy_statics`. See `Object.setRealmRegExpLegacySlot`.
    owner.setRealmRegExpLegacySlot(rt, slot, next_value);
}

pub fn stringAtomId(value: core.JSValue) ?core.Atom {
    // This is a cache probe, not a request to materialize a property key.
    const string_value = core.string.asFlat(value) orelse
        (if (value.ropeBody()) |rope| rope.flatString() else null) orelse return null;
    if (string_value.atom_id == core.string.String.no_atom_id) return null;
    return string_value.atom_id;
}

/// Route a reused String method *body* through the record table's
/// func-object-free arm. `decoded_method_id` is the legacy selector the builtin
/// string bodies switch on; it is re-encoded to its `PrototypeMethod` record id
/// so the dispatch lands on `string_builtin_ops.zig` `stringCall`, whose
/// `func_obj == null` arm runs the pure `methodCall` (or, for `charAt`,
/// `charAtValue`) body directly. `string_value` is the resolved receiver and
/// `args` are already coerced. This replaces the former direct
/// direct String body calls while the record owner was still outside exec.
pub fn callStringBody(
    ctx: *core.JSContext,
    string_value: core.JSValue,
    decoded_method_id: u32,
    args: []const core.JSValue,
) !core.JSValue {
    const native_ref = core.function.NativeBuiltinRef{ .domain = .string, .id = string_id_lookup.encodePrototypeMethodId(decoded_method_id) orelse return error.TypeError };
    return (try builtin_dispatch.callInternalRecord(ctx, null, null, &.{}, null, string_value, native_ref, args, null, null)) orelse error.TypeError;
}

/// Route `String.prototype.charAt` (decoded id 0, the `charAtValue` body)
/// through the table. The receiver is `string_value` and the single index is
/// forwarded as `args[0]`.
pub fn callStringCharAtBody(
    ctx: *core.JSContext,
    string_value: core.JSValue,
    index_value: core.JSValue,
) !core.JSValue {
    return callStringBody(ctx, string_value, 0, &.{index_value});
}

pub fn stringPrototypeMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    // The RegExp-coupled methods (search/match/split/replaceAll/matchAll) start
    // with `JS_ThrowTypeError(ctx, "cannot convert to object")` on a nullish
    // receiver, not the
    // `JS_ToStringCheckObject` "null or undefined are forbidden" used by the
    // remaining bodies. They therefore run their own nullish check below and are
    // dispatched before the coarse check.
    if (method_id == string_id_lookup.legacy_split_method_id) {
        return stringSplit(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (method_id == string_id_lookup.legacy_search_method_id) {
        return stringSearch(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (method_id == string_id_lookup.legacy_match_method_id) {
        return stringMatch(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (method_id == string_id_lookup.legacy_replace_method_id) {
        return stringReplace(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (method_id == string_id_lookup.legacy_replace_all_method_id) {
        return stringReplaceAll(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (method_id == string_id_lookup.legacy_match_all_method_id) {
        return stringMatchAll(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (this_value.is(.null_value) or this_value.is(.undefined_value)) return throwTypeErrorMessage(ctx, global, "null or undefined are forbidden");
    if (method_id == 10) {
        return stringConcat(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    // Pad / Html / Normalize / LocaleCompare / NumericArgs bodies live in this
    // file (Phase 6b-3 STEP 3B moved them back from the transitional String
    // owner): they
    // are exec-only, reachable solely through this dispatcher. The RegExp-coupled
    // bodies (search/match/split/replaceAll/matchAll and
    // `stringSearchPositionMethod`, which observes RegExp via
    // `isRegExpForStringSearch`) and the BOTH bodies (concat) also stay in exec.
    if (method_id == 34 or method_id == 35) {
        return stringPad(ctx, output, global, this_value, method_id, args, caller_function, caller_frame);
    }
    if (method_id == 11 or method_id == 12 or method_id == 13 or method_id == 14 or method_id == 15 or
        method_id == 16 or method_id == 17 or method_id == 18 or method_id == 19 or method_id == 20 or
        method_id == 23 or method_id == 24 or method_id == 26)
    {
        return stringHtmlMethod(ctx, output, global, this_value, method_id, args, caller_function, caller_frame);
    }
    if (method_id == string_id_lookup.legacy_normalize_method_id) {
        return stringNormalize(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (method_id == 36) {
        return stringLocaleCompare(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (method_id == 4 or method_id == 5 or method_id == 6 or method_id == 7 or method_id == 28) {
        return stringSearchPositionMethod(ctx, output, global, this_value, method_id, args, caller_function, caller_frame);
    }
    if (method_id == 0 or method_id == 1 or method_id == 25 or method_id == 29 or method_id == 30 or method_id == 31 or method_id == 32 or method_id == 33) {
        return stringNumericArgsMethod(ctx, output, global, this_value, method_id, args, caller_function, caller_frame);
    }
    const string_value = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
    return callStringBody(ctx, string_value, method_id, args) catch |err| switch (err) {
        error.RangeError => return throwRangeErrorMessage(ctx, global, "invalid repeat count"),
        error.InvalidLength => return throwRangeErrorMessage(ctx, global, "invalid string length"),
        else => err,
    };
}
pub fn appendUtf32FromStringValue(rt: *core.JSRuntime, out: *std.ArrayList(u32), value: core.JSValue) !void {
    var units = std.ArrayList(u16).empty;
    defer units.deinit(rt.nativeAllocator());
    try appendStringValueUnits(rt, &units, value);
    var index: usize = 0;
    while (index < units.items.len) {
        const unit = units.items[index];
        if (isHighSurrogateUnit(unit) and index + 1 < units.items.len and isLowSurrogateUnit(units.items[index + 1])) {
            try out.append(rt.nativeAllocator(), combinedSurrogateCodePoint(unit, units.items[index + 1]));
            index += 2;
        } else {
            try out.append(rt.nativeAllocator(), unit);
            index += 1;
        }
    }
}

pub fn appendUtf16CodePoint(rt: *core.JSRuntime, out: *std.ArrayList(u16), code_point: u32) !void {
    return unicode_lib.appendUtf16CodePoint(rt.nativeAllocator(), out, @intCast(code_point));
}
pub fn stringSearchPositionMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (this_value.is(.null_value) or this_value.is(.undefined_value)) return error.TypeError;
    var values = [_]core.JSValue{ global.value(), this_value, if (args.len >= 1) args[0] else core.JSValue.undefinedValue(), if (args.len >= 2) args[1] else core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    values[1] = try toStringForAnnexB(ctx, output, objectFromValue(values[0]).?, values[1], caller_function, caller_frame);
    if (method_id == 5 or method_id == 6 or method_id == 7) {
        // js_string_includes: a regexp search argument to
        // includes/startsWith/endsWith throws TypeError "regexp not supported".
        if (try isRegExpForStringSearch(ctx, output, objectFromValue(values[0]).?, values[2], caller_function, caller_frame))
            return throwTypeErrorMessage(ctx, objectFromValue(values[0]).?, "regexp not supported");
    }
    values[2] = try toStringForAnnexB(ctx, output, objectFromValue(values[0]).?, values[2], caller_function, caller_frame);
    if (!values[3].is(.undefined_value)) {
        values[3] = try toPrimitiveForNumber(ctx, output, objectFromValue(values[0]).?, values[3]);
        if (values[3].isBigInt()) return error.TypeError;
        const number_value = try value_ops.toNumberValue(ctx.runtime, values[3]);
        values[3] = value_ops.numberToValue(value_ops.numberValue(number_value) orelse std.math.nan(f64));
    }
    return callStringBody(ctx, values[1], method_id, values[2..][0..if (args.len >= 2) @as(usize, 2) else 1]);
}

pub fn isRegExpForStringSearch(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    return isRegExpObservable(ctx, output, global, value, caller_function, caller_frame);
}

pub fn stringReplaceAll(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return stringReplaceCore(ctx, output, global, this_value, args, true, caller_function, caller_frame);
}

pub fn stringSearch(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    // js_string_match: nullish receiver -> "cannot convert to object".
    if (this_value.is(.null_value) or this_value.is(.undefined_value)) return throwTypeErrorMessage(ctx, global, "cannot convert to object");
    const regexp = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const string_value = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
    if (try callStringWellKnownMethod(ctx, output, global, string_value, regexp, "Symbol.search", caller_function, caller_frame)) |value| return value;
    return try stringRegExpCreateAndInvoke(ctx, output, global, string_value, regexp, "Symbol.search", caller_function, caller_frame);
}

pub fn stringIteratorCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (this_value.is(.null_value) or this_value.is(.undefined_value)) return error.TypeError;
    const string_value = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
    const prototype = try stringIteratorPrototypeFromContext(ctx, global);
    const object = try core.Object.create(ctx.runtime, core.class.ids.string_iterator, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, object.gcHeader());
    try object.setOptionalValueSlot(ctx.runtime, object.iteratorTargetSlot(), string_value);
    object.iteratorIndexSlot().* = 0;
    return object.value();
}

pub fn stringIteratorPrototypeFromContext(ctx: *core.JSContext, global: *core.Object) !*core.Object {
    const slot: usize = core.class.ids.string_iterator;
    if (slot < ctx.class_prototypes.len) {
        const stored = ctx.class_prototypes[slot];
        if (stored.is(.object)) return try property_ops.expectObject(stored);
    }

    const object = try iteratorPrototype(ctx.runtime, global, "String Iterator");
    errdefer core.Object.destroyFromHeader(ctx.runtime, object.gcHeader());
    try builtin_glue.defineNativeDataMethodWithNativeId(ctx.runtime, global, object, core.atom.ids.next, 0, core.function.nativeBuiltinId(.string, @intFromEnum(method_ids.string.PrototypeMethod.iterator_next)));

    // %StringIteratorPrototype% inherits @@iterator from %IteratorPrototype%.
    // An own copy would fail the ES6 String iterator prototype-chain test.

    if (slot < ctx.class_prototypes.len) {
        const value = object.value();
        ctx.class_prototypes[slot] = value;
        // Raw slot store, not `setClassPrototype`: see the same barrier on the
        // Array-iterator prototype in iterator_ops.
        ctx.runtime.gc.generationalBarrier(&ctx.header, object.gcHeader());
    }
    return object;
}

pub fn stringMatch(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    // js_string_match: nullish receiver -> "cannot convert to object".
    if (this_value.is(.null_value) or this_value.is(.undefined_value)) return throwTypeErrorMessage(ctx, global, "cannot convert to object");
    const regexp = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    // QuickJS calls an existing @@match method with the original receiver and
    // only performs ToString after that lookup falls through.
    if (try callStringWellKnownMethod(ctx, output, global, this_value, regexp, "Symbol.match", caller_function, caller_frame)) |value| return value;
    const string_value = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
    return try stringRegExpCreateAndInvoke(ctx, output, global, string_value, regexp, "Symbol.match", caller_function, caller_frame);
}

pub fn stringRegExpCreateAndInvoke(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    string_value: core.JSValue,
    regexp: core.JSValue,
    symbol_name: []const u8,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const constructor = if (global.cachedRealmValue(ctx.runtime, .regexp_constructor)) |stored|
        stored
    else blk: {
        // Embedder fallback when the realm has not published %RegExp%.
        const regexp_key = comptime core.atom.predefinedId("RegExp", .string).?;
        break :blk try global.getProperty(regexp_key);
    };
    // String.prototype.match/search fallback is spec RegExpCreate(P, undefined):
    // RegExpAlloc + RegExpInitialize, which ToStrings a non-RegExp pattern.
    // Going through the constructor would also run IsRegExp and Get @@match
    // a second time (kangax Proxy.get.String.match/search require exactly
    // [@@match|@@search, @@toPrimitive]).
    var owned_pattern: ?core.JSValue = null;
    var pattern = regexp;
    if (pattern.is(.object) and !isRegExpValue(pattern)) {
        const pattern_string = try toStringForAnnexB(ctx, output, global, pattern, caller_function, caller_frame);
        owned_pattern = pattern_string;
        pattern = pattern_string;
    }
    const rx = try regExpConstructCall(ctx, output, global, objectFromValue(constructor), constructor, &.{pattern}, caller_function, caller_frame);
    if (try callStringWellKnownMethod(ctx, output, global, string_value, rx, symbol_name, caller_function, caller_frame)) |value| return value;
    // Mirrors js_string_match: the tail is
    // JS_InvokeFree(ctx, rx, atom, 1, &S) which throws TypeError when the
    // freshly constructed rx has no callable @@match/@@search; there is no
    // silent builtin-match fallback.
    return error.TypeError;
}

pub fn callStringWellKnownMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    candidate: core.JSValue,
    symbol_name: []const u8,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (candidate.is(.undefined_value) or candidate.is(.null_value)) return null;
    if (!candidate.is(.object)) return null;
    const symbol_atom = core.atom.predefinedId(symbol_name, .symbol) orelse return error.TypeError;
    const method = try getValueProperty(ctx, output, global, candidate, symbol_atom, caller_function, caller_frame);
    if (method.is(.undefined_value) or method.is(.null_value)) return null;
    if (!isCallableValue(method)) return error.TypeError;
    const method_args = [_]core.JSValue{this_value};
    return try callValueOrBytecodeRoot(ctx, output, global, candidate, method, &method_args, caller_function, caller_frame);
}

pub fn stringSplit(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    // js_string_split: nullish receiver -> "cannot convert to object".
    if (this_value.is(.null_value) or this_value.is(.undefined_value)) return throwTypeErrorMessage(ctx, global, "cannot convert to object");
    const separator = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (separator.is(.object)) {
        const split_atom = (comptime core.atom.predefinedId("Symbol.split", .symbol)) orelse return error.TypeError;
        const splitter = try getValueProperty(ctx, output, global, separator, split_atom, caller_function, caller_frame);
        if (!splitter.is(.undefined_value) and !splitter.is(.null_value)) {
            if (!isCallableValue(splitter)) return error.TypeError;
            const split_limit = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
            // TGC R1-c: NOT rooted, and the reason is a property of the
            // callee, not of this window. `callValueOrBytecodeRoot` copies
            // the argument array into its own `inline_args` with a plain
            // `@memcpy` before it can allocate, so this array stops being
            // the authoritative storage before the first collection point.
            // A `.slices` root here measured no drop in the census and would
            // have added a production frame link for nothing; the real gap
            // is the callee's own unrooted `inline_args` (call_runtime.zig,
            // outside this lane).
            const split_args = [_]core.JSValue{ this_value, split_limit };
            return callValueOrBytecodeRoot(ctx, output, global, separator, splitter, &split_args, caller_function, caller_frame);
        }
    }

    const string_value = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
    if (args.len == 0) return stringSplitBuiltinArray(ctx, global, string_value, &.{});

    var coerced: [2]core.JSValue = .{ core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    var count: usize = 1;

    if (args.len >= 2 and !args[1].is(.undefined_value)) {
        const primitive = try toPrimitiveForNumber(ctx, output, global, args[1]);
        if (primitive.isBigInt()) return error.TypeError;
        const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
        const number = value_ops.numberValue(number_value) orelse std.math.nan(f64);
        coerced[1] = uint32NumberValue(toUint32Number(number));
        count = 2;
    } else if (args.len >= 2) {
        coerced[1] = core.JSValue.undefinedValue();
        count = 2;
    }

    // Mirrors js_string_split: once the @@split lookup
    // above yielded undefined/null, even a regexp separator takes the string
    // path via R = JS_ToString(ctx, separator) — no builtin regexp split.
    if (args[0].is(.undefined_value)) {
        coerced[0] = core.JSValue.undefinedValue();
    } else {
        coerced[0] = try toStringForAnnexB(ctx, output, global, args[0], caller_function, caller_frame);
    }

    return stringSplitBuiltinArray(ctx, global, string_value, coerced[0..count]);
}

pub fn stringSplitBuiltinArray(
    ctx: *core.JSContext,
    global: *core.Object,
    string_value: core.JSValue,
    args: []const core.JSValue,
) !core.JSValue {
    const result = try callStringBody(ctx, string_value, string_id_lookup.legacy_split_method_id, args);
    if (objectFromValue(result)) |object| {
        if (object.isArray() and object.getPrototype() == null) {
            if (arrayPrototypeFromGlobal(ctx.runtime, global)) |prototype| {
                try object.setPrototype(ctx.runtime, prototype);
            }
        }
    }
    return result;
}

pub const RegExpMatch = struct {
    index: usize,
    len: usize,
    /// Capture pairs borrowed from the matcher for the duration of result
    /// construction. Group zero is represented by `index`/`len`, so this
    /// slice starts at capture group one and contains two slots per group.
    /// QuickJS likewise carries the matcher capture array directly into
    /// `js_regexp_exec` instead of copying it through a max-sized structure.
    capture_slots: []const usize = &.{},
    capture_bytecode: []const u8 = &.{},
    capture_count: usize = 0,
    has_named_captures: bool = false,

    pub inline fn captureAt(self: *const RegExpMatch, capture_index: usize) RegExpCapture {
        std.debug.assert(capture_index < self.capture_count);
        const slot_index = capture_index * 2;
        const capture_start = regexp_adapter.captureSlotValue(self.capture_slots[slot_index]);
        if (capture_start) |start| {
            const end = regexp_adapter.captureSlotValue(self.capture_slots[slot_index + 1]) orelse start;
            return .{ .start = start, .len = end - start };
        }
        return .{ .start = 0, .len = 0, .undefined = true };
    }

    pub inline fn captureNameAt(self: *const RegExpMatch, capture_index: usize) ?[]const u8 {
        std.debug.assert(capture_index < self.capture_count);
        if (!self.has_named_captures) return null;
        return regexp_adapter.groupName(self.capture_bytecode, capture_index + 1);
    }
};

pub const LazyRegExpLegacyCapture = struct {
    start: usize,
    len: usize,
};

const lazy_legacy_capture_len_bits: u6 = 20;
const lazy_legacy_capture_len_limit: usize = @as(usize, 1) << lazy_legacy_capture_len_bits;
const lazy_legacy_capture_len_mask: u64 = lazy_legacy_capture_len_limit - 1;
const lazy_legacy_capture_start_limit: usize = @as(usize, 1) << (47 - lazy_legacy_capture_len_bits);
const lazy_legacy_capture_payload_limit: i64 = @as(i64, 1) << 47;

pub fn encodeRegExpLegacyCaptureSlice(start: usize, len: usize) ?core.JSValue {
    if (start >= lazy_legacy_capture_start_limit or len >= lazy_legacy_capture_len_limit) return null;
    const payload = (@as(u64, @intCast(start)) << lazy_legacy_capture_len_bits) | @as(u64, @intCast(len));
    return core.JSValue.shortBigInt(@intCast(payload));
}

pub fn decodeRegExpLegacyCaptureSlice(value: core.JSValue) ?LazyRegExpLegacyCapture {
    const payload_i64 = value.as(.short_big_int) orelse return null;
    if (payload_i64 < 0 or payload_i64 >= lazy_legacy_capture_payload_limit) return null;
    const payload: u64 = @intCast(payload_i64);
    return .{
        .start = @intCast(payload >> lazy_legacy_capture_len_bits),
        .len = @intCast(payload & lazy_legacy_capture_len_mask),
    };
}

pub fn defineSplitSliceElement(rt: *core.JSRuntime, object: *core.Object, index: u32, input: core.JSValue, start: usize, len: usize) !void {
    const value = try stringSliceValue(rt, input, start, len);
    try defineSplitValueElementOwned(rt, object, index, value);
}

pub fn defineSplitValueElement(rt: *core.JSRuntime, object: *core.Object, index: u32, value: core.JSValue) !void {
    // The core mutation API borrows raw owner/value pointers through storage
    // growth. A read-only root does not rewrite them: explicitly pin the raw
    // object addresses until this call returns; strings are stable carriers.
    const values = [_]core.JSValue{ object.value(), value };
    const slices = [_]core.runtime.ValueRootSlice{.{ .borrowed = &values }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    var owner_pin = try core.runtime.pinHeaderForNative(rt, object.gcHeader());
    defer owner_pin.deinit();
    var value_pin = try core.runtime.pinValueForNative(rt, value);
    defer if (value_pin) |*held| held.deinit();
    const atom_id = core.Atom.taggedInt(index);
    if (try object.appendDenseArrayDefineIndex(rt, index, atom_id, value)) return;
    try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(value, .all));
}

pub fn defineSplitValueElementOwned(rt: *core.JSRuntime, object: *core.Object, index: u32, value: core.JSValue) !void {
    return defineSplitValueElement(rt, object, index, value);
}

// Standard bootstrap creates all five initial shapes together. Keep this
// fallback for minimal embedders, but publish only Shape owners on the realm.
pub noinline fn initRegExpResultPropertyTemplate(rt: *core.JSRuntime, global: *core.Object) !*core.Shape {
    const ctx = rt.contextForGlobal(global) orelse return error.TypeError;
    if (ctx.regexp_result_shape) |initial| return initial;
    try ctx.initializeInitialShapes(
        object_ops.objectPrototypeFromGlobal(rt, global),
        arrayPrototypeFromGlobal(rt, global),
        ctx.classPrototypeObject(core.class.ids.regexp) orelse object_ops.constructorPrototypeFromGlobal(rt, global, "RegExp"),
    );
    return ctx.regexp_result_shape orelse return error.TypeError;
}

fn regExpResultPropertyTemplate(rt: *core.JSRuntime, global: *core.Object) !*core.Shape {
    if (rt.contextForGlobal(global)) |ctx| {
        if (ctx.regexp_result_shape) |initial| return initial;
    }
    return initRegExpResultPropertyTemplate(rt, global);
}

pub noinline fn createRegExpMatchArrayFromValue(
    rt: *core.JSRuntime,
    global: *core.Object,
    input_value: core.JSValue,
    found: *const RegExpMatch,
    input_len: usize,
    has_indices: bool,
) !core.JSValue {
    // The matcher retains found's native capture slots and bytecode backing.
    // All heap intermediates belong to writable slots until publication.
    var values = [_]core.JSValue{ global.value(), input_value, core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    const template = try regExpResultPropertyTemplate(rt, objectFromValue(values[0]).?);
    if (found.has_named_captures) values[2] = (try core.Object.create(rt, core.class.ids.object, null)).value();
    values[3] = (try core.Object.createRegExpMatchArrayFromShape(rt, template, @intCast(found.index), values[1], values[2])).value();

    try initRegExpMatchArrayDenseElementsFromValue(rt, objectFromValue(values[3]).?, values[1], found, objectFromValue(values[2]));

    try updateRegExpLegacyStaticsForMatch(rt, objectFromValue(values[0]).?, values[1], found, input_len);

    if (has_indices) {
        values[4] = try createRegExpIndicesArray(rt, objectFromValue(values[0]).?, found);
        const indices_atom = (comptime core.atom.predefinedId("indices", .string)) orelse return error.TypeError;
        try defineFreshNonIndexDataProperty(rt, objectFromValue(values[3]).?, indices_atom, values[4], .all);
    }
    return values[3];
}

pub fn initRegExpMatchArrayDenseElementsFromValue(
    rt: *core.JSRuntime,
    out: *core.Object,
    input_value: core.JSValue,
    found: *const RegExpMatch,
    groups: ?*core.Object,
) !void {
    var values = [_]core.JSValue{ out.value(), input_value, if (groups) |object| object.value() else core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    std.debug.assert(out.isArray());
    std.debug.assert(out.arrayLength() == 0);
    std.debug.assert(out.arrayElements().len == 0);
    std.debug.assert(out.arrayElementsCapacity() == 0);

    const element_count = found.capture_count + 1;
    // TGC R1 item 6, retiring the S4-b native-staging exception. The old shape
    // staged the captures in native memory and copied them into a freshly
    // minted `.array_storage` cell at the end, because a bare cell has no
    // precise root to survive an allocation on and every `stringSliceValue`
    // below IS an allocation boundary (S2-f: a string body allocation calls
    // `collectBeforeObjectAllocation`). `ValueRootFrame` can name a bare cell:
    // `.headers` roots the cell itself and the `.slices` window roots what is
    // in it, so "mint and install must be adjacent" is satisfied by the root
    // frame instead of by adjacency, and the native buffer plus its copy go
    // away. The window is what makes the frame a CONTAINER frame, which is
    // what the production container-only link policy honours.
    const cell = try core.Object.createArrayStorageSlice(rt, element_count);
    // Rooting publishes the whole cell to the tracer, so no slot may still
    // hold an uninitialized word once the frame is live.
    @memset(cell, core.JSValue.undefinedValue());
    const cell_header = core.Object.arrayStorageCellHeader(cell.ptr);
    var cell_headers = [_]core.runtime.HeaderRootValue{.{ .header = cell_header }};
    var cell_slices = [_]core.runtime.ValueRootSlice{.{ .borrowed = cell }};
    var cell_frame = core.runtime.ValueRootFrame{ .slices = &cell_slices, .headers = &cell_headers };
    cell_frame.activate(rt);
    defer cell_frame.deactivate(rt);

    // QuickJS writes each newly-created substring straight into the expanded
    // fast array. Let the dense array own this value directly as well, instead
    // of duplicating it here and releasing a second owner in the caller. The
    // barrier is the one `setFastArrayElement` takes for the same store: a
    // minor inside the fill loop can promote this cell before the next
    // capture, and an old cell gaining a young string is exactly the edge the
    // generational barrier exists for.
    cell[0] = try stringSliceValue(rt, values[1], found.index, found.len);
    rt.gc.generationalBarrierValue(cell_header, cell[0]);

    var capture_index: usize = 0;
    while (capture_index < found.capture_count) : (capture_index += 1) {
        const element_index = capture_index + 1;
        const capture = found.captureAt(capture_index);
        if (capture.undefined) continue;
        cell[element_index] = try stringSliceValue(rt, values[1], capture.start, capture.len);
        rt.gc.generationalBarrierValue(cell_header, cell[element_index]);
    }

    if (objectFromValue(values[2])) |groups_object| {
        try populateRegExpGroupsFromCaptureValues(rt, groups_object, found, cell);
    }

    const array = objectFromValue(values[0]).?;
    array.adoptDenseArrayElementsAssumingEmpty(rt, cell);
    array.flags.may_have_indexed_properties = true;
}

pub fn updateRegExpLegacyStaticsForMatchValues(
    rt: *core.JSRuntime,
    global: *core.Object,
    input_value: core.JSValue,
    found: *const RegExpMatch,
    input_len: usize,
    matched: core.JSValue,
    legacy_capture_values: *const [9]?core.JSValue,
    last_capture_value: ?core.JSValue,
) !void {
    // Capture arguments are borrowed strings. Root every value before context
    // slicing can collect, and prepare all fallible work before publishing.
    var values: [15]core.JSValue = @splat(core.JSValue.undefinedValue());
    values[0] = global.value();
    values[1] = input_value;
    values[2] = matched;
    values[3] = last_capture_value orelse core.JSValue.undefinedValue();
    const captures = legacy_capture_values.*;
    for (captures, 0..) |capture, index| values[6 + index] = capture orelse core.JSValue.undefinedValue();
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    // The snapshot is native storage owned by the rooted, stable realm.
    const legacy = objectFromValue(values[0]).?.installedRealmRegExpLegacyStatics(rt) orelse
        (try objectFromValue(values[0]).?.ensureInstalledRealmRegExpLegacyStatics(rt)) orelse return;
    const has_left = found.index != 0;
    if (has_left) values[4] = try stringSliceValue(rt, values[1], 0, found.index);
    const right_start = @min(found.index + found.len, input_len);
    const has_right = right_start < input_len;
    if (has_right) values[5] = try stringSliceValue(rt, values[1], right_start, input_len - right_start);

    // A collection during preparation may reenter the engine. Read the old
    // live prefix now so this complete outer snapshot replaces that state.
    var publish = core.runtime.NoGcScope{};
    publish.activate(rt);
    defer publish.deactivate();
    const owner = objectFromValue(values[0]).?;
    const previous_capture_slot_count: usize = legacy.capture_slot_count;
    const next_capture_slot_count = @min(found.capture_count, legacy.captures.len);
    legacy.lazy_no_capture_match = false;

    try replaceRegExpLegacySlot(rt, owner, &legacy.input, values[1]);
    try replaceRegExpLegacySlot(rt, owner, &legacy.last_match, values[2]);

    if (has_left) {
        try replaceRegExpLegacySlot(rt, owner, &legacy.left_context, values[4]);
    } else {
        clearRegExpLegacySlot(rt, &legacy.left_context);
    }

    if (has_right) {
        try replaceRegExpLegacySlot(rt, owner, &legacy.right_context, values[5]);
    } else {
        clearRegExpLegacySlot(rt, &legacy.right_context);
    }

    if (last_capture_value != null) {
        try replaceRegExpLegacySlot(rt, owner, &legacy.last_paren, values[3]);
    } else if (legacy.last_paren != null) {
        clearRegExpLegacySlot(rt, &legacy.last_paren);
    }

    var slot_index: usize = 0;
    while (slot_index < @max(previous_capture_slot_count, next_capture_slot_count)) : (slot_index += 1) {
        if (slot_index < next_capture_slot_count) {
            if (captures[slot_index] != null) {
                try replaceRegExpLegacySlot(rt, owner, &legacy.captures[slot_index], values[6 + slot_index]);
                continue;
            }
        }
        if (legacy.captures[slot_index] != null) clearRegExpLegacySlot(rt, &legacy.captures[slot_index]);
    }
    legacy.capture_slot_count = @intCast(next_capture_slot_count);
}

pub fn updateRegExpLegacyStaticsForMatch(rt: *core.JSRuntime, global: *core.Object, input_value: core.JSValue, found: *const RegExpMatch, input_len: usize) !void {
    if (try updateRegExpLegacyStaticsLazyForMatch(rt, global, input_value, found, input_len)) return;

    // Slots 3..11 hold $1..$9; slot 12 separately retains the last participating
    // capture when its index is beyond the exposed nine captures.
    var values: [13]core.JSValue = @splat(core.JSValue.undefinedValue());
    values[0] = global.value();
    values[1] = input_value;
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    values[2] = try stringSliceValue(rt, values[1], found.index, found.len);

    var capture_index: usize = 0;
    while (capture_index < found.capture_count) : (capture_index += 1) {
        const capture = found.captureAt(capture_index);
        if (capture.undefined) continue;
        values[12] = try stringSliceValue(rt, values[1], capture.start, capture.len);
        if (capture_index < 9) values[3 + capture_index] = values[12];
    }

    var legacy_capture_values: [9]?core.JSValue = @splat(null);
    for (values[3..12], 0..) |value, index| {
        if (!value.is(.undefined_value)) legacy_capture_values[index] = value;
    }
    const last_capture_value = if (values[12].is(.undefined_value)) null else values[12];
    try updateRegExpLegacyStaticsForMatchValues(rt, objectFromValue(values[0]).?, values[1], found, input_len, values[2], &legacy_capture_values, last_capture_value);
}

pub fn updateRegExpLegacyStaticsLazyForMatch(rt: *core.JSRuntime, global: *core.Object, input_value: core.JSValue, found: *const RegExpMatch, input_len: usize) !bool {
    // Only the live capture prefix is read below. Leaving the tail undefined
    // avoids clearing nine 16-byte JSValue cells for every successful match,
    // including the overwhelmingly common zero-capture case; qjs's result
    // loop is likewise proportional to capture_count.
    var encoded_captures: [9]?core.JSValue = undefined;
    var encoded_last_paren: ?core.JSValue = null;

    var capture_index: usize = 0;
    while (capture_index < found.capture_count) : (capture_index += 1) {
        const capture = found.captureAt(capture_index);
        if (capture_index < encoded_captures.len) encoded_captures[capture_index] = null;
        if (capture.undefined) continue;
        const encoded = encodeRegExpLegacyCaptureSlice(capture.start, capture.len) orelse return false;
        if (capture_index < encoded_captures.len) encoded_captures[capture_index] = encoded;
        encoded_last_paren = encoded;
    }

    const legacy = global.installedRealmRegExpLegacyStatics(rt) orelse
        (try global.ensureInstalledRealmRegExpLegacyStatics(rt)) orelse return true;
    const already_lazy = legacy.lazy_no_capture_match;
    const previous_capture_slot_count: usize = legacy.capture_slot_count;
    const next_capture_slot_count = @min(found.capture_count, legacy.captures.len);

    try replaceRegExpLegacySlot(rt, global, &legacy.input, input_value);
    if (!already_lazy) {
        clearRegExpLegacySlot(rt, &legacy.last_match);
        clearRegExpLegacySlot(rt, &legacy.left_context);
        clearRegExpLegacySlot(rt, &legacy.right_context);
    }

    if (encoded_last_paren) |value| {
        try replaceRegExpLegacySlot(rt, global, &legacy.last_paren, value);
    } else if (legacy.last_paren != null) {
        clearRegExpLegacySlot(rt, &legacy.last_paren);
    }

    var slot_index: usize = 0;
    while (slot_index < @max(previous_capture_slot_count, next_capture_slot_count)) : (slot_index += 1) {
        if (slot_index < next_capture_slot_count and encoded_captures[slot_index] != null) {
            const value = encoded_captures[slot_index].?;
            try replaceRegExpLegacySlot(rt, global, &legacy.captures[slot_index], value);
        } else if (legacy.captures[slot_index] != null) {
            clearRegExpLegacySlot(rt, &legacy.captures[slot_index]);
        }
    }

    legacy.capture_slot_count = @intCast(next_capture_slot_count);
    legacy.lazy_no_capture_match = true;
    legacy.lazy_match_index = found.index;
    legacy.lazy_match_len = found.len;
    // `js_regexp_exec` computes the input length once before matching and
    // reuses that scalar while constructing the result. The caller has the
    // same resolved-string length, so do not repeat string representation
    // dispatch solely for the lazy Annex-B snapshot.
    legacy.lazy_input_len = input_len;
    return true;
}

pub fn appendUtf8CodePointForRegExpName(rt: *core.JSRuntime, out: *std.ArrayList(u8), cp: u21) !void {
    return unicode_lib.appendUtf8CodePoint(rt.nativeAllocator(), out, cp);
}

pub fn isHighSurrogateCodePoint(cp: u21) bool {
    return unicode_lib.isHighSurrogateCodePoint(cp);
}

pub fn isLowSurrogateCodePoint(cp: u21) bool {
    return unicode_lib.isLowSurrogateCodePoint(cp);
}

pub fn combinedSurrogateCodePoint(high: u16, low: u16) u21 {
    return unicode_lib.codePointFromSurrogatePair(high, low);
}

pub fn stringSliceValue(rt: *core.JSRuntime, value: core.JSValue, start: usize, len: usize) !core.JSValue {
    if (!value.isString()) return value;
    const input_len = core.string.stringValueLenUnchecked(value);
    const slice_start = @min(start, input_len);
    const slice_len = @min(len, input_len - slice_start);
    if (slice_start == 0 and slice_len == input_len) return value;
    if (slice_len == 0) return (try rt.emptyString()).value();
    if (slice_len == 1) {
        const unit = core.string.stringValueCodeUnitAtUnchecked(value, slice_start);
        if (unit < 0x100) return (try rt.singleByteString(@intCast(unit))).value();
    }
    return (try core.string.String.createValueSlice(rt, value, slice_start, slice_len)).value();
}

pub fn getStringPrototypeMethodId(rt: *core.JSRuntime, function_object: *core.Object) ?u32 {
    _ = rt;
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionId()) orelse return null;
    if (native_ref.domain != .string) return null;
    return string_id_lookup.decodePrototypeMethodId(native_ref.id);
}

pub fn bigIntPrototypeToString(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    primitive: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = caller_function;
    _ = caller_frame;
    const radix: u8 = if (args.len == 0 or args[0].is(.undefined_value))
        10
    else blk: {
        const radix_primitive = try toPrimitiveForNumber(ctx, output, global, args[0]);
        if (radix_primitive.isBigInt() or radix_primitive.is(.symbol)) return error.TypeError;
        const radix_value = try value_ops.toNumberValue(ctx.runtime, radix_primitive);
        const radix_number = value_ops.numberValue(radix_value) orelse return error.RangeError;
        if (std.math.isNan(radix_number) or !std.math.isFinite(radix_number)) return error.RangeError;
        const integer = @trunc(radix_number);
        if (integer < 2 or integer > 36) return error.RangeError;
        break :blk @intFromFloat(integer);
    };
    var bigint = try value_ops.cloneBigIntValue(ctx.runtime, primitive);
    defer bigint.deinit();
    const text = try bigint.formatBaseAlloc(ctx.runtime.nativeAllocator(), radix);
    defer ctx.runtime.nativeAllocator().free(text);
    return value_ops.createStringValue(ctx.runtime, text);
}

const standard_string_method_ids = [_]core.host_function.name_id.Entry{
    .{ .name = "substring", .id = 1 },
    .{ .name = "toUpperCase", .id = 2 },
    .{ .name = "toLocaleUpperCase", .id = 2 },
    .{ .name = "toLowerCase", .id = 3 },
    .{ .name = "toLocaleLowerCase", .id = 3 },
    .{ .name = "indexOf", .id = 4 },
    .{ .name = "includes", .id = 5 },
    .{ .name = "startsWith", .id = 6 },
    .{ .name = "endsWith", .id = 7 },
    .{ .name = "trim", .id = 8 },
    .{ .name = "lastIndexOf", .id = 28 },
    .{ .name = "charCodeAt", .id = 29 },
    .{ .name = "at", .id = 30 },
    .{ .name = "codePointAt", .id = 31 },
    .{ .name = "slice", .id = 32 },
    .{ .name = "repeat", .id = 33 },
    .{ .name = "padStart", .id = 34 },
    .{ .name = "padEnd", .id = 35 },
    .{ .name = "localeCompare", .id = 36 },
    .{ .name = "normalize", .id = string_id_lookup.legacy_normalize_method_id },
    .{ .name = "isWellFormed", .id = 38 },
    .{ .name = "toWellFormed", .id = 39 },
    .{ .name = "search", .id = string_id_lookup.legacy_search_method_id },
    .{ .name = "match", .id = string_id_lookup.legacy_match_method_id },
    .{ .name = "replaceAll", .id = string_id_lookup.legacy_replace_all_method_id },
    .{ .name = "matchAll", .id = string_id_lookup.legacy_match_all_method_id },
};

pub fn standardStringMethodId(name: []const u8) ?u32 {
    return core.host_function.name_id.lookup(name, &standard_string_method_ids);
}

pub fn isStringMethodReceiver(value: core.JSValue) bool {
    if (value.isString()) return true;
    if (!value.is(.object)) return !value.is(.null_value) and !value.is(.undefined_value);
    const object = objectFromValue(value) orelse return false;
    return object.class_id == core.class.ids.string;
}

const annexb_string_method_ids = [_]core.host_function.name_id.Entry{
    .{ .name = "anchor", .id = 11 },
    .{ .name = "big", .id = 12 },
    .{ .name = "blink", .id = 13 },
    .{ .name = "bold", .id = 14 },
    .{ .name = "fixed", .id = 15 },
    .{ .name = "fontcolor", .id = 16 },
    .{ .name = "fontsize", .id = 17 },
    .{ .name = "italics", .id = 18 },
    .{ .name = "link", .id = 19 },
    .{ .name = "small", .id = 20 },
    .{ .name = "trimLeft", .id = 21 },
    .{ .name = "trimStart", .id = 21 },
    .{ .name = "trimRight", .id = 22 },
    .{ .name = "trimEnd", .id = 22 },
    .{ .name = "strike", .id = 23 },
    .{ .name = "sub", .id = 24 },
    .{ .name = "substr", .id = 25 },
    .{ .name = "sup", .id = 26 },
    .{ .name = "split", .id = string_id_lookup.legacy_split_method_id },
};

pub fn annexBStringMethodId(name: []const u8) ?u32 {
    return core.host_function.name_id.lookup(name, &annexb_string_method_ids);
}

pub fn errorToStringCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = objectFromValue(this_value) orelse return exception_ops.throwTypeErrorMessage(ctx, global, "not an object");

    const name_value = try getValueProperty(ctx, output, global, this_value, core.atom.ids.name, caller_function, caller_frame);
    const name_string = if (name_value.is(.undefined_value))
        try value_ops.createStringValue(ctx.runtime, "Error")
    else
        try toStringForAnnexB(ctx, output, global, name_value, caller_function, caller_frame);

    const message_atom = (comptime core.atom.predefinedId("message", .string)).?;
    const message_value = try getValueProperty(ctx, output, global, this_value, message_atom, caller_function, caller_frame);
    const message_string = if (message_value.is(.undefined_value))
        try value_ops.createStringValue(ctx.runtime, "")
    else
        try toStringForAnnexB(ctx, output, global, message_value, caller_function, caller_frame);

    var name_bytes = std.ArrayList(u8).empty;
    defer name_bytes.deinit(ctx.runtime.nativeAllocator());
    try value_ops.appendRawString(ctx.runtime, &name_bytes, name_string);
    var message_bytes = std.ArrayList(u8).empty;
    defer message_bytes.deinit(ctx.runtime.nativeAllocator());
    try value_ops.appendRawString(ctx.runtime, &message_bytes, message_string);

    if (name_bytes.items.len == 0) return try value_ops.createStringValue(ctx.runtime, message_bytes.items);
    if (message_bytes.items.len == 0) return try value_ops.createStringValue(ctx.runtime, name_bytes.items);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(ctx.runtime.nativeAllocator());
    try out.appendSlice(ctx.runtime.nativeAllocator(), name_bytes.items);
    try out.appendSlice(ctx.runtime.nativeAllocator(), ": ");
    try out.appendSlice(ctx.runtime.nativeAllocator(), message_bytes.items);
    return try value_ops.createStringValue(ctx.runtime, out.items);
}

pub fn toStringBytesForSymbol(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) ![]u8 {
    if (value.is(.symbol)) return error.TypeError;
    const string_value = if (value.isString())
        value
    else
        try toStringForAnnexB(ctx, output, global, value, caller_function, caller_frame);

    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(ctx.runtime.nativeAllocator());
    try value_ops.appendRawString(ctx.runtime, &buffer, string_value);
    return buffer.toOwnedSlice(ctx.runtime.nativeAllocator());
}

pub fn consumePendingExceptionIfMatchesConstructor(ctx: *core.JSContext, expected_name: []const u8) !bool {
    const thrown_value = ctx.runtime.current_exception;
    const matches = try thrownValueMatchesConstructor(ctx.runtime, thrown_value, expected_name);
    ctx.clearException();
    return matches;
}

pub fn thrownValueMatchesConstructor(rt: *core.JSRuntime, thrown_value: core.JSValue, expected_name: []const u8) !bool {
    if (!thrown_value.is(.object)) return false;
    const thrown_object = core.value_semantics.objectFromValue(thrown_value) orelse return false;
    const ctor_value = try thrown_object.getProperty(core.atom.ids.constructor);
    if (ctor_value.is(.object)) {
        const ctor = core.value_semantics.objectFromValue(ctor_value);
        if (ctor) |ctor_object| {
            const dispatch_name = try call_mod.nativeFunctionNameForVmBorrowed(rt, ctor_object);
            defer dispatch_name.deinit(rt);
            const name = dispatch_name.name;
            if (std.mem.eql(u8, name, expected_name)) return true;
        }
    }
    const name_value = try thrown_object.getProperty(core.atom.ids.name);
    if (!name_value.isString()) return false;
    var name_bytes = std.ArrayList(u8).empty;
    defer name_bytes.deinit(rt.nativeAllocator());
    try value_ops.appendRawString(rt, &name_bytes, name_value);
    return std.mem.eql(u8, name_bytes.items, expected_name);
}

pub fn arraySearchCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    const mode: enum { index_of, last_index_of, includes } = if (arrayPrototypeRecordId(function_object)) |record_id|
        switch (record_id) {
            @intFromEnum(method_ids.array.PrototypeMethod.last_index_of) => .last_index_of,
            @intFromEnum(method_ids.array.PrototypeMethod.index_of) => .index_of,
            @intFromEnum(method_ids.array.PrototypeMethod.includes) => .includes,
            else => return null,
        }
    else blk: {
        const dispatch_name = try call_mod.nativeFunctionNameForVmBorrowed(ctx.runtime, function_object);
        defer dispatch_name.deinit(ctx.runtime);
        const name = dispatch_name.name;
        break :blk if (std.mem.eql(u8, name, "lastIndexOf"))
            .last_index_of
        else if (std.mem.eql(u8, name, "indexOf"))
            .index_of
        else if (std.mem.eql(u8, name, "includes"))
            .includes
        else
            return null;
    };

    if (receiver.is(.null_value) or receiver.is(.undefined_value)) {
        return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "Cannot convert undefined or null to object"));
    }
    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    const object = objectFromValue(receiver_object_value) orelse return null;
    const is_typed_array = core.object.isTypedArrayObject(object);
    const is_typed_method = isTypedArrayPrototypeMethod(ctx.runtime, function_object);
    if (is_typed_method and !is_typed_array) return error.TypeError;
    const array_proto = arrayPrototypeFromGlobal(ctx.runtime, global) orelse return null;
    if (arrayPrototypeRecordId(function_object) == null) {
        const name = switch (mode) {
            .index_of => "indexOf",
            .last_index_of => "lastIndexOf",
            .includes => "includes",
        };
        const method_atom = try ctx.runtime.internAtom(name);
        const array_method = try array_proto.getProperty(method_atom);
        if (objectFromValue(array_method) != function_object and !is_typed_array) return null;
    }
    const length = if (is_typed_array)
        try arrayMethodTypedArrayLength(ctx.runtime, object, is_typed_method)
    else if (object.isArray())
        @as(usize, @intCast(object.arrayLength()))
    else blk: {
        const length_value = try getValueProperty(ctx, output, global, receiver_object_value, core.atom.ids.length, null, null);
        break :blk try toLengthIndex(ctx, output, global, length_value);
    };
    if (length == 0) return if (mode == .includes) core.JSValue.boolean(false) else core.JSValue.int32(-1);

    const search_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    // Typed arrays: raw-buffer per-class scan (qjs js_typed_array_indexOf,
    // quickjs.c /:58179-58245). Normalize the search value once with an
    // early can't-fit short-circuit, then scan the backing buffer per element
    // kind instead of boxing each element through typedArrayGetIndex. The
    // fromIndex coercion below mirrors what the generic loop already ran.
    if (is_typed_array) {
        const search_mode: array_ops.TypedSearchMode = switch (mode) {
            .index_of => .index_of,
            .last_index_of => .last_index_of,
            .includes => .includes,
        };
        const cursor = if (mode == .last_index_of)
            try arrayLastIndexStart(ctx, output, global, args, length)
        else
            try arrayFirstIndexStart(ctx, output, global, args, length);
        return try array_ops.typedArraySearchScan(ctx.runtime, object, search_mode, search_value, cursor, length);
    }
    if (mode == .last_index_of and length > 1_000_000) {
        return try arrayLastIndexSparseLarge(ctx, output, global, object, receiver_object_value, args, length, search_value);
    }

    // Unique dense paths stay separate. lastIndexOf requires a full-density
    // fast array and returns -1 if the dense scan misses. indexOf/includes
    // scan the dense PREFIX then fall through to the generic tail (qjs
    // js_array_indexOf/includes, quickjs.c).
    const from_right = mode == .last_index_of;
    var cursor = if (from_right)
        try arrayLastIndexStart(ctx, output, global, args, length)
    else
        try arrayFirstIndexStart(ctx, output, global, args, length);
    if (from_right) {
        if (object.isFastArray() and @as(usize, @intCast(object.arrayLength())) == length and object.arrayElements().len == length) {
            const elements = object.arrayElements();
            if (cursor > elements.len) cursor = elements.len;
            while (cursor > 0) {
                cursor -= 1;
                if (try valuesStrictEqual(ctx.runtime, elements[cursor], search_value)) return lengthIndexValue(cursor);
            }
            return core.JSValue.int32(-1);
        }
    } else if (object.isFastArray()) {
        const elements = object.arrayElements();
        const dense_end = @min(elements.len, length);
        while (cursor < dense_end) : (cursor += 1) {
            const item = elements[cursor];
            if (mode == .includes) {
                if (item.sameValueZero(search_value)) return core.JSValue.boolean(true);
            } else {
                if (try valuesStrictEqual(ctx.runtime, item, search_value)) return lengthIndexValue(cursor);
            }
        }
    }

    // Leftover generic present-element search: propertyAtom + has (except
    // includes) + get + sameValueZero / valuesStrictEqual. Direction is
    // taken at runtime (knife 118 leftover-direction shape). After the
    // typed-array early return above, the previous in-loop typed-array
    // arms are dead.
    var remaining: usize = if (from_right) cursor else length - cursor;
    while (remaining > 0) : ({
        remaining -= 1;
        if (!from_right) cursor += 1;
    }) {
        if (from_right) cursor -= 1;
        const key = try propertyAtomFromLengthIndex(ctx.runtime, cursor);
        defer key.deinit(ctx.runtime);
        if (mode != .includes and !try hasValueProperty(ctx, output, global, receiver_object_value, object, key.atom, null, null)) continue;
        const item = try getValueProperty(ctx, output, global, receiver_object_value, key.atom, null, null);
        if (mode == .includes) {
            if (item.sameValueZero(search_value)) return core.JSValue.boolean(true);
        } else {
            if (try valuesStrictEqual(ctx.runtime, item, search_value)) return lengthIndexValue(cursor);
        }
    }
    return if (mode == .includes) core.JSValue.boolean(false) else core.JSValue.int32(-1);
}

pub fn arrayConcatCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    if (!isArrayPrototypeRecord(function_object, @intFromEnum(method_ids.array.PrototypeMethod.concat))) {
        if (!try call_mod.nativeFunctionNameForVmEquals(ctx.runtime, function_object, "concat")) return null;
        if (function_object.arrayBuiltinMarker() != .concat) return null;
    }

    if (receiver.is(.null_value) or receiver.is(.undefined_value)) return error.TypeError;
    const receiver_object_value = if (receiver.is(.object)) receiver else try primitiveObjectForAccess(ctx.runtime, global, receiver);

    const out_value = try arraySpeciesCreate(ctx, output, global, receiver_object_value, 0, caller_function, caller_frame);
    const out = try property_ops.expectObject(out_value);
    var next_index: usize = 0;
    try concatAppendValue(ctx, output, global, out, &next_index, receiver_object_value, caller_function, caller_frame);
    for (args) |arg| try concatAppendValue(ctx, output, global, out, &next_index, arg, caller_function, caller_frame);
    if (next_index > core.array.max_array_length) return error.RangeError;
    _ = try setValueProperty(ctx, output, global, out_value, core.atom.ids.length, lengthIndexValue(next_index), caller_function, caller_frame);
    return out_value;
}

pub fn concatAppendValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    out: *core.Object,
    next_index: *usize,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const max_safe_length: usize = 9007199254740991;
    if (objectFromValue(value)) |object| {
        if (try isConcatSpreadable(ctx, output, global, value, object, caller_function, caller_frame)) {
            const length_value = try concatSpreadLengthValue(ctx, output, global, value, object, caller_function, caller_frame);
            const length = try toLengthIndex(ctx, output, global, length_value);
            if (next_index.* > max_safe_length or length > max_safe_length - next_index.*) return error.TypeError;
            for (0..length) |index| {
                if (next_index.* > core.array.max_array_length) return error.RangeError;
                try arrayCopyPresentIndex(
                    ctx,
                    output,
                    global,
                    value,
                    object,
                    index,
                    out.value(),
                    out,
                    next_index.*,
                    caller_function,
                    caller_frame,
                );
                next_index.* += 1;
            }
            return;
        }
    }
    if (next_index.* >= max_safe_length) return error.TypeError;
    if (next_index.* > core.array.max_array_length) return error.RangeError;
    const key = try propertyAtomFromLengthIndex(ctx.runtime, next_index.*);
    defer key.deinit(ctx.runtime);
    try createDataPropertyOrThrow(ctx, output, global, out.value(), out, key.atom, value, caller_function, caller_frame);
    next_index.* += 1;
}

pub fn concatSpreadLengthValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    object: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const dynamic = try getValueProperty(ctx, output, global, value, core.atom.ids.length, caller_function, caller_frame);
    if (!core.object.isTypedArrayObject(object) or object.typedArrayFixedLength() == null) return dynamic;
    if (try core.object.typedArrayOutOfBounds(object)) return dynamic;
    const own = (try object.getOwnProperty(ctx.runtime, core.atom.ids.length)) orelse return dynamic;
    if (own.kind != .data or !own.value.isNumber() or !dynamic.isNumber()) return dynamic;
    const own_number = value_ops.numberValue(own.value) orelse return dynamic;
    const dynamic_number = value_ops.numberValue(dynamic) orelse return dynamic;
    if (own_number > dynamic_number) {
        return own.value;
    }
    return dynamic;
}

pub fn isConcatSpreadable(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    object: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    const spreadable_atom = (comptime core.atom.predefinedId("Symbol.isConcatSpreadable", .symbol)) orelse return arraySpeciesOriginalIsArray(object);
    const spreadable = try getValueProperty(ctx, output, global, value, spreadable_atom, caller_function, caller_frame);
    if (!spreadable.is(.undefined_value)) return valueTruthy(spreadable);
    return arraySpeciesOriginalIsArray(object);
}

pub fn uint8ArrayStringBytes(rt: *core.JSRuntime, value: core.JSValue) !std.ArrayList(u8) {
    if (!value.isString()) return error.TypeError;
    var bytes = std.ArrayList(u8).empty;
    errdefer bytes.deinit(rt.nativeAllocator());
    try value_ops.appendRawString(rt, &bytes, value);
    return bytes;
}

pub fn appendSourceStringUtf8(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) !void {
    // Eval and Function constructor source conversion use
    // JS_ToCStringLen's non-CESU-8 mode in QuickJS: a valid UTF-16 surrogate
    // pair becomes one four-byte UTF-8 scalar, while an unmatched surrogate is
    // preserved as its three-byte WTF-8 encoding. Reuse the canonical string
    // view instead of encoding each code unit independently.
    var utf8 = try core.JSValue.String.Utf8.fromValue(rt.nativeAllocator(), value);
    defer utf8.deinit();
    try buffer.appendSlice(rt.nativeAllocator(), utf8.slice());
}

pub fn iteratorConcatCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    return iterator_ops.iteratorConcatCall(ctx, output, global, args, arrayPrototypeFromGlobal, getIteratorMethod, isCallableValue);
}

pub fn regExpStringIteratorNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    return regExpStringIteratorNextRooted(ctx, output, global, receiver, caller_function, caller_frame) catch |err| switch (err) {
        error.RootGenerationExhausted => error.OutOfMemory,
        error.RootAlreadyActive, error.RootMutationDuringCollection, error.WrongRuntime, error.InactiveRoot, error.InvalidRootIndex => std.debug.panic("regExpStringIteratorNext value contract: {s}", .{@errorName(err)}),
        else => |other| other,
    };
}

fn regExpStringIteratorNextRooted(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    var iterator = objectFromValue(receiver) orelse return null;
    if (iterator.class_id != core.class.ids.regexp_string_iterator) return null;
    const rt = ctx.runtime;
    var roots = core.runtime.ExactValueRoots(6){};
    try roots.activate(rt);
    defer roots.deactivate();
    const realm = try roots.ref(0);
    const self = try roots.ref(1);
    const regexp = try roots.ref(2);
    const source = try roots.ref(3);
    const result = try roots.ref(4);
    const temporary = try roots.ref(5);
    try realm.set(rt, global.value());
    try self.set(rt, receiver);
    if ((iterator.iteratorIndexSlot().*) != 0) return try createIteratorResult(rt, objectFromValue(try realm.get(rt)).?, core.JSValue.undefinedValue(), true);
    try regexp.set(rt, (iterator.iteratorTargetSlot().*) orelse {
        const done_result = try createIteratorResult(rt, objectFromValue(try realm.get(rt)).?, core.JSValue.undefinedValue(), true);
        objectFromValue(try self.get(rt)).?.iteratorIndexSlot().* = 1;
        return done_result;
    });
    try source.set(rt, iterator.iteratorData() orelse {
        const done_result = try createIteratorResult(rt, objectFromValue(try realm.get(rt)).?, core.JSValue.undefinedValue(), true);
        objectFromValue(try self.get(rt)).?.iteratorIndexSlot().* = 1;
        return done_result;
    });
    // These snapshots must survive even if a reentrant call clears the
    // iterator's target/data slots before the outer operation resumes.
    try result.set(rt, try regExpExecGeneric(ctx, output, objectFromValue(try realm.get(rt)).?, try regexp.get(rt), try source.get(rt), caller_function, caller_frame));
    if ((try result.get(rt)).is(.null_value)) {
        const done_result = try createIteratorResult(rt, objectFromValue(try realm.get(rt)).?, core.JSValue.undefinedValue(), true);
        iterator = objectFromValue(try self.get(rt)).?;
        iterator.iteratorIndexSlot().* = 1;
        iterator.clearOptionalValueSlot(rt, iterator.iteratorTargetSlot());
        iterator.clearOptionalValueSlot(rt, iterator.iteratorDataSlot());
        return done_result;
    }
    iterator = objectFromValue(try self.get(rt)).?;
    const flags = iterator_slots.regExpStringIteratorFlags(iterator);
    const is_global = flags.global;
    if (!is_global) iterator.iteratorIndexSlot().* = 1;
    const unicode = flags.unicode;
    try temporary.set(rt, try getValueProperty(ctx, output, objectFromValue(try realm.get(rt)).?, try result.get(rt), core.Atom.taggedInt(0), caller_function, caller_frame));
    try temporary.set(rt, try toStringForAnnexB(ctx, output, objectFromValue(try realm.get(rt)).?, try temporary.get(rt), caller_function, caller_frame));
    if (is_global and isEmptyStringValue(rt, try temporary.get(rt))) {
        try temporary.set(rt, try getValueProperty(ctx, output, objectFromValue(try realm.get(rt)).?, try regexp.get(rt), core.atom.ids.lastIndex, caller_function, caller_frame));
        const next = try advanceStringIndexNumber(ctx, output, objectFromValue(try realm.get(rt)).?, try source.get(rt), try temporary.get(rt), unicode);
        try setValuePropertyStrict(ctx, output, objectFromValue(try realm.get(rt)).?, try regexp.get(rt), core.atom.ids.lastIndex, next, caller_function, caller_frame);
    }
    return try createIteratorResult(rt, objectFromValue(try realm.get(rt)).?, try result.get(rt), false);
}

pub fn getFastStringPrimitiveDataProperty(
    ctx: *core.JSContext,
    global: *core.Object,
    receiver: core.JSValue,
    atom_id: core.Atom,
) !?core.JSValue {
    if (!receiver.isString()) return null;
    // Resolve any String.prototype own method straight off the prototype without
    // materializing a boxed String wrapper. Restricting to predefined, non-index
    // atoms (excluding `length`, which is the primitive's own length, not
    // `String.prototype.length`) keeps `s[i]`/`s.length`/dynamic-name accesses on
    // their existing paths. This must cover NOT ONLY the `prototypeMethodId`
    // method-table methods (charCodeAt, split, match, …) but also the
    // String.prototype methods installed as plain functions (concat, replace,
    // replaceAll, the AnnexB html helpers). Before this, `"x".replace(...)`
    // missed the bitset gate and fell into `primitiveObjectForAccess`, which
    // builds a String wrapper with one own property per character of the
    // receiver -- O(n) per call, ~13x slower than QuickJS on string `.replace`.
    if (atom_id.isTaggedInt() or atom_id == core.atom.null_atom or atom_id.raw() > core.atom.predefined_count) return null;
    if (atom_id == core.atom.ids.length) return null;

    // Primitive method lookup uses the realm intrinsic `%String.prototype%`,
    // mirroring QuickJS JS_GetPrototypePrimitive. If a bare
    // runtime has no realm slot, fall back to the old global constructor walk.
    const string_ctor_atom = comptime (core.atom.predefinedId("String", .string)).?;
    const proto = object_ops.primitivePrototypeFromRealmOrGlobal(ctx.runtime, global, .string_prototype, string_ctor_atom) orelse return null;
    // W1: route the hot data-property lookup through the lean, already-inline
    // `findOwnDataValueFast` — the SAME primitive the ordinary object get_field path
    // uses — instead of the defensive out-of-line `findProperty`. Mirrors qjs
    // `find_own_property` returning prs+pr in one force_inline pass, then the TMASK
    // switch reading the already-loaded flags: no out-of-line
    // call/frame, no FAM-base re-derivation, no flags re-read. The rare non-data
    // (accessor / auto-init) property falls back to the full resolver.
    if (proto.hasExoticMethods()) return null;
    var slow = false;
    if (proto.findOwnDataValueFast(atom_id, &slow)) |value| return value;
    if (slow) return try ownDataOrAutoInitPropertyValue(proto, atom_id);
    return null;
}

pub fn defineStringWrapperIndexProperty(rt: *core.JSRuntime, object: *core.Object, index: u32, unit: u16) !void {
    // Compatibility entry shares the rooted constructor's property writer.
    return defineStringIndexUnitProperty(rt, object, index, unit);
}

pub fn getStringIndexValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) !?core.JSValue {
    const index = core.array.arrayIndexFromAtom(rt.atoms, atom_id) orelse return null;
    if (!value.isString()) return null;
    if (index >= core.string.stringValueLenUnchecked(value)) return core.JSValue.undefinedValue();
    const unit = core.string.stringValueCodeUnitAtUnchecked(value, index);
    if (unit < 0x100) {
        // Latin-1 fast path: reuse the runtime's single-code-unit string
        // table. Hot loops like `decimalToPercentHexString` in URI sweeps
        // hit this path thousands of times per inner
        // iteration, and avoiding the per-call header+bytes allocation
        // pair is a major speedup.
        return (try rt.singleByteString(@intCast(unit))).value();
    }
    const units: [1]u16 = .{unit};
    const out = try core.string.String.createUtf16(rt, &units);
    return out.value();
}

pub fn arrayToStringCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (!isArrayPrototypeRecord(function_object, @intFromEnum(method_ids.array.PrototypeMethod.to_string))) {
        if (function_object.arrayBuiltinMarker() != .to_string) return null;
    }
    if (this_value.is(.null_value) or this_value.is(.undefined_value)) return error.TypeError;
    const object_value = if (this_value.is(.object)) this_value else try primitiveObjectForAccess(ctx.runtime, global, this_value);
    const join_atom = core.atom.ids.join;
    const join_value = try getValueProperty(ctx, output, global, object_value, join_atom, caller_function, caller_frame);
    if (isCallableValue(join_value)) {
        return try callValueOrBytecodeRoot(ctx, output, global, object_value, join_value, &.{}, caller_function, caller_frame);
    }
    return try objectToStringIntrinsic(ctx, output, global, object_value, caller_function, caller_frame);
}

pub fn arrayToLocaleStringCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (!isArrayPrototypeRecord(function_object, @intFromEnum(method_ids.array.PrototypeMethod.to_locale_string))) {
        if (function_object.arrayBuiltinMarker() != .to_locale_string) return null;
    }
    if (this_value.is(.null_value) or this_value.is(.undefined_value)) return error.TypeError;
    const object_value = if (this_value.is(.object)) this_value else try primitiveObjectForAccess(ctx.runtime, global, this_value);
    const object = core.value_semantics.objectFromValue(object_value) orelse return null;
    const is_typed_method = isTypedArrayPrototypeMethod(ctx.runtime, function_object);
    const is_typed_array = core.object.isTypedArrayObject(object);
    if (is_typed_method and !is_typed_array) return error.TypeError;
    const length = if (is_typed_array)
        try arrayMethodTypedArrayLength(ctx.runtime, object, is_typed_method)
    else blk: {
        const length_value = try getValueProperty(ctx, output, global, object_value, core.atom.ids.length, caller_function, caller_frame);
        break :blk try toLengthIndex(ctx, output, global, length_value);
    };
    const to_locale_key = core.atom.ids.toLocaleString;

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(ctx.runtime.nativeAllocator());
    for (0..length) |index| {
        if (index != 0) try bytes.append(ctx.runtime.nativeAllocator(), ',');
        const item = if (is_typed_array) blk: {
            if (!is_typed_method and index >= try arrayMethodTypedArrayLength(ctx.runtime, object, false)) break :blk core.JSValue.undefinedValue();
            break :blk try core.typed_array.typedArrayGetIndex(ctx.runtime, object, @intCast(index));
        } else blk: {
            const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
            defer key.deinit(ctx.runtime);
            break :blk try getValueProperty(ctx, output, global, object_value, key.atom, caller_function, caller_frame);
        };
        if (!item.is(.undefined_value) and !item.is(.null_value)) {
            const method = try getValueProperty(ctx, output, global, item, to_locale_key, caller_function, caller_frame);
            const locale_value = try callValueOrBytecodeRoot(ctx, output, global, item, method, &.{}, caller_function, caller_frame);
            const locale_string = try toStringForAnnexB(ctx, output, global, locale_value, caller_function, caller_frame);
            try value_ops.appendRawString(ctx.runtime, &bytes, locale_string);
        }
    }
    return try value_ops.createStringValue(ctx.runtime, bytes.items);
}

pub fn objectToLocaleStringCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const to_string_key = core.atom.ids.toString;
    const method = try getValueProperty(ctx, output, global, this_value, to_string_key, caller_function, caller_frame);
    return try callValueOrBytecodeRoot(ctx, output, global, this_value, method, &.{}, caller_function, caller_frame);
}

pub fn objectToStringCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (this_value.is(.undefined_value)) return try objectTagString(ctx.runtime, "Undefined");
    if (this_value.is(.null_value)) return try objectTagString(ctx.runtime, "Null");
    const object_value = if (this_value.is(.object)) this_value else try primitiveObjectForAccess(ctx.runtime, global, this_value);
    return try objectToStringIntrinsic(ctx, output, global, object_value, caller_function, caller_frame);
}

pub fn objectToStringIntrinsic(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const object = try property_ops.expectObject(object_value);
    const builtin_tag = try defaultObjectToStringTag(object);
    const tag_atom = (comptime core.atom.predefinedId("Symbol.toStringTag", .symbol)) orelse return try objectTagString(ctx.runtime, "Object");
    const tag_value = try getValueProperty(ctx, output, global, object_value, tag_atom, caller_function, caller_frame);
    if (tag_value.isString()) {
        var tag = std.ArrayList(u8).empty;
        defer tag.deinit(ctx.runtime.nativeAllocator());
        try value_ops.appendRawString(ctx.runtime, &tag, tag_value);
        return try objectTagString(ctx.runtime, tag.items);
    }
    return try objectTagString(ctx.runtime, builtin_tag);
}

pub fn objectTagString(rt: *core.JSRuntime, tag: []const u8) !core.JSValue {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try bytes.appendSlice(rt.nativeAllocator(), "[object ");
    try bytes.appendSlice(rt.nativeAllocator(), tag);
    try bytes.appendSlice(rt.nativeAllocator(), "]");
    return value_ops.createStringValue(rt, bytes.items);
}

pub fn defaultObjectToStringTag(object: *core.Object) ![]const u8 {
    if (object.isProxy()) {
        if (object.proxyHandler() == null) return error.TypeError;
        if (object.proxyTarget()) |target_value| {
            if (objectFromValue(target_value)) |target| {
                if (try objectIsArrayForToString(target)) return "Array";
                if (proxyTargetIsCallableObject(target)) return "Function";
            }
        }
        return "Object";
    }
    if (object.isArray()) return "Array";
    if (core.class.isBytecodeFunctionClass(object.class_id)) {
        return switch (object.class_id) {
            core.class.ids.bytecode_function => bytecodeFunctionObjectTag(object),
            core.class.ids.generator_function => "GeneratorFunction",
            core.class.ids.async_function => "AsyncFunction",
            core.class.ids.async_generator_function => "AsyncGeneratorFunction",
            else => unreachable,
        };
    }
    return switch (object.class_id) {
        core.class.ids.arguments, core.class.ids.mapped_arguments => "Arguments",
        core.class.ids.error_ => "Error",
        core.class.ids.c_function,
        core.class.ids.bound_function,
        core.class.ids.c_function_data,
        core.class.ids.async_function_resolve,
        core.class.ids.async_function_reject,
        => "Function",
        core.class.ids.boolean => "Boolean",
        core.class.ids.number => "Number",
        core.class.ids.string => "String",
        core.class.ids.date => "Date",
        core.class.ids.regexp => "RegExp",
        core.class.ids.array_buffer => "ArrayBuffer",
        else => "Object",
    };
}

test "standard and annexB string method-id tables preserve load-bearing ids" {
    try std.testing.expectEqual(@as(?u32, 1), standardStringMethodId("substring"));
    try std.testing.expectEqual(@as(?u32, 2), standardStringMethodId("toLocaleUpperCase"));
    try std.testing.expectEqual(@as(?u32, string_id_lookup.legacy_match_all_method_id), standardStringMethodId("matchAll"));
    try std.testing.expectEqual(@as(?u32, null), standardStringMethodId("big"));
    try std.testing.expectEqual(@as(?u32, 12), annexBStringMethodId("big"));
    try std.testing.expectEqual(@as(?u32, 21), annexBStringMethodId("trimLeft"));
    try std.testing.expectEqual(@as(?u32, string_id_lookup.legacy_split_method_id), annexBStringMethodId("split"));
    try std.testing.expectEqual(@as(?u32, null), annexBStringMethodId("substring"));
}

test "default object tag distinguishes bytecode function classes" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const class_ids = [_]core.ClassId{
        core.class.ids.bytecode_function,
        core.class.ids.generator_function,
        core.class.ids.async_function,
        core.class.ids.async_generator_function,
    };
    const expected_tags = [_][]const u8{
        "Function",
        "GeneratorFunction",
        "AsyncFunction",
        "AsyncGeneratorFunction",
    };
    for (class_ids, expected_tags) |class_id, expected_tag| {
        const function_object = try core.Object.create(rt, class_id, null);
        try std.testing.expectEqualStrings(expected_tag, try defaultObjectToStringTag(function_object));
    }
}

pub fn objectIsArrayForToString(object: *core.Object) !bool {
    if (object.isArray()) return true;
    if (!object.isProxy()) return false;
    if (object.proxyHandler() == null) return error.TypeError;
    const target_value = object.proxyTarget() orelse return false;
    const target = objectFromValue(target_value) orelse return false;
    return objectIsArrayForToString(target);
}

pub fn stringObjectHasIndexProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) bool {
    if (object.class_id != core.class.ids.string) return false;
    const string_data = object.objectData() orelse return false;
    const index = core.array.arrayIndexFromAtom(rt.atoms, atom_id) orelse return false;
    if (!string_data.isString()) return false;
    return index < core.string.stringValueLenUnchecked(string_data);
}

// String unit/byte classification helpers (moved from the VM call runtime).

pub fn appendUtf16UnitsAsUtf8(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), units: []const u16) !void {
    return unicode_lib.appendUtf16UnitsAsUtf8(rt.nativeAllocator(), buffer, units);
}
pub fn appendAsciiUnits(rt: *core.JSRuntime, out: *std.ArrayList(u16), bytes: []const u8) !void {
    for (bytes) |byte| try out.append(rt.nativeAllocator(), byte);
}

pub fn isAsciiDigitUnit(unit: u16) bool {
    return unicode_lib.isAsciiDigitUnit(unit);
}

pub fn isHighSurrogateUnit(unit: u16) bool {
    return unicode_lib.isHighSurrogateUnit(unit);
}

pub fn isLowSurrogateUnit(unit: u16) bool {
    return unicode_lib.isLowSurrogateUnit(unit);
}

// ---------------------------------------------------------------------------
// Realm-aware String.prototype method bodies (pad / HTML wrappers / normalize /
// localeCompare / numeric-arg methods). These are reachable ONLY through the
// `stringPrototypeMethod` dispatcher above (the `.string` builtin record
// handler `stringCall` routes the remaining shared prototype methods to it),
// never from a dedicated builtin table entry, so they are exec-only. They were
// briefly hosted in the transitional String owner (Phase 6b-2) and were moved
// back here in Phase 6b-3 STEP 3B to keep the dependency edge exec -> builtins
// out of these bodies. They
// reuse the file-local rope/UTF helpers (`toStringForAnnexB`,
// `appendStringValueUnits`, `appendUtf32FromStringValue`, `appendUtf16CodePoint`,
// `appendAsciiUnits`) plus the shared `value_ops`/`coercion_ops`/`builtin_glue`
// ops. The two leaf bodies they still defer to (the `charAtValue` and
// `methodCall` method-impl bodies that stay in builtins) are reached through the
// record table via `callStringBody`/`callStringCharAtBody` (Phase 6b-3 STEP 5),
// so exec no longer names them directly.

// qjs JS_STRING_LEN_MAX: js_string_pad throws RangeError when the
// requested length exceeds it.
const js_string_len_max: usize = core.string.max_length;

/// A narrow-first accumulator mirroring qjs's StringBuffer (string_buffer_init,
/// quickjs.c): code units are copied into a latin1 (u8) buffer and only widened
/// to UTF-16 when a unit exceeds 0xFF, so an all-latin1 build never
/// materializes a UTF-16 result. It operates on code UNITS (surrogate halves
/// are copied verbatim, matching string_buffer_concat). Consumed by the
/// js_string_pad and js_string_replace mirrors.
const StringBuffer = struct {
    allocator: std.mem.Allocator,
    latin1: std.ArrayList(u8) = .empty,
    wide: std.ArrayList(u16) = .empty,
    is_wide: bool = false,

    fn deinit(self: *StringBuffer) void {
        self.latin1.deinit(self.allocator);
        self.wide.deinit(self.allocator);
    }

    /// string_buffer_putc8: append one latin1 code unit.
    fn putc8(self: *StringBuffer, byte: u8) !void {
        if (self.is_wide)
            try self.wide.append(self.allocator, byte)
        else
            try self.latin1.append(self.allocator, byte);
    }

    /// string_buffer_concat_value: append every code unit of a string value.
    fn appendStringValue(self: *StringBuffer, rt: *core.JSRuntime, value: core.JSValue) !void {
        try self.appendStringPrefix(rt, value, core.string.stringValueLenUnchecked(value));
    }

    /// Copy a prefix in code units, including lone surrogates. Only native
    /// storage grows; no leaf view survives this no-GC window.
    fn appendStringPrefix(self: *StringBuffer, rt: *core.JSRuntime, value: core.JSValue, count: usize) !void {
        std.debug.assert(value.isString());
        std.debug.assert(count <= core.string.stringValueLenUnchecked(value));
        var borrow = core.runtime.NoGcScope{};
        borrow.activate(rt);
        defer borrow.deactivate();
        var remaining = count;
        var iterator = core.string.StringValueIterator.init(value);
        while (remaining != 0) {
            const data = iterator.next().?;
            const chunk = @min(remaining, data.len());
            try self.appendUnits(data, 0, chunk);
            remaining -= chunk;
        }
    }

    fn widen(self: *StringBuffer) !void {
        self.is_wide = true;
        try self.wide.ensureTotalCapacity(self.allocator, self.latin1.items.len);
        for (self.latin1.items) |byte| self.wide.appendAssumeCapacity(byte);
        self.latin1.clearRetainingCapacity();
    }

    fn ensureCapacity(self: *StringBuffer, additional: usize) !void {
        if (self.is_wide)
            try self.wide.ensureUnusedCapacity(self.allocator, additional)
        else
            try self.latin1.ensureUnusedCapacity(self.allocator, additional);
    }

    /// Appends `count` code units of `data` starting at `start`, widening on the
    /// first >0xFF unit encountered (mirrors string_buffer_concat's widen path).
    fn appendUnits(self: *StringBuffer, data: core.string.String.ResolvedData, start: usize, count: usize) !void {
        switch (data) {
            // latin1 units are all <= 0xFF: copy flat, no widen check needed.
            .latin1 => |bytes| {
                const chunk = bytes[start .. start + count];
                if (self.is_wide) {
                    try self.wide.ensureUnusedCapacity(self.allocator, count);
                    for (chunk) |byte| self.wide.appendAssumeCapacity(byte);
                } else {
                    try self.latin1.appendSlice(self.allocator, chunk);
                }
            },
            .utf16 => |units| {
                const chunk = units[start .. start + count];
                try self.ensureCapacity(count);
                for (0..chunk.len) |i| {
                    const unit = chunk[i];
                    if (!self.is_wide) {
                        if (unit <= 0xff) {
                            self.latin1.appendAssumeCapacity(@intCast(unit));
                            continue;
                        }
                        // Widen, then reserve room for the rest of this chunk
                        // (already-copied units moved into `wide`).
                        try self.widen();
                        try self.wide.ensureUnusedCapacity(self.allocator, chunk.len - i);
                    }
                    self.wide.appendAssumeCapacity(unit);
                }
            },
        }
    }

    fn finish(self: *StringBuffer, rt: *core.JSRuntime) !core.JSValue {
        const string = if (self.is_wide)
            try core.string.String.createUtf16(rt, self.wide.items)
        else
            try core.string.String.createLatin1(rt, self.latin1.items);
        return string.value();
    }
};

pub fn stringPad(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return stringPadRooted(ctx, output, global, this_value, method_id, args, caller_function, caller_frame) catch |err| switch (err) {
        error.RootGenerationExhausted => error.OutOfMemory,
        error.RootAlreadyActive, error.RootMutationDuringCollection, error.WrongRuntime, error.InactiveRoot, error.InvalidRootIndex => std.debug.panic("stringPad value contract: {s}", .{@errorName(err)}),
        else => |other| other,
    };
}

fn stringPadRooted(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (this_value.is(.null_value) or this_value.is(.undefined_value)) return throwTypeErrorMessage(ctx, global, "null or undefined are forbidden");
    const rt = ctx.runtime;
    var roots = core.runtime.ExactValueRoots(4){};
    try roots.activate(rt);
    defer roots.deactivate();
    const source = try roots.ref(0);
    const max_length = try roots.ref(1);
    const fill = try roots.ref(2);
    const global_root = try roots.ref(3);
    try source.set(rt, this_value);
    try max_length.set(rt, if (args.len >= 1) args[0] else core.JSValue.undefinedValue());
    try fill.set(rt, if (args.len >= 2) args[1] else core.JSValue.undefinedValue());
    try global_root.set(rt, global.value());

    // All original arguments are registered before the first observable
    // conversion. No caller-owned argument slice or heap view is reused.
    try source.set(rt, try toStringForAnnexB(ctx, output, try expectObject(try global_root.get(rt)), try source.get(rt), caller_function, caller_frame));
    const target_length = try coercion_ops.toLengthIndex(ctx, output, try expectObject(try global_root.get(rt)), try max_length.get(rt));
    const source_len = core.string.stringValueLenUnchecked(try source.get(rt));
    if (target_length <= source_len) return source.get(rt);

    try fill.set(rt, if ((try fill.get(rt)).is(.undefined_value))
        (try rt.singleByteString(' ')).value()
    else
        try toStringForAnnexB(ctx, output, try expectObject(try global_root.get(rt)), try fill.get(rt), caller_function, caller_frame));
    const fill_len = core.string.stringValueLenUnchecked(try fill.get(rt));
    if (fill_len == 0) return source.get(rt);

    // qjs caps the result at JS_STRING_LEN_MAX; without
    // this an out-of-range maxLength would attempt a multi-GiB allocation instead
    // of the spec/qjs RangeError.
    if (target_length > js_string_len_max) return throwRangeErrorMessage(ctx, try expectObject(try global_root.get(rt)), "invalid string length");
    const pad_count = target_length - source_len;

    var buffer = StringBuffer{ .allocator = ctx.runtime.nativeAllocator() };
    defer buffer.deinit();
    try buffer.ensureCapacity(target_length);

    // padEnd: source first, then fill. padStart: fill first, then source.
    // (quickjs.c, magic 0 = padStart / 1 = padEnd; here 34 = start.)
    if (method_id == 35) try buffer.appendStringValue(rt, try source.get(rt));

    var remaining = pad_count;
    while (remaining > 0) {
        const chunk = @min(remaining, fill_len);
        try buffer.appendStringPrefix(rt, try fill.get(rt), chunk);
        remaining -= chunk;
    }

    if (method_id == 34) try buffer.appendStringValue(rt, try source.get(rt));

    return buffer.finish(ctx.runtime);
}

pub fn stringNormalize(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (this_value.is(.null_value) or this_value.is(.undefined_value)) return throwTypeErrorMessage(ctx, global, "null or undefined are forbidden");
    var values = [_]core.JSValue{ global.value(), this_value, if (args.len >= 1) args[0] else core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    values[1] = try toStringForAnnexB(ctx, output, objectFromValue(values[0]).?, values[1], caller_function, caller_frame);

    const form: unicode_lib.NormalizationForm = if (values[2].is(.undefined_value)) .nfc else blk: {
        values[2] = try toStringForAnnexB(ctx, output, objectFromValue(values[0]).?, values[2], caller_function, caller_frame);
        var form_bytes = std.ArrayList(u8).empty;
        defer form_bytes.deinit(ctx.runtime.nativeAllocator());
        try value_ops.appendRawString(ctx.runtime, &form_bytes, values[2]);
        if (std.mem.eql(u8, form_bytes.items, "NFC")) break :blk unicode_lib.NormalizationForm.nfc;
        if (std.mem.eql(u8, form_bytes.items, "NFD")) break :blk unicode_lib.NormalizationForm.nfd;
        if (std.mem.eql(u8, form_bytes.items, "NFKC")) break :blk unicode_lib.NormalizationForm.nfkc;
        if (std.mem.eql(u8, form_bytes.items, "NFKD")) break :blk unicode_lib.NormalizationForm.nfkd;
        // js_string_normalize: unknown form -> RangeError
        // "bad normalization form".
        return throwRangeErrorMessage(ctx, objectFromValue(values[0]).?, "bad normalization form");
    };

    var input = std.ArrayList(u32).empty;
    defer input.deinit(ctx.runtime.nativeAllocator());
    try appendUtf32FromStringValue(ctx.runtime, &input, values[1]);
    const normalized_slice = try unicode_lib.normalizeAlloc(ctx.runtime.nativeAllocator(), input.items, form);
    defer ctx.runtime.nativeAllocator().free(normalized_slice);

    var out = std.ArrayList(u16).empty;
    defer out.deinit(ctx.runtime.nativeAllocator());
    for (normalized_slice) |code_point| try appendUtf16CodePoint(ctx.runtime, &out, code_point);
    return (try core.string.String.createUtf16(ctx.runtime, out.items)).value();
}

pub fn stringLocaleCompare(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (this_value.is(.null_value) or this_value.is(.undefined_value)) return throwTypeErrorMessage(ctx, global, "null or undefined are forbidden");
    var values = [_]core.JSValue{ global.value(), this_value, if (args.len >= 1) args[0] else core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    values[1] = try toStringForAnnexB(ctx, output, objectFromValue(values[0]).?, values[1], caller_function, caller_frame);
    values[2] = try toStringForAnnexB(ctx, output, objectFromValue(values[0]).?, values[2], caller_function, caller_frame);

    const lhs_nfc = try normalizedUtf32(ctx.runtime, values[1], .nfc);
    defer lhs_nfc.deinit();
    const rhs_nfc = try normalizedUtf32(ctx.runtime, values[2], .nfc);
    defer rhs_nfc.deinit();

    const result: i32 = switch (std.mem.order(u32, lhs_nfc.slice, rhs_nfc.slice)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
    return core.JSValue.int32(result);
}

const NormalizedUtf32 = struct {
    allocator: std.mem.Allocator,
    slice: []u32,

    fn deinit(self: NormalizedUtf32) void {
        self.allocator.free(self.slice);
    }
};

fn normalizedUtf32(rt: *core.JSRuntime, value: core.JSValue, form: unicode_lib.NormalizationForm) !NormalizedUtf32 {
    var input = std.ArrayList(u32).empty;
    defer input.deinit(rt.nativeAllocator());
    try appendUtf32FromStringValue(rt, &input, value);
    return .{
        .allocator = rt.nativeAllocator(),
        .slice = try unicode_lib.normalizeAlloc(rt.nativeAllocator(), input.items, form),
    };
}

pub fn stringNumericArgsMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return stringNumericArgsMethodRooted(ctx, output, global, this_value, method_id, args, caller_function, caller_frame) catch |err| switch (err) {
        error.RootGenerationExhausted => error.OutOfMemory,
        error.RootAlreadyActive, error.RootMutationDuringCollection, error.WrongRuntime, error.InactiveRoot, error.InvalidRootIndex => std.debug.panic("stringNumericArgsMethod value contract: {s}", .{@errorName(err)}),
        else => |other| other,
    };
}

fn stringNumericArgsMethodRooted(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (this_value.is(.null_value) or this_value.is(.undefined_value)) return throwTypeErrorMessage(ctx, global, "null or undefined are forbidden");
    const rt = ctx.runtime;
    var roots = core.runtime.ExactValueRoots(4){};
    try roots.activate(rt);
    defer roots.deactivate();
    const source = try roots.ref(0);
    const global_root = try roots.ref(1);
    try source.set(rt, this_value);
    try global_root.set(rt, global.value());
    var coerced: [2]core.JSValue = .{ core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    const count = @min(args.len, coerced.len);
    // Snapshot future arguments before receiver or index conversion can
    // call JS. Converted indices are immediate numbers/undefined.
    const inputs = [_]core.runtime.MutableRootedValueRef{ try roots.ref(2), try roots.ref(3) };
    for (args[0..count], 0..) |arg, index| try inputs[index].set(rt, arg);
    try source.set(rt, try toStringForAnnexB(ctx, output, try expectObject(try global_root.get(rt)), try source.get(rt), caller_function, caller_frame));
    for (0..count) |index| {
        const arg = try inputs[index].get(rt);
        coerced[index] = if (arg.is(.undefined_value))
            core.JSValue.undefinedValue()
        else if (arg.isNumber())
            arg
        else
            try builtin_glue.toNumberLikeArgument(ctx, output, try expectObject(try global_root.get(rt)), arg);
    }
    const string_value = try source.get(rt);
    const current_global = try expectObject(try global_root.get(rt));
    if (method_id == 1) {
        if (try fastLatin1Substring(ctx.runtime, string_value, coerced[0..count])) |value| return value;
    }
    if (method_id == 0) {
        const index = if (count >= 1) coerced[0] else core.JSValue.int32(0);
        return callStringCharAtBody(ctx, string_value, index);
    }
    if (method_id == 25) {
        return stringSubstr(ctx, output, current_global, string_value, coerced[0..count]);
    }
    return callStringBody(ctx, string_value, method_id, coerced[0..count]) catch |err| switch (err) {
        error.RangeError => return throwRangeErrorMessage(ctx, try expectObject(try global_root.get(rt)), "invalid repeat count"),
        error.InvalidLength => return throwRangeErrorMessage(ctx, try expectObject(try global_root.get(rt)), "invalid string length"),
        else => err,
    };
}

fn fastLatin1Substring(rt: *core.JSRuntime, string_value: core.JSValue, args: []const core.JSValue) !?core.JSValue {
    if (!string_value.isString() or args.len > 2) return null;
    const string = core.string.asFlat(string_value) orelse return null;
    if (string.isWide()) return null;
    const len: i64 = @intCast(string.len());
    const start_raw = if (args.len >= 1) int32OrUndefinedStringIndex(args[0]) orelse return null else 0;
    const end_raw = if (args.len >= 2 and !args[1].is(.undefined_value)) int32OrUndefinedStringIndex(args[1]) orelse return null else len;
    const start: usize = @intCast(@max(@as(i64, 0), @min(start_raw, len)));
    const end: usize = @intCast(@max(@as(i64, 0), @min(end_raw, len)));
    const lo = @min(start, end);
    const hi = @max(start, end);
    if (lo == hi) {
        const empty = try rt.emptyString();
        return empty.value();
    }
    return try stringSliceValue(rt, string_value, lo, hi - lo);
}

fn int32OrUndefinedStringIndex(value: core.JSValue) ?i64 {
    if (value.is(.undefined_value)) return null;
    return if (value.as(.int)) |int_value| @as(i64, int_value) else null;
}

/// `output` / `global` are unused: the receiver and both arguments are already
/// coerced by `stringNumericArgsMethod`, so nothing here is observable. They
/// stay in the signature to keep this body ABI-identical to its sibling AnnexB
/// bodies (`stringPad`, `stringHtmlMethod`, `stringNormalize`, …).
pub fn stringSubstr(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    string_value: core.JSValue,
    args: []const core.JSValue,
) !core.JSValue {
    var units = std.ArrayList(u16).empty;
    defer units.deinit(ctx.runtime.nativeAllocator());
    try appendStringValueUnits(ctx.runtime, &units, string_value);

    const size = units.items.len;
    const start_number = if (args.len >= 1 and !args[0].is(.undefined_value))
        value_ops.numberValue(args[0]) orelse std.math.nan(f64)
    else
        0;
    var start: usize = 0;
    if (std.math.isNan(start_number) or start_number == 0) {
        start = 0;
    } else if (start_number < 0) {
        const integer_start = @trunc(start_number);
        if (integer_start == 0) {
            start = 0;
        } else if (std.math.isNegativeInf(integer_start)) {
            start = 0;
        } else {
            const abs_start: usize = @intFromFloat(@min(@abs(integer_start), @as(f64, @floatFromInt(size))));
            start = size - abs_start;
        }
    } else if (std.math.isPositiveInf(start_number)) {
        start = size;
    } else {
        start = @min(@as(usize, @intFromFloat(@trunc(start_number))), size);
    }

    const max_len = size - start;
    const requested_len = if (args.len >= 2 and !args[1].is(.undefined_value)) blk: {
        const length_number = value_ops.numberValue(args[1]) orelse std.math.nan(f64);
        if (std.math.isNan(length_number) or length_number <= 0) break :blk @as(usize, 0);
        if (std.math.isPositiveInf(length_number)) break :blk max_len;
        break :blk @min(@as(usize, @intFromFloat(@trunc(length_number))), max_len);
    } else max_len;

    _ = output;
    _ = global;
    return (try core.string.String.createUtf16(ctx.runtime, units.items[start..][0..requested_len])).value();
}

pub fn stringHtmlMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (this_value.is(.null_value) or this_value.is(.undefined_value)) return error.TypeError;
    const string_value = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);

    var string_units = std.ArrayList(u16).empty;
    defer string_units.deinit(ctx.runtime.nativeAllocator());
    try appendStringValueUnits(ctx.runtime, &string_units, string_value);

    switch (method_id) {
        11 => return stringCreateHtml(ctx, string_units.items, "a", "name", if (args.len >= 1) args[0] else core.JSValue.undefinedValue(), true, output, global, caller_function, caller_frame),
        12 => return stringCreateHtml(ctx, string_units.items, "big", "", core.JSValue.undefinedValue(), false, output, global, caller_function, caller_frame),
        13 => return stringCreateHtml(ctx, string_units.items, "blink", "", core.JSValue.undefinedValue(), false, output, global, caller_function, caller_frame),
        14 => return stringCreateHtml(ctx, string_units.items, "b", "", core.JSValue.undefinedValue(), false, output, global, caller_function, caller_frame),
        15 => return stringCreateHtml(ctx, string_units.items, "tt", "", core.JSValue.undefinedValue(), false, output, global, caller_function, caller_frame),
        16 => return stringCreateHtml(ctx, string_units.items, "font", "color", if (args.len >= 1) args[0] else core.JSValue.undefinedValue(), true, output, global, caller_function, caller_frame),
        17 => return stringCreateHtml(ctx, string_units.items, "font", "size", if (args.len >= 1) args[0] else core.JSValue.undefinedValue(), true, output, global, caller_function, caller_frame),
        18 => return stringCreateHtml(ctx, string_units.items, "i", "", core.JSValue.undefinedValue(), false, output, global, caller_function, caller_frame),
        19 => return stringCreateHtml(ctx, string_units.items, "a", "href", if (args.len >= 1) args[0] else core.JSValue.undefinedValue(), true, output, global, caller_function, caller_frame),
        20 => return stringCreateHtml(ctx, string_units.items, "small", "", core.JSValue.undefinedValue(), false, output, global, caller_function, caller_frame),
        23 => return stringCreateHtml(ctx, string_units.items, "strike", "", core.JSValue.undefinedValue(), false, output, global, caller_function, caller_frame),
        24 => return stringCreateHtml(ctx, string_units.items, "sub", "", core.JSValue.undefinedValue(), false, output, global, caller_function, caller_frame),
        26 => return stringCreateHtml(ctx, string_units.items, "sup", "", core.JSValue.undefinedValue(), false, output, global, caller_function, caller_frame),
        else => return error.TypeError,
    }
}

fn stringCreateHtml(
    ctx: *core.JSContext,
    string_units: []const u16,
    tag: []const u8,
    attr: []const u8,
    attr_value: core.JSValue,
    has_attr: bool,
    output: ?*std.Io.Writer,
    global: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var out = std.ArrayList(u16).empty;
    defer out.deinit(ctx.runtime.nativeAllocator());
    try appendAsciiUnits(ctx.runtime, &out, "<");
    try appendAsciiUnits(ctx.runtime, &out, tag);
    if (has_attr) {
        const value = try toStringForAnnexB(ctx, output, global, attr_value, caller_function, caller_frame);
        var attr_units = std.ArrayList(u16).empty;
        defer attr_units.deinit(ctx.runtime.nativeAllocator());
        try appendStringValueUnits(ctx.runtime, &attr_units, value);

        try appendAsciiUnits(ctx.runtime, &out, " ");
        try appendAsciiUnits(ctx.runtime, &out, attr);
        try appendAsciiUnits(ctx.runtime, &out, "=\"");
        for (attr_units.items) |unit| {
            if (unit == '"') {
                try appendAsciiUnits(ctx.runtime, &out, "&quot;");
            } else {
                try out.append(ctx.runtime.nativeAllocator(), unit);
            }
        }
        try appendAsciiUnits(ctx.runtime, &out, "\"");
    }
    try appendAsciiUnits(ctx.runtime, &out, ">");
    try out.appendSlice(ctx.runtime.nativeAllocator(), string_units);
    try appendAsciiUnits(ctx.runtime, &out, "</");
    try appendAsciiUnits(ctx.runtime, &out, tag);
    try appendAsciiUnits(ctx.runtime, &out, ">");
    return (try core.string.String.createUtf16(ctx.runtime, out.items)).value();
}

// ----- merged from string_builtin_ops.zig -----
// String constructor/prototype records and their direct builtin bodies.
//
// Receiver and argument values are borrowed for ordinary calls; returned
// JSValues are owned. Helpers explicitly named `Owned` consume their inputs,
// and temporary flattened strings or buffers are released locally. Realm- and
// VM-aware string/RegExp integration stays in `string_ops.zig`; the record/id
// seam here lets direct leaf handlers avoid that wider dependency. QuickJS
// coordinates include `js_string_concat` at quickjs.c, split at
// quickjs.c, and repeat at quickjs.c.
const number_format = @import("../libs/number_format.zig");
const native_legacy = @import("builtin_dispatch.zig");
const exceptions = @import("exception_ops.zig");
const HostError = exceptions.HostError;
const NativeCall = builtin_dispatch.NativeCall;
const AppendStringError = core.value_string.AppendStringError;
const TrimMode = enum { start, end, both };
pub const StaticMethod = core.host_function.builtin_method_ids.string.StaticMethod;
pub const ConstructorMethod = core.host_function.builtin_method_ids.string.ConstructorMethod;
pub const PrototypeMethod = core.host_function.builtin_method_ids.string.PrototypeMethod;
pub const legacy_split_method_id = string_id_lookup.legacy_split_method_id;
pub const legacy_normalize_method_id = string_id_lookup.legacy_normalize_method_id;
pub const legacy_search_method_id = string_id_lookup.legacy_search_method_id;
pub const legacy_match_method_id = string_id_lookup.legacy_match_method_id;
pub const legacy_replace_all_method_id = string_id_lookup.legacy_replace_all_method_id;
pub const legacy_match_all_method_id = string_id_lookup.legacy_match_all_method_id;
pub const staticMethodId = string_id_lookup.staticMethodId;
pub const prototypeMethodId = string_id_lookup.prototypeMethodId;
pub const decodePrototypeMethodId = string_id_lookup.decodePrototypeMethodId;
pub const encodePrototypeMethodId = string_id_lookup.encodePrototypeMethodId;
pub const internal_entries = stringEntries: {
    const Entry = core.host_function.InternalEntry;
    break :stringEntries [_]Entry{
        // Constructor + statics. The `String` record serves both `String(...)`
        // (call path) and `new String(...)` (construct path), so it is marked
        // construct-capable; `stringCall` branches on `is_constructor`.
        stringConstructorEntry("String", 1, @intFromEnum(ConstructorMethod.call)),
        stringExecDirectEntry("fromCharCode", 1, @intFromEnum(StaticMethod.from_char_code), &stringFromCharCodeCall, &stringFromCharCodeDirect),
        stringEntry("fromCodePoint", 1, @intFromEnum(StaticMethod.from_code_point)),
        stringEntry("raw", 1, @intFromEnum(StaticMethod.raw)),
        // Prototype methods that carry a `(.string, id)` native record id
        // (the subset `prototypeMethodId` maps and `decodePrototypeMethodId`
        // decodes). The remaining String.prototype methods (toString, valueOf,
        // the AnnexB html helpers, …) are installed as plain name-dispatched
        // native functions and never reach record dispatch.
        stringPrimLeafEntry("charAt", 1, @intFromEnum(PrototypeMethod.char_at), &stringCall, null, .string_i32_to_string, &stringCharAtLeaf),
        stringEntry("substring", 2, @intFromEnum(PrototypeMethod.substring)),
        stringDirectEntry("toUpperCase", 0, @intFromEnum(PrototypeMethod.to_upper_case), &stringCaseCall),
        stringDirectEntry("toLowerCase", 0, @intFromEnum(PrototypeMethod.to_lower_case), &stringCaseCall),
        stringEntry("indexOf", 1, @intFromEnum(PrototypeMethod.index_of)),
        stringEntry("includes", 1, @intFromEnum(PrototypeMethod.includes)),
        stringEntry("startsWith", 1, @intFromEnum(PrototypeMethod.starts_with)),
        stringEntry("endsWith", 1, @intFromEnum(PrototypeMethod.ends_with)),
        stringEntry("trim", 0, @intFromEnum(PrototypeMethod.trim)),
        stringDirectEntry("concat", 1, @intFromEnum(PrototypeMethod.concat), &stringConcatCall),
        stringEntry("trimStart", 0, @intFromEnum(PrototypeMethod.trim_start)),
        stringEntry("trimEnd", 0, @intFromEnum(PrototypeMethod.trim_end)),
        stringEntry("split", 2, @intFromEnum(PrototypeMethod.split)),
        stringEntry("lastIndexOf", 1, @intFromEnum(PrototypeMethod.last_index_of)),
        stringPrimLeafEntry("charCodeAt", 1, @intFromEnum(PrototypeMethod.char_code_at), &stringCharCodeAtCall, &stringCharCodeAtDirect, .string_i32_to_i32, &stringCharCodeAtLeaf),
        stringPrimLeafEntry("at", 1, @intFromEnum(PrototypeMethod.at), &stringAtCall, null, .string_i32_to_string, &stringAtLeaf),
        stringPrimLeafEntry("codePointAt", 1, @intFromEnum(PrototypeMethod.code_point_at), &stringCodePointAtCall, null, .string_i32_to_i32, &stringCodePointAtLeaf),
        stringEntry("slice", 2, @intFromEnum(PrototypeMethod.slice)),
        stringEntry("repeat", 1, @intFromEnum(PrototypeMethod.repeat)),
        stringEntry("padStart", 1, @intFromEnum(PrototypeMethod.pad_start)),
        stringEntry("padEnd", 1, @intFromEnum(PrototypeMethod.pad_end)),
        stringEntry("localeCompare", 1, @intFromEnum(PrototypeMethod.locale_compare)),
        stringEntry("normalize", 0, @intFromEnum(PrototypeMethod.normalize)),
        stringEntry("isWellFormed", 0, @intFromEnum(PrototypeMethod.is_well_formed)),
        stringEntry("toWellFormed", 0, @intFromEnum(PrototypeMethod.to_well_formed)),
        stringEntry("search", 1, @intFromEnum(PrototypeMethod.search)),
        stringEntry("match", 1, @intFromEnum(PrototypeMethod.match)),
        stringEntry("replace", 2, @intFromEnum(PrototypeMethod.replace)),
        stringEntry("replaceAll", 2, @intFromEnum(PrototypeMethod.replace_all)),
        stringEntry("matchAll", 1, @intFromEnum(PrototypeMethod.match_all)),
        // The String Iterator's `next` method.
        stringEntry("next", 0, @intFromEnum(PrototypeMethod.iterator_next)),
    };
};
fn stringEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return stringEntryWithHandler(name, length, id, &stringCall);
}

fn stringDirectEntry(
    comptime name: []const u8,
    comptime length: u8,
    comptime id: u32,
    comptime handler: anytype,
) core.host_function.InternalEntry {
    return stringEntryWithHandler(name, length, id, handler);
}

/// K3: dedicated handler plus `exec_direct` so the hot NMFD path skips TLS /
/// typed-cproto / `stringCall` magic mux (charCodeAt's dedicated-handler
/// shape plus Function.apply's exec_direct ABI).
fn stringExecDirectEntry(
    comptime name: []const u8,
    comptime length: u8,
    comptime id: u32,
    comptime handler: anytype,
    comptime direct: core.native_entry.ManagedFn,
) core.host_function.InternalEntry {
    var entry = stringEntryWithHandler(name, length, id, handler);
    entry.managed = direct;
    return entry;
}

/// Lane K (design §4.3 `prim_self`): a `method_leaf` entry whose hot arm is
/// the typed `leaf` target over a flat string receiver and an int32 index;
/// the declared handler (plus optional exec_direct body) is the tag-miss
/// fallback, so coercing receivers / indices keep the legacy semantics.
fn stringPrimLeafEntry(
    comptime name: []const u8,
    comptime length: u8,
    comptime id: u32,
    comptime handler: anytype,
    comptime direct: ?core.native_entry.ManagedFn,
    comptime sig: core.LeafSig,
    comptime leaf: native_legacy.LeafStringI32ToI32,
) core.host_function.InternalEntry {
    var entry = stringEntryWithHandler(name, length, id, handler);
    entry.managed = direct;
    entry.prim_leaf = .{ .sig = sig, .target = core.NativeEntry.code(leaf) };
    return entry;
}

fn stringEntryWithHandler(
    comptime name: []const u8,
    comptime length: u8,
    comptime id: u32,
    comptime handler: anytype,
) core.host_function.InternalEntry {
    return .{
        .name = name,
        .length = length,
        .id = id,
        .magic = @intCast(id),
        .cproto = .generic_magic,
        .native_function = builtin_dispatch.genericMagicFunction(handler),
    };
}

test "String.charCodeAt uses exec_direct and a dedicated handler" {
    var found = false;
    for (internal_entries) |entry| {
        if (entry.id != @intFromEnum(PrototypeMethod.char_code_at)) continue;
        found = true;
        try std.testing.expect(core.host_function.genericMagicHandler(entry).? == &stringCharCodeAtCall);
        try std.testing.expect(entry.managed != null);
        try std.testing.expect(entry.managed.? == &stringCharCodeAtDirect);
        try std.testing.expect(!entry.forwards_call);
    }
    try std.testing.expect(found);
}

fn testStringDeclById(comptime id: u32) core.host_function.InternalEntry {
    for (internal_entries) |decl| {
        if (decl.id == id) return decl;
    }
    @compileError("no String entry with that id");
}

test "String index reads are prim_self method_leaf entries with their legacy bodies as fallback" {
    const Expect = struct { id: u32, sig: core.LeafSig, leaf: native_legacy.LeafStringI32ToI32 };
    const expected = [_]Expect{
        .{ .id = @intFromEnum(PrototypeMethod.char_code_at), .sig = native_legacy.sig_string_i32_to_i32, .leaf = &stringCharCodeAtLeaf },
        .{ .id = @intFromEnum(PrototypeMethod.char_at), .sig = native_legacy.sig_string_i32_to_string, .leaf = &stringCharAtLeaf },
        .{ .id = @intFromEnum(PrototypeMethod.at), .sig = native_legacy.sig_string_i32_to_string, .leaf = &stringAtLeaf },
        .{ .id = @intFromEnum(PrototypeMethod.code_point_at), .sig = native_legacy.sig_string_i32_to_i32, .leaf = &stringCodePointAtLeaf },
    };
    inline for (expected) |want| {
        const decl = comptime testStringDeclById(want.id);
        const entry = comptime native_legacy.entryFromInternal(decl);
        try std.testing.expectEqual(core.native_entry.Kind.method_leaf, entry.kind);
        try std.testing.expectEqual(want.sig, entry.sig);
        try std.testing.expect(entry.target == core.NativeEntry.code(want.leaf));
        try std.testing.expect(entry.fallback != null);
        try std.testing.expect(!entry.effect.may_throw);
        // The exec_direct body reads the caller through vmCallerView; the
        // generic_magic thunks still need the environment.
        try std.testing.expectEqual(decl.managed == null, entry.flags.needs_env);
    }
    // The leaf targets own the index rule: negative = fallback.
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const str = try core.string.String.createLatin1(rt, "abc");
    try std.testing.expectEqual(@as(i32, 'b'), stringCharCodeAtLeaf(str, 1));
    try std.testing.expectEqual(@as(i32, -1), stringCharCodeAtLeaf(str, 3));
    try std.testing.expectEqual(@as(i32, -1), stringCharCodeAtLeaf(str, -1));
    try std.testing.expectEqual(@as(i32, 'c'), stringAtLeaf(str, -1));
    try std.testing.expectEqual(@as(i32, -1), stringAtLeaf(str, -4));
    const pair = try core.string.String.createUtf16(rt, &.{ 'a', 0xD83D, 0xDE00 });
    try std.testing.expectEqual(@as(i32, 0x1F600), stringCodePointAtLeaf(pair, 1));
    try std.testing.expectEqual(@as(i32, 0xDE00), stringCodePointAtLeaf(pair, 2));
}

test "String.fromCharCode uses exec_direct and a dedicated handler" {
    var found = false;
    for (internal_entries) |entry| {
        if (entry.id != @intFromEnum(StaticMethod.from_char_code)) continue;
        found = true;
        try std.testing.expect(core.host_function.genericMagicHandler(entry).? == &stringFromCharCodeCall);
        try std.testing.expect(entry.managed != null);
        try std.testing.expect(entry.managed.? == &stringFromCharCodeDirect);
        try std.testing.expect(!entry.forwards_call);
    }
    try std.testing.expect(found);
}

test "String case conversion methods have a dedicated native record handler" {
    var upper_call: ?core.host_function.NativeGenericMagicFn = null;
    var lower_call: ?core.host_function.NativeGenericMagicFn = null;
    for (internal_entries) |entry| {
        if (entry.id == @intFromEnum(PrototypeMethod.to_upper_case)) upper_call = core.host_function.genericMagicHandler(entry);
        if (entry.id == @intFromEnum(PrototypeMethod.to_lower_case)) lower_call = core.host_function.genericMagicHandler(entry);
    }
    try std.testing.expect(upper_call != null);
    try std.testing.expect(lower_call != null);
    try std.testing.expect(upper_call.? != &stringCall);
    try std.testing.expect(lower_call.? != &stringCall);
    try std.testing.expect(upper_call.? == lower_call.?);
}

/// The String constructor record: construct-capable so `new String(...)`
/// routes through the construct dispatch path into `stringCall`'s construct
/// branch (it still serves `String(...)` as a function on the call path).
fn stringConstructorEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{
        .name = name,
        .length = length,
        .id = id,
        .magic = @intCast(id),
        .cproto = .constructor_or_func_magic,
        .native_function = builtin_dispatch.constructorOrFunctionMagic(&stringCall),
    };
}

/// Shared record handler for the `.string` domain. Mirrors the retired
/// `call.zig` `callStringNativeFunctionRecord`: the String Iterator `next` and
/// the `from*`/constructor statics run their own helpers, while the prototype
/// methods (and `String.raw`) delegate to the exec VM ops, which stay in exec
/// because the string opcode handlers and `regexp_fastpath.zig` also call them.
///
/// QJS gives `at`, `charCodeAt`, `codePointAt`, and the shared
/// `js_string_toLowerCase` case-conversion body their own function-list entries.
/// Their zjs entries likewise land in the small functions below. The index
/// methods keep their already-string/immediate-index path local; values requiring
/// observable ToString/ToNumber coercion tail into this shared handler. Keeping
/// that rare path out of the direct index functions avoids cloning the whole
/// coercion tower into each hot native entry.
inline fn stringPrimitiveIndexRead(host_call: NativeCall, comptime mid: u32) HostError!?core.JSValue {
    if (!host_call.this_value.isString()) return null;
    const args = host_call.args;
    const idx: i64 = if (args.len == 0)
        0
    else if (stringPrimitiveInt32Sat(args[0])) |index|
        index
    else
        return null;
    const rt = host_call.ctx.runtime;
    // Decide whether this path applies before allocating. The fallback owns
    // observable index conversion and its input roots.
    const string_value = stringIndexFlatValue(rt, host_call.this_value) catch |err| return @as(HostError, @errorCast(err));
    const len: i64 = @intCast(core.string.stringValueLenUnchecked(string_value));
    switch (mid) {
        29 => {
            if (idx < 0 or idx >= len) return core.JSValue.float64(std.math.nan(f64));
            return core.JSValue.int32(core.string.stringValueCodeUnitAtUnchecked(string_value, @intCast(idx)));
        },
        30 => {
            const index = if (idx < 0) len + idx else idx;
            if (index < 0 or index >= len) return core.JSValue.undefinedValue();
            return codeUnitStringValue(rt, core.string.stringValueCodeUnitAtUnchecked(string_value, @intCast(index))) catch |err| return @as(HostError, @errorCast(err));
        },
        else => {
            if (idx < 0 or idx >= len) return core.JSValue.undefinedValue();
            const unit = core.string.stringValueCodeUnitAtUnchecked(string_value, @intCast(idx));
            if (isHighSurrogateUnit(unit) and idx + 1 < len) {
                const next = core.string.stringValueCodeUnitAtUnchecked(string_value, @intCast(idx + 1));
                if (isLowSurrogateUnit(next)) return core.JSValue.int32(@intCast(unicode_lib.codePointFromSurrogatePair(unit, next)));
            }
            return core.JSValue.int32(unit);
        },
    }
}

/// Keep repeated character reads O(1) after the first rope materialization.
/// The source is protected here; callers consume or root the returned value
/// before their next allocation or user callback.
fn stringIndexFlatValue(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue {
    const node = value.ropeBody() orelse return value;
    const source = [_]core.JSValue{value};
    const slices = [_]core.runtime.ValueRootSlice{.{ .borrowed = &source }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    return (try node.flatten()).value();
}

/// QJS `JS_ToInt32SatFree`'s immediate-value leg. String index methods use a
/// saturated i32 because strings cannot reach `INT32_MAX` code units, so every
/// larger positive/negative index has the same out-of-range result. Returning
/// null preserves the observable ToNumber fallback for objects, strings,
/// Symbols and BigInts.
inline fn stringPrimitiveInt32Sat(value: core.JSValue) ?i32 {
    if (value.as(.int)) |integer| return integer;
    if (value.as(.boolean)) |boolean| return @intFromBool(boolean);
    if (value.is(.null_value) or value.is(.undefined_value)) return 0;
    const number = value.asNumber() orelse return null;
    if (std.math.isNan(number)) return 0;
    if (number < @as(f64, @floatFromInt(std.math.minInt(i32)))) return std.math.minInt(i32);
    if (number > @as(f64, @floatFromInt(std.math.maxInt(i32)))) return std.math.maxInt(i32);
    return @intFromFloat(number);
}

/// Direct-part cap for the primitive `concat` fast body below. The template
/// literal / `s.concat(a, b)` hot shapes carry one or two arguments; anything
/// larger falls to the shared dispatcher without observable difference.
const concat_direct_max_args = 7;
inline fn stringPrimitiveConcat(host_call: NativeCall) HostError!?core.JSValue {
    const receiver = host_call.this_value;
    if (!receiver.isString() or receiver.ropeBody() != null) return null;
    const receiver_body = receiver.asStringBodyRaw() orelse return null;
    const receiver_bytes = receiver_body.borrowLatin1() orelse return null;
    const args = host_call.args;
    if (args.len > concat_direct_max_args) return null;
    var digits: [12]u8 = undefined;
    var parts: [concat_direct_max_args + 1]core.JSValue = undefined;
    parts[0] = receiver;
    var total: usize = receiver_bytes.len;
    for (args, 0..) |arg, index| {
        if (arg.as(.int)) |int_value| {
            total += number_format.formatInt32(&digits, int_value).len;
        } else if (arg.isString() and arg.ropeBody() == null) {
            const body = arg.asStringBodyRaw() orelse return null;
            const bytes = body.borrowLatin1() orelse return null;
            total += bytes.len;
        } else {
            return null;
        }
        parts[index + 1] = arg;
    }
    // Overlong results fall to the shared dispatcher so the StringTooLong
    // error shape stays on the single audited path.
    if (total > core.string.max_length) return null;
    const rt = host_call.ctx.runtime;
    if (total == 0) {
        const empty = rt.emptyString() catch |err| return @as(HostError, @errorCast(err));
        return empty.value();
    }
    if (args.len == 0) return receiver;
    const created = core.string.String.createConcatParts(rt, parts[0 .. args.len + 1]) catch |err| switch (err) {
        error.ExpectedString => @panic("primitive concat passed an invalid part"),
        else => |other| return @as(HostError, @errorCast(other)),
    };
    return created.value();
}

fn stringConcatCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    if (try stringPrimitiveConcat(host_call)) |value| return value;
    return stringCall(native_ctx, native_this, native_args, native_magic);
}

fn stringFromCharCodeDirect(
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
    _ = this_value;
    _ = caller_function;
    _ = caller_frame;
    const result = stringFromCharCode(ctx, output, global, args) catch |err| {
        return builtin_dispatch.hostErrorToValue(ctx, global, @as(HostError, @errorCast(err)));
    };
    return (result);
}

fn stringFromCharCodeCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const global = if (host_call.func_obj != null) blk: {
        const realm = try builtin_dispatch.callableRealm(host_call);
        std.debug.assert(realm.realm == host_call.ctx);
        break :blk realm.global;
    } else host_call.global orelse return error.TypeError;
    return stringFromCharCode(host_call.ctx, host_call.output, global, host_call.args) catch |err| return @as(HostError, @errorCast(err));
}

// --- Lane K prim_self leaf targets (`native_legacy.LeafStringI32ToI32`) ---
//
// The arm (`builtin_dispatch.invokeMethodLeafFast`) has already established
// a flat string receiver and an int32 index; these bodies own only the
// per-method index rule and the code-unit read (`String.codeUnitAt`, the
// same single access `stringValueCodeUnitAtUnchecked` ends in). A negative
// return sends the arm to the fallback, which recomputes the observable
// out-of-range result (NaN / undefined / "").

fn stringCharCodeAtLeaf(str: *const core.string.String, index: i32) callconv(.c) i32 {
    if (index < 0 or @as(usize, @intCast(index)) >= str.len()) return -1;
    return str.codeUnitAt(@intCast(index));
}

fn stringCharAtLeaf(str: *const core.string.String, index: i32) callconv(.c) i32 {
    if (index < 0 or @as(usize, @intCast(index)) >= str.len()) return -1;
    return str.codeUnitAt(@intCast(index));
}

fn stringAtLeaf(str: *const core.string.String, index: i32) callconv(.c) i32 {
    const len: i64 = @intCast(str.len());
    const relative: i64 = if (index < 0) len + index else index;
    if (relative < 0 or relative >= len) return -1;
    return str.codeUnitAt(@intCast(relative));
}

fn stringCodePointAtLeaf(str: *const core.string.String, index: i32) callconv(.c) i32 {
    const len = str.len();
    if (index < 0 or @as(usize, @intCast(index)) >= len) return -1;
    const position: usize = @intCast(index);
    const unit = str.codeUnitAt(position);
    if (isHighSurrogateUnit(unit) and position + 1 < len) {
        const next = str.codeUnitAt(position + 1);
        if (isLowSurrogateUnit(next)) return @intCast(unicode_lib.codePointFromSurrogatePair(unit, next));
    }
    return unit;
}

fn stringCharCodeAtDirect(
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
    return builtin_dispatch.hostResultToValue(ctx, stringCharCodeAtDirectHost(
        ctx,
        output,
        global,
        this_value,
        args,
        caller_function,
        caller_frame,
    ));
}

inline fn stringCharCodeAtDirectHost(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) HostError!core.JSValue {
    const host_call = NativeCall{
        .ctx = ctx,
        .callable_realm = null,
        .output = output,
        .global = global,
        .globals = &.{},
        .func_obj = null,
        .this_value = this_value,
        .args = args,
        .magic = @intFromEnum(PrototypeMethod.char_code_at),
        .is_constructor = false,
        .new_target = null,
        .caller_function = caller_function,
        .caller_frame = caller_frame,
    };
    if (try stringPrimitiveIndexRead(host_call, 29)) |value| return value;
    // Do not bounce through `stringPrototypeMethod` / `callStringBody`:
    // that re-enters this record's exec_direct with a null func_obj and
    // raises InvalidBuiltinRegistry. Coerce with the explicit ABI instead.
    var values = [_]core.JSValue{ global.value(), this_value, if (args.len == 0) core.JSValue.undefinedValue() else args[0], core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    // The conversion ABI takes raw global/receiver/index snapshots. Pin those
    // for the call; keep the produced string in an actual registered slot.
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = values[0..3] } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    values[3] = toStringCheckObject(
        ctx,
        output,
        global,
        values[1],
        caller_function,
        caller_frame,
    ) catch |err| return @as(HostError, @errorCast(err));
    // Preserve the converted input as well as its cached flat child until
    // index conversion has finished.
    _ = stringIndexFlatValue(ctx.runtime, values[3]) catch |err| return @as(HostError, @errorCast(err));
    const idx: i64 = if (args.len == 0)
        0
    else if (stringPrimitiveInt32Sat(values[2])) |index|
        index
    else blk: {
        const numeric = builtin_glue.toNumberLikeArgument(ctx, output, global, values[2]) catch |err| return @as(HostError, @errorCast(err));
        break :blk stringPrimitiveInt32Sat(numeric) orelse return error.TypeError;
    };
    const string_value = values[3];
    const len: i64 = @intCast(core.string.stringValueLenUnchecked(string_value));
    if (idx < 0 or idx >= len) return core.JSValue.float64(std.math.nan(f64));
    return core.JSValue.int32(core.string.stringValueCodeUnitAtUnchecked(string_value, @intCast(idx)));
}

fn stringCharCodeAtCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    if (try stringPrimitiveIndexRead(host_call, 29)) |value| return value;
    return stringCall(native_ctx, native_this, native_args, native_magic);
}

fn stringAtCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    if (try stringPrimitiveIndexRead(host_call, 30)) |value| return value;
    return stringCall(native_ctx, native_this, native_args, native_magic);
}

fn stringCodePointAtCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    if (try stringPrimitiveIndexRead(host_call, 31)) |value| return value;
    return stringCall(native_ctx, native_this, native_args, native_magic);
}

fn stringCaseCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const to_lower = host_call.magic == @intFromEnum(PrototypeMethod.to_lower_case);
    if (host_call.func_obj == null and host_call.global == null) {
        if (host_call.is_constructor) return error.TypeError;
        // Explicit algorithmic reuse after the caller has already reduced the
        // receiver to the pure Unicode case body.
        return unicodeCaseReceiver(host_call.ctx.runtime, host_call.this_value, to_lower) catch |err| return @as(HostError, @errorCast(err));
    }

    const global = if (host_call.func_obj != null) blk: {
        const realm = try builtin_dispatch.callableRealm(host_call);
        std.debug.assert(realm.realm == host_call.ctx);
        break :blk realm.global;
    } else host_call.global orelse return error.TypeError;
    const caller_function = builtin_dispatch.callerBytecode(host_call);
    const caller_frame = builtin_dispatch.callerFrame(host_call);
    const string_value = try toStringCheckObject(
        host_call.ctx,
        host_call.output,
        global,
        host_call.this_value,
        caller_function,
        caller_frame,
    );

    return unicodeCaseOwnedString(host_call.ctx.runtime, string_value, to_lower) catch |err| return @as(HostError, @errorCast(err));
}

fn stringCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const ctx = host_call.ctx;
    const id: u32 = host_call.magic;
    const args = host_call.args;
    const this_value = host_call.this_value;

    if (id == @intFromEnum(PrototypeMethod.iterator_next)) {
        const receiver = thisObject(this_value) orelse return error.TypeError;
        if (receiver.class_id != core.class.ids.string_iterator) return error.TypeError;
        return stringIteratorNext(ctx.runtime, ctx.globalObject() catch null, this_value) catch |err| switch (err) {
            error.TypeError => error.TypeError,
            else => err,
        };
    }

    // `new String(...)` arrives through the construct record path
    // (`exec/construct.zig`) with `is_constructor` set and the resolved
    // wrapper prototype in `new_target`; `String(...)` called as a function
    // falls through to `stringFunctionCall` (the `ConstructorMethod.call`
    // case below).
    if (host_call.is_constructor and id == @intFromEnum(ConstructorMethod.call)) {
        return constructWithPrototype(ctx.runtime, args, host_call.new_target);
    }

    const output = host_call.output;
    const caller_function = builtin_dispatch.callerBytecode(host_call);
    const caller_frame = builtin_dispatch.callerFrame(host_call);

    // Engine-internal dispatch arm: the exec string dispatcher and fast paths
    // (`exec/zig`, `exec/call_runtime.zig`) have already resolved the
    // string receiver/args and route the reused *pure body* through the table
    // here. It is gated on `func_obj == null and global == null`, the
    // contract those call sites use (the body needs no realm global). The
    // Other direct callers can pass `func_obj == null` with a realm `global`
    // and raw args, so they must fall through to the coercing dispatcher below.
    // This deliberately bypasses the prototype dispatcher
    // (`stringPrototypeMethod`) — routing back through it would
    // re-enter this record (the dispatcher's own body call is one of the
    // converted sites) and recurse.
    if (host_call.func_obj == null and host_call.global == null and !host_call.is_constructor) {
        const method_id = decodePrototypeMethodId(id) orelse return error.TypeError;
        if (method_id == 0) {
            // `String.prototype.charAt` body (its own helper; `methodCall` does
            // not handle id 0). The exec caller forwards the index as args[0].
            const index = if (args.len >= 1) args[0] else core.JSValue.int32(0);
            return charAtValue(ctx.runtime, this_value, index) catch |err| return @as(HostError, @errorCast(err));
        }
        return methodCall(ctx.runtime, this_value, method_id, args) catch |err| return @as(HostError, @errorCast(err));
    }

    const active_global = if (host_call.func_obj != null) blk: {
        const realm = try builtin_dispatch.callableRealm(host_call);
        std.debug.assert(realm.realm == ctx);
        break :blk realm.global;
    } else host_call.global orelse return error.TypeError;
    return switch (id) {
        @intFromEnum(ConstructorMethod.call) => stringFunctionCall(ctx, output, active_global, args, caller_function, caller_frame),
        @intFromEnum(StaticMethod.from_char_code) => stringFromCharCode(ctx, output, active_global, args),
        @intFromEnum(StaticMethod.from_code_point) => stringFromCodePoint(ctx, output, active_global, args),
        @intFromEnum(StaticMethod.raw) => stringRaw(ctx, output, active_global, args, caller_function, caller_frame),
        else => {
            const method_id = decodePrototypeMethodId(id) orelse return error.TypeError;
            return stringPrototypeMethod(ctx, output, active_global, this_value, method_id, args, caller_function, caller_frame);
        },
    };
}

fn thisObject(value: core.JSValue) ?*core.Object {
    if (!value.is(.object)) return null;
    const header = value.refHeader() orelse return null;
    return core.Object.fromHeader(header);
}

pub fn constructWithPrototype(rt: *core.JSRuntime, args: []const core.JSValue, prototype: ?*core.Object) !core.JSValue {
    var values = [_]core.JSValue{ if (args.len >= 1) args[0] else core.JSValue.undefinedValue(), if (prototype) |object| object.value() else core.JSValue.nullValue(), core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var root_frame = core.runtime.ValueRootFrame{ .slices = &slices };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    if (args.len >= 1 and values[0].is(.symbol)) return error.TypeError;
    values[0] = if (args.len >= 1)
        try stringValueFromSearchArgument(rt, values[0])
    else
        try createStringValue(rt, "");
    const length = core.string.stringValueLenUnchecked(values[0]);
    values[2] = (try core.Object.create(rt, core.class.ids.string, objectFromValue(values[1]))).value();
    const object = objectFromValue(values[2]).?;
    try object.setOptionalValueSlot(rt, object.objectDataSlot(), values[0]);
    var index: u32 = 0;
    while (index < length) : (index += 1) {
        try defineStringIndexUnitProperty(rt, objectFromValue(values[2]).?, index, core.string.stringValueCodeUnitAtUnchecked(values[0], index));
    }
    try objectFromValue(values[2]).?.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(@intCast(length)), .none));
    return values[2];
}

// The String Iterator factory (`iterator`) + its private prototype/toStringTag
// helpers relocated to engine core (`core/object.zig` `stringIterator`) in Phase
// 6b-3 STEP 6: they are pure object/native-function constructors over core
// string/object primitives with no exec/VM deps, and the exec iteration
// machinery consumes them directly. Re-exported here so this module's own
// references (and any future builtin caller) keep the original name. The
// produced iterator's `next` still carries the `(.string, iterator_next)`
// native id, dispatching back into `stringIteratorNext` below through the record
// table.
pub const stringIterator = core.object.stringIterator;
pub fn stringIteratorNext(rt: *core.JSRuntime, global: ?*core.Object, receiver: core.JSValue) !core.JSValue {
    var values = [_]core.JSValue{ receiver, if (global) |object| object.value() else core.JSValue.nullValue(), core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    const iterator_object = try expectObject(values[0]);
    if (iterator_object.class_id != core.class.ids.string_iterator) return error.TypeError;
    const target = (iterator_object.iteratorTargetSlot().*) orelse return iteratorResult(rt, objectFromValue(values[1]), core.JSValue.undefinedValue(), true);
    if (!target.isString()) return error.TypeError;
    const target_len = core.string.stringValueLenUnchecked(target);
    if ((iterator_object.iteratorIndexSlot().*) >= target_len) {
        const done_result = try iteratorResult(rt, objectFromValue(values[1]), core.JSValue.undefinedValue(), true);
        const current = objectFromValue(values[0]).?;
        current.clearOptionalValueSlot(rt, current.iteratorTargetSlot());
        return done_result;
    }

    const index: usize = @intCast((iterator_object.iteratorIndexSlot().*));
    const first = core.string.stringValueCodeUnitAtUnchecked(target, index);

    // Single code unit (`c <= 0xffff`, non-surrogate-pair): qjs routes these
    // through js_new_string_char, which takes the latin1
    // path for `c < 0x100`. Mirror that — a latin1 unit comes from the
    // runtime's single-code-unit table (zero-alloc); only `>= 0x100` and
    // surrogate pairs reach the wide createUtf16.
    if (first < 0x100) {
        iterator_object.iteratorIndexSlot().* += 1;
        values[2] = (try rt.singleByteString(@intCast(first))).value();
        return iteratorResult(rt, objectFromValue(values[1]), values[2], false);
    }

    if (isHighSurrogateUnit(first) and index + 1 < target_len) {
        const second = core.string.stringValueCodeUnitAtUnchecked(target, index + 1);
        if (isLowSurrogateUnit(second)) {
            iterator_object.iteratorIndexSlot().* += 2;
            const units: [2]u16 = .{ first, second };
            values[2] = (try core.string.String.createUtf16(rt, &units)).value();
            return iteratorResult(rt, objectFromValue(values[1]), values[2], false);
        }
    }

    iterator_object.iteratorIndexSlot().* += 1;
    const units: [1]u16 = .{first};
    values[2] = (try core.string.String.createUtf16(rt, &units)).value();
    return iteratorResult(rt, objectFromValue(values[1]), values[2], false);
}

/// QuickJS source map: narrow charAt helper used by transitional
/// `string_char_at` bytecode.
pub fn charAtValue(rt: *core.JSRuntime, receiver: core.JSValue, index_value: core.JSValue) !core.JSValue {
    const index = try stringInteger(rt, index_value);
    if (stringValueFromReceiverRaw(receiver)) |string_value| {
        if (index < 0 or index >= @as(i64, @intCast(core.string.stringValueLenUnchecked(string_value)))) return createStringValue(rt, "");
        return codeUnitStringValue(rt, core.string.stringValueCodeUnitAtUnchecked(string_value, @intCast(index)));
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try appendStringReceiverBytes(rt, &bytes, receiver);
    if (index < 0) return createStringValue(rt, "");
    const char_index: usize = @intCast(index);
    const out = if (char_index < bytes.items.len) bytes.items[char_index .. char_index + 1] else "";
    return createStringValue(rt, out);
}

/// QuickJS source map: selected String.prototype methods currently covered by
/// smoke fixtures and targeted String validation.
pub fn methodCall(rt: *core.JSRuntime, receiver: core.JSValue, id: u32, args: []const core.JSValue) !core.JSValue {
    if (id == 29) return charCodeAtReceiver(rt, receiver, args);
    if (id == 31) return codePointAtReceiver(rt, receiver, args);
    if (id == 8) return trimReceiver(rt, receiver, .both);
    if (id == 21) return trimReceiver(rt, receiver, .start);
    if (id == 22) return trimReceiver(rt, receiver, .end);
    if (id == 2) return unicodeCaseReceiver(rt, receiver, false);
    if (id == 3) return unicodeCaseReceiver(rt, receiver, true);
    if (id == 1) return substringReceiver(rt, receiver, args);
    if (id == 4) return indexOfReceiver(rt, receiver, args);
    if (id == 5) return containsReceiver(rt, receiver, args, .contains);
    if (id == 6) return containsReceiver(rt, receiver, args, .starts);
    if (id == 7) return containsReceiver(rt, receiver, args, .ends);
    if (id == 30) return atReceiver(rt, receiver, args);
    if (id == 27) return splitReceiver(rt, receiver, args);
    if (id == 33) return repeatReceiver(rt, receiver, args);
    if (id == 28) return lastIndexOfReceiver(rt, receiver, args);
    if (id == 32) return sliceReceiver(rt, receiver, args);
    if (id == 38) return isWellFormedReceiver(rt, receiver);
    if (id == 39) return toWellFormedReceiver(rt, receiver);

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try appendStringReceiverBytes(rt, &bytes, receiver);

    // Every id handled above returns before this point, so the remaining
    // reachable set is exactly the bodies that still live in this file. The
    // concat / AnnexB-html / substr ids never arrive: their records dispatch
    // to `string_ops` (`stringConcat` / `stringHtmlMethod` / `stringSubstr`),
    // and `encodePrototypeMethodId` has no record for the html and substr ids
    // at all, so `callStringBody` rejects them before this switch.
    return switch (id) {
        34 => pad(rt, bytes.items, args, .start),
        35 => pad(rt, bytes.items, args, .end),
        36 => localeCompare(rt, bytes.items, args),
        legacy_normalize_method_id => normalize(rt, bytes.items, args),
        legacy_search_method_id => search(rt, bytes.items, args),
        legacy_match_method_id => matchString(rt, bytes.items, args),
        legacy_replace_all_method_id => replaceAll(rt, bytes.items, args),
        else => error.TypeError,
    };
}

fn substring(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue {
    const range = try stringSubstringRange(rt, bytes.len, args);
    return createStringValue(rt, bytes[range.start..range.end]);
}

fn substringReceiver(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    if (stringValueFromReceiverRaw(receiver)) |string_value| {
        const range = try stringSubstringRange(rt, core.string.stringValueLenUnchecked(string_value), args);
        return stringSliceValue(rt, string_value, range.start, range.end - range.start);
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try appendStringReceiverBytes(rt, &bytes, receiver);
    return substring(rt, bytes.items, args);
}

fn trimReceiver(rt: *core.JSRuntime, receiver: core.JSValue, mode: TrimMode) !core.JSValue {
    if (stringValueFromReceiverRaw(receiver)) |string_value| {
        return trimStringValue(rt, string_value, mode);
    }
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try appendStringReceiverBytes(rt, &bytes, receiver);
    const trimmed = switch (mode) {
        .start => trimStartAscii(bytes.items),
        .end => trimEndAscii(bytes.items),
        .both => std.mem.trim(u8, bytes.items, " \t\r\n"),
    };
    return createStringValue(rt, trimmed);
}

fn trimStringValue(rt: *core.JSRuntime, string_value: core.JSValue, mode: TrimMode) !core.JSValue {
    var start: usize = 0;
    var end = core.string.stringValueLenUnchecked(string_value);
    if (mode == .start or mode == .both) {
        while (start < end and isTrimCodeUnit(core.string.stringValueCodeUnitAtUnchecked(string_value, start))) : (start += 1) {}
    }
    if (mode == .end or mode == .both) {
        while (end > start and isTrimCodeUnit(core.string.stringValueCodeUnitAtUnchecked(string_value, end - 1))) : (end -= 1) {}
    }
    return stringSliceValue(rt, string_value, start, end - start);
}

/// ToString the receiver for the non-string arms below. Reachable because
/// `call_runtime`'s name-dispatch fallback forwards primitives (number,
/// boolean, bigint, …) verbatim into `callStringBody`, i.e. without the
/// `stringPrototypeMethod` coercion.
fn coercedReceiverStringValue(rt: *core.JSRuntime, receiver: core.JSValue) !core.JSValue {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try appendStringReceiverBytes(rt, &bytes, receiver);
    return createStringValue(rt, bytes.items);
}

fn isWellFormedReceiver(rt: *core.JSRuntime, receiver: core.JSValue) !core.JSValue {
    if (stringValueFromReceiverRaw(receiver)) |string_value| {
        return core.JSValue.boolean(isWellFormedString(string_value));
    }
    // Scan the coerced text rather than assuming ToString() is well-formed.
    // No allocation happens between here and the scan, so the fresh string
    // needs no root frame.
    const coerced = try coercedReceiverStringValue(rt, receiver);
    const string_value = stringValueFromReceiverRaw(coerced) orelse return error.TypeError;
    return core.JSValue.boolean(isWellFormedString(string_value));
}

fn toWellFormedReceiver(rt: *core.JSRuntime, receiver: core.JSValue) !core.JSValue {
    if (stringValueFromReceiverRaw(receiver)) |string_value| {
        return toWellFormedString(rt, string_value);
    }
    const coerced = try coercedReceiverStringValue(rt, receiver);
    // The source is copied to native storage before the result allocates.
    const string_value = stringValueFromReceiverRaw(coerced) orelse return error.TypeError;
    return toWellFormedString(rt, string_value);
}

fn isWellFormedString(string_value: core.JSValue) bool {
    const length = core.string.stringValueLenUnchecked(string_value);
    var i: usize = 0;
    while (i < length) {
        const unit = core.string.stringValueCodeUnitAtUnchecked(string_value, i);
        if (isHighSurrogateUnit(unit)) {
            if (i + 1 >= length or !isLowSurrogateUnit(core.string.stringValueCodeUnitAtUnchecked(string_value, i + 1))) return false;
            i += 2;
            continue;
        }
        if (isLowSurrogateUnit(unit)) return false;
        i += 1;
    }
    return true;
}

fn toWellFormedString(rt: *core.JSRuntime, string_value: core.JSValue) !core.JSValue {
    var units = std.ArrayList(u16).empty;
    defer units.deinit(rt.nativeAllocator());
    var borrow = core.runtime.NoGcScope{};
    borrow.activate(rt);
    defer borrow.deactivate();
    const length = core.string.stringValueLenUnchecked(string_value);
    try units.ensureTotalCapacity(rt.nativeAllocator(), length);

    var i: usize = 0;
    while (i < length) {
        const unit = core.string.stringValueCodeUnitAtUnchecked(string_value, i);
        if (isHighSurrogateUnit(unit)) {
            if (i + 1 < length and isLowSurrogateUnit(core.string.stringValueCodeUnitAtUnchecked(string_value, i + 1))) {
                units.appendAssumeCapacity(unit);
                units.appendAssumeCapacity(core.string.stringValueCodeUnitAtUnchecked(string_value, i + 1));
                i += 2;
            } else {
                units.appendAssumeCapacity(0xfffd);
                i += 1;
            }
            continue;
        }
        units.appendAssumeCapacity(if (isLowSurrogateUnit(unit)) 0xfffd else unit);
        i += 1;
    }
    borrow.deactivate();
    return (try core.string.String.createUtf16(rt, units.items)).value();
}

fn split(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue {
    var rooted_args_buffer = try core.runtime.ValueRootBuffer.initCopy(rt, args);
    defer rooted_args_buffer.deinit();
    const rooted_args = rooted_args_buffer.values();
    var values = [_]core.JSValue{core.JSValue.undefinedValue()};
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var root_frame = core.runtime.ValueRootFrame{ .slices = &slices };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    values[0] = (try core.Object.createArray(rt, null)).value();

    const limit: u32 = if (rooted_args.len >= 2 and !rooted_args[1].is(.undefined_value))
        try toUint32Limit(rt, rooted_args[1])
    else
        std.math.maxInt(u32);
    if (limit == 0) return values[0];

    if (rooted_args.len == 0 or rooted_args[0].is(.undefined_value)) {
        try defineStringElement(rt, objectFromValue(values[0]).?, 0, bytes);
        return values[0];
    }

    var sep = std.ArrayList(u8).empty;
    defer sep.deinit(rt.nativeAllocator());
    try appendValueString(rt, &sep, rooted_args[0]);

    var out_index: u32 = 0;
    if (sep.items.len == 0) {
        var index: usize = 0;
        while (index < bytes.len and out_index < limit) : (index += 1) {
            try defineStringElement(rt, objectFromValue(values[0]).?, out_index, bytes[index .. index + 1]);
            out_index += 1;
        }
        return values[0];
    }

    var start: usize = 0;
    while (out_index < limit) {
        const found = std.mem.indexOfPos(u8, bytes, start, sep.items) orelse break;
        try defineStringElement(rt, objectFromValue(values[0]).?, out_index, bytes[start..found]);
        out_index += 1;
        start = found + sep.items.len;
    }
    if (out_index < limit) {
        try defineStringElement(rt, objectFromValue(values[0]).?, out_index, bytes[start..]);
    }
    return values[0];
}

fn splitReceiver(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    return splitReceiverRooted(rt, receiver, args) catch |err| switch (err) {
        error.RootGenerationExhausted => error.OutOfMemory,
        error.RootAlreadyActive, error.RootMutationDuringCollection, error.WrongRuntime, error.InactiveRoot, error.InvalidRootIndex, error.ExpectedString => std.debug.panic("string split root contract: {s}", .{@errorName(err)}),
        else => |other| other,
    };
}

fn splitReceiverRooted(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    var roots = core.runtime.ExactValueRoots(5){};
    try roots.activate(rt);
    defer roots.deactivate();
    const source = try roots.ref(0);
    const separator = try roots.ref(1);
    const limit_arg = try roots.ref(2);
    const output = try roots.ref(3);
    const element = try roots.ref(4);
    try source.set(rt, receiver);
    try separator.set(rt, if (args.len >= 1) args[0] else core.JSValue.undefinedValue());
    try limit_arg.set(rt, if (args.len >= 2) args[1] else core.JSValue.undefinedValue());

    if (stringValueFromReceiverRaw(try source.get(rt))) |primitive| {
        try source.set(rt, primitive);
        try core.string.ensureFlat(rt, source.readOnly(), source);
        try output.set(rt, (try core.Object.createArray(rt, null)).value());
        const limit: u32 = if (!(try limit_arg.get(rt)).is(.undefined_value))
            try toUint32Limit(rt, try limit_arg.get(rt))
        else
            std.math.maxInt(u32);
        if (limit == 0) return output.get(rt);

        if ((try separator.get(rt)).is(.undefined_value)) {
            try defineValueElement(rt, objectFromValue(try output.get(rt)).?, 0, try source.get(rt));
            return output.get(rt);
        }

        try separator.set(rt, try stringValueFromSearchArgument(rt, try separator.get(rt)));
        try core.string.ensureFlat(rt, separator.readOnly(), separator);
        const source_len = core.string.stringValueLenUnchecked(try source.get(rt));
        const sep_len = core.string.stringValueLenUnchecked(try separator.get(rt));

        var out_index: u32 = 0;
        if (sep_len == 0) {
            var index: usize = 0;
            while (index < source_len and out_index < limit) : (index += 1) {
                try element.set(rt, try codeUnitStringValue(rt, core.string.stringValueCodeUnitAtUnchecked(try source.get(rt), index)));
                try defineValueElement(rt, objectFromValue(try output.get(rt)).?, out_index, try element.get(rt));
                out_index += 1;
            }
            return output.get(rt);
        }

        var start: usize = 0;
        while (out_index < limit) {
            const found = found: {
                var borrow = core.runtime.NoGcScope{};
                borrow.activate(rt);
                defer borrow.deactivate();
                break :found stringIndexOfUnits(core.string.asFlat(try source.get(rt)).?, core.string.asFlat(try separator.get(rt)).?, start);
            } orelse break;
            try element.set(rt, try stringSliceValue(rt, try source.get(rt), start, found - start));
            try defineValueElement(rt, objectFromValue(try output.get(rt)).?, out_index, try element.get(rt));
            out_index += 1;
            start = found + sep_len;
        }
        if (out_index < limit) {
            try element.set(rt, try stringSliceValue(rt, try source.get(rt), start, source_len - start));
            try defineValueElement(rt, objectFromValue(try output.get(rt)).?, out_index, try element.get(rt));
        }
        return output.get(rt);
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try appendStringReceiverBytes(rt, &bytes, try source.get(rt));
    return split(rt, bytes.items, &.{ try separator.get(rt), try limit_arg.get(rt) });
}

fn search(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue {
    var needle = std.ArrayList(u8).empty;
    defer needle.deinit(rt.nativeAllocator());
    const search_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    try appendValueString(rt, &needle, search_value);
    const index = std.mem.indexOf(u8, bytes, needle.items);
    return core.JSValue.int32(if (index) |value| @intCast(value) else -1);
}

fn matchString(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue {
    var rooted_args_buffer = try core.runtime.ValueRootBuffer.initCopy(rt, args);
    defer rooted_args_buffer.deinit();
    const rooted_args = rooted_args_buffer.values();
    var out_value = core.JSValue.undefinedValue();
    var input = core.JSValue.undefinedValue();
    var root_values = [_]*core.JSValue{
        &out_value,
        &input,
    };
    var root_frame = core.runtime.ValueRootFrame{
        .values = &root_values,
    };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    var needle = std.ArrayList(u8).empty;
    defer needle.deinit(rt.nativeAllocator());
    const search_value = if (rooted_args.len >= 1) rooted_args[0] else core.JSValue.undefinedValue();
    try appendValueString(rt, &needle, search_value);
    const index = std.mem.indexOf(u8, bytes, needle.items) orelse return core.JSValue.nullValue();

    const out = try core.Object.createArray(rt, null);
    out_value = out.value();
    try defineStringElement(rt, out, 0, bytes[index .. index + needle.items.len]);
    try defineIntProperty(rt, out, core.atom.ids.index, @intCast(index));
    input = try createStringValue(rt, bytes);
    const input_key = core.atom.ids.input;
    try out.defineOwnProperty(rt, input_key, core.Descriptor.data(input, .method));
    return out_value;
}

fn replaceAll(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue {
    var search_value = std.ArrayList(u8).empty;
    defer search_value.deinit(rt.nativeAllocator());
    const search_input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    try appendValueString(rt, &search_value, search_input);

    var replacement = std.ArrayList(u8).empty;
    defer replacement.deinit(rt.nativeAllocator());
    const replacement_input = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    try appendValueString(rt, &replacement, replacement_input);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(rt.nativeAllocator());
    if (search_value.items.len == 0) {
        try out.appendSlice(rt.nativeAllocator(), replacement.items);
        for (bytes) |byte| {
            try out.append(rt.nativeAllocator(), byte);
            try out.appendSlice(rt.nativeAllocator(), replacement.items);
        }
        return createStringValue(rt, out.items);
    }

    var start: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, start, search_value.items)) |found| {
        try out.appendSlice(rt.nativeAllocator(), bytes[start..found]);
        try out.appendSlice(rt.nativeAllocator(), replacement.items);
        start = found + search_value.items.len;
    }
    try out.appendSlice(rt.nativeAllocator(), bytes[start..]);
    return createStringValue(rt, out.items);
}

fn defineStringElement(rt: *core.JSRuntime, object: *core.Object, index: u32, bytes: []const u8) !void {
    var values = [_]core.JSValue{ object.value(), core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var root_frame = core.runtime.ValueRootFrame{ .slices = &slices };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    values[1] = try createStringValue(rt, bytes);
    try defineValueElement(rt, objectFromValue(values[0]).?, index, values[1]);
}

fn defineValueElement(rt: *core.JSRuntime, object: *core.Object, index: u32, value: core.JSValue) !void {
    var values = [_]core.JSValue{ object.value(), value };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var root_frame = core.runtime.ValueRootFrame{ .slices = &slices };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    try objectFromValue(values[0]).?.defineOwnProperty(rt, core.Atom.taggedInt(index), core.Descriptor.data(values[1], .all));
}

fn defineStringIndexUnitProperty(rt: *core.JSRuntime, object: *core.Object, index: u32, unit: u16) !void {
    var values = [_]core.JSValue{ object.value(), core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var root_frame = core.runtime.ValueRootFrame{ .slices = &slices };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    values[1] = if (unit < 0x100)
        (try rt.singleByteString(@intCast(unit))).value()
    else blk: {
        const units: [1]u16 = .{unit};
        break :blk (try core.string.String.createUtf16(rt, &units)).value();
    };
    try objectFromValue(values[0]).?.defineOwnProperty(rt, core.Atom.taggedInt(index), core.Descriptor.data(values[1], .{ .enumerable = true }));
}

fn trimStartAscii(bytes: []const u8) []const u8 {
    var start: usize = 0;
    while (start < bytes.len and isAsciiTrim(bytes[start])) : (start += 1) {}
    return bytes[start..];
}

fn trimEndAscii(bytes: []const u8) []const u8 {
    var end = bytes.len;
    while (end > 0 and isAsciiTrim(bytes[end - 1])) : (end -= 1) {}
    return bytes[0..end];
}

fn isAsciiTrim(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

fn codePointAtResolved(data: core.string.String.ResolvedData, len: usize, index: usize) CodePointSpan {
    switch (data) {
        // latin1 code units are never surrogates: each byte is one code point.
        .latin1 => |bytes| return .{ .value = bytes[index], .start = index, .end = index + 1 },
        .utf16 => |units| {
            const first = units[index];
            const next_index = index + 1;
            if (isHighSurrogateUnit(first) and next_index < len) {
                const second = units[next_index];
                if (isLowSurrogateUnit(second)) {
                    const value = 0x10000 + ((@as(u21, first) - 0xD800) << 10) + (@as(u21, second) - 0xDC00);
                    return .{ .value = value, .start = index, .end = index + 2 };
                }
            }
            return .{ .value = first, .start = index, .end = next_index };
        },
    }
}

fn unicodeCaseReceiver(rt: *core.JSRuntime, receiver: core.JSValue, to_lower: bool) !core.JSValue {
    const primitive = try toStringValueForMethod(rt, receiver);
    return unicodeCaseOwnedString(rt, primitive, to_lower);
}

fn unicodeCaseOwnedString(rt: *core.JSRuntime, primitive: core.JSValue, to_lower: bool) !core.JSValue {
    return unicodeCaseRootedString(rt, primitive, to_lower) catch |err| switch (err) {
        error.RootGenerationExhausted => error.OutOfMemory,
        error.RootAlreadyActive, error.RootMutationDuringCollection, error.WrongRuntime, error.InactiveRoot, error.InvalidRootIndex, error.ExpectedString => std.debug.panic("string case root contract: {s}", .{@errorName(err)}),
        else => |other| other,
    };
}

fn unicodeCaseRootedString(rt: *core.JSRuntime, primitive: core.JSValue, to_lower: bool) !core.JSValue {
    if (!primitive.isString()) return error.TypeError;
    var roots = core.runtime.ExactValueRoots(1){};
    try roots.activate(rt);
    defer roots.deactivate();
    const source = try roots.ref(0);
    try source.set(rt, primitive);
    const slen = core.string.stringValueLenUnchecked(primitive);
    if (slen == 0) return primitive;
    if (try core.string.String.createValueAsciiCaseMapped(rt, try source.get(rt), to_lower)) |mapped| return mapped.value();
    try core.string.ensureFlat(rt, source.readOnly(), source);

    var latin1 = std.ArrayList(u8).empty;
    defer latin1.deinit(rt.nativeAllocator());
    var wide = std.ArrayList(u16).empty;
    defer wide.deinit(rt.nativeAllocator());
    var is_wide = false;
    // Unicode mapping only grows native buffers. Finish every heap borrow
    // before allocating the final result; no resolved view crosses GC.
    var borrow = core.runtime.NoGcScope{};
    borrow.activate(rt);
    defer borrow.deactivate();
    const string_value = core.string.asFlat(try source.get(rt)).?;
    const data = string_value.resolveData();

    var index: usize = 0;
    while (index < slen) {
        const span = codePointAtResolved(data, slen, index);
        index = span.end;

        // The final-sigma test (Σ→ς) is the only branch that needs neighbour
        // context; it is rare (lowercase Σ only) so it keeps the string_value walk.
        const mapping = if (to_lower and span.value == 0x03a3 and isFinalSigma(string_value, span.start, span.end))
            singleCaseMapping(0x03c2)
        else
            unicode_lib.caseConvert(span.value, to_lower);

        for (mapping.codepoints[0..mapping.len]) |cp| {
            if (!is_wide and cp <= 0xff) {
                try latin1.append(rt.nativeAllocator(), @intCast(cp));
            } else {
                if (!is_wide) {
                    is_wide = true;
                    try wide.ensureTotalCapacity(rt.nativeAllocator(), latin1.items.len + 1);
                    for (latin1.items) |byte| wide.appendAssumeCapacity(byte);
                    latin1.clearRetainingCapacity();
                }
                try appendUtf16CodePoint(rt, &wide, cp);
            }
        }
    }

    borrow.deactivate();
    const string = if (is_wide)
        try core.string.String.createUtf16(rt, wide.items)
    else
        try core.string.String.createLatin1(rt, latin1.items);
    return string.value();
}

fn toStringValueForMethod(rt: *core.JSRuntime, receiver: core.JSValue) !core.JSValue {
    if (receiver.isString()) return receiver;
    if (receiver.is(.object)) {
        const object = try expectObject(receiver);
        if (object.class_id == core.class.ids.string) {
            return (object.objectData() orelse return error.TypeError);
        }
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(rt.nativeAllocator());
        try appendValueString(rt, &bytes, receiver);
        return createStringValue(rt, bytes.items);
    }
    if (receiver.is(.null_value) or receiver.is(.undefined_value)) return error.TypeError;

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try appendValueString(rt, &bytes, receiver);
    return createStringValue(rt, bytes.items);
}

fn singleCaseMapping(cp: u21) unicode_lib.CaseMapping {
    var mapping: unicode_lib.CaseMapping = .{ .codepoints = undefined, .len = 1 };
    mapping.codepoints[0] = cp;
    return mapping;
}

const CodePointSpan = struct {
    value: u21,
    start: usize,
    end: usize,
};
fn codePointAtStringIndex(string_value: *const core.string.String, index: usize) CodePointSpan {
    const first = string_value.codeUnitAt(index);
    const next_index = index + 1;
    if (isHighSurrogateUnit(first) and next_index < string_value.len()) {
        const second = string_value.codeUnitAt(next_index);
        if (isLowSurrogateUnit(second)) {
            return .{ .value = unicode_lib.codePointFromSurrogatePair(first, second), .start = index, .end = index + 2 };
        }
    }
    return .{ .value = @intCast(first), .start = index, .end = next_index };
}

fn codePointBeforeStringIndex(string_value: *const core.string.String, end: usize) ?CodePointSpan {
    if (end == 0) return null;
    const last_index = end - 1;
    const last = string_value.codeUnitAt(last_index);
    if (isLowSurrogateUnit(last) and last_index > 0) {
        const first_index = last_index - 1;
        const first = string_value.codeUnitAt(first_index);
        if (isHighSurrogateUnit(first)) {
            return .{ .value = unicode_lib.codePointFromSurrogatePair(first, last), .start = first_index, .end = end };
        }
    }
    return .{ .value = @intCast(last), .start = last_index, .end = end };
}

fn isFinalSigma(string_value: *const core.string.String, sigma_start: usize, after_sigma: usize) bool {
    var before_index = sigma_start;
    while (true) {
        const previous = codePointBeforeStringIndex(string_value, before_index) orelse return false;
        before_index = previous.start;
        if (unicode_lib.isCaseIgnorable(previous.value)) continue;
        if (!unicode_lib.isCased(previous.value)) return false;
        break;
    }

    var next_index = after_sigma;
    while (next_index < string_value.len()) {
        const next = codePointAtStringIndex(string_value, next_index);
        next_index = next.end;
        if (unicode_lib.isCaseIgnorable(next.value)) continue;
        return !unicode_lib.isCased(next.value);
    }
    return true;
}

fn indexOf(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue {
    if (args.len < 1 or args.len > 2) return error.TypeError;
    var needle = std.ArrayList(u8).empty;
    defer needle.deinit(rt.nativeAllocator());
    try appendValueString(rt, &needle, args[0]);
    const start = if (args.len >= 2) try stringSearchStart(rt, bytes.len, args[1]) else @as(usize, 0);
    const index = if (start <= bytes.len) std.mem.indexOfPos(u8, bytes, start, needle.items) else null;
    return core.JSValue.int32(if (index) |value| @intCast(value) else -1);
}

fn indexOfReceiver(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    if (stringValueFromReceiverRaw(receiver)) |value| return flatStringSearch(rt, value, args, .first);

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try appendStringReceiverBytes(rt, &bytes, receiver);
    return indexOf(rt, bytes.items, args);
}

fn lastIndexOf(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue {
    if (args.len < 1 or args.len > 2) return error.TypeError;
    var needle = std.ArrayList(u8).empty;
    defer needle.deinit(rt.nativeAllocator());
    try appendValueString(rt, &needle, args[0]);

    const default_start = if (needle.items.len <= bytes.len) bytes.len - needle.items.len else 0;
    const start = if (args.len >= 2 and !args[1].is(.undefined_value))
        try stringLastSearchStart(rt, default_start, args[1])
    else
        default_start;
    if (needle.items.len == 0) return core.JSValue.int32(@intCast(start));
    if (needle.items.len > bytes.len) return core.JSValue.int32(-1);

    var index = @min(start, default_start) + 1;
    while (index > 0) {
        index -= 1;
        if (std.mem.eql(u8, bytes[index .. index + needle.items.len], needle.items)) {
            return core.JSValue.int32(@intCast(index));
        }
    }
    return core.JSValue.int32(-1);
}

fn lastIndexOfReceiver(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    if (stringValueFromReceiverRaw(receiver)) |value| return flatStringSearch(rt, value, args, .last);

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try appendStringReceiverBytes(rt, &bytes, receiver);
    return lastIndexOf(rt, bytes.items, args);
}

fn charCodeAtReceiver(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const primitive = try stringPrimitiveValue(receiver);
    const index = if (args.len >= 1) try stringInteger(rt, args[0]) else 0;
    if (index < 0 or index >= @as(i64, @intCast(core.string.stringValueLenUnchecked(primitive)))) return core.JSValue.float64(std.math.nan(f64));
    return core.JSValue.int32(core.string.stringValueCodeUnitAtUnchecked(primitive, @intCast(index)));
}

fn codePointAtReceiver(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const primitive = try stringPrimitiveValue(receiver);
    const index = if (args.len >= 1) try stringInteger(rt, args[0]) else 0;
    const primitive_len = core.string.stringValueLenUnchecked(primitive);
    if (index < 0 or index >= @as(i64, @intCast(primitive_len))) return core.JSValue.undefinedValue();
    const unit = core.string.stringValueCodeUnitAtUnchecked(primitive, @intCast(index));
    if (isHighSurrogateUnit(unit) and index + 1 < primitive_len) {
        const next = core.string.stringValueCodeUnitAtUnchecked(primitive, @intCast(index + 1));
        if (isLowSurrogateUnit(next)) {
            return core.JSValue.int32(@intCast(unicode_lib.codePointFromSurrogatePair(unit, next)));
        }
    }
    return core.JSValue.int32(unit);
}

fn at(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue {
    const relative = if (args.len >= 1) try stringInteger(rt, args[0]) else 0;
    const len: i64 = @intCast(bytes.len);
    const index = if (relative < 0) len + relative else relative;
    if (index < 0 or index >= len) return core.JSValue.undefinedValue();
    return createStringValue(rt, bytes[@intCast(index)..@intCast(index + 1)]);
}

fn atReceiver(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    if (stringValueFromReceiverRaw(receiver)) |string_value| {
        const relative = if (args.len >= 1) try stringInteger(rt, args[0]) else 0;
        const len: i64 = @intCast(core.string.stringValueLenUnchecked(string_value));
        const index = if (relative < 0) len + relative else relative;
        if (index < 0 or index >= len) return core.JSValue.undefinedValue();
        return codeUnitStringValue(rt, core.string.stringValueCodeUnitAtUnchecked(string_value, @intCast(index)));
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try appendStringReceiverBytes(rt, &bytes, receiver);
    return at(rt, bytes.items, args);
}

fn slice(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue {
    const len: i64 = @intCast(bytes.len);
    var start = if (args.len >= 1) try stringInteger(rt, args[0]) else 0;
    var end = if (args.len >= 2 and !args[1].is(.undefined_value)) try stringInteger(rt, args[1]) else len;
    if (start < 0) start = @max(len + start, 0) else start = @min(start, len);
    if (end < 0) end = @max(len + end, 0) else end = @min(end, len);
    if (end < start) end = start;
    return createStringValue(rt, bytes[@intCast(start)..@intCast(end)]);
}

fn sliceReceiver(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    if (stringValueFromReceiverRaw(receiver)) |string_value| {
        const range = try stringSliceRange(rt, core.string.stringValueLenUnchecked(string_value), args);
        return stringSliceValue(rt, string_value, range.start, range.end - range.start);
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try appendStringReceiverBytes(rt, &bytes, receiver);
    return slice(rt, bytes.items, args);
}

const StringSliceRange = struct {
    start: usize,
    end: usize,
};
fn stringSubstringRange(rt: *core.JSRuntime, len_usize: usize, args: []const core.JSValue) !StringSliceRange {
    const len: i64 = @intCast(len_usize);
    const start_raw = if (args.len >= 1) try stringInteger(rt, args[0]) else 0;
    const end_raw = if (args.len >= 2 and !args[1].is(.undefined_value)) try stringInteger(rt, args[1]) else len;
    const start: usize = @intCast(@max(@as(i64, 0), @min(start_raw, len)));
    const end: usize = @intCast(@max(@as(i64, 0), @min(end_raw, len)));
    return .{ .start = @min(start, end), .end = @max(start, end) };
}

fn stringSliceRange(rt: *core.JSRuntime, len_usize: usize, args: []const core.JSValue) !StringSliceRange {
    const len: i64 = @intCast(len_usize);
    var start = if (args.len >= 1) try stringInteger(rt, args[0]) else 0;
    var end = if (args.len >= 2 and !args[1].is(.undefined_value)) try stringInteger(rt, args[1]) else len;
    if (start < 0) start = @max(len + start, 0) else start = @min(start, len);
    if (end < 0) end = @max(len + end, 0) else end = @min(end, len);
    if (end < start) end = start;
    return .{ .start = @intCast(start), .end = @intCast(end) };
}

/// Copy the source once without materializing ropes, then duplicate native
/// units up to the final length. No GC borrow survives result allocation.
fn repeatReceiver(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const string_value = stringValueFromReceiverRaw(receiver) orelse {
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(rt.nativeAllocator());
        try appendStringReceiverBytes(rt, &bytes, receiver);
        return repeat(rt, bytes.items, args);
    };

    const count = if (args.len >= 1) try stringInteger(rt, args[0]) else 0;
    // qjs js_string_repeat: count outside [0, 2^31-1] is
    // RangeError "invalid repeat count"; a result past JS_STRING_LEN_MAX is
    // RangeError "invalid string length". Both messages are attached by the
    // string_ops dispatch wrapper (error.RangeError / error.InvalidLength).
    if (count < 0 or count > 2147483647) return error.RangeError;
    const unit_len = core.string.stringValueLenUnchecked(string_value);
    if (unit_len == 0 or count == 0) return createStringValue(rt, "");
    const repeat_count: usize = @intCast(count);
    const total = try std.math.mul(usize, unit_len, repeat_count);
    if (total > core.string.max_length) return error.InvalidLength;
    var buffer = StringBuffer{
        .allocator = rt.nativeAllocator(),
        .is_wide = if (core.string.asFlat(string_value)) |flat| flat.isWide() else string_value.ropeBody().?.isWide(),
    };
    defer buffer.deinit();
    var borrow = core.runtime.NoGcScope{};
    borrow.activate(rt);
    defer borrow.deactivate();
    try buffer.ensureCapacity(total);
    try buffer.appendStringValue(rt, string_value);
    if (buffer.is_wide) {
        while (buffer.wide.items.len < total) {
            const count_to_copy = @min(buffer.wide.items.len, total - buffer.wide.items.len);
            buffer.wide.appendSliceAssumeCapacity(buffer.wide.items[0..count_to_copy]);
        }
    } else {
        while (buffer.latin1.items.len < total) {
            const count_to_copy = @min(buffer.latin1.items.len, total - buffer.latin1.items.len);
            buffer.latin1.appendSliceAssumeCapacity(buffer.latin1.items[0..count_to_copy]);
        }
    }
    borrow.deactivate();
    return buffer.finish(rt);
}

fn repeat(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue {
    const count = if (args.len >= 1) try stringInteger(rt, args[0]) else 0;
    // Mirror of repeatReceiver's qjs js_string_repeat checks.
    if (count < 0 or count > 2147483647) return error.RangeError;
    if (bytes.len == 0 or count == 0) return createStringValue(rt, "");
    const repeat_count: usize = @intCast(count);
    const total = try std.math.mul(usize, bytes.len, repeat_count);
    if (total > core.string.max_length) return error.InvalidLength;
    var out = try rt.nativeAllocator().alloc(u8, total);
    defer rt.nativeAllocator().free(out);
    var index: usize = 0;
    while (index < total) : (index += bytes.len) @memcpy(out[index .. index + bytes.len], bytes);
    return createStringValue(rt, out);
}

const PadSide = enum { start, end };
fn pad(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue, side: PadSide) !core.JSValue {
    const target_len_i = if (args.len >= 1) try stringInteger(rt, args[0]) else 0;
    if (target_len_i <= @as(i64, @intCast(bytes.len))) return createStringValue(rt, bytes);
    const target_len: usize = @intCast(target_len_i);
    var fill = std.ArrayList(u8).empty;
    defer fill.deinit(rt.nativeAllocator());
    if (args.len >= 2 and !args[1].is(.undefined_value)) {
        try appendValueString(rt, &fill, args[1]);
    } else {
        try fill.append(rt.nativeAllocator(), ' ');
    }
    if (fill.items.len == 0) return createStringValue(rt, bytes);

    var out = try rt.nativeAllocator().alloc(u8, target_len);
    defer rt.nativeAllocator().free(out);
    const fill_len = target_len - bytes.len;
    switch (side) {
        .start => {
            var index: usize = 0;
            while (index < fill_len) : (index += 1) out[index] = fill.items[index % fill.items.len];
            @memcpy(out[fill_len..], bytes);
        },
        .end => {
            @memcpy(out[0..bytes.len], bytes);
            var index: usize = 0;
            while (index < fill_len) : (index += 1) out[bytes.len + index] = fill.items[index % fill.items.len];
        },
    }
    return createStringValue(rt, out);
}

fn localeCompare(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue {
    var other = std.ArrayList(u8).empty;
    defer other.deinit(rt.nativeAllocator());
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    try appendValueString(rt, &other, value);
    const result: i32 = switch (std.mem.order(u8, bytes, other.items)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
    return core.JSValue.int32(result);
}

fn normalize(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue {
    if (args.len >= 1 and !args[0].is(.undefined_value)) {
        var form = std.ArrayList(u8).empty;
        defer form.deinit(rt.nativeAllocator());
        try appendValueString(rt, &form, args[0]);
        if (!std.mem.eql(u8, form.items, "NFC") and
            !std.mem.eql(u8, form.items, "NFD") and
            !std.mem.eql(u8, form.items, "NFKC") and
            !std.mem.eql(u8, form.items, "NFKD")) return error.RangeError;
    }
    return createStringValue(rt, bytes);
}

const StringContainsMode = enum { contains, starts, ends };
fn contains(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue, mode: StringContainsMode) !core.JSValue {
    if (args.len < 1 or args.len > 2) return error.TypeError;
    var needle = std.ArrayList(u8).empty;
    defer needle.deinit(rt.nativeAllocator());
    try appendValueString(rt, &needle, args[0]);
    const pos = if (args.len >= 2) try stringSearchStart(rt, bytes.len, args[1]) else 0;
    const found = switch (mode) {
        .contains => if (pos <= bytes.len) std.mem.indexOfPos(u8, bytes, pos, needle.items) != null else false,
        .starts => pos <= bytes.len and std.mem.startsWith(u8, bytes[pos..], needle.items),
        .ends => blk: {
            const end = if (args.len >= 2 and !args[1].is(.undefined_value)) pos else bytes.len;
            if (needle.items.len > end) break :blk false;
            break :blk std.mem.eql(u8, bytes[end - needle.items.len .. end], needle.items);
        },
    };
    return core.JSValue.boolean(found);
}

fn containsReceiver(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue, mode: StringContainsMode) !core.JSValue {
    if (stringValueFromReceiverRaw(receiver)) |value| return flatStringSearch(rt, value, args, switch (mode) {
        .contains => .contains,
        .starts => .starts,
        .ends => .ends,
    });

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try appendStringReceiverBytes(rt, &bytes, receiver);
    return contains(rt, bytes.items, args, mode);
}

fn appendStringReceiverBytes(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), target: core.JSValue) !void {
    if (target.isString()) {
        try core.string.appendValueUtf8(rt, buffer, target);
        return;
    }
    if (target.is(.object)) {
        const object = try expectObject(target);
        if (object.class_id == core.class.ids.string) {
            const data = object.objectData() orelse return error.TypeError;
            try appendValueString(rt, buffer, data);
            return;
        }
        try appendValueString(rt, buffer, target);
        return;
    }
    if (target.is(.null_value) or target.is(.undefined_value)) return error.TypeError;
    try appendValueString(rt, buffer, target);
}

const createStringValue = value_ops.createStringValue;
const FlatStringSearchMode = enum { first, last, contains, starts, ends };

fn flatStringSearch(rt: *core.JSRuntime, source_value: core.JSValue, args: []const core.JSValue, mode: FlatStringSearchMode) !core.JSValue {
    return flatStringSearchRooted(rt, source_value, args, mode) catch |err| switch (err) {
        error.RootGenerationExhausted => error.OutOfMemory,
        error.RootAlreadyActive, error.RootMutationDuringCollection, error.WrongRuntime, error.InactiveRoot, error.InvalidRootIndex, error.ExpectedString => std.debug.panic("string search root contract: {s}", .{@errorName(err)}),
        else => |other| other,
    };
}

fn flatStringSearchRooted(rt: *core.JSRuntime, source_value: core.JSValue, args: []const core.JSValue, mode: FlatStringSearchMode) !core.JSValue {
    if (!source_value.isString()) return error.TypeError;
    var roots = core.runtime.ExactValueRoots(3){};
    try roots.activate(rt);
    defer roots.deactivate();
    const source = try roots.ref(0);
    const target = try roots.ref(1);
    const position = try roots.ref(2);
    try source.set(rt, source_value);
    try target.set(rt, if (args.len >= 1) args[0] else core.JSValue.undefinedValue());
    try position.set(rt, if (args.len >= 2) args[1] else core.JSValue.undefinedValue());
    try target.set(rt, try stringValueFromSearchArgument(rt, try target.get(rt)));
    // Both operands can allocate. Acquire no body/slice until both outputs
    // are rooted, then rederive every borrow from those updated slots.
    try core.string.ensureFlat(rt, source.readOnly(), source);
    try core.string.ensureFlat(rt, target.readOnly(), target);
    const hlen = core.string.stringValueLenUnchecked(try source.get(rt));
    const nlen = core.string.stringValueLenUnchecked(try target.get(rt));
    const pos_value = try position.get(rt);
    const pos = if (mode == .last) blk: {
        if (nlen > hlen) return core.JSValue.int32(-1);
        const default_start = hlen - nlen;
        break :blk if (pos_value.is(.undefined_value)) default_start else try stringLastSearchStart(rt, default_start, pos_value);
    } else if (mode == .ends and pos_value.is(.undefined_value))
        hlen
    else
        try stringSearchStart(rt, hlen, pos_value);
    var borrow = core.runtime.NoGcScope{};
    borrow.activate(rt);
    defer borrow.deactivate();
    const haystack = core.string.asFlat(try source.get(rt)).?;
    const needle = core.string.asFlat(try target.get(rt)).?;
    switch (mode) {
        .first, .last => {
            const index = if (mode == .first) stringIndexOfUnits(haystack, needle, pos) else stringLastIndexOfUnits(haystack, needle, pos);
            return core.JSValue.int32(if (index) |value| @intCast(value) else -1);
        },
        .contains => return core.JSValue.boolean(stringIndexOfUnits(haystack, needle, pos) != null),
        .starts => return core.JSValue.boolean(stringMatchesAtUnits(haystack, needle, pos)),
        .ends => return core.JSValue.boolean(nlen <= pos and stringMatchesAtUnits(haystack, needle, pos - nlen)),
    }
}

fn stringValueFromSearchArgument(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue {
    if (value.isString()) return value;
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try appendValueString(rt, &bytes, value);
    return createStringValue(rt, bytes.items);
}

fn stringMatchesAtResolved(
    haystack: core.string.String.ResolvedData,
    needle: core.string.String.ResolvedData,
    hlen: usize,
    nlen: usize,
    start: usize,
) bool {
    if (start > hlen or nlen > hlen - start) return false;
    var offset: usize = 0;
    while (offset < nlen) : (offset += 1) {
        if (resolvedUnitAt(haystack, start + offset) != resolvedUnitAt(needle, offset)) return false;
    }
    return true;
}

// startsWith / endsWith call this once per op; resolve the flat slices once
// (hoisting the slice/rope parent-chain walk out of the per-char loop) instead
// of `codeUnitAt` per character — same resolve-once pattern as stringIndexOfUnits.
fn stringMatchesAtUnits(haystack: *core.string.String, needle: *core.string.String, start: usize) bool {
    return stringMatchesAtResolved(haystack.resolveData(), needle.resolveData(), haystack.len(), needle.len(), start);
}

inline fn resolvedUnitAt(data: core.string.String.ResolvedData, i: usize) u16 {
    return switch (data) {
        .latin1 => |bytes| bytes[i],
        .utf16 => |units| units[i],
    };
}

fn stringIndexOfUnits(haystack: *core.string.String, needle: *core.string.String, start: usize) ?usize {
    const hlen = haystack.len();
    const nlen = needle.len();
    if (start > hlen) return null;
    if (nlen == 0) return start;
    if (nlen > hlen - start) return null;
    // Resolve both operands to their flat code-unit slice ONCE (qjs string_indexof
    // hoists is_wide_char out of the loop, quickjs.c) instead of
    // re-walking the slice/rope parent chain via `codeUnitAt` on every character,
    // and first-char-skip so a non-matching position is rejected in a single read.
    // The loop runs no allocations, so the resolved slices stay valid throughout.
    const h = haystack.resolveData();
    const n = needle.resolveData();
    const first = resolvedUnitAt(n, 0);
    var index = start;
    const limit = hlen - nlen;
    while (index <= limit) : (index += 1) {
        if (resolvedUnitAt(h, index) != first) continue;
        var offset: usize = 1;
        while (offset < nlen and resolvedUnitAt(h, index + offset) == resolvedUnitAt(n, offset)) : (offset += 1) {}
        if (offset == nlen) return index;
    }
    return null;
}

fn stringLastIndexOfUnits(haystack: *core.string.String, needle: *core.string.String, start: usize) ?usize {
    const hlen = haystack.len();
    const nlen = needle.len();
    if (nlen == 0) return @min(start, hlen);
    if (nlen > hlen) return null;
    // Resolve both flat slices ONCE outside the per-position loop (the prior
    // code re-walked the slice/rope chain via codeUnitAt for every character of
    // every candidate position) and first-char-skip, mirroring stringIndexOfUnits.
    const h = haystack.resolveData();
    const n = needle.resolveData();
    const first = resolvedUnitAt(n, 0);
    var index = @min(start, hlen - nlen) + 1;
    while (index > 0) {
        index -= 1;
        if (resolvedUnitAt(h, index) != first) continue;
        if (stringMatchesAtResolved(h, n, hlen, nlen, index)) return index;
    }
    return null;
}

/// One-code-unit result string (`charAt` / `at` / the wrapper index reads).
/// A latin1 unit is the runtime's shared table entry, matching qjs
/// `js_new_string_char`'s narrow arm without its allocation.
fn codeUnitStringValue(rt: *core.JSRuntime, unit: u16) !core.JSValue {
    if (unit < 0x100) return (try rt.singleByteString(@intCast(unit))).value();
    return (try core.string.String.createUtf16(rt, &.{unit})).value();
}

fn createLatin1SliceValue(rt: *core.JSRuntime, bytes: []const u8) !core.JSValue {
    const str = try core.string.String.createLatin1(rt, bytes);
    return str.value();
}

fn stringPrimitiveValue(value: core.JSValue) !core.JSValue {
    if (value.isString()) return value;
    const object = try expectObject(value);
    if (object.class_id != core.class.ids.string) return error.TypeError;
    return (object.objectData() orelse return error.TypeError);
}

fn stringValueFromReceiverRaw(value: core.JSValue) ?core.JSValue {
    const string_value = if (value.isString())
        value
    else if (value.is(.object)) blk: {
        const object = core.value_semantics.objectFromValue(value) orelse return null;
        if (object.class_id != core.class.ids.string) return null;
        break :blk object.objectData() orelse return null;
    } else return null;
    return string_value;
}

/// Owning wrapper over the single `CreateIterResultObject` owner: this file's
/// callers hand over their reference to `value`.
fn iteratorResult(rt: *core.JSRuntime, global: ?*core.Object, value: core.JSValue, done: bool) !core.JSValue {
    return iterator_ops.createIteratorResult(rt, global, value, done);
}

test "string iteratorResult roots direct function bytecode value while creating result" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-string-iterator-result-bytecode-symbol");
    const fb = try core.FunctionBytecode.createPublishedFixture(rt, .{ .cpool_count = 1 }, &.{try rt.takeSymbolValue(symbol_atom)});

    const result_value = core.JSValue.functionBytecode(&fb.header);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const iterator_result_value = try iteratorResult(rt, null, result_value, false);
    const iterator_result = try expectObject(iterator_result_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    {
        const stored = try iterator_result.getProperty(core.atom.predefinedId("value", .string).?);
        try std.testing.expect(stored.same(result_value));
    }

    _ = rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "string wrapper iterator split and match helpers keep values under GC" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    ctx.cached_function_proto = try core.Object.create(rt, core.class.ids.object, null);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const text = try createStringValue(rt, "aba");

    const wrapper_value = try constructWithPrototype(rt, &.{text}, null);
    const wrapper = try expectObject(wrapper_value);
    const wrapped_data = wrapper.objectData() orelse return error.TypeError;
    const wrapped_string = flatReceiverForTest(wrapped_data) orelse return error.TypeError;
    try std.testing.expect(wrapped_string.eqlBytes("aba"));

    const iterator_value = try stringIterator(ctx, text);
    const iterator_object = try expectObject(iterator_value);
    const iterator_target = iterator_object.iteratorTarget() orelse return error.TypeError;
    const iterator_string = flatReceiverForTest(iterator_target) orelse return error.TypeError;
    try std.testing.expect(iterator_string.eqlBytes("aba"));

    const separator = try createStringValue(rt, "b");
    const split_value = try splitReceiver(rt, text, &.{separator});
    const split_object = try expectObject(split_value);
    const split_first = try split_object.getProperty(core.Atom.taggedInt(0));
    const split_second = try split_object.getProperty(core.Atom.taggedInt(1));
    try std.testing.expect((flatReceiverForTest(split_first) orelse return error.TypeError).eqlBytes("a"));
    try std.testing.expect((flatReceiverForTest(split_second) orelse return error.TypeError).eqlBytes("a"));

    const needle = try createStringValue(rt, "ba");
    const match_value = try matchString(rt, "ababa", &.{needle});
    const match_object = try expectObject(match_value);
    const match_item = try match_object.getProperty(core.Atom.taggedInt(0));
    try std.testing.expect((flatReceiverForTest(match_item) orelse return error.TypeError).eqlBytes("ba"));
    const input_key = try rt.internAtom("input");
    const input_value = try match_object.getProperty(input_key);
    try std.testing.expect((flatReceiverForTest(input_value) orelse return error.TypeError).eqlBytes("ababa"));
}

/// These fixtures only produce flat strings; a rope would return null here
/// rather than being materialized behind the caller's back.
fn flatReceiverForTest(value: core.JSValue) ?*core.string.String {
    return core.string.asFlat(stringValueFromReceiverRaw(value) orelse return null);
}

const expectObject = core.value_semantics.expectObject;
fn defineIntProperty(rt: *core.JSRuntime, object: *core.Object, key: core.Atom, value: i32) !void {
    var object_value = object.value();
    var root_frame = core.runtime.rootValues(.{&object_value});
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    try object.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(value), .all));
}

fn stringSearchStart(rt: *core.JSRuntime, length: usize, value: core.JSValue) !usize {
    const number = try value_ops.toIntegerOrInfinity(rt, value);
    if (std.math.isNan(number) or number <= 0) return 0;
    if (std.math.isPositiveInf(number)) return length;
    const truncated = @trunc(number);
    if (truncated >= @as(f64, @floatFromInt(length))) return length;
    return @intFromFloat(truncated);
}

fn stringLastSearchStart(rt: *core.JSRuntime, default_start: usize, value: core.JSValue) !usize {
    const number = try value_ops.toIntegerOrInfinity(rt, value);
    if (std.math.isNan(number)) return default_start;
    if (number <= 0) return 0;
    if (std.math.isPositiveInf(number)) return default_start;
    const truncated = @trunc(number);
    if (truncated >= @as(f64, @floatFromInt(default_start))) return default_start;
    return @intFromFloat(truncated);
}

fn toUint32Limit(rt: *core.JSRuntime, value: core.JSValue) !u32 {
    if (value.isBigInt() or value.is(.symbol)) return error.TypeError;
    const number = try value_ops.toIntegerOrInfinity(rt, value);
    if (std.math.isNan(number) or !std.math.isFinite(number) or number == 0) return 0;
    const integer = if (number < 0) -@floor(@abs(number)) else @floor(number);
    const modulo = @mod(integer, 4294967296.0);
    return @intFromFloat(modulo);
}

fn stringInteger(rt: *core.JSRuntime, value: core.JSValue) !i64 {
    if (value.as(.int)) |int_value| return int_value;
    const number = try value_ops.toIntegerOrInfinity(rt, value);
    if (std.math.isNan(number)) return 0;
    if (std.math.isPositiveInf(number)) return std.math.maxInt(i64);
    if (std.math.isNegativeInf(number)) return std.math.minInt(i64);
    const integer = if (number < 0) -@floor(@abs(number)) else @floor(number);
    return @intFromFloat(integer);
}

fn isTrimCodeUnit(unit: u16) bool {
    return unicode_lib.isEcmaWhitespaceOrLineTerminatorUnit(unit);
}

/// This file's policy for the shared bare-runtime ToString owner.
fn appendValueString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) AppendStringError!void {
    return core.value_string.appendValueString(rt, buffer, value, .{ .unwrap_wrappers = true });
}

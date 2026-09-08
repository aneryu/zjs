//! String builtins, coercion/concatenation, and RegExp-string integration.
//!
//! String/value inputs are borrowed; returned JSValues and temporary concat or
//! capture values carry explicit ownership and must be freed or transferred.
//! The large alias wall keeps extracted RegExp, object, array, and error-stack
//! seams source-compatible; it does not make their implementations one module.
//! Preserve the measured `ctx`/`output`/`global`/caller-function/caller-frame
//! ABI and keep benchmark-hot string/RegExp arms out of shared cold bodies.
//! Algorithm coordinates live beside each implementation, including QuickJS
//! concatenation at quickjs.c:4646-5042 and replacement at quickjs.c:46012.

const std = @import("std");

const bytecode = @import("../bytecode.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const core = @import("../core/root.zig");
const method_ids = core.host_function.builtin_method_ids;
const string_id_lookup = core.host_function.builtin_method_id_lookup.string;
const regexp_adapter = @import("regexp_adapter.zig");
const unicode_lib = @import("../libs/unicode.zig");
const call_mod = @import("call.zig");
const exception_ops = @import("exception_ops.zig");
const frame_mod = @import("frame.zig");
const iterator_ops = @import("iterator_ops.zig");
const property_ops = @import("property_ops.zig");
const value_ops = @import("value_ops.zig");

const qjs_concat_direct_part_limit = 32;

const QjsConcatPart = struct {
    value: core.JSValue,
    latin1: []const u8 = &.{},
};

const call_runtime = @import("call_runtime.zig");
const call_site_mod = @import("call_site.zig");
const array_ops = @import("array_ops.zig");
const builtin_glue = @import("builtin_glue.zig");
const coercion_ops = @import("coercion_ops.zig");
const error_stack_ops = @import("error_stack_ops.zig");
const object_ops = @import("object_ops.zig");
const regexp_fastpath = @import("regexp_fastpath.zig");
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
    // string" (JS_ToStringInternal quickjs.c:13632).
    if (value.isSymbol()) return throwTypeErrorMessage(ctx, global, "cannot convert symbol to string");
    if (value.isString()) return value;
    const primitive = if (value.isObject())
        try toPrimitiveForString(ctx, output, global, value, caller_function, caller_frame)
    else
        value;
    if (primitive.isSymbol()) return throwTypeErrorMessage(ctx, global, "cannot convert symbol to string");
    if (primitive.isString()) return primitive;
    return value_ops.toStringValue(ctx.runtime, primitive);
}

/// qjs `JS_ToStringCheckObject` (quickjs.c:13670): a null/undefined receiver
/// throws TypeError "null or undefined are forbidden" in the callee realm;
/// everything else is `JS_ToString`d. This is the exact `this`-coercion the
/// String.prototype method bodies open with (`js_string_charCodeAt` etc.,
/// quickjs.c:45453). Exposed so the self-contained builtin bodies can perform
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
    if (value.isNull() or value.isUndefined())
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
    if (!value.isObject()) return value;
    const symbol_to_primitive = (comptime core.atom.predefinedId("Symbol.toPrimitive", .symbol)) orelse
        return toOrdinaryPrimitiveString(ctx, output, global, value, caller_function, caller_frame);
    const method = try getValueProperty(ctx, output, global, value, symbol_to_primitive, caller_function, caller_frame);
    if (!method.isUndefined() and !method.isNull()) {
        // JS_ToPrimitiveInternal (quickjs.c:11096 JS_CallFree): a non-callable
        // Symbol.toPrimitive is still called and reports "not a function"; an
        // object return value throws "toPrimitive" (quickjs.c:11104).
        if (!isCallableValue(method)) return throwTypeErrorMessage(ctx, global, "not a function");
        const hint = try value_ops.createStringValue(ctx.runtime, "string");
        const primitive = try call_runtime.callValueOrBytecodeSyncInternalOutlined(ctx, output, global, value, method, &.{hint}, caller_function, caller_frame);
        if (primitive.isObject()) {
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
    // JS_ToPrimitiveInternal (quickjs.c:11131): no primitive from toString/valueOf.
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
    if (args[0].isSymbol()) return value_ops.toStringValue(ctx.runtime, args[0]);
    if (!args[0].isObject()) return value_ops.toStringValue(ctx.runtime, args[0]);
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
    if (this_value.isNull() or this_value.isUndefined()) {
        return throwTypeErrorMessage(ctx, global, "null or undefined are forbidden");
    }

    const part_count = try std.math.add(usize, args.len, 1);
    if (part_count <= qjs_concat_direct_part_limit) {
        var parts: [qjs_concat_direct_part_limit]QjsConcatPart = undefined;

        var direct_latin1 = true;
        var total_len: usize = 0;

        const receiver_string = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
        parts[0] = .{ .value = receiver_string };
        if (concatLatin1Part(receiver_string)) |bytes| {
            parts[0].latin1 = bytes;
            total_len = try concatAddLength(total_len, bytes.len);
        } else {
            direct_latin1 = false;
        }

        for (args, 0..) |arg, index| {
            const arg_string = try toStringForAnnexB(ctx, output, global, arg, caller_function, caller_frame);
            const part_index = index + 1;
            parts[part_index] = .{ .value = arg_string };
            if (direct_latin1) {
                if (concatLatin1Part(arg_string)) |bytes| {
                    parts[part_index].latin1 = bytes;
                    total_len = try concatAddLength(total_len, bytes.len);
                } else {
                    direct_latin1 = false;
                }
            }
        }

        if (direct_latin1) {
            if (total_len == 0) return (try ctx.runtime.emptyString()).value();

            var byte_parts: [qjs_concat_direct_part_limit][]const u8 = undefined;
            for (parts[0..part_count], 0..) |part, index| byte_parts[index] = part.latin1;
            // qjs `JS_ConcatString` -> `JS_ConcatString1` (quickjs.c:5042,
            // 4646): ToString first, measure, allocate one result, memcpy
            // each flat latin1 part directly into that result.
            return (try core.string.String.createLatin1Parts(ctx.runtime, byte_parts[0..part_count], total_len)).value();
        }

        return stringConcatFromConverted(ctx, parts[0..part_count]);
    }

    return stringConcatSlow(ctx, output, global, this_value, args, caller_function, caller_frame);
}

fn stringConcatSlow(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const rt = ctx.runtime;
    var values = std.ArrayList(core.JSValue).empty;
    defer {
        values.deinit(rt.memory.allocator);
    }
    try values.ensureTotalCapacity(rt.memory.allocator, args.len + 1);
    // `values` is malloc memory: not a traced carrier, not a range the
    // conservative scan walks. Every `toStringForAnnexB` below allocates (and
    // may run a user `toString`), so without this the string appended at
    // iteration `i` is reachable from nothing but this buffer when iteration
    // `i+1` collects -- the same hole as the regexp match-array staging buffer.
    // The capacity is reserved above, so `items.ptr` is stable and the list's
    // own `items` slice can BE the root slice; every `appendAssumeCapacity`
    // then extends the rooted prefix for free.
    var values_root = ValueSliceRoot{};
    values_root.init(rt, &values.items);
    defer values_root.deinit();

    const receiver_string = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
    values.appendAssumeCapacity(receiver_string);
    for (args) |arg| {
        const arg_string = try toStringForAnnexB(ctx, output, global, arg, caller_function, caller_frame);
        values.appendAssumeCapacity(arg_string);
    }

    var resolved = std.ArrayList(core.string.String.ResolvedData).empty;
    defer resolved.deinit(rt.memory.allocator);
    try resolved.ensureTotalCapacity(rt.memory.allocator, values.items.len);
    var total: usize = 0;
    var wide = false;
    for (values.items) |value| {
        const body = value.asStringBody() orelse return error.TypeError;
        const data = body.resolveData();
        switch (data) {
            .latin1 => |latin1_bytes| total = try concatAddLength(total, latin1_bytes.len),
            .utf16 => |units| {
                total = try concatAddLength(total, units.len);
                wide = true;
            },
        }
        resolved.appendAssumeCapacity(data);
    }
    if (total == 0) return (try rt.emptyString()).value();
    return (try core.string.String.createResolvedParts(rt, resolved.items, total, wide)).value();
}

/// Mixed-width / rope residue of the direct concat path. The retired
/// implementation appended each part's RAW latin1 bytes into a byte buffer and
/// re-decoded the buffer as UTF-8, so any high-latin1 part (code points
/// 0x80-0xFF) reaching this leg produced a corrupt decode. Mirror qjs
/// `JS_ConcatString1` (quickjs.c:4646) instead: flatten + measure each part
/// (result wide iff any part is wide), then copy with per-unit widening.
fn stringConcatFromConverted(ctx: *core.JSContext, parts: []const QjsConcatPart) !core.JSValue {
    const rt = ctx.runtime;
    var resolved: [qjs_concat_direct_part_limit]core.string.String.ResolvedData = undefined;
    var total: usize = 0;
    var wide = false;
    for (parts, 0..) |part, index| {
        const body = part.value.asStringBody() orelse return error.TypeError;
        const data = body.resolveData();
        switch (data) {
            .latin1 => |latin1_bytes| total = try concatAddLength(total, latin1_bytes.len),
            .utf16 => |units| {
                total = try concatAddLength(total, units.len);
                wide = true;
            },
        }
        resolved[index] = data;
    }
    if (total == 0) return (try rt.emptyString()).value();
    return (try core.string.String.createResolvedParts(rt, resolved[0..parts.len], total, wide)).value();
}

fn concatLatin1Part(value: core.JSValue) ?[]const u8 {
    if (value.ropeBody() != null) return null;
    const string_value = value.asStringBodyRaw() orelse return null;
    return string_value.borrowLatin1();
}

fn concatAddLength(total: usize, addend: usize) !usize {
    const next = std.math.add(usize, total, addend) catch return error.StringTooLong;
    if (next > core.string.max_length) return error.StringTooLong;
    return next;
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

/// js_string_replace (quickjs.c:46012, magic: 0 = replace / 1 = replaceAll).
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
    // js_string_replace (quickjs.c:46021): nullish receiver -> "cannot convert to object".
    if (this_value.isNull() or this_value.isUndefined()) {
        return throwTypeErrorMessage(ctx, global, "cannot convert to object");
    }
    const search_input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const replacement_input = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();

    if (search_input.isObject()) {
        if (is_replace_all) {
            // check_regexp_g_flag (quickjs.c:45807): undefined/null flags throw
            // TypeError "cannot convert to object"; a flags string without 'g'
            // throws TypeError "regexp must have the 'g' flag".
            if (try isRegExpObservable(ctx, output, global, search_input, caller_function, caller_frame)) {
                const flags_atom = (comptime core.atom.predefinedId("flags", .string)) orelse return error.TypeError;
                const flags = try getValueProperty(ctx, output, global, search_input, flags_atom, caller_function, caller_frame);
                if (flags.isNull() or flags.isUndefined())
                    return throwTypeErrorMessage(ctx, global, "cannot convert to object");
                const flags_string = try toStringForAnnexB(ctx, output, global, flags, caller_function, caller_frame);
                var bytes = std.ArrayList(u8).empty;
                defer bytes.deinit(ctx.runtime.memory.allocator);
                try value_ops.appendRawString(ctx.runtime, &bytes, flags_string);
                if (std.mem.indexOfScalar(u8, bytes.items, 'g') == null)
                    return throwTypeErrorMessage(ctx, global, "regexp must have the 'g' flag");
            }
        }
        if (try callStringReplaceMethod(ctx, output, global, this_value, search_input, replacement_input, caller_function, caller_frame)) |value| return value;
    }

    const source_value = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
    const search_value = try toStringForAnnexB(ctx, output, global, search_input, caller_function, caller_frame);
    const functional_replace = isCallableValue(replacement_input);
    var replacement_call: ?CallSite = if (functional_replace)
        CallSite.initInternal(
            ctx,
            output,
            global,
            core.JSValue.undefinedValue(),
            replacement_input,
            caller_function,
            caller_frame,
        )
    else
        null;
    const replacement_text = if (functional_replace)
        core.JSValue.undefinedValue()
    else
        try toStringForAnnexB(ctx, output, global, replacement_input, caller_function, caller_frame);

    const sp = source_value.asStringBody() orelse return error.TypeError;
    try sp.ensureFlat(ctx.runtime);
    const sp_data = sp.resolveData();
    const searchp = search_value.asStringBody() orelse return error.TypeError;
    try searchp.ensureFlat(ctx.runtime);
    const search_data = searchp.resolveData();
    const search_len = search_data.len();
    const rep_data: ?core.string.String.ResolvedData = if (functional_replace) null else blk: {
        const rp = replacement_text.asStringBody() orelse return error.TypeError;
        try rp.ensureFlat(ctx.runtime);
        break :blk rp.resolveData();
    };

    var b = StringBuffer{ .allocator = ctx.runtime.memory.allocator };
    defer b.deinit();

    var end_of_last_match: usize = 0;
    var is_first = true;
    while (true) {
        const maybe_pos: ?usize = if (search_len == 0) blk: {
            if (is_first) break :blk 0;
            if (end_of_last_match >= sp_data.len()) break :blk null;
            break :blk end_of_last_match + 1;
        } else stringIndexOfData(sp_data, search_data, end_of_last_match);
        const pos = maybe_pos orelse {
            if (is_first) return source_value;
            break;
        };

        try b.appendUnits(sp_data, end_of_last_match, pos - end_of_last_match);

        if (functional_replace) {
            const call_result = try replacement_call.?.call(&.{ search_value, core.JSValue.int32(@intCast(pos)), source_value });
            const repl_str = try toStringForAnnexB(ctx, output, global, call_result, caller_function, caller_frame);
            try b.appendStringValue(ctx.runtime, repl_str);
        } else {
            try appendSubstitutionStringSearch(&b, ctx.runtime, search_value, sp_data, pos, search_len, rep_data.?);
        }

        end_of_last_match = pos + search_len;
        is_first = false;
        if (!is_replace_all) break;
    }
    try b.appendUnits(sp_data, end_of_last_match, sp_data.len() - end_of_last_match);
    return b.finish(ctx.runtime);
}

fn resolvedCodeUnitAt(data: core.string.String.ResolvedData, index: usize) u16 {
    return switch (data) {
        .latin1 => |bytes| bytes[index],
        .utf16 => |units| units[index],
    };
}

/// string_indexof_char (quickjs.c:45553): first index of code unit `c` at or
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

/// string_indexof (quickjs.c:45573): naive first-char scan plus tail compare.
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

/// js_string_GetSubstitution (quickjs.c:45888) in its string-search shape:
/// captures == NULL, captures_val/namedCaptures == undefined, so `$N` and
/// `$<name>` take the norep path verbatim and only $$ $& $` $' substitute.
fn appendSubstitutionStringSearch(
    b: *StringBuffer,
    rt: *core.JSRuntime,
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
    if (!search_value.isObject()) return null;
    const replace_atom = (comptime core.atom.predefinedId("Symbol.replace", .symbol)) orelse return error.TypeError;
    const replacer = try getValueProperty(ctx, output, global, search_value, replace_atom, caller_function, caller_frame);
    if (replacer.isUndefined() or replacer.isNull()) return null;
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

pub fn buildErrorStackStringValue(ctx: *core.JSContext, global: *core.Object, skip_name: ?[]const u8) !core.JSValue {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(ctx.runtime.memory.allocator);

    const limit = errorStackTraceLimit(ctx.runtime, global);
    if (limit == 0) return value_ops.createStringValue(ctx.runtime, "");

    const frames = try ctx.snapshotBacktraceFrames();
    defer ctx.freeBacktraceFrameSnapshot(frames);
    var idx = frames.len;
    var emitted: usize = 0;
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
        if (bytes.items.len != 0) try bytes.append(ctx.runtime.memory.allocator, '\n');
        try bytes.appendSlice(ctx.runtime.memory.allocator, "    at ");
        try appendBacktraceFunctionName(ctx, &bytes, entry.function_name, entry.filename);
        if (entry.is_native) {
            try bytes.appendSlice(ctx.runtime.memory.allocator, " (native)");
            emitted += 1;
            continue;
        }
        const filename = ctx.runtime.atoms.name(entry.filename) orelse "<anonymous>";
        const location = entry.location();
        const line_num = if (location.line_num > 0) location.line_num else 1;
        const col_num = if (location.col_num > 0) location.col_num else 1;
        const suffix = try std.fmt.allocPrint(ctx.runtime.memory.allocator, " ({s}:{}:{})", .{ filename, line_num, col_num });
        defer ctx.runtime.memory.allocator.free(suffix);
        try bytes.appendSlice(ctx.runtime.memory.allocator, suffix);
        emitted += 1;
    }
    if (emitted != 0) try bytes.append(ctx.runtime.memory.allocator, '\n');

    return value_ops.createStringValue(ctx.runtime, bytes.items);
}

pub fn formatCapturedErrorStackStringValue(ctx: *core.JSContext, sites_value: core.JSValue, site_count: usize) !core.JSValue {
    const sites = objectFromValue(sites_value) orelse return value_ops.createStringValue(ctx.runtime, "");
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(ctx.runtime.memory.allocator);

    const current_length: usize = if (sites.isArray()) @intCast(sites.arrayLength()) else 0;
    const length = @min(current_length, site_count);
    var index: usize = 0;
    var emitted: usize = 0;
    while (index < length) : (index += 1) {
        if (index > std.math.maxInt(u32)) break;
        const site_value = try sites.getProperty(core.atom.atomFromUInt32(@intCast(index)));
        const site = objectFromValue(site_value) orelse continue;
        if (!site.isCallSite()) continue;
        if (bytes.items.len != 0) try bytes.append(ctx.runtime.memory.allocator, '\n');
        try bytes.appendSlice(ctx.runtime.memory.allocator, "    at ");
        try appendCallSiteFunctionName(ctx.runtime, &bytes, site);
        if (site.callSiteIsNative()) {
            try bytes.appendSlice(ctx.runtime.memory.allocator, " (native)");
            emitted += 1;
            continue;
        }

        var filename_bytes: std.ArrayList(u8) = .empty;
        defer filename_bytes.deinit(ctx.runtime.memory.allocator);
        try appendCallSiteFileName(ctx.runtime, &filename_bytes, site);
        const suffix = try std.fmt.allocPrint(
            ctx.runtime.memory.allocator,
            " ({s}:{}:{})",
            .{ filename_bytes.items, site.callSiteLine(), site.callSiteColumn() },
        );
        defer ctx.runtime.memory.allocator.free(suffix);
        try bytes.appendSlice(ctx.runtime.memory.allocator, suffix);
        emitted += 1;
    }
    if (emitted != 0) try bytes.append(ctx.runtime.memory.allocator, '\n');
    return value_ops.createStringValue(ctx.runtime, bytes.items);
}

pub fn stringFromCodePoint(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    var units = std.ArrayList(u16).empty;
    defer units.deinit(ctx.runtime.memory.allocator);
    for (args) |value| {
        const primitive = try toPrimitiveForNumber(ctx, output, global, value);
        const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
        const number = value_ops.numberValue(number_value) orelse std.math.nan(f64);
        // js_string_fromCodePoint (quickjs.c:45361): out-of-range/non-integer
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
    defer out.deinit(ctx.runtime.memory.allocator);

    var index: usize = 0;
    while (index < length) : (index += 1) {
        if (index > std.math.maxInt(u32)) return error.RangeError;
        const raw_part = try getValueProperty(ctx, output, global, raw, core.atom.atomFromUInt32(@intCast(index)), caller_function, caller_frame);
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
    // JS_ToObject on undefined/null (js_string_raw -> quickjs.c:39916) throws
    // TypeError "cannot convert to object".
    if (value.isNull() or value.isUndefined()) return throwTypeErrorMessage(ctx, global, "cannot convert to object");
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
        if (args[0].asInt32()) |code| {
            const unit: u16 = @intCast(@as(u32, @bitCast(code)) & 0xffff);
            if (unit <= 0xff) return (try ctx.runtime.singleByteString(@intCast(unit))).value();
            return (try core.string.String.createUtf16(ctx.runtime, &.{unit})).value();
        }
    }
    if (args.len == 2) {
        if (args[0].asInt32()) |first_code| {
            if (args[1].asInt32()) |second_code| {
                const cached = try ctx.runtime.recentTwoUnitString(
                    @intCast(@as(u32, @bitCast(first_code)) & 0xffff),
                    @intCast(@as(u32, @bitCast(second_code)) & 0xffff),
                );
                return cached.value();
            }
        }
    }
    var units: []u16 = &.{};
    if (args.len != 0) units = try ctx.runtime.memory.alloc(u16, args.len);
    defer if (units.len != 0) ctx.runtime.memory.free(u16, units);
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
    if (!this_value.isObject()) return error.TypeError;

    const source_atom = core.atom.ids.source;
    const source_value = try getValueProperty(ctx, output, global, this_value, source_atom, caller_function, caller_frame);
    const source_string = try toStringForAnnexB(ctx, output, global, source_value, caller_function, caller_frame);

    const flags_atom = comptime core.atom.predefinedId("flags", .string).?;
    const flags_value = try getValueProperty(ctx, output, global, this_value, flags_atom, caller_function, caller_frame);
    const flags_string = try toStringForAnnexB(ctx, output, global, flags_value, caller_function, caller_frame);

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(ctx.runtime.memory.allocator);
    try bytes.append(ctx.runtime.memory.allocator, '/');
    try value_ops.appendRawString(ctx.runtime, &bytes, source_string);
    try bytes.append(ctx.runtime.memory.allocator, '/');
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
    if (!this_value.isObject()) return error.TypeError;
    const string_input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const string_value = try toStringForAnnexB(ctx, output, global, string_input, caller_function, caller_frame);
    return try regExpSymbolSearchGeneric(ctx, output, global, this_value, string_value, caller_function, caller_frame);
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
    if (!this_value.isObject()) return error.TypeError;
    const string_input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const string_value = try toStringForAnnexB(ctx, output, global, string_input, caller_function, caller_frame);
    return try regExpSymbolMatchGeneric(ctx, output, global, this_value, string_value, caller_function, caller_frame);
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
    if (!this_value.isObject()) return error.TypeError;
    const string_input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const string_value = try toStringForAnnexB(ctx, output, global, string_input, caller_function, caller_frame);

    const constructor_value = try regExpSpeciesConstructor(ctx, output, global, this_value, caller_function, caller_frame);

    const flags_atom = (comptime core.atom.predefinedId("flags", .string)) orelse return error.TypeError;
    const flags_value = try getValueProperty(ctx, output, global, this_value, flags_atom, caller_function, caller_frame);
    const flags_string = try toStringForAnnexB(ctx, output, global, flags_value, caller_function, caller_frame);

    const construct_args = [_]core.JSValue{ this_value, flags_string };
    const matcher = try constructValueOrBytecode(ctx, output, global, constructor_value, &construct_args, caller_function, caller_frame);

    const last_index_value = try getValueProperty(ctx, output, global, this_value, core.atom.ids.lastIndex, caller_function, caller_frame);
    const last_index = try toLengthIndex(ctx, output, global, last_index_value);
    try setValuePropertyStrict(ctx, output, global, matcher, core.atom.ids.lastIndex, uint32NumberValue(toUint32Number(@floatFromInt(last_index))), caller_function, caller_frame);

    const prototype = try regExpStringIteratorPrototype(ctx.runtime, global);
    const iterator = try core.Object.create(ctx.runtime, core.class.ids.regexp_string_iterator, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, iterator.gcHeader());
    try iterator.setOptionalValueSlot(ctx.runtime, iterator.iteratorTargetSlot(), matcher);
    try iterator.setOptionalValueSlot(ctx.runtime, iterator.iteratorDataSlot(), string_value);
    const global_flag = try stringValueContainsByte(ctx.runtime, flags_string, 'g');
    const unicode_flag = try regExpFlagsAreFullUnicode(ctx.runtime, flags_string);
    iterator.iteratorKindSlot().* = (if (global_flag) @as(u8, 1) else 0) | (if (unicode_flag) @as(u8, 2) else 0);
    iterator.iteratorIndexSlot().* = 0;
    return iterator.value();
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
    // js_string_match (quickjs.c:45846): nullish receiver -> "cannot convert to object".
    if (this_value.isNull() or this_value.isUndefined()) return throwTypeErrorMessage(ctx, global, "cannot convert to object");
    const string_value = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);

    const regexp = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const match_all_atom = (comptime core.atom.predefinedId("Symbol.matchAll", .symbol)) orelse return error.TypeError;
    if (!regexp.isUndefined() and !regexp.isNull() and regexp.isObject()) {
        const matcher = try getValueProperty(ctx, output, global, regexp, match_all_atom, caller_function, caller_frame);
        if (try isRegExpObservable(ctx, output, global, regexp, caller_function, caller_frame)) {
            // check_regexp_g_flag (quickjs.c:45819/45829): undefined/null flags
            // -> "cannot convert to object"; missing 'g' -> "regexp must have the 'g' flag".
            const flags_atom = (comptime core.atom.predefinedId("flags", .string)) orelse return error.TypeError;
            const flags_value = try getValueProperty(ctx, output, global, regexp, flags_atom, caller_function, caller_frame);
            if (flags_value.isUndefined() or flags_value.isNull())
                return throwTypeErrorMessage(ctx, global, "cannot convert to object");
            const flags_string = try toStringForAnnexB(ctx, output, global, flags_value, caller_function, caller_frame);
            if (!try stringValueContainsByte(ctx.runtime, flags_string, 'g'))
                return throwTypeErrorMessage(ctx, global, "regexp must have the 'g' flag");
        }
        if (!matcher.isUndefined() and !matcher.isNull()) {
            return callValueOrBytecodeRoot(ctx, output, global, regexp, matcher, &.{string_value}, caller_function, caller_frame);
        }
    }

    const flags = try value_ops.createStringValue(ctx.runtime, "g");
    const regexp_args = [_]core.JSValue{ regexp, flags };
    const matcher = (try builtin_dispatch.callConstructRecord(ctx, output, global, &.{}, null, regexp_construct_ref, ctx.classPrototypeObject(core.class.ids.regexp), &regexp_args, caller_function, caller_frame)) orelse return error.TypeError;
    const match_all = try getValueProperty(ctx, output, global, matcher, match_all_atom, caller_function, caller_frame);
    if (match_all.isUndefined() or match_all.isNull()) return error.TypeError;
    return callValueOrBytecodeRoot(ctx, output, global, matcher, match_all, &.{string_value}, caller_function, caller_frame);
}

pub fn regExpStringIteratorPrototype(rt: *core.JSRuntime, global: *core.Object) !*core.Object {
    const proto = try iteratorPrototype(rt, global, "RegExp String Iterator");
    errdefer core.Object.destroyFromHeader(rt, proto.gcHeader());
    const next = try core.function.nativeFunctionForGlobal(rt, global, "next", 0);
    try proto.defineOwnProperty(rt, (comptime core.atom.predefinedId("next", .string)).?, core.Descriptor.data(next, true, false, true));
    return proto;
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
    if (!this_value.isObject()) return error.TypeError;
    const string_input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const string_value = try toStringForAnnexB(ctx, output, global, string_input, caller_function, caller_frame);
    const replace_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    return try regExpSymbolReplaceGeneric(ctx, output, global, this_value, string_value, replace_value, caller_function, caller_frame);
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
    if (!this_value.isObject()) return error.TypeError;
    const string_input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const string_value = try toStringForAnnexB(ctx, output, global, string_input, caller_function, caller_frame);

    const constructor_value = try regExpSpeciesConstructor(ctx, output, global, this_value, caller_function, caller_frame);
    const flags_string = try regExpSplitFlags(ctx, output, global, this_value, caller_function, caller_frame);
    const construct_args = [_]core.JSValue{ this_value, flags_string };
    const splitter = try constructValueOrBytecode(ctx, output, global, constructor_value, &construct_args, caller_function, caller_frame);

    var limit_value = core.JSValue.undefinedValue();
    if (args.len >= 2 and !args[1].isUndefined()) {
        const primitive = try toPrimitiveForNumber(ctx, output, global, args[1]);
        if (primitive.isBigInt()) return error.TypeError;
        const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
        const number = value_ops.numberValue(number_value) orelse std.math.nan(f64);
        limit_value = uint32NumberValue(toUint32Number(number));
    }
    const limit = if (limit_value.isUndefined()) std.math.maxInt(u32) else toUint32Number(value_ops.numberValue(limit_value) orelse std.math.nan(f64));
    if (limit == 0) {
        const out = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
        return out.value();
    }
    const unicode_matching = try regExpFlagsAreFullUnicode(ctx.runtime, flags_string);
    return try regExpSymbolSplitGeneric(ctx, output, global, splitter, string_value, limit, unicode_matching, caller_function, caller_frame);
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
    // string_indexof_char by inspecting the flat Latin-1/UTF-16 payload in
    // place; retain the generic conversion fallback for non-string callers.
    if (string_value.asStringBody() != null) return stringValueContainsUnitByte(string_value, needle);
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
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
    // `string_value` is already the result of ToString. Borrow its flat body
    // just as QuickJS keeps `strp` for the complete split loop; copying every
    // code unit up front adds work and also widens Latin-1 inputs to UTF-16.
    const string_body = string_value.asStringBody() orelse return error.TypeError;
    try string_body.ensureFlat(ctx.runtime);
    const input_len = string_body.len();

    const out = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
    errdefer core.Object.destroyFromHeader(ctx.runtime, out.gcHeader());
    var out_index: u32 = 0;

    // TGC R1-c. Everything this loop carries is a bare Zig local across a
    // JS-observable step: `out` is a freshly created array reachable from
    // nowhere else until it is returned, `string_body` is a borrowed flat
    // payload pointer whose owner is only named by `string_value`, and the
    // `splitter` / exec `result` values are held while `lastIndex`
    // set/get run accessors and `regExpExecGeneric` runs a user `exec`.
    // Rooting `string_value` is what keeps `string_body` (and every
    // `advanceStringIndexBody` read of it) legal, so the two must share the
    // frame's lifetime.
    var rooted_out: ?*core.Object = out;
    var rooted_string = string_value;
    var rooted_splitter = splitter;
    var rooted_result = core.JSValue.undefinedValue();
    var split_roots = core.runtime.ValueRootFrame{
        .values = &[_]core.runtime.ValueRootValue{
            .{ .value = &rooted_string },
            .{ .value = &rooted_splitter },
            .{ .value = &rooted_result },
        },
        .objects = &[_]core.runtime.ObjectRootValue{.{ .object = &rooted_out }},
    };
    split_roots.activate(ctx.runtime);
    defer split_roots.deactivate(ctx.runtime);

    if (input_len == 0) {
        rooted_result = try regExpExecGeneric(ctx, output, global, splitter, string_value, caller_function, caller_frame);
        if (rooted_result.isNull()) try defineSplitValueElement(ctx.runtime, out, out_index, string_value);
        return out.value();
    }

    var start: usize = 0;
    var pos: usize = 0;
    while (pos < input_len) {
        try setValuePropertyStrict(ctx, output, global, splitter, core.atom.ids.lastIndex, core.JSValue.int32(@intCast(pos)), caller_function, caller_frame);
        rooted_result = try regExpExecGeneric(ctx, output, global, splitter, string_value, caller_function, caller_frame);
        const result = rooted_result;
        if (result.isNull()) {
            pos = advanceStringIndexBody(string_body, pos, unicode_matching);
            continue;
        }

        const end_value = try getValueProperty(ctx, output, global, splitter, core.atom.ids.lastIndex, caller_function, caller_frame);
        var end = try toLengthIndex(ctx, output, global, end_value);
        if (end > input_len) end = input_len;
        if (end == start) {
            pos = advanceStringIndexBody(string_body, pos, unicode_matching);
            continue;
        }

        try defineSplitSliceElement(ctx.runtime, out, out_index, string_value, start, pos - start);
        out_index += 1;
        if (out_index >= limit) return out.value();
        start = end;

        const length_value = try getValueProperty(ctx, output, global, result, core.atom.ids.length, caller_function, caller_frame);
        const capture_limit = try toLengthIndex(ctx, output, global, length_value);
        var capture_index: usize = 1;
        while (capture_index < capture_limit) : (capture_index += 1) {
            const capture = try getValueProperty(ctx, output, global, result, core.atom.atomFromUInt32(@intCast(capture_index)), caller_function, caller_frame);
            // CreateDataProperty consumes the capture value as-is. Custom exec
            // methods may return non-string captures, and QuickJS does not
            // coerce them in @@split.
            try defineSplitValueElementOwned(ctx.runtime, out, out_index, capture);
            out_index += 1;
            if (out_index >= limit) return out.value();
        }
        pos = start;
    }

    const tail_start = @min(start, input_len);
    try defineSplitSliceElement(ctx.runtime, out, out_index, string_value, tail_start, input_len - tail_start);
    return out.value();
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
    const previous = try getValueProperty(ctx, output, global, rx, core.atom.ids.lastIndex, caller_function, caller_frame);
    if (!previous.sameValue(core.JSValue.int32(0))) {
        try setValuePropertyStrict(ctx, output, global, rx, core.atom.ids.lastIndex, core.JSValue.int32(0), caller_function, caller_frame);
    }

    const result = try regExpExecGeneric(ctx, output, global, rx, string_value, caller_function, caller_frame);

    const current = try getValueProperty(ctx, output, global, rx, core.atom.ids.lastIndex, caller_function, caller_frame);
    if (!current.sameValue(previous)) {
        try setValuePropertyStrict(ctx, output, global, rx, core.atom.ids.lastIndex, previous, caller_function, caller_frame);
    }

    if (result.isNull()) return core.JSValue.int32(-1);
    if (!result.isObject()) return error.TypeError;
    const index_atom = (comptime core.atom.predefinedId("index", .string)) orelse return error.TypeError;
    return getValueProperty(ctx, output, global, result, index_atom, caller_function, caller_frame);
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
    const flags_string = try getRegExpFlagsString(ctx, output, global, rx, caller_function, caller_frame);

    if (!stringValueContainsUnitByte(flags_string, 'g')) {
        return regExpExecGeneric(ctx, output, global, rx, string_value, caller_function, caller_frame);
    }

    const full_unicode = try regExpFlagsAreFullUnicode(ctx.runtime, flags_string);
    try setValuePropertyStrict(ctx, output, global, rx, core.atom.ids.lastIndex, core.JSValue.int32(0), caller_function, caller_frame);

    const out = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
    errdefer core.Object.destroyFromHeader(ctx.runtime, out.gcHeader());
    var count: u32 = 0;
    while (true) {
        const result = try regExpExecGeneric(ctx, output, global, rx, string_value, caller_function, caller_frame);
        if (result.isNull()) break;
        const zero_value = try getValueProperty(ctx, output, global, result, core.atom.atomFromUInt32(0), caller_function, caller_frame);
        const match_string = if (zero_value.isString())
            zero_value
        else blk: {
            const coerced = toStringForAnnexB(ctx, output, global, zero_value, caller_function, caller_frame) catch |err| {
                return err;
            };
            break :blk coerced;
        };
        const is_empty = isEmptyStringValue(ctx.runtime, match_string);
        try defineSplitValueElementOwned(ctx.runtime, out, count, match_string);
        count += 1;
        if (is_empty) {
            const last_index = try getValueProperty(ctx, output, global, rx, core.atom.ids.lastIndex, caller_function, caller_frame);
            const next = try advanceStringIndexNumber(ctx, output, global, string_value, last_index, full_unicode);
            try setValuePropertyStrict(ctx, output, global, rx, core.atom.ids.lastIndex, next, caller_function, caller_frame);
        }
    }
    if (count == 0) {
        // QJS frees the speculative result array before returning null when a
        // global match finds no entries. `errdefer` does not run on this
        // successful return, so release the owning object explicitly.
        core.Object.destroyFromHeader(ctx.runtime, out.gcHeader());
        return core.JSValue.nullValue();
    }
    return out.value();
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
    const functional_replace = isCallableValue(replace_value);
    var replacer_call_storage: CallSite = undefined;
    const replacer_call: ?*CallSite = if (functional_replace) blk: {
        replacer_call_storage = CallSite.initInternal(
            ctx,
            output,
            global,
            core.JSValue.undefinedValue(),
            replace_value,
            caller_function,
            caller_frame,
        );
        break :blk &replacer_call_storage;
    } else null;
    const replacement_string = if (functional_replace)
        core.JSValue.undefinedValue()
    else
        try toStringForAnnexB(ctx, output, global, replace_value, caller_function, caller_frame);

    // Standard-regexp fast path (QuickJS js_is_standard_regexp -> js_regexp_replace),
    // probed BEFORE observing the flags getter -- exactly like QuickJS. The guard
    // is fully side-effect-free (never invokes exec/flags/global/unicode), so a
    // non-standard regexp falls through to the generic path which observes those
    // getters in spec order. The fast path drives matching on the compiled
    // bytecode with a single reused capture buffer and no per-match array object.
    if (!functional_replace) {
        if (objectFromValue(rx)) |rx_object| {
            if (object_ops.regExpIsStandard(ctx.runtime, rx_object)) {
                if (try regExpReplaceFast(ctx, output, global, rx, string_value, replacement_string, caller_function, caller_frame)) |res| {
                    return res;
                }
            }
        }
    }

    const flags_string = try getRegExpFlagsStringForReplace(ctx, output, global, rx, caller_function, caller_frame);
    const is_global = try stringValueContainsByte(ctx.runtime, flags_string, 'g');
    const full_unicode = try regExpFlagsAreFullUnicode(ctx.runtime, flags_string);
    if (is_global) {
        try setValuePropertyStrict(ctx, output, global, rx, core.atom.ids.lastIndex, core.JSValue.int32(0), caller_function, caller_frame);
    }

    var matches = std.ArrayList(ReplaceMatch).empty;
    defer matches.deinit(ctx.runtime.memory.allocator);
    defer {
        freeReplaceMatches(ctx.runtime, matches.items);
    }
    var match_roots = ReplaceMatchRoots{ .runtime = ctx.runtime, .list = &matches };
    try match_roots.activate();
    defer match_roots.deactivate();

    while (true) {
        const result = try regExpExecGeneric(ctx, output, global, rx, string_value, caller_function, caller_frame);
        if (result.isNull()) {
            break;
        }
        if (!result.isObject()) {
            return error.TypeError;
        }
        const match = try captureReplaceMatch(ctx, output, global, result, string_value, caller_function, caller_frame);
        try matches.append(ctx.runtime.memory.allocator, match);
        if (!is_global) break;
        if (isEmptyStringValue(ctx.runtime, match.matched)) {
            const last_index = try getValueProperty(ctx, output, global, rx, core.atom.ids.lastIndex, caller_function, caller_frame);
            const next = try advanceStringIndexNumber(ctx, output, global, string_value, last_index, full_unicode);
            try setValuePropertyStrict(ctx, output, global, rx, core.atom.ids.lastIndex, next, caller_function, caller_frame);
        }
    }
    if (matches.items.len == 0) return string_value;

    const replacement_is_empty = !functional_replace and (try stringLengthIndex(ctx.runtime, replacement_string) == 0);
    const replacement_is_literal = !functional_replace and !replacement_is_empty and !stringValueContainsUnitByte(replacement_string, '$');

    var source_units = std.ArrayList(u16).empty;
    defer source_units.deinit(ctx.runtime.memory.allocator);
    try appendStringValueUnits(ctx.runtime, &source_units, string_value);

    var out = std.ArrayList(u16).empty;
    defer out.deinit(ctx.runtime.memory.allocator);
    var next_source_position: usize = 0;
    for (matches.items) |match| {
        const matched_len = try stringLengthIndex(ctx.runtime, match.matched);
        const position = @min(match.index, source_units.items.len);
        if (position < next_source_position) continue;
        try out.appendSlice(ctx.runtime.memory.allocator, source_units.items[next_source_position..position]);

        const replacement = if (functional_replace)
            try callReplaceFunction(ctx, output, global, replacer_call.?, match, string_value, caller_function, caller_frame)
        else if (replacement_is_empty and match.groups.isUndefined())
            core.JSValue.undefinedValue()
        else if (replacement_is_literal and match.groups.isUndefined())
            replacement_string
        else
            try getSubstitutionString(ctx, output, global, match, string_value, replacement_string, caller_function, caller_frame);
        if (!replacement_is_empty) try appendStringValueUnits(ctx.runtime, &out, replacement);
        next_source_position = @min(source_units.items.len, position + matched_len);
    }
    try out.appendSlice(ctx.runtime.memory.allocator, source_units.items[next_source_position..]);
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
    const rx_object = objectFromValue(rx) orelse return null;
    if (rx_object.class_id != core.class.ids.regexp) return null;
    if (!regexp_fastpath.regExpLastIndexCanSkipCoercion(rx_object)) return null;
    const cached_bytecode = rx_object.regexpCompiledBytecode();
    if (cached_bytecode.len == 0) return null;
    const compiled = regexp_adapter.Compiled{ .bytecode = @constCast(cached_bytecode) };
    const bits = compiled.flagBits();
    // QuickJS bails on group names (the generic driver handles `$<name>`).
    if ((bits & regexp_adapter.flag_bits.named_groups) != 0) return null;
    // Read flags straight from the compiled bytecode -- like QuickJS's
    // js_regexp_replace -- instead of observing the (potentially overridden)
    // flags getter. Safe because the caller already confirmed `exec` is default.
    const is_global = (bits & regexp_adapter.flag_bits.global) != 0;
    const is_sticky = (bits & regexp_adapter.flag_bits.sticky) != 0;
    const full_unicode = (bits & (regexp_adapter.flag_bits.unicode | regexp_adapter.flag_bits.unicode_sets)) != 0;
    // QuickJS resets lastIndex to 0 up front for global regexps.
    if (is_global) try setRegExpLastIndexZero(ctx.runtime, rx_object);

    // js_regexp_replace works directly on the flat string bodies (str->u.str8/
    // str16 + string_buffer); no per-call UTF-16 copies of source/replacement.
    const sp = string_value.asStringBody() orelse return null;
    try sp.ensureFlat(ctx.runtime);
    const sp_data = sp.resolveData();
    const source_len = sp_data.len();
    const rp = replacement_string.asStringBody() orelse return null;
    try rp.ensureFlat(ctx.runtime);
    const rep_data = rp.resolveData();

    const alloc_count = compiled.allocCount();
    const capture_count = compiled.captureCount();
    var inline_capture_slots: [regexp_adapter.small_exec_slots]usize = undefined;
    var heap_capture_slots: []usize = &.{};
    defer if (heap_capture_slots.len != 0) ctx.runtime.memory.allocator.free(heap_capture_slots);
    const capture = if (alloc_count <= inline_capture_slots.len)
        inline_capture_slots[0..alloc_count]
    else capture: {
        heap_capture_slots = try ctx.runtime.memory.allocator.alloc(usize, alloc_count);
        break :capture heap_capture_slots;
    };

    var b = StringBuffer{ .allocator = ctx.runtime.memory.allocator };
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
                try regexp_fastpath.setRegExpLastIndexStrict(ctx, output, global, rx, rx_object, next_value, caller_function, caller_frame);
            }
            break;
        }
        last_index = if (match_end == match_start)
            advanceStringIndexData(sp_data, match_end, full_unicode)
        else
            match_end;
    }
    if (next_src < source_len) try b.appendUnits(sp_data, next_src, source_len - next_src);
    return try b.finish(ctx.runtime);
}

/// string_advance_index (quickjs.c:45589) over a resolved flat body: a narrow
/// string can hold no surrogate pair, so only wide data consults the pair.
fn advanceStringIndexData(data: core.string.String.ResolvedData, index: usize, unicode: bool) usize {
    return switch (data) {
        .latin1 => index + 1,
        .utf16 => |units| advanceStringIndexUnits(units, index, unicode),
    };
}

pub fn appendStringValueUnits(rt: *core.JSRuntime, out: *std.ArrayList(u16), value: core.JSValue) !void {
    const string_object = value.asStringBody() orelse {
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(rt.memory.allocator);
        try value_ops.appendRawString(rt, &bytes, value);
        for (bytes.items) |byte| try out.append(rt.memory.allocator, byte);
        return;
    };
    try string_object.ensureFlat(rt);
    switch (string_object.resolveData()) {
        .latin1 => |bytes| for (bytes) |byte| try out.append(rt.memory.allocator, byte),
        .utf16 => |units| try out.appendSlice(rt.memory.allocator, units),
    }
}

pub fn stringValueContainsUnitByte(value: core.JSValue, needle: u8) bool {
    const string_object = value.asStringBody() orelse return false;
    return switch (string_object.resolveData()) {
        .latin1 => |bytes| std.mem.indexOfScalar(u8, bytes, needle) != null,
        .utf16 => |units| blk: {
            for (units) |unit| {
                if (unit == needle) break :blk true;
            }
            break :blk false;
        },
    };
}

pub fn stringValueUnitsEqualBytes(value: core.JSValue, expected: []const u8) bool {
    const string_object = value.asStringBody() orelse return false;
    return switch (string_object.resolveData()) {
        .latin1 => |bytes| std.mem.eql(u8, bytes, expected),
        .utf16 => |units| blk: {
            if (units.len != expected.len) break :blk false;
            for (units, expected) |unit, byte| {
                if (unit != byte) break :blk false;
            }
            break :blk true;
        },
    };
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
    const flags_value = try getValueProperty(ctx, output, global, rx, flags_atom, caller_function, caller_frame);
    return toStringForAnnexB(ctx, output, global, flags_value, caller_function, caller_frame);
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
    const matched_value = try getValueProperty(ctx, output, global, result, core.atom.atomFromUInt32(0), caller_function, caller_frame);
    const matched = try toStringForAnnexB(ctx, output, global, matched_value, caller_function, caller_frame);

    const index_atom = (comptime core.atom.predefinedId("index", .string)) orelse return error.TypeError;
    const index_value = try getValueProperty(ctx, output, global, result, index_atom, caller_function, caller_frame);
    const string_len = try stringLengthIndex(ctx.runtime, string_value);
    const index = @min(try toLengthIndex(ctx, output, global, index_value), string_len);

    const length_value = try getValueProperty(ctx, output, global, result, core.atom.ids.length, caller_function, caller_frame);
    const length = try toLengthIndex(ctx, output, global, length_value);
    const capture_count = if (length == 0) 0 else length - 1;
    var captures: []core.JSValue = &.{};
    if (capture_count != 0) {
        captures = try ctx.runtime.memory.alloc(core.JSValue, capture_count);
        errdefer ctx.runtime.memory.free(core.JSValue, captures);
        var rooted_captures: []core.JSValue = captures[0..0];
        var captures_root = ValueSliceRoot{};
        captures_root.init(ctx.runtime, &rooted_captures);
        defer captures_root.deinit();
        var initialized: usize = 0;
        errdefer {
            for (captures[0..initialized]) |*capture| {
                capture.* = core.JSValue.undefinedValue();
            }
            rooted_captures = &.{};
        }
        while (initialized < capture_count) {
            const capture_index = initialized;
            captures[capture_index] = try getValueProperty(ctx, output, global, result, core.atom.atomFromUInt32(@intCast(capture_index + 1)), caller_function, caller_frame);
            initialized += 1;
            rooted_captures = captures[0..initialized];
            if (!captures[capture_index].isUndefined()) {
                const capture_string = try toStringForAnnexB(ctx, output, global, captures[capture_index], caller_function, caller_frame);
                captures[capture_index] = capture_string;
            }
        }
    }

    const groups_atom = (comptime core.atom.predefinedId("groups", .string)) orelse return error.TypeError;
    const groups = try getValueProperty(ctx, output, global, result, groups_atom, caller_function, caller_frame);
    return .{ .result = result, .matched = matched, .index = index, .captures = captures, .groups = groups };
}

pub fn freeReplaceMatches(rt: *core.JSRuntime, matches: []ReplaceMatch) void {
    for (matches) |match| {
        if (match.captures.len != 0) rt.memory.free(core.JSValue, match.captures);
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
    const extra: usize = if (match.groups.isUndefined()) 2 else 3;
    const arg_count = 1 + match.captures.len + extra;
    const args = try ctx.runtime.memory.alloc(core.JSValue, arg_count);
    defer ctx.runtime.memory.free(core.JSValue, args);
    args[0] = match.matched;
    for (match.captures, 0..) |capture, index| args[index + 1] = capture;
    args[1 + match.captures.len] = core.JSValue.int32(@intCast(match.index));
    args[2 + match.captures.len] = string_value;
    if (!match.groups.isUndefined()) args[3 + match.captures.len] = match.groups;
    const result = try replacer_call.call(args);
    return toStringForAnnexB(ctx, output, global, result, caller_function, caller_frame);
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
    const named_captures = if (match.groups.isUndefined())
        core.JSValue.undefinedValue()
    else if (match.groups.isNull())
        return error.TypeError
    else if (match.groups.isObject())
        match.groups
    else
        try primitiveObjectForAccess(ctx.runtime, global, match.groups);

    var source = std.ArrayList(u16).empty;
    defer source.deinit(ctx.runtime.memory.allocator);
    try appendStringValueUnits(ctx.runtime, &source, string_value);
    var matched = std.ArrayList(u16).empty;
    defer matched.deinit(ctx.runtime.memory.allocator);
    try appendStringValueUnits(ctx.runtime, &matched, match.matched);
    var replacement = std.ArrayList(u16).empty;
    defer replacement.deinit(ctx.runtime.memory.allocator);
    try appendStringValueUnits(ctx.runtime, &replacement, replacement_string);

    var out = std.ArrayList(u16).empty;
    defer out.deinit(ctx.runtime.memory.allocator);
    var index: usize = 0;
    while (index < replacement.items.len) : (index += 1) {
        if (replacement.items[index] != '$' or index + 1 >= replacement.items.len) {
            try out.append(ctx.runtime.memory.allocator, replacement.items[index]);
            continue;
        }
        const next = replacement.items[index + 1];
        switch (next) {
            '$' => {
                try out.append(ctx.runtime.memory.allocator, '$');
                index += 1;
            },
            '&' => {
                try out.appendSlice(ctx.runtime.memory.allocator, matched.items);
                index += 1;
            },
            '`' => {
                try out.appendSlice(ctx.runtime.memory.allocator, source.items[0..@min(match.index, source.items.len)]);
                index += 1;
            },
            '\'' => {
                const tail_start = @min(source.items.len, match.index + matched.items.len);
                try out.appendSlice(ctx.runtime.memory.allocator, source.items[tail_start..]);
                index += 1;
            },
            '0'...'9' => {
                const capture = replacementCaptureUnits(match, replacement.items, &index) orelse {
                    try out.append(ctx.runtime.memory.allocator, '$');
                    continue;
                };
                if (!capture.isUndefined()) try appendStringValueUnits(ctx.runtime, &out, capture);
            },
            '<' => {
                if (try appendNamedCaptureSubstitution(ctx, output, global, named_captures, replacement.items, &index, &out, caller_function, caller_frame)) continue;
                try out.append(ctx.runtime.memory.allocator, '$');
            },
            else => try out.append(ctx.runtime.memory.allocator, '$'),
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
/// js_string_GetSubstitution (quickjs.c:45888) in its raw-capture shape
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
    const string_object = string_value.asStringBody() orelse return 0;
    _ = rt;
    return string_object.len();
}

pub fn isEmptyStringValue(rt: *core.JSRuntime, value: core.JSValue) bool {
    // QuickJS JS_IsEmptyString reads the already-flat JSString length. RegExp
    // @@match calls this for every global match, so materializing a temporary
    // byte buffer here both obscures the representation and adds an allocation
    // to the common non-empty case.
    if (value.asStringBody()) |string| return string.len() == 0;
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
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
    const index_number = try toLengthNumber(ctx, output, global, index_value);
    if (!unicode or index_number >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) {
        return value_ops.numberToValue(index_number + 1);
    }
    const index: usize = @intFromFloat(index_number);
    if (!string_value.isString() or index + 1 >= core.string.stringValueLenUnchecked(string_value)) return value_ops.numberToValue(index_number + 1);
    const first = core.string.stringValueCodeUnitAtUnchecked(string_value, index);
    const second = core.string.stringValueCodeUnitAtUnchecked(string_value, index + 1);
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
    const string_value = value.asStringBody() orelse return null;
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
    // receiver (quickjs.c:45846/46021/46133/45846), not the
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
    if (this_value.isNull() or this_value.isUndefined()) return throwTypeErrorMessage(ctx, global, "null or undefined are forbidden");
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
    defer units.deinit(rt.memory.allocator);
    try appendStringValueUnits(rt, &units, value);
    var index: usize = 0;
    while (index < units.items.len) {
        const unit = units.items[index];
        if (isHighSurrogateUnit(unit) and index + 1 < units.items.len and isLowSurrogateUnit(units.items[index + 1])) {
            try out.append(rt.memory.allocator, combinedSurrogateCodePoint(unit, units.items[index + 1]));
            index += 2;
        } else {
            try out.append(rt.memory.allocator, unit);
            index += 1;
        }
    }
}

pub fn appendUtf16CodePoint(rt: *core.JSRuntime, out: *std.ArrayList(u16), code_point: u32) !void {
    return unicode_lib.appendUtf16CodePoint(rt.memory.allocator, out, @intCast(code_point));
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
    if (this_value.isNull() or this_value.isUndefined()) return error.TypeError;
    const string_value = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);

    const search_input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (method_id == 5 or method_id == 6 or method_id == 7) {
        // js_string_includes (quickjs.c:45757): a regexp search argument to
        // includes/startsWith/endsWith throws TypeError "regexp not supported".
        if (try isRegExpForStringSearch(ctx, output, global, search_input, caller_function, caller_frame))
            return throwTypeErrorMessage(ctx, global, "regexp not supported");
    }
    const search_value = try toStringForAnnexB(ctx, output, global, search_input, caller_function, caller_frame);

    var coerced: [2]core.JSValue = .{ search_value, core.JSValue.undefinedValue() };
    var count: usize = 1;
    if (args.len >= 2) {
        if (args[1].isUndefined()) {
            coerced[1] = core.JSValue.undefinedValue();
        } else {
            const primitive = try toPrimitiveForNumber(ctx, output, global, args[1]);
            if (primitive.isBigInt()) return error.TypeError;
            const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
            coerced[1] = value_ops.numberToValue(value_ops.numberValue(number_value) orelse std.math.nan(f64));
        }
        count = 2;
    }

    return callStringBody(ctx, string_value, method_id, coerced[0..count]);
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
    // js_string_match (quickjs.c:45846): nullish receiver -> "cannot convert to object".
    if (this_value.isNull() or this_value.isUndefined()) return throwTypeErrorMessage(ctx, global, "cannot convert to object");
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
    if (this_value.isNull() or this_value.isUndefined()) return error.TypeError;
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
        if (stored.isObject()) return property_ops.expectObject(stored) catch return error.TypeError;
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
    // js_string_match (quickjs.c:45846): nullish receiver -> "cannot convert to object".
    if (this_value.isNull() or this_value.isUndefined()) return throwTypeErrorMessage(ctx, global, "cannot convert to object");
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
    if (pattern.isObject() and !isRegExpValue(pattern)) {
        const pattern_string = try toStringForAnnexB(ctx, output, global, pattern, caller_function, caller_frame);
        owned_pattern = pattern_string;
        pattern = pattern_string;
    }
    const rx = try regExpConstructCall(ctx, output, global, objectFromValue(constructor), constructor, &.{pattern}, caller_function, caller_frame);
    if (try callStringWellKnownMethod(ctx, output, global, string_value, rx, symbol_name, caller_function, caller_frame)) |value| return value;
    // Mirrors js_string_match (quickjs.c:45881): the tail is
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
    if (candidate.isUndefined() or candidate.isNull()) return null;
    if (!candidate.isObject()) return null;
    const symbol_atom = core.atom.predefinedId(symbol_name, .symbol) orelse return error.TypeError;
    const method = try getValueProperty(ctx, output, global, candidate, symbol_atom, caller_function, caller_frame);
    if (method.isUndefined() or method.isNull()) return null;
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
    // js_string_split (quickjs.c:46133): nullish receiver -> "cannot convert to object".
    if (this_value.isNull() or this_value.isUndefined()) return throwTypeErrorMessage(ctx, global, "cannot convert to object");
    const separator = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (separator.isObject()) {
        const split_atom = (comptime core.atom.predefinedId("Symbol.split", .symbol)) orelse return error.TypeError;
        const splitter = try getValueProperty(ctx, output, global, separator, split_atom, caller_function, caller_frame);
        if (!splitter.isUndefined() and !splitter.isNull()) {
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

    if (args.len >= 2 and !args[1].isUndefined()) {
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

    // Mirrors js_string_split (quickjs.c:46139-46165): once the @@split lookup
    // above yielded undefined/null, even a regexp separator takes the string
    // path via R = JS_ToString(ctx, separator) — no builtin regexp split.
    if (args[0].isUndefined()) {
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

pub fn codePointFromSurrogatePair(high: u16, low: u16) u21 {
    return unicode_lib.codePointFromSurrogatePair(high, low);
}

pub fn surrogatePairFromCodePoint(code_point: u21) unicode_lib.SurrogatePair {
    return unicode_lib.surrogatePairFromCodePoint(code_point);
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
    const payload_i64 = value.asShortBigInt() orelse return null;
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
    const atom_id = core.atom.atomFromUInt32(index);
    if (try object.appendDenseArrayDefineIndex(rt, index, atom_id, value)) return;
    try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(value, true, true, true));
}

pub fn defineSplitValueElementOwned(rt: *core.JSRuntime, object: *core.Object, index: u32, value: core.JSValue) !void {
    const atom_id = core.atom.atomFromUInt32(index);
    const appended = object.appendDenseArrayDefineIndexOwned(rt, index, atom_id, value) catch |err| {
        return err;
    };
    if (appended) return;
    try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(value, true, true, true));
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
    const template = try regExpResultPropertyTemplate(rt, global);
    const groups_object: ?*core.Object = if (found.has_named_captures)
        try core.Object.create(rt, core.class.ids.object, null)
    else
        null;
    const groups_value = if (groups_object) |groups| groups.value() else core.JSValue.undefinedValue();
    const out = try core.Object.createRegExpMatchArrayFromShape(rt, template, @intCast(found.index), input_value, groups_value);
    errdefer core.Object.destroyFromHeader(rt, out.gcHeader());

    try initRegExpMatchArrayDenseElementsFromValue(rt, out, input_value, found, groups_object);

    try updateRegExpLegacyStaticsForMatch(rt, global, input_value, found, input_len);

    if (has_indices) {
        const indices = try createRegExpIndicesArray(rt, global, &.{}, found);
        const indices_atom = (comptime core.atom.predefinedId("indices", .string)) orelse return error.TypeError;
        try defineFreshNonIndexDataProperty(rt, out, indices_atom, indices, true, true, true);
    }
    return out.value();
}

pub fn initRegExpMatchArrayDenseElementsFromValue(
    rt: *core.JSRuntime,
    out: *core.Object,
    input_value: core.JSValue,
    found: *const RegExpMatch,
    groups: ?*core.Object,
) !void {
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
    cell[0] = try stringSliceValue(rt, input_value, found.index, found.len);
    rt.gc.generationalBarrierValue(cell_header, cell[0]);

    var capture_index: usize = 0;
    while (capture_index < found.capture_count) : (capture_index += 1) {
        const element_index = capture_index + 1;
        const capture = found.captureAt(capture_index);
        if (capture.undefined) continue;
        cell[element_index] = try stringSliceValue(rt, input_value, capture.start, capture.len);
        rt.gc.generationalBarrierValue(cell_header, cell[element_index]);
    }

    if (groups) |groups_object| {
        try populateRegExpGroupsFromCaptureValues(rt, groups_object, found, cell);
    }

    out.adoptDenseArrayElementsAssumingEmpty(rt, cell);
    out.flags.may_have_indexed_properties = true;
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
    const legacy = global.installedRealmRegExpLegacyStatics(rt) orelse
        (try global.ensureInstalledRealmRegExpLegacyStatics(rt)) orelse return;
    const previous_capture_slot_count: usize = legacy.capture_slot_count;
    const next_capture_slot_count = @min(found.capture_count, legacy.captures.len);
    legacy.lazy_no_capture_match = false;

    try replaceRegExpLegacySlot(rt, global, &legacy.input, input_value);
    try replaceRegExpLegacySlot(rt, global, &legacy.last_match, matched);

    if (found.index == 0) {
        clearRegExpLegacySlot(rt, &legacy.left_context);
    } else {
        const left = try stringSliceValue(rt, input_value, 0, found.index);
        try replaceRegExpLegacySlot(rt, global, &legacy.left_context, left);
    }

    const right_start = @min(found.index + found.len, input_len);
    if (right_start >= input_len) {
        clearRegExpLegacySlot(rt, &legacy.right_context);
    } else {
        const right = try stringSliceValue(rt, input_value, right_start, input_len - right_start);
        try replaceRegExpLegacySlot(rt, global, &legacy.right_context, right);
    }

    if (last_capture_value) |value| {
        try replaceRegExpLegacySlot(rt, global, &legacy.last_paren, value);
    } else if (legacy.last_paren != null) {
        clearRegExpLegacySlot(rt, &legacy.last_paren);
    }

    var slot_index: usize = 0;
    while (slot_index < @max(previous_capture_slot_count, next_capture_slot_count)) : (slot_index += 1) {
        if (slot_index < next_capture_slot_count) {
            if (legacy_capture_values[slot_index]) |value| {
                try replaceRegExpLegacySlot(rt, global, &legacy.captures[slot_index], value);
                continue;
            }
        }
        if (legacy.captures[slot_index] != null) clearRegExpLegacySlot(rt, &legacy.captures[slot_index]);
    }
    legacy.capture_slot_count = @intCast(next_capture_slot_count);
}

pub fn updateRegExpLegacyStaticsForMatch(rt: *core.JSRuntime, global: *core.Object, input_value: core.JSValue, found: *const RegExpMatch, input_len: usize) !void {
    if (try updateRegExpLegacyStaticsLazyForMatch(rt, global, input_value, found, input_len)) return;

    const matched = try stringSliceValue(rt, input_value, found.index, found.len);

    var legacy_capture_values: [9]?core.JSValue = @splat(null);
    var last_capture_value: ?core.JSValue = null;
    var capture_index: usize = 0;
    while (capture_index < found.capture_count) : (capture_index += 1) {
        const capture = found.captureAt(capture_index);
        if (capture.undefined) continue;
        const value = try stringSliceValue(rt, input_value, capture.start, capture.len);
        if (capture_index < legacy_capture_values.len) legacy_capture_values[capture_index] = value;
        const next_last_capture = value;
        last_capture_value = next_last_capture;
    }

    try updateRegExpLegacyStaticsForMatchValues(rt, global, input_value, found, input_len, matched, &legacy_capture_values, last_capture_value);
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
    return unicode_lib.appendUtf8CodePoint(rt.memory.allocator, out, cp);
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
    const string_value = value.asStringBody() orelse return value;
    const input_len = string_value.len();
    const slice_start = @min(start, input_len);
    const slice_end = @min(input_len, slice_start + len);
    const slice_len = slice_end - slice_start;
    if (slice_start == 0 and slice_len == input_len) return value;
    if (slice_len == 0) return (try rt.emptyString()).value();
    try string_value.ensureFlat(rt);
    if (slice_len == 1) {
        const unit = string_value.codeUnitAt(slice_start);
        if (unit < 0x100) return (try rt.singleByteString(@intCast(unit))).value();
    }
    return (try core.string.String.createSlice(rt, string_value, slice_start, slice_len)).value();
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
    const radix: u8 = if (args.len == 0 or args[0].isUndefined())
        10
    else blk: {
        const radix_primitive = try toPrimitiveForNumber(ctx, output, global, args[0]);
        if (radix_primitive.isBigInt() or radix_primitive.isSymbol()) return error.TypeError;
        const radix_value = try value_ops.toNumberValue(ctx.runtime, radix_primitive);
        const radix_number = value_ops.numberValue(radix_value) orelse return error.RangeError;
        if (std.math.isNan(radix_number) or !std.math.isFinite(radix_number)) return error.RangeError;
        const integer = @trunc(radix_number);
        if (integer < 2 or integer > 36) return error.RangeError;
        break :blk @intFromFloat(integer);
    };
    var bigint = try value_ops.cloneBigIntValue(ctx.runtime, primitive);
    defer bigint.deinit();
    const text = try bigint.formatBaseAlloc(ctx.runtime.memory.allocator, radix);
    defer ctx.runtime.memory.allocator.free(text);
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
    if (!value.isObject()) return !value.isNull() and !value.isUndefined();
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
    const name_string = if (name_value.isUndefined())
        try value_ops.createStringValue(ctx.runtime, "Error")
    else
        try toStringForAnnexB(ctx, output, global, name_value, caller_function, caller_frame);

    const message_atom = (comptime core.atom.predefinedId("message", .string)).?;
    const message_value = try getValueProperty(ctx, output, global, this_value, message_atom, caller_function, caller_frame);
    const message_string = if (message_value.isUndefined())
        try value_ops.createStringValue(ctx.runtime, "")
    else
        try toStringForAnnexB(ctx, output, global, message_value, caller_function, caller_frame);

    var name_bytes = std.ArrayList(u8).empty;
    defer name_bytes.deinit(ctx.runtime.memory.allocator);
    try value_ops.appendRawString(ctx.runtime, &name_bytes, name_string);
    var message_bytes = std.ArrayList(u8).empty;
    defer message_bytes.deinit(ctx.runtime.memory.allocator);
    try value_ops.appendRawString(ctx.runtime, &message_bytes, message_string);

    if (name_bytes.items.len == 0) return try value_ops.createStringValue(ctx.runtime, message_bytes.items);
    if (message_bytes.items.len == 0) return try value_ops.createStringValue(ctx.runtime, name_bytes.items);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(ctx.runtime.memory.allocator);
    try out.appendSlice(ctx.runtime.memory.allocator, name_bytes.items);
    try out.appendSlice(ctx.runtime.memory.allocator, ": ");
    try out.appendSlice(ctx.runtime.memory.allocator, message_bytes.items);
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
    if (value.isSymbol()) return error.TypeError;
    const string_value = if (value.isString())
        value
    else
        try toStringForAnnexB(ctx, output, global, value, caller_function, caller_frame);

    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(ctx.runtime.memory.allocator);
    try value_ops.appendRawString(ctx.runtime, &buffer, string_value);
    return buffer.toOwnedSlice(ctx.runtime.memory.allocator);
}

pub fn consumePendingExceptionIfMatchesConstructor(ctx: *core.JSContext, expected_name: []const u8) !bool {
    const thrown_value = ctx.runtime.current_exception;
    const matches = try thrownValueMatchesConstructor(ctx.runtime, thrown_value, expected_name);
    ctx.clearException();
    return matches;
}

pub fn thrownValueMatchesConstructor(rt: *core.JSRuntime, thrown_value: core.JSValue, expected_name: []const u8) !bool {
    if (!thrown_value.isObject()) return false;
    const thrown_object = property_ops.expectObject(thrown_value) catch return false;
    const ctor_value = try thrown_object.getProperty(core.atom.ids.constructor);
    if (ctor_value.isObject()) {
        const ctor = property_ops.expectObject(ctor_value) catch null;
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
    defer name_bytes.deinit(rt.memory.allocator);
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

    if (receiver.isNull() or receiver.isUndefined()) {
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
    // quickjs.c:58072 / :58179-58245). Normalize the search value once with an
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
    if (mode == .last_index_of) {
        var cursor = try arrayLastIndexStart(ctx, output, global, args, length);
        // Dense fast scan (qjs js_array_lastIndexOf js_get_fast_array loop,
        // quickjs.c:42476): if the receiver is still a dense fast array and the
        // fromIndex coercion above did not resize it, scan the borrowed element
        // slice directly — no per-element propertyAtomFromLengthIndex intern +
        // generic getValueProperty. `===` runs no user code, so the slice stays
        // valid for the whole loop.
        if (!is_typed_array and object.isFastArray() and @as(usize, @intCast(object.arrayLength())) == length and object.arrayElements().len == length) {
            const elements = object.arrayElements();
            if (cursor > elements.len) cursor = elements.len;
            while (cursor > 0) {
                cursor -= 1;
                if (try valuesStrictEqual(ctx.runtime, elements[cursor], search_value)) return lengthIndexValue(cursor);
            }
            return core.JSValue.int32(-1);
        }
        while (cursor > 0) {
            cursor -= 1;
            const item = if (is_typed_array) blk: {
                const current_length = @as(usize, @intCast(try core.object.typedArrayLength(ctx.runtime, object)));
                if (cursor >= current_length) continue;
                break :blk try core.typed_array.typedArrayGetIndex(ctx.runtime, object, @intCast(cursor));
            } else blk: {
                const key = try propertyAtomFromLengthIndex(ctx.runtime, cursor);
                defer key.deinit(ctx.runtime);
                if (!try hasValueProperty(ctx, output, global, receiver_object_value, object, key.atom, null, null)) continue;
                break :blk try getValueProperty(ctx, output, global, receiver_object_value, key.atom, null, null);
            };
            if (try valuesStrictEqual(ctx.runtime, item, search_value)) return lengthIndexValue(cursor);
        }
    } else {
        var cursor = try arrayFirstIndexStart(ctx, output, global, args, length);
        // Dense fast PREFIX scan, then fall through to the generic tail (qjs
        // js_array_indexOf/includes: js_get_fast_array dense loop over [0, count) then the
        // generic loop over [count, len) for the tail holes, quickjs.c:42426-42483). Unlike
        // a full-density gate, this also fast-scans the dense prefix of an L3 holey fast
        // array (array_count < length) before the proto-aware tail.
        if (!is_typed_array and object.isFastArray()) {
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
            // cursor == dense_end; the generic loop below covers [dense_end, length) holes.
        }
        while (cursor < length) : (cursor += 1) {
            const item = if (is_typed_array) blk: {
                if (mode != .includes) {
                    const current_length = @as(usize, @intCast(try core.object.typedArrayLength(ctx.runtime, object)));
                    if (cursor >= current_length) continue;
                }
                break :blk try core.typed_array.typedArrayGetIndex(ctx.runtime, object, @intCast(cursor));
            } else blk: {
                const key = try propertyAtomFromLengthIndex(ctx.runtime, cursor);
                defer key.deinit(ctx.runtime);
                if (mode != .includes and !try hasValueProperty(ctx, output, global, receiver_object_value, object, key.atom, null, null)) continue;
                break :blk try getValueProperty(ctx, output, global, receiver_object_value, key.atom, null, null);
            };
            if (mode == .includes) {
                if (item.sameValueZero(search_value)) return core.JSValue.boolean(true);
                continue;
            }
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

    if (receiver.isNull() or receiver.isUndefined()) return error.TypeError;
    const receiver_object_value = if (receiver.isObject()) receiver else try primitiveObjectForAccess(ctx.runtime, global, receiver);

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
            var index: usize = 0;
            while (index < length) : (index += 1) {
                if (next_index.* > core.array.max_array_length) return error.RangeError;
                const from_key = try propertyAtomFromLengthIndex(ctx.runtime, index);
                defer from_key.deinit(ctx.runtime);
                if (try hasValueProperty(ctx, output, global, value, object, from_key.atom, null, null)) {
                    const item = try getValueProperty(ctx, output, global, value, from_key.atom, caller_function, caller_frame);
                    const to_key = try propertyAtomFromLengthIndex(ctx.runtime, next_index.*);
                    defer to_key.deinit(ctx.runtime);
                    try createDataPropertyOrThrow(ctx, output, global, out.value(), out, to_key.atom, item, caller_function, caller_frame);
                }
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
    if (!spreadable.isUndefined()) return valueTruthy(spreadable);
    return arraySpeciesOriginalIsArray(object);
}

pub fn uint8ArrayStringBytes(rt: *core.JSRuntime, value: core.JSValue) !std.ArrayList(u8) {
    if (!value.isString()) return error.TypeError;
    var bytes = std.ArrayList(u8).empty;
    errdefer bytes.deinit(rt.memory.allocator);
    try value_ops.appendRawString(rt, &bytes, value);
    return bytes;
}

pub fn appendSourceStringUtf8(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) !void {
    // Eval and Function constructor source conversion use
    // JS_ToCStringLen's non-CESU-8 mode in QuickJS: a valid UTF-16 surrogate
    // pair becomes one four-byte UTF-8 scalar, while an unmatched surrogate is
    // preserved as its three-byte WTF-8 encoding. Reuse the canonical string
    // view instead of encoding each code unit independently.
    var utf8 = try core.JSValue.String.Utf8.fromValue(rt.memory.allocator, value);
    defer utf8.deinit();
    try buffer.appendSlice(rt.memory.allocator, utf8.slice());
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
    const iterator = property_ops.expectObject(receiver) catch return null;
    if (iterator.class_id != core.class.ids.regexp_string_iterator) return null;
    if ((iterator.iteratorIndexSlot().*) != 0) return try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
    const regexp = (iterator.iteratorTargetSlot().*) orelse {
        const done_result = try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
        iterator.iteratorIndexSlot().* = 1;
        return done_result;
    };
    const string_value = iterator.iteratorData() orelse {
        const done_result = try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
        iterator.iteratorIndexSlot().* = 1;
        return done_result;
    };
    const result = try regExpExecGeneric(ctx, output, global, regexp, string_value, caller_function, caller_frame);
    if (result.isNull()) {
        const done_result = try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
        iterator.iteratorIndexSlot().* = 1;
        iterator.clearOptionalValueSlot(ctx.runtime, iterator.iteratorTargetSlot());
        iterator.clearOptionalValueSlot(ctx.runtime, iterator.iteratorDataSlot());
        return done_result;
    }
    const is_global = ((iterator.iteratorKindSlot().*) & 1) != 0;
    if (!is_global) iterator.iteratorIndexSlot().* = 1;
    const unicode = ((iterator.iteratorKindSlot().*) & 2) != 0;
    const zero_value = try getValueProperty(ctx, output, global, result, core.atom.atomFromUInt32(0), caller_function, caller_frame);
    const match_string = try toStringForAnnexB(ctx, output, global, zero_value, caller_function, caller_frame);
    if (is_global and isEmptyStringValue(ctx.runtime, match_string)) {
        const last_index = try getValueProperty(ctx, output, global, regexp, core.atom.ids.lastIndex, caller_function, caller_frame);
        const next = try advanceStringIndexNumber(ctx, output, global, string_value, last_index, unicode);
        try setValuePropertyStrict(ctx, output, global, regexp, core.atom.ids.lastIndex, next, caller_function, caller_frame);
    }
    return try createIteratorResult(ctx.runtime, global, result, false);
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
    if (core.atom.isTaggedInt(atom_id) or atom_id == 0 or atom_id > core.atom.predefined_count) return null;
    if (atom_id == core.atom.ids.length) return null;

    // Primitive method lookup uses the realm intrinsic `%String.prototype%`,
    // mirroring QuickJS JS_GetPrototypePrimitive (quickjs.c:7995-8011). If a bare
    // runtime has no realm slot, fall back to the old global constructor walk.
    const string_ctor_atom = comptime (core.atom.predefinedId("String", .string)).?;
    const proto = object_ops.primitivePrototypeFromRealmOrGlobal(ctx.runtime, global, .string_prototype, string_ctor_atom) orelse return null;
    // W1: route the hot data-property lookup through the lean, already-inline
    // `findOwnDataValueFast` — the SAME primitive the ordinary object get_field path
    // uses — instead of the defensive out-of-line `findProperty`. Mirrors qjs
    // `find_own_property` returning prs+pr in one force_inline pass, then the TMASK
    // switch reading the already-loaded flags (quickjs.c:6135/8271): no out-of-line
    // call/frame, no FAM-base re-derivation, no flags re-read. The rare non-data
    // (accessor / auto-init) property falls back to the full resolver.
    if (proto.hasExoticMethods()) return null;
    var slow = false;
    if (proto.findOwnDataValueFast(atom_id, &slow)) |value| return value;
    if (slow) return try ownDataOrAutoInitPropertyValue(proto, atom_id);
    return null;
}

pub fn defineStringWrapperIndexProperty(rt: *core.JSRuntime, object: *core.Object, index: u32, unit: u16) !void {
    const value = if (unit < 0x100)
        (try rt.singleByteString(@intCast(unit))).value()
    else blk: {
        const units: [1]u16 = .{unit};
        break :blk (try core.string.String.createUtf16(rt, &units)).value();
    };
    try object.defineOwnProperty(rt, core.atom.atomFromUInt32(index), core.Descriptor.data(value, false, true, false));
}

pub fn getStringIndexValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) !?core.JSValue {
    const index = core.array.arrayIndexFromAtom(&rt.atoms, atom_id) orelse return null;
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
    if (this_value.isNull() or this_value.isUndefined()) return error.TypeError;
    const object_value = if (this_value.isObject()) this_value else try primitiveObjectForAccess(ctx.runtime, global, this_value);
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
    if (this_value.isNull() or this_value.isUndefined()) return error.TypeError;
    const object_value = if (this_value.isObject()) this_value else try primitiveObjectForAccess(ctx.runtime, global, this_value);
    const object = property_ops.expectObject(object_value) catch return null;
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
    defer bytes.deinit(ctx.runtime.memory.allocator);
    var index: usize = 0;
    while (index < length) : (index += 1) {
        if (index != 0) try bytes.append(ctx.runtime.memory.allocator, ',');
        const item = if (is_typed_array) blk: {
            if (!is_typed_method and index >= try arrayMethodTypedArrayLength(ctx.runtime, object, false)) break :blk core.JSValue.undefinedValue();
            break :blk try core.typed_array.typedArrayGetIndex(ctx.runtime, object, @intCast(index));
        } else blk: {
            const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
            defer key.deinit(ctx.runtime);
            break :blk try getValueProperty(ctx, output, global, object_value, key.atom, caller_function, caller_frame);
        };
        if (!item.isUndefined() and !item.isNull()) {
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
    if (this_value.isUndefined()) return try objectTagString(ctx.runtime, "Undefined");
    if (this_value.isNull()) return try objectTagString(ctx.runtime, "Null");
    const object_value = if (this_value.isObject()) this_value else try primitiveObjectForAccess(ctx.runtime, global, this_value);
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
        defer tag.deinit(ctx.runtime.memory.allocator);
        try value_ops.appendRawString(ctx.runtime, &tag, tag_value);
        return try objectTagString(ctx.runtime, tag.items);
    }
    return try objectTagString(ctx.runtime, builtin_tag);
}

pub fn objectTagString(rt: *core.JSRuntime, tag: []const u8) !core.JSValue {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try bytes.appendSlice(rt.memory.allocator, "[object ");
    try bytes.appendSlice(rt.memory.allocator, tag);
    try bytes.appendSlice(rt.memory.allocator, "]");
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
        core.class.ids.c_closure,
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
    const rt = try core.JSRuntime.create(std.testing.allocator);
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
    const index = core.array.arrayIndexFromAtom(&rt.atoms, atom_id) orelse return false;
    const string_value = string_data.asStringBody() orelse return false;
    return index < string_value.len();
}

// String unit/byte classification helpers (moved from the VM call runtime).

pub fn appendUtf16UnitsAsUtf8(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), units: []const u16) !void {
    return unicode_lib.appendUtf16UnitsAsUtf8(rt.memory.allocator, buffer, units);
}
pub fn appendAsciiUnits(rt: *core.JSRuntime, out: *std.ArrayList(u16), bytes: []const u8) !void {
    for (bytes) |byte| try out.append(rt.memory.allocator, byte);
}

pub fn isAsciiDigitUnit(unit: u16) bool {
    return unicode_lib.isAsciiDigitUnit(unit);
}

pub fn isAsciiDigitByte(byte: u8) bool {
    return unicode_lib.isAsciiDigitByte(byte);
}

pub fn isAsciiWordUnit(unit: u16) bool {
    return unicode_lib.isAsciiWordUnit(unit);
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

// qjs JS_STRING_LEN_MAX (quickjs.c:212): js_string_pad throws RangeError when the
// requested length exceeds it (quickjs.c:46331).
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
        const body = value.asStringBody() orelse return error.TypeError;
        try body.ensureFlat(rt);
        const data = body.resolveData();
        try self.appendUnits(data, 0, data.len());
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
                var i: usize = 0;
                while (i < chunk.len) : (i += 1) {
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
    if (this_value.isNull() or this_value.isUndefined()) return throwTypeErrorMessage(ctx, global, "null or undefined are forbidden");
    const string_value = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);

    // Resolve the source to its flat code-unit slice ONCE (no per-char UTF-16
    // copy of the whole source — qjs reads p->len from the JSString directly,
    // quickjs.c:46313-46314).
    const source = string_value.asStringBody() orelse return error.TypeError;
    try source.ensureFlat(ctx.runtime);
    const source_data = source.resolveData();
    const source_len = source_data.len();

    const max_length_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const target_length = try coercion_ops.toLengthIndex(ctx, output, global, max_length_value);
    if (target_length <= source_len) return string_value;

    const fill_value = if (args.len >= 2 and !args[1].isUndefined()) blk: {
        break :blk try toStringForAnnexB(ctx, output, global, args[1], caller_function, caller_frame);
    } else try value_ops.createStringValue(ctx.runtime, " ");

    const fill = fill_value.asStringBody() orelse return error.TypeError;
    try fill.ensureFlat(ctx.runtime);
    const fill_data = fill.resolveData();
    const fill_len = fill_data.len();
    if (fill_len == 0) return string_value;

    // qjs caps the result at JS_STRING_LEN_MAX (quickjs.c:46331-46334); without
    // this an out-of-range maxLength would attempt a multi-GiB allocation instead
    // of the spec/qjs RangeError.
    if (target_length > js_string_len_max) return throwRangeErrorMessage(ctx, global, "invalid string length");
    const pad_count = target_length - source_len;

    var buffer = StringBuffer{ .allocator = ctx.runtime.memory.allocator };
    defer buffer.deinit();
    try buffer.ensureCapacity(target_length);

    // padEnd: source first, then fill. padStart: fill first, then source.
    // (quickjs.c:46338-46356, magic 0 = padStart / 1 = padEnd; here 34 = start.)
    if (method_id == 35) try buffer.appendUnits(source_data, 0, source_len);

    var remaining = pad_count;
    while (remaining > 0) {
        const chunk = @min(remaining, fill_len);
        try buffer.appendUnits(fill_data, 0, chunk);
        remaining -= chunk;
    }

    if (method_id == 34) try buffer.appendUnits(source_data, 0, source_len);

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
    if (this_value.isNull() or this_value.isUndefined()) return throwTypeErrorMessage(ctx, global, "null or undefined are forbidden");
    const string_value = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);

    const form: unicode_lib.NormalizationForm = if (args.len == 0 or args[0].isUndefined()) .nfc else blk: {
        const form_value = try toStringForAnnexB(ctx, output, global, args[0], caller_function, caller_frame);
        var form_bytes = std.ArrayList(u8).empty;
        defer form_bytes.deinit(ctx.runtime.memory.allocator);
        try value_ops.appendRawString(ctx.runtime, &form_bytes, form_value);
        if (std.mem.eql(u8, form_bytes.items, "NFC")) break :blk unicode_lib.NormalizationForm.nfc;
        if (std.mem.eql(u8, form_bytes.items, "NFD")) break :blk unicode_lib.NormalizationForm.nfd;
        if (std.mem.eql(u8, form_bytes.items, "NFKC")) break :blk unicode_lib.NormalizationForm.nfkc;
        if (std.mem.eql(u8, form_bytes.items, "NFKD")) break :blk unicode_lib.NormalizationForm.nfkd;
        // js_string_normalize (quickjs.c:46635): unknown form -> RangeError
        // "bad normalization form".
        return throwRangeErrorMessage(ctx, global, "bad normalization form");
    };

    var input = std.ArrayList(u32).empty;
    defer input.deinit(ctx.runtime.memory.allocator);
    try appendUtf32FromStringValue(ctx.runtime, &input, string_value);
    const normalized_slice = try unicode_lib.normalizeAlloc(ctx.runtime.memory.allocator, input.items, form);
    defer ctx.runtime.memory.allocator.free(normalized_slice);

    var out = std.ArrayList(u16).empty;
    defer out.deinit(ctx.runtime.memory.allocator);
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
    if (this_value.isNull() or this_value.isUndefined()) return throwTypeErrorMessage(ctx, global, "null or undefined are forbidden");
    const lhs = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
    const rhs_input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const rhs = try toStringForAnnexB(ctx, output, global, rhs_input, caller_function, caller_frame);

    const lhs_nfc = try normalizedUtf32(ctx.runtime, lhs, .nfc);
    defer lhs_nfc.deinit();
    const rhs_nfc = try normalizedUtf32(ctx.runtime, rhs, .nfc);
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
    defer input.deinit(rt.memory.allocator);
    try appendUtf32FromStringValue(rt, &input, value);
    return .{
        .allocator = rt.memory.allocator,
        .slice = try unicode_lib.normalizeAlloc(rt.memory.allocator, input.items, form),
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
    if (this_value.isNull() or this_value.isUndefined()) return throwTypeErrorMessage(ctx, global, "null or undefined are forbidden");
    const string_value = if (this_value.isString())
        this_value
    else
        try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);

    var coerced: [2]core.JSValue = .{ core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    const count = @min(args.len, coerced.len);
    for (args[0..count], 0..) |arg, index| {
        coerced[index] = if (arg.isUndefined())
            core.JSValue.undefinedValue()
        else if (arg.isNumber())
            arg
        else
            try builtin_glue.toNumberLikeArgument(ctx, output, global, arg);
    }

    if (method_id == 1) {
        if (try fastLatin1Substring(ctx.runtime, string_value, coerced[0..count])) |value| return value;
    }
    if (method_id == 0) {
        const index = if (count >= 1) coerced[0] else core.JSValue.int32(0);
        return callStringCharAtBody(ctx, string_value, index);
    }
    if (method_id == 25) {
        return stringSubstr(ctx, output, global, string_value, coerced[0..count]);
    }
    return callStringBody(ctx, string_value, method_id, coerced[0..count]) catch |err| switch (err) {
        error.RangeError => return throwRangeErrorMessage(ctx, global, "invalid repeat count"),
        error.InvalidLength => return throwRangeErrorMessage(ctx, global, "invalid string length"),
        else => err,
    };
}

fn fastLatin1Substring(rt: *core.JSRuntime, string_value: core.JSValue, args: []const core.JSValue) !?core.JSValue {
    if (!string_value.isString() or args.len > 2) return null;
    const string = string_value.asStringBody() orelse return null;
    try string.ensureFlat(rt);
    const bytes = switch (string.resolveData()) {
        .latin1 => |latin1| latin1,
        .utf16 => return null,
    };
    const len: i64 = @intCast(string.len());
    const start_raw = if (args.len >= 1) int32OrUndefinedStringIndex(args[0]) orelse return null else 0;
    const end_raw = if (args.len >= 2 and !args[1].isUndefined()) int32OrUndefinedStringIndex(args[1]) orelse return null else len;
    const start: usize = @intCast(@max(@as(i64, 0), @min(start_raw, len)));
    const end: usize = @intCast(@max(@as(i64, 0), @min(end_raw, len)));
    const lo = @min(start, end);
    const hi = @max(start, end);
    if (lo == hi) {
        const empty = try rt.emptyString();
        return empty.value();
    }
    return (try core.string.String.createLatin1(rt, bytes[lo..hi])).value();
}

fn int32OrUndefinedStringIndex(value: core.JSValue) ?i64 {
    if (value.isUndefined()) return null;
    return if (value.asInt32()) |int_value| @as(i64, int_value) else null;
}

pub fn stringSubstr(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    string_value: core.JSValue,
    args: []const core.JSValue,
) !core.JSValue {
    var units = std.ArrayList(u16).empty;
    defer units.deinit(ctx.runtime.memory.allocator);
    try appendStringValueUnits(ctx.runtime, &units, string_value);

    const size = units.items.len;
    const start_number = if (args.len >= 1 and !args[0].isUndefined())
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
    const requested_len = if (args.len >= 2 and !args[1].isUndefined()) blk: {
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
    if (this_value.isNull() or this_value.isUndefined()) return error.TypeError;
    const string_value = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);

    var string_units = std.ArrayList(u16).empty;
    defer string_units.deinit(ctx.runtime.memory.allocator);
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
    defer out.deinit(ctx.runtime.memory.allocator);
    try appendAsciiUnits(ctx.runtime, &out, "<");
    try appendAsciiUnits(ctx.runtime, &out, tag);
    if (has_attr) {
        const value = try toStringForAnnexB(ctx, output, global, attr_value, caller_function, caller_frame);
        var attr_units = std.ArrayList(u16).empty;
        defer attr_units.deinit(ctx.runtime.memory.allocator);
        try appendStringValueUnits(ctx.runtime, &attr_units, value);

        try appendAsciiUnits(ctx.runtime, &out, " ");
        try appendAsciiUnits(ctx.runtime, &out, attr);
        try appendAsciiUnits(ctx.runtime, &out, "=\"");
        for (attr_units.items) |unit| {
            if (unit == '"') {
                try appendAsciiUnits(ctx.runtime, &out, "&quot;");
            } else {
                try out.append(ctx.runtime.memory.allocator, unit);
            }
        }
        try appendAsciiUnits(ctx.runtime, &out, "\"");
    }
    try appendAsciiUnits(ctx.runtime, &out, ">");
    try out.appendSlice(ctx.runtime.memory.allocator, string_units);
    try appendAsciiUnits(ctx.runtime, &out, "</");
    try appendAsciiUnits(ctx.runtime, &out, tag);
    try appendAsciiUnits(ctx.runtime, &out, ">");
    return (try core.string.String.createUtf16(ctx.runtime, out.items)).value();
}

//! String builtins, coercion/concatenation, and RegExp-string integration.
//!
//! String/value inputs are borrowed; returned JSValues and temporary concat or
//! capture values carry explicit ownership and must be freed or transferred.
//! The large alias wall keeps extracted RegExp, object, array, and error-stack
//! seams source-compatible; it does not make their implementations one module.
//! Preserve the measured `ctx`/`output`/`global`/caller-function/caller-frame
//! ABI and keep benchmark-hot string/RegExp arms out of shared cold bodies.

const std = @import("std");

const bytecode = @import("../bytecode.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const core = @import("../core/root.zig");
const method_ids = core.host_function.builtin_method_ids;
const string_id_lookup = core.host_function.builtin_method_id_lookup.string;
const regexp_ops = @import("regexp_ops.zig");
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
const object_ops = @import("object_ops.zig");
const RegExpCapture = call_runtime.RegExpCapture;
const ValueSliceRoot = array_ops.ValueSliceRoot;
const appendBacktraceFunctionName = exception_ops.appendBacktraceFunctionName;
const appendCallSiteFileName = exception_ops.appendCallSiteFileName;
const appendCallSiteFunctionName = exception_ops.appendCallSiteFunctionName;
const appendNamedCaptureSubstitution = regexp_ops.appendNamedCaptureSubstitution;
const arrayPrototypeFromGlobal = array_ops.arrayPrototypeFromGlobal;
const callValueOrBytecodeRoot = call_runtime.callValueOrBytecodeRoot;
const CallSite = call_site_mod.CallSite;
const clearRegExpLegacySlot = regexp_ops.clearRegExpLegacySlot;
const constructValueOrBytecode = call_runtime.constructValueOrBytecode;

const createIteratorResult = iterator_ops.createIteratorResult;
const createRegExpIndicesArray = array_ops.createRegExpIndicesArray;
const defineFreshNonIndexDataProperty = object_ops.defineFreshNonIndexDataProperty;
const populateRegExpGroupsFromCaptureValues = object_ops.populateRegExpGroupsFromCaptureValues;
const errorStackTraceLimit = exception_ops.errorStackTraceLimit;
const getValueProperty = object_ops.getValueProperty;
const isCallableValue = call_runtime.isCallableValue;
const isRegExpObservable = regexp_ops.isRegExpObservable;
const lengthIndexValue = array_ops.lengthIndexValue;
const objectFromValue = object_ops.objectFromValue;
const ownDataOrAutoInitPropertyValue = object_ops.ownDataOrAutoInitPropertyValue;
const primitiveObjectForAccess = object_ops.primitiveObjectForAccess;
const propertyAtomFromLengthIndex = object_ops.propertyAtomFromLengthIndex;
const proxyTargetIsCallableObject = object_ops.proxyTargetIsCallableObject;
const iteratorPrototype = object_ops.iteratorPrototype;
const regExpConstructCall = regexp_ops.regExpConstructCall;
const regExpExecGeneric = regexp_ops.regExpExecGeneric;
const regExpSpeciesConstructor = regexp_ops.regExpSpeciesConstructor;
const regExpFlagsAreFullUnicode = regexp_ops.regExpFlagsAreFullUnicode;
const setRegExpLastIndexZero = regexp_ops.setRegExpLastIndexZero;
const setValuePropertyStrict = object_ops.setValuePropertyStrict;

const throwRangeErrorMessage = exception_ops.throwRangeErrorMessage;
const throwTypeErrorMessage = exception_ops.throwTypeErrorMessage;
const toLengthIndex = value_ops.toLengthIndex;
const toLengthNumber = value_ops.toLengthNumber;
const toNumberLikeArgument = builtin_glue.toNumberLikeArgument;
const toPrimitiveForNumber = value_ops.toPrimitiveForNumber;
const toUint16CodeUnit = value_ops.toUint16CodeUnit;
const toUint32Number = value_ops.toUint32Number;
const uint32NumberValue = value_ops.uint32NumberValue;

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

pub const toPrimitiveForString = value_ops.toPrimitiveForString;

pub fn stringFunctionCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (args.len == 0) return value_ops.createStringValue(ctx.runtime, "");
    if (!args[0].is(.object)) return value_ops.toStringValue(ctx.runtime, args[0]);
    return toStringForAnnexB(ctx, output, global, args[0], caller_function, caller_frame);
}

// `RegExp` construction for string methods goes through the construct
// record with the realm's RegExp prototype.
const regexp_construct_ref = core.function.NativeBuiltinRef{
    .domain = .regexp,
    .id = @intFromEnum(method_ids.regexp.ConstructorMethod.construct),
};

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
    // A rope part, or a result long enough for `+` to start a tail buffer,
    // folds through the `+` path so `s = s.concat(x)` and `` s = `${s}x` ``
    // append in amortized O(|x|) like `s += x` instead of copying `s`.
    if (concatShouldFold(parts)) {
        for (parts[1..]) |part| parts[0] = try value_ops.addStringsOwned(rt, parts[0], part);
        return parts[0];
    }
    return (try core.string.String.createConcatParts(rt, parts)).value();
}

fn concatShouldFold(parts: []const core.JSValue) bool {
    var total: usize = 0;
    for (parts) |part| {
        if (part.ropeBody() != null) return true;
        total += (part.asStringBodyRaw() orelse return false).len();
    }
    return total >= core.string.String.tail_buffer_seed_len;
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
                const flags_atom = comptime core.atom.predefinedId("flags", .string).?;
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
        try rt.interrupt.pollNativeWork();
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

inline fn resolvedCodeUnitAt(data: core.string.String.ResolvedData, index: usize) u16 {
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
/// Needles at least this long use the linear-time Two-Way search; shorter ones
/// keep the first-unit scan, whose worst case is then bounded by 64n.
const two_way_min_needle = 64;

/// A window of a resolved string, optionally read back to front, so one
/// Two-Way implementation serves both indexOf and lastIndexOf.
const UnitView = struct {
    data: core.string.String.ResolvedData,
    base: usize,
    len: usize,
    reversed: bool,

    inline fn at(self: UnitView, index: usize) u16 {
        const offset = if (self.reversed) self.len - 1 - index else index;
        return resolvedCodeUnitAt(self.data, self.base + offset);
    }
};

/// Start and period of the maximal suffix of `x` under `<` (or `>` when
/// `greater`), as in Crochemore–Perrin's critical factorization.
fn twoWayMaximalSuffix(x: UnitView, comptime greater: bool) struct { start: isize, period: usize } {
    var ms: isize = -1;
    var j: usize = 0;
    var k: usize = 1;
    var p: usize = 1;
    while (j + k < x.len) {
        const a = x.at(j + k);
        const b = x.at(@as(usize, @intCast(ms + @as(isize, @intCast(k)))));
        if (if (greater) a > b else a < b) {
            j += k;
            k = 1;
            p = @intCast(@as(isize, @intCast(j)) - ms);
        } else if (a == b) {
            if (k != p) {
                k += 1;
            } else {
                j += p;
                k = 1;
            }
        } else {
            ms = @intCast(j);
            j += 1;
            k = 1;
            p = 1;
        }
    }
    return .{ .start = ms, .period = p };
}

/// First index of `x` in `y`: Two-Way string matching, O(|x| + |y|) time
/// and O(1) space. `x.len` is at least 1 and at most `y.len`.
fn twoWaySearch(y: UnitView, x: UnitView) ?usize {
    const m = x.len;
    const n = y.len;
    const less = twoWayMaximalSuffix(x, false);
    const more = twoWayMaximalSuffix(x, true);
    const ell: isize = @max(less.start, more.start);
    var period: usize = if (less.start > more.start) less.period else more.period;
    const ell_u: usize = @intCast(ell + 1);
    const periodic = period + ell_u <= m and periodic: {
        var i: usize = 0;
        while (i < ell_u) : (i += 1) {
            if (x.at(i) != x.at(i + period)) break :periodic false;
        }
        break :periodic true;
    };
    var pos: usize = 0;
    if (periodic) {
        var memory: isize = -1;
        while (pos + m <= n) {
            var i: usize = @intCast(@max(ell, memory) + 1);
            while (i < m and x.at(i) == y.at(i + pos)) i += 1;
            if (i >= m) {
                var back: isize = ell;
                while (back > memory and x.at(@intCast(back)) == y.at(@as(usize, @intCast(back)) + pos)) back -= 1;
                if (back <= memory) return pos;
                pos += period;
                memory = @as(isize, @intCast(m - period)) - 1;
            } else {
                pos += @intCast(@as(isize, @intCast(i)) - ell);
                memory = -1;
            }
        }
    } else {
        period = @max(ell_u, m - ell_u) + 1;
        while (pos + m <= n) {
            var i: usize = ell_u;
            while (i < m and x.at(i) == y.at(i + pos)) i += 1;
            if (i >= m) {
                var back: isize = ell;
                while (back >= 0 and x.at(@intCast(back)) == y.at(@as(usize, @intCast(back)) + pos)) back -= 1;
                if (back < 0) return pos;
                pos += period;
            } else {
                pos += @intCast(@as(isize, @intCast(i)) - ell);
            }
        }
    }
    return null;
}

fn stringIndexOfData(
    haystack: core.string.String.ResolvedData,
    needle: core.string.String.ResolvedData,
    from: usize,
) ?usize {
    const len1 = haystack.len();
    const len2 = needle.len();
    if (len2 == 0) return from;
    if (len2 >= two_way_min_needle) {
        if (from > len1 or len2 > len1 - from) return null;
        const y: UnitView = .{ .data = haystack, .base = from, .len = len1 - from, .reversed = false };
        const x: UnitView = .{ .data = needle, .base = 0, .len = len2, .reversed = false };
        return if (twoWaySearch(y, x)) |pos| from + pos else null;
    }
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
    const replace_atom = comptime core.atom.predefinedId("Symbol.replace", .symbol).?;
    const replacer = try getValueProperty(ctx, output, global, search_value, replace_atom, caller_function, caller_frame);
    if (replacer.is(.undefined_value) or replacer.is(.null_value)) return null;
    if (!isCallableValue(replacer)) return error.NotAFunction;
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

/// Format `"    at name (file:line:col)"` stack lines; `kind` selects a live
/// backtrace (with skip) vs a captured CallSite array. The public entry
/// points are `inline` wrappers that pass only `kind`.
noinline fn errorStackStringValue(
    ctx: *core.JSContext,
    global: ?*core.Object,
    skip: exception_ops.StackSkip,
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
            const limit = errorStackTraceLimit(realm);
            if (limit == 0) return value_ops.createStringValue(ctx.runtime, "");

            // Without a frame to skip to, only the `limit` innermost frames print.
            const frames = try ctx.snapshotBacktraceFrames(if (skip.active()) std.math.maxInt(usize) else limit);
            defer ctx.freeBacktraceFrameSnapshot(frames);
            var idx = frames.len;
            var skipping = skip.active();
            while (idx > 0) {
                idx -= 1;
                if (skipping) {
                    if (skip.endsAt(frames[idx])) skipping = false;
                    continue;
                }
                _ = exception_ops.resolveBacktraceFunctionName(ctx, &frames[idx]);
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
    // Frame names and filenames come from host paths, which need not be UTF-8.
    return value_ops.createStringValueLossy(ctx.runtime, bytes.items);
}

pub inline fn buildErrorStackStringValue(ctx: *core.JSContext, global: *core.Object, skip: exception_ops.StackSkip) !core.JSValue {
    return errorStackStringValue(ctx, global, skip, core.JSValue.undefinedValue(), 0, .live);
}

pub inline fn formatCapturedErrorStackStringValue(ctx: *core.JSContext, sites_value: core.JSValue, site_count: usize) !core.JSValue {
    return errorStackStringValue(ctx, null, .none, sites_value, site_count, .captured);
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
        const key = try object_ops.propertyAtomFromLengthIndex(ctx.runtime, index);
        defer key.deinit(ctx.runtime);
        const raw_part = try getValueProperty(ctx, output, global, raw, key.atom, caller_function, caller_frame);
        const raw_string = try toStringForAnnexB(ctx, output, global, raw_part, caller_function, caller_frame);
        try appendStringValueUnits(ctx.runtime, &out, raw_string);
        if (out.items.len > js_string_len_max) return error.InvalidStringLength;

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
        if (primitive.isBigInt()) return error.BigIntToNumber;
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
    if (!this_value.is(.object)) return error.NotAnObject;

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
    return regexp_ops.flagsStringValueFromBytecode(rt, object.regexpCompiledBytecode());
}

pub fn regExpSymbolSearch(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
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
) !core.JSValue {
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
) !core.JSValue {
    if (!this_value.is(.object)) return error.NotAnObject;
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
) !core.JSValue {
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
) !core.JSValue {
    if (!this_value.is(.object)) return error.NotAnObject;
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
    try setValuePropertyStrict(ctx, output, objectFromValue(try realm.get(rt)).?, try matcher.get(rt), core.atom.ids.lastIndex, lengthIndexValue(last_index), caller_function, caller_frame);

    try temporary.set(rt, (try regExpStringIteratorPrototype(ctx, objectFromValue(try realm.get(rt)).?)).value());
    try temporary.set(rt, (try core.Object.create(rt, core.class.ids.regexp_string_iterator, objectFromValue(try temporary.get(rt)).?)).value());
    const iterator = objectFromValue(try temporary.get(rt)).?;
    // No allocating step follows these owner-aware barrier writes.
    try iterator.setOptionalValueSlot(rt, iterator.iteratorTargetSlot(), try matcher.get(rt));
    try iterator.setOptionalValueSlot(rt, iterator.iteratorDataSlot(), try source.get(rt));
    iterator_ops.setRegExpStringIteratorFlags(iterator, .{ .global = global_flag, .unicode = unicode_flag });
    iterator.iteratorIndexSlot().* = regexp_iterator_active;
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
    const match_all_atom = comptime core.atom.predefinedId("Symbol.matchAll", .symbol).?;
    if (values[2].is(.object)) {
        if (try isRegExpObservable(ctx, output, objectFromValue(values[0]).?, values[2], caller_function, caller_frame)) {
            // check_regexp_g_flag: undefined/null flags
            // -> "cannot convert to object"; missing 'g' -> "regexp must have the 'g' flag".
            const flags_atom = comptime core.atom.predefinedId("flags", .string).?;
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
    values[2] = (try builtin_dispatch.callConstructRecord(ctx, output, objectFromValue(values[0]).?, null, regexp_construct_ref, ctx.classPrototypeObject(core.class.ids.regexp), &regexp_args, caller_function, caller_frame)) orelse return error.TypeError;
    values[3] = try getValueProperty(ctx, output, objectFromValue(values[0]).?, values[2], match_all_atom, caller_function, caller_frame);
    return callValueOrBytecodeRoot(ctx, output, objectFromValue(values[0]).?, values[2], values[3], &.{values[1]}, caller_function, caller_frame);
}

/// %RegExpStringIteratorPrototype%: one per realm (§22.2.9.2), cached in
/// the realm's class-prototype slot like the other iterator prototypes.
pub fn regExpStringIteratorPrototype(ctx: *core.JSContext, global: *core.Object) !*core.Object {
    if (ctx.classPrototypeObject(core.class.ids.regexp_string_iterator)) |cached| return cached;
    const rt = ctx.runtime;
    var values = [_]core.JSValue{ global.value(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    values[1] = (try iteratorPrototype(rt, objectFromValue(values[0]).?, "RegExp String Iterator")).value();
    values[2] = try core.function.nativeFunctionForGlobal(rt, objectFromValue(values[0]).?, "next", 0);
    objectFromValue(values[2]).?.setNativeBuiltinIdAndRecord(core.function.nativeBuiltinId(.iterator, @intFromEnum(method_ids.iterator.IntrinsicMethod.regexp_string_iterator_next)));
    try objectFromValue(values[1]).?.defineOwnProperty(rt, (comptime core.atom.predefinedId("next", .string)).?, core.Descriptor.data(values[2], .method));
    const object = objectFromValue(values[1]).?;
    try ctx.setClassPrototype(core.class.ids.regexp_string_iterator, object);
    return object;
}

pub fn regExpSymbolReplace(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (!this_value.is(.object)) return error.NotAnObject;
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
) !core.JSValue {
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
) !core.JSValue {
    if (!this_value.is(.object)) return error.NotAnObject;
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
        if ((try limit_input.get(rt)).isBigInt()) return error.BigIntToNumber;
        const number_value = try value_ops.toNumberValue(rt, try limit_input.get(rt));
        const number = value_ops.numberValue(number_value) orelse std.math.nan(f64);
        limit = toUint32Number(number);
    }
    if (limit != 0 and core.string.stringValueLen(try source.get(rt)) != 0) {
        if (try regExpSplitUnobservableLoop(ctx, objectFromValue(try realm.get(rt)).?, try receiver.get(rt), try splitter.get(rt), try source.get(rt), limit, unicode_matching)) |array| return array;
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
        try defineSplitValueElement(rt, objectFromValue(try out.get(rt)).?, out_index, try temporary.get(rt));
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
            try defineSplitValueElement(rt, objectFromValue(try out.get(rt)).?, out_index, try temporary.get(rt));
            out_index += 1;
            if (out_index >= limit) return out.get(rt);
        }
        pos = start;
    }

    const tail_start = @min(start, input_len);
    try temporary.set(rt, try stringSliceValue(rt, try source.get(rt), tail_start, input_len - tail_start));
    try defineSplitValueElement(rt, objectFromValue(try out.get(rt)).?, out_index, try temporary.get(rt));
    return out.get(rt);
}

/// Whether steps 19-25 of RegExp.prototype[@@split] (§22.2.6.14) are
/// unobservable for `splitter` apart from the array they produce: the splitter
/// is a sticky RegExp of this realm whose own `lastIndex` is a writable data
/// property and whose `exec` resolves, without running a getter, to this
/// realm's %RegExp.prototype.exec%. Its matcher must also read code points
/// exactly when AdvanceStringIndex does, so an unanchored search from q visits
/// the same start positions the spec loop does.
fn regExpSplitterLoopIsUnobservable(rt: *core.JSRuntime, global: *core.Object, splitter_value: core.JSValue, unicode_matching: bool) bool {
    const splitter = objectFromValue(splitter_value) orelse return false;
    if (splitter.class_id != core.class.ids.regexp) return false;
    if (!splitter.regexpLastIndexWritable()) return false;
    const program = splitter.regexpCompiledBytecode();
    if (program.len == 0 or splitter.regexpSource() == null) return false;
    const flags = regexp_ops.flagsFromBytecode(program);
    if (!flags.sticky or flags.fullUnicode() != unicode_matching) return false;

    if (!object_ops.regExpExecIsDefault(splitter)) return false;
    const exec_atom = comptime core.atom.predefinedId("exec", .string).?;
    // Legacy RegExp statics belong to the realm of the `exec` that ran.
    const prototype = splitter.getPrototype() orelse return false;
    const ctx = rt.contextForGlobal(global) orelse return false;
    if (ctx.classPrototypeObject(core.class.ids.regexp) != prototype) return false;
    const property_index = prototype.findProperty(exec_atom) orelse return false;
    return switch (prototype.propKindAt(property_index)) {
        .auto_init => true,
        .data => blk: {
            const exec_function = objectFromValue(prototype.propertyEntry(property_index).slot.data) orelse break :blk false;
            break :blk object_ops.objectRealmGlobal(exec_function) == global;
        },
        .accessor, .var_ref => false,
    };
}

/// The receiver's compiled program when it is exactly the splitter's program
/// without the sticky anchor (same source, same flags except 'y').
fn regExpSplitReceiverProgram(receiver_value: core.JSValue, splitter: *const core.Object) ?core.JSValue {
    const receiver = objectFromValue(receiver_value) orelse return null;
    if (receiver.class_id != core.class.ids.regexp) return null;
    const program_value = receiver.regexpCompiledBytecodeValue() orelse return null;
    const program = receiver.regexpCompiledBytecode();
    if (program.len == 0) return null;
    var expected = regexp_ops.flagsFromBytecode(splitter.regexpCompiledBytecode());
    expected.sticky = false;
    if (regexp_ops.flagsFromBytecode(program).bits() != expected.bits()) return null;
    const receiver_source = core.string.asFlat(receiver.regexpSource() orelse return null) orelse return null;
    const splitter_source = core.string.asFlat(splitter.regexpSource() orelse return null) orelse return null;
    if (!core.string.flatStringsEq(receiver_source, splitter_source)) return null;
    return program_value;
}

/// One unanchored search from `start`. Nothing here can collect, so the
/// borrowed input and program bodies stay valid for the whole match.
fn regExpSplitSearch(rt: *core.JSRuntime, source_value: core.JSValue, program: []const u8, start: usize, capture: []usize) regexp_ops.ExecError!regexp_ops.ExecResult {
    var borrow = core.runtime.NoGcScope{};
    borrow.activate(rt);
    defer borrow.deactivate();
    const data = core.string.asFlat(source_value).?.resolveData();
    return regexp_ops.execCaptureSlotsOnResolvedStringFromIndex(rt, .{ .bytecode = @constCast(program) }, data, start, capture);
}

/// RegExp.prototype[@@split] steps 19-25 without the per-position
/// Set(lastIndex)/Get(exec)/RegExpExec/Get(lastIndex) round trip, for a
/// splitter that `regExpSplitterLoopIsUnobservable` accepts. The first start
/// m >= q of an unanchored search is the first position the sticky loop would
/// match at, with the same captures, so the loop is replayed over search
/// results. The splitter's final `lastIndex` and the legacy RegExp statics
/// are left as the last RegExpBuiltinExec of the spec loop leaves them.
/// Returns null, having done nothing observable, when the fast loop does not
/// apply; the caller then runs the generic loop.
fn regExpSplitUnobservableLoop(
    ctx: *core.JSContext,
    global: *core.Object,
    receiver_value: core.JSValue,
    splitter_value: core.JSValue,
    string_value: core.JSValue,
    limit: u32,
    unicode_matching: bool,
) !?core.JSValue {
    if (!string_value.isString()) return null;
    const rt = ctx.runtime;
    if (!regExpSplitterLoopIsUnobservable(rt, global, splitter_value, unicode_matching)) return null;

    var owned_program: ?regexp_ops.Compiled = null;
    defer if (owned_program) |*compiled| compiled.deinit(rt.nativeAllocator());
    const borrowed_program = regExpSplitReceiverProgram(receiver_value, objectFromValue(splitter_value).?);
    if (borrowed_program == null) {
        const splitter_object = objectFromValue(splitter_value).?;
        var pattern = std.ArrayList(u8).empty;
        defer pattern.deinit(rt.nativeAllocator());
        try value_ops.appendValueString(rt, &pattern, splitter_object.regexpSource().?);
        var flags = regexp_ops.flagsFromBytecode(splitter_object.regexpCompiledBytecode());
        flags.sticky = false;
        var flag_bytes = std.ArrayList(u8).empty;
        defer flag_bytes.deinit(rt.nativeAllocator());
        try regexp_ops.appendCanonicalFlags(rt.nativeAllocator(), &flag_bytes, flags);
        owned_program = regexp_ops.compileWithRuntime(rt, pattern.items, flag_bytes.items) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
    }

    var roots = core.runtime.ExactValueRoots(6){};
    try roots.activate(rt);
    defer roots.deactivate();
    const realm = try roots.ref(0);
    const splitter = try roots.ref(1);
    const source = try roots.ref(2);
    const program = try roots.ref(3);
    const out = try roots.ref(4);
    const temporary = try roots.ref(5);
    try realm.set(rt, global.value());
    try splitter.set(rt, splitter_value);
    try source.set(rt, string_value);
    try program.set(rt, borrowed_program orelse core.JSValue.undefinedValue());
    core.string.ensureFlat(rt, source.readOnly(), source) catch |err| switch (err) {
        // The input was checked to be a string above.
        error.ExpectedString => std.debug.panic("regExpSplitUnobservableLoop input contract: {s}", .{@errorName(err)}),
        else => |other| return other,
    };
    try out.set(rt, (try core.Object.createArray(rt, arrayPrototypeFromGlobal(rt, objectFromValue(try realm.get(rt)).?))).value());

    const header: regexp_ops.Compiled = if (owned_program) |compiled| compiled else .{ .bytecode = @constCast(core.string.asFlat(try program.get(rt)).?.resolveData().latin1) };
    const alloc_count = header.allocCount();
    const capture_count = header.captureCount();
    var inline_capture_slots: [regexp_ops.small_exec_slots]usize = undefined;
    var inline_last_slots: [regexp_ops.small_exec_slots]usize = undefined;
    var heap_slots: []usize = &.{};
    defer if (heap_slots.len != 0) rt.nativeAllocator().free(heap_slots);
    var capture: []usize = undefined;
    var last_match: []usize = undefined;
    if (alloc_count <= inline_capture_slots.len) {
        capture = inline_capture_slots[0..alloc_count];
        last_match = inline_last_slots[0..alloc_count];
    } else {
        heap_slots = try rt.nativeAllocator().alloc(usize, alloc_count * 2);
        capture = heap_slots[0..alloc_count];
        last_match = heap_slots[alloc_count..];
    }

    const size = core.string.stringValueLenUnchecked(try source.get(rt));
    var matched = false;
    // lastIndex as the most recent RegExpBuiltinExec leaves it: the match end
    // after a success, 0 after a failure.
    var last_index: usize = 0;
    var out_index: u32 = 0;
    var p: usize = 0;
    var q: usize = 0;
    split: {
        while (q < size) {
            const program_bytes = if (owned_program) |compiled| compiled.bytecode else core.string.asFlat(try program.get(rt)).?.resolveData().latin1;
            const result = regExpSplitSearch(rt, try source.get(rt), program_bytes, q, capture) catch |err| switch (err) {
                error.BytecodeCorrupt => return null,
                // The runtime interrupt handler fired (host interrupt or
                // termination): uncatchable, as in the interpreter.
                error.Timeout => {
                    try exception_ops.throwInterrupted(ctx, objectFromValue(try realm.get(rt)).?);
                    unreachable;
                },
                else => |other| return other,
            };
            switch (result) {
                .match => {},
                .no_match, .out_of_range => {
                    last_index = 0;
                    break;
                },
                .not_available => return null,
            }
            const match_start = regexp_ops.captureSlotValue(capture[0]) orelse q;
            const match_end = regexp_ops.captureSlotValue(capture[1]) orelse match_start;
            // In full-Unicode mode a start inside a surrogate pair matches
            // from the pair's lead; the spec loop still reports position q.
            const position = @max(match_start, q);
            if (position >= size) {
                // Every sticky attempt in [q, size) fails.
                last_index = 0;
                break;
            }
            @memcpy(last_match, capture);
            matched = true;
            last_index = match_end;
            const end = @min(match_end, size);
            if (end == p) {
                q = advanceStringIndexValue(try source.get(rt), position, unicode_matching);
                continue;
            }

            try temporary.set(rt, try stringSliceValue(rt, try source.get(rt), p, position - p));
            try defineSplitValueElement(rt, objectFromValue(try out.get(rt)).?, out_index, try temporary.get(rt));
            out_index += 1;
            if (out_index >= limit) break :split;
            var capture_index: usize = 1;
            while (capture_index < capture_count) : (capture_index += 1) {
                if (regexp_ops.captureSlotValue(capture[capture_index * 2])) |capture_start| {
                    const capture_end = regexp_ops.captureSlotValue(capture[capture_index * 2 + 1]) orelse capture_start;
                    try temporary.set(rt, try stringSliceValue(rt, try source.get(rt), capture_start, capture_end - capture_start));
                } else {
                    try temporary.set(rt, core.JSValue.undefinedValue());
                }
                try defineSplitValueElement(rt, objectFromValue(try out.get(rt)).?, out_index, try temporary.get(rt));
                out_index += 1;
                if (out_index >= limit) break :split;
            }
            p = end;
            q = p;
        }
        try temporary.set(rt, try stringSliceValue(rt, try source.get(rt), p, size - p));
        try defineSplitValueElement(rt, objectFromValue(try out.get(rt)).?, out_index, try temporary.get(rt));
    }

    const last_index_value = lengthIndexValue(last_index);
    try regexp_ops.setRegExpLastIndexStrict(ctx, null, objectFromValue(try realm.get(rt)).?, try splitter.get(rt), objectFromValue(try splitter.get(rt)).?, last_index_value, null, null);
    if (matched) {
        const match_start = regexp_ops.captureSlotValue(last_match[0]) orelse 0;
        const match_end = regexp_ops.captureSlotValue(last_match[1]) orelse match_start;
        const found = RegExpMatch{
            .index = match_start,
            .len = match_end - match_start,
            .capture_slots = last_match[2 .. capture_count * 2],
            .capture_count = capture_count - 1,
        };
        try updateRegExpLegacyStaticsForMatch(rt, objectFromValue(try realm.get(rt)).?, try source.get(rt), &found, size);
    }
    return try out.get(rt);
}

fn advanceStringIndexValue(value: core.JSValue, index: usize, unicode: bool) usize {
    if (!unicode or index + 1 >= core.string.stringValueLen(value)) return index + 1;
    const first = core.string.stringValueCodeUnitAtUnchecked(value, index);
    if (!isHighSurrogateUnit(first)) return index + 1;
    const second = core.string.stringValueCodeUnitAtUnchecked(value, index + 1);
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
    const index_atom = comptime core.atom.predefinedId("index", .string).?;
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
        try defineSplitValueElement(rt, objectFromValue(try out.get(rt)).?, count, try temporary.get(rt));
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
        try self.runtime.registerRootProvider(self.provider());
        self.registered = true;
    }

    fn deactivate(self: *ReplaceMatchRoots) void {
        if (!self.registered) return;
        self.runtime.unregisterRootProvider(self.provider());
        self.registered = false;
    }
};

/// The fast path and the per-match helpers it does not need while a replacer
/// callback runs (`regExpReplaceFast`, `captureReplaceMatch`,
/// `getSubstitutionString`, `getRegExpFlagsString`) are `noinline`, so this
/// frame -- live under every callback -- does not reserve their locals.
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
            if (object_ops.regExpIsStandard(rx_object)) {
                if (try regExpReplaceFast(ctx, output, objectFromValue(values[0]).?, values[1], values[2], values[4], caller_function, caller_frame)) |res| {
                    return res;
                }
            }
        }
    }

    values[5] = try getRegExpFlagsString(ctx, output, objectFromValue(values[0]).?, values[1], caller_function, caller_frame);
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
            return error.InvalidExecResult;
        }
        // Step 11: collect the results; each one's fields are read in step 14,
        // interleaved with its replacement. Only a global replace reads
        // ToString(result[0]) here, to advance past an empty match.
        try matches.append(ctx.runtime.nativeAllocator(), .{
            .result = values[6],
            .matched = core.JSValue.undefinedValue(),
            .index = 0,
            .captures = &.{},
            .groups = core.JSValue.undefinedValue(),
        });
        if (!is_global) break;
        const first = try getValueProperty(ctx, output, objectFromValue(values[0]).?, values[6], core.Atom.taggedInt(0), caller_function, caller_frame);
        matches.items[matches.items.len - 1].matched = try toStringForAnnexB(ctx, output, objectFromValue(values[0]).?, first, caller_function, caller_frame);
        if (isEmptyStringValue(ctx.runtime, matches.items[matches.items.len - 1].matched)) {
            values[5] = try getValueProperty(ctx, output, objectFromValue(values[0]).?, values[1], core.atom.ids.lastIndex, caller_function, caller_frame);
            const next = try advanceStringIndexNumber(ctx, output, objectFromValue(values[0]).?, values[2], values[5], full_unicode);
            try setValuePropertyStrict(ctx, output, objectFromValue(values[0]).?, values[1], core.atom.ids.lastIndex, next, caller_function, caller_frame);
        }
    }
    if (matches.items.len == 0) return values[2];

    const replacement_is_empty = !functional_replace and (core.string.stringValueLen(values[4]) == 0);
    const replacement_is_literal = !functional_replace and !replacement_is_empty and !stringValueContainsUnitByte(values[4], '$');

    var source_units = std.ArrayList(u16).empty;
    defer source_units.deinit(ctx.runtime.nativeAllocator());
    try appendStringValueUnits(ctx.runtime, &source_units, values[2]);

    var out = std.ArrayList(u16).empty;
    defer out.deinit(ctx.runtime.nativeAllocator());
    var next_source_position: usize = 0;
    for (matches.items) |*slot| {
        // Step 14.a-k: this result's length, 0, index, captures and groups.
        slot.* = try captureReplaceMatch(ctx, output, objectFromValue(values[0]).?, slot.result, values[2], caller_function, caller_frame);
        const match = slot.*;
        const matched_len = core.string.stringValueLen(match.matched);
        const position = @min(match.index, source_units.items.len);

        // Step 14.l: the replacement is computed for every result; only its
        // use (step 14.o) depends on the position.
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
        if (position < next_source_position) continue;
        try ensureStringRoom(out.items.len, position - next_source_position);
        try out.appendSlice(ctx.runtime.nativeAllocator(), source_units.items[next_source_position..position]);
        if (!replacement_is_empty) {
            if (replacement.isString()) try ensureStringRoom(out.items.len, core.string.stringValueLenUnchecked(replacement));
            try appendStringValueUnits(ctx.runtime, &out, replacement);
        }
        // Step 15.o: unclamped, so a match reaching past the end suppresses
        // every later result (`position < nextSourcePosition`).
        next_source_position = position + matched_len;
    }
    if (next_source_position < source_units.items.len) {
        try out.appendSlice(ctx.runtime.nativeAllocator(), source_units.items[next_source_position..]);
    }
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
pub noinline fn regExpReplaceFast(
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
    if (!regexp_ops.regExpLastIndexCanSkipCoercion(rx_object)) return null;
    const cached_bytecode = rx_object.regexpCompiledBytecode();
    if (cached_bytecode.len == 0) return null;
    var compiled = regexp_ops.Compiled{ .bytecode = @constCast(cached_bytecode) };
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
    var inline_capture_slots: [regexp_ops.small_exec_slots]usize = undefined;
    var heap_capture_slots: []usize = &.{};
    defer if (heap_capture_slots.len != 0) ctx.runtime.nativeAllocator().free(heap_capture_slots);
    const capture = if (alloc_count <= inline_capture_slots.len)
        inline_capture_slots[0..alloc_count]
    else capture: {
        heap_capture_slots = try ctx.runtime.nativeAllocator().alloc(usize, alloc_count);
        break :capture heap_capture_slots;
    };

    // The last successful match, kept for the legacy RegExp statics that
    // every RegExpBuiltinExec match records; applied once borrowing ends.
    var inline_last_slots: [regexp_ops.small_exec_slots]usize = undefined;
    var heap_last_slots: []usize = &.{};
    defer if (heap_last_slots.len != 0) ctx.runtime.nativeAllocator().free(heap_last_slots);
    const last_match = if (alloc_count <= inline_last_slots.len)
        inline_last_slots[0..alloc_count]
    else last: {
        heap_last_slots = try ctx.runtime.nativeAllocator().alloc(usize, alloc_count);
        break :last heap_last_slots;
    };
    var matched = false;

    var b = StringBuffer{ .allocator = ctx.runtime.nativeAllocator() };
    defer b.deinit();

    // lastIndex: reset to 0 above for global regexps. Sticky
    // (non-global) reads it; otherwise matching starts at 0 (qjs js_regexp_replace).
    var last_index: usize = 0;
    if (!is_global and is_sticky) {
        last_index = regexp_ops.regexpLastIndex(rx_object);
    }
    var next_src: usize = 0;
    while (true) {
        if (last_index > source_len) {
            if (is_global or is_sticky) try setRegExpLastIndexZero(ctx.runtime, rx_object);
            break;
        }
        const result = regexp_ops.execCaptureSlotsOnResolvedStringFromIndex(ctx.runtime, compiled, sp_data, last_index, capture) catch |err| switch (err) {
            error.BytecodeCorrupt => return null,
            error.Timeout => {
                try exception_ops.throwInterrupted(ctx, global);
                unreachable;
            },
            else => return err,
        };
        if (result != .match) {
            if (is_global or is_sticky) try setRegExpLastIndexZero(ctx.runtime, rx_object);
            break;
        }
        @memcpy(last_match, capture);
        matched = true;
        const match_start = regexp_ops.captureSlotValue(capture[0]) orelse 0;
        const match_end = regexp_ops.captureSlotValue(capture[1]) orelse match_start;
        if (next_src < match_start) try b.appendUnits(sp_data, next_src, match_start - next_src);
        if (rep_data.len() != 0) {
            try appendRegExpSubstitutionFromSlots(&b, sp_data, match_start, match_end, capture, capture_count, rep_data);
        }
        next_src = match_end;
        if (!is_global) {
            if (is_sticky) {
                const next_value = lengthIndexValue(match_end);
                try regexp_ops.setRegExpLastIndexStrict(ctx, output, objectFromValue(try realm.get(rt)).?, try regexp.get(rt), rx_object, next_value, caller_function, caller_frame);
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
    if (matched) {
        const match_start = regexp_ops.captureSlotValue(last_match[0]) orelse 0;
        const match_end = regexp_ops.captureSlotValue(last_match[1]) orelse match_start;
        const found = RegExpMatch{
            .index = match_start,
            .len = match_end - match_start,
            .capture_slots = last_match[2 .. capture_count * 2],
            .capture_bytecode = compiled.bytecode,
            .capture_count = capture_count - 1,
        };
        try updateRegExpLegacyStaticsForMatch(rt, objectFromValue(try realm.get(rt)).?, try source.get(rt), &found, source_len);
    }
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
            .latin1 => |bytes| for (bytes) |byte| {
                try rt.interrupt.pollNativeWork();
                try out.append(rt.nativeAllocator(), byte);
            },
            .utf16 => |units| {
                try out.appendSlice(rt.nativeAllocator(), units);
                try rt.interrupt.pollNativeBulkWork(units.len * 2);
            },
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

pub noinline fn getRegExpFlagsString(
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

pub noinline fn captureReplaceMatch(
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
        // Violations are engine contract bugs, not JavaScript exception_ops.
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
    // RegExp.prototype[@@replace] step 14: length, then "0", then "index".
    try temporary.set(rt, try getValueProperty(ctx, output, objectFromValue(try realm.get(rt)).?, try result_root.get(rt), core.atom.ids.length, caller_function, caller_frame));
    const length = try toLengthIndex(ctx, output, objectFromValue(try realm.get(rt)).?, try temporary.get(rt));

    try matched_root.set(rt, try getValueProperty(ctx, output, objectFromValue(try realm.get(rt)).?, try result_root.get(rt), core.Atom.taggedInt(0), caller_function, caller_frame));
    try matched_root.set(rt, try toStringForAnnexB(ctx, output, objectFromValue(try realm.get(rt)).?, try matched_root.get(rt), caller_function, caller_frame));

    const index_atom = comptime core.atom.predefinedId("index", .string).?;
    try temporary.set(rt, try getValueProperty(ctx, output, objectFromValue(try realm.get(rt)).?, try result_root.get(rt), index_atom, caller_function, caller_frame));
    const string_len = core.string.stringValueLen(try source_root.get(rt));
    const index = @min(try toLengthIndex(ctx, output, objectFromValue(try realm.get(rt)).?, try temporary.get(rt)), string_len);
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

    const groups_atom = comptime core.atom.predefinedId("groups", .string).?;
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

pub noinline fn getSubstitutionString(
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
        return error.NullishToObject
    else if (values[1].is(.object))
        values[1]
    else
        try primitiveObjectForAccess(ctx.runtime, objectFromValue(values[0]).?, values[1]);

    // Only `$\`` and `$'` read the subject. Copying it for every match made a
    // global replace O(matches * length).
    var source = std.ArrayList(u16).empty;
    defer source.deinit(ctx.runtime.nativeAllocator());
    var source_loaded = false;
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
                try ensureStringRoom(out.items.len, matched.items.len);
                try out.appendSlice(ctx.runtime.nativeAllocator(), matched.items);
                index += 1;
            },
            '`' => {
                if (!source_loaded) try appendStringValueUnits(ctx.runtime, &source, values[2]);
                source_loaded = true;
                const head = source.items[0..@min(match.index, source.items.len)];
                try ensureStringRoom(out.items.len, head.len);
                try out.appendSlice(ctx.runtime.nativeAllocator(), head);
                index += 1;
            },
            '\'' => {
                if (!source_loaded) try appendStringValueUnits(ctx.runtime, &source, values[2]);
                source_loaded = true;
                const tail_start = @min(source.items.len, match.index + matched.items.len);
                try ensureStringRoom(out.items.len, source.items.len - tail_start);
                try out.appendSlice(ctx.runtime.nativeAllocator(), source.items[tail_start..]);
                index += 1;
            },
            '0'...'9' => {
                const capture = replacementCaptureUnits(match, replacement.items, &index) orelse {
                    try out.append(ctx.runtime.nativeAllocator(), '$');
                    continue;
                };
                if (!capture.is(.undefined_value)) {
                    if (capture.isString()) try ensureStringRoom(out.items.len, core.string.stringValueLenUnchecked(capture));
                    try appendStringValueUnits(ctx.runtime, &out, capture);
                }
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
    const second: ?u16 = if (index.* + 2 < replacement.len) replacement[index.* + 2] else null;
    const ref = parseCaptureRef(replacement[index.* + 1], second, match.captures.len) orelse return null;
    index.* += ref.consumed;
    return match.captures[ref.group - 1];
}

/// GetSubstitution's `$n` / `$nn`: the one-based group named by the digits
/// after a `$` (`first`, then `second` when present) among `group_count`
/// groups, and how many digits it consumes. `null` means a literal `$`.
const CaptureRef = struct { group: usize, consumed: usize };
fn parseCaptureRef(first: u16, second: ?u16, group_count: usize) ?CaptureRef {
    if (!isAsciiDigitUnit(first)) return null;
    const second_digit: ?usize = if (second) |unit| (if (isAsciiDigitUnit(unit)) @as(usize, unit - '0') else null) else null;
    if (first == '0') {
        const group = second_digit orelse return null;
        if (group == 0 or group > group_count) return null;
        return .{ .group = group, .consumed = 2 };
    }
    const single: usize = first - '0';
    if (second_digit) |digit| {
        const two = single * 10 + digit;
        if (two <= group_count) return .{ .group = two, .consumed = 2 };
    }
    if (single > group_count) return null;
    return .{ .group = single, .consumed = 1 };
}

fn parseCaptureRefData(rep_data: core.string.String.ResolvedData, index: usize, capture_count: usize) ?CaptureRef {
    // `capture_count` includes group 0.
    if (capture_count <= 1) return null;
    const second: ?u16 = if (index + 2 < rep_data.len()) resolvedCodeUnitAt(rep_data, index + 2) else null;
    return parseCaptureRef(resolvedCodeUnitAt(rep_data, index + 1), second, capture_count - 1);
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
                if (parseCaptureRefData(rep_data, index, capture_count)) |ref| {
                    index += ref.consumed;
                    if (regexp_ops.captureSlotValue(capture[2 * ref.group])) |cstart| {
                        const cend = regexp_ops.captureSlotValue(capture[2 * ref.group + 1]) orelse cstart;
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

/// Route a String method *body* through the record table's func-object-free
/// arm. `decoded_method_id` is the legacy selector the string bodies switch
/// on; it is re-encoded to its `PrototypeMethod` record id so the dispatch
/// lands on `stringCall`, whose `func_obj == null` arm runs `methodCall` (or,
/// for `charAt`, `charAtValue`) directly. `string_value` must already be the
/// ToString'd receiver and `args` must already be coerced; the bodies accept
/// only a string primitive receiver.
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
    // `isRegExpObservable`) and the BOTH bodies (concat) also stay in exec.
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
    return callStringBody(ctx, string_value, method_id, args);
}
pub fn appendUtf32FromStringValue(rt: *core.JSRuntime, out: *std.ArrayList(u32), value: core.JSValue) !void {
    var units = std.ArrayList(u16).empty;
    defer units.deinit(rt.nativeAllocator());
    try appendStringValueUnits(rt, &units, value);
    var index: usize = 0;
    while (index < units.items.len) {
        try rt.interrupt.pollNativeWork();
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
        if (try isRegExpObservable(ctx, output, objectFromValue(values[0]).?, values[2], caller_function, caller_frame))
            return throwTypeErrorMessage(ctx, objectFromValue(values[0]).?, "regexp not supported");
    }
    values[2] = try toStringForAnnexB(ctx, output, objectFromValue(values[0]).?, values[2], caller_function, caller_frame);
    if (!values[3].is(.undefined_value)) {
        values[3] = try toPrimitiveForNumber(ctx, output, objectFromValue(values[0]).?, values[3]);
        if (values[3].isBigInt()) return error.BigIntToNumber;
        const number_value = try value_ops.toNumberValue(ctx.runtime, values[3]);
        values[3] = value_ops.numberToValue(value_ops.numberValue(number_value) orelse std.math.nan(f64));
    }
    return callStringBody(ctx, values[1], method_id, values[2..][0..if (args.len >= 2) @as(usize, 2) else 1]);
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
    return stringMatchOrSearch("Symbol.search", ctx, output, global, this_value, args, caller_function, caller_frame);
}

pub fn stringIteratorCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (this_value.is(.null_value) or this_value.is(.undefined_value)) return error.NotAnObject;
    const string_value = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
    const prototype = try stringIteratorPrototypeFromContext(ctx, global);
    const object = try core.Object.create(ctx.runtime, core.class.ids.string_iterator, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, object.gcHeader());
    try object.setOptionalValueSlot(ctx.runtime, object.iteratorTargetSlot(), string_value);
    object.iteratorIndexSlot().* = 0;
    return object.value();
}

pub fn stringIteratorPrototypeFromContext(ctx: *core.JSContext, global: *core.Object) !*core.Object {
    if (ctx.classPrototypeObject(core.class.ids.string_iterator)) |cached| return cached;
    const object = try iteratorPrototype(ctx.runtime, global, "String Iterator");
    errdefer core.Object.destroyFromHeader(ctx.runtime, object.gcHeader());
    try builtin_glue.defineNativeDataMethodWithNativeId(ctx.runtime, global, object, core.atom.ids.next, 0, core.function.nativeBuiltinId(.string, @intFromEnum(method_ids.string.PrototypeMethod.iterator_next)));

    // %StringIteratorPrototype% inherits @@iterator from %IteratorPrototype%.
    // An own copy would fail the ES6 String iterator prototype-chain test.

    try ctx.setClassPrototype(core.class.ids.string_iterator, object);
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
    return stringMatchOrSearch("Symbol.match", ctx, output, global, this_value, args, caller_function, caller_frame);
}

/// String.prototype.match / search (§22.1.3.13, §22.1.3.21): an existing
/// @@match/@@search of the argument gets the original receiver; ToString(this)
/// only runs after that lookup falls through.
fn stringMatchOrSearch(
    comptime symbol_name: []const u8,
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
    if (try callStringWellKnownMethod(ctx, output, global, this_value, regexp, symbol_name, caller_function, caller_frame)) |value| return value;
    const string_value = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
    return try stringRegExpCreateAndInvoke(ctx, output, global, string_value, regexp, symbol_name, caller_function, caller_frame);
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
    // A RegExp whose @@match/@@search was removed is ToStringed too.
    const pattern = if (regexp.is(.object))
        try toStringForAnnexB(ctx, output, global, regexp, caller_function, caller_frame)
    else
        regexp;
    const rx = try regExpConstructCall(ctx, output, global, objectFromValue(constructor), constructor, &.{pattern}, caller_function, caller_frame);
    if (try callStringWellKnownMethod(ctx, output, global, string_value, rx, symbol_name, caller_function, caller_frame)) |value| return value;
    // Mirrors js_string_match: the tail is
    // JS_InvokeFree(ctx, rx, atom, 1, &S) which throws TypeError when the
    // freshly constructed rx has no callable @@match/@@search; there is no
    // silent builtin-match fallback.
    return error.NotAFunction;
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
    if (!candidate.is(.object)) return null;
    const symbol_atom = core.atom.predefinedId(symbol_name, .symbol) orelse return error.TypeError;
    const method = try getValueProperty(ctx, output, global, candidate, symbol_atom, caller_function, caller_frame);
    if (method.is(.undefined_value) or method.is(.null_value)) return null;
    if (!isCallableValue(method)) return error.NotAFunction;
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
        const split_atom = comptime core.atom.predefinedId("Symbol.split", .symbol).?;
        const splitter = try getValueProperty(ctx, output, global, separator, split_atom, caller_function, caller_frame);
        if (!splitter.is(.undefined_value) and !splitter.is(.null_value)) {
            if (!isCallableValue(splitter)) return error.NotAFunction;
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
        if (primitive.isBigInt()) return error.BigIntToNumber;
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
        const capture_start = regexp_ops.captureSlotValue(self.capture_slots[slot_index]);
        if (capture_start) |start| {
            const end = regexp_ops.captureSlotValue(self.capture_slots[slot_index + 1]) orelse start;
            return .{ .start = start, .len = end - start };
        }
        return .{ .start = 0, .len = 0, .undefined = true };
    }

    pub inline fn captureNameAt(self: *const RegExpMatch, capture_index: usize) ?[]const u8 {
        std.debug.assert(capture_index < self.capture_count);
        if (!self.has_named_captures) return null;
        return regexp_ops.groupName(self.capture_bytecode, capture_index + 1);
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

pub fn defineSplitValueElement(rt: *core.JSRuntime, object: *core.Object, index: u32, value: core.JSValue) !void {
    // The core mutation API borrows raw owner/value pointers through storage
    // growth. A read-only root does not rewrite them: explicitly pin the raw
    // object addresses until this call returns; strings are stable carriers.
    const values = [_]core.JSValue{ object.value(), value };
    const slices = [_]core.runtime.ValueRootSlice{.{ .borrowed = &values }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    var owner_pin = try core.runtime.NativePin.initHeader(rt, object.gcHeader());
    defer owner_pin.deinit();
    var value_pin = try core.runtime.NativePin.initValue(rt, value);
    defer if (value_pin) |*held| held.deinit();
    const atom_id = core.Atom.taggedInt(index);
    if (try object.appendDenseArrayDefineIndex(rt, index, atom_id, value)) return;
    try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(value, .all));
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
        const indices_atom = comptime core.atom.predefinedId("indices", .string).?;
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
        clearRegExpLegacySlot(&legacy.left_context);
    }

    if (has_right) {
        try replaceRegExpLegacySlot(rt, owner, &legacy.right_context, values[5]);
    } else {
        clearRegExpLegacySlot(&legacy.right_context);
    }

    if (last_capture_value != null) {
        try replaceRegExpLegacySlot(rt, owner, &legacy.last_paren, values[3]);
    } else if (legacy.last_paren != null) {
        clearRegExpLegacySlot(&legacy.last_paren);
    }

    var slot_index: usize = 0;
    while (slot_index < @max(previous_capture_slot_count, next_capture_slot_count)) : (slot_index += 1) {
        if (slot_index < next_capture_slot_count) {
            if (captures[slot_index] != null) {
                try replaceRegExpLegacySlot(rt, owner, &legacy.captures[slot_index], values[6 + slot_index]);
                continue;
            }
        }
        if (legacy.captures[slot_index] != null) clearRegExpLegacySlot(&legacy.captures[slot_index]);
    }
    legacy.capture_slot_count = @intCast(next_capture_slot_count);
}

pub fn updateRegExpLegacyStaticsForMatch(rt: *core.JSRuntime, global: *core.Object, input_value: core.JSValue, found: *const RegExpMatch, input_len: usize) !void {
    if (try updateRegExpLegacyStaticsLazyForMatch(rt, global, input_value, found, input_len)) return;

    // Slots 3..11 hold $1..$9; slot 12 holds `lastParen`, the LAST capture
    // group's value (undefined when that group did not participate).
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
        const is_last = capture_index + 1 == found.capture_count;
        if (capture_index >= 9 and !is_last) continue;
        const slice = try stringSliceValue(rt, values[1], capture.start, capture.len);
        if (capture_index < 9) values[3 + capture_index] = slice;
        if (is_last) values[12] = slice;
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
        // lastParen is the last group's value, not the last participating one.
        if (capture_index + 1 == found.capture_count) encoded_last_paren = encoded;
    }

    const legacy = global.installedRealmRegExpLegacyStatics(rt) orelse
        (try global.ensureInstalledRealmRegExpLegacyStatics(rt)) orelse return true;
    const already_lazy = legacy.lazy_no_capture_match;
    const previous_capture_slot_count: usize = legacy.capture_slot_count;
    const next_capture_slot_count = @min(found.capture_count, legacy.captures.len);

    try replaceRegExpLegacySlot(rt, global, &legacy.input, input_value);
    if (!already_lazy) {
        clearRegExpLegacySlot(&legacy.last_match);
        clearRegExpLegacySlot(&legacy.left_context);
        clearRegExpLegacySlot(&legacy.right_context);
    }

    if (encoded_last_paren) |value| {
        try replaceRegExpLegacySlot(rt, global, &legacy.last_paren, value);
    } else if (legacy.last_paren != null) {
        clearRegExpLegacySlot(&legacy.last_paren);
    }

    var slot_index: usize = 0;
    while (slot_index < @max(previous_capture_slot_count, next_capture_slot_count)) : (slot_index += 1) {
        if (slot_index < next_capture_slot_count and encoded_captures[slot_index] != null) {
            const value = encoded_captures[slot_index].?;
            try replaceRegExpLegacySlot(rt, global, &legacy.captures[slot_index], value);
        } else if (legacy.captures[slot_index] != null) {
            clearRegExpLegacySlot(&legacy.captures[slot_index]);
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

pub const combinedSurrogateCodePoint = unicode_lib.codePointFromSurrogatePair;

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

pub fn getStringPrototypeMethodId(function_object: *core.Object) ?u32 {
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
        if (radix_primitive.isBigInt()) return error.BigIntToNumber;
        if (radix_primitive.is(.symbol)) return error.SymbolToNumber;
        const radix_value = try value_ops.toNumberValue(ctx.runtime, radix_primitive);
        const radix_number = value_ops.numberValue(radix_value) orelse return error.InvalidRadix;
        const integer = @trunc(radix_number);
        if (!(integer >= 2 and integer <= 36)) return error.InvalidRadix;
        break :blk @intFromFloat(integer);
    };
    var bigint = try core.value_format.BigIntView.init(ctx.runtime.nativeAllocator(), primitive);
    defer bigint.deinit();
    const text = try bigint.int.formatBaseAlloc(ctx.runtime.nativeAllocator(), radix, ctx.runtime);
    defer ctx.runtime.nativeAllocator().free(text);
    return value_ops.createStringValue(ctx.runtime, text);
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
    if (value.is(.symbol)) return error.SymbolToString;
    const string_value = if (value.isString())
        value
    else
        try toStringForAnnexB(ctx, output, global, value, caller_function, caller_frame);

    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(ctx.runtime.nativeAllocator());
    try value_ops.appendRawString(ctx.runtime, &buffer, string_value);
    return buffer.toOwnedSlice(ctx.runtime.nativeAllocator());
}

pub fn thrownValueMatchesConstructor(rt: *core.JSRuntime, thrown_value: core.JSValue, expected_name: []const u8) !bool {
    const thrown_object = core.value_semantics.objectFromValue(thrown_value) orelse return false;
    const ctor_value = try thrown_object.getProperty(core.atom.ids.constructor);
    if (core.value_semantics.objectFromValue(ctor_value)) |ctor_object| {
        const name = try call_mod.nativeFunctionNameForVm(rt, ctor_object);
        defer rt.nativeAllocator().free(name);
        if (std.mem.eql(u8, name, expected_name)) return true;
    }
    const name_value = try thrown_object.getProperty(core.atom.ids.name);
    if (!name_value.isString()) return false;
    var name_bytes = std.ArrayList(u8).empty;
    defer name_bytes.deinit(rt.nativeAllocator());
    try value_ops.appendRawString(rt, &name_bytes, name_value);
    return std.mem.eql(u8, name_bytes.items, expected_name);
}

pub fn uint8ArrayStringBytes(rt: *core.JSRuntime, value: core.JSValue) !std.ArrayList(u8) {
    if (!value.isString()) return error.NotAString;
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
    // The spec's iterator is a generator: `next` from inside `exec` finds it
    // running, and an abrupt completion finishes it. Allocation failure is
    // not a completion: it leaves the iterator to be retried.
    switch (iterator.iteratorIndexSlot().*) {
        regexp_iterator_active => {},
        regexp_iterator_running => {
            _ = try throwTypeErrorMessage(ctx, global, "RegExp String Iterator is already running");
            unreachable;
        },
        else => return try createIteratorResult(rt, objectFromValue(try realm.get(rt)).?, core.JSValue.undefinedValue(), true),
    }
    iterator.iteratorIndexSlot().* = regexp_iterator_running;
    errdefer |err| if (self.get(rt)) |value| {
        objectFromValue(value).?.iteratorIndexSlot().* = if (err == error.OutOfMemory) regexp_iterator_active else regexp_iterator_done;
    } else |_| {};
    try regexp.set(rt, (iterator.iteratorTargetSlot().*) orelse {
        const done_result = try createIteratorResult(rt, objectFromValue(try realm.get(rt)).?, core.JSValue.undefinedValue(), true);
        objectFromValue(try self.get(rt)).?.iteratorIndexSlot().* = regexp_iterator_done;
        return done_result;
    });
    try source.set(rt, iterator.iteratorData() orelse {
        const done_result = try createIteratorResult(rt, objectFromValue(try realm.get(rt)).?, core.JSValue.undefinedValue(), true);
        objectFromValue(try self.get(rt)).?.iteratorIndexSlot().* = regexp_iterator_done;
        return done_result;
    });
    // These snapshots must survive even if a reentrant call clears the
    // iterator's target/data slots before the outer operation resumes.
    try result.set(rt, try regExpExecGeneric(ctx, output, objectFromValue(try realm.get(rt)).?, try regexp.get(rt), try source.get(rt), caller_function, caller_frame));
    if ((try result.get(rt)).is(.null_value)) {
        const done_result = try createIteratorResult(rt, objectFromValue(try realm.get(rt)).?, core.JSValue.undefinedValue(), true);
        iterator = objectFromValue(try self.get(rt)).?;
        iterator.iteratorIndexSlot().* = regexp_iterator_done;
        iterator.clearOptionalValueSlot(rt, iterator.iteratorTargetSlot());
        iterator.clearOptionalValueSlot(rt, iterator.iteratorDataSlot());
        return done_result;
    }
    iterator = objectFromValue(try self.get(rt)).?;
    const flags = iterator_ops.regExpStringIteratorFlags(iterator);
    if (!flags.global) {
        // Step b: yield the one match without reading it.
        iterator.iteratorIndexSlot().* = regexp_iterator_done;
        return try createIteratorResult(rt, objectFromValue(try realm.get(rt)).?, try result.get(rt), false);
    }
    try temporary.set(rt, try getValueProperty(ctx, output, objectFromValue(try realm.get(rt)).?, try result.get(rt), core.Atom.taggedInt(0), caller_function, caller_frame));
    try temporary.set(rt, try toStringForAnnexB(ctx, output, objectFromValue(try realm.get(rt)).?, try temporary.get(rt), caller_function, caller_frame));
    if (isEmptyStringValue(rt, try temporary.get(rt))) {
        try temporary.set(rt, try getValueProperty(ctx, output, objectFromValue(try realm.get(rt)).?, try regexp.get(rt), core.atom.ids.lastIndex, caller_function, caller_frame));
        const next = try advanceStringIndexNumber(ctx, output, objectFromValue(try realm.get(rt)).?, try source.get(rt), try temporary.get(rt), flags.unicode);
        try setValuePropertyStrict(ctx, output, objectFromValue(try realm.get(rt)).?, try regexp.get(rt), core.atom.ids.lastIndex, next, caller_function, caller_frame);
    }
    const yielded = try createIteratorResult(rt, objectFromValue(try realm.get(rt)).?, try result.get(rt), false);
    objectFromValue(try self.get(rt)).?.iteratorIndexSlot().* = regexp_iterator_active;
    return yielded;
}

/// `iteratorIndexSlot` of a RegExp String Iterator.
const regexp_iterator_active = 0;
const regexp_iterator_done = 1;
const regexp_iterator_running = 2;

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

pub fn getStringIndexValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) !?core.JSValue {
    const index = core.array.arrayIndexFromAtom(rt.atoms, atom_id) orelse return null;
    if (!value.isString()) return null;
    // Past the end the string has no own index: [[Get]] continues on the
    // prototype chain (String.prototype[5] = ...; "ab"[5]).
    if (index >= core.string.stringValueLenUnchecked(value)) return null;
    const unit = core.string.stringValueCodeUnitAtUnchecked(value, index);
    if (unit < 0x100) {
        // Latin-1 fast path: reuse the runtime's single-code-unit string
        // table. Hot loops like the URI encode/decode sweeps
        // hit this path thousands of times per inner
        // iteration, and avoiding the per-call header+bytes allocation
        // pair is a major speedup.
        return (try rt.singleByteString(@intCast(unit))).value();
    }
    const units: [1]u16 = .{unit};
    const out = try core.string.String.createUtf16(rt, &units);
    return out.value();
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
    const tag_atom = comptime core.atom.predefinedId("Symbol.toStringTag", .symbol).?;
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

/// builtinTag of Object.prototype.toString (§20.1.3.6 steps 5-14).
pub fn defaultObjectToStringTag(object: *core.Object) ![]const u8 {
    if (object.isProxy()) {
        if (object.proxyHandler() == null) return error.RevokedProxy;
        if (object.proxyTarget()) |target_value| {
            if (try core.array.isArrayValue(target_value)) return "Array";
        }
        return if (object.proxyIsCallable()) "Function" else "Object";
    }
    if (object.isArray()) return "Array";
    if (proxyTargetIsCallableObject(object)) return "Function";
    return switch (object.class_id) {
        core.class.ids.arguments, core.class.ids.mapped_arguments => "Arguments",
        core.class.ids.error_ => "Error",
        core.class.ids.boolean => "Boolean",
        core.class.ids.number => "Number",
        core.class.ids.string => "String",
        core.class.ids.date => "Date",
        core.class.ids.regexp => "RegExp",
        else => "Object",
    };
}

test "annexB string methods carry records that decode to their legacy body ids" {
    try std.testing.expectEqual(@as(?u32, 12), decodePrototypeMethodId(prototypeMethodId("big").?));
    try std.testing.expectEqual(@as(?u32, 25), decodePrototypeMethodId(prototypeMethodId("substr").?));
    try std.testing.expectEqual(@as(?u32, 26), decodePrototypeMethodId(prototypeMethodId("sup").?));
}

test "default object tag is Function for every callable class" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const class_ids = [_]core.ClassId{
        core.class.ids.bytecode_function,
        core.class.ids.generator_function,
        core.class.ids.async_function,
        core.class.ids.async_generator_function,
    };
    for (class_ids) |class_id| {
        const function_object = try core.Object.create(rt, class_id, null);
        try std.testing.expectEqualStrings("Function", try defaultObjectToStringTag(function_object));
    }
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

pub const isAsciiDigitUnit = unicode_lib.isAsciiDigitUnit;

pub const isHighSurrogateUnit = unicode_lib.isHighSurrogateUnit;

pub const isLowSurrogateUnit = unicode_lib.isLowSurrogateUnit;

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
// `appendAsciiUnits`) plus the shared `value_ops`/`builtin_glue`
// ops. The two leaf bodies they still defer to (the `charAtValue` and
// `methodCall` method-impl bodies that stay in builtins) are reached through the
// record table via `callStringBody`/`callStringCharAtBody` (Phase 6b-3 STEP 5),
// so exec no longer names them directly.

// qjs JS_STRING_LEN_MAX: js_string_pad throws RangeError when the
// requested length exceeds it.
const js_string_len_max: usize = core.string.max_length;

/// Fail before a builder grows past the longest string it could produce.
/// The final create would reject it anyway, but only after the builder had
/// grown to that size (`$\``` replacements square the input length).
fn ensureStringRoom(len: usize, additional: usize) error{StringTooLong}!void {
    if (additional > js_string_len_max -| len) return error.StringTooLong;
}

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
        try ensureStringRoom(self.len(), 1);
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

    fn len(self: *const StringBuffer) usize {
        return if (self.is_wide) self.wide.items.len else self.latin1.items.len;
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
        try ensureStringRoom(self.len(), count);
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
    const target_length = try value_ops.toLengthIndex(ctx, output, try expectObject(try global_root.get(rt)), try max_length.get(rt));
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
        try rt.interrupt.pollNativeWork();
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
    try ctx.runtime.interrupt.pollNativeBulkWork(input.items.len * @sizeOf(u32));

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
    try ctx.runtime.interrupt.pollNativeBulkWork((lhs_nfc.slice.len + rhs_nfc.slice.len) * @sizeOf(u32));

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
    // Only declared parameters are converted: substring/substr/slice take
    // two, charAt/charCodeAt/at/codePointAt/repeat one. An extra argument
    // is never observed.
    const parameter_count: usize = switch (method_id) {
        1, 25, 32 => 2,
        else => 1,
    };
    const count = @min(args.len, parameter_count);
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
    if (method_id == 1) {
        if (try fastLatin1Substring(ctx.runtime, string_value, coerced[0..count])) |value| return value;
    }
    if (method_id == 0) {
        const index = if (count >= 1) coerced[0] else core.JSValue.int32(0);
        return callStringCharAtBody(ctx, string_value, index);
    }
    if (method_id == 25) {
        return stringSubstr(ctx, string_value, coerced[0..count]);
    }
    return callStringBody(ctx, string_value, method_id, coerced[0..count]);
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

/// The receiver and both arguments are already coerced by
/// `stringNumericArgsMethod`, so nothing here is observable.
pub fn stringSubstr(
    ctx: *core.JSContext,
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
    // Clamp in f64 before converting: the arguments may be any finite
    // magnitude or infinite.
    const size_number: f64 = @floatFromInt(size);
    const start_integer = if (std.math.isNan(start_number)) 0 else @trunc(start_number);
    const start: usize = @intFromFloat(if (start_integer < 0)
        @max(size_number + start_integer, 0)
    else
        @min(start_integer, size_number));

    const max_len = size - start;
    const requested_len = if (args.len >= 2 and !args[1].is(.undefined_value)) blk: {
        const length_number = value_ops.numberValue(args[1]) orelse std.math.nan(f64);
        if (std.math.isNan(length_number)) break :blk @as(usize, 0);
        break :blk @as(usize, @intFromFloat(std.math.clamp(@trunc(length_number), 0, @as(f64, @floatFromInt(max_len)))));
    } else max_len;

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

// ----- String constructor and prototype builtins -----
// String constructor/prototype records and their direct builtin bodies.
//
// Receiver and argument values are borrowed for ordinary calls; returned
// JSValues are owned. Helpers explicitly named `Owned` consume their inputs,
// and temporary flattened strings or buffers are released locally.
const number_format = @import("../libs/number_format.zig");
const HostError = exception_ops.HostError;
const NativeCall = builtin_dispatch.NativeCall;
const AppendStringError = core.value_string.AppendStringError;
const TrimMode = enum { start, end, both };
pub const StaticMethod = core.host_function.builtin_method_ids.string.StaticMethod;
pub const ConstructorMethod = core.host_function.builtin_method_ids.string.ConstructorMethod;
pub const PrototypeMethod = core.host_function.builtin_method_ids.string.PrototypeMethod;
pub const legacy_split_method_id = string_id_lookup.legacy_split_method_id;
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
        // Prototype methods (the set `prototypeMethodId` maps and
        // `decodePrototypeMethodId` decodes). `toString` / `valueOf` live in
        // the `.primitive` domain.
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
        stringEntry("anchor", 1, @intFromEnum(PrototypeMethod.anchor)),
        stringEntry("big", 0, @intFromEnum(PrototypeMethod.big)),
        stringEntry("blink", 0, @intFromEnum(PrototypeMethod.blink)),
        stringEntry("bold", 0, @intFromEnum(PrototypeMethod.bold)),
        stringEntry("fixed", 0, @intFromEnum(PrototypeMethod.fixed)),
        stringEntry("fontcolor", 1, @intFromEnum(PrototypeMethod.fontcolor)),
        stringEntry("fontsize", 1, @intFromEnum(PrototypeMethod.fontsize)),
        stringEntry("italics", 0, @intFromEnum(PrototypeMethod.italics)),
        stringEntry("link", 1, @intFromEnum(PrototypeMethod.link)),
        stringEntry("small", 0, @intFromEnum(PrototypeMethod.small)),
        stringEntry("strike", 0, @intFromEnum(PrototypeMethod.strike)),
        stringEntry("sub", 0, @intFromEnum(PrototypeMethod.sub)),
        stringEntry("substr", 2, @intFromEnum(PrototypeMethod.substr)),
        stringEntry("sup", 0, @intFromEnum(PrototypeMethod.sup)),
        stringEntry("[Symbol.iterator]", 0, @intFromEnum(PrototypeMethod.iterator)),
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
    comptime leaf: builtin_dispatch.LeafStringI32ToI32,
) core.host_function.InternalEntry {
    var entry = stringEntryWithHandler(name, length, id, handler);
    entry.managed = direct;
    entry.prim_leaf = .{ .sig = sig, .target = core.NativeEntry.code(leaf) };
    return entry;
}

const stringEntryWithHandler = builtin_dispatch.entryWithHandler;

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
    const Expect = struct { id: u32, sig: core.LeafSig, leaf: builtin_dispatch.LeafStringI32ToI32 };
    const expected = [_]Expect{
        .{ .id = @intFromEnum(PrototypeMethod.char_code_at), .sig = builtin_dispatch.sig_string_i32_to_i32, .leaf = &stringCharCodeAtLeaf },
        .{ .id = @intFromEnum(PrototypeMethod.char_at), .sig = builtin_dispatch.sig_string_i32_to_string, .leaf = &stringCharAtLeaf },
        .{ .id = @intFromEnum(PrototypeMethod.at), .sig = builtin_dispatch.sig_string_i32_to_string, .leaf = &stringAtLeaf },
        .{ .id = @intFromEnum(PrototypeMethod.code_point_at), .sig = builtin_dispatch.sig_string_i32_to_i32, .leaf = &stringCodePointAtLeaf },
    };
    inline for (expected) |want| {
        const decl = comptime testStringDeclById(want.id);
        const entry = comptime builtin_dispatch.entryFromInternal(decl);
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

/// QJS gives `at`, `charCodeAt`, `codePointAt`, and the shared
/// `js_string_toLowerCase` case-conversion body their own function-list entries.
/// Their zjs entries likewise land in the small functions below. The index
/// methods keep their already-string/immediate-index path local; values requiring
/// observable ToString/ToNumber coercion tail into this shared handler. Keeping
/// that rare path out of the direct index functions avoids cloning the whole
/// coercion tower into each hot native entry.
const PrimitiveIndexMethod = enum { char_code_at, at, code_point_at };

inline fn stringPrimitiveIndexRead(host_call: NativeCall, comptime method: PrimitiveIndexMethod) HostError!?core.JSValue {
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
    switch (method) {
        .char_code_at => {
            if (idx < 0 or idx >= len) return core.JSValue.float64(std.math.nan(f64));
            return core.JSValue.int32(core.string.stringValueCodeUnitAtUnchecked(string_value, @intCast(idx)));
        },
        .at => {
            const index = if (idx < 0) len + idx else idx;
            if (index < 0 or index >= len) return core.JSValue.undefinedValue();
            return codeUnitStringValue(rt, core.string.stringValueCodeUnitAtUnchecked(string_value, @intCast(index))) catch |err| return @as(HostError, @errorCast(err));
        },
        .code_point_at => {
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
    // A tail-buffer view already reads in O(1); flattening it would copy the
    // whole string and spend its append right, making `s += x; s.at(0)`
    // loops quadratic.
    if (node.buffer != null) return value;
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
    // Long results fall to the shared dispatcher, which folds them through
    // the `+` tail-buffer path (see `concatShouldFold`) and owns the
    // StringTooLong error shape.
    if (total >= core.string.String.tail_buffer_seed_len) return null;
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
    _: core.JSValue,
    argv: [*]const core.JSValue,
    argc: u32,
    _: *const core.NativeEntry,
    _: ?*core.Object,
) callconv(.c) core.JSValue {
    const args = argv[0..argc];
    const global = ctx.global orelse return builtin_dispatch.hostErrorToValue(ctx, null, error.InvalidBuiltinRegistry);
    const output = builtin_dispatch.vmCallerView(ctx).output;
    const result = stringFromCharCode(ctx, output, global, args) catch |err| {
        return builtin_dispatch.hostErrorToValue(ctx, global, @as(HostError, @errorCast(err)));
    };
    return result;
}

fn stringFromCharCodeCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const global = try builtin_dispatch.activeGlobal(host_call);
    return stringFromCharCode(host_call.ctx, host_call.output, global, host_call.args) catch |err| return @as(HostError, @errorCast(err));
}

// --- Lane K prim_self leaf targets (`builtin_dispatch.LeafStringI32ToI32`) ---
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
    if (try stringPrimitiveIndexRead(host_call, .char_code_at)) |value| return value;
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
    if (try stringPrimitiveIndexRead(host_call, .char_code_at)) |value| return value;
    return stringCall(native_ctx, native_this, native_args, native_magic);
}

fn stringAtCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    if (try stringPrimitiveIndexRead(host_call, .at)) |value| return value;
    return stringCall(native_ctx, native_this, native_args, native_magic);
}

fn stringCodePointAtCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    if (try stringPrimitiveIndexRead(host_call, .code_point_at)) |value| return value;
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
    const global = try builtin_dispatch.activeGlobal(host_call);
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

    return unicodeCaseString(host_call.ctx.runtime, string_value, to_lower) catch |err| return @as(HostError, @errorCast(err));
}

/// Shared record handler for the `.string` domain: the String Iterator `next`
/// and the `from*`/constructor statics run their own helpers, while the
/// prototype methods (and `String.raw`) delegate to the shared string ops
/// that the string opcode handlers and `regexp_ops.zig` also call.
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
        const receiver = thisObject(this_value) orelse return error.IncompatibleReceiver;
        if (receiver.class_id != core.class.ids.string_iterator) return error.IncompatibleReceiver;
        return stringIteratorNext(ctx.runtime, ctx.globalObject() catch null, this_value);
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

    // Engine-internal dispatch arm: `callStringBody` callers in this file
    // (`stringPrototypeMethod`, `stringSearchPositionMethod`,
    // `stringNumericArgsMethod`, `stringSplitBuiltinArray`) have already
    // ToString'd the receiver and coerced the arguments, and route the body
    // through the table here. It is gated on `func_obj == null and
    // global == null`, the contract those call sites use (the body needs no
    // realm global). Other direct callers can pass `func_obj == null` with a
    // realm `global` and raw args, so they must fall through to the coercing
    // dispatcher below. This deliberately bypasses `stringPrototypeMethod`:
    // routing back through it would re-enter this record and recurse.
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

    const active_global = try builtin_dispatch.activeGlobal(host_call);
    return switch (id) {
        @intFromEnum(ConstructorMethod.call) => stringFunctionCall(ctx, output, active_global, args, caller_function, caller_frame),
        @intFromEnum(StaticMethod.from_char_code) => stringFromCharCode(ctx, output, active_global, args),
        @intFromEnum(StaticMethod.from_code_point) => stringFromCodePoint(ctx, output, active_global, args),
        @intFromEnum(StaticMethod.raw) => stringRaw(ctx, output, active_global, args, caller_function, caller_frame),
        @intFromEnum(PrototypeMethod.iterator) => stringIteratorCall(ctx, output, active_global, this_value, caller_function, caller_frame),
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

    if (args.len >= 1 and values[0].is(.symbol)) return error.SymbolToString;
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

// String Iterator factory. The produced iterator's `next` carries the
// `(.string, iterator_next)` native id, so the `next` body still dispatches
// through the record table into `stringIteratorNext` below.

fn stringIteratorPrimitiveValue(value: core.JSValue) !core.JSValue {
    if (value.isString()) return value;
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.is(.object)) return error.TypeError;
    const object = core.Object.fromHeader(header);
    if (object.class_id != core.class.ids.string) return error.TypeError;
    return (object.objectData() orelse return error.TypeError);
}

fn defineStringIteratorToStringTag(rt: *core.JSRuntime, object: *core.Object, tag_name: []const u8) !void {
    var values = [_]core.JSValue{ object.value(), core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    const tag_atom = core.atom.predefinedId("Symbol.toStringTag", .symbol) orelse return error.TypeError;
    values[1] = (try core.string.String.createUtf8(rt, tag_name)).value();
    try core.Object.fromHeader(values[0].refHeader().?).defineOwnProperty(rt, tag_atom, core.Descriptor.data(values[1], .{ .configurable = true }));
}

fn stringIteratorPrototype(ctx: *core.JSContext, tag_name: []const u8) !*core.Object {
    const rt = ctx.runtime;
    var values = [_]core.JSValue{ core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    const headers = [_]core.runtime.HeaderRootValue{.{ .header = &ctx.header }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices, .headers = &headers };
    roots.activate(rt);
    defer roots.deactivate(rt);
    values[0] = (try core.Object.create(rt, core.class.ids.object, null)).value();
    try defineStringIteratorToStringTag(rt, core.Object.fromHeader(values[0].refHeader().?), "Iterator");
    values[1] = (try core.Object.create(rt, core.class.ids.object, core.Object.fromHeader(values[0].refHeader().?))).value();
    try defineStringIteratorToStringTag(rt, core.Object.fromHeader(values[1].refHeader().?), tag_name);
    values[2] = try core.function.nativeFunction(ctx, "next", 0);
    const next_object = (values[2].refHeader() orelse return error.TypeError);
    if (!values[2].is(.object)) return error.TypeError;
    const next_function = core.Object.fromHeader(next_object);
    next_function.setNativeBuiltinIdAndRecord(core.function.nativeBuiltinId(.string, @intFromEnum(method_ids.string.PrototypeMethod.iterator_next)));
    try core.Object.fromHeader(values[1].refHeader().?).defineOwnProperty(rt, core.atom.predefinedId("next", .string).?, core.Descriptor.data(values[2], .method));
    return core.Object.fromHeader(values[1].refHeader().?);
}

pub fn stringIterator(ctx: *core.JSContext, receiver: core.JSValue) !core.JSValue {
    const rt = ctx.runtime;
    var values = [_]core.JSValue{ receiver, core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    const headers = [_]core.runtime.HeaderRootValue{.{ .header = &ctx.header }};
    var root_frame = core.runtime.ValueRootFrame{ .slices = &slices, .headers = &headers };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    values[0] = try stringIteratorPrimitiveValue(values[0]);
    values[1] = (try stringIteratorPrototype(ctx, "String Iterator")).value();
    values[2] = (try core.Object.create(rt, core.class.ids.string_iterator, core.Object.fromHeader(values[1].refHeader().?))).value();
    const object = core.Object.fromHeader(values[2].refHeader().?);
    try object.setOptionalValueSlot(rt, object.iteratorTargetSlot(), values[0]);
    core.Object.fromHeader(values[2].refHeader().?).iteratorIndexSlot().* = 0;
    return values[2];
}
pub fn stringIteratorNext(rt: *core.JSRuntime, global: ?*core.Object, receiver: core.JSValue) !core.JSValue {
    var values = [_]core.JSValue{ receiver, if (global) |object| object.value() else core.JSValue.nullValue(), core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    const iterator_object = objectFromValue(values[0]) orelse return error.IncompatibleReceiver;
    if (iterator_object.class_id != core.class.ids.string_iterator) return error.IncompatibleReceiver;
    const target = (iterator_object.iteratorTargetSlot().*) orelse return createIteratorResult(rt, objectFromValue(values[1]), core.JSValue.undefinedValue(), true);
    if (!target.isString()) return error.TypeError;
    const target_len = core.string.stringValueLenUnchecked(target);
    if ((iterator_object.iteratorIndexSlot().*) >= target_len) {
        const done_result = try createIteratorResult(rt, objectFromValue(values[1]), core.JSValue.undefinedValue(), true);
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
        return createIteratorResult(rt, objectFromValue(values[1]), values[2], false);
    }

    if (isHighSurrogateUnit(first) and index + 1 < target_len) {
        const second = core.string.stringValueCodeUnitAtUnchecked(target, index + 1);
        if (isLowSurrogateUnit(second)) {
            iterator_object.iteratorIndexSlot().* += 2;
            const units: [2]u16 = .{ first, second };
            values[2] = (try core.string.String.createUtf16(rt, &units)).value();
            return createIteratorResult(rt, objectFromValue(values[1]), values[2], false);
        }
    }

    iterator_object.iteratorIndexSlot().* += 1;
    const units: [1]u16 = .{first};
    values[2] = (try core.string.String.createUtf16(rt, &units)).value();
    return createIteratorResult(rt, objectFromValue(values[1]), values[2], false);
}

/// `String.prototype.charAt` body. `string_value` is the receiver after
/// RequireObjectCoercible + ToString; `index_value` is already a number.
pub fn charAtValue(rt: *core.JSRuntime, string_value: core.JSValue, index_value: core.JSValue) !core.JSValue {
    if (!string_value.isString()) return error.TypeError;
    const index = try stringInteger(rt, index_value);
    if (index < 0 or index >= @as(i64, @intCast(core.string.stringValueLenUnchecked(string_value)))) return createStringValue(rt, "");
    return codeUnitStringValue(rt, core.string.stringValueCodeUnitAtUnchecked(string_value, @intCast(index)));
}

/// String.prototype method bodies reached through `callStringBody`. The
/// dispatcher has already applied RequireObjectCoercible + ToString to the
/// receiver and coerced every argument, so `string_value` must be a string
/// primitive. Every body works on UTF-16 code units and reads ropes without
/// flattening them unless a search needs contiguous units.
pub fn methodCall(rt: *core.JSRuntime, string_value: core.JSValue, id: u32, args: []const core.JSValue) !core.JSValue {
    if (!string_value.isString()) return error.TypeError;
    return switch (id) {
        1 => substringString(rt, string_value, args),
        4 => flatStringSearch(rt, string_value, args, .first),
        5 => flatStringSearch(rt, string_value, args, .contains),
        6 => flatStringSearch(rt, string_value, args, .starts),
        7 => flatStringSearch(rt, string_value, args, .ends),
        8 => trimStringValue(rt, string_value, .both),
        21 => trimStringValue(rt, string_value, .start),
        22 => trimStringValue(rt, string_value, .end),
        legacy_split_method_id => splitString(rt, string_value, args),
        28 => flatStringSearch(rt, string_value, args, .last),
        29 => charCodeAtString(rt, string_value, args),
        30 => atString(rt, string_value, args),
        31 => codePointAtString(rt, string_value, args),
        32 => sliceString(rt, string_value, args),
        33 => repeatString(rt, string_value, args),
        38 => core.JSValue.boolean(isWellFormedString(string_value)),
        39 => toWellFormedString(rt, string_value),
        else => error.TypeError,
    };
}

fn substringString(rt: *core.JSRuntime, string_value: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const range = try stringSubstringRange(rt, core.string.stringValueLenUnchecked(string_value), args);
    return stringSliceValue(rt, string_value, range.start, range.end - range.start);
}

fn trimStringValue(rt: *core.JSRuntime, string_value: core.JSValue, mode: TrimMode) !core.JSValue {
    var start: usize = 0;
    var end = core.string.stringValueLenUnchecked(string_value);
    if (mode == .start or mode == .both) {
        while (start < end and isTrimCodeUnit(core.string.stringValueCodeUnitAtUnchecked(string_value, start))) : (start += 1) try rt.interrupt.pollNativeWork();
    }
    if (mode == .end or mode == .both) {
        while (end > start and isTrimCodeUnit(core.string.stringValueCodeUnitAtUnchecked(string_value, end - 1))) : (end -= 1) try rt.interrupt.pollNativeWork();
    }
    return stringSliceValue(rt, string_value, start, end - start);
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

fn splitString(rt: *core.JSRuntime, string_value: core.JSValue, args: []const core.JSValue) !core.JSValue {
    return splitStringRooted(rt, string_value, args) catch |err| switch (err) {
        error.RootGenerationExhausted => error.OutOfMemory,
        error.RootAlreadyActive, error.RootMutationDuringCollection, error.WrongRuntime, error.InactiveRoot, error.InvalidRootIndex, error.ExpectedString => std.debug.panic("string split root contract: {s}", .{@errorName(err)}),
        else => |other| other,
    };
}

fn splitStringRooted(rt: *core.JSRuntime, string_value: core.JSValue, args: []const core.JSValue) !core.JSValue {
    var roots = core.runtime.ExactValueRoots(5){};
    try roots.activate(rt);
    defer roots.deactivate();
    const source = try roots.ref(0);
    const separator = try roots.ref(1);
    const limit_arg = try roots.ref(2);
    const output = try roots.ref(3);
    const element = try roots.ref(4);
    try source.set(rt, string_value);
    try separator.set(rt, if (args.len >= 1) args[0] else core.JSValue.undefinedValue());
    try limit_arg.set(rt, if (args.len >= 2) args[1] else core.JSValue.undefinedValue());

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
            try rt.interrupt.pollNativeWork();
            try element.set(rt, try codeUnitStringValue(rt, core.string.stringValueCodeUnitAtUnchecked(try source.get(rt), index)));
            try defineValueElement(rt, objectFromValue(try output.get(rt)).?, out_index, try element.get(rt));
            out_index += 1;
        }
        return output.get(rt);
    }

    var start: usize = 0;
    while (out_index < limit) {
        try rt.interrupt.pollNativeWork();
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
                    const value = unicode_lib.codePointFromSurrogatePair(first, second);
                    return .{ .value = value, .start = index, .end = index + 2 };
                }
            }
            return .{ .value = first, .start = index, .end = next_index };
        },
    }
}

/// Full Unicode case mapping of a string primitive, including the final
/// sigma rule. Ropes are flattened once; the input stays rooted throughout.
pub fn unicodeCaseString(rt: *core.JSRuntime, primitive: core.JSValue, to_lower: bool) !core.JSValue {
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
    if (try core.string.String.createValueAsciiCaseMapped(rt, try source.get(rt), if (to_lower) .lower else .upper)) |mapped| {
        try rt.interrupt.pollNativeBulkWork(slen);
        return mapped.value();
    }
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
        try rt.interrupt.pollNativeWork();
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

fn charCodeAtString(rt: *core.JSRuntime, primitive: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const index = if (args.len >= 1) try stringInteger(rt, args[0]) else 0;
    if (index < 0 or index >= @as(i64, @intCast(core.string.stringValueLenUnchecked(primitive)))) return core.JSValue.float64(std.math.nan(f64));
    return core.JSValue.int32(core.string.stringValueCodeUnitAtUnchecked(primitive, @intCast(index)));
}

fn codePointAtString(rt: *core.JSRuntime, primitive: core.JSValue, args: []const core.JSValue) !core.JSValue {
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

fn atString(rt: *core.JSRuntime, string_value: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const relative = if (args.len >= 1) try stringInteger(rt, args[0]) else 0;
    const len: i64 = @intCast(core.string.stringValueLenUnchecked(string_value));
    const index = if (relative < 0) len + relative else relative;
    if (index < 0 or index >= len) return core.JSValue.undefinedValue();
    return codeUnitStringValue(rt, core.string.stringValueCodeUnitAtUnchecked(string_value, @intCast(index)));
}

fn sliceString(rt: *core.JSRuntime, string_value: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const range = try stringSliceRange(rt, core.string.stringValueLenUnchecked(string_value), args);
    return stringSliceValue(rt, string_value, range.start, range.end - range.start);
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

/// String.prototype.repeat steps 3-5: ToIntegerOrInfinity, then RangeError
/// for a negative or +Infinity count. Finite counts saturate.
fn repeatCount(rt: *core.JSRuntime, args: []const core.JSValue) !usize {
    if (args.len == 0) return 0;
    if (args[0].as(.int)) |count| return if (count < 0) error.InvalidRepeatCount else @intCast(count);
    const number = try value_ops.primitiveToNumber(rt, args[0]);
    if (std.math.isNan(number)) return 0;
    if (number <= -1 or number == std.math.inf(f64)) return error.InvalidRepeatCount;
    if (number >= 0x1p63) return std.math.maxInt(usize);
    return @intFromFloat(number);
}

/// Result length of a non-empty repeat, bounded by the string length cap.
fn repeatLength(unit_len: usize, count: usize) error{InvalidStringLength}!usize {
    const total = std.math.mul(usize, unit_len, count) catch return error.InvalidStringLength;
    if (total > core.string.max_length) return error.InvalidStringLength;
    return total;
}

/// Copy the source once without materializing ropes, then duplicate native
/// units up to the final length. No GC borrow survives result allocation.
/// Units `repeat` copies between interrupt polls once the doubling copies
/// grow past it (rounded down to whole repetitions).
const repeat_copy_step = 1 << 20;

fn repeatString(rt: *core.JSRuntime, string_value: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const count = try repeatCount(rt, args);
    const unit_len = core.string.stringValueLenUnchecked(string_value);
    if (unit_len == 0 or count == 0) return createStringValue(rt, "");
    const total = try repeatLength(unit_len, count);
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
    // Every copy is whole repetitions, so the copied prefix keeps the period.
    const copy_step = @max(unit_len, repeat_copy_step / unit_len * unit_len);
    if (buffer.is_wide) {
        while (buffer.wide.items.len < total) {
            const count_to_copy = @min(buffer.wide.items.len, total - buffer.wide.items.len, copy_step);
            buffer.wide.appendSliceAssumeCapacity(buffer.wide.items[0..count_to_copy]);
            try rt.interrupt.pollNativeBulkWork(count_to_copy * 2);
        }
    } else {
        while (buffer.latin1.items.len < total) {
            const count_to_copy = @min(buffer.latin1.items.len, total - buffer.latin1.items.len, copy_step);
            buffer.latin1.appendSliceAssumeCapacity(buffer.latin1.items[0..count_to_copy]);
            try rt.interrupt.pollNativeBulkWork(count_to_copy);
        }
    }
    borrow.deactivate();
    return buffer.finish(rt);
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
    // A loop of searches over a long string polls as its scans add up.
    try rt.interrupt.pollNativeBulkWork(hlen);
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
        if (resolvedCodeUnitAt(haystack, start + offset) != resolvedCodeUnitAt(needle, offset)) return false;
    }
    return true;
}

// startsWith / endsWith call this once per op; resolve the flat slices once
// (hoisting the slice/rope parent-chain walk out of the per-char loop) instead
// of `codeUnitAt` per character — same resolve-once pattern as stringIndexOfUnits.
fn stringMatchesAtUnits(haystack: *core.string.String, needle: *core.string.String, start: usize) bool {
    return stringMatchesAtResolved(haystack.resolveData(), needle.resolveData(), haystack.len(), needle.len(), start);
}

fn stringIndexOfUnits(haystack: *core.string.String, needle: *core.string.String, start: usize) ?usize {
    if (start > haystack.len()) return null;
    return stringIndexOfData(haystack.resolveData(), needle.resolveData(), start);
}

fn stringLastIndexOfUnits(haystack: *core.string.String, needle: *core.string.String, start: usize) ?usize {
    const hlen = haystack.len();
    const nlen = needle.len();
    if (nlen == 0) return @min(start, hlen);
    if (nlen > hlen) return null;
    // Resolve both flat slices ONCE outside the per-position loop (the prior
    // code re-walked the slice/rope chain via codeUnitAt for every character of
    // every candidate position) and first-char-skip.
    const h = haystack.resolveData();
    const n = needle.resolveData();
    if (nlen >= two_way_min_needle) {
        // The last match starting at or before `start` is the first match of
        // the reversed needle in the reversed prefix that ends there.
        const end = @min(start, hlen - nlen) + nlen;
        const y: UnitView = .{ .data = h, .base = 0, .len = end, .reversed = true };
        const x: UnitView = .{ .data = n, .base = 0, .len = nlen, .reversed = true };
        return if (twoWaySearch(y, x)) |pos| end - pos - nlen else null;
    }
    const first = resolvedCodeUnitAt(n, 0);
    var index = @min(start, hlen - nlen) + 1;
    while (index > 0) {
        index -= 1;
        if (resolvedCodeUnitAt(h, index) != first) continue;
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

test "string iteratorResult roots direct function bytecode value while creating result" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-string-iterator-result-bytecode-symbol");
    const fb = try core.FunctionBytecode.createPublishedFixture(rt, .{ .cpool_count = 1 }, &.{try rt.symbolValue(symbol_atom)});

    const result_value = core.JSValue.functionBytecode(&fb.header);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const iterator_result_value = try createIteratorResult(rt, null, result_value, false);
    const iterator_result = try expectObject(iterator_result_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    {
        const stored = try iterator_result.getProperty(core.atom.predefinedId("value", .string).?);
        try std.testing.expect(stored.same(result_value));
    }

    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "string wrapper iterator and split helpers keep values under GC" {
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
    const split_value = try splitString(rt, text, &.{separator});
    const split_object = try expectObject(split_value);
    const split_first = try split_object.getProperty(core.Atom.taggedInt(0));
    const split_second = try split_object.getProperty(core.Atom.taggedInt(1));
    try std.testing.expect((flatReceiverForTest(split_first) orelse return error.TypeError).eqlBytes("a"));
    try std.testing.expect((flatReceiverForTest(split_second) orelse return error.TypeError).eqlBytes("a"));
}

/// These fixtures only produce flat strings; a rope would return null here
/// rather than being materialized behind the caller's back.
fn flatReceiverForTest(value: core.JSValue) ?*core.string.String {
    return core.string.asFlat(value);
}

const expectObject = core.value_semantics.expectObject;

fn stringSearchStart(rt: *core.JSRuntime, length: usize, value: core.JSValue) !usize {
    const number = try value_ops.primitiveToNumber(rt, value);
    if (std.math.isNan(number) or number <= 0) return 0;
    if (std.math.isPositiveInf(number)) return length;
    const truncated = @trunc(number);
    if (truncated >= @as(f64, @floatFromInt(length))) return length;
    return @intFromFloat(truncated);
}

fn stringLastSearchStart(rt: *core.JSRuntime, default_start: usize, value: core.JSValue) !usize {
    const number = try value_ops.primitiveToNumber(rt, value);
    if (std.math.isNan(number)) return default_start;
    if (number <= 0) return 0;
    if (std.math.isPositiveInf(number)) return default_start;
    const truncated = @trunc(number);
    if (truncated >= @as(f64, @floatFromInt(default_start))) return default_start;
    return @intFromFloat(truncated);
}

fn toUint32Limit(rt: *core.JSRuntime, value: core.JSValue) !u32 {
    if (value.isBigInt()) return error.BigIntToNumber;
    if (value.is(.symbol)) return error.SymbolToNumber;
    return value_ops.toUint32Number(try value_ops.primitiveToNumber(rt, value));
}

fn stringInteger(rt: *core.JSRuntime, value: core.JSValue) !i64 {
    if (value.as(.int)) |int_value| return int_value;
    const number = try value_ops.primitiveToNumber(rt, value);
    if (std.math.isNan(number)) return 0;
    // Saturate: maxInt(i64) is not representable in f64 and 0x1p63 is the
    // first f64 past it; -0x1p63 is exactly minInt(i64).
    if (number >= 0x1p63) return std.math.maxInt(i64);
    if (number <= -0x1p63) return std.math.minInt(i64);
    return @intFromFloat(@trunc(number));
}

fn isTrimCodeUnit(unit: u16) bool {
    return unicode_lib.isEcmaWhitespaceOrLineTerminatorUnit(unit);
}

/// This file's policy for the shared bare-runtime ToString owner.
fn appendValueString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) AppendStringError!void {
    return core.value_string.appendValueString(rt, buffer, value, .{ .unwrap_wrappers = true });
}

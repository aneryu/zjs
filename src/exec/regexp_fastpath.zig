//! RegExp fast paths and simple-pattern matchers shared between the VM and builtins.

const bytecode = @import("../bytecode/root.zig");
const core = @import("../core/root.zig");
const method_ids = core.host_function.builtin_method_ids;
const frame_mod = @import("frame.zig");
const property_ops = @import("property_ops.zig");
const regexp_adapter = @import("../libs/regexp.zig").js_adapter;
const regexp_validate = @import("../libs/regexp.zig").validate;
const std = @import("std");
const unicode_lib = @import("../libs/unicode.zig");
const value_ops = @import("value_ops.zig");

const builtin_dispatch = @import("builtin_dispatch.zig");
const call_runtime = @import("call_runtime.zig");
const exception_ops = @import("vm_exception_ops.zig");
const array_ops = @import("array_ops.zig");
const coercion_ops = @import("coercion_ops.zig");
const object_ops = @import("object_ops.zig");
const string_ops = @import("string_ops.zig");

// Native-builtin id of the RegExp constructor record. The construct fast path's
// coercing terminals run the builtin RegExp constructor body through the record
// table (`builtin_dispatch.callConstructRecord`) keyed on this ref rather than
// importing `builtins.regexp.constructWithPrototype` directly, so the construct
// logic stays owned by the table (Phase 6b-3e). The pattern/flags are already
// coerced and the instance prototype resolved at the call site, so the record
// only runs the constructor body.
const regexp_construct_ref = core.function.NativeBuiltinRef{
    .domain = .regexp,
    .id = @intFromEnum(core.host_function.builtin_method_ids.regexp.ConstructorMethod.construct),
};

/// Run the builtin RegExp constructor body for already-coerced `(pattern,
/// flags)` and a resolved instance `prototype` through the record table. The
/// RegExp construct record reads only `args`/`new_target`, so no constructor
/// function object is threaded.
fn constructRegExpRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    prototype: ?*core.Object,
    pattern: core.JSValue,
    flags: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const args = [_]core.JSValue{ pattern, flags };
    return (try builtin_dispatch.callConstructRecord(ctx, output, global, &.{}, null, regexp_construct_ref, prototype, &args, caller_function, caller_frame)) orelse error.TypeError;
}

// Helpers that remain in call_runtime.zig (generic utilities and RegExp helpers
// outside the fast-path cluster).
const RegExpCapture = call_runtime.RegExpCapture;
const RegExpMatch = string_ops.RegExpMatch;
const anchoredSingleNonWhitespaceMatches = string_ops.anchoredSingleNonWhitespaceMatches;
const appendStringValueUnits = string_ops.appendStringValueUnits;
const appendUtf16UnitsAsUtf8 = string_ops.appendUtf16UnitsAsUtf8;
const appendUtf8CodePointForRegExpName = string_ops.appendUtf8CodePointForRegExpName;
const arrayPrototypeFromGlobal = array_ops.arrayPrototypeFromGlobal;
const bytesAreAscii = string_ops.bytesAreAscii;
const callValueOrBytecode = call_runtime.callValueOrBytecode;
const classEscapeUnitMatches = string_ops.classEscapeUnitMatches;
const codePointFromSurrogatePair = string_ops.codePointFromSurrogatePair;
const combinedSurrogateCodePoint = string_ops.combinedSurrogateCodePoint;
const constructorPrototypeFromGlobal = object_ops.constructorPrototypeFromGlobal;
const createRegExpMatchArrayFromValue = string_ops.createRegExpMatchArrayFromValue;
const createRegExpMatchArrayNoCapturesFromValue = string_ops.createRegExpMatchArrayNoCapturesFromValue;
const defineSplitValueElement = string_ops.defineSplitValueElement;
const decodeRegExpLegacyCaptureSlice = string_ops.decodeRegExpLegacyCaptureSlice;
const fastToLengthIndex = coercion_ops.fastToLengthIndex;
const findStringClassEscapeMatch = string_ops.findStringClassEscapeMatch;
const getValueProperty = object_ops.getValueProperty;
const hexNibble = array_ops.hexNibble;
const isCallableValue = call_runtime.isCallableValue;
const isHighSurrogateCodePoint = string_ops.isHighSurrogateCodePoint;
const isHighSurrogateUnit = string_ops.isHighSurrogateUnit;
const isLineTerminatorUnit = string_ops.isLineTerminatorUnit;
const isLowSurrogateCodePoint = string_ops.isLowSurrogateCodePoint;
const isLowSurrogateUnit = string_ops.isLowSurrogateUnit;
const isSameRealmRegExpPrototypeGetter = object_ops.isSameRealmRegExpPrototypeGetter;
const isSimpleStringClassEscapeSource = string_ops.isSimpleStringClassEscapeSource;
const isStringLineEndPosition = string_ops.isStringLineEndPosition;
const isStringLineStartPosition = string_ops.isStringLineStartPosition;
const latin1StringSlice = string_ops.latin1StringSlice;
const nativeFunctionMatcherUnicodeClassAsciiResult = string_ops.nativeFunctionMatcherUnicodeClassAsciiResult;
const objectFromValue = object_ops.objectFromValue;
const objectHasRegExpInternalSlots = object_ops.objectHasRegExpInternalSlots;
const objectRealmGlobal = object_ops.objectRealmGlobal;
const qjsRegExpExecPropertyFallback = object_ops.qjsRegExpExecPropertyFallback;
const qjsRegExpPrototypeMethodIsDefault = object_ops.qjsRegExpPrototypeMethodIsDefault;
const qjsRegExpSymbolMatch = string_ops.qjsRegExpSymbolMatch;
const qjsRegExpSymbolMatchAll = string_ops.qjsRegExpSymbolMatchAll;
const qjsRegExpSymbolReplace = string_ops.qjsRegExpSymbolReplace;
const qjsRegExpSymbolSearch = string_ops.qjsRegExpSymbolSearch;
const qjsRegExpSymbolSplit = string_ops.qjsRegExpSymbolSplit;
const qjsRegExpToString = string_ops.qjsRegExpToString;
const qjsStringValueContainsByte = string_ops.qjsStringValueContainsByte;
const reflectConstructPrototypeVm = object_ops.reflectConstructPrototypeVm;
const regExpLegacyNoCaptureSliceValue = array_ops.regExpLegacyNoCaptureSliceValue;
const regExpPrototypeFromGlobal = object_ops.regExpPrototypeFromGlobal;
const regexpInternalStringValue = string_ops.regexpInternalStringValue;
const regexpSourceUsesZigPropertyFallback = object_ops.regexpSourceUsesZigPropertyFallback;
const replaceRegExpLegacySlot = string_ops.replaceRegExpLegacySlot;
const sameObjectIdentity = object_ops.sameObjectIdentity;
const setValuePropertyStrict = object_ops.setValuePropertyStrict;
const simpleAsciiLiteralClassPlusLiteralMatchBytes = string_ops.simpleAsciiLiteralClassPlusLiteralMatchBytes;
const simpleCaptureAtomsKnownDisjoint = array_ops.simpleCaptureAtomsKnownDisjoint;
const simpleCaptureSequenceAtomMatches = string_ops.simpleCaptureSequenceAtomMatches;
const simpleCaptureSequenceMatchPattern = string_ops.simpleCaptureSequenceMatchPattern;
const simpleClassAlternationMatchPattern = string_ops.simpleClassAlternationMatchPattern;
const simpleClassSequenceAtomMatches = string_ops.simpleClassSequenceAtomMatches;
const simpleClassSequenceMatchPattern = string_ops.simpleClassSequenceMatchPattern;
const simpleLatin1LiteralPlusLiteralMatch = string_ops.simpleLatin1LiteralPlusLiteralMatch;
const simpleUnicodeLiteralMatch = string_ops.simpleUnicodeLiteralMatch;
const simpleUnicodePropertyRunTestFast = object_ops.simpleUnicodePropertyRunTestFast;
const stringAtomId = string_ops.stringAtomId;
const stringCodePointAt = string_ops.stringCodePointAt;
const stringLengthIndex = string_ops.stringLengthIndex;
const stringSliceValue = string_ops.stringSliceValue;
const stringValueContainsUnitByte = string_ops.stringValueContainsUnitByte;
const stringValueUnitsEqualBytes = string_ops.stringValueUnitsEqualBytes;
const surrogatePairFromCodePoint = string_ops.surrogatePairFromCodePoint;
const throwRegExpAccessorTypeError = array_ops.throwRegExpAccessorTypeError;
const throwTypeErrorMessage = exception_ops.throwTypeErrorMessage;
const toLengthIndex = coercion_ops.toLengthIndex;
const toStringForAnnexB = string_ops.toStringForAnnexB;
const unicodeAstralSpecialMatch = string_ops.unicodeAstralSpecialMatch;
const unicodeLowSurrogateLiteralMatch = string_ops.unicodeLowSurrogateLiteralMatch;
const updateRegExpLegacyStaticsForMatch = string_ops.updateRegExpLegacyStaticsForMatch;
const valueTruthy = coercion_ops.valueTruthy;

pub fn qjsRegExpFunctionCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const input_pattern = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const input_flags = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const pattern_is_regexp = try isRegExpObservable(ctx, output, global, input_pattern, caller_function, caller_frame);
    if (pattern_is_regexp and input_flags.isUndefined()) {
        const ctor_key = try ctx.runtime.internAtom("constructor");
        defer ctx.runtime.atoms.free(ctor_key);
        const pattern_constructor = try getValueProperty(ctx, output, global, input_pattern, ctor_key, caller_function, caller_frame);
        defer pattern_constructor.free(ctx.runtime);
        const regexp_key = try ctx.runtime.internAtom("RegExp");
        defer ctx.runtime.atoms.free(regexp_key);
        const regexp_ctor = global.getProperty(regexp_key);
        defer regexp_ctor.free(ctx.runtime);
        if (sameObjectIdentity(pattern_constructor, regexp_ctor)) return input_pattern.dup();
    }

    var owned_source: ?core.JSValue = null;
    defer if (owned_source) |value| value.free(ctx.runtime);
    var owned_pattern: ?core.JSValue = null;
    defer if (owned_pattern) |value| value.free(ctx.runtime);
    var pattern = if (args.len >= 1) args[0] else blk: {
        const empty = try value_ops.createStringValue(ctx.runtime, "");
        owned_pattern = empty;
        break :blk empty;
    };
    if (pattern_is_regexp) {
        if (objectFromValue(pattern)) |pattern_object| {
            if (pattern_object.class_id != core.class.ids.regexp) {
                const source = try getValueProperty(ctx, output, global, pattern, core.atom.ids.source, caller_function, caller_frame);
                owned_source = source;
                pattern = source;
            }
        }
    }
    if (pattern.isObject() and !pattern_is_regexp) {
        const pattern_object = objectFromValue(pattern) orelse return error.TypeError;
        if (pattern_object.class_id != core.class.ids.regexp) {
            const string_value = try toStringForAnnexB(ctx, output, global, pattern, caller_function, caller_frame);
            owned_pattern = string_value;
            pattern = string_value;
        }
    }

    var owned_flags: ?core.JSValue = null;
    defer if (owned_flags) |value| value.free(ctx.runtime);
    var flags = if (!input_flags.isUndefined())
        input_flags
    else if (pattern_is_regexp) blk: {
        const pattern_object = objectFromValue(input_pattern) orelse break :blk input_flags;
        if (pattern_object.class_id == core.class.ids.regexp) break :blk input_flags;
        const flags_key = try ctx.runtime.internAtom("flags");
        defer ctx.runtime.atoms.free(flags_key);
        const pattern_flags = try getValueProperty(ctx, output, global, input_pattern, flags_key, caller_function, caller_frame);
        owned_flags = pattern_flags;
        break :blk pattern_flags;
    } else blk: {
        const empty = try value_ops.createStringValue(ctx.runtime, "");
        owned_flags = empty;
        break :blk empty;
    };
    if (!flags.isUndefined() and flags.isObject()) {
        const string_value = try toStringForAnnexB(ctx, output, global, flags, caller_function, caller_frame);
        if (owned_flags) |old| old.free(ctx.runtime);
        owned_flags = string_value;
        flags = string_value;
    }

    return constructRegExpRecord(ctx, output, global, constructorPrototypeFromGlobal(ctx.runtime, global, "RegExp"), pattern, flags, caller_function, caller_frame);
}

pub fn qjsRegExpConstructCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    new_target: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const input_pattern = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const input_flags = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    if ((input_pattern.isString() or input_pattern.isUndefined()) and
        (input_flags.isString() or input_flags.isUndefined()))
    {
        // Both operands are already string/undefined primitives, so the
        // construct record's value path runs no observable coercion: thread
        // the (pattern, flags) values straight through the table. (The former
        // borrowed-Latin1 fast path produced an identical object for these
        // inputs and is subsumed here now that the construct logic is owned by
        // the record.)
        const prototype = try reflectConstructPrototypeVm(ctx, output, global, "RegExp", new_target, caller_function, caller_frame);
        return constructRegExpRecord(ctx, output, global, prototype, input_pattern, input_flags, caller_function, caller_frame);
    }
    const pattern_is_regexp = try isRegExpObservable(ctx, output, global, input_pattern, caller_function, caller_frame);

    var owned_source: ?core.JSValue = null;
    defer if (owned_source) |value| value.free(ctx.runtime);
    var owned_pattern: ?core.JSValue = null;
    defer if (owned_pattern) |value| value.free(ctx.runtime);
    var pattern = if (args.len >= 1) args[0] else blk: {
        const empty = try value_ops.createStringValue(ctx.runtime, "");
        owned_pattern = empty;
        break :blk empty;
    };
    if (pattern.isUndefined()) {
        const empty = try value_ops.createStringValue(ctx.runtime, "");
        owned_pattern = empty;
        pattern = empty;
    } else if (pattern_is_regexp) {
        if (objectFromValue(pattern)) |pattern_object| {
            if (pattern_object.class_id == core.class.ids.regexp) {
                const source = try regexpInternalStringValue(pattern_object, true);
                owned_source = source;
                pattern = source;
            } else {
                const source = try getValueProperty(ctx, output, global, pattern, core.atom.ids.source, caller_function, caller_frame);
                owned_source = source;
                pattern = source;
            }
        }
    } else if (pattern.isObject()) {
        const pattern_object = objectFromValue(pattern) orelse return error.TypeError;
        if (pattern_object.class_id != core.class.ids.regexp) {
            const string_value = try toStringForAnnexB(ctx, output, global, pattern, caller_function, caller_frame);
            owned_pattern = string_value;
            pattern = string_value;
        }
    }

    var owned_flags: ?core.JSValue = null;
    defer if (owned_flags) |value| value.free(ctx.runtime);
    var flags = if (!input_flags.isUndefined())
        input_flags
    else if (pattern_is_regexp) blk: {
        const pattern_object = objectFromValue(input_pattern) orelse break :blk core.JSValue.undefinedValue();
        if (pattern_object.class_id == core.class.ids.regexp) {
            const pattern_flags = try regexpInternalStringValue(pattern_object, false);
            owned_flags = pattern_flags;
            break :blk pattern_flags;
        }
        const flags_key = try ctx.runtime.internAtom("flags");
        defer ctx.runtime.atoms.free(flags_key);
        const pattern_flags = try getValueProperty(ctx, output, global, input_pattern, flags_key, caller_function, caller_frame);
        owned_flags = pattern_flags;
        break :blk pattern_flags;
    } else core.JSValue.undefinedValue();
    if (!flags.isUndefined() and flags.isObject()) {
        const string_value = try toStringForAnnexB(ctx, output, global, flags, caller_function, caller_frame);
        if (owned_flags) |old| old.free(ctx.runtime);
        owned_flags = string_value;
        flags = string_value;
    }

    const prototype = try reflectConstructPrototypeVm(ctx, output, global, "RegExp", new_target, caller_function, caller_frame);
    return constructRegExpRecord(ctx, output, global, prototype, pattern, flags, caller_function, caller_frame);
}

pub fn qjsRegExpExecMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const regexp_object = property_ops.expectObject(this_value) catch {
        return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "RegExp object expected"));
    };
    if (regexp_object.class_id != core.class.ids.regexp) {
        return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "RegExp object expected"));
    }
    const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    var owned_string: ?core.JSValue = null;
    defer if (owned_string) |value| value.free(ctx.runtime);
    const string_value = if (input.isString()) input else blk: {
        const value = try toStringForAnnexB(ctx, output, global, input, caller_function, caller_frame);
        owned_string = value;
        break :blk value;
    };
    return qjsRegExpExecResult(ctx, output, global, this_value, regexp_object, string_value, true, caller_function, caller_frame);
}

pub fn qjsRegExpTestMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const receiver_object = property_ops.expectObject(this_value) catch {
        return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "RegExp object expected"));
    };
    const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    var owned_string: ?core.JSValue = null;
    defer if (owned_string) |value| value.free(ctx.runtime);
    const string_value = if (input.isString()) input else blk: {
        const value = try toStringForAnnexB(ctx, output, global, input, caller_function, caller_frame);
        owned_string = value;
        break :blk value;
    };
    const exec_atom = core.atom.predefinedId("exec", .string) orelse return error.TypeError;
    if (qjsRegExpPrototypeMethodIsDefault(ctx.runtime, receiver_object, exec_atom, @intFromEnum(method_ids.regexp.PrototypeMethod.exec))) {
        if (try qjsRegExpTestFastNoResult(ctx, receiver_object, string_value)) |matched| {
            return core.JSValue.boolean(matched);
        }
        const result = try qjsRegExpExecResult(ctx, output, global, this_value, receiver_object, string_value, true, caller_function, caller_frame) orelse return core.JSValue.boolean(false);
        defer result.free(ctx.runtime);
        return core.JSValue.boolean(!result.isNull());
    }

    const result = try qjsRegExpExecGeneric(ctx, output, global, this_value, string_value, caller_function, caller_frame);
    defer result.free(ctx.runtime);
    return core.JSValue.boolean(!result.isNull());
}

pub const RegExpBorrowedSourceFlags = struct {
    source: []const u8,
    flags: []const u8,
};

pub fn qjsRegExpTestFastNoResult(
    ctx: *core.JSContext,
    regexp_object: *core.Object,
    string_value: core.JSValue,
) !?bool {
    if (!regExpLastIndexCanSkipCoercion(regexp_object)) return null;

    const borrowed_source_flags = regexpBorrowedLatin1SourceFlags(regexp_object);
    if (borrowed_source_flags) |borrowed| {
        const flags = borrowed.flags;
        const is_global = std.mem.indexOfScalar(u8, flags, 'g') != null;
        const is_sticky = std.mem.indexOfScalar(u8, flags, 'y') != null;
        if (is_global or is_sticky) return null;

        if (!regexpSourceUsesZigPropertyFallback(borrowed.source, flags)) {
            if (simpleLatin1LiteralPlusLiteralMatch(borrowed.source, flags, string_value)) |matched| {
                return matched;
            }
            if (nativeFunctionMatcherUnicodeClassAsciiResult(borrowed.source, flags, string_value, 0)) |matched| {
                return matched;
            }
            const full_unicode = regExpFlagsContain(flags, 'u') or regExpFlagsContain(flags, 'v');
            if (full_unicode and parseUnicodeAstralSpecialSource(borrowed.source) != null) {
                return unicodeAstralSpecialMatch(borrowed.source, string_value, 0, false, true) != null;
            }
            if (full_unicode and std.mem.eql(u8, borrowed.source, "^\\S$")) {
                return anchoredSingleNonWhitespaceMatches(string_value, true);
            }
            if (full_unicode and singleLowSurrogateLiteralSource(borrowed.source) != null) {
                return unicodeLowSurrogateLiteralMatch(borrowed.source, string_value, 0, false) != null;
            }
            if (full_unicode) {
                if (simpleUnicodePropertyRunTestFast(borrowed.source, flags, string_value)) |matched| {
                    return matched;
                }
            }
            if (simpleClassEscapeTestFast(borrowed.source, flags, string_value)) |matched| {
                return matched;
            }
            if (simpleAsciiLiteralTestFast(borrowed.source, flags, string_value)) |matched| {
                return matched;
            }
            if (simpleAsciiLiteralClassPlusLiteralTestFast(borrowed.source, flags, string_value)) |matched| {
                return matched;
            }
            if (isSimpleUnicodeLiteralSource(borrowed.source)) {
                return simpleUnicodeLiteralMatch(borrowed.source, string_value, 0, false, flags) != null;
            }
            if (parseSimpleClassSequenceLatin1Source(borrowed.source, flags)) |pattern| {
                return simpleClassSequenceMatchPattern(pattern, string_value, 0, false, flags) != null;
            }
            if (parseSimpleCaptureSequenceSource(borrowed.source, flags)) |pattern| {
                return simpleCaptureSequenceMatchPattern(pattern, string_value, 0, false, flags) != null;
            }
        }
    }

    const cached_bytecode = regexp_object.regexpCompiledBytecode();
    if (cached_bytecode.len != 0) {
        const compiled = regexp_adapter.Compiled{ .bytecode = @constCast(cached_bytecode) };
        const flag_bits = compiled.flagBits();
        if ((flag_bits & (regexp_adapter.flag_bits.global | regexp_adapter.flag_bits.sticky)) != 0) return null;
        return regexp_adapter.testOnStringFromIndex(ctx.runtime, compiled, string_value, 0) catch |err| switch (err) {
            error.BytecodeCorrupt, error.Timeout => return null,
            else => return err,
        };
    }

    const borrowed = borrowed_source_flags orelse return null;
    const flags = borrowed.flags;
    const is_global = std.mem.indexOfScalar(u8, flags, 'g') != null;
    const is_sticky = std.mem.indexOfScalar(u8, flags, 'y') != null;
    if (is_global or is_sticky) return null;
    if (regexpSourceUsesZigPropertyFallback(borrowed.source, flags)) return null;
    if (!bytesAreAscii(borrowed.source)) return null;

    if (regexp_object.regexpCompiledBytecode().len == 0) {
        var compiled = regexp_adapter.compile(ctx.runtime.memory.allocator, borrowed.source, flags) catch |err| switch (err) {
            error.InvalidPattern, error.Unsupported => return null,
            else => |other| return other,
        };
        defer compiled.deinit(ctx.runtime.memory.allocator);
        try regexp_object.setRegexpCompiledBytecode(ctx.runtime, compiled.bytecode);
    }
    const compiled = regexp_adapter.Compiled{ .bytecode = @constCast(regexp_object.regexpCompiledBytecode()) };

    return regexp_adapter.testOnStringFromIndex(ctx.runtime, compiled, string_value, 0) catch |err| switch (err) {
        error.BytecodeCorrupt, error.Timeout => return null,
        else => return err,
    };
}

pub fn simpleClassEscapeTestFast(source: []const u8, flags: []const u8, string_value: core.JSValue) ?bool {
    if (!isSimpleStringClassEscapeSource(source)) return null;
    if (regExpFlagsContain(flags, 'i')) return null;
    return findStringClassEscapeMatch(string_value, source, 0) != null;
}

pub fn simpleAsciiLiteralTestFast(source: []const u8, flags: []const u8, string_value: core.JSValue) ?bool {
    if (flags.len != 0 or source.len == 0) return null;
    for (source) |byte| {
        if (!isPlainAsciiRegExpLiteral(byte)) return null;
    }
    const input = latin1StringSlice(string_value) orelse return null;
    return std.mem.indexOf(u8, input, source) != null;
}

pub const SimpleAsciiLiteralClassPlusLiteral = struct {
    prefix: []const u8,
    class_source: []const u8,
    suffix: []const u8,
};

pub fn simpleAsciiLiteralClassPlusLiteralTestFast(source: []const u8, flags: []const u8, string_value: core.JSValue) ?bool {
    if (flags.len != 0) return null;
    const pattern = parseSimpleAsciiLiteralClassPlusLiteral(source) orelse return null;
    const input = latin1StringSlice(string_value) orelse return null;
    return simpleAsciiLiteralClassPlusLiteralMatchBytes(pattern, input);
}

pub fn parseSimpleAsciiLiteralClassPlusLiteral(source: []const u8) ?SimpleAsciiLiteralClassPlusLiteral {
    if (source.len < 3) return null;

    var index: usize = 0;
    while (index < source.len and isPlainAsciiRegExpLiteral(source[index])) : (index += 1) {}

    const class_start = index;
    const class_end = blk: {
        if (index + 2 < source.len and source[index] == '\\' and isSimpleClassEscapeByte(source[index + 1]) and source[index + 2] == '+') {
            index += 3;
            break :blk class_start + 2;
        }
        if (index + 3 < source.len and source[index] == '\\' and source[index + 1] == '\\' and isSimpleClassEscapeByte(source[index + 2]) and source[index + 3] == '+') {
            index += 4;
            break :blk class_start + 3;
        }
        return null;
    };

    const suffix_start = index;
    while (index < source.len and isPlainAsciiRegExpLiteral(source[index])) : (index += 1) {}
    if (index != source.len) return null;
    if (class_start == 0 and suffix_start == source.len) return null;

    return .{
        .prefix = source[0..class_start],
        .class_source = source[class_end - 2 .. class_end],
        .suffix = source[suffix_start..],
    };
}

pub fn isPlainAsciiRegExpLiteral(ch: u8) bool {
    if (ch >= '0' and ch <= '9') return true;
    if (ch >= 'A' and ch <= 'Z') return true;
    if (ch >= 'a' and ch <= 'z') return true;
    return switch (ch) {
        '_', ' ' => true,
        else => false,
    };
}

pub fn regexpBorrowedLatin1SourceFlags(object: *core.Object) ?RegExpBorrowedSourceFlags {
    const source_value = object.regexpSource() orelse return null;
    const flags_value = object.regexpFlags() orelse return null;
    const source = latin1StringSlice(source_value) orelse return null;
    const flags = latin1StringSlice(flags_value) orelse return null;
    return .{ .source = source, .flags = flags };
}

pub fn regExpLastIndexCanSkipCoercion(object: *core.Object) bool {
    const value = object.regexpLastIndex() orelse return false;
    if (value.isObject() or value.isBigInt() or value.isSymbol()) return false;
    return true;
}

pub fn qjsRegExpCompile(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const regexp_object = property_ops.expectObject(this_value) catch return null;
    if (regexp_object.class_id != core.class.ids.regexp) return null;
    const expected_prototype = regExpPrototypeFromGlobal(ctx.runtime, global) orelse
        return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "RegExp object expected"));
    if (regexp_object.getPrototype() != expected_prototype) {
        return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "RegExp object expected"));
    }

    const pattern = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const flags = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();

    const source_value = blk: {
        if (objectFromValue(pattern)) |pattern_object| {
            if (pattern_object.class_id == core.class.ids.regexp) {
                if (!flags.isUndefined()) return error.TypeError;
                break :blk try regexpInternalStringValue(pattern_object, true);
            }
        }
        if (pattern.isUndefined()) break :blk try value_ops.createStringValue(ctx.runtime, "");
        break :blk try toStringForAnnexB(ctx, output, global, pattern, caller_function, caller_frame);
    };
    defer source_value.free(ctx.runtime);

    const flags_value = blk: {
        if (objectFromValue(pattern)) |pattern_object| {
            if (pattern_object.class_id == core.class.ids.regexp) {
                break :blk try regexpInternalStringValue(pattern_object, false);
            }
        }
        if (flags.isUndefined()) break :blk try value_ops.createStringValue(ctx.runtime, "");
        break :blk try toStringForAnnexB(ctx, output, global, flags, caller_function, caller_frame);
    };
    defer flags_value.free(ctx.runtime);

    var source_bytes = std.ArrayList(u8).empty;
    defer source_bytes.deinit(ctx.runtime.memory.allocator);
    try value_ops.appendValueString(ctx.runtime, &source_bytes, source_value);
    var flag_bytes = std.ArrayList(u8).empty;
    defer flag_bytes.deinit(ctx.runtime.memory.allocator);
    try value_ops.appendValueString(ctx.runtime, &flag_bytes, flags_value);
    if (!regexp_validate.validatePatternAndFlags(source_bytes.items, flag_bytes.items)) return error.SyntaxError;

    const next_source = source_value.dup();
    var next_source_owned = true;
    errdefer if (next_source_owned) next_source.free(ctx.runtime);
    const next_flags = flags_value.dup();
    var next_flags_owned = true;
    errdefer if (next_flags_owned) next_flags.free(ctx.runtime);
    const source_slot = regexp_object.regexpSourceSlot();
    const flags_slot = regexp_object.regexpFlagsSlot();

    const old_source = source_slot.*;
    const old_flags = flags_slot.*;
    source_slot.* = next_source;
    next_source_owned = false;
    flags_slot.* = next_flags;
    next_flags_owned = false;
    if (old_source) |value| value.free(ctx.runtime);
    if (old_flags) |value| value.free(ctx.runtime);
    regexp_object.clearRegexpCompiledBytecode(ctx.runtime);

    try setValuePropertyStrict(ctx, output, global, this_value, core.atom.ids.lastIndex, core.JSValue.int32(0), caller_function, caller_frame);
    return this_value.dup();
}

pub fn qjsRegExpSpeciesConstructor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const regexp_atom = try ctx.runtime.internAtom("RegExp");
    defer ctx.runtime.atoms.free(regexp_atom);
    const default_constructor = global.getProperty(regexp_atom);

    const constructor_value = try getValueProperty(ctx, output, global, rx, core.atom.ids.constructor, caller_function, caller_frame);
    defer constructor_value.free(ctx.runtime);
    if (constructor_value.isUndefined()) return default_constructor;
    if (!constructor_value.isObject()) {
        default_constructor.free(ctx.runtime);
        return error.TypeError;
    }

    const species_atom = core.atom.predefinedId("Symbol.species", .symbol) orelse {
        default_constructor.free(ctx.runtime);
        return error.TypeError;
    };
    const species_value = try getValueProperty(ctx, output, global, constructor_value, species_atom, caller_function, caller_frame);
    defer species_value.free(ctx.runtime);
    if (species_value.isUndefined() or species_value.isNull()) return default_constructor;
    default_constructor.free(ctx.runtime);
    return species_value.dup();
}

pub fn isDefaultRegExpConstructor(rt: *core.JSRuntime, global: *core.Object, value: core.JSValue) bool {
    const regexp_atom = rt.internAtom("RegExp") catch return false;
    defer rt.atoms.free(regexp_atom);
    const default_constructor = global.getProperty(regexp_atom);
    defer default_constructor.free(rt);
    return sameObjectIdentity(default_constructor, value);
}

pub fn regExpFlagsAreFullUnicode(rt: *core.JSRuntime, flags_string: core.JSValue) !bool {
    return try qjsStringValueContainsByte(rt, flags_string, 'u') or
        try qjsStringValueContainsByte(rt, flags_string, 'v');
}

pub fn qjsRegExpExecSimpleUnicodeLiteral(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    string_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const regexp_object = property_ops.expectObject(rx) catch return null;
    if (regexp_object.class_id != core.class.ids.regexp) return null;
    var source = std.ArrayList(u8).empty;
    defer source.deinit(ctx.runtime.memory.allocator);
    if (!try appendRegExpSource(ctx.runtime, regexp_object, &source)) return null;
    if (!isSimpleUnicodeLiteralSource(source.items)) return null;
    return (try qjsRegExpExecResult(ctx, output, global, rx, regexp_object, string_value, true, caller_function, caller_frame)) orelse null;
}

pub fn regexpInternalFlagsContain(regexp_object: *core.Object, needle: u8) bool {
    if (regexp_object.regexpFlags()) |flags_value| return stringValueContainsUnitByte(flags_value, needle);
    return false;
}

pub fn regexpInternalSimpleQuantifiedClassSource(regexp_object: *core.Object) ?[]const u8 {
    if (regexp_object.regexpSource()) |source_value| return simpleQuantifiedClassSourceFromValue(source_value);
    return null;
}

pub fn simpleQuantifiedClassSourceFromValue(source_value: core.JSValue) ?[]const u8 {
    const sources = [_][]const u8{
        "\\d+",   "\\D+",   "\\s+",   "\\S+",   "\\w+",   "\\W+",
        "\\\\d+", "\\\\D+", "\\\\s+", "\\\\S+", "\\\\w+", "\\\\W+",
    };
    for (sources) |source| {
        if (stringValueUnitsEqualBytes(source_value, source)) return source;
    }
    return null;
}

pub fn setRegExpLastIndexZero(rt: *core.JSRuntime, regexp_object: *core.Object) !void {
    regexp_object.setProperty(rt, core.atom.ids.lastIndex, core.JSValue.int32(0)) catch |err| switch (err) {
        error.ReadOnly, error.AccessorWithoutSetter, error.NotExtensible => return error.TypeError,
        else => return err,
    };
}

pub fn appendNamedCaptureSubstitution(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    named_captures: core.JSValue,
    replacement: []const u16,
    index: *usize,
    out: *std.ArrayList(u16),
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    if (named_captures.isUndefined()) return false;
    const name_start = index.* + 2;
    const name_end = std.mem.indexOfScalarPos(u16, replacement, name_start, '>') orelse return false;
    var name = std.ArrayList(u8).empty;
    defer name.deinit(ctx.runtime.memory.allocator);
    try appendUtf16UnitsAsUtf8(ctx.runtime, &name, replacement[name_start..name_end]);
    const atom = try ctx.runtime.internAtom(name.items);
    defer ctx.runtime.atoms.free(atom);
    const capture = try getValueProperty(ctx, output, global, named_captures, atom, caller_function, caller_frame);
    defer capture.free(ctx.runtime);
    if (!capture.isUndefined()) {
        const capture_string = try toStringForAnnexB(ctx, output, global, capture, caller_function, caller_frame);
        defer capture_string.free(ctx.runtime);
        try appendStringValueUnits(ctx.runtime, out, capture_string);
    }
    index.* = name_end;
    return true;
}

pub fn qjsRegExpExecGeneric(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    string_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const exec_atom = core.atom.predefinedId("exec", .string) orelse return error.TypeError;
    const exec_method = try getValueProperty(ctx, output, global, rx, exec_atom, caller_function, caller_frame);
    defer exec_method.free(ctx.runtime);
    if (!exec_method.isUndefined() and !exec_method.isNull()) {
        if (isCallableValue(exec_method)) {
            const result = try callValueOrBytecode(ctx, output, global, rx, exec_method, &.{string_value}, caller_function, caller_frame);
            if (!result.isNull() and !result.isObject()) {
                result.free(ctx.runtime);
                return error.TypeError;
            }
            return result;
        }
        const rx_object = objectFromValue(rx) orelse return error.TypeError;
        if (rx_object.class_id != core.class.ids.regexp) return error.TypeError;
    }
    return (try qjsRegExpExecMethod(ctx, output, global, rx, &.{string_value}, caller_function, caller_frame)) orelse error.TypeError;
}

pub fn qjsRegExpAccessor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    getter_value: core.JSValue,
    name: []const u8,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (std.mem.eql(u8, name, "flags")) {
        if (this_value.isNull() or this_value.isUndefined()) return error.TypeError;
        if (!this_value.isObject()) return error.TypeError;
        var flags = std.ArrayList(u8).empty;
        defer flags.deinit(ctx.runtime.memory.allocator);
        const names = [_][]const u8{ "hasIndices", "global", "ignoreCase", "multiline", "dotAll", "unicode", "unicodeSets", "sticky" };
        const chars = [_]u8{ 'd', 'g', 'i', 'm', 's', 'u', 'v', 'y' };
        for (names, chars) |prop_name, flag_char| {
            const atom = try ctx.runtime.internAtom(prop_name);
            defer ctx.runtime.atoms.free(atom);
            const value = try getValueProperty(ctx, output, global, this_value, atom, caller_function, caller_frame);
            defer value.free(ctx.runtime);
            if (valueTruthy(value)) try flags.append(ctx.runtime.memory.allocator, flag_char);
        }
        return (try core.string.String.createUtf8(ctx.runtime, flags.items)).value();
    }
    const object = property_ops.expectObject(this_value) catch return null;
    if (std.mem.eql(u8, name, "source")) {
        if (try isSameRealmRegExpPrototypeGetter(ctx.runtime, global, object, name, getter_value)) return try value_ops.createStringValue(ctx.runtime, "(?:)");
        if (!objectHasRegExpInternalSlots(object)) return throwRegExpAccessorTypeError(ctx, global, getter_value);
        return null;
    }
    if (!std.mem.eql(u8, name, "source")) {
        if (try isSameRealmRegExpPrototypeGetter(ctx.runtime, global, object, name, getter_value)) return core.JSValue.undefinedValue();
        if (!objectHasRegExpInternalSlots(object)) return throwRegExpAccessorTypeError(ctx, global, getter_value);
    }
    return null;
}

pub fn qjsRegExpLegacyAccessor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    method: method_ids.regexp.LegacyAccessorMethod,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const owner_global = function_object.functionRealmGlobalPtr() orelse global;
    const regexp_ctor = try regExpConstructorFromGlobal(ctx.runtime, owner_global);
    const receiver = objectFromValue(this_value) orelse return throwTypeErrorMessage(ctx, owner_global, "RegExp legacy accessor receiver mismatch");
    if (receiver != regexp_ctor) return throwTypeErrorMessage(ctx, owner_global, "RegExp legacy accessor receiver mismatch");

    const legacy = try regexp_ctor.ensureRegExpLegacyStatics(ctx.runtime);
    switch (method) {
        .set_input => {
            try materializeRegExpLegacyNoCaptureSlots(ctx.runtime, regexp_ctor, legacy);
            const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const string_value = try toStringForAnnexB(ctx, output, owner_global, input, caller_function, caller_frame);
            defer string_value.free(ctx.runtime);
            try replaceRegExpLegacySlot(ctx.runtime, regexp_ctor, &legacy.input, string_value);
            return core.JSValue.undefinedValue();
        },
        .get_input => return regExpLegacySlotValue(ctx.runtime, legacy.input),
        .get_last_match => return regExpLegacyNoCaptureSliceValue(ctx.runtime, legacy, .match) orelse regExpLegacySlotValue(ctx.runtime, legacy.last_match),
        .get_last_paren => return regExpLegacyCaptureSliceValue(ctx.runtime, legacy, legacy.last_paren) orelse regExpLegacySlotValue(ctx.runtime, legacy.last_paren),
        .get_left_context => return regExpLegacyNoCaptureSliceValue(ctx.runtime, legacy, .left) orelse regExpLegacySlotValue(ctx.runtime, legacy.left_context),
        .get_right_context => return regExpLegacyNoCaptureSliceValue(ctx.runtime, legacy, .right) orelse regExpLegacySlotValue(ctx.runtime, legacy.right_context),
        else => {
            const capture_index = core.host_function.builtin_method_id_lookup.regexp.legacyCaptureIndex(method) orelse return error.TypeError;
            return regExpLegacyCaptureSliceValue(ctx.runtime, legacy, legacy.captures[capture_index]) orelse regExpLegacySlotValue(ctx.runtime, legacy.captures[capture_index]);
        },
    }
}

pub fn regExpConstructorFromGlobal(rt: *core.JSRuntime, global: *core.Object) !*core.Object {
    if (global.cachedRealmValue(.regexp_constructor)) |stored| {
        return objectFromValue(stored) orelse error.TypeError;
    }
    const key = try rt.internAtom("RegExp");
    defer rt.atoms.free(key);
    const value = global.getProperty(key);
    defer value.free(rt);
    return objectFromValue(value) orelse error.TypeError;
}

pub fn regExpLegacySlotValue(rt: *core.JSRuntime, slot: ?core.JSValue) !core.JSValue {
    if (slot) |stored| return stored.dup();
    return value_ops.createStringValue(rt, "");
}

pub fn materializeRegExpLegacyNoCaptureSlots(rt: *core.JSRuntime, owner: *core.Object, legacy: anytype) !void {
    if (!legacy.lazy_no_capture_match) return;
    const input = legacy.input orelse {
        legacy.lazy_no_capture_match = false;
        return;
    };

    const matched = try stringSliceValue(rt, input, legacy.lazy_match_index, legacy.lazy_match_len);
    defer matched.free(rt);
    try replaceRegExpLegacySlot(rt, owner, &legacy.last_match, matched);

    if (legacy.lazy_match_index == 0) {
        clearRegExpLegacySlot(rt, &legacy.left_context);
    } else {
        const left = try stringSliceValue(rt, input, 0, legacy.lazy_match_index);
        defer left.free(rt);
        try replaceRegExpLegacySlot(rt, owner, &legacy.left_context, left);
    }

    const right_start = @min(legacy.lazy_match_index + legacy.lazy_match_len, legacy.lazy_input_len);
    if (right_start >= legacy.lazy_input_len) {
        clearRegExpLegacySlot(rt, &legacy.right_context);
    } else {
        const right = try stringSliceValue(rt, input, right_start, legacy.lazy_input_len - right_start);
        defer right.free(rt);
        try replaceRegExpLegacySlot(rt, owner, &legacy.right_context, right);
    }

    if (regExpLegacyCaptureSliceValue(rt, legacy, legacy.last_paren)) |last_paren| {
        defer last_paren.free(rt);
        try replaceRegExpLegacySlot(rt, owner, &legacy.last_paren, last_paren);
    }
    for (&legacy.captures) |*capture_slot| {
        if (regExpLegacyCaptureSliceValue(rt, legacy, capture_slot.*)) |capture| {
            defer capture.free(rt);
            try replaceRegExpLegacySlot(rt, owner, capture_slot, capture);
        }
    }
    legacy.lazy_no_capture_match = false;
}

pub fn regExpLegacyCaptureSliceValue(rt: *core.JSRuntime, legacy: anytype, slot: ?core.JSValue) ?core.JSValue {
    if (!legacy.lazy_no_capture_match) return null;
    const input = legacy.input orelse return null;
    const encoded = slot orelse return null;
    const slice = decodeRegExpLegacyCaptureSlice(encoded) orelse return null;
    return stringSliceValue(rt, input, slice.start, slice.len) catch null;
}

pub fn clearRegExpLegacySlot(rt: *core.JSRuntime, slot: *?core.JSValue) void {
    const old_value = slot.*;
    slot.* = null;
    if (old_value) |old| old.free(rt);
}

pub fn getRegExpLastIndexLength(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    regexp_object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !usize {
    if (objectFromValue(regexp_value) == regexp_object) {
        if (regexp_object.regexpLastIndex()) |stored| {
            if (fastToLengthIndex(stored)) |index| return index;
        }
    }
    const last_index_value = try getValueProperty(ctx, output, global, regexp_value, core.atom.ids.lastIndex, caller_function, caller_frame);
    defer last_index_value.free(ctx.runtime);
    return try toLengthIndex(ctx, output, global, last_index_value);
}

pub fn setRegExpLastIndexStrict(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    regexp_object: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    if (objectFromValue(regexp_value) == regexp_object and regexp_object.regexpLastIndex() != null) {
        if (!regexp_object.regexpLastIndexWritable()) return error.TypeError;
        const slot = regexp_object.regexpLastIndexSlot();
        try regexp_object.setOptionalValueSlot(ctx.runtime, slot, value.dup());
        return;
    }
    try setValuePropertyStrict(ctx, output, global, regexp_value, core.atom.ids.lastIndex, value, caller_function, caller_frame);
}

pub fn qjsRegExpExecResult(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    regexp_object: *core.Object,
    string_value: core.JSValue,
    use_last_index: bool,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const rt = ctx.runtime;
    const input_len = try stringLengthIndex(rt, string_value);
    const initial_last_index = if (use_last_index)
        try getRegExpLastIndexLength(ctx, output, global, regexp_value, regexp_object, caller_function, caller_frame)
    else
        0;

    switch (try qjsRegExpExecSimpleCaptureSequenceResult(ctx, output, global, regexp_value, regexp_object, string_value, use_last_index, input_len, initial_last_index, caller_function, caller_frame)) {
        .unsupported => {},
        .value => |value| return value,
    }

    switch (try qjsRegExpExecSimpleClassAlternationResult(ctx, output, global, regexp_value, regexp_object, string_value, use_last_index, input_len, initial_last_index, caller_function, caller_frame)) {
        .unsupported => {},
        .value => |value| return value,
    }

    const cached_bytecode = regexp_object.regexpCompiledBytecode();
    if (cached_bytecode.len != 0) {
        const compiled = regexp_adapter.Compiled{ .bytecode = @constCast(cached_bytecode) };
        const bits = compiled.flagBits();
        const is_global = (bits & regexp_adapter.flag_bits.global) != 0;
        const is_sticky = (bits & regexp_adapter.flag_bits.sticky) != 0;
        const has_indices = (bits & regexp_adapter.flag_bits.indices) != 0;
        const start_index = if (use_last_index and (is_global or is_sticky)) initial_last_index else 0;
        if (start_index > input_len) {
            if (use_last_index and (is_global or is_sticky)) {
                try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
            }
            return core.JSValue.nullValue();
        }
        return try qjsRegExpExecCompiledResult(ctx, output, global, regexp_value, regexp_object, string_value, compiled, use_last_index, is_global, is_sticky, has_indices, start_index, caller_function, caller_frame);
    }

    var source = std.ArrayList(u8).empty;
    defer source.deinit(rt.memory.allocator);
    if (!try appendRegExpSource(rt, regexp_object, &source)) return null;

    var flags = std.ArrayList(u8).empty;
    defer flags.deinit(rt.memory.allocator);
    if (!try appendRegExpFlags(rt, regexp_object, &flags)) return null;

    const is_global = std.mem.indexOfScalar(u8, flags.items, 'g') != null;
    const is_sticky = std.mem.indexOfScalar(u8, flags.items, 'y') != null;
    const has_indices = std.mem.indexOfScalar(u8, flags.items, 'd') != null;
    const start_index = if (use_last_index and (is_global or is_sticky)) initial_last_index else 0;

    if (start_index > input_len) {
        if (use_last_index and (is_global or is_sticky)) {
            try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
        }
        return core.JSValue.nullValue();
    }

    if (regexpSourceUsesZigPropertyFallback(source.items, flags.items)) {
        return try qjsRegExpExecPropertyFallback(ctx, output, global, regexp_value, source.items, flags.items, string_value, use_last_index, is_global, is_sticky, has_indices, input_len, start_index, caller_function, caller_frame);
    }
    const full_unicode = regExpFlagsContain(flags.items, 'u') or regExpFlagsContain(flags.items, 'v');
    if (nativeFunctionMatcherUnicodeClassAsciiResult(source.items, flags.items, string_value, start_index)) |matched| {
        if (!matched) return core.JSValue.nullValue();
        const found = RegExpMatch{
            .index = start_index,
            .len = 1,
            .capture_count = 0,
        };
        return try createRegExpMatchArrayFromValue(rt, global, string_value, found, has_indices);
    }
    if (full_unicode and parseUnicodeAstralSpecialSource(source.items) != null) {
        if (unicodeAstralSpecialMatch(source.items, string_value, start_index, is_sticky, true)) |found| {
            if (use_last_index and (is_global or is_sticky)) {
                const next_index = found.index + found.len;
                const next_value = if (next_index <= @as(usize, @intCast(std.math.maxInt(i32))))
                    core.JSValue.int32(@intCast(next_index))
                else
                    core.JSValue.float64(@floatFromInt(next_index));
                try setValuePropertyStrict(ctx, output, global, regexp_value, core.atom.ids.lastIndex, next_value, caller_function, caller_frame);
            }
            return try createRegExpMatchArrayFromValue(rt, global, string_value, found, has_indices);
        }
        if (use_last_index and (is_global or is_sticky)) {
            try setValuePropertyStrict(ctx, output, global, regexp_value, core.atom.ids.lastIndex, core.JSValue.int32(0), caller_function, caller_frame);
        }
        return core.JSValue.nullValue();
    }
    if (full_unicode and std.mem.eql(u8, source.items, "^\\S$")) {
        if (start_index == 0 and anchoredSingleNonWhitespaceMatches(string_value, true)) {
            const found = RegExpMatch{ .index = 0, .len = input_len, .capture_count = 0 };
            if (use_last_index and (is_global or is_sticky)) {
                const next_value = if (input_len <= @as(usize, @intCast(std.math.maxInt(i32))))
                    core.JSValue.int32(@intCast(input_len))
                else
                    core.JSValue.float64(@floatFromInt(input_len));
                try setValuePropertyStrict(ctx, output, global, regexp_value, core.atom.ids.lastIndex, next_value, caller_function, caller_frame);
            }
            return try createRegExpMatchArrayFromValue(rt, global, string_value, found, has_indices);
        }
        if (use_last_index and (is_global or is_sticky)) {
            try setValuePropertyStrict(ctx, output, global, regexp_value, core.atom.ids.lastIndex, core.JSValue.int32(0), caller_function, caller_frame);
        }
        return core.JSValue.nullValue();
    }
    if (full_unicode and singleLowSurrogateLiteralSource(source.items) != null) {
        if (unicodeLowSurrogateLiteralMatch(source.items, string_value, start_index, is_sticky)) |found| {
            if (use_last_index and (is_global or is_sticky)) {
                const next_index = found.index + found.len;
                const next_value = if (next_index <= @as(usize, @intCast(std.math.maxInt(i32))))
                    core.JSValue.int32(@intCast(next_index))
                else
                    core.JSValue.float64(@floatFromInt(next_index));
                try setValuePropertyStrict(ctx, output, global, regexp_value, core.atom.ids.lastIndex, next_value, caller_function, caller_frame);
            }
            return try createRegExpMatchArrayFromValue(rt, global, string_value, found, has_indices);
        }
        if (use_last_index and (is_global or is_sticky)) {
            try setValuePropertyStrict(ctx, output, global, regexp_value, core.atom.ids.lastIndex, core.JSValue.int32(0), caller_function, caller_frame);
        }
        return core.JSValue.nullValue();
    }
    if (parseSimpleClassAlternationSource(source.items, flags.items)) |pattern| {
        if (simpleClassAlternationMatchPattern(pattern, string_value, start_index, is_sticky, flags.items)) |found| {
            if (use_last_index and (is_global or is_sticky)) {
                const next_index = found.index + found.len;
                const next_value = if (next_index <= @as(usize, @intCast(std.math.maxInt(i32))))
                    core.JSValue.int32(@intCast(next_index))
                else
                    core.JSValue.float64(@floatFromInt(next_index));
                try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, next_value, caller_function, caller_frame);
            }
            return try createRegExpMatchArrayFromValue(rt, global, string_value, found, has_indices);
        }
        if (use_last_index and (is_global or is_sticky)) {
            try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
        }
        return core.JSValue.nullValue();
    }
    if (regexp_object.regexpCompiledBytecode().len == 0) {
        var compiled = regexp_adapter.compile(rt.memory.allocator, source.items, flags.items) catch |err| switch (err) {
            error.InvalidPattern, error.Unsupported => return try qjsRegExpExecPropertyFallback(ctx, output, global, regexp_value, source.items, flags.items, string_value, use_last_index, is_global, is_sticky, has_indices, input_len, start_index, caller_function, caller_frame),
            else => |other| return other,
        };
        defer compiled.deinit(rt.memory.allocator);
        try regexp_object.setRegexpCompiledBytecode(rt, compiled.bytecode);
    }
    const compiled = regexp_adapter.Compiled{ .bytecode = @constCast(regexp_object.regexpCompiledBytecode()) };

    return try qjsRegExpExecCompiledResult(ctx, output, global, regexp_value, regexp_object, string_value, compiled, use_last_index, is_global, is_sticky, has_indices, start_index, caller_function, caller_frame);
}

pub fn qjsRegExpExecCompiledResult(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    regexp_object: *core.Object,
    string_value: core.JSValue,
    compiled: regexp_adapter.Compiled,
    use_last_index: bool,
    is_global: bool,
    is_sticky: bool,
    has_indices: bool,
    start_index: usize,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const rt = ctx.runtime;
    const status = regexp_adapter.execOnStringFromIndex(rt, compiled, string_value, start_index) catch |err| switch (err) {
        error.BytecodeCorrupt, error.Timeout => return null,
        else => return err,
    };

    switch (status.result) {
        .match => {
            const match = status.match;
            if (use_last_index and (is_global or is_sticky)) {
                const next_index = match.end;
                const next_value = if (next_index <= @as(usize, @intCast(std.math.maxInt(i32))))
                    core.JSValue.int32(@intCast(next_index))
                else
                    core.JSValue.float64(@floatFromInt(next_index));
                try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, next_value, caller_function, caller_frame);
            }

            var found = RegExpMatch{
                .index = match.start,
                .len = match.end - match.start,
                .capture_count = match.capture_count,
            };
            var capture_index: usize = 0;
            while (capture_index < match.capture_count) : (capture_index += 1) {
                const capture = match.captures[capture_index];
                if (capture.start) |capture_start| {
                    const capture_end = capture.end.?;
                    found.captures[capture_index] = .{
                        .start = capture_start,
                        .len = capture_end - capture_start,
                        .undefined = false,
                        .name = capture.name,
                    };
                } else {
                    found.captures[capture_index] = .{
                        .start = 0,
                        .len = 0,
                        .undefined = true,
                        .name = capture.name,
                    };
                }
            }
            return try createRegExpMatchArrayFromValue(rt, global, string_value, found, has_indices);
        },
        .no_match, .out_of_range => {
            if (use_last_index and (is_global or is_sticky)) {
                try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
            }
            return core.JSValue.nullValue();
        },
        .not_available => return null,
    }
}

pub const FastRegExpExecResult = union(enum) {
    unsupported,
    value: core.JSValue,
};

pub const RegExpNoCaptureLengthResult = union(enum) {
    unsupported,
    matched: usize,
    no_match,
};

pub const RegExpNoCaptureLengthLoopAllResult = union(enum) {
    unsupported,
    done: usize,
};

pub const RegExpCountLoopAllResult = union(enum) {
    unsupported,
    done: usize,
};

pub fn qjsRegExpLiteralNoCaptureLengthLoopAll(
    ctx: *core.JSContext,
    global: *core.Object,
    source: []const u8,
    flags: []const u8,
    source_atom: core.Atom,
    flags_atom: core.Atom,
    string_value: core.JSValue,
) !RegExpNoCaptureLengthLoopAllResult {
    const is_global = std.mem.indexOfScalar(u8, flags, 'g') != null;
    const is_sticky = std.mem.indexOfScalar(u8, flags, 'y') != null;
    const has_indices = std.mem.indexOfScalar(u8, flags, 'd') != null;
    if (has_indices or (!is_global and !is_sticky)) return .unsupported;

    const rt = ctx.runtime;
    const input_len = try stringLengthIndex(rt, string_value);
    var total_len: usize = 0;
    var last_found: ?RegExpMatch = null;

    if (std.mem.indexOfScalar(u8, source, '|') != null) {
        const parse_source = rt.atoms.name(source_atom) orelse source;
        const parse_flags = if (flags_atom != core.atom.null_atom) rt.atoms.name(flags_atom) orelse flags else flags;
        const pattern = if (rt.cachedRegExpSimpleClassAlternation(source_atom, flags_atom)) |cached|
            cached
        else blk: {
            const parsed = parseSimpleClassAlternationSource(parse_source, parse_flags) orelse return .unsupported;
            rt.setRegExpSimpleClassAlternationCache(source_atom, flags_atom, parsed);
            break :blk parsed;
        };
        if (simpleClassAlternationLengthLoop(pattern, string_value, 0, is_sticky, flags)) |result| {
            total_len += result.total_len;
            last_found = result.last_found;
        } else {
            var search_start: usize = 0;
            while (true) {
                const found = simpleClassAlternationMatchPattern(pattern, string_value, search_start, is_sticky, flags) orelse break;
                if (found.capture_count != 0 or found.len == 0) return .unsupported;
                total_len += found.len;
                search_start = found.index + found.len;
                last_found = found;
            }
        }
    } else {
        const pattern = parseSimpleClassSequenceSource(source, flags) orelse return .unsupported;
        if (simpleClassSequenceSingleUnitLengthLoop(pattern, string_value, 0, is_sticky)) |result| {
            total_len += result.total_len;
            last_found = result.last_found;
        } else {
            var search_start: usize = 0;
            while (true) {
                const found = simpleClassSequenceMatchPattern(pattern, string_value, search_start, is_sticky, flags) orelse break;
                if (found.capture_count != 0 or found.len == 0) return .unsupported;
                total_len += found.len;
                search_start = found.index + found.len;
                last_found = found;
            }
        }
    }

    if (last_found) |found| try updateRegExpLegacyStaticsNoCaptures(rt, global, string_value, found, input_len);
    return .{ .done = total_len };
}

pub const RegExpCaptureLengthSumResult = union(enum) {
    unsupported,
    matched: usize,
};

pub const RegExpCaptureLengthLoopAllResult = union(enum) {
    unsupported,
    done: usize,
};

pub fn qjsRegExpExecNoCaptureLengthForLoop(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    regexp_object: *core.Object,
    string_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !RegExpNoCaptureLengthResult {
    const borrowed = regexpBorrowedLatin1SourceFlags(regexp_object) orelse return .unsupported;
    if (std.mem.indexOfScalar(u8, borrowed.source, '|') == null) return .unsupported;
    const pattern = regexpSimpleClassAlternationPattern(ctx.runtime, regexp_object, borrowed.source, borrowed.flags) orelse return .unsupported;
    const is_global = std.mem.indexOfScalar(u8, borrowed.flags, 'g') != null;
    const is_sticky = std.mem.indexOfScalar(u8, borrowed.flags, 'y') != null;
    const has_indices = std.mem.indexOfScalar(u8, borrowed.flags, 'd') != null;
    if (has_indices or (!is_global and !is_sticky)) return .unsupported;

    const rt = ctx.runtime;
    const input_len = try stringLengthIndex(rt, string_value);
    const start_index = try getRegExpLastIndexLength(ctx, output, global, regexp_value, regexp_object, caller_function, caller_frame);
    if (start_index > input_len) {
        try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
        return .no_match;
    }

    if (simpleClassAlternationMatchPattern(pattern, string_value, start_index, is_sticky, borrowed.flags)) |found| {
        if (found.capture_count != 0 or found.len == 0) return .unsupported;
        const next_index = found.index + found.len;
        const next_value = if (next_index <= @as(usize, @intCast(std.math.maxInt(i32))))
            core.JSValue.int32(@intCast(next_index))
        else
            core.JSValue.float64(@floatFromInt(next_index));
        try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, next_value, caller_function, caller_frame);
        try updateRegExpLegacyStaticsNoCaptures(rt, global, string_value, found, input_len);
        return .{ .matched = found.len };
    }

    try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
    return .no_match;
}

pub fn qjsRegExpExecNoCaptureLengthLoopAll(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    regexp_object: *core.Object,
    string_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !RegExpNoCaptureLengthLoopAllResult {
    if (objectFromValue(regexp_value) != regexp_object or regexp_object.regexpLastIndex() == null or !regexp_object.regexpLastIndexWritable()) return .unsupported;
    const borrowed = regexpBorrowedLatin1SourceFlags(regexp_object) orelse return .unsupported;
    const is_global = std.mem.indexOfScalar(u8, borrowed.flags, 'g') != null;
    const is_sticky = std.mem.indexOfScalar(u8, borrowed.flags, 'y') != null;
    const has_indices = std.mem.indexOfScalar(u8, borrowed.flags, 'd') != null;
    if (has_indices or (!is_global and !is_sticky)) return .unsupported;

    const rt = ctx.runtime;
    const input_len = try stringLengthIndex(rt, string_value);
    var search_start = try getRegExpLastIndexLength(ctx, output, global, regexp_value, regexp_object, caller_function, caller_frame);
    var total_len: usize = 0;
    var last_found: ?RegExpMatch = null;

    if (search_start <= input_len) {
        if (std.mem.indexOfScalar(u8, borrowed.source, '|') != null) {
            const pattern = regexpSimpleClassAlternationPattern(ctx.runtime, regexp_object, borrowed.source, borrowed.flags) orelse return .unsupported;
            if (simpleClassAlternationLengthLoop(pattern, string_value, search_start, is_sticky, borrowed.flags)) |result| {
                total_len += result.total_len;
                last_found = result.last_found;
            } else {
                while (true) {
                    const found = simpleClassAlternationMatchPattern(pattern, string_value, search_start, is_sticky, borrowed.flags) orelse break;
                    if (found.capture_count != 0 or found.len == 0) return .unsupported;
                    total_len += found.len;
                    search_start = found.index + found.len;
                    last_found = found;
                }
            }
        } else {
            const pattern = parseSimpleClassSequenceLatin1Source(borrowed.source, borrowed.flags) orelse return .unsupported;
            if (simpleClassSequenceSingleUnitLengthLoop(pattern, string_value, search_start, is_sticky)) |result| {
                total_len += result.total_len;
                last_found = result.last_found;
            } else {
                while (true) {
                    const found = simpleClassSequenceMatchPattern(pattern, string_value, search_start, is_sticky, borrowed.flags) orelse break;
                    if (found.capture_count != 0 or found.len == 0) return .unsupported;
                    total_len += found.len;
                    search_start = found.index + found.len;
                    last_found = found;
                }
            }
        }
    }

    try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
    if (last_found) |found| try updateRegExpLegacyStaticsNoCaptures(rt, global, string_value, found, input_len);
    return .{ .done = total_len };
}

pub fn qjsRegExpExecNoCaptureCountLoopAll(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    regexp_object: *core.Object,
    string_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !RegExpCountLoopAllResult {
    if (objectFromValue(regexp_value) != regexp_object or regexp_object.regexpLastIndex() == null or !regexp_object.regexpLastIndexWritable()) return .unsupported;
    const borrowed = regexpBorrowedLatin1SourceFlags(regexp_object) orelse return .unsupported;
    const is_global = std.mem.indexOfScalar(u8, borrowed.flags, 'g') != null;
    const is_sticky = std.mem.indexOfScalar(u8, borrowed.flags, 'y') != null;
    const has_indices = std.mem.indexOfScalar(u8, borrowed.flags, 'd') != null;
    if (has_indices or (!is_global and !is_sticky)) return .unsupported;

    const rt = ctx.runtime;
    const input_len = try stringLengthIndex(rt, string_value);
    var search_start = try getRegExpLastIndexLength(ctx, output, global, regexp_value, regexp_object, caller_function, caller_frame);
    var count: usize = 0;
    var last_found: ?RegExpMatch = null;

    if (search_start <= input_len) {
        if (std.mem.indexOfScalar(u8, borrowed.source, '|') != null) {
            const pattern = regexpSimpleClassAlternationPattern(ctx.runtime, regexp_object, borrowed.source, borrowed.flags) orelse return .unsupported;
            if (simpleClassAlternationLengthLoop(pattern, string_value, search_start, is_sticky, borrowed.flags)) |result| {
                count += result.match_count;
                last_found = result.last_found;
            } else {
                while (true) {
                    const found = simpleClassAlternationMatchPattern(pattern, string_value, search_start, is_sticky, borrowed.flags) orelse break;
                    if (found.capture_count != 0 or found.len == 0) return .unsupported;
                    count += 1;
                    search_start = found.index + found.len;
                    last_found = found;
                }
            }
        } else {
            const pattern = parseSimpleClassSequenceLatin1Source(borrowed.source, borrowed.flags) orelse return .unsupported;
            if (simpleClassSequenceSingleUnitLengthLoop(pattern, string_value, search_start, is_sticky)) |result| {
                count += result.match_count;
                last_found = result.last_found;
            } else {
                while (true) {
                    const found = simpleClassSequenceMatchPattern(pattern, string_value, search_start, is_sticky, borrowed.flags) orelse break;
                    if (found.capture_count != 0 or found.len == 0) return .unsupported;
                    count += 1;
                    search_start = found.index + found.len;
                    last_found = found;
                }
            }
        }
    }

    try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
    if (last_found) |found| try updateRegExpLegacyStaticsNoCaptures(rt, global, string_value, found, input_len);
    return .{ .done = count };
}

pub fn qjsRegExpExecCaptureLengthSumLoopAll(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    regexp_object: *core.Object,
    string_value: core.JSValue,
    capture_indexes: []const u8,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !RegExpCaptureLengthLoopAllResult {
    if (objectFromValue(regexp_value) != regexp_object or regexp_object.regexpLastIndex() == null or !regexp_object.regexpLastIndexWritable()) return .unsupported;
    const borrowed = regexpBorrowedLatin1SourceFlags(regexp_object) orelse return .unsupported;
    const is_global = std.mem.indexOfScalar(u8, borrowed.flags, 'g') != null;
    const is_sticky = std.mem.indexOfScalar(u8, borrowed.flags, 'y') != null;
    const has_indices = std.mem.indexOfScalar(u8, borrowed.flags, 'd') != null;
    if (has_indices or (!is_global and !is_sticky)) return .unsupported;
    const pattern = regexpSimpleCaptureSequencePattern(regexp_object, borrowed.source, borrowed.flags) orelse return .unsupported;

    const rt = ctx.runtime;
    const input_len = try stringLengthIndex(rt, string_value);
    var search_start = try getRegExpLastIndexLength(ctx, output, global, regexp_value, regexp_object, caller_function, caller_frame);
    var total_sum: usize = 0;
    var last_found: ?RegExpMatch = null;

    if (search_start <= input_len) {
        if (simpleCaptureSequenceLengthSumLoop(pattern, string_value, search_start, is_sticky, borrowed.flags, capture_indexes)) |result| {
            total_sum = result.total_sum;
            last_found = result.last_found;
        } else {
            while (true) {
                const found = simpleCaptureSequenceMatchPattern(pattern, string_value, search_start, is_sticky, borrowed.flags) orelse break;
                if (found.len == 0) return .unsupported;
                const sum = captureLengthSum(found, capture_indexes) orelse return .unsupported;
                total_sum = std.math.add(usize, total_sum, sum) catch return .unsupported;
                search_start = found.index + found.len;
                last_found = found;
            }
        }
    }

    try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
    if (last_found) |found| try updateRegExpLegacyStaticsForMatch(rt, global, string_value, found);
    return .{ .done = total_sum };
}

pub fn qjsRegExpExecCaptureLengthSumForLoop(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    regexp_object: *core.Object,
    string_value: core.JSValue,
    capture_indexes: []const u8,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !RegExpCaptureLengthSumResult {
    _ = output;
    _ = regexp_value;
    _ = caller_function;
    _ = caller_frame;
    const borrowed = regexpBorrowedLatin1SourceFlags(regexp_object) orelse return .unsupported;
    if (std.mem.indexOfScalar(u8, borrowed.flags, 'g') != null or
        std.mem.indexOfScalar(u8, borrowed.flags, 'y') != null or
        std.mem.indexOfScalar(u8, borrowed.flags, 'd') != null)
    {
        return .unsupported;
    }
    const pattern = regexpSimpleCaptureSequencePattern(regexp_object, borrowed.source, borrowed.flags) orelse return .unsupported;
    const found = simpleCaptureSequenceMatchPattern(pattern, string_value, 0, false, borrowed.flags) orelse return .unsupported;

    const sum = captureLengthSum(found, capture_indexes) orelse return .unsupported;

    try updateRegExpLegacyStaticsForMatch(ctx.runtime, global, string_value, found);
    return .{ .matched = sum };
}

pub fn captureLengthSum(found: RegExpMatch, capture_indexes: []const u8) ?usize {
    var sum: usize = 0;
    for (capture_indexes) |capture_index| {
        const len = if (capture_index == 0) found.len else blk: {
            const zero_based = @as(usize, capture_index) - 1;
            if (zero_based >= found.capture_count) return null;
            const capture = found.captures[zero_based];
            if (capture.undefined) return null;
            break :blk capture.len;
        };
        sum = std.math.add(usize, sum, len) catch return null;
    }
    return sum;
}

pub fn qjsRegExpExecSimpleCaptureSequenceResult(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    regexp_object: *core.Object,
    string_value: core.JSValue,
    use_last_index: bool,
    input_len: usize,
    initial_last_index: usize,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !FastRegExpExecResult {
    const borrowed = regexpBorrowedLatin1SourceFlags(regexp_object) orelse return .unsupported;
    if (std.mem.indexOfScalar(u8, borrowed.source, '(') == null) return .unsupported;
    const pattern = regexpSimpleCaptureSequencePattern(regexp_object, borrowed.source, borrowed.flags) orelse return .unsupported;
    const rt = ctx.runtime;
    const is_global = std.mem.indexOfScalar(u8, borrowed.flags, 'g') != null;
    const is_sticky = std.mem.indexOfScalar(u8, borrowed.flags, 'y') != null;
    const has_indices = std.mem.indexOfScalar(u8, borrowed.flags, 'd') != null;
    const start_index = if (use_last_index and (is_global or is_sticky)) initial_last_index else 0;
    if (start_index > input_len) {
        if (use_last_index and (is_global or is_sticky)) {
            try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
        }
        return .{ .value = core.JSValue.nullValue() };
    }

    if (simpleCaptureSequenceMatchPattern(pattern, string_value, start_index, is_sticky, borrowed.flags)) |found| {
        if (use_last_index and (is_global or is_sticky)) {
            const next_index = found.index + found.len;
            const next_value = if (next_index <= @as(usize, @intCast(std.math.maxInt(i32))))
                core.JSValue.int32(@intCast(next_index))
            else
                core.JSValue.float64(@floatFromInt(next_index));
            try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, next_value, caller_function, caller_frame);
        }
        return .{ .value = try createRegExpMatchArrayFromValue(rt, global, string_value, found, has_indices) };
    }

    if (use_last_index and (is_global or is_sticky)) {
        try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
    }
    return .{ .value = core.JSValue.nullValue() };
}

pub fn regexpSimpleCaptureSequencePattern(regexp_object: *core.Object, source: []const u8, flags: []const u8) ?SimpleCaptureSequencePattern {
    if (regexp_object.regexpSimpleCaptureSequenceCache()) |pattern| return pattern;
    const pattern = parseSimpleCaptureSequenceSource(source, flags) orelse return null;
    regexp_object.setRegexpSimpleCaptureSequenceCache(pattern);
    return pattern;
}

pub fn qjsRegExpExecSimpleClassAlternationResult(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    regexp_object: *core.Object,
    string_value: core.JSValue,
    use_last_index: bool,
    input_len: usize,
    initial_last_index: usize,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !FastRegExpExecResult {
    const borrowed = regexpBorrowedLatin1SourceFlags(regexp_object) orelse return .unsupported;
    if (std.mem.indexOfScalar(u8, borrowed.source, '|') == null) return .unsupported;
    const pattern = regexpSimpleClassAlternationPattern(ctx.runtime, regexp_object, borrowed.source, borrowed.flags) orelse return .unsupported;
    const rt = ctx.runtime;
    const is_global = std.mem.indexOfScalar(u8, borrowed.flags, 'g') != null;
    const is_sticky = std.mem.indexOfScalar(u8, borrowed.flags, 'y') != null;
    const has_indices = std.mem.indexOfScalar(u8, borrowed.flags, 'd') != null;
    const start_index = if (use_last_index and (is_global or is_sticky)) initial_last_index else 0;
    if (start_index > input_len) {
        if (use_last_index and (is_global or is_sticky)) {
            try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
        }
        return .{ .value = core.JSValue.nullValue() };
    }

    if (simpleClassAlternationMatchPattern(pattern, string_value, start_index, is_sticky, borrowed.flags)) |found| {
        if (use_last_index and (is_global or is_sticky)) {
            const next_index = found.index + found.len;
            const next_value = if (next_index <= @as(usize, @intCast(std.math.maxInt(i32))))
                core.JSValue.int32(@intCast(next_index))
            else
                core.JSValue.float64(@floatFromInt(next_index));
            try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, next_value, caller_function, caller_frame);
        }
        return .{ .value = try createRegExpMatchArrayNoCapturesFromValue(rt, global, string_value, found, input_len, has_indices) };
    }

    if (use_last_index and (is_global or is_sticky)) {
        try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
    }
    return .{ .value = core.JSValue.nullValue() };
}

pub fn regexpSimpleClassAlternationPattern(rt: *core.JSRuntime, regexp_object: *core.Object, source: []const u8, flags: []const u8) ?SimpleClassAlternationPattern {
    if (regexp_object.regexpSimpleClassAlternationCache()) |pattern| return pattern;
    const source_atom = if (regexp_object.regexpSource()) |value| stringAtomId(value) else null;
    const flags_atom = if (regexp_object.regexpFlags()) |value| stringAtomId(value) else null;
    if (source_atom != null and flags_atom != null) {
        if (rt.cachedRegExpSimpleClassAlternation(source_atom.?, flags_atom.?)) |pattern| {
            regexp_object.setRegexpSimpleClassAlternationCache(pattern);
            return pattern;
        }
    }

    const parse_source = if (source_atom) |atom_id| rt.atoms.name(atom_id) orelse source else source;
    const parse_flags = if (flags_atom) |atom_id| rt.atoms.name(atom_id) orelse flags else flags;
    const pattern = parseSimpleClassAlternationSource(parse_source, parse_flags) orelse return null;
    regexp_object.setRegexpSimpleClassAlternationCache(pattern);
    if (source_atom != null and flags_atom != null) rt.setRegExpSimpleClassAlternationCache(source_atom.?, flags_atom.?, pattern);
    return pattern;
}

pub fn regExpFlagsContain(flags: []const u8, needle: u8) bool {
    return std.mem.indexOfScalar(u8, flags, needle) != null;
}

pub fn isRegExpValue(value: core.JSValue) bool {
    const object = property_ops.expectObject(value) catch return false;
    return object.class_id == core.class.ids.regexp;
}

pub fn isRegExpObservable(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    if (!value.isObject()) return false;
    const match_atom = core.atom.predefinedId("Symbol.match", .symbol) orelse return isRegExpValue(value);
    const matcher = try getValueProperty(ctx, output, global, value, match_atom, caller_function, caller_frame);
    defer matcher.free(ctx.runtime);
    if (!matcher.isUndefined()) return valueTruthy(matcher);
    return isRegExpValue(value);
}

pub fn appendRegExpSource(rt: *core.JSRuntime, object: *core.Object, out: *std.ArrayList(u8)) !bool {
    if (object.regexpSource()) |source_value| {
        try value_ops.appendValueString(rt, out, source_value);
        return true;
    }
    return false;
}

pub fn appendRegExpFlags(rt: *core.JSRuntime, object: *core.Object, out: *std.ArrayList(u8)) !bool {
    if (object.regexpFlags()) |flags_value| {
        try value_ops.appendRawString(rt, out, flags_value);
        return true;
    }
    return false;
}

pub fn appendRegExpInputUnits(rt: *core.JSRuntime, out: *std.ArrayList(u8), value: core.JSValue) !void {
    const string_value = value.asStringBody() orelse return value_ops.appendRawString(rt, out, value);
    try string_value.ensureFlat(rt);
    switch (string_value.resolveData()) {
        .latin1 => |bytes| try out.appendSlice(rt.memory.allocator, bytes),
        .utf16 => |units| {
            for (units) |unit| {
                const tag: u8 = if (unit <= 0xff) @intCast(unit) else @intCast(unit >> 8);
                try out.append(rt.memory.allocator, tag);
            }
        },
    }
}

pub fn singleUnicodeEscapeUnit(source: []const u8) ?u16 {
    if (source.len != 6 or source[0] != '\\' or source[1] != 'u') return null;
    var value: u16 = 0;
    var index: usize = 2;
    while (index < source.len) : (index += 1) {
        const digit = hexNibble(source[index]) orelse return null;
        value = value * 16 + @as(u16, @intCast(digit));
    }
    return value;
}

pub fn singleLowSurrogateLiteralSource(source: []const u8) ?u16 {
    const unit = singleUnicodeEscapeUnit(source) orelse return null;
    return if (isLowSurrogateUnit(unit)) unit else null;
}

pub fn lowSurrogateLiteralAt(unit: u16, string_value: core.string.String, pos: usize) ?RegExpMatch {
    if (pos >= string_value.len() or string_value.codeUnitAt(pos) != unit) return null;
    return .{ .index = pos, .len = 1 };
}

pub fn singleUnicodeClassEscapeUnit(source: []const u8) ?u16 {
    if (source.len != 8 or source[0] != '[' or source[1] != '\\' or source[2] != 'u' or source[7] != ']') return null;
    var value: u16 = 0;
    var index: usize = 3;
    while (index < 7) : (index += 1) {
        const digit = hexNibble(source[index]) orelse return null;
        value = value * 16 + @as(u16, @intCast(digit));
    }
    return value;
}

pub fn findCharacterClassEnd(source: []const u8, class_start: usize) ?usize {
    if (class_start >= source.len or source[class_start] != '[') return null;
    var index = class_start + 1;
    var at_start = true;
    while (index < source.len) : (index += 1) {
        if (source[index] == '\\') {
            if (index + 1 >= source.len) return null;
            index += 1;
            at_start = false;
            continue;
        }
        if (source[index] == ']' and !at_start) return index;
        at_start = false;
    }
    return null;
}

pub fn standaloneCharacterClassSource(source: []const u8) ?[]const u8 {
    if (source.len < 2 or source[0] != '[') return null;
    const class_end = findCharacterClassEnd(source, 0) orelse return null;
    if (class_end + 1 != source.len) return null;
    return source;
}

pub fn leadingAlternationCharacterClassSource(source: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, source, "(?:[")) return null;
    const class_end = findCharacterClassEnd(source, 3) orelse return null;
    if (class_end + 1 >= source.len or source[class_end + 1] != '|') return null;
    return source[3 .. class_end + 1];
}

pub const SimpleUnicodeLiteralPattern = struct {
    units: [64]u16 = undefined,
    len: usize = 0,
    anchor_start: bool = false,
    anchor_end: bool = false,
};

pub const SimpleClassSequenceAtom = core.object.RegExpSimpleClassSequenceAtom;

pub const SimpleCaptureSequenceAtom = core.object.RegExpSimpleCaptureSequenceAtom;

pub const SimpleClassPredicate = core.object.RegExpSimpleClassPredicate;

pub const SimpleCaptureSequencePattern = core.object.RegExpSimpleCaptureSequencePattern;

pub const SimpleClassSequencePattern = core.object.RegExpSimpleClassSequencePattern;
pub const SimpleClassAlternationPattern = core.object.RegExpSimpleClassAlternationPattern;

pub fn isSimpleUnicodeLiteralSource(source: []const u8) bool {
    return parseSimpleUnicodeLiteralSource(source) != null;
}

pub fn isSimpleClassSequenceSource(source: []const u8, flags: []const u8) bool {
    return parseSimpleClassSequenceSource(source, flags) != null;
}

pub fn parseSimpleCaptureSequenceSource(source: []const u8, flags: []const u8) ?SimpleCaptureSequencePattern {
    if (source.len == 0 or hasFlag(flags, 'i') or hasFlag(flags, 'u') or hasFlag(flags, 'v') or hasFlag(flags, 's')) return null;
    var pattern = SimpleCaptureSequencePattern{};
    var index: usize = 0;
    if (source[index] == '^') {
        pattern.anchor_start = true;
        index += 1;
    }
    const end_limit = if (source.len > index and source[source.len - 1] == '$') blk: {
        pattern.anchor_end = true;
        break :blk source.len - 1;
    } else source.len;
    while (index < end_limit) {
        if (pattern.len >= pattern.atoms.len) return null;
        var capture_index: ?usize = null;
        var atom: SimpleCaptureSequenceAtom = undefined;
        if (source[index] == '(') {
            if (index + 1 >= end_limit or source[index + 1] == '?') return null;
            index += 1;
            pattern.capture_count += 1;
            if (pattern.capture_count > 255) return null;
            capture_index = pattern.capture_count;
            atom = parseSimpleCaptureSequenceAtom(source, &index, end_limit, capture_index) orelse return null;
            if (index >= end_limit or source[index] != ')') return null;
            index += 1;
            if (index < end_limit) {
                switch (source[index]) {
                    '*', '+', '?', '{' => return null,
                    else => {},
                }
            }
        } else {
            atom = parseSimpleCaptureSequenceAtom(source, &index, end_limit, null) orelse return null;
        }
        pattern.atoms[pattern.len] = atom;
        pattern.len += 1;
    }
    if (pattern.len == 0 or pattern.capture_count == 0) return null;
    return pattern;
}

pub fn parseSimpleCaptureSequenceAtom(source: []const u8, index: *usize, end_limit: usize, capture_index: ?usize) ?SimpleCaptureSequenceAtom {
    var atom = SimpleCaptureSequenceAtom{ .capture_index = capture_index };
    if (index.* >= end_limit) return null;
    if (source[index.*] == '[') {
        const class_end = findCharacterClassEnd(source, index.*) orelse return null;
        if (class_end >= end_limit) return null;
        atom.kind = .class;
        atom.class_source = source[index.* .. class_end + 1];
        atom.class_predicate = simpleClassPredicateFromSource(atom.class_source);
        index.* = class_end + 1;
    } else if (source[index.*] == '\\') {
        if (index.* + 1 >= end_limit) return null;
        if (index.* + 2 < end_limit and source[index.* + 1] == '\\' and isSimpleClassEscapeByte(source[index.* + 2])) {
            atom.kind = .class;
            atom.class_source = source[index.* + 1 .. index.* + 3];
            atom.class_predicate = simpleClassPredicateFromSource(atom.class_source);
            index.* += 3;
            return parseSimpleCaptureSequenceAtomQuantifier(source, index, end_limit, capture_index, atom);
        }
        switch (source[index.* + 1]) {
            'd', 'D', 's', 'S', 'w', 'W' => {
                atom.kind = .class;
                atom.class_source = source[index.* .. index.* + 2];
                atom.class_predicate = simpleClassPredicateFromSource(atom.class_source);
                index.* += 2;
            },
            else => {
                atom.kind = .literal;
                atom.literal = parseSimpleClassSequenceEscapedLiteral(source, index, end_limit) orelse return null;
            },
        }
    } else {
        atom.kind = .literal;
        atom.literal = parseSimpleClassSequenceLiteral(source, index, end_limit) orelse return null;
    }

    return parseSimpleCaptureSequenceAtomQuantifier(source, index, end_limit, capture_index, atom);
}

pub fn parseSimpleCaptureSequenceAtomQuantifier(source: []const u8, index: *usize, end_limit: usize, capture_index: ?usize, initial_atom: SimpleCaptureSequenceAtom) ?SimpleCaptureSequenceAtom {
    var atom = initial_atom;
    if (index.* < end_limit) {
        switch (source[index.*]) {
            '*' => {
                if (capture_index != null) return null;
                atom.min_repeat = 0;
                atom.max_repeat = std.math.maxInt(usize);
                index.* += 1;
            },
            '+' => {
                atom.max_repeat = std.math.maxInt(usize);
                index.* += 1;
            },
            '?' => {
                if (capture_index != null) return null;
                atom.min_repeat = 0;
                atom.max_repeat = 1;
                index.* += 1;
            },
            '{', '|', ')' => {},
            else => {},
        }
    }
    return atom;
}

pub const SimpleClassSequenceLengthLoopResult = struct {
    total_len: usize,
    match_count: usize,
    last_found: ?RegExpMatch,
};

pub const SimpleClassAlternationLengthLoopResult = struct {
    total_len: usize,
    match_count: usize,
    last_found: ?RegExpMatch,
};

pub fn simpleClassSequenceSingleUnitLengthLoop(pattern: SimpleClassSequencePattern, value: core.JSValue, start: usize, sticky: bool) ?SimpleClassSequenceLengthLoopResult {
    if (pattern.len != 1 or pattern.anchor_start or pattern.anchor_end) return null;
    const atom = pattern.atoms[0];
    if (atom.min_repeat != 1 or atom.max_repeat != 1) return null;
    const string_value = value.asStringBody() orelse return null;
    return switch (string_value.resolveData()) {
        .latin1 => |bytes| simpleClassSequenceSingleUnitLengthLoopLatin1(atom, bytes, start, sticky),
        .utf16 => |units| simpleClassSequenceSingleUnitLengthLoopUtf16(atom, units, start, sticky),
    };
}

pub fn simpleClassAlternationSingleAtomRunLengthLoop(pattern: SimpleClassAlternationPattern, value: core.JSValue, start: usize, sticky: bool) ?SimpleClassAlternationLengthLoopResult {
    if (pattern.len < 2) return null;
    for (pattern.alternatives[0..pattern.len]) |alternative| {
        if (alternative.len != 1 or alternative.anchor_start or alternative.anchor_end) return null;
        const atom = alternative.atoms[0];
        if (atom.min_repeat != 1) return null;
        if (atom.max_repeat != 1 and atom.max_repeat != std.math.maxInt(usize)) return null;
    }

    const string_value = value.asStringBody() orelse return null;
    return switch (string_value.resolveData()) {
        .latin1 => |bytes| simpleClassAlternationSingleAtomRunLengthLoopLatin1(pattern, bytes, start, sticky),
        .utf16 => |units| simpleClassAlternationSingleAtomRunLengthLoopUtf16(pattern, units, start, sticky),
    };
}

pub fn simpleClassAlternationLengthLoop(pattern: SimpleClassAlternationPattern, value: core.JSValue, start: usize, sticky: bool, flags: []const u8) ?SimpleClassAlternationLengthLoopResult {
    if (simpleClassAlternationSingleAtomRunLengthLoop(pattern, value, start, sticky)) |result| return result;
    if (pattern.len < 2) return null;
    const string_value = value.asStringBody() orelse return null;
    return switch (string_value.resolveData()) {
        .latin1 => |bytes| simpleClassAlternationLengthLoopLatin1(pattern, bytes, start, sticky, flags),
        .utf16 => |units| simpleClassAlternationLengthLoopUtf16(pattern, units, start, sticky, flags),
    };
}

pub const SimpleCaptureLengthSumLoopResult = struct {
    total_sum: usize,
    last_found: ?RegExpMatch,
};

pub fn simpleCaptureSequenceLengthSumLoop(
    pattern: SimpleCaptureSequencePattern,
    value: core.JSValue,
    start: usize,
    sticky: bool,
    flags: []const u8,
    capture_indexes: []const u8,
) ?SimpleCaptureLengthSumLoopResult {
    const string_value = value.asStringBody() orelse return null;
    return switch (string_value.resolveData()) {
        .latin1 => |bytes| simpleCaptureSequenceLengthSumLoopLatin1(pattern, bytes, start, sticky, flags, capture_indexes),
        .utf16 => |units| simpleCaptureSequenceLengthSumLoopUtf16(pattern, units, start, sticky, flags, capture_indexes),
    };
}

pub fn simpleClassAlternationSingleAtomRunLengthLoopLatin1(pattern: SimpleClassAlternationPattern, bytes: []const u8, start: usize, sticky: bool) SimpleClassAlternationLengthLoopResult {
    var total_len: usize = 0;
    var match_count: usize = 0;
    var last_found: ?RegExpMatch = null;
    if (start > bytes.len) return .{ .total_len = 0, .match_count = 0, .last_found = null };

    var index = start;
    while (index < bytes.len) {
        var matched_atom: ?SimpleClassSequenceAtom = null;
        for (pattern.alternatives[0..pattern.len]) |alternative| {
            const atom = alternative.atoms[0];
            if (simpleClassSequenceAtomMatches(atom, bytes[index])) {
                matched_atom = atom;
                break;
            }
        }

        const atom = matched_atom orelse {
            if (sticky) break;
            index += 1;
            continue;
        };
        const match_start = index;
        index += 1;
        if (atom.max_repeat == std.math.maxInt(usize)) {
            while (index < bytes.len and simpleClassSequenceAtomMatches(atom, bytes[index])) : (index += 1) {}
        }
        const len = index - match_start;
        total_len += len;
        match_count += 1;
        last_found = .{ .index = match_start, .len = len };
    }
    return .{ .total_len = total_len, .match_count = match_count, .last_found = last_found };
}

pub fn simpleClassAlternationSingleAtomRunLengthLoopUtf16(pattern: SimpleClassAlternationPattern, units: []const u16, start: usize, sticky: bool) SimpleClassAlternationLengthLoopResult {
    var total_len: usize = 0;
    var match_count: usize = 0;
    var last_found: ?RegExpMatch = null;
    if (start > units.len) return .{ .total_len = 0, .match_count = 0, .last_found = null };

    var index = start;
    while (index < units.len) {
        var matched_atom: ?SimpleClassSequenceAtom = null;
        for (pattern.alternatives[0..pattern.len]) |alternative| {
            const atom = alternative.atoms[0];
            if (simpleClassSequenceAtomMatches(atom, units[index])) {
                matched_atom = atom;
                break;
            }
        }

        const atom = matched_atom orelse {
            if (sticky) break;
            index += 1;
            continue;
        };
        const match_start = index;
        index += 1;
        if (atom.max_repeat == std.math.maxInt(usize)) {
            while (index < units.len and simpleClassSequenceAtomMatches(atom, units[index])) : (index += 1) {}
        }
        const len = index - match_start;
        total_len += len;
        match_count += 1;
        last_found = .{ .index = match_start, .len = len };
    }
    return .{ .total_len = total_len, .match_count = match_count, .last_found = last_found };
}

pub fn simpleClassAlternationLengthLoopLatin1(pattern: SimpleClassAlternationPattern, bytes: []const u8, start: usize, sticky: bool, flags: []const u8) ?SimpleClassAlternationLengthLoopResult {
    if (simpleClassAlternationLiteralLengthLoopLatin1(pattern, bytes, start, sticky)) |result| return result;
    var total_len: usize = 0;
    var match_count: usize = 0;
    var last_found: ?RegExpMatch = null;
    if (start > bytes.len) return .{ .total_len = 0, .match_count = 0, .last_found = null };

    var index = start;
    while (index <= bytes.len) {
        var matched: ?RegExpMatch = null;
        for (pattern.alternatives[0..pattern.len]) |alternative| {
            if (simpleClassSequenceAtLatin1(alternative, bytes, index, flags)) |found| {
                matched = found;
                break;
            }
        }
        if (matched) |found| {
            if (found.len == 0) return null;
            total_len = std.math.add(usize, total_len, found.len) catch return null;
            match_count += 1;
            last_found = found;
            index = found.index + found.len;
            continue;
        }
        if (sticky) break;
        index += 1;
    }
    return .{ .total_len = total_len, .match_count = match_count, .last_found = last_found };
}

pub fn simpleClassAlternationLengthLoopUtf16(pattern: SimpleClassAlternationPattern, units: []const u16, start: usize, sticky: bool, flags: []const u8) ?SimpleClassAlternationLengthLoopResult {
    if (simpleClassAlternationLiteralLengthLoopUtf16(pattern, units, start, sticky)) |result| return result;
    var total_len: usize = 0;
    var match_count: usize = 0;
    var last_found: ?RegExpMatch = null;
    if (start > units.len) return .{ .total_len = 0, .match_count = 0, .last_found = null };

    var index = start;
    while (index <= units.len) {
        var matched: ?RegExpMatch = null;
        for (pattern.alternatives[0..pattern.len]) |alternative| {
            if (simpleClassSequenceAtUtf16(alternative, units, index, flags)) |found| {
                matched = found;
                break;
            }
        }
        if (matched) |found| {
            if (found.len == 0) return null;
            total_len = std.math.add(usize, total_len, found.len) catch return null;
            match_count += 1;
            last_found = found;
            index = found.index + found.len;
            continue;
        }
        if (sticky) break;
        index += 1;
    }
    return .{ .total_len = total_len, .match_count = match_count, .last_found = last_found };
}

pub fn simpleClassAlternationLiteralLengthLoopLatin1(pattern: SimpleClassAlternationPattern, bytes: []const u8, start: usize, sticky: bool) ?SimpleClassAlternationLengthLoopResult {
    if (!simpleClassAlternationAllUnitLiterals(pattern, true)) return null;
    var total_len: usize = 0;
    var match_count: usize = 0;
    var last_found: ?RegExpMatch = null;
    if (start > bytes.len) return .{ .total_len = 0, .match_count = 0, .last_found = null };

    var index = start;
    while (index < bytes.len) {
        var matched_len: usize = 0;
        alternatives: for (pattern.alternatives[0..pattern.len]) |alternative| {
            if (index + alternative.len > bytes.len) continue;
            for (alternative.atoms[0..alternative.len], 0..) |atom, offset| {
                if (bytes[index + offset] != @as(u8, @intCast(atom.literal))) continue :alternatives;
            }
            matched_len = alternative.len;
            break;
        }
        if (matched_len != 0) {
            total_len = std.math.add(usize, total_len, matched_len) catch return null;
            match_count += 1;
            last_found = .{ .index = index, .len = matched_len };
            index += matched_len;
            continue;
        }
        if (sticky) break;
        index += 1;
    }
    return .{ .total_len = total_len, .match_count = match_count, .last_found = last_found };
}

pub fn simpleClassAlternationLiteralLengthLoopUtf16(pattern: SimpleClassAlternationPattern, units: []const u16, start: usize, sticky: bool) ?SimpleClassAlternationLengthLoopResult {
    if (!simpleClassAlternationAllUnitLiterals(pattern, false)) return null;
    var total_len: usize = 0;
    var match_count: usize = 0;
    var last_found: ?RegExpMatch = null;
    if (start > units.len) return .{ .total_len = 0, .match_count = 0, .last_found = null };

    var index = start;
    while (index < units.len) {
        var matched_len: usize = 0;
        alternatives: for (pattern.alternatives[0..pattern.len]) |alternative| {
            if (index + alternative.len > units.len) continue;
            for (alternative.atoms[0..alternative.len], 0..) |atom, offset| {
                if (units[index + offset] != atom.literal) continue :alternatives;
            }
            matched_len = alternative.len;
            break;
        }
        if (matched_len != 0) {
            total_len = std.math.add(usize, total_len, matched_len) catch return null;
            match_count += 1;
            last_found = .{ .index = index, .len = matched_len };
            index += matched_len;
            continue;
        }
        if (sticky) break;
        index += 1;
    }
    return .{ .total_len = total_len, .match_count = match_count, .last_found = last_found };
}

pub fn simpleClassAlternationAllUnitLiterals(pattern: SimpleClassAlternationPattern, comptime latin1: bool) bool {
    if (pattern.len < 2) return false;
    for (pattern.alternatives[0..pattern.len]) |alternative| {
        if (alternative.len == 0 or alternative.anchor_start or alternative.anchor_end) return false;
        for (alternative.atoms[0..alternative.len]) |atom| {
            if (atom.kind != .literal or atom.min_repeat != 1 or atom.max_repeat != 1) return false;
            if (latin1 and atom.literal > 0xff) return false;
        }
    }
    return true;
}

pub fn simpleCaptureSequenceTwoRunLengthSumLoopLatin1(pattern: SimpleCaptureSequencePattern, bytes: []const u8, start: usize, sticky: bool, capture_indexes: []const u8) ?SimpleCaptureLengthSumLoopResult {
    if (pattern.anchor_start or pattern.anchor_end or pattern.len != 2 or pattern.capture_count < 2) return null;
    const first = pattern.atoms[0];
    const second = pattern.atoms[1];
    if (first.capture_index == null or second.capture_index == null) return null;
    if (first.min_repeat != 1 or first.max_repeat != std.math.maxInt(usize)) return null;
    if (second.min_repeat != 1 or second.max_repeat != std.math.maxInt(usize)) return null;
    if (!simpleCaptureAtomsKnownDisjoint(first, second)) return null;

    var total_sum: usize = 0;
    var last_found: ?RegExpMatch = null;
    if (start > bytes.len) return .{ .total_sum = 0, .last_found = null };

    var index = start;
    while (index < bytes.len) {
        if (!simpleCaptureSequenceAtomMatches(first, bytes[index])) {
            if (sticky) break;
            index += 1;
            continue;
        }
        const match_start = index;
        const first_start = index;
        index += 1;
        while (index < bytes.len and simpleCaptureSequenceAtomMatches(first, bytes[index])) : (index += 1) {}
        const first_len = index - first_start;
        if (index >= bytes.len or !simpleCaptureSequenceAtomMatches(second, bytes[index])) {
            if (sticky) break;
            index = match_start + 1;
            continue;
        }
        const second_start = index;
        index += 1;
        while (index < bytes.len and simpleCaptureSequenceAtomMatches(second, bytes[index])) : (index += 1) {}
        const second_len = index - second_start;
        const match_len = index - match_start;

        var found = RegExpMatch{ .index = match_start, .len = match_len, .capture_count = pattern.capture_count };
        initFastCaptures(&found.captures, pattern.capture_count);
        found.captures[first.capture_index.? - 1] = .{ .start = first_start, .len = first_len };
        found.captures[second.capture_index.? - 1] = .{ .start = second_start, .len = second_len };
        const sum = captureLengthSum(found, capture_indexes) orelse return null;
        total_sum = std.math.add(usize, total_sum, sum) catch return null;
        last_found = found;
    }
    return .{ .total_sum = total_sum, .last_found = last_found };
}

pub fn simpleCaptureSequenceLengthSumLoopLatin1(pattern: SimpleCaptureSequencePattern, bytes: []const u8, start: usize, sticky: bool, flags: []const u8, capture_indexes: []const u8) ?SimpleCaptureLengthSumLoopResult {
    if (simpleCaptureSequenceTwoRunLengthSumLoopLatin1(pattern, bytes, start, sticky, capture_indexes)) |result| return result;
    var total_sum: usize = 0;
    var last_found: ?RegExpMatch = null;
    if (start > bytes.len) return .{ .total_sum = 0, .last_found = null };

    var index = start;
    while (index <= bytes.len) {
        const found = simpleCaptureSequenceAtLatin1(pattern, bytes, index, flags) orelse {
            if (sticky) break;
            index += 1;
            continue;
        };
        if (found.len == 0) return null;
        const sum = captureLengthSum(found, capture_indexes) orelse return null;
        total_sum = std.math.add(usize, total_sum, sum) catch return null;
        last_found = found;
        index = found.index + found.len;
    }
    return .{ .total_sum = total_sum, .last_found = last_found };
}

pub fn simpleCaptureSequenceLengthSumLoopUtf16(pattern: SimpleCaptureSequencePattern, units: []const u16, start: usize, sticky: bool, flags: []const u8, capture_indexes: []const u8) ?SimpleCaptureLengthSumLoopResult {
    var total_sum: usize = 0;
    var last_found: ?RegExpMatch = null;
    if (start > units.len) return .{ .total_sum = 0, .last_found = null };

    var index = start;
    while (index <= units.len) {
        const found = simpleCaptureSequenceAtUtf16(pattern, units, index, flags) orelse {
            if (sticky) break;
            index += 1;
            continue;
        };
        if (found.len == 0) return null;
        const sum = captureLengthSum(found, capture_indexes) orelse return null;
        total_sum = std.math.add(usize, total_sum, sum) catch return null;
        last_found = found;
        index = found.index + found.len;
    }
    return .{ .total_sum = total_sum, .last_found = last_found };
}

pub fn simpleClassSequenceSingleUnitLengthLoopLatin1(atom: SimpleClassSequenceAtom, bytes: []const u8, start: usize, sticky: bool) SimpleClassSequenceLengthLoopResult {
    var total_len: usize = 0;
    var match_count: usize = 0;
    var last_found: ?RegExpMatch = null;
    if (start > bytes.len) return .{ .total_len = 0, .match_count = 0, .last_found = null };
    if (sticky) {
        var index = start;
        while (index < bytes.len and simpleClassSequenceAtomMatches(atom, bytes[index])) : (index += 1) {
            total_len += 1;
            match_count += 1;
            last_found = .{ .index = index, .len = 1 };
        }
        return .{ .total_len = total_len, .match_count = match_count, .last_found = last_found };
    }
    var index = start;
    while (index < bytes.len) : (index += 1) {
        if (simpleClassSequenceAtomMatches(atom, bytes[index])) {
            total_len += 1;
            match_count += 1;
            last_found = .{ .index = index, .len = 1 };
        }
    }
    return .{ .total_len = total_len, .match_count = match_count, .last_found = last_found };
}

pub fn simpleClassSequenceSingleUnitLengthLoopUtf16(atom: SimpleClassSequenceAtom, units: []const u16, start: usize, sticky: bool) SimpleClassSequenceLengthLoopResult {
    var total_len: usize = 0;
    var match_count: usize = 0;
    var last_found: ?RegExpMatch = null;
    if (start > units.len) return .{ .total_len = 0, .match_count = 0, .last_found = null };
    if (sticky) {
        var index = start;
        while (index < units.len and simpleClassSequenceAtomMatches(atom, units[index])) : (index += 1) {
            total_len += 1;
            match_count += 1;
            last_found = .{ .index = index, .len = 1 };
        }
        return .{ .total_len = total_len, .match_count = match_count, .last_found = last_found };
    }
    var index = start;
    while (index < units.len) : (index += 1) {
        if (simpleClassSequenceAtomMatches(atom, units[index])) {
            total_len += 1;
            match_count += 1;
            last_found = .{ .index = index, .len = 1 };
        }
    }
    return .{ .total_len = total_len, .match_count = match_count, .last_found = last_found };
}

pub fn parseSimpleUnicodeLiteralSource(source: []const u8) ?SimpleUnicodeLiteralPattern {
    if (source.len == 0) return null;
    if (std.mem.indexOf(u8, source, "\\0") == null and std.mem.indexOf(u8, source, "\\u{") == null) return null;
    var pattern = SimpleUnicodeLiteralPattern{};
    var index: usize = 0;
    if (source[index] == '^') {
        pattern.anchor_start = true;
        index += 1;
    }
    const end_limit = if (source.len > index and source[source.len - 1] == '$') blk: {
        pattern.anchor_end = true;
        break :blk source.len - 1;
    } else source.len;
    while (index < end_limit) {
        if (pattern.len >= pattern.units.len) return null;
        if (source[index] == '\\') {
            if (index + 1 >= end_limit) return null;
            switch (source[index + 1]) {
                '0' => {
                    if (index + 2 < end_limit and unicode_lib.isAsciiDigitByte(source[index + 2])) return null;
                    pattern.units[pattern.len] = 0;
                    pattern.len += 1;
                    index += 2;
                },
                'u' => {
                    if (index + 2 < end_limit and source[index + 2] == '{') {
                        var scan = index + 3;
                        var saw_digit = false;
                        var value: u32 = 0;
                        while (scan < end_limit and source[scan] != '}') : (scan += 1) {
                            const digit = hexNibble(source[scan]) orelse return null;
                            saw_digit = true;
                            if (value > 0x10ffff / 16) return null;
                            value = value * 16 + digit;
                            if (value > 0x10ffff) return null;
                        }
                        if (!saw_digit or scan >= end_limit or source[scan] != '}') return null;
                        if (value <= 0xffff) {
                            pattern.units[pattern.len] = @intCast(value);
                            pattern.len += 1;
                        } else {
                            if (pattern.len + 2 > pattern.units.len) return null;
                            const pair = unicode_lib.surrogatePairFromCodePoint(@intCast(value));
                            pattern.units[pattern.len] = pair.high;
                            pattern.units[pattern.len + 1] = pair.low;
                            pattern.len += 2;
                        }
                        index = scan + 1;
                        continue;
                    }
                    if (index + 6 > end_limit) return null;
                    var value: u16 = 0;
                    var digit_index = index + 2;
                    while (digit_index < index + 6) : (digit_index += 1) {
                        const digit = hexNibble(source[digit_index]) orelse return null;
                        value = value * 16 + @as(u16, @intCast(digit));
                    }
                    pattern.units[pattern.len] = value;
                    pattern.len += 1;
                    index += 6;
                },
                else => return null,
            }
            continue;
        }
        if (isRegExpSyntaxByte(source[index])) return null;
        const width = std.unicode.utf8ByteSequenceLength(source[index]) catch return null;
        if (index + width > end_limit) return null;
        const cp = std.unicode.utf8Decode(source[index .. index + width]) catch return null;
        if (cp <= 0xffff) {
            pattern.units[pattern.len] = @intCast(cp);
            pattern.len += 1;
        } else {
            if (pattern.len + 2 > pattern.units.len) return null;
            const pair = unicode_lib.surrogatePairFromCodePoint(@intCast(cp));
            pattern.units[pattern.len] = pair.high;
            pattern.units[pattern.len + 1] = pair.low;
            pattern.len += 2;
        }
        index += width;
    }
    return if (pattern.len == 0) null else pattern;
}

pub fn parseSimpleClassSequenceSource(source: []const u8, flags: []const u8) ?SimpleClassSequencePattern {
    return parseSimpleClassSequenceSourceWithEncoding(source, flags, .utf8);
}

pub fn parseSimpleClassSequenceLatin1Source(source: []const u8, flags: []const u8) ?SimpleClassSequencePattern {
    return parseSimpleClassSequenceSourceWithEncoding(source, flags, .latin1);
}

const SimpleClassSequenceSourceEncoding = enum {
    utf8,
    latin1,
};

fn parseSimpleClassSequenceSourceWithEncoding(source: []const u8, flags: []const u8, comptime encoding: SimpleClassSequenceSourceEncoding) ?SimpleClassSequencePattern {
    if (source.len == 0 or hasFlag(flags, 'i')) return null;
    if (hasFlag(flags, 'v') and std.mem.indexOfScalar(u8, source, '[') != null) return null;
    var pattern = SimpleClassSequencePattern{};
    var has_required_atom = false;
    var index: usize = 0;
    if (source[index] == '^') {
        pattern.anchor_start = true;
        index += 1;
    }
    const end_limit = if (source.len > index and source[source.len - 1] == '$') blk: {
        pattern.anchor_end = true;
        break :blk source.len - 1;
    } else source.len;
    while (index < end_limit) {
        if (pattern.len >= pattern.atoms.len) return null;
        var atom = SimpleClassSequenceAtom{};
        if (source[index] == '[') {
            const class_end = findCharacterClassEnd(source, index) orelse return null;
            if (class_end >= end_limit) return null;
            atom.kind = .class;
            atom.class_source = source[index .. class_end + 1];
            atom.class_predicate = simpleClassPredicateFromSource(atom.class_source);
            index = class_end + 1;
        } else if (source[index] == '\\') {
            if (index + 1 >= end_limit) return null;
            if (index + 2 < end_limit and source[index + 1] == '\\' and isSimpleClassEscapeByte(source[index + 2])) {
                atom.kind = .class;
                atom.class_source = source[index + 1 .. index + 3];
                atom.class_predicate = simpleClassPredicateFromSource(atom.class_source);
                index += 3;
            } else switch (source[index + 1]) {
                'd', 'D', 's', 'S', 'w', 'W' => {
                    atom.kind = .class;
                    atom.class_source = source[index .. index + 2];
                    atom.class_predicate = simpleClassPredicateFromSource(atom.class_source);
                    index += 2;
                },
                else => {
                    atom.kind = .literal;
                    atom.literal = parseSimpleClassSequenceEscapedLiteral(source, &index, end_limit) orelse return null;
                },
            }
        } else {
            atom.kind = .literal;
            atom.literal = switch (encoding) {
                .utf8 => parseSimpleClassSequenceLiteral(source, &index, end_limit),
                .latin1 => parseSimpleClassSequenceLatin1Literal(source, &index, end_limit),
            } orelse return null;
        }

        if (index < end_limit) {
            switch (source[index]) {
                '*' => {
                    atom.min_repeat = 0;
                    atom.max_repeat = std.math.maxInt(usize);
                    index += 1;
                },
                '+' => {
                    atom.max_repeat = std.math.maxInt(usize);
                    index += 1;
                },
                '?' => {
                    atom.min_repeat = 0;
                    atom.max_repeat = 1;
                    index += 1;
                },
                '{', '(', ')', '|' => return null,
                else => {},
            }
        }
        if (atom.min_repeat > 0) has_required_atom = true;
        pattern.atoms[pattern.len] = atom;
        pattern.len += 1;
    }
    if (pattern.len == 0 or !has_required_atom) return null;
    return pattern;
}

pub fn parseSimpleClassAlternationSource(source: []const u8, flags: []const u8) ?SimpleClassAlternationPattern {
    if (source.len == 0 or hasFlag(flags, 'i')) return null;

    var pattern = SimpleClassAlternationPattern{};
    var part_start: usize = 0;
    var index: usize = 0;
    var saw_alternation = false;
    while (index < source.len) {
        switch (source[index]) {
            '\\' => {
                if (index + 1 >= source.len) return null;
                index += 2;
                continue;
            },
            '[' => {
                const class_end = findCharacterClassEnd(source, index) orelse return null;
                index = class_end + 1;
                continue;
            },
            '|' => {
                saw_alternation = true;
                addSimpleClassAlternationPart(&pattern, source[part_start..index], flags) orelse return null;
                part_start = index + 1;
            },
            else => {},
        }
        index += 1;
    }

    if (!saw_alternation) return null;
    addSimpleClassAlternationPart(&pattern, source[part_start..], flags) orelse return null;
    return if (pattern.len >= 2) pattern else null;
}

pub fn addSimpleClassAlternationPart(pattern: *SimpleClassAlternationPattern, source: []const u8, flags: []const u8) ?void {
    if (pattern.len >= pattern.alternatives.len) return null;
    if (source.len == 0) return null;
    const alternative = parseSimpleClassSequenceSource(source, flags) orelse return null;
    if (alternative.anchor_start or alternative.anchor_end) return null;
    pattern.alternatives[pattern.len] = alternative;
    pattern.len += 1;
}

pub fn isSimpleClassEscapeByte(byte: u8) bool {
    return switch (byte) {
        'd', 'D', 's', 'S', 'w', 'W' => true,
        else => false,
    };
}

pub fn simpleUnicodeLiteralAt(pattern: SimpleUnicodeLiteralPattern, string_value: core.string.String, pos: usize, flags: []const u8) ?RegExpMatch {
    if (pattern.anchor_start and !isStringLineStartPosition(string_value, pos, hasFlag(flags, 'm'))) return null;
    if (pos + pattern.len > string_value.len()) return null;
    for (pattern.units[0..pattern.len], 0..) |unit, offset| {
        if (string_value.codeUnitAt(pos + offset) != unit) return null;
    }
    if (pattern.anchor_end and !isStringLineEndPosition(string_value, pos + pattern.len, hasFlag(flags, 'm'))) return null;
    return RegExpMatch{ .index = pos, .len = pattern.len };
}

pub fn simpleClassSequenceAtLatin1(pattern: SimpleClassSequencePattern, bytes: []const u8, pos: usize, flags: []const u8) ?RegExpMatch {
    if (pattern.anchor_start and !isBytesLineStartPosition(bytes, pos, hasFlag(flags, 'm'))) return null;
    const end = simpleClassSequenceBacktrackLatin1(pattern, bytes, 0, pos, flags) orelse return null;
    return RegExpMatch{ .index = pos, .len = end - pos };
}

pub fn simpleCaptureSequenceAtLatin1(pattern: SimpleCaptureSequencePattern, bytes: []const u8, pos: usize, flags: []const u8) ?RegExpMatch {
    if (pattern.anchor_start and !isBytesLineStartPosition(bytes, pos, hasFlag(flags, 'm'))) return null;
    var captures: [256]RegExpCapture = undefined;
    initFastCaptures(&captures, pattern.capture_count);
    const end = simpleCaptureSequenceBacktrackLatin1(pattern, bytes, 0, pos, flags, &captures) orelse return null;
    var found = RegExpMatch{ .index = pos, .len = end - pos, .capture_count = pattern.capture_count };
    @memcpy(found.captures[0..pattern.capture_count], captures[0..pattern.capture_count]);
    return found;
}

pub fn simpleClassSequenceAtUtf16(pattern: SimpleClassSequencePattern, units: []const u16, pos: usize, flags: []const u8) ?RegExpMatch {
    if (pattern.anchor_start and !isUnitsLineStartPosition(units, pos, hasFlag(flags, 'm'))) return null;
    const end = simpleClassSequenceBacktrackUtf16(pattern, units, 0, pos, flags) orelse return null;
    return RegExpMatch{ .index = pos, .len = end - pos };
}

pub fn simpleCaptureSequenceAtUtf16(pattern: SimpleCaptureSequencePattern, units: []const u16, pos: usize, flags: []const u8) ?RegExpMatch {
    if (pattern.anchor_start and !isUnitsLineStartPosition(units, pos, hasFlag(flags, 'm'))) return null;
    var captures: [256]RegExpCapture = undefined;
    initFastCaptures(&captures, pattern.capture_count);
    const end = simpleCaptureSequenceBacktrackUtf16(pattern, units, 0, pos, flags, &captures) orelse return null;
    var found = RegExpMatch{ .index = pos, .len = end - pos, .capture_count = pattern.capture_count };
    @memcpy(found.captures[0..pattern.capture_count], captures[0..pattern.capture_count]);
    return found;
}

pub fn simpleClassSequenceBacktrackLatin1(
    pattern: SimpleClassSequencePattern,
    bytes: []const u8,
    atom_index: usize,
    pos: usize,
    flags: []const u8,
) ?usize {
    if (atom_index == pattern.len) {
        if (pattern.anchor_end and !isBytesLineEndPosition(bytes, pos, hasFlag(flags, 'm'))) return null;
        return pos;
    }

    const atom = pattern.atoms[atom_index];
    var count: usize = 0;
    var end = pos;
    while (count < atom.max_repeat and end < bytes.len and simpleClassSequenceAtomMatches(atom, bytes[end])) {
        count += 1;
        end += 1;
    }
    if (count < atom.min_repeat) return null;

    var try_count = count;
    while (true) {
        if (simpleClassSequenceBacktrackLatin1(pattern, bytes, atom_index + 1, pos + try_count, flags)) |matched_end| return matched_end;
        if (try_count == atom.min_repeat) break;
        try_count -= 1;
    }
    return null;
}

pub fn simpleCaptureSequenceBacktrackLatin1(
    pattern: SimpleCaptureSequencePattern,
    bytes: []const u8,
    atom_index: usize,
    pos: usize,
    flags: []const u8,
    captures: *[256]RegExpCapture,
) ?usize {
    if (atom_index == pattern.len) {
        if (pattern.anchor_end and !isBytesLineEndPosition(bytes, pos, hasFlag(flags, 'm'))) return null;
        return pos;
    }

    const atom = pattern.atoms[atom_index];
    var count: usize = 0;
    var end = pos;
    while (count < atom.max_repeat and end < bytes.len and simpleCaptureSequenceAtomMatches(atom, bytes[end])) {
        count += 1;
        end += 1;
    }
    if (count < atom.min_repeat) return null;

    var try_count = count;
    while (true) {
        const saved_capture = if (atom.capture_index) |capture_index| blk: {
            const slot = capture_index - 1;
            const saved = captures[slot];
            captures[slot] = .{ .start = pos, .len = try_count };
            break :blk saved;
        } else null;
        if (simpleCaptureSequenceBacktrackLatin1(pattern, bytes, atom_index + 1, pos + try_count, flags, captures)) |matched_end| return matched_end;
        if (atom.capture_index) |capture_index| captures[capture_index - 1] = saved_capture.?;
        if (try_count == atom.min_repeat) break;
        try_count -= 1;
    }
    return null;
}

pub fn simpleClassSequenceBacktrackUtf16(
    pattern: SimpleClassSequencePattern,
    units: []const u16,
    atom_index: usize,
    pos: usize,
    flags: []const u8,
) ?usize {
    if (atom_index == pattern.len) {
        if (pattern.anchor_end and !isUnitsLineEndPosition(units, pos, hasFlag(flags, 'm'))) return null;
        return pos;
    }

    const atom = pattern.atoms[atom_index];
    var count: usize = 0;
    var end = pos;
    while (count < atom.max_repeat and end < units.len and simpleClassSequenceAtomMatches(atom, units[end])) {
        count += 1;
        end += 1;
    }
    if (count < atom.min_repeat) return null;

    var try_count = count;
    while (true) {
        if (simpleClassSequenceBacktrackUtf16(pattern, units, atom_index + 1, pos + try_count, flags)) |matched_end| return matched_end;
        if (try_count == atom.min_repeat) break;
        try_count -= 1;
    }
    return null;
}

pub fn simpleCaptureSequenceBacktrackUtf16(
    pattern: SimpleCaptureSequencePattern,
    units: []const u16,
    atom_index: usize,
    pos: usize,
    flags: []const u8,
    captures: *[256]RegExpCapture,
) ?usize {
    if (atom_index == pattern.len) {
        if (pattern.anchor_end and !isUnitsLineEndPosition(units, pos, hasFlag(flags, 'm'))) return null;
        return pos;
    }

    const atom = pattern.atoms[atom_index];
    var count: usize = 0;
    var end = pos;
    while (count < atom.max_repeat and end < units.len and simpleCaptureSequenceAtomMatches(atom, units[end])) {
        count += 1;
        end += 1;
    }
    if (count < atom.min_repeat) return null;

    var try_count = count;
    while (true) {
        const saved_capture = if (atom.capture_index) |capture_index| blk: {
            const slot = capture_index - 1;
            const saved = captures[slot];
            captures[slot] = .{ .start = pos, .len = try_count };
            break :blk saved;
        } else null;
        if (simpleCaptureSequenceBacktrackUtf16(pattern, units, atom_index + 1, pos + try_count, flags, captures)) |matched_end| return matched_end;
        if (atom.capture_index) |capture_index| captures[capture_index - 1] = saved_capture.?;
        if (try_count == atom.min_repeat) break;
        try_count -= 1;
    }
    return null;
}

pub fn simpleClassPredicateFromSource(source: []const u8) SimpleClassPredicate {
    if (std.mem.eql(u8, source, "\\d")) return .ascii_digit;
    if (std.mem.eql(u8, source, "\\D")) return .ascii_not_digit;
    if (std.mem.eql(u8, source, "\\w")) return .ascii_word;
    if (std.mem.eql(u8, source, "\\W")) return .ascii_not_word;
    if (std.mem.eql(u8, source, "[a-z]")) return .ascii_lower;
    if (std.mem.eql(u8, source, "[A-Za-z]")) return .ascii_alpha;
    if (std.mem.eql(u8, source, "[0-9]")) return .ascii_decimal;
    return .generic;
}

pub fn initFastCaptures(captures: *[256]RegExpCapture, capture_count: usize) void {
    var index: usize = 0;
    while (index < capture_count) : (index += 1) {
        captures[index] = .{ .start = 0, .len = 0, .undefined = true };
    }
}

pub fn parseSimpleClassSequenceLiteral(source: []const u8, index: *usize, end_limit: usize) ?u16 {
    if (index.* >= end_limit or isRegExpSyntaxByte(source[index.*])) return null;
    const width = std.unicode.utf8ByteSequenceLength(source[index.*]) catch return null;
    if (index.* + width > end_limit) return null;
    const code_point = std.unicode.utf8Decode(source[index.* .. index.* + width]) catch return null;
    if (code_point > 0xffff) return null;
    index.* += width;
    return @intCast(code_point);
}

pub fn parseSimpleClassSequenceLatin1Literal(source: []const u8, index: *usize, end_limit: usize) ?u16 {
    if (index.* >= end_limit or isRegExpSyntaxByte(source[index.*])) return null;
    const unit = source[index.*];
    index.* += 1;
    return unit;
}

test "Latin1 RegExp source parser accepts raw non-ASCII simple literal sequence" {
    const latin1_source = [_]u8{ 0xe9, '+' };
    const pattern = parseSimpleClassSequenceLatin1Source(&latin1_source, "") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), pattern.len);
    try std.testing.expectEqual(@as(u16, 0xe9), pattern.atoms[0].literal);
    try std.testing.expectEqual(@as(usize, 1), pattern.atoms[0].min_repeat);
    try std.testing.expectEqual(std.math.maxInt(usize), pattern.atoms[0].max_repeat);
    try std.testing.expect(parseSimpleClassSequenceSource(&latin1_source, "") == null);
}

pub fn parseSimpleClassSequenceEscapedLiteral(source: []const u8, index: *usize, end_limit: usize) ?u16 {
    if (index.* + 1 >= end_limit or source[index.*] != '\\') return null;
    const escaped = source[index.* + 1];
    switch (escaped) {
        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/' => {
            index.* += 2;
            return escaped;
        },
        '0' => {
            if (index.* + 2 < end_limit and unicode_lib.isAsciiDigitByte(source[index.* + 2])) return null;
            index.* += 2;
            return 0;
        },
        'f' => {
            index.* += 2;
            return 0x0c;
        },
        'n' => {
            index.* += 2;
            return '\n';
        },
        'r' => {
            index.* += 2;
            return '\r';
        },
        't' => {
            index.* += 2;
            return '\t';
        },
        'v' => {
            index.* += 2;
            return 0x0b;
        },
        'c' => {
            if (index.* + 2 >= end_limit or !unicode_lib.isAsciiAlphaByte(source[index.* + 2])) return null;
            const value: u16 = source[index.* + 2] & 0x1f;
            index.* += 3;
            return value;
        },
        'x' => {
            if (index.* + 4 > end_limit) return null;
            var value: u16 = 0;
            var digit_index = index.* + 2;
            while (digit_index < index.* + 4) : (digit_index += 1) {
                const digit = hexNibble(source[digit_index]) orelse return null;
                value = value * 16 + @as(u16, @intCast(digit));
            }
            index.* += 4;
            return value;
        },
        'u' => {
            if (index.* + 2 < end_limit and source[index.* + 2] == '{') {
                var scan = index.* + 3;
                var saw_digit = false;
                var value: u32 = 0;
                while (scan < end_limit and source[scan] != '}') : (scan += 1) {
                    const digit = hexNibble(source[scan]) orelse return null;
                    saw_digit = true;
                    if (value > 0xffff / 16) return null;
                    value = value * 16 + digit;
                    if (value > 0xffff) return null;
                }
                if (!saw_digit or scan >= end_limit or source[scan] != '}') return null;
                index.* = scan + 1;
                return @intCast(value);
            }
            if (index.* + 6 > end_limit) return null;
            var value: u16 = 0;
            var digit_index = index.* + 2;
            while (digit_index < index.* + 6) : (digit_index += 1) {
                const digit = hexNibble(source[digit_index]) orelse return null;
                value = value * 16 + @as(u16, @intCast(digit));
            }
            index.* += 6;
            return value;
        },
        else => return null,
    }
}

pub fn isBytesLineStartPosition(bytes: []const u8, pos: usize, multiline: bool) bool {
    if (pos == 0) return true;
    if (!multiline or pos > bytes.len) return false;
    return bytes[pos - 1] == '\n' or bytes[pos - 1] == '\r';
}

pub fn isBytesLineEndPosition(bytes: []const u8, pos: usize, multiline: bool) bool {
    if (pos == bytes.len) return true;
    if (!multiline or pos > bytes.len) return false;
    return bytes[pos] == '\n' or bytes[pos] == '\r';
}

pub fn isUnitsLineStartPosition(units: []const u16, pos: usize, multiline: bool) bool {
    if (pos == 0) return true;
    if (!multiline or pos > units.len) return false;
    return isLineTerminatorUnit(units[pos - 1]);
}

pub fn isUnitsLineEndPosition(units: []const u16, pos: usize, multiline: bool) bool {
    if (pos == units.len) return true;
    if (!multiline or pos > units.len) return false;
    return isLineTerminatorUnit(units[pos]);
}

pub const SurrogatePairClassPattern = struct {
    high: u16,
    low: u16,
    anchor_start: bool,
    anchor_end: bool,
};

pub fn parseSurrogatePairClassSource(source: []const u8) ?SurrogatePairClassPattern {
    var index: usize = 0;
    const anchor_start = source.len > 0 and source[0] == '^';
    if (anchor_start) index += 1;
    if (index >= source.len or source[index] != '[') return null;
    index += 1;
    const high = readFixedUnicodeEscapeUnit(source, &index) orelse return null;
    const low = readFixedUnicodeEscapeUnit(source, &index) orelse return null;
    if (!isHighSurrogateUnit(high) or !isLowSurrogateUnit(low)) return null;
    if (index >= source.len or source[index] != ']') return null;
    index += 1;
    const anchor_end = index < source.len and source[index] == '$';
    if (anchor_end) index += 1;
    if (index != source.len) return null;
    return .{ .high = high, .low = low, .anchor_start = anchor_start, .anchor_end = anchor_end };
}

pub fn readFixedUnicodeEscapeUnit(source: []const u8, index: *usize) ?u16 {
    if (index.* + 6 > source.len or source[index.*] != '\\' or source[index.* + 1] != 'u') return null;
    var value: u16 = 0;
    var pos = index.* + 2;
    while (pos < index.* + 6) : (pos += 1) {
        const digit = hexNibble(source[pos]) orelse return null;
        value = value * 16 + @as(u16, @intCast(digit));
    }
    index.* += 6;
    return value;
}

pub fn surrogatePairClassAt(pattern: SurrogatePairClassPattern, string_value: core.string.String, pos: usize) ?RegExpMatch {
    if (pattern.anchor_start and pos != 0) return null;
    if (pos + 2 > string_value.len()) return null;
    if (string_value.codeUnitAt(pos) != pattern.high or string_value.codeUnitAt(pos + 1) != pattern.low) return null;
    if (pattern.anchor_end and pos + 2 != string_value.len()) return null;
    return .{ .index = pos, .len = 2 };
}

pub const UnicodeAstralSpecialPattern = union(enum) {
    repeat: struct {
        high: u16,
        low: u16,
        count: usize,
    },
    range: struct {
        lo: u21,
        hi: u21,
    },
    exact_class: struct {
        high: u16,
        low: u16,
        anchor_start: bool,
        anchor_end: bool,
    },
    negated_pair: struct {
        high: u16,
        low: u16,
    },
};

pub fn parseUnicodeAstralSpecialSource(source: []const u8) ?UnicodeAstralSpecialPattern {
    if (source.len == 0) return null;
    if (source[0] == '[' or source[0] == '^') return parseUnicodeAstralClassSpecialSource(source);

    var index: usize = 0;
    const pair = readAstralAtom(source, &index) orelse return null;
    if (index >= source.len or source[index] != '{') return null;
    index += 1;
    if (index >= source.len or !unicode_lib.isAsciiDigitByte(source[index])) return null;
    var count: usize = 0;
    while (index < source.len and unicode_lib.isAsciiDigitByte(source[index])) : (index += 1) {
        count = count * 10 + (source[index] - '0');
    }
    if (index >= source.len or source[index] != '}' or count == 0) return null;
    index += 1;
    if (index != source.len) return null;
    return .{ .repeat = .{ .high = pair.high, .low = pair.low, .count = count } };
}

pub fn parseUnicodeAstralClassSpecialSource(source: []const u8) ?UnicodeAstralSpecialPattern {
    var index: usize = 0;
    const anchor_start = source[index] == '^';
    if (anchor_start) index += 1;
    if (index >= source.len) return null;
    if (source[index] != '[') return null;
    index += 1;
    const negated = index < source.len and source[index] == '^';
    if (negated) index += 1;
    const first = readAstralAtom(source, &index) orelse return null;
    if (negated) {
        if (index >= source.len or source[index] != ']') return null;
        index += 1;
        if (anchor_start) return null;
        if (index != source.len) return null;
        return .{ .negated_pair = .{ .high = first.high, .low = first.low } };
    }
    if (index < source.len and source[index] == ']') {
        index += 1;
        const anchor_end = index < source.len and source[index] == '$';
        if (anchor_end) index += 1;
        if (index != source.len) return null;
        return .{ .exact_class = .{ .high = first.high, .low = first.low, .anchor_start = anchor_start, .anchor_end = anchor_end } };
    }
    if (index >= source.len or source[index] != '-') return null;
    index += 1;
    const second = readAstralAtom(source, &index) orelse return null;
    if (index >= source.len or source[index] != ']') return null;
    index += 1;
    if (anchor_start) return null;
    if (index != source.len) return null;
    const lo = first.code_point;
    const hi = second.code_point;
    if (lo > hi) return null;
    return .{ .range = .{ .lo = lo, .hi = hi } };
}

pub const AstralAtom = struct {
    high: u16,
    low: u16,
    code_point: u21,
};

pub fn readAstralAtom(source: []const u8, index: *usize) ?AstralAtom {
    if (readSurrogatePairEscape(source, index)) |pair| {
        return .{ .high = pair.high, .low = pair.low, .code_point = codePointFromSurrogatePair(pair.high, pair.low) };
    }
    if (index.* >= source.len) return null;
    const width = std.unicode.utf8ByteSequenceLength(source[index.*]) catch return null;
    if (index.* + width > source.len) return null;
    const cp = std.unicode.utf8Decode(source[index.* .. index.* + width]) catch return null;
    if (cp <= 0xffff or cp > 0x10ffff) return null;
    index.* += width;
    const pair = surrogatePairFromCodePoint(@intCast(cp));
    return .{ .high = pair.high, .low = pair.low, .code_point = @intCast(cp) };
}

pub fn readSurrogatePairEscape(source: []const u8, index: *usize) ?struct { high: u16, low: u16 } {
    const high = readFixedUnicodeEscapeUnit(source, index) orelse return null;
    const low = readFixedUnicodeEscapeUnit(source, index) orelse return null;
    if (!isHighSurrogateUnit(high) or !isLowSurrogateUnit(low)) return null;
    return .{ .high = high, .low = low };
}

pub fn unicodeAstralSpecialAt(pattern: UnicodeAstralSpecialPattern, string_value: core.string.String, pos: usize) ?RegExpMatch {
    return switch (pattern) {
        .repeat => |repeat| repeatedSurrogatePairAt(repeat.high, repeat.low, repeat.count, string_value, pos),
        .range => |range| astralRangeAt(range.lo, range.hi, string_value, pos),
        .exact_class => |pair| exactSurrogatePairClassAt(pair.high, pair.low, pair.anchor_start, pair.anchor_end, string_value, pos),
        .negated_pair => |pair| negatedSurrogatePairClassAt(pair.high, pair.low, string_value, pos),
    };
}

pub fn repeatedSurrogatePairAt(high: u16, low: u16, count: usize, string_value: core.string.String, pos: usize) ?RegExpMatch {
    const len = count * 2;
    if (pos + len > string_value.len()) return null;
    var offset: usize = 0;
    while (offset < len) : (offset += 2) {
        if (string_value.codeUnitAt(pos + offset) != high or string_value.codeUnitAt(pos + offset + 1) != low) return null;
    }
    return .{ .index = pos, .len = len };
}

pub fn exactSurrogatePairClassAt(high: u16, low: u16, anchor_start: bool, anchor_end: bool, string_value: core.string.String, pos: usize) ?RegExpMatch {
    if (anchor_start and pos != 0) return null;
    if (pos + 2 > string_value.len()) return null;
    if (string_value.codeUnitAt(pos) != high or string_value.codeUnitAt(pos + 1) != low) return null;
    if (anchor_end and pos + 2 != string_value.len()) return null;
    return .{ .index = pos, .len = 2 };
}

pub fn astralRangeAt(lo: u21, hi: u21, string_value: core.string.String, pos: usize) ?RegExpMatch {
    const cp = stringCodePointAt(string_value, pos) orelse return null;
    if (cp.len != 2 or cp.value < lo or cp.value > hi) return null;
    return .{ .index = pos, .len = 2 };
}

pub fn negatedSurrogatePairClassAt(high: u16, low: u16, string_value: core.string.String, pos: usize) ?RegExpMatch {
    const cp = stringCodePointAt(string_value, pos) orelse return null;
    if (cp.len == 2 and string_value.codeUnitAt(pos) == high and string_value.codeUnitAt(pos + 1) == low) return null;
    return .{ .index = pos, .len = cp.len };
}

pub fn isRegExpLineTerminator(unit: u16) bool {
    return unicode_lib.isEcmaLineTerminatorUnit(unit);
}

pub fn classEscapeRunLengthLatin1(source: []const u8, bytes: []const u8, start: usize) usize {
    if (!classEscapeIsQuantified(source)) return 1;
    var end = start;
    while (end < bytes.len and classEscapeUnitMatches(source, bytes[end])) : (end += 1) {}
    return end - start;
}

pub fn classEscapeRunLengthUtf16(source: []const u8, units: []const u16, start: usize) usize {
    if (!classEscapeIsQuantified(source)) return 1;
    var end = start;
    while (end < units.len and classEscapeUnitMatches(source, units[end])) : (end += 1) {}
    return end - start;
}

pub fn classEscapeIsQuantified(source: []const u8) bool {
    const kind_index = classEscapeKindIndex(source) orelse return false;
    return source.len == kind_index + 2 and source[kind_index + 1] == '+';
}

pub fn classEscapeKindIndex(source: []const u8) ?usize {
    if (source.len < 2 or source[0] != '\\') return null;
    if (source[1] == '\\') return if (source.len >= 3) 2 else null;
    return 1;
}

pub fn isRegExpSyntaxByte(byte: u8) bool {
    return switch (byte) {
        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|' => true,
        else => false,
    };
}

pub fn hasFlag(flags: []const u8, flag: u8) bool {
    return std.mem.indexOfScalar(u8, flags, flag) != null;
}

pub fn regexpLastIndex(rt: *core.JSRuntime, object: *core.Object) usize {
    const value = object.getProperty(core.atom.ids.lastIndex);
    defer value.free(rt);
    if (value.asInt32()) |int_value| return if (int_value < 0) 0 else @intCast(int_value);
    if (value.asFloat64()) |float_value| {
        if (std.math.isNan(float_value) or float_value <= 0) return 0;
        if (float_value >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return std.math.maxInt(usize);
        return @intFromFloat(@floor(float_value));
    }
    return 0;
}

pub fn setRegExpLastIndex(rt: *core.JSRuntime, object: *core.Object, index: usize) !void {
    const value = if (index <= @as(usize, @intCast(std.math.maxInt(i32))))
        core.JSValue.int32(@intCast(index))
    else
        core.JSValue.float64(@floatFromInt(index));
    object.setProperty(rt, core.atom.ids.lastIndex, value) catch return error.TypeError;
}

pub fn updateRegExpLegacyStaticsNoCaptures(rt: *core.JSRuntime, global: *core.Object, input_value: core.JSValue, found: RegExpMatch, input_len: usize) !void {
    const regexp_ctor = regExpConstructorFromGlobal(rt, global) catch return;
    if (regexp_ctor.class_payload_kind != .function) return;
    const legacy = try regexp_ctor.ensureRegExpLegacyStatics(rt);
    const already_lazy_no_capture = legacy.lazy_no_capture_match;

    try replaceRegExpLegacySlot(rt, regexp_ctor, &legacy.input, input_value);
    if (!already_lazy_no_capture) {
        clearRegExpLegacySlot(rt, &legacy.last_match);
        clearRegExpLegacySlot(rt, &legacy.left_context);
        clearRegExpLegacySlot(rt, &legacy.right_context);
    }
    clearRegExpLegacySlot(rt, &legacy.last_paren);
    for (&legacy.captures) |*capture| clearRegExpLegacySlot(rt, capture);

    legacy.lazy_no_capture_match = true;
    legacy.lazy_match_index = found.index;
    legacy.lazy_match_len = found.len;
    legacy.lazy_input_len = input_len;
}

pub fn createRegExpIndexPair(rt: *core.JSRuntime, global: *core.Object, start: usize, end: usize) !core.JSValue {
    const out = try core.Object.createArray(rt, arrayPrototypeFromGlobal(rt, global));
    errdefer core.Object.destroyFromHeader(rt, &out.header);
    try defineSplitValueElement(rt, out, 0, core.JSValue.int32(@intCast(start)));
    try defineSplitValueElement(rt, out, 1, core.JSValue.int32(@intCast(end)));
    return out.value();
}

pub fn appendDecodedRegExpGroupName(rt: *core.JSRuntime, out: *std.ArrayList(u8), name: []const u8) !void {
    var index: usize = 0;
    while (index < name.len) {
        if (name[index] == '\\' and index + 1 < name.len and name[index + 1] == 'u') {
            if (readRegExpGroupNameEscape(name, &index)) |cp| {
                var code_point = cp;
                if (isHighSurrogateCodePoint(cp)) {
                    const saved = index;
                    if (readRegExpGroupNameEscape(name, &index)) |low| {
                        if (isLowSurrogateCodePoint(low)) {
                            code_point = combinedSurrogateCodePoint(@intCast(cp), @intCast(low));
                        } else {
                            index = saved;
                        }
                    } else {
                        index = saved;
                    }
                }
                try appendUtf8CodePointForRegExpName(rt, out, code_point);
                continue;
            }
        }
        try out.append(rt.memory.allocator, name[index]);
        index += 1;
    }
}

pub fn readRegExpGroupNameEscape(name: []const u8, index: *usize) ?u21 {
    if (index.* + 2 > name.len or name[index.*] != '\\' or name[index.* + 1] != 'u') return null;
    var pos = index.* + 2;
    if (pos < name.len and name[pos] == '{') {
        pos += 1;
        var value: u32 = 0;
        var saw_digit = false;
        while (pos < name.len and name[pos] != '}') : (pos += 1) {
            const digit = hexNibble(name[pos]) orelse return null;
            saw_digit = true;
            value = value * 16 + digit;
            if (value > 0x10ffff) return null;
        }
        if (!saw_digit or pos >= name.len or name[pos] != '}') return null;
        index.* = pos + 1;
        return @intCast(value);
    }
    if (pos >= name.len or hexNibble(name[pos]) == null) return null;
    var available_hex: usize = 0;
    while (pos + available_hex < name.len and available_hex < 4 and hexNibble(name[pos + available_hex]) != null) : (available_hex += 1) {}
    const digit_count: usize = if (available_hex >= 4) 4 else available_hex;
    var value: u32 = 0;
    var count: usize = 0;
    while (count < digit_count) : (count += 1) {
        const digit = hexNibble(name[pos + count]) orelse return null;
        value = value * 16 + digit;
    }
    index.* = pos + digit_count;
    return @intCast(value);
}

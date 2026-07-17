//! RegExp builtin integration helpers and VM-backed fast paths.

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const method_ids = core.host_function.builtin_method_ids;
const frame_mod = @import("frame.zig");
const property_ops = @import("property_ops.zig");
const regexp_adapter = @import("regexp_adapter.zig");
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
// importing `regexp_ops.constructWithPrototype` directly, so the construct
// logic stays owned by the table (Phase 6b-3e). The pattern/flags are already
// coerced and the instance prototype resolved at the call site, so the record
// only runs the constructor body.
const regexp_construct_ref = core.function.NativeBuiltinRef{
    .domain = .regexp,
    .id = @intFromEnum(core.host_function.builtin_method_ids.regexp.ConstructorMethod.construct),
};

fn constructRegExpRecordInNativeScope(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: ?*core.Object,
    prototype: ?*core.Object,
    pattern: core.JSValue,
    flags: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const args = [_]core.JSValue{ pattern, flags };
    return (try builtin_dispatch.callConstructRecordInNativeScope(ctx, output, global, &.{}, constructor, regexp_construct_ref, prototype, &args, caller_function, caller_frame)) orelse error.TypeError;
}

// Helpers that remain in call_runtime.zig (generic utilities and RegExp helpers
// outside the fast-path cluster).
const RegExpMatch = string_ops.RegExpMatch;
const appendStringValueUnits = string_ops.appendStringValueUnits;
const appendUtf16UnitsAsUtf8 = string_ops.appendUtf16UnitsAsUtf8;
const appendUtf8CodePointForRegExpName = string_ops.appendUtf8CodePointForRegExpName;
const arrayPrototypeFromGlobal = array_ops.arrayPrototypeFromGlobal;
const callValueOrBytecode = call_runtime.callValueOrBytecode;
const combinedSurrogateCodePoint = string_ops.combinedSurrogateCodePoint;
const constructorPrototypeFromGlobal = object_ops.constructorPrototypeFromGlobal;
const createRegExpMatchArrayFromValue = string_ops.createRegExpMatchArrayFromValue;
const defineSplitValueElement = string_ops.defineSplitValueElement;
const decodeRegExpLegacyCaptureSlice = string_ops.decodeRegExpLegacyCaptureSlice;
const fastToLengthIndex = coercion_ops.fastToLengthIndex;
const getValueProperty = object_ops.getValueProperty;
const hexNibble = array_ops.hexNibble;
const isCallableValue = call_runtime.isCallableValue;
const isHighSurrogateCodePoint = string_ops.isHighSurrogateCodePoint;
const isLineTerminatorUnit = string_ops.isLineTerminatorUnit;
const isLowSurrogateCodePoint = string_ops.isLowSurrogateCodePoint;
const isSameRealmRegExpPrototypeGetter = object_ops.isSameRealmRegExpPrototypeGetter;
const latin1StringSlice = string_ops.latin1StringSlice;
const objectFromValue = object_ops.objectFromValue;
const objectHasRegExpInternalSlots = object_ops.objectHasRegExpInternalSlots;
const objectRealmGlobal = object_ops.objectRealmGlobal;
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
const replaceRegExpLegacySlot = string_ops.replaceRegExpLegacySlot;
const sameObjectIdentity = object_ops.sameObjectIdentity;
const setValuePropertyStrict = object_ops.setValuePropertyStrict;
const stringLengthIndex = string_ops.stringLengthIndex;
const stringSliceValue = string_ops.stringSliceValue;
const stringValueContainsUnitByte = string_ops.stringValueContainsUnitByte;
const throwRegExpAccessorTypeError = array_ops.throwRegExpAccessorTypeError;
const throwTypeErrorMessage = exception_ops.throwTypeErrorMessage;
const toLengthIndex = coercion_ops.toLengthIndex;
const toStringForAnnexB = string_ops.toStringForAnnexB;
const valueTruthy = coercion_ops.valueTruthy;

pub fn qjsRegExpFunctionCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: ?*core.Object,
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
    } else if (!pattern_is_regexp and !pattern.isString() and !pattern.isUndefined()) {
        // Mirrors js_regexp_constructor (quickjs.c:47786-47793): any non-regexp,
        // non-undefined pattern goes through JS_ToString, which throws TypeError
        // for symbols instead of leaking '[object Object]'.
        const string_value = try toStringForAnnexB(ctx, output, global, pattern, caller_function, caller_frame);
        owned_pattern = string_value;
        pattern = string_value;
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
    // Mirrors js_compile_regexp (quickjs.c:47577-47578): the flags operand is
    // ToString'd via JS_ToCStringLen, which throws TypeError for symbols.
    if (!flags.isUndefined() and !flags.isString()) {
        const string_value = try toStringForAnnexB(ctx, output, global, flags, caller_function, caller_frame);
        if (owned_flags) |old| old.free(ctx.runtime);
        owned_flags = string_value;
        flags = string_value;
    }

    return constructRegExpRecordInNativeScope(ctx, output, global, constructor, constructorPrototypeFromGlobal(ctx.runtime, global, "RegExp"), pattern, flags, caller_function, caller_frame);
}

pub fn qjsRegExpConstructCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: ?*core.Object,
    new_target: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var native_scope = builtin_dispatch.NativeBacktraceScope.init(ctx, constructor);
    native_scope.push();
    defer native_scope.deinit();

    return qjsRegExpConstructCallInNativeScope(ctx, output, global, constructor, new_target, args, caller_function, caller_frame) catch |err| {
        try builtin_dispatch.materializeRuntimeError(ctx, global, err);
        return err;
    };
}

fn qjsRegExpConstructCallInNativeScope(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: ?*core.Object,
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
        return constructRegExpRecordInNativeScope(ctx, output, global, constructor, prototype, input_pattern, input_flags, caller_function, caller_frame);
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
                const source = try regexpInternalStringValue(ctx.runtime, pattern_object, true);
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
    } else if (!pattern.isString()) {
        // Mirrors js_regexp_constructor (quickjs.c:47786-47793): any non-regexp,
        // non-undefined pattern goes through JS_ToString, which throws TypeError
        // for symbols instead of leaking '[object Object]'.
        const string_value = try toStringForAnnexB(ctx, output, global, pattern, caller_function, caller_frame);
        owned_pattern = string_value;
        pattern = string_value;
    }

    var owned_flags: ?core.JSValue = null;
    defer if (owned_flags) |value| value.free(ctx.runtime);
    var flags = if (!input_flags.isUndefined())
        input_flags
    else if (pattern_is_regexp) blk: {
        const pattern_object = objectFromValue(input_pattern) orelse break :blk core.JSValue.undefinedValue();
        if (pattern_object.class_id == core.class.ids.regexp) {
            const pattern_flags = try regexpInternalStringValue(ctx.runtime, pattern_object, false);
            owned_flags = pattern_flags;
            break :blk pattern_flags;
        }
        const flags_key = try ctx.runtime.internAtom("flags");
        defer ctx.runtime.atoms.free(flags_key);
        const pattern_flags = try getValueProperty(ctx, output, global, input_pattern, flags_key, caller_function, caller_frame);
        owned_flags = pattern_flags;
        break :blk pattern_flags;
    } else core.JSValue.undefinedValue();

    const prototype = try reflectConstructPrototypeVm(ctx, output, global, "RegExp", new_target, caller_function, caller_frame);
    // Mirrors js_regexp_constructor + js_compile_regexp (quickjs.c:47795-47797 +
    // 47577-47578): the flags operand is ToString'd inside js_compile_regexp —
    // after js_create_from_ctor resolved new.target's prototype — and
    // JS_ToCStringLen throws TypeError for symbols (not SyntaxError).
    if (!flags.isUndefined() and !flags.isString()) {
        const string_value = try toStringForAnnexB(ctx, output, global, flags, caller_function, caller_frame);
        if (owned_flags) |old| old.free(ctx.runtime);
        owned_flags = string_value;
        flags = string_value;
    }
    return constructRegExpRecordInNativeScope(ctx, output, global, constructor, prototype, pattern, flags, caller_function, caller_frame);
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
    const exec_atom = (comptime core.atom.predefinedId("exec", .string)) orelse return error.TypeError;
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

pub fn qjsRegExpTestFastNoResult(
    ctx: *core.JSContext,
    regexp_object: *core.Object,
    string_value: core.JSValue,
) !?bool {
    if (!regExpLastIndexCanSkipCoercion(regexp_object)) return null;

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

    return null;
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

    if (flags.isUndefined()) {
        if (objectFromValue(pattern)) |pattern_object| {
            if (pattern_object.class_id == core.class.ids.regexp) {
                const source_value = try regexpInternalStringValue(ctx.runtime, pattern_object, true);
                defer source_value.free(ctx.runtime);
                const compiled_bytecode = pattern_object.regexpCompiledBytecode();
                if (compiled_bytecode.len == 0) return error.TypeError;

                const next_source = source_value.dup();
                var next_source_owned = true;
                errdefer if (next_source_owned) next_source.free(ctx.runtime);
                const source_slot = regexp_object.regexpSourceSlot();
                const old_source = source_slot.*;
                try regexp_object.setRegexpCompiledBytecode(ctx.runtime, compiled_bytecode);
                source_slot.* = next_source;
                next_source_owned = false;
                if (old_source) |value| value.free(ctx.runtime);

                try setValuePropertyStrict(ctx, output, global, this_value, core.atom.ids.lastIndex, core.JSValue.int32(0), caller_function, caller_frame);
                return this_value.dup();
            }
        }
    }

    const source_value = blk: {
        if (objectFromValue(pattern)) |pattern_object| {
            if (pattern_object.class_id == core.class.ids.regexp) {
                if (!flags.isUndefined()) return error.TypeError;
                break :blk try regexpInternalStringValue(ctx.runtime, pattern_object, true);
            }
        }
        if (pattern.isUndefined()) break :blk try value_ops.createStringValue(ctx.runtime, "");
        break :blk try toStringForAnnexB(ctx, output, global, pattern, caller_function, caller_frame);
    };
    defer source_value.free(ctx.runtime);

    const flags_value = blk: {
        if (objectFromValue(pattern)) |pattern_object| {
            if (pattern_object.class_id == core.class.ids.regexp) {
                break :blk try regexpInternalStringValue(ctx.runtime, pattern_object, false);
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
    var compiled = regexp_adapter.compile(ctx.runtime.memory.allocator, source_bytes.items, flag_bytes.items) catch |err| switch (err) {
        error.InvalidPattern, error.Unsupported => return error.SyntaxError,
        else => |other| return other,
    };
    defer compiled.deinit(ctx.runtime.memory.allocator);

    const next_source = source_value.dup();
    var next_source_owned = true;
    errdefer if (next_source_owned) next_source.free(ctx.runtime);
    const source_slot = regexp_object.regexpSourceSlot();

    const old_source = source_slot.*;
    try regexp_object.setRegexpCompiledBytecode(ctx.runtime, compiled.bytecode);
    source_slot.* = next_source;
    next_source_owned = false;
    if (old_source) |value| value.free(ctx.runtime);

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

    const species_atom = (comptime core.atom.predefinedId("Symbol.species", .symbol)) orelse {
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

pub fn regexpInternalFlagsContain(regexp_object: *core.Object, needle: u8) bool {
    const compiled_bytecode = regexp_object.regexpCompiledBytecode();
    if (compiled_bytecode.len == 0) return false;
    const bit: u16 = switch (needle) {
        'd' => regexp_adapter.flag_bits.indices,
        'g' => regexp_adapter.flag_bits.global,
        'i' => regexp_adapter.flag_bits.ignore_case,
        'm' => regexp_adapter.flag_bits.multiline,
        's' => regexp_adapter.flag_bits.dot_all,
        'u' => regexp_adapter.flag_bits.unicode,
        'v' => regexp_adapter.flag_bits.unicode_sets,
        'y' => regexp_adapter.flag_bits.sticky,
        else => return false,
    };
    return (regexp_adapter.flagBitsFromBytecode(compiled_bytecode) & bit) != 0;
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
    const exec_atom = (comptime core.atom.predefinedId("exec", .string)) orelse return error.TypeError;
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

    return null;
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
    const alloc_count = compiled.allocCount();
    var inline_capture_slots: [regexp_adapter.small_exec_slots]usize = undefined;
    var heap_capture_slots: []usize = &.{};
    defer if (heap_capture_slots.len != 0) rt.memory.allocator.free(heap_capture_slots);
    const capture_slots = if (alloc_count <= inline_capture_slots.len)
        inline_capture_slots[0..alloc_count]
    else capture: {
        heap_capture_slots = try rt.memory.allocator.alloc(usize, alloc_count);
        break :capture heap_capture_slots;
    };
    const result = regexp_adapter.execCaptureSlotsOnStringFromIndex(rt, compiled, string_value, start_index, capture_slots) catch |err| switch (err) {
        error.BytecodeCorrupt, error.Timeout => return null,
        else => return err,
    };

    switch (result) {
        .match => {
            const match_start = regexp_adapter.captureSlotValue(capture_slots[0]) orelse 0;
            const match_end = regexp_adapter.captureSlotValue(capture_slots[1]) orelse match_start;
            if (use_last_index and (is_global or is_sticky)) {
                const next_index = match_end;
                const next_value = if (next_index <= @as(usize, @intCast(std.math.maxInt(i32))))
                    core.JSValue.int32(@intCast(next_index))
                else
                    core.JSValue.float64(@floatFromInt(next_index));
                try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, next_value, caller_function, caller_frame);
            }

            const total_capture_count = compiled.captureCount();
            var found = RegExpMatch{
                .index = match_start,
                .len = match_end - match_start,
                .capture_count = total_capture_count - 1,
            };
            var capture_index: usize = 1;
            while (capture_index < total_capture_count) : (capture_index += 1) {
                const found_index = capture_index - 1;
                const capture_start_slot = capture_slots[2 * capture_index];
                if (regexp_adapter.captureSlotValue(capture_start_slot)) |capture_start| {
                    const capture_end = regexp_adapter.captureSlotValue(capture_slots[2 * capture_index + 1]) orelse capture_start;
                    found.captures[found_index] = .{
                        .start = capture_start,
                        .len = capture_end - capture_start,
                        .undefined = false,
                        .name = compiled.groupName(capture_index),
                    };
                } else {
                    found.captures[found_index] = .{
                        .start = 0,
                        .len = 0,
                        .undefined = true,
                        .name = compiled.groupName(capture_index),
                    };
                }
            }
            return try createRegExpMatchArrayFromValue(rt, global, string_value, &found, has_indices);
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
    const match_atom = (comptime core.atom.predefinedId("Symbol.match", .symbol)) orelse return isRegExpValue(value);
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
    const compiled_bytecode = object.regexpCompiledBytecode();
    if (compiled_bytecode.len == 0) return false;
    try regexp_adapter.appendCanonicalFlagsFromBits(rt.memory.allocator, out, regexp_adapter.flagBitsFromBytecode(compiled_bytecode));
    return true;
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

pub fn isRegExpLineTerminator(unit: u16) bool {
    return unicode_lib.isEcmaLineTerminatorUnit(unit);
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

pub fn updateRegExpLegacyStaticsNoCaptures(rt: *core.JSRuntime, global: *core.Object, input_value: core.JSValue, found: *const RegExpMatch, input_len: usize) !void {
    const regexp_ctor = regExpConstructorFromGlobal(rt, global) catch return;
    if (regexp_ctor.flags.class_payload_kind != .function) return;
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

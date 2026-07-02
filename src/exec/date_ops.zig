const std = @import("std");

const bytecode = @import("../bytecode.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const value_ops = @import("value_ops.zig");
const call_runtime = @import("call_runtime.zig");
const coercion_ops = @import("coercion_ops.zig");
const object_ops = @import("object_ops.zig");
const string_ops = @import("string_ops.zig");

// The Date constructor body runs through the record table keyed on this ref
// (matching the RegExp/String construct unification in Phase 6b-3d/e): the
// VM-context argument coercion stays here in `qjsDateConstructWithPrototype`
// and the coerced primitives + resolved instance prototype are threaded to the
// record, whose construct branch (`builtins/date.zig` `dateCall`) runs
// `constructWithPrototype`. The Date construct record reads only
// `args`/`new_target`, so no constructor function object or caller frame is
// threaded.
const date_construct_ref = core.function.NativeBuiltinRef{
    .domain = .date,
    .id = @intFromEnum(core.host_function.builtin_method_ids.date.ConstructorMethod.construct),
};

/// Run the builtin Date constructor body for already-coerced `args` and a
/// resolved instance `prototype` through the record table.
fn constructDateRecord(
    ctx: *core.JSContext,
    prototype: ?*core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    return (try builtin_dispatch.callConstructRecord(ctx, null, null, &.{}, null, date_construct_ref, prototype, args, null, null)) orelse error.TypeError;
}

const date_method_ids = core.host_function.builtin_method_id_lookup.date;
const DatePrototypeMethod = core.host_function.builtin_method_ids.date.PrototypeMethod;

/// Route a Date prototype-method *body* through the record table's
/// func-object-free arm. `decoded_method_id` is the legacy 1..34 selector the
/// builtin date bodies switch on; it is re-encoded to its `PrototypeMethod`
/// record id so the dispatch lands on `builtins/date.zig` `dateCall` (which runs
/// the pure `methodCallArgs` body for it). `args` must already be coerced. This
/// replaces the former direct `builtins.date.methodCall*` calls so exec carries
/// no compile-time Date knowledge.
pub fn callDateBody(
    ctx: *core.JSContext,
    this_value: core.JSValue,
    decoded_method_id: u32,
    args: []const core.JSValue,
) !core.JSValue {
    const native_ref = core.function.NativeBuiltinRef{ .domain = .date, .id = date_method_ids.encodePrototypeMethodId(decoded_method_id).? };
    return (try builtin_dispatch.callInternalRecord(ctx, null, null, &.{}, null, this_value, native_ref, args, null, null)) orelse error.TypeError;
}

/// Route a Date static-method body (`Date.UTC`/`Date.parse`/`Date.now`) through
/// the table. `static_method_id` is the `StaticMethod` enum value (1/2/3), which
/// doubles as the `staticCall` selector; `args` must already be coerced.
pub fn callDateStaticBody(
    ctx: *core.JSContext,
    static_method_id: u32,
    args: []const core.JSValue,
) !core.JSValue {
    const native_ref = core.function.NativeBuiltinRef{ .domain = .date, .id = static_method_id };
    return (try builtin_dispatch.callInternalRecord(ctx, null, null, &.{}, null, core.JSValue.undefinedValue(), native_ref, args, null, null)) orelse error.TypeError;
}

/// Capture a Date instance's `[[DateValue]]` as an f64 by routing the `getTime`
/// body through the table (the spec captures `t` before coercing setter args).
fn captureDateValueMs(ctx: *core.JSContext, this_value: core.JSValue) !f64 {
    const captured_value = try callDateBody(ctx, this_value, 1, &.{});
    defer captured_value.free(ctx.runtime);
    return value_ops.numberValue(captured_value) orelse std.math.nan(f64);
}

/// Route `setYear` with a pre-captured `[[DateValue]]` and coerced year through
/// the table's captured-setter arm (`setYearNumber` body). The captured ms and
/// year are packed as the leading args the record handler unpacks.
fn callDateSetYearWithCapturedMs(
    ctx: *core.JSContext,
    this_value: core.JSValue,
    captured_ms: f64,
    year_number: f64,
) !core.JSValue {
    const native_ref = core.function.NativeBuiltinRef{ .domain = .date, .id = @intFromEnum(DatePrototypeMethod.set_year_with_captured_ms) };
    const packed_args = [_]core.JSValue{ core.JSValue.float64(captured_ms), core.JSValue.float64(year_number) };
    return (try builtin_dispatch.callInternalRecord(ctx, null, null, &.{}, null, this_value, native_ref, &packed_args, null, null)) orelse error.TypeError;
}

/// Route a date-parts setter (decoded ids 25..31) with a pre-captured
/// `[[DateValue]]` and coerced field args through the table's captured-setter arm
/// (`methodCallArgsWithCapturedMs` body). Layout: args[0]=captured ms,
/// args[1]=int32 decoded setter id, args[2..]=coerced field args.
fn callDateSetPartsWithCapturedMs(
    ctx: *core.JSContext,
    this_value: core.JSValue,
    decoded_method_id: u32,
    captured_ms: f64,
    args: []const core.JSValue,
) !core.JSValue {
    const native_ref = core.function.NativeBuiltinRef{ .domain = .date, .id = @intFromEnum(DatePrototypeMethod.set_parts_with_captured_ms) };
    var packed_args: [6]core.JSValue = undefined;
    packed_args[0] = core.JSValue.float64(captured_ms);
    packed_args[1] = core.JSValue.int32(@intCast(decoded_method_id));
    const count = @min(args.len, packed_args.len - 2);
    @memcpy(packed_args[2 .. 2 + count], args[0..count]);
    return (try builtin_dispatch.callInternalRecord(ctx, null, null, &.{}, null, this_value, native_ref, packed_args[0 .. 2 + count], null, null)) orelse error.TypeError;
}

const DateToPrimitiveHint = enum {
    string,
    number,
};

pub fn qjsDateSetYear(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const object = object_ops.objectFromValue(this_value) orelse return null;
    if (object.class_id != core.class.ids.date) return null;
    const captured_ms = try captureDateValueMs(ctx, this_value);
    const year_input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const year_value = try coercion_ops.toNumberForDateMethod(ctx, output, global, year_input, caller_function, caller_frame);
    defer year_value.free(ctx.runtime);
    const year_number = value_ops.numberValue(year_value) orelse std.math.nan(f64);
    return try callDateSetYearWithCapturedMs(ctx, this_value, captured_ms, year_number);
}

pub fn qjsDateSetTime(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const object = object_ops.objectFromValue(this_value) orelse return null;
    if (object.class_id != core.class.ids.date) return null;
    const time_input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const time_value = try coercion_ops.toNumberForDateMethod(ctx, output, global, time_input, caller_function, caller_frame);
    defer time_value.free(ctx.runtime);
    return try callDateBody(ctx, this_value, 24, &.{time_value});
}

pub fn qjsDateStaticCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    _ = this_value;
    if (method_id != 1) return null;
    var coerced_args: [7]core.JSValue = undefined;
    var coerced_len: usize = 0;
    defer {
        for (coerced_args[0..coerced_len]) |value| value.free(ctx.runtime);
    }
    while (coerced_len < args.len and coerced_len < coerced_args.len) : (coerced_len += 1) {
        coerced_args[coerced_len] = try coercion_ops.toNumberForDateMethod(ctx, output, global, args[coerced_len], caller_function, caller_frame);
    }
    return try callDateStaticBody(ctx, method_id, coerced_args[0..coerced_len]);
}

pub fn qjsDateCapturedSetterCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (method_id < 25 or method_id > 31) return null;
    const object = object_ops.objectFromValue(this_value) orelse return null;
    if (object.class_id != core.class.ids.date) return null;

    const captured_ms = try captureDateValueMs(ctx, this_value);

    // qjs set_date_field coerces exactly `min_int(argc, end_field -
    // first_field)` arguments (quickjs.c:55265); extra arguments are not
    // coerced (their valueOf must not run).
    const field_count: usize = switch (method_id) {
        25 => 1, // setMilliseconds 0x671
        26 => 2, // setSeconds 0x571
        27 => 3, // setMinutes 0x471
        28 => 4, // setHours 0x371
        29 => 1, // setDate 0x211
        30 => 2, // setMonth 0x121
        31 => 3, // setFullYear 0x011
        else => unreachable,
    };
    var coerced_args: [4]core.JSValue = undefined;
    var coerced_len: usize = 0;
    defer {
        for (coerced_args[0..coerced_len]) |value| value.free(ctx.runtime);
    }
    while (coerced_len < args.len and coerced_len < field_count) : (coerced_len += 1) {
        coerced_args[coerced_len] = try coercion_ops.toNumberForDateMethod(ctx, output, global, args[coerced_len], caller_function, caller_frame);
    }

    return try callDateSetPartsWithCapturedMs(ctx, this_value, method_id, captured_ms, coerced_args[0..coerced_len]);
}

pub fn qjsDateToJsonCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    _ = args;
    if (this_value.isNull() or this_value.isUndefined()) return error.TypeError;

    const primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, this_value);
    defer primitive.free(ctx.runtime);
    if (primitive.isNumber()) {
        const number = value_ops.numberValue(primitive) orelse std.math.nan(f64);
        if (!std.math.isFinite(number)) return core.JSValue.nullValue();
    }

    const key = try ctx.runtime.internAtom("toISOString");
    defer ctx.runtime.atoms.free(key);
    const method = try object_ops.getValueProperty(ctx, output, global, this_value, key, caller_function, caller_frame);
    defer method.free(ctx.runtime);
    if (!call_runtime.isCallableValue(method)) return error.TypeError;
    return try call_runtime.callValueOrBytecode(ctx, output, global, this_value, method, &.{}, caller_function, caller_frame);
}

pub fn qjsDateConstructWithPrototype(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    prototype: ?*core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len == 0) return constructDateRecord(ctx, prototype, args);

    if (args.len == 1) {
        if (object_ops.objectFromValue(args[0])) |object| {
            if (object.class_id == core.class.ids.date) {
                const time_value = try callDateBody(ctx, args[0], 1, &.{});
                defer time_value.free(ctx.runtime);
                return constructDateRecord(ctx, prototype, &.{time_value});
            }

            const primitive = try coercion_ops.toPrimitiveForAddition(ctx, output, global, args[0]);
            defer primitive.free(ctx.runtime);
            if (primitive.isString()) return constructDateRecord(ctx, prototype, &.{primitive});
            // JS_ToFloat64Free on a bigint primitive throws (qjs
            // js_date_constructor single-arg branch).
            if (primitive.isBigInt()) return error.TypeError;
            const number = try value_ops.toNumberValue(ctx.runtime, primitive);
            defer number.free(ctx.runtime);
            return constructDateRecord(ctx, prototype, &.{number});
        }

        if (args[0].isString()) return constructDateRecord(ctx, prototype, args);
        if (args[0].isBigInt()) return error.TypeError;
        const number = try value_ops.toNumberValue(ctx.runtime, args[0]);
        defer number.free(ctx.runtime);
        return constructDateRecord(ctx, prototype, &.{number});
    }

    var coerced_args: [7]core.JSValue = undefined;
    var coerced_len: usize = 0;
    defer {
        for (coerced_args[0..coerced_len]) |value| value.free(ctx.runtime);
    }
    while (coerced_len < args.len and coerced_len < coerced_args.len) : (coerced_len += 1) {
        coerced_args[coerced_len] = try coercion_ops.toNumberForDateMethod(ctx, output, global, args[coerced_len], null, null);
    }
    return constructDateRecord(ctx, prototype, coerced_args[0..coerced_len]);
}

pub fn qjsDateToPrimitiveCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (!this_value.isObject()) return error.TypeError;

    const hint_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const hint = qjsDateToPrimitiveHint(hint_value) orelse return error.TypeError;
    return switch (hint) {
        .string => try qjsDateOrdinaryToPrimitive(ctx, output, global, this_value, true, caller_function, caller_frame),
        .number => try qjsDateOrdinaryToPrimitive(ctx, output, global, this_value, false, caller_function, caller_frame),
    };
}

fn qjsDateToPrimitiveHint(value: core.JSValue) ?DateToPrimitiveHint {
    if (!value.isString()) return null;
    if (string_ops.stringValueUnitsEqualBytes(value, "string") or string_ops.stringValueUnitsEqualBytes(value, "default")) return .string;
    if (string_ops.stringValueUnitsEqualBytes(value, "number")) return .number;
    return null;
}

fn qjsDateOrdinaryToPrimitive(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    string_first: bool,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (string_first) {
        if (try object_ops.callObjectToPrimitiveMethod(ctx, output, global, receiver, "toString", caller_function, caller_frame)) |primitive| return primitive;
        if (try object_ops.callObjectToPrimitiveMethod(ctx, output, global, receiver, "valueOf", caller_function, caller_frame)) |primitive| return primitive;
    } else {
        if (try object_ops.callObjectToPrimitiveMethod(ctx, output, global, receiver, "valueOf", caller_function, caller_frame)) |primitive| return primitive;
        if (try object_ops.callObjectToPrimitiveMethod(ctx, output, global, receiver, "toString", caller_function, caller_frame)) |primitive| return primitive;
    }
    return error.TypeError;
}

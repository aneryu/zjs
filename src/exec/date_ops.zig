const std = @import("std");

const bytecode = @import("../bytecode.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const value_ops = @import("value_ops.zig");
const call_runtime = @import("call_runtime.zig");
const coercion_ops = @import("coercion_ops.zig");
const exception_ops = @import("vm_exception_ops.zig");
const exceptions = @import("exceptions.zig");
const object_ops = @import("object_ops.zig");
const string_ops = @import("string_ops.zig");

const HostError = exceptions.HostError;
const InternalCall = core.host_function.InternalCall;
const vm_exception_ops = exception_ops;

// The Date constructor body runs through the record table keyed on this ref
// (matching the RegExp/String construct unification in Phase 6b-3d/e): the
// VM-context argument coercion stays here in `qjsDateConstructWithPrototype`
// and the coerced primitives + resolved instance prototype are threaded to the
// record, whose construct branch (`exec/date_ops.zig` `dateCall`) runs
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
/// record id so the dispatch lands on `exec/date_ops.zig` `dateCall` (which runs
/// the pure `methodCallArgs` body for it). `args` must already be coerced. This
/// replaces the former direct builtins-layer calls while preserving the record
/// dispatch shape.
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
            if (primitive.isBigInt()) return exception_ops.throwTypeErrorMessage(ctx, global, "cannot convert bigint to number");
            const number = try value_ops.toNumberValue(ctx.runtime, primitive);
            defer number.free(ctx.runtime);
            return constructDateRecord(ctx, prototype, &.{number});
        }

        if (args[0].isString()) return constructDateRecord(ctx, prototype, args);
        if (args[0].isBigInt()) return exception_ops.throwTypeErrorMessage(ctx, global, "cannot convert bigint to number");
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
    if (!this_value.isObject()) return exception_ops.throwTypeErrorMessage(ctx, global, "not an object");

    const hint_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const hint = qjsDateToPrimitiveHint(hint_value) orelse
        return exception_ops.throwTypeErrorMessage(ctx, global, "invalid hint");
    return switch (hint) {
        .string => try qjsDateOrdinaryToPrimitive(ctx, output, global, this_value, true, caller_function, caller_frame),
        .number => try qjsDateOrdinaryToPrimitive(ctx, output, global, this_value, false, caller_function, caller_frame),
    };
}

fn qjsDateToPrimitiveHint(value: core.JSValue) ?DateToPrimitiveHint {
    if (!value.isString()) return null;
    if (string_ops.stringValueUnitsEqualBytes(value, "string") or string_ops.stringValueUnitsEqualBytes(value, "default")) return .string;
    // qjs js_date_Symbol_toPrimitive (quickjs.c:55964) maps JS_ATOM_integer to
    // HINT_NUMBER alongside JS_ATOM_number (nonstandard qjs extension;
    // test262 does not exercise the 'integer' hint).
    if (string_ops.stringValueUnitsEqualBytes(value, "number") or string_ops.stringValueUnitsEqualBytes(value, "integer")) return .number;
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

const ms_per_second: i64 = 1000;
const ms_per_minute: i64 = 60 * ms_per_second;
const ms_per_hour: i64 = 60 * ms_per_minute;
pub const ms_per_day: i64 = 24 * ms_per_hour;

pub const StaticMethod = core.host_function.builtin_method_ids.date.StaticMethod;

// Relocated to engine core (`core/host_function.zig`, next to
// `builtin_method_ids.date.StaticMethod`) in Phase 6b-3e so the VM construct
// dispatchers can gate on the construct id without importing builtins;
// re-exported here so the install/dispatch side keeps the original name.
pub const ConstructorMethod = core.host_function.builtin_method_ids.date.ConstructorMethod;

// Relocated to engine core (`core/host_function.zig`,
// `builtin_method_ids.date.PrototypeMethod`) in Phase 6b-3 STEP 5 so the exec
// date glue can build the record `NativeBuiltinRef` for table dispatch without
// importing builtins; re-exported here so the dispatch/install side keeps the
// original name.
pub const PrototypeMethod = core.host_function.builtin_method_ids.date.PrototypeMethod;

/// Date-domain record ids that exist only on the builtins side (they continue
/// the `PrototypeMethod` id space above without touching engine core): the
/// UTC/local method split (QuickJS gives every name its own
/// JS_CFUNC_MAGIC_DEF entry with an `is_local` magic bit, quickjs.c
/// js_date_proto_funcs) and the qjs fmt=3 `toLocale*` shapes. Only date.zig
/// produces and decodes these ids; the exec glue never sees them.
pub const ExtendedPrototypeMethod = enum(u32) {
    get_utc_day = 138,
    set_utc_milliseconds = 139,
    set_utc_seconds = 140,
    set_utc_minutes = 141,
    set_utc_hours = 142,
    set_utc_date = 143,
    set_utc_month = 144,
    set_utc_full_year = 145,
    to_locale_string = 146,
    to_locale_date_string = 147,
    to_locale_time_string = 148,
};

/// Declaration + dispatch table for the `.date` native-builtin domain
/// (QuickJS js_date_funcs analogue). One shared record handler `dateCall`
/// switches on the per-record `magic` (== domain-local id); the constructor,
/// the statics, the `Symbol.toPrimitive` method, and the prototype methods all
/// route through it. `id` doubles as `magic`, so the record carries no extra
/// selector. Property installation still resolves names through the registry's
/// Date method tables (canonical name/length) and date.zig's id helpers; this
/// table is consumed by the slow record-dispatch path (`rt.internal_builtins`).
/// `prepared_call_ok` mirrors the prepared-call gate in `vm_call.zig`
/// (`nativeBuiltinSupportedWithoutFunctionObject`): only `Date.now` is callable
/// without a materialized function object today.
pub const internal_entries = dateEntries: {
    const Entry = core.host_function.InternalEntry;
    break :dateEntries [_]Entry{
        dateEntry("UTC", 7, @intFromEnum(StaticMethod.utc), false),
        dateEntry("parse", 1, @intFromEnum(StaticMethod.parse), false),
        dateEntry("now", 0, @intFromEnum(StaticMethod.now), true),
        dateConstructorEntry("Date", 7, @intFromEnum(ConstructorMethod.construct)),
        dateEntry("getTime", 0, @intFromEnum(PrototypeMethod.get_time), false),
        dateEntry("valueOf", 0, @intFromEnum(PrototypeMethod.value_of), false),
        dateEntry("getFullYear", 0, @intFromEnum(PrototypeMethod.get_full_year), false),
        dateEntry("getMonth", 0, @intFromEnum(PrototypeMethod.get_month), false),
        dateEntry("getDate", 0, @intFromEnum(PrototypeMethod.get_date), false),
        dateEntry("getHours", 0, @intFromEnum(PrototypeMethod.get_hours), false),
        dateEntry("getMinutes", 0, @intFromEnum(PrototypeMethod.get_minutes), false),
        dateEntry("getSeconds", 0, @intFromEnum(PrototypeMethod.get_seconds), false),
        dateEntry("getMilliseconds", 0, @intFromEnum(PrototypeMethod.get_milliseconds), false),
        dateEntry("toISOString", 0, @intFromEnum(PrototypeMethod.to_iso_string), false),
        dateEntry("toJSON", 1, @intFromEnum(PrototypeMethod.to_json), false),
        dateEntry("getUTCFullYear", 0, @intFromEnum(PrototypeMethod.get_utc_full_year), false),
        dateEntry("getUTCMonth", 0, @intFromEnum(PrototypeMethod.get_utc_month), false),
        dateEntry("getUTCDate", 0, @intFromEnum(PrototypeMethod.get_utc_date), false),
        dateEntry("getUTCHours", 0, @intFromEnum(PrototypeMethod.get_utc_hours), false),
        dateEntry("getUTCMinutes", 0, @intFromEnum(PrototypeMethod.get_utc_minutes), false),
        dateEntry("getUTCSeconds", 0, @intFromEnum(PrototypeMethod.get_utc_seconds), false),
        dateEntry("getUTCMilliseconds", 0, @intFromEnum(PrototypeMethod.get_utc_milliseconds), false),
        dateEntry("getDay", 0, @intFromEnum(PrototypeMethod.get_day), false),
        dateEntry("toString", 0, @intFromEnum(PrototypeMethod.to_string), false),
        dateEntry("toUTCString", 0, @intFromEnum(PrototypeMethod.to_utc_string), false),
        dateEntry("getYear", 0, @intFromEnum(PrototypeMethod.get_year), false),
        dateEntry("setYear", 1, @intFromEnum(PrototypeMethod.set_year), false),
        dateEntry("setTime", 1, @intFromEnum(PrototypeMethod.set_time), false),
        dateEntry("setMilliseconds", 1, @intFromEnum(PrototypeMethod.set_milliseconds), false),
        dateEntry("setSeconds", 2, @intFromEnum(PrototypeMethod.set_seconds), false),
        dateEntry("setMinutes", 3, @intFromEnum(PrototypeMethod.set_minutes), false),
        dateEntry("setHours", 4, @intFromEnum(PrototypeMethod.set_hours), false),
        dateEntry("setDate", 1, @intFromEnum(PrototypeMethod.set_date), false),
        dateEntry("setMonth", 2, @intFromEnum(PrototypeMethod.set_month), false),
        dateEntry("setFullYear", 3, @intFromEnum(PrototypeMethod.set_full_year), false),
        dateEntry("getTimezoneOffset", 0, @intFromEnum(PrototypeMethod.get_timezone_offset), false),
        dateEntry("toDateString", 0, @intFromEnum(PrototypeMethod.to_date_string), false),
        dateEntry("toTimeString", 0, @intFromEnum(PrototypeMethod.to_time_string), false),
        dateEntry("[Symbol.toPrimitive]", 1, @intFromEnum(PrototypeMethod.to_primitive), false),
        // Engine-internal captured-setter records (no JS property; the registry
        // installs only the named methods above). Reached solely from the
        // `func_obj == null` arm so `exec/date_ops.zig` can route the
        // capture-then-apply setter bodies through the table.
        dateEntry("", 0, @intFromEnum(PrototypeMethod.set_year_with_captured_ms), false),
        dateEntry("", 0, @intFromEnum(PrototypeMethod.set_parts_with_captured_ms), false),
        // Local/UTC method split + qjs fmt=3 locale shapes (see
        // `ExtendedPrototypeMethod`); handled entirely inside `dateCall`.
        dateEntry("getUTCDay", 0, @intFromEnum(ExtendedPrototypeMethod.get_utc_day), false),
        dateEntry("setUTCMilliseconds", 1, @intFromEnum(ExtendedPrototypeMethod.set_utc_milliseconds), false),
        dateEntry("setUTCSeconds", 2, @intFromEnum(ExtendedPrototypeMethod.set_utc_seconds), false),
        dateEntry("setUTCMinutes", 3, @intFromEnum(ExtendedPrototypeMethod.set_utc_minutes), false),
        dateEntry("setUTCHours", 4, @intFromEnum(ExtendedPrototypeMethod.set_utc_hours), false),
        dateEntry("setUTCDate", 1, @intFromEnum(ExtendedPrototypeMethod.set_utc_date), false),
        dateEntry("setUTCMonth", 2, @intFromEnum(ExtendedPrototypeMethod.set_utc_month), false),
        dateEntry("setUTCFullYear", 3, @intFromEnum(ExtendedPrototypeMethod.set_utc_full_year), false),
        dateEntry("toLocaleString", 0, @intFromEnum(ExtendedPrototypeMethod.to_locale_string), false),
        dateEntry("toLocaleDateString", 0, @intFromEnum(ExtendedPrototypeMethod.to_locale_date_string), false),
        dateEntry("toLocaleTimeString", 0, @intFromEnum(ExtendedPrototypeMethod.to_locale_time_string), false),
    };
};

fn dateEntry(comptime name: []const u8, comptime length: u8, comptime id: u32, comptime prepared: bool) core.host_function.InternalEntry {
    return .{ .name = name, .length = length, .id = id, .magic = @intCast(id), .prepared_call_ok = prepared, .call = &dateCall };
}

/// The Date constructor record: construct-capable so `new Date(...)` routes
/// through the construct dispatch path into `dateCall`'s construct branch.
fn dateConstructorEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{ .name = name, .length = length, .id = id, .magic = @intCast(id), .prepared_call_ok = false, .constructor = true, .call = &dateCall };
}

/// Shared record handler for the `.date` domain. Mirrors the retired
/// `call.zig` `callDateNativeFunctionRecord`: the constructor and statics run
/// the pure builtin helpers below, while the `Symbol.toPrimitive` and
/// prototype methods delegate to the exec VM ops (which stay in exec because
/// the date opcode handlers and the prepared-call fast path also call them).
fn dateCall(host_call: InternalCall) HostError!core.JSValue {
    const ctx = host_call.ctx;
    const output = host_call.output;
    const id: u32 = host_call.magic;
    const args = host_call.args;
    const caller_function = builtin_dispatch.callerBytecode(host_call);
    const caller_frame = builtin_dispatch.callerFrame(host_call);

    if (id == @intFromEnum(ConstructorMethod.construct)) {
        // `new Date(...)` arrives through the construct record path
        // (`exec/construct.zig`) with `flags.constructor` set and the resolved
        // instance prototype in `new_target`; `Date(...)` called as a function
        // returns the current time string (QuickJS js_date_constructor with
        // `new_target == undefined`).
        if (host_call.flags.constructor) return constructWithPrototype(ctx.runtime, args, host_call.new_target);
        return call(ctx.runtime, args);
    }

    // Engine-internal dispatch arm: the exec date VM-coercion glue
    // (`exec/date_ops.zig`, plus the `Date.now` fusion and the static
    // fall-throughs) has already coerced its arguments and routes the *pure body*
    // through the table here so VM coercion stays on the same record boundary. It is
    // gated on `func_obj == null and global == null`, the contract those call
    // sites use; the prepared-call fast path (`vm_call.zig`) also passes
    // `func_obj == null` but threads the realm `global` and *raw* args, so it
    // must instead fall through to the coercing dispatcher below. This
    // deliberately bypasses the prototype dispatcher
    // (`object_ops.qjsDatePrototypeMethod`) — routing back through it would
    // re-enter this record (the dispatcher's own body call is one of the
    // converted sites) and recurse, and the glue already performed the
    // dispatcher's coercion/capture work.
    if (host_call.func_obj == null and host_call.global == null and !host_call.flags.constructor) {
        return dateInternalBodyCall(ctx.runtime, id, host_call.this_value, args);
    }

    if (id == @intFromEnum(PrototypeMethod.to_primitive)) {
        const active_global = host_call.global orelse realmGlobalFor(ctx, host_call.func_obj) orelse return error.TypeError;
        return qjsDateToPrimitiveCall(ctx, output, active_global, host_call.this_value, args, caller_function, caller_frame);
    }
    if (id == @intFromEnum(StaticMethod.utc)) {
        const active_global = host_call.global orelse return error.TypeError;
        var coerced_args: [7]core.JSValue = undefined;
        var coerced_len: usize = 0;
        defer {
            for (coerced_args[0..coerced_len]) |value| value.free(ctx.runtime);
        }
        while (coerced_len < args.len and coerced_len < coerced_args.len) : (coerced_len += 1) {
            coerced_args[coerced_len] = try coercion_ops.toNumberForDateMethod(ctx, output, active_global, args[coerced_len], null, null);
        }
        return staticCall(ctx.runtime, id, coerced_args[0..coerced_len]) catch |err| switch (err) {
            error.TypeError => error.TypeError,
            else => err,
        };
    }
    if (id == @intFromEnum(StaticMethod.parse)) {
        // js_Date_parse (quickjs.c:55907) ToString-coerces its argument (never
        // a TypeError arity/type gate); the coercion runs in VM context so a
        // user `toString`/`Symbol.toPrimitive` executes with the caller frame.
        const active_global = host_call.global orelse realmGlobalFor(ctx, host_call.func_obj) orelse return error.TypeError;
        const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const string_value = try string_ops.toStringForAnnexB(ctx, output, active_global, input, caller_function, caller_frame);
        defer string_value.free(ctx.runtime);
        return core.JSValue.float64(try parseDateString(ctx.runtime, string_value));
    }
    if (decodeExtendedPrototypeMethodId(id)) |method_id| {
        const active_global = host_call.global orelse realmGlobalFor(ctx, host_call.func_obj) orelse return error.TypeError;
        return dateExtendedPrototypeCall(ctx, output, active_global, host_call.this_value, method_id, args);
    }
    if (decodePrototypeMethodId(id)) |method_id| {
        const active_global = host_call.global orelse return error.TypeError;
        return object_ops.qjsDatePrototypeMethod(ctx, output, active_global, host_call.this_value, method_id, args, caller_function, caller_frame) catch |err| switch (err) {
            error.TypeError => error.TypeError,
            else => err,
        };
    }
    return staticCall(ctx.runtime, id, args) catch |err| switch (err) {
        error.TypeError => error.TypeError,
        else => err,
    };
}

/// Run a date method *body* directly for an engine-internal table call that
/// holds no function object and has already coerced its arguments. Reached only
/// from `dateCall`'s `func_obj == null` arm. `id` is a `.date` record id:
/// `StaticMethod.{utc,parse,now}` run the static body on the pre-coerced args;
/// the captured-setter selectors unpack the captured `[[DateValue]]` (and, for
/// the parts variant, the decoded setter id) the exec glue threaded through
/// `args`; every other prototype id runs the plain `methodCallArgs` body on the
/// decoded id.
fn dateInternalBodyCall(rt: *core.JSRuntime, id: u32, this_value: core.JSValue, args: []const core.JSValue) HostError!core.JSValue {
    const result = blk: {
        if (id == @intFromEnum(PrototypeMethod.set_year_with_captured_ms)) {
            const captured_ms = args[0].asNumber() orelse std.math.nan(f64);
            const year_number = args[1].asNumber() orelse std.math.nan(f64);
            break :blk setYearNumber(rt, this_value, captured_ms, year_number);
        }
        if (id == @intFromEnum(PrototypeMethod.set_parts_with_captured_ms)) {
            const captured_ms = args[0].asNumber() orelse std.math.nan(f64);
            const setter_id: u32 = @intFromFloat(args[1].asNumber() orelse 0);
            break :blk methodCallArgsWithCapturedMs(rt, this_value, setter_id, captured_ms, args[2..]);
        }
        if (decodeExtendedPrototypeMethodId(id)) |method_id| {
            break :blk methodCallArgs(rt, this_value, method_id, args);
        }
        if (decodePrototypeMethodId(id)) |method_id| {
            break :blk methodCallArgs(rt, this_value, method_id, args);
        }
        // `StaticMethod.{utc,parse,now}`: the enum values (1/2/3) are the
        // `staticCall` method selectors; the glue pre-coerced any args.
        break :blk staticCall(rt, id, args);
    };
    return result catch |err| return @as(HostError, @errorCast(err));
}

/// Coercing arm for the extended (builtins-local) prototype record ids.
/// Mirrors QuickJS: `set_date_field` (quickjs.c:55253) checks `this` and reads
/// the time value *before* coercing arguments, then coerces exactly
/// `min(argc, end_field - first_field)` arguments; `get_date_field` /
/// `get_date_string` bodies take no arguments.
fn dateExtendedPrototypeCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
) HostError!core.JSValue {
    const rt = ctx.runtime;
    if (setterSpan(method_id)) |span| {
        const object = expectDateObject(this_value) catch
            return vm_exception_ops.throwTypeErrorMessage(ctx, global, "not a Date object");
        const captured_ms = dateValue(object) catch
            return vm_exception_ops.throwTypeErrorMessage(ctx, global, "not a Date object");
        var coerced_args: [4]core.JSValue = undefined;
        var coerced_len: usize = 0;
        defer {
            for (coerced_args[0..coerced_len]) |value| value.free(rt);
        }
        const coerce_count = @min(args.len, span.end - span.first);
        while (coerced_len < coerce_count) : (coerced_len += 1) {
            coerced_args[coerced_len] = try coercion_ops.toNumberForDateMethod(ctx, output, global, args[coerced_len], null, null);
        }
        return setDateFieldBody(rt, object, captured_ms, coerced_args[0..coerced_len], args.len, span);
    }
    return methodCallArgs(rt, this_value, method_id, args) catch |err| switch (err) {
        error.TypeError => return vm_exception_ops.throwTypeErrorMessage(ctx, global, "not a Date object"),
        else => err,
    };
}

fn realmGlobalFor(ctx: *core.JSContext, func_obj: ?*core.Object) ?*core.Object {
    if (func_obj) |obj| {
        if (object_ops.objectRealmGlobal(obj)) |realm_global| return realm_global;
    }
    return ctx.global;
}

// Pure name->id mapping relocated to engine core (`core/host_function.zig`,
// next to `builtin_method_ids.date`) in Phase 6b-3c; re-exported here so the
// dispatch/install side keeps the original name.
pub const staticMethodId = core.host_function.builtin_method_id_lookup.date.staticMethodId;

pub fn prototypeMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "getTime")) return @intFromEnum(PrototypeMethod.get_time);
    if (std.mem.eql(u8, name, "valueOf")) return @intFromEnum(PrototypeMethod.value_of);
    if (std.mem.eql(u8, name, "getFullYear")) return @intFromEnum(PrototypeMethod.get_full_year);
    if (std.mem.eql(u8, name, "getTimezoneOffset")) return @intFromEnum(PrototypeMethod.get_timezone_offset);
    if (std.mem.eql(u8, name, "getMonth")) return @intFromEnum(PrototypeMethod.get_month);
    if (std.mem.eql(u8, name, "getDate")) return @intFromEnum(PrototypeMethod.get_date);
    if (std.mem.eql(u8, name, "getHours")) return @intFromEnum(PrototypeMethod.get_hours);
    if (std.mem.eql(u8, name, "getMinutes")) return @intFromEnum(PrototypeMethod.get_minutes);
    if (std.mem.eql(u8, name, "getSeconds")) return @intFromEnum(PrototypeMethod.get_seconds);
    if (std.mem.eql(u8, name, "getMilliseconds")) return @intFromEnum(PrototypeMethod.get_milliseconds);
    if (std.mem.eql(u8, name, "toISOString")) return @intFromEnum(PrototypeMethod.to_iso_string);
    if (std.mem.eql(u8, name, "toJSON")) return @intFromEnum(PrototypeMethod.to_json);
    if (std.mem.eql(u8, name, "getUTCFullYear")) return @intFromEnum(PrototypeMethod.get_utc_full_year);
    if (std.mem.eql(u8, name, "getUTCMonth")) return @intFromEnum(PrototypeMethod.get_utc_month);
    if (std.mem.eql(u8, name, "getUTCDate")) return @intFromEnum(PrototypeMethod.get_utc_date);
    if (std.mem.eql(u8, name, "getUTCHours")) return @intFromEnum(PrototypeMethod.get_utc_hours);
    if (std.mem.eql(u8, name, "getUTCMinutes")) return @intFromEnum(PrototypeMethod.get_utc_minutes);
    if (std.mem.eql(u8, name, "getUTCSeconds")) return @intFromEnum(PrototypeMethod.get_utc_seconds);
    if (std.mem.eql(u8, name, "getUTCMilliseconds")) return @intFromEnum(PrototypeMethod.get_utc_milliseconds);
    if (std.mem.eql(u8, name, "getUTCDay")) return @intFromEnum(ExtendedPrototypeMethod.get_utc_day);
    if (std.mem.eql(u8, name, "getDay")) return @intFromEnum(PrototypeMethod.get_day);
    if (std.mem.eql(u8, name, "toString")) return @intFromEnum(PrototypeMethod.to_string);
    if (std.mem.eql(u8, name, "toLocaleString")) return @intFromEnum(ExtendedPrototypeMethod.to_locale_string);
    if (std.mem.eql(u8, name, "toUTCString") or std.mem.eql(u8, name, "toGMTString")) return @intFromEnum(PrototypeMethod.to_utc_string);
    if (std.mem.eql(u8, name, "toDateString")) return @intFromEnum(PrototypeMethod.to_date_string);
    if (std.mem.eql(u8, name, "toLocaleDateString")) return @intFromEnum(ExtendedPrototypeMethod.to_locale_date_string);
    if (std.mem.eql(u8, name, "toTimeString")) return @intFromEnum(PrototypeMethod.to_time_string);
    if (std.mem.eql(u8, name, "toLocaleTimeString")) return @intFromEnum(ExtendedPrototypeMethod.to_locale_time_string);
    if (std.mem.eql(u8, name, "getYear")) return @intFromEnum(PrototypeMethod.get_year);
    if (std.mem.eql(u8, name, "setYear")) return @intFromEnum(PrototypeMethod.set_year);
    if (std.mem.eql(u8, name, "setTime")) return @intFromEnum(PrototypeMethod.set_time);
    if (std.mem.eql(u8, name, "setMilliseconds")) return @intFromEnum(PrototypeMethod.set_milliseconds);
    if (std.mem.eql(u8, name, "setUTCMilliseconds")) return @intFromEnum(ExtendedPrototypeMethod.set_utc_milliseconds);
    if (std.mem.eql(u8, name, "setSeconds")) return @intFromEnum(PrototypeMethod.set_seconds);
    if (std.mem.eql(u8, name, "setUTCSeconds")) return @intFromEnum(ExtendedPrototypeMethod.set_utc_seconds);
    if (std.mem.eql(u8, name, "setMinutes")) return @intFromEnum(PrototypeMethod.set_minutes);
    if (std.mem.eql(u8, name, "setUTCMinutes")) return @intFromEnum(ExtendedPrototypeMethod.set_utc_minutes);
    if (std.mem.eql(u8, name, "setHours")) return @intFromEnum(PrototypeMethod.set_hours);
    if (std.mem.eql(u8, name, "setUTCHours")) return @intFromEnum(ExtendedPrototypeMethod.set_utc_hours);
    if (std.mem.eql(u8, name, "setDate")) return @intFromEnum(PrototypeMethod.set_date);
    if (std.mem.eql(u8, name, "setUTCDate")) return @intFromEnum(ExtendedPrototypeMethod.set_utc_date);
    if (std.mem.eql(u8, name, "setMonth")) return @intFromEnum(PrototypeMethod.set_month);
    if (std.mem.eql(u8, name, "setUTCMonth")) return @intFromEnum(ExtendedPrototypeMethod.set_utc_month);
    if (std.mem.eql(u8, name, "setFullYear")) return @intFromEnum(PrototypeMethod.set_full_year);
    if (std.mem.eql(u8, name, "setUTCFullYear")) return @intFromEnum(ExtendedPrototypeMethod.set_utc_full_year);
    return null;
}

// Pure id<->id mappings relocated to engine core (`core/host_function.zig`,
// `builtin_method_id_lookup.date`) in Phase 6b-3 STEP 5; re-exported here so the
// dispatch side keeps the original names.
pub const decodePrototypeMethodId = core.host_function.builtin_method_id_lookup.date.decodePrototypeMethodId;
pub const encodePrototypeMethodId = core.host_function.builtin_method_id_lookup.date.encodePrototypeMethodId;

/// Extended record id -> legacy body selector (continues the 1..34 space the
/// core decode covers): 35 getUTCDay, 36..42 setUTC*, 43..45 toLocale*.
fn decodeExtendedPrototypeMethodId(id: u32) ?u32 {
    return switch (id) {
        @intFromEnum(ExtendedPrototypeMethod.get_utc_day) => 35,
        @intFromEnum(ExtendedPrototypeMethod.set_utc_milliseconds) => 36,
        @intFromEnum(ExtendedPrototypeMethod.set_utc_seconds) => 37,
        @intFromEnum(ExtendedPrototypeMethod.set_utc_minutes) => 38,
        @intFromEnum(ExtendedPrototypeMethod.set_utc_hours) => 39,
        @intFromEnum(ExtendedPrototypeMethod.set_utc_date) => 40,
        @intFromEnum(ExtendedPrototypeMethod.set_utc_month) => 41,
        @intFromEnum(ExtendedPrototypeMethod.set_utc_full_year) => 42,
        @intFromEnum(ExtendedPrototypeMethod.to_locale_string) => 43,
        @intFromEnum(ExtendedPrototypeMethod.to_locale_date_string) => 44,
        @intFromEnum(ExtendedPrototypeMethod.to_locale_time_string) => 45,
        else => null,
    };
}

/// QuickJS source map: Date as a function. `js_date_constructor` with
/// `new_target == undefined` returns `get_date_string(now, 0x13)`.
pub fn call(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue {
    _ = args;
    return getDateStringValue(rt, currentTimeMs(), 0x13);
}

/// QuickJS source map: Date constructor. This preserves the current smoke/test
/// compatible Date object payload while moving ownership out of the VM.
pub fn construct(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue {
    return constructWithPrototype(rt, args, null);
}

pub fn constructWithPrototype(rt: *core.JSRuntime, args: []const core.JSValue, prototype: ?*core.Object) !core.JSValue {
    const object = try core.Object.create(rt, core.class.ids.date, prototype);
    errdefer core.Object.destroyFromHeader(rt, &object.header);

    if (args.len >= 2) {
        const next_ms = try constructDateFromParts(args);
        try defineDateValue(rt, object, next_ms);
    } else if (args.len == 1) {
        const ms = if (args[0].isString())
            try parseDateString(rt, args[0])
        else if (dateObjectFromValue(args[0])) |date_object|
            try dateValue(date_object)
        else
            timeClip(toNumber(args[0]) orelse return error.TypeError);
        try defineDateValue(rt, object, ms);
    } else {
        try defineDateValue(rt, object, currentTimeMs());
    }

    return object.value();
}

fn defineDateValue(rt: *core.JSRuntime, object: *core.Object, ms: f64) !void {
    try setDateValue(rt, object, ms);
}

/// QuickJS source map: Date.UTC / Date.parse / Date.now.
pub fn staticCall(rt: *core.JSRuntime, method: u32, args: []const core.JSValue) !core.JSValue {
    return switch (method) {
        1 => utc(args),
        2 => try parse(rt, args),
        3 => core.JSValue.float64(currentTimeMs()),
        else => error.TypeError,
    };
}

/// QuickJS source map: selected Date.prototype methods used by current smoke
/// and targeted regression coverage.
pub fn methodCall(rt: *core.JSRuntime, object_value: core.JSValue, method: u32) !core.JSValue {
    return methodCallArgs(rt, object_value, method, &.{});
}

pub fn methodCallArgs(rt: *core.JSRuntime, object_value: core.JSValue, method: u32, args: []const core.JSValue) !core.JSValue {
    const object = try expectDateObject(object_value);
    const ms = try dateValue(object);
    if (setterSpan(method)) |span| {
        // Raw-args setter path (engine-internal callers): coerce here, then run
        // the shared `set_date_field` body.
        return setDateFieldBody(rt, object, ms, args, args.len, span);
    }
    return switch (method) {
        1, 2 => numberResult(ms),
        24 => try setTime(rt, object, args),
        // get_date_field (quickjs.c:55225): local getters n=0..6, getDay n=7.
        3...9 => getDateFieldValue(ms, @intCast(method - 3), true, false),
        19 => getDateFieldValue(ms, 7, true, false),
        // getUTC* n=0..6, getUTCDay n=7.
        12...18 => getDateFieldValue(ms, @intCast(method - 12), false, false),
        35 => getDateFieldValue(ms, 7, false, false),
        // getYear: magic 0x101 (local, fields[0] - 1900).
        22 => getDateFieldValue(ms, 0, true, true),
        // get_date_string magics (quickjs.c js_date_proto_funcs).
        10 => try getDateStringValue(rt, ms, 0x23),
        11 => if (std.math.isNan(ms)) core.JSValue.nullValue() else try getDateStringValue(rt, ms, 0x23),
        20 => try getDateStringValue(rt, ms, 0x13),
        21 => try getDateStringValue(rt, ms, 0x03),
        33 => try getDateStringValue(rt, ms, 0x11),
        34 => try getDateStringValue(rt, ms, 0x12),
        43 => try getDateStringValue(rt, ms, 0x33),
        44 => try getDateStringValue(rt, ms, 0x31),
        45 => try getDateStringValue(rt, ms, 0x32),
        23 => try setYear(rt, object, ms, args),
        // js_date_getTimezoneOffset (quickjs.c:55996).
        32 => if (std.math.isNan(ms))
            core.JSValue.float64(std.math.nan(f64))
        else
            numberResult(@floatFromInt(getTimezoneOffsetForTime(@intFromFloat(@trunc(ms))))),
        else => error.TypeError,
    };
}

pub fn methodCallArgsWithCapturedMs(rt: *core.JSRuntime, object_value: core.JSValue, method: u32, captured_ms: f64, args: []const core.JSValue) !core.JSValue {
    const object = try expectDateObject(object_value);
    const span = setterSpan(method) orelse return error.TypeError;
    return setDateFieldBody(rt, object, captured_ms, args, args.len, span);
}

/// set_date_field magic decode (quickjs.c js_date_proto_funcs): selector ->
/// (first_field, end_field, is_local). 25..31 are the local setters, 36..42
/// the setUTC* twins.
const SetterSpan = struct { first: usize, end: usize, is_local: bool };

fn setterSpan(method: u32) ?SetterSpan {
    return switch (method) {
        25 => .{ .first = 6, .end = 7, .is_local = true }, // setMilliseconds 0x671
        26 => .{ .first = 5, .end = 7, .is_local = true }, // setSeconds 0x571
        27 => .{ .first = 4, .end = 7, .is_local = true }, // setMinutes 0x471
        28 => .{ .first = 3, .end = 7, .is_local = true }, // setHours 0x371
        29 => .{ .first = 2, .end = 3, .is_local = true }, // setDate 0x211
        30 => .{ .first = 1, .end = 3, .is_local = true }, // setMonth 0x121
        31 => .{ .first = 0, .end = 3, .is_local = true }, // setFullYear 0x011
        36 => .{ .first = 6, .end = 7, .is_local = false }, // setUTCMilliseconds 0x670
        37 => .{ .first = 5, .end = 7, .is_local = false }, // setUTCSeconds 0x570
        38 => .{ .first = 4, .end = 7, .is_local = false }, // setUTCMinutes 0x470
        39 => .{ .first = 3, .end = 7, .is_local = false }, // setUTCHours 0x370
        40 => .{ .first = 2, .end = 3, .is_local = false }, // setUTCDate 0x210
        41 => .{ .first = 1, .end = 3, .is_local = false }, // setUTCMonth 0x120
        42 => .{ .first = 0, .end = 3, .is_local = false }, // setUTCFullYear 0x010
        else => null,
    };
}

/// Mirrors qjs set_date_field (quickjs.c:55253) given the captured time value
/// and (pre-coerced or raw-primitive) args. `argc` is the caller's argument
/// count: `argc == 0` sets the date to NaN even without field writes.
fn setDateFieldBody(rt: *core.JSRuntime, object: *core.Object, captured_ms: f64, args: []const core.JSValue, argc: usize, span: SetterSpan) !core.JSValue {
    var fields: [9]f64 = undefined;
    var res = getDateFields(captured_ms, &fields, span.is_local, span.first == 0);
    const res1 = res;

    // Argument coercion is observable and must be done unconditionally.
    const n = @min(args.len, span.end - span.first);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const a = toNumber(args[i]) orelse return error.TypeError;
        if (!std.math.isFinite(a)) res = false;
        fields[span.first + i] = @trunc(a);
    }

    if (!res1) return core.JSValue.float64(std.math.nan(f64)); // thisTimeValue is NaN

    var d: f64 = std.math.nan(f64);
    if (res and argc > 0) d = setDateFields(fields[0..7], span.is_local);

    try setDateValue(rt, object, d);
    return numberResult(d);
}

fn setYear(rt: *core.JSRuntime, object: *core.Object, ms: f64, args: []const core.JSValue) !core.JSValue {
    const year_number = if (args.len >= 1) (toNumber(args[0]) orelse return error.TypeError) else std.math.nan(f64);
    return setYearNumberOnObject(rt, object, ms, year_number);
}

pub fn setYearNumber(rt: *core.JSRuntime, object_value: core.JSValue, captured_ms: f64, year_number: f64) !core.JSValue {
    const object = try expectDateObject(object_value);
    return setYearNumberOnObject(rt, object, captured_ms, year_number);
}

/// Mirrors qjs js_date_setYear (quickjs.c:56030): map finite years 0..99 to
/// 1900..1999, then run set_date_field with magic 0x011 (first=0, end=1,
/// local).
fn setYearNumberOnObject(rt: *core.JSRuntime, object: *core.Object, ms: f64, year_number: f64) !core.JSValue {
    var y = year_number;
    if (std.math.isFinite(y)) {
        y = @trunc(y);
        if (y >= 0 and y < 100) y += 1900;
    }
    const year_args = [1]core.JSValue{core.JSValue.float64(y)};
    return setDateFieldBody(rt, object, ms, &year_args, 1, .{ .first = 0, .end = 1, .is_local = true });
}

fn setTime(rt: *core.JSRuntime, object: *core.Object, args: []const core.JSValue) !core.JSValue {
    const time_number = if (args.len >= 1) (toNumber(args[0]) orelse return error.TypeError) else std.math.nan(f64);
    const next_ms = timeClip(time_number);
    try setDateValue(rt, object, next_ms);
    return numberResult(next_ms);
}

/// Mirrors qjs get_date_field (quickjs.c:55225): n selects the field,
/// `is_get_year` applies the getYear 0x100 bias.
fn getDateFieldValue(ms: f64, n: usize, is_local: bool, is_get_year: bool) core.JSValue {
    var fields: [9]f64 = undefined;
    if (!getDateFields(ms, &fields, is_local, false)) return core.JSValue.float64(std.math.nan(f64));
    var field_value = fields[n];
    if (is_get_year) field_value -= 1900;
    return numberResult(field_value);
}

fn utc(args: []const core.JSValue) !core.JSValue {
    // js_Date_UTC (quickjs.c:55480).
    if (args.len == 0) return core.JSValue.float64(std.math.nan(f64));
    var fields = [7]f64{ 0, 0, 1, 0, 0, 0, 0 };
    const n = @min(args.len, 7);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        fields[i] = toNumber(args[i]) orelse return error.TypeError;
    }
    return numberResult(setDateFieldsChecked(&fields, false));
}

fn constructDateFromParts(args: []const core.JSValue) !f64 {
    // js_date_constructor n >= 2 branch (quickjs.c:55442): coerce up to 7
    // fields, then set_date_fields_checked(fields, 1) — LOCAL time.
    var fields = [7]f64{ 0, 0, 1, 0, 0, 0, 0 };
    const n = @min(args.len, 7);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        fields[i] = toNumber(args[i]) orelse return error.TypeError;
    }
    return setDateFieldsChecked(&fields, true);
}

fn parse(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue {
    // js_Date_parse (quickjs.c:55907) ToString-coerces its argument. This pure
    // body only sees pre-coerced args (the record arm in `dateCall` runs the
    // VM ToString for objects); primitives are converted without VM re-entry.
    const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (input.isString()) return core.JSValue.float64(try parseDateString(rt, input));
    if (input.isObject()) return core.JSValue.float64(std.math.nan(f64));
    const string_value = try value_ops.toStringValue(rt, input);
    defer string_value.free(rt);
    return core.JSValue.float64(try parseDateString(rt, string_value));
}

// --- Host timezone offset (mirrors quickjs.c getTimezoneOffset:47454) -------

/// C `struct tm` (glibc/musl layout; POSIX.1-2024 mandates `tm_gmtoff`).
const CTm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};

extern "c" fn localtime_r(timep: *const std.c.time_t, result: *CTm) ?*CTm;

/// OS dependent. `time` is in ms from 1970. Return the difference between UTC
/// time and local time at `time`, in minutes (quickjs.c getTimezoneOffset).
fn getTimezoneOffsetForTime(time_ms: i64) i32 {
    var time = @divTrunc(time_ms, 1000); // convert to seconds (C truncation)
    if (@sizeOf(std.c.time_t) == 4) {
        // On 32-bit systems clamp to the range of `time_t` (qjs does the same).
        if (time < std.math.minInt(i32)) {
            time = std.math.minInt(i32);
        } else if (time > std.math.maxInt(i32)) {
            time = std.math.maxInt(i32);
        }
    }
    var ti: std.c.time_t = @intCast(time);
    var tm: CTm = std.mem.zeroes(CTm);
    _ = localtime_r(&ti, &tm);
    return @intCast(@divTrunc(-tm.tm_gmtoff, 60));
}

// --- Calendar decomposition (mirrors quickjs.c date field helpers) ----------

const month_days = [12]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
const month_names = "JanFebMarAprMayJunJulAugSepOctNovDec";
const day_names = "SunMonTueWedThuFriSat";

/// floor_div (quickjs.c:55020): integer division rounding toward -Infinity.
fn floorDiv(a: i64, b: i64) i64 {
    return @divFloor(a, b);
}

/// days_from_year (quickjs.c:55053).
fn daysFromYear(y: i64) i64 {
    return 365 * (y - 1970) + floorDiv(y - 1969, 4) -
        floorDiv(y - 1901, 100) + floorDiv(y - 1601, 400);
}

/// days_in_year (quickjs.c:55059).
fn daysInYear(y: i64) i64 {
    return 365 + @as(i64, @intFromBool(@rem(y, 4) == 0)) -
        @as(i64, @intFromBool(@rem(y, 100) == 0)) +
        @as(i64, @intFromBool(@rem(y, 400) == 0));
}

/// year_from_days (quickjs.c:55064): return the year, update days.
fn yearFromDays(days: *i64) i64 {
    const d = days.*;
    var y = floorDiv(d * 10000, 3652425) + 1970;
    // The initial approximation is very good, so only a few iterations are
    // necessary.
    while (true) {
        var d1 = d - daysFromYear(y);
        if (d1 < 0) {
            y -= 1;
            d1 += daysInYear(y);
        } else {
            const nd = daysInYear(y);
            if (d1 < nd) {
                days.* = d1;
                break;
            }
            d1 -= nd;
            y += 1;
        }
    }
    return y;
}

/// Mirrors qjs get_date_fields (quickjs.c:55090). Returns false for a NaN time
/// value when `force` is unset; with `force` the fields decompose from 0.
/// fields: [y, mon(0-based), d, h, m, s, ms, wd, tz].
fn getDateFields(dval: f64, fields: *[9]f64, is_local: bool, force: bool) bool {
    var tz: i64 = 0;
    var d: i64 = undefined;

    if (std.math.isNan(dval)) {
        if (!force) return false; // NaN
        d = 0; // initialize all fields to 0
    } else {
        d = @intFromFloat(dval); // assuming -8.64e15 <= dval <= 8.64e15
        if (is_local) {
            tz = -@as(i64, getTimezoneOffsetForTime(d));
            d += tz * 60000;
        }
    }

    // result is >= 0, we can use plain remainders below
    var h = @mod(d, 86400000);
    var days = @divExact(d - h, 86400000);
    const msec = @rem(h, 1000);
    h = @divExact(h - msec, 1000);
    const s = @rem(h, 60);
    h = @divExact(h - s, 60);
    const m = @rem(h, 60);
    h = @divExact(h - m, 60);
    const wd = @mod(days + 4, 7); // week day
    const y = yearFromDays(&days);

    var i: usize = 0;
    while (i < 11) : (i += 1) {
        var md = month_days[i];
        if (i == 1) md += daysInYear(y) - 365;
        if (days < md) break;
        days -= md;
    }
    fields[0] = @floatFromInt(y);
    fields[1] = @floatFromInt(i);
    fields[2] = @floatFromInt(days + 1);
    fields[3] = @floatFromInt(h);
    fields[4] = @floatFromInt(m);
    fields[5] = @floatFromInt(s);
    fields[6] = @floatFromInt(msec);
    fields[7] = @floatFromInt(wd);
    fields[8] = @floatFromInt(tz);
    return true;
}

/// time_clip (quickjs.c:55214).
fn timeClip(value: f64) f64 {
    if (value >= -8.64e15 and value <= 8.64e15) return @trunc(value) + 0.0; // convert -0 to +0
    return std.math.nan(f64);
}

/// Mirrors qjs set_date_fields (quickjs.c:55153): the spec mandates `double`
/// evaluation order (volatile intermediary as in qjs, see the
/// fp-evaluation-order test262 note there).
fn setDateFields(fields: *const [7]f64, is_local: bool) f64 {
    // emulate 21.4.1.15 MakeDay ( year, month, date )
    const y = fields[0];
    const m = fields[1];
    const dt = fields[2];
    const ym = y + @floor(m / 12);
    var mn = @rem(m, 12);
    if (mn < 0) mn += 12;
    if (ym < -271821 or ym > 275760) return std.math.nan(f64);

    const yi: i64 = @intFromFloat(ym);
    const mi: i64 = @intFromFloat(mn);
    var days = daysFromYear(yi);
    var i: i64 = 0;
    while (i < mi) : (i += 1) {
        days += month_days[@intCast(i)];
        if (i == 1) days += daysInYear(yi) - 365;
    }
    const day = @as(f64, @floatFromInt(days)) + dt - 1;

    // emulate 21.4.1.14 MakeTime ( hour, min, sec, ms ) — volatile temp keeps
    // the evaluation order / prevents FMA, as in qjs.
    var temp_storage: f64 = undefined;
    const temp: *volatile f64 = &temp_storage;
    var time: f64 = fields[3] * 3600000;
    temp.* = fields[4] * 60000;
    time += temp.*;
    temp.* = fields[5] * 1000;
    time += temp.*;
    time += fields[6];

    // emulate 21.4.1.16 MakeDate ( day, time )
    temp.* = day * 86400000;
    var tv = temp.* + time; // prevent generation of FMA
    if (!std.math.isFinite(tv)) return std.math.nan(f64);

    // adjust for local time and clip
    if (is_local) {
        const ti: i64 = if (tv < -0x1p63)
            std.math.minInt(i64)
        else if (tv >= 0x1p63)
            std.math.maxInt(i64)
        else
            @intFromFloat(tv);
        tv += @as(f64, @floatFromInt(@as(i64, getTimezoneOffsetForTime(ti)) * 60000));
    }
    return timeClip(tv);
}

/// Mirrors qjs set_date_fields_checked (quickjs.c:55206).
fn setDateFieldsChecked(fields: *[7]f64, is_local: bool) f64 {
    var i: usize = 0;
    while (i < 7) : (i += 1) {
        const a = fields[i];
        if (!std.math.isFinite(a)) return std.math.nan(f64);
        fields[i] = @trunc(a);
        if (i == 0 and fields[0] >= 0 and fields[0] < 100) fields[0] += 1900;
    }
    return setDateFields(fields, is_local);
}

// --- Date -> string (mirrors quickjs.c get_date_string:55290) ---------------

fn dayName(wd: usize) []const u8 {
    return day_names[wd * 3 ..][0..3];
}

fn monthName(mon: usize) []const u8 {
    return month_names[mon * 3 ..][0..3];
}

/// snprintf "%0*d" with width 4 + (y < 0): sign counts toward the width.
/// (unsigned operand: Zig 0.16 std.fmt zero-fill prints an explicit '+' for
/// signed integers.)
fn writeYearPadded4(w: *std.Io.Writer, y: i64) !void {
    if (y < 0) {
        try w.print("-{d:0>4}", .{@as(u64, @intCast(-y))});
    } else {
        try w.print("{d:0>4}", .{@as(u64, @intCast(y))});
    }
}

/// Mirrors qjs get_date_string (quickjs.c:55290).
/// fmt: 0 toUTCString / 1 toString / 2 toISOString / 3 toLocaleString.
/// part: 1 = date, 2 = time, 3 = both. NaN: fmt 2 raises RangeError, others
/// produce "Invalid Date".
fn getDateStringValue(rt: *core.JSRuntime, ms: f64, magic: u32) !core.JSValue {
    const fmt = (magic >> 4) & 0x0F;
    const part = magic & 0x0F;

    var fields: [9]f64 = undefined;
    if (!getDateFields(ms, &fields, (fmt & 1) == 1, false)) {
        if (fmt == 2) return error.RangeError; // "Date value is NaN"
        const str = try core.string.String.createUtf8(rt, "Invalid Date");
        return str.value();
    }

    // Non-negative print operands are unsigned (Zig 0.16 std.fmt zero-fill
    // prints an explicit '+' for signed integers).
    const y: i64 = @intFromFloat(fields[0]);
    const mon: usize = @intFromFloat(fields[1]);
    const d: u32 = @intFromFloat(fields[2]);
    const h: u32 = @intFromFloat(fields[3]);
    const m: u32 = @intFromFloat(fields[4]);
    const s: u32 = @intFromFloat(fields[5]);
    const msec: u32 = @intFromFloat(fields[6]);
    const wd: usize = @intFromFloat(fields[7]);
    var tz: i64 = @intFromFloat(fields[8]);

    var buffer: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);

    if (part & 1 != 0) { // date part
        switch (fmt) {
            0 => {
                try w.print("{s}, {d:0>2} {s} ", .{ dayName(wd), d, monthName(mon) });
                try writeYearPadded4(&w, y);
                try w.writeByte(' ');
            },
            1 => {
                try w.print("{s} {s} {d:0>2} ", .{ dayName(wd), monthName(mon), d });
                try writeYearPadded4(&w, y);
                if (part == 3) try w.writeByte(' ');
            },
            2 => {
                if (y >= 0 and y <= 9999) {
                    try w.print("{d:0>4}", .{@as(u64, @intCast(y))});
                } else if (y < 0) {
                    try w.print("-{d:0>6}", .{@as(u64, @intCast(-y))});
                } else {
                    try w.print("+{d:0>6}", .{@as(u64, @intCast(y))});
                }
                try w.print("-{d:0>2}-{d:0>2}T", .{ mon + 1, d });
            },
            3 => {
                try w.print("{d:0>2}/{d:0>2}/", .{ mon + 1, d });
                try writeYearPadded4(&w, y);
                if (part == 3) try w.writeAll(", ");
            },
            else => {},
        }
    }
    if (part & 2 != 0) { // time part
        switch (fmt) {
            0 => try w.print("{d:0>2}:{d:0>2}:{d:0>2} GMT", .{ h, m, s }),
            1 => {
                try w.print("{d:0>2}:{d:0>2}:{d:0>2} GMT", .{ h, m, s });
                if (tz < 0) {
                    try w.writeByte('-');
                    tz = -tz;
                } else {
                    try w.writeByte('+');
                }
                // tz is >= 0, can use remainders
                const tzu: u32 = @intCast(tz);
                try w.print("{d:0>2}{d:0>2}", .{ tzu / 60, tzu % 60 });
            },
            2 => try w.print("{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{ h, m, s, msec }),
            3 => try w.print("{d:0>2}:{d:0>2}:{d:0>2} {c}M", .{ @rem(h + 11, 12) + 1, m, s, @as(u8, if (h < 12) 'A' else 'P') }),
            else => {},
        }
    }
    const str = try core.string.String.createUtf8(rt, w.buffered());
    return str.value();
}

// --- Date string parsing (mirrors quickjs.c js_Date_parse:55907) ------------

/// js_Date_parse string -> byte-array conversion (quickjs.c:55926): 127-byte
/// truncation, U+2212 -> '-', any other unit > 255 -> 'x'.
fn parseDateString(rt: *core.JSRuntime, value: core.JSValue) !f64 {
    const string_value = value.asStringBody() orelse return std.math.nan(f64);
    try string_value.ensureFlat(rt);
    var buf: [128]u8 = undefined;
    var len: usize = 0;
    switch (string_value.resolveData()) {
        .latin1 => |bytes| {
            len = @min(bytes.len, buf.len - 1);
            @memcpy(buf[0..len], bytes[0..len]);
        },
        .utf16 => |units| {
            len = @min(units.len, buf.len - 1);
            for (units[0..len], 0..) |unit, i| {
                buf[i] = if (unit > 255)
                    (if (unit == 0x2212) '-' else 'x')
                else
                    @intCast(unit);
            }
        },
    }
    buf[len] = 0;
    return dateParseBytes(buf[0..len :0]);
}

fn dateParseBytes(sp: [:0]const u8) f64 {
    var fields: [9]i32 = undefined;
    var is_local: bool = undefined;
    if (jsDateParseIsostring(sp, &fields, &is_local) or
        jsDateParseOtherstring(sp, &fields, &is_local))
    {
        const field_max = [6]i32{ 0, 11, 31, 24, 59, 59 };
        var valid = true;
        // check field maximum values
        var i: usize = 1;
        while (i < 6) : (i += 1) {
            if (fields[i] > field_max[i]) valid = false;
        }
        // special case 24:00:00.000
        if (fields[3] == 24 and (fields[4] | fields[5] | fields[6]) != 0) valid = false;
        if (valid) {
            var fields1: [7]f64 = undefined;
            for (0..7) |j| fields1[j] = @floatFromInt(fields[j]);
            return setDateFields(&fields1, is_local) - @as(f64, @floatFromInt(fields[8])) * 60000;
        }
    }
    return std.math.nan(f64);
}

/// string_skip_char (quickjs.c:55495).
fn stringSkipChar(sp: [:0]const u8, pp: *usize, c: u8) bool {
    if (sp[pp.*] == c) {
        pp.* += 1;
        return true;
    }
    return false;
}

/// string_skip_spaces (quickjs.c:55505): skip spaces, return next char.
fn stringSkipSpaces(sp: [:0]const u8, pp: *usize) u8 {
    var c = sp[pp.*];
    while (c == ' ') {
        pp.* += 1;
        c = sp[pp.*];
    }
    return c;
}

/// string_skip_separators (quickjs.c:55513): skip dashes, slashes, dots and
/// commas.
fn stringSkipSeparators(sp: [:0]const u8, pp: *usize) u8 {
    var c = sp[pp.*];
    while (c == '-' or c == '/' or c == '.' or c == ',') {
        pp.* += 1;
        c = sp[pp.*];
    }
    return c;
}

/// string_skip_until (quickjs.c:55521): skip a word, stop on chars in
/// `stoplist` (C strchr also matches the NUL terminator, hence the c == 0
/// stop).
fn stringSkipUntil(sp: [:0]const u8, pp: *usize, stoplist: []const u8) u8 {
    var c = sp[pp.*];
    while (c != 0 and std.mem.indexOfScalar(u8, stoplist, c) == null) {
        pp.* += 1;
        c = sp[pp.*];
    }
    return c;
}

/// string_get_digits (quickjs.c:55529): parse a numeric field
/// (max_digits == 0 -> no maximum, arbitrary limit of 9 digits).
fn stringGetDigits(sp: [:0]const u8, pp: *usize, pval: *i32, min_digits: usize, max_digits: usize) bool {
    var v: i32 = 0;
    var p = pp.*;
    const p_start = p;
    while (true) {
        const c = sp[p];
        if (c < '0' or c > '9') break;
        // arbitrary limit to 9 digits
        if (v >= 100000000) return false;
        v = v * 10 + @as(i32, c - '0');
        p += 1;
        if (p - p_start == max_digits) break;
    }
    if (p - p_start < min_digits) return false;
    pval.* = v;
    pp.* = p;
    return true;
}

/// string_get_milliseconds (quickjs.c:55552): parse an optional fractional
/// part as milliseconds and truncate.
fn stringGetMilliseconds(sp: [:0]const u8, pp: *usize, pval: *i32) bool {
    var mul: i32 = 100;
    var msec: i32 = 0;
    var p = pp.*;
    const c = sp[p];
    if (c == '.' or c == ',') {
        p += 1;
        const p_start = p;
        while (sp[p] >= '0' and sp[p] <= '9') {
            msec += @as(i32, sp[p] - '0') * mul;
            mul = @divTrunc(mul, 10);
            p += 1;
            if (p - p_start == 9) break;
        }
        if (p > p_start) {
            // only consume the separator if digits are present
            pval.* = msec;
            pp.* = p;
        }
    }
    return true;
}

/// upper_ascii (quickjs.c:55577).
fn upperAscii(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 'a' + 'A' else c;
}

/// string_get_tzoffset (quickjs.c:55581).
fn stringGetTzOffset(sp: [:0]const u8, pp: *usize, tzp: *i32, strict: bool) bool {
    var p = pp.*;
    const sgn = sp[p];
    p += 1;
    var tz: i32 = 0;
    if (sgn == '+' or sgn == '-') {
        var hh: i32 = undefined;
        const digits_start = p;
        if (!stringGetDigits(sp, &p, &hh, 1, 0)) return false;
        var n = p - digits_start;
        if (strict and n != 2 and n != 4) return false;
        while (n > 4) {
            n -= 2;
            hh = @divTrunc(hh, 100);
        }
        var mm: i32 = 0;
        if (n > 2) {
            mm = @rem(hh, 100);
            hh = @divTrunc(hh, 100);
        } else {
            mm = 0;
            if (stringSkipChar(sp, &p, ':')) {
                // optional separator
                if (!stringGetDigits(sp, &p, &mm, 2, 2)) return false;
            } else {
                if (strict) return false; // [+-]HH is not accepted in strict mode
            }
        }
        if (hh > 23 or mm > 59) return false;
        tz = hh * 60 + mm;
        if (sgn != '+') tz = -tz;
    } else if (sgn != 'Z') {
        return false;
    }
    pp.* = p;
    tzp.* = tz;
    return true;
}

/// string_match (quickjs.c:55622): case-insensitive keyword match.
fn stringMatch(sp: [:0]const u8, pp: *usize, s: []const u8) bool {
    var p = pp.*;
    for (s) |ch| {
        if (upperAscii(sp[p]) != upperAscii(ch)) return false;
        p += 1;
    }
    pp.* = p;
    return true;
}

/// find_abbrev (quickjs.c:55635): 3-letter abbreviation lookup.
fn findAbbrev(sp: [:0]const u8, p: usize, list: []const u8, count: usize) ?usize {
    var n: usize = 0;
    while (n < count) : (n += 1) {
        var i: usize = 0;
        while (true) : (i += 1) {
            if (upperAscii(sp[p + i]) != upperAscii(list[n * 3 + i])) break;
            if (i == 2) return n;
        }
    }
    return null;
}

/// string_get_month (quickjs.c:55649).
fn stringGetMonth(sp: [:0]const u8, pp: *usize, pval: *i32) bool {
    const n = findAbbrev(sp, pp.*, month_names, 12) orelse return false;
    pval.* = @intCast(n + 1);
    pp.* += 3;
    return true;
}

/// js_date_parse_isostring (quickjs.c:55662): parse the toISOString format.
/// A date-time without a timezone offset is LOCAL time (is_local = true at the
/// 'T'; an explicit offset/Z clears it); a date-only form stays UTC.
fn jsDateParseIsostring(sp: [:0]const u8, fields: *[9]i32, is_local: *bool) bool {
    var p: usize = 0;

    // initialize fields to the beginning of the Epoch
    for (0..9) |i| fields[i] = @intFromBool(i == 2);
    is_local.* = false;

    // year is either yyyy digits or [+-]yyyyyy
    const sgn = sp[p];
    if (sgn == '-' or sgn == '+') {
        p += 1;
        if (!stringGetDigits(sp, &p, &fields[0], 6, 6)) return false;
        if (sgn == '-') {
            if (fields[0] == 0) return false; // reject -000000
            fields[0] = -fields[0];
        }
    } else {
        if (!stringGetDigits(sp, &p, &fields[0], 4, 4)) return false;
    }
    if (stringSkipChar(sp, &p, '-')) {
        if (!stringGetDigits(sp, &p, &fields[1], 2, 2)) return false; // month
        if (fields[1] < 1) return false;
        fields[1] -= 1;
        if (stringSkipChar(sp, &p, '-')) {
            if (!stringGetDigits(sp, &p, &fields[2], 2, 2)) return false; // day
            if (fields[2] < 1) return false;
        }
    }
    if (stringSkipChar(sp, &p, 'T')) {
        is_local.* = true;
        if (!stringGetDigits(sp, &p, &fields[3], 2, 2) // hour
        or !stringSkipChar(sp, &p, ':') or
            !stringGetDigits(sp, &p, &fields[4], 2, 2)) // minute
        {
            fields[3] = 100; // reject unconditionally
            return true;
        }
        if (stringSkipChar(sp, &p, ':')) {
            if (!stringGetDigits(sp, &p, &fields[5], 2, 2)) return false; // second
            _ = stringGetMilliseconds(sp, &p, &fields[6]);
        }
    }
    // parse the time zone offset if present: [+-]HH:mm or [+-]HHmm
    if (sp[p] != 0) {
        is_local.* = false;
        if (!stringGetTzOffset(sp, &p, &fields[8], true)) return false;
    }
    // error if extraneous characters
    return sp[p] == 0;
}

/// js_tzabbr (quickjs.c:55722).
const TzAbbr = struct { name: []const u8, offset: i32 };
const js_tzabbr = [_]TzAbbr{
    .{ .name = "GMT", .offset = 0 }, // Greenwich Mean Time
    .{ .name = "UTC", .offset = 0 }, // Coordinated Universal Time
    .{ .name = "UT", .offset = 0 }, // Universal Time
    .{ .name = "Z", .offset = 0 }, // Zulu Time
    .{ .name = "EDT", .offset = -4 * 60 }, // Eastern Daylight Time
    .{ .name = "EST", .offset = -5 * 60 }, // Eastern Standard Time
    .{ .name = "CDT", .offset = -5 * 60 }, // Central Daylight Time
    .{ .name = "CST", .offset = -6 * 60 }, // Central Standard Time
    .{ .name = "MDT", .offset = -6 * 60 }, // Mountain Daylight Time
    .{ .name = "MST", .offset = -7 * 60 }, // Mountain Standard Time
    .{ .name = "PDT", .offset = -7 * 60 }, // Pacific Daylight Time
    .{ .name = "PST", .offset = -8 * 60 }, // Pacific Standard Time
    .{ .name = "WET", .offset = 0 * 60 }, // Western European Time
    .{ .name = "WEST", .offset = 1 * 60 }, // Western European Summer Time
    .{ .name = "CET", .offset = 1 * 60 }, // Central European Time
    .{ .name = "CEST", .offset = 2 * 60 }, // Central European Summer Time
    .{ .name = "EET", .offset = 2 * 60 }, // Eastern European Time
    .{ .name = "EEST", .offset = 3 * 60 }, // Eastern European Summer Time
};

/// string_get_tzabbr (quickjs.c:55747).
fn stringGetTzAbbr(sp: [:0]const u8, pp: *usize, offset: *i32) bool {
    for (js_tzabbr) |abbr| {
        if (stringMatch(sp, pp, abbr.name)) {
            offset.* = abbr.offset;
            return true;
        }
    }
    return false;
}

fn adjustTwoDigitYear(v: i32) i32 {
    return v + @as(i32, if (v < 100) 1900 else 0) + @as(i32, if (v < 50) 100 else 0);
}

/// js_date_parse_otherstring (quickjs.c:55758): parse toString, toUTCString
/// and other lenient formats (month names, slash dates, tz abbreviations,
/// AM/PM, parenthesized phrases, skipped words).
fn jsDateParseOtherstring(sp: [:0]const u8, fields: *[9]i32, is_local: *bool) bool {
    var p: usize = 0;
    var val: i32 = 0;
    var num: [3]i32 = undefined;
    var has_year = false;
    var has_mon = false;
    var has_time = false;
    var num_index: usize = 0;

    // initialize fields to the beginning of 2001-01-01
    fields[0] = 2001;
    fields[1] = 1;
    fields[2] = 1;
    for (3..9) |i| fields[i] = 0;
    is_local.* = true;

    while (stringSkipSpaces(sp, &p) != 0) {
        const p_start = p;
        var c = sp[p];
        if (c == '+' or c == '-') {
            if (has_time and stringGetTzOffset(sp, &p, &fields[8], false)) {
                is_local.* = false;
            } else {
                p += 1;
                if (stringGetDigits(sp, &p, &val, 1, 0)) {
                    if (c == '-') {
                        if (val == 0) return false;
                        val = -val;
                    }
                    fields[0] = val;
                    has_year = true;
                }
            }
        } else if (stringGetDigits(sp, &p, &val, 1, 0)) {
            if (stringSkipChar(sp, &p, ':')) {
                // time part
                fields[3] = val;
                if (!stringGetDigits(sp, &p, &fields[4], 1, 2)) return false;
                if (stringSkipChar(sp, &p, ':')) {
                    if (!stringGetDigits(sp, &p, &fields[5], 1, 2)) return false;
                    _ = stringGetMilliseconds(sp, &p, &fields[6]);
                }
                has_time = true;
                if ((sp[p] == '+' or sp[p] == '-') and
                    stringGetTzOffset(sp, &p, &fields[8], false))
                {
                    is_local.* = false;
                }
            } else {
                if (p - p_start > 2 and !has_year) {
                    fields[0] = val;
                    has_year = true;
                } else if ((val < 1 or val > 31) and !has_year) {
                    fields[0] = adjustTwoDigitYear(val);
                    has_year = true;
                } else {
                    if (num_index == 3) return false;
                    num[num_index] = val;
                    num_index += 1;
                }
            }
        } else if (stringGetMonth(sp, &p, &fields[1])) {
            has_mon = true;
            _ = stringSkipUntil(sp, &p, "0123456789 -/(");
        } else if (has_time and stringMatch(sp, &p, "PM")) {
            if (fields[3] < 12) fields[3] += 12;
            continue;
        } else if (has_time and stringMatch(sp, &p, "AM")) {
            if (fields[3] == 12) fields[3] -= 12;
            continue;
        } else if (stringGetTzAbbr(sp, &p, &fields[8])) {
            is_local.* = false;
            continue;
        } else if (c == '(') { // skip parenthesized phrase
            var level: i32 = 0;
            while (sp[p] != 0) {
                c = sp[p];
                p += 1;
                level += @intFromBool(c == '(');
                level -= @intFromBool(c == ')');
                if (level == 0) break;
            }
            if (level > 0) return false;
        } else if (c == ')') {
            return false;
        } else {
            if (has_year or has_mon or has_time or num_index > 0) return false;
            // skip a word
            _ = stringSkipUntil(sp, &p, " -/(");
        }
        _ = stringSkipSeparators(sp, &p);
    }
    if (num_index + @as(usize, @intFromBool(has_year)) + @as(usize, @intFromBool(has_mon)) > 3) return false;

    switch (num_index) {
        0 => if (!has_year) return false,
        1 => {
            if (has_mon) {
                fields[2] = num[0];
            } else {
                fields[1] = num[0];
            }
        },
        2 => {
            if (has_year) {
                fields[1] = num[0];
                fields[2] = num[1];
            } else if (has_mon) {
                fields[0] = adjustTwoDigitYear(num[1]);
                fields[2] = num[0];
            } else {
                fields[1] = num[0];
                fields[2] = num[1];
            }
        },
        3 => {
            fields[0] = adjustTwoDigitYear(num[2]);
            fields[1] = num[0];
            fields[2] = num[1];
        },
        else => return false,
    }
    if (fields[1] < 1 or fields[2] < 1) return false;
    fields[1] -= 1;
    return true;
}

// --- Object plumbing ---------------------------------------------------------

fn expectDateObject(value: core.JSValue) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_id != core.class.ids.date) return error.TypeError;
    return object;
}

fn setDateValue(rt: *core.JSRuntime, object: *core.Object, ms: f64) !void {
    const slot = object.objectDataSlot();
    const old_value = slot.*;
    slot.* = core.JSValue.float64(ms);
    if (old_value) |stored| stored.free(rt);
}

fn dateValue(object: *const core.Object) !f64 {
    const value = object.objectData() orelse return error.TypeError;
    return numberValue(value) orelse error.TypeError;
}

fn dateObjectFromValue(value: core.JSValue) ?*core.Object {
    const header = value.refHeader() orelse return null;
    if (!value.isObject()) return null;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_id != core.class.ids.date) return null;
    return object;
}

fn numberValue(value: core.JSValue) ?f64 {
    if (value.isInt()) return @floatFromInt(value.asInt32().?);
    if (value.isFloat64()) return value.asFloat64().?;
    return null;
}

fn numberResult(value: f64) core.JSValue {
    if (std.math.isFinite(value) and @floor(value) == value and value >= @as(f64, @floatFromInt(std.math.minInt(i32))) and value <= @as(f64, @floatFromInt(std.math.maxInt(i32))) and !std.math.isNegativeZero(value)) {
        return core.JSValue.int32(@intFromFloat(value));
    }
    return core.JSValue.float64(value);
}

fn toNumber(value: core.JSValue) ?f64 {
    if (value.isSymbol()) return null;
    // JS_ToFloat64 throws "cannot convert bigint to number" (qjs
    // js_date_constructor/set_date_field/js_Date_UTC all coerce through it).
    if (value.isBigInt()) return null;
    if (numberValue(value)) |number| return number;
    if (value.asBool()) |bool_value| return if (bool_value) 1 else 0;
    if (value.isNull()) return 0;
    if (value.isUndefined()) return std.math.nan(f64);
    if (value.isString()) {
        var scratch: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&scratch);
        appendStringValueAscii(&writer, value) catch return std.math.nan(f64);
        const text = writer.buffered();
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return 0;
        return std.fmt.parseFloat(f64, trimmed) catch std.math.nan(f64);
    }
    return std.math.nan(f64);
}

fn appendStringValueAscii(writer: *std.Io.Writer, value: core.JSValue) !void {
    const string_value = value.asStringBody() orelse return;
    switch (string_value.resolveData()) {
        .latin1 => |bytes| try writer.writeAll(bytes),
        .utf16 => |units| {
            for (units) |unit| {
                if (unit > 0x7f) return error.TypeError;
                try writer.writeByte(@intCast(unit));
            }
        },
    }
}

fn currentTimeMs() f64 {
    var tv: std.c.timeval = undefined;
    if (std.c.gettimeofday(&tv, null) == 0) {
        return @as(f64, @floatFromInt(tv.sec)) * 1000.0 + @as(f64, @floatFromInt(@divTrunc(tv.usec, 1000)));
    }
    return 0;
}

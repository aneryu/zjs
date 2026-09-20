//! Date constructor, static/prototype records, coercion, and calendar logic.
//!
//! Call arguments are borrowed; coercion results and temporary strings are
//! owned locally, and constructed/returned JSValues transfer one owned
//! reference. VM-observable coercion stays on the explicit call environment;
//! record bodies receive only already-resolved inputs where possible. QuickJS
//! mappings include `set_date_field` at quickjs.c, Date construction at
//! quickjs.c, parsing at quickjs.c, and
//! `Symbol.toPrimitive` at quickjs.c.

const std = @import("std");
const builtin = @import("builtin");

const bytecode = @import("../bytecode.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const value_ops = @import("value_ops.zig");
const call_runtime = @import("call_runtime.zig");
const coercion_ops = @import("coercion_ops.zig");
const exception_ops = @import("exception_ops.zig");
const exceptions = @import("exceptions.zig");
const object_ops = @import("object_ops.zig");
const string_ops = @import("string_ops.zig");

const HostError = exceptions.HostError;

// The Date constructor body runs through the record table keyed on this ref
// (matching the RegExp/String construct unification in Phase 6b-3d/e): the
// VM-context argument coercion stays here in `dateConstructWithPrototype`
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

/// Route a Date.prototype method *body* through the record table's
/// func-object-free arm so the dispatch lands on `dateCall`, which runs the
/// pure `methodCallArgs` body. `args` must already be coerced.
pub fn callDateBody(
    ctx: *core.JSContext,
    this_value: core.JSValue,
    method: PrototypeMethod,
    args: []const core.JSValue,
) !core.JSValue {
    const native_ref = core.function.NativeBuiltinRef{ .domain = .date, .id = @intFromEnum(method) };
    return (try builtin_dispatch.callInternalRecord(ctx, null, null, &.{}, null, this_value, native_ref, args, null, null)) orelse error.TypeError;
}

/// Route a Date static-method body (`Date.UTC`/`Date.parse`/`Date.now`) through
/// the table; `args` must already be coerced.
pub fn callDateStaticBody(
    ctx: *core.JSContext,
    method: StaticMethod,
    args: []const core.JSValue,
) !core.JSValue {
    const native_ref = core.function.NativeBuiltinRef{ .domain = .date, .id = @intFromEnum(method) };
    return (try builtin_dispatch.callInternalRecord(ctx, null, null, &.{}, null, core.JSValue.undefinedValue(), native_ref, args, null, null)) orelse error.TypeError;
}

/// Capture a Date instance's `[[DateValue]]` as an f64 by routing the `getTime`
/// body through the table (the spec captures `t` before coercing setter args).
fn captureDateValueMs(ctx: *core.JSContext, this_value: core.JSValue) !f64 {
    const captured_value = try callDateBody(ctx, this_value, .get_time, &.{});
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
    const native_ref = core.function.NativeBuiltinRef{ .domain = .date, .id = @intFromEnum(PrototypeMethod.set_year_with_captured_ms) };
    const packed_args = [_]core.JSValue{ core.JSValue.float64(captured_ms), core.JSValue.float64(year_number) };
    return (try builtin_dispatch.callInternalRecord(ctx, null, null, &.{}, null, this_value, native_ref, &packed_args, null, null)) orelse error.TypeError;
}

/// Route a date-parts setter with a pre-captured `[[DateValue]]` and coerced
/// field args through the table's captured-setter arm
/// (`methodCallArgsWithCapturedMs` body). Layout: args[0]=captured ms,
/// args[1]=int32 setter `PrototypeMethod` id, args[2..]=coerced field args.
fn callDateSetPartsWithCapturedMs(
    ctx: *core.JSContext,
    this_value: core.JSValue,
    method: PrototypeMethod,
    captured_ms: f64,
    args: []const core.JSValue,
) !core.JSValue {
    const native_ref = core.function.NativeBuiltinRef{ .domain = .date, .id = @intFromEnum(PrototypeMethod.set_parts_with_captured_ms) };
    var packed_args: [6]core.JSValue = undefined;
    packed_args[0] = core.JSValue.float64(captured_ms);
    packed_args[1] = core.JSValue.int32(@intCast(@intFromEnum(method)));
    const count = @min(args.len, packed_args.len - 2);
    @memcpy(packed_args[2 .. 2 + count], args[0..count]);
    return (try builtin_dispatch.callInternalRecord(ctx, null, null, &.{}, null, this_value, native_ref, packed_args[0 .. 2 + count], null, null)) orelse error.TypeError;
}

const DateToPrimitiveHint = enum {
    string,
    number,
};

pub fn dateSetYear(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const object = object_ops.objectFromValue(this_value) orelse return null;
    if (object.class_id != core.class.ids.date) return null;
    const captured_ms = try captureDateValueMs(ctx, this_value);
    const year_input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const year_value = try coercion_ops.toNumberForDateMethod(ctx, output, global, year_input, caller_function, caller_frame);
    const year_number = value_ops.numberValue(year_value) orelse std.math.nan(f64);
    return try callDateSetYearWithCapturedMs(ctx, this_value, captured_ms, year_number);
}

pub fn dateSetTime(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const object = object_ops.objectFromValue(this_value) orelse return null;
    if (object.class_id != core.class.ids.date) return null;
    const time_input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const time_value = try coercion_ops.toNumberForDateMethod(ctx, output, global, time_input, caller_function, caller_frame);
    return try callDateBody(ctx, this_value, .set_time, &.{time_value});
}

pub fn dateStaticCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    method: StaticMethod,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    _ = this_value;
    if (method != .utc) return null;
    var coerced_args: [7]core.JSValue = undefined;
    var coerced_len: usize = 0;
    while (coerced_len < args.len and coerced_len < coerced_args.len) : (coerced_len += 1) {
        coerced_args[coerced_len] = try coercion_ops.toNumberForDateMethod(ctx, output, global, args[coerced_len], caller_function, caller_frame);
    }
    return try callDateStaticBody(ctx, method, coerced_args[0..coerced_len]);
}

pub fn dateCapturedSetterCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    method: PrototypeMethod,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    // qjs set_date_field coerces exactly `min_int(argc, end_field -
    // first_field)` arguments; extra arguments are not
    // coerced (their valueOf must not run).
    const field_count: usize = switch (method) {
        .set_milliseconds => 1,
        .set_seconds => 2,
        .set_minutes => 3,
        .set_hours => 4,
        .set_date => 1,
        .set_month => 2,
        .set_full_year => 3,
        else => return null,
    };
    const object = object_ops.objectFromValue(this_value) orelse return null;
    if (object.class_id != core.class.ids.date) return null;

    const captured_ms = try captureDateValueMs(ctx, this_value);

    var coerced_args: [4]core.JSValue = undefined;
    var coerced_len: usize = 0;
    while (coerced_len < args.len and coerced_len < field_count) : (coerced_len += 1) {
        coerced_args[coerced_len] = try coercion_ops.toNumberForDateMethod(ctx, output, global, args[coerced_len], caller_function, caller_frame);
    }

    return try callDateSetPartsWithCapturedMs(ctx, this_value, method, captured_ms, coerced_args[0..coerced_len]);
}

pub fn dateToJsonCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    _ = args;
    if (this_value.is(.null_value) or this_value.is(.undefined_value)) return error.TypeError;

    const primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, this_value);
    if (primitive.isNumber()) {
        const number = value_ops.numberValue(primitive) orelse std.math.nan(f64);
        if (!std.math.isFinite(number)) return core.JSValue.nullValue();
    }

    const key = core.atom.ids.toISOString;
    const method = try object_ops.getValueProperty(ctx, output, global, this_value, key, caller_function, caller_frame);
    if (!call_runtime.isCallableValue(method)) return error.TypeError;
    return try call_runtime.callValueOrBytecodeRoot(ctx, output, global, this_value, method, &.{}, caller_function, caller_frame);
}

pub fn dateConstructWithPrototype(
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
                const time_value = try callDateBody(ctx, args[0], .get_time, &.{});
                return constructDateRecord(ctx, prototype, &.{time_value});
            }

            const primitive = try coercion_ops.toPrimitiveForAddition(ctx, output, global, args[0]);
            if (primitive.isString()) return constructDateRecord(ctx, prototype, &.{primitive});
            // JS_ToFloat64Free on a bigint primitive throws (qjs
            // js_date_constructor single-arg branch).
            if (primitive.isBigInt()) return exception_ops.throwTypeErrorMessage(ctx, global, "cannot convert bigint to number");
            const number = try value_ops.toNumberValue(ctx.runtime, primitive);
            return constructDateRecord(ctx, prototype, &.{number});
        }

        if (args[0].isString()) return constructDateRecord(ctx, prototype, args);
        if (args[0].isBigInt()) return exception_ops.throwTypeErrorMessage(ctx, global, "cannot convert bigint to number");
        const number = try value_ops.toNumberValue(ctx.runtime, args[0]);
        return constructDateRecord(ctx, prototype, &.{number});
    }

    var coerced_args: [7]core.JSValue = undefined;
    var coerced_len: usize = 0;
    while (coerced_len < args.len and coerced_len < coerced_args.len) : (coerced_len += 1) {
        coerced_args[coerced_len] = try coercion_ops.toNumberForDateMethod(ctx, output, global, args[coerced_len], null, null);
    }
    return constructDateRecord(ctx, prototype, coerced_args[0..coerced_len]);
}

pub fn dateToPrimitiveCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (!this_value.is(.object)) return exception_ops.throwTypeErrorMessage(ctx, global, "not an object");

    const hint_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const hint = dateToPrimitiveHint(hint_value) orelse
        return exception_ops.throwTypeErrorMessage(ctx, global, "invalid hint");
    return switch (hint) {
        .string => try dateOrdinaryToPrimitive(ctx, output, global, this_value, true, caller_function, caller_frame),
        .number => try dateOrdinaryToPrimitive(ctx, output, global, this_value, false, caller_function, caller_frame),
    };
}

fn dateToPrimitiveHint(value: core.JSValue) ?DateToPrimitiveHint {
    if (!value.isString()) return null;
    if (string_ops.stringValueUnitsEqualBytes(value, "string") or string_ops.stringValueUnitsEqualBytes(value, "default")) return .string;
    // qjs js_date_Symbol_toPrimitive maps JS_ATOM_integer to
    // HINT_NUMBER alongside JS_ATOM_number (nonstandard qjs extension;
    // test262 does not exercise the 'integer' hint).
    if (string_ops.stringValueUnitsEqualBytes(value, "number") or string_ops.stringValueUnitsEqualBytes(value, "integer")) return .number;
    return null;
}

fn dateOrdinaryToPrimitive(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    string_first: bool,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (string_first) {
        if (try object_ops.callObjectToPrimitiveMethod(ctx, output, global, receiver, core.atom.ids.toString, caller_function, caller_frame)) |primitive| return primitive;
        if (try object_ops.callObjectToPrimitiveMethod(ctx, output, global, receiver, core.atom.ids.valueOf, caller_function, caller_frame)) |primitive| return primitive;
    } else {
        if (try object_ops.callObjectToPrimitiveMethod(ctx, output, global, receiver, core.atom.ids.valueOf, caller_function, caller_frame)) |primitive| return primitive;
        if (try object_ops.callObjectToPrimitiveMethod(ctx, output, global, receiver, core.atom.ids.toString, caller_function, caller_frame)) |primitive| return primitive;
    }
    return error.TypeError;
}

pub const StaticMethod = core.host_function.builtin_method_ids.date.StaticMethod;

// Relocated to engine core (`core/host_function.zig`, next to
// `builtin_method_ids.date.StaticMethod`) in Phase 6b-3e so the VM construct
// dispatchers can gate on the construct id without importing this operation Module;
// re-exported here so the install/dispatch side keeps the original name.
pub const ConstructorMethod = core.host_function.builtin_method_ids.date.ConstructorMethod;

// Relocated to engine core (`core/host_function.zig`,
// `builtin_method_ids.date.PrototypeMethod`) in Phase 6b-3 STEP 5 so the exec
// date glue can build the record `NativeBuiltinRef` for table dispatch without
// importing this operation Module; re-exported here so the dispatch/install side keeps the
// original name.
pub const PrototypeMethod = core.host_function.builtin_method_ids.date.PrototypeMethod;

/// Declaration + dispatch table for the `.date` native-builtin domain
/// (QuickJS js_date_funcs analogue). One shared record handler `dateCall`
/// switches on the per-record `magic` (== domain-local id); the constructor,
/// the statics, the `Symbol.toPrimitive` method, and the prototype methods all
/// route through it. `id` doubles as `magic`, so the record carries no extra
/// selector. Property installation still resolves names through the registry's
/// Date method tables (canonical name/length) and date.zig's id helpers; this
/// table is consumed by the record-dispatch path (`rt.internal_builtins`).
pub const internal_entries = dateEntries: {
    const Entry = core.host_function.InternalEntry;
    break :dateEntries [_]Entry{
        dateEntry("UTC", 7, @intFromEnum(StaticMethod.utc)),
        dateEntry("parse", 1, @intFromEnum(StaticMethod.parse)),
        dateEntry("now", 0, @intFromEnum(StaticMethod.now)),
        dateConstructorEntry("Date", 7, @intFromEnum(ConstructorMethod.construct)),
        dateEntry("getTime", 0, @intFromEnum(PrototypeMethod.get_time)),
        dateEntry("valueOf", 0, @intFromEnum(PrototypeMethod.value_of)),
        dateEntry("getFullYear", 0, @intFromEnum(PrototypeMethod.get_full_year)),
        dateEntry("getMonth", 0, @intFromEnum(PrototypeMethod.get_month)),
        dateEntry("getDate", 0, @intFromEnum(PrototypeMethod.get_date)),
        dateEntry("getHours", 0, @intFromEnum(PrototypeMethod.get_hours)),
        dateEntry("getMinutes", 0, @intFromEnum(PrototypeMethod.get_minutes)),
        dateEntry("getSeconds", 0, @intFromEnum(PrototypeMethod.get_seconds)),
        dateEntry("getMilliseconds", 0, @intFromEnum(PrototypeMethod.get_milliseconds)),
        dateEntry("toISOString", 0, @intFromEnum(PrototypeMethod.to_iso_string)),
        dateEntry("toJSON", 1, @intFromEnum(PrototypeMethod.to_json)),
        dateEntry("getUTCFullYear", 0, @intFromEnum(PrototypeMethod.get_utc_full_year)),
        dateEntry("getUTCMonth", 0, @intFromEnum(PrototypeMethod.get_utc_month)),
        dateEntry("getUTCDate", 0, @intFromEnum(PrototypeMethod.get_utc_date)),
        dateEntry("getUTCHours", 0, @intFromEnum(PrototypeMethod.get_utc_hours)),
        dateEntry("getUTCMinutes", 0, @intFromEnum(PrototypeMethod.get_utc_minutes)),
        dateEntry("getUTCSeconds", 0, @intFromEnum(PrototypeMethod.get_utc_seconds)),
        dateEntry("getUTCMilliseconds", 0, @intFromEnum(PrototypeMethod.get_utc_milliseconds)),
        dateEntry("getDay", 0, @intFromEnum(PrototypeMethod.get_day)),
        dateEntry("toString", 0, @intFromEnum(PrototypeMethod.to_string)),
        dateEntry("toUTCString", 0, @intFromEnum(PrototypeMethod.to_utc_string)),
        dateEntry("getYear", 0, @intFromEnum(PrototypeMethod.get_year)),
        dateEntry("setYear", 1, @intFromEnum(PrototypeMethod.set_year)),
        dateEntry("setTime", 1, @intFromEnum(PrototypeMethod.set_time)),
        dateEntry("setMilliseconds", 1, @intFromEnum(PrototypeMethod.set_milliseconds)),
        dateEntry("setSeconds", 2, @intFromEnum(PrototypeMethod.set_seconds)),
        dateEntry("setMinutes", 3, @intFromEnum(PrototypeMethod.set_minutes)),
        dateEntry("setHours", 4, @intFromEnum(PrototypeMethod.set_hours)),
        dateEntry("setDate", 1, @intFromEnum(PrototypeMethod.set_date)),
        dateEntry("setMonth", 2, @intFromEnum(PrototypeMethod.set_month)),
        dateEntry("setFullYear", 3, @intFromEnum(PrototypeMethod.set_full_year)),
        dateEntry("getTimezoneOffset", 0, @intFromEnum(PrototypeMethod.get_timezone_offset)),
        dateEntry("toDateString", 0, @intFromEnum(PrototypeMethod.to_date_string)),
        dateEntry("toTimeString", 0, @intFromEnum(PrototypeMethod.to_time_string)),
        dateEntry("[Symbol.toPrimitive]", 1, @intFromEnum(PrototypeMethod.to_primitive)),
        // Engine-internal captured-setter records (no JS property; the registry
        // installs only the named methods above). Reached solely from the
        // `func_obj == null` arm so `exec/date_ops.zig` can route the
        // capture-then-apply setter bodies through the table.
        dateEntry("", 0, @intFromEnum(PrototypeMethod.set_year_with_captured_ms)),
        dateEntry("", 0, @intFromEnum(PrototypeMethod.set_parts_with_captured_ms)),
        // Local/UTC method split + qjs fmt=3 locale shapes (see
        // `ExtendedPrototypeMethod`); handled entirely inside `dateCall`.
        dateEntry("getUTCDay", 0, @intFromEnum(PrototypeMethod.get_utc_day)),
        dateEntry("setUTCMilliseconds", 1, @intFromEnum(PrototypeMethod.set_utc_milliseconds)),
        dateEntry("setUTCSeconds", 2, @intFromEnum(PrototypeMethod.set_utc_seconds)),
        dateEntry("setUTCMinutes", 3, @intFromEnum(PrototypeMethod.set_utc_minutes)),
        dateEntry("setUTCHours", 4, @intFromEnum(PrototypeMethod.set_utc_hours)),
        dateEntry("setUTCDate", 1, @intFromEnum(PrototypeMethod.set_utc_date)),
        dateEntry("setUTCMonth", 2, @intFromEnum(PrototypeMethod.set_utc_month)),
        dateEntry("setUTCFullYear", 3, @intFromEnum(PrototypeMethod.set_utc_full_year)),
        dateEntry("toLocaleString", 0, @intFromEnum(PrototypeMethod.to_locale_string)),
        dateEntry("toLocaleDateString", 0, @intFromEnum(PrototypeMethod.to_locale_date_string)),
        dateEntry("toLocaleTimeString", 0, @intFromEnum(PrototypeMethod.to_locale_time_string)),
    };
};

fn dateEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{
        .name = name,
        .length = length,
        .id = id,
        .magic = @intCast(id),
        .cproto = .generic_magic,
        .native_function = builtin_dispatch.genericMagicFunction(&dateCall),
    };
}

/// The Date constructor record: construct-capable so `new Date(...)` routes
/// through the construct dispatch path into `dateCall`'s construct branch.
fn dateConstructorEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{
        .name = name,
        .length = length,
        .id = id,
        .magic = @intCast(id),
        .cproto = .constructor_or_func_magic,
        .native_function = builtin_dispatch.constructorOrFunctionMagic(&dateCall),
    };
}

/// Shared record handler for the `.date` domain. Mirrors the retired
/// `call.zig` `callDateNativeFunctionRecord`: the constructor and statics run
/// the pure builtin helpers below, while the `Symbol.toPrimitive` and
/// prototype methods delegate to the exec VM ops (which stay in exec because
/// the date opcode handlers also call them).
fn dateCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const ctx = host_call.ctx;
    const callable_global: ?*core.Object = if (host_call.func_obj != null) blk: {
        const realm = try builtin_dispatch.callableRealm(host_call);
        std.debug.assert(realm.realm == ctx);
        break :blk realm.global;
    } else host_call.global;
    const output = host_call.output;
    const id: u32 = host_call.magic;
    const args = host_call.args;
    const caller_function = builtin_dispatch.callerBytecode(host_call);
    const caller_frame = builtin_dispatch.callerFrame(host_call);

    if (id == @intFromEnum(ConstructorMethod.construct)) {
        // `new Date(...)` arrives through the construct record path
        // (`exec/construct.zig`) with `is_constructor` set and the resolved
        // instance prototype in `new_target`; `Date(...)` called as a function
        // returns the current time string (QuickJS js_date_constructor with
        // `new_target == undefined`).
        if (host_call.is_constructor) return constructWithPrototype(ctx.runtime, args, host_call.new_target);
        return call(ctx.runtime, args);
    }

    // Engine-internal dispatch arm: the exec date VM-coercion glue
    // (`exec/date_ops.zig`, plus the `Date.now` fusion and the static
    // fall-throughs) has already coerced its arguments and routes the *pure body*
    // through the table here so VM coercion stays on the same record boundary. It is
    // gated on `func_obj == null and global == null`, the contract those call
    // sites use; other direct callers pass `func_obj == null` while threading
    // the realm `global` and raw args, so they must instead fall through to the
    // coercing dispatcher below. This
    // deliberately bypasses the prototype dispatcher
    // (`object_ops.datePrototypeMethod`) — routing back through it would
    // re-enter this record (the dispatcher's own body call is one of the
    // converted sites) and recurse, and the glue already performed the
    // dispatcher's coercion/capture work.
    if (host_call.func_obj == null and host_call.global == null and !host_call.is_constructor) {
        return dateInternalBodyCall(ctx.runtime, id, host_call.this_value, args);
    }

    if (id == @intFromEnum(PrototypeMethod.to_primitive)) {
        const active_global = callable_global orelse return error.TypeError;
        return dateToPrimitiveCall(ctx, output, active_global, host_call.this_value, args, caller_function, caller_frame);
    }
    if (id == @intFromEnum(StaticMethod.utc)) {
        const active_global = callable_global orelse return error.TypeError;
        var coerced_args: [7]core.JSValue = undefined;
        var coerced_len: usize = 0;
        while (coerced_len < args.len and coerced_len < coerced_args.len) : (coerced_len += 1) {
            coerced_args[coerced_len] = try coercion_ops.toNumberForDateMethod(ctx, output, active_global, args[coerced_len], null, null);
        }
        return staticCall(ctx.runtime, .utc, coerced_args[0..coerced_len]) catch |err| switch (err) {
            error.TypeError => error.TypeError,
            else => err,
        };
    }
    if (id == @intFromEnum(StaticMethod.parse)) {
        // js_Date_parse ToString-coerces its argument (never
        // a TypeError arity/type gate); the coercion runs in VM context so a
        // user `toString`/`Symbol.toPrimitive` executes with the caller frame.
        const active_global = callable_global orelse return error.TypeError;
        const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const string_value = try string_ops.toStringForAnnexB(ctx, output, active_global, input, caller_function, caller_frame);
        return core.JSValue.float64(try parseDateString(string_value));
    }
    if (std.enums.fromInt(PrototypeMethod, id)) |method| {
        const active_global = callable_global orelse return error.TypeError;
        switch (method) {
            // Only reachable through the engine-internal arm above.
            .set_year_with_captured_ms, .set_parts_with_captured_ms => return error.TypeError,
            else => {},
        }
        if (isBuiltinsLocalMethod(method)) {
            return dateExtendedPrototypeCall(ctx, output, active_global, host_call.this_value, method, args);
        }
        return object_ops.datePrototypeMethod(ctx, output, active_global, host_call.this_value, method, args, caller_function, caller_frame) catch |err| switch (err) {
            error.TypeError => error.TypeError,
            else => err,
        };
    }
    const static_method = std.enums.fromInt(StaticMethod, id) orelse return error.TypeError;
    return staticCall(ctx.runtime, static_method, args) catch |err| switch (err) {
        error.TypeError => error.TypeError,
        else => err,
    };
}

/// The UTC/local twins and `toLocale*` shapes are coerced by
/// `dateExtendedPrototypeCall` here; every other prototype method goes
/// through the exec dispatcher (`object_ops.datePrototypeMethod`).
fn isBuiltinsLocalMethod(method: PrototypeMethod) bool {
    return switch (method) {
        .get_utc_day,
        .set_utc_milliseconds,
        .set_utc_seconds,
        .set_utc_minutes,
        .set_utc_hours,
        .set_utc_date,
        .set_utc_month,
        .set_utc_full_year,
        .to_locale_string,
        .to_locale_date_string,
        .to_locale_time_string,
        => true,
        else => false,
    };
}

/// Run a date method *body* directly for an engine-internal table call that
/// holds no function object and has already coerced its arguments. Reached only
/// from `dateCall`'s `func_obj == null` arm. `id` is a `.date` record id:
/// `StaticMethod.{utc,parse,now}` run the static body on the pre-coerced args;
/// the captured-setter selectors unpack the captured `[[DateValue]]` (and, for
/// the parts variant, the setter method id) the exec glue threaded through
/// `args`; every other prototype method runs the plain `methodCallArgs` body.
fn dateInternalBodyCall(rt: *core.JSRuntime, id: u32, this_value: core.JSValue, args: []const core.JSValue) HostError!core.JSValue {
    const result = blk: {
        if (std.enums.fromInt(PrototypeMethod, id)) |method| switch (method) {
            .set_year_with_captured_ms => {
                const captured_ms = args[0].asNumber() orelse std.math.nan(f64);
                const year_number = args[1].asNumber() orelse std.math.nan(f64);
                break :blk setYearNumber(this_value, captured_ms, year_number);
            },
            .set_parts_with_captured_ms => {
                const captured_ms = args[0].asNumber() orelse std.math.nan(f64);
                const setter_id: u32 = @intFromFloat(args[1].asNumber() orelse 0);
                const setter = std.enums.fromInt(PrototypeMethod, setter_id) orelse break :blk error.TypeError;
                break :blk methodCallArgsWithCapturedMs(this_value, setter, captured_ms, args[2..]);
            },
            else => break :blk methodCallArgs(rt, this_value, method, args),
        };
        // `StaticMethod.{utc,parse,now}`: the glue pre-coerced any args.
        const static_method = std.enums.fromInt(StaticMethod, id) orelse break :blk error.TypeError;
        break :blk staticCall(rt, static_method, args);
    };
    return result catch |err| return @as(HostError, @errorCast(err));
}

/// Coercing arm for the extended (builtins-local) prototype record ids.
/// Mirrors QuickJS: `set_date_field` checks `this` and reads
/// the time value *before* coercing arguments, then coerces exactly
/// `min(argc, end_field - first_field)` arguments; `get_date_field` /
/// `get_date_string` bodies take no arguments.
fn dateExtendedPrototypeCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    method: PrototypeMethod,
    args: []const core.JSValue,
) HostError!core.JSValue {
    const rt = ctx.runtime;
    if (setterSpan(method)) |span| {
        const object = expectDateObject(this_value) catch
            return exception_ops.throwTypeErrorMessage(ctx, global, "not a Date object");
        const captured_ms = dateValue(object) catch
            return exception_ops.throwTypeErrorMessage(ctx, global, "not a Date object");
        var coerced_args: [4]core.JSValue = undefined;
        var coerced_len: usize = 0;
        const coerce_count = @min(args.len, span.count());
        while (coerced_len < coerce_count) : (coerced_len += 1) {
            coerced_args[coerced_len] = try coercion_ops.toNumberForDateMethod(ctx, output, global, args[coerced_len], null, null);
        }
        return setDateFieldBody(object, captured_ms, coerced_args[0..coerced_len], args.len, span);
    }
    return methodCallArgs(rt, this_value, method, args) catch |err| switch (err) {
        error.TypeError => return exception_ops.throwTypeErrorMessage(ctx, global, "not a Date object"),
        else => err,
    };
}

// Pure name->id mapping relocated to engine core (`core/host_function.zig`,
// next to `builtin_method_ids.date`) in Phase 6b-3c; re-exported here so the
// dispatch/install side keeps the original name.
pub const staticMethod = core.host_function.builtin_method_id_lookup.date.staticMethod;

const prototype_method_names = std.StaticStringMap(PrototypeMethod).initComptime(.{
    .{ "getTime", .get_time },
    .{ "valueOf", .value_of },
    .{ "getFullYear", .get_full_year },
    .{ "getTimezoneOffset", .get_timezone_offset },
    .{ "getMonth", .get_month },
    .{ "getDate", .get_date },
    .{ "getHours", .get_hours },
    .{ "getMinutes", .get_minutes },
    .{ "getSeconds", .get_seconds },
    .{ "getMilliseconds", .get_milliseconds },
    .{ "toISOString", .to_iso_string },
    .{ "toJSON", .to_json },
    .{ "getUTCFullYear", .get_utc_full_year },
    .{ "getUTCMonth", .get_utc_month },
    .{ "getUTCDate", .get_utc_date },
    .{ "getUTCHours", .get_utc_hours },
    .{ "getUTCMinutes", .get_utc_minutes },
    .{ "getUTCSeconds", .get_utc_seconds },
    .{ "getUTCMilliseconds", .get_utc_milliseconds },
    .{ "getUTCDay", .get_utc_day },
    .{ "getDay", .get_day },
    .{ "toString", .to_string },
    .{ "toLocaleString", .to_locale_string },
    .{ "toUTCString", .to_utc_string },
    .{ "toGMTString", .to_utc_string },
    .{ "toDateString", .to_date_string },
    .{ "toLocaleDateString", .to_locale_date_string },
    .{ "toTimeString", .to_time_string },
    .{ "toLocaleTimeString", .to_locale_time_string },
    .{ "getYear", .get_year },
    .{ "setYear", .set_year },
    .{ "setTime", .set_time },
    .{ "setMilliseconds", .set_milliseconds },
    .{ "setUTCMilliseconds", .set_utc_milliseconds },
    .{ "setSeconds", .set_seconds },
    .{ "setUTCSeconds", .set_utc_seconds },
    .{ "setMinutes", .set_minutes },
    .{ "setUTCMinutes", .set_utc_minutes },
    .{ "setHours", .set_hours },
    .{ "setUTCHours", .set_utc_hours },
    .{ "setDate", .set_date },
    .{ "setUTCDate", .set_utc_date },
    .{ "setMonth", .set_month },
    .{ "setUTCMonth", .set_utc_month },
    .{ "setFullYear", .set_full_year },
    .{ "setUTCFullYear", .set_utc_full_year },
});

pub fn prototypeMethodId(name: []const u8) ?u32 {
    return @intFromEnum(prototype_method_names.get(name) orelse return null);
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
    errdefer core.Object.destroyFromHeader(rt, object.gcHeader());

    if (args.len >= 2) {
        const next_ms = try constructDateFromParts(args);
        setDateValue(object, next_ms);
    } else if (args.len == 1) {
        const ms = if (args[0].isString())
            try parseDateString(args[0])
        else if (dateObjectFromValue(args[0])) |date_object|
            try dateValue(date_object)
        else
            timeClip(toNumber(args[0]) orelse return error.TypeError);
        setDateValue(object, ms);
    } else {
        setDateValue(object, currentTimeMs());
    }

    return object.value();
}

/// QuickJS source map: Date.UTC / Date.parse / Date.now.
pub fn staticCall(rt: *core.JSRuntime, method: StaticMethod, args: []const core.JSValue) !core.JSValue {
    return switch (method) {
        .utc => utc(args),
        .parse => try parse(rt, args),
        .now => core.JSValue.float64(currentTimeMs()),
    };
}

/// QuickJS source map: selected Date.prototype methods used by current smoke
/// and targeted regression coverage.
pub fn methodCall(rt: *core.JSRuntime, object_value: core.JSValue, method: PrototypeMethod) !core.JSValue {
    return methodCallArgs(rt, object_value, method, &.{});
}

pub fn methodCallArgs(rt: *core.JSRuntime, object_value: core.JSValue, method: PrototypeMethod, args: []const core.JSValue) !core.JSValue {
    const object = try expectDateObject(object_value);
    const ms = try dateValue(object);
    if (setterSpan(method)) |span| {
        // Raw-args setter path (engine-internal callers): coerce here, then run
        // the shared `set_date_field` body.
        return setDateFieldBody(object, ms, args, args.len, span);
    }
    return switch (method) {
        .get_time, .value_of => numberResult(ms),
        .set_time => try setTime(object, args),
        .get_full_year => getDateFieldValue(ms, .year, .local),
        .get_month => getDateFieldValue(ms, .month, .local),
        .get_date => getDateFieldValue(ms, .day, .local),
        .get_hours => getDateFieldValue(ms, .hours, .local),
        .get_minutes => getDateFieldValue(ms, .minutes, .local),
        .get_seconds => getDateFieldValue(ms, .seconds, .local),
        .get_milliseconds => getDateFieldValue(ms, .milliseconds, .local),
        .get_day => getDateFieldValue(ms, .weekday, .local),
        .get_utc_full_year => getDateFieldValue(ms, .year, .utc),
        .get_utc_month => getDateFieldValue(ms, .month, .utc),
        .get_utc_date => getDateFieldValue(ms, .day, .utc),
        .get_utc_hours => getDateFieldValue(ms, .hours, .utc),
        .get_utc_minutes => getDateFieldValue(ms, .minutes, .utc),
        .get_utc_seconds => getDateFieldValue(ms, .seconds, .utc),
        .get_utc_milliseconds => getDateFieldValue(ms, .milliseconds, .utc),
        .get_utc_day => getDateFieldValue(ms, .weekday, .utc),
        .get_year => getYearValue(ms),
        // get_date_string magics (quickjs.c js_date_proto_funcs).
        .to_iso_string => try getDateStringValue(rt, ms, 0x23),
        .to_json => if (std.math.isNan(ms)) core.JSValue.nullValue() else try getDateStringValue(rt, ms, 0x23),
        .to_string => try getDateStringValue(rt, ms, 0x13),
        .to_utc_string => try getDateStringValue(rt, ms, 0x03),
        .to_date_string => try getDateStringValue(rt, ms, 0x11),
        .to_time_string => try getDateStringValue(rt, ms, 0x12),
        .to_locale_string => try getDateStringValue(rt, ms, 0x33),
        .to_locale_date_string => try getDateStringValue(rt, ms, 0x31),
        .to_locale_time_string => try getDateStringValue(rt, ms, 0x32),
        .set_year => try setYear(object, ms, args),
        // js_date_getTimezoneOffset.
        .get_timezone_offset => if (std.math.isNan(ms))
            core.JSValue.float64(std.math.nan(f64))
        else
            numberResult(@floatFromInt(getTimezoneOffsetForTime(@intFromFloat(@trunc(ms))))),
        .to_primitive, .set_year_with_captured_ms, .set_parts_with_captured_ms => error.TypeError,
        // Setters were handled by `setterSpan` above.
        .set_milliseconds, .set_seconds, .set_minutes, .set_hours, .set_date, .set_month, .set_full_year, .set_utc_milliseconds, .set_utc_seconds, .set_utc_minutes, .set_utc_hours, .set_utc_date, .set_utc_month, .set_utc_full_year => unreachable,
    };
}

pub fn methodCallArgsWithCapturedMs(object_value: core.JSValue, method: PrototypeMethod, captured_ms: f64, args: []const core.JSValue) !core.JSValue {
    const object = try expectDateObject(object_value);
    const span = setterSpan(method) orelse return error.TypeError;
    return setDateFieldBody(object, captured_ms, args, args.len, span);
}

/// set_date_field field window (quickjs.c js_date_proto_funcs magic):
/// (first_field, end_field, is_local) for the local setters and their
/// setUTC* twins; null for every other method.
/// A setter writes its arguments into the run of fields starting at
/// `first` and stopping before `end` (setHours takes hours..milliseconds,
/// setFullYear takes year..day).
const SetterSpan = struct {
    first: DateField,
    end: DateField,
    zone: TimeZone,

    /// How many arguments the setter consumes.
    fn count(self: SetterSpan) usize {
        return @intFromEnum(self.end) - @intFromEnum(self.first);
    }
};

fn setterSpan(method: PrototypeMethod) ?SetterSpan {
    return switch (method) {
        .set_milliseconds => .{ .first = .milliseconds, .end = .weekday, .zone = .local },
        .set_seconds => .{ .first = .seconds, .end = .weekday, .zone = .local },
        .set_minutes => .{ .first = .minutes, .end = .weekday, .zone = .local },
        .set_hours => .{ .first = .hours, .end = .weekday, .zone = .local },
        .set_date => .{ .first = .day, .end = .hours, .zone = .local },
        .set_month => .{ .first = .month, .end = .hours, .zone = .local },
        .set_full_year => .{ .first = .year, .end = .hours, .zone = .local },
        .set_utc_milliseconds => .{ .first = .milliseconds, .end = .weekday, .zone = .utc },
        .set_utc_seconds => .{ .first = .seconds, .end = .weekday, .zone = .utc },
        .set_utc_minutes => .{ .first = .minutes, .end = .weekday, .zone = .utc },
        .set_utc_hours => .{ .first = .hours, .end = .weekday, .zone = .utc },
        .set_utc_date => .{ .first = .day, .end = .hours, .zone = .utc },
        .set_utc_month => .{ .first = .month, .end = .hours, .zone = .utc },
        .set_utc_full_year => .{ .first = .year, .end = .hours, .zone = .utc },
        else => null,
    };
}

/// Mirrors qjs set_date_field given the captured time value
/// and (pre-coerced or raw-primitive) args. `argc` is the caller's argument
/// count: `argc == 0` sets the date to NaN even without field writes.
fn setDateFieldBody(object: *core.Object, captured_ms: f64, args: []const core.JSValue, argc: usize, span: SetterSpan) !core.JSValue {
    // A NaN time value still decomposes (from the epoch, +0000) when the
    // year is being set: setFullYear on an invalid date yields a date.
    const decomposed: ?DateFieldValues = if (getDateFields(captured_ms, span.zone)) |live|
        live
    else if (span.first == .year)
        getDateFields(0, .utc)
    else
        null;
    var fields = decomposed orelse undefined;
    var res = decomposed != null;

    // Argument coercion is observable and must be done unconditionally.
    const first = @intFromEnum(span.first);
    const n = @min(args.len, span.count());
    for (0..n) |i| {
        const a = toNumber(args[i]) orelse return error.TypeError;
        if (!std.math.isFinite(a)) res = false;
        fields.values[first + i] = @trunc(a);
    }

    if (decomposed == null) return core.JSValue.float64(std.math.nan(f64)); // thisTimeValue is NaN

    var d: f64 = std.math.nan(f64);
    if (res and argc > 0) d = setDateFields(&fields, span.zone);

    setDateValue(object, d);
    return numberResult(d);
}

fn setYear(object: *core.Object, ms: f64, args: []const core.JSValue) !core.JSValue {
    const year_number = if (args.len >= 1) (toNumber(args[0]) orelse return error.TypeError) else std.math.nan(f64);
    return setYearNumberOnObject(object, ms, year_number);
}

pub fn setYearNumber(object_value: core.JSValue, captured_ms: f64, year_number: f64) !core.JSValue {
    const object = try expectDateObject(object_value);
    return setYearNumberOnObject(object, captured_ms, year_number);
}

/// Mirrors qjs js_date_setYear: map finite years 0..99 to
/// 1900..1999, then run set_date_field with magic 0x011 (first=0, end=1,
/// local).
fn setYearNumberOnObject(object: *core.Object, ms: f64, year_number: f64) !core.JSValue {
    var y = year_number;
    if (std.math.isFinite(y)) {
        y = @trunc(y);
        if (y >= 0 and y < 100) y += 1900;
    }
    const year_args = [1]core.JSValue{core.JSValue.float64(y)};
    return setDateFieldBody(object, ms, &year_args, 1, .{ .first = .year, .end = .month, .zone = .local });
}

fn setTime(object: *core.Object, args: []const core.JSValue) !core.JSValue {
    const time_number = if (args.len >= 1) (toNumber(args[0]) orelse return error.TypeError) else std.math.nan(f64);
    const next_ms = timeClip(time_number);
    setDateValue(object, next_ms);
    return numberResult(next_ms);
}

/// Mirrors qjs get_date_field.
fn getDateFieldValue(ms: f64, field: DateField, zone: TimeZone) core.JSValue {
    const fields = getDateFields(ms, zone) orelse return core.JSValue.float64(std.math.nan(f64));
    return numberResult(fields.get(field));
}

/// Annex B getYear: the local year biased by 1900.
fn getYearValue(ms: f64) core.JSValue {
    const fields = getDateFields(ms, .local) orelse return core.JSValue.float64(std.math.nan(f64));
    return numberResult(fields.get(.year) - 1900);
}

fn utc(args: []const core.JSValue) !core.JSValue {
    // js_Date_UTC.
    if (args.len == 0) return core.JSValue.float64(std.math.nan(f64));
    var fields = try dateFieldsFromArgs(args);
    return numberResult(setDateFieldsChecked(&fields, .utc));
}

fn constructDateFromParts(args: []const core.JSValue) !f64 {
    // js_date_constructor n >= 2 branch: coerce up to 7
    // fields, then set_date_fields_checked(fields, 1) — LOCAL time.
    var fields = try dateFieldsFromArgs(args);
    return setDateFieldsChecked(&fields, .local);
}

/// Up to seven positional arguments (year .. milliseconds) over the
/// `1 January` defaults, coerced in order.
fn dateFieldsFromArgs(args: []const core.JSValue) !DateFieldValues {
    var fields = DateFieldValues.initFill(0);
    fields.set(.day, 1);
    const n = @min(args.len, settable_field_count);
    for (fields.values[0..n], args[0..n]) |*slot, arg| {
        slot.* = toNumber(arg) orelse return error.TypeError;
    }
    return fields;
}

fn parse(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue {
    // js_Date_parse ToString-coerces its argument. This pure
    // body only sees pre-coerced args (the record arm in `dateCall` runs the
    // VM ToString for objects); primitives are converted without VM re-entry.
    const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (input.isString()) return core.JSValue.float64(try parseDateString(input));
    if (input.is(.object)) return core.JSValue.float64(std.math.nan(f64));
    const string_value = try value_ops.toStringValue(rt, input);
    return core.JSValue.float64(try parseDateString(string_value));
}

// --- Host timezone offset (mirrors quickjs.c getTimezoneOffset:47454) -------

/// POSIX C `struct tm` (glibc/musl layout; POSIX.1-2024 mandates
/// `tm_gmtoff`). Windows uses the nine-field CRT layout below.
const PosixTm = extern struct {
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

const WindowsTm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
};

const HostTimeT = if (builtin.os.tag == .windows) i64 else std.c.time_t;

extern "c" fn localtime_r(timep: *const HostTimeT, result: *PosixTm) ?*PosixTm;
extern "c" fn gmtime(timer: *const HostTimeT) ?*WindowsTm;
extern "c" fn localtime(timer: *const HostTimeT) ?*WindowsTm;
extern "c" fn mktime(timeptr: *WindowsTm) HostTimeT;

/// OS dependent. `time` is in ms from 1970. Return the difference between UTC
/// time and local time at `time`, in minutes (quickjs.c getTimezoneOffset).
fn getTimezoneOffsetForTime(time_ms: i64) i32 {
    var time = @divTrunc(time_ms, 1000); // convert to seconds (C truncation)
    if (comptime builtin.os.tag == .windows) {
        // Mirrors QuickJS's _WIN32 arm exactly: reinterpret the same instant
        // once as UTC and once as local time through the Windows CRT, then
        // compare the two mktime results.
        var ti: HostTimeT = time;
        const gm_tm = gmtime(&ti) orelse return 0;
        const gm_ti = mktime(gm_tm);
        const local_tm = localtime(&ti) orelse return 0;
        const local_ti = mktime(local_tm);
        return @intCast(@divTrunc(gm_ti - local_ti, 60));
    }
    if (@sizeOf(HostTimeT) == 4) {
        // On 32-bit systems clamp to the range of `time_t` (qjs does the same).
        if (time < std.math.minInt(i32)) {
            time = std.math.minInt(i32);
        } else if (time > std.math.maxInt(i32)) {
            time = std.math.maxInt(i32);
        }
    }
    var ti: HostTimeT = @intCast(time);
    var tm: PosixTm = std.mem.zeroes(PosixTm);
    _ = localtime_r(&ti, &tm);
    return @intCast(@divTrunc(-tm.tm_gmtoff, 60));
}

// --- Calendar decomposition (mirrors quickjs.c date field helpers) ----------

const month_days = [12]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
const month_names = "JanFebMarAprMayJunJulAugSepOctNovDec";
const day_names = "SunMonTueWedThuFriSat";

/// floor_div: integer division rounding toward -Infinity.
fn floorDiv(a: i64, b: i64) i64 {
    return @divFloor(a, b);
}

/// days_from_year.
fn daysFromYear(y: i64) i64 {
    return 365 * (y - 1970) + floorDiv(y - 1969, 4) -
        floorDiv(y - 1901, 100) + floorDiv(y - 1601, 400);
}

/// days_in_year.
fn daysInYear(y: i64) i64 {
    return 365 + @as(i64, @intFromBool(@rem(y, 4) == 0)) -
        @as(i64, @intFromBool(@rem(y, 100) == 0)) +
        @as(i64, @intFromBool(@rem(y, 400) == 0));
}

/// year_from_days: return the year, update days.
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

/// The calendar decomposition qjs keeps in `double fields[9]`, by name.
/// The setters and the argument coercions still address a contiguous run
/// of the first seven by position (`values[...]`), which is why this is an
/// EnumArray rather than a struct.
const DateField = enum(u8) { year, month, day, hours, minutes, seconds, milliseconds, weekday, tz_minutes };
const DateFieldValues = std.EnumArray(DateField, f64);
/// year .. milliseconds: the fields a constructor / setter argument can set.
const settable_field_count = @intFromEnum(DateField.weekday);

const TimeZone = enum { utc, local };

/// Mirrors qjs get_date_fields; null for a NaN time value.
fn getDateFields(dval: f64, zone: TimeZone) ?DateFieldValues {
    if (std.math.isNan(dval)) return null;
    var tz: i64 = 0;
    var d: i64 = @intFromFloat(dval); // assuming -8.64e15 <= dval <= 8.64e15
    if (zone == .local) {
        tz = -@as(i64, getTimezoneOffsetForTime(d));
        d += tz * 60000;
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
    return DateFieldValues.init(.{
        .year = @floatFromInt(y),
        .month = @floatFromInt(i),
        .day = @floatFromInt(days + 1),
        .hours = @floatFromInt(h),
        .minutes = @floatFromInt(m),
        .seconds = @floatFromInt(s),
        .milliseconds = @floatFromInt(msec),
        .weekday = @floatFromInt(wd),
        .tz_minutes = @floatFromInt(tz),
    });
}

/// time_clip.
fn timeClip(value: f64) f64 {
    if (value >= -8.64e15 and value <= 8.64e15) return @trunc(value) + 0.0; // convert -0 to +0
    return std.math.nan(f64);
}

/// Mirrors qjs set_date_fields: the spec mandates `double`
/// evaluation order (volatile intermediary as in qjs, see the
/// fp-evaluation-order test262 note there).
fn setDateFields(fields: *const DateFieldValues, zone: TimeZone) f64 {
    // emulate 21.4.1.15 MakeDay ( year, month, date )
    const y = fields.get(.year);
    const m = fields.get(.month);
    const dt = fields.get(.day);
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
    var time: f64 = fields.get(.hours) * 3600000;
    temp.* = fields.get(.minutes) * 60000;
    time += temp.*;
    temp.* = fields.get(.seconds) * 1000;
    time += temp.*;
    time += fields.get(.milliseconds);

    // emulate 21.4.1.16 MakeDate ( day, time )
    temp.* = day * 86400000;
    var tv = temp.* + time; // prevent generation of FMA
    if (!std.math.isFinite(tv)) return std.math.nan(f64);

    // adjust for local time and clip
    if (zone == .local) {
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

/// Mirrors qjs set_date_fields_checked.
fn setDateFieldsChecked(fields: *DateFieldValues, zone: TimeZone) f64 {
    for (fields.values[0..settable_field_count]) |*slot| {
        if (!std.math.isFinite(slot.*)) return std.math.nan(f64);
        slot.* = @trunc(slot.*);
    }
    // Two-digit years mean 19xx (21.4.2.1 step 4 / MakeFullYear).
    const year = fields.get(.year);
    if (year >= 0 and year < 100) fields.set(.year, year + 1900);
    return setDateFields(fields, zone);
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

/// Mirrors qjs get_date_string.
/// fmt: 0 toUTCString / 1 toString / 2 toISOString / 3 toLocaleString.
/// part: 1 = date, 2 = time, 3 = both. NaN: fmt 2 raises RangeError, others
/// produce "Invalid Date".
fn getDateStringValue(rt: *core.JSRuntime, ms: f64, magic: u32) !core.JSValue {
    const fmt = (magic >> 4) & 0x0F;
    const part = magic & 0x0F;

    const zone: TimeZone = if ((fmt & 1) == 1) .local else .utc;
    const fields = getDateFields(ms, zone) orelse {
        if (fmt == 2) return error.RangeError; // "Date value is NaN"
        const str = try core.string.String.createUtf8(rt, "Invalid Date");
        return str.value();
    };

    // Non-negative print operands are unsigned (Zig 0.16 std.fmt zero-fill
    // prints an explicit '+' for signed integers).
    const y: i64 = @intFromFloat(fields.get(.year));
    const mon: usize = @intFromFloat(fields.get(.month));
    const d: u32 = @intFromFloat(fields.get(.day));
    const h: u32 = @intFromFloat(fields.get(.hours));
    const m: u32 = @intFromFloat(fields.get(.minutes));
    const s: u32 = @intFromFloat(fields.get(.seconds));
    const msec: u32 = @intFromFloat(fields.get(.milliseconds));
    const wd: usize = @intFromFloat(fields.get(.weekday));
    const tz: i64 = @intFromFloat(fields.get(.tz_minutes));

    var buffer: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);

    writeDateString(&w, fmt, part, y, mon, d, h, m, s, msec, wd, tz) catch unreachable;
    const str = try core.string.String.createUtf8(rt, w.buffered());
    return str.value();
}

/// Every Date string form is shorter than the fixed 64-byte caller buffer, so
/// the writer's capacity error is a local invariant rather than an engine
/// transport error.
fn writeDateString(
    w: *std.Io.Writer,
    fmt: u32,
    part: u32,
    y: i64,
    mon: usize,
    d: u32,
    h: u32,
    m: u32,
    s: u32,
    msec: u32,
    wd: usize,
    initial_tz: i64,
) std.Io.Writer.Error!void {
    var tz = initial_tz;

    if (part & 1 != 0) { // date part
        switch (fmt) {
            0 => {
                try w.print("{s}, {d:0>2} {s} ", .{ dayName(wd), d, monthName(mon) });
                try writeYearPadded4(w, y);
                try w.writeByte(' ');
            },
            1 => {
                try w.print("{s} {s} {d:0>2} ", .{ dayName(wd), monthName(mon), d });
                try writeYearPadded4(w, y);
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
                try writeYearPadded4(w, y);
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
}

// --- Date string parsing (mirrors quickjs.c js_Date_parse:55907) ------------

/// js_Date_parse string -> byte-array conversion: 127-byte
/// truncation, U+2212 -> '-', any other unit > 255 -> 'x'.
fn parseDateString(value: core.JSValue) !f64 {
    const string_value = value.asStringBody() orelse return std.math.nan(f64);
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
    const parsed = parseIsoDateString(sp) orelse parseLenientDateString(sp) orelse return std.math.nan(f64);
    const f = parsed.fields;
    // check field maximum values
    var valid = f.month <= 11 and f.day <= 31 and f.hour <= 24 and f.minute <= 59 and f.second <= 59;
    // special case 24:00:00.000
    if (f.hour == 24 and (f.minute | f.second | f.millisecond) != 0) valid = false;
    if (!valid) return std.math.nan(f64);
    const fields = DateFieldValues.init(.{
        .year = @floatFromInt(f.year),
        .month = @floatFromInt(f.month),
        .day = @floatFromInt(f.day),
        .hours = @floatFromInt(f.hour),
        .minutes = @floatFromInt(f.minute),
        .seconds = @floatFromInt(f.second),
        .milliseconds = @floatFromInt(f.millisecond),
        .weekday = 0,
        .tz_minutes = 0,
    });
    const zone: TimeZone = if (parsed.is_local) .local else .utc;
    return setDateFields(&fields, zone) - @as(f64, @floatFromInt(f.tz_offset_minutes)) * 60000;
}

/// Calendar fields as `js_Date_parse` assembles them (month is 0-based once
/// a parser returns), plus the explicit UTC offset when the text carried one.
const DateFields = struct {
    year: i32,
    month: i32,
    day: i32,
    hour: i32 = 0,
    minute: i32 = 0,
    second: i32 = 0,
    millisecond: i32 = 0,
    tz_offset_minutes: i32 = 0,
};

const ParsedDate = struct {
    fields: DateFields,
    /// The text named no zone, so the fields are local time.
    is_local: bool,
};

/// Read position over a NUL-terminated date string. Readers that can fail
/// leave `pos` where it was.
const Cursor = struct {
    text: [:0]const u8,
    pos: usize = 0,

    fn peek(self: Cursor) u8 {
        return self.text[self.pos];
    }

    fn atEnd(self: Cursor) bool {
        return self.peek() == 0;
    }

    fn skipChar(self: *Cursor, c: u8) bool {
        if (self.peek() != c) return false;
        self.pos += 1;
        return true;
    }

    /// Skip spaces; returns the next character.
    fn skipSpaces(self: *Cursor) u8 {
        while (self.peek() == ' ') self.pos += 1;
        return self.peek();
    }

    /// Skip dashes, slashes, dots and commas.
    fn skipSeparators(self: *Cursor) void {
        while (true) {
            switch (self.peek()) {
                '-', '/', '.', ',' => self.pos += 1,
                else => return,
            }
        }
    }

    /// Skip a word, stopping at NUL or any character in `stoplist`.
    fn skipUntil(self: *Cursor, stoplist: []const u8) void {
        while (!self.atEnd() and std.mem.indexOfScalar(u8, stoplist, self.peek()) == null) self.pos += 1;
    }

    /// A run of `min_digits..max_digits` decimal digits (`max_digits == 0`:
    /// no maximum, but at most nine digits are accepted).
    fn digits(self: *Cursor, min_digits: usize, max_digits: usize) ?i32 {
        var value: i32 = 0;
        var p = self.pos;
        while (true) {
            const c = self.text[p];
            if (c < '0' or c > '9') break;
            if (value >= 100000000) return null; // arbitrary limit to 9 digits
            value = value * 10 + @as(i32, c - '0');
            p += 1;
            if (p - self.pos == max_digits) break;
        }
        if (p - self.pos < min_digits) return null;
        self.pos = p;
        return value;
    }

    /// An optional `.` / `,` fraction, truncated to milliseconds; the
    /// separator is consumed only when digits follow it.
    fn milliseconds(self: *Cursor) ?i32 {
        const c = self.peek();
        if (c != '.' and c != ',') return null;
        var p = self.pos + 1;
        const digits_start = p;
        var mul: i32 = 100;
        var msec: i32 = 0;
        while (self.text[p] >= '0' and self.text[p] <= '9') {
            msec += @as(i32, self.text[p] - '0') * mul;
            mul = @divTrunc(mul, 10);
            p += 1;
            if (p - digits_start == 9) break;
        }
        if (p == digits_start) return null;
        self.pos = p;
        return msec;
    }

    /// `Z`, or `[+-]HH`, `[+-]HHmm`, `[+-]HH:mm` (longer digit runs are
    /// truncated from the right); strict mode rejects bare `[+-]HH`.
    fn tzOffset(self: *Cursor, strict: bool) ?i32 {
        var c = self.*;
        const sgn = c.peek();
        c.pos += 1;
        var tz: i32 = 0;
        if (sgn == '+' or sgn == '-') {
            const digits_start = c.pos;
            var hh = c.digits(1, 0) orelse return null;
            var n = c.pos - digits_start;
            if (strict and n != 2 and n != 4) return null;
            while (n > 4) {
                n -= 2;
                hh = @divTrunc(hh, 100);
            }
            var mm: i32 = 0;
            if (n > 2) {
                mm = @rem(hh, 100);
                hh = @divTrunc(hh, 100);
            } else if (c.skipChar(':')) {
                // optional separator
                mm = c.digits(2, 2) orelse return null;
            } else if (strict) {
                return null; // [+-]HH is not accepted in strict mode
            }
            if (hh > 23 or mm > 59) return null;
            tz = hh * 60 + mm;
            if (sgn != '+') tz = -tz;
        } else if (sgn != 'Z') {
            return null;
        }
        self.* = c;
        return tz;
    }

    /// Case-insensitive keyword match.
    fn matchLiteral(self: *Cursor, keyword: []const u8) bool {
        var p = self.pos;
        for (keyword) |ch| {
            if (upperAscii(self.text[p]) != upperAscii(ch)) return false;
            p += 1;
        }
        self.pos = p;
        return true;
    }

    /// Three-letter month abbreviation, 1-based.
    fn month(self: *Cursor) ?i32 {
        const n = findAbbrev(self.text, self.pos, month_names, 12) orelse return null;
        self.pos += 3;
        return @intCast(n + 1);
    }

    /// A time-zone abbreviation from `js_tzabbr`, as minutes east of UTC.
    fn tzAbbr(self: *Cursor) ?i32 {
        for (js_tzabbr) |abbr| {
            if (self.matchLiteral(abbr.name)) return abbr.offset;
        }
        return null;
    }
};

/// upper_ascii.
fn upperAscii(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 'a' + 'A' else c;
}

/// find_abbrev: 3-letter abbreviation lookup.
fn findAbbrev(sp: [:0]const u8, p: usize, list: []const u8, count: usize) ?usize {
    for (0..count) |n| {
        var i: usize = 0;
        while (true) : (i += 1) {
            if (upperAscii(sp[p + i]) != upperAscii(list[n * 3 + i])) break;
            if (i == 2) return n;
        }
    }
    return null;
}

/// js_date_parse_isostring: parse the toISOString format.
/// A date-time without a timezone offset is LOCAL time (is_local at the
/// 'T'; an explicit offset/Z clears it); a date-only form stays UTC.
fn parseIsoDateString(sp: [:0]const u8) ?ParsedDate {
    var c = Cursor{ .text = sp };
    // initialize fields to the beginning of the Epoch
    var f = DateFields{ .year = 0, .month = 0, .day = 1 };
    var is_local = false;

    // year is either yyyy digits or [+-]yyyyyy
    const sgn = c.peek();
    if (sgn == '-' or sgn == '+') {
        c.pos += 1;
        f.year = c.digits(6, 6) orelse return null;
        if (sgn == '-') {
            if (f.year == 0) return null; // reject -000000
            f.year = -f.year;
        }
    } else {
        f.year = c.digits(4, 4) orelse return null;
    }
    if (c.skipChar('-')) {
        f.month = c.digits(2, 2) orelse return null;
        if (f.month < 1) return null;
        f.month -= 1;
        if (c.skipChar('-')) {
            f.day = c.digits(2, 2) orelse return null;
            if (f.day < 1) return null;
        }
    }
    if (c.skipChar('T')) {
        is_local = true;
        const time = blk: {
            const hour = c.digits(2, 2) orelse break :blk null;
            if (!c.skipChar(':')) break :blk null;
            const minute = c.digits(2, 2) orelse break :blk null;
            break :blk .{ hour, minute };
        };
        if (time) |hm| {
            f.hour, f.minute = hm;
        } else {
            // A malformed time still claims the string for this format:
            // an out-of-range hour makes the caller's range check fail
            // instead of letting the lenient parser try again.
            f.hour = 100;
            return .{ .fields = f, .is_local = is_local };
        }
        if (c.skipChar(':')) {
            f.second = c.digits(2, 2) orelse return null;
            f.millisecond = c.milliseconds() orelse 0;
        }
    }
    // parse the time zone offset if present: [+-]HH:mm or [+-]HHmm
    if (!c.atEnd()) {
        is_local = false;
        f.tz_offset_minutes = c.tzOffset(true) orelse return null;
    }
    // error if extraneous characters
    if (!c.atEnd()) return null;
    return .{ .fields = f, .is_local = is_local };
}

/// js_tzabbr.
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

fn adjustTwoDigitYear(v: i32) i32 {
    return v + @as(i32, if (v < 100) 1900 else 0) + @as(i32, if (v < 50) 100 else 0);
}

/// js_date_parse_otherstring: parse toString, toUTCString
/// and other lenient formats (month names, slash dates, tz abbreviations,
/// AM/PM, parenthesized phrases, skipped words).
fn parseLenientDateString(sp: [:0]const u8) ?ParsedDate {
    var c = Cursor{ .text = sp };
    var num: [3]i32 = undefined;
    var has_year = false;
    var has_mon = false;
    var has_time = false;
    var num_index: usize = 0;

    // initialize fields to the beginning of 2001-01-01 (month 1-based until
    // the end)
    var f = DateFields{ .year = 2001, .month = 1, .day = 1 };
    var is_local = true;

    while (c.skipSpaces() != 0) {
        const word_start = c.pos;
        const ch = c.peek();
        if (ch == '+' or ch == '-') {
            if (has_time) if (c.tzOffset(false)) |tz| {
                f.tz_offset_minutes = tz;
                is_local = false;
                c.skipSeparators();
                continue;
            };
            c.pos += 1;
            if (c.digits(1, 0)) |digits| {
                var val = digits;
                if (ch == '-') {
                    if (val == 0) return null;
                    val = -val;
                }
                f.year = val;
                has_year = true;
            }
        } else if (c.digits(1, 0)) |val| {
            if (c.skipChar(':')) {
                // time part
                f.hour = val;
                f.minute = c.digits(1, 2) orelse return null;
                if (c.skipChar(':')) {
                    f.second = c.digits(1, 2) orelse return null;
                    f.millisecond = c.milliseconds() orelse 0;
                }
                has_time = true;
                if (c.peek() == '+' or c.peek() == '-') {
                    if (c.tzOffset(false)) |tz| {
                        f.tz_offset_minutes = tz;
                        is_local = false;
                    }
                }
            } else if (c.pos - word_start > 2 and !has_year) {
                f.year = val;
                has_year = true;
            } else if ((val < 1 or val > 31) and !has_year) {
                f.year = adjustTwoDigitYear(val);
                has_year = true;
            } else {
                if (num_index == 3) return null;
                num[num_index] = val;
                num_index += 1;
            }
        } else if (c.month()) |month| {
            f.month = month;
            has_mon = true;
            c.skipUntil("0123456789 -/(");
        } else if (has_time and c.matchLiteral("PM")) {
            if (f.hour < 12) f.hour += 12;
            continue;
        } else if (has_time and c.matchLiteral("AM")) {
            if (f.hour == 12) f.hour -= 12;
            continue;
        } else if (c.tzAbbr()) |tz| {
            f.tz_offset_minutes = tz;
            is_local = false;
            continue;
        } else if (ch == '(') { // skip parenthesized phrase
            var level: i32 = 0;
            while (!c.atEnd()) {
                const inner = c.peek();
                c.pos += 1;
                level += @intFromBool(inner == '(');
                level -= @intFromBool(inner == ')');
                if (level == 0) break;
            }
            if (level > 0) return null;
        } else if (ch == ')') {
            return null;
        } else {
            if (has_year or has_mon or has_time or num_index > 0) return null;
            // skip a word
            c.skipUntil(" -/(");
        }
        c.skipSeparators();
    }
    if (num_index + @as(usize, @intFromBool(has_year)) + @as(usize, @intFromBool(has_mon)) > 3) return null;

    switch (num_index) {
        0 => if (!has_year) return null,
        1 => {
            if (has_mon) {
                f.day = num[0];
            } else {
                f.month = num[0];
            }
        },
        2 => {
            if (has_year) {
                f.month = num[0];
                f.day = num[1];
            } else if (has_mon) {
                f.year = adjustTwoDigitYear(num[1]);
                f.day = num[0];
            } else {
                f.month = num[0];
                f.day = num[1];
            }
        },
        3 => {
            f.year = adjustTwoDigitYear(num[2]);
            f.month = num[0];
            f.day = num[1];
        },
        else => return null,
    }
    if (f.month < 1 or f.day < 1) return null;
    f.month -= 1;
    return .{ .fields = f, .is_local = is_local };
}

// --- Object plumbing ---------------------------------------------------------

fn expectDateObject(value: core.JSValue) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.is(.object)) return error.TypeError;
    const object = core.Object.fromHeader(header);
    if (object.class_id != core.class.ids.date) return error.TypeError;
    return object;
}

fn setDateValue(object: *core.Object, ms: f64) void {
    object.objectDataSlot().* = core.JSValue.float64(ms);
}

/// CLI print inspector hook (qjs js_print_object JS_CLASS_DATE arm,
/// quickjs.c: `get_date_string(..., 0x23)`): the toISOString text of a
/// Date object with no side effect, or null when the time value is NaN (qjs
/// then falls back to the generic object dump).
pub fn isoStringForInspector(rt: *core.JSRuntime, object: *const core.Object) !?core.JSValue {
    const ms = dateValue(object) catch return null;
    if (std.math.isNan(ms)) return null;
    return try getDateStringValue(rt, ms, 0x23);
}

fn dateValue(object: *const core.Object) !f64 {
    const value = object.objectData() orelse return error.TypeError;
    return numberValue(value) orelse error.TypeError;
}

fn dateObjectFromValue(value: core.JSValue) ?*core.Object {
    const header = value.refHeader() orelse return null;
    if (!value.is(.object)) return null;
    const object = core.Object.fromHeader(header);
    if (object.class_id != core.class.ids.date) return null;
    return object;
}

fn numberValue(value: core.JSValue) ?f64 {
    if (value.is(.int)) return @floatFromInt(value.as(.int).?);
    if (value.is(.float64)) return value.as(.float64).?;
    return null;
}

fn numberResult(value: f64) core.JSValue {
    if (std.math.isFinite(value) and @floor(value) == value and value >= @as(f64, @floatFromInt(std.math.minInt(i32))) and value <= @as(f64, @floatFromInt(std.math.maxInt(i32))) and !std.math.isNegativeZero(value)) {
        return core.JSValue.int32(@intFromFloat(value));
    }
    return core.JSValue.float64(value);
}

fn toNumber(value: core.JSValue) ?f64 {
    if (value.is(.symbol)) return null;
    // JS_ToFloat64 throws "cannot convert bigint to number" (qjs
    // js_date_constructor/set_date_field/js_Date_UTC all coerce through it).
    if (value.isBigInt()) return null;
    if (numberValue(value)) |number| return number;
    if (value.as(.boolean)) |bool_value| return if (bool_value) 1 else 0;
    if (value.is(.null_value)) return 0;
    if (value.is(.undefined_value)) return std.math.nan(f64);
    if (value.isString()) {
        var scratch: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&scratch);
        appendStringValueAscii(&writer, value) catch return std.math.nan(f64);
        return core.value_format.parseJsNumber(writer.buffered());
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

/// Golden parses captured from the pre-Cursor port of qjs `js_Date_parse`
/// (2026-09-20); the two parsers must keep producing exactly these fields.
const date_parse_cases = [_]struct { []const u8, ?ParsedDate }{
    .{ "2024-03-05", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 0, .minute = 0, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = false } },
    .{ "2024-03", .{ .fields = .{ .year = 2024, .month = 2, .day = 1, .hour = 0, .minute = 0, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = false } },
    .{ "2024", .{ .fields = .{ .year = 2024, .month = 0, .day = 1, .hour = 0, .minute = 0, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = false } },
    .{ "+002024-03-05", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 0, .minute = 0, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = false } },
    .{ "-000001-01-01", .{ .fields = .{ .year = -1, .month = 0, .day = 1, .hour = 0, .minute = 0, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = false } },
    .{ "-000000-01-01", null },
    .{ "2024-03-05T10:20", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 10, .minute = 20, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "2024-03-05T10:20:30", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 10, .minute = 20, .second = 30, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "2024-03-05T10:20:30.123", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 10, .minute = 20, .second = 30, .millisecond = 123, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "2024-03-05T10:20:30,5", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 10, .minute = 20, .second = 30, .millisecond = 500, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "2024-03-05T10:20:30Z", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 10, .minute = 20, .second = 30, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = false } },
    .{ "2024-03-05T10:20:30+02:00", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 10, .minute = 20, .second = 30, .millisecond = 0, .tz_offset_minutes = 120 }, .is_local = false } },
    .{ "2024-03-05T10:20:30-0530", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 10, .minute = 20, .second = 30, .millisecond = 0, .tz_offset_minutes = -330 }, .is_local = false } },
    .{ "2024-03-05T10:20:30+02", null },
    .{ "2024-03-05T10", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 100, .minute = 0, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "2024-03-05T24:00:00", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 24, .minute = 0, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "2024-03-05T24:00:01", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 24, .minute = 0, .second = 1, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "2024-13-05", .{ .fields = .{ .year = 2024, .month = 12, .day = 5, .hour = 0, .minute = 0, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = false } },
    .{ "2024-00-05", null },
    .{ "2024-03-00", null },
    .{ "2024-03-05x", null },
    .{ "Tue Mar 05 2024 10:20:30 GMT+0200 (Eastern European Standard Time)", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 10, .minute = 20, .second = 30, .millisecond = 0, .tz_offset_minutes = 120 }, .is_local = false } },
    .{ "Tue, 05 Mar 2024 10:20:30 GMT", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 10, .minute = 20, .second = 30, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = false } },
    .{ "Mar 5, 2024", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 0, .minute = 0, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "March 5, 2024 10:20 PM", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 22, .minute = 20, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "5 Mar 2024 12:00 AM", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 0, .minute = 0, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "3/5/2024", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 0, .minute = 0, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "3/5/24", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 0, .minute = 0, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "3/5/49", .{ .fields = .{ .year = 2049, .month = 2, .day = 5, .hour = 0, .minute = 0, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "3/5/50", .{ .fields = .{ .year = 1950, .month = 2, .day = 5, .hour = 0, .minute = 0, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "Mar 5 2024 10:20:30 EST", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 10, .minute = 20, .second = 30, .millisecond = 0, .tz_offset_minutes = -300 }, .is_local = false } },
    .{ "Mar 5 2024 10:20:30 PST", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 10, .minute = 20, .second = 30, .millisecond = 0, .tz_offset_minutes = -480 }, .is_local = false } },
    .{ "Mar 5 2024 10:20:30 CEST", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 10, .minute = 20, .second = 30, .millisecond = 0, .tz_offset_minutes = 120 }, .is_local = false } },
    .{ "Mar 5 2024 10:20:30 UTC", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 10, .minute = 20, .second = 30, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = false } },
    .{ "Mar 5 2024 10:20:30 Z", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 10, .minute = 20, .second = 30, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = false } },
    .{ "Mar 5 2024 10:20:30 +0530", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 10, .minute = 20, .second = 30, .millisecond = 0, .tz_offset_minutes = 330 }, .is_local = false } },
    .{ "Mar 5 2024 10:20:30 -05", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 10, .minute = 20, .second = 30, .millisecond = 0, .tz_offset_minutes = -300 }, .is_local = false } },
    .{ "Mar 5 2024 10:20:30.25", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 10, .minute = 20, .second = 30, .millisecond = 250, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "Mar 5, 2024 (comment (nested)) 10:20", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 10, .minute = 20, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "Mar 5, 2024 (unclosed", null },
    .{ "Mar 5, 2024 )", null },
    .{ "Mar 5 2024 10:20:30 PM", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 22, .minute = 20, .second = 30, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "Mar 5 2024 12:20:30 AM", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 0, .minute = 20, .second = 30, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "Mar 5 2024 13:20:30 PM", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 13, .minute = 20, .second = 30, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "2024 Mar 5", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 0, .minute = 0, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "5 2024 Mar", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 0, .minute = 0, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "Mar 5", .{ .fields = .{ .year = 2001, .month = 2, .day = 5, .hour = 0, .minute = 0, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "Mar", null },
    .{ "foo Mar 5 2024", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 0, .minute = 0, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "Mar 5 2024 foo", null },
    .{ "12 Mar 2024", .{ .fields = .{ .year = 2024, .month = 2, .day = 12, .hour = 0, .minute = 0, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "32 Mar 2024", .{ .fields = .{ .year = 2032, .month = 2, .day = 2024, .hour = 0, .minute = 0, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "Mar 32 2024", .{ .fields = .{ .year = 2032, .month = 2, .day = 2024, .hour = 0, .minute = 0, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "1 2 3 4", null },
    .{ "Mar 5 2024 10:20:30 GMT+1", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 10, .minute = 20, .second = 30, .millisecond = 0, .tz_offset_minutes = 60 }, .is_local = false } },
    .{ "Mar 5 2024 10:20:30 GMT+12345", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 10, .minute = 20, .second = 30, .millisecond = 0, .tz_offset_minutes = 83 }, .is_local = false } },
    .{ "Mar 5 2024 10:20:30 GMT+123456", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 10, .minute = 20, .second = 30, .millisecond = 0, .tz_offset_minutes = 754 }, .is_local = false } },
    .{ "2024-03-05 10:20:30", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 10, .minute = 20, .second = 30, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "20240305", .{ .fields = .{ .year = 20240305, .month = 0, .day = 1, .hour = 0, .minute = 0, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "2024-3-5", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 0, .minute = 0, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "", null },
    .{ "   ", null },
    .{ "Mar 5 2024 10:20:30+02:00", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 10, .minute = 20, .second = 30, .millisecond = 0, .tz_offset_minutes = 120 }, .is_local = false } },
    .{ "Mar 5 2024 10:20:30 +02:00", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 10, .minute = 20, .second = 30, .millisecond = 0, .tz_offset_minutes = 120 }, .is_local = false } },
    .{ "+2024", .{ .fields = .{ .year = 2024, .month = 0, .day = 1, .hour = 0, .minute = 0, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "-2024", .{ .fields = .{ .year = -2024, .month = 0, .day = 1, .hour = 0, .minute = 0, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "-0", null },
    .{ "Tue Mar 05 2024", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 0, .minute = 0, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "Tuesday, March 5, 2024", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 0, .minute = 0, .second = 0, .millisecond = 0, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "Mar 5 2024 10:20:30.1234567890", null },
    .{ "2024-03-05T10:20:30.123456789", .{ .fields = .{ .year = 2024, .month = 2, .day = 5, .hour = 10, .minute = 20, .second = 30, .millisecond = 123, .tz_offset_minutes = 0 }, .is_local = true } },
    .{ "2024-03-05T10:20:30.", null },
    .{ "2024-03-05T10:20:30Zx", null },
    .{ "2024-03-05T10:20:30+02:0", null },
    .{ "2024-03-05T10:20:30+2:00", null },
    .{ "1e3", null },
};

test "Date.parse: ISO and lenient parsers reproduce the golden fields" {
    for (date_parse_cases) |case| {
        const text, const expected = case;
        var buf: [128:0]u8 = undefined;
        @memcpy(buf[0..text.len], text);
        buf[text.len] = 0;
        const sp: [:0]const u8 = buf[0..text.len :0];
        const actual = parseIsoDateString(sp) orelse parseLenientDateString(sp);
        try std.testing.expectEqualDeep(expected, actual);
    }
}

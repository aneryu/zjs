const core = @import("../core/root.zig");
const std = @import("std");
const builtin_dispatch = @import("../exec/builtin_dispatch.zig");
const builtin_glue = @import("../exec/builtin_glue.zig");
const coercion_ops = @import("../exec/coercion_ops.zig");
const exceptions = @import("../exec/exceptions.zig");
const object_ops = @import("../exec/object_ops.zig");

const HostError = exceptions.HostError;
const InternalCall = core.host_function.InternalCall;

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
    // through the table here so it never names `builtins.date.*` directly. It is
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
        return builtin_glue.qjsDateToPrimitiveNativeRecord(ctx, output, active_global, host_call.this_value, args, caller_function, caller_frame);
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
        if (decodePrototypeMethodId(id)) |method_id| {
            break :blk methodCallArgs(rt, this_value, method_id, args);
        }
        // `StaticMethod.{utc,parse,now}`: the enum values (1/2/3) are the
        // `staticCall` method selectors; the glue pre-coerced any args.
        break :blk staticCall(rt, id, args);
    };
    return result catch |err| return @as(HostError, @errorCast(err));
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
    if (std.mem.eql(u8, name, "getUTCDay") or std.mem.eql(u8, name, "getDay")) return @intFromEnum(PrototypeMethod.get_day);
    if (std.mem.eql(u8, name, "toString") or std.mem.eql(u8, name, "toLocaleString")) return @intFromEnum(PrototypeMethod.to_string);
    if (std.mem.eql(u8, name, "toUTCString") or std.mem.eql(u8, name, "toGMTString")) return @intFromEnum(PrototypeMethod.to_utc_string);
    if (std.mem.eql(u8, name, "toDateString") or std.mem.eql(u8, name, "toLocaleDateString")) return @intFromEnum(PrototypeMethod.to_date_string);
    if (std.mem.eql(u8, name, "toTimeString") or std.mem.eql(u8, name, "toLocaleTimeString")) return @intFromEnum(PrototypeMethod.to_time_string);
    if (std.mem.eql(u8, name, "getYear")) return @intFromEnum(PrototypeMethod.get_year);
    if (std.mem.eql(u8, name, "setYear")) return @intFromEnum(PrototypeMethod.set_year);
    if (std.mem.eql(u8, name, "setTime")) return @intFromEnum(PrototypeMethod.set_time);
    if (std.mem.eql(u8, name, "setMilliseconds") or std.mem.eql(u8, name, "setUTCMilliseconds")) return @intFromEnum(PrototypeMethod.set_milliseconds);
    if (std.mem.eql(u8, name, "setSeconds") or std.mem.eql(u8, name, "setUTCSeconds")) return @intFromEnum(PrototypeMethod.set_seconds);
    if (std.mem.eql(u8, name, "setMinutes") or std.mem.eql(u8, name, "setUTCMinutes")) return @intFromEnum(PrototypeMethod.set_minutes);
    if (std.mem.eql(u8, name, "setHours") or std.mem.eql(u8, name, "setUTCHours")) return @intFromEnum(PrototypeMethod.set_hours);
    if (std.mem.eql(u8, name, "setDate") or std.mem.eql(u8, name, "setUTCDate")) return @intFromEnum(PrototypeMethod.set_date);
    if (std.mem.eql(u8, name, "setMonth") or std.mem.eql(u8, name, "setUTCMonth")) return @intFromEnum(PrototypeMethod.set_month);
    if (std.mem.eql(u8, name, "setFullYear") or std.mem.eql(u8, name, "setUTCFullYear")) return @intFromEnum(PrototypeMethod.set_full_year);
    return null;
}

// Pure id<->id mappings relocated to engine core (`core/host_function.zig`,
// `builtin_method_id_lookup.date`) in Phase 6b-3 STEP 5; re-exported here so the
// dispatch side keeps the original names.
pub const decodePrototypeMethodId = core.host_function.builtin_method_id_lookup.date.decodePrototypeMethodId;
pub const encodePrototypeMethodId = core.host_function.builtin_method_id_lookup.date.encodePrototypeMethodId;

pub fn dayFromTime(ms: i64) i64 {
    return @divFloor(ms, ms_per_day);
}

pub fn timeWithinDay(ms: i64) i64 {
    return @mod(ms, ms_per_day);
}

/// QuickJS source map: Date as a function. This is the current narrow Date
/// subset used by transitional `date_call` bytecode.
pub fn call(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue {
    _ = args;
    return dateString(rt, currentTimeMs(), .local);
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

/// QuickJS source map: Date.UTC / Date.parse / Date.now. This is still a narrow
/// builtin implementation; unsupported Date shapes stay on transitional paths.
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
    return switch (method) {
        1, 2 => numberResult(ms),
        24 => try setTime(rt, object, args),
        3 => dateFullYear(ms),
        4 => dateField(ms, .month),
        5 => dateField(ms, .day),
        6 => dateField(ms, .hour),
        7 => dateField(ms, .minute),
        8 => dateField(ms, .second),
        9 => dateField(ms, .millis),
        10 => try isoString(rt, ms, true),
        11 => try jsonString(rt, ms),
        20 => try dateString(rt, ms, .local),
        21 => try dateString(rt, ms, .utc),
        12...19 => utcDateField(ms, method),
        22 => dateYear(ms),
        23 => try setYear(rt, object, ms, args),
        25 => try setDateParts(rt, object, ms, args, .millis),
        26 => try setDateParts(rt, object, ms, args, .second),
        27 => try setDateParts(rt, object, ms, args, .minute),
        28 => try setDateParts(rt, object, ms, args, .hour),
        29 => try setDateParts(rt, object, ms, args, .day),
        30 => try setDateParts(rt, object, ms, args, .month),
        31 => try setDateParts(rt, object, ms, args, .year),
        32 => if (std.math.isFinite(ms)) core.JSValue.int32(0) else core.JSValue.float64(std.math.nan(f64)),
        33 => try dateString(rt, ms, .date),
        34 => try dateString(rt, ms, .time),
        else => error.TypeError,
    };
}

pub fn methodCallArgsWithCapturedMs(rt: *core.JSRuntime, object_value: core.JSValue, method: u32, captured_ms: f64, args: []const core.JSValue) !core.JSValue {
    const object = try expectDateObject(object_value);
    return switch (method) {
        25 => try setDateParts(rt, object, captured_ms, args, .millis),
        26 => try setDateParts(rt, object, captured_ms, args, .second),
        27 => try setDateParts(rt, object, captured_ms, args, .minute),
        28 => try setDateParts(rt, object, captured_ms, args, .hour),
        29 => try setDateParts(rt, object, captured_ms, args, .day),
        30 => try setDateParts(rt, object, captured_ms, args, .month),
        31 => try setDateParts(rt, object, captured_ms, args, .year),
        else => error.TypeError,
    };
}

const DateSetField = enum { millis, second, minute, hour, day, month, year };
const DateGetField = enum { millis, second, minute, hour, day, month };
const DateStringKind = enum { local, utc, date, time };

fn dateFullYear(ms: f64) core.JSValue {
    if (!std.math.isFinite(ms)) return core.JSValue.float64(std.math.nan(f64));
    const parts = utcDateParts(@intFromFloat(ms));
    return core.JSValue.int32(@intCast(parts.year));
}

fn dateYear(ms: f64) core.JSValue {
    if (!std.math.isFinite(ms)) return core.JSValue.float64(std.math.nan(f64));
    const parts = utcDateParts(@intFromFloat(ms));
    return core.JSValue.int32(@intCast(parts.year - 1900));
}

fn dateField(ms: f64, field: DateGetField) core.JSValue {
    if (!std.math.isFinite(ms)) return core.JSValue.float64(std.math.nan(f64));
    const parts = utcDateParts(@intFromFloat(ms));
    const out: i32 = switch (field) {
        .millis => @intCast(parts.millis),
        .second => @intCast(parts.second),
        .minute => @intCast(parts.minute),
        .hour => @intCast(parts.hour),
        .day => @intCast(parts.day),
        .month => @intCast(parts.month - 1),
    };
    return core.JSValue.int32(out);
}

fn setYear(rt: *core.JSRuntime, object: *core.Object, ms: f64, args: []const core.JSValue) !core.JSValue {
    const year_number = if (args.len >= 1) (toNumber(args[0]) orelse return error.TypeError) else std.math.nan(f64);
    return setYearNumberOnObject(rt, object, ms, year_number);
}

pub fn setYearNumber(rt: *core.JSRuntime, object_value: core.JSValue, captured_ms: f64, year_number: f64) !core.JSValue {
    const object = try expectDateObject(object_value);
    return setYearNumberOnObject(rt, object, captured_ms, year_number);
}

fn setYearNumberOnObject(rt: *core.JSRuntime, object: *core.Object, ms: f64, year_number: f64) !core.JSValue {
    if (std.math.isNan(year_number)) {
        try setDateValue(rt, object, std.math.nan(f64));
        return core.JSValue.float64(std.math.nan(f64));
    }
    if (!std.math.isFinite(year_number)) {
        try setDateValue(rt, object, std.math.nan(f64));
        return core.JSValue.float64(std.math.nan(f64));
    }

    const integer_year_float = toInteger(year_number);
    var year: i64 = @intFromFloat(integer_year_float);
    if (year >= 0 and year <= 99) year += 1900;

    const base_ms: f64 = if (std.math.isFinite(ms)) ms else 0;
    const parts = utcDateParts(@intFromFloat(base_ms));
    const next_ms = timeClip(makeUtcMs(year, parts.month - 1, parts.day, parts.hour, parts.minute, parts.second, parts.millis));
    try setDateValue(rt, object, next_ms);
    return numberResult(next_ms);
}

fn setTime(rt: *core.JSRuntime, object: *core.Object, args: []const core.JSValue) !core.JSValue {
    const time_number = if (args.len >= 1) (toNumber(args[0]) orelse return error.TypeError) else std.math.nan(f64);
    const next_ms = timeClip(time_number);
    try setDateValue(rt, object, next_ms);
    return numberResult(next_ms);
}

fn setDateParts(rt: *core.JSRuntime, object: *core.Object, ms: f64, args: []const core.JSValue, field: DateSetField) !core.JSValue {
    const had_finite_time = std.math.isFinite(ms);
    const parts = if (had_finite_time) utcDateParts(@intFromFloat(ms)) else utcDateParts(0);
    const first = if (args.len >= 1) (toNumber(args[0]) orelse return error.TypeError) else std.math.nan(f64);
    const first_integer = dateSetterInteger(first) orelse {
        return dateSetNaNResult(rt, object, had_finite_time, field);
    };

    var year: f64 = @floatFromInt(parts.year);
    var month: f64 = @floatFromInt(parts.month - 1);
    var day: f64 = @floatFromInt(parts.day);
    var hour: f64 = @floatFromInt(parts.hour);
    var minute: f64 = @floatFromInt(parts.minute);
    var second: f64 = @floatFromInt(parts.second);
    var millis: f64 = @floatFromInt(parts.millis);

    switch (field) {
        .millis => millis = first_integer,
        .second => {
            second = first_integer;
            if (try providedNumber(args, 1)) |number| {
                millis = dateSetterInteger(number) orelse return dateSetNaNResult(rt, object, had_finite_time, field);
            }
        },
        .minute => {
            minute = first_integer;
            if (try providedNumber(args, 1)) |number| {
                second = dateSetterInteger(number) orelse return dateSetNaNResult(rt, object, had_finite_time, field);
            }
            if (try providedNumber(args, 2)) |number| {
                millis = dateSetterInteger(number) orelse return dateSetNaNResult(rt, object, had_finite_time, field);
            }
        },
        .hour => {
            hour = first_integer;
            if (try providedNumber(args, 1)) |number| {
                minute = dateSetterInteger(number) orelse return dateSetNaNResult(rt, object, had_finite_time, field);
            }
            if (try providedNumber(args, 2)) |number| {
                second = dateSetterInteger(number) orelse return dateSetNaNResult(rt, object, had_finite_time, field);
            }
            if (try providedNumber(args, 3)) |number| {
                millis = dateSetterInteger(number) orelse return dateSetNaNResult(rt, object, had_finite_time, field);
            }
        },
        .day => day = first_integer,
        .month => {
            month = first_integer;
            if (try providedNumber(args, 1)) |number| {
                day = dateSetterInteger(number) orelse return dateSetNaNResult(rt, object, had_finite_time, field);
            }
        },
        .year => {
            year = first_integer;
            if (try providedNumber(args, 1)) |number| {
                month = dateSetterInteger(number) orelse return dateSetNaNResult(rt, object, had_finite_time, field);
            }
            if (try providedNumber(args, 2)) |number| {
                day = dateSetterInteger(number) orelse return dateSetNaNResult(rt, object, had_finite_time, field);
            }
        },
    }

    if (!had_finite_time and field != .year) return core.JSValue.float64(std.math.nan(f64));
    const next_ms = makeUtcMsFromNumbers(year, month, day, hour, minute, second, millis, false);
    try setDateValue(rt, object, next_ms);
    return numberResult(next_ms);
}

fn dateSetterInteger(value: f64) ?f64 {
    if (!std.math.isFinite(value)) return null;
    return toInteger(value);
}

fn providedNumber(args: []const core.JSValue, index: usize) !?f64 {
    if (args.len <= index) return null;
    return toNumber(args[index]) orelse return error.TypeError;
}

fn dateSetNaNResult(rt: *core.JSRuntime, object: *core.Object, had_finite_time: bool, field: DateSetField) !core.JSValue {
    if (!had_finite_time and field != .year) return core.JSValue.float64(std.math.nan(f64));
    try setDateValue(rt, object, std.math.nan(f64));
    return core.JSValue.float64(std.math.nan(f64));
}

fn utc(args: []const core.JSValue) !core.JSValue {
    const year_number = if (args.len >= 1) (toNumber(args[0]) orelse return error.TypeError) else std.math.nan(f64);
    const month_number = if (args.len >= 2) (toNumber(args[1]) orelse return error.TypeError) else 0;
    const day_number = if (args.len >= 3) (toNumber(args[2]) orelse return error.TypeError) else 1;
    const hour_number = if (args.len >= 4) (toNumber(args[3]) orelse return error.TypeError) else 0;
    const minute_number = if (args.len >= 5) (toNumber(args[4]) orelse return error.TypeError) else 0;
    const second_number = if (args.len >= 6) (toNumber(args[5]) orelse return error.TypeError) else 0;
    const millis_number = if (args.len >= 7) (toNumber(args[6]) orelse return error.TypeError) else 0;
    return numberResult(makeUtcMsFromNumbers(year_number, month_number, day_number, hour_number, minute_number, second_number, millis_number, true));
}

fn parse(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue {
    if (args.len != 1 or !args[0].isString()) return error.TypeError;
    return core.JSValue.float64(try parseDateString(rt, args[0]));
}

fn parseDateString(rt: *core.JSRuntime, value: core.JSValue) !f64 {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendRawString(rt, &bytes, value);
    return parseIsoDate(bytes.items) orelse parseLegacyDateString(bytes.items) orelse std.math.nan(f64);
}

fn jsonString(rt: *core.JSRuntime, ms: f64) !core.JSValue {
    if (std.math.isNan(ms)) return core.JSValue.nullValue();
    return isoString(rt, ms, false);
}

fn isoString(rt: *core.JSRuntime, ms: f64, throw_on_nan: bool) !core.JSValue {
    if (!std.math.isFinite(ms)) {
        if (throw_on_nan) return error.RangeError;
        return core.JSValue.nullValue();
    }
    if (ms == 0) {
        const str = try core.string.String.createUtf8(rt, "1970-01-01T00:00:00.000Z");
        return str.value();
    }
    const parts = utcDateParts(@intFromFloat(ms));
    var year_buffer: [16]u8 = undefined;
    const year = try formatIsoYear(&year_buffer, parts.year);
    var month_buffer: [2]u8 = undefined;
    var day_buffer: [2]u8 = undefined;
    var hour_buffer: [2]u8 = undefined;
    var minute_buffer: [2]u8 = undefined;
    var second_buffer: [2]u8 = undefined;
    var millis_buffer: [3]u8 = undefined;
    const month = twoDigit(&month_buffer, parts.month);
    const day = twoDigit(&day_buffer, parts.day);
    const hour = twoDigit(&hour_buffer, parts.hour);
    const minute = twoDigit(&minute_buffer, parts.minute);
    const second = twoDigit(&second_buffer, parts.second);
    const millis = threeDigit(&millis_buffer, parts.millis);
    var buffer: [40]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{s}-{s}-{s}T{s}:{s}:{s}.{s}Z", .{
        year,
        month,
        day,
        hour,
        minute,
        second,
        millis,
    });
    const str = try core.string.String.createUtf8(rt, text);
    return str.value();
}

fn dateString(rt: *core.JSRuntime, ms: f64, kind: DateStringKind) !core.JSValue {
    if (!std.math.isFinite(ms)) {
        const str = try core.string.String.createUtf8(rt, "Invalid Date");
        return str.value();
    }
    const parts = utcDateParts(@intFromFloat(ms));
    const weekday = dayName(parts.weekday);
    const month = monthName(parts.month);
    var year_buffer: [16]u8 = undefined;
    const year = try formatDateStringYear(&year_buffer, parts.year);
    var day_buffer: [2]u8 = undefined;
    var hour_buffer: [2]u8 = undefined;
    var minute_buffer: [2]u8 = undefined;
    var second_buffer: [2]u8 = undefined;
    const day = twoDigit(&day_buffer, parts.day);
    const hour = twoDigit(&hour_buffer, parts.hour);
    const minute = twoDigit(&minute_buffer, parts.minute);
    const second = twoDigit(&second_buffer, parts.second);
    var buffer: [64]u8 = undefined;
    const text = switch (kind) {
        .local => try std.fmt.bufPrint(&buffer, "{s} {s} {s} {s} {s}:{s}:{s} GMT+0000", .{
            weekday,
            month,
            day,
            year,
            hour,
            minute,
            second,
        }),
        .utc => try std.fmt.bufPrint(&buffer, "{s}, {s} {s} {s} {s}:{s}:{s} GMT", .{
            weekday,
            day,
            month,
            year,
            hour,
            minute,
            second,
        }),
        .date => try std.fmt.bufPrint(&buffer, "{s} {s} {s} {s}", .{
            weekday,
            month,
            day,
            year,
        }),
        .time => try std.fmt.bufPrint(&buffer, "{s}:{s}:{s} GMT+0000", .{
            hour,
            minute,
            second,
        }),
    };
    const str = try core.string.String.createUtf8(rt, text);
    return str.value();
}

fn utcDateField(ms: f64, method: u32) core.JSValue {
    if (!std.math.isFinite(ms)) return core.JSValue.float64(std.math.nan(f64));
    const parts = utcDateParts(@intFromFloat(ms));
    const out: i32 = switch (method) {
        12 => @intCast(parts.year),
        13 => @intCast(parts.month - 1),
        14 => @intCast(parts.day),
        15 => @intCast(parts.hour),
        16 => @intCast(parts.minute),
        17 => @intCast(parts.second),
        18 => @intCast(parts.millis),
        19 => @intCast(parts.weekday),
        else => 0,
    };
    return core.JSValue.int32(out);
}

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

fn appendRawString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) !void {
    const string_value = value.asStringBody() orelse return;
    try string_value.ensureFlat(rt);
    switch (string_value.resolveData()) {
        .latin1 => |bytes| try buffer.appendSlice(rt.memory.allocator, bytes),
        .utf16 => |units| {
            for (units) |unit| {
                if (unit <= 0x7f) {
                    try buffer.append(rt.memory.allocator, @intCast(unit));
                } else {
                    var unit_buf: [16]u8 = undefined;
                    const printed = try std.fmt.bufPrint(&unit_buf, "\\u{x}", .{unit});
                    try buffer.appendSlice(rt.memory.allocator, printed);
                }
            }
        },
    }
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

fn valueToI64(value: core.JSValue) ?i64 {
    if (toNumber(value)) |number| {
        if (!std.math.isFinite(number)) return null;
        return @intFromFloat(toInteger(number));
    }
    return null;
}

fn toNumber(value: core.JSValue) ?f64 {
    if (value.isSymbol()) return null;
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

fn parseIsoDate(bytes: []const u8) ?f64 {
    var index: usize = 0;
    var year: i64 = 0;
    var month: i64 = 1;
    var day: i64 = 1;
    var hour: i64 = 0;
    var minute: i64 = 0;
    var second: i64 = 0;
    var millis: i64 = 0;
    var offset_minutes: i64 = 0;

    if (bytes.len == 0) return null;
    if (bytes[0] == '-' or bytes[0] == '+') {
        const sign = bytes[0];
        index += 1;
        const abs_year = parseFixedDigits(bytes, &index, 6) orelse return null;
        if (sign == '-' and abs_year == 0) return null;
        year = if (sign == '-') -abs_year else abs_year;
    } else {
        year = parseFixedDigits(bytes, &index, 4) orelse return null;
    }

    if (index < bytes.len and bytes[index] == '-') {
        index += 1;
        month = parseFixedDigits(bytes, &index, 2) orelse return null;
        if (month < 1) return null;
        if (index < bytes.len and bytes[index] == '-') {
            index += 1;
            day = parseFixedDigits(bytes, &index, 2) orelse return null;
            if (day < 1) return null;
        }
    }

    if (index < bytes.len and bytes[index] == 'T') {
        index += 1;
        hour = parseFixedDigits(bytes, &index, 2) orelse return null;
        if (index >= bytes.len or bytes[index] != ':') return null;
        index += 1;
        minute = parseFixedDigits(bytes, &index, 2) orelse return null;
        if (index < bytes.len and bytes[index] == ':') {
            index += 1;
            second = parseFixedDigits(bytes, &index, 2) orelse return null;
        }
        if (index < bytes.len and (bytes[index] == '.' or bytes[index] == ',')) {
            index += 1;
            var scale: i64 = 100;
            var parsed_fraction = false;
            while (index < bytes.len and bytes[index] >= '0' and bytes[index] <= '9') : (index += 1) {
                parsed_fraction = true;
                if (scale > 0) {
                    millis += @as(i64, bytes[index] - '0') * scale;
                    scale = @divTrunc(scale, 10);
                }
            }
            if (!parsed_fraction) return null;
        }
    }

    if (index < bytes.len) {
        offset_minutes = parseIsoTimeZoneOffset(bytes, &index) orelse return null;
    }
    if (index != bytes.len) return null;
    if (month > 12 or day > 31 or hour > 24 or minute > 59 or second > 59) return null;
    if (hour == 24 and (minute != 0 or second != 0 or millis != 0)) return null;

    const utc_ms = makeUtcMsFromNumbers(
        @floatFromInt(year),
        @floatFromInt(month - 1),
        @floatFromInt(day),
        @floatFromInt(hour),
        @floatFromInt(minute),
        @floatFromInt(second),
        @floatFromInt(millis),
        false,
    );
    if (!std.math.isFinite(utc_ms)) return utc_ms;
    return timeClip(utc_ms - @as(f64, @floatFromInt(offset_minutes * 60 * 1000)));
}

fn parseFixedDigits(bytes: []const u8, index: *usize, count: usize) ?i64 {
    if (index.* + count > bytes.len) return null;
    const slice = bytes[index.* .. index.* + count];
    for (slice) |ch| {
        if (ch < '0' or ch > '9') return null;
    }
    index.* += count;
    return std.fmt.parseInt(i64, slice, 10) catch return null;
}

fn parseIsoTimeZoneOffset(bytes: []const u8, index: *usize) ?i64 {
    if (index.* >= bytes.len) return 0;
    const sign = bytes[index.*];
    if (sign == 'Z') {
        index.* += 1;
        return 0;
    }
    if (sign != '+' and sign != '-') return null;
    index.* += 1;

    const digit_start = index.*;
    while (index.* < bytes.len and bytes[index.*] >= '0' and bytes[index.*] <= '9') : (index.* += 1) {}
    const digit_count = index.* - digit_start;
    if (digit_count != 2 and digit_count != 4) return null;

    var hours: i64 = 0;
    var minutes: i64 = 0;
    if (digit_count == 4) {
        hours = std.fmt.parseInt(i64, bytes[digit_start .. digit_start + 2], 10) catch return null;
        minutes = std.fmt.parseInt(i64, bytes[digit_start + 2 .. digit_start + 4], 10) catch return null;
    } else {
        hours = std.fmt.parseInt(i64, bytes[digit_start..index.*], 10) catch return null;
        if (index.* < bytes.len and bytes[index.*] == ':') {
            index.* += 1;
            minutes = parseFixedDigits(bytes, index, 2) orelse return null;
        }
    }
    if (hours > 23 or minutes > 59) return null;
    const total = hours * 60 + minutes;
    return if (sign == '+') total else -total;
}

fn parseLegacyDateString(bytes: []const u8) ?f64 {
    return parseLocalDateString(bytes) orelse parseUtcDateString(bytes);
}

fn parseLocalDateString(bytes: []const u8) ?f64 {
    var tokens = std.mem.tokenizeScalar(u8, bytes, ' ');
    const weekday = tokens.next() orelse return null;
    if (!isWeekdayToken(weekday)) return null;
    const month_token = tokens.next() orelse return null;
    const day_token = tokens.next() orelse return null;
    const year_token = tokens.next() orelse return null;
    const time_token = tokens.next() orelse return null;
    const zone_token = tokens.next() orelse return null;
    if (tokens.next() != null) return null;

    const month = parseMonthToken(month_token) orelse return null;
    const day = parseDateComponent(day_token) orelse return null;
    const year = parseDateComponent(year_token) orelse return null;
    const time = parseClockToken(time_token) orelse return null;
    const offset_ms = parseGmtOffsetToken(zone_token) orelse return null;

    return timeClip(makeUtcMs(year, month - 1, day, time.hour, time.minute, time.second, 0) - @as(f64, @floatFromInt(offset_ms)));
}

fn parseUtcDateString(bytes: []const u8) ?f64 {
    var tokens = std.mem.tokenizeScalar(u8, bytes, ' ');
    const weekday = tokens.next() orelse return null;
    if (weekday.len != 4 or weekday[3] != ',' or !isWeekdayToken(weekday[0..3])) return null;
    const day_token = tokens.next() orelse return null;
    const month_token = tokens.next() orelse return null;
    const year_token = tokens.next() orelse return null;
    const time_token = tokens.next() orelse return null;
    const zone_token = tokens.next() orelse return null;
    if (tokens.next() != null) return null;
    if (!std.mem.eql(u8, zone_token, "GMT")) return null;

    const day = parseDateComponent(day_token) orelse return null;
    const month = parseMonthToken(month_token) orelse return null;
    const year = parseDateComponent(year_token) orelse return null;
    const time = parseClockToken(time_token) orelse return null;

    return timeClip(makeUtcMs(year, month - 1, day, time.hour, time.minute, time.second, 0));
}

const ParsedClock = struct {
    hour: i64,
    minute: i64,
    second: i64,
};

fn parseClockToken(bytes: []const u8) ?ParsedClock {
    if (bytes.len != 8 or bytes[2] != ':' or bytes[5] != ':') return null;
    return .{
        .hour = parseDateComponent(bytes[0..2]) orelse return null,
        .minute = parseDateComponent(bytes[3..5]) orelse return null,
        .second = parseDateComponent(bytes[6..8]) orelse return null,
    };
}

fn parseDateComponent(bytes: []const u8) ?i64 {
    return std.fmt.parseInt(i64, bytes, 10) catch null;
}

fn parseMonthToken(bytes: []const u8) ?i64 {
    return if (std.mem.eql(u8, bytes, "Jan"))
        1
    else if (std.mem.eql(u8, bytes, "Feb"))
        2
    else if (std.mem.eql(u8, bytes, "Mar"))
        3
    else if (std.mem.eql(u8, bytes, "Apr"))
        4
    else if (std.mem.eql(u8, bytes, "May"))
        5
    else if (std.mem.eql(u8, bytes, "Jun"))
        6
    else if (std.mem.eql(u8, bytes, "Jul"))
        7
    else if (std.mem.eql(u8, bytes, "Aug"))
        8
    else if (std.mem.eql(u8, bytes, "Sep"))
        9
    else if (std.mem.eql(u8, bytes, "Oct"))
        10
    else if (std.mem.eql(u8, bytes, "Nov"))
        11
    else if (std.mem.eql(u8, bytes, "Dec"))
        12
    else
        null;
}

fn isWeekdayToken(bytes: []const u8) bool {
    return std.mem.eql(u8, bytes, "Sun") or
        std.mem.eql(u8, bytes, "Mon") or
        std.mem.eql(u8, bytes, "Tue") or
        std.mem.eql(u8, bytes, "Wed") or
        std.mem.eql(u8, bytes, "Thu") or
        std.mem.eql(u8, bytes, "Fri") or
        std.mem.eql(u8, bytes, "Sat");
}

fn parseGmtOffsetToken(bytes: []const u8) ?i64 {
    if (!std.mem.startsWith(u8, bytes, "GMT")) return null;
    const suffix = bytes[3..];
    if (suffix.len == 0) return 0;
    if (suffix.len != 5) return null;
    const sign = switch (suffix[0]) {
        '+' => @as(i64, 1),
        '-' => @as(i64, -1),
        else => return null,
    };
    const hours = std.fmt.parseInt(i64, suffix[1..3], 10) catch return null;
    const minutes = std.fmt.parseInt(i64, suffix[3..5], 10) catch return null;
    if (hours > 23 or minutes > 59) return null;
    return sign * (hours * ms_per_hour + minutes * ms_per_minute);
}

fn dayName(weekday: i64) []const u8 {
    return switch (weekday) {
        0 => "Sun",
        1 => "Mon",
        2 => "Tue",
        3 => "Wed",
        4 => "Thu",
        5 => "Fri",
        6 => "Sat",
        else => "Sun",
    };
}

fn monthName(month: i64) []const u8 {
    return switch (month) {
        1 => "Jan",
        2 => "Feb",
        3 => "Mar",
        4 => "Apr",
        5 => "May",
        6 => "Jun",
        7 => "Jul",
        8 => "Aug",
        9 => "Sep",
        10 => "Oct",
        11 => "Nov",
        12 => "Dec",
        else => "Jan",
    };
}

fn formatIsoYear(buffer: []u8, year: i64) ![]const u8 {
    if (year >= 0 and year <= 9999) return fourDigit(buffer, year);
    const sign: u8 = if (year < 0) '-' else '+';
    const abs_year = if (year < 0) -year else year;
    if (buffer.len < 7) return error.NoSpaceLeft;
    buffer[0] = sign;
    _ = try sixDigit(buffer[1..], abs_year);
    return buffer[0..7];
}

fn formatDateStringYear(buffer: []u8, year: i64) ![]const u8 {
    if (year >= 0) {
        if (year <= 9999) return fourDigit(buffer, year);
        return std.fmt.bufPrint(buffer, "{d}", .{year});
    }
    const abs_year = -year;
    if (abs_year <= 9999) {
        if (buffer.len < 5) return error.NoSpaceLeft;
        buffer[0] = '-';
        _ = try fourDigit(buffer[1..], abs_year);
        return buffer[0..5];
    }
    return std.fmt.bufPrint(buffer, "-{d}", .{abs_year});
}

fn twoDigit(buffer: *[2]u8, value: i64) []const u8 {
    const v: u8 = @intCast(@mod(value, 100));
    buffer[0] = '0' + @divTrunc(v, 10);
    buffer[1] = '0' + @mod(v, 10);
    return buffer[0..];
}

fn threeDigit(buffer: *[3]u8, value: i64) []const u8 {
    const v: u16 = @intCast(@mod(value, 1000));
    buffer[0] = '0' + @as(u8, @intCast(@divTrunc(v, 100)));
    buffer[1] = '0' + @as(u8, @intCast(@mod(@divTrunc(v, 10), 10)));
    buffer[2] = '0' + @as(u8, @intCast(@mod(v, 10)));
    return buffer[0..];
}

fn fourDigit(buffer: []u8, value: i64) ![]const u8 {
    if (buffer.len < 4) return error.NoSpaceLeft;
    const v: u16 = @intCast(@mod(value, 10000));
    buffer[0] = '0' + @as(u8, @intCast(@divTrunc(v, 1000)));
    buffer[1] = '0' + @as(u8, @intCast(@mod(@divTrunc(v, 100), 10)));
    buffer[2] = '0' + @as(u8, @intCast(@mod(@divTrunc(v, 10), 10)));
    buffer[3] = '0' + @as(u8, @intCast(@mod(v, 10)));
    return buffer[0..4];
}

fn sixDigit(buffer: []u8, value: i64) ![]const u8 {
    if (buffer.len < 6) return error.NoSpaceLeft;
    const v: u32 = @intCast(@mod(value, 1000000));
    buffer[0] = '0' + @as(u8, @intCast(@divTrunc(v, 100000)));
    buffer[1] = '0' + @as(u8, @intCast(@mod(@divTrunc(v, 10000), 10)));
    buffer[2] = '0' + @as(u8, @intCast(@mod(@divTrunc(v, 1000), 10)));
    buffer[3] = '0' + @as(u8, @intCast(@mod(@divTrunc(v, 100), 10)));
    buffer[4] = '0' + @as(u8, @intCast(@mod(@divTrunc(v, 10), 10)));
    buffer[5] = '0' + @as(u8, @intCast(@mod(v, 10)));
    return buffer[0..6];
}

fn toInteger(value: f64) f64 {
    if (std.math.isNan(value) or value == 0) return value;
    return if (value < 0) -@floor(@abs(value)) else @floor(value);
}

fn timeClip(value: f64) f64 {
    if (!std.math.isFinite(value) or @abs(value) > 8.64e15) return std.math.nan(f64);
    return toInteger(value) + 0.0;
}

fn constructDateFromParts(args: []const core.JSValue) !f64 {
    const year_number = toNumber(args[0]) orelse return error.TypeError;
    const month_number = toNumber(args[1]) orelse return error.TypeError;
    const day_number = if (args.len >= 3) (toNumber(args[2]) orelse return error.TypeError) else 1;
    const hour_number = if (args.len >= 4) (toNumber(args[3]) orelse return error.TypeError) else 0;
    const minute_number = if (args.len >= 5) (toNumber(args[4]) orelse return error.TypeError) else 0;
    const second_number = if (args.len >= 6) (toNumber(args[5]) orelse return error.TypeError) else 0;
    const millis_number = if (args.len >= 7) (toNumber(args[6]) orelse return error.TypeError) else 0;

    return makeUtcMsFromNumbers(year_number, month_number, day_number, hour_number, minute_number, second_number, millis_number, true);
}

fn currentTimeMs() f64 {
    var tv: std.c.timeval = undefined;
    if (std.c.gettimeofday(&tv, null) == 0) {
        return @as(f64, @floatFromInt(tv.sec)) * 1000.0 + @as(f64, @floatFromInt(@divTrunc(tv.usec, 1000)));
    }
    return 0;
}

const DateParts = struct {
    year: i64,
    month: i64,
    day: i64,
    hour: i64,
    minute: i64,
    second: i64,
    millis: i64,
    weekday: i64,
};

fn makeUtcMs(year: i64, month_zero_based: i64, day: i64, hour: i64, minute: i64, second: i64, millis: i64) f64 {
    const month_one_based = month_zero_based + 1;
    const years_delta = @divFloor(month_one_based - 1, 12);
    const normalized_year = year + years_delta;
    const normalized_month = @mod(month_one_based - 1, 12) + 1;
    const days = daysFromCivil(normalized_year, normalized_month, day);
    const total = days * ms_per_day + hour * ms_per_hour + minute * ms_per_minute + second * ms_per_second + millis;
    return @floatFromInt(total);
}

fn makeUtcMsFromNumbers(year_number: f64, month_number: f64, day_number: f64, hour_number: f64, minute_number: f64, second_number: f64, millis_number: f64, adjust_two_digit_year: bool) f64 {
    if (!std.math.isFinite(year_number) or
        !std.math.isFinite(month_number) or
        !std.math.isFinite(day_number) or
        !std.math.isFinite(hour_number) or
        !std.math.isFinite(minute_number) or
        !std.math.isFinite(second_number) or
        !std.math.isFinite(millis_number))
    {
        return std.math.nan(f64);
    }

    var year = year_number;
    if (adjust_two_digit_year) {
        const year_integer = toInteger(year_number);
        if (year_integer >= 0 and year_integer <= 99) year = year_integer + 1900;
    }
    const month = toInteger(month_number);
    const day = toInteger(day_number);
    const hour = toInteger(hour_number);
    const minute = toInteger(minute_number);
    const second = toInteger(second_number);
    const millis = toInteger(millis_number);

    const normalized_year_number = year + @floor(month / 12.0);
    var normalized_month_number = @rem(month, 12.0);
    if (normalized_month_number < 0) normalized_month_number += 12.0;
    if (!std.math.isFinite(normalized_year_number) or normalized_year_number < -271821 or normalized_year_number > 275760) {
        return std.math.nan(f64);
    }

    const normalized_year: i64 = @intFromFloat(normalized_year_number);
    const normalized_month: i64 = @as(i64, @intFromFloat(normalized_month_number)) + 1;
    const day_base = @as(f64, @floatFromInt(daysFromCivil(normalized_year, normalized_month, 1)));
    const total_day = day_base + day - 1.0;
    const ms_per_hour_f = @as(f64, @floatFromInt(ms_per_hour));
    const ms_per_minute_f = @as(f64, @floatFromInt(ms_per_minute));
    const ms_per_second_f = @as(f64, @floatFromInt(ms_per_second));
    const ms_per_day_f = @as(f64, @floatFromInt(ms_per_day));

    var temp_storage: f64 = hour * ms_per_hour_f;
    const temp_ptr: *volatile f64 = &temp_storage;
    var time = temp_ptr.*;
    temp_storage = minute * ms_per_minute_f;
    time += temp_ptr.*;
    temp_storage = second * ms_per_second_f;
    time += temp_ptr.*;
    time += millis;

    temp_storage = total_day * ms_per_day_f;
    const value = temp_ptr.* + time;
    if (!std.math.isFinite(value)) return std.math.nan(f64);
    return timeClip(value);
}

fn utcDateParts(ms: i64) DateParts {
    const days = @divFloor(ms, ms_per_day);
    var time = @mod(ms, ms_per_day);
    const civil = civilFromDays(days);
    const hour = @divFloor(time, ms_per_hour);
    time = @mod(time, ms_per_hour);
    const minute = @divFloor(time, ms_per_minute);
    time = @mod(time, ms_per_minute);
    const second = @divFloor(time, ms_per_second);
    const millis = @mod(time, ms_per_second);
    return .{
        .year = civil.year,
        .month = civil.month,
        .day = civil.day,
        .hour = hour,
        .minute = minute,
        .second = second,
        .millis = millis,
        .weekday = @mod(days + 4, 7),
    };
}

fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = year - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = month + @as(i64, if (month > 2) -3 else 9);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilFromDays(days_since_epoch: i64) struct { year: i64, month: i64, day: i64 } {
    const z = days_since_epoch + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var year = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = mp + if (mp < 10) @as(i64, 3) else @as(i64, -9);
    year += if (month <= 2) 1 else 0;
    return .{ .year = year, .month = month, .day = day };
}

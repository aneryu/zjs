const core = @import("../core/root.zig");
const std = @import("std");

const ms_per_second: i64 = 1000;
const ms_per_minute: i64 = 60 * ms_per_second;
const ms_per_hour: i64 = 60 * ms_per_minute;
pub const ms_per_day: i64 = 24 * ms_per_hour;

pub const StaticMethod = enum(u32) {
    utc = 1,
    parse = 2,
    now = 3,
};

pub const ConstructorMethod = enum(u32) {
    construct = 100,
};

pub const PrototypeMethod = enum(u32) {
    get_time = 101,
    value_of = 102,
    get_full_year = 103,
    get_month = 104,
    get_date = 105,
    get_hours = 106,
    get_minutes = 107,
    get_seconds = 108,
    get_milliseconds = 109,
    to_iso_string = 110,
    to_json = 111,
    get_utc_full_year = 112,
    get_utc_month = 113,
    get_utc_date = 114,
    get_utc_hours = 115,
    get_utc_minutes = 116,
    get_utc_seconds = 117,
    get_utc_milliseconds = 118,
    get_day = 119,
    to_string = 120,
    to_utc_string = 121,
    get_year = 122,
    set_year = 123,
    set_time = 124,
    set_milliseconds = 125,
    set_seconds = 126,
    set_minutes = 127,
    set_hours = 128,
    set_date = 129,
    set_month = 130,
    set_full_year = 131,
    get_timezone_offset = 132,
    to_date_string = 133,
    to_time_string = 134,
    to_primitive = 135,
};

pub fn staticMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "UTC")) return @intFromEnum(StaticMethod.utc);
    if (std.mem.eql(u8, name, "parse")) return @intFromEnum(StaticMethod.parse);
    if (std.mem.eql(u8, name, "now")) return @intFromEnum(StaticMethod.now);
    return null;
}

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

pub fn decodePrototypeMethodId(id: u32) ?u32 {
    return switch (id) {
        @intFromEnum(PrototypeMethod.get_time) => 1,
        @intFromEnum(PrototypeMethod.value_of) => 2,
        @intFromEnum(PrototypeMethod.get_full_year) => 3,
        @intFromEnum(PrototypeMethod.get_month) => 4,
        @intFromEnum(PrototypeMethod.get_date) => 5,
        @intFromEnum(PrototypeMethod.get_hours) => 6,
        @intFromEnum(PrototypeMethod.get_minutes) => 7,
        @intFromEnum(PrototypeMethod.get_seconds) => 8,
        @intFromEnum(PrototypeMethod.get_milliseconds) => 9,
        @intFromEnum(PrototypeMethod.to_iso_string) => 10,
        @intFromEnum(PrototypeMethod.to_json) => 11,
        @intFromEnum(PrototypeMethod.get_utc_full_year) => 12,
        @intFromEnum(PrototypeMethod.get_utc_month) => 13,
        @intFromEnum(PrototypeMethod.get_utc_date) => 14,
        @intFromEnum(PrototypeMethod.get_utc_hours) => 15,
        @intFromEnum(PrototypeMethod.get_utc_minutes) => 16,
        @intFromEnum(PrototypeMethod.get_utc_seconds) => 17,
        @intFromEnum(PrototypeMethod.get_utc_milliseconds) => 18,
        @intFromEnum(PrototypeMethod.get_day) => 19,
        @intFromEnum(PrototypeMethod.to_string) => 20,
        @intFromEnum(PrototypeMethod.to_utc_string) => 21,
        @intFromEnum(PrototypeMethod.get_year) => 22,
        @intFromEnum(PrototypeMethod.set_year) => 23,
        @intFromEnum(PrototypeMethod.set_time) => 24,
        @intFromEnum(PrototypeMethod.set_milliseconds) => 25,
        @intFromEnum(PrototypeMethod.set_seconds) => 26,
        @intFromEnum(PrototypeMethod.set_minutes) => 27,
        @intFromEnum(PrototypeMethod.set_hours) => 28,
        @intFromEnum(PrototypeMethod.set_date) => 29,
        @intFromEnum(PrototypeMethod.set_month) => 30,
        @intFromEnum(PrototypeMethod.set_full_year) => 31,
        @intFromEnum(PrototypeMethod.get_timezone_offset) => 32,
        @intFromEnum(PrototypeMethod.to_date_string) => 33,
        @intFromEnum(PrototypeMethod.to_time_string) => 34,
        else => null,
    };
}

pub fn dayFromTime(ms: i64) i64 {
    return @divFloor(ms, ms_per_day);
}

pub fn timeWithinDay(ms: i64) i64 {
    return @mod(ms, ms_per_day);
}

/// QuickJS source map: Date as a function. This is the current narrow Date
/// subset used by transitional `date_call` bytecode.
pub fn call(rt: *core.Runtime, args: []const core.Value) !core.Value {
    _ = args;
    return dateString(rt, currentTimeMs(), .local);
}

/// QuickJS source map: Date constructor. This preserves the current smoke/test
/// compatible Date object payload while moving ownership out of the VM.
pub fn construct(rt: *core.Runtime, args: []const core.Value) !core.Value {
    return constructWithPrototype(rt, args, null);
}

pub fn constructWithPrototype(rt: *core.Runtime, args: []const core.Value, prototype: ?*core.Object) !core.Value {
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

fn defineDateValue(rt: *core.Runtime, object: *core.Object, ms: f64) !void {
    try setDateValue(rt, object, ms);
}

/// QuickJS source map: Date.UTC / Date.parse / Date.now. This is still a narrow
/// builtin implementation; unsupported Date shapes stay on transitional paths.
pub fn staticCall(rt: *core.Runtime, method: u32, args: []const core.Value) !core.Value {
    return switch (method) {
        1 => utc(args),
        2 => try parse(rt, args),
        3 => core.Value.float64(currentTimeMs()),
        else => error.TypeError,
    };
}

/// QuickJS source map: selected Date.prototype methods used by current smoke
/// and targeted regression coverage.
pub fn methodCall(rt: *core.Runtime, object_value: core.Value, method: u32) !core.Value {
    return methodCallArgs(rt, object_value, method, &.{});
}

pub fn methodCallArgs(rt: *core.Runtime, object_value: core.Value, method: u32, args: []const core.Value) !core.Value {
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
        32 => if (std.math.isFinite(ms)) core.Value.int32(0) else core.Value.float64(std.math.nan(f64)),
        33 => try dateString(rt, ms, .date),
        34 => try dateString(rt, ms, .time),
        else => error.TypeError,
    };
}

pub fn methodCallArgsWithCapturedMs(rt: *core.Runtime, object_value: core.Value, method: u32, captured_ms: f64, args: []const core.Value) !core.Value {
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

fn dateFullYear(ms: f64) core.Value {
    if (!std.math.isFinite(ms)) return core.Value.float64(std.math.nan(f64));
    const parts = utcDateParts(@intFromFloat(ms));
    return core.Value.int32(@intCast(parts.year));
}

fn dateYear(ms: f64) core.Value {
    if (!std.math.isFinite(ms)) return core.Value.float64(std.math.nan(f64));
    const parts = utcDateParts(@intFromFloat(ms));
    return core.Value.int32(@intCast(parts.year - 1900));
}

fn dateField(ms: f64, field: DateGetField) core.Value {
    if (!std.math.isFinite(ms)) return core.Value.float64(std.math.nan(f64));
    const parts = utcDateParts(@intFromFloat(ms));
    const out: i32 = switch (field) {
        .millis => @intCast(parts.millis),
        .second => @intCast(parts.second),
        .minute => @intCast(parts.minute),
        .hour => @intCast(parts.hour),
        .day => @intCast(parts.day),
        .month => @intCast(parts.month - 1),
    };
    return core.Value.int32(out);
}

fn setYear(rt: *core.Runtime, object: *core.Object, ms: f64, args: []const core.Value) !core.Value {
    const year_number = if (args.len >= 1) (toNumber(args[0]) orelse return error.TypeError) else std.math.nan(f64);
    return setYearNumberOnObject(rt, object, ms, year_number);
}

pub fn setYearNumber(rt: *core.Runtime, object_value: core.Value, captured_ms: f64, year_number: f64) !core.Value {
    const object = try expectDateObject(object_value);
    return setYearNumberOnObject(rt, object, captured_ms, year_number);
}

fn setYearNumberOnObject(rt: *core.Runtime, object: *core.Object, ms: f64, year_number: f64) !core.Value {
    if (std.math.isNan(year_number)) {
        try setDateValue(rt, object, std.math.nan(f64));
        return core.Value.float64(std.math.nan(f64));
    }
    if (!std.math.isFinite(year_number)) {
        try setDateValue(rt, object, std.math.nan(f64));
        return core.Value.float64(std.math.nan(f64));
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

fn setTime(rt: *core.Runtime, object: *core.Object, args: []const core.Value) !core.Value {
    const time_number = if (args.len >= 1) (toNumber(args[0]) orelse return error.TypeError) else std.math.nan(f64);
    const next_ms = timeClip(time_number);
    try setDateValue(rt, object, next_ms);
    return numberResult(next_ms);
}

fn setDateParts(rt: *core.Runtime, object: *core.Object, ms: f64, args: []const core.Value, field: DateSetField) !core.Value {
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

    if (!had_finite_time and field != .year) return core.Value.float64(std.math.nan(f64));
    const next_ms = makeUtcMsFromNumbers(year, month, day, hour, minute, second, millis, false);
    try setDateValue(rt, object, next_ms);
    return numberResult(next_ms);
}

fn dateSetterInteger(value: f64) ?f64 {
    if (!std.math.isFinite(value)) return null;
    return toInteger(value);
}

fn providedNumber(args: []const core.Value, index: usize) !?f64 {
    if (args.len <= index) return null;
    return toNumber(args[index]) orelse return error.TypeError;
}

fn dateSetNaNResult(rt: *core.Runtime, object: *core.Object, had_finite_time: bool, field: DateSetField) !core.Value {
    if (!had_finite_time and field != .year) return core.Value.float64(std.math.nan(f64));
    try setDateValue(rt, object, std.math.nan(f64));
    return core.Value.float64(std.math.nan(f64));
}

fn utc(args: []const core.Value) !core.Value {
    const year_number = if (args.len >= 1) (toNumber(args[0]) orelse return error.TypeError) else std.math.nan(f64);
    const month_number = if (args.len >= 2) (toNumber(args[1]) orelse return error.TypeError) else 0;
    const day_number = if (args.len >= 3) (toNumber(args[2]) orelse return error.TypeError) else 1;
    const hour_number = if (args.len >= 4) (toNumber(args[3]) orelse return error.TypeError) else 0;
    const minute_number = if (args.len >= 5) (toNumber(args[4]) orelse return error.TypeError) else 0;
    const second_number = if (args.len >= 6) (toNumber(args[5]) orelse return error.TypeError) else 0;
    const millis_number = if (args.len >= 7) (toNumber(args[6]) orelse return error.TypeError) else 0;
    return numberResult(makeUtcMsFromNumbers(year_number, month_number, day_number, hour_number, minute_number, second_number, millis_number, true));
}

fn parse(rt: *core.Runtime, args: []const core.Value) !core.Value {
    if (args.len != 1 or !args[0].isString()) return error.TypeError;
    return core.Value.float64(try parseDateString(rt, args[0]));
}

fn parseDateString(rt: *core.Runtime, value: core.Value) !f64 {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendRawString(rt, &bytes, value);
    return parseIsoDate(bytes.items) orelse parseLegacyDateString(bytes.items) orelse std.math.nan(f64);
}

fn jsonString(rt: *core.Runtime, ms: f64) !core.Value {
    if (std.math.isNan(ms)) return core.Value.nullValue();
    return isoString(rt, ms, false);
}

fn isoString(rt: *core.Runtime, ms: f64, throw_on_nan: bool) !core.Value {
    if (!std.math.isFinite(ms)) {
        if (throw_on_nan) return error.RangeError;
        return core.Value.nullValue();
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

fn dateString(rt: *core.Runtime, ms: f64, kind: DateStringKind) !core.Value {
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

fn utcDateField(ms: f64, method: u32) core.Value {
    if (!std.math.isFinite(ms)) return core.Value.float64(std.math.nan(f64));
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
    return core.Value.int32(out);
}

fn expectDateObject(value: core.Value) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_id != core.class.ids.date) return error.TypeError;
    return object;
}

fn setDateValue(rt: *core.Runtime, object: *core.Object, ms: f64) !void {
    const slot = object.objectDataSlot();
    const old_value = slot.*;
    slot.* = core.Value.float64(ms);
    if (old_value) |stored| stored.free(rt);
}

fn dateValue(object: *const core.Object) !f64 {
    const value = object.objectData() orelse return error.TypeError;
    return numberValue(value) orelse error.TypeError;
}

fn dateObjectFromValue(value: core.Value) ?*core.Object {
    const header = value.refHeader() orelse return null;
    if (!value.isObject()) return null;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_id != core.class.ids.date) return null;
    return object;
}

fn appendRawString(rt: *core.Runtime, buffer: *std.ArrayList(u8), value: core.Value) !void {
    const header = value.refHeader() orelse return;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
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

fn numberValue(value: core.Value) ?f64 {
    if (value.tag == core.Tag.int) return @floatFromInt(value.asInt32().?);
    if (value.tag == core.Tag.float64) return value.asFloat64().?;
    return null;
}

fn numberResult(value: f64) core.Value {
    if (std.math.isFinite(value) and @floor(value) == value and value >= @as(f64, @floatFromInt(std.math.minInt(i32))) and value <= @as(f64, @floatFromInt(std.math.maxInt(i32))) and !isNegativeZero(value)) {
        return core.Value.int32(@intFromFloat(value));
    }
    return core.Value.float64(value);
}

fn valueToI64(value: core.Value) ?i64 {
    if (toNumber(value)) |number| {
        if (!std.math.isFinite(number)) return null;
        return @intFromFloat(toInteger(number));
    }
    return null;
}

fn toNumber(value: core.Value) ?f64 {
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

fn appendStringValueAscii(writer: *std.Io.Writer, value: core.Value) !void {
    const header = value.refHeader() orelse return;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
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

fn constructDateFromParts(args: []const core.Value) !f64 {
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

fn isNegativeZero(value: f64) bool {
    return value == 0 and std.math.isNegativeInf(1.0 / value);
}

const core = @import("../core/root.zig");
const function_builtin = @import("function.zig");
const bignum = @import("../libs/bignum.zig");
const unicode = @import("../libs/unicode.zig");
const std = @import("std");

const AppendStringError = error{
    OutOfMemory,
    TypeError,
    InvalidRadix,
    NoSpaceLeft,
};

const TrimMode = enum { start, end, both };

pub const StaticMethod = enum(u32) {
    from_char_code = 1,
    from_code_point = 2,
    raw = 3,
};

pub const ConstructorMethod = enum(u32) {
    call = 4,
};

pub const legacy_split_method_id: u32 = 27;
pub const legacy_normalize_method_id: u32 = 37;
pub const legacy_search_method_id: u32 = 40;
pub const legacy_match_method_id: u32 = 41;
pub const legacy_replace_all_method_id: u32 = 42;
pub const legacy_match_all_method_id: u32 = 43;

pub const PrototypeMethod = enum(u32) {
    char_at = 100,
    substring = 101,
    to_upper_case = 102,
    to_lower_case = 103,
    index_of = 104,
    includes = 105,
    starts_with = 106,
    ends_with = 107,
    trim = 108,
    concat = 110,
    trim_start = 121,
    trim_end = 122,
    split = 127,
    last_index_of = 128,
    char_code_at = 129,
    at = 130,
    code_point_at = 131,
    slice = 132,
    repeat = 133,
    pad_start = 134,
    pad_end = 135,
    locale_compare = 136,
    normalize = 137,
    is_well_formed = 138,
    to_well_formed = 139,
    search = 140,
    match = 141,
    replace_all = 142,
    match_all = 143,
};

pub fn staticMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "fromCharCode")) return @intFromEnum(StaticMethod.from_char_code);
    if (std.mem.eql(u8, name, "fromCodePoint")) return @intFromEnum(StaticMethod.from_code_point);
    if (std.mem.eql(u8, name, "raw")) return @intFromEnum(StaticMethod.raw);
    return null;
}

pub fn prototypeMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "charAt")) return @intFromEnum(PrototypeMethod.char_at);
    if (std.mem.eql(u8, name, "substring")) return @intFromEnum(PrototypeMethod.substring);
    if (std.mem.eql(u8, name, "toUpperCase")) return @intFromEnum(PrototypeMethod.to_upper_case);
    if (std.mem.eql(u8, name, "toLocaleUpperCase")) return @intFromEnum(PrototypeMethod.to_upper_case);
    if (std.mem.eql(u8, name, "toLowerCase")) return @intFromEnum(PrototypeMethod.to_lower_case);
    if (std.mem.eql(u8, name, "toLocaleLowerCase")) return @intFromEnum(PrototypeMethod.to_lower_case);
    if (std.mem.eql(u8, name, "indexOf")) return @intFromEnum(PrototypeMethod.index_of);
    if (std.mem.eql(u8, name, "includes")) return @intFromEnum(PrototypeMethod.includes);
    if (std.mem.eql(u8, name, "startsWith")) return @intFromEnum(PrototypeMethod.starts_with);
    if (std.mem.eql(u8, name, "endsWith")) return @intFromEnum(PrototypeMethod.ends_with);
    if (std.mem.eql(u8, name, "trim")) return @intFromEnum(PrototypeMethod.trim);
    if (std.mem.eql(u8, name, "concat")) return @intFromEnum(PrototypeMethod.concat);
    if (std.mem.eql(u8, name, "lastIndexOf")) return @intFromEnum(PrototypeMethod.last_index_of);
    if (std.mem.eql(u8, name, "charCodeAt")) return @intFromEnum(PrototypeMethod.char_code_at);
    if (std.mem.eql(u8, name, "at")) return @intFromEnum(PrototypeMethod.at);
    if (std.mem.eql(u8, name, "codePointAt")) return @intFromEnum(PrototypeMethod.code_point_at);
    if (std.mem.eql(u8, name, "slice")) return @intFromEnum(PrototypeMethod.slice);
    if (std.mem.eql(u8, name, "repeat")) return @intFromEnum(PrototypeMethod.repeat);
    if (std.mem.eql(u8, name, "padStart")) return @intFromEnum(PrototypeMethod.pad_start);
    if (std.mem.eql(u8, name, "padEnd")) return @intFromEnum(PrototypeMethod.pad_end);
    if (std.mem.eql(u8, name, "localeCompare")) return @intFromEnum(PrototypeMethod.locale_compare);
    if (std.mem.eql(u8, name, "normalize")) return @intFromEnum(PrototypeMethod.normalize);
    if (std.mem.eql(u8, name, "isWellFormed")) return @intFromEnum(PrototypeMethod.is_well_formed);
    if (std.mem.eql(u8, name, "toWellFormed")) return @intFromEnum(PrototypeMethod.to_well_formed);
    if (std.mem.eql(u8, name, "trimStart")) return @intFromEnum(PrototypeMethod.trim_start);
    if (std.mem.eql(u8, name, "trimEnd")) return @intFromEnum(PrototypeMethod.trim_end);
    if (std.mem.eql(u8, name, "split")) return @intFromEnum(PrototypeMethod.split);
    if (std.mem.eql(u8, name, "search")) return @intFromEnum(PrototypeMethod.search);
    if (std.mem.eql(u8, name, "match")) return @intFromEnum(PrototypeMethod.match);
    if (std.mem.eql(u8, name, "matchAll")) return @intFromEnum(PrototypeMethod.match_all);
    if (std.mem.eql(u8, name, "replaceAll")) return @intFromEnum(PrototypeMethod.replace_all);
    return null;
}

pub fn decodePrototypeMethodId(id: u32) ?u32 {
    return switch (id) {
        @intFromEnum(PrototypeMethod.char_at) => 0,
        @intFromEnum(PrototypeMethod.substring) => 1,
        @intFromEnum(PrototypeMethod.to_upper_case) => 2,
        @intFromEnum(PrototypeMethod.to_lower_case) => 3,
        @intFromEnum(PrototypeMethod.index_of) => 4,
        @intFromEnum(PrototypeMethod.includes) => 5,
        @intFromEnum(PrototypeMethod.starts_with) => 6,
        @intFromEnum(PrototypeMethod.ends_with) => 7,
        @intFromEnum(PrototypeMethod.trim) => 8,
        @intFromEnum(PrototypeMethod.concat) => 10,
        @intFromEnum(PrototypeMethod.trim_start) => 21,
        @intFromEnum(PrototypeMethod.trim_end) => 22,
        @intFromEnum(PrototypeMethod.split) => legacy_split_method_id,
        @intFromEnum(PrototypeMethod.last_index_of) => 28,
        @intFromEnum(PrototypeMethod.char_code_at) => 29,
        @intFromEnum(PrototypeMethod.at) => 30,
        @intFromEnum(PrototypeMethod.code_point_at) => 31,
        @intFromEnum(PrototypeMethod.slice) => 32,
        @intFromEnum(PrototypeMethod.repeat) => 33,
        @intFromEnum(PrototypeMethod.pad_start) => 34,
        @intFromEnum(PrototypeMethod.pad_end) => 35,
        @intFromEnum(PrototypeMethod.locale_compare) => 36,
        @intFromEnum(PrototypeMethod.normalize) => legacy_normalize_method_id,
        @intFromEnum(PrototypeMethod.is_well_formed) => 38,
        @intFromEnum(PrototypeMethod.to_well_formed) => 39,
        @intFromEnum(PrototypeMethod.search) => legacy_search_method_id,
        @intFromEnum(PrototypeMethod.match) => legacy_match_method_id,
        @intFromEnum(PrototypeMethod.replace_all) => legacy_replace_all_method_id,
        @intFromEnum(PrototypeMethod.match_all) => legacy_match_all_method_id,
        else => null,
    };
}

pub fn charAt(bytes: []const u8, index: usize) []const u8 {
    if (index >= bytes.len) return "";
    return bytes[index .. index + 1];
}

pub fn toUpperAscii(buf: []u8, bytes: []const u8) []u8 {
    const n = @min(buf.len, bytes.len);
    for (bytes[0..n], 0..) |byte, i| buf[i] = unicode.toUpperAscii(byte);
    return buf[0..n];
}

/// QuickJS source map: narrow String wrapper constructor used by transitional
/// `new_string_object` bytecode.
pub fn construct(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue {
    return constructWithPrototype(rt, args, null);
}

pub fn constructWithPrototype(rt: *core.JSRuntime, args: []const core.JSValue, prototype: ?*core.Object) !core.JSValue {
    var rooted_args_buffer = try core.runtime.ValueRootBuffer.initCopy(rt, args);
    defer rooted_args_buffer.deinit(rt);
    const rooted_args = rooted_args_buffer.values;
    var data_value = core.JSValue.undefinedValue();
    var object_value = core.JSValue.undefinedValue();
    var root_slices = [_]core.runtime.ValueRootSlice{
        rooted_args_buffer.slice(),
    };
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &data_value },
        .{ .value = &object_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .slices = &root_slices,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    if (rooted_args.len >= 1 and rooted_args[0].isSymbol()) return error.TypeError;
    data_value = if (rooted_args.len >= 1)
        try stringValueFromSearchArgument(rt, rooted_args[0])
    else
        try createStringValue(rt, "");
    defer data_value.free(rt);
    const data = stringValueFromReceiver(data_value) orelse return error.TypeError;

    const object = try core.Object.create(rt, core.class.ids.string, prototype);
    object_value = object.value();
    errdefer {
        const failed_object = object_value;
        object_value = core.JSValue.undefinedValue();
        failed_object.free(rt);
    }

    try object.setOptionalValueSlot(rt, object.objectDataSlot(), data_value.dup());
    var index: u32 = 0;
    while (index < data.len()) : (index += 1) {
        try defineStringIndexUnitProperty(rt, object, index, data.codeUnitAt(index));
    }
    try defineReadonlyIntProperty(rt, object, "length", @intCast(data.len()));
    return object_value;
}

pub fn iterator(rt: *core.JSRuntime, receiver: core.JSValue) !core.JSValue {
    var rooted_receiver = receiver;
    var target = core.JSValue.undefinedValue();
    var prototype_value = core.JSValue.undefinedValue();
    var object_value = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_receiver },
        .{ .value = &target },
        .{ .value = &prototype_value },
        .{ .value = &object_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    target = try stringPrimitiveValue(rooted_receiver);
    defer target.free(rt);
    const prototype = try iteratorPrototype(rt, "String Iterator");
    prototype_value = prototype.value();
    defer prototype_value.free(rt);
    const object = try core.Object.create(rt, core.class.ids.string_iterator, prototype);
    object_value = object.value();
    errdefer {
        const failed_object = object_value;
        object_value = core.JSValue.undefinedValue();
        failed_object.free(rt);
    }
    try object.setOptionalValueSlot(rt, object.iteratorTargetSlot(), target.dup());
    object.iteratorIndexSlot().* = 0;
    return object_value;
}

fn iteratorPrototype(rt: *core.JSRuntime, tag_name: []const u8) !*core.Object {
    const base = try core.Object.create(rt, core.class.ids.object, null);
    var base_raw_owned = true;
    errdefer if (base_raw_owned) core.Object.destroyFromHeader(rt, &base.header);
    try defineToStringTag(rt, base, "Iterator");
    const specific = try core.Object.create(rt, core.class.ids.object, base);
    errdefer core.Object.destroyFromHeader(rt, &specific.header);
    base_raw_owned = false;
    base.value().free(rt);
    try defineToStringTag(rt, specific, tag_name);
    const next = try function_builtin.nativeFunction(rt, "next", 0);
    defer next.free(rt);
    try specific.defineOwnProperty(rt, core.atom.predefinedId("next", .string).?, core.Descriptor.data(next, true, false, true));
    return specific;
}

fn defineToStringTag(rt: *core.JSRuntime, object: *core.Object, tag_name: []const u8) !void {
    const tag_atom = core.atom.predefinedId("Symbol.toStringTag", .symbol) orelse return error.TypeError;
    const tag_value = try core.string.String.createUtf8(rt, tag_name);
    defer tag_value.value().free(rt);
    try object.defineOwnProperty(rt, tag_atom, core.Descriptor.data(tag_value.value(), false, false, true));
}

pub fn iteratorNext(rt: *core.JSRuntime, receiver: core.JSValue) !core.JSValue {
    const iterator_object = try expectObject(receiver);
    if (iterator_object.class_id != core.class.ids.string_iterator) return error.TypeError;
    const target = (iterator_object.iteratorTargetSlot().*) orelse return iteratorResult(rt, core.JSValue.undefinedValue(), true);
    const header = target.refHeader() orelse return error.TypeError;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    if ((iterator_object.iteratorIndexSlot().*) >= string_value.len()) {
        const done_result = try iteratorResult(rt, core.JSValue.undefinedValue(), true);
        iterator_object.clearOptionalValueSlot(rt, iterator_object.iteratorTargetSlot());
        return done_result;
    }

    const index: usize = @intCast((iterator_object.iteratorIndexSlot().*));
    const first = string_value.codeUnitAt(index);
    if (isHighSurrogateUnit(first) and index + 1 < string_value.len()) {
        const second = string_value.codeUnitAt(index + 1);
        if (isLowSurrogateUnit(second)) {
            iterator_object.iteratorIndexSlot().* += 2;
            const units: [2]u16 = .{ first, second };
            const out = try core.string.String.createUtf16(rt, &units);
            return iteratorResult(rt, out.value(), false);
        }
    }

    iterator_object.iteratorIndexSlot().* += 1;
    const units: [1]u16 = .{first};
    const out = try core.string.String.createUtf16(rt, &units);
    return iteratorResult(rt, out.value(), false);
}

/// Legacy primitive-only String.fromCharCode helper used by transitional bytecode.
/// JS-visible native calls use the VM shared helper so object coercion and
/// abrupt completion propagation match QuickJS.
pub fn fromCharCode(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue {
    if (args.len == 2) {
        const first_code = args[0].asInt32() orelse return error.TypeError;
        const second_code = args[1].asInt32() orelse return error.TypeError;
        const first: u16 = @intCast(@as(u32, @bitCast(first_code)) & 0xffff);
        const second: u16 = @intCast(@as(u32, @bitCast(second_code)) & 0xffff);
        const cached = try rt.recentTwoUnitString(first, second);
        return cached.value().dup();
    }
    if (args.len == 1) {
        const code = args[0].asInt32() orelse return error.TypeError;
        const unit: u16 = @intCast(@as(u32, @bitCast(code)) & 0xffff);
        if (unit <= 0xff) {
            const byte: u8 = @intCast(unit);
            if (try rt.singleByteString(byte)) |cached| return cached.value().dup();
        }
    }

    // Most call sites pass 1-2 code points (notably the `String.fromCharCode(H, L)`
    // surrogate-pair pattern that drives URI sweeps), so keep the
    // working buffer on the stack.
    var stack_buf: [16]u16 = undefined;
    var heap_buf: []u16 = &.{};
    defer if (heap_buf.len != 0) rt.memory.free(u16, heap_buf);
    const units: []u16 = if (args.len <= stack_buf.len)
        stack_buf[0..args.len]
    else blk: {
        heap_buf = try rt.memory.alloc(u16, args.len);
        break :blk heap_buf;
    };
    for (args, 0..) |value, i| {
        const code = value.asInt32() orelse return error.TypeError;
        units[i] = @intCast(@as(u32, @bitCast(code)) & 0xffff);
    }
    const string = try core.string.String.createUtf16(rt, units);
    return string.value();
}

pub fn fromCodePoint(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue {
    var units = std.ArrayList(u16).empty;
    defer units.deinit(rt.memory.allocator);
    for (args) |value| {
        if (value.isSymbol()) return error.TypeError;
        const number = try toIntegerOrInfinity(rt, value);
        if (std.math.isNan(number) or !std.math.isFinite(number) or number < 0 or number > 0x10ffff or @trunc(number) != number) {
            return error.RangeError;
        }
        const code_point: u32 = @intFromFloat(number);
        if (code_point <= 0xffff) {
            try units.append(rt.memory.allocator, @intCast(code_point));
        } else {
            const adjusted = code_point - 0x10000;
            try units.append(rt.memory.allocator, @intCast(0xd800 + (adjusted >> 10)));
            try units.append(rt.memory.allocator, @intCast(0xdc00 + (adjusted & 0x3ff)));
        }
    }
    const string = try core.string.String.createUtf16(rt, units.items);
    return string.value();
}

/// QuickJS source map: narrow charAt helper used by transitional
/// `string_char_at` bytecode.
pub fn charAtValue(rt: *core.JSRuntime, receiver: core.JSValue, index_value: core.JSValue) !core.JSValue {
    const index = try stringInteger(rt, index_value);
    if (stringValueFromReceiver(receiver)) |string_value| {
        if (index < 0 or index >= @as(i64, @intCast(string_value.len()))) return createStringValue(rt, "");
        return codeUnitStringValue(rt, string_value.codeUnitAt(@intCast(index)));
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
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
    if (id == 28) return lastIndexOfReceiver(rt, receiver, args);
    if (id == 32) return sliceReceiver(rt, receiver, args);
    if (id == 38) return isWellFormedReceiver(rt, receiver);
    if (id == 39) return toWellFormedReceiver(rt, receiver);

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendStringReceiverBytes(rt, &bytes, receiver);

    return switch (id) {
        1 => unreachable,
        2 => unreachable,
        3 => unreachable,
        4 => unreachable,
        5 => unreachable,
        6 => unreachable,
        7 => unreachable,
        8 => unreachable,
        9 => {
            if (args.len != 0) return error.TypeError;
            return createStringValue(rt, bytes.items);
        },
        10 => concat(rt, bytes.items, args),
        11 => htmlWithAttribute(rt, bytes.items, "a", "name", args),
        12 => htmlWrap(rt, bytes.items, "big"),
        13 => htmlWrap(rt, bytes.items, "blink"),
        14 => htmlWrap(rt, bytes.items, "b"),
        15 => htmlWrap(rt, bytes.items, "tt"),
        16 => htmlWithAttribute(rt, bytes.items, "font", "color", args),
        17 => htmlWithAttribute(rt, bytes.items, "font", "size", args),
        18 => htmlWrap(rt, bytes.items, "i"),
        19 => htmlWithAttribute(rt, bytes.items, "a", "href", args),
        20 => htmlWrap(rt, bytes.items, "small"),
        21 => unreachable,
        22 => unreachable,
        23 => htmlWrap(rt, bytes.items, "strike"),
        24 => htmlWrap(rt, bytes.items, "sub"),
        25 => substr(rt, bytes.items, args),
        26 => htmlWrap(rt, bytes.items, "sup"),
        legacy_split_method_id => unreachable,
        28 => unreachable,
        29 => unreachable,
        30 => unreachable,
        31 => unreachable,
        32 => unreachable,
        33 => repeat(rt, bytes.items, args),
        34 => pad(rt, bytes.items, args, .start),
        35 => pad(rt, bytes.items, args, .end),
        36 => localeCompare(rt, bytes.items, args),
        legacy_normalize_method_id => normalize(rt, bytes.items, args),
        38 => unreachable,
        39 => unreachable,
        legacy_search_method_id => search(rt, bytes.items, args),
        legacy_match_method_id => match(rt, bytes.items, args),
        legacy_replace_all_method_id => replaceAll(rt, bytes.items, args),
        else => error.TypeError,
    };
}

fn concat(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(rt.memory.allocator);
    try out.appendSlice(rt.memory.allocator, bytes);
    for (args) |arg| try appendValueString(rt, &out, arg);
    return createStringValue(rt, out.items);
}

fn substring(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue {
    const range = try stringSubstringRange(rt, bytes.len, args);
    return createStringValue(rt, bytes[range.start..range.end]);
}

fn substringReceiver(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    if (stringValueFromReceiver(receiver)) |string_value| {
        const range = try stringSubstringRange(rt, string_value.len(), args);
        const res = try core.string.String.createSlice(rt, string_value, range.start, range.end - range.start);
        return res.value();
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendStringReceiverBytes(rt, &bytes, receiver);
    return substring(rt, bytes.items, args);
}

fn trimReceiver(rt: *core.JSRuntime, receiver: core.JSValue, mode: TrimMode) !core.JSValue {
    if (stringValueFromReceiver(receiver)) |string_value| {
        return trimStringValue(rt, string_value, mode);
    }
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendStringReceiverBytes(rt, &bytes, receiver);
    const trimmed = switch (mode) {
        .start => trimStartAscii(bytes.items),
        .end => trimEndAscii(bytes.items),
        .both => std.mem.trim(u8, bytes.items, " \t\r\n"),
    };
    return createStringValue(rt, trimmed);
}

fn trimStringValue(rt: *core.JSRuntime, string_value: *core.string.String, mode: TrimMode) !core.JSValue {
    var start: usize = 0;
    var end = string_value.len();
    if (mode == .start or mode == .both) {
        while (start < end and isTrimCodeUnit(string_value.codeUnitAt(start))) : (start += 1) {}
    }
    if (mode == .end or mode == .both) {
        while (end > start and isTrimCodeUnit(string_value.codeUnitAt(end - 1))) : (end -= 1) {}
    }
    switch (string_value.resolveData()) {
        .latin1 => |bytes| return createLatin1SliceValue(rt, bytes[start..end]),
        .utf16 => |units| return (try core.string.String.createUtf16(rt, units[start..end])).value(),
    }
}

fn isWellFormedReceiver(rt: *core.JSRuntime, receiver: core.JSValue) !core.JSValue {
    if (stringValueFromReceiver(receiver)) |string_value| {
        return core.JSValue.boolean(isWellFormedString(string_value));
    }
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendStringReceiverBytes(rt, &bytes, receiver);
    return core.JSValue.boolean(true);
}

fn toWellFormedReceiver(rt: *core.JSRuntime, receiver: core.JSValue) !core.JSValue {
    if (stringValueFromReceiver(receiver)) |string_value| {
        return toWellFormedString(rt, string_value);
    }
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendStringReceiverBytes(rt, &bytes, receiver);
    return createStringValue(rt, bytes.items);
}

fn isWellFormedString(string_value: *core.string.String) bool {
    var i: usize = 0;
    while (i < string_value.len()) {
        const unit = string_value.codeUnitAt(i);
        if (isHighSurrogateUnit(unit)) {
            if (i + 1 >= string_value.len() or !isLowSurrogateUnit(string_value.codeUnitAt(i + 1))) return false;
            i += 2;
            continue;
        }
        if (isLowSurrogateUnit(unit)) return false;
        i += 1;
    }
    return true;
}

fn toWellFormedString(rt: *core.JSRuntime, string_value: *core.string.String) !core.JSValue {
    var units = std.ArrayList(u16).empty;
    defer units.deinit(rt.memory.allocator);
    try units.ensureTotalCapacity(rt.memory.allocator, string_value.len());

    var i: usize = 0;
    while (i < string_value.len()) {
        const unit = string_value.codeUnitAt(i);
        if (isHighSurrogateUnit(unit)) {
            if (i + 1 < string_value.len() and isLowSurrogateUnit(string_value.codeUnitAt(i + 1))) {
                units.appendAssumeCapacity(unit);
                units.appendAssumeCapacity(string_value.codeUnitAt(i + 1));
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
    return (try core.string.String.createUtf16(rt, units.items)).value();
}

fn isHighSurrogateUnit(unit: u16) bool {
    return unicode.isHighSurrogateUnit(unit);
}

fn isLowSurrogateUnit(unit: u16) bool {
    return unicode.isLowSurrogateUnit(unit);
}

fn substr(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue {
    if (args.len < 1 or args.len > 2) return error.TypeError;
    var start = try stringInteger(rt, args[0]);
    const len_i64: i64 = if (args.len >= 2 and !args[1].isUndefined()) blk: {
        const raw = try stringInteger(rt, args[1]);
        break :blk if (raw <= 0) 0 else raw;
    } else @intCast(bytes.len);
    const total: i64 = @intCast(bytes.len);
    if (start < 0) start = @max(total + start, 0);
    start = @min(start, total);
    const end = @min(start + len_i64, total);
    return createStringValue(rt, bytes[@intCast(start)..@intCast(end)]);
}

/// Mirrors the non-RegExp core of QuickJS `js_string_split`
/// (`quickjs.c:45749-45836`): convert receiver/separator to strings and
/// create an ordinary array of substrings.
fn split(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue {
    var rooted_args_buffer = try core.runtime.ValueRootBuffer.initCopy(rt, args);
    defer rooted_args_buffer.deinit(rt);
    const rooted_args = rooted_args_buffer.values;
    var out_value = core.JSValue.undefinedValue();
    var root_slices = [_]core.runtime.ValueRootSlice{
        rooted_args_buffer.slice(),
    };
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &out_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .slices = &root_slices,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const out = try core.Object.createArray(rt, null);
    out_value = out.value();
    errdefer {
        const failed_out = out_value;
        out_value = core.JSValue.undefinedValue();
        failed_out.free(rt);
    }

    const limit: u32 = if (rooted_args.len >= 2 and !rooted_args[1].isUndefined())
        try toUint32Limit(rt, rooted_args[1])
    else
        std.math.maxInt(u32);
    if (limit == 0) return out_value;

    if (rooted_args.len == 0 or rooted_args[0].isUndefined()) {
        try defineStringElement(rt, out, 0, bytes);
        return out_value;
    }

    var sep = std.ArrayList(u8).empty;
    defer sep.deinit(rt.memory.allocator);
    try appendValueString(rt, &sep, rooted_args[0]);

    var out_index: u32 = 0;
    if (sep.items.len == 0) {
        var index: usize = 0;
        while (index < bytes.len and out_index < limit) : (index += 1) {
            try defineStringElement(rt, out, out_index, bytes[index .. index + 1]);
            out_index += 1;
        }
        return out_value;
    }

    var start: usize = 0;
    while (out_index < limit) {
        const found = std.mem.indexOfPos(u8, bytes, start, sep.items) orelse break;
        try defineStringElement(rt, out, out_index, bytes[start..found]);
        out_index += 1;
        start = found + sep.items.len;
    }
    if (out_index < limit) {
        try defineStringElement(rt, out, out_index, bytes[start..]);
    }
    return out_value;
}

fn splitReceiver(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    var rooted_receiver = receiver;
    var rooted_args_buffer = try core.runtime.ValueRootBuffer.initCopy(rt, args);
    defer rooted_args_buffer.deinit(rt);
    const rooted_args = rooted_args_buffer.values;
    var out_value = core.JSValue.undefinedValue();
    var sep_value = core.JSValue.undefinedValue();
    var root_slices = [_]core.runtime.ValueRootSlice{
        rooted_args_buffer.slice(),
    };
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_receiver },
        .{ .value = &out_value },
        .{ .value = &sep_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .slices = &root_slices,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    if (stringValueFromReceiver(rooted_receiver)) |string_value| {
        const out = try core.Object.createArray(rt, null);
        out_value = out.value();
        errdefer {
            const failed_out = out_value;
            out_value = core.JSValue.undefinedValue();
            failed_out.free(rt);
        }

        const limit: u32 = if (rooted_args.len >= 2 and !rooted_args[1].isUndefined())
            try toUint32Limit(rt, rooted_args[1])
        else
            std.math.maxInt(u32);
        if (limit == 0) return out_value;

        if (rooted_args.len == 0 or rooted_args[0].isUndefined()) {
            try defineStringSliceElement(rt, out, 0, string_value, 0, string_value.len());
            return out_value;
        }

        sep_value = try stringValueFromSearchArgument(rt, rooted_args[0]);
        defer sep_value.free(rt);
        const sep = stringValueFromReceiver(sep_value) orelse return error.TypeError;

        var out_index: u32 = 0;
        if (sep.len() == 0) {
            var index: usize = 0;
            while (index < string_value.len() and out_index < limit) : (index += 1) {
                const value = try codeUnitStringValue(rt, string_value.codeUnitAt(index));
                try defineValueElement(rt, out, out_index, value);
                out_index += 1;
            }
            return out_value;
        }

        var start: usize = 0;
        while (out_index < limit) {
            const found = stringIndexOfUnits(string_value, sep, start) orelse break;
            try defineStringSliceElement(rt, out, out_index, string_value, start, found - start);
            out_index += 1;
            start = found + sep.len();
        }
        if (out_index < limit) {
            try defineStringSliceElement(rt, out, out_index, string_value, start, string_value.len() - start);
        }
        return out_value;
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendStringReceiverBytes(rt, &bytes, rooted_receiver);
    return split(rt, bytes.items, rooted_args);
}

fn search(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue {
    var needle = std.ArrayList(u8).empty;
    defer needle.deinit(rt.memory.allocator);
    const search_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    try appendValueString(rt, &needle, search_value);
    const index = std.mem.indexOf(u8, bytes, needle.items);
    return core.JSValue.int32(if (index) |value| @intCast(value) else -1);
}

fn match(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue {
    var rooted_args_buffer = try core.runtime.ValueRootBuffer.initCopy(rt, args);
    defer rooted_args_buffer.deinit(rt);
    const rooted_args = rooted_args_buffer.values;
    var out_value = core.JSValue.undefinedValue();
    var input = core.JSValue.undefinedValue();
    var root_slices = [_]core.runtime.ValueRootSlice{
        rooted_args_buffer.slice(),
    };
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &out_value },
        .{ .value = &input },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .slices = &root_slices,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    var needle = std.ArrayList(u8).empty;
    defer needle.deinit(rt.memory.allocator);
    const search_value = if (rooted_args.len >= 1) rooted_args[0] else core.JSValue.undefinedValue();
    try appendValueString(rt, &needle, search_value);
    const index = std.mem.indexOf(u8, bytes, needle.items) orelse return core.JSValue.nullValue();

    const out = try core.Object.createArray(rt, null);
    out_value = out.value();
    errdefer {
        const failed_out = out_value;
        out_value = core.JSValue.undefinedValue();
        failed_out.free(rt);
    }
    try defineStringElement(rt, out, 0, bytes[index .. index + needle.items.len]);
    try defineIntProperty(rt, out, "index", @intCast(index));
    input = try createStringValue(rt, bytes);
    defer input.free(rt);
    const input_key = try rt.internAtom("input");
    defer rt.atoms.free(input_key);
    try out.defineOwnProperty(rt, input_key, core.Descriptor.data(input, true, false, true));
    return out_value;
}

fn replaceAll(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue {
    var search_value = std.ArrayList(u8).empty;
    defer search_value.deinit(rt.memory.allocator);
    const search_input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    try appendValueString(rt, &search_value, search_input);

    var replacement = std.ArrayList(u8).empty;
    defer replacement.deinit(rt.memory.allocator);
    const replacement_input = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    try appendValueString(rt, &replacement, replacement_input);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(rt.memory.allocator);
    if (search_value.items.len == 0) {
        try out.appendSlice(rt.memory.allocator, replacement.items);
        for (bytes) |byte| {
            try out.append(rt.memory.allocator, byte);
            try out.appendSlice(rt.memory.allocator, replacement.items);
        }
        return createStringValue(rt, out.items);
    }

    var start: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, start, search_value.items)) |found| {
        try out.appendSlice(rt.memory.allocator, bytes[start..found]);
        try out.appendSlice(rt.memory.allocator, replacement.items);
        start = found + search_value.items.len;
    }
    try out.appendSlice(rt.memory.allocator, bytes[start..]);
    return createStringValue(rt, out.items);
}

fn defineStringElement(rt: *core.JSRuntime, object: *core.Object, index: u32, bytes: []const u8) !void {
    var object_value = object.value();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &object_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const value = try createStringValue(rt, bytes);
    try defineValueElement(rt, object, index, value);
}

fn defineStringSliceElement(rt: *core.JSRuntime, object: *core.Object, index: u32, string_value: *core.string.String, start: usize, slice_len: usize) !void {
    var object_value = object.value();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &object_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const value = (try core.string.String.createSlice(rt, string_value, start, slice_len)).value();
    try defineValueElement(rt, object, index, value);
}

fn defineValueElement(rt: *core.JSRuntime, object: *core.Object, index: u32, value: core.JSValue) !void {
    var object_value = object.value();
    var rooted_value = value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &object_value },
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    defer rooted_value.free(rt);
    try object.defineOwnProperty(rt, core.atom.atomFromUInt32(index), core.Descriptor.data(rooted_value, true, true, true));
}

fn defineStringIndexProperty(rt: *core.JSRuntime, object: *core.Object, index: u32, bytes: []const u8) !void {
    var object_value = object.value();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &object_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const value = try createStringValue(rt, bytes);
    defer value.free(rt);
    try object.defineOwnProperty(rt, core.atom.atomFromUInt32(index), core.Descriptor.data(value, false, true, false));
}

fn defineStringIndexUnitProperty(rt: *core.JSRuntime, object: *core.Object, index: u32, unit: u16) !void {
    var object_value = object.value();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &object_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const units: [1]u16 = .{unit};
    const string = try core.string.String.createUtf16(rt, &units);
    const value = string.value();
    defer value.free(rt);
    try object.defineOwnProperty(rt, core.atom.atomFromUInt32(index), core.Descriptor.data(value, false, true, false));
}

fn htmlWrap(rt: *core.JSRuntime, bytes: []const u8, tag: []const u8) !core.JSValue {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(rt.memory.allocator);
    try out.append(rt.memory.allocator, '<');
    try out.appendSlice(rt.memory.allocator, tag);
    try out.append(rt.memory.allocator, '>');
    try out.appendSlice(rt.memory.allocator, bytes);
    try out.appendSlice(rt.memory.allocator, "</");
    try out.appendSlice(rt.memory.allocator, tag);
    try out.append(rt.memory.allocator, '>');
    return createStringValue(rt, out.items);
}

fn htmlWithAttribute(rt: *core.JSRuntime, bytes: []const u8, tag: []const u8, attr: []const u8, args: []const core.JSValue) !core.JSValue {
    if (args.len > 1) return error.TypeError;
    var attr_bytes = std.ArrayList(u8).empty;
    defer attr_bytes.deinit(rt.memory.allocator);
    if (args.len >= 1) try appendValueString(rt, &attr_bytes, args[0]) else try attr_bytes.appendSlice(rt.memory.allocator, "undefined");

    var out = std.ArrayList(u8).empty;
    defer out.deinit(rt.memory.allocator);
    try out.append(rt.memory.allocator, '<');
    try out.appendSlice(rt.memory.allocator, tag);
    try out.append(rt.memory.allocator, ' ');
    try out.appendSlice(rt.memory.allocator, attr);
    try out.appendSlice(rt.memory.allocator, "=\"");
    try appendEscapedHtmlAttribute(rt, &out, attr_bytes.items);
    try out.appendSlice(rt.memory.allocator, "\">");
    try out.appendSlice(rt.memory.allocator, bytes);
    try out.appendSlice(rt.memory.allocator, "</");
    try out.appendSlice(rt.memory.allocator, tag);
    try out.append(rt.memory.allocator, '>');
    return createStringValue(rt, out.items);
}

fn appendEscapedHtmlAttribute(rt: *core.JSRuntime, out: *std.ArrayList(u8), bytes: []const u8) !void {
    for (bytes) |byte| {
        if (byte == '"') {
            try out.appendSlice(rt.memory.allocator, "&quot;");
        } else {
            try out.append(rt.memory.allocator, byte);
        }
    }
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

fn unicodeCaseReceiver(rt: *core.JSRuntime, receiver: core.JSValue, to_lower: bool) !core.JSValue {
    const primitive = try toStringValueForMethod(rt, receiver);
    defer primitive.free(rt);
    const header = primitive.refHeader() orelse return error.TypeError;
    const string_value: *core.string.String = @fieldParentPtr("header", header);

    var units = std.ArrayList(u16).empty;
    defer units.deinit(rt.memory.allocator);

    var index: usize = 0;
    while (index < string_value.len()) {
        const span = codePointAtStringIndex(string_value.*, index);
        index = span.end;

        const mapping = if (to_lower and span.value == 0x03a3 and isFinalSigma(string_value.*, span.start, span.end))
            singleCaseMapping(0x03c2)
        else
            unicode.caseConvert(span.value, to_lower);

        for (mapping.codepoints[0..mapping.len]) |cp| {
            try appendUtf16CodePoint(rt, &units, cp);
        }
    }

    const string = try core.string.String.createUtf16(rt, units.items);
    return string.value();
}

fn toStringValueForMethod(rt: *core.JSRuntime, receiver: core.JSValue) !core.JSValue {
    if (receiver.isString()) return receiver.dup();
    if (receiver.isObject()) {
        const object = try expectObject(receiver);
        if (object.class_id == core.class.ids.string) {
            return (object.objectData() orelse return error.TypeError).dup();
        }
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(rt.memory.allocator);
        try appendValueString(rt, &bytes, receiver);
        return createStringValue(rt, bytes.items);
    }
    if (receiver.isNull() or receiver.isUndefined()) return error.TypeError;

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendValueString(rt, &bytes, receiver);
    return createStringValue(rt, bytes.items);
}

fn singleCaseMapping(cp: u21) unicode.CaseMapping {
    var mapping: unicode.CaseMapping = .{ .codepoints = undefined, .len = 1 };
    mapping.codepoints[0] = cp;
    return mapping;
}

const CodePointSpan = struct {
    value: u21,
    start: usize,
    end: usize,
};

fn codePointAtStringIndex(string_value: core.string.String, index: usize) CodePointSpan {
    const first = string_value.codeUnitAt(index);
    const next_index = index + 1;
    if (isHighSurrogateUnit(first) and next_index < string_value.len()) {
        const second = string_value.codeUnitAt(next_index);
        if (isLowSurrogateUnit(second)) {
            return .{ .value = unicode.codePointFromSurrogatePair(first, second), .start = index, .end = index + 2 };
        }
    }
    return .{ .value = @intCast(first), .start = index, .end = next_index };
}

fn codePointBeforeStringIndex(string_value: core.string.String, end: usize) ?CodePointSpan {
    if (end == 0) return null;
    const last_index = end - 1;
    const last = string_value.codeUnitAt(last_index);
    if (isLowSurrogateUnit(last) and last_index > 0) {
        const first_index = last_index - 1;
        const first = string_value.codeUnitAt(first_index);
        if (isHighSurrogateUnit(first)) {
            return .{ .value = unicode.codePointFromSurrogatePair(first, last), .start = first_index, .end = end };
        }
    }
    return .{ .value = @intCast(last), .start = last_index, .end = end };
}

fn appendUtf16CodePoint(rt: *core.JSRuntime, units: *std.ArrayList(u16), cp: u21) !void {
    if (cp <= 0xffff) {
        try units.append(rt.memory.allocator, @intCast(cp));
        return;
    }

    const adjusted = @as(u32, cp) - 0x10000;
    try units.append(rt.memory.allocator, @intCast(0xd800 + (adjusted >> 10)));
    try units.append(rt.memory.allocator, @intCast(0xdc00 + (adjusted & 0x3ff)));
}

fn isFinalSigma(string_value: core.string.String, sigma_start: usize, after_sigma: usize) bool {
    var before_index = sigma_start;
    while (true) {
        const previous = codePointBeforeStringIndex(string_value, before_index) orelse return false;
        before_index = previous.start;
        if (unicode.isCaseIgnorable(previous.value)) continue;
        if (!unicode.isCased(previous.value)) return false;
        break;
    }

    var next_index = after_sigma;
    while (next_index < string_value.len()) {
        const next = codePointAtStringIndex(string_value, next_index);
        next_index = next.end;
        if (unicode.isCaseIgnorable(next.value)) continue;
        return !unicode.isCased(next.value);
    }
    return true;
}

fn indexOf(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue {
    if (args.len < 1 or args.len > 2) return error.TypeError;
    var needle = std.ArrayList(u8).empty;
    defer needle.deinit(rt.memory.allocator);
    try appendValueString(rt, &needle, args[0]);
    const start = if (args.len >= 2) try stringSearchStart(rt, bytes.len, args[1]) else @as(usize, 0);
    const index = if (start <= bytes.len) std.mem.indexOfPos(u8, bytes, start, needle.items) else null;
    return core.JSValue.int32(if (index) |value| @intCast(value) else -1);
}

fn indexOfReceiver(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    if (stringValueFromReceiver(receiver)) |string_value| {
        const needle_value = try stringValueFromSearchArgument(rt, if (args.len >= 1) args[0] else core.JSValue.undefinedValue());
        defer needle_value.free(rt);
        const needle = stringValueFromReceiver(needle_value) orelse return error.TypeError;
        const start = if (args.len >= 2) try stringSearchStart(rt, string_value.len(), args[1]) else @as(usize, 0);
        const index = stringIndexOfUnits(string_value, needle, start);
        return core.JSValue.int32(if (index) |value| @intCast(value) else -1);
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendStringReceiverBytes(rt, &bytes, receiver);
    return indexOf(rt, bytes.items, args);
}

fn lastIndexOf(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue {
    if (args.len < 1 or args.len > 2) return error.TypeError;
    var needle = std.ArrayList(u8).empty;
    defer needle.deinit(rt.memory.allocator);
    try appendValueString(rt, &needle, args[0]);

    const default_start = if (needle.items.len <= bytes.len) bytes.len - needle.items.len else 0;
    const start = if (args.len >= 2 and !args[1].isUndefined())
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
    if (stringValueFromReceiver(receiver)) |string_value| {
        const needle_value = try stringValueFromSearchArgument(rt, if (args.len >= 1) args[0] else core.JSValue.undefinedValue());
        defer needle_value.free(rt);
        const needle = stringValueFromReceiver(needle_value) orelse return error.TypeError;

        if (needle.len() == 0) {
            const start = if (args.len >= 2 and !args[1].isUndefined())
                try stringLastSearchStart(rt, string_value.len(), args[1])
            else
                string_value.len();
            return core.JSValue.int32(@intCast(start));
        }
        if (needle.len() > string_value.len()) return core.JSValue.int32(-1);

        const default_start = string_value.len() - needle.len();
        const start = if (args.len >= 2 and !args[1].isUndefined())
            try stringLastSearchStart(rt, default_start, args[1])
        else
            default_start;
        const index = stringLastIndexOfUnits(string_value, needle, start);
        return core.JSValue.int32(if (index) |value| @intCast(value) else -1);
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendStringReceiverBytes(rt, &bytes, receiver);
    return lastIndexOf(rt, bytes.items, args);
}

fn charCodeAtReceiver(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const primitive = try stringPrimitiveValue(receiver);
    defer primitive.free(rt);
    const header = primitive.refHeader() orelse return error.TypeError;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    const index = if (args.len >= 1) try stringInteger(rt, args[0]) else 0;
    if (index < 0 or index >= @as(i64, @intCast(string_value.len()))) return core.JSValue.float64(std.math.nan(f64));
    return core.JSValue.int32(string_value.codeUnitAt(@intCast(index)));
}

fn codePointAtReceiver(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const primitive = try stringPrimitiveValue(receiver);
    defer primitive.free(rt);
    const header = primitive.refHeader() orelse return error.TypeError;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    const index = if (args.len >= 1) try stringInteger(rt, args[0]) else 0;
    if (index < 0 or index >= @as(i64, @intCast(string_value.len()))) return core.JSValue.undefinedValue();
    const unit = string_value.codeUnitAt(@intCast(index));
    if (isHighSurrogateUnit(unit) and index + 1 < string_value.len()) {
        const next = string_value.codeUnitAt(@intCast(index + 1));
        if (isLowSurrogateUnit(next)) {
            return core.JSValue.int32(@intCast(unicode.codePointFromSurrogatePair(unit, next)));
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
    if (stringValueFromReceiver(receiver)) |string_value| {
        const relative = if (args.len >= 1) try stringInteger(rt, args[0]) else 0;
        const len: i64 = @intCast(string_value.len());
        const index = if (relative < 0) len + relative else relative;
        if (index < 0 or index >= len) return core.JSValue.undefinedValue();
        return codeUnitStringValue(rt, string_value.codeUnitAt(@intCast(index)));
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendStringReceiverBytes(rt, &bytes, receiver);
    return at(rt, bytes.items, args);
}

fn slice(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue {
    const len: i64 = @intCast(bytes.len);
    var start = if (args.len >= 1) try stringInteger(rt, args[0]) else 0;
    var end = if (args.len >= 2 and !args[1].isUndefined()) try stringInteger(rt, args[1]) else len;
    if (start < 0) start = @max(len + start, 0) else start = @min(start, len);
    if (end < 0) end = @max(len + end, 0) else end = @min(end, len);
    if (end < start) end = start;
    return createStringValue(rt, bytes[@intCast(start)..@intCast(end)]);
}

fn sliceReceiver(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    if (stringValueFromReceiver(receiver)) |string_value| {
        const range = try stringSliceRange(rt, string_value.len(), args);
        const res = try core.string.String.createSlice(rt, string_value, range.start, range.end - range.start);
        return res.value();
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
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
    const end_raw = if (args.len >= 2 and !args[1].isUndefined()) try stringInteger(rt, args[1]) else len;
    const start: usize = @intCast(@max(@as(i64, 0), @min(start_raw, len)));
    const end: usize = @intCast(@max(@as(i64, 0), @min(end_raw, len)));
    return .{ .start = @min(start, end), .end = @max(start, end) };
}

fn stringSliceRange(rt: *core.JSRuntime, len_usize: usize, args: []const core.JSValue) !StringSliceRange {
    const len: i64 = @intCast(len_usize);
    var start = if (args.len >= 1) try stringInteger(rt, args[0]) else 0;
    var end = if (args.len >= 2 and !args[1].isUndefined()) try stringInteger(rt, args[1]) else len;
    if (start < 0) start = @max(len + start, 0) else start = @min(start, len);
    if (end < 0) end = @max(len + end, 0) else end = @min(end, len);
    if (end < start) end = start;
    return .{ .start = @intCast(start), .end = @intCast(end) };
}

fn repeat(rt: *core.JSRuntime, bytes: []const u8, args: []const core.JSValue) !core.JSValue {
    const count = if (args.len >= 1) try stringInteger(rt, args[0]) else 0;
    if (count < 0 or count == std.math.maxInt(i64)) return error.RangeError;
    if (bytes.len == 0 or count == 0) return createStringValue(rt, "");
    const repeat_count: usize = @intCast(count);
    const total = try std.math.mul(usize, bytes.len, repeat_count);
    var out = try rt.memory.allocator.alloc(u8, total);
    defer rt.memory.allocator.free(out);
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
    defer fill.deinit(rt.memory.allocator);
    if (args.len >= 2 and !args[1].isUndefined()) {
        try appendValueString(rt, &fill, args[1]);
    } else {
        try fill.append(rt.memory.allocator, ' ');
    }
    if (fill.items.len == 0) return createStringValue(rt, bytes);

    var out = try rt.memory.allocator.alloc(u8, target_len);
    defer rt.memory.allocator.free(out);
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
    defer other.deinit(rt.memory.allocator);
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
    if (args.len >= 1 and !args[0].isUndefined()) {
        var form = std.ArrayList(u8).empty;
        defer form.deinit(rt.memory.allocator);
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
    defer needle.deinit(rt.memory.allocator);
    try appendValueString(rt, &needle, args[0]);
    const pos = if (args.len >= 2) try stringSearchStart(rt, bytes.len, args[1]) else 0;
    const found = switch (mode) {
        .contains => if (pos <= bytes.len) std.mem.indexOfPos(u8, bytes, pos, needle.items) != null else false,
        .starts => pos <= bytes.len and std.mem.startsWith(u8, bytes[pos..], needle.items),
        .ends => blk: {
            const end = if (args.len >= 2 and !args[1].isUndefined()) pos else bytes.len;
            if (needle.items.len > end) break :blk false;
            break :blk std.mem.eql(u8, bytes[end - needle.items.len .. end], needle.items);
        },
    };
    return core.JSValue.boolean(found);
}

fn containsReceiver(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue, mode: StringContainsMode) !core.JSValue {
    if (stringValueFromReceiver(receiver)) |string_value| {
        const needle_value = try stringValueFromSearchArgument(rt, if (args.len >= 1) args[0] else core.JSValue.undefinedValue());
        defer needle_value.free(rt);
        const needle = stringValueFromReceiver(needle_value) orelse return error.TypeError;
        const pos = if (args.len >= 2) try stringSearchStart(rt, string_value.len(), args[1]) else 0;
        const found = switch (mode) {
            .contains => stringIndexOfUnits(string_value, needle, pos) != null,
            .starts => stringMatchesAtUnits(string_value, needle, pos),
            .ends => blk: {
                const end = if (args.len >= 2 and !args[1].isUndefined()) pos else string_value.len();
                if (needle.len() > end) break :blk false;
                break :blk stringMatchesAtUnits(string_value, needle, end - needle.len());
            },
        };
        return core.JSValue.boolean(found);
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendStringReceiverBytes(rt, &bytes, receiver);
    return contains(rt, bytes.items, args, mode);
}

fn appendStringReceiverBytes(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), target: core.JSValue) !void {
    if (target.isString()) {
        try appendRawString(rt, buffer, target);
        return;
    }
    if (target.isObject()) {
        const object = try expectObject(target);
        if (object.class_id == core.class.ids.string) {
            const data = object.objectData() orelse return error.TypeError;
            try appendValueString(rt, buffer, data);
            return;
        }
        try appendValueString(rt, buffer, target);
        return;
    }
    if (target.isNull() or target.isUndefined()) return error.TypeError;
    try appendValueString(rt, buffer, target);
}

fn createStringValue(rt: *core.JSRuntime, bytes: []const u8) !core.JSValue {
    const str = if (core.string.isAsciiBytes(bytes))
        try core.string.String.createAscii(rt, bytes)
    else
        try core.string.String.createUtf8(rt, bytes);
    return str.value();
}

fn stringValueFromSearchArgument(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue {
    if (value.isString()) return value.dup();
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendValueString(rt, &bytes, value);
    return createStringValue(rt, bytes.items);
}

fn stringMatchesAtUnits(haystack: *core.string.String, needle: *core.string.String, start: usize) bool {
    if (start > haystack.len() or needle.len() > haystack.len() - start) return false;
    var offset: usize = 0;
    while (offset < needle.len()) : (offset += 1) {
        if (haystack.codeUnitAt(start + offset) != needle.codeUnitAt(offset)) return false;
    }
    return true;
}

fn stringIndexOfUnits(haystack: *core.string.String, needle: *core.string.String, start: usize) ?usize {
    if (start > haystack.len()) return null;
    if (needle.len() == 0) return start;
    if (needle.len() > haystack.len() - start) return null;
    var index = start;
    const limit = haystack.len() - needle.len();
    while (index <= limit) : (index += 1) {
        if (stringMatchesAtUnits(haystack, needle, index)) return index;
    }
    return null;
}

fn stringLastIndexOfUnits(haystack: *core.string.String, needle: *core.string.String, start: usize) ?usize {
    if (needle.len() == 0) return @min(start, haystack.len());
    if (needle.len() > haystack.len()) return null;
    var index = @min(start, haystack.len() - needle.len()) + 1;
    while (index > 0) {
        index -= 1;
        if (stringMatchesAtUnits(haystack, needle, index)) return index;
    }
    return null;
}

fn codeUnitStringValue(rt: *core.JSRuntime, unit: u16) !core.JSValue {
    return (try core.string.String.createUtf16(rt, &.{unit})).value();
}

fn createLatin1SliceValue(rt: *core.JSRuntime, bytes: []const u8) !core.JSValue {
    const str = try core.string.String.createLatin1(rt, bytes);
    return str.value();
}

fn stringPrimitiveValue(value: core.JSValue) !core.JSValue {
    if (value.isString()) return value.dup();
    const object = try expectObject(value);
    if (object.class_id != core.class.ids.string) return error.TypeError;
    return (object.objectData() orelse return error.TypeError).dup();
}

pub fn stringValueFromReceiver(value: core.JSValue) ?*core.string.String {
    const string_value = if (value.isString())
        value
    else if (value.isObject()) blk: {
        const object = expectObject(value) catch return null;
        if (object.class_id != core.class.ids.string) return null;
        break :blk object.objectData() orelse return null;
    } else return null;
    const header = string_value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

fn iteratorResult(rt: *core.JSRuntime, value: core.JSValue, done: bool) !core.JSValue {
    var rooted_value = value;
    defer rooted_value.free(rt);
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const result = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &result.header);
    try result.defineOwnProperty(rt, core.atom.predefinedId("value", .string).?, core.Descriptor.data(rooted_value, true, true, true));
    try result.defineOwnProperty(rt, core.atom.predefinedId("done", .string).?, core.Descriptor.data(core.JSValue.boolean(done), true, true, true));
    return result.value();
}

test "string iteratorResult roots direct function bytecode value while creating result" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const fb_slice = try rt.memory.alloc(core.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = core.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-string-iterator-result-bytecode-symbol");
    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    fb.cpool[0] = core.JSValue.symbol(symbol_atom);
    fb.cpool_count = 1;

    var result_value = core.JSValue.functionBytecode(&fb.header);
    var result_alive = true;
    defer if (result_alive) result_value.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const iterator_result_value = try iteratorResult(rt, result_value.dup(), false);
    var iterator_result_alive = true;
    defer if (iterator_result_alive) iterator_result_value.free(rt);
    const iterator_result = try expectObject(iterator_result_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = iterator_result.getProperty(core.atom.predefinedId("value", .string).?);
    defer stored.free(rt);
    try std.testing.expect(stored.same(result_value));

    iterator_result_value.free(rt);
    iterator_result_alive = false;
    result_value.free(rt);
    result_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "string wrapper iterator split and match helpers keep values under GC" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const text = try createStringValue(rt, "aba");
    defer text.free(rt);

    const wrapper_value = try constructWithPrototype(rt, &.{text}, null);
    defer wrapper_value.free(rt);
    const wrapper = try expectObject(wrapper_value);
    const wrapped_data = wrapper.objectData() orelse return error.TypeError;
    const wrapped_string = stringValueFromReceiver(wrapped_data) orelse return error.TypeError;
    try std.testing.expect(wrapped_string.eqlBytes("aba"));

    const iterator_value = try iterator(rt, text);
    defer iterator_value.free(rt);
    const iterator_object = try expectObject(iterator_value);
    const iterator_target = iterator_object.iteratorTarget() orelse return error.TypeError;
    const iterator_string = stringValueFromReceiver(iterator_target) orelse return error.TypeError;
    try std.testing.expect(iterator_string.eqlBytes("aba"));

    const separator = try createStringValue(rt, "b");
    defer separator.free(rt);
    const split_value = try splitReceiver(rt, text, &.{separator});
    defer split_value.free(rt);
    const split_object = try expectObject(split_value);
    const split_first = split_object.getProperty(core.atom.atomFromUInt32(0));
    defer split_first.free(rt);
    const split_second = split_object.getProperty(core.atom.atomFromUInt32(1));
    defer split_second.free(rt);
    try std.testing.expect((stringValueFromReceiver(split_first) orelse return error.TypeError).eqlBytes("a"));
    try std.testing.expect((stringValueFromReceiver(split_second) orelse return error.TypeError).eqlBytes("a"));

    const needle = try createStringValue(rt, "ba");
    defer needle.free(rt);
    const match_value = try match(rt, "ababa", &.{needle});
    defer match_value.free(rt);
    const match_object = try expectObject(match_value);
    const match_item = match_object.getProperty(core.atom.atomFromUInt32(0));
    defer match_item.free(rt);
    try std.testing.expect((stringValueFromReceiver(match_item) orelse return error.TypeError).eqlBytes("ba"));
    const input_key = try rt.internAtom("input");
    defer rt.atoms.free(input_key);
    const input_value = match_object.getProperty(input_key);
    defer input_value.free(rt);
    try std.testing.expect((stringValueFromReceiver(input_value) orelse return error.TypeError).eqlBytes("ababa"));
}

fn expectObject(value: core.JSValue) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    return @fieldParentPtr("header", header);
}

fn defineIntProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: i32) !void {
    var object_value = object.value();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &object_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(value), true, true, true));
}

fn defineReadonlyIntProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: i32) !void {
    var object_value = object.value();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &object_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(value), false, false, false));
}

fn appendValueString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) AppendStringError!void {
    if (value.asInt32()) |int_value| {
        var int_buf: [32]u8 = undefined;
        const printed = try std.fmt.bufPrint(&int_buf, "{d}", .{int_value});
        try buffer.appendSlice(rt.memory.allocator, printed);
    } else if (value.asFloat64()) |float_value| {
        if (std.math.isNan(float_value)) {
            try buffer.appendSlice(rt.memory.allocator, "NaN");
        } else if (std.math.isPositiveInf(float_value)) {
            try buffer.appendSlice(rt.memory.allocator, "Infinity");
        } else if (std.math.isNegativeInf(float_value)) {
            try buffer.appendSlice(rt.memory.allocator, "-Infinity");
        } else if (std.math.isNegativeZero(float_value)) {
            try buffer.append(rt.memory.allocator, '0');
        } else {
            var float_buf: [64]u8 = undefined;
            const printed = try core.value_format.formatFiniteNumber(&float_buf, float_value);
            try buffer.appendSlice(rt.memory.allocator, printed);
        }
    } else if (value.isBigInt()) {
        var big = try cloneBigIntValue(rt, value);
        defer big.deinit();
        const printed = try big.formatBase10Alloc(rt.memory.allocator);
        defer rt.memory.allocator.free(printed);
        try buffer.appendSlice(rt.memory.allocator, printed);
    } else if (value.asBool()) |bool_value| {
        try buffer.appendSlice(rt.memory.allocator, if (bool_value) "true" else "false");
    } else if (value.isUndefined()) {
        try buffer.appendSlice(rt.memory.allocator, "undefined");
    } else if (value.isNull()) {
        try buffer.appendSlice(rt.memory.allocator, "null");
    } else if (value.isString()) {
        try appendRawString(rt, buffer, value);
    } else if (value.isObject()) {
        const header = value.refHeader() orelse return;
        const object_value: *core.Object = @fieldParentPtr("header", header);
        if (object_value.class_id == core.class.ids.string) {
            const data = object_value.objectData() orelse return error.TypeError;
            try appendValueString(rt, buffer, data);
        } else if (object_value.class_id == core.class.ids.number or object_value.class_id == core.class.ids.boolean or
            object_value.class_id == core.class.ids.big_int or object_value.class_id == core.class.ids.symbol)
        {
            const primitive = (object_value.objectData() orelse return error.TypeError).dup();
            defer primitive.free(rt);
            try appendValueString(rt, buffer, primitive);
        } else if (object_value.class_id == core.class.ids.array_buffer) {
            try buffer.appendSlice(rt.memory.allocator, "[object ArrayBuffer]");
        } else if (object_value.class_id == core.class.ids.promise) {
            try buffer.appendSlice(rt.memory.allocator, "[object Promise]");
        } else if (object_value.is_array) {
            try appendArrayString(rt, buffer, object_value);
        } else {
            try buffer.appendSlice(rt.memory.allocator, "[object Object]");
        }
    } else {
        try buffer.appendSlice(rt.memory.allocator, "[object Object]");
    }
}

fn appendRawString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) !void {
    const header = value.refHeader() orelse return;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    switch (string_value.resolveData()) {
        .latin1 => |bytes| {
            for (bytes) |byte| try appendUtf8CodePoint(rt, buffer, byte);
        },
        .utf16 => |units| {
            for (units) |unit| try appendUtf8CodePoint(rt, buffer, unit);
        },
    }
}

fn appendArrayString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), object: *core.Object) AppendStringError!void {
    var index: u32 = 0;
    while (index < object.length) : (index += 1) {
        if (index != 0) try buffer.append(rt.memory.allocator, ',');
        const value = object.getProperty(core.atom.atomFromUInt32(index));
        defer value.free(rt);
        if (!value.isUndefined() and !value.isNull()) try appendValueString(rt, buffer, value);
    }
}

fn stringSearchStart(rt: *core.JSRuntime, length: usize, value: core.JSValue) !usize {
    const number = try toIntegerOrInfinity(rt, value);
    if (std.math.isNan(number) or number <= 0) return 0;
    if (std.math.isPositiveInf(number)) return length;
    const truncated = @trunc(number);
    if (truncated >= @as(f64, @floatFromInt(length))) return length;
    return @intFromFloat(truncated);
}

fn stringLastSearchStart(rt: *core.JSRuntime, default_start: usize, value: core.JSValue) !usize {
    const number = try toIntegerOrInfinity(rt, value);
    if (std.math.isNan(number)) return default_start;
    if (number <= 0) return 0;
    if (std.math.isPositiveInf(number)) return default_start;
    const truncated = @trunc(number);
    if (truncated >= @as(f64, @floatFromInt(default_start))) return default_start;
    return @intFromFloat(truncated);
}

fn toUint32Limit(rt: *core.JSRuntime, value: core.JSValue) !u32 {
    if (value.isBigInt() or value.isSymbol()) return error.TypeError;
    const number = try toIntegerOrInfinity(rt, value);
    if (std.math.isNan(number) or !std.math.isFinite(number) or number == 0) return 0;
    const integer = if (number < 0) -@floor(@abs(number)) else @floor(number);
    const modulo = @mod(integer, 4294967296.0);
    return @intFromFloat(modulo);
}

fn toIntegerOrInfinity(rt: *core.JSRuntime, value: core.JSValue) !f64 {
    if (numberValue(value)) |number| return number;
    if (value.asBool()) |bool_value| return if (bool_value) 1 else 0;
    if (value.isNull()) return 0;
    if (value.isUndefined()) return std.math.nan(f64);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try appendValueString(rt, &buffer, value);
    return parseJsNumber(buffer.items);
}

fn stringInteger(rt: *core.JSRuntime, value: core.JSValue) !i64 {
    if (value.asInt32()) |int_value| return int_value;
    const number = try toIntegerOrInfinity(rt, value);
    if (std.math.isNan(number)) return 0;
    if (std.math.isPositiveInf(number)) return std.math.maxInt(i64);
    if (std.math.isNegativeInf(number)) return std.math.minInt(i64);
    const integer = if (number < 0) -@floor(@abs(number)) else @floor(number);
    return @intFromFloat(integer);
}

fn parseJsNumber(bytes: []const u8) f64 {
    return core.value_format.parseJsNumber(bytes);
}

fn cloneBigIntValue(rt: *core.JSRuntime, value: core.JSValue) !bignum.BigInt {
    if (value.asShortBigInt()) |big_int| return bignum.BigInt.fromIntAlloc(rt.memory.allocator, big_int);
    if (value.isBigInt() and value.refHeader() != null) {
        const header = value.refHeader().?;
        const big: *core.bigint.BigInt = @alignCast(@fieldParentPtr("header", header));
        return big.value.cloneWithAllocator(rt.memory.allocator);
    }
    return error.TypeError;
}

fn numberValue(value: core.JSValue) ?f64 {
    if (value.tag == core.Tag.int) return @floatFromInt(value.asInt32().?);
    if (value.tag == core.Tag.float64) return value.asFloat64().?;
    return null;
}

fn appendUtf8CodePoint(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), cp: u32) !void {
    return unicode.appendUtf8CodePoint(rt.memory.allocator, buffer, cp);
}

fn isTrimCodeUnit(unit: u16) bool {
    return switch (unit) {
        0x0009, 0x000a, 0x000b, 0x000c, 0x000d, 0x0020, 0x00a0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff => true,
        else => (unit >= 0x2000 and unit <= 0x200a),
    };
}

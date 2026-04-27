const core = @import("../core/root.zig");
const core_array = @import("../core/array.zig");
const bignum = @import("../libs/bignum.zig");
const std = @import("std");

pub fn isArrayIndex(bytes: []const u8) bool {
    return core_array.isArrayIndexName(bytes);
}

pub fn lengthAfterSet(index: u32, current: u32) u32 {
    if (index >= current) return index + 1;
    return current;
}

/// QuickJS source map: narrow array literal helper used by transitional
/// `new_array` bytecode.
pub fn construct(rt: *core.Runtime, values: []const core.Value) !core.Value {
    return constructWithPrototype(rt, values, null);
}

pub fn constructWithPrototype(rt: *core.Runtime, values: []const core.Value, prototype: ?*core.Object) !core.Value {
    const object = try core.Object.createArray(rt, prototype);
    errdefer core.Object.destroyFromHeader(rt, &object.header);

    for (values, 0..) |value, index| {
        try object.defineOwnProperty(rt, core.atom.atomFromUInt32(@intCast(index)), core.Descriptor.data(value, true, true, true));
    }
    return object.value();
}

/// QuickJS source map: selected Array.prototype.join behavior used by the
/// transitional `array_join` bytecode.
pub fn join(rt: *core.Runtime, array_value: core.Value, separator_value: core.Value) !core.Value {
    const object = try expectObject(array_value);

    var separator = std.ArrayList(u8).empty;
    defer separator.deinit(rt.memory.allocator);
    try appendValueString(rt, &separator, separator_value);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    var index: u32 = 0;
    while (index < object.length) : (index += 1) {
        if (index != 0) try buffer.appendSlice(rt.memory.allocator, separator.items);
        const item = object.getProperty(core.atom.atomFromUInt32(index));
        defer item.free(rt);
        if (!item.isUndefined() and !item.isNull()) try appendValueString(rt, &buffer, item);
    }
    return createStringValue(rt, buffer.items);
}

/// QuickJS source map: selected Array.prototype methods currently covered by
/// smoke fixtures and transitional array opcodes.
pub fn methodCall(rt: *core.Runtime, receiver: core.Value, method: u32, args: []const core.Value) !core.Value {
    return switch (method) {
        1 => {
            if (args.len != 0) return error.UnsupportedArrayCall;
            return filterEven(rt, receiver);
        },
        2 => {
            if (args.len != 0) return error.UnsupportedArrayCall;
            return reduceSum(rt, receiver);
        },
        4 => {
            if (args.len != 0) return error.UnsupportedArrayCall;
            return someEven(rt, receiver);
        },
        5 => {
            if (args.len != 0) return error.UnsupportedArrayCall;
            return everyPositive(rt, receiver);
        },
        6 => {
            if (args.len != 1) return error.UnsupportedArrayCall;
            return indexSearch(rt, receiver, args[0], .first);
        },
        7 => {
            if (args.len != 1) return error.UnsupportedArrayCall;
            return indexSearch(rt, receiver, args[0], .includes);
        },
        8 => {
            if (args.len != 1) return error.UnsupportedArrayCall;
            return indexSearch(rt, receiver, args[0], .last);
        },
        9 => {
            if (args.len != 1) return error.UnsupportedArrayCall;
            return at(rt, receiver, args[0]);
        },
        10 => {
            if (args.len != 1) return error.UnsupportedArrayCall;
            return slice(rt, receiver, args[0]);
        },
        11 => {
            if (args.len != 4) return error.UnsupportedArrayCall;
            return splice(rt, receiver, args);
        },
        13 => return push(rt, receiver, args),
        14 => {
            if (args.len != 0) return error.UnsupportedArrayCall;
            return pop(rt, receiver);
        },
        else => error.UnsupportedArrayCall,
    };
}

fn filterEven(rt: *core.Runtime, array_value: core.Value) !core.Value {
    const array = try expectArray(array_value);
    const out = try core.Object.createArray(rt, null);
    errdefer core.Object.destroyFromHeader(rt, &out.header);
    var out_index: u32 = 0;
    var index: u32 = 0;
    while (index < array.length) : (index += 1) {
        const item = array.getProperty(core.atom.atomFromUInt32(index));
        defer item.free(rt);
        if (item.asInt32()) |n| {
            if (@mod(n, 2) == 0) {
                try out.defineOwnProperty(rt, core.atom.atomFromUInt32(out_index), core.Descriptor.data(item, true, true, true));
                out_index += 1;
            }
        }
    }
    return out.value();
}

fn reduceSum(rt: *core.Runtime, array_value: core.Value) !core.Value {
    const array = try expectArray(array_value);
    var sum: i32 = 0;
    var index: u32 = 0;
    while (index < array.length) : (index += 1) {
        const item = array.getProperty(core.atom.atomFromUInt32(index));
        defer item.free(rt);
        sum += item.asInt32() orelse 0;
    }
    return core.Value.int32(sum);
}

fn someEven(rt: *core.Runtime, array_value: core.Value) !core.Value {
    const array = try expectArray(array_value);
    var found = false;
    var index: u32 = 0;
    while (index < array.length) : (index += 1) {
        const item = array.getProperty(core.atom.atomFromUInt32(index));
        defer item.free(rt);
        if (item.asInt32()) |n| found = found or @mod(n, 2) == 0;
    }
    return core.Value.boolean(found);
}

fn everyPositive(rt: *core.Runtime, array_value: core.Value) !core.Value {
    const array = try expectArray(array_value);
    var ok = true;
    var index: u32 = 0;
    while (index < array.length) : (index += 1) {
        const item = array.getProperty(core.atom.atomFromUInt32(index));
        defer item.free(rt);
        if ((item.asInt32() orelse 0) <= 0) ok = false;
    }
    return core.Value.boolean(ok);
}

const SearchMode = enum {
    first,
    includes,
    last,
};

fn indexSearch(rt: *core.Runtime, value: core.Value, needle: core.Value, mode: SearchMode) !core.Value {
    if (value.isString()) return stringSearchValue(rt, value, needle, mode);
    const array = try expectArray(value);
    var found_index: i32 = -1;
    var index: u32 = 0;
    while (index < array.length) : (index += 1) {
        const item = array.getProperty(core.atom.atomFromUInt32(index));
        defer item.free(rt);
        if (valuesEqual(item, needle)) {
            found_index = @intCast(index);
            if (mode != .last) break;
        }
    }
    if (needle.isUndefined() and mode != .includes) found_index = @as(i32, @intCast(array.length)) - 1;
    return switch (mode) {
        .includes => core.Value.boolean(found_index >= 0),
        else => core.Value.int32(found_index),
    };
}

fn stringSearchValue(rt: *core.Runtime, value: core.Value, needle: core.Value, mode: SearchMode) !core.Value {
    var haystack = std.ArrayList(u8).empty;
    defer haystack.deinit(rt.memory.allocator);
    try appendRawString(rt, &haystack, value);
    var query = std.ArrayList(u8).empty;
    defer query.deinit(rt.memory.allocator);
    try appendValueString(rt, &query, needle);
    const index = std.mem.indexOf(u8, haystack.items, query.items);
    return switch (mode) {
        .includes => core.Value.boolean(index != null),
        else => core.Value.int32(if (index) |found| @intCast(found) else -1),
    };
}

fn at(_: *core.Runtime, array_value: core.Value, index_value: core.Value) !core.Value {
    const array = try expectArray(array_value);
    var index = index_value.asInt32() orelse 0;
    if (index < 0) index = @as(i32, @intCast(array.length)) + index;
    if (index < 0 or index >= array.length) return core.Value.undefinedValue();
    return array.getProperty(core.atom.atomFromUInt32(@intCast(index)));
}

fn slice(rt: *core.Runtime, array_value: core.Value, start_value: core.Value) !core.Value {
    const array = try expectArray(array_value);
    var start = start_value.asInt32() orelse 0;
    if (start < 0) start = @as(i32, @intCast(array.length)) + start;
    if (start < 0) start = 0;
    const out = try core.Object.createArray(rt, null);
    errdefer core.Object.destroyFromHeader(rt, &out.header);
    var out_index: u32 = 0;
    var index: u32 = @intCast(start);
    while (index < array.length) : (index += 1) {
        const item = array.getProperty(core.atom.atomFromUInt32(index));
        defer item.free(rt);
        try out.defineOwnProperty(rt, core.atom.atomFromUInt32(out_index), core.Descriptor.data(item, true, true, true));
        out_index += 1;
    }
    return out.value();
}

fn splice(rt: *core.Runtime, array_value: core.Value, args: []const core.Value) !core.Value {
    const array = try expectArray(array_value);
    const start: u32 = @intCast(args[0].asInt32() orelse 0);
    const delete_count: u32 = @intCast(args[1].asInt32() orelse 0);
    const insert_a = args[2];
    const insert_b = args[3];

    const removed = try core.Object.createArray(rt, null);
    errdefer core.Object.destroyFromHeader(rt, &removed.header);
    var i: u32 = 0;
    while (i < delete_count) : (i += 1) {
        const item = array.getProperty(core.atom.atomFromUInt32(start + i));
        defer item.free(rt);
        try removed.defineOwnProperty(rt, core.atom.atomFromUInt32(i), core.Descriptor.data(item, true, true, true));
    }
    const tail = array.getProperty(core.atom.atomFromUInt32(start + delete_count));
    defer tail.free(rt);
    try array.defineOwnProperty(rt, core.atom.atomFromUInt32(start), core.Descriptor.data(insert_a, true, true, true));
    try array.defineOwnProperty(rt, core.atom.atomFromUInt32(start + 1), core.Descriptor.data(insert_b, true, true, true));
    if (!tail.isUndefined()) try array.defineOwnProperty(rt, core.atom.atomFromUInt32(start + 2), core.Descriptor.data(tail, true, true, true));
    return removed.value();
}

fn push(rt: *core.Runtime, array_value: core.Value, args: []const core.Value) !core.Value {
    const array = try expectArray(array_value);
    for (args) |item| {
        try array.defineOwnProperty(rt, core.atom.atomFromUInt32(array.length), core.Descriptor.data(item, true, true, true));
    }
    return core.Value.int32(@intCast(array.length));
}

fn pop(rt: *core.Runtime, array_value: core.Value) !core.Value {
    const array = try expectArray(array_value);
    if (array.length == 0) return core.Value.undefinedValue();
    const index = array.length - 1;
    const key = core.atom.atomFromUInt32(index);
    const value = array.getProperty(key);
    _ = array.deleteProperty(rt, key);
    try array.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.Value.int32(@intCast(index)), true, false, false));
    return value;
}

fn expectObject(value: core.Value) !*core.Object {
    const header = value.refHeader() orelse return error.UnsupportedArrayCall;
    if (!value.isObject()) return error.UnsupportedArrayCall;
    return @fieldParentPtr("header", header);
}

pub fn expectArray(value: core.Value) !*core.Object {
    const object = try expectObject(value);
    if (!object.is_array) return error.UnsupportedArrayCall;
    return object;
}

fn createStringValue(rt: *core.Runtime, bytes: []const u8) !core.Value {
    const str = try core.string.String.createUtf8(rt, bytes);
    return str.value();
}

fn appendRawString(rt: *core.Runtime, buffer: *std.ArrayList(u8), value: core.Value) !void {
    const header = value.refHeader() orelse return;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    switch (string_value.data) {
        .latin1 => |bytes| try buffer.appendSlice(rt.memory.allocator, bytes),
        .utf16 => |units| {
            for (units) |unit| {
                if (unit <= 0x7f) try buffer.append(rt.memory.allocator, @intCast(unit));
            }
        },
    }
}

fn appendValueString(rt: *core.Runtime, buffer: *std.ArrayList(u8), value: core.Value) anyerror!void {
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
        } else if (isNegativeZero(float_value)) {
            try buffer.append(rt.memory.allocator, '0');
        } else {
            var float_buf: [64]u8 = undefined;
            const printed = try std.fmt.bufPrint(&float_buf, "{d}", .{float_value});
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
        const header = value.refHeader() orelse return;
        const string_value: *core.string.String = @fieldParentPtr("header", header);
        switch (string_value.data) {
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
    } else if (value.isObject()) {
        const header = value.refHeader() orelse return;
        const object_value: *core.Object = @fieldParentPtr("header", header);
        if (object_value.class_id == core.class.ids.string) {
            const data = object_value.string_data orelse return error.UnsupportedArrayCall;
            try appendValueString(rt, buffer, data);
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

fn appendArrayString(rt: *core.Runtime, buffer: *std.ArrayList(u8), object: *core.Object) anyerror!void {
    var index: u32 = 0;
    while (index < object.length) : (index += 1) {
        if (index != 0) try buffer.append(rt.memory.allocator, ',');
        const value = object.getProperty(core.atom.atomFromUInt32(index));
        defer value.free(rt);
        if (!value.isUndefined() and !value.isNull()) try appendValueString(rt, buffer, value);
    }
}

fn valuesEqual(a: core.Value, b: core.Value) bool {
    if (a.isBigInt() and b.isBigInt()) {
        return (compareBigIntValues(a, b) orelse return false) == .eq;
    }
    if (a.asInt32()) |ai| {
        if (b.asInt32()) |bi| return ai == bi;
    }
    if (a.asBool()) |ab| {
        if (b.asBool()) |bb| return ab == bb;
    }
    if (a.isNull() or a.isUndefined()) return a.same(b);
    if (a.isString() and b.isString()) {
        return (compareStringValues(a, b) orelse 1) == 0;
    }
    return a.same(b);
}

fn compareBigIntValues(a: core.Value, b: core.Value) ?std.math.Order {
    var lhs_scratch: [2]bignum.Limb = undefined;
    var rhs_scratch: [2]bignum.Limb = undefined;
    const lhs = bigIntParts(a, &lhs_scratch) orelse return null;
    const rhs = bigIntParts(b, &rhs_scratch) orelse return null;
    return bignum.compareParts(lhs.negative, lhs.limbs, rhs.negative, rhs.limbs);
}

const BigIntParts = struct {
    negative: bool,
    limbs: []const bignum.Limb,
};

fn bigIntParts(value: core.Value, scratch: *[2]bignum.Limb) ?BigIntParts {
    if (value.asShortBigInt()) |short| {
        const signed: i128 = short;
        var magnitude: u128 = if (signed < 0) @intCast(-signed) else @intCast(signed);
        var len: usize = 0;
        while (magnitude != 0) {
            scratch[len] = @truncate(magnitude);
            magnitude >>= 32;
            len += 1;
        }
        return .{
            .negative = short < 0,
            .limbs = scratch[0..len],
        };
    }
    if (value.isBigInt() and value.refHeader() != null) {
        const header = value.refHeader().?;
        const big: *core.bigint.BigInt = @alignCast(@fieldParentPtr("header", header));
        return .{ .negative = big.value.negative, .limbs = big.value.limbs };
    }
    return null;
}

fn compareStringValues(a: core.Value, b: core.Value) ?i32 {
    if (!a.isString() or !b.isString()) return null;
    const a_header = a.refHeader() orelse return null;
    const b_header = b.refHeader() orelse return null;
    const a_string: *core.string.String = @fieldParentPtr("header", a_header);
    const b_string: *core.string.String = @fieldParentPtr("header", b_header);
    return a_string.compare(b_string.*);
}

fn cloneBigIntValue(rt: *core.Runtime, value: core.Value) !bignum.BigInt {
    if (value.asShortBigInt()) |big_int| return bignum.BigInt.fromIntAlloc(rt.memory.allocator, big_int);
    if (value.isBigInt() and value.refHeader() != null) {
        const header = value.refHeader().?;
        const big: *core.bigint.BigInt = @alignCast(@fieldParentPtr("header", header));
        return big.value.cloneWithAllocator(rt.memory.allocator);
    }
    return error.TypeError;
}

fn isNegativeZero(value: f64) bool {
    return value == 0 and std.math.isNegativeInf(1.0 / value);
}

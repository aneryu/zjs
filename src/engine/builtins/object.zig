const core = @import("../core/root.zig");
const bignum = @import("../libs/bignum.zig");
const std = @import("std");

pub const EntriesMode = enum {
    keys,
    values,
    entries,
};

pub fn create(rt: *core.Runtime, prototype: ?*core.Object) !*core.Object {
    return core.Object.create(rt, core.class.ids.object, prototype);
}

pub fn keys(rt: *core.Runtime, object: *core.Object) ![]core.Atom {
    return object.ownKeys(rt);
}

/// QuickJS source map: narrow object-literal helper used by transitional
/// `new_object` bytecode.
pub fn literal(rt: *core.Runtime, names: []const core.Atom, values: []const core.Value) !core.Value {
    if (names.len != values.len) return error.UnsupportedObjectCall;
    const object = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &object.header);

    for (names, values) |name, value| {
        try object.defineOwnProperty(rt, name, core.Descriptor.data(value, true, true, true));
    }
    return object.value();
}

/// QuickJS source map: Object.keys / Object.values / Object.entries selected
/// behavior used by transitional object entry opcodes.
pub fn ownEntriesArray(rt: *core.Runtime, value: core.Value, mode: EntriesMode) !core.Value {
    const object = try expectObject(value);
    const owned_keys = try object.ownKeys(rt);
    defer core.Object.freeKeys(rt, owned_keys);

    const out = try core.Object.createArray(rt, null);
    errdefer core.Object.destroyFromHeader(rt, &out.header);
    for (owned_keys, 0..) |key, index| {
        const element = switch (mode) {
            .keys => try atomToStringValue(rt, key),
            .values => object.getProperty(key),
            .entries => try entryArrayValue(rt, key, object.getProperty(key)),
        };
        defer element.free(rt);
        try out.defineOwnProperty(rt, core.atom.atomFromUInt32(@intCast(index)), core.Descriptor.data(element, true, true, true));
    }
    return out.value();
}

pub fn sameValue(a: core.Value, b: core.Value) bool {
    if (numberValue(a)) |lhs| {
        if (numberValue(b)) |rhs| {
            if (std.math.isNan(lhs) and std.math.isNan(rhs)) return true;
            if (lhs == 0 and rhs == 0) return isNegativeZero(lhs) == isNegativeZero(rhs);
            return lhs == rhs;
        }
    }
    return valuesEqual(a, b);
}

fn expectObject(value: core.Value) !*core.Object {
    const header = value.refHeader() orelse return error.UnsupportedObjectCall;
    if (!value.isObject()) return error.UnsupportedObjectCall;
    return @fieldParentPtr("header", header);
}

fn entryArrayValue(rt: *core.Runtime, key: core.Atom, value: core.Value) !core.Value {
    defer value.free(rt);
    const array = try core.Object.createArray(rt, null);
    errdefer core.Object.destroyFromHeader(rt, &array.header);
    const key_value = try atomToStringValue(rt, key);
    defer key_value.free(rt);
    try array.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(key_value, true, true, true));
    try array.defineOwnProperty(rt, core.atom.atomFromUInt32(1), core.Descriptor.data(value, true, true, true));
    return array.value();
}

fn atomToStringValue(rt: *core.Runtime, atom_id: core.Atom) !core.Value {
    const name = rt.atoms.name(atom_id) orelse "";
    const str = try core.string.String.createUtf8(rt, name);
    return str.value();
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

fn numberValue(value: core.Value) ?f64 {
    if (value.asInt32()) |v| return @floatFromInt(v);
    if (value.asFloat64()) |v| return v;
    return null;
}

fn isNegativeZero(value: f64) bool {
    return value == 0 and std.math.isNegativeInf(1.0 / value);
}

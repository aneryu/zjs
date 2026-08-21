//! The bare-runtime `ToString` fallback: rendering a JSValue as UTF-8 bytes
//! without a realm to route a user-visible `toString` through.
//!
//! Seven hand-written copies of this operation existed — in `exec/value_ops`,
//! `exec/uri_ops`, `exec/array_builtin_ops`, `exec/string_builtin_ops`,
//! `exec/regexp_ops`, `core/typed_array` and `core/number` — together with
//! seven copies of the array leg and six of a BigInt cloner. They had drifted
//! on four axes, three of them accidental:
//!
//!   * float formatting: two copies used the ECMAScript `Number::toString`
//!     algorithm, five used Zig's `{d}`, which disagrees (`1e20` renders as
//!     `1e20`, not `100000000000000000000`). Unified onto the ES algorithm.
//!     The divergence was latent — every reachable path coerces through a
//!     realm-aware `ToString` before arriving here — but it sat one call site
//!     away from being observable.
//!   * BigInt: five copies cloned the value to format it; unified onto
//!     `value_format.appendBigIntBase10`, which does not.
//!   * strings: unified onto `string.appendValueUtf8`.
//!
//! The fourth axis is real and stays, as `Policy`: callers legitimately
//! disagree about Symbols, primitive wrapper objects, and what a value with no
//! `ToString` form becomes. It is comptime, so each site keeps exactly its old
//! behavior and pays nothing for the arms it does not use.

const std = @import("std");

const dtoa = @import("../libs/number_format.zig");
const atom = @import("atom.zig");
const class = @import("class.zig");
const context = @import("context.zig");
const object = @import("object.zig");
const runtime = @import("runtime.zig");
const string = @import("string.zig");
const symbol = @import("symbol.zig");
const value_format = @import("value_format.zig");
const value_mod = @import("value.zig");

const JSRuntime = runtime.JSRuntime;
const JSValue = value_mod.JSValue;
const Object = object.Object;

/// The error set every bare-runtime ToString site shares. Seven files each
/// declared this same union; they now alias it.
pub const AppendStringError = error{
    OutOfMemory,
    TypeError,
    InvalidRadix,
    NoSpaceLeft,
} || context.DynamicImportError;

pub const Policy = struct {
    /// A Symbol has no `ToString` form. `.describe` writes `Symbol(<desc>)`,
    /// the inspect form the public value printer wants; `.unsupported` falls
    /// through to the `unsupported` arm below, which is what a spec-facing
    /// conversion wants.
    symbol: enum { describe, unsupported } = .unsupported,
    /// Unwrap `Number`/`Boolean`/`BigInt`/`Symbol` wrapper objects to their
    /// primitive before rendering, instead of tagging them `[object Object]`.
    unwrap_wrappers: bool = false,
    /// What a value with no `ToString` form renders as.
    unsupported: enum { object_tag, type_error } = .object_tag,
};

pub fn appendValueString(
    rt: *JSRuntime,
    buffer: *std.ArrayList(u8),
    value: JSValue,
    comptime policy: Policy,
) AppendStringError!void {
    if (comptime policy.symbol == .describe) {
        if (value.asSymbolAtom()) |atom_id| {
            const description = symbol.description(&rt.atoms, atom_id) orelse "";
            try buffer.appendSlice(rt.memory.allocator, "Symbol(");
            try buffer.appendSlice(rt.memory.allocator, description);
            try buffer.append(rt.memory.allocator, ')');
            return;
        }
    }
    if (value.asInt32()) |int_value| {
        var int_buf: [32]u8 = undefined;
        try buffer.appendSlice(rt.memory.allocator, dtoa.formatInt32(&int_buf, int_value));
        return;
    }
    if (value.asFloat64()) |float_value| return appendFloat(rt, buffer, float_value);
    if (value.isBigInt()) return value_format.appendBigIntBase10(rt.memory.allocator, buffer, value);
    if (value.asBool()) |bool_value| {
        return buffer.appendSlice(rt.memory.allocator, if (bool_value) "true" else "false");
    }
    if (value.isUndefined()) return buffer.appendSlice(rt.memory.allocator, "undefined");
    if (value.isNull()) return buffer.appendSlice(rt.memory.allocator, "null");
    if (value.isString()) return string.appendValueUtf8(rt, buffer, value);
    if (value.isObject()) return appendObjectString(rt, buffer, value, policy);
    return unsupportedValue(rt, buffer, policy);
}

fn appendFloat(rt: *JSRuntime, buffer: *std.ArrayList(u8), float_value: f64) AppendStringError!void {
    if (std.math.isNan(float_value)) return buffer.appendSlice(rt.memory.allocator, "NaN");
    if (std.math.isPositiveInf(float_value)) return buffer.appendSlice(rt.memory.allocator, "Infinity");
    if (std.math.isNegativeInf(float_value)) return buffer.appendSlice(rt.memory.allocator, "-Infinity");
    // ToString(-0) is "0", not "-0" (ES Number::toString step 2).
    if (std.math.isNegativeZero(float_value)) return buffer.append(rt.memory.allocator, '0');
    var float_buf: [64]u8 = undefined;
    const printed = try value_format.formatFiniteNumber(&float_buf, float_value);
    return buffer.appendSlice(rt.memory.allocator, printed);
}

fn appendObjectString(
    rt: *JSRuntime,
    buffer: *std.ArrayList(u8),
    value: JSValue,
    comptime policy: Policy,
) AppendStringError!void {
    const header = value.refHeader() orelse return;
    const object_value: *Object = @fieldParentPtr("header", header);
    if (object_value.class_id == class.ids.string) {
        const data = object_value.objectData() orelse return error.TypeError;
        return appendValueString(rt, buffer, data, policy);
    }
    if (comptime policy.unwrap_wrappers) {
        if (object_value.class_id == class.ids.number or object_value.class_id == class.ids.boolean or
            object_value.class_id == class.ids.big_int or object_value.class_id == class.ids.symbol)
        {
            const primitive = (object_value.objectData() orelse return error.TypeError).dup();
            defer primitive.free(rt);
            return appendValueString(rt, buffer, primitive, policy);
        }
    }
    if (object_value.class_id == class.ids.array_buffer) {
        return buffer.appendSlice(rt.memory.allocator, "[object ArrayBuffer]");
    }
    if (object_value.class_id == class.ids.promise) {
        return buffer.appendSlice(rt.memory.allocator, "[object Promise]");
    }
    if (object_value.isArray()) return appendArrayString(rt, buffer, object_value, policy);
    return buffer.appendSlice(rt.memory.allocator, "[object Object]");
}

fn unsupportedValue(rt: *JSRuntime, buffer: *std.ArrayList(u8), comptime policy: Policy) AppendStringError!void {
    return switch (comptime policy.unsupported) {
        .object_tag => buffer.appendSlice(rt.memory.allocator, "[object Object]"),
        // qjs `JS_ToString` throws for Symbols rather than tagging them; the
        // RegExp constructor legs (quickjs.c:47578,47627,47789) rely on it.
        .type_error => error.TypeError,
    };
}

/// The `Array.prototype.join`-shaped rendering an array gets from ToString:
/// comma-separated elements with undefined and null rendering as empty.
fn appendArrayString(
    rt: *JSRuntime,
    buffer: *std.ArrayList(u8),
    array: *Object,
    comptime policy: Policy,
) AppendStringError!void {
    var index: u32 = 0;
    while (index < array.arrayLength()) : (index += 1) {
        if (index != 0) try buffer.append(rt.memory.allocator, ',');
        const value = try array.getProperty(atom.atomFromUInt32(index));
        defer value.free(rt);
        if (!value.isUndefined() and !value.isNull()) try appendValueString(rt, buffer, value, policy);
    }
}

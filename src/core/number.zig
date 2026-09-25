//! Number-parsing primitives shared by the `Number.parseInt`/`parseFloat`
//! and global `parseInt`/`parseFloat` fast paths and their bare-runtime
//! fallbacks. The byte parsers are pure ASCII -> f64 arithmetic. Value adapters
//! may grow native snapshots, and array rendering can materialize AUTOINIT and
//! collect. This module has zero exec/VM dependencies. The realm-coercing record
//! handler and the `Number.prototype.*` formatting methods live in
//! `src/exec/number_ops.zig`.

const core = @import("root.zig");
const dtoa = @import("../libs/number_format.zig");
const std = @import("std");

/// QuickJS source map: global parseInt / Number.parseInt. This is still the
/// narrow subset used by transitional `parse_int` bytecode.
pub fn parseIntValue(rt: *core.JSRuntime, input: core.JSValue, radix_value: ?core.JSValue) !f64 {
    var values = [_]core.JSValue{ input, radix_value orelse core.JSValue.undefinedValue() };
    const live: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &live }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);

    // Bare-runtime array rendering can materialize inherited AUTOINIT values.
    // Keep both pending inputs alive, including radix during input rendering.
    const input_is_string = values[0].isString();
    var radix: i32 = if (input_is_string) toInt32(try toNumber(rt, values[1])) else 0;
    if (core.string.asFlat(values[0])) |str| {
        var borrow = core.runtime.NoGcScope{};
        borrow.activate(rt);
        defer borrow.deactivate();
        switch (str.resolveData()) {
            .latin1 => |bytes| return parseIntLatin1Bytes(bytes, radix),
            .utf16 => {},
        }
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try core.value_string.appendValueString(rt, &bytes, values[0], .{ .unwrap_wrappers = true });

    if (!input_is_string) radix = toInt32(try toNumber(rt, values[1]));
    // appendValueString emits UTF-8 (qjs JS_ToCStringLen2, quickjs.c);
    // trim UTF-8 whitespace first, then scan the remainder as already-decoded
    // code units. parseIntLatin1Bytes itself treats each byte as a latin1
    // code point and must not re-decode UTF-8 whitespace sequences.
    return parseIntLatin1Bytes(core.value_format.trimJsWhitespace(bytes.items), radix);
}

/// QuickJS source map: global parseFloat / Number.parseFloat. This is still the
/// narrow subset used by transitional `parse_float` bytecode.
pub fn parseFloatValue(rt: *core.JSRuntime, input: core.JSValue) !f64 {
    if (core.string.asFlat(input)) |str| {
        var borrow = core.runtime.NoGcScope{};
        borrow.activate(rt);
        defer borrow.deactivate();
        switch (str.resolveData()) {
            .latin1 => |bytes| return parseFloatLatin1Bytes(bytes),
            .utf16 => {},
        }
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try core.value_string.appendValueString(rt, &bytes, input, .{ .unwrap_wrappers = true });
    return parseFloatLatin1Bytes(core.value_format.trimJsWhitespace(bytes.items));
}

/// qjs `js_parseInt`: radix check, skip whitespace, `js_atof` with
/// `ATOD_INT_ONLY | ATOD_ACCEPT_PREFIX_AFTER_SIGN`. Digits beyond 2^53 are
/// rounded once by the dtoa kernel, not per digit.
pub fn parseIntLatin1Bytes(source: []const u8, radix: i32) f64 {
    if (radix != 0 and (radix < 2 or radix > 36)) return std.math.nan(f64);
    const text = trimLeadingJsWhitespace(source);
    return dtoa.parseNumberPrefix(text, @intCast(radix), .{ .int_only = true, .accept_prefix_after_sign = true }).value;
}

/// qjs `js_parseFloat`: skip whitespace, `js_atof` in radix 10 with no
/// flags (so `0x` is not a prefix and `Infinity` is accepted).
pub fn parseFloatLatin1Bytes(source: []const u8) f64 {
    const text = trimLeadingJsWhitespace(source);
    return dtoa.parseNumberPrefix(text, 10, .{}).value;
}

pub fn numberValue(value: core.JSValue) ?f64 {
    if (value.as(.int)) |v| return @floatFromInt(v);
    if (value.as(.float64)) |v| return v;
    return null;
}

pub fn toNumber(rt: *core.JSRuntime, value: core.JSValue) !f64 {
    if (numberValue(value)) |number| return number;
    if (value.as(.boolean)) |bool_value| return if (bool_value) 1 else 0;
    if (value.is(.null_value)) return 0;
    if (value.is(.undefined_value)) return std.math.nan(f64);

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try core.value_string.appendValueString(rt, &bytes, value, .{ .unwrap_wrappers = true });
    return core.value_format.parseJsNumber(bytes.items);
}

/// Latin1 code-point whitespace. ASCII 0x09-0x0d/0x20 stay the first arm so
/// the ASCII hot path is a single switch match; 0xA0 is NBSP (U+00A0).
/// Multi-byte UTF-8 sequences are NOT whitespace here — those bytes are
/// independent latin1 code points. qjs skip_spaces (qjs:11230) + lre_is_space
/// classify by CODE POINT.
fn jsWhitespacePrefixLen(bytes: []const u8) ?usize {
    if (bytes.len == 0) return null;
    switch (bytes[0]) {
        0x09...0x0d, 0x20, 0xa0 => return 1,
        else => return null,
    }
}

fn toInt32(number: f64) i32 {
    if (number == 0 or std.math.isNan(number) or !std.math.isFinite(number)) return 0;
    const two32 = 4294967296.0;
    var int = @mod(@floor(@abs(number)), two32);
    if (number < 0 and int != 0) int = two32 - int;
    if (int >= 2147483648.0) return @intFromFloat(int - two32);
    return @intFromFloat(int);
}

fn trimLeadingJsWhitespace(source: []const u8) []const u8 {
    var index: usize = 0;
    while (index < source.len) {
        const width = jsWhitespacePrefixLen(source[index..]) orelse break;
        index += width;
    }
    return source[index..];
}

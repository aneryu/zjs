const core = @import("../core/root.zig");
const bignum = @import("../libs/bignum.zig");
const unicode = @import("../libs/unicode.zig");
const std = @import("std");
const builtin_dispatch = @import("../exec/builtin_dispatch.zig");
const builtin_glue = @import("../exec/builtin_glue.zig");
const exceptions = @import("../exec/exceptions.zig");

const HostError = exceptions.HostError;
const InternalCall = core.host_function.InternalCall;

const AppendStringError = error{
    OutOfMemory,
    TypeError,
    InvalidRadix,
    NoSpaceLeft,
};

/// Declaration table: one entry per global URI builtin. `id` is the
/// `methodId` value (encode/decode mode selector), reused as the dispatch
/// `magic`. The record `call` fn mirrors the legacy
/// `callUriNativeFunctionRecord` dispatch: realm callers take the VM string
/// coercion path in `builtin_glue` (shared with the fast-call entry points),
/// bare-runtime callers use the primitive-only `call` fallback below.
pub const internal_entries = [_]core.host_function.InternalEntry{
    uriEntry("encodeURI", 1),
    uriEntry("encodeURIComponent", 2),
    uriEntry("decodeURI", 3),
    uriEntry("decodeURIComponent", 4),
};

fn uriEntry(comptime name: []const u8, comptime mode: u32) core.host_function.InternalEntry {
    return .{ .name = name, .length = 1, .id = mode, .magic = mode, .prepared_call_ok = true, .call = &uriCall };
}

/// Shared record handler for the four global URI functions. With a realm
/// global the input is string-coerced through the VM (Annex B ToString);
/// without one the primitive-only `call` path preserves the legacy host
/// behavior on bare runtimes.
fn uriCall(host_call: InternalCall) HostError!core.JSValue {
    const ctx = host_call.ctx;
    const mode: u32 = host_call.magic;
    if (host_call.global) |global| {
        return builtin_glue.qjsUriCallForNativeRecord(
            ctx,
            host_call.output,
            global,
            mode,
            host_call.args,
            builtin_dispatch.callerBytecode(host_call),
            builtin_dispatch.callerFrame(host_call),
        ) catch |err| switch (err) {
            error.TypeError, error.URIError => err,
            else => err,
        };
    }
    const input = if (host_call.args.len >= 1) host_call.args[0] else core.JSValue.undefinedValue();
    return call(ctx.runtime, mode, input) catch |err| switch (err) {
        error.TypeError, error.URIError => err,
        else => err,
    };
}

pub const FourByteEscapeUnits = struct {
    high: u16,
    low: u16,
};

pub fn methodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "encodeURI")) return 1;
    if (std.mem.eql(u8, name, "encodeURIComponent")) return 2;
    if (std.mem.eql(u8, name, "decodeURI")) return 3;
    if (std.mem.eql(u8, name, "decodeURIComponent")) return 4;
    return null;
}

/// QuickJS source map: global URI encode/decode functions in quickjs.c. This
/// is the current narrow URI subset used by transitional `uri_call` bytecode.
pub fn call(rt: *core.JSRuntime, mode: u32, input: core.JSValue) !core.JSValue {
    if (mode == 3 or mode == 4) {
        // Fast path: string inputs (the common case in real-world callers
        // and in tight 4-byte-UTF-8 URI sweeps) avoid the
        // `appendValueString` round-trip. We decode straight from the
        // string's owned bytes into a small stack buffer, falling back
        // to an `ArrayList` only when the result outgrows the buffer.
        // The fast path is restricted to ASCII content because the URI
        // grammar only accepts ASCII; anything else falls through to the
        // legacy `appendValueString` route below, which preserves
        // QuickJS-compatible `\uXXXX` widening for non-ASCII utf16 units.
        if (try stringInputValue(input)) |string_value| {
            if (stringDataFromValue(string_value)) |string_data| {
                if (!stringDataContainsPercent(string_data)) return string_value.dup();
                if (try decodeStringDataFast(rt, string_data, mode == 4)) |result| {
                    return result;
                }
            }
        }
    } else if (mode == 1 or mode == 2) {
        if (try stringInputValue(input)) |string_value| {
            if (stringHasUnpairedSurrogate(string_value)) return error.URIError;
            var out = std.ArrayList(u8).empty;
            defer out.deinit(rt.memory.allocator);
            try encodeStringValue(rt, &out, string_value, mode == 2);
            const str = try core.string.String.createUtf8(rt, out.items);
            return str.value();
        }
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendValueString(rt, &bytes, input);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(rt.memory.allocator);
    switch (mode) {
        1 => try encodeBytes(rt, &out, bytes.items, false),
        2 => try encodeBytes(rt, &out, bytes.items, true),
        3 => try decodeBytes(rt, &out, bytes.items, false),
        4 => try decodeBytes(rt, &out, bytes.items, true),
        else => return error.TypeError,
    }

    const str = try core.string.String.createUtf8(rt, out.items);
    return str.value();
}

/// Stack-buffered decode for `decodeURI` / `decodeURIComponent` on string
/// inputs. Returns `null` to defer to the slow `appendValueString` path
/// when the input would not benefit from the fast path (utf16 strings that
/// contain non-ASCII units, which need the QuickJS `\uXXXX`-widening
/// stringification before decoding).
///
/// The stack buffer is sized so that 4-byte-UTF-8 URI sweeps
/// (`decodeURI("%F0%9F%98%80")` and similar) never spills to the heap.
/// Larger strings spill to an `ArrayList`.
fn decodeStringDataFast(rt: *core.JSRuntime, string_value: *core.string.String, component: bool) !?core.JSValue {
    try string_value.ensureFlat(rt);
    switch (string_value.resolveData()) {
        .latin1 => |bytes| return try decodeAsciiBytes(rt, bytes, component),
        .utf16 => |units| {
            for (units) |unit| if (unit > 0x7f) return null;
            var stack_buf: [128]u8 = undefined;
            if (units.len > stack_buf.len) {
                var bytes = std.ArrayList(u8).empty;
                defer bytes.deinit(rt.memory.allocator);
                try bytes.ensureTotalCapacity(rt.memory.allocator, units.len);
                for (units) |unit| bytes.appendAssumeCapacity(@intCast(unit));
                return try decodeAsciiBytes(rt, bytes.items, component);
            }
            for (units, 0..) |unit, idx| stack_buf[idx] = @intCast(unit);
            return try decodeAsciiBytes(rt, stack_buf[0..units.len], component);
        },
    }
}

/// Decode `%XX` escapes from an ASCII byte slice. The decoded form lives on
/// a 128-byte stack buffer for the common short-input case; longer outputs
/// (or unusually large inputs) spill to a heap `ArrayList`.
fn decodeAsciiBytes(rt: *core.JSRuntime, bytes: []const u8, component: bool) !core.JSValue {
    if (try decodeSingleFourByteEscape(rt, bytes)) |result| return result;

    // Worst case after decoding is `bytes.len` bytes (each `%XX` triplet
    // collapses to 1 byte; reserved characters preserve their `%XX` form
    // when component=false, also length-bounded).
    var stack_buf: [128]u8 = undefined;
    if (bytes.len <= stack_buf.len) {
        var len: usize = 0;
        try decodeBytesInto(stack_buf[0..], bytes, component, &len);
        const str = try core.string.String.createUtf8(rt, stack_buf[0..len]);
        return str.value();
    }
    var out = std.ArrayList(u8).empty;
    defer out.deinit(rt.memory.allocator);
    try decodeBytes(rt, &out, bytes, component);
    const str = try core.string.String.createUtf8(rt, out.items);
    return str.value();
}

fn decodeSingleFourByteEscape(rt: *core.JSRuntime, bytes: []const u8) !?core.JSValue {
    const units = try decodeSingleFourByteEscapeUnitsFromAscii(bytes) orelse return null;
    const cached = try rt.recentTwoUnitString(units.high, units.low);
    return cached.value().dup();
}

pub fn decodeSingleFourByteEscapeUnits(value: core.JSValue) !?FourByteEscapeUnits {
    if (!value.isString()) return null;
    const header = value.refHeader() orelse return null;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    const bytes = switch (string_value.resolveData()) {
        .latin1 => |latin1| latin1,
        .utf16 => return null,
    };
    return decodeSingleFourByteEscapeUnitsFromAscii(bytes);
}

fn decodeSingleFourByteEscapeUnitsFromAscii(bytes: []const u8) !?FourByteEscapeUnits {
    if (bytes.len != 12) return null;

    if (bytes[0] != '%' or bytes[3] != '%' or bytes[6] != '%' or bytes[9] != '%') return null;
    const h01 = fastHexPair(bytes[1], bytes[2]) orelse return null;
    const h23 = fastHexPair(bytes[4], bytes[5]) orelse return null;
    const h45 = fastHexPair(bytes[7], bytes[8]) orelse return null;
    const h67 = fastHexPair(bytes[10], bytes[11]) orelse return null;

    const b0 = h01;
    if (b0 < 0xf0) return null;
    if (b0 > 0xf4) return error.URIError;
    if ((h23 & 0xc0) != 0x80 or (h45 & 0xc0) != 0x80 or (h67 & 0xc0) != 0x80) {
        return error.URIError;
    }

    const codepoint: u21 =
        (@as(u21, b0 & 0x07) << 18) |
        (@as(u21, h23 & 0x3f) << 12) |
        (@as(u21, h45 & 0x3f) << 6) |
        @as(u21, h67 & 0x3f);
    if (codepoint < 0x10000 or codepoint > 0x10ffff) return error.URIError;

    const pair = unicode.surrogatePairFromCodePoint(codepoint);
    return .{ .high = pair.high, .low = pair.low };
}

fn fastHexPair(high: u8, low: u8) ?u8 {
    return (fastHexValue(high) orelse return null) << 4 | (fastHexValue(low) orelse return null);
}

const fast_hex_table: [256]i8 = initFastHexTable();

fn initFastHexTable() [256]i8 {
    var table: [256]i8 = @splat(-1);
    var digit: usize = 0;
    while (digit < 10) : (digit += 1) {
        table['0' + digit] = @intCast(digit);
    }
    var upper: usize = 0;
    while (upper < 6) : (upper += 1) {
        const value: i8 = @intCast(upper + 10);
        table['A' + upper] = value;
        table['a' + upper] = value;
    }
    return table;
}

fn fastHexValue(byte: u8) ?u8 {
    const value = fast_hex_table[byte];
    if (value < 0) return null;
    return @intCast(value);
}

pub fn escape(rt: *core.JSRuntime, input: core.JSValue) !core.JSValue {
    var units = std.ArrayList(u16).empty;
    defer units.deinit(rt.memory.allocator);
    try appendValueCodeUnits(rt, &units, input);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(rt.memory.allocator);
    for (units.items) |unit| {
        if (unit <= 0xff) {
            const ch: u8 = @intCast(unit);
            if (isAnnexBEscapeUnmodified(ch)) {
                try out.append(rt.memory.allocator, ch);
            } else {
                const encoded = percentEncodedByte(ch);
                try out.appendSlice(rt.memory.allocator, &encoded);
            }
        } else {
            const encoded = percentEncodedUnit(unit);
            try out.appendSlice(rt.memory.allocator, &encoded);
        }
    }
    const str = try core.string.String.createUtf8(rt, out.items);
    return str.value();
}

pub fn unescape(rt: *core.JSRuntime, input: core.JSValue) !core.JSValue {
    var units = std.ArrayList(u16).empty;
    defer units.deinit(rt.memory.allocator);
    try appendValueCodeUnits(rt, &units, input);

    var out = std.ArrayList(u16).empty;
    defer out.deinit(rt.memory.allocator);
    var index: usize = 0;
    while (index < units.items.len) : (index += 1) {
        var unit = units.items[index];
        if (unit == '%' and index + 1 < units.items.len) {
            if (units.items[index + 1] == 'u' and
                index + 5 < units.items.len and
                isHexCodeUnit(units.items[index + 2]) and
                isHexCodeUnit(units.items[index + 3]) and
                isHexCodeUnit(units.items[index + 4]) and
                isHexCodeUnit(units.items[index + 5]))
            {
                unit = (@as(u16, hexCodeUnitValue(units.items[index + 2])) << 12) |
                    (@as(u16, hexCodeUnitValue(units.items[index + 3])) << 8) |
                    (@as(u16, hexCodeUnitValue(units.items[index + 4])) << 4) |
                    @as(u16, hexCodeUnitValue(units.items[index + 5]));
                index += 5;
            } else if (index + 2 < units.items.len and
                isHexCodeUnit(units.items[index + 1]) and
                isHexCodeUnit(units.items[index + 2]))
            {
                unit = (@as(u16, hexCodeUnitValue(units.items[index + 1])) << 4) |
                    @as(u16, hexCodeUnitValue(units.items[index + 2]));
                index += 2;
            }
        }
        try out.append(rt.memory.allocator, unit);
    }

    const str = try core.string.String.createUtf16(rt, out.items);
    return str.value();
}

fn stringInputValue(input: core.JSValue) !?core.JSValue {
    if (input.isString()) {
        return input;
    }
    if (input.isObject()) {
        const header = input.refHeader() orelse return null;
        const object_value: *core.Object = @fieldParentPtr("header", header);
        if (object_value.class_id == core.class.ids.string) {
            const data = object_value.objectData() orelse return error.TypeError;
            return data;
        }
    }
    return null;
}

fn stringDataFromValue(value: core.JSValue) ?*core.string.String {
    const header = value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

fn stringHasUnpairedSurrogate(value: core.JSValue) bool {
    const header = value.refHeader() orelse return false;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    return switch (string_value.resolveData()) {
        .latin1 => false,
        .utf16 => |units| hasUnpairedSurrogate(units),
    };
}

fn encodeStringValue(rt: *core.JSRuntime, out: *std.ArrayList(u8), value: core.JSValue, component: bool) !void {
    const header = value.refHeader() orelse return;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    try string_value.ensureFlat(rt);
    switch (string_value.resolveData()) {
        .latin1 => |bytes| {
            for (bytes) |byte| try encodeCodepoint(rt, out, byte, component);
        },
        .utf16 => |units| {
            var index: usize = 0;
            while (index < units.len) : (index += 1) {
                const unit = units[index];
                if (unicode.isHighSurrogateUnit(unit)) {
                    const next = units[index + 1];
                    try encodeCodepoint(rt, out, unicode.codePointFromSurrogatePair(unit, next), component);
                    index += 1;
                } else {
                    try encodeCodepoint(rt, out, unit, component);
                }
            }
        },
    }
}

fn encodeCodepoint(rt: *core.JSRuntime, out: *std.ArrayList(u8), codepoint: u21, component: bool) !void {
    if (codepoint <= 0x7f) {
        const ch: u8 = @intCast(codepoint);
        if (isUnescaped(ch) or (!component and isReserved(ch))) {
            try out.append(rt.memory.allocator, ch);
            return;
        }
    }
    var encoded: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &encoded) catch return error.URIError;
    for (encoded[0..len]) |byte| try appendPercentByte(rt, out, byte);
}

fn appendPercentByte(rt: *core.JSRuntime, out: *std.ArrayList(u8), byte: u8) !void {
    const encoded = percentEncodedByte(byte);
    try out.appendSlice(rt.memory.allocator, &encoded);
}

fn hasUnpairedSurrogate(units: []const u16) bool {
    var index: usize = 0;
    while (index < units.len) : (index += 1) {
        const unit = units[index];
        if (unicode.isHighSurrogateUnit(unit)) {
            if (index + 1 >= units.len) return true;
            const next = units[index + 1];
            if (!unicode.isLowSurrogateUnit(next)) return true;
            index += 1;
        } else if (unicode.isLowSurrogateUnit(unit)) {
            return true;
        }
    }
    return false;
}

fn stringDataContainsPercent(string_value: *core.string.String) bool {
    return switch (string_value.resolveData()) {
        .latin1 => |bytes| std.mem.indexOfScalar(u8, bytes, '%') != null,
        .utf16 => |units| std.mem.indexOfScalar(u16, units, '%') != null,
    };
}

fn encodeBytes(rt: *core.JSRuntime, out: *std.ArrayList(u8), bytes: []const u8, component: bool) !void {
    for (bytes) |ch| {
        if (isUnescaped(ch) or (!component and isReserved(ch))) {
            try out.append(rt.memory.allocator, ch);
        } else {
            const encoded = percentEncodedByte(ch);
            try out.appendSlice(rt.memory.allocator, &encoded);
        }
    }
}

fn percentEncodedByte(byte: u8) [3]u8 {
    return .{ '%', unicode.asciiUpperHexDigitChar(byte >> 4), unicode.asciiUpperHexDigitChar(byte & 0x0f) };
}

fn percentEncodedUnit(unit: u16) [6]u8 {
    return .{
        '%',
        'u',
        unicode.asciiUpperHexDigitChar((unit >> 12) & 0x0f),
        unicode.asciiUpperHexDigitChar((unit >> 8) & 0x0f),
        unicode.asciiUpperHexDigitChar((unit >> 4) & 0x0f),
        unicode.asciiUpperHexDigitChar(unit & 0x0f),
    };
}

fn decodeBytes(rt: *core.JSRuntime, out: *std.ArrayList(u8), bytes: []const u8, component: bool) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        if (bytes[index] != '%') {
            try out.append(rt.memory.allocator, bytes[index]);
            index += 1;
            continue;
        }
        if (index + 2 >= bytes.len) {
            return error.URIError;
        }
        const decoded = fastHexPair(bytes[index + 1], bytes[index + 2]) orelse return error.URIError;
        index += 3;
        if (!component and isReserved(decoded)) {
            try out.append(rt.memory.allocator, '%');
            try out.append(rt.memory.allocator, bytes[index - 2]);
            try out.append(rt.memory.allocator, bytes[index - 1]);
        } else if (decoded < 0x80) {
            try out.append(rt.memory.allocator, decoded);
        } else {
            const DecodedUtf8 = struct {
                count: u3,
                min: u21,
                codepoint: u21,
            };
            var decoded_utf8: DecodedUtf8 = if (decoded >= 0xc0 and decoded <= 0xdf)
                .{ .count = 1, .min = 0x80, .codepoint = decoded & 0x1f }
            else if (decoded >= 0xe0 and decoded <= 0xef)
                .{ .count = 2, .min = 0x800, .codepoint = decoded & 0x0f }
            else if (decoded >= 0xf0 and decoded <= 0xf7)
                .{ .count = 3, .min = 0x10000, .codepoint = decoded & 0x07 }
            else
                .{ .count = 0, .min = 1, .codepoint = 0 };

            var remaining = decoded_utf8.count;
            while (remaining > 0) : (remaining -= 1) {
                if (index + 2 >= bytes.len or bytes[index] != '%') {
                    return error.URIError;
                }
                const continuation = fastHexPair(bytes[index + 1], bytes[index + 2]) orelse return error.URIError;
                index += 3;
                if ((continuation & 0xc0) != 0x80) return error.URIError;
                decoded_utf8.codepoint = (decoded_utf8.codepoint << 6) | (continuation & 0x3f);
            }
            if (decoded_utf8.codepoint < decoded_utf8.min or decoded_utf8.codepoint > 0x10ffff or isSurrogate(decoded_utf8.codepoint)) {
                return error.URIError;
            }
            var encoded: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(decoded_utf8.codepoint, &encoded) catch return error.URIError;
            try out.appendSlice(rt.memory.allocator, encoded[0..len]);
        }
    }
}

/// Same logic as `decodeBytes`, but the destination is a caller-provided
/// fixed-size buffer; `out_len` tracks how many bytes have been written.
/// Caller guarantees `dest.len >= bytes.len` (the worst case after URI
/// decoding never exceeds the input length).
fn decodeBytesInto(dest: []u8, bytes: []const u8, component: bool, out_len: *usize) !void {
    var index: usize = 0;
    var len: usize = 0;
    while (index < bytes.len) {
        if (bytes[index] != '%') {
            dest[len] = bytes[index];
            len += 1;
            index += 1;
            continue;
        }
        if (index + 2 >= bytes.len) {
            return error.URIError;
        }
        const decoded = fastHexPair(bytes[index + 1], bytes[index + 2]) orelse return error.URIError;
        index += 3;
        if (!component and isReserved(decoded)) {
            dest[len] = '%';
            dest[len + 1] = bytes[index - 2];
            dest[len + 2] = bytes[index - 1];
            len += 3;
        } else if (decoded < 0x80) {
            dest[len] = decoded;
            len += 1;
        } else {
            const DecodedUtf8 = struct {
                count: u3,
                min: u21,
                codepoint: u21,
            };
            var decoded_utf8: DecodedUtf8 = if (decoded >= 0xc0 and decoded <= 0xdf)
                .{ .count = 1, .min = 0x80, .codepoint = decoded & 0x1f }
            else if (decoded >= 0xe0 and decoded <= 0xef)
                .{ .count = 2, .min = 0x800, .codepoint = decoded & 0x0f }
            else if (decoded >= 0xf0 and decoded <= 0xf7)
                .{ .count = 3, .min = 0x10000, .codepoint = decoded & 0x07 }
            else
                .{ .count = 0, .min = 1, .codepoint = 0 };

            var remaining = decoded_utf8.count;
            while (remaining > 0) : (remaining -= 1) {
                if (index + 2 >= bytes.len or bytes[index] != '%') {
                    return error.URIError;
                }
                const continuation = fastHexPair(bytes[index + 1], bytes[index + 2]) orelse return error.URIError;
                index += 3;
                if ((continuation & 0xc0) != 0x80) return error.URIError;
                decoded_utf8.codepoint = (decoded_utf8.codepoint << 6) | (continuation & 0x3f);
            }
            if (decoded_utf8.codepoint < decoded_utf8.min or decoded_utf8.codepoint > 0x10ffff or isSurrogate(decoded_utf8.codepoint)) {
                return error.URIError;
            }
            const encoded_len = std.unicode.utf8Encode(decoded_utf8.codepoint, dest[len..]) catch return error.URIError;
            len += encoded_len;
        }
    }
    out_len.* = len;
}

fn isSurrogate(codepoint: u21) bool {
    return unicode.isSurrogateCodePoint(codepoint);
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
        try appendRawString(rt, buffer, value);
    } else if (value.isObject()) {
        const header = value.refHeader() orelse return;
        const object_value: *core.Object = @fieldParentPtr("header", header);
        if (object_value.class_id == core.class.ids.string) {
            const data = object_value.objectData() orelse return error.TypeError;
            try appendValueString(rt, buffer, data);
        } else if (object_value.class_id == core.class.ids.array_buffer) {
            try buffer.appendSlice(rt.memory.allocator, "[object ArrayBuffer]");
        } else if (object_value.class_id == core.class.ids.promise) {
            try buffer.appendSlice(rt.memory.allocator, "[object Promise]");
        } else if (object_value.flags.is_array) {
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

fn appendArrayString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), object: *core.Object) AppendStringError!void {
    var index: u32 = 0;
    while (index < object.length) : (index += 1) {
        if (index != 0) try buffer.append(rt.memory.allocator, ',');
        const value = object.getProperty(core.atom.atomFromUInt32(index));
        defer value.free(rt);
        if (!value.isUndefined() and !value.isNull()) try appendValueString(rt, buffer, value);
    }
}

fn appendValueCodeUnits(rt: *core.JSRuntime, out: *std.ArrayList(u16), value: core.JSValue) AppendStringError!void {
    if (value.isSymbol()) return error.TypeError;
    if (value.isString()) return appendStringCodeUnits(rt, out, value);
    if (value.isObject()) {
        const header = value.refHeader() orelse return;
        const object_value: *core.Object = @fieldParentPtr("header", header);
        if (object_value.class_id == core.class.ids.string) {
            const data = object_value.objectData() orelse return error.TypeError;
            return appendStringCodeUnits(rt, out, data);
        }
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendValueString(rt, &bytes, value);
    for (bytes.items) |byte| try out.append(rt.memory.allocator, byte);
}

fn appendStringCodeUnits(rt: *core.JSRuntime, out: *std.ArrayList(u16), value: core.JSValue) !void {
    const header = value.refHeader() orelse return;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    try string_value.ensureFlat(rt);
    switch (string_value.resolveData()) {
        .latin1 => |bytes| for (bytes) |byte| try out.append(rt.memory.allocator, byte),
        .utf16 => |units| try out.appendSlice(rt.memory.allocator, units),
    }
}

fn isAnnexBEscapeUnmodified(ch: u8) bool {
    return unicode.isAsciiAlphanumericByte(ch) or ch == '@' or ch == '*' or ch == '_' or ch == '+' or ch == '-' or ch == '.' or ch == '/';
}

fn isHexCodeUnit(unit: u16) bool {
    return unicode.isAsciiHexDigitUnit(unit);
}

fn hexCodeUnitValue(unit: u16) u8 {
    return unicode.asciiHexDigitValueUnit(unit) orelse unreachable;
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

fn isUnescaped(ch: u8) bool {
    return unicode.isAsciiAlphanumericByte(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '!' or ch == '~' or ch == '*' or ch == '\'' or ch == '(' or ch == ')';
}

fn isReserved(ch: u8) bool {
    return ch == ';' or ch == ',' or ch == '/' or ch == '?' or ch == ':' or ch == '@' or ch == '&' or ch == '=' or ch == '+' or ch == '$' or ch == '#';
}

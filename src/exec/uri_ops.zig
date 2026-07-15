const core = @import("../core/root.zig");
const bignum = @import("../libs/bigint.zig");
const unicode = @import("../libs/unicode.zig");
const std = @import("std");
const builtin_dispatch = @import("builtin_dispatch.zig");
const exceptions = @import("exceptions.zig");
const exception_ops = @import("vm_exception_ops.zig");
const string_ops = @import("string_ops.zig");

const HostError = exceptions.HostError;
const InternalCall = core.host_function.InternalCall;

/// Domain-local ids for the legacy `escape`/`unescape` globals (relocated to
/// `core/uri.zig` so exec's string-name fallback can route their bodies
/// through `callInternalRecord` without naming this builtin). The four
/// `encodeURI`/`decodeURI` records use the `methodId` mode selector (1..4);
/// these continue the same `.uri` id space. Reachable only through the record
/// table (`bindUriNativeRecords` skips them, so the installed `escape`/
/// `unescape` functions keep their existing dispatch).
const escape_id = core.uri.escape_id;
const unescape_id = core.uri.unescape_id;

const AppendStringError = error{
    OutOfMemory,
    TypeError,
    InvalidRadix,
    NoSpaceLeft,
};

/// Throw a `URIError` with `message` (mirrors qjs `js_throw_URIError`,
/// quickjs.c:54734): construct the error value, set the context exception, and
/// return the `error.URIError` sentinel. The exception value is preserved by the
/// host-call boundary's `hasException()` check, so the specific message survives
/// rather than being replaced by the coarse "expecting hex digit" fallback. On
/// the bare-runtime path (no realm global) there is no error prototype to build
/// against, so the bare `error.URIError` sentinel is returned unchanged.
fn throwUriErrorMessage(ctx: *core.JSContext, global: ?*core.Object, message: []const u8) HostError {
    const active_global = global orelse return error.URIError;
    const error_value = exception_ops.createNamedError(ctx, active_global, "URIError", message) catch |err| return err;
    _ = ctx.throwValue(error_value);
    return error.URIError;
}

/// Declaration table: one entry per global URI builtin plus the legacy
/// `escape`/`unescape` globals. `id` is the `methodId` mode selector (1..4)
/// for the URI functions and `escape_id`/`unescape_id` for the legacy pair,
/// reused as the dispatch `magic`. The record `call` fn (`uriCall`) coerces
/// the input through the VM Annex B ToString path when a realm global is
/// present and falls back to the primitive-only bodies (`call`/`escape`/
/// `unescape`) on bare runtimes.
pub const internal_entries = [_]core.host_function.InternalEntry{
    uriEntry("encodeURI", 1),
    uriEntry("encodeURIComponent", 2),
    uriEntry("decodeURI", 3),
    uriEntry("decodeURIComponent", 4),
    .{ .name = "escape", .length = 1, .id = escape_id, .magic = escape_id, .prepared_call_ok = true, .call = &uriCall },
    .{ .name = "unescape", .length = 1, .id = unescape_id, .magic = unescape_id, .prepared_call_ok = true, .call = &uriCall },
};

fn uriEntry(comptime name: []const u8, comptime mode: u32) core.host_function.InternalEntry {
    return .{ .name = name, .length = 1, .id = mode, .magic = mode, .prepared_call_ok = true, .call = &uriCall };
}

/// Shared record handler for the global URI functions and the legacy
/// `escape`/`unescape` pair. With a realm global the input is string-coerced
/// through the VM (Annex B ToString); without one the primitive-only bodies
/// preserve the legacy host behavior on bare runtimes. Both modes invoke the
/// same method bodies (`call`/`escape`/`unescape`) below, so exec routes its
/// direct call sites here through `callInternalRecord` instead of naming them.
fn uriCall(host_call: InternalCall) HostError!core.JSValue {
    const ctx = host_call.ctx;
    const mode: u32 = host_call.magic;
    const input = if (host_call.args.len >= 1) host_call.args[0] else core.JSValue.undefinedValue();
    if (host_call.global) |global| {
        // Realm path: coerce the argument through the user-visible ToString
        // (Annex B) before the body, except an already-string input which the
        // body consumes directly (matching the retired exec coercion glue).
        if (input.isString()) return uriBody(ctx, global, mode, input);
        const string_value = try string_ops.toStringForAnnexB(
            ctx,
            host_call.output,
            global,
            input,
            builtin_dispatch.callerBytecode(host_call),
            builtin_dispatch.callerFrame(host_call),
        );
        defer string_value.free(ctx.runtime);
        return uriBody(ctx, global, mode, string_value);
    }
    // Bare-runtime primitive path (no realm global for specific URIError text).
    return uriBody(ctx, null, mode, input);
}

/// Dispatch a `.uri` record id to its primitive method body. `global` is the
/// realm global used to build specific `URIError` messages, or null on bare
/// runtimes.
fn uriBody(ctx: *core.JSContext, global: ?*core.Object, mode: u32, input: core.JSValue) HostError!core.JSValue {
    const rt = ctx.runtime;
    return switch (mode) {
        escape_id => escape(rt, input),
        unescape_id => unescape(rt, input),
        else => call(ctx, global, mode, input),
    };
}

// `FourByteEscapeUnits` + the single-four-byte-escape probe relocated to
// engine core (`core/uri.zig`) in Phase 6b-3 STEP 5B so exec's
// `decodeURI(...) === String.fromCharCode(...)` fusion can reach it without
// naming this builtin; re-exported here for the decode bodies below.
pub const FourByteEscapeUnits = core.uri.FourByteEscapeUnits;
pub const decodeSingleFourByteEscapeUnits = core.uri.decodeSingleFourByteEscapeUnits;
const decodeSingleFourByteEscapeUnitsFromAscii = core.uri.decodeSingleFourByteEscapeUnitsFromAscii;
const fastHexPair = core.uri.fastHexPair;

// `methodId` relocated to engine core
// (`core/host_function.zig`, `builtin_method_id_lookup.uri`) in Phase 6b-3
// STEP 2; re-exported here unchanged.
pub const methodId = core.host_function.builtin_method_id_lookup.uri.methodId;

fn uriHexDigitValue(unit: u32) ?u8 {
    return switch (unit) {
        '0'...'9' => @intCast(unit - '0'),
        'a'...'f' => @intCast(unit - 'a' + 10),
        'A'...'F' => @intCast(unit - 'A' + 10),
        else => null,
    };
}

/// qjs `hex_decode` (quickjs.c:54744): `k` must point at '%' (else URIError
/// "expecting %"); two hex digits must follow within the string, else URIError
/// "expecting hex digit".
fn uriHexDecodeAt(comptime T: type, ctx: *core.JSContext, global: ?*core.Object, units: []const T, k: usize) HostError!u8 {
    if (k >= units.len or units[k] != '%') return throwUriErrorMessage(ctx, global, "expecting %");
    if (k + 3 > units.len) return throwUriErrorMessage(ctx, global, "expecting hex digit");
    const hi = uriHexDigitValue(units[k + 1]) orelse return throwUriErrorMessage(ctx, global, "expecting hex digit");
    const lo = uriHexDigitValue(units[k + 2]) orelse return throwUriErrorMessage(ctx, global, "expecting hex digit");
    return (hi << 4) | lo;
}

/// qjs `isURIReserved` (quickjs.c:54727).
fn isUriReservedChar(c: u32) bool {
    if (c >= 0x100) return false;
    return std.mem.indexOfScalar(u8, "#$&+,/:;=?@", @intCast(c)) != null;
}

/// Faithful port of qjs `js_global_decodeURI` (quickjs.c:54755): walk the
/// source string's code units; '%' starts a hex escape; a lead byte >= 0x80
/// assembles a %XX-encoded UTF-8 sequence, validated (c_min / 0x10FFFF /
/// surrogates -> URIError "malformed UTF-8", thrown via `throwUriErrorMessage`)
/// and emitted as a code point (surrogate pair when > 0xFFFF, the qjs
/// string_buffer_putc); non-component keeps URI-reserved ASCII escaped.
fn decodeUriUnits(comptime T: type, ctx: *core.JSContext, global: ?*core.Object, units: []const T, component: bool) HostError!core.JSValue {
    const rt = ctx.runtime;
    var out = std.ArrayList(u16).empty;
    defer out.deinit(rt.memory.allocator);
    try out.ensureTotalCapacity(rt.memory.allocator, units.len);
    var k: usize = 0;
    while (k < units.len) {
        var c: u32 = units[k];
        if (c == '%') {
            const lead = try uriHexDecodeAt(T, ctx, global, units, k);
            k += 3;
            c = lead;
            if (lead < 0x80) {
                if (!component and isUriReservedChar(c)) {
                    c = '%';
                    k -= 2;
                }
            } else {
                var n: u8 = 0;
                var c_min: u32 = 1;
                if (lead >= 0xc0 and lead <= 0xdf) {
                    n = 1;
                    c_min = 0x80;
                    c = lead & 0x1f;
                } else if (lead >= 0xe0 and lead <= 0xef) {
                    n = 2;
                    c_min = 0x800;
                    c = lead & 0x0f;
                } else if (lead >= 0xf0 and lead <= 0xf7) {
                    n = 3;
                    c_min = 0x10000;
                    c = lead & 0x07;
                } else {
                    n = 0;
                    c_min = 1;
                    c = 0;
                }
                while (n > 0) : (n -= 1) {
                    const c1 = try uriHexDecodeAt(T, ctx, global, units, k);
                    k += 3;
                    if ((c1 & 0xc0) != 0x80) {
                        c = 0;
                        break;
                    }
                    c = (c << 6) | (c1 & 0x3f);
                }
                // js_global_decodeURI (quickjs.c:54812): overlong / out-of-range
                // / surrogate code point -> URIError "malformed UTF-8".
                if (c < c_min or c > 0x10FFFF or (c >= 0xD800 and c <= 0xDFFF)) {
                    return throwUriErrorMessage(ctx, global, "malformed UTF-8");
                }
            }
        } else {
            k += 1;
        }
        if (c > 0xFFFF) {
            const v = c - 0x10000;
            try out.append(rt.memory.allocator, @intCast(0xD800 + (v >> 10)));
            try out.append(rt.memory.allocator, @intCast(0xDC00 + (v & 0x3FF)));
        } else {
            try out.append(rt.memory.allocator, @intCast(c));
        }
    }
    return (try core.string.String.createUtf16(rt, out.items)).value();
}

/// QuickJS source map: global URI encode/decode functions in quickjs.c. This
/// is the current narrow URI subset used by transitional `uri_call` bytecode.
/// `global` is the realm global used to build specific `URIError` messages
/// (`js_throw_URIError`); on bare runtimes it is null and the bare
/// `error.URIError` sentinel is surfaced instead.
pub fn call(ctx: *core.JSContext, global: ?*core.Object, mode: u32, input: core.JSValue) HostError!core.JSValue {
    const rt = ctx.runtime;
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
                try string_data.ensureFlat(rt);
                switch (string_data.resolveData()) {
                    // The stack-buffer fast path is ASCII-only; any non-ASCII
                    // unit routes to the faithful qjs js_global_decodeURI walk
                    // (previously non-ASCII was mangled byte-wise).
                    .latin1 => |bytes| {
                        for (bytes) |byte| {
                            if (byte >= 0x80) return decodeUriUnits(u8, ctx, global, bytes, mode == 4);
                        }
                    },
                    .utf16 => |units| {
                        for (units) |unit| {
                            if (unit >= 0x80) return decodeUriUnits(u16, ctx, global, units, mode == 4);
                        }
                    },
                }
                if (try decodeStringDataFast(ctx, global, string_data, mode == 4)) |result| {
                    return result;
                }
            }
        }
    } else if (mode == 1 or mode == 2) {
        if (try stringInputValue(input)) |string_value| {
            var out = std.ArrayList(u8).empty;
            defer out.deinit(rt.memory.allocator);
            try encodeStringValue(ctx, global, &out, string_value, mode == 2);
            const str = try core.string.String.createUtf8(rt, out.items);
            return str.value();
        }
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendValueString(rt, &bytes, input);

    if (mode == 3 or mode == 4) {
        // Coerced (non-string) inputs decode through the same faithful
        // unit-level walk over the real string content.
        const coerced = try core.string.String.createUtf8(rt, bytes.items);
        defer coerced.value().free(rt);
        try coerced.ensureFlat(rt);
        return switch (coerced.resolveData()) {
            .latin1 => |latin1| decodeUriUnits(u8, ctx, global, latin1, mode == 4),
            .utf16 => |units| decodeUriUnits(u16, ctx, global, units, mode == 4),
        };
    }

    var out = std.ArrayList(u8).empty;
    defer out.deinit(rt.memory.allocator);
    switch (mode) {
        1 => try encodeBytes(rt, &out, bytes.items, false),
        2 => try encodeBytes(rt, &out, bytes.items, true),
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
fn decodeStringDataFast(ctx: *core.JSContext, global: ?*core.Object, string_value: *core.string.String, component: bool) HostError!?core.JSValue {
    const rt = ctx.runtime;
    try string_value.ensureFlat(rt);
    switch (string_value.resolveData()) {
        .latin1 => |bytes| return try decodeAsciiBytes(ctx, global, bytes, component),
        .utf16 => |units| {
            for (units) |unit| if (unit > 0x7f) return null;
            var stack_buf: [128]u8 = undefined;
            if (units.len > stack_buf.len) {
                var bytes = std.ArrayList(u8).empty;
                defer bytes.deinit(rt.memory.allocator);
                try bytes.ensureTotalCapacity(rt.memory.allocator, units.len);
                for (units) |unit| bytes.appendAssumeCapacity(@intCast(unit));
                return try decodeAsciiBytes(ctx, global, bytes.items, component);
            }
            for (units, 0..) |unit, idx| stack_buf[idx] = @intCast(unit);
            return try decodeAsciiBytes(ctx, global, stack_buf[0..units.len], component);
        },
    }
}

/// Decode `%XX` escapes from an ASCII byte slice. The decoded form lives on
/// a 128-byte stack buffer for the common short-input case; longer outputs
/// (or unusually large inputs) spill to a heap `ArrayList`.
fn decodeAsciiBytes(ctx: *core.JSContext, global: ?*core.Object, bytes: []const u8, component: bool) HostError!core.JSValue {
    const rt = ctx.runtime;
    if (try decodeSingleFourByteEscape(rt, bytes)) |result| return result;

    // Worst case after decoding is `bytes.len` bytes (each `%XX` triplet
    // collapses to 1 byte; reserved characters preserve their `%XX` form
    // when component=false, also length-bounded).
    var stack_buf: [128]u8 = undefined;
    if (bytes.len <= stack_buf.len) {
        var len: usize = 0;
        try decodeBytesInto(ctx, global, stack_buf[0..], bytes, component, &len);
        const str = try core.string.String.createUtf8(rt, stack_buf[0..len]);
        return str.value();
    }
    var out = std.ArrayList(u8).empty;
    defer out.deinit(rt.memory.allocator);
    try decodeBytes(ctx, global, &out, bytes, component);
    const str = try core.string.String.createUtf8(rt, out.items);
    return str.value();
}

fn decodeSingleFourByteEscape(rt: *core.JSRuntime, bytes: []const u8) !?core.JSValue {
    const units = try decodeSingleFourByteEscapeUnitsFromAscii(bytes) orelse return null;
    const cached = try rt.recentTwoUnitString(units.high, units.low);
    return cached.value().dup();
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
    return value.asStringBody();
}


fn encodeStringValue(ctx: *core.JSContext, global: ?*core.Object, out: *std.ArrayList(u8), value: core.JSValue, component: bool) HostError!void {
    const rt = ctx.runtime;
    const string_value = value.asStringBody() orelse return;
    try string_value.ensureFlat(rt);
    switch (string_value.resolveData()) {
        .latin1 => |bytes| {
            for (bytes) |byte| try encodeCodepoint(rt, out, byte, component);
        },
        .utf16 => |units| {
            // js_global_encodeURI (quickjs.c:54887): a lone low surrogate throws
            // URIError "invalid character"; a high surrogate not followed by a
            // low surrogate throws URIError "expecting surrogate pair".
            var index: usize = 0;
            while (index < units.len) : (index += 1) {
                const unit = units[index];
                if (unicode.isLowSurrogateUnit(unit)) {
                    return throwUriErrorMessage(ctx, global, "invalid character");
                } else if (unicode.isHighSurrogateUnit(unit)) {
                    if (index + 1 >= units.len) {
                        return throwUriErrorMessage(ctx, global, "expecting surrogate pair");
                    }
                    const next = units[index + 1];
                    if (!unicode.isLowSurrogateUnit(next)) {
                        return throwUriErrorMessage(ctx, global, "expecting surrogate pair");
                    }
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

fn decodeBytes(ctx: *core.JSContext, global: ?*core.Object, out: *std.ArrayList(u8), bytes: []const u8, component: bool) HostError!void {
    const rt = ctx.runtime;
    var index: usize = 0;
    while (index < bytes.len) {
        if (bytes[index] != '%') {
            try out.append(rt.memory.allocator, bytes[index]);
            index += 1;
            continue;
        }
        // hex_decode (quickjs.c:54744): missing hex digits -> "expecting hex digit".
        if (index + 2 >= bytes.len) {
            return throwUriErrorMessage(ctx, global, "expecting hex digit");
        }
        const decoded = fastHexPair(bytes[index + 1], bytes[index + 2]) orelse return throwUriErrorMessage(ctx, global, "expecting hex digit");
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
                // hex_decode on a continuation byte (quickjs.c:54747): a
                // non-'%' byte -> "expecting %"; missing hex -> "expecting hex digit".
                if (index >= bytes.len or bytes[index] != '%') {
                    return throwUriErrorMessage(ctx, global, "expecting %");
                }
                if (index + 2 >= bytes.len) {
                    return throwUriErrorMessage(ctx, global, "expecting hex digit");
                }
                const continuation = fastHexPair(bytes[index + 1], bytes[index + 2]) orelse return throwUriErrorMessage(ctx, global, "expecting hex digit");
                index += 3;
                // js_global_decodeURI (quickjs.c:54806): a non-continuation byte
                // resets the code point to 0, which fails the range check below.
                if ((continuation & 0xc0) != 0x80) {
                    decoded_utf8.codepoint = 0;
                    break;
                }
                decoded_utf8.codepoint = (decoded_utf8.codepoint << 6) | (continuation & 0x3f);
            }
            // js_global_decodeURI (quickjs.c:54812): overlong / out-of-range /
            // surrogate -> "malformed UTF-8".
            if (decoded_utf8.codepoint < decoded_utf8.min or decoded_utf8.codepoint > 0x10ffff or isSurrogate(decoded_utf8.codepoint)) {
                return throwUriErrorMessage(ctx, global, "malformed UTF-8");
            }
            var encoded: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(decoded_utf8.codepoint, &encoded) catch return throwUriErrorMessage(ctx, global, "malformed UTF-8");
            try out.appendSlice(rt.memory.allocator, encoded[0..len]);
        }
    }
}

/// Same logic as `decodeBytes`, but the destination is a caller-provided
/// fixed-size buffer; `out_len` tracks how many bytes have been written.
/// Caller guarantees `dest.len >= bytes.len` (the worst case after URI
/// decoding never exceeds the input length).
fn decodeBytesInto(ctx: *core.JSContext, global: ?*core.Object, dest: []u8, bytes: []const u8, component: bool, out_len: *usize) HostError!void {
    var index: usize = 0;
    var len: usize = 0;
    while (index < bytes.len) {
        if (bytes[index] != '%') {
            dest[len] = bytes[index];
            len += 1;
            index += 1;
            continue;
        }
        // hex_decode (quickjs.c:54744): missing hex digits -> "expecting hex digit".
        if (index + 2 >= bytes.len) {
            return throwUriErrorMessage(ctx, global, "expecting hex digit");
        }
        const decoded = fastHexPair(bytes[index + 1], bytes[index + 2]) orelse return throwUriErrorMessage(ctx, global, "expecting hex digit");
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
                // hex_decode on a continuation byte (quickjs.c:54747): a
                // non-'%' byte -> "expecting %"; missing hex -> "expecting hex digit".
                if (index >= bytes.len or bytes[index] != '%') {
                    return throwUriErrorMessage(ctx, global, "expecting %");
                }
                if (index + 2 >= bytes.len) {
                    return throwUriErrorMessage(ctx, global, "expecting hex digit");
                }
                const continuation = fastHexPair(bytes[index + 1], bytes[index + 2]) orelse return throwUriErrorMessage(ctx, global, "expecting hex digit");
                index += 3;
                // js_global_decodeURI (quickjs.c:54806): a non-continuation byte
                // resets the code point to 0, which fails the range check below.
                if ((continuation & 0xc0) != 0x80) {
                    decoded_utf8.codepoint = 0;
                    break;
                }
                decoded_utf8.codepoint = (decoded_utf8.codepoint << 6) | (continuation & 0x3f);
            }
            // js_global_decodeURI (quickjs.c:54812): overlong / out-of-range /
            // surrogate -> "malformed UTF-8".
            if (decoded_utf8.codepoint < decoded_utf8.min or decoded_utf8.codepoint > 0x10ffff or isSurrogate(decoded_utf8.codepoint)) {
                return throwUriErrorMessage(ctx, global, "malformed UTF-8");
            }
            const encoded_len = std.unicode.utf8Encode(decoded_utf8.codepoint, dest[len..]) catch return throwUriErrorMessage(ctx, global, "malformed UTF-8");
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
        } else if (object_value.isArray()) {
            try appendArrayString(rt, buffer, object_value);
        } else {
            try buffer.appendSlice(rt.memory.allocator, "[object Object]");
        }
    } else {
        try buffer.appendSlice(rt.memory.allocator, "[object Object]");
    }
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

fn appendArrayString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), object: *core.Object) AppendStringError!void {
    var index: u32 = 0;
    while (index < object.arrayLength()) : (index += 1) {
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
    const string_value = value.asStringBody() orelse return;
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

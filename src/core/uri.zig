//! Pure URI decode primitives shared by the URI builtin and the VM's
//! `decodeURI(...) === String.fromCharCode(...)` fusion fast path. These touch
//! no runtime/VM state (std + the unicode helper lib only), so they live in
//! engine core and `src/builtins/uri.zig` re-exports them for its decode
//! bodies. Relocated from `builtins/uri.zig` in Phase 6b-3 STEP 5B so exec can
//! reach the four-byte-escape probe without naming the builtin.

const std = @import("std");
const unicode = @import("../libs/unicode.zig");
const JSValue = @import("value.zig").JSValue;
const string = @import("string.zig");

/// Domain-local `.uri` record ids for the legacy `escape`/`unescape` globals.
/// The `encodeURI`/`decodeURI` records use the `methodId` mode selector
/// (1..4); these continue the same id space. Load-bearing (baked into the
/// `.uri` record table); exec routes the legacy globals' bodies through the
/// table under these ids. `builtins/uri.zig` re-exports them.
pub const escape_id: u32 = 5;
pub const unescape_id: u32 = 6;

/// The two UTF-16 code units a single four-byte `%XX%XX%XX%XX` URI escape
/// decodes to (a surrogate pair for astral code points).
pub const FourByteEscapeUnits = struct {
    high: u16,
    low: u16,
};

/// If `value` is a Latin-1 string holding exactly one four-byte UTF-8 URI
/// escape (`%F0%9F%98%80` and similar), return the surrogate-pair units it
/// decodes to; otherwise null. utf16-backed strings and any other shape defer
/// to the general decode path (null). Mirrors the URI grammar's ASCII-only
/// constraint, so a non-ASCII utf16 string can never be a valid escape run.
pub fn decodeSingleFourByteEscapeUnits(value: JSValue) !?FourByteEscapeUnits {
    if (!value.isString()) return null;
    const string_value = value.asStringBody() orelse return null;
    const bytes = switch (string_value.resolveData()) {
        .latin1 => |latin1| latin1,
        .utf16 => return null,
    };
    return decodeSingleFourByteEscapeUnitsFromAscii(bytes);
}

/// Probe a raw ASCII byte slice for a single four-byte UTF-8 URI escape.
/// Returns null when the slice is not a 12-byte `%XX%XX%XX%XX` run starting
/// with a 4-byte lead byte, and `error.URIError` for a malformed run (bad
/// continuation bytes or an out-of-range code point), matching the URI spec.
pub fn decodeSingleFourByteEscapeUnitsFromAscii(bytes: []const u8) !?FourByteEscapeUnits {
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

/// Decode two hex digit bytes into a byte value, or null if either is not a
/// hex digit. Shared by the four-byte probe above and the URI builtin's
/// general `%XX` decode bodies.
pub fn fastHexPair(high: u8, low: u8) ?u8 {
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

/// Decode a single hex digit byte into its value, or null if not a hex digit.
pub fn fastHexValue(byte: u8) ?u8 {
    const value = fast_hex_table[byte];
    if (value < 0) return null;
    return @intCast(value);
}

//! Pure NaN-box word operations. This module must not depend on heap layouts,
//! Runtime, the collector or language coercion. It never reads heap memory.
const std = @import("std");
const refs = @import("heap_ref.zig");

pub const payload_bits = refs.payload_bits;
pub const payload_mask = refs.payload_mask;
pub const float_max: u64 = 0xFFF0_0000_0000_0000;
pub const first_boxed: u64 = 0xFFF1_0000_0000_0000;
pub const heap_end: u64 = 0xFFF8_0000_0000_0000;
const prefix_base: u64 = 0xFFF0;
const canonical_nan: u64 = 0x7FF8_0000_0000_0000;
const inf_bits: u64 = 0x7FF0_0000_0000_0000;

pub fn boxedPrefix(comptime tag: i32) u64 {
    if (tag < -8 or tag == -5 or tag > 7) @compileError("not a boxed JSValue tag");
    return prefix_base + @as(u64, @intCast(8 + tag + @as(i32, @intFromBool(tag < -4))));
}

pub inline fn box(comptime tag: i32, raw_payload: u64) u64 {
    std.debug.assert(raw_payload <= payload_mask);
    return (boxedPrefix(tag) << payload_bits) | raw_payload;
}

pub inline fn payload(word: u64) u64 {
    return word & payload_mask;
}

pub inline fn tagOf(word: u64) i32 {
    if (word <= float_max) return 8;
    const index: i32 = @intCast((word >> payload_bits) - prefix_base);
    return index - 8 - @as(i32, @intFromBool(index < 4));
}

pub inline fn isKind(word: u64, comptime tag: i32) bool {
    if (comptime tag == 8) return word <= float_max;
    return (word >> payload_bits) == comptime boxedPrefix(tag);
}

pub inline fn isHeapReference(word: u64) bool {
    return word >= first_boxed and word < heap_end;
}

pub inline fn floatWord(value: f64) u64 {
    const word: u64 = @bitCast(value);
    return if ((word & 0x7FFF_FFFF_FFFF_FFFF) > inf_bits) canonical_nan else word;
}

pub inline fn intPayload(value: i32) u64 {
    return @as(u32, @bitCast(value));
}

pub inline fn intFromPayload(bits: u64) i32 {
    return @bitCast(@as(u32, @truncate(bits)));
}

test "pure value encoding preserves float boundaries and immediate payloads" {
    try std.testing.expectEqual(@as(u64, 0x8000_0000_0000_0000), floatWord(-0.0));
    try std.testing.expectEqual(@as(u64, 0), floatWord(0.0));
    try std.testing.expectEqual(canonical_nan, floatWord(@bitCast(@as(u64, 0xFFF8_0000_0000_0001))));
    try std.testing.expectEqual(inf_bits, floatWord(std.math.inf(f64)));
    try std.testing.expectEqual(float_max, floatWord(-std.math.inf(f64)));
    for ([_]i32{ std.math.minInt(i32), -1, 0, 1, std.math.maxInt(i32) }) |value| {
        const word = box(0, intPayload(value));
        try std.testing.expectEqual(@as(i32, 0), tagOf(word));
        try std.testing.expectEqual(value, intFromPayload(payload(word)));
        try std.testing.expect(!isHeapReference(word));
    }
}

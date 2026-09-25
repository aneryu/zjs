//! The bridge between opaque value references and collector carrier layouts.
const gc = @import("gc.zig");
const refs = @import("heap_ref.zig");
const JSValue = @import("value.zig").JSValue;

pub inline fn reference(carrier: *gc.Header) refs.HeapRef {
    return @ptrCast(carrier);
}

pub inline fn header(ref: refs.HeapRef) *gc.Header {
    return @ptrCast(ref);
}

/// Borrow a carrier body from a validated value address. This is an address
/// projection only: it neither reads metadata/link words nor proves the
/// carrier's kind, liveness, or Runtime membership. The caller supplies that
/// proof and must not keep the returned pointer across a moving safepoint.
pub inline fn body(comptime Carrier: type, ref: refs.HeapRef) *Carrier {
    return @ptrCast(@alignCast(ref));
}

/// Compatibility decode for value facades. Keep the numeric address checks
/// shared with HeapRef instead of allowing a second unchecked pointer codec.
pub inline fn bodyFromPayload(comptime Carrier: type, payload: u64) ?*Carrier {
    return body(Carrier, refs.decode(payload) orelse return null);
}

/// BigInt embeds its collector header; its offset belongs to the layout
/// adapter, not to the value's numeric conversion helpers.
pub inline fn bigIntBody(ref: refs.HeapRef) *@import("bigint.zig").BigInt {
    return @alignCast(@fieldParentPtr("header", header(ref)));
}

/// Trusted collector operation, called while both carriers are still valid.
/// A tag describes a JS value, not its physical carrier: in particular an
/// object-tagged VarRef cannot be replaced by an ordinary Object allocation.
pub fn relocate(value: JSValue, destination: refs.HeapRef) JSValue {
    const source = value.heapReference() orelse @panic("relocation requires a heap value");
    const relocated = replacePayload(value, destination);
    if (header(source).metaConst().flags.kind != header(destination).metaConst().flags.kind)
        @panic("relocation changes heap carrier kind");
    return relocated;
}

/// Compatibility bridge for the old raw Header API. The caller must prove
/// the destination names the same entity. Internal collectors use relocate.
pub inline fn replacePayload(value: JSValue, destination: refs.HeapRef) JSValue {
    if (!value.isHeapReference()) @panic("relocation requires a heap value");
    return .{ .bits = (value.bits & ~refs.payload_mask) | refs.encode(destination) };
}

test "layout body projections do not read carrier metadata" {
    const std = @import("std");
    const ref = try refs.fromAddress(0x1000);
    try std.testing.expectEqual(@as(usize, 0x1000), @intFromPtr(bigIntBody(ref)));
    try std.testing.expectEqual(ref, reference(body(gc.Header, ref)));
    try std.testing.expect(bodyFromPayload(gc.Header, 0) == null);
}

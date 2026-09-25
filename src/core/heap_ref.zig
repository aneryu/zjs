//! Value-level heap identity. No collector, metadata or object layout dependency.
//! A reference identifies an address only; rooting and heap membership are
//! separate contracts owned by Runtime and the collector.
const std = @import("std");

pub const HeapCell = opaque {};
pub const HeapRef = *align(8) HeapCell;
pub const payload_bits: u16 = 48;
pub const payload_mask: u64 = (@as(u64, 1) << payload_bits) - 1;
pub const AddressError = error{ NullHeapAddress, UnalignedHeapAddress, HeapAddressOutOfRange };

/// Validate numeric encoding constraints without reading memory. This does
/// not authenticate an address received from an untrusted host.
pub fn fromAddress(address: usize) AddressError!HeapRef {
    if (address == 0) return error.NullHeapAddress;
    if (address > payload_mask) return error.HeapAddressOutOfRange;
    if (address & 7 != 0) return error.UnalignedHeapAddress;
    return @ptrFromInt(address);
}

pub inline fn encode(reference: HeapRef) u64 {
    const address = @intFromPtr(reference);
    _ = fromAddress(address) catch |err| std.debug.panic("invalid JSValue heap address: {s}", .{@errorName(err)});
    return address;
}

pub inline fn decode(payload: u64) ?HeapRef {
    if (payload == 0) return null;
    return fromAddress(@intCast(payload)) catch |err| std.debug.panic("invalid JSValue heap payload: {s}", .{@errorName(err)});
}

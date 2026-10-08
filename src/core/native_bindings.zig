//! Host `NativeEntry` records owned by one runtime (`JSRuntime.native_bindings`).
//!
//! Entries are address-stable until teardown, so a call-site cache that
//! compares entry pointers can never reach freed memory. Finalizer
//! registrations run at teardown.

const std = @import("std");
const native_entry = @import("native_entry.zig");
const JSRuntime = @import("../runtime.zig").JSRuntime;

pub const Finalizer = struct {
    ptr: *anyopaque,
    finalize: *const fn (*anyopaque) void,
};

pub const Registry = struct {
    /// Individually allocated host entries; the list exists only to free them.
    entries: std.ArrayListUnmanaged(*native_entry.NativeEntry) = .empty,
    /// Ownership registrations for entry `state` pointers.
    finalizers: std.ArrayListUnmanaged(Finalizer) = .empty,
    /// Registrations reserved but not yet made. Creating the function between
    /// reserve and register can run weak callbacks that reserve and register
    /// their own, so capacity is kept for all of them.
    reserved_finalizers: usize = 0,
};

pub fn alloc(rt: *JSRuntime, template: native_entry.NativeEntry) !*const native_entry.NativeEntry {
    rt.assertOwnerThread();
    const entry = try rt.createNative(native_entry.NativeEntry);
    errdefer rt.destroyNative(native_entry.NativeEntry, entry);
    entry.* = template;
    try rt.native_bindings.entries.append(rt.nativeAllocator(), entry);
    return entry;
}

/// Return an entry no function object has installed yet (the failure path
/// of host function creation). Published entries stay until teardown.
pub fn abandon(rt: *JSRuntime, entry: *const native_entry.NativeEntry) void {
    const entries = &rt.native_bindings.entries;
    var index = entries.items.len;
    while (index != 0) {
        index -= 1;
        if (entries.items[index] == entry) {
            const owned = entries.swapRemove(index);
            rt.destroyNative(native_entry.NativeEntry, owned);
            return;
        }
    }
    @panic("abandoned native entry is not in this runtime's arena");
}

pub fn registerFinalizer(rt: *JSRuntime, ptr: *anyopaque, finalize: *const fn (*anyopaque) void) !void {
    try reserveFinalizer(rt);
    registerReservedFinalizer(rt, ptr, finalize);
}

/// Reserve one registration so a caller can publish its state first and
/// then register the finalizer without a failure in between. Pair with
/// `registerReservedFinalizer`, or `releaseFinalizerReservation` on failure.
pub fn reserveFinalizer(rt: *JSRuntime) !void {
    rt.assertOwnerThread();
    const bindings = &rt.native_bindings;
    try bindings.finalizers.ensureUnusedCapacity(rt.nativeAllocator(), bindings.reserved_finalizers + 1);
    bindings.reserved_finalizers += 1;
}

pub fn releaseFinalizerReservation(rt: *JSRuntime) void {
    std.debug.assert(rt.native_bindings.reserved_finalizers != 0);
    rt.native_bindings.reserved_finalizers -= 1;
}

pub fn registerReservedFinalizer(rt: *JSRuntime, ptr: *anyopaque, finalize: *const fn (*anyopaque) void) void {
    releaseFinalizerReservation(rt);
    rt.native_bindings.finalizers.appendAssumeCapacity(.{ .ptr = ptr, .finalize = finalize });
}

/// Run every finalizer registration, then free every entry.
pub fn destroyOwned(rt: *JSRuntime) void {
    var registry = rt.native_bindings;
    rt.native_bindings = .{};
    for (registry.finalizers.items) |item| item.finalize(item.ptr);
    registry.finalizers.deinit(rt.nativeAllocator());
    for (registry.entries.items) |entry| rt.destroyNative(native_entry.NativeEntry, entry);
    registry.entries.deinit(rt.nativeAllocator());
}

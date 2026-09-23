//! Host `NativeEntry` records owned by one runtime.
//!
//! Entries are address-stable until teardown. Retirement tombstones the
//! record in place and does not free it. Finalizer registrations run at
//! teardown, falling back to an immediate call if the deferred queue cannot
//! accept them. The lists stay on `JSRuntime`.

const mem_ops = @import("memory.zig");
const native_entry = @import("native_entry.zig");
const JSRuntime = @import("../runtime.zig").JSRuntime;

pub fn alloc(rt: *JSRuntime, template: native_entry.NativeEntry) !*const native_entry.NativeEntry {
    const entry = try mem_ops.create(rt, native_entry.NativeEntry);
    errdefer mem_ops.destroy(rt, native_entry.NativeEntry, entry);
    entry.* = template;
    try rt.native_entries.append(rt.nativeAllocator(), entry);
    return entry;
}

pub fn registerFinalizer(rt: *JSRuntime, ptr: *anyopaque, finalize: *const fn (*anyopaque) void) !void {
    try rt.native_entry_finalizers.append(rt.nativeAllocator(), .{ .ptr = ptr, .finalize = finalize });
}

pub fn retire(entry: *const native_entry.NativeEntry) void {
    const mutable: *native_entry.NativeEntry = @constCast(entry);
    mutable.kind = .retired;
}

pub fn destroyOwned(rt: *JSRuntime) void {
    const entry_finalizers = rt.native_entry_finalizers;
    rt.native_entry_finalizers = .empty;
    for (entry_finalizers.items) |item| {
        rt.enqueueDeferredNativeCleanup(item.finalize, item.ptr) catch {
            item.finalize(item.ptr);
        };
    }
    var finalizers_storage = entry_finalizers;
    finalizers_storage.deinit(rt.nativeAllocator());
    const entries = rt.native_entries;
    rt.native_entries = .empty;
    for (entries.items) |entry| mem_ops.destroy(rt, native_entry.NativeEntry, entry);
    var entries_storage = entries;
    entries_storage.deinit(rt.nativeAllocator());
}

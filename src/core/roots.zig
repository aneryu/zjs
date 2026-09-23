//! Strong and weak value handles, handle scopes, native pins, and the
//! runtime's root-provider storage.
//!
//! `JSRuntime` embeds one `RootSet` and is the only tracer that aggregates
//! strong roots. Weak slots are identity records, not value roots. Stack
//! `ValueRootFrame`s stay on the runtime. `bindInline` points the provider
//! slice at the inline array inside the runtime's final address.

const mem_ops = @import("memory.zig");
const std = @import("std");
const gc = @import("gc.zig");
const object_mod = @import("object.zig");
const runtime_mod = @import("../runtime.zig");
const JSRuntime = runtime_mod.JSRuntime;
const JSValue = @import("value.zig").JSValue;
const RootVisitor = runtime_mod.RootVisitor;
const RootTraceError = runtime_mod.RootTraceError;

const provider_inline_capacity = 1;

pub const RootProvider = struct {
    context: *anyopaque,
    trace: *const fn (context: *anyopaque, visitor: *RootVisitor) RootTraceError!void,
};

pub const RootSlot = struct {
    value: JSValue = JSValue.undefinedValue(),
};

pub const WeakPersistentCallback = *const fn (runtime: *JSRuntime, context: ?*anyopaque) void;

pub const WeakRootSlot = struct {
    identity: ?usize = null,
    callback: ?WeakPersistentCallback = null,
    callback_context: ?*anyopaque = null,
};

/// Host handles and declared root providers. Initialized in place: the
/// provider slice must point at `root_providers_inline` on the runtime that
/// owns this set, not at a copy.
pub const RootSet = struct {
    root_providers: []RootProvider = &.{},
    root_providers_capacity: usize = 0,
    root_providers_inline: [provider_inline_capacity]RootProvider = undefined,
    /// Native owning buffers must be released before Runtime teardown.
    value_root_buffers: usize = 0,
    local_root_slots: std.ArrayListUnmanaged(*RootSlot) = .empty,
    persistent_root_slots: std.ArrayListUnmanaged(*RootSlot) = .empty,
    weak_root_slots: std.ArrayListUnmanaged(*WeakRootSlot) = .empty,

    pub fn bindInline(self: *RootSet) void {
        self.root_providers_inline = undefined;
        self.root_providers = self.root_providers_inline[0..0];
        self.root_providers_capacity = self.root_providers_inline.len;
        self.value_root_buffers = 0;
        self.local_root_slots = .empty;
        self.persistent_root_slots = .empty;
        self.weak_root_slots = .empty;
    }

    pub fn usingInline(self: *const RootSet) bool {
        return self.root_providers.ptr == self.root_providers_inline[0..].ptr;
    }

    /// Heap buffer to free, or an empty slice when the providers still sit
    /// in the inline array. Clears the set's provider fields either way.
    pub fn takeHeapProviderStorage(self: *RootSet) []RootProvider {
        const heap: []RootProvider = if (self.root_providers_capacity != 0 and !self.usingInline())
            self.root_providers.ptr[0..self.root_providers_capacity]
        else
            self.root_providers[0..0];
        self.root_providers = &.{};
        self.root_providers_capacity = 0;
        return heap;
    }

    pub fn deinitSlotLists(self: *RootSet, allocator: std.mem.Allocator) void {
        self.local_root_slots.deinit(allocator);
        self.persistent_root_slots.deinit(allocator);
        self.weak_root_slots.deinit(allocator);
    }

    pub fn register(self: *RootSet, rt: *JSRuntime, provider: RootProvider) !void {
        for (self.root_providers) |registered| {
            if (registered.context == provider.context and registered.trace == provider.trace) return;
        }
        try self.append(rt, provider);
    }

    pub fn unregister(self: *RootSet, rt: *JSRuntime, provider: RootProvider) void {
        var found: ?usize = null;
        for (self.root_providers, 0..) |registered, index| {
            if (registered.context == provider.context and registered.trace == provider.trace) {
                found = index;
                break;
            }
        }
        const index = found orelse return;
        if (index + 1 < self.root_providers.len) {
            std.mem.copyForwards(RootProvider, self.root_providers[index .. self.root_providers.len - 1], self.root_providers[index + 1 ..]);
        }
        self.root_providers = self.root_providers[0 .. self.root_providers.len - 1];
        if (self.root_providers.len == 0 and self.root_providers_capacity != 0) {
            if (self.usingInline()) {
                self.root_providers = self.root_providers_inline[0..0];
                self.root_providers_capacity = self.root_providers_inline.len;
                return;
            }
            const old_providers = self.root_providers.ptr[0..self.root_providers_capacity];
            self.root_providers = self.root_providers_inline[0..0];
            self.root_providers_capacity = self.root_providers_inline.len;
            mem_ops.free(rt, RootProvider, old_providers);
        }
    }

    fn append(self: *RootSet, rt: *JSRuntime, provider: RootProvider) !void {
        while (self.root_providers.len == self.root_providers_capacity) {
            const next_capacity = if (self.root_providers_capacity == 0)
                provider_inline_capacity
            else
                std.math.mul(usize, self.root_providers_capacity, 2) catch return error.OutOfMemory;
            const next = try mem_ops.alloc(rt, RootProvider, next_capacity);
            // Allocation can reenter registration through a collection/probe.
            // Re-read the live table before copying: a nested call may already
            // have grown it, or filled more entries than this candidate holds.
            if (self.root_providers.len < self.root_providers_capacity or
                self.root_providers.len >= next_capacity)
            {
                mem_ops.free(rt, RootProvider, next);
                continue;
            }
            @memcpy(next[0..self.root_providers.len], self.root_providers);
            const old_capacity = self.root_providers_capacity;
            const old_using_inline = self.usingInline();
            const old = if (!old_using_inline and old_capacity != 0) self.root_providers.ptr[0..old_capacity] else self.root_providers[0..0];
            self.root_providers = next[0..self.root_providers.len];
            self.root_providers_capacity = next_capacity;
            if (old.len != 0) mem_ops.free(rt, RootProvider, old);
        }
        const len = self.root_providers.len;
        self.root_providers = self.root_providers.ptr[0 .. len + 1];
        self.root_providers[len] = provider;
    }

    pub fn traceHandleSlots(self: *const RootSet, visitor: *RootVisitor) RootTraceError!void {
        for (self.local_root_slots.items) |slot| {
            try visitor.value(&slot.value);
        }
        for (self.persistent_root_slots.items) |slot| {
            try visitor.value(&slot.value);
        }
    }

    pub fn traceProviders(self: *const RootSet, visitor: *RootVisitor) RootTraceError!void {
        for (self.root_providers) |provider| {
            try provider.trace(provider.context, visitor);
        }
    }

    pub fn createPersistent(self: *RootSet, rt: *JSRuntime, value: JSValue) !*RootSlot {
        return createStrong(rt, value, &self.persistent_root_slots);
    }

    pub fn createLocal(self: *RootSet, rt: *JSRuntime, value: JSValue) !*RootSlot {
        return createStrong(rt, value, &self.local_root_slots);
    }

    pub fn createWeak(
        self: *RootSet,
        rt: *JSRuntime,
        identity: usize,
        callback: ?WeakPersistentCallback,
        callback_context: ?*anyopaque,
    ) !*WeakRootSlot {
        const budget = &rt.gc.heap_budget;
        const saved_suspend = budget.suspend_alloc_notify;
        budget.suspend_alloc_notify = true;
        defer budget.suspend_alloc_notify = saved_suspend;

        const slot = try mem_ops.create(rt, WeakRootSlot);
        errdefer mem_ops.destroy(rt, WeakRootSlot, slot);
        slot.* = .{
            .identity = identity,
            .callback = callback,
            .callback_context = callback_context,
        };
        try self.weak_root_slots.append(rt.nativeAllocator(), slot);
        return slot;
    }

    fn createStrong(rt: *JSRuntime, value: JSValue, slots: *std.ArrayListUnmanaged(*RootSlot)) !*RootSlot {
        const budget = &rt.gc.heap_budget;
        const saved_suspend = budget.suspend_alloc_notify;
        budget.suspend_alloc_notify = true;
        defer budget.suspend_alloc_notify = saved_suspend;

        const slot = try mem_ops.create(rt, RootSlot);
        errdefer mem_ops.destroy(rt, RootSlot, slot);
        slot.* = .{ .value = JSValue.undefinedValue() };
        try slots.append(rt.nativeAllocator(), slot);
        slot.value = value;
        return slot;
    }

    pub fn destroyWeak(self: *RootSet, rt: *JSRuntime, slot: *WeakRootSlot) void {
        self.removeWeak(rt, slot);
        rt.clearWeakRootSlot(slot, false);
        slot.* = .{};
        mem_ops.destroy(rt, WeakRootSlot, slot);
    }

    fn removeWeak(self: *RootSet, rt: *JSRuntime, slot: *WeakRootSlot) void {
        var found: ?usize = null;
        for (self.weak_root_slots.items, 0..) |registered, index| {
            if (registered == slot) {
                found = index;
                break;
            }
        }
        const index = found.?;
        _ = self.weak_root_slots.orderedRemove(index);
        if (self.weak_root_slots.items.len == 0) self.weak_root_slots.clearAndFree(rt.nativeAllocator());
    }

    pub fn takePersistent(self: *RootSet, rt: *JSRuntime, slot: *RootSlot) JSValue {
        self.removePersistent(rt, slot);
        const value = slot.value;
        slot.value = JSValue.undefinedValue();
        mem_ops.destroy(rt, RootSlot, slot);
        return value;
    }

    fn removePersistent(self: *RootSet, rt: *JSRuntime, slot: *RootSlot) void {
        var found: ?usize = null;
        for (self.persistent_root_slots.items, 0..) |registered, index| {
            if (registered == slot) {
                found = index;
                break;
            }
        }
        const index = found.?;
        _ = self.persistent_root_slots.orderedRemove(index);
        if (self.persistent_root_slots.items.len == 0) self.persistent_root_slots.clearAndFree(rt.nativeAllocator());
    }

    pub fn assertNoOutstandingBuffers(self: *const RootSet) void {
        if (self.value_root_buffers != 0)
            @panic("JSRuntime destroyed with outstanding value root buffers");
    }

    pub fn assertNoOutstanding(self: *const RootSet) void {
        if (self.local_root_slots.items.len != 0 or
            self.persistent_root_slots.items.len != 0 or
            self.weak_root_slots.items.len != 0)
        {
            @panic("JSRuntime destroyed with outstanding value handles");
        }
    }

    pub fn clearLocalFrom(self: *RootSet, rt: *JSRuntime, start: usize) void {
        std.debug.assert(start <= self.local_root_slots.items.len);
        var index = self.local_root_slots.items.len;
        while (index > start) {
            index -= 1;
            const slot = self.local_root_slots.items[index];
            slot.value = JSValue.undefinedValue();
            mem_ops.destroy(rt, RootSlot, slot);
        }
        self.local_root_slots.shrinkRetainingCapacity(start);
        if (self.local_root_slots.items.len == 0) self.local_root_slots.clearAndFree(rt.nativeAllocator());
    }
};

pub const JSValueHandle = struct {
    runtime: ?*JSRuntime = null,
    slot: ?*RootSlot = null,

    /// Stores `value` in a new strong persistent slot. A `JSValue` is copied
    /// by bits; this does not retain a separate heap reference.
    pub fn init(runtime: *JSRuntime, value: JSValue) !JSValueHandle {
        const slot = try runtime.roots.createPersistent(runtime, value);
        return .{
            .runtime = runtime,
            .slot = slot,
        };
    }

    /// Same operation as `init`. The name stays for callers that still say "dup".
    pub fn initDup(runtime: *JSRuntime, value: JSValue) !JSValueHandle {
        return init(runtime, value);
    }

    pub fn get(self: JSValueHandle) JSValue {
        const slot = self.slot orelse return JSValue.undefinedValue();
        return slot.value;
    }

    pub fn deinit(self: *JSValueHandle) void {
        const runtime = self.runtime orelse return;
        const slot = self.slot orelse return;
        self.runtime = null;
        self.slot = null;
        _ = runtime.roots.takePersistent(runtime, slot);
    }

    /// Compatibility spelling: by-value wrapper that asserts `rt` matches the
    /// handle's runtime, then drops the root. Prefer `deinit` on a mutable handle.
    pub fn destroy(self: JSValueHandle, rt: *JSRuntime) void {
        if (self.runtime) |runtime| std.debug.assert(runtime == rt);
        var owned = self;
        owned.deinit();
    }

    /// Transfer ownership of the rooted value out of the handle.
    pub fn take(self: *JSValueHandle) JSValue {
        const runtime = self.runtime orelse return JSValue.undefinedValue();
        const slot = self.slot orelse return JSValue.undefinedValue();
        const value = runtime.roots.takePersistent(runtime, slot);
        self.runtime = null;
        self.slot = null;
        return value;
    }
};

pub const LocalHandle = struct {
    slot: *RootSlot,

    pub fn get(self: LocalHandle) JSValue {
        return self.slot.value;
    }

    pub fn valueSlot(self: LocalHandle) *JSValue {
        return &self.slot.value;
    }
};

pub const HandleScope = struct {
    runtime: *JSRuntime,
    start: usize,
    active: bool = true,

    pub fn enter(runtime: *JSRuntime) HandleScope {
        return .{
            .runtime = runtime,
            .start = runtime.roots.local_root_slots.items.len,
        };
    }

    pub fn deinit(self: *HandleScope) void {
        if (!self.active) return;
        std.debug.assert(self.start <= self.runtime.roots.local_root_slots.items.len);
        self.runtime.roots.clearLocalFrom(self.runtime, self.start);
        self.active = false;
    }

    /// Stores `value` in a new strong slot owned by this scope.
    pub fn local(self: *HandleScope, value: JSValue) !LocalHandle {
        std.debug.assert(self.active);
        const slot = try self.runtime.roots.createLocal(self.runtime, value);
        return .{ .slot = slot };
    }

    /// Same operation as `local`.
    pub fn localDup(self: *HandleScope, value: JSValue) !LocalHandle {
        return self.local(value);
    }
};

pub const WeakPersistentValue = struct {
    runtime: ?*JSRuntime = null,
    slot: ?*WeakRootSlot = null,

    pub fn init(
        runtime: *JSRuntime,
        value: JSValue,
        callback: ?WeakPersistentCallback,
        callback_context: ?*anyopaque,
    ) !WeakPersistentValue {
        const identity = (try object_mod.Object.weakIdentityFromValue(runtime, value)) orelse return error.InvalidWeakTarget;
        const slot = try runtime.roots.createWeak(runtime, identity, callback, callback_context);
        runtime.retainWeakIdentity(identity);
        return .{
            .runtime = runtime,
            .slot = slot,
        };
    }

    pub fn get(self: WeakPersistentValue) JSValue {
        const runtime = self.runtime orelse return JSValue.undefinedValue();
        const slot = self.slot orelse return JSValue.undefinedValue();
        const identity = slot.identity orelse return JSValue.undefinedValue();
        return runtime.valueFromWeakIdentity(identity);
    }

    pub fn isAlive(self: WeakPersistentValue) bool {
        const runtime = self.runtime orelse return false;
        const slot = self.slot orelse return false;
        const identity = slot.identity orelse return false;
        return runtime.weakIdentityIsCurrentlyLive(identity);
    }

    pub fn deinit(self: *WeakPersistentValue) void {
        const runtime = self.runtime orelse return;
        const slot = self.slot orelse return;
        self.runtime = null;
        self.slot = null;
        runtime.roots.destroyWeak(runtime, slot);
    }

    pub fn destroy(self: WeakPersistentValue, rt: *JSRuntime) void {
        if (self.runtime) |runtime| std.debug.assert(runtime == rt);
        var owned = self;
        owned.deinit();
    }
};

pub const WeakPersistent = WeakPersistentValue;

pub const NativePin = struct {
    runtime: ?*JSRuntime = null,
    header: ?*gc.Header = null,

    pub fn deinit(self: *NativePin) void {
        const runtime = self.runtime orelse return;
        const header = self.header orelse return;
        self.runtime = null;
        self.header = null;
        runtime.gc.unpinHeader(header);
    }
};

pub fn pinValueForNative(runtime: *JSRuntime, value: JSValue) !?NativePin {
    const header = value.refHeader() orelse value.functionBytecodeHeader() orelse return null;
    return try pinHeaderForNative(runtime, header);
}

pub fn pinHeaderForNative(runtime: *JSRuntime, header: *gc.Header) !NativePin {
    try runtime.gc.pinHeader(header);
    return .{
        .runtime = runtime,
        .header = header,
    };
}

/// Fixed-length native copy whose values are strong roots until deinit.
/// Owns its backing block; assignment does not duplicate ownership. Moving
/// ownership (including return by value) is safe because registration points
/// at the block, never at this wrapper. Runtime must outlive the buffer.
pub const ValueRootBuffer = struct {
    block: ?*Block = null,

    const Block = struct {
        runtime: *JSRuntime,
        len: usize,

        fn slots(self: *Block) []JSValue {
            const bytes: [*]u8 = @ptrCast(self);
            const ptr: [*]JSValue = @ptrCast(@alignCast(bytes + slots_offset));
            return ptr[0..self.len];
        }

        fn provider(self: *Block) RootProvider {
            return .{ .context = self, .trace = trace };
        }

        fn trace(raw: *anyopaque, visitor: *RootVisitor) RootTraceError!void {
            const self: *Block = @ptrCast(@alignCast(raw));
            try visitor.values(self.slots());
        }
    };
    const block_alignment = std.mem.Alignment.fromByteUnits(@max(@alignOf(Block), @alignOf(JSValue)));
    const slots_offset = std.mem.alignForward(usize, @sizeOf(Block), @alignOf(JSValue));

    /// Protects source during allocation, then the copy through registration.
    /// Source storage must remain valid until this call returns. Success needs
    /// no additional ValueRootFrame, including across subsequent collections.
    pub fn initCopy(rt: *JSRuntime, source: []const JSValue) !ValueRootBuffer {
        rt.assertOwnerThread();
        if (source.len == 0) return .{};
        const payload_bytes = std.math.mul(usize, source.len, @sizeOf(JSValue)) catch return error.OutOfMemory;
        const total_bytes = std.math.add(usize, slots_offset, payload_bytes) catch return error.OutOfMemory;
        var slices = [_]runtime_mod.ValueRootSlice{.{ .borrowed = source }};
        var frame = runtime_mod.ValueRootFrame{ .slices = &slices };
        frame.activate(rt);
        defer frame.deactivate(rt);

        const bytes = try mem_ops.allocElements(rt, total_bytes, 1, block_alignment);
        errdefer mem_ops.freeAlignedBytes(rt, bytes, block_alignment);
        const block: *Block = @ptrCast(@alignCast(bytes.ptr));
        block.* = .{ .runtime = rt, .len = source.len };
        const copied_values = block.slots();
        @memcpy(copied_values, source);
        // Transfer temporary protection to the snapshot before registration:
        // reentrant work during provider growth may modify the original source.
        slices[0] = .{ .mutable = &copied_values };
        try rt.registerRootProvider(block.provider());
        rt.roots.value_root_buffers += 1;
        return .{ .block = block };
    }

    /// Borrowed view, valid until deinit. The container retains root ownership.
    pub fn values(self: *const ValueRootBuffer) []const JSValue {
        return if (self.block) |block| block.slots() else &.{};
    }

    /// May run in any order relative to other buffers. Repeated calls on the
    /// same wrapper are harmless; aliased owners must never be destroyed twice.
    pub fn deinit(self: *ValueRootBuffer) void {
        const block = self.block orelse return;
        const rt = block.runtime;
        rt.assertOwnerThread();
        rt.unregisterRootProvider(block.provider());
        std.debug.assert(rt.roots.value_root_buffers != 0);
        rt.roots.value_root_buffers -= 1;
        const bytes: [*]u8 = @ptrCast(block);
        const total_bytes = slots_offset + block.len * @sizeOf(JSValue);
        self.block = null;
        mem_ops.freeAlignedBytes(rt, bytes[0..total_bytes], block_alignment);
    }
};

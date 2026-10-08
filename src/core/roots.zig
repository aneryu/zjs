//! Strong and weak value handles, handle scopes, native pins, and the
//! runtime's root-provider storage.
//!
//! `JSRuntime` embeds one `RootSet` and is the only tracer that aggregates
//! strong roots. Weak slots are identity records, not value roots. Stack
//! `ValueRootFrame`s stay on the runtime. Inline provider views are derived
//! on access, so an empty RootSet needs no address binding.

const std = @import("std");
const gc = @import("gc.zig");
const gc_roots = @import("gc_roots.zig");
const object_mod = @import("object.zig");
const runtime_mod = @import("../runtime.zig");
const JSRuntime = runtime_mod.JSRuntime;
const JSValue = @import("value.zig").JSValue;
const RootVisitor = gc_roots.RootVisitor;
const RootTraceError = gc_roots.RootTraceError;

const provider_inline_capacity = 1;

pub const RootProvider = struct {
    context: *anyopaque,
    /// Enumerate the same roots on every walk while collection is active.
    /// A relocating collector first walks to retain readonly targets, then
    /// walks to mark and update slots. Do not consume entries or mutate the
    /// root set from this callback; failures may abort either walk.
    trace: *const fn (context: *anyopaque, visitor: *RootVisitor) RootTraceError!void,
};

pub const RootSlot = struct {
    value: JSValue = JSValue.undefinedValue(),
};

pub const RootReferenceError = error{
    WrongRuntime,
    InactiveRoot,
    InvalidRootIndex,
    RootMutationDuringCollection,
};

/// Internal registration record. Only live records are traversed when
/// validating a borrowed reference, never the reference's possibly dead frame.
const ExactValueRootFrame = struct {
    runtime: ?*JSRuntime = null,
    previous: ?*ExactValueRootFrame = null,
    generation: u64 = 0,
    values: []JSValue = &.{},
    slices: [1]runtime_mod.ValueRootSlice = undefined,
    frame: runtime_mod.ValueRootFrame = .{},

    fn activate(self: *@This(), rt: *JSRuntime, values: []JSValue) !void {
        rt.assertOwnerThread();
        if (self.runtime != null) return error.RootAlreadyActive;
        if (rt.gc.hot.collecting or rt.roots.isTracing()) return error.RootMutationDuringCollection;
        const generation = std.math.add(u64, rt.roots.exact_root_generation, 1) catch return error.RootGenerationExhausted;
        // A deactivated scope can contain pointers reclaimed since its last
        // use. Never publish that old storage on reactivation.
        @memset(values, JSValue.undefinedValue());
        self.values = values;
        self.slices[0] = .{ .mutable = &self.values };
        self.frame = .{ .slices = &self.slices };
        self.frame.activate(rt);
        self.runtime = rt;
        self.generation = generation;
        self.previous = rt.roots.active_exact_roots;
        rt.roots.exact_root_generation = generation;
        rt.roots.active_exact_roots = self;
    }

    fn deactivate(self: *@This()) void {
        const rt = self.runtime orelse return;
        rt.assertOwnerThread();
        if (rt.gc.hot.collecting) @panic("exact root mutation during collection");
        rt.roots.assertMutable();
        if (rt.roots.active_exact_roots != self or rt.active_value_roots != &self.frame)
            @panic("exact roots must deactivate in root-frame LIFO order");
        self.frame.deactivate(rt);
        rt.roots.active_exact_roots = self.previous;
        self.runtime = null;
        self.previous = null;
        self.values = &.{};
    }
};

/// Borrow of a registered slot, not a copied value. Runtime must outlive the
/// reference. Scope membership and generation are checked before slot access.
pub const RootedValueRef = struct {
    runtime: *JSRuntime,
    owner: *const ExactValueRootFrame,
    generation: u64,
    index: usize,

    fn slot(self: @This(), rt: *JSRuntime) RootReferenceError!*JSValue {
        if (self.runtime != rt) return error.WrongRuntime;
        rt.assertOwnerThread();
        var current = rt.roots.active_exact_roots;
        while (current) |frame| : (current = frame.previous) {
            if (frame != self.owner) continue;
            if (frame.generation != self.generation) return error.InactiveRoot;
            if (self.index >= frame.values.len) return error.InvalidRootIndex;
            return &frame.values[self.index];
        }
        return error.InactiveRoot;
    }

    pub fn get(self: @This(), rt: *JSRuntime) RootReferenceError!JSValue {
        return (try self.slot(rt)).*;
    }
};

pub const MutableRootedValueRef = struct {
    reference: RootedValueRef,

    pub fn readOnly(self: @This()) RootedValueRef {
        return self.reference;
    }

    pub fn get(self: @This(), rt: *JSRuntime) RootReferenceError!JSValue {
        return self.reference.get(rt);
    }

    /// Check an output before a fallible operation, without changing its value.
    pub fn validate(self: @This(), rt: *JSRuntime) RootReferenceError!void {
        _ = try self.reference.slot(rt);
        if (rt.gc.hot.collecting or rt.roots.isTracing()) return error.RootMutationDuringCollection;
    }

    pub fn set(self: @This(), rt: *JSRuntime, value: JSValue) RootReferenceError!void {
        const destination = try self.reference.slot(rt);
        if (rt.gc.hot.collecting or rt.roots.isTracing()) return error.RootMutationDuringCollection;
        destination.* = value;
    }

    /// Alias-safe, allocation-free transfer between two registered slots.
    pub fn copyFrom(self: @This(), rt: *JSRuntime, source: RootedValueRef) RootReferenceError!void {
        const value = try source.get(rt);
        try self.set(rt, value);
    }
};

/// Declare, then activate at the final address. Slots start as undefined;
/// activation never allocates, so installing the initial value needs no extra
/// root. Never copy or move an active scope.
pub fn ExactValueRoots(comptime count: usize) type {
    return struct {
        storage: [count]JSValue = @splat(JSValue.undefinedValue()),
        registration: ExactValueRootFrame = .{},

        pub fn activate(self: *@This(), rt: *JSRuntime) !void {
            try self.registration.activate(rt, &self.storage);
        }

        pub fn deactivate(self: *@This()) void {
            self.registration.deactivate();
        }

        pub fn ref(self: *@This(), comptime index: usize) RootReferenceError!MutableRootedValueRef {
            if (index >= count) @compileError("exact root index out of bounds");
            const frame = &self.registration;
            const rt = frame.runtime orelse return error.InactiveRoot;
            const reference = RootedValueRef{ .runtime = rt, .owner = frame, .generation = frame.generation, .index = index };
            _ = try reference.slot(rt);
            return .{ .reference = reference };
        }
    };
}

pub const WeakPersistentCallback = *const fn (runtime: *JSRuntime, context: ?*anyopaque) void;

pub const WeakRootSlot = struct {
    identity: ?usize = null,
    callback: ?WeakPersistentCallback = null,
    callback_context: ?*anyopaque = null,
    /// Queued in `RootSet.weak_notify_queue` until its callback runs.
    notify_pending: bool = false,
};

/// Host handles and declared root providers. Inline storage contains no
/// self-pointer; the default value is immediately usable.
pub const RootSet = struct {
    /// Owner-thread trace windows can nest. Collector slot repair remains
    /// legal; mutator changes to roots and registration storage do not.
    trace_depth: usize = 0,
    active_exact_roots: ?*ExactValueRootFrame = null,
    exact_root_generation: u64 = 0,
    root_providers_heap: ?[]RootProvider = null,
    root_providers_len: usize = 0,
    root_providers_inline: [provider_inline_capacity]RootProvider = undefined,
    /// Native owning buffers must be released before Runtime teardown.
    value_root_buffers: usize = 0,
    local_root_slots: std.ArrayListUnmanaged(*RootSlot) = .empty,
    handle_scope_depth: usize = 0,
    persistent_root_slots: std.ArrayListUnmanaged(*RootSlot) = .empty,
    weak_root_slots: std.ArrayListUnmanaged(*WeakRootSlot) = .empty,
    /// Slots the last major cleared whose callbacks have not run yet. Weak
    /// processing runs inside the collection, where a callback that releases
    /// a handle or allocates would corrupt the collector; the callbacks run
    /// once it returns (`JSRuntime.runPendingWeakCallbacks`). Capacity always
    /// covers `weak_root_slots`, so queueing never allocates.
    weak_notify_queue: std.ArrayListUnmanaged(*WeakRootSlot) = .empty,
    weak_notify_draining: bool = false,

    pub fn beginTrace(self: *RootSet) void {
        self.trace_depth = std.math.add(usize, self.trace_depth, 1) catch @panic("root trace depth exhausted");
    }

    pub fn endTrace(self: *RootSet) void {
        if (self.trace_depth == 0) @panic("unbalanced root trace window");
        self.trace_depth -= 1;
    }

    pub fn isTracing(self: *const RootSet) bool {
        return self.trace_depth != 0;
    }

    pub fn assertMutable(self: *const RootSet) void {
        if (self.isTracing()) @panic("root mutation during tracing");
    }

    pub fn usingInline(self: *const RootSet) bool {
        return self.root_providers_heap == null;
    }

    pub fn providerCapacity(self: *const RootSet) usize {
        return if (self.root_providers_heap) |heap| heap.len else provider_inline_capacity;
    }

    pub fn providers(self: *const RootSet) []const RootProvider {
        const storage: []const RootProvider = self.root_providers_heap orelse &self.root_providers_inline;
        return storage[0..self.root_providers_len];
    }

    fn providerStorage(self: *RootSet) []RootProvider {
        return self.root_providers_heap orelse &self.root_providers_inline;
    }

    /// Transfer heap storage to the caller and restore the default empty set.
    fn takeHeapProviderStorage(self: *RootSet) []RootProvider {
        self.assertMutable();
        const heap: []RootProvider = self.root_providers_heap orelse &.{};
        self.root_providers_heap = null;
        self.root_providers_len = 0;
        return heap;
    }

    /// Release provider and slot-list storage at runtime teardown.
    pub fn deinit(self: *RootSet, rt: *JSRuntime) void {
        const heap = self.takeHeapProviderStorage();
        if (heap.len != 0) rt.freeNative(RootProvider, heap);
        const allocator = rt.nativeAllocator();
        self.local_root_slots.deinit(allocator);
        self.persistent_root_slots.deinit(allocator);
        self.weak_root_slots.deinit(allocator);
        self.weak_notify_queue.deinit(allocator);
    }

    pub fn register(self: *RootSet, rt: *JSRuntime, provider: RootProvider) !void {
        self.assertMutable();
        for (self.providers()) |registered| {
            if (registered.context == provider.context and registered.trace == provider.trace) return;
        }
        try self.append(rt, provider);
    }

    pub fn unregister(self: *RootSet, rt: *JSRuntime, provider: RootProvider) void {
        self.assertMutable();
        var found: ?usize = null;
        for (self.providers(), 0..) |registered, index| {
            if (registered.context == provider.context and registered.trace == provider.trace) {
                found = index;
                break;
            }
        }
        const index = found orelse return;
        const storage = self.providerStorage();
        if (index + 1 < self.root_providers_len) {
            std.mem.copyForwards(RootProvider, storage[index .. self.root_providers_len - 1], storage[index + 1 .. self.root_providers_len]);
        }
        self.root_providers_len -= 1;
        if (self.root_providers_len == 0) {
            const heap = self.takeHeapProviderStorage();
            if (heap.len != 0) rt.freeNative(RootProvider, heap);
        }
    }

    fn append(self: *RootSet, rt: *JSRuntime, provider: RootProvider) !void {
        while (self.root_providers_len == self.providerCapacity()) {
            const next_capacity = std.math.mul(usize, self.providerCapacity(), 2) catch return error.OutOfMemory;
            const next = try rt.allocNative(RootProvider, next_capacity);
            // Allocation can reenter registration. Re-read the live storage
            // before copying or committing a candidate buffer.
            if (self.root_providers_len < self.providerCapacity() or self.root_providers_len >= next_capacity) {
                rt.freeNative(RootProvider, next);
                continue;
            }
            @memcpy(next[0..self.root_providers_len], self.providers());
            const old = self.root_providers_heap;
            self.root_providers_heap = next;
            if (old) |heap| rt.freeNative(RootProvider, heap);
        }
        self.providerStorage()[self.root_providers_len] = provider;
        self.root_providers_len += 1;
    }

    pub fn traceHandleSlots(self: *RootSet, visitor: *RootVisitor) RootTraceError!void {
        self.beginTrace();
        defer self.endTrace();
        for (self.local_root_slots.items) |slot| {
            try visitor.value(&slot.value);
        }
        for (self.persistent_root_slots.items) |slot| {
            try visitor.value(&slot.value);
        }
    }

    pub fn traceProviders(self: *RootSet, visitor: *RootVisitor) RootTraceError!void {
        self.beginTrace();
        defer self.endTrace();
        for (self.providers()) |provider| {
            try provider.trace(provider.context, visitor);
        }
    }

    pub fn createPersistent(self: *RootSet, rt: *JSRuntime, value: JSValue) !*RootSlot {
        self.assertMutable();
        return createStrong(rt, value, &self.persistent_root_slots);
    }

    pub fn createLocal(self: *RootSet, rt: *JSRuntime, value: JSValue) !*RootSlot {
        self.assertMutable();
        return createStrong(rt, value, &self.local_root_slots);
    }

    pub fn createWeak(
        self: *RootSet,
        rt: *JSRuntime,
        identity: usize,
        callback: ?WeakPersistentCallback,
        callback_context: ?*anyopaque,
    ) !*WeakRootSlot {
        self.assertMutable();
        const budget = &rt.gc.heap_budget;
        const saved_suspend = budget.suspend_alloc_notify;
        budget.suspend_alloc_notify = true;
        defer budget.suspend_alloc_notify = saved_suspend;

        const slot = try rt.createNative(WeakRootSlot);
        errdefer rt.destroyNative(WeakRootSlot, slot);
        slot.* = .{
            .identity = identity,
            .callback = callback,
            .callback_context = callback_context,
        };
        try self.weak_root_slots.append(rt.nativeAllocator(), slot);
        errdefer _ = self.weak_root_slots.pop();
        try self.weak_notify_queue.ensureTotalCapacity(rt.nativeAllocator(), self.weak_root_slots.items.len);
        return slot;
    }

    /// Collector side: queue a cleared slot's callback without allocating.
    pub fn queueWeakNotify(self: *RootSet, slot: *WeakRootSlot) void {
        if (slot.callback == null or slot.notify_pending) return;
        slot.notify_pending = true;
        self.weak_notify_queue.appendAssumeCapacity(slot);
    }

    fn createStrong(rt: *JSRuntime, value: JSValue, slots: *std.ArrayListUnmanaged(*RootSlot)) !*RootSlot {
        const budget = &rt.gc.heap_budget;
        const saved_suspend = budget.suspend_alloc_notify;
        budget.suspend_alloc_notify = true;
        defer budget.suspend_alloc_notify = saved_suspend;

        const slot = try rt.createNative(RootSlot);
        errdefer rt.destroyNative(RootSlot, slot);
        slot.* = .{ .value = JSValue.undefinedValue() };
        try slots.append(rt.nativeAllocator(), slot);
        slot.value = value;
        return slot;
    }

    pub fn destroyWeak(self: *RootSet, rt: *JSRuntime, slot: *WeakRootSlot) void {
        self.assertMutable();
        self.removeWeak(rt, slot);
        rt.clearWeakRootSlot(slot);
        slot.* = .{};
        rt.destroyNative(WeakRootSlot, slot);
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
        // A handle released before its callback ran cancels the callback.
        if (slot.notify_pending) {
            const queued = std.mem.indexOfScalar(*WeakRootSlot, self.weak_notify_queue.items, slot).?;
            _ = self.weak_notify_queue.orderedRemove(queued);
            slot.notify_pending = false;
        }
        if (self.weak_root_slots.items.len == 0) {
            self.weak_root_slots.clearAndFree(rt.nativeAllocator());
            self.weak_notify_queue.clearAndFree(rt.nativeAllocator());
        }
    }

    pub fn takePersistent(self: *RootSet, rt: *JSRuntime, slot: *RootSlot) JSValue {
        self.assertMutable();
        self.removePersistent(rt, slot);
        const value = slot.value;
        slot.value = JSValue.undefinedValue();
        rt.destroyNative(RootSlot, slot);
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
        if (self.active_exact_roots != null)
            @panic("JSRuntime destroyed with active exact roots");
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
        self.assertMutable();
        std.debug.assert(start <= self.local_root_slots.items.len);
        var index = self.local_root_slots.items.len;
        while (index > start) {
            index -= 1;
            const slot = self.local_root_slots.items[index];
            slot.value = JSValue.undefinedValue();
            rt.destroyNative(RootSlot, slot);
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

    pub fn get(self: JSValueHandle) JSValue {
        const slot = self.slot orelse return JSValue.undefinedValue();
        return slot.value;
    }

    pub fn deinit(self: *JSValueHandle) void {
        const runtime = self.runtime orelse return;
        const slot = self.slot orelse return;
        runtime.roots.assertMutable();
        self.runtime = null;
        self.slot = null;
        _ = runtime.roots.takePersistent(runtime, slot);
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

    /// Install the destination before consuming this persistent root. Failure
    /// leaves both source ownership and the destination value unchanged.
    pub fn takeInto(self: *JSValueHandle, destination: MutableRootedValueRef) !void {
        const rt = self.runtime orelse return error.InactiveHandle;
        const slot = self.slot orelse return error.InactiveHandle;
        try destination.set(rt, slot.value);
        _ = self.take();
    }
};

pub const LocalHandle = struct {
    slot: *RootSlot,

    pub fn get(self: LocalHandle) JSValue {
        return self.slot.value;
    }
};

pub const HandleScope = struct {
    runtime: *JSRuntime,
    start: usize,
    /// Nesting depth; scopes must close innermost first.
    depth: usize,
    active: bool = true,

    pub fn enter(runtime: *JSRuntime) HandleScope {
        runtime.roots.handle_scope_depth += 1;
        return .{
            .runtime = runtime,
            .start = runtime.roots.local_root_slots.items.len,
            .depth = runtime.roots.handle_scope_depth,
        };
    }

    /// Closing an outer scope first would free the inner scope's slots
    /// under live `LocalHandle`s, so misordering panics in every build.
    pub fn deinit(self: *HandleScope) void {
        if (!self.active) return;
        const roots = &self.runtime.roots;
        if (roots.handle_scope_depth != self.depth) @panic("HandleScope closed out of LIFO order");
        self.runtime.roots.clearLocalFrom(self.runtime, self.start);
        roots.handle_scope_depth -= 1;
        self.active = false;
    }

    /// Stores `value` in a new strong slot owned by this scope.
    pub fn local(self: *HandleScope, value: JSValue) !LocalHandle {
        if (!self.active) @panic("HandleScope.local after deinit");
        if (self.runtime.roots.handle_scope_depth != self.depth) @panic("HandleScope.local on an enclosing scope");
        const slot = try self.runtime.roots.createLocal(self.runtime, value);
        return .{ .slot = slot };
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
        runtime.roots.assertMutable();
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
};

pub const NativePin = struct {
    runtime: ?*JSRuntime = null,
    header: ?*gc.Header = null,

    pub fn deinit(self: *NativePin) void {
        const runtime = self.runtime orelse return;
        const header = self.header orelse return;
        runtime.roots.assertMutable();
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
    runtime.roots.assertMutable();
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

        const bytes = try rt.allocNativeElements(total_bytes, 1, block_alignment);
        errdefer rt.freeNativeAlignedBytes(bytes, block_alignment);
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
        rt.freeNativeAlignedBytes(bytes[0..total_bytes], block_alignment);
    }
};

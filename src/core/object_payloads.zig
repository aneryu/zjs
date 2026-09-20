//! Out-of-line object payload representations and their ownership teardown.

const atom = @import("atom.zig");
const gc_visit = @import("gc_visit.zig");
const class = @import("class.zig");
const context_mod = @import("context.zig");
const gc = @import("gc.zig");
const host_function = @import("host_function.zig");
const native_entry = @import("native_entry.zig");
const property = @import("property.zig");
const runtime_mod = @import("runtime.zig");
const string = @import("string.zig");
const var_ref_mod = @import("var_ref.zig");
const Object = @import("object.zig").Object;
const JSRuntime = runtime_mod.JSRuntime;
const JSValue = @import("value.zig").JSValue;
const FunctionBytecode = @import("../bytecode.zig").function_bytecode.FunctionBytecode;
const std = @import("std");
const typed_array_names = @import("typed_array_names.zig");
const builtin = @import("builtin");

// Payload entry records and shared ownership helpers.
pub const collection_no_entry: usize = std.math.maxInt(usize);

pub const CollectionEntry = struct {
    key: JSValue,
    value: JSValue,
    active: bool = true,
    hash: u64 = 0,
    hash_next: usize = collection_no_entry,
};

pub const WeakCollectionEntry = struct {
    key_identity: usize,
    value: JSValue,
    hash: u64 = 0,
    hash_next: usize = collection_no_entry,

    pub fn destroy(self: WeakCollectionEntry, rt: *JSRuntime) void {
        rt.releaseWeakIdentity(self.key_identity);
    }
};

pub const FinalizationRegistryCellState = enum(u8) {
    active,
    pending_enqueue,
    queued,
};

pub const FinalizationRegistryCell = struct {
    target_identity: ?usize = null,
    held_value: JSValue = JSValue.undefinedValue(),
    unregister_token_identity: ?usize = null,
    state: FinalizationRegistryCellState = .active,

    pub fn isActive(self: FinalizationRegistryCell) bool {
        return self.state == .active;
    }

    pub fn isPending(self: FinalizationRegistryCell) bool {
        return self.state == .pending_enqueue;
    }

    pub fn keepsHeldValuesAlive(self: FinalizationRegistryCell) bool {
        return self.state == .active or self.state == .pending_enqueue;
    }

    pub fn destroy(self: FinalizationRegistryCell, rt: *JSRuntime) void {
        if (self.target_identity) |identity| rt.releaseWeakIdentity(identity);
        if (self.unregister_token_identity) |identity| rt.releaseWeakIdentity(identity);
        // Active/pending cells still own the job-queue reservation taken at
        // register. Queued cells already consumed it via enqueueReserved.
        // Runtime teardown destroys the queue before leftover objects.
        if ((self.isActive() or self.isPending()) and rt.job_queue.capacity != 0) {
            rt.job_queue.releaseReservedEntries(1);
        }
    }
};

/// TGC S4-c: the collector header of a subordinate `.payload` cell -- the
/// variable-length slice an a-class payload owns. Only valid where the owning
/// payload says the slice names a cell (a non-zero capacity, or a non-empty
/// fixed slice); the empty slice is a sentinel, not an allocation.
pub inline fn payloadSliceCellHeader(ptr: anytype) *gc.Header {
    return @ptrCast(@alignCast(ptr));
}

/// Close and release the frame-owned references in an open-var-ref window.
/// The window itself belongs to the surrounding frame slab.
pub fn closeOpenVarRefCellSlots(rt: *JSRuntime, slots: []?*var_ref_mod.VarRef) void {
    for (slots) |*slot| {
        const cell = slot.* orelse continue;
        slot.* = null;
        cell.close(rt);
    }
}

pub fn destroyValueSliceWithCapacity(rt: *JSRuntime, slot: *[]JSValue, capacity: *usize) void {
    const values = slot.*;
    const old_capacity = capacity.*;
    slot.* = &.{};
    capacity.* = 0;
    if (old_capacity != 0) {
        rt.memory.free(JSValue, values.ptr[0..old_capacity]);
    } else if (values.len != 0) {
        rt.memory.free(JSValue, values);
    }
}

pub const DataPropertyLookup = struct {
    index: usize,
    value: JSValue,
};

/// Internal Promise reaction state. Unlike OrdinaryPayload this carries only
/// the four slots used by pending subscribers and reaction jobs. The Object
/// owns this tracer-managed cell; no native resource or finalizer is needed.
pub const IntrinsicPromiseReaction = struct {
    target: JSValue, // gc-slot: heap; Object.setPromiseReactionIntrinsicCapability barriers the target.
    self_error_global: JSValue, // gc-slot: heap; the same bulk setter barriers the realm global.
};

pub const PromiseReactionCapability = union(enum) {
    external: struct { resolve: ?JSValue = null, reject: ?JSValue = null },
    intrinsic: IntrinsicPromiseReaction,

    pub const gc_edges: gc_visit.Edges = .{ .manual = &.{ "external", "intrinsic" } };

    comptime {
        gc_visit.assertClassified(@This());
    }

    pub fn traceChildEdges(self: *PromiseReactionCapability, visitor: anytype) !void {
        switch (self.*) {
            .external => |*external| {
                try gc_visit.optionalValue(visitor, &external.resolve);
                try gc_visit.optionalValue(visitor, &external.reject);
            },
            .intrinsic => |*intrinsic| {
                try gc_visit.value(visitor, &intrinsic.target);
                try gc_visit.value(visitor, &intrinsic.self_error_global);
            },
        }
    }
};

pub const PromiseReactionRecordPayload = struct {
    on_fulfilled: ?JSValue = null, // gc-slot: heap; Object.setPromiseReactionOnFulfilled uses setOptionalValueSlot.
    on_rejected: ?JSValue = null, // gc-slot: heap; Object.setPromiseReactionOnRejected uses setOptionalValueSlot.
    capability: PromiseReactionCapability = .{ .external = .{} },

    pub const gc_edges: gc_visit.Edges = .{
        .strong = &.{ "on_fulfilled", "on_rejected" },
        .nested = &.{"capability"},
    };

    comptime {
        gc_visit.assertClassified(@This());
    }

    pub fn traceChildEdges(self: *PromiseReactionRecordPayload, visitor: anytype) !void {
        try gc_visit.traceDeclared(self, visitor);
    }
};

pub const OrdinaryPayload = struct {
    callsite_file: ?JSValue = null,
    callsite_function: ?JSValue = null,
    promise_reaction_on_fulfilled: ?JSValue = null,
    promise_reaction_on_rejected: ?JSValue = null,
    promise_reaction_capability: PromiseReactionCapability = .{ .external = .{} },
    promise_capability_resolve: ?JSValue = null,
    promise_capability_reject: ?JSValue = null,
    promise_combinator_resolve: ?JSValue = null,
    promise_combinator_reject: ?JSValue = null,
    promise_combinator_values: ?JSValue = null,
    promise_combinator_keys: ?JSValue = null,
    error_stack: ?JSValue = null,
    error_stack_sites: ?JSValue = null,
    error_stack_site_count: usize = 0,
    callsite_line: i32 = 1,
    callsite_column: i32 = 1,
    is_callsite: bool = false,
    callsite_is_native: bool = false,
    promise_already_resolved: bool = false,
    promise_combinator_remaining: i32 = 0,

    pub const gc_edges: gc_visit.Edges = .{
        .strong = &.{
            "callsite_file",
            "callsite_function",
            "promise_reaction_on_fulfilled",
            "promise_reaction_on_rejected",
            "promise_capability_resolve",
            "promise_capability_reject",
            "promise_combinator_resolve",
            "promise_combinator_reject",
            "promise_combinator_values",
            "promise_combinator_keys",
            "error_stack",
            "error_stack_sites",
        },
        .nested = &.{"promise_reaction_capability"},
    };

    comptime {
        gc_visit.assertClassified(@This());
    }

    pub fn traceChildEdges(self: *OrdinaryPayload, visitor: anytype) !void {
        try gc_visit.traceDeclared(self, visitor);
    }
};

pub const IteratorPayload = struct {
    target: ?JSValue = null,
    data: ?JSValue = null,
    next: ?JSValue = null,
    callback: ?JSValue = null,
    inner_next: ?JSValue = null,
    zip_nexts: ?JSValue = null,
    zip_pads: ?JSValue = null,
    zip_keys: ?JSValue = null,
    atom_keys: []atom.Atom = &.{},
    index: usize = 0,
    length: u32 = 0,
    zip_alive: usize = 0,
    kind: u8 = 0,
    zip_mode: u8 = 0,
    zip_state: u8 = 0,
    executing: bool = false,
    /// Set while this Map/Set iterator holds a cursor on `target`'s entry
    /// array. Taken on the first advance and dropped on exhaustion or
    /// finalization, mirroring qjs's `it->cur_record` reference: an iterator
    /// that has not stepped yet holds no record (js_map_iterator_next
    /// quickjs.c only refs once it has picked one), so it must not pin
    /// anything either.
    collection_cursor_held: bool = false,

    pub fn destroy(self: *IteratorPayload, rt: *JSRuntime) void {
        const atom_keys = self.atom_keys;
        self.atom_keys = &.{};
        if (atom_keys.len != 0) rt.memory.free(atom.Atom, atom_keys);
    }

    pub const gc_edges: gc_visit.Edges = .{
        .strong = &.{ "target", "data", "next", "callback", "inner_next", "zip_nexts", "zip_pads", "zip_keys" },
        .manual = &.{"atom_keys"},
    };

    comptime {
        gc_visit.assertClassified(@This());
    }

    pub fn traceChildEdges(self: *IteratorPayload, visitor: anytype) !void {
        try gc_visit.traceDeclared(self, visitor);
        // TGC S3 §2.2 edge F: `atom_keys` is a real holder of atom ids (a
        // for-in / ownKeys snapshot parked on the iterator), so the tracer
        // needs the edge even though the cycle graph has nothing to see.
        for (self.atom_keys) |atom_id| try gc_visit.atom(visitor, atom_id);
    }
};

/// Per-payload node in the runtime's weak-holder list. The links point to the
/// owning Object rather than to another node, so traversal does not need a
/// payload-kind cast. `borrowed_holder_index` is the independent O(1) index
/// into Runtime.borrowed_reference_holders; keeping both pieces here matches
/// QuickJS's payload-resident JSWeakRefHeader without growing JSObject.
pub const WeakReferenceHolderLink = struct {
    previous: ?*Object = null,
    next: ?*Object = null,
    borrowed_holder_index: u32 = 0,
    registered: bool = false,
};

pub const CollectionPayload = struct {
    entries: std.ArrayListUnmanaged(CollectionEntry) = .empty,
    bucket_heads: []usize = &.{},
    active_count: usize = 0,
    /// Number of cursors currently parked inside `entries`: live Map/Set
    /// iterators plus in-flight native scans (forEach, the Set-composition
    /// helpers). This is the zjs form of the per-record `ref_count` an
    /// enumerator takes in qjs (`JSMapRecord.ref_count`, quickjs.c;
    /// `mr->ref_count++` in js_map_iterator_next quickjs.c and
    /// js_map_forEach quickjs.c): a qjs cursor is a record pointer, so it
    /// pins one record, while a zjs cursor is an entry index, so it pins the
    /// whole array layout. Nonzero => deletions keep tombstones exactly like a
    /// qjs zombie record (`mr->empty = TRUE`, quickjs.c); zero => the
    /// tombstones can be compacted away, which is what
    /// `map_delete_record_internal` does when `--ref_count == 0`.
    live_cursors: usize = 0,
    weak_entries: std.ArrayListUnmanaged(WeakCollectionEntry) = .empty,
    weak_holder_link: WeakReferenceHolderLink = .{},

    /// `weak_holder_link` is deliberately left alone: the payload may still
    /// sit in the runtime's weak-holder list, which unlinks it separately.
    pub fn destroy(self: *CollectionPayload, rt: *JSRuntime) void {
        self.entries.deinit(rt.memory.persistent_allocator);
        const old_bucket_heads = self.bucket_heads;
        self.bucket_heads = &.{};
        self.active_count = 0;
        if (old_bucket_heads.len != 0) rt.memory.free(usize, old_bucket_heads);
        for (self.weak_entries.items) |entry| rt.releaseWeakIdentity(entry.key_identity);
        self.weak_entries.deinit(rt.memory.persistent_allocator);
    }

    pub const gc_edges: gc_visit.Edges = .{
        .manual = &.{ "entries", "weak_entries" },
        .weak = &.{"weak_holder_link"},
    };

    comptime {
        gc_visit.assertClassified(@This());
    }

    pub fn traceChildEdges(self: *CollectionPayload, visitor: anytype) !void {
        for (self.entries.items) |*entry| {
            try gc_visit.value(visitor, &entry.key);
            try gc_visit.value(visitor, &entry.value);
        }
        for (self.weak_entries.items) |*entry| {
            try gc_visit.weakCollectionEntry(visitor, entry);
        }
    }
};

pub const SharedBufferStore = struct {
    ref_count: std.atomic.Value(usize) = .init(1),
    bytes: []u8 = &.{},
    external_memory: gc.ExternalMemoryToken = .{},
    external_deinit: ?ExternalByteStorageDeinit = null,
    external_context: ?*anyopaque = null,

    pub fn create(rt: *JSRuntime, byte_length: usize) !*SharedBufferStore {
        const allocator = std.heap.page_allocator;
        const store = try allocator.create(SharedBufferStore);
        errdefer allocator.destroy(store);
        const bytes = try allocator.alloc(u8, byte_length);
        errdefer allocator.free(bytes);
        var external_memory = try rt.reportExternalAlloc(byte_length);
        errdefer external_memory.release();
        @memset(bytes, 0);
        store.* = .{
            .ref_count = .init(1),
            .bytes = bytes,
            .external_memory = external_memory,
        };
        return store;
    }

    pub fn createExternal(
        rt: *JSRuntime,
        bytes: []u8,
        deinit_fn: ExternalByteStorageDeinit,
        context: ?*anyopaque,
    ) !*SharedBufferStore {
        const allocator = std.heap.page_allocator;
        const store = try allocator.create(SharedBufferStore);
        errdefer allocator.destroy(store);
        var external_memory = try rt.reportExternalAlloc(bytes.len);
        errdefer external_memory.release();
        store.* = .{
            .ref_count = .init(1),
            .bytes = bytes,
            .external_memory = external_memory,
            .external_deinit = deinit_fn,
            .external_context = context,
        };
        return store;
    }

    pub fn retain(self: *SharedBufferStore) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *SharedBufferStore) void {
        if (self.ref_count.fetchSub(1, .acq_rel) != 1) return;
        const allocator = std.heap.page_allocator;
        const bytes = self.bytes;
        const external_deinit = self.external_deinit;
        const external_context = self.external_context;
        self.external_memory.release();
        self.bytes = &.{};
        self.external_deinit = null;
        self.external_context = null;
        if (external_deinit) |deinit_fn| {
            deinit_fn(external_context, bytes);
        } else {
            allocator.free(bytes);
        }
        allocator.destroy(self);
    }
};

pub const ExternalByteStorageDeinit = *const fn (context: ?*anyopaque, bytes: []u8) void;

pub const BufferPayload = struct {
    pub const inline_storage_capacity: usize = 32;

    bytes: []u8 = &.{},
    inline_bytes: [inline_storage_capacity]u8 = undefined,
    inline_length: u8 = 0,
    shared_store: ?*SharedBufferStore = null,
    external_memory: gc.ExternalMemoryToken = .{},
    external_deinit: ?ExternalByteStorageDeinit = null,
    external_context: ?*anyopaque = null,
    detached: bool = false,
    immutable: bool = false,
    max_byte_length: ?usize = null,
    first_view: ?*TypedArrayPayload = null,

    pub fn destroy(self: *BufferPayload, rt: *JSRuntime) void {
        // QuickJS's ArrayBuffer finalizer can run before the TypedArray /
        // DataView finalizers during cycle removal. Sever every weak view link
        // first so a later view finalizer never dereferences this payload.
        self.unlinkAllViews();
        self.releaseStorage(rt);
    }

    /// Byte storage is external or inline memory and views hold the buffer,
    /// not the reverse: the payload has no collector edges.
    pub const gc_edges: gc_visit.Edges = .{};

    comptime {
        gc_visit.assertClassified(@This());
    }

    pub fn traceChildEdges(self: *const BufferPayload, visitor: anytype) !void {
        try gc_visit.traceDeclared(self, visitor);
    }

    pub fn releaseStorage(self: *BufferPayload, rt: *JSRuntime) void {
        // Any release may invalidate or move the data pointer. Clear cached
        // view state before the old storage is returned to its owner; install
        // paths republish the new state after committing the replacement.
        self.invalidateViews();
        if (self.shared_store) |store| {
            store.release();
        } else if (self.external_deinit) |deinit| {
            self.external_memory.release();
            deinit(self.external_context, self.bytes);
        } else if (self.inline_length != 0) {
            rt.reportExternalFreeUntracked(self.inline_length);
            self.inline_length = 0;
        } else {
            self.external_memory.release();
            if (self.bytes.len != 0) rt.memory.free(u8, self.bytes);
        }
        self.bytes = &.{};
        self.shared_store = null;
        self.external_memory = .{};
        self.external_deinit = null;
        self.external_context = null;
    }

    pub fn attachView(self: *BufferPayload, view: *TypedArrayPayload) void {
        std.debug.assert(view.backing_payload == null);
        std.debug.assert(view.buffer_prev == null);
        std.debug.assert(view.buffer_next == null);

        view.backing_payload = self;
        view.buffer_next = self.first_view;
        if (self.first_view) |first| first.buffer_prev = view;
        self.first_view = view;
        view.updateLiveState(self);
    }

    pub fn detachView(self: *BufferPayload, view: *TypedArrayPayload) void {
        if (view.backing_payload != self) {
            std.debug.assert(view.backing_payload == null);
            return;
        }

        const previous = view.buffer_prev;
        const next = view.buffer_next;
        if (previous) |prev| {
            prev.buffer_next = next;
        } else {
            std.debug.assert(self.first_view == view);
            self.first_view = next;
        }
        if (next) |following| following.buffer_prev = previous;

        view.backing_payload = null;
        view.buffer_prev = null;
        view.buffer_next = null;
        view.clearLiveState();
    }

    fn invalidateViews(self: *BufferPayload) void {
        var current = self.first_view;
        while (current) |view| : (current = view.buffer_next) {
            view.clearLiveState();
        }
    }

    pub fn updateViews(self: *BufferPayload) void {
        var current = self.first_view;
        while (current) |view| : (current = view.buffer_next) {
            view.updateLiveState(self);
        }
    }

    fn unlinkAllViews(self: *BufferPayload) void {
        while (self.first_view) |view| self.detachView(view);
    }
};

pub const TypedArrayPayload = struct {
    buffer: ?JSValue = null,
    byte_offset: usize = 0,
    element_size: u32 = 0,
    fixed_length: ?u32 = null,
    kind: typed_array_names.Kind = .none,
    live_length: u32 = 0,
    data: ?[*]u8 = null,
    backing_payload: ?*BufferPayload = null,
    buffer_prev: ?*TypedArrayPayload = null,
    buffer_next: ?*TypedArrayPayload = null,

    /// Unlink from the buffer's view list; the buffer value itself is a
    /// tracer edge and needs no release.
    pub fn destroy(self: *TypedArrayPayload) void {
        if (self.backing_payload) |backing| backing.detachView(self);
        self.buffer = null;
    }

    pub const gc_edges: gc_visit.Edges = .{ .strong = &.{"buffer"} };

    comptime {
        gc_visit.assertClassified(@This());
    }

    pub fn traceChildEdges(self: *TypedArrayPayload, visitor: anytype) !void {
        try gc_visit.traceDeclared(self, visitor);
    }

    fn clearLiveState(self: *TypedArrayPayload) void {
        self.live_length = 0;
        self.data = null;
    }

    fn updateLiveState(self: *TypedArrayPayload, backing: *BufferPayload) void {
        self.clearLiveState();
        if (backing.detached) return;

        const offset = self.byte_offset;
        const storage = backing.bytes;
        if (offset > storage.len) return;
        const remaining = storage.len - offset;

        // DataView is byte-addressed (`element_size == 0`). QuickJS updates a
        // length-tracking DataView's byte length from the ArrayBuffer list; the
        // fixed-length form stays live only while its complete range fits.
        if (self.element_size == 0) {
            const tracks_buffer = self.kind == .data_view_length_tracking and backing.max_byte_length != null;
            const live: usize = if (!tracks_buffer) blk: {
                const fixed = self.fixed_length orelse return;
                if (@as(usize, fixed) > remaining) return;
                break :blk fixed;
            } else blk: {
                // qjs requires offset < byte_length for a tracking DataView to
                // have a non-zero live range.
                if (offset == storage.len) return;
                break :blk remaining;
            };
            self.live_length = std.math.cast(u32, live) orelse return;
            self.data = storage.ptr + offset;
            return;
        }

        const width: usize = self.element_size;
        if (self.fixed_length) |fixed| {
            const byte_length = std.math.mul(usize, fixed, width) catch return;
            if (byte_length > remaining) return;
            self.live_length = fixed;
            self.data = storage.ptr + offset;
            return;
        }

        // QuickJS only publishes a pointer for a length-tracking TypedArray
        // when at least one complete element remains. Partial trailing bytes
        // are not addressable.
        if (remaining < width) return;
        self.live_length = std.math.cast(u32, @divTrunc(remaining, width)) orelse return;
        self.data = storage.ptr + offset;
    }
};

pub const RegExpPayload = extern struct {
    /// QuickJS stores these two owned `JSString *` fields directly in
    /// `JSObject.u.regexp`. Keeping the zjs
    /// representation pointer-only lets the standard RegExp class use the
    /// object's existing union instead of a second payload allocation.
    source: ?*string.String = null,
    compiled_bytecode: ?*string.String = null,

    /// Source and compiled bytecode are tracer-owned string child edges.
    pub const gc_edges: gc_visit.Edges = .{ .manual = &.{ "source", "compiled_bytecode" } };

    comptime {
        gc_visit.assertClassified(@This());
    }

    pub fn traceChildEdges(self: *const RegExpPayload, visitor: anytype) !void {
        if (self.source) |body| try gc_visit.stringBody(visitor, body);
        if (self.compiled_bytecode) |body| try gc_visit.stringBody(visitor, body);
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == 2 * @sizeOf(?*string.String));
    }
};

/// Cold Function.prototype.bind payload.
pub const BoundFunctionPayload = struct {
    target: ?JSValue = null,
    this_value: ?JSValue = null,
    args: []JSValue = &.{},

    pub const gc_edges: gc_visit.Edges = .{ .strong = &.{ "target", "this_value" }, .manual = &.{"args"} };

    comptime {
        gc_visit.assertClassified(@This());
    }

    pub fn traceChildEdges(self: *BoundFunctionPayload, visitor: anytype) !void {
        try gc_visit.traceDeclared(self, visitor);
        // The argument array is fixed at creation, so a non-empty slice IS the
        // cell (there is no over-allocated capacity to distinguish).
        if (self.args.len != 0)
            try gc_visit.storageCell(visitor, payloadSliceCellHeader(self.args.ptr));
        for (self.args) |*stored| try gc_visit.value(visitor, stored);
    }
};

pub const ProxyPayload = struct {
    target: ?JSValue = null,
    handler: ?JSValue = null,

    pub const gc_edges: gc_visit.Edges = .{ .strong = &.{ "target", "handler" } };

    comptime {
        gc_visit.assertClassified(@This());
    }

    pub fn traceChildEdges(self: *ProxyPayload, visitor: anytype) !void {
        try gc_visit.traceDeclared(self, visitor);
    }
};

pub const ArgumentsPayload = struct {
    var_refs: []JSValue = &.{},

    pub const gc_edges: gc_visit.Edges = .{ .manual = &.{"var_refs"} };

    comptime {
        gc_visit.assertClassified(@This());
    }

    pub fn traceChildEdges(self: *ArgumentsPayload, visitor: anytype) !void {
        if (self.var_refs.len != 0)
            try gc_visit.storageCell(visitor, payloadSliceCellHeader(self.var_refs.ptr));
        for (self.var_refs) |*stored| try gc_visit.value(visitor, stored);
    }
};

pub const ObjectDataPayload = struct {
    data: ?JSValue = null,

    pub const gc_edges: gc_visit.Edges = .{ .strong = &.{"data"} };

    comptime {
        gc_visit.assertClassified(@This());
    }

    pub fn traceChildEdges(self: *ObjectDataPayload, visitor: anytype) !void {
        try gc_visit.traceDeclared(self, visitor);
    }
};

pub const WeakRefPayload = struct {
    weak_target_identity: ?usize = null,
    weak_holder_link: WeakReferenceHolderLink = .{},

    pub fn destroy(self: *WeakRefPayload, rt: *JSRuntime) void {
        rt.clearWeakIdentitySlot(&self.weak_target_identity);
    }

    /// Weak identities are not strong cycle-GC edges.
    pub const gc_edges: gc_visit.Edges = .{ .weak = &.{"weak_holder_link"} };

    comptime {
        gc_visit.assertClassified(@This());
    }

    pub fn traceChildEdges(self: *const WeakRefPayload, visitor: anytype) !void {
        try gc_visit.traceDeclared(self, visitor);
    }
};

pub const VarRefPayload = struct {
    value: ?JSValue = null,
    is_const: bool = false,
    is_function_name: bool = false,
    is_deletable: bool = false,

    pub const gc_edges: gc_visit.Edges = .{ .strong = &.{"value"} };

    comptime {
        gc_visit.assertClassified(@This());
    }

    pub fn traceChildEdges(self: *VarRefPayload, visitor: anytype) !void {
        try gc_visit.traceDeclared(self, visitor);
    }
};

pub const FinalizationRegistryPayload = struct {
    cleanup_callback: ?JSValue = null,
    cells: std.ArrayListUnmanaged(FinalizationRegistryCell) = .empty,
    /// QuickJS `JSFinalizationRegistryData.realm`: the registry, not its
    /// callback, selects the Realm used to enqueue and begin the cleanup job.
    /// The callback's own callable carrier may subsequently switch execution
    /// to a different Realm when the job invokes it.
    realm: context_mod.RealmRef = .{},
    weak_holder_link: WeakReferenceHolderLink = .{},

    pub fn destroy(self: *FinalizationRegistryPayload, rt: *JSRuntime) void {
        self.realm.deinit();
        for (self.cells.items) |entry| entry.destroy(rt);
        self.cells.deinit(rt.memory.persistent_allocator);
        self.* = .{};
    }

    pub const gc_edges: gc_visit.Edges = .{
        .strong = &.{"cleanup_callback"},
        .manual = &.{ "realm", "cells" },
        .weak = &.{"weak_holder_link"},
    };

    comptime {
        gc_visit.assertClassified(@This());
    }

    pub fn traceChildEdges(self: *FinalizationRegistryPayload, visitor: anytype) !void {
        try gc_visit.realm(visitor, &self.realm.ptr);
        try gc_visit.traceDeclared(self, visitor);
        for (self.cells.items) |*entry| {
            try gc_visit.finalizationCell(visitor, entry);
        }
    }
};

pub const StdFilePayload = struct {
    file: ?*std.c.FILE = null,
    is_popen: bool = false,
    is_stdio: bool = false,

    pub fn destroy(self: *StdFilePayload) void {
        self.* = .{};
    }

    pub const gc_edges: gc_visit.Edges = .{};

    comptime {
        gc_visit.assertClassified(@This());
    }

    pub fn traceChildEdges(self: *const StdFilePayload, visitor: anytype) !void {
        try gc_visit.traceDeclared(self, visitor);
        // FILE* host handle; no cycle-GC child edges.
    }
};

pub const DisposableResourceKind = enum(u8) {
    use,
    adopt,
    defer_,
};

pub const DisposalHint = enum(u8) {
    sync,
    async,
};

pub const DisposableMethodKind = enum(u8) {
    direct,
    async_from_sync,
};

pub const DisposableResource = struct {
    value: JSValue = JSValue.undefinedValue(),
    method: JSValue = JSValue.undefinedValue(),
    kind: DisposableResourceKind = .defer_,
    hint: DisposalHint = .sync,
    method_kind: DisposableMethodKind = .direct,
};

pub const DisposableStackPayload = struct {
    resources: []DisposableResource = &.{},
    resource_capacity: usize = 0,
    disposed: bool = false,
    async_dispose_resolve: ?JSValue = null,
    async_dispose_reject: ?JSValue = null,
    async_dispose_error: ?JSValue = null,

    pub const gc_edges: gc_visit.Edges = .{
        .strong = &.{ "async_dispose_resolve", "async_dispose_reject", "async_dispose_error" },
        .manual = &.{"resources"},
    };

    comptime {
        gc_visit.assertClassified(@This());
    }

    pub fn traceChildEdges(self: *DisposableStackPayload, visitor: anytype) !void {
        if (self.resource_capacity != 0)
            try gc_visit.storageCell(visitor, payloadSliceCellHeader(self.resources.ptr));
        for (self.resources) |*resource| {
            try gc_visit.value(visitor, &resource.value);
            try gc_visit.value(visitor, &resource.method);
        }
        try gc_visit.traceDeclared(self, visitor);
    }
};

/// State belonging to the global *object*, not to the realm. Intrinsics,
/// prototypes, eval, lexical state, random state, and initial Shapes are owned
/// by `RealmContext`.
pub const GlobalPayload = struct {
    // qjs JSGlobalObject.uninitialized_vars (quickjs.c js_global_object_get_-
    // uninitialized_var, 17069-17096): side table of shared UNINITIALIZED
    // var-ref cells for globals captured before any declaration exists. A later
    // global var/let/const declaration of the same name reuses the parked cell
    // (js_global_object_find_uninitialized_var, 17098-17123) so every earlier
    // capture aliases the new binding.
    uninitialized_vars: ?*Object = null,

    pub const gc_edges: gc_visit.Edges = .{ .strong = &.{"uninitialized_vars"} };

    comptime {
        gc_visit.assertClassified(@This());
    }

    pub fn traceChildEdges(self: *GlobalPayload, visitor: anytype) !void {
        try gc_visit.traceDeclared(self, visitor);
    }
};

/// Host-visible `$262.createRealm()` record.  Its one strong edge is explicit:
/// the record may escape the creating call, so it owns a `RealmRef` rather
/// than borrowing a context pointer.
pub const RealmRecordPayload = struct {
    realm: context_mod.RealmRef = .{},

    pub fn destroy(self: *RealmRecordPayload) void {
        self.realm.deinit();
        self.* = .{};
    }

    pub const gc_edges: gc_visit.Edges = .{ .manual = &.{"realm"} };

    comptime {
        gc_visit.assertClassified(@This());
    }

    pub fn traceChildEdges(self: *RealmRecordPayload, visitor: anytype) !void {
        var realm = self.realm.borrow();
        try gc_visit.realm(visitor, &realm);
    }
};

pub const PromisePayload = struct {
    result: ?JSValue = null,
    reaction_callback: ?JSValue = null,
    reaction_arg: ?JSValue = null,
    /// Live prefix of the subscriber list. qjs threads reaction records onto
    /// the promise with `list_add_tail`, so a pending
    /// promise absorbs N subscribers in O(N); `reactions_capacity` describes
    /// the backing allocation so the array adaptation grows amortized instead
    /// of reallocating at the exact length on every subscription.
    reactions: []JSValue = &.{},
    reactions_capacity: usize = 0,
    is_rejected: bool = false,
    atomics_wait_async: bool = false,

    pub const gc_edges: gc_visit.Edges = .{
        .strong = &.{ "result", "reaction_callback", "reaction_arg" },
        .manual = &.{"reactions"},
    };

    comptime {
        gc_visit.assertClassified(@This());
    }

    pub fn traceChildEdges(self: *PromisePayload, visitor: anytype) !void {
        try gc_visit.traceDeclared(self, visitor);
        // `reactions_capacity != 0` is exactly "the slice names a cell": the
        // live prefix may be shorter than the allocation, and an empty list
        // holds the `&.{}` sentinel.
        if (self.reactions_capacity != 0)
            try gc_visit.storageCell(visitor, payloadSliceCellHeader(self.reactions.ptr));
        for (self.reactions) |*stored| try gc_visit.value(visitor, stored);
    }
};

pub const ArrayBuiltinMarker = property.ArrayBuiltinMarker;
pub const TypedArrayBuiltinMarker = property.TypedArrayBuiltinMarker;

pub const RegExpLegacyStatics = struct {
    input: ?JSValue = null,
    last_match: ?JSValue = null,
    last_paren: ?JSValue = null,
    left_context: ?JSValue = null,
    right_context: ?JSValue = null,
    captures: [9]?JSValue = @splat(null),
    /// Number of capture slots that can be populated by the current legacy
    /// snapshot. Updates clear only the union of the old and new live ranges
    /// instead of scanning all nine Annex-B slots after every match.
    capture_slot_count: u8 = 0,
    lazy_no_capture_match: bool = false,
    lazy_match_index: usize = 0,
    lazy_match_len: usize = 0,
    lazy_input_len: usize = 0,
};

pub const FunctionRarePayload = struct {
    source: ?JSValue = null,
    internal_callable_tag: host_function.InternalCallableTag = .none,
    array_builtin_marker: ArrayBuiltinMarker = .none,
    typed_array_builtin_marker: TypedArrayBuiltinMarker = .none,
    array_iterator_kind: u8 = 0,
    iterator_identity: bool = false,
    array_iterator_next: bool = false,
    generator_next: bool = false,
    throw_type_error_intrinsic: bool = false,
    async_iterator_async_dispose: bool = false,
    async_generator_method: bool = false,
    iterator_helper_method: u8 = 0,
    async_from_sync_iterator_method: u8 = 0,
    disposable_stack_method: u8 = 0,
    async_disposable_stack_method: u8 = 0,
    collection_method_owner_class: class.ClassId = class.invalid_class_id,
    typed_array_element_size: u32 = 0,
    typed_array_kind: typed_array_names.Kind = .none,
    iterator_wrap_method: u8 = 0,
    async_from_sync_unwrap_done: u8 = 0,
    realm_global: ?JSValue = null,
    proxy_revoke_target: ?JSValue = null,
    promise_capability_slot: ?JSValue = null,
    promise_resolving_target: ?JSValue = null,
    promise_resolving_state: ?JSValue = null,
    promise_resolving_reject: bool = false,
    promise_combinator_state: ?JSValue = null,
    promise_combinator_index: u32 = 0,
    promise_combinator_mode: u8 = 0,
    promise_combinator_called: bool = false,
    promise_finally_payload: ?JSValue = null,
    promise_finally_callback: ?JSValue = null,
    promise_finally_constructor: ?JSValue = null,
    promise_finally_mode: u8 = 0,
    async_dispose_stack: ?JSValue = null,
    async_dispose_rejected: bool = false,
    async_function_continuation: ?JSValue = null,
    async_function_rejected: bool = false,
    /// Action discriminator for `.async_generator_resolve` trampolines (zjs
    /// adaptation of the js_async_generator_resolve_function magic,
    /// quickjs.c; extra actions carry the awaits qjs compiles into the
    /// body bytecode — see exec/async_generator.zig ResolveAction).
    async_generator_action: u8 = 0,

    pub const gc_edges: gc_visit.Edges = .{
        .strong = &.{
            "source",
            "realm_global",
            "proxy_revoke_target",
            "promise_capability_slot",
            "promise_resolving_target",
            "promise_resolving_state",
            "promise_combinator_state",
            "promise_finally_payload",
            "promise_finally_callback",
            "promise_finally_constructor",
            "async_dispose_stack",
            "async_function_continuation",
        },
    };

    comptime {
        gc_visit.assertClassified(@This());
    }

    pub fn traceChildEdges(self: *FunctionRarePayload, visitor: anytype) !void {
        try gc_visit.traceDeclared(self, visitor);
    }
};

pub const FunctionPayload = struct {
    pub const NativeFields = extern struct {
        // qjs `u.cfunc.realm`: a true C_FUNCTION owns its construction realm.
        // C_FUNCTION_DATA and other caller-semantics payloads leave this empty;
        // bytecode functions instead own the shared realm through their FB.
        realm: context_mod.RealmRef = .{},
        // Memoized resolved internal-record handle, mirroring qjs
        // `p->u.cfunc.c_function`. The record is comptime rodata and cannot
        // dangle.
        call_cache: ?*const native_entry.NativeEntry = null,
        host_function_kind: i32 = 0,
        native_function_id: i32 = 0,
        native_dispatch_name: atom.Atom = atom.null_atom,
        typed_array_element_size: u32 = 0,
        typed_array_kind: typed_array_names.Kind = .none,
    };

    // Bytecode functions use Object.u.bytecode_function directly, so this
    // out-of-line extension is native-only.
    native: NativeFields = .{},
    rare: ?*FunctionRarePayload = null,
    /// Dense-index cache for the runtime's borrowed-reference-holder registry.
    /// Stored as a little-endian 24-bit index+1 so zero is the uncached
    /// sentinel. Registries beyond 16M entries fall back to generic lookup.
    borrowed_holder_index_lo: u8 = 0,
    borrowed_holder_index_mid: u8 = 0,
    borrowed_holder_index_hi: u8 = 0,

    fn destroyRare(self: *FunctionPayload, rt: *JSRuntime) void {
        if (self.rare) |rare| {
            self.rare = null;
            rt.memory.destroy(FunctionRarePayload, rare);
        }
    }

    pub fn destroyNative(self: *FunctionPayload, rt: *JSRuntime) void {
        const fields = &self.native;
        fields.realm.deinit();
        fields.native_dispatch_name = atom.null_atom;
        self.destroyRare(rt);
    }

    pub fn traceNativeRealm(self: *FunctionPayload, visitor: anytype) !void {
        try gc_visit.realm(visitor, &self.native.realm.ptr);
        // TGC S3 §2.2 edge F: the dispatch name is an atom id this payload
        // names (`destroyNative` only writes the field back to
        // `atom.null_atom`; there is no atom release any more).
        try gc_visit.atom(visitor, self.native.native_dispatch_name);
    }

    comptime {
        std.debug.assert(@sizeOf(NativeFields) == 40);
        std.debug.assert(@sizeOf(FunctionPayload) == 56);
    }
};

/// Cold per-closure extension for zjs-only function metadata. The hot qjs
/// `u.func.home_object` word stores a direct Object pointer when this extension
/// is absent; its low tag bit points here only when a bytecode function needs
/// rare per-closure state in addition to its optional home object.
pub const BytecodeFunctionAux = struct {
    home_object: ?*Object = null,
    rare: FunctionRarePayload = .{},
};

/// Exact qjs `JSObject.u.func` three-word arm.
pub const BytecodeFunctionStorage = extern struct {
    function_bytecode: ?*FunctionBytecode = null,
    // A non-null dangling pointer represents the empty capture array. The
    // pointer is never dereferenced while the FB count is zero. This keeps the
    // hot call prologue branch-free without changing qjs's one-word var_refs
    // storage or allocating an empty array.
    var_refs: [*]?*var_ref_mod.VarRef = emptyVarRefs(),
    /// null/direct `Object*`, or a low-bit-tagged `BytecodeFunctionAux*`.
    home_or_aux: ?*anyopaque = null,

    pub inline fn captureSlots(self: *const BytecodeFunctionStorage) []?*var_ref_mod.VarRef {
        // FB is installed before closure capture construction. Treat the
        // sentinel as an empty/uninstalled array even when the eventual FB
        // count is non-zero, so construction rollback and replacement never
        // walk the dangling pointer. Fully-published callables with a non-zero
        // count have already replaced it with their allocated array.
        if (self.var_refs == emptyVarRefs()) return &.{};
        const fb = self.function_bytecode orelse return &.{};
        return self.var_refs[0..fb.closureVarCount()];
    }

    pub inline fn captureSlice(self: *const BytecodeFunctionStorage) []*var_ref_mod.VarRef {
        const fb = self.function_bytecode orelse return &.{};
        const slots = self.captureSlots();
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            std.debug.assert(slots.len == fb.closureVarCount());
            for (slots) |slot| std.debug.assert(slot != null);
        }
        if (slots.len == 0) return &.{};
        const sealed: [*]*var_ref_mod.VarRef = @ptrCast(slots.ptr);
        return sealed[0..slots.len];
    }

    pub inline fn emptyVarRefs() [*]?*var_ref_mod.VarRef {
        return @ptrFromInt(@alignOf(?*var_ref_mod.VarRef));
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == 24);
    }
};

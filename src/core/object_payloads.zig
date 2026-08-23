//! Out-of-line object payload representations and their ownership teardown.

const atom = @import("atom.zig");
const class = @import("class.zig");
const context_mod = @import("context.zig");
const gc = @import("gc.zig");
const host_function = @import("host_function.zig");
const property = @import("property.zig");
const runtime_mod = @import("runtime.zig");
const string = @import("string.zig");
const var_ref_mod = @import("var_ref.zig");
const Object = @import("object.zig").Object;
const JSRuntime = runtime_mod.JSRuntime;
const JSValue = @import("value.zig").JSValue;
const FunctionBytecode = @import("../bytecode.zig").function_bytecode.FunctionBytecode;
const std = @import("std");
const builtin = @import("builtin");

// Payload entry records and shared ownership helpers.
pub const collection_no_entry: usize = std.math.maxInt(usize);

pub const CollectionEntry = struct {
    key: JSValue,
    value: JSValue,
    active: bool = true,
    hash: u64 = 0,
    hash_next: usize = collection_no_entry,

    pub fn destroy(self: CollectionEntry, rt: *JSRuntime) void {
        self.key.free(rt);
        self.value.free(rt);
    }
};

pub const WeakCollectionEntry = struct {
    key_identity: usize,
    value: JSValue,
    hash: u64 = 0,
    hash_next: usize = collection_no_entry,

    pub fn destroy(self: WeakCollectionEntry, rt: *JSRuntime) void {
        rt.releaseWeakIdentity(self.key_identity);
        self.value.free(rt);
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
        self.held_value.free(rt);
    }
};

/// Generic visitor dispatch used by payload `traceChildEdges` (paired with
/// the destroy helpers above). Copied from `Object.traceChildEdgesFallible`'s
/// local Helper so each payload can sit beside its destroy method.
pub inline fn callVisitObject(vis: anytype, obj_ptr: anytype) !void {
    const VisType = @TypeOf(vis);
    const CleanType = comptime if (@typeInfo(VisType) == .pointer) @typeInfo(VisType).pointer.child else VisType;
    if (comptime @hasDecl(CleanType, "visitObject")) {
        const ReturnType = @typeInfo(@TypeOf(CleanType.visitObject)).@"fn".return_type.?;
        if (comptime @typeInfo(ReturnType) == .error_union) {
            try vis.visitObject(obj_ptr);
        } else {
            vis.visitObject(obj_ptr);
        }
    }
}

pub inline fn callVisitValue(vis: anytype, val_ptr: anytype) !void {
    const VisType = @TypeOf(vis);
    const CleanType = comptime if (@typeInfo(VisType) == .pointer) @typeInfo(VisType).pointer.child else VisType;
    if (comptime @hasDecl(CleanType, "visitValue")) {
        const ReturnType = @typeInfo(@TypeOf(CleanType.visitValue)).@"fn".return_type.?;
        if (comptime @typeInfo(ReturnType) == .error_union) {
            try vis.visitValue(val_ptr);
        } else {
            vis.visitValue(val_ptr);
        }
    }
}

pub inline fn callVisitShape(vis: anytype, shape_ref: anytype) !void {
    const VisType = @TypeOf(vis);
    const CleanType = comptime if (@typeInfo(VisType) == .pointer) @typeInfo(VisType).pointer.child else VisType;
    if (comptime @hasDecl(CleanType, "visitShape")) {
        const ReturnType = @typeInfo(@TypeOf(CleanType.visitShape)).@"fn".return_type.?;
        if (comptime @typeInfo(ReturnType) == .error_union) {
            try vis.visitShape(shape_ref);
        } else {
            vis.visitShape(shape_ref);
        }
    }
}

pub inline fn callVisitRealm(vis: anytype, ctx_ptr: anytype) !void {
    const VisType = @TypeOf(vis);
    const CleanType = comptime if (@typeInfo(VisType) == .pointer) @typeInfo(VisType).pointer.child else VisType;
    if (comptime @hasDecl(CleanType, "visitRealm")) {
        const ReturnType = @typeInfo(@TypeOf(CleanType.visitRealm)).@"fn".return_type.?;
        if (comptime @typeInfo(ReturnType) == .error_union) {
            try vis.visitRealm(ctx_ptr);
        } else {
            vis.visitRealm(ctx_ptr);
        }
    }
}

pub inline fn traceOptValue(vis: anytype, opt_val: anytype) !void {
    if (opt_val.*) |*stored| try callVisitValue(vis, stored);
}

pub inline fn callVisitWeakCollectionEntry(vis: anytype, entry: anytype) !void {
    const VisType = @TypeOf(vis);
    const CleanType = comptime if (@typeInfo(VisType) == .pointer) @typeInfo(VisType).pointer.child else VisType;
    if (comptime @hasDecl(CleanType, "visitWeakCollectionEntry")) {
        const ReturnType = @typeInfo(@TypeOf(CleanType.visitWeakCollectionEntry)).@"fn".return_type.?;
        if (comptime @typeInfo(ReturnType) == .error_union) {
            try vis.visitWeakCollectionEntry(entry);
        } else {
            vis.visitWeakCollectionEntry(entry);
        }
    }
}

pub inline fn callVisitFinalizationCell(vis: anytype, entry: anytype) !void {
    const VisType = @TypeOf(vis);
    const CleanType = comptime if (@typeInfo(VisType) == .pointer) @typeInfo(VisType).pointer.child else VisType;
    if (comptime @hasDecl(CleanType, "visitFinalizationCell")) {
        const ReturnType = @typeInfo(@TypeOf(CleanType.visitFinalizationCell)).@"fn".return_type.?;
        if (comptime @typeInfo(ReturnType) == .error_union) {
            try vis.visitFinalizationCell(entry);
        } else {
            vis.visitFinalizationCell(entry);
        }
    }
}

pub fn destroyOptionalValue(rt: *JSRuntime, slot: *?JSValue) void {
    const old_value = slot.*;
    slot.* = null;
    if (old_value) |stored| stored.free(rt);
}

pub fn destroyOwnedValue(rt: *JSRuntime, slot: *JSValue) void {
    const old_value = slot.*;
    slot.* = JSValue.undefinedValue();
    old_value.free(rt);
}

pub fn replaceOwnedValue(rt: *JSRuntime, slot: *JSValue, next_value: JSValue) void {
    const old_value = slot.*;
    slot.* = next_value;
    old_value.free(rt);
}

pub fn destroyOptionalObjectRef(rt: *JSRuntime, slot: *?*Object) void {
    const old_object = slot.*;
    slot.* = null;
    if (old_object) |stored| stored.value().free(rt);
}

pub fn destroyOptionalValueSlots(rt: *JSRuntime, slots: []?JSValue) void {
    for (slots) |*slot| destroyOptionalValue(rt, slot);
}

pub fn destroyValueSlice(rt: *JSRuntime, slot: *[]JSValue) void {
    const values = slot.*;
    slot.* = &.{};
    for (values) |stored| stored.free(rt);
    if (values.len != 0) rt.memory.free(JSValue, values);
}

pub fn destroyValueSliceValuesOnly(rt: *JSRuntime, slot: *[]JSValue) void {
    const values = slot.*;
    slot.* = &.{};
    for (values) |stored| stored.free(rt);
}

/// Release the nullable module/ordinary closure slots and their single backing
/// allocation.  Module creation deliberately leaves MODULE_IMPORT entries
/// null until indexed linking; ordinary published functions are sealed.
///
/// qjs `js_bytecode_function_finalizer` (quickjs.c:6253-6256) is one loop of
/// `free_var_ref` then `js_free_rt` of the pointer array. Keep that shape:
/// null slots are skipped inside `free_var_ref`, not by a second helper.
pub fn destroyOptionalVarRefCellSlice(rt: *JSRuntime, slot: *[]?*var_ref_mod.VarRef) void {
    const cells = slot.*;
    slot.* = &.{};
    for (cells) |cell| var_ref_mod.VarRef.freeVarRef(rt, cell);
    if (cells.len != 0) rt.memory.free(?*var_ref_mod.VarRef, cells);
}

/// Cell releases only — for a var-ref window whose backing memory belongs to
/// a surrounding storage slab.
pub fn destroyVarRefCellSliceValuesOnly(rt: *JSRuntime, slot: *[]*var_ref_mod.VarRef) void {
    const cells = slot.*;
    slot.* = &.{};
    for (cells) |cell| cell.freeCell(rt);
}

/// Close and release the frame-owned references in an open-var-ref window.
/// The window itself belongs to the surrounding frame slab.
pub fn closeOpenVarRefCellSlots(rt: *JSRuntime, slots: []?*var_ref_mod.VarRef) void {
    for (slots) |*slot| {
        const cell = slot.* orelse continue;
        slot.* = null;
        cell.close(rt);
        cell.freeCell(rt);
    }
}

pub fn destroyValueSliceWithCapacity(rt: *JSRuntime, slot: *[]JSValue, capacity: *usize) void {
    const values = slot.*;
    const old_capacity = capacity.*;
    slot.* = &.{};
    capacity.* = 0;
    for (values) |stored| stored.free(rt);
    if (old_capacity != 0) {
        rt.memory.free(JSValue, values.ptr[0..old_capacity]);
    } else if (values.len != 0) {
        rt.memory.free(JSValue, values);
    }
}

pub fn destroyAtomSlice(rt: *JSRuntime, slot: *[]atom.Atom) void {
    const atoms = slot.*;
    slot.* = &.{};
    for (atoms) |atom_id| rt.atoms.free(atom_id);
    if (atoms.len != 0) rt.memory.free(atom.Atom, atoms);
}

pub const DataPropertyLookup = struct {
    index: usize,
    value: JSValue,
};

pub const OrdinaryPayload = struct {
    callsite_file: ?JSValue = null,
    callsite_function: ?JSValue = null,
    promise_reaction_on_fulfilled: ?JSValue = null,
    promise_reaction_on_rejected: ?JSValue = null,
    promise_reaction_resolve: ?JSValue = null,
    promise_reaction_reject: ?JSValue = null,
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

    pub fn destroy(self: *OrdinaryPayload, rt: *JSRuntime) void {
        destroyOptionalValue(rt, &self.callsite_file);
        destroyOptionalValue(rt, &self.callsite_function);
        destroyOptionalValue(rt, &self.promise_reaction_on_fulfilled);
        destroyOptionalValue(rt, &self.promise_reaction_on_rejected);
        destroyOptionalValue(rt, &self.promise_reaction_resolve);
        destroyOptionalValue(rt, &self.promise_reaction_reject);
        destroyOptionalValue(rt, &self.promise_capability_resolve);
        destroyOptionalValue(rt, &self.promise_capability_reject);
        destroyOptionalValue(rt, &self.promise_combinator_resolve);
        destroyOptionalValue(rt, &self.promise_combinator_reject);
        destroyOptionalValue(rt, &self.promise_combinator_values);
        destroyOptionalValue(rt, &self.promise_combinator_keys);
        destroyOptionalValue(rt, &self.error_stack);
        destroyOptionalValue(rt, &self.error_stack_sites);
        self.* = .{};
    }

    pub fn traceChildEdges(self: *OrdinaryPayload, visitor: anytype) !void {
        try traceOptValue(visitor, &self.callsite_file);
        try traceOptValue(visitor, &self.callsite_function);
        try traceOptValue(visitor, &self.promise_reaction_on_fulfilled);
        try traceOptValue(visitor, &self.promise_reaction_on_rejected);
        try traceOptValue(visitor, &self.promise_reaction_resolve);
        try traceOptValue(visitor, &self.promise_reaction_reject);
        try traceOptValue(visitor, &self.promise_capability_resolve);
        try traceOptValue(visitor, &self.promise_capability_reject);
        try traceOptValue(visitor, &self.promise_combinator_resolve);
        try traceOptValue(visitor, &self.promise_combinator_reject);
        try traceOptValue(visitor, &self.promise_combinator_values);
        try traceOptValue(visitor, &self.promise_combinator_keys);
        try traceOptValue(visitor, &self.error_stack);
        try traceOptValue(visitor, &self.error_stack_sites);
    }
};

pub const IteratorPayload = struct {
    target: ?JSValue = null, // gc-slot: heap
    data: ?JSValue = null, // gc-slot: heap
    next: ?JSValue = null, // gc-slot: heap
    callback: ?JSValue = null, // gc-slot: heap
    inner_next: ?JSValue = null, // gc-slot: heap
    zip_nexts: ?JSValue = null, // gc-slot: heap
    zip_pads: ?JSValue = null, // gc-slot: heap
    zip_keys: ?JSValue = null, // gc-slot: heap
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
    /// quickjs.c:52596 only refs once it has picked one), so it must not pin
    /// anything either.
    collection_cursor_held: bool = false,

    pub fn destroy(self: *IteratorPayload, rt: *JSRuntime) void {
        destroyOptionalValue(rt, &self.target);
        destroyOptionalValue(rt, &self.data);
        destroyOptionalValue(rt, &self.next);
        destroyOptionalValue(rt, &self.callback);
        destroyOptionalValue(rt, &self.inner_next);
        destroyOptionalValue(rt, &self.zip_nexts);
        destroyOptionalValue(rt, &self.zip_pads);
        destroyOptionalValue(rt, &self.zip_keys);
        destroyAtomSlice(rt, &self.atom_keys);
    }

    pub fn traceChildEdges(self: *IteratorPayload, visitor: anytype) !void {
        try traceOptValue(visitor, &self.target);
        try traceOptValue(visitor, &self.data);
        try traceOptValue(visitor, &self.next);
        try traceOptValue(visitor, &self.callback);
        try traceOptValue(visitor, &self.inner_next);
        try traceOptValue(visitor, &self.zip_nexts);
        try traceOptValue(visitor, &self.zip_pads);
        try traceOptValue(visitor, &self.zip_keys);
        // atom_keys live on the atom RC table, not the cycle graph.
    }
};

/// Per-payload node in the runtime's weak-holder list. The links point to the
/// owning Object rather than to another node, so traversal does not need a
/// payload-kind cast. `borrowed_holder_index` is the independent O(1) index
/// into Runtime.borrowed_reference_holders; keeping both pieces here matches
/// QuickJS's payload-resident JSWeakRefHeader without growing JSObject.
pub const WeakReferenceHolderLink = struct {
    previous: ?*Object = null, // gc-slot: weak
    next: ?*Object = null, // gc-slot: weak
    borrowed_holder_index: u32 = 0,
    registered: bool = false,
};

pub const CollectionPayload = struct {
    entries: []CollectionEntry = &.{},
    entries_capacity: usize = 0,
    bucket_heads: []usize = &.{},
    active_count: usize = 0,
    /// Number of cursors currently parked inside `entries`: live Map/Set
    /// iterators plus in-flight native scans (forEach, the Set-composition
    /// helpers). This is the zjs form of the per-record `ref_count` an
    /// enumerator takes in qjs (`JSMapRecord.ref_count`, quickjs.c:1080;
    /// `mr->ref_count++` in js_map_iterator_next quickjs.c:52605 and
    /// js_map_forEach quickjs.c:52320): a qjs cursor is a record pointer, so it
    /// pins one record, while a zjs cursor is an entry index, so it pins the
    /// whole array layout. Nonzero => deletions keep tombstones exactly like a
    /// qjs zombie record (`mr->empty = TRUE`, quickjs.c:52082); zero => the
    /// tombstones can be compacted away, which is what
    /// `map_delete_record_internal` does when `--ref_count == 0`.
    live_cursors: usize = 0,
    weak_entries: []WeakCollectionEntry = &.{},
    weak_entries_capacity: usize = 0,
    weak_holder_link: WeakReferenceHolderLink = .{},

    pub fn destroy(self: *CollectionPayload, rt: *JSRuntime) void {
        const old_entries = self.entries;
        const old_entries_capacity = self.entries_capacity;
        const old_bucket_heads = self.bucket_heads;
        const old_weak_entries = self.weak_entries;
        const old_weak_entries_capacity = self.weak_entries_capacity;
        self.entries = &.{};
        self.entries_capacity = 0;
        self.bucket_heads = &.{};
        self.active_count = 0;
        self.weak_entries = &.{};
        self.weak_entries_capacity = 0;

        for (old_entries) |entry| entry.destroy(rt);
        if (old_entries_capacity != 0) {
            rt.memory.free(CollectionEntry, old_entries.ptr[0..old_entries_capacity]);
        } else if (old_entries.len != 0) {
            rt.memory.free(CollectionEntry, old_entries);
        }
        if (old_bucket_heads.len != 0) rt.memory.free(usize, old_bucket_heads);
        const started_borrowed_cleanup = old_weak_entries.len != 0 and !rt.borrowedWeakCleanupActive();
        if (started_borrowed_cleanup) rt.beginBorrowedWeakCleanup();
        defer if (started_borrowed_cleanup) rt.endBorrowedWeakCleanup();
        for (old_weak_entries) |entry| {
            rt.releaseWeakIdentity(entry.key_identity);
            const prepared_identity = rt.prepareBorrowedWeakCleanupForLastRefValue(entry.value);
            rt.enqueueDeferredWeakValueFreeWithPreparedIdentity(entry.value, prepared_identity) catch |err| switch (err) {
                error.OutOfMemory => entry.value.free(rt),
            };
        }
        if (started_borrowed_cleanup) Object.drainBorrowedWeakCleanup(rt);
        if (old_weak_entries_capacity != 0) {
            rt.memory.free(WeakCollectionEntry, old_weak_entries.ptr[0..old_weak_entries_capacity]);
        } else if (old_weak_entries.len != 0) {
            rt.memory.free(WeakCollectionEntry, old_weak_entries);
        }
    }

    pub fn traceChildEdges(self: *CollectionPayload, visitor: anytype) !void {
        for (self.entries) |*entry| {
            try callVisitValue(visitor, &entry.key);
            try callVisitValue(visitor, &entry.value);
        }
        for (self.weak_entries) |*entry| {
            try callVisitWeakCollectionEntry(visitor, entry);
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

    pub fn traceChildEdges(self: *const BufferPayload, visitor: anytype) !void {
        _ = self;
        _ = visitor;
        // Byte storage and first_view are not strong cycle-GC edges: bytes are
        // external/inline memory, and views hold the buffer rather than the
        // reverse.
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
    buffer: ?JSValue = null, // gc-slot: heap
    byte_offset: usize = 0,
    element_size: u32 = 0,
    fixed_length: ?u32 = null,
    kind: u8 = 0,
    live_length: u32 = 0,
    data: ?[*]u8 = null,
    backing_payload: ?*BufferPayload = null,
    buffer_prev: ?*TypedArrayPayload = null,
    buffer_next: ?*TypedArrayPayload = null,

    pub fn destroy(self: *TypedArrayPayload, rt: *JSRuntime) void {
        // Mirrors js_typed_array_finalizer: unlink before releasing the strong
        // buffer value because that release may immediately finalize the
        // ArrayBuffer payload.
        if (self.backing_payload) |backing| backing.detachView(self);
        destroyOptionalValue(rt, &self.buffer);
    }

    pub fn traceChildEdges(self: *TypedArrayPayload, visitor: anytype) !void {
        try traceOptValue(visitor, &self.buffer);
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
            const tracks_buffer = self.kind == 1 and backing.max_byte_length != null;
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
    /// `JSObject.u.regexp` (quickjs.c:748-751, 47554-47564). Keeping the zjs
    /// representation pointer-only lets the standard RegExp class use the
    /// object's existing union instead of a second payload allocation.
    source: ?*string.String = null, // gc-slot: immutable
    compiled_bytecode: ?*string.String = null, // gc-slot: immutable

    pub fn destroy(self: *RegExpPayload, rt: *JSRuntime) void {
        const old_source = self.source;
        const old_bytecode = self.compiled_bytecode;
        self.* = .{};
        if (old_source) |stored_string| stored_string.value().free(rt);
        if (old_bytecode) |stored_string| stored_string.value().free(rt);
    }

    pub fn traceChildEdges(self: *const RegExpPayload, visitor: anytype) !void {
        _ = self;
        _ = visitor;
        // source / compiled_bytecode are JSString leaves, excluded from
        // cycleMarkHeader (JS_MarkValue drops strings).
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == 2 * @sizeOf(?*string.String));
    }
};

/// Cold Function.prototype.bind payload. Heap JSValue fields are written
/// through `gc_slot.HeapValueSlot` / `GcBuffer` (Stage 2 Slot-under-RC
/// pilot). Layout stays `?JSValue` / `[]JSValue`.
pub const BoundFunctionPayload = struct {
    target: ?JSValue = null, // gc-slot: heap
    this_value: ?JSValue = null, // gc-slot: heap
    args: []JSValue = &.{}, // gc-slot: heap

    pub fn destroy(self: *BoundFunctionPayload, rt: *JSRuntime) void {
        destroyOptionalValue(rt, &self.target);
        destroyOptionalValue(rt, &self.this_value);
        destroyValueSlice(rt, &self.args);
    }

    pub fn traceChildEdges(self: *BoundFunctionPayload, visitor: anytype) !void {
        try traceOptValue(visitor, &self.target);
        try traceOptValue(visitor, &self.this_value);
        for (self.args) |*stored| try callVisitValue(visitor, stored);
    }
};

pub const ProxyPayload = struct {
    target: ?JSValue = null, // gc-slot: heap
    handler: ?JSValue = null, // gc-slot: heap

    pub fn destroy(self: *ProxyPayload, rt: *JSRuntime) void {
        destroyOptionalValue(rt, &self.target);
        destroyOptionalValue(rt, &self.handler);
    }

    pub fn traceChildEdges(self: *ProxyPayload, visitor: anytype) !void {
        try traceOptValue(visitor, &self.target);
        try traceOptValue(visitor, &self.handler);
    }
};

pub const ArgumentsPayload = struct {
    var_refs: []JSValue = &.{}, // gc-slot: heap

    pub fn destroy(self: *ArgumentsPayload, rt: *JSRuntime) void {
        destroyValueSlice(rt, &self.var_refs);
    }

    pub fn traceChildEdges(self: *ArgumentsPayload, visitor: anytype) !void {
        for (self.var_refs) |*stored| try callVisitValue(visitor, stored);
    }
};

pub const ObjectDataPayload = struct {
    data: ?JSValue = null, // gc-slot: heap

    pub fn destroy(self: *ObjectDataPayload, rt: *JSRuntime) void {
        destroyOptionalValue(rt, &self.data);
    }

    pub fn traceChildEdges(self: *ObjectDataPayload, visitor: anytype) !void {
        try traceOptValue(visitor, &self.data);
    }
};

pub const WeakRefPayload = struct {
    weak_target_identity: ?usize = null,
    weak_holder_link: WeakReferenceHolderLink = .{},

    pub fn destroy(self: *WeakRefPayload, rt: *JSRuntime) void {
        rt.clearWeakIdentitySlot(&self.weak_target_identity);
    }

    pub fn traceChildEdges(self: *const WeakRefPayload, visitor: anytype) !void {
        _ = self;
        _ = visitor;
        // Weak identities are not strong cycle-GC edges.
    }
};

pub const VarRefPayload = struct {
    value: ?JSValue = null,
    is_const: bool = false,
    is_function_name: bool = false,
    is_deletable: bool = false,

    pub fn destroy(self: *VarRefPayload, rt: *JSRuntime) void {
        destroyOptionalValue(rt, &self.value);
        self.* = .{};
    }

    pub fn traceChildEdges(self: *VarRefPayload, visitor: anytype) !void {
        try traceOptValue(visitor, &self.value);
    }
};

pub const FinalizationRegistryPayload = struct {
    cleanup_callback: ?JSValue = null,
    cells: []FinalizationRegistryCell = &.{},
    cells_capacity: usize = 0,
    /// QuickJS `JSFinalizationRegistryData.realm`: the registry, not its
    /// callback, selects the Realm used to enqueue and begin the cleanup job.
    /// The callback's own callable carrier may subsequently switch execution
    /// to a different Realm when the job invokes it.
    realm: context_mod.RealmRef = .{},
    weak_holder_link: WeakReferenceHolderLink = .{},

    pub fn destroy(self: *FinalizationRegistryPayload, rt: *JSRuntime) void {
        destroyOptionalValue(rt, &self.cleanup_callback);
        self.realm.deinit();
        const old_cells = self.cells;
        const old_capacity = self.cells_capacity;
        self.cells = &.{};
        self.cells_capacity = 0;
        for (old_cells) |entry| entry.destroy(rt);
        if (old_capacity != 0) {
            rt.memory.free(FinalizationRegistryCell, old_cells.ptr[0..old_capacity]);
        } else if (old_cells.len != 0) {
            rt.memory.free(FinalizationRegistryCell, old_cells);
        }
        self.* = .{};
    }

    pub fn traceChildEdges(self: *FinalizationRegistryPayload, visitor: anytype) !void {
        try callVisitRealm(visitor, &self.realm.ptr);
        try traceOptValue(visitor, &self.cleanup_callback);
        for (self.cells) |*entry| {
            try callVisitFinalizationCell(visitor, entry);
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

    pub fn traceChildEdges(self: *const StdFilePayload, visitor: anytype) !void {
        _ = self;
        _ = visitor;
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

    pub fn destroy(self: DisposableResource, rt: *JSRuntime) void {
        self.value.free(rt);
        self.method.free(rt);
    }
};

pub const DisposableStackPayload = struct {
    resources: []DisposableResource = &.{},
    resource_capacity: usize = 0,
    disposed: bool = false,
    async_dispose_resolve: ?JSValue = null,
    async_dispose_reject: ?JSValue = null,
    async_dispose_error: ?JSValue = null,

    pub fn destroy(self: *DisposableStackPayload, rt: *JSRuntime) void {
        const old_resources = self.resources;
        const old_capacity = self.resource_capacity;
        self.resources = &.{};
        self.resource_capacity = 0;
        for (old_resources) |resource| resource.destroy(rt);
        if (old_capacity != 0) {
            rt.memory.free(DisposableResource, old_resources.ptr[0..old_capacity]);
        } else if (old_resources.len != 0) {
            rt.memory.free(DisposableResource, old_resources);
        }
        destroyOptionalValue(rt, &self.async_dispose_resolve);
        destroyOptionalValue(rt, &self.async_dispose_reject);
        destroyOptionalValue(rt, &self.async_dispose_error);
        self.* = .{};
    }

    pub fn traceChildEdges(self: *DisposableStackPayload, visitor: anytype) !void {
        for (self.resources) |*resource| {
            try callVisitValue(visitor, &resource.value);
            try callVisitValue(visitor, &resource.method);
        }
        try traceOptValue(visitor, &self.async_dispose_resolve);
        try traceOptValue(visitor, &self.async_dispose_reject);
        try traceOptValue(visitor, &self.async_dispose_error);
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
    pub fn destroy(self: *GlobalPayload, rt: *JSRuntime) void {
        const uninitialized_vars = self.uninitialized_vars;
        self.uninitialized_vars = null;
        if (uninitialized_vars) |env| {
            if (rt.gc.phase != .deinit) env.value().free(rt);
        }
        self.* = .{};
    }

    pub fn traceChildEdges(self: *GlobalPayload, visitor: anytype) !void {
        try callVisitObject(visitor, &self.uninitialized_vars);
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

    pub fn traceChildEdges(self: *RealmRecordPayload, visitor: anytype) !void {
        var realm = self.realm.borrow();
        try callVisitRealm(visitor, &realm);
    }
};

pub const PromisePayload = struct {
    result: ?JSValue = null,
    reaction_callback: ?JSValue = null,
    reaction_arg: ?JSValue = null,
    /// Live prefix of the subscriber list. qjs threads reaction records onto
    /// the promise with `list_add_tail` (quickjs.c:54221-54222), so a pending
    /// promise absorbs N subscribers in O(N); `reactions_capacity` describes
    /// the backing allocation so the array adaptation grows amortized instead
    /// of reallocating at the exact length on every subscription.
    reactions: []JSValue = &.{},
    reactions_capacity: usize = 0,
    is_rejected: bool = false,
    atomics_wait_async: bool = false,

    pub fn destroy(self: *PromisePayload, rt: *JSRuntime) void {
        destroyOptionalValue(rt, &self.result);
        destroyOptionalValue(rt, &self.reaction_callback);
        destroyOptionalValue(rt, &self.reaction_arg);
        destroyValueSliceWithCapacity(rt, &self.reactions, &self.reactions_capacity);
        self.is_rejected = false;
        self.atomics_wait_async = false;
    }

    pub fn traceChildEdges(self: *PromisePayload, visitor: anytype) !void {
        try traceOptValue(visitor, &self.result);
        try traceOptValue(visitor, &self.reaction_callback);
        try traceOptValue(visitor, &self.reaction_arg);
        for (self.reactions) |*stored| try callVisitValue(visitor, stored);
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

    pub fn destroy(self: *RegExpLegacyStatics, rt: *JSRuntime) void {
        destroyOptionalValue(rt, &self.input);
        destroyOptionalValue(rt, &self.last_match);
        destroyOptionalValue(rt, &self.last_paren);
        destroyOptionalValue(rt, &self.left_context);
        destroyOptionalValue(rt, &self.right_context);
        destroyOptionalValueSlots(rt, &self.captures);
        self.* = .{};
    }
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
    typed_array_kind: u8 = 0,
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
    /// quickjs.c:21670; extra actions carry the awaits qjs compiles into the
    /// body bytecode — see exec/async_generator.zig ResolveAction).
    async_generator_action: u8 = 0,

    pub fn destroy(self: *FunctionRarePayload, rt: *JSRuntime) void {
        destroyOptionalValue(rt, &self.source);
        destroyOptionalValue(rt, &self.realm_global);
        destroyOptionalValue(rt, &self.proxy_revoke_target);
        destroyOptionalValue(rt, &self.promise_capability_slot);
        destroyOptionalValue(rt, &self.promise_resolving_target);
        destroyOptionalValue(rt, &self.promise_resolving_state);
        destroyOptionalValue(rt, &self.promise_combinator_state);
        destroyOptionalValue(rt, &self.promise_finally_payload);
        destroyOptionalValue(rt, &self.promise_finally_callback);
        destroyOptionalValue(rt, &self.promise_finally_constructor);
        destroyOptionalValue(rt, &self.async_dispose_stack);
        destroyOptionalValue(rt, &self.async_function_continuation);
        self.* = .{};
    }

    pub fn traceChildEdges(self: *FunctionRarePayload, visitor: anytype) !void {
        try traceOptValue(visitor, &self.source);
        try traceOptValue(visitor, &self.realm_global);
        try traceOptValue(visitor, &self.proxy_revoke_target);
        try traceOptValue(visitor, &self.promise_capability_slot);
        try traceOptValue(visitor, &self.promise_resolving_target);
        try traceOptValue(visitor, &self.promise_resolving_state);
        try traceOptValue(visitor, &self.promise_combinator_state);
        try traceOptValue(visitor, &self.promise_finally_payload);
        try traceOptValue(visitor, &self.promise_finally_callback);
        try traceOptValue(visitor, &self.promise_finally_constructor);
        try traceOptValue(visitor, &self.async_dispose_stack);
        try traceOptValue(visitor, &self.async_function_continuation);
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
        call_cache: ?*const host_function.InternalRecord = null,
        host_function_kind: i32 = 0,
        native_function_id: i32 = 0,
        external_host_function_id: u32 = 0,
        native_dispatch_name: atom.Atom = atom.null_atom,
        typed_array_element_size: u32 = 0,
        typed_array_kind: u8 = 0,
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

    pub fn initNative() FunctionPayload {
        return .{};
    }

    fn destroyRare(self: *FunctionPayload, rt: *JSRuntime) void {
        if (self.rare) |rare| {
            self.rare = null;
            rare.destroy(rt);
            rt.memory.destroy(FunctionRarePayload, rare);
        }
    }

    pub fn destroyNative(self: *FunctionPayload, rt: *JSRuntime) void {
        const fields = &self.native;
        fields.realm.deinit();
        const native_dispatch_name = fields.native_dispatch_name;
        fields.native_dispatch_name = atom.null_atom;
        rt.atoms.free(native_dispatch_name);
        self.destroyRare(rt);
    }

    pub fn traceNativeRealm(self: *FunctionPayload, visitor: anytype) !void {
        try callVisitRealm(visitor, &self.native.realm.ptr);
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

    pub fn destroy(self: *BytecodeFunctionAux, rt: *JSRuntime) void {
        destroyOptionalObjectRef(rt, &self.home_object);
        self.rare.destroy(rt);
    }
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

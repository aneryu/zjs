const array = @import("array.zig");
const atom = @import("atom.zig");
const class = @import("class.zig");
const value_format = @import("value_format.zig");
const descriptor = @import("descriptor.zig");
const function = @import("function.zig");
const gc = @import("gc.zig");
const host_function = @import("host_function.zig");
const property = @import("property.zig");
const profile = @import("profile.zig");
const runtime_mod = @import("runtime.zig");
const shape = @import("shape.zig");
const string = @import("string.zig");
const var_ref_mod = @import("var_ref.zig");
const JSRuntime = runtime_mod.JSRuntime;
const JSValue = @import("value.zig").JSValue;
const function_bytecode_mod = @import("../bytecode.zig").function_bytecode;
const FunctionBytecode = function_bytecode_mod.FunctionBytecode;
const memory_mod = @import("memory.zig");
const std = @import("std");
const builtin = @import("builtin");

extern "c" fn pclose(stream: *std.c.FILE) c_int;

const ObjectVisitSet = std.AutoHashMap(usize, void);
const ObjectIncomingMap = std.AutoHashMap(usize, usize);
const ObjectGraphError = std.mem.Allocator.Error || error{PayloadMarkFailed};
const OwnKeysError = std.mem.Allocator.Error;

pub const Error = error{
    NotExtensible,
    IncompatibleDescriptor,
    ReadOnly,
    AccessorWithoutSetter,
    PrototypeCycle,
    InvalidLength,
    OutOfMemory,
};

pub const ExoticMethods = struct {
    get_own_property: ?*const fn (*Object, atom.Atom) ?descriptor.Descriptor = null,
    define_own_property: ?*const fn (*Object, atom.Atom, descriptor.Descriptor) bool = null,
    delete_property: ?*const fn (*Object, atom.Atom) bool = null,
    own_keys: ?*const fn (*Object, *JSRuntime) OwnKeysError![]atom.Atom = null,
};

pub const ArrayStorageMode = enum {
    dense,
    sparse,
};

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

fn destroyOptionalValue(rt: *JSRuntime, slot: *?JSValue) void {
    const old_value = slot.*;
    slot.* = null;
    if (old_value) |stored| stored.free(rt);
}

fn destroyOwnedValue(rt: *JSRuntime, slot: *JSValue) void {
    const old_value = slot.*;
    slot.* = JSValue.undefinedValue();
    old_value.free(rt);
}

fn replaceOwnedValue(rt: *JSRuntime, slot: *JSValue, next_value: JSValue) void {
    const old_value = slot.*;
    slot.* = next_value;
    old_value.free(rt);
}

fn destroyOptionalObjectRef(rt: *JSRuntime, slot: *?*Object) void {
    const old_object = slot.*;
    slot.* = null;
    if (old_object) |stored| stored.value().free(rt);
}

fn destroyOptionalValueSlots(rt: *JSRuntime, slots: []?JSValue) void {
    for (slots) |*slot| destroyOptionalValue(rt, slot);
}

fn destroyValueSlice(rt: *JSRuntime, slot: *[]JSValue) void {
    const values = slot.*;
    slot.* = &.{};
    for (values) |stored| stored.free(rt);
    if (values.len != 0) rt.memory.free(JSValue, values);
}

fn destroyValueSliceValuesOnly(rt: *JSRuntime, slot: *[]JSValue) void {
    const values = slot.*;
    slot.* = &.{};
    for (values) |stored| stored.free(rt);
}

/// `destroyValueSlice` for a slot-typed var-ref cell slice (`[]*VarRef`):
/// release each cell (qjs free_var_ref, quickjs.c:16199) and the slice memory.
fn destroyVarRefCellSlice(rt: *JSRuntime, slot: *[]*var_ref_mod.VarRef) void {
    const cells = slot.*;
    slot.* = &.{};
    for (cells) |cell| cell.freeCell(rt);
    if (cells.len != 0) rt.memory.free(*var_ref_mod.VarRef, cells);
}

/// Cell releases only — for a var-ref window whose backing memory belongs to
/// a surrounding storage slab.
fn destroyVarRefCellSliceValuesOnly(rt: *JSRuntime, slot: *[]*var_ref_mod.VarRef) void {
    const cells = slot.*;
    slot.* = &.{};
    for (cells) |cell| cell.freeCell(rt);
}

/// Close and release the frame-owned references in an open-var-ref window.
/// The window itself belongs to the surrounding frame slab.
fn closeOpenVarRefCellSlots(rt: *JSRuntime, slots: []?*var_ref_mod.VarRef) void {
    for (slots) |*slot| {
        const cell = slot.* orelse continue;
        slot.* = null;
        cell.close(rt);
        cell.freeCell(rt);
    }
}

fn destroyValueSliceWithCapacity(rt: *JSRuntime, slot: *[]JSValue, capacity: *usize) void {
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

fn destroyOptionalValueSlice(rt: *JSRuntime, slot: *[]?JSValue, capacity: *usize) void {
    const values = slot.*;
    const old_capacity = capacity.*;
    slot.* = &.{};
    capacity.* = 0;
    for (values) |maybe_value| {
        if (maybe_value) |stored| stored.free(rt);
    }
    if (old_capacity != 0) {
        rt.memory.free(?JSValue, values.ptr[0..old_capacity]);
    } else if (values.len != 0) {
        rt.memory.free(?JSValue, values);
    }
}

fn destroyAtomSlice(rt: *JSRuntime, slot: *[]atom.Atom) void {
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
    private_remap_from: []atom.Atom = &.{},
    private_remap_to: []atom.Atom = &.{},
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
    typed_array_array_buffer_prototype: ?JSValue = null,
    error_stack: ?JSValue = null,
    error_stack_sites: ?JSValue = null,
    error_stack_site_count: usize = 0,
    callsite_line: i32 = 1,
    callsite_column: i32 = 1,
    is_callsite: bool = false,
    callsite_is_native: bool = false,
    promise_already_resolved: bool = false,
    promise_combinator_remaining: i32 = 0,
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *OrdinaryPayload, rt: *JSRuntime) void {
        destroyAtomSlice(rt, &self.private_remap_from);
        destroyAtomSlice(rt, &self.private_remap_to);
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
        destroyOptionalValue(rt, &self.typed_array_array_buffer_prototype);
        destroyOptionalValue(rt, &self.error_stack);
        destroyOptionalValue(rt, &self.error_stack_sites);
        self.* = .{};
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
    realm_global_ptr: ?*Object = null,

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
    entries: []CollectionEntry = &.{},
    entries_capacity: usize = 0,
    bucket_heads: []usize = &.{},
    active_count: usize = 0,
    weak_entries: []WeakCollectionEntry = &.{},
    weak_entries_capacity: usize = 0,
    realm_global_ptr: ?*Object = null,
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
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *BufferPayload, rt: *JSRuntime) void {
        self.releaseStorage(rt);
    }

    fn releaseStorage(self: *BufferPayload, rt: *JSRuntime) void {
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
};

pub const TypedArrayPayload = struct {
    buffer: ?JSValue = null,
    byte_offset: usize = 0,
    element_size: u32 = 0,
    fixed_length: ?u32 = null,
    kind: u8 = 0,
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *TypedArrayPayload, rt: *JSRuntime) void {
        destroyOptionalValue(rt, &self.buffer);
    }
};

pub const RegExpPayload = extern struct {
    /// QuickJS stores these two owned `JSString *` fields directly in
    /// `JSObject.u.regexp` (quickjs.c:748-751, 47554-47564). Keeping the zjs
    /// representation pointer-only lets the standard RegExp class use the
    /// object's existing 24-byte union instead of a second payload allocation.
    source: ?*string.String = null,
    compiled_bytecode: ?*string.String = null,
    /// ZJS's generic realm resolver can attach a borrowed realm identity to
    /// class payloads. Standard RegExp construction currently leaves this
    /// null; retaining the spare union word keeps custom `.regexp` payloads
    /// layout-compatible while the first two words mirror QuickJS exactly.
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *RegExpPayload, rt: *JSRuntime) void {
        const old_source = self.source;
        const old_bytecode = self.compiled_bytecode;
        self.* = .{};
        if (old_source) |stored_string| stored_string.value().free(rt);
        if (old_bytecode) |stored_string| stored_string.value().free(rt);
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == 24);
    }
};

pub const BoundFunctionPayload = struct {
    target: ?JSValue = null,
    this_value: ?JSValue = null,
    realm_global: ?JSValue = null,
    realm_global_ptr: ?*Object = null,
    args: []JSValue = &.{},

    pub fn destroy(self: *BoundFunctionPayload, rt: *JSRuntime) void {
        destroyOptionalValue(rt, &self.target);
        destroyOptionalValue(rt, &self.this_value);
        destroyOptionalValue(rt, &self.realm_global);
        destroyValueSlice(rt, &self.args);
    }
};

pub const ProxyPayload = struct {
    target: ?JSValue = null,
    handler: ?JSValue = null,
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *ProxyPayload, rt: *JSRuntime) void {
        destroyOptionalValue(rt, &self.target);
        destroyOptionalValue(rt, &self.handler);
    }
};

pub const ArgumentsPayload = struct {
    var_refs: []JSValue = &.{},
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *ArgumentsPayload, rt: *JSRuntime) void {
        destroyValueSlice(rt, &self.var_refs);
    }
};

pub const ObjectDataPayload = struct {
    data: ?JSValue = null,
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *ObjectDataPayload, rt: *JSRuntime) void {
        destroyOptionalValue(rt, &self.data);
    }
};

pub const WeakRefPayload = struct {
    weak_target_identity: ?usize = null,
    realm_global_ptr: ?*Object = null,
    weak_holder_link: WeakReferenceHolderLink = .{},

    pub fn destroy(self: *WeakRefPayload, rt: *JSRuntime) void {
        rt.clearWeakIdentitySlot(&self.weak_target_identity);
    }
};

pub const VarRefPayload = struct {
    value: ?JSValue = null,
    is_const: bool = false,
    is_function_name: bool = false,
    is_deletable: bool = false,
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *VarRefPayload, rt: *JSRuntime) void {
        destroyOptionalValue(rt, &self.value);
        self.* = .{};
    }
};

pub const FinalizationRegistryPayload = struct {
    cleanup_callback: ?JSValue = null,
    cells: []FinalizationRegistryCell = &.{},
    cells_capacity: usize = 0,
    realm_global_ptr: ?*Object = null,
    weak_holder_link: WeakReferenceHolderLink = .{},

    pub fn destroy(self: *FinalizationRegistryPayload, rt: *JSRuntime) void {
        destroyOptionalValue(rt, &self.cleanup_callback);
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
};

pub const StdFilePayload = struct {
    file: ?*std.c.FILE = null,
    is_popen: bool = false,
    is_stdio: bool = false,
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *StdFilePayload) void {
        self.* = .{};
    }
};

const DeferredStdFileClose = struct {
    runtime: *JSRuntime,
    file: *std.c.FILE,
    is_popen: bool = false,

    fn run(ptr: *anyopaque) void {
        const job: *DeferredStdFileClose = @ptrCast(@alignCast(ptr));
        const rt = job.runtime;
        _ = closeStdFileHandle(job.file, job.is_popen);
        rt.memory.destroy(DeferredStdFileClose, job);
    }
};

fn closeStdFileHandle(file: *std.c.FILE, is_popen: bool) c_int {
    if (is_popen) {
        const rc = pclose(file);
        return if (rc == -1) -@as(c_int, @intCast(@intFromEnum(std.c.errno(-1)))) else rc;
    } else {
        const rc = std.c.fclose(file);
        return if (rc == -1) -@as(c_int, @intCast(@intFromEnum(std.c.errno(-1)))) else rc;
    }
}

pub const DisposableResourceKind = enum(u8) {
    use,
    adopt,
    defer_,
};

pub const DisposableResource = struct {
    value: JSValue = JSValue.undefinedValue(),
    method: JSValue = JSValue.undefinedValue(),
    kind: DisposableResourceKind = .defer_,
    await_result: bool = false,

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
    realm_global_ptr: ?*Object = null,

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
};

pub const RealmValueSlot = enum(u8) {
    throw_type_error_intrinsic,
    object_prototype,
    array_prototype,
    array_prototype_values,
    string_prototype,
    number_prototype,
    boolean_prototype,
    bigint_prototype,
    symbol_prototype,
    async_function_constructor,
    async_function_prototype,
    generator_prototype,
    async_iterator_prototype,
    async_generator_prototype,
    generator_function_constructor,
    generator_function_prototype,
    async_generator_function_constructor,
    async_generator_function_prototype,
    iterator_helper_prototype,
    iterator_concat_prototype,
    wrap_for_valid_iterator_prototype,
    std_file_prototype,
    regexp_constructor,
    promise_constructor,
    callsite_prototype,
    regexp_instance_template,
    regexp_match_result_template,
    iterator_result_template,
    unmapped_arguments_template,
    mapped_arguments_template,
    count,
};

const realm_value_slot_count: usize = @intFromEnum(RealmValueSlot.count);

pub const RealmPayload = struct {
    cached_function_proto: ?*Object = null,
    cached_promise_proto: ?*Object = null,
    cached_values: [realm_value_slot_count]?JSValue = @splat(null),
    global_lexicals: ?*Object = null,
    // qjs JSGlobalObject.uninitialized_vars (quickjs.c js_global_object_get_-
    // uninitialized_var, 17069-17096): side table of shared UNINITIALIZED
    // var-ref cells for globals captured before any declaration exists. A later
    // global var/let/const declaration of the same name reuses the parked cell
    // (js_global_object_find_uninitialized_var, 17098-17123) so every earlier
    // capture aliases the new binding.
    uninitialized_vars: ?*Object = null,
    shared_lazy_native_functions: ?*[runtime_mod.shared_lazy_native_function_slots]?JSValue = null,
    /// Annex-B RegExp constructor statics are realm state, not function-object
    /// state. QuickJS does not expose these extensions, but keeping zjs's
    /// compatibility snapshot beside the realm caches avoids routing every
    /// successful match through the RegExp constructor's native+rare payloads.
    regexp_legacy_statics: ?*RegExpLegacyStatics = null,

    pub fn destroy(self: *RealmPayload, rt: *JSRuntime) void {
        destroyOptionalObjectRef(rt, &self.cached_function_proto);
        destroyOptionalObjectRef(rt, &self.cached_promise_proto);
        destroyOptionalValueSlots(rt, &self.cached_values);
        const global_lexicals = self.global_lexicals;
        self.global_lexicals = null;
        if (global_lexicals) |env| {
            if (rt.gc.phase != .deinit) env.value().free(rt);
        }
        const uninitialized_vars = self.uninitialized_vars;
        self.uninitialized_vars = null;
        if (uninitialized_vars) |env| {
            if (rt.gc.phase != .deinit) env.value().free(rt);
        }
        const shared_lazy_native_functions = self.shared_lazy_native_functions;
        self.shared_lazy_native_functions = null;
        if (shared_lazy_native_functions) |cache| {
            for (cache) |*slot| {
                const cached = slot.*;
                slot.* = null;
                if (cached) |stored| stored.free(rt);
            }
            rt.memory.destroy([runtime_mod.shared_lazy_native_function_slots]?JSValue, cache);
        }
        const legacy_statics = self.regexp_legacy_statics;
        self.regexp_legacy_statics = null;
        if (legacy_statics) |legacy| {
            legacy.destroy(rt);
            rt.memory.destroy(RegExpLegacyStatics, legacy);
        }
        self.* = .{};
    }
};

pub const PromisePayload = struct {
    result: ?JSValue = null,
    reaction_callback: ?JSValue = null,
    reaction_arg: ?JSValue = null,
    reactions: []JSValue = &.{},
    is_rejected: bool = false,
    atomics_wait_async: bool = false,
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *PromisePayload, rt: *JSRuntime) void {
        destroyOptionalValue(rt, &self.result);
        destroyOptionalValue(rt, &self.reaction_callback);
        destroyOptionalValue(rt, &self.reaction_arg);
        destroyValueSlice(rt, &self.reactions);
        self.is_rejected = false;
        self.atomics_wait_async = false;
    }
};

/// One queued async-generator request (mirrors qjs JSAsyncGeneratorRequest,
/// quickjs.c:21354): completion type (GEN_MAGIC next=0 / return=1 / throw=2),
/// the completion argument, and the request's promise capability.
pub const AsyncGeneratorRequest = struct {
    completion_type: i32,
    result: JSValue,
    promise: JSValue,
    resolve: JSValue,
    reject: JSValue,
};

/// How a generator/async frame last suspended (zjs adaptation of qjs
/// FUNC_RET_YIELD / FUNC_RET_YIELD_STAR / FUNC_RET_AWAIT return codes,
/// quickjs.c:17735-17738): written by the save sites in vm_gen_async.zig,
/// read by the async-generator driver to discriminate the suspension.
pub const GeneratorSuspendKind = enum(u8) {
    none = 0,
    yield = 1,
    yield_star = 2,
    await_op = 3,
};

/// Owned operand-stack buffer parked while a generator/async frame is
/// suspended. `values` is the live prefix; `capacity` describes the backing
/// allocation when non-zero.
pub const SuspendedStackStorage = struct {
    values: []JSValue = &.{},
    capacity: usize = 0,

    /// Grow the parked stack without changing ownership on failure. Values are
    /// moved as raw slots (no dup/free); only the backing allocation changes.
    pub fn ensureAdditional(self: *SuspendedStackStorage, rt: *JSRuntime, limit: usize, additional: usize) !void {
        return self.ensureAdditionalWithResidentBacking(rt, limit, additional, false);
    }

    /// `resident_backing` means the current buffer is trailing storage in its
    /// GeneratorExecutionState allocation. Growth migrates the live prefix to
    /// a normal owned buffer but leaves that region for the record destructor.
    pub fn ensureAdditionalWithResidentBacking(self: *SuspendedStackStorage, rt: *JSRuntime, limit: usize, additional: usize, resident_backing: bool) !void {
        if (self.values.len > limit) return error.StackOverflow;
        if (additional > limit - self.values.len) return error.StackOverflow;
        const needed = self.values.len + additional;
        if (needed <= self.capacity) return;

        var next_capacity = if (self.capacity == 0) @min(@as(usize, 8), limit) else self.capacity;
        while (next_capacity < needed) {
            if (next_capacity > limit / 2) {
                next_capacity = limit;
                break;
            }
            next_capacity *= 2;
        }
        const next = try rt.memory.alloc(JSValue, next_capacity);
        errdefer rt.memory.free(JSValue, next);
        @memcpy(next[0..self.values.len], self.values);
        const old_values = self.values;
        const old_capacity = self.capacity;
        self.values = next[0..old_values.len];
        self.capacity = next_capacity;
        if (old_capacity != 0 and !resident_backing) {
            rt.memory.free(JSValue, old_values.ptr[0..old_capacity]);
        } else if (old_capacity == 0 and old_values.len != 0) {
            rt.memory.free(JSValue, old_values);
        }
    }

    pub fn deinit(self: *SuspendedStackStorage, rt: *JSRuntime) void {
        destroyValueSliceWithCapacity(rt, &self.values, &self.capacity);
    }

    pub fn isEmpty(self: *const SuspendedStackStorage) bool {
        return self.values.len == 0 and self.capacity == 0;
    }
};

/// Owned frame slab and its typed live windows while execution is suspended.
/// When `storage` is non-empty the other slices borrow windows inside it; a
/// storage-less state may own separate locals/args slices, while var-ref and
/// open-var-ref slots release cells only because their slot memory is never
/// standalone. Open cells continue pointing into `locals`/`args`; preserving
/// the unchanged slab therefore preserves their qjs-style live aliases.
pub const SuspendedFrameStorage = struct {
    storage: []JSValue = &.{},
    locals: []JSValue = &.{},
    args: []JSValue = &.{},
    var_refs: []*var_ref_mod.VarRef = &.{},
    open_var_refs: []?*var_ref_mod.VarRef = &.{},

    pub fn deinit(self: *SuspendedFrameStorage, rt: *JSRuntime) void {
        const owned = self.*;
        self.* = .{};
        var locals = owned.locals;
        var args = owned.args;
        var var_refs = owned.var_refs;
        // Close while the aliased local/argument slots are still live, then
        // release their values and finally the shared slab backing.
        closeOpenVarRefCellSlots(rt, owned.open_var_refs);
        if (owned.storage.len != 0) {
            destroyValueSliceValuesOnly(rt, &locals);
            destroyValueSliceValuesOnly(rt, &args);
            destroyVarRefCellSliceValuesOnly(rt, &var_refs);
            rt.memory.free(JSValue, owned.storage);
            return;
        }
        destroyValueSlice(rt, &locals);
        destroyValueSlice(rt, &args);
        destroyVarRefCellSliceValuesOnly(rt, &var_refs);
    }

    /// Release the live window contents while leaving the backing bytes to the
    /// surrounding GeneratorExecutionState FAM allocation.
    pub fn deinitResident(self: *SuspendedFrameStorage, rt: *JSRuntime) void {
        const owned = self.*;
        self.* = .{};
        var locals = owned.locals;
        var args = owned.args;
        var var_refs = owned.var_refs;
        closeOpenVarRefCellSlots(rt, owned.open_var_refs);
        destroyValueSliceValuesOnly(rt, &locals);
        destroyValueSliceValuesOnly(rt, &args);
        destroyVarRefCellSliceValuesOnly(rt, &var_refs);
    }

    pub fn isEmpty(self: *const SuspendedFrameStorage) bool {
        return self.storage.len == 0 and self.locals.len == 0 and
            self.args.len == 0 and self.var_refs.len == 0 and
            self.open_var_refs.len == 0;
    }
};

/// All buffer ownership parked while a generator is suspended. Program-counter
/// state intentionally lives one level above this record: resume moves these
/// buffers into live exec owners while finally/catch drivers continue reading
/// the payload's pc, matching qjs retaining `cur_pc` while `cur_sp == NULL`.
pub const SuspendedExecutionStorage = struct {
    stack: SuspendedStackStorage = .{},
    frame: SuspendedFrameStorage = .{},

    /// Exchange ownership field-wise. `std.mem.swap` lowers this wide
    /// record to a short-element loop in ReleaseFast, and save sites execute
    /// that loop at every yield/await suspension.
    fn swapOwned(self: *SuspendedExecutionStorage, other: *SuspendedExecutionStorage) void {
        const stack_values = self.stack.values;
        self.stack.values = other.stack.values;
        other.stack.values = stack_values;

        const stack_capacity = self.stack.capacity;
        self.stack.capacity = other.stack.capacity;
        other.stack.capacity = stack_capacity;

        const frame_storage = self.frame.storage;
        self.frame.storage = other.frame.storage;
        other.frame.storage = frame_storage;

        const frame_locals = self.frame.locals;
        self.frame.locals = other.frame.locals;
        other.frame.locals = frame_locals;

        const frame_args = self.frame.args;
        self.frame.args = other.frame.args;
        other.frame.args = frame_args;

        const frame_var_refs = self.frame.var_refs;
        self.frame.var_refs = other.frame.var_refs;
        other.frame.var_refs = frame_var_refs;

        const frame_open_var_refs = self.frame.open_var_refs;
        self.frame.open_var_refs = other.frame.open_var_refs;
        other.frame.open_var_refs = frame_open_var_refs;
    }

    pub fn deinit(self: *SuspendedExecutionStorage, rt: *JSRuntime) void {
        // Resume normally takes every parked buffer before the next save. In
        // that overwhelmingly common case there is no previous owner to tear
        // down; avoid copying/resetting the full record just to discover that
        // all seven ownership fields are empty.
        if (self.isEmpty()) return;
        const owned = self.*;
        self.* = .{};
        var stack = owned.stack;
        var frame = owned.frame;
        stack.deinit(rt);
        frame.deinit(rt);
    }

    /// Move this storage into an empty destination.
    pub fn moveInto(self: *SuspendedExecutionStorage, destination: *SuspendedExecutionStorage) void {
        std.debug.assert(self != destination);
        std.debug.assert(destination.isEmpty());
        self.swapOwned(destination);
    }

    pub fn isEmpty(self: *const SuspendedExecutionStorage) bool {
        return self.stack.isEmpty() and self.frame.isEmpty();
    }
};

/// The single execution record parked in a generator payload. This is a
/// core-neutral precursor to qjs's resident `JSAsyncFunctionState.frame`.
pub const SuspendedExecutionState = struct {
    pc: usize = 0,
    storage: SuspendedExecutionStorage = .{},
    /// Authoritative dynamic catch target observed when the frame was parked.
    /// `maxInt(u32)` is the null sentinel; bytecode offsets are u32-addressable.
    /// A shared finalizer PC has multiple possible incoming catch states, so
    /// resume must restore this scalar instead of inferring it from `pc`.
    catch_target_pc: u32 = no_suspended_catch_target,
    /// A resident frame exists even when every window is zero length and pc is
    /// zero. This is the zjs counterpart of qjs `func_state != NULL`; neither
    /// the program counter nor storage emptiness can represent that state.
    has_frame: bool = false,
    /// While true, the parked storage is installed in a live exec Frame/Stack.
    /// Legacy/standalone states temporarily hand ownership to those views;
    /// FAM-backed generator states keep ownership resident and lend borrowed
    /// views, matching qjs `JSAsyncFunctionState.frame` with `cur_sp == NULL`.
    running_aliases: bool = false,
    /// The parked record remains the backing owner while `running_aliases` is
    /// true. This is enabled after the first suspension proves that the normal
    /// generator's stack and frame still occupy their combined FAM windows.
    resident_storage_owner: bool = false,

    pub fn deinit(self: *SuspendedExecutionState, rt: *JSRuntime) void {
        if (self.running_aliases) {
            std.debug.assert(!self.resident_storage_owner);
            // The active Frame/Stack owns these aliases and tears them down.
            // A running generator is normally rooted, but keeping deinit
            // ownership-safe prevents a double free if teardown is forced.
            self.storage = .{};
            self.running_aliases = false;
        } else {
            self.storage.deinit(rt);
        }
        self.pc = 0;
        self.catch_target_pc = no_suspended_catch_target;
        self.has_frame = false;
        self.resident_storage_owner = false;
    }

    /// Mark the parked storage as aliases of the newly-installed live owners.
    /// No GC point may occur between installing the views and this call.
    pub fn beginRunningAliases(self: *SuspendedExecutionState) void {
        std.debug.assert(!self.running_aliases);
        self.running_aliases = true;
    }

    /// A run completed or failed without suspending. Drop the stale aliases;
    /// the live Frame/Stack remains responsible for releasing the buffers.
    pub fn finishRunningAliases(self: *SuspendedExecutionState) void {
        if (!self.running_aliases) return;
        self.running_aliases = false;
        self.has_frame = false;
        self.catch_target_pc = no_suspended_catch_target;
        if (self.resident_storage_owner) return;
        self.storage = .{};
    }

    pub fn catchTarget(self: *const SuspendedExecutionState) ?usize {
        if (self.catch_target_pc == no_suspended_catch_target) return null;
        return self.catch_target_pc;
    }

    /// Publish replacement storage and pc before destroying the old buffers;
    /// cleanup-time GC therefore observes the new authoritative state.
    pub fn replaceStorageOwned(self: *SuspendedExecutionState, pc: usize, catch_target_pc: u32, replacement: *SuspendedExecutionStorage, rt: *JSRuntime) void {
        std.debug.assert(&self.storage != replacement);
        if (self.running_aliases) {
            // The old fields are aliases of the same live owners (and may be
            // stale if the operand stack grew). Publish the current views with
            // direct ownership transfer; never inspect or destroy the aliases.
            self.storage = replacement.*;
            replacement.* = .{};
            self.pc = pc;
            self.catch_target_pc = catch_target_pc;
            self.has_frame = true;
            self.running_aliases = false;
            self.resident_storage_owner = false;
            return;
        }
        self.storage.swapOwned(replacement);
        self.pc = pc;
        self.catch_target_pc = catch_target_pc;
        self.has_frame = true;
        self.resident_storage_owner = false;
        // The normal resume path emptied the previous parked owner. Test at
        // the publication seam so that case does not enter the heavyweight
        // generic destructor prologue at all.
        if (!replacement.isEmpty()) replacement.deinit(rt);
    }
};

const no_suspended_catch_target = std.math.maxInt(u32);

const empty_suspended_execution_state: SuspendedExecutionState = .{};

/// The separately-owned qjs `JSAsyncFunctionState` analogue.  A live
/// generator points at one of these; completion destroys it and leaves only
/// the compact `GeneratorPayload` state discriminator on the iterator object,
/// matching `JSGeneratorData { state, func_state }`.
pub const GeneratorExecutionState = struct {
    suspended: SuspendedExecutionState = .{},
    // qjs stores these as raw JSValue slots with JS_UNDEFINED as the empty
    // sentinel. Avoiding Zig optionals keeps the resident state in the same
    // 160-byte slab class as its qjs-style field set.
    this_value: JSValue = JSValue.undefinedValue(),
    current_function: JSValue = JSValue.undefinedValue(),
    yield_star_iterator: JSValue = JSValue.undefinedValue(),
    /// qjs JSAsyncFunctionState.argc. Once parameter initialization parks the
    /// resident frame, the separate input slice is gone; this scalar preserves
    /// mapped/unmapped `arguments` actual-count semantics on resume.
    actual_arg_count: u16 = 0,
    /// Operand-stack slots trailing this record in the same allocation. Zero
    /// denotes the standalone record used by internal hand-built continuations.
    combined_stack_slots: u16 = 0,
    /// Frame args/locals/var-ref slots immediately following the stack region.
    /// The high bit is the completion-pending flag, keeping the record's tail
    /// at four bytes while allowing strict generators with >32K actual args to
    /// retain both args and their required original-args snapshot. A u16 count
    /// incorrectly rejected those ordinary calls even though qjs accepts up to
    /// JS_MAX_LOCAL_VARS (65534) actual arguments.
    combined_frame_metadata: u32 = 0,

    const completion_pending_bit: u32 = 1 << 31;
    const frame_slot_count_mask: u32 = completion_pending_bit - 1;

    fn combinedFrameSlotCount(self: *const GeneratorExecutionState) usize {
        return self.combined_frame_metadata & frame_slot_count_mask;
    }

    fn completionPending(self: *const GeneratorExecutionState) bool {
        return self.combined_frame_metadata & completion_pending_bit != 0;
    }

    fn setCompletionPending(self: *GeneratorExecutionState, pending: bool) void {
        if (pending) {
            self.combined_frame_metadata |= completion_pending_bit;
        } else {
            self.combined_frame_metadata &= frame_slot_count_mask;
        }
    }

    fn combinedStackStorage(self: *GeneratorExecutionState) []JSValue {
        if (self.combined_stack_slots == 0) return &.{};
        const base: [*]u8 = @ptrCast(self);
        const slots: [*]JSValue = @ptrCast(@alignCast(base + generator_execution_storage_offset));
        return slots[0..self.combined_stack_slots];
    }

    fn combinedFrameStorage(self: *GeneratorExecutionState) []JSValue {
        const frame_slot_count = self.combinedFrameSlotCount();
        if (frame_slot_count == 0) return &.{};
        const base: [*]u8 = @ptrCast(self);
        const stack_bytes = @as(usize, self.combined_stack_slots) * @sizeOf(JSValue);
        const slots: [*]JSValue = @ptrCast(@alignCast(base + generator_execution_storage_offset + stack_bytes));
        return slots[0..frame_slot_count];
    }

    pub fn stackUsesCombinedStorage(self: *GeneratorExecutionState) bool {
        const combined = self.combinedStackStorage();
        if (combined.len == 0) return false;
        const stack = self.suspended.storage.stack;
        return stack.capacity != 0 and stack.values.ptr == combined.ptr;
    }

    pub fn frameUsesCombinedStorage(self: *GeneratorExecutionState) bool {
        const combined = self.combinedFrameStorage();
        if (combined.len == 0) return false;
        const frame = self.suspended.storage.frame;
        return frame.storage.len != 0 and frame.storage.ptr == combined.ptr;
    }

    pub fn canRetainResidentStorageOwnership(self: *GeneratorExecutionState) bool {
        if (!self.stackUsesCombinedStorage()) return false;
        return self.combinedFrameSlotCount() == 0 or self.frameUsesCombinedStorage();
    }

    pub fn destroy(self: *GeneratorExecutionState, rt: *JSRuntime) void {
        // qjs async_func_free_frame releases the resident frame before cur_func
        // and this_val. Keep the same ownership order; yield-star's separate
        // zjs root belongs to this execution record as well.
        if (!self.suspended.running_aliases and self.stackUsesCombinedStorage()) {
            var live_values = self.suspended.storage.stack.values;
            destroyValueSliceValuesOnly(rt, &live_values);
            self.suspended.storage.stack = .{};
        }
        if (!self.suspended.running_aliases and self.frameUsesCombinedStorage()) {
            self.suspended.storage.frame.deinitResident(rt);
        }
        self.suspended.deinit(rt);
        destroyOwnedValue(rt, &self.current_function);
        destroyOwnedValue(rt, &self.this_value);
        destroyOwnedValue(rt, &self.yield_star_iterator);
        self.* = .{};
    }
};

const generator_execution_alignment = blk: {
    const state_alignment = std.mem.Alignment.of(GeneratorExecutionState);
    const value_alignment = std.mem.Alignment.of(JSValue);
    break :blk if (state_alignment.compare(.gt, value_alignment)) state_alignment else value_alignment;
};
const generator_execution_storage_offset = std.mem.alignForward(usize, @sizeOf(GeneratorExecutionState), @alignOf(JSValue));

fn createGeneratorExecutionStateWithStorage(rt: *JSRuntime, stack_slots: usize, frame_slots: usize) !*GeneratorExecutionState {
    const stack_slot_count = std.math.cast(u16, stack_slots) orelse return error.StackOverflow;
    if (frame_slots > GeneratorExecutionState.frame_slot_count_mask) return error.StackOverflow;
    const frame_slot_count: u32 = @intCast(frame_slots);
    const total_slots = try std.math.add(usize, stack_slots, frame_slots);
    const slot_bytes = try std.math.mul(usize, total_slots, @sizeOf(JSValue));
    const allocation_size = try std.math.add(usize, generator_execution_storage_offset, slot_bytes);
    const bytes = try rt.allocRuntimeAlignedBytes(allocation_size, generator_execution_alignment);
    const execution: *GeneratorExecutionState = @ptrCast(@alignCast(bytes.ptr));
    execution.* = .{
        .combined_stack_slots = stack_slot_count,
        .combined_frame_metadata = frame_slot_count,
    };
    const combined_stack = execution.combinedStackStorage();
    execution.suspended.storage.stack = .{
        .values = combined_stack.ptr[0..0],
        .capacity = combined_stack.len,
    };
    execution.suspended.storage.frame.storage = execution.combinedFrameStorage();
    return execution;
}

fn freeGeneratorExecutionState(rt: *JSRuntime, execution: *GeneratorExecutionState) void {
    const combined_stack_slots = execution.combined_stack_slots;
    const combined_frame_slots = execution.combinedFrameSlotCount();
    execution.destroy(rt);
    if (combined_stack_slots == 0 and combined_frame_slots == 0) {
        rt.memory.destroy(GeneratorExecutionState, execution);
        return;
    }
    const total_slots = @as(usize, combined_stack_slots) + combined_frame_slots;
    const slot_bytes = total_slots * @sizeOf(JSValue);
    const allocation_size = generator_execution_storage_offset + slot_bytes;
    const bytes: [*]u8 = @ptrCast(execution);
    rt.memory.freeAlignedBytes(bytes[0..allocation_size], generator_execution_alignment);
}

fn destroyGeneratorExecutionState(rt: *JSRuntime, slot: *?*GeneratorExecutionState) void {
    const execution = slot.* orelse return;
    // Publish completion before releasing graph edges so re-entrant GC sees
    // the compact completed state, never a half-destroyed execution record.
    slot.* = null;
    std.debug.assert(!execution.completionPending());
    freeGeneratorExecutionState(rt, execution);
}

pub const GeneratorPayload = struct {
    realm_global_ptr: ?*Object = null,
    execution: ?*GeneratorExecutionState = null,
    async_promise: ?JSValue = null,
    /// Async-generator request queue (mirrors JSAsyncGeneratorData.queue,
    /// quickjs.c:21362): FIFO of pending next/return/throw requests.
    async_queue: []AsyncGeneratorRequest = &.{},
    async_queue_capacity: usize = 0,
    resume_completion_type: i32 = 0,
    /// Dense index into the runtime's borrowed-reference-holder registry.
    /// Generator instances carry a borrowed realm pointer just like function
    /// objects; caching the index keeps short-lived generator teardown O(1).
    /// These three bytes consume existing tail padding without growing the
    /// payload (see the matching fields on FunctionPayload).
    borrowed_holder_index_lo: u8 = 0,
    borrowed_holder_index_mid: u8 = 0,
    borrowed_holder_index_hi: u8 = 0,
    /// Async-generator state machine (mirrors JSAsyncGeneratorStateEnum,
    /// quickjs.c:21345). Only meaningful for JS_CLASS_ASYNC_GENERATOR objects.
    async_state: u8 = 0,
    /// GeneratorSuspendKind of the last suspension.
    suspend_kind: u8 = 0,
    done: bool = false,
    executing: bool = false,
    started: bool = false,
    just_yielded: bool = false,
    yield_star_suspended: bool = false,

    pub fn destroy(self: *GeneratorPayload, rt: *JSRuntime) void {
        // Normal generators borrow this pointer under current_function; clear
        // it before releasing that dominating strong edge.
        self.realm_global_ptr = null;
        destroyGeneratorExecutionState(rt, &self.execution);
        destroyOptionalValue(rt, &self.async_promise);
        for (self.async_queue) |*req| {
            req.result.free(rt);
            req.promise.free(rt);
            req.resolve.free(rt);
            req.reject.free(rt);
        }
        if (self.async_queue_capacity != 0) {
            rt.memory.free(AsyncGeneratorRequest, self.async_queue.ptr[0..self.async_queue_capacity]);
        }
        self.async_queue = &.{};
        self.async_queue_capacity = 0;
        self.* = .{};
    }
};

pub const ArrayBuiltinMarker = property.ArrayBuiltinMarker;
pub const TypedArrayBuiltinMarker = property.TypedArrayBuiltinMarker;

pub const PrimitivePrototypeSlot = enum(u8) {
    string,
    number,
    boolean,
    symbol,
    bigint,
    count,
};

const primitive_prototype_slot_count: usize = @intFromEnum(PrimitivePrototypeSlot.count);

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
    primitive_prototypes: [primitive_prototype_slot_count]?JSValue = @splat(null),
    class_fields_init: ?JSValue = null,
    import_meta: ?JSValue = null,
    lexical_this: ?JSValue = null,
    arrow_constructor_this: ?JSValue = null,
    arrow_new_target: ?JSValue = null,
    super_constructor: ?JSValue = null,
    private_remap_from: []atom.Atom = &.{},
    private_remap_to: []atom.Atom = &.{},
    realm_global: ?JSValue = null,
    proxy_revoke_target: ?JSValue = null,
    promise_capability_slot: ?JSValue = null,
    promise_resolving_target: ?JSValue = null,
    promise_resolving_state: ?JSValue = null,
    promise_resolving_reject: bool = false,
    promise_thenable_target: ?JSValue = null,
    promise_thenable_this: ?JSValue = null,
    promise_thenable_then: ?JSValue = null,
    promise_reaction_record: ?JSValue = null,
    promise_reaction_value: ?JSValue = null,
    promise_reaction_is_rejected: bool = false,
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
    realm_type_error_constructor: ?JSValue = null,

    pub fn destroy(self: *FunctionRarePayload, rt: *JSRuntime) void {
        destroyOptionalValue(rt, &self.source);
        destroyOptionalValue(rt, &self.class_fields_init);
        destroyOptionalValue(rt, &self.import_meta);
        destroyOptionalValue(rt, &self.lexical_this);
        destroyOptionalValue(rt, &self.arrow_constructor_this);
        destroyOptionalValue(rt, &self.arrow_new_target);
        destroyOptionalValue(rt, &self.super_constructor);
        destroyAtomSlice(rt, &self.private_remap_from);
        destroyAtomSlice(rt, &self.private_remap_to);
        destroyOptionalValue(rt, &self.realm_global);
        destroyOptionalValue(rt, &self.proxy_revoke_target);
        destroyOptionalValue(rt, &self.promise_capability_slot);
        destroyOptionalValue(rt, &self.promise_resolving_target);
        destroyOptionalValue(rt, &self.promise_resolving_state);
        destroyOptionalValue(rt, &self.promise_thenable_target);
        destroyOptionalValue(rt, &self.promise_thenable_this);
        destroyOptionalValue(rt, &self.promise_thenable_then);
        destroyOptionalValue(rt, &self.promise_reaction_record);
        destroyOptionalValue(rt, &self.promise_reaction_value);
        destroyOptionalValue(rt, &self.promise_combinator_state);
        destroyOptionalValue(rt, &self.promise_finally_payload);
        destroyOptionalValue(rt, &self.promise_finally_callback);
        destroyOptionalValue(rt, &self.promise_finally_constructor);
        destroyOptionalValue(rt, &self.async_dispose_stack);
        destroyOptionalValue(rt, &self.async_function_continuation);
        destroyOptionalValue(rt, &self.realm_type_error_constructor);
        destroyOptionalValueSlots(rt, &self.primitive_prototypes);
        self.* = .{};
    }
};

pub const FunctionPayload = struct {
    pub const NativeFields = extern struct {
        // qjs `u.cfunc.realm`: native functions own a per-object realm field;
        // bytecode functions instead read the shared realm from their FB.
        realm_global_ptr: ?*Object = null,
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
        fields.realm_global_ptr = null;
        const native_dispatch_name = fields.native_dispatch_name;
        fields.native_dispatch_name = atom.null_atom;
        rt.atoms.free(native_dispatch_name);
        self.destroyRare(rt);
    }

    comptime {
        std.debug.assert(@sizeOf(NativeFields) == 40);
        std.debug.assert(@sizeOf(FunctionPayload) == 56);
    }
};

/// Cold per-closure extension for zjs-only function metadata. The hot qjs
/// `u.func.home_object` word stores a direct Object pointer when this extension
/// is absent; its low tag bit points here only for arrows/classes that need
/// additional per-closure state.
pub const BytecodeFunctionAux = struct {
    home_object: ?*Object = null,
    rare: FunctionRarePayload = .{},

    fn destroy(self: *BytecodeFunctionAux, rt: *JSRuntime) void {
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
    var_refs: [*]*var_ref_mod.VarRef = emptyVarRefs(),
    /// null/direct `Object*`, or a low-bit-tagged `BytecodeFunctionAux*`.
    home_or_aux: ?*anyopaque = null,

    pub inline fn captureSlice(self: *const BytecodeFunctionStorage) []*var_ref_mod.VarRef {
        // FB is installed before closure capture construction. Treat the
        // sentinel as an empty/uninstalled array even when the eventual FB
        // count is non-zero, so construction rollback and replacement never
        // walk the dangling pointer. Fully-published callables with a non-zero
        // count have already replaced it with their allocated array.
        if (self.var_refs == emptyVarRefs()) return &.{};
        const fb = self.function_bytecode orelse return &.{};
        return self.var_refs[0..fb.var_refs_len];
    }

    pub inline fn emptyVarRefs() [*]*var_ref_mod.VarRef {
        return @ptrFromInt(@alignOf(*var_ref_mod.VarRef));
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == 24);
    }
};

pub const ModuleNamespacePayload = struct {
    names: []atom.Atom = &.{},
    cells: []JSValue = &.{},
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *ModuleNamespacePayload, rt: *JSRuntime) void {
        destroyAtomSlice(rt, &self.names);
        destroyValueSlice(rt, &self.cells);
        self.* = .{};
    }
};

pub fn destroyDetachedClassPayload(rt: *JSRuntime, class_id: class.ClassId, payload_kind: class.PayloadKind, payload: *class.Payload) void {
    _ = class_id;
    const ptr = payload.* orelse return;
    payload.* = null;
    switch (payload_kind) {
        .ordinary => {
            const typed: *OrdinaryPayload = @ptrCast(@alignCast(ptr));
            typed.destroy(rt);
            rt.memory.destroy(OrdinaryPayload, typed);
        },
        .iterator => {
            const typed: *IteratorPayload = @ptrCast(@alignCast(ptr));
            typed.destroy(rt);
            rt.memory.destroy(IteratorPayload, typed);
        },
        .collection => {
            const typed: *CollectionPayload = @ptrCast(@alignCast(ptr));
            typed.destroy(rt);
            rt.memory.destroy(CollectionPayload, typed);
        },
        .finalization_registry => {
            const typed: *FinalizationRegistryPayload = @ptrCast(@alignCast(ptr));
            typed.destroy(rt);
            rt.memory.destroy(FinalizationRegistryPayload, typed);
        },
        .std_file => {
            const typed: *StdFilePayload = @ptrCast(@alignCast(ptr));
            typed.destroy();
            rt.memory.destroy(StdFilePayload, typed);
        },
        .disposable_stack => {
            const typed: *DisposableStackPayload = @ptrCast(@alignCast(ptr));
            typed.destroy(rt);
            rt.memory.destroy(DisposableStackPayload, typed);
        },
        .realm => {
            const typed: *RealmPayload = @ptrCast(@alignCast(ptr));
            typed.destroy(rt);
            rt.memory.destroy(RealmPayload, typed);
        },
        .buffer => {
            const typed: *BufferPayload = @ptrCast(@alignCast(ptr));
            typed.destroy(rt);
            rt.memory.destroy(BufferPayload, typed);
        },
        .typed_array => {
            const typed: *TypedArrayPayload = @ptrCast(@alignCast(ptr));
            typed.destroy(rt);
            rt.memory.destroy(TypedArrayPayload, typed);
        },
        .regexp => {
            const typed: *RegExpPayload = @ptrCast(@alignCast(ptr));
            typed.destroy(rt);
            rt.memory.destroy(RegExpPayload, typed);
        },
        .bound_function => {
            const typed: *BoundFunctionPayload = @ptrCast(@alignCast(ptr));
            typed.destroy(rt);
            rt.memory.destroy(BoundFunctionPayload, typed);
        },
        .proxy => {
            const typed: *ProxyPayload = @ptrCast(@alignCast(ptr));
            typed.destroy(rt);
            rt.memory.destroy(ProxyPayload, typed);
        },
        .arguments => {
            const typed: *ArgumentsPayload = @ptrCast(@alignCast(ptr));
            typed.destroy(rt);
            rt.memory.destroy(ArgumentsPayload, typed);
        },
        .object_data => {
            const typed: *ObjectDataPayload = @ptrCast(@alignCast(ptr));
            typed.destroy(rt);
            rt.memory.destroy(ObjectDataPayload, typed);
        },
        .weak_ref => {
            const typed: *WeakRefPayload = @ptrCast(@alignCast(ptr));
            typed.destroy(rt);
            rt.memory.destroy(WeakRefPayload, typed);
        },
        .var_ref => {
            const typed: *VarRefPayload = @ptrCast(@alignCast(ptr));
            typed.destroy(rt);
            rt.memory.destroy(VarRefPayload, typed);
        },
        .promise => {
            const typed: *PromisePayload = @ptrCast(@alignCast(ptr));
            typed.destroy(rt);
            rt.memory.destroy(PromisePayload, typed);
        },
        .generator => {
            const typed: *GeneratorPayload = @ptrCast(@alignCast(ptr));
            typed.destroy(rt);
            rt.memory.destroy(GeneratorPayload, typed);
        },
        .function => {
            const typed: *FunctionPayload = @ptrCast(@alignCast(ptr));
            typed.destroyNative(rt);
            rt.memory.destroy(FunctionPayload, typed);
        },
        .module_namespace => {
            const typed: *ModuleNamespacePayload = @ptrCast(@alignCast(ptr));
            typed.destroy(rt);
            rt.memory.destroy(ModuleNamespacePayload, typed);
        },
        .none => {},
    }
}

pub const ObjectFlags = packed struct(u16) {
    extensible: bool = true,
    immutable_prototype: bool = false,
    fast_array: bool = false,
    is_html_dda: bool = false,
    may_have_indexed_properties: bool = false,
    length_writable: bool = true,
    is_with_environment: bool = false,
    is_prototype: bool = false,
    reserved_class_payload_finalizer_slot: bool = false,
    has_exotic_methods: bool = false,
    is_borrowed_reference_holder: bool = false,
    /// Actual active payload state. This is distinct from the class's declared
    /// payload kind because ordinary/realm payloads are attached lazily.
    class_payload_kind: class.PayloadKind = .none,
};

var test_standard_exotic_methods: [class.ids.init_count]?*const ExoticMethods = @splat(null);

fn classHasExoticMethods(rt: *const JSRuntime, class_id: class.ClassId, class_record: ?*const class.Record) bool {
    if (exoticMethodsForClassId(class_id) != null) return true;
    if (class_record) |record| return record.has_exotic or record.exotic_methods != null;
    const record = rt.classes.recordPtr(class_id) orelse return false;
    return record.has_exotic or record.exotic_methods != null;
}

fn classNeedsSlowPropertyAccess(class_id: class.ClassId, has_exotic_methods: bool) bool {
    if (has_exotic_methods) return true;
    return switch (class_id) {
        class.ids.array,
        class.ids.mapped_arguments,
        class.ids.module_ns,
        class.ids.proxy,
        class.ids.uint8c_array,
        class.ids.int8_array,
        class.ids.uint8_array,
        class.ids.int16_array,
        class.ids.uint16_array,
        class.ids.int32_array,
        class.ids.uint32_array,
        class.ids.big_int64_array,
        class.ids.big_uint64_array,
        class.ids.float16_array,
        class.ids.float32_array,
        class.ids.float64_array,
        class.ids.dataview,
        => true,
        else => false,
    };
}

fn exoticMethodsForClassId(class_id: class.ClassId) ?*const ExoticMethods {
    if (builtin.is_test and class_id < test_standard_exotic_methods.len) {
        if (test_standard_exotic_methods[class_id]) |methods| return methods;
    }
    return switch (class_id) {
        else => null,
    };
}

/// Three-state result of an existence-only binding probe (no value `dup`).
/// `uninitialized` mirrors qjs's TDZ VARREF case where the existence path
/// (quickjs.c:8856-8860) still raises `ReferenceErrorUninitialized`.
pub const BindingExistence = enum { absent, present, uninitialized };

/// Dense-array arm of QuickJS's 24-byte `JSObject.u`. ZJS retains an explicit
/// capacity in addition to the visible length/count, so the final scalar is
/// padding rather than observable state.
pub const DenseArrayStorage = extern struct {
    values: [*]JSValue = @ptrFromInt(@alignOf(JSValue)),
    count: u32 = 0,
    capacity: u32 = 0,
    length: u32 = 0,
    _padding: u32 = 0,
};

/// Full 24-byte class-data union, matching qjs `JSObject.u`. Payload-backed
/// classes use only the first pointer; dense arrays use the complete array arm.
/// Bytecode functions will use the same three-word budget for FB/var_refs/home.
pub const ObjectStorage = extern union {
    /// Out-of-line payload for non-array classes (Map/Proxy/native function/...).
    payload: class.Payload,
    array: DenseArrayStorage,
    bytecode_function: BytecodeFunctionStorage,
    regexp: RegExpPayload,

    pub inline fn initPayload(payload: class.Payload) ObjectStorage {
        var storage: ObjectStorage = .{ .array = .{} };
        storage.payload = payload;
        return storage;
    }
};

pub const Object = extern struct {
    pub const gc_kind_tag: u8 = @intFromEnum(gc.GcKind.object);
    comptime {
        // GC prefix model: BlockHeader.meta() reads objectPtr-8, so header MUST
        // be at offset 0. Zig reorders non-extern fields; if this fails, force
        // header first with `align(16)` (see FunctionBytecode).
        std.debug.assert(@offsetOf(@This(), "header") == 0);
        // qjs JSObject is 64B: 16B GC header + 8B metadata + shape/prop
        // pointers + the 24B class-specific union.
        std.debug.assert(@sizeOf(@This()) == 64);
        std.debug.assert(@sizeOf(ObjectFlags) == 2);
        std.debug.assert(@sizeOf(ObjectStorage) == 24);
        std.debug.assert(@offsetOf(@This(), "u") == 40);
    }
    header: gc.GCObjectHeader,
    weakref_count: u32 = 0,
    class_id: class.ClassId,
    flags: ObjectFlags = .{},
    shape_ref: *shape.Shape,
    // Bare pointer to the property VALUE array (qjs `JSObject.prop`, a bare
    // `JSProperty *`). The element count is NOT stored here — it is the owning
    // shape's `prop_count` (qjs reads count/size from `JSShape`), and the
    // allocated capacity is `shape_ref.props().len` (`propertyStorageCapacity`).
    // A dangling aligned sentinel means no storage; allocated capacity remains
    // derivable from the shape, avoiding a redundant object flag.
    prop_values: [*]property.Entry = @ptrFromInt(@alignOf(property.Entry)),
    // qjs 24-byte class union: payload pointer OR dense-array state.
    u: ObjectStorage = .{ .array = .{} },
    /// JS-observable `.length` for arrays. Distinct from dense `count` (the
    /// dense element extent): an array may carry `array_length > array_count`
    /// with the slots `[array_count, array_length)` being HOLES (resolve up the
    /// prototype chain; never own; not enumerated). Semantically mirrors qjs
    /// `p->prop[0].u.value` (set_array_length / add_fast_array_element). Invariant:
    /// `array_length >= array_count` for arrays. Unmapped arguments keep it
    /// equal to `array_count` solely as dense-storage metadata; their visible
    /// `length` remains an ordinary own property in the shared arguments shape.
    pub fn expect(val: JSValue) !*Object {
        const header = val.refHeader() orelse return error.TypeError;
        if (!val.isObject()) return error.TypeError;
        return @fieldParentPtr("header", header);
    }

    pub fn create(rt: *JSRuntime, class_id: class.ClassId, prototype: ?*Object) !*Object {
        return createInternal(rt, class_id, prototype, 0, null);
    }

    pub fn createWithOwnPropertyCapacity(rt: *JSRuntime, class_id: class.ClassId, prototype: ?*Object, capacity: usize) !*Object {
        return createInternal(rt, class_id, prototype, capacity, null);
    }

    /// Allocate the private generator object/state used while parameter
    /// initialization runs, but do not allocate a Shape or link the object into
    /// the GC registry yet. qjs keeps JSGeneratorData/JSAsyncFunctionState
    /// detached until `async_func_resume` reaches OP_initial_yield, then creates
    /// the public object once with its final constructor-derived prototype.
    ///
    /// The shell is not a JSValue and must be paired with either
    /// `finishGeneratorShell` or `destroyGeneratorShell`. Its owned JSValue
    /// edges carry ordinary refcounts while detached, so allocation-triggered
    /// cycle collection cannot reclaim them.
    pub fn createGeneratorShell(rt: *JSRuntime, class_id: class.ClassId) !*Object {
        std.debug.assert(class_id == class.ids.generator or class_id == class.ids.async_generator);
        const class_record = rt.classes.recordPtr(class_id);
        std.debug.assert(inlineClassPayloadLayout(class_record) == null);
        const payload_kind = if (class_record) |record|
            record.payload_kind
        else
            class.standardPayloadKind(class_id);
        std.debug.assert(payload_kind == .generator);

        const self = try rt.createRuntime(Object);
        errdefer rt.memory.destroy(Object, self);
        // The detached path knows the finalized operand-stack size and installs
        // a variable-sized execution record immediately afterwards. Allocate
        // only the compact JSGeneratorData analogue here; Object.create keeps
        // using allocClassPayload for internal continuations with no bytecode
        // sizing context.
        const generator_payload = try rt.createRuntime(GeneratorPayload);
        generator_payload.* = .{};
        const class_payload: class.Payload = @ptrCast(generator_payload);
        errdefer freeClassPayloadAllocation(rt, class_payload, .generator);

        var reserved_class_payload_finalizer_slot = false;
        errdefer if (reserved_class_payload_finalizer_slot) rt.releaseDeferredClassPayloadFinalizerSlot();
        if (class_record) |record| {
            if (record.payload_finalizer != null) {
                try rt.reserveDeferredClassPayloadFinalizerSlot();
                reserved_class_payload_finalizer_slot = true;
            }
        }
        const has_exotic_methods = classHasExoticMethods(rt, class_id, class_record);
        self.* = .{
            .header = .{},
            .class_id = class_id,
            .u = ObjectStorage.initPayload(class_payload),
            // These fields become readable only after finishGeneratorShell.
            .shape_ref = undefined,
            .prop_values = @ptrFromInt(@alignOf(property.Entry)),
            .flags = .{
                .class_payload_kind = .generator,
                .reserved_class_payload_finalizer_slot = reserved_class_payload_finalizer_slot,
                .has_exotic_methods = has_exotic_methods,
            },
        };
        return self;
    }

    /// Turn a detached generator shell into the registered public object using
    /// its final prototype. No temporary null-prototype Shape is ever created.
    pub fn finishGeneratorShell(self: *Object, rt: *JSRuntime, prototype: ?*Object) !void {
        std.debug.assert(self.class_id == class.ids.generator or self.class_id == class.ids.async_generator);
        std.debug.assert(self.flags.class_payload_kind == .generator);
        std.debug.assert(!self.header.meta().flags.heap_accounted);
        const final_shape = try rt.shapes.createObjectRoot(prototype);
        markObjectAsPrototype(rt, prototype);
        self.shape_ref = final_shape;
        rt.registerObjectWithBytes(self, @sizeOf(Object)) catch |err| {
            self.shape_ref = undefined;
            rt.shapes.release(final_shape);
            return err;
        };
    }

    /// Error-path counterpart for a shell that has not been registered yet.
    pub fn destroyGeneratorShell(self: *Object, rt: *JSRuntime) void {
        std.debug.assert(self.class_id == class.ids.generator or self.class_id == class.ids.async_generator);
        std.debug.assert(!self.header.meta().flags.heap_accounted);
        if (self.flags.is_borrowed_reference_holder) rt.unregisterBorrowedReferenceHolder(self);
        freeClassPayloadAllocation(rt, self.u.payload, self.flags.class_payload_kind);
        self.u.payload = null;
        self.flags.class_payload_kind = .none;
        if (self.flags.reserved_class_payload_finalizer_slot) {
            self.flags.reserved_class_payload_finalizer_slot = false;
            rt.releaseDeferredClassPayloadFinalizerSlot();
        }
        rt.memory.destroy(Object, self);
    }

    /// Create a fresh object with the same class, prototype, shared shape, and
    /// own-property slots as a realm-pinned template. This is the zjs analogue
    /// of qjs `JS_NewObjectFromShape`: the caller has already paid the property
    /// transition cost once while building `template`; each later object only
    /// retains that final shape and duplicates its value slots.
    ///
    /// Object state outside the fixed property layout (array elements, class
    /// payload contents, extensibility, and rare flags) is intentionally not
    /// cloned. Templates must therefore be freshly-built ordinary class
    /// instances whose only reusable state is their own-property layout.
    pub fn createFromPropertyTemplate(rt: *JSRuntime, template: *const Object) !*Object {
        std.debug.assert(!template.isArray());
        std.debug.assert(!template.isProxy());
        std.debug.assert(!template.flags.is_borrowed_reference_holder);
        return createPreparedPropertyTemplate(rt, template, template.propertyEntries(), .borrowed);
    }

    /// Construct a RegExp result from its realm-pinned named-property layout,
    /// supplying the three per-result slots in the same allocation. QuickJS
    /// does this with `JS_NewObjectFromShape(ctx->regexp_result_shape, props)`.
    pub fn createRegExpMatchArrayFromPropertyTemplate(
        rt: *JSRuntime,
        template: *const Object,
        match_index: i32,
        input_value: JSValue,
        groups_value: JSValue,
    ) !*Object {
        std.debug.assert(template.isArray());
        std.debug.assert(!template.isProxy());
        std.debug.assert(!template.flags.is_borrowed_reference_holder);
        std.debug.assert(template.arrayLength() == 0);
        std.debug.assert(template.arrayElements().len == 0);

        const props = template.shape_ref.props();
        const index_atom = comptime atom.predefinedId("index", .string).?;
        const input_atom = comptime atom.predefinedId("input", .string).?;
        const groups_atom = comptime atom.predefinedId("groups", .string).?;
        std.debug.assert(template.shape_ref.prop_count == 3);
        std.debug.assert(props[0].atom_id == index_atom);
        std.debug.assert(props[1].atom_id == input_atom);
        std.debug.assert(props[2].atom_id == groups_atom);
        for (props) |prop| std.debug.assert(property.Flags.fromBits(prop.flags).kind == .data);

        // `createPreparedPropertyTemplate(.owned)` consumes these refs on both
        // success and error, matching qjs JS_NewObjectFromShape's `props`
        // contract. The caller keeps its borrowed input/groups values.
        const entries = [_]property.Entry{
            .{ .slot = .{ .data = JSValue.int32(match_index) } },
            .{ .slot = .{ .data = input_value.dup() } },
            .{ .slot = .{ .data = groups_value.dup() } },
        };
        return createPreparedPropertyTemplate(rt, template, &entries, .owned);
    }

    /// Allocate a RegExp instance directly from the realm-pinned one-property
    /// layout. This uses the general class-payload constructor because RegExp
    /// owns internal state, but skips rebuilding `lastIndex` after allocation.
    /// It is the direct counterpart of qjs `JS_NewObjectFromShape` with
    /// `ctx->regexp_shape`.
    pub fn createRegExpFromPropertyTemplate(rt: *JSRuntime, template: *const Object) !*Object {
        std.debug.assert(template.class_id == class.ids.regexp);
        std.debug.assert(!template.isProxy());
        std.debug.assert(template.shape_ref.prop_count == 1);
        std.debug.assert(template.propAtomAt(0) == atom.ids.lastIndex);
        const last_index_flags = template.propFlagsAt(0);
        std.debug.assert(last_index_flags.kind == .data);
        std.debug.assert(last_index_flags.writable and !last_index_flags.enumerable and !last_index_flags.configurable);
        return createInternal(rt, class.ids.regexp, template.getPrototype(), 0, .{
            .shape_ref = template.shape_ref,
            .entries = template.propertyEntries(),
        });
    }

    const PreparedPropertyEntryOwnership = enum {
        /// Retain each live slot while installing it; the caller keeps entries.
        borrowed,
        /// Consume every live slot, including when construction fails.
        owned,
    };

    /// Allocate an object directly from a realm-pinned, fully prepared shape.
    /// This is the core analogue of qjs `JS_NewObjectFromShape`: class layout,
    /// prototype, exotic metadata, and property kinds were validated when the
    /// template was built, so construction retains that shape and allocates
    /// exactly its value slots without re-entering the general class-payload
    /// constructor.
    noinline fn createPreparedPropertyTemplate(
        rt: *JSRuntime,
        template: *const Object,
        entries: []const property.Entry,
        comptime entry_ownership: PreparedPropertyEntryOwnership,
    ) !*Object {
        std.debug.assert(!template.isProxy());
        std.debug.assert(!template.flags.is_borrowed_reference_holder);
        std.debug.assert(!template.flags.reserved_class_payload_finalizer_slot);
        std.debug.assert(!payloadKindAllocates(template.flags.class_payload_kind));
        std.debug.assert(entries.len == template.shape_ref.prop_count);
        std.debug.assert(template.class_id == class.ids.object or
            template.class_id == class.ids.array or
            template.class_id == class.ids.arguments or
            template.class_id == class.ids.mapped_arguments);

        // qjs JS_NewObjectFromShape consumes `props` unconditionally: it
        // copies the cells into the object on success and destroys them by the
        // shape flags on allocation failure. Keep that ownership mode explicit
        // rather than hiding a second retain/release pair in the prepared-shape
        // constructor.
        var owned_entries_pending = entry_ownership == .owned;
        errdefer if (owned_entries_pending) {
            const props = template.shape_ref.props();
            for (entries, 0..) |entry, index| {
                const entry_flags = property.Flags.fromBits(props[index].flags);
                destroyPropertySlot(rt, props[index].atom_id, entry_flags, entry.slot);
            }
        };

        const alloc_size = @sizeOf(Object);
        rt.collectBeforeObjectAllocation(alloc_size);
        const self = try rt.memory.createNoTrigger(Object);
        var initialized = false;
        errdefer if (initialized)
            destroyFromHeader(rt, &self.header)
        else
            rt.memory.destroy(Object, self);

        const shape_ref = template.shape_ref;
        shape_ref.retain();
        var shape_owned = true;
        errdefer if (shape_owned) rt.shapes.release(shape_ref);

        const property_capacity: usize = shape_ref.prop_size;
        var property_storage: []property.Entry = &.{};
        var property_storage_owned = false;
        errdefer if (property_storage_owned) rt.memory.free(property.Entry, property_storage);
        if (property_capacity != 0) {
            property_storage = try rt.allocRuntime(property.Entry, property_capacity);
            property_storage_owned = true;
        }

        markObjectAsPrototype(rt, shape_ref.proto);
        self.* = .{
            .header = .{},
            .class_id = template.class_id,
            .u = ObjectStorage.initPayload(null),
            .flags = .{
                .has_exotic_methods = template.flags.has_exotic_methods,
                .class_payload_kind = template.flags.class_payload_kind,
            },
            .shape_ref = shape_ref,
            .prop_values = if (property_capacity == 0) @ptrFromInt(@alignOf(property.Entry)) else property_storage.ptr,
        };
        switch (entry_ownership) {
            .borrowed => {
                const props = shape_ref.props();
                for (entries, 0..) |entry, index| {
                    const entry_flags = property.Flags.fromBits(props[index].flags);
                    self.prop_values[index] = .{ .slot = entry.slot.dup(entry_flags) };
                }
            },
            .owned => {
                @memcpy(self.prop_values[0..entries.len], entries);
                owned_entries_pending = false;
            },
        }

        property_storage_owned = false;
        shape_owned = false;
        initialized = true;
        try rt.registerObjectWithBytes(self, alloc_size);
        initialized = false;
        return self;
    }

    const PropertyTemplate = struct {
        shape_ref: *shape.Shape,
        entries: []const property.Entry,
    };

    fn markObjectAsPrototype(rt: *JSRuntime, prototype: ?*Object) void {
        if (prototype) |proto| {
            proto.flags.is_prototype = true;
            if (proto.flags.may_have_indexed_properties) {
                rt.any_prototype_may_have_indexed_properties = true;
            }
        }
    }

    fn createInternal(
        rt: *JSRuntime,
        class_id: class.ClassId,
        prototype: ?*Object,
        own_property_capacity: usize,
        property_template: ?PropertyTemplate,
    ) !*Object {
        // qjs JS_NewObjectFromShape reads class metadata in place from
        // `ctx->rt->class_array[class_id]` — it never copies the whole JSClass
        // onto the stack. Mirror that with a pointer-only view so the plain
        // object / array hot path (emptyobj/objalloc/array3) touches just the
        // scalar fields it needs (inline_payload_size, payload_kind,
        // payload_finalizer, exotic) instead of an 88B SIMD block copy of Record.
        const class_record = rt.classes.recordPtr(class_id);
        const inline_layout = inlineClassPayloadLayout(class_record);
        const alloc_size = if (inline_layout) |layout| layout.object_size else @sizeOf(Object);
        rt.collectBeforeObjectAllocation(alloc_size);
        const self = if (inline_layout) |layout| blk: {
            // The object-level threshold/force-GC hook just ran above. Enter
            // MemoryAccount directly so this same allocation does not request
            // a second collection (observable to test allocation probes and
            // unnecessarily expensive in force-GC builds).
            const bytes = try rt.memory.allocAlignedBytesNoTrigger(layout.allocation_size, layout.allocation_alignment);
            break :blk @as(*Object, @ptrFromInt(@intFromPtr(bytes.ptr) + layout.object_offset));
        } else try rt.memory.createNoTrigger(Object);
        var initialized = false;
        errdefer {
            if (initialized) {
                destroyFromHeader(rt, &self.header);
            } else {
                freeObjectAllocation(rt, self, inline_layout);
            }
        }
        // qjs shape model (faithful): start from the SHARED, transition-cacheable
        // empty root shape (qjs hash-consed shapes) so objects adding the same
        // properties converge on one shared shape via cached transitions, instead
        // of each getting a fresh unique shape mutated in place (the old
        // createObjectRootWithPropertyCapacity → ~1:1 shapes + per-object
        // appendProperty/rehashShape). The property VALUE array is still
        // pre-reserved below; only the SHAPE is shared.
        const property_capacity: usize = if (property_template) |template|
            template.shape_ref.prop_size
        else
            shape.propertyCapacityForNeeded(own_property_capacity);
        const shape_ref = if (property_template) |template| blk: {
            std.debug.assert(template.shape_ref.proto == prototype);
            std.debug.assert(template.entries.len == template.shape_ref.prop_count);
            template.shape_ref.retain();
            break :blk template.shape_ref;
        } else if (property_capacity == 0)
            try rt.shapes.createObjectRoot(prototype)
        else
            try rt.shapes.createObjectRootWithPropertyCapacity(prototype, property_capacity);
        var shape_owned = true;
        errdefer if (shape_owned) rt.shapes.release(shape_ref);
        var property_storage: []property.Entry = &.{};
        var property_storage_owned = false;
        errdefer if (property_storage_owned) rt.memory.free(property.Entry, property_storage);
        if (property_capacity != 0) {
            property_storage = try rt.allocRuntime(property.Entry, property_capacity);
            property_storage_owned = true;
        }
        var class_payload: class.Payload = null;
        var class_payload_kind: class.PayloadKind = .none;
        const payload_kind = if (class_record) |record|
            record.payload_kind
        else
            class.standardPayloadKind(class_id);
        // The plain-object (`.ordinary`), fast-array (`.none`) and `.realm` hot
        // paths carry NO class payload — they skip the allocating switch
        // entirely. Every allocating arm has identical shape
        // (`createRuntime(T); payload.* = .{}`), so it lives in a `noinline`
        // out-of-line helpers: the mutually exclusive native/bytecode function
        // payload has its own allocator, while the remaining class payloads
        // stay in `allocClassPayload`. Keeping those arms out of
        // `createInternal` drops the register-spill frame — the union of all
        // arms' locals — off the emptyobj/objalloc/array3 hot path. Mirrors qjs
        // where JS_NewObjectFromShape's class `switch` is tiny scalar init, not
        // class sub-allocations inlined into one oversized frame. Pre-`initialized`
        // cleanup is a single by-kind free (mirror of the per-arm
        // `errdefer destroy`).
        var class_payload_allocated = false;
        errdefer if (class_payload_allocated) freeClassPayloadAllocation(rt, class_payload, class_payload_kind);
        if (class_id == class.ids.regexp) {
            // qjs initializes `JSObject.u.regexp` in the object allocation;
            // only custom classes selecting `.regexp` retain the generic
            // out-of-line payload path.
            class_payload_kind = .regexp;
        } else if (payload_kind == .function and class.isBytecodeFunctionClass(class_id)) {
            // qjs stores bytecode callable state directly in JSObject.u.func.
            class_payload_kind = .function;
        } else if (payloadKindAllocates(payload_kind)) {
            class_payload = if (payload_kind == .function)
                try allocFunctionPayload(rt)
            else
                try allocClassPayload(rt, payload_kind);
            class_payload_kind = payload_kind;
            class_payload_allocated = true;
        }
        if (inline_layout) |layout| {
            class_payload = inlineClassPayloadPtr(self, layout);
            class_payload_kind = .none;
        }
        var reserved_class_payload_finalizer_slot = false;
        errdefer if (reserved_class_payload_finalizer_slot) rt.releaseDeferredClassPayloadFinalizerSlot();
        if (class_record) |record| {
            if (record.payload_finalizer != null and record.inline_payload_size == 0) {
                try rt.reserveDeferredClassPayloadFinalizerSlot();
                reserved_class_payload_finalizer_slot = true;
            }
        }
        markObjectAsPrototype(rt, prototype);
        const has_exotic_methods = classHasExoticMethods(rt, class_id, class_record);
        const initial_storage: ObjectStorage = switch (class_id) {
            class.ids.bytecode_function,
            class.ids.generator_function,
            class.ids.async_function,
            class.ids.async_generator_function,
            => .{ .bytecode_function = .{} },
            // A null first word is simultaneously qjs's empty array pointer and
            // the no-payload sentinel. Counts/length stay zero in the remaining
            // words; Array.prototype may later use the pointer word for its
            // cold realm metadata while remaining non-dense.
            class.ids.array, class.ids.arguments, class.ids.mapped_arguments => ObjectStorage.initPayload(null),
            class.ids.regexp => .{ .regexp = .{} },
            else => ObjectStorage.initPayload(class_payload),
        };
        self.* = .{
            .header = .{},
            .class_id = class_id,
            .u = initial_storage,
            .flags = .{
                .class_payload_kind = class_payload_kind,
                .reserved_class_payload_finalizer_slot = reserved_class_payload_finalizer_slot,
                .has_exotic_methods = has_exotic_methods,
            },
            .shape_ref = shape_ref,
            .prop_values = if (property_capacity == 0) @ptrFromInt(@alignOf(property.Entry)) else property_storage.ptr,
        };
        if (property_template) |template| {
            const props = template.shape_ref.props();
            for (template.entries, 0..) |entry, index| {
                const entry_flags = property.Flags.fromBits(props[index].flags);
                self.prop_values[index] = .{ .slot = entry.slot.dup(entry_flags) };
            }
        }
        if (inline_layout != null) self.initInlineClassPayloadGcPrefix();
        property_storage_owned = false;
        reserved_class_payload_finalizer_slot = false;
        shape_owned = false;
        // The object now owns the payload (stored in `u.payload` +
        // `class_payload_kind`): from here `destroyFromHeader` (the
        // `initialized` errdefer) is the sole teardown owner, so drop the
        // pre-init single-payload free to avoid a double free.
        class_payload_allocated = false;
        initialized = true;
        // Reuse the inline-layout size computed at the top of createInternal
        // instead of recomputing it inside registerObject (mirror of the free
        // path's unregisterObjectWithBytes). Same value allocationSize derives.
        try rt.registerObjectWithBytes(self, alloc_size);
        if (self.isWeakReferenceHolderClass()) rt.registerWeakReferenceHolder(self);
        initialized = false;
        return self;
    }

    /// True iff `payload_kind` names a class whose object carries a separately
    /// heap-allocated payload behind `u.payload`. The plain-object hot kinds
    /// (`.none` fast array, `.ordinary`, `.realm`) return false and skip
    /// `allocClassPayload` entirely.
    inline fn payloadKindAllocates(payload_kind: class.PayloadKind) bool {
        return switch (payload_kind) {
            .none, .ordinary, .realm => false,
            else => true,
        };
    }

    /// Out-of-line allocator dedicated to the mutually exclusive function
    /// payload. Keeping it separate from `allocClassPayload` prevents the
    /// function arm from inflating that helper and preserves a compact native
    /// versus bytecode initialization branch.
    noinline fn allocFunctionPayload(rt: *JSRuntime) !class.Payload {
        // QJS's native/bytecode function union is part of the one JSObject
        // allocation, so it cannot independently request a threshold GC. ZJS
        // still allocates this compact payload out of line, but the next object
        // allocation observes its accounted bytes. Keep the all-allocation
        // callback contract intact for tests and force-GC diagnostics.
        const payload = if (comptime builtin.is_test or memory_mod.force_gc_on_allocation_enabled)
            try rt.createRuntime(FunctionPayload)
        else
            try rt.memory.createNoTrigger(FunctionPayload);
        payload.* = FunctionPayload.initNative();
        return @ptrCast(payload);
    }

    /// Out-of-line allocator for the remaining class-payload kinds. Kept
    /// `noinline` so their combined stack usage does NOT inflate
    /// `createInternal`'s frame on the payload-free hot path. Each arm mirrors
    /// the former inline switch: one `createRuntime(T)` then zero-init. On the
    /// error return the payload is unallocated, so the caller's
    /// `class_payload_allocated` stays false.
    noinline fn allocClassPayload(rt: *JSRuntime, payload_kind: class.PayloadKind) !class.Payload {
        switch (payload_kind) {
            .iterator => {
                const payload = try rt.createRuntime(IteratorPayload);
                payload.* = .{};
                return @ptrCast(payload);
            },
            .collection => {
                const payload = try rt.createRuntime(CollectionPayload);
                payload.* = .{};
                return @ptrCast(payload);
            },
            .buffer => {
                const payload = try rt.createRuntime(BufferPayload);
                payload.* = .{};
                return @ptrCast(payload);
            },
            .typed_array => {
                const payload = try rt.createRuntime(TypedArrayPayload);
                payload.* = .{};
                return @ptrCast(payload);
            },
            .regexp => {
                const payload = try rt.createRuntime(RegExpPayload);
                payload.* = .{};
                return @ptrCast(payload);
            },
            .bound_function => {
                const payload = try rt.createRuntime(BoundFunctionPayload);
                payload.* = .{};
                return @ptrCast(payload);
            },
            .proxy => {
                const payload = try rt.createRuntime(ProxyPayload);
                payload.* = .{};
                return @ptrCast(payload);
            },
            .arguments => {
                const payload = try rt.createRuntime(ArgumentsPayload);
                payload.* = .{};
                return @ptrCast(payload);
            },
            .object_data => {
                const payload = try rt.createRuntime(ObjectDataPayload);
                payload.* = .{};
                return @ptrCast(payload);
            },
            .weak_ref => {
                const payload = try rt.createRuntime(WeakRefPayload);
                payload.* = .{};
                return @ptrCast(payload);
            },
            .var_ref => {
                const payload = try rt.createRuntime(VarRefPayload);
                payload.* = .{};
                return @ptrCast(payload);
            },
            .promise => {
                const payload = try rt.createRuntime(PromisePayload);
                payload.* = .{};
                return @ptrCast(payload);
            },
            .generator => {
                const payload = try rt.createRuntime(GeneratorPayload);
                payload.* = .{};
                errdefer rt.memory.destroy(GeneratorPayload, payload);
                const execution = try rt.createRuntime(GeneratorExecutionState);
                execution.* = .{};
                payload.execution = execution;
                return @ptrCast(payload);
            },
            .function => unreachable,
            .module_namespace => {
                const payload = try rt.createRuntime(ModuleNamespacePayload);
                payload.* = .{};
                return @ptrCast(payload);
            },
            .finalization_registry => {
                const payload = try rt.createRuntime(FinalizationRegistryPayload);
                payload.* = .{};
                return @ptrCast(payload);
            },
            .std_file => {
                const payload = try rt.createRuntime(StdFilePayload);
                payload.* = .{};
                return @ptrCast(payload);
            },
            .disposable_stack => {
                const payload = try rt.createRuntime(DisposableStackPayload);
                payload.* = .{};
                return @ptrCast(payload);
            },
            .none, .ordinary, .realm => unreachable,
        }
    }

    /// Free a payload allocated by `allocClassPayload` when `createInternal`
    /// fails before the object is `initialized` (i.e. before `destroyFromHeader`
    /// owns teardown). Mirrors the per-arm `errdefer rt.memory.destroy(T, ...)`
    /// of the former inline switch — a single by-kind `destroy`.
    noinline fn freeClassPayloadAllocation(rt: *JSRuntime, payload: class.Payload, payload_kind: class.PayloadKind) void {
        const ptr = payload orelse return;
        switch (payload_kind) {
            .iterator => rt.memory.destroy(IteratorPayload, @ptrCast(@alignCast(ptr))),
            .collection => rt.memory.destroy(CollectionPayload, @ptrCast(@alignCast(ptr))),
            .buffer => rt.memory.destroy(BufferPayload, @ptrCast(@alignCast(ptr))),
            .typed_array => rt.memory.destroy(TypedArrayPayload, @ptrCast(@alignCast(ptr))),
            .regexp => rt.memory.destroy(RegExpPayload, @ptrCast(@alignCast(ptr))),
            .bound_function => rt.memory.destroy(BoundFunctionPayload, @ptrCast(@alignCast(ptr))),
            .proxy => rt.memory.destroy(ProxyPayload, @ptrCast(@alignCast(ptr))),
            .arguments => rt.memory.destroy(ArgumentsPayload, @ptrCast(@alignCast(ptr))),
            .object_data => rt.memory.destroy(ObjectDataPayload, @ptrCast(@alignCast(ptr))),
            .weak_ref => rt.memory.destroy(WeakRefPayload, @ptrCast(@alignCast(ptr))),
            .var_ref => rt.memory.destroy(VarRefPayload, @ptrCast(@alignCast(ptr))),
            .promise => rt.memory.destroy(PromisePayload, @ptrCast(@alignCast(ptr))),
            .generator => {
                const typed: *GeneratorPayload = @ptrCast(@alignCast(ptr));
                typed.destroy(rt);
                rt.memory.destroy(GeneratorPayload, typed);
            },
            .function => rt.memory.destroy(FunctionPayload, @ptrCast(@alignCast(ptr))),
            .module_namespace => rt.memory.destroy(ModuleNamespacePayload, @ptrCast(@alignCast(ptr))),
            .finalization_registry => rt.memory.destroy(FinalizationRegistryPayload, @ptrCast(@alignCast(ptr))),
            .std_file => rt.memory.destroy(StdFilePayload, @ptrCast(@alignCast(ptr))),
            .disposable_stack => rt.memory.destroy(DisposableStackPayload, @ptrCast(@alignCast(ptr))),
            .none, .ordinary, .realm => {},
        }
    }

    const InlineClassPayloadLayout = struct {
        object_offset: usize,
        payload_offset: usize,
        object_size: usize,
        allocation_size: usize,
        allocation_alignment: std.mem.Alignment,
    };

    fn inlineClassPayloadLayout(maybe_record: ?*const class.Record) ?InlineClassPayloadLayout {
        const record = maybe_record orelse return null;
        if (record.inline_payload_size == 0) return null;
        const payload_align = std.mem.Alignment.fromByteUnits(record.inline_payload_align);
        const object_align = std.mem.Alignment.of(Object);
        const allocation_alignment = if (payload_align.compare(.gt, object_align)) payload_align else object_align;
        const object_offset = std.mem.alignForward(usize, 8, allocation_alignment.toByteUnits());
        const payload_offset = std.mem.alignForward(usize, @sizeOf(Object), payload_align.toByteUnits());
        const object_size = std.math.add(usize, payload_offset, record.inline_payload_size) catch return null;
        const allocation_size = std.math.add(usize, object_offset, object_size) catch return null;
        return .{
            .object_offset = object_offset,
            .payload_offset = payload_offset,
            .object_size = object_size,
            .allocation_size = allocation_size,
            .allocation_alignment = allocation_alignment,
        };
    }

    fn initInlineClassPayloadGcPrefix(self: *Object) void {
        const meta: [*]u8 = @ptrFromInt(@intFromPtr(self) - 8);
        @memset(meta[0..8], 0);
        meta[2] = Object.gc_kind_tag;
        meta[4] = 1;
    }

    fn inlineClassPayloadPtr(self: *Object, layout: InlineClassPayloadLayout) *anyopaque {
        const bytes: [*]u8 = @ptrCast(self);
        return @ptrCast(bytes + layout.payload_offset);
    }

    fn freeObjectAllocation(rt: *JSRuntime, self: *Object, inline_layout: ?InlineClassPayloadLayout) void {
        if (inline_layout) |layout| {
            const bytes: [*]u8 = @ptrFromInt(@intFromPtr(self) - layout.object_offset);
            rt.memory.freeAlignedBytes(bytes[0..layout.allocation_size], layout.allocation_alignment);
            return;
        }
        rt.memory.destroy(Object, self);
    }

    pub fn allocationSize(self: *const Object, rt: *const JSRuntime) usize {
        if (inlineClassPayloadLayout(rt.classes.recordPtr(self.class_id))) |layout| return layout.object_size;
        return @sizeOf(Object);
    }

    pub fn createArray(rt: *JSRuntime, prototype: ?*Object) !*Object {
        const self = try create(rt, class.ids.array, prototype);
        self.flags.fast_array = true;
        return self;
    }

    pub fn createArrayWithOwnPropertyCapacity(rt: *JSRuntime, prototype: ?*Object, capacity: usize) !*Object {
        const self = try createWithOwnPropertyCapacity(rt, class.ids.array, prototype, capacity);
        self.flags.fast_array = true;
        return self;
    }

    pub fn value(self: *Object) JSValue {
        return JSValue.object(&self.header);
    }

    pub fn cachedIteratorNextSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        if (self.cachedIteratorNextSlotIfPresent(rt)) |slot| return slot;
        const len = rt.cached_iterator_next_entries.len;
        if (len == rt.cached_iterator_next_entries_capacity) {
            var next_capacity = if (rt.cached_iterator_next_entries_capacity == 0) @as(usize, 4) else rt.cached_iterator_next_entries_capacity * 2;
            while (next_capacity < len + 1) : (next_capacity *= 2) {}
            const next = try rt.allocRuntime(runtime_mod.CachedIteratorNextEntry, next_capacity);
            errdefer rt.memory.free(runtime_mod.CachedIteratorNextEntry, next);
            @memcpy(next[0..len], rt.cached_iterator_next_entries);
            const old_capacity = rt.cached_iterator_next_entries_capacity;
            const old_entries: []runtime_mod.CachedIteratorNextEntry = if (old_capacity != 0) rt.cached_iterator_next_entries.ptr[0..old_capacity] else rt.cached_iterator_next_entries[0..0];
            rt.cached_iterator_next_entries = next[0..len];
            rt.cached_iterator_next_entries_capacity = next_capacity;
            if (old_capacity != 0) rt.memory.free(runtime_mod.CachedIteratorNextEntry, old_entries);
        }
        rt.cached_iterator_next_entries = rt.cached_iterator_next_entries.ptr[0 .. len + 1];
        rt.cached_iterator_next_entries[len] = .{ .object = self };
        return &rt.cached_iterator_next_entries[len].value;
    }

    pub fn cachedIteratorNext(self: *const Object, rt: *JSRuntime) ?JSValue {
        const slot = self.cachedIteratorNextSlotIfPresent(rt) orelse return null;
        return slot.*;
    }

    pub fn clearCachedIteratorNext(self: *Object, rt: *JSRuntime) void {
        const index = cachedIteratorNextEntryIndex(rt, self) orelse return;
        const old_cached = rt.cached_iterator_next_entries[index].value;
        rt.cached_iterator_next_entries[index].value = null;
        removeCachedIteratorNextEntryAt(rt, index);
        if (old_cached) |stored| stored.free(rt);
    }

    fn clearCachedIteratorNextWithoutFree(rt: *JSRuntime, self: *Object) void {
        const index = cachedIteratorNextEntryIndex(rt, self) orelse return;
        rt.cached_iterator_next_entries[index].value = null;
        removeCachedIteratorNextEntryAt(rt, index);
    }

    fn cachedIteratorNextSlotIfPresent(self: *const Object, rt: *JSRuntime) ?*?JSValue {
        const index = cachedIteratorNextEntryIndex(rt, self) orelse return null;
        return &rt.cached_iterator_next_entries[index].value;
    }

    fn cachedIteratorNextEntryIndex(rt: *const JSRuntime, self: *const Object) ?usize {
        for (rt.cached_iterator_next_entries, 0..) |entry, index| {
            if (entry.object == self) return index;
        }
        return null;
    }

    fn removeCachedIteratorNextEntryAt(rt: *JSRuntime, index: usize) void {
        const last_index = rt.cached_iterator_next_entries.len - 1;
        if (index != last_index) rt.cached_iterator_next_entries[index] = rt.cached_iterator_next_entries[last_index];
        rt.cached_iterator_next_entries = rt.cached_iterator_next_entries.ptr[0..last_index];
    }

    pub fn ensureSharedLazyNativeFunctionCache(self: *Object, rt: *JSRuntime) !void {
        const payload = try self.ensureRealmPayload(rt);
        if (payload.shared_lazy_native_functions != null) return;
        const cache = try rt.createRuntime([runtime_mod.shared_lazy_native_function_slots]?JSValue);
        cache.* = @splat(null);
        payload.shared_lazy_native_functions = cache;
    }

    pub fn ensureOrdinaryPayload(self: *Object, rt: *JSRuntime) !*OrdinaryPayload {
        if (self.ordinaryPayload()) |payload| return payload;
        std.debug.assert(self.u.payload == null);
        const payload = try rt.createRuntime(OrdinaryPayload);
        payload.* = .{};
        self.u.payload = @ptrCast(payload);
        self.flags.class_payload_kind = .ordinary;
        return payload;
    }

    pub fn globalLexicals(self: *const Object) ?*Object {
        return if (self.realmPayloadConst()) |payload| payload.global_lexicals else null;
    }

    pub fn setGlobalLexicals(self: *Object, rt: *JSRuntime, v: ?*Object) !void {
        (try self.ensureRealmPayload(rt)).global_lexicals = v;
    }

    // qjs u.global_object.uninitialized_vars accessors (quickjs.c:17069).
    pub fn globalUninitializedVars(self: *const Object) ?*Object {
        return if (self.realmPayloadConst()) |payload| payload.uninitialized_vars else null;
    }

    pub fn setGlobalUninitializedVars(self: *Object, rt: *JSRuntime, v: ?*Object) !void {
        (try self.ensureRealmPayload(rt)).uninitialized_vars = v;
    }

    pub fn ensureRealmPayload(self: *Object, rt: *JSRuntime) !*RealmPayload {
        if (self.realmPayload()) |payload| return payload;
        const payload = try rt.createRuntime(RealmPayload);
        payload.* = .{};
        self.u.payload = @ptrCast(payload);
        self.flags.class_payload_kind = .realm;
        return payload;
    }

    const bytecode_function_aux_tag: usize = 1;

    inline fn bytecodeFunctionAux(self: *Object) ?*BytecodeFunctionAux {
        if (!class.isBytecodeFunctionClass(self.class_id)) return null;
        const stored = self.u.bytecode_function.home_or_aux orelse return null;
        const raw = @intFromPtr(stored);
        if ((raw & bytecode_function_aux_tag) == 0) return null;
        return @ptrFromInt(raw & ~bytecode_function_aux_tag);
    }

    inline fn bytecodeFunctionAuxConst(self: *const Object) ?*const BytecodeFunctionAux {
        if (!class.isBytecodeFunctionClass(self.class_id)) return null;
        const stored = self.u.bytecode_function.home_or_aux orelse return null;
        const raw = @intFromPtr(stored);
        if ((raw & bytecode_function_aux_tag) == 0) return null;
        return @ptrFromInt(raw & ~bytecode_function_aux_tag);
    }

    inline fn encodeBytecodeFunctionAux(aux: *BytecodeFunctionAux) *anyopaque {
        return @ptrFromInt(@intFromPtr(aux) | bytecode_function_aux_tag);
    }

    fn ensureFunctionRarePayload(self: *Object, rt: *JSRuntime) !*FunctionRarePayload {
        if (class.isBytecodeFunctionClass(self.class_id)) {
            if (self.bytecodeFunctionAux()) |aux| return &aux.rare;
            const aux = try rt.createRuntime(BytecodeFunctionAux);
            aux.* = .{};
            if (self.u.bytecode_function.home_or_aux) |stored| {
                std.debug.assert((@intFromPtr(stored) & bytecode_function_aux_tag) == 0);
                aux.home_object = @ptrCast(@alignCast(stored));
            }
            self.u.bytecode_function.home_or_aux = encodeBytecodeFunctionAux(aux);
            return &aux.rare;
        }
        const payload = self.functionPayload() orelse {
            std.debug.assert(self.flags.class_payload_kind == .function);
            return error.TypeError;
        };
        if (payload.rare) |rare| return rare;
        const rare = try rt.createRuntime(FunctionRarePayload);
        rare.* = .{};
        payload.rare = rare;
        return rare;
    }

    fn functionRarePayload(self: *Object) ?*FunctionRarePayload {
        if (self.bytecodeFunctionAux()) |aux| return &aux.rare;
        const payload = self.functionPayload() orelse return null;
        return payload.rare;
    }

    fn functionRarePayloadConst(self: *const Object) ?*const FunctionRarePayload {
        if (self.bytecodeFunctionAuxConst()) |aux| return &aux.rare;
        const payload = self.functionPayloadConst() orelse return null;
        return payload.rare;
    }

    pub fn installExternalClassPayload(self: *Object, payload: *anyopaque) void {
        std.debug.assert(self.u.payload == null);
        self.u.payload = payload;
        self.flags.class_payload_kind = .none;
    }

    pub fn externalClassPayload(self: *Object) ?*anyopaque {
        // A dense-element object's `u` holds `array_values`, not a payload;
        // only an object with kind==.none and no dense storage can carry an
        // external payload pointer.
        if (self.isArray() or self.flags.fast_array or self.class_id == class.ids.mapped_arguments or self.flags.class_payload_kind != .none) return null;
        return self.u.payload;
    }

    pub fn externalClassPayloadConst(self: *const Object) ?*anyopaque {
        if (self.isArray() or self.flags.fast_array or self.class_id == class.ids.mapped_arguments or self.flags.class_payload_kind != .none) return null;
        return self.u.payload;
    }

    pub fn cachedFunctionProtoSlot(self: *Object, rt: *JSRuntime) !*?*Object {
        const payload = try self.ensureRealmPayload(rt);
        return &payload.cached_function_proto;
    }

    pub fn setCachedFunctionProto(self: *Object, rt: *JSRuntime, prototype: ?*Object) !void {
        const payload = try self.ensureRealmPayload(rt);
        if (prototype) |stored| gc.retain(&stored.header);
        errdefer if (prototype) |stored| stored.value().free(rt);
        const old_prototype = payload.cached_function_proto;
        payload.cached_function_proto = prototype;
        if (old_prototype) |old| old.value().free(rt);
    }

    pub fn cachedFunctionProto(self: *const Object) ?*Object {
        if (self.realmPayloadConst()) |payload| return payload.cached_function_proto;
        return null;
    }

    pub fn cachedPromiseProtoSlot(self: *Object, rt: *JSRuntime) !*?*Object {
        const payload = try self.ensureRealmPayload(rt);
        return &payload.cached_promise_proto;
    }

    pub fn setCachedPromiseProto(self: *Object, rt: *JSRuntime, prototype: ?*Object) !void {
        const payload = try self.ensureRealmPayload(rt);
        if (prototype) |stored| gc.retain(&stored.header);
        errdefer if (prototype) |stored| stored.value().free(rt);
        const old_prototype = payload.cached_promise_proto;
        payload.cached_promise_proto = prototype;
        if (old_prototype) |old| old.value().free(rt);
    }

    pub fn cachedPromiseProto(self: *const Object) ?*Object {
        if (self.realmPayloadConst()) |payload| return payload.cached_promise_proto;
        return null;
    }

    pub fn cachedRealmValueSlot(self: *Object, rt: *JSRuntime, slot: RealmValueSlot) !*?JSValue {
        const payload = try self.ensureRealmPayload(rt);
        return &payload.cached_values[@intFromEnum(slot)];
    }

    pub fn cachedRealmValue(self: *const Object, slot: RealmValueSlot) ?JSValue {
        if (self.realmPayloadConst()) |payload| return payload.cached_values[@intFromEnum(slot)];
        return null;
    }

    pub fn cachedThrowTypeErrorIntrinsicSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        return self.cachedRealmValueSlot(rt, .throw_type_error_intrinsic);
    }

    pub fn cachedThrowTypeErrorIntrinsic(self: *const Object) ?JSValue {
        return self.cachedRealmValue(.throw_type_error_intrinsic);
    }

    fn sharedLazyNativeFunctionSlot(self: *Object, slot: u8) ?*?JSValue {
        if (slot == 0 or slot > runtime_mod.shared_lazy_native_function_slots) return null;
        const payload = self.realmPayload() orelse return null;
        const cache = payload.shared_lazy_native_functions orelse return null;
        return &cache[slot - 1];
    }

    pub fn closeStdFile(self: *Object) void {
        _ = self.closeStdFileWithResult();
    }

    pub fn closeStdFileWithResult(self: *Object) c_int {
        const payload = self.stdFilePayload() orelse return 0;
        const file = payload.file orelse return 0;
        if (payload.is_stdio) return 0;
        payload.file = null;
        return closeStdFileHandle(file, payload.is_popen);
    }

    fn enqueueDeferredStdFileClose(self: *Object, rt: *JSRuntime) void {
        const payload = self.stdFilePayload() orelse return;
        const file = payload.file orelse return;
        if (payload.is_stdio) return;
        payload.file = null;

        const job = rt.createRuntime(DeferredStdFileClose) catch {
            _ = closeStdFileHandle(file, payload.is_popen);
            return;
        };
        job.* = .{
            .runtime = rt,
            .file = file,
            .is_popen = payload.is_popen,
        };
        rt.enqueueDeferredNativeCleanup(DeferredStdFileClose.run, @ptrCast(job)) catch {
            _ = closeStdFileHandle(file, payload.is_popen);
            rt.memory.destroy(DeferredStdFileClose, job);
        };
    }

    pub fn destroyFromHeader(rt: *JSRuntime, header: *gc.Header) void {
        const self: *Object = @alignCast(@fieldParentPtr("header", header));
        // qjs marks an object "about to be freed" before its zero-refcount free
        // runs (`js_rc(p)->mark = 1`, __JS_FreeValueRT quickjs.c:6479), and
        // js_weakref_free tests that mark (quickjs.c:51728-51735) so releasing
        // the LAST weak reference to an object whose own teardown is in
        // progress (a FinalizationRegistry registered as its own target /
        // unregister token, or two dead registries weakly cross-registered)
        // does NOT free the struct out from under free_object. The husk branch
        // below resets the mark (mirror of quickjs.c:6389) so a later weak
        // release can reclaim the kept struct. Without setting the mark here,
        // `releaseWeakIdentity` could reentrantly `destroyDeadWeakHusk` this
        // object mid-teardown — a double free corrupting the slab free list.
        header.meta().flags.mark = true;
        // Single pointer-only class-record view (qjs reads class_array[class_id]
        // in place, quickjs.c:6365). Reused for BOTH the inline-payload layout and
        // the inline-payload finalize below, so the plain-object free path does
        // ONE bounds-checked pointer fetch instead of a `recordPtr` here plus a
        // second by-value 88B `record()` copy inside finalizeInlineClassPayload.
        const class_record = rt.classes.recordPtr(self.class_id);
        const inline_layout = inlineClassPayloadLayout(class_record);
        // Size for GC free-accounting is the same value `allocationSize` derives
        // from `inline_layout` (object_size for inline-payload classes, else
        // @sizeOf(Object)) — reuse the layout we just computed instead of a second
        // record-table lookup + inline-layout recompute inside unregisterObject.
        const alloc_size = if (inline_layout) |layout| layout.object_size else @sizeOf(Object);
        rt.unregisterObjectWithBytes(self, alloc_size);
        // qjs free_object keeps no borrowed-ref / std-file side tables, so the
        // plain-object hot free path must not call into either scan. Hoist each
        // helper's own entry guard to the call site: an object with no realm-
        // global borrowed identity (is_global, false for ~every object) and no
        // .std_file payload skips BOTH calls — the helpers keep their internal
        // guards for the rare live-resource path. (borrowed guard already no-ops
        // for non-global; pure dispatch-shape change, zero behavioral risk.)
        if (self.isGlobal() and rt.borrowed_reference_holders.len != 0) clearBorrowedReferencesForDestroyedObject(rt, self);
        if (self.flags.class_payload_kind == .std_file) self.enqueueDeferredStdFileClose(rt);
        // `inline_layout != null` is exactly `record.hasInlinePayload()`
        // (inlineClassPayloadLayout returns null iff inline_payload_size == 0), so
        // the plain-object hot path (no inline payload) skips the finalize helper —
        // and its record re-lookup — and takes the deferred-finalizer arm directly.
        if (inline_layout == null or !self.finalizeInlineClassPayload(rt, class_record.?)) self.enqueueClassPayloadFinalizer(rt);
        const old_properties = self.propertyEntries();
        const old_property_capacity = self.propertyStorageCapacity();
        const old_shape_props = self.shape_ref.props()[0..@min(self.shape_ref.prop_count, old_properties.len)];
        self.prop_values = @ptrFromInt(@alignOf(property.Entry));
        for (old_properties, 0..) |entry, index| {
            const entry_atom = if (index < old_shape_props.len) old_shape_props[index].atom_id else atom.null_atom;
            const entry_flags = if (index < old_shape_props.len) property.Flags.fromBits(old_shape_props[index].flags) else property.Flags{};
            destroyPropertySlot(rt, entry_atom, entry_flags, entry.slot);
        }
        if (old_property_capacity != 0) rt.memory.free(property.Entry, old_properties.ptr[0..old_property_capacity]);
        // Array elements live in the `u.array_values` union arm (gated by
        // `is_array`), orthogonal to the class-payload arm below.
        self.destroyArrayElements(rt);
        // The non-array class payloads all share the single `u.payload`
        // union slot, discriminated by `class_payload_kind` — at most ONE is
        // ever live per object. qjs frees the class-specific payload with a
        // SINGLE table lookup (`class_array[class_id].finalizer`,
        // quickjs.c:6365); mirror that with one switch on the discriminant
        // instead of walking 19 mutually-exclusive `if (kind != .X) return`
        // destroyers in sequence (LLVM re-materializes each as
        // ldrb+and+cmp+b.ne — ~76 insn of dead dispatch for a plain object).
        // Each arm's destroyer keeps its own `kind != .X` guard, so this is a
        // pure dispatch-shape change with identical per-object semantics.
        switch (self.flags.class_payload_kind) {
            .none => {},
            .ordinary => self.destroyOrdinaryPayload(rt),
            .arguments => self.destroyArgumentsPayload(rt),
            .object_data => self.destroyObjectDataPayload(rt),
            .weak_ref => self.destroyWeakRefPayload(rt),
            .function => self.destroyFunctionPayload(rt),
            .bound_function => self.destroyBoundFunctionPayload(rt),
            .var_ref => self.destroyVarRefPayload(rt),
            .generator => self.destroyGeneratorPayload(rt),
            .promise => self.destroyPromisePayload(rt),
            .proxy => self.destroyProxyPayload(rt),
            .regexp => self.destroyRegExpPayload(rt),
            .iterator => self.destroyIteratorPayload(rt),
            .collection => self.destroyCollectionPayload(rt),
            .buffer => self.destroyBufferPayload(rt),
            .typed_array => self.destroyTypedArrayPayload(rt),
            .module_namespace => self.destroyModuleNamespacePayload(rt),
            .finalization_registry => self.destroyFinalizationRegistryPayload(rt),
            .std_file => self.destroyStdFilePayload(rt),
            .disposable_stack => self.destroyDisposableStackPayload(rt),
            .realm => self.destroyRealmPayload(rt),
        }
        if (rt.gc.phase != .deinit) self.clearCachedIteratorNext(rt) else clearCachedIteratorNextWithoutFree(rt, self);
        const object_shape = self.shape_ref;
        if (!(rt.gc.phase == .remove_cycles and headerIsCycleGarbage(&object_shape.header))) {
            rt.shapes.release(object_shape);
        }
        // Cycle removal and runtime deinit both use a resource pass followed by
        // a struct-free pass: a not-yet-processed sibling (or a held Shape)
        // may still decref and therefore dereference this header. Defer the
        // allocation free until that resource pass completes (qjs free_object,
        // quickjs.c:6382).
        if (rt.gc.phase == .remove_cycles or rt.gc.phase == .deinit) {
            rt.gc.deferCycleStructFree(&self.header);
            return;
        }
        // Outside cycle removal, zero-ref destruction may need to leave the
        // resource-stripped object as a weak husk. During REMOVE_CYCLES the
        // restored refcount must remain intact until every condemned incoming
        // edge has been released; Pass B below makes the keep/free decision,
        // exactly like qjs free_object + gc_free_cycles.
        if (self.weakref_count != 0) {
            self.header.meta().rc = 0;
            self.header.meta().flags.mark = false;
            return;
        }
        // qjs releases the weak-id mapping in its weak sweep, never per plain
        // object; only objects handed a weak id (has_weak_id) have an entry, so
        // gate the call — a plain object never enters takeWeakObjectIdentity just
        // to load the flag and return.
        if (self.header.meta().flags.has_weak_id) _ = rt.takeWeakObjectIdentity(self);
        freeObjectAllocation(rt, self, inline_layout);
    }

    /// Pass-B drain of a cycle-deferred object: its resources were freed by the
    /// resource pass; only the struct memory remains. Mirrors qjs Pass B
    /// (quickjs.c:6797). Pass B filters retained weak husks before calling this.
    pub fn freeCycleDeferredStruct(rt: *JSRuntime, self: *Object) void {
        const inline_layout = inlineClassPayloadLayout(rt.classes.recordPtr(self.class_id));
        _ = rt.takeWeakObjectIdentity(self);
        freeObjectAllocation(rt, self, inline_layout);
    }

    pub fn destroyDeadWeakHusk(rt: *JSRuntime, self: *Object) void {
        std.debug.assert(self.header.meta().rc == 0);
        std.debug.assert(self.weakref_count == 0);
        std.debug.assert(!self.header.meta().flags.mark);
        const inline_layout = inlineClassPayloadLayout(rt.classes.recordPtr(self.class_id));
        _ = rt.takeWeakObjectIdentity(self);
        freeObjectAllocation(rt, self, inline_layout);
    }

    /// Precondition: `record.hasInlinePayload()` — the caller
    /// (`destroyFromHeader`) only enters this when the already-computed
    /// `inline_layout` is non-null, which is exactly that predicate. `record` is
    /// the pointer view fetched once at the top of the free path, so this no
    /// longer re-looks-up the class table (nor makes the by-value 88B `Record`
    /// copy the old `rt.classes.record(...)` did on every object free).
    fn finalizeInlineClassPayload(self: *Object, rt: *JSRuntime, record: *const class.Record) bool {
        const finalizer = record.payload_finalizer orelse {
            self.u.payload = null;
            self.flags.class_payload_kind = .none;
            return true;
        };
        finalizer(@ptrCast(rt), @ptrCast(self), &self.u.payload);
        self.u.payload = null;
        self.flags.class_payload_kind = .none;
        return true;
    }

    fn enqueueClassPayloadFinalizer(self: *Object, rt: *JSRuntime) void {
        if (!self.flags.reserved_class_payload_finalizer_slot) return;
        const payload = self.u.payload;
        const payload_kind = self.flags.class_payload_kind;
        const object_identity = @intFromPtr(&self.header) & ~@as(usize, 1);
        self.flags.reserved_class_payload_finalizer_slot = false;
        const enqueued = rt.enqueueReservedDeferredClassPayloadFinalizer(self.class_id, payload, payload_kind, object_identity);
        if (!enqueued) return;
        self.u.payload = null;
        self.flags.class_payload_kind = .none;
    }

    fn clearBorrowedReferencesForDestroyedObject(rt: *JSRuntime, destroyed: *Object) void {
        if (rt.gc.phase == .deinit) return;
        // The raw address identity only drives borrowed raw-pointer cleanup
        // such as realm-global pointers. Registered weak identities are kept
        // until the qjs-style weak sweep releases them.
        const destroyed_identity = @intFromPtr(&destroyed.header) & ~@as(usize, 1);
        if (rt.borrowed_reference_holders.len == 0) return;
        if (!destroyed.isGlobal()) return;
        if (rt.borrowedWeakCleanupActive()) {
            if (destroyed.isGlobal()) rt.enqueueBorrowedWeakCleanupRealmIdentity(destroyed_identity);
            if (rt.isCurrentDeferredWeakValueFreeIdentity(destroyed_identity)) return;
            rt.enqueueBorrowedWeakCleanupIdentity(destroyed_identity) catch {
                clearBorrowedReferencesForDestroyedIdentity(rt, destroyed_identity);
            };
            return;
        }

        rt.beginBorrowedWeakCleanup();
        defer rt.endBorrowedWeakCleanup();
        if (destroyed.isGlobal()) rt.enqueueBorrowedWeakCleanupRealmIdentity(destroyed_identity);
        rt.enqueueBorrowedWeakCleanupIdentity(destroyed_identity) catch {
            clearBorrowedReferencesForDestroyedIdentity(rt, destroyed_identity);
        };

        drainBorrowedWeakCleanup(rt);
    }

    pub fn drainBorrowedWeakCleanup(rt: *JSRuntime) void {
        var scanned_identity_count: usize = 0;
        while (scanned_identity_count < rt.borrowedWeakCleanupIdentityCount() or rt.hasDeferredWeakValueFrees()) {
            while (scanned_identity_count < rt.borrowedWeakCleanupIdentityCount()) {
                const pass_end = rt.borrowedWeakCleanupIdentityCount();
                clearBorrowedReferencesForBorrowedWeakCleanup(rt, scanned_identity_count);
                if (rt.takeBorrowedWeakCleanupNeedsRescan()) {
                    scanned_identity_count = pass_end;
                } else {
                    scanned_identity_count = rt.borrowedWeakCleanupIdentityCount();
                }
            }
            rt.drainDeferredWeakValueFrees();
        }
    }

    fn clearBorrowedReferencesForBorrowedWeakCleanup(rt: *JSRuntime, start_index: usize) void {
        clearBorrowedReferencesForMatcher(rt, .{ .runtime_batch = start_index });
    }

    fn clearBorrowedReferencesForDestroyedIdentity(rt: *JSRuntime, destroyed_identity: usize) void {
        clearBorrowedReferencesForMatcher(rt, .{ .single = destroyed_identity });
    }

    fn clearBorrowedReferencesForMatcher(rt: *JSRuntime, matcher: BorrowedIdentityMatcher) void {
        compactBorrowedReferenceHolders(rt);
        var index: usize = 0;
        while (index < rt.borrowed_reference_holders.len) {
            const current = rt.borrowed_reference_holders[index];
            if (current.header.meta().rc == 0) {
                rt.unregisterBorrowedReferenceHolder(current);
                continue;
            }
            if (!current.mayContainBorrowedReferences(rt)) {
                index += 1;
                continue;
            }
            gc.retain(&current.header);
            rt.markBorrowedWeakCleanupHolderSeen();
            current.clearBorrowedReferencesToDestroyedIdentities(rt, matcher);
            if (index < rt.borrowed_reference_holders.len and rt.borrowed_reference_holders[index] == current) {
                current.value().free(rt);
                if (index < rt.borrowed_reference_holders.len and rt.borrowed_reference_holders[index] == current) {
                    index += 1;
                }
                continue;
            }
            const current_index = runtimeBorrowedReferenceHolderIndex(rt, current) orelse {
                current.value().free(rt);
                continue;
            };
            current.value().free(rt);
            if (current_index < rt.borrowed_reference_holders.len and rt.borrowed_reference_holders[current_index] == current) {
                index = current_index + 1;
            } else {
                index = current_index;
            }
        }
    }

    fn compactBorrowedReferenceHolders(rt: *JSRuntime) void {
        var write_index: usize = 0;
        var read_index: usize = 0;
        while (read_index < rt.borrowed_reference_holders.len) : (read_index += 1) {
            const current = rt.borrowed_reference_holders[read_index];
            if (current.header.meta().rc != 0) {
                if (write_index != read_index) rt.borrowed_reference_holders[write_index] = current;
                current.setBorrowedReferenceHolderIndex(write_index);
                write_index += 1;
                continue;
            }
            current.setBorrowedReferenceHolderIndex(null);
            current.flags.is_borrowed_reference_holder = false;
        }
        rt.borrowed_reference_holders = rt.borrowed_reference_holders.ptr[0..write_index];
    }

    fn runtimeBorrowedReferenceHolderIndex(rt: *JSRuntime, object: *Object) ?usize {
        if (!object.flags.is_borrowed_reference_holder) return null;
        if (object.borrowedReferenceHolderIndex()) |cached_index| {
            if (cached_index < rt.borrowed_reference_holders.len and rt.borrowed_reference_holders[cached_index] == object) return cached_index;
        }
        for (rt.borrowed_reference_holders, 0..) |candidate, index| {
            if (candidate == object) {
                object.setBorrowedReferenceHolderIndex(index);
                return index;
            }
        }
        return null;
    }

    fn registerBorrowedHolderForPendingMutation(rt: *JSRuntime, object: *Object) !bool {
        const was_registered = rt.borrowedReferenceHolderRegistered(object);
        try rt.registerBorrowedReferenceHolder(object);
        return !was_registered;
    }

    fn rollbackBorrowedHolderRegistration(rt: *JSRuntime, object: *Object, inserted: bool) void {
        if (inserted) rt.unregisterBorrowedReferenceHolder(object);
    }

    pub fn pruneBorrowedReferenceHolderIfEmpty(self: *Object, rt: *JSRuntime) void {
        if (!self.flags.is_borrowed_reference_holder) return;
        if (!self.hasBorrowedReferences(rt)) rt.unregisterBorrowedReferenceHolder(self);
    }

    fn hasBorrowedReferences(self: *const Object, rt: *JSRuntime) bool {
        if (self.weakRefPayloadConst()) |payload| {
            if (payload.weak_target_identity != null) return true;
        }
        if (self.collectionPayloadConst()) |payload| {
            if (payload.weak_entries.len != 0) return true;
        }
        if (self.finalizationRegistryPayloadConst()) |payload| {
            if (payload.cells.len != 0) return true;
        }
        if (self.borrowedRealmGlobalPtr() != null) return true;
        const scanned = self.shape_ref.prop_count;
        for (self.prop_values[0..scanned], 0..) |entry, index| {
            if (self.propFlagsAt(index).isAutoInit()) {
                const info = property.autoInitAt(rt, entry.slot.auto_init).*;
                if (info.host_function_realm_global != 0) return true;
            }
        }
        return false;
    }

    fn mayContainBorrowedReferences(self: *const Object, rt: *JSRuntime) bool {
        if (self.weakRefPayloadConst()) |payload| {
            if (payload.weak_target_identity != null) return true;
        }
        if (self.collectionPayloadConst()) |payload| {
            if (payload.weak_entries.len != 0) return true;
        }
        if (self.finalizationRegistryPayloadConst()) |payload| {
            if (payload.cells.len != 0) return true;
        }
        if (rt.borrowedWeakCleanupMayMatchRealmIdentity()) {
            if (self.borrowedRealmGlobalPtr()) |realm_global| {
                const identity = @intFromPtr(&realm_global.header) & ~@as(usize, 1);
                if (rt.borrowedWeakCleanupRealmIdentityMatches(identity)) return true;
            }
            const scanned = self.shape_ref.prop_count;
            for (self.prop_values[0..scanned], 0..) |entry, index| {
                if (self.propFlagsAt(index).isAutoInit()) {
                    const info = property.autoInitAt(rt, entry.slot.auto_init).*;
                    if (info.host_function_realm_global != 0 and rt.borrowedWeakCleanupRealmIdentityMatches(info.host_function_realm_global)) return true;
                }
            }
        }
        return false;
    }

    fn sweepCycleGarbageWeakCollectionEntries(rt: *JSRuntime) void {
        rt.gc.beginDecrefPhase();
        defer rt.gc.endDecrefPhase(rt);

        var current = rt.weak_reference_holder_head;
        while (current) |holder| {
            // Destruction is deferred by the DECREF phase, but capture the
            // link first just as qjs list traversal does. Condemned holders
            // are already detached from the live GC partition and will have
            // their complete payload destroyed by the cycle batch.
            const next = holder.weakReferenceHolderNext();
            if (!objectIsCycleGarbage(holder)) {
                if (holder.collectionPayloadConst()) |payload| {
                    if (payload.weak_entries.len != 0) holder.sweepCycleGarbageWeakCollectionEntriesForHolder(rt);
                }
            }
            current = next;
        }
    }

    fn sweepCycleGarbageWeakCollectionEntriesForHolder(self: *Object, rt: *JSRuntime) void {
        const payload = self.collectionPayload() orelse return;
        var read_index: usize = 0;
        var write_index: usize = 0;
        var removed = false;
        while (read_index < payload.weak_entries.len) : (read_index += 1) {
            var entry = payload.weak_entries[read_index];
            if (!weakIdentityReferencesCycleGarbage(rt, entry.key_identity)) {
                if (write_index != read_index) payload.weak_entries[write_index] = entry;
                write_index += 1;
                continue;
            }

            rt.releaseWeakIdentity(entry.key_identity);
            clearValueReferenceToVisited(rt, &entry.value);
            entry.value.free(rt);
            removed = true;
        }
        payload.weak_entries = payload.weak_entries.ptr[0..write_index];
        if (removed) {
            self.clearCollectionIndex(rt);
            self.pruneBorrowedReferenceHolderIfEmpty(rt);
        }
    }

    fn weakIdentityReferencesCycleGarbage(rt: *const JSRuntime, identity: usize) bool {
        if ((identity & 1) != 0) return false;
        const object = rt.liveObjectFromWeakIdentity(identity) orelse return false;
        return objectIsCycleGarbage(object);
    }

    const BorrowedIdentityMatcher = union(enum) {
        single: usize,
        runtime_batch: usize,

        inline fn matches(self: BorrowedIdentityMatcher, rt: *JSRuntime, identity: usize) bool {
            return switch (self) {
                .single => |stored| stored == identity,
                .runtime_batch => |start_index| rt.borrowedWeakCleanupIdentityMatchesSlice(start_index, identity),
            };
        }
    };

    fn clearBorrowedReferencesToDestroyedIdentities(self: *Object, rt: *JSRuntime, matcher: BorrowedIdentityMatcher) void {
        self.clearWeakIdentities(rt, matcher);
        self.clearRealmGlobalPtrs(rt, matcher);
        self.clearAutoInitRealmGlobals(rt, matcher);
        self.pruneBorrowedReferenceHolderIfEmpty(rt);
    }

    fn clearWeakIdentities(self: *Object, rt: *JSRuntime, matcher: BorrowedIdentityMatcher) void {
        if (self.weakRefPayload()) |payload| {
            if (payload.weak_target_identity) |identity| {
                if (matcher.matches(rt, identity)) rt.clearWeakIdentitySlot(&payload.weak_target_identity);
            }
        }

        if (self.collectionPayload()) |payload| {
            const old_len = payload.weak_entries.len;
            var read_index: usize = 0;
            var write_index: usize = 0;
            while (read_index < payload.weak_entries.len) : (read_index += 1) {
                const entry = payload.weak_entries[read_index];
                if (!matcher.matches(rt, entry.key_identity)) {
                    if (write_index != read_index) payload.weak_entries[write_index] = entry;
                    write_index += 1;
                    continue;
                }

                deferWeakEntryValueFree(rt, entry);
            }
            payload.weak_entries = payload.weak_entries.ptr[0..write_index];
            if (write_index != old_len) self.clearCollectionIndex(rt);
        }

        const finalization_payload = self.finalizationRegistryPayload() orelse return;
        var read_index: usize = 0;
        var write_index: usize = 0;
        while (read_index < finalization_payload.cells.len) : (read_index += 1) {
            var cell = finalization_payload.cells[read_index];
            const target_identity = cell.target_identity orelse {
                if (write_index != read_index) finalization_payload.cells[write_index] = cell;
                write_index += 1;
                continue;
            };
            if (!matcher.matches(rt, target_identity)) {
                if (write_index != read_index) finalization_payload.cells[write_index] = cell;
                write_index += 1;
                continue;
            }

            if (cell.isActive()) {
                cell.state = .pending_enqueue;
                enqueueFinalizationCleanup(rt, finalization_payload.cleanup_callback, cell.held_value) catch |err| switch (err) {
                    error.OutOfMemory => {
                        finalization_payload.cells[write_index] = cell;
                        write_index += 1;
                        continue;
                    },
                    error.PayloadMarkFailed => unreachable,
                };
                cell.state = .queued;
            } else if (cell.isPending()) {
                if (write_index != read_index) finalization_payload.cells[write_index] = cell;
                write_index += 1;
                continue;
            }
            cell.destroy(rt);
        }
        finalization_payload.cells = finalization_payload.cells.ptr[0..write_index];
    }

    fn deferWeakEntryValueFree(rt: *JSRuntime, entry: WeakCollectionEntry) void {
        rt.releaseWeakIdentity(entry.key_identity);
        const prepared_identity = prepareBorrowedWeakCleanupForOwnedValue(rt, entry.value);
        rt.enqueueDeferredWeakValueFreeWithPreparedIdentity(entry.value, prepared_identity) catch |err| switch (err) {
            error.OutOfMemory => entry.value.free(rt),
        };
    }

    fn prepareBorrowedWeakCleanupForOwnedValue(rt: *JSRuntime, stored_value: JSValue) ?usize {
        return rt.prepareBorrowedWeakCleanupForLastRefValue(stored_value);
    }

    fn clearRealmGlobalPtrs(self: *Object, rt: *JSRuntime, matcher: BorrowedIdentityMatcher) void {
        if (self.ordinaryPayload()) |payload| clearObjectPtr(&payload.realm_global_ptr, rt, matcher);
        if (self.iteratorPayload()) |payload| clearObjectPtr(&payload.realm_global_ptr, rt, matcher);
        if (self.collectionPayload()) |payload| clearObjectPtr(&payload.realm_global_ptr, rt, matcher);
        if (self.bufferPayload()) |payload| clearObjectPtr(&payload.realm_global_ptr, rt, matcher);
        if (self.typedArrayPayload()) |payload| clearObjectPtr(&payload.realm_global_ptr, rt, matcher);
        if (self.regExpPayload()) |payload| clearObjectPtr(&payload.realm_global_ptr, rt, matcher);
        if (self.boundFunctionPayload()) |payload| clearObjectPtr(&payload.realm_global_ptr, rt, matcher);
        if (self.proxyPayload()) |payload| clearObjectPtr(&payload.realm_global_ptr, rt, matcher);
        if (self.argumentsPayload()) |payload| clearObjectPtr(&payload.realm_global_ptr, rt, matcher);
        if (self.objectDataPayload()) |payload| clearObjectPtr(&payload.realm_global_ptr, rt, matcher);
        if (self.weakRefPayload()) |payload| clearObjectPtr(&payload.realm_global_ptr, rt, matcher);
        if (self.varRefPayload()) |payload| clearObjectPtr(&payload.realm_global_ptr, rt, matcher);
        if (self.finalizationRegistryPayload()) |payload| clearObjectPtr(&payload.realm_global_ptr, rt, matcher);
        if (self.stdFilePayload()) |payload| clearObjectPtr(&payload.realm_global_ptr, rt, matcher);
        if (self.disposableStackPayload()) |payload| clearObjectPtr(&payload.realm_global_ptr, rt, matcher);
        if (self.promisePayload()) |payload| clearObjectPtr(&payload.realm_global_ptr, rt, matcher);
        if (self.generatorPayload()) |payload| clearObjectPtr(&payload.realm_global_ptr, rt, matcher);
        if (self.functionPayload()) |payload| {
            if (!class.isBytecodeFunctionClass(self.class_id)) clearObjectPtr(&payload.native.realm_global_ptr, rt, matcher);
        }
        if (self.moduleNamespacePayload()) |payload| clearObjectPtr(&payload.realm_global_ptr, rt, matcher);
    }

    fn clearObjectPtr(slot: *?*Object, rt: *JSRuntime, matcher: BorrowedIdentityMatcher) void {
        if (slot.*) |stored| {
            const identity = @intFromPtr(&stored.header) & ~@as(usize, 1);
            if (matcher.matches(rt, identity)) slot.* = null;
        }
    }

    fn clearAutoInitRealmGlobals(self: *Object, rt: *JSRuntime, matcher: BorrowedIdentityMatcher) void {
        const scanned = self.shape_ref.prop_count;
        for (self.prop_values[0..scanned], 0..) |*entry, index| {
            if (self.propFlagsAt(index).isAutoInit()) {
                const info = property.autoInitAt(rt, entry.slot.auto_init);
                if (matcher.matches(rt, info.host_function_realm_global)) info.host_function_realm_global = 0;
            }
        }
    }

    pub const post_a_object_size_baseline: usize = 192;
    comptime {
        std.debug.assert(@sizeOf(Object) <= post_a_object_size_baseline / 2);
    }

    pub fn iteratorTargetSlot(self: *Object) *?JSValue {
        if (self.iteratorPayload()) |payload| return &payload.target;
        std.debug.assert(self.flags.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorLengthSlot(self: *Object) *u32 {
        if (self.iteratorPayload()) |payload| return &payload.length;
        std.debug.assert(self.flags.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorLength(self: *const Object) u32 {
        if (self.iteratorPayloadConst()) |payload| return payload.length;
        return 0;
    }

    pub fn setIteratorLength(self: *Object, length: u32) void {
        self.iteratorLengthSlot().* = length;
    }

    pub fn arrayLengthSlot(self: *Object) *u32 {
        std.debug.assert(self.isArray());
        return &self.u.array.length;
    }

    pub fn arrayLength(self: *const Object) u32 {
        return if (self.isArray()) self.u.array.length else 0;
    }

    /// Set the JS-observable `.length` only. Faithful to qjs `set_array_length`
    /// (quickjs.c:9447-9455): growing length above capacity keeps `fast_array`
    /// (the slots `[array_count, length)` simply become holes), it does NOT
    /// drop to sparse and it NEVER touches `array_count`. Callers that must
    /// also shrink the dense extent pair this with `truncateArrayElements`.
    pub fn setArrayLength(self: *Object, length: u32) void {
        std.debug.assert(self.isArray());
        self.u.array.length = length;
    }

    pub fn hasExoticMethods(self: *const Object) bool {
        return self.flags.has_exotic_methods;
    }

    pub inline fn isArray(self: *const Object) bool {
        return self.class_id == class.ids.array;
    }

    inline fn supportsPlainNamedPropertyStorage(self: *const Object) bool {
        if (!self.isArray()) return true;
        // During intrinsic installation %Array.prototype% is a real Array but
        // owns no dense element buffer. Its only class-union pointer is the
        // cold ordinary payload used while standard globals are bootstrapped.
        return !self.flags.fast_array and
            self.flags.class_payload_kind == .ordinary and
            self.u.array.capacity == 0;
    }

    pub inline fn isProxy(self: *const Object) bool {
        return self.class_id == class.ids.proxy;
    }

    /// Global objects are precisely the objects carrying the realm payload.
    /// This removes a duplicate identity bit and mirrors qjs's context-owned
    /// global-object state rather than allowing arbitrary objects to masquerade.
    pub inline fn isGlobal(self: *const Object) bool {
        return self.flags.class_payload_kind == .realm;
    }

    pub inline fn hasNullPrototype(self: *const Object) bool {
        return self.shape_ref.proto == null;
    }

    pub inline fn hasPropertyStorage(self: *const Object) bool {
        return @intFromPtr(self.prop_values) != @alignOf(property.Entry);
    }

    pub inline fn needsSlowPropertyAccess(self: *const Object) bool {
        return classNeedsSlowPropertyAccess(self.class_id, self.flags.has_exotic_methods);
    }

    pub fn exoticMethods(self: *const Object, rt: *const JSRuntime) ?*const ExoticMethods {
        if (!self.flags.has_exotic_methods) return null;
        return exoticMethodsForClassId(self.class_id) orelse blk: {
            const record = rt.classes.record(self.class_id) orelse return null;
            const raw = record.exotic_methods orelse return null;
            break :blk @ptrCast(@alignCast(raw));
        };
    }

    pub fn installClassExoticMethods(rt: *JSRuntime, class_id: class.ClassId, methods: *const ExoticMethods) void {
        if (!builtin.is_test) @compileError("installClassExoticMethods is only available in tests");
        if (class_id < class.ids.init_count) {
            test_standard_exotic_methods[class_id] = methods;
            return;
        }
        if (class_id < rt.classes.records.len) {
            rt.classes.records[class_id].has_exotic = true;
            rt.classes.records[class_id].exotic_methods = @ptrCast(methods);
        }
    }

    pub fn iteratorTarget(self: *const Object) ?JSValue {
        if (self.iteratorPayloadConst()) |payload| return payload.target;
        return null;
    }

    pub fn iteratorDataSlot(self: *Object) *?JSValue {
        if (self.iteratorPayload()) |payload| return &payload.data;
        std.debug.assert(self.flags.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorData(self: *const Object) ?JSValue {
        if (self.iteratorPayloadConst()) |payload| return payload.data;
        return null;
    }

    pub fn iteratorNextSlot(self: *Object) *?JSValue {
        if (self.iteratorPayload()) |payload| return &payload.next;
        std.debug.assert(self.flags.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorNext(self: *const Object) ?JSValue {
        if (self.iteratorPayloadConst()) |payload| return payload.next;
        return null;
    }

    pub fn iteratorCallbackSlot(self: *Object) *?JSValue {
        if (self.iteratorPayload()) |payload| return &payload.callback;
        std.debug.assert(self.flags.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorCallback(self: *const Object) ?JSValue {
        if (self.iteratorPayloadConst()) |payload| return payload.callback;
        return null;
    }

    pub fn iteratorInnerNextSlot(self: *Object) *?JSValue {
        if (self.iteratorPayload()) |payload| return &payload.inner_next;
        std.debug.assert(self.flags.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorInnerNext(self: *const Object) ?JSValue {
        if (self.iteratorPayloadConst()) |payload| return payload.inner_next;
        return null;
    }

    pub fn iteratorZipNextsSlot(self: *Object) *?JSValue {
        if (self.iteratorPayload()) |payload| return &payload.zip_nexts;
        std.debug.assert(self.flags.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorZipNexts(self: *const Object) ?JSValue {
        if (self.iteratorPayloadConst()) |payload| return payload.zip_nexts;
        return null;
    }

    pub fn iteratorZipPadsSlot(self: *Object) *?JSValue {
        if (self.iteratorPayload()) |payload| return &payload.zip_pads;
        std.debug.assert(self.flags.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorZipPads(self: *const Object) ?JSValue {
        if (self.iteratorPayloadConst()) |payload| return payload.zip_pads;
        return null;
    }

    pub fn iteratorZipKeysSlot(self: *Object) *?JSValue {
        if (self.iteratorPayload()) |payload| return &payload.zip_keys;
        std.debug.assert(self.flags.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorZipKeys(self: *const Object) ?JSValue {
        if (self.iteratorPayloadConst()) |payload| return payload.zip_keys;
        return null;
    }

    pub fn iteratorAtomKeysSlot(self: *Object) *[]atom.Atom {
        if (self.iteratorPayload()) |payload| return &payload.atom_keys;
        std.debug.assert(self.flags.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorAtomKeys(self: *const Object) []const atom.Atom {
        if (self.iteratorPayloadConst()) |payload| return payload.atom_keys;
        return &.{};
    }

    pub fn iteratorIndexSlot(self: *Object) *usize {
        if (self.iteratorPayload()) |payload| return &payload.index;
        std.debug.assert(self.flags.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorKindSlot(self: *Object) *u8 {
        if (self.iteratorPayload()) |payload| return &payload.kind;
        std.debug.assert(self.flags.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorZipAliveSlot(self: *Object) *usize {
        if (self.iteratorPayload()) |payload| return &payload.zip_alive;
        std.debug.assert(self.flags.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorZipModeSlot(self: *Object) *u8 {
        if (self.iteratorPayload()) |payload| return &payload.zip_mode;
        std.debug.assert(self.flags.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorZipStateSlot(self: *Object) *u8 {
        if (self.iteratorPayload()) |payload| return &payload.zip_state;
        std.debug.assert(self.flags.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn clearIteratorTarget(self: *Object, rt: *JSRuntime) void {
        const target = self.iteratorTargetSlot();
        const old_target = target.*;
        target.* = null;
        if (old_target) |stored| stored.free(rt);
    }

    pub fn collectionEntriesSlot(self: *Object) *[]CollectionEntry {
        if (self.collectionPayload()) |payload| return &payload.entries;
        std.debug.assert(self.flags.class_payload_kind == .collection);
        unreachable;
    }

    pub fn collectionEntries(self: *const Object) []CollectionEntry {
        if (self.collectionPayloadConst()) |payload| return payload.entries;
        return &.{};
    }

    pub fn collectionEntriesCapacitySlot(self: *Object) *usize {
        if (self.collectionPayload()) |payload| return &payload.entries_capacity;
        std.debug.assert(self.flags.class_payload_kind == .collection);
        unreachable;
    }

    pub fn collectionEntriesCapacity(self: *const Object) usize {
        if (self.collectionPayloadConst()) |payload| return payload.entries_capacity;
        return 0;
    }

    pub fn collectionBucketHeadsSlot(self: *Object) *[]usize {
        if (self.collectionPayload()) |payload| return &payload.bucket_heads;
        std.debug.assert(self.flags.class_payload_kind == .collection);
        unreachable;
    }

    pub fn collectionBucketHeads(self: *const Object) []usize {
        if (self.collectionPayloadConst()) |payload| return payload.bucket_heads;
        return &.{};
    }

    pub fn collectionActiveCountSlot(self: *Object) *usize {
        if (self.collectionPayload()) |payload| return &payload.active_count;
        std.debug.assert(self.flags.class_payload_kind == .collection);
        unreachable;
    }

    pub fn collectionActiveCount(self: *const Object) usize {
        if (self.collectionPayloadConst()) |payload| return payload.active_count;
        return 0;
    }

    pub fn ensureCollectionEntryCapacity(self: *Object, rt: *JSRuntime, min_capacity: usize) !void {
        const entries_slot = self.collectionEntriesSlot();
        const capacity_slot = self.collectionEntriesCapacitySlot();
        if (capacity_slot.* >= min_capacity) return;

        var next_capacity = if (capacity_slot.* != 0) capacity_slot.* else entries_slot.*.len;
        if (next_capacity < 8) next_capacity = 8;
        while (next_capacity < min_capacity) next_capacity *= 2;

        const next = try rt.allocRuntime(CollectionEntry, next_capacity);
        errdefer rt.memory.free(CollectionEntry, next);
        @memcpy(next[0..entries_slot.*.len], entries_slot.*);
        const old_entries = entries_slot.*;
        const old_capacity = capacity_slot.*;
        entries_slot.* = next[0..entries_slot.*.len];
        capacity_slot.* = next_capacity;
        if (old_capacity != 0) {
            rt.memory.free(CollectionEntry, old_entries.ptr[0..old_capacity]);
        } else if (old_entries.len != 0) {
            rt.memory.free(CollectionEntry, old_entries);
        }
    }

    pub fn appendCollectionEntryUnindexed(self: *Object, rt: *JSRuntime, entry: CollectionEntry) !usize {
        const entries_slot = self.collectionEntriesSlot();
        const index = entries_slot.*.len;
        try self.ensureCollectionEntryCapacity(rt, index + 1);
        const refreshed_entries = self.collectionEntriesSlot();
        refreshed_entries.* = refreshed_entries.*.ptr[0 .. index + 1];
        errdefer refreshed_entries.* = refreshed_entries.*[0..index];
        refreshed_entries.*[index] = entry;
        return index;
    }

    pub fn clearCollectionIndex(self: *Object, rt: *JSRuntime) void {
        const heads = self.collectionBucketHeadsSlot();
        const old_heads = heads.*;
        heads.* = &.{};
        if (old_heads.len != 0) rt.memory.free(usize, old_heads);
    }

    pub fn weakCollectionEntriesSlot(self: *Object) *[]WeakCollectionEntry {
        if (self.collectionPayload()) |payload| return &payload.weak_entries;
        std.debug.assert(self.flags.class_payload_kind == .collection);
        unreachable;
    }

    pub fn weakCollectionEntries(self: *const Object) []WeakCollectionEntry {
        if (self.collectionPayloadConst()) |payload| return payload.weak_entries;
        return &.{};
    }

    pub fn ensureWeakCollectionEntryCapacity(self: *Object, rt: *JSRuntime, min_capacity: usize) !void {
        const payload = self.collectionPayload() orelse {
            std.debug.assert(self.flags.class_payload_kind == .collection);
            unreachable;
        };
        const entries_slot = self.weakCollectionEntriesSlot();
        if (payload.weak_entries_capacity >= min_capacity) return;

        var next_capacity = if (payload.weak_entries_capacity != 0) payload.weak_entries_capacity else entries_slot.*.len;
        if (next_capacity < 4) next_capacity = 4;
        while (next_capacity < min_capacity) next_capacity *= 2;

        const next = try rt.allocRuntime(WeakCollectionEntry, next_capacity);
        errdefer rt.memory.free(WeakCollectionEntry, next);
        @memcpy(next[0..entries_slot.*.len], entries_slot.*);
        const old_entries = entries_slot.*;
        const old_capacity = payload.weak_entries_capacity;
        entries_slot.* = next[0..entries_slot.*.len];
        payload.weak_entries_capacity = next_capacity;
        if (old_capacity != 0) {
            rt.memory.free(WeakCollectionEntry, old_entries.ptr[0..old_capacity]);
        } else if (old_entries.len != 0) {
            rt.memory.free(WeakCollectionEntry, old_entries);
        }
    }

    pub fn finalizationRegistryCleanupCallbackSlot(self: *Object) *?JSValue {
        if (self.finalizationRegistryPayload()) |payload| return &payload.cleanup_callback;
        std.debug.assert(self.flags.class_payload_kind == .finalization_registry);
        unreachable;
    }

    pub fn finalizationRegistryCleanupCallback(self: *const Object) ?JSValue {
        if (self.finalizationRegistryPayloadConst()) |payload| return payload.cleanup_callback;
        return null;
    }

    pub fn finalizationRegistryCellsSlot(self: *Object) *[]FinalizationRegistryCell {
        if (self.finalizationRegistryPayload()) |payload| return &payload.cells;
        std.debug.assert(self.flags.class_payload_kind == .finalization_registry);
        unreachable;
    }

    pub fn finalizationRegistryCells(self: *const Object) []FinalizationRegistryCell {
        if (self.finalizationRegistryPayloadConst()) |payload| return payload.cells;
        return &.{};
    }

    pub fn pendingFinalizationCellCountForTest(self: *const Object) usize {
        if (!builtin.is_test) @compileError("test-only helper");
        const payload = self.finalizationRegistryPayloadConst() orelse return 0;
        var count: usize = 0;
        for (payload.cells) |cell| {
            if (cell.isPending()) count += 1;
        }
        return count;
    }

    pub fn unregisterFinalizationRegistryCells(self: *Object, rt: *JSRuntime, token: JSValue) bool {
        std.debug.assert(self.class_id == class.ids.finalization_registry);
        const token_identity = weakIdentityFromValuePeek(rt, token) orelse return false;
        if (!weakIdentityIsLive(rt, token_identity)) return false;

        const entries = self.finalizationRegistryCellsSlot();
        var removed = false;
        var index: usize = 0;
        while (index < entries.*.len) {
            const entry = &entries.*[index];
            if (!entry.isActive()) {
                index += 1;
                continue;
            }
            if (entry.unregister_token_identity == null or entry.unregister_token_identity.? != token_identity) {
                index += 1;
                continue;
            }

            const removed_cell = entry.*;
            const last_idx = entries.*.len - 1;
            if (index < last_idx) {
                entries.*[index] = entries.*[last_idx];
            }
            entries.* = entries.*.ptr[0..last_idx];
            removed = true;
            removed_cell.destroy(rt);
        }
        if (removed) self.pruneBorrowedReferenceHolderIfEmpty(rt);
        return removed;
    }

    pub fn ensureFinalizationRegistryCellCapacity(self: *Object, rt: *JSRuntime, min_capacity: usize) !void {
        const payload = self.finalizationRegistryPayload() orelse {
            std.debug.assert(self.flags.class_payload_kind == .finalization_registry);
            unreachable;
        };
        if (payload.cells_capacity >= min_capacity) return;

        var next_capacity = if (payload.cells_capacity != 0) payload.cells_capacity else payload.cells.len;
        if (next_capacity < 4) next_capacity = 4;
        while (next_capacity < min_capacity) next_capacity *= 2;

        const next = try rt.allocRuntime(FinalizationRegistryCell, next_capacity);
        errdefer rt.memory.free(FinalizationRegistryCell, next);
        @memcpy(next[0..payload.cells.len], payload.cells);
        const old_cells = payload.cells;
        const old_capacity = payload.cells_capacity;
        payload.cells = next[0..payload.cells.len];
        payload.cells_capacity = next_capacity;
        if (old_capacity != 0) {
            rt.memory.free(FinalizationRegistryCell, old_cells.ptr[0..old_capacity]);
        } else if (old_cells.len != 0) {
            rt.memory.free(FinalizationRegistryCell, old_cells);
        }
    }

    pub fn appendFinalizationRegistryCell(
        self: *Object,
        rt: *JSRuntime,
        target: JSValue,
        held_value: JSValue,
        unregister_token: JSValue,
    ) !void {
        std.debug.assert(self.class_id == class.ids.finalization_registry);
        var rooted_target = target;
        var rooted_held_value = held_value;
        var rooted_unregister_token = unregister_token;
        var root_values = [_]runtime_mod.ValueRootValue{
            .{ .value = &rooted_target },
            .{ .value = &rooted_held_value },
            .{ .value = &rooted_unregister_token },
        };
        const root_frame = runtime_mod.ValueRootFrame{
            .previous = rt.active_value_roots,
            .values = &root_values,
        };
        rt.active_value_roots = &root_frame;
        defer rt.active_value_roots = root_frame.previous;

        const target_identity = try weakIdentityFromValue(rt, rooted_target);
        const unregister_token_identity = try weakIdentityFromValue(rt, rooted_unregister_token);
        const entries = self.finalizationRegistryCellsSlot();
        const index = entries.*.len;
        const inserted_holder = !rt.borrowedReferenceHolderRegistered(self);
        try rt.registerBorrowedReferenceHolder(self);
        errdefer if (inserted_holder) rt.unregisterBorrowedReferenceHolder(self);
        try self.ensureFinalizationRegistryCellCapacity(rt, index + 1);
        const refreshed_entries = self.finalizationRegistryCellsSlot();
        refreshed_entries.* = refreshed_entries.*.ptr[0 .. index + 1];
        errdefer refreshed_entries.* = refreshed_entries.*[0..index];
        if (target_identity) |identity| rt.retainWeakIdentity(identity);
        errdefer if (target_identity) |identity| rt.releaseWeakIdentity(identity);
        if (unregister_token_identity) |identity| rt.retainWeakIdentity(identity);
        errdefer if (unregister_token_identity) |identity| rt.releaseWeakIdentity(identity);
        refreshed_entries.*[index] = .{
            .target_identity = target_identity,
            .held_value = rooted_held_value.dup(),
            .unregister_token_identity = unregister_token_identity,
        };
        try rt.registerBorrowedReferenceHolder(self);
    }

    pub fn stdFileSlot(self: *Object) *?*std.c.FILE {
        if (self.stdFilePayload()) |payload| return &payload.file;
        std.debug.assert(self.flags.class_payload_kind == .std_file);
        unreachable;
    }

    pub fn stdFile(self: *const Object) ?*std.c.FILE {
        if (self.stdFilePayloadConst()) |payload| return payload.file;
        return null;
    }

    pub fn stdFileIsPopenSlot(self: *Object) *bool {
        if (self.stdFilePayload()) |payload| return &payload.is_popen;
        std.debug.assert(self.flags.class_payload_kind == .std_file);
        unreachable;
    }

    pub fn stdFileIsPopen(self: *const Object) bool {
        if (self.stdFilePayloadConst()) |payload| return payload.is_popen;
        return false;
    }

    pub fn stdFileIsStdioSlot(self: *Object) *bool {
        if (self.stdFilePayload()) |payload| return &payload.is_stdio;
        std.debug.assert(self.flags.class_payload_kind == .std_file);
        unreachable;
    }

    pub fn stdFileIsStdio(self: *const Object) bool {
        if (self.stdFilePayloadConst()) |payload| return payload.is_stdio;
        return false;
    }

    pub fn disposableStackDisposedSlot(self: *Object) *bool {
        if (self.disposableStackPayload()) |payload| return &payload.disposed;
        std.debug.assert(self.flags.class_payload_kind == .disposable_stack);
        unreachable;
    }

    pub fn disposableStackDisposed(self: *const Object) bool {
        if (self.disposableStackPayloadConst()) |payload| return payload.disposed;
        return false;
    }

    pub fn appendDisposableResource(
        self: *Object,
        rt: *JSRuntime,
        resource_value: JSValue,
        method: JSValue,
        kind: DisposableResourceKind,
        await_result: bool,
    ) !void {
        const payload = self.disposableStackPayload() orelse {
            std.debug.assert(self.flags.class_payload_kind == .disposable_stack);
            unreachable;
        };
        if (payload.resources.len == payload.resource_capacity) {
            const new_capacity = if (payload.resource_capacity == 0) @as(usize, 4) else payload.resource_capacity * 2;
            const next = try rt.allocRuntime(DisposableResource, new_capacity);
            errdefer rt.memory.free(DisposableResource, next);
            if (payload.resources.len != 0) @memcpy(next[0..payload.resources.len], payload.resources);
            const old_resources = payload.resources;
            const old_capacity = payload.resource_capacity;
            payload.resources = next[0..payload.resources.len];
            payload.resource_capacity = new_capacity;
            if (old_capacity != 0) rt.memory.free(DisposableResource, old_resources.ptr[0..old_capacity]);
        }
        const index = payload.resources.len;
        payload.resources = payload.resources.ptr[0 .. index + 1];
        errdefer payload.resources = payload.resources[0..index];
        payload.resources[index] = .{
            .value = resource_value.dup(),
            .method = method.dup(),
            .kind = kind,
            .await_result = await_result,
        };
    }

    pub fn disposableStackAsyncResolveSlot(self: *Object) *?JSValue {
        if (self.disposableStackPayload()) |payload| return &payload.async_dispose_resolve;
        std.debug.assert(self.flags.class_payload_kind == .disposable_stack);
        unreachable;
    }

    pub fn disposableStackAsyncRejectSlot(self: *Object) *?JSValue {
        if (self.disposableStackPayload()) |payload| return &payload.async_dispose_reject;
        std.debug.assert(self.flags.class_payload_kind == .disposable_stack);
        unreachable;
    }

    pub fn disposableStackAsyncErrorSlot(self: *Object) *?JSValue {
        if (self.disposableStackPayload()) |payload| return &payload.async_dispose_error;
        std.debug.assert(self.flags.class_payload_kind == .disposable_stack);
        unreachable;
    }

    pub fn clearDisposableStackAsyncCapability(self: *Object, rt: *JSRuntime) void {
        if (self.disposableStackPayload()) |payload| {
            const old_resolve = payload.async_dispose_resolve;
            const old_reject = payload.async_dispose_reject;
            const old_error = payload.async_dispose_error;
            payload.async_dispose_resolve = null;
            payload.async_dispose_reject = null;
            payload.async_dispose_error = null;
            if (old_resolve) |stored| stored.free(rt);
            if (old_reject) |stored| stored.free(rt);
            if (old_error) |stored| stored.free(rt);
        }
    }

    pub fn popDisposableResource(self: *Object) ?DisposableResource {
        const payload = self.disposableStackPayload() orelse return null;
        if (payload.resources.len == 0) return null;
        const index = payload.resources.len - 1;
        const resource = payload.resources[index];
        payload.resources = payload.resources[0..index];
        return resource;
    }

    pub fn moveDisposableResourcesTo(self: *Object, rt: *JSRuntime, target: *Object) !void {
        const source_payload = self.disposableStackPayload() orelse {
            std.debug.assert(self.flags.class_payload_kind == .disposable_stack);
            unreachable;
        };
        const target_payload = target.disposableStackPayload() orelse {
            std.debug.assert(target.flags.class_payload_kind == .disposable_stack);
            unreachable;
        };
        _ = rt;
        std.debug.assert(target_payload.resources.len == 0 and target_payload.resource_capacity == 0);
        target_payload.resources = source_payload.resources;
        target_payload.resource_capacity = source_payload.resource_capacity;
        source_payload.resources = &.{};
        source_payload.resource_capacity = 0;
    }

    pub fn ensureVarRefPayload(self: *Object, rt: *JSRuntime) !*VarRefPayload {
        if (self.varRefPayload()) |payload| return payload;
        std.debug.assert(self.u.payload == null);
        const payload = try rt.createRuntime(VarRefPayload);
        payload.* = .{};
        self.u.payload = @ptrCast(payload);
        self.flags.class_payload_kind = .var_ref;
        return payload;
    }

    pub fn initVarRefPayload(self: *Object, rt: *JSRuntime, initial_value: JSValue) !void {
        _ = try self.ensureVarRefPayload(rt);
        try self.setVarRefValue(rt, initial_value);
    }

    pub fn setVarRefValue(self: *Object, rt: *JSRuntime, next_value: JSValue) !void {
        errdefer next_value.free(rt);
        const value_slot = self.varRefValueSlot();
        const old_value = value_slot.*;
        value_slot.* = next_value;
        if (old_value) |stored| stored.free(rt);
    }

    pub fn setOptionalValueSlot(self: *Object, rt: *JSRuntime, slot: *?JSValue, next_value: ?JSValue) !void {
        _ = self;
        errdefer if (next_value) |stored_value| stored_value.free(rt);
        const old_value = slot.*;
        slot.* = next_value;
        if (old_value) |stored| stored.free(rt);
    }

    pub fn clearOptionalValueSlot(self: *Object, rt: *JSRuntime, slot: *?JSValue) void {
        _ = self;
        const old_value = slot.*;
        slot.* = null;
        if (old_value) |stored| stored.free(rt);
    }

    pub fn takeOptionalValueSlot(self: *Object, slot: *?JSValue) ?JSValue {
        _ = self;
        const old_value = slot.*;
        slot.* = null;
        return old_value;
    }

    pub fn setValueSlice(self: *Object, rt: *JSRuntime, slot: *[]JSValue, next_values: []JSValue) !void {
        _ = self;
        errdefer {
            var owned_next = next_values;
            destroyValueSlice(rt, &owned_next);
        }
        destroyValueSlice(rt, slot);
        slot.* = next_values;
    }

    pub fn setValueSliceWithCapacity(
        self: *Object,
        rt: *JSRuntime,
        slot: *[]JSValue,
        capacity: *usize,
        next_values: []JSValue,
        next_capacity: usize,
    ) !void {
        _ = self;
        errdefer {
            var owned_next = next_values;
            var owned_capacity = next_capacity;
            destroyValueSliceWithCapacity(rt, &owned_next, &owned_capacity);
        }
        destroyValueSliceWithCapacity(rt, slot, capacity);
        slot.* = next_values;
        capacity.* = next_capacity;
    }

    pub fn setPromiseResult(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, self.promiseResultSlot(), next_value);
    }

    pub fn setPromiseReactionCallback(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, self.promiseReactionCallbackSlot(), next_value);
    }

    pub fn setPromiseReactionArg(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, self.promiseReactionArgSlot(), next_value);
    }

    pub fn setFunctionPromiseCapabilitySlot(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, try self.functionPromiseCapabilitySlotSlot(rt), next_value);
    }

    pub fn setFunctionPromiseResolvingTarget(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, try self.functionPromiseResolvingTargetSlot(rt), next_value);
    }

    pub fn setFunctionPromiseResolvingState(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, try self.functionPromiseResolvingStateSlot(rt), next_value);
    }

    pub fn setFunctionPromiseThenableTarget(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, try self.functionPromiseThenableTargetSlot(rt), next_value);
    }

    pub fn setFunctionPromiseThenableThis(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, try self.functionPromiseThenableThisSlot(rt), next_value);
    }

    pub fn setFunctionPromiseThenableThen(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, try self.functionPromiseThenableThenSlot(rt), next_value);
    }

    pub fn setFunctionPromiseReactionRecord(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, try self.functionPromiseReactionRecordSlot(rt), next_value);
    }

    pub fn setFunctionPromiseReactionValue(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, try self.functionPromiseReactionValueSlot(rt), next_value);
    }

    pub fn setFunctionPromiseCombinatorState(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, try self.functionPromiseCombinatorStateSlot(rt), next_value);
    }

    pub fn setFunctionPromiseFinallyPayload(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, try self.functionPromiseFinallyPayloadSlot(rt), next_value);
    }

    pub fn setFunctionPromiseFinallyCallback(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, try self.functionPromiseFinallyCallbackSlot(rt), next_value);
    }

    pub fn setFunctionPromiseFinallyConstructor(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, try self.functionPromiseFinallyConstructorSlot(rt), next_value);
    }

    pub fn varRefValueSlot(self: *Object) *?JSValue {
        if (self.varRefPayload()) |payload| return &payload.value;
        std.debug.assert(self.flags.class_payload_kind == .var_ref);
        unreachable;
    }

    pub fn varRefValue(self: *const Object) ?JSValue {
        if (self.varRefPayloadConst()) |payload| return payload.value;
        return null;
    }

    pub fn varRefIsConstSlot(self: *Object) *bool {
        if (self.varRefPayload()) |payload| return &payload.is_const;
        std.debug.assert(self.flags.class_payload_kind == .var_ref);
        unreachable;
    }

    pub fn varRefIsFunctionNameSlot(self: *Object) *bool {
        if (self.varRefPayload()) |payload| return &payload.is_function_name;
        std.debug.assert(self.flags.class_payload_kind == .var_ref);
        unreachable;
    }

    pub fn varRefIsDeletableSlot(self: *Object) *bool {
        if (self.varRefPayload()) |payload| return &payload.is_deletable;
        std.debug.assert(self.flags.class_payload_kind == .var_ref);
        unreachable;
    }

    pub fn ensureTypedArrayPayload(self: *Object, rt: *JSRuntime) !void {
        if (self.typedArrayPayload() != null) return;
        const payload = try rt.createRuntime(TypedArrayPayload);
        payload.* = .{};
        self.u.payload = @ptrCast(payload);
        self.flags.class_payload_kind = .typed_array;
    }

    pub fn byteStorageSlot(self: *Object) *[]u8 {
        if (self.bufferPayload()) |payload| return &payload.bytes;
        std.debug.assert(self.flags.class_payload_kind == .buffer);
        unreachable;
    }

    pub fn byteStorage(self: *const Object) []u8 {
        if (self.bufferPayloadConst()) |payload| return payload.bytes;
        return &.{};
    }

    pub fn installByteStorage(self: *Object, rt: *JSRuntime, bytes: []u8) !void {
        if (self.bufferPayload()) |payload| {
            const external_memory = try rt.reportExternalAlloc(bytes.len);
            payload.releaseStorage(rt);
            payload.shared_store = null;
            payload.bytes = bytes;
            payload.inline_length = 0;
            payload.external_memory = external_memory;
            payload.detached = false;
            return;
        }
        std.debug.assert(self.flags.class_payload_kind == .buffer);
        unreachable;
    }

    pub fn installInlineByteStorage(self: *Object, rt: *JSRuntime, byte_length: usize) !bool {
        if (byte_length > BufferPayload.inline_storage_capacity) return false;
        if (self.bufferPayload()) |payload| {
            payload.releaseStorage(rt);
            rt.reportExternalAllocUntracked(byte_length);
            payload.shared_store = null;
            payload.external_memory = .{};
            payload.external_deinit = null;
            payload.external_context = null;
            payload.inline_length = @intCast(byte_length);
            payload.bytes = payload.inline_bytes[0..byte_length];
            payload.detached = false;
            return true;
        }
        std.debug.assert(self.flags.class_payload_kind == .buffer);
        unreachable;
    }

    pub fn installExternalByteStorage(
        self: *Object,
        rt: *JSRuntime,
        bytes: []u8,
        deinit_fn: ExternalByteStorageDeinit,
        context: ?*anyopaque,
    ) !void {
        if (self.bufferPayload()) |payload| {
            const external_memory = try rt.reportExternalAlloc(bytes.len);
            payload.releaseStorage(rt);
            payload.bytes = bytes;
            payload.inline_length = 0;
            payload.external_memory = external_memory;
            payload.external_deinit = deinit_fn;
            payload.external_context = context;
            payload.detached = false;
            return;
        }
        std.debug.assert(self.flags.class_payload_kind == .buffer);
        unreachable;
    }

    pub fn detachByteStorage(self: *Object, rt: *JSRuntime) void {
        if (self.bufferPayload()) |payload| {
            if (payload.shared_store != null) return;
            payload.releaseStorage(rt);
            payload.detached = true;
            return;
        }
        std.debug.assert(self.flags.class_payload_kind == .buffer);
        unreachable;
    }

    pub fn sharedByteStorageStore(self: *const Object) ?*SharedBufferStore {
        const payload = self.bufferPayloadConst() orelse return null;
        return payload.shared_store;
    }

    pub fn installSharedByteStorage(self: *Object, rt: *JSRuntime, store: *SharedBufferStore) void {
        if (self.bufferPayload()) |payload| {
            payload.releaseStorage(rt);
            payload.shared_store = store;
            payload.bytes = store.bytes;
            payload.inline_length = 0;
            payload.external_memory = .{};
            payload.detached = false;
            return;
        }
        std.debug.assert(self.flags.class_payload_kind == .buffer);
        unreachable;
    }

    pub fn arrayBufferDetachedSlot(self: *Object) *bool {
        if (self.bufferPayload()) |payload| return &payload.detached;
        std.debug.assert(self.flags.class_payload_kind == .buffer);
        unreachable;
    }

    pub fn arrayBufferDetached(self: *const Object) bool {
        if (self.bufferPayloadConst()) |payload| return payload.detached;
        return false;
    }

    pub fn arrayBufferImmutableSlot(self: *Object) *bool {
        if (self.bufferPayload()) |payload| return &payload.immutable;
        std.debug.assert(self.flags.class_payload_kind == .buffer);
        unreachable;
    }

    pub fn arrayBufferImmutable(self: *const Object) bool {
        if (self.bufferPayloadConst()) |payload| return payload.immutable;
        return false;
    }

    pub fn arrayBufferMaxByteLengthSlot(self: *Object) *?usize {
        if (self.bufferPayload()) |payload| return &payload.max_byte_length;
        std.debug.assert(self.flags.class_payload_kind == .buffer);
        unreachable;
    }

    pub fn arrayBufferMaxByteLength(self: *const Object) ?usize {
        if (self.bufferPayloadConst()) |payload| return payload.max_byte_length;
        return null;
    }

    pub fn typedArrayBufferSlot(self: *Object) *?JSValue {
        if (self.typedArrayPayload()) |payload| return &payload.buffer;
        std.debug.assert(self.flags.class_payload_kind == .typed_array);
        unreachable;
    }

    pub fn typedArrayBuffer(self: *const Object) ?JSValue {
        if (self.typedArrayPayloadConst()) |payload| return payload.buffer;
        return null;
    }

    pub fn typedArrayByteOffsetSlot(self: *Object) *usize {
        if (self.typedArrayPayload()) |payload| return &payload.byte_offset;
        std.debug.assert(self.flags.class_payload_kind == .typed_array);
        unreachable;
    }

    pub fn typedArrayByteOffset(self: *const Object) usize {
        if (self.typedArrayPayloadConst()) |payload| return payload.byte_offset;
        return 0;
    }

    pub fn typedArrayElementSizeSlot(self: *Object) *u32 {
        if (self.typedArrayPayload()) |payload| return &payload.element_size;
        std.debug.assert(!class.isBytecodeFunctionClass(self.class_id));
        if (self.functionPayload()) |payload| return &payload.native.typed_array_element_size;
        std.debug.assert(self.flags.class_payload_kind == .typed_array);
        unreachable;
    }

    pub fn typedArrayElementSize(self: *const Object) u32 {
        if (self.typedArrayPayloadConst()) |payload| return payload.element_size;
        if (class.isBytecodeFunctionClass(self.class_id)) return 0;
        if (self.functionPayloadConst()) |payload| return payload.native.typed_array_element_size;
        return 0;
    }

    pub fn typedArrayFixedLengthSlot(self: *Object) *?u32 {
        if (self.typedArrayPayload()) |payload| return &payload.fixed_length;
        std.debug.assert(self.flags.class_payload_kind == .typed_array);
        unreachable;
    }

    pub fn typedArrayFixedLength(self: *const Object) ?u32 {
        if (self.typedArrayPayloadConst()) |payload| return payload.fixed_length;
        return null;
    }

    pub fn typedArrayKindSlot(self: *Object) *u8 {
        if (self.typedArrayPayload()) |payload| return &payload.kind;
        std.debug.assert(!class.isBytecodeFunctionClass(self.class_id));
        if (self.functionPayload()) |payload| return &payload.native.typed_array_kind;
        std.debug.assert(self.flags.class_payload_kind == .typed_array);
        unreachable;
    }

    pub fn typedArrayKind(self: *const Object) u8 {
        if (self.typedArrayPayloadConst()) |payload| return payload.kind;
        if (class.isBytecodeFunctionClass(self.class_id)) return 0;
        if (self.functionPayloadConst()) |payload| return payload.native.typed_array_kind;
        return 0;
    }

    pub fn regexpSource(self: *const Object) ?JSValue {
        if (self.regExpPayloadConst()) |payload| {
            const source = payload.source orelse return null;
            return source.value();
        }
        return null;
    }

    /// Store the owned flat-string pointer used by QuickJS's `JSRegExp`.
    /// `asStringBody` materializes a rope at the value boundary when needed;
    /// RegExp source is required to be a string by the internal constructor.
    pub fn setRegexpSource(self: *Object, rt: *JSRuntime, source_value: JSValue) !void {
        const source = source_value.asStringBody() orelse return error.TypeError;
        source.retain();
        const payload = self.regExpPayload() orelse return error.TypeError;
        const old_source = payload.source;
        payload.source = source;
        if (old_source) |stored_string| stored_string.value().free(rt);
    }

    /// QuickJS keeps RegExp `lastIndex` as the first ordinary, non-configurable
    /// shape property (`ctx->regexp_shape`; quickjs.c:47657, 48081, 49289).
    /// The fixed position lets the regexp executor access the value directly,
    /// while the ordinary property machinery owns descriptors, keys, GC, and
    /// mutation semantics.
    pub inline fn regexpLastIndexSlot(self: *Object) *JSValue {
        std.debug.assert(self.class_id == class.ids.regexp);
        std.debug.assert(self.shape_ref.prop_count >= 1);
        std.debug.assert(self.propAtomAt(0) == atom.ids.lastIndex);
        const flags = self.propFlagsAt(0);
        std.debug.assert(!flags.deleted and flags.kind == .data);
        std.debug.assert(!flags.enumerable and !flags.configurable);
        return &self.prop_values[0].slot.data;
    }

    pub inline fn regexpLastIndex(self: *const Object) ?JSValue {
        if (self.class_id != class.ids.regexp or self.shape_ref.prop_count == 0) return null;
        if (self.propAtomAt(0) != atom.ids.lastIndex) return null;
        return self.asDataAt(0);
    }

    pub inline fn regexpLastIndexWritable(self: *const Object) bool {
        if (self.regexpLastIndex() == null) return false;
        return self.propFlagsAt(0).writable;
    }

    /// Install the invariant first RegExp property on a fresh instance. This
    /// is the zjs counterpart of QuickJS's realm `regexp_shape` plus its
    /// initial integer value. Shape transitions are cached, so instances with
    /// the same prototype converge on the same final shape.
    pub fn initializeRegExpLastIndex(self: *Object, rt: *JSRuntime) !void {
        std.debug.assert(self.class_id == class.ids.regexp);
        std.debug.assert(self.shape_ref.prop_count == 0);
        try self.appendPreparedPropertyEntry(
            rt,
            atom.ids.lastIndex,
            property.Flags.data(true, false, false),
            .{ .data = JSValue.int32(0) },
        );
        std.debug.assert(self.regexpLastIndexSlot().asInt32().? == 0);
    }

    pub fn regexpCompiledBytecode(self: *const Object) []const u8 {
        if (self.regExpPayloadConst()) |payload| {
            const bytecode = payload.compiled_bytecode orelse return &.{};
            return switch (bytecode.resolveData()) {
                .latin1 => |bytes| bytes,
                .utf16 => unreachable,
            };
        }
        return &.{};
    }

    pub fn clearRegexpCompiledBytecode(self: *Object, rt: *JSRuntime) void {
        if (self.regExpPayload()) |payload| {
            const old_bytecode = payload.compiled_bytecode;
            payload.compiled_bytecode = null;
            if (old_bytecode) |stored_string| stored_string.value().free(rt);
            return;
        }
        std.debug.assert(self.flags.class_payload_kind == .regexp);
        unreachable;
    }

    pub fn setRegexpCompiledBytecode(self: *Object, rt: *JSRuntime, bytecode: []const u8) !void {
        if (self.regExpPayload()) |payload| {
            if (bytecode.len == 0) {
                self.clearRegexpCompiledBytecode(rt);
                return;
            }

            // qjs wraps lre bytecode in a narrow JSString and stores that
            // string pointer in `u.regexp.bytecode` (quickjs.c:47624-47633).
            const owned = try string.String.createLatin1(rt, bytecode);
            const old_bytecode = payload.compiled_bytecode;
            payload.compiled_bytecode = owned;
            if (old_bytecode) |stored_string| stored_string.value().free(rt);
        } else {
            std.debug.assert(self.flags.class_payload_kind == .regexp);
            unreachable;
        }
    }

    /// Install an already-compiled narrow-string payload by retaining it.
    /// RegExp literals use this path to share their bytecode constant exactly
    /// like qjs `JS_NewRegexp`; dynamic constructors use the slice overload
    /// above because they own a fresh compiler buffer.
    pub fn setRegexpCompiledBytecodeString(self: *Object, rt: *JSRuntime, bytecode: *string.String) !void {
        if (bytecode.isWide() or bytecode.len() == 0) return error.TypeError;
        if (self.regExpPayload()) |payload| {
            bytecode.retain();
            const old_bytecode = payload.compiled_bytecode;
            payload.compiled_bytecode = bytecode;
            if (old_bytecode) |stored_string| stored_string.value().free(rt);
        } else {
            std.debug.assert(self.flags.class_payload_kind == .regexp);
            unreachable;
        }
    }

    pub fn boundTargetSlot(self: *Object) *?JSValue {
        if (self.boundFunctionPayload()) |payload| return &payload.target;
        std.debug.assert(self.class_id == class.ids.bound_function);
        unreachable;
    }

    pub fn boundTarget(self: *const Object) ?JSValue {
        if (self.boundFunctionPayloadConst()) |payload| return payload.target;
        return null;
    }

    pub fn boundThisSlot(self: *Object) *?JSValue {
        if (self.boundFunctionPayload()) |payload| return &payload.this_value;
        std.debug.assert(self.class_id == class.ids.bound_function);
        unreachable;
    }

    pub fn boundThis(self: *const Object) ?JSValue {
        if (self.boundFunctionPayloadConst()) |payload| return payload.this_value;
        return null;
    }

    pub fn boundArgsSlot(self: *Object) *[]JSValue {
        if (self.boundFunctionPayload()) |payload| return &payload.args;
        std.debug.assert(self.class_id == class.ids.bound_function);
        unreachable;
    }

    pub fn boundArgs(self: *const Object) []JSValue {
        if (self.boundFunctionPayloadConst()) |payload| return payload.args;
        return &.{};
    }

    pub fn ensureProxyPayload(self: *Object, rt: *JSRuntime) !void {
        std.debug.assert(self.isProxy());
        if (self.proxyPayload() != null) return;
        const payload = try rt.createRuntime(ProxyPayload);
        payload.* = .{};
        self.u.payload = @ptrCast(payload);
        self.flags.class_payload_kind = .proxy;
    }

    pub fn proxyTargetSlot(self: *Object) *?JSValue {
        if (self.proxyPayload()) |payload| return &payload.target;
        std.debug.assert(self.isProxy());
        unreachable;
    }

    pub fn proxyTarget(self: *const Object) ?JSValue {
        if (self.proxyPayloadConst()) |payload| return payload.target;
        return null;
    }

    pub fn proxyHandlerSlot(self: *Object) *?JSValue {
        if (self.proxyPayload()) |payload| return &payload.handler;
        std.debug.assert(self.isProxy());
        unreachable;
    }

    pub fn proxyHandler(self: *const Object) ?JSValue {
        if (self.proxyPayloadConst()) |payload| return payload.handler;
        return null;
    }

    /// Allocate the mapped-arguments pointer table behind a typed Interface.
    ///
    /// The shared array union still owns a JSValue-sized backing allocation so
    /// destruction and memory accounting stay correct for both supported value
    /// representations. Callers never construct or reinterpret that backing;
    /// they only receive the logical `?*VarRef` entries.
    pub fn allocateMappedArgumentsVarRefsAssumingEmpty(self: *Object, rt: *JSRuntime, count: usize) ![]?*var_ref_mod.VarRef {
        std.debug.assert(self.class_id == class.ids.mapped_arguments);
        std.debug.assert(self.flags.class_payload_kind == .none);
        std.debug.assert(self.u.array.count == 0 and self.u.array.capacity == 0);
        if (count == 0) return &.{};

        const backing = try rt.memory.alloc(JSValue, count);
        self.u.array.values = backing.ptr;
        self.u.array.count = @intCast(count);
        self.u.array.capacity = @intCast(count);
        self.u.array.length = @intCast(count);
        self.markIndexedProperties(rt);

        const refs = self.argumentsVarRefsMut();
        @memset(refs, null);
        return refs;
    }

    pub fn argumentsVarRefs(self: *const Object) []const ?*var_ref_mod.VarRef {
        if (self.class_id != class.ids.mapped_arguments or self.u.array.count == 0) return &.{};
        std.debug.assert(self.u.array.capacity >= self.u.array.count);
        const backing = self.u.array.values[0..@as(usize, @intCast(self.u.array.capacity))];
        const cells = std.mem.bytesAsSlice(?*var_ref_mod.VarRef, std.mem.sliceAsBytes(backing));
        return cells[0..@as(usize, @intCast(self.u.array.count))];
    }

    pub fn argumentsVarRefsMut(self: *Object) []?*var_ref_mod.VarRef {
        if (self.class_id != class.ids.mapped_arguments or self.u.array.count == 0) return &.{};
        std.debug.assert(self.u.array.capacity >= self.u.array.count);
        const backing = self.u.array.values[0..@as(usize, @intCast(self.u.array.capacity))];
        const cells = std.mem.bytesAsSlice(?*var_ref_mod.VarRef, std.mem.sliceAsBytes(backing));
        return cells[0..@as(usize, @intCast(self.u.array.count))];
    }

    pub fn objectDataSlot(self: *Object) *?JSValue {
        if (self.objectDataPayload()) |payload| return &payload.data;
        std.debug.assert(self.flags.class_payload_kind == .object_data);
        unreachable;
    }

    pub fn objectData(self: *const Object) ?JSValue {
        if (self.objectDataPayloadConst()) |payload| return payload.data;
        return null;
    }

    pub fn setWeakRefTarget(self: *Object, rt: *JSRuntime, target: JSValue) !void {
        std.debug.assert(self.class_id == class.ids.weak_ref);
        var rooted_target = target;
        var root_values = [_]runtime_mod.ValueRootValue{
            .{ .value = &rooted_target },
        };
        const root_frame = runtime_mod.ValueRootFrame{
            .previous = rt.active_value_roots,
            .values = &root_values,
        };
        rt.active_value_roots = &root_frame;
        defer rt.active_value_roots = root_frame.previous;

        const weak_target_identity = try weakIdentityFromValue(rt, rooted_target);
        try rt.registerBorrowedReferenceHolder(self);
        const payload = self.weakRefPayload() orelse {
            std.debug.assert(self.flags.class_payload_kind == .weak_ref);
            unreachable;
        };
        const old_identity = payload.weak_target_identity;
        if (weak_target_identity) |identity| rt.retainWeakIdentity(identity);
        payload.weak_target_identity = weak_target_identity;
        try rt.registerBorrowedReferenceHolder(self);
        if (old_identity) |identity| rt.releaseWeakIdentity(identity);
        self.pruneBorrowedReferenceHolderIfEmpty(rt);
    }

    pub fn weakRefDeref(self: *const Object, rt: *JSRuntime) JSValue {
        std.debug.assert(self.class_id == class.ids.weak_ref);
        const payload = self.weakRefPayloadConst() orelse return JSValue.undefinedValue();
        const identity = payload.weak_target_identity orelse return JSValue.undefinedValue();
        if ((identity & 1) != 0) {
            const atom_id = identity >> 1;
            if (atom_id > std.math.maxInt(atom.Atom)) return JSValue.undefinedValue();
            const symbol_atom: atom.Atom = @intCast(atom_id);
            if (rt.atoms.kind(symbol_atom) != .symbol) return JSValue.undefinedValue();
            return rt.atoms.symbolValueIfLive(rt, symbol_atom) catch JSValue.undefinedValue();
        }
        const target = rt.liveObjectFromWeakIdentity(identity) orelse return JSValue.undefinedValue();
        return target.value().dup();
    }

    pub fn arrayElementStorageMode(self: *const Object) ArrayStorageMode {
        return if (self.flags.fast_array) .dense else .sparse;
    }

    pub fn arrayElements(self: *const Object) []JSValue {
        if (!self.flags.fast_array or self.u.array.count == 0) return &.{};
        std.debug.assert(self.u.array.capacity >= self.u.array.count);
        std.debug.assert(self.u.array.length >= self.u.array.count);
        return self.u.array.values[0..@as(usize, @intCast(self.u.array.count))];
    }

    fn arrayElementsMut(self: *Object) []JSValue {
        if (!self.flags.fast_array or self.u.array.count == 0) return &.{};
        std.debug.assert(self.u.array.capacity >= self.u.array.count);
        std.debug.assert(self.u.array.length >= self.u.array.count);
        return self.u.array.values[0..@as(usize, @intCast(self.u.array.count))];
    }

    fn allocatedArrayElements(self: *Object) []JSValue {
        if (self.u.array.capacity == 0) return &.{};
        return self.u.array.values[0..@as(usize, @intCast(self.u.array.capacity))];
    }

    pub fn arrayElementsCapacity(self: *const Object) usize {
        return @intCast(self.u.array.capacity);
    }

    pub fn isFastArray(self: *const Object) bool {
        return self.isArray() and self.flags.fast_array;
    }

    pub fn isFastArrayIndexInBounds(self: *const Object, index: u32) bool {
        return self.flags.fast_array and index < self.u.array.count;
    }

    pub fn fastArrayElementAt(self: *const Object, index: u32) JSValue {
        std.debug.assert(self.isFastArrayIndexInBounds(index));
        return self.u.array.values[@intCast(index)];
    }

    pub fn fastArrayElementSlot(self: *Object, index: u32) *JSValue {
        std.debug.assert(self.isFastArrayIndexInBounds(index));
        return &self.u.array.values[@intCast(index)];
    }

    pub fn fastArrayElementDup(self: *const Object, index: u32) ?JSValue {
        if (!self.isFastArrayIndexInBounds(index)) return null;
        return self.u.array.values[@intCast(index)].dup();
    }

    pub fn setFastArrayElementDup(self: *Object, rt: *JSRuntime, index: u32, new_value: JSValue) bool {
        if (!self.isFastArrayIndexInBounds(index)) return false;
        const slot = &self.u.array.values[@intCast(index)];
        const old = slot.*;
        slot.* = new_value.dup();
        old.free(rt);
        return true;
    }

    pub fn adoptDenseArrayElementsAssumingEmpty(self: *Object, elements: []JSValue) void {
        std.debug.assert(self.isArray());
        std.debug.assert(self.u.array.count == 0);
        std.debug.assert(self.u.array.capacity == 0);
        self.u.array.values = elements.ptr;
        self.u.array.count = @intCast(elements.len);
        self.u.array.capacity = @intCast(elements.len);
        // Fully-dense adoption: the logical length equals the dense extent.
        self.u.array.length = @intCast(elements.len);
        self.flags.fast_array = true;
    }

    /// Adopt a fully initialized qjs-style dense element buffer for an
    /// unmapped arguments object. The visible `length` property lives in the
    /// prepared shape; `array_length` is only the dense-extent invariant used
    /// by the shared storage machinery.
    pub fn adoptDenseUnmappedArgumentsElementsAssumingEmpty(self: *Object, rt: *JSRuntime, elements: []JSValue) void {
        std.debug.assert(self.class_id == class.ids.arguments);
        std.debug.assert(self.supportsPlainNamedPropertyStorage());
        std.debug.assert(self.flags.class_payload_kind == .none);
        std.debug.assert(self.u.array.count == 0);
        std.debug.assert(self.u.array.capacity == 0);
        if (elements.len != 0) self.u.array.values = elements.ptr;
        self.u.array.count = @intCast(elements.len);
        self.u.array.capacity = @intCast(elements.len);
        self.u.array.length = @intCast(elements.len);
        self.flags.fast_array = true;
        if (elements.len != 0) self.markIndexedProperties(rt);
    }

    pub fn clearFastArray(self: *Object) void {
        if (!self.isArray()) return;
        std.debug.assert(self.u.array.capacity == 0);
        self.flags.fast_array = false;
    }

    pub fn setArraySparseLength(self: *Object, length: u32) void {
        std.debug.assert(self.isArray());
        std.debug.assert(self.u.array.capacity == 0);
        // Sparse arrays carry no dense extent: count is 0, length is the
        // JS-observable `.length`. (Invariant 5: sparse => array_count == 0.)
        self.u.array.count = 0;
        self.u.array.length = length;
        self.flags.fast_array = false;
    }

    pub fn resetFastArrayEmpty(self: *Object) void {
        std.debug.assert(self.isArray());
        std.debug.assert(self.u.array.capacity == 0);
        self.u.array.count = 0;
        self.u.array.length = 0;
        self.flags.fast_array = true;
    }

    pub fn takeLastFastArrayElement(self: *Object) ?JSValue {
        if (!self.isArray() or !self.flags.fast_array or self.u.array.count == 0) return null;
        self.u.array.count -= 1;
        return self.u.array.values[@intCast(self.u.array.count)];
    }

    /// Pop the last element of a FULLY DENSE fast array (count == length),
    /// lowering BOTH the dense extent and the JS `.length` by one. Returns null
    /// for an empty or holey array (`length > count`) so the caller falls back
    /// to the generic [[Delete last]] + set-length path that handles tail holes.
    /// Mirrors the pop fast path's "delete last, length-=1" pair.
    pub fn takeLastFullyDenseFastArrayElement(self: *Object) ?JSValue {
        if (!self.isArray() or !self.flags.fast_array) return null;
        if (self.u.array.count == 0 or self.u.array.count != self.u.array.length) return null;
        self.u.array.count -= 1;
        self.u.array.length -= 1;
        return self.u.array.values[@intCast(self.u.array.count)];
    }

    pub fn borrowLastFastArrayElement(self: *Object) ?*JSValue {
        if (!self.isArray() or !self.flags.fast_array or self.u.array.count == 0) return null;
        return &self.u.array.values[@intCast(self.u.array.count - 1)];
    }

    pub fn shrinkFastArrayByOne(self: *Object) void {
        std.debug.assert(self.isArray() and self.flags.fast_array and self.u.array.count != 0);
        self.u.array.count -= 1;
    }

    fn destroyArrayElements(self: *Object, rt: *JSRuntime) void {
        // Only these classes activate the dense-array union arm. Other class
        // arms may legitimately use all three words (notably inline RegExp's
        // second string pointer), so their bytes must never be interpreted as
        // array count/capacity state.
        if (self.class_id != class.ids.array and
            self.class_id != class.ids.arguments and
            self.class_id != class.ids.mapped_arguments) return;
        if (self.class_id == class.ids.mapped_arguments) {
            for (self.argumentsVarRefs()) |maybe_cell| {
                const cell = maybe_cell orelse continue;
                cell.release(rt);
            }
            const allocated = self.allocatedArrayElements();
            self.u.array.count = 0;
            self.u.array.capacity = 0;
            self.u.array.length = 0;
            if (allocated.len != 0) rt.memory.free(JSValue, allocated);
            return;
        }
        if (!self.flags.fast_array and self.u.array.capacity == 0) return;
        if (self.flags.fast_array) {
            var index: usize = 0;
            const count: usize = @intCast(self.u.array.count);
            while (index < count) : (index += 1) self.u.array.values[index].free(rt);
        } else {
            std.debug.assert(self.u.array.capacity == 0);
        }
        const allocated = self.allocatedArrayElements();
        self.u.array.count = 0;
        self.u.array.capacity = 0;
        self.u.array.length = 0;
        self.flags.fast_array = false;
        if (allocated.len != 0) rt.memory.free(JSValue, allocated);
    }

    fn freeArrayElementBufferAfterMove(self: *Object, rt: *JSRuntime) void {
        std.debug.assert(!self.flags.fast_array or self.u.array.count == 0);
        const allocated = self.allocatedArrayElements();
        self.u.array.capacity = 0;
        self.flags.fast_array = false;
        if (allocated.len != 0) rt.memory.free(JSValue, allocated);
    }

    fn ensureArrayBufferCapacity(self: *Object, rt: *JSRuntime, needed_len: usize) !void {
        const old_capacity: usize = @intCast(self.u.array.capacity);
        if (needed_len <= old_capacity) return;
        // Mirror QuickJS expand_fast_array (quickjs.c:9530):
        //   new_size = max_int(new_len, size * 3 / 2)
        // When the array has no backing storage yet (size == 0) the 3/2 term is
        // zero, so qjs allocates exactly `new_len` slots — no hardcoded floor.
        // The prior min-16 seed (16d7826e, not a qjs anchor) over-allocated a
        // 3-element literal into 16 slots (256B, 13 wasted). Fall back to
        // exact-fit and keep the 1.5x growth branch (already == qjs size*3/2).
        var next_capacity = if (old_capacity == 0) needed_len else old_capacity + old_capacity / 2;
        if (next_capacity <= old_capacity) next_capacity = old_capacity + 1;
        while (next_capacity < needed_len) {
            const growth = @max(next_capacity / 2, 1);
            next_capacity += growth;
        }
        if (next_capacity > std.math.maxInt(u32)) return error.OutOfMemory;
        const old_allocated = self.allocatedArrayElements();
        if (old_allocated.len != 0) {
            // Slab-backed small buffers cannot be remapped by the backing
            // allocator, and some allocators decline relocation; keep the
            // copy/free fallback for those cases.
            if (try rt.remapRuntime(JSValue, old_allocated, next_capacity)) |next| {
                self.u.array.values = next.ptr;
                self.u.array.capacity = @intCast(next_capacity);
                return;
            }
        }
        const next = try rt.allocRuntime(JSValue, next_capacity);
        errdefer rt.memory.free(JSValue, next);
        if (self.flags.fast_array and self.u.array.count != 0) {
            const count: usize = @intCast(self.u.array.count);
            @memcpy(next[0..count], self.u.array.values[0..count]);
        }
        self.u.array.values = next.ptr;
        self.u.array.capacity = @intCast(next_capacity);
        if (old_allocated.len != 0) rt.memory.free(JSValue, old_allocated);
    }

    pub fn appendUninitializedFastArraySlot(self: *Object, rt: *JSRuntime) !*JSValue {
        const index = self.u.array.count;
        try self.ensureArrayBufferCapacity(rt, @as(usize, @intCast(index)) + 1);
        self.u.array.count = index + 1;
        self.flags.fast_array = true;
        return &self.u.array.values[@intCast(index)];
    }

    pub fn fastArrayEnsureCapacity(self: *Object, rt: *JSRuntime, needed: u32) !void {
        try self.ensureArrayBufferCapacity(rt, @intCast(needed));
    }

    pub fn fastArrayValuesPtr(self: *const Object) ?[*]JSValue {
        if (!self.isFastArray() or self.u.array.count == 0) return null;
        return self.u.array.values;
    }

    pub fn fastArrayCount(self: *const Object) u32 {
        return if (self.isFastArray()) self.u.array.count else 0;
    }

    pub fn fastArrayCapacity(self: *const Object) u32 {
        return self.u.array.capacity;
    }

    pub fn fastArrayValues(self: *const Object) []JSValue {
        return self.arrayElements();
    }

    pub fn fastArrayValuesMut(self: *Object) []JSValue {
        return self.arrayElementsMut();
    }

    pub fn arrayElementsForCount(self: *const Object) []const JSValue {
        if (!self.flags.fast_array or self.u.array.count == 0) return &.{};
        return self.u.array.values[0..@as(usize, @intCast(self.u.array.count))];
    }

    pub fn setFastArrayCountAssumeCapacity(self: *Object, count: u32) void {
        std.debug.assert(count <= self.u.array.capacity);
        self.u.array.count = count;
        self.flags.fast_array = true;
    }

    pub fn fastArraySlotAssumeCapacity(self: *Object, index: u32) *JSValue {
        std.debug.assert(index < self.u.array.capacity);
        return &self.u.array.values[@intCast(index)];
    }

    pub fn fastArraySetSparseLength(self: *Object, length: u32) void {
        self.setArraySparseLength(length);
    }

    pub fn fastArrayResetEmpty(self: *Object) void {
        self.resetFastArrayEmpty();
    }

    pub fn fastArrayAdoptElementsAssumingEmpty(self: *Object, elements: []JSValue) void {
        self.adoptDenseArrayElementsAssumingEmpty(elements);
    }

    pub fn fastArrayTakeLast(self: *Object) ?JSValue {
        return self.takeLastFastArrayElement();
    }

    pub fn fastArrayBorrowLast(self: *Object) ?*JSValue {
        return self.borrowLastFastArrayElement();
    }

    pub fn fastArrayShrinkLast(self: *Object) void {
        self.shrinkFastArrayByOne();
    }

    pub fn fastArrayHasIndex(self: *const Object, index: u32) bool {
        return self.isFastArrayIndexInBounds(index);
    }

    pub fn fastArrayGetDup(self: *const Object, index: u32) ?JSValue {
        return self.fastArrayElementDup(index);
    }

    pub fn fastArraySetDup(self: *Object, rt: *JSRuntime, index: u32, new_value: JSValue) bool {
        return self.setFastArrayElementDup(rt, index, new_value);
    }

    pub fn promiseResultSlot(self: *Object) *?JSValue {
        if (self.promisePayload()) |payload| return &payload.result;
        std.debug.assert(self.flags.class_payload_kind == .promise);
        unreachable;
    }

    pub fn promiseResult(self: *const Object) ?JSValue {
        if (self.promisePayloadConst()) |payload| return payload.result;
        return null;
    }

    pub fn promiseReactionCallbackSlot(self: *Object) *?JSValue {
        if (self.promisePayload()) |payload| return &payload.reaction_callback;
        std.debug.assert(self.flags.class_payload_kind == .promise);
        unreachable;
    }

    pub fn promiseReactionCallback(self: *const Object) ?JSValue {
        if (self.promisePayloadConst()) |payload| return payload.reaction_callback;
        return null;
    }

    pub fn promiseReactionArgSlot(self: *Object) *?JSValue {
        if (self.promisePayload()) |payload| return &payload.reaction_arg;
        std.debug.assert(self.flags.class_payload_kind == .promise);
        unreachable;
    }

    pub fn promiseReactionArg(self: *const Object) ?JSValue {
        if (self.promisePayloadConst()) |payload| return payload.reaction_arg;
        return null;
    }

    pub fn promiseReactionsSlot(self: *Object) *[]JSValue {
        if (self.promisePayload()) |payload| return &payload.reactions;
        std.debug.assert(self.flags.class_payload_kind == .promise);
        unreachable;
    }

    pub fn promiseReactions(self: *const Object) []JSValue {
        if (self.promisePayloadConst()) |payload| return payload.reactions;
        return &.{};
    }

    pub fn promiseIsRejectedSlot(self: *Object) *bool {
        if (self.promisePayload()) |payload| return &payload.is_rejected;
        std.debug.assert(self.flags.class_payload_kind == .promise);
        unreachable;
    }

    pub fn promiseIsRejected(self: *const Object) bool {
        if (self.promisePayloadConst()) |payload| return payload.is_rejected;
        return false;
    }

    pub fn promiseAtomicsWaitAsyncSlot(self: *Object) *bool {
        if (self.promisePayload()) |payload| return &payload.atomics_wait_async;
        std.debug.assert(self.flags.class_payload_kind == .promise);
        unreachable;
    }

    pub fn promiseAtomicsWaitAsync(self: *const Object) bool {
        if (self.promisePayloadConst()) |payload| return payload.atomics_wait_async;
        return false;
    }

    /// Install the qjs-style variable-sized execution record for a detached
    /// generator shell. The trailing operand stack and scalar execution state
    /// are returned by one allocator operation.
    pub fn initGeneratorExecutionWithStorage(self: *Object, rt: *JSRuntime, stack_slots: usize, frame_slots: usize) !void {
        const payload = self.generatorPayload() orelse {
            std.debug.assert(self.flags.class_payload_kind == .generator);
            unreachable;
        };
        std.debug.assert(payload.execution == null);
        payload.execution = try createGeneratorExecutionStateWithStorage(rt, stack_slots, frame_slots);
    }

    fn generatorLiveExecution(self: *Object) *GeneratorExecutionState {
        const payload = self.generatorPayload() orelse {
            std.debug.assert(self.flags.class_payload_kind == .generator);
            unreachable;
        };
        return payload.execution orelse {
            std.debug.assert(!payload.done);
            unreachable;
        };
    }

    /// Direct payload for a proven generator object. Resume entry checks the
    /// class once, then reuses this stable qjs-style state record instead of
    /// redispatching through the class-payload union for every field.
    pub inline fn generatorPayloadPtr(self: *Object) *GeneratorPayload {
        std.debug.assert(self.class_id == class.ids.generator or self.class_id == class.ids.async_generator);
        std.debug.assert(self.flags.class_payload_kind == .generator);
        return @ptrCast(@alignCast(self.u.payload.?));
    }

    pub fn generatorThisSlot(self: *Object) *JSValue {
        return &self.generatorLiveExecution().this_value;
    }

    pub fn setGeneratorThis(self: *Object, rt: *JSRuntime, next_value: JSValue) void {
        replaceOwnedValue(rt, self.generatorThisSlot(), next_value);
    }

    pub fn generatorThis(self: *const Object) ?JSValue {
        if (self.generatorPayloadConst()) |payload| {
            const execution = payload.execution orelse return null;
            return execution.this_value;
        }
        return null;
    }

    pub fn generatorArgs(self: *const Object) []JSValue {
        if (self.generatorPayloadConst()) |payload| {
            const execution = payload.execution orelse return &.{};
            return execution.suspended.storage.frame.args;
        }
        return &.{};
    }

    pub fn generatorCaptures(self: *const Object) []*var_ref_mod.VarRef {
        if (self.generatorPayloadConst()) |payload| {
            const execution = payload.execution orelse return &.{};
            return execution.suspended.storage.frame.var_refs;
        }
        return &.{};
    }

    pub fn generatorActualArgCountSlot(self: *Object) *u16 {
        return &self.generatorLiveExecution().actual_arg_count;
    }

    pub fn generatorActualArgCount(self: *const Object) usize {
        if (self.generatorPayloadConst()) |payload| {
            const execution = payload.execution orelse return 0;
            return execution.actual_arg_count;
        }
        return 0;
    }

    pub fn generatorExecutionStateSlot(self: *Object) *SuspendedExecutionState {
        return &self.generatorLiveExecution().suspended;
    }

    pub fn generatorExecutionState(self: *const Object) *const SuspendedExecutionState {
        if (self.generatorPayloadConst()) |payload| {
            const execution = payload.execution orelse return &empty_suspended_execution_state;
            return &execution.suspended;
        }
        std.debug.assert(self.flags.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorStackUsesCombinedStorage(self: *Object) bool {
        const payload = self.generatorPayload() orelse return false;
        const execution = payload.execution orelse return false;
        return execution.stackUsesCombinedStorage();
    }

    pub fn generatorCombinedFrameStorage(self: *Object) []JSValue {
        const payload = self.generatorPayload() orelse return &.{};
        const execution = payload.execution orelse return &.{};
        return execution.combinedFrameStorage();
    }

    pub fn generatorFrameUsesCombinedStorage(self: *Object) bool {
        const payload = self.generatorPayload() orelse return false;
        const execution = payload.execution orelse return false;
        return execution.frameUsesCombinedStorage();
    }

    pub fn generatorCanRetainResidentStorageOwnership(self: *Object) bool {
        const payload = self.generatorPayload() orelse return false;
        const execution = payload.execution orelse return false;
        return execution.canRetainResidentStorageOwnership();
    }

    /// Called by the outer call wrapper after its live Frame and Stack have
    /// deinitialized. A running state cannot be freed inside the return opcode:
    /// both live owners still borrow/alias fields until VM unwind completes.
    pub fn finalizeGeneratorExecutionCompletion(self: *Object, rt: *JSRuntime) void {
        const payload = self.generatorPayload() orelse return;
        const execution = payload.execution orelse return;
        if (!execution.completionPending()) return;
        std.debug.assert(!execution.suspended.running_aliases);
        execution.setCompletionPending(false);
        destroyGeneratorExecutionState(rt, &payload.execution);
    }

    pub fn generatorCurrentFunctionSlot(self: *Object) *JSValue {
        return &self.generatorLiveExecution().current_function;
    }

    pub fn setGeneratorCurrentFunction(self: *Object, rt: *JSRuntime, next_value: JSValue) void {
        replaceOwnedValue(rt, self.generatorCurrentFunctionSlot(), next_value);
    }

    pub fn generatorCurrentFunction(self: *const Object) ?JSValue {
        if (self.generatorPayloadConst()) |payload| {
            const execution = payload.execution orelse return null;
            if (execution.current_function.isUndefined()) return null;
            return execution.current_function;
        }
        return null;
    }

    pub fn generatorYieldStarIteratorSlot(self: *Object) *JSValue {
        return &self.generatorLiveExecution().yield_star_iterator;
    }

    pub fn setGeneratorYieldStarIterator(self: *Object, rt: *JSRuntime, next_value: JSValue) void {
        replaceOwnedValue(rt, self.generatorYieldStarIteratorSlot(), next_value);
    }

    pub fn clearGeneratorYieldStarIterator(self: *Object, rt: *JSRuntime) void {
        destroyOwnedValue(rt, self.generatorYieldStarIteratorSlot());
    }

    pub fn generatorYieldStarIterator(self: *const Object) ?JSValue {
        if (self.generatorPayloadConst()) |payload| {
            const execution = payload.execution orelse return null;
            if (execution.yield_star_iterator.isUndefined()) return null;
            return execution.yield_star_iterator;
        }
        return null;
    }

    pub fn generatorAsyncPromiseSlot(self: *Object) *?JSValue {
        if (self.generatorPayload()) |payload| return &payload.async_promise;
        std.debug.assert(self.flags.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorAsyncPromise(self: *const Object) ?JSValue {
        if (self.generatorPayloadConst()) |payload| return payload.async_promise;
        return null;
    }

    pub fn generatorPcSlot(self: *Object) *usize {
        return &self.generatorLiveExecution().suspended.pc;
    }

    pub fn generatorPc(self: *const Object) usize {
        if (self.generatorPayloadConst()) |payload| {
            const execution = payload.execution orelse return 0;
            return execution.suspended.pc;
        }
        return 0;
    }

    pub fn generatorResumeCompletionTypeSlot(self: *Object) *i32 {
        if (self.generatorPayload()) |payload| return &payload.resume_completion_type;
        std.debug.assert(self.flags.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorResumeCompletionType(self: *const Object) i32 {
        if (self.generatorPayloadConst()) |payload| return payload.resume_completion_type;
        return 0;
    }

    pub fn generatorDoneSlot(self: *Object) *bool {
        if (self.generatorPayload()) |payload| return &payload.done;
        std.debug.assert(self.flags.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorDone(self: *const Object) bool {
        if (self.generatorPayloadConst()) |payload| return payload.done;
        return false;
    }

    /// End the resident generator/async-function execution record exactly once.
    ///
    /// QuickJS funnels normal return, injected return/throw, and exceptional
    /// completion through `free_generator_stack()` /
    /// `js_async_generator_complete()`: the parked `JSAsyncFunctionState` is
    /// released immediately instead of being retained by the completed
    /// iterator object. zjs keeps the same owners in one separately allocated
    /// execution record, so completion can return the entire record to the
    /// allocator while retaining only the compact state discriminator. This
    /// helper is deliberately cold;
    /// ordinary function returns still pay only the existing nullable-generator
    /// branch in the VM return handler.
    pub noinline fn completeGeneratorExecution(self: *Object, rt: *JSRuntime) void {
        const payload = self.generatorPayload() orelse {
            std.debug.assert(self.flags.class_payload_kind == .generator);
            unreachable;
        };

        payload.done = true;
        payload.just_yielded = false;
        payload.resume_completion_type = 0;
        payload.yield_star_suspended = false;
        // Clear the borrowed realm before the execution record releases its
        // current-function owner. Raw continuations unregister below.
        payload.realm_global_ptr = null;

        if (payload.execution) |execution| {
            if (execution.suspended.running_aliases) {
                // The live Frame borrows call bindings and the live Stack may
                // point into the execution allocation. Publish completion now;
                // the outer call wrapper releases the record after both unwind.
                execution.setCompletionPending(true);
            } else {
                destroyGeneratorExecutionState(rt, &payload.execution);
            }
        }

        // Only marker-less internal continuations need this fallback while
        // alive. A completed qjs generator no longer owns a func_state/realm
        // edge, so unregister the corresponding borrowed holder as well.
        self.pruneBorrowedReferenceHolderIfEmpty(rt);
    }

    pub fn generatorExecutingSlot(self: *Object) *bool {
        if (self.generatorPayload()) |payload| return &payload.executing;
        if (self.iteratorPayload()) |payload| return &payload.executing;
        std.debug.assert(self.flags.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorExecuting(self: *const Object) bool {
        if (self.generatorPayloadConst()) |payload| return payload.executing;
        if (self.iteratorPayloadConst()) |payload| return payload.executing;
        return false;
    }

    pub fn generatorStartedSlot(self: *Object) *bool {
        if (self.generatorPayload()) |payload| return &payload.started;
        std.debug.assert(self.flags.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorStarted(self: *const Object) bool {
        if (self.generatorPayloadConst()) |payload| return payload.started;
        return false;
    }

    pub fn generatorJustYieldedSlot(self: *Object) *bool {
        if (self.generatorPayload()) |payload| return &payload.just_yielded;
        std.debug.assert(self.flags.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorJustYielded(self: *const Object) bool {
        if (self.generatorPayloadConst()) |payload| return payload.just_yielded;
        return false;
    }

    pub fn generatorYieldStarSuspendedSlot(self: *Object) *bool {
        if (self.generatorPayload()) |payload| return &payload.yield_star_suspended;
        std.debug.assert(self.flags.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorYieldStarSuspended(self: *const Object) bool {
        if (self.generatorPayloadConst()) |payload| return payload.yield_star_suspended;
        return false;
    }

    pub fn generatorSuspendKindSlot(self: *Object) *u8 {
        if (self.generatorPayload()) |payload| return &payload.suspend_kind;
        std.debug.assert(self.flags.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorSuspendKind(self: *const Object) GeneratorSuspendKind {
        if (self.generatorPayloadConst()) |payload| return @enumFromInt(payload.suspend_kind);
        return .none;
    }

    pub fn asyncGeneratorStateSlot(self: *Object) *u8 {
        if (self.generatorPayload()) |payload| return &payload.async_state;
        std.debug.assert(self.flags.class_payload_kind == .generator);
        unreachable;
    }

    pub fn asyncGeneratorQueueSlot(self: *Object) *[]AsyncGeneratorRequest {
        if (self.generatorPayload()) |payload| return &payload.async_queue;
        std.debug.assert(self.flags.class_payload_kind == .generator);
        unreachable;
    }

    pub fn asyncGeneratorQueue(self: *const Object) []AsyncGeneratorRequest {
        if (self.generatorPayloadConst()) |payload| return payload.async_queue;
        return &.{};
    }

    pub fn asyncGeneratorQueueCapacitySlot(self: *Object) *usize {
        if (self.generatorPayload()) |payload| return &payload.async_queue_capacity;
        std.debug.assert(self.flags.class_payload_kind == .generator);
        unreachable;
    }

    pub fn functionSourceSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        return &(try self.ensureFunctionRarePayload(rt)).source;
    }

    pub fn functionSource(self: *const Object) ?JSValue {
        if (self.functionRarePayloadConst()) |payload| return payload.source;
        return null;
    }

    pub fn hostFunctionKindSlot(self: *Object) *i32 {
        std.debug.assert(!class.isBytecodeFunctionClass(self.class_id));
        if (self.functionPayload()) |payload| return &payload.native.host_function_kind;
        std.debug.assert(self.flags.class_payload_kind == .function);
        unreachable;
    }

    pub fn hostFunctionKind(self: *const Object) i32 {
        if (class.isBytecodeFunctionClass(self.class_id)) return 0;
        if (self.functionPayloadConst()) |payload| return payload.native.host_function_kind;
        return 0;
    }

    pub fn nativeFunctionIdSlot(self: *Object) *i32 {
        std.debug.assert(!class.isBytecodeFunctionClass(self.class_id));
        if (self.functionPayload()) |payload| return &payload.native.native_function_id;
        std.debug.assert(self.flags.class_payload_kind == .function);
        unreachable;
    }

    pub fn nativeFunctionId(self: *const Object) i32 {
        if (class.isBytecodeFunctionClass(self.class_id)) return 0;
        if (self.functionPayloadConst()) |payload| return payload.native.native_function_id;
        return 0;
    }

    pub fn setNativeBuiltinIdAndRecord(self: *Object, rt: *JSRuntime, native_id: i32) void {
        self.nativeFunctionIdSlot().* = native_id;
        const record = if (function.decodeNativeBuiltinId(native_id)) |native_ref|
            rt.internalBuiltinRecord(@intCast(@intFromEnum(native_ref.domain)), native_ref.id)
        else
            null;
        self.nativeRecordSlot().* = record;
    }

    // Divergence B: on-object memo of the resolved internal record. `Slot`
    // returns a mutable pointer to the payload field so the hot call site can
    // lazily populate it after its first DECODE+LOOKUP; the read-only accessor
    // returns null when there is no function payload (matching nativeFunctionId's
    // 0 default) so a non-native callable simply misses the memo.
    pub fn nativeRecordSlot(self: *Object) *?*const host_function.InternalRecord {
        std.debug.assert(self.class_id == class.ids.c_function);
        if (self.functionPayload()) |payload| return &payload.native.call_cache;
        std.debug.assert(self.flags.class_payload_kind == .function);
        unreachable;
    }

    pub fn nativeRecord(self: *const Object) ?*const host_function.InternalRecord {
        if (self.class_id != class.ids.c_function) return null;
        if (self.functionPayloadConst()) |payload| return payload.native.call_cache;
        return null;
    }

    /// Resolve the two fields consumed together by the native-call boundary
    /// from one payload load. QuickJS reads both directly from
    /// `JSObject.u.cfunc` (`c_function` and `realm`; quickjs.c:17576-17603).
    /// Keeping the pair together avoids re-entering the generic realm resolver
    /// after the call target has already proved this is a C-function object.
    pub const NativeCallTarget = struct {
        record: *const host_function.InternalRecord,
        realm_global_ptr: ?*Object,
    };

    pub fn nativeCallTarget(self: *const Object) ?NativeCallTarget {
        if (self.class_id != class.ids.c_function) return null;
        const payload = self.functionPayloadConst() orelse return null;
        const record = payload.native.call_cache orelse return null;
        return .{
            .record = record,
            .realm_global_ptr = payload.native.realm_global_ptr,
        };
    }

    pub fn externalHostFunctionIdSlot(self: *Object) *u32 {
        std.debug.assert(!class.isBytecodeFunctionClass(self.class_id));
        if (self.functionPayload()) |payload| return &payload.native.external_host_function_id;
        std.debug.assert(self.flags.class_payload_kind == .function);
        unreachable;
    }

    pub fn externalHostFunctionId(self: *const Object) u32 {
        if (class.isBytecodeFunctionClass(self.class_id)) return 0;
        if (self.functionPayloadConst()) |payload| return payload.native.external_host_function_id;
        return 0;
    }

    pub fn functionIteratorWrapMethodSlot(self: *Object, rt: *JSRuntime) !*u8 {
        return &(try self.ensureFunctionRarePayload(rt)).iterator_wrap_method;
    }

    pub fn functionIteratorWrapMethod(self: *const Object) u8 {
        if (self.functionRarePayloadConst()) |payload| return payload.iterator_wrap_method;
        return 0;
    }

    pub fn functionPrimitivePrototypeSlot(self: *Object, rt: *JSRuntime, slot: PrimitivePrototypeSlot) !*?JSValue {
        const payload = try self.ensureFunctionRarePayload(rt);
        return &payload.primitive_prototypes[@intFromEnum(slot)];
    }

    pub fn functionPrimitivePrototype(self: *const Object, slot: PrimitivePrototypeSlot) ?JSValue {
        if (self.functionRarePayloadConst()) |payload| return payload.primitive_prototypes[@intFromEnum(slot)];
        return null;
    }

    pub fn nativeDispatchNameSlot(self: *Object) *atom.Atom {
        std.debug.assert(!class.isBytecodeFunctionClass(self.class_id));
        if (self.functionPayload()) |payload| return &payload.native.native_dispatch_name;
        std.debug.assert(self.flags.class_payload_kind == .function);
        unreachable;
    }

    pub fn nativeDispatchName(self: *const Object) atom.Atom {
        if (class.isBytecodeFunctionClass(self.class_id)) return atom.null_atom;
        if (self.functionPayloadConst()) |payload| return payload.native.native_dispatch_name;
        return atom.null_atom;
    }

    /// Return the realm's Annex-B RegExp snapshot only when the intrinsic
    /// constructor was installed. The cache-presence check and state lookup
    /// share one RealmPayload load, mirroring a direct JSContext field read.
    pub inline fn installedRealmRegExpLegacyStatics(self: *Object) ?*RegExpLegacyStatics {
        const payload = self.realmPayload() orelse return null;
        if (payload.cached_values[@intFromEnum(RealmValueSlot.regexp_constructor)] == null) return null;
        return payload.regexp_legacy_statics;
    }

    pub fn ensureInstalledRealmRegExpLegacyStatics(self: *Object, rt: *JSRuntime) !?*RegExpLegacyStatics {
        const payload = self.realmPayload() orelse return null;
        if (payload.cached_values[@intFromEnum(RealmValueSlot.regexp_constructor)] == null) return null;
        if (payload.regexp_legacy_statics) |legacy| return legacy;
        const legacy = try rt.createRuntime(RegExpLegacyStatics);
        legacy.* = .{};
        payload.regexp_legacy_statics = legacy;
        return legacy;
    }

    pub fn arrayBuiltinMarkerSlot(self: *Object, rt: *JSRuntime) !*ArrayBuiltinMarker {
        return &(try self.ensureFunctionRarePayload(rt)).array_builtin_marker;
    }

    pub fn arrayBuiltinMarker(self: *const Object) ArrayBuiltinMarker {
        if (self.functionRarePayloadConst()) |payload| return payload.array_builtin_marker;
        return .none;
    }

    pub fn typedArrayBuiltinMarker(self: *const Object) TypedArrayBuiltinMarker {
        if (self.functionRarePayloadConst()) |payload| return payload.typed_array_builtin_marker;
        return .none;
    }

    pub fn internalCallableTag(self: *const Object) host_function.InternalCallableTag {
        if (self.functionRarePayloadConst()) |payload| return payload.internal_callable_tag;
        return .none;
    }

    pub fn setInternalCallableTag(self: *Object, rt: *JSRuntime, tag: host_function.InternalCallableTag) !void {
        (try self.internalCallableTagSlot(rt)).* = tag;
    }

    pub fn internalCallableTagSlot(self: *Object, rt: *JSRuntime) !*host_function.InternalCallableTag {
        return &(try self.ensureFunctionRarePayload(rt)).internal_callable_tag;
    }

    pub fn arrayIteratorKind(self: *const Object) u8 {
        if (self.functionRarePayloadConst()) |payload| return payload.array_iterator_kind;
        return 0;
    }

    pub fn isIteratorIdentityFunction(self: *const Object) bool {
        if (self.functionRarePayloadConst()) |payload| return payload.iterator_identity;
        return false;
    }

    pub fn isArrayIteratorNextFunction(self: *const Object) bool {
        if (self.functionRarePayloadConst()) |payload| return payload.array_iterator_next;
        return false;
    }

    pub fn isGeneratorNextFunction(self: *const Object) bool {
        if (self.functionRarePayloadConst()) |payload| return payload.generator_next;
        return false;
    }

    pub fn addGeneratorNextFunction(self: *Object, rt: *JSRuntime) !void {
        const payload = try self.ensureFunctionRarePayload(rt);
        payload.generator_next = true;
    }

    pub fn isThrowTypeErrorIntrinsicFunction(self: *const Object) bool {
        if (self.functionRarePayloadConst()) |payload| return payload.throw_type_error_intrinsic;
        return false;
    }

    pub fn isAsyncIteratorAsyncDisposeFunction(self: *const Object) bool {
        if (self.functionRarePayloadConst()) |payload| return payload.async_iterator_async_dispose;
        return false;
    }

    pub fn isAsyncGeneratorPrototypeMethod(self: *const Object) bool {
        if (self.functionRarePayloadConst()) |payload| return payload.async_generator_method;
        return false;
    }

    pub fn iteratorHelperMethod(self: *const Object) u8 {
        if (self.functionRarePayloadConst()) |payload| return payload.iterator_helper_method;
        return 0;
    }

    pub fn asyncFromSyncIteratorMethod(self: *const Object) u8 {
        if (self.functionRarePayloadConst()) |payload| return payload.async_from_sync_iterator_method;
        return 0;
    }

    pub fn disposableStackMethod(self: *const Object) u8 {
        if (self.functionRarePayloadConst()) |payload| return payload.disposable_stack_method;
        return 0;
    }

    pub fn asyncDisposableStackMethod(self: *const Object) u8 {
        if (self.functionRarePayloadConst()) |payload| return payload.async_disposable_stack_method;
        return 0;
    }

    pub fn addArrayBuiltinMarker(self: *Object, rt: *JSRuntime, marker: ArrayBuiltinMarker) bool {
        if (marker == .none) return true;
        const payload = self.ensureFunctionRarePayload(rt) catch return false;
        return setArrayBuiltinMarker(payload, marker);
    }

    pub fn addTypedArrayBuiltinMarker(self: *Object, rt: *JSRuntime, marker: TypedArrayBuiltinMarker) bool {
        if (marker == .none) return true;
        const payload = self.ensureFunctionRarePayload(rt) catch return false;
        return setTypedArrayBuiltinMarker(payload, marker);
    }

    pub fn addArrayIteratorKind(self: *Object, rt: *JSRuntime, kind: u8) bool {
        if (kind == 0) return true;
        const payload = self.ensureFunctionRarePayload(rt) catch return false;
        return setArrayIteratorKind(payload, kind);
    }

    pub fn addIteratorIdentityFunction(self: *Object, rt: *JSRuntime) bool {
        const payload = self.ensureFunctionRarePayload(rt) catch return false;
        payload.iterator_identity = true;
        return true;
    }

    pub fn addArrayIteratorNextFunction(self: *Object, rt: *JSRuntime) bool {
        const payload = self.ensureFunctionRarePayload(rt) catch return false;
        payload.array_iterator_next = true;
        return true;
    }

    pub fn addThrowTypeErrorIntrinsicFunction(self: *Object, rt: *JSRuntime) !void {
        const payload = try self.ensureFunctionRarePayload(rt);
        payload.throw_type_error_intrinsic = true;
        payload.internal_callable_tag = .throw_type_error_intrinsic;
    }

    pub fn addAsyncIteratorAsyncDisposeFunction(self: *Object, rt: *JSRuntime) bool {
        const payload = self.ensureFunctionRarePayload(rt) catch return false;
        payload.async_iterator_async_dispose = true;
        return true;
    }

    pub fn addAsyncGeneratorPrototypeMethod(self: *Object, rt: *JSRuntime) bool {
        const payload = self.ensureFunctionRarePayload(rt) catch return false;
        payload.async_generator_method = true;
        return true;
    }

    pub fn addIteratorHelperMethod(self: *Object, rt: *JSRuntime, method_id: u8) bool {
        if (method_id == 0) return true;
        const payload = self.ensureFunctionRarePayload(rt) catch return false;
        if (payload.iterator_helper_method != 0 and payload.iterator_helper_method != method_id) return false;
        payload.iterator_helper_method = method_id;
        return true;
    }

    pub fn addAsyncFromSyncIteratorMethod(self: *Object, rt: *JSRuntime, method_id: u8) bool {
        if (method_id == 0) return true;
        const payload = self.ensureFunctionRarePayload(rt) catch return false;
        if (payload.async_from_sync_iterator_method != 0 and payload.async_from_sync_iterator_method != method_id) return false;
        payload.async_from_sync_iterator_method = method_id;
        return true;
    }

    pub fn addDisposableStackMethod(self: *Object, rt: *JSRuntime, method_id: u8) bool {
        if (method_id == 0) return true;
        const payload = self.ensureFunctionRarePayload(rt) catch return false;
        return setDisposableStackMethod(payload, method_id);
    }

    pub fn addAsyncDisposableStackMethod(self: *Object, rt: *JSRuntime, method_id: u8) bool {
        if (method_id == 0) return true;
        const payload = self.ensureFunctionRarePayload(rt) catch return false;
        return setAsyncDisposableStackMethod(payload, method_id);
    }

    pub fn addCollectionMethodOwnerClass(self: *Object, rt: *JSRuntime, owner_class: class.ClassId) bool {
        if (owner_class == class.invalid_class_id) return true;
        const payload = self.ensureFunctionRarePayload(rt) catch return false;
        return setCollectionMethodOwnerClass(payload, owner_class);
    }

    fn setArrayBuiltinMarker(payload: *FunctionRarePayload, marker: ArrayBuiltinMarker) bool {
        if (payload.array_builtin_marker != .none and payload.array_builtin_marker != marker) return false;
        payload.array_builtin_marker = marker;
        return true;
    }

    fn setTypedArrayBuiltinMarker(payload: *FunctionRarePayload, marker: TypedArrayBuiltinMarker) bool {
        if (payload.typed_array_builtin_marker != .none and payload.typed_array_builtin_marker != marker) return false;
        payload.typed_array_builtin_marker = marker;
        return true;
    }

    fn setArrayIteratorKind(payload: *FunctionRarePayload, kind: u8) bool {
        if (payload.array_iterator_kind != 0 and payload.array_iterator_kind != kind) return false;
        payload.array_iterator_kind = kind;
        return true;
    }

    fn setDisposableStackMethod(payload: *FunctionRarePayload, method_id: u8) bool {
        if (payload.disposable_stack_method != 0 and payload.disposable_stack_method != method_id) return false;
        payload.disposable_stack_method = method_id;
        return true;
    }

    fn setAsyncDisposableStackMethod(payload: *FunctionRarePayload, method_id: u8) bool {
        if (payload.async_disposable_stack_method != 0 and payload.async_disposable_stack_method != method_id) return false;
        payload.async_disposable_stack_method = method_id;
        return true;
    }

    fn setCollectionMethodOwnerClass(payload: *FunctionRarePayload, owner_class: class.ClassId) bool {
        if (payload.collection_method_owner_class != class.invalid_class_id and payload.collection_method_owner_class != owner_class) return false;
        payload.collection_method_owner_class = owner_class;
        return true;
    }

    pub fn collectionMethodOwnerClassSlot(self: *Object, rt: *JSRuntime) !*class.ClassId {
        return &(try self.ensureFunctionRarePayload(rt)).collection_method_owner_class;
    }

    pub fn collectionMethodOwnerClass(self: *const Object) class.ClassId {
        if (self.functionRarePayloadConst()) |payload| return payload.collection_method_owner_class;
        return class.invalid_class_id;
    }

    pub fn setFunctionBytecodeValue(self: *Object, rt: *JSRuntime, next_value: JSValue) !void {
        errdefer next_value.free(rt);
        if (!next_value.isFunctionBytecode()) return error.InvalidBytecode;
        std.debug.assert(class.isBytecodeFunctionClass(self.class_id));
        const header = next_value.objectHeader() orelse return error.InvalidBytecode;
        std.debug.assert(header.meta().kind == .function_bytecode);
        const fb: *FunctionBytecode = @alignCast(@fieldParentPtr("header", header));
        // Publish only fully executable FBs. This moves the compatibility-view
        // allocation to closure construction so resolveInlineTarget has a
        // non-null invariant and cannot turn OOM into a fast-path miss later.
        _ = try fb.ensureCachedView(&rt.memory, &rt.atoms);
        const old_fb = self.u.bytecode_function.function_bytecode;
        self.u.bytecode_function.function_bytecode = fb;
        if (old_fb) |old| gc.release(rt, &old.header);
    }

    /// Bind a bytecode closure to its realm using qjs's ownership shape:
    /// `JSFunctionBytecode.realm` owns the common realm once, while all closure
    /// objects that reference that FB merely derive it. As in qjs, a compiled
    /// FB belongs to exactly one realm; evaluation in another realm must compile
    /// or deserialize a distinct FB rather than mutating/shadowing this owner.
    pub fn bindBytecodeFunctionRealmGlobal(self: *Object, global: *Object) !void {
        std.debug.assert(class.isBytecodeFunctionClass(self.class_id));
        const fb = self.u.bytecode_function.function_bytecode orelse return error.InvalidBytecode;
        if (fb.realm_global_header == null) {
            gc.retain(&global.header);
            fb.realm_global_header = &global.header;
            return;
        }
        if (fb.realm_global_header == &global.header) return;
        return error.InvalidBytecode;
    }

    /// Direct qjs `u.func` view for a proven bytecode-function object.
    pub inline fn bytecodeFunctionStoragePtr(self: *Object) *BytecodeFunctionStorage {
        std.debug.assert(class.isBytecodeFunctionClass(self.class_id));
        std.debug.assert(self.flags.class_payload_kind == .function);
        return &self.u.bytecode_function;
    }

    pub inline fn bytecodeFunctionStoragePtrConst(self: *const Object) *const BytecodeFunctionStorage {
        std.debug.assert(class.isBytecodeFunctionClass(self.class_id));
        std.debug.assert(self.flags.class_payload_kind == .function);
        return &self.u.bytecode_function;
    }

    pub fn functionBytecode(self: *const Object) ?JSValue {
        if (!class.isBytecodeFunctionClass(self.class_id)) return null;
        const fb = self.u.bytecode_function.function_bytecode orelse return null;
        return JSValue.functionBytecode(&fb.header);
    }

    /// Bytecode backing a suspended generator frame. A generator instance is
    /// not itself a bytecode function (and must not make the ordinary function
    /// accessor pay for this uncommon derivation). qjs reaches the FB through
    /// JSAsyncFunctionState.frame.cur_func in the same way.
    pub fn generatorFunctionBytecode(self: *const Object) ?JSValue {
        const current = self.generatorCurrentFunction() orelse return null;
        if (current.isFunctionBytecode()) return current;
        const current_object = Object.expect(current) catch return null;
        if (current_object == self) return null;
        return current_object.functionBytecode();
    }

    pub fn functionClassFieldsInitSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        return &(try self.ensureFunctionRarePayload(rt)).class_fields_init;
    }

    pub fn functionClassFieldsInit(self: *const Object) ?JSValue {
        if (self.functionRarePayloadConst()) |payload| return payload.class_fields_init;
        return null;
    }

    pub fn functionImportMetaSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        return &(try self.ensureFunctionRarePayload(rt)).import_meta;
    }

    pub fn functionImportMeta(self: *const Object) ?JSValue {
        if (self.functionRarePayloadConst()) |payload| return payload.import_meta;
        return null;
    }

    pub fn functionProxyRevokeTargetSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        return &(try self.ensureFunctionRarePayload(rt)).proxy_revoke_target;
    }

    pub fn functionProxyRevokeTarget(self: *const Object) ?JSValue {
        if (self.functionRarePayloadConst()) |payload| return payload.proxy_revoke_target;
        return null;
    }

    pub fn functionPromiseCapabilitySlotSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        return &(try self.ensureFunctionRarePayload(rt)).promise_capability_slot;
    }

    pub fn functionPromiseCapabilitySlot(self: *const Object) ?JSValue {
        if (self.functionRarePayloadConst()) |payload| return payload.promise_capability_slot;
        return null;
    }

    pub fn functionPromiseResolvingTargetSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        return &(try self.ensureFunctionRarePayload(rt)).promise_resolving_target;
    }

    pub fn functionPromiseResolvingTarget(self: *const Object) ?JSValue {
        if (self.functionRarePayloadConst()) |payload| return payload.promise_resolving_target;
        return null;
    }

    pub fn functionPromiseResolvingStateSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        return &(try self.ensureFunctionRarePayload(rt)).promise_resolving_state;
    }

    pub fn functionPromiseResolvingState(self: *const Object) ?JSValue {
        if (self.functionRarePayloadConst()) |payload| return payload.promise_resolving_state;
        return null;
    }

    pub fn functionPromiseResolvingRejectSlot(self: *Object, rt: *JSRuntime) !*bool {
        return &(try self.ensureFunctionRarePayload(rt)).promise_resolving_reject;
    }

    pub fn functionPromiseResolvingReject(self: *const Object) bool {
        if (self.functionRarePayloadConst()) |payload| return payload.promise_resolving_reject;
        return false;
    }

    pub fn functionPromiseThenableTargetSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        return &(try self.ensureFunctionRarePayload(rt)).promise_thenable_target;
    }

    pub fn functionPromiseThenableTarget(self: *const Object) ?JSValue {
        if (self.functionRarePayloadConst()) |payload| return payload.promise_thenable_target;
        return null;
    }

    pub fn functionPromiseThenableThisSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        return &(try self.ensureFunctionRarePayload(rt)).promise_thenable_this;
    }

    pub fn functionPromiseThenableThis(self: *const Object) ?JSValue {
        if (self.functionRarePayloadConst()) |payload| return payload.promise_thenable_this;
        return null;
    }

    pub fn functionPromiseThenableThenSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        return &(try self.ensureFunctionRarePayload(rt)).promise_thenable_then;
    }

    pub fn functionPromiseThenableThen(self: *const Object) ?JSValue {
        if (self.functionRarePayloadConst()) |payload| return payload.promise_thenable_then;
        return null;
    }

    pub fn functionPromiseReactionRecordSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        return &(try self.ensureFunctionRarePayload(rt)).promise_reaction_record;
    }

    pub fn functionPromiseReactionRecord(self: *const Object) ?JSValue {
        if (self.functionRarePayloadConst()) |payload| return payload.promise_reaction_record;
        return null;
    }

    pub fn functionPromiseReactionValueSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        return &(try self.ensureFunctionRarePayload(rt)).promise_reaction_value;
    }

    pub fn functionPromiseReactionValue(self: *const Object) ?JSValue {
        if (self.functionRarePayloadConst()) |payload| return payload.promise_reaction_value;
        return null;
    }

    pub fn functionPromiseReactionIsRejectedSlot(self: *Object, rt: *JSRuntime) !*bool {
        return &(try self.ensureFunctionRarePayload(rt)).promise_reaction_is_rejected;
    }

    pub fn functionPromiseReactionIsRejected(self: *const Object) bool {
        if (self.functionRarePayloadConst()) |payload| return payload.promise_reaction_is_rejected;
        return false;
    }

    pub fn functionPromiseCombinatorStateSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        return &(try self.ensureFunctionRarePayload(rt)).promise_combinator_state;
    }

    pub fn functionPromiseCombinatorState(self: *const Object) ?JSValue {
        if (self.functionRarePayloadConst()) |payload| return payload.promise_combinator_state;
        return null;
    }

    pub fn functionPromiseCombinatorModeSlot(self: *Object, rt: *JSRuntime) !*u8 {
        return &(try self.ensureFunctionRarePayload(rt)).promise_combinator_mode;
    }

    pub fn functionPromiseCombinatorMode(self: *const Object) u8 {
        if (self.functionRarePayloadConst()) |payload| return payload.promise_combinator_mode;
        return 0;
    }

    pub fn functionPromiseCombinatorIndexSlot(self: *Object, rt: *JSRuntime) !*u32 {
        return &(try self.ensureFunctionRarePayload(rt)).promise_combinator_index;
    }

    pub fn functionPromiseCombinatorIndex(self: *const Object) u32 {
        if (self.functionRarePayloadConst()) |payload| return payload.promise_combinator_index;
        return 0;
    }

    pub fn functionPromiseCombinatorCalledSlot(self: *Object, rt: *JSRuntime) !*bool {
        return &(try self.ensureFunctionRarePayload(rt)).promise_combinator_called;
    }

    pub fn functionPromiseCombinatorCalled(self: *const Object) bool {
        if (self.functionRarePayloadConst()) |payload| return payload.promise_combinator_called;
        return false;
    }

    pub fn functionPromiseFinallyPayloadSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        return &(try self.ensureFunctionRarePayload(rt)).promise_finally_payload;
    }

    pub fn functionPromiseFinallyPayload(self: *const Object) ?JSValue {
        if (self.functionRarePayloadConst()) |payload| return payload.promise_finally_payload;
        return null;
    }

    pub fn functionPromiseFinallyCallbackSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        return &(try self.ensureFunctionRarePayload(rt)).promise_finally_callback;
    }

    pub fn functionPromiseFinallyCallback(self: *const Object) ?JSValue {
        if (self.functionRarePayloadConst()) |payload| return payload.promise_finally_callback;
        return null;
    }

    pub fn functionPromiseFinallyConstructorSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        return &(try self.ensureFunctionRarePayload(rt)).promise_finally_constructor;
    }

    pub fn functionPromiseFinallyConstructor(self: *const Object) ?JSValue {
        if (self.functionRarePayloadConst()) |payload| return payload.promise_finally_constructor;
        return null;
    }

    pub fn functionPromiseFinallyModeSlot(self: *Object, rt: *JSRuntime) !*u8 {
        return &(try self.ensureFunctionRarePayload(rt)).promise_finally_mode;
    }

    pub fn functionPromiseFinallyMode(self: *const Object) u8 {
        if (self.functionRarePayloadConst()) |payload| return payload.promise_finally_mode;
        return 0;
    }

    pub fn functionAsyncDisposeStackSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        return &(try self.ensureFunctionRarePayload(rt)).async_dispose_stack;
    }

    pub fn functionAsyncDisposeStack(self: *const Object) ?JSValue {
        if (self.functionRarePayloadConst()) |payload| return payload.async_dispose_stack;
        return null;
    }

    pub fn functionAsyncDisposeRejectedSlot(self: *Object, rt: *JSRuntime) !*bool {
        return &(try self.ensureFunctionRarePayload(rt)).async_dispose_rejected;
    }

    pub fn functionAsyncDisposeRejected(self: *const Object) bool {
        if (self.functionRarePayloadConst()) |payload| return payload.async_dispose_rejected;
        return false;
    }

    pub fn functionAsyncContinuationSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        return &(try self.ensureFunctionRarePayload(rt)).async_function_continuation;
    }

    pub fn functionAsyncContinuation(self: *const Object) ?JSValue {
        if (self.functionRarePayloadConst()) |payload| return payload.async_function_continuation;
        return null;
    }

    pub fn functionAsyncContinuationRejectedSlot(self: *Object, rt: *JSRuntime) !*bool {
        return &(try self.ensureFunctionRarePayload(rt)).async_function_rejected;
    }

    pub fn functionAsyncContinuationRejected(self: *const Object) bool {
        if (self.functionRarePayloadConst()) |payload| return payload.async_function_rejected;
        return false;
    }

    pub fn functionAsyncGeneratorActionSlot(self: *Object, rt: *JSRuntime) !*u8 {
        return &(try self.ensureFunctionRarePayload(rt)).async_generator_action;
    }

    pub fn functionAsyncGeneratorAction(self: *const Object) u8 {
        if (self.functionRarePayloadConst()) |payload| return payload.async_generator_action;
        return 0;
    }

    pub fn functionAsyncFromSyncUnwrapDoneSlot(self: *Object, rt: *JSRuntime) !*u8 {
        return &(try self.ensureFunctionRarePayload(rt)).async_from_sync_unwrap_done;
    }

    pub fn functionAsyncFromSyncUnwrapDone(self: *const Object) u8 {
        if (self.functionRarePayloadConst()) |payload| return payload.async_from_sync_unwrap_done;
        return 0;
    }

    pub fn functionRealmTypeErrorConstructorSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        return &(try self.ensureFunctionRarePayload(rt)).realm_type_error_constructor;
    }

    pub fn functionRealmTypeErrorConstructor(self: *const Object) ?JSValue {
        if (self.functionRarePayloadConst()) |payload| return payload.realm_type_error_constructor;
        return null;
    }

    pub fn functionArrowConstructorThisSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        return &(try self.ensureFunctionRarePayload(rt)).arrow_constructor_this;
    }

    pub fn functionArrowConstructorThis(self: *const Object) ?JSValue {
        if (self.functionRarePayloadConst()) |payload| return payload.arrow_constructor_this;
        return null;
    }

    pub fn functionArrowNewTargetSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        return &(try self.ensureFunctionRarePayload(rt)).arrow_new_target;
    }

    pub fn functionArrowNewTarget(self: *const Object) ?JSValue {
        if (self.functionRarePayloadConst()) |payload| return payload.arrow_new_target;
        return null;
    }

    pub fn functionSuperConstructorSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        return &(try self.ensureFunctionRarePayload(rt)).super_constructor;
    }

    pub fn functionSuperConstructor(self: *const Object) ?JSValue {
        if (self.functionRarePayloadConst()) |payload| return payload.super_constructor;
        return null;
    }

    pub fn functionCaptures(self: *const Object) []*var_ref_mod.VarRef {
        if (!class.isBytecodeFunctionClass(self.class_id)) return &.{};
        return self.u.bytecode_function.captureSlice();
    }

    /// Find one closure cell by its immutable FB metadata. Used for the
    /// language's hidden arrow captures (`this` / `new.target`) on cold semantic
    /// paths such as direct eval and super; ordinary opcodes index cells
    /// directly and never scan.
    pub fn functionCaptureCell(self: *const Object, name: atom.Atom) ?*var_ref_mod.VarRef {
        if (!class.isBytecodeFunctionClass(self.class_id)) return null;
        const fb = self.u.bytecode_function.function_bytecode orelse return null;
        const captures = self.u.bytecode_function.captureSlice();
        for (fb.closureVar(), 0..) |capture, index| {
            if (capture.var_name == name and index < captures.len) return captures[index];
        }
        return null;
    }

    /// Replace the closure-captures slice, releasing the previous cells —
    /// the cell-typed `setValueSlice` (ownership of `next_cells` transfers).
    pub fn setFunctionCaptures(self: *Object, rt: *JSRuntime, next_cells: []*var_ref_mod.VarRef) void {
        std.debug.assert(class.isBytecodeFunctionClass(self.class_id));
        var old_cells = self.u.bytecode_function.captureSlice();
        if (self.u.bytecode_function.function_bytecode) |fb| {
            std.debug.assert(next_cells.len == fb.var_refs_len);
        }
        self.u.bytecode_function.var_refs = if (next_cells.len == 0) BytecodeFunctionStorage.emptyVarRefs() else next_cells.ptr;
        destroyVarRefCellSlice(rt, &old_cells);
    }

    pub fn functionLexicalThisSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        return &(try self.ensureFunctionRarePayload(rt)).lexical_this;
    }

    pub fn functionLexicalThis(self: *const Object) ?JSValue {
        if (self.functionRarePayloadConst()) |payload| return payload.lexical_this;
        return null;
    }

    pub fn functionHomeObject(self: *const Object) ?*Object {
        if (!class.isBytecodeFunctionClass(self.class_id)) return null;
        if (self.bytecodeFunctionAuxConst()) |aux| return aux.home_object;
        const stored = self.u.bytecode_function.home_or_aux orelse return null;
        std.debug.assert((@intFromPtr(stored) & bytecode_function_aux_tag) == 0);
        return @ptrCast(@alignCast(stored));
    }

    /// Stores a strong `[[HomeObject]]` edge; callers must not write the slot directly.
    pub fn setFunctionHomeObject(self: *Object, rt: *JSRuntime, home_object: ?*Object) !void {
        std.debug.assert(class.isBytecodeFunctionClass(self.class_id));
        const old_home_object = self.functionHomeObject();
        if (old_home_object == home_object) return;
        if (home_object) |next| gc.retain(&next.header);
        errdefer if (home_object) |next| next.value().free(rt);
        if (self.bytecodeFunctionAux()) |aux| {
            aux.home_object = home_object;
        } else {
            self.u.bytecode_function.home_or_aux = if (home_object) |next| @ptrCast(next) else null;
        }
        if (old_home_object) |old| old.value().free(rt);
    }

    pub fn privateRemapFromSlot(self: *Object) *[]atom.Atom {
        if (self.ordinaryPayload()) |payload| return &payload.private_remap_from;
        if (self.functionRarePayload()) |payload| return &payload.private_remap_from;
        std.debug.assert(self.flags.class_payload_kind == .ordinary or self.flags.class_payload_kind == .function);
        unreachable;
    }

    pub fn privateRemapFromSlotEnsured(self: *Object, rt: *JSRuntime) !*[]atom.Atom {
        if (self.ordinaryPayload()) |payload| return &payload.private_remap_from;
        if (self.flags.class_payload_kind == .function) return &(try self.ensureFunctionRarePayload(rt)).private_remap_from;
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.private_remap_from;
    }

    pub fn privateRemapFrom(self: *const Object) []atom.Atom {
        if (self.ordinaryPayloadConst()) |payload| return payload.private_remap_from;
        if (self.functionRarePayloadConst()) |payload| return payload.private_remap_from;
        return &.{};
    }

    pub fn privateRemapToSlot(self: *Object) *[]atom.Atom {
        if (self.ordinaryPayload()) |payload| return &payload.private_remap_to;
        if (self.functionRarePayload()) |payload| return &payload.private_remap_to;
        std.debug.assert(self.flags.class_payload_kind == .ordinary or self.flags.class_payload_kind == .function);
        unreachable;
    }

    pub fn privateRemapToSlotEnsured(self: *Object, rt: *JSRuntime) !*[]atom.Atom {
        if (self.ordinaryPayload()) |payload| return &payload.private_remap_to;
        if (self.flags.class_payload_kind == .function) return &(try self.ensureFunctionRarePayload(rt)).private_remap_to;
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.private_remap_to;
    }

    pub fn privateRemapTo(self: *const Object) []atom.Atom {
        if (self.ordinaryPayloadConst()) |payload| return payload.private_remap_to;
        if (self.functionRarePayloadConst()) |payload| return payload.private_remap_to;
        return &.{};
    }

    pub fn setCallSiteMetadata(
        self: *Object,
        rt: *JSRuntime,
        file: JSValue,
        function_name: JSValue,
        line: i32,
        column: i32,
        is_native: bool,
    ) !void {
        const payload = try self.ensureOrdinaryPayload(rt);
        const next_file = file.dup();
        errdefer next_file.free(rt);
        const next_function = function_name.dup();
        errdefer next_function.free(rt);
        const old_file = payload.callsite_file;
        const old_function = payload.callsite_function;
        payload.callsite_file = next_file;
        payload.callsite_function = next_function;
        payload.callsite_line = line;
        payload.callsite_column = column;
        payload.is_callsite = true;
        payload.callsite_is_native = is_native;
        if (old_file) |stored| stored.free(rt);
        if (old_function) |stored| stored.free(rt);
    }

    pub fn isCallSite(self: *const Object) bool {
        if (self.ordinaryPayloadConst()) |payload| return payload.is_callsite;
        return false;
    }

    pub fn callSiteFile(self: *const Object) ?JSValue {
        if (self.ordinaryPayloadConst()) |payload| return payload.callsite_file;
        return null;
    }

    pub fn callSiteFunctionName(self: *const Object) ?JSValue {
        if (self.ordinaryPayloadConst()) |payload| return payload.callsite_function;
        return null;
    }

    pub fn callSiteLine(self: *const Object) i32 {
        if (self.ordinaryPayloadConst()) |payload| return payload.callsite_line;
        return 1;
    }

    pub fn callSiteColumn(self: *const Object) i32 {
        if (self.ordinaryPayloadConst()) |payload| return payload.callsite_column;
        return 1;
    }

    pub fn callSiteIsNative(self: *const Object) bool {
        if (self.ordinaryPayloadConst()) |payload| return payload.is_callsite and payload.callsite_is_native;
        return false;
    }

    pub fn setErrorStack(self: *Object, rt: *JSRuntime, stack_value: JSValue) !void {
        const payload = try self.ensureOrdinaryPayload(rt);
        const next_value = stack_value.dup();
        errdefer next_value.free(rt);
        const old_value = payload.error_stack;
        const old_sites = payload.error_stack_sites;
        payload.error_stack = next_value;
        payload.error_stack_sites = null;
        payload.error_stack_site_count = 0;
        if (old_value) |stored| stored.free(rt);
        if (old_sites) |stored| stored.free(rt);
    }

    pub fn errorStack(self: *const Object) ?JSValue {
        if (self.ordinaryPayloadConst()) |payload| return payload.error_stack;
        return null;
    }

    pub fn setErrorStackSites(self: *Object, rt: *JSRuntime, sites_value: JSValue) !void {
        const payload = try self.ensureOrdinaryPayload(rt);
        const next_value = sites_value.dup();
        errdefer next_value.free(rt);
        const old_stack = payload.error_stack;
        const old_sites = payload.error_stack_sites;
        payload.error_stack = null;
        payload.error_stack_sites = next_value;
        payload.error_stack_site_count = capturedStackSiteCount(sites_value);
        if (old_stack) |stored| stored.free(rt);
        if (old_sites) |stored| stored.free(rt);
    }

    pub fn errorStackSites(self: *const Object) ?JSValue {
        if (self.ordinaryPayloadConst()) |payload| return payload.error_stack_sites;
        return null;
    }

    pub fn errorStackSiteCount(self: *const Object) usize {
        if (self.ordinaryPayloadConst()) |payload| return payload.error_stack_site_count;
        return 0;
    }

    fn capturedStackSiteCount(sites_value: JSValue) usize {
        const sites = objectFromValue(sites_value) orelse return 0;
        return if (sites.isArray()) @intCast(sites.arrayLength()) else 0;
    }

    pub fn promiseReactionOnFulfilledSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.promise_reaction_on_fulfilled;
    }

    pub fn promiseReactionOnFulfilled(self: *const Object) ?JSValue {
        if (self.ordinaryPayloadConst()) |payload| return payload.promise_reaction_on_fulfilled;
        return null;
    }

    pub fn setPromiseReactionOnFulfilled(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, try self.promiseReactionOnFulfilledSlot(rt), next_value);
    }

    pub fn promiseReactionOnRejectedSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.promise_reaction_on_rejected;
    }

    pub fn promiseReactionOnRejected(self: *const Object) ?JSValue {
        if (self.ordinaryPayloadConst()) |payload| return payload.promise_reaction_on_rejected;
        return null;
    }

    pub fn setPromiseReactionOnRejected(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, try self.promiseReactionOnRejectedSlot(rt), next_value);
    }

    pub fn promiseReactionResolveSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.promise_reaction_resolve;
    }

    pub fn promiseReactionResolve(self: *const Object) ?JSValue {
        if (self.ordinaryPayloadConst()) |payload| return payload.promise_reaction_resolve;
        return null;
    }

    pub fn setPromiseReactionResolve(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, try self.promiseReactionResolveSlot(rt), next_value);
    }

    pub fn promiseReactionRejectSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.promise_reaction_reject;
    }

    pub fn promiseReactionReject(self: *const Object) ?JSValue {
        if (self.ordinaryPayloadConst()) |payload| return payload.promise_reaction_reject;
        return null;
    }

    pub fn setPromiseReactionReject(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, try self.promiseReactionRejectSlot(rt), next_value);
    }

    pub fn promiseAlreadyResolvedSlot(self: *Object, rt: *JSRuntime) !*bool {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.promise_already_resolved;
    }

    pub fn promiseAlreadyResolved(self: *const Object) bool {
        if (self.ordinaryPayloadConst()) |payload| return payload.promise_already_resolved;
        return false;
    }

    pub fn promiseCapabilityResolveSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.promise_capability_resolve;
    }

    pub fn promiseCapabilityResolve(self: *const Object) ?JSValue {
        if (self.ordinaryPayloadConst()) |payload| return payload.promise_capability_resolve;
        return null;
    }

    pub fn setPromiseCapabilityResolve(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, try self.promiseCapabilityResolveSlot(rt), next_value);
    }

    pub fn promiseCapabilityRejectSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.promise_capability_reject;
    }

    pub fn promiseCapabilityReject(self: *const Object) ?JSValue {
        if (self.ordinaryPayloadConst()) |payload| return payload.promise_capability_reject;
        return null;
    }

    pub fn setPromiseCapabilityReject(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, try self.promiseCapabilityRejectSlot(rt), next_value);
    }

    pub fn setPromiseCapability(self: *Object, rt: *JSRuntime, next_resolve: ?JSValue, next_reject: ?JSValue) !void {
        errdefer {
            if (next_resolve) |stored| stored.free(rt);
            if (next_reject) |stored| stored.free(rt);
        }
        const resolve_slot = try self.promiseCapabilityResolveSlot(rt);
        const reject_slot = try self.promiseCapabilityRejectSlot(rt);
        const old_resolve = resolve_slot.*;
        const old_reject = reject_slot.*;
        resolve_slot.* = next_resolve;
        reject_slot.* = next_reject;
        if (old_resolve) |stored| stored.free(rt);
        if (old_reject) |stored| stored.free(rt);
    }

    pub fn promiseCombinatorResolveSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.promise_combinator_resolve;
    }

    pub fn promiseCombinatorResolve(self: *const Object) ?JSValue {
        if (self.ordinaryPayloadConst()) |payload| return payload.promise_combinator_resolve;
        return null;
    }

    pub fn setPromiseCombinatorResolve(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, try self.promiseCombinatorResolveSlot(rt), next_value);
    }

    pub fn promiseCombinatorRejectSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.promise_combinator_reject;
    }

    pub fn promiseCombinatorReject(self: *const Object) ?JSValue {
        if (self.ordinaryPayloadConst()) |payload| return payload.promise_combinator_reject;
        return null;
    }

    pub fn setPromiseCombinatorReject(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, try self.promiseCombinatorRejectSlot(rt), next_value);
    }

    pub fn promiseCombinatorValuesSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.promise_combinator_values;
    }

    pub fn promiseCombinatorValues(self: *const Object) ?JSValue {
        if (self.ordinaryPayloadConst()) |payload| return payload.promise_combinator_values;
        return null;
    }

    pub fn setPromiseCombinatorValues(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, try self.promiseCombinatorValuesSlot(rt), next_value);
    }

    pub fn promiseCombinatorKeysSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.promise_combinator_keys;
    }

    pub fn promiseCombinatorKeys(self: *const Object) ?JSValue {
        if (self.ordinaryPayloadConst()) |payload| return payload.promise_combinator_keys;
        return null;
    }

    pub fn setPromiseCombinatorKeys(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, try self.promiseCombinatorKeysSlot(rt), next_value);
    }

    pub fn typedArrayArrayBufferPrototypeSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.typed_array_array_buffer_prototype;
    }

    pub fn typedArrayArrayBufferPrototype(self: *const Object) ?JSValue {
        if (self.ordinaryPayloadConst()) |payload| return payload.typed_array_array_buffer_prototype;
        return null;
    }

    pub fn setTypedArrayArrayBufferPrototype(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, try self.typedArrayArrayBufferPrototypeSlot(rt), next_value);
    }

    pub fn promiseCombinatorRemainingSlot(self: *Object, rt: *JSRuntime) !*i32 {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.promise_combinator_remaining;
    }

    pub fn promiseCombinatorRemaining(self: *const Object) i32 {
        if (self.ordinaryPayloadConst()) |payload| return payload.promise_combinator_remaining;
        return 0;
    }

    pub fn functionRealmGlobalSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        if (self.flags.class_payload_kind == .function) return &(try self.ensureFunctionRarePayload(rt)).realm_global;
        if (self.boundFunctionPayload()) |payload| return &payload.realm_global;
        std.debug.assert(self.flags.class_payload_kind == .function or self.flags.class_payload_kind == .bound_function);
        unreachable;
    }

    pub fn functionRealmGlobal(self: *const Object) ?JSValue {
        if (self.functionRarePayloadConst()) |payload| return payload.realm_global;
        if (self.boundFunctionPayloadConst()) |payload| return payload.realm_global;
        return null;
    }

    pub fn functionRealmGlobalPtrSlot(self: *Object) *?*Object {
        if (self.ordinaryPayload()) |payload| return &payload.realm_global_ptr;
        if (self.objectDataPayload()) |payload| return &payload.realm_global_ptr;
        if (self.weakRefPayload()) |payload| return &payload.realm_global_ptr;
        if (self.iteratorPayload()) |payload| return &payload.realm_global_ptr;
        if (self.collectionPayload()) |payload| return &payload.realm_global_ptr;
        if (self.bufferPayload()) |payload| return &payload.realm_global_ptr;
        if (self.typedArrayPayload()) |payload| return &payload.realm_global_ptr;
        if (self.regExpPayload()) |payload| return &payload.realm_global_ptr;
        if (self.boundFunctionPayload()) |payload| return &payload.realm_global_ptr;
        if (self.proxyPayload()) |payload| return &payload.realm_global_ptr;
        if (self.argumentsPayload()) |payload| return &payload.realm_global_ptr;
        if (self.varRefPayload()) |payload| return &payload.realm_global_ptr;
        if (self.finalizationRegistryPayload()) |payload| return &payload.realm_global_ptr;
        if (self.stdFilePayload()) |payload| return &payload.realm_global_ptr;
        if (self.disposableStackPayload()) |payload| return &payload.realm_global_ptr;
        if (self.promisePayload()) |payload| return &payload.realm_global_ptr;
        if (self.moduleNamespacePayload()) |payload| return &payload.realm_global_ptr;
        if (self.functionPayload()) |payload| {
            // qjs stores the realm on JSFunctionBytecode for bytecode
            // callables, not on every closure object. Only the native cfunc
            // arm has a mutable borrowed pointer slot here.
            std.debug.assert(!class.isBytecodeFunctionClass(self.class_id));
            return &payload.native.realm_global_ptr;
        }
        if (self.generatorPayload()) |payload| return &payload.realm_global_ptr;
        std.debug.assert(self.flags.class_payload_kind != .none);
        unreachable;
    }

    pub fn functionRealmGlobalPtrSlotEnsured(self: *Object, rt: *JSRuntime) !*?*Object {
        if (self.flags.class_payload_kind == .none) {
            const payload = try self.ensureOrdinaryPayload(rt);
            return &payload.realm_global_ptr;
        }
        return self.functionRealmGlobalPtrSlot();
    }

    pub fn setFunctionRealmGlobalPtr(self: *Object, rt: *JSRuntime, realm_global: ?*Object) !void {
        if (class.isBytecodeFunctionClass(self.class_id)) {
            if (realm_global) |global| {
                try self.bindBytecodeFunctionRealmGlobal(global);
            } else {
                if (self.functionRarePayload()) |rare| self.clearOptionalValueSlot(rt, &rare.realm_global);
            }
            return;
        }
        const slot = try self.functionRealmGlobalPtrSlotEnsured(rt);
        if (realm_global != null) try rt.registerBorrowedReferenceHolder(self);
        slot.* = realm_global;
        if (realm_global == null) self.pruneBorrowedReferenceHolderIfEmpty(rt);
    }

    pub fn setFunctionRealmGlobalPtrIfNull(self: *Object, rt: *JSRuntime, realm_global: ?*Object) !void {
        if (class.isBytecodeFunctionClass(self.class_id)) {
            if (self.bytecodeFunctionRealmGlobalPtr() == null) {
                if (realm_global) |global| try self.bindBytecodeFunctionRealmGlobal(global);
            }
            return;
        }
        const slot = try self.functionRealmGlobalPtrSlotEnsured(rt);
        if (slot.* == null) {
            if (realm_global != null) try rt.registerBorrowedReferenceHolder(self);
            slot.* = realm_global;
            if (realm_global == null) self.pruneBorrowedReferenceHolderIfEmpty(rt);
        }
    }

    pub fn borrowedReferenceHolderIndex(self: *const Object) ?usize {
        const compact_encoded = if (self.functionPayloadConst()) |payload|
            @as(u32, payload.borrowed_holder_index_lo) |
                (@as(u32, payload.borrowed_holder_index_mid) << 8) |
                (@as(u32, payload.borrowed_holder_index_hi) << 16)
        else if (self.generatorPayloadConst()) |payload|
            @as(u32, payload.borrowed_holder_index_lo) |
                (@as(u32, payload.borrowed_holder_index_mid) << 8) |
                (@as(u32, payload.borrowed_holder_index_hi) << 16)
        else
            0;
        if (compact_encoded != 0) return @as(usize, compact_encoded - 1);
        const link = self.weakReferenceHolderLinkConst() orelse return null;
        return if (link.borrowed_holder_index == 0) null else @as(usize, link.borrowed_holder_index - 1);
    }

    pub fn setBorrowedReferenceHolderIndex(self: *Object, index: ?usize) void {
        const compact_encoded: u32 = if (index) |holder_index|
            if (holder_index < std.math.maxInt(u24)) @intCast(holder_index + 1) else 0
        else
            0;
        if (self.functionPayload()) |payload| {
            payload.borrowed_holder_index_lo = @truncate(compact_encoded);
            payload.borrowed_holder_index_mid = @truncate(compact_encoded >> 8);
            payload.borrowed_holder_index_hi = @truncate(compact_encoded >> 16);
            return;
        } else if (self.generatorPayload()) |payload| {
            payload.borrowed_holder_index_lo = @truncate(compact_encoded);
            payload.borrowed_holder_index_mid = @truncate(compact_encoded >> 8);
            payload.borrowed_holder_index_hi = @truncate(compact_encoded >> 16);
            return;
        }
        const link = self.weakReferenceHolderLink() orelse return;
        link.borrowed_holder_index = if (index) |holder_index|
            if (holder_index < std.math.maxInt(u32)) @intCast(holder_index + 1) else 0
        else
            0;
    }

    /// Realm-global pointer for a proven bytecode-function object. The common
    /// edge lives on the shared FunctionBytecode exactly like qjs `b->realm`.
    pub fn bytecodeFunctionRealmGlobalPtr(self: *const Object) ?*Object {
        if (self.functionRarePayloadConst()) |rare| {
            if (rare.realm_global) |stored| {
                if (objectFromValue(stored)) |global| return global;
            }
        }
        const fb = self.u.bytecode_function.function_bytecode orelse return null;
        const header = fb.realm_global_header orelse return null;
        std.debug.assert(header.metaConst().kind == .object);
        return @fieldParentPtr("header", header);
    }

    /// Direct realm read for the native-c_function call path — qjs `ctx =
    /// p->u.cfunc.realm` (quickjs.c:17586). Same one-load `.function` payload body as
    /// `bytecodeFunctionRealmGlobalPtr`; a distinct name documents the call-site
    /// invariant (`fastNativeMethodCall` proves `class_payload_kind == .function` up
    /// front before calling this, so the `unreachable` can never fire). Returns null
    /// only when the payload's `realm_global_ptr` is unset (dead for materialized native
    /// builtins), letting the caller fall back to the generic realm resolver.
    pub fn nativeFunctionRealmGlobalPtr(self: *const Object) ?*Object {
        if (self.functionPayloadConst()) |payload| return payload.native.realm_global_ptr;
        std.debug.assert(self.flags.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionRealmGlobalPtr(self: *const Object) ?*Object {
        if (class.isBytecodeFunctionClass(self.class_id)) return self.bytecodeFunctionRealmGlobalPtr();
        return self.borrowedRealmGlobalPtr();
    }

    /// Raw realm pointers that participate in the runtime's borrowed-reference
    /// cleanup registry. Bytecode-function realms are deliberately absent:
    /// their FunctionBytecode owns a JSValue edge and is traced by the cycle GC.
    fn borrowedRealmGlobalPtr(self: *const Object) ?*Object {
        if (self.functionPayloadConst()) |payload| return payload.native.realm_global_ptr;
        if (self.generatorPayloadConst()) |payload| return payload.realm_global_ptr;
        if (self.ordinaryPayloadConst()) |payload| return payload.realm_global_ptr;
        if (self.objectDataPayloadConst()) |payload| return payload.realm_global_ptr;
        if (self.weakRefPayloadConst()) |payload| return payload.realm_global_ptr;
        if (self.iteratorPayloadConst()) |payload| return payload.realm_global_ptr;
        if (self.collectionPayloadConst()) |payload| return payload.realm_global_ptr;
        if (self.bufferPayloadConst()) |payload| return payload.realm_global_ptr;
        if (self.typedArrayPayloadConst()) |payload| return payload.realm_global_ptr;
        if (self.regExpPayloadConst()) |payload| return payload.realm_global_ptr;
        if (self.boundFunctionPayloadConst()) |payload| return payload.realm_global_ptr;
        if (self.proxyPayloadConst()) |payload| return payload.realm_global_ptr;
        if (self.argumentsPayloadConst()) |payload| return payload.realm_global_ptr;
        if (self.varRefPayloadConst()) |payload| return payload.realm_global_ptr;
        if (self.finalizationRegistryPayloadConst()) |payload| return payload.realm_global_ptr;
        if (self.stdFilePayloadConst()) |payload| return payload.realm_global_ptr;
        if (self.disposableStackPayloadConst()) |payload| return payload.realm_global_ptr;
        if (self.promisePayloadConst()) |payload| return payload.realm_global_ptr;
        if (self.moduleNamespacePayloadConst()) |payload| return payload.realm_global_ptr;
        return null;
    }

    fn ordinaryPayload(self: *Object) ?*OrdinaryPayload {
        if (self.flags.class_payload_kind != .ordinary) return null;
        return @ptrCast(@alignCast(self.u.payload.?));
    }

    fn ordinaryPayloadConst(self: *const Object) ?*const OrdinaryPayload {
        if (self.flags.class_payload_kind != .ordinary) return null;
        return @ptrCast(@alignCast(self.u.payload.?));
    }

    fn destroyOrdinaryPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.ordinaryPayload() orelse return;
        self.u.payload = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(OrdinaryPayload, payload);
    }

    fn iteratorPayload(self: *Object) ?*IteratorPayload {
        if (self.flags.class_payload_kind != .iterator) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn iteratorPayloadConst(self: *const Object) ?*const IteratorPayload {
        if (self.flags.class_payload_kind != .iterator) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyIteratorPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.iteratorPayload() orelse return;
        self.u.payload = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(IteratorPayload, payload);
    }

    fn collectionPayload(self: *Object) ?*CollectionPayload {
        if (self.flags.class_payload_kind != .collection) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn collectionPayloadConst(self: *const Object) ?*const CollectionPayload {
        if (self.flags.class_payload_kind != .collection) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyCollectionPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.collectionPayload() orelse return;
        self.u.payload = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(CollectionPayload, payload);
    }

    fn finalizationRegistryPayload(self: *Object) ?*FinalizationRegistryPayload {
        if (self.flags.class_payload_kind != .finalization_registry) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn finalizationRegistryPayloadConst(self: *const Object) ?*const FinalizationRegistryPayload {
        if (self.flags.class_payload_kind != .finalization_registry) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyFinalizationRegistryPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.finalizationRegistryPayload() orelse return;
        self.u.payload = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(FinalizationRegistryPayload, payload);
    }

    fn weakRefPayload(self: *Object) ?*WeakRefPayload {
        if (self.flags.class_payload_kind != .weak_ref) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn weakRefPayloadConst(self: *const Object) ?*const WeakRefPayload {
        if (self.flags.class_payload_kind != .weak_ref) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyWeakRefPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.weakRefPayload() orelse return;
        self.u.payload = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(WeakRefPayload, payload);
    }

    pub fn isWeakReferenceHolderClass(self: *const Object) bool {
        return switch (self.class_id) {
            class.ids.weakmap, class.ids.weakset, class.ids.weak_ref, class.ids.finalization_registry => true,
            else => false,
        };
    }

    pub fn weakReferenceHolderLink(self: *Object) ?*WeakReferenceHolderLink {
        if (self.collectionPayload()) |payload| return &payload.weak_holder_link;
        if (self.weakRefPayload()) |payload| return &payload.weak_holder_link;
        if (self.finalizationRegistryPayload()) |payload| return &payload.weak_holder_link;
        return null;
    }

    pub fn weakReferenceHolderLinkConst(self: *const Object) ?*const WeakReferenceHolderLink {
        if (self.collectionPayloadConst()) |payload| return &payload.weak_holder_link;
        if (self.weakRefPayloadConst()) |payload| return &payload.weak_holder_link;
        if (self.finalizationRegistryPayloadConst()) |payload| return &payload.weak_holder_link;
        return null;
    }

    pub fn weakReferenceHolderPrevious(self: *const Object) ?*Object {
        const link = self.weakReferenceHolderLinkConst() orelse return null;
        return link.previous;
    }

    pub fn weakReferenceHolderNext(self: *const Object) ?*Object {
        const link = self.weakReferenceHolderLinkConst() orelse return null;
        return link.next;
    }

    fn stdFilePayload(self: *Object) ?*StdFilePayload {
        if (self.flags.class_payload_kind != .std_file) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn stdFilePayloadConst(self: *const Object) ?*const StdFilePayload {
        if (self.flags.class_payload_kind != .std_file) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyStdFilePayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.stdFilePayload() orelse return;
        self.u.payload = null;
        self.flags.class_payload_kind = .none;
        payload.destroy();
        rt.memory.destroy(StdFilePayload, payload);
    }

    fn disposableStackPayload(self: *Object) ?*DisposableStackPayload {
        if (self.flags.class_payload_kind != .disposable_stack) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn disposableStackPayloadConst(self: *const Object) ?*const DisposableStackPayload {
        if (self.flags.class_payload_kind != .disposable_stack) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyDisposableStackPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.disposableStackPayload() orelse return;
        self.u.payload = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(DisposableStackPayload, payload);
    }

    fn realmPayload(self: *Object) ?*RealmPayload {
        if (self.flags.class_payload_kind != .realm) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn realmPayloadConst(self: *const Object) ?*const RealmPayload {
        if (self.flags.class_payload_kind != .realm) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyRealmPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.realmPayload() orelse return;
        self.u.payload = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(RealmPayload, payload);
    }

    fn bufferPayload(self: *Object) ?*BufferPayload {
        if (self.flags.class_payload_kind != .buffer) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn bufferPayloadConst(self: *const Object) ?*const BufferPayload {
        if (self.flags.class_payload_kind != .buffer) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyBufferPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.bufferPayload() orelse return;
        self.u.payload = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(BufferPayload, payload);
    }

    fn typedArrayPayload(self: *Object) ?*TypedArrayPayload {
        if (self.flags.class_payload_kind != .typed_array) return null;
        return @ptrCast(@alignCast(self.u.payload.?));
    }

    fn typedArrayPayloadConst(self: *const Object) ?*const TypedArrayPayload {
        if (self.flags.class_payload_kind != .typed_array) return null;
        return @ptrCast(@alignCast(self.u.payload.?));
    }

    fn destroyTypedArrayPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.typedArrayPayload() orelse return;
        self.u.payload = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(TypedArrayPayload, payload);
    }

    fn regExpPayload(self: *Object) ?*RegExpPayload {
        if (self.flags.class_payload_kind != .regexp) return null;
        if (self.class_id == class.ids.regexp) return &self.u.regexp;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn regExpPayloadConst(self: *const Object) ?*const RegExpPayload {
        if (self.flags.class_payload_kind != .regexp) return null;
        if (self.class_id == class.ids.regexp) return &self.u.regexp;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyRegExpPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.regExpPayload() orelse return;
        if (self.class_id == class.ids.regexp) {
            payload.destroy(rt);
            self.u.regexp = .{};
            self.flags.class_payload_kind = .none;
            return;
        }
        self.u.payload = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(RegExpPayload, payload);
    }

    fn boundFunctionPayload(self: *Object) ?*BoundFunctionPayload {
        if (self.flags.class_payload_kind != .bound_function) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn boundFunctionPayloadConst(self: *const Object) ?*const BoundFunctionPayload {
        if (self.flags.class_payload_kind != .bound_function) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyBoundFunctionPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.boundFunctionPayload() orelse return;
        self.u.payload = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(BoundFunctionPayload, payload);
    }

    fn proxyPayload(self: *Object) ?*ProxyPayload {
        if (self.flags.class_payload_kind != .proxy) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn proxyPayloadConst(self: *const Object) ?*const ProxyPayload {
        if (self.flags.class_payload_kind != .proxy) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyProxyPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.proxyPayload() orelse return;
        self.u.payload = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(ProxyPayload, payload);
    }

    fn argumentsPayload(self: *Object) ?*ArgumentsPayload {
        if (self.flags.class_payload_kind != .arguments) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn argumentsPayloadConst(self: *const Object) ?*const ArgumentsPayload {
        if (self.flags.class_payload_kind != .arguments) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyArgumentsPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.argumentsPayload() orelse return;
        self.u.payload = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(ArgumentsPayload, payload);
    }

    fn objectDataPayload(self: *Object) ?*ObjectDataPayload {
        if (self.flags.class_payload_kind != .object_data) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn objectDataPayloadConst(self: *const Object) ?*const ObjectDataPayload {
        if (self.flags.class_payload_kind != .object_data) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyObjectDataPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.objectDataPayload() orelse return;
        self.u.payload = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(ObjectDataPayload, payload);
    }

    fn varRefPayload(self: *Object) ?*VarRefPayload {
        if (self.flags.class_payload_kind != .var_ref) return null;
        return @ptrCast(@alignCast(self.u.payload.?));
    }

    fn varRefPayloadConst(self: *const Object) ?*const VarRefPayload {
        if (self.flags.class_payload_kind != .var_ref) return null;
        return @ptrCast(@alignCast(self.u.payload.?));
    }

    fn destroyVarRefPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.varRefPayload() orelse return;
        self.u.payload = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(VarRefPayload, payload);
    }

    fn promisePayload(self: *Object) ?*PromisePayload {
        if (self.flags.class_payload_kind != .promise) return null;
        return @ptrCast(@alignCast(self.u.payload.?));
    }

    fn promisePayloadConst(self: *const Object) ?*const PromisePayload {
        if (self.flags.class_payload_kind != .promise) return null;
        return @ptrCast(@alignCast(self.u.payload.?));
    }

    fn destroyPromisePayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.promisePayload() orelse return;
        self.u.payload = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(PromisePayload, payload);
    }

    fn generatorPayload(self: *Object) ?*GeneratorPayload {
        if (self.flags.class_payload_kind != .generator) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn generatorPayloadConst(self: *const Object) ?*const GeneratorPayload {
        if (self.flags.class_payload_kind != .generator) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyGeneratorPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.generatorPayload() orelse return;
        self.u.payload = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(GeneratorPayload, payload);
    }

    fn functionPayload(self: *Object) ?*FunctionPayload {
        if (self.flags.class_payload_kind != .function) return null;
        if (class.isBytecodeFunctionClass(self.class_id)) return null;
        return @ptrCast(@alignCast(self.u.payload.?));
    }

    fn functionPayloadConst(self: *const Object) ?*const FunctionPayload {
        if (self.flags.class_payload_kind != .function) return null;
        if (class.isBytecodeFunctionClass(self.class_id)) return null;
        return @ptrCast(@alignCast(self.u.payload.?));
    }

    fn destroyFunctionPayload(self: *Object, rt: *JSRuntime) void {
        if (class.isBytecodeFunctionClass(self.class_id)) {
            var captures = self.u.bytecode_function.captureSlice();
            self.u.bytecode_function.var_refs = BytecodeFunctionStorage.emptyVarRefs();
            destroyVarRefCellSlice(rt, &captures);

            if (self.bytecodeFunctionAux()) |aux| {
                self.u.bytecode_function.home_or_aux = null;
                aux.destroy(rt);
                rt.memory.destroy(BytecodeFunctionAux, aux);
            } else if (self.functionHomeObject()) |home| {
                self.u.bytecode_function.home_or_aux = null;
                home.value().free(rt);
            }

            if (self.u.bytecode_function.function_bytecode) |fb| {
                self.u.bytecode_function.function_bytecode = null;
                gc.release(rt, &fb.header);
            }
            self.flags.class_payload_kind = .none;
            return;
        }
        const payload = self.functionPayload() orelse return;
        self.u.payload = null;
        self.flags.class_payload_kind = .none;
        payload.destroyNative(rt);
        rt.memory.destroy(FunctionPayload, payload);
    }

    pub fn moduleNamespacePayload(self: *Object) ?*ModuleNamespacePayload {
        if (self.flags.class_payload_kind != .module_namespace) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    pub fn setModuleNamespaceCells(self: *Object, rt: *JSRuntime, next_cells: []JSValue) !void {
        const payload = self.moduleNamespacePayload() orelse {
            std.debug.assert(self.flags.class_payload_kind == .module_namespace);
            unreachable;
        };
        try self.setValueSlice(rt, &payload.cells, next_cells);
    }

    fn moduleNamespacePayloadConst(self: *const Object) ?*const ModuleNamespacePayload {
        if (self.flags.class_payload_kind != .module_namespace) return null;
        const ptr = self.u.payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    inline fn moduleNamespaceBindingValue(self: Object, atom_id: atom.Atom) ?JSValue {
        if (self.class_id != class.ids.module_ns) return null;
        const payload = @constCast(&self).moduleNamespacePayload() orelse return null;
        for (payload.names, 0..) |name, idx| {
            if (name != atom_id or idx >= payload.cells.len) continue;
            const cell = varRefCellFromValue(payload.cells[idx]) orelse return JSValue.undefinedValue();
            return cell.varRefValue().dup();
        }
        return null;
    }

    pub inline fn moduleNamespaceOwnBindingValue(self: Object, atom_id: atom.Atom) ?JSValue {
        return self.moduleNamespaceBindingValue(atom_id);
    }

    /// Existence-only probe for a module-namespace binding. Mirrors
    /// `moduleNamespaceBindingValue` but performs NO `dup` -- it reports
    /// presence and, separately, whether the cell is still uninitialized
    /// (qjs `JS_GetOwnPropertyInternal` desc==NULL VARREF branch,
    /// quickjs.c:8856-8860). Module-namespace bindings are stored as
    /// VARREF cells in qjs's namespace property table, so the existence
    /// path throws `ReferenceErrorUninitialized` when the cell is in TDZ.
    pub fn moduleNamespaceBindingExists(self: Object, atom_id: atom.Atom) BindingExistence {
        if (self.class_id != class.ids.module_ns) return .absent;
        const payload = @constCast(&self).moduleNamespacePayload() orelse return .absent;
        for (payload.names, 0..) |name, idx| {
            if (name != atom_id or idx >= payload.cells.len) continue;
            const cell = varRefCellFromValue(payload.cells[idx]) orelse return .present;
            if (cell.varRefValue().isUninitialized()) return .uninitialized;
            return .present;
        }
        return .absent;
    }

    fn destroyModuleNamespacePayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.moduleNamespacePayload() orelse return;
        self.u.payload = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(ModuleNamespacePayload, payload);
    }

    pub fn destroyRuntimeCycles(rt: *JSRuntime) usize {
        return rt.runObjectCycleRemoval();
    }

    fn traceChildren(rt: *JSRuntime, header: *gc.Header, visitor: anytype) void {
        switch (header.meta().kind) {
            .object => {
                const obj: *Object = @alignCast(@fieldParentPtr("header", header));
                obj.traceChildEdgesNoFail(rt, visitor);
            },
            .function_bytecode => {
                const fb: *FunctionBytecode = @alignCast(@fieldParentPtr("header", header));
                if (fb.class_fields_init) |stored| visitor.visitValue(stored);
                var realm_global: ?*Object = if (fb.realm_global_header) |realm_header|
                    @fieldParentPtr("header", realm_header)
                else
                    null;
                visitor.visitObject(&realm_global);
                fb.realm_global_header = if (realm_global) |global| &global.header else null;
                for (fb.cpoolSlice()) |*stored| visitor.visitValue(stored);
            },
            .var_ref => {
                const ref: *var_ref_mod.VarRef = @alignCast(@fieldParentPtr("header", header));
                // Closed cell: the owned edge is `value` (qjs gc marks a
                // detached var_ref's *pvalue, which IS &value there —
                // gc_decref/mark var-ref arm). Not `pvalue.*` here: the
                // direct-eval const VIEW (eval_ops.directEvalOuterVarRefView)
                // aliases pvalue into its TARGET cell's storage while owning
                // the target cell through `value` — tracing pvalue.* would
                // count an edge the view holds no ref on (the target's plain
                // value) and miss the owned target-cell ref.
                if (ref.is_open) {
                    visitor.visitValue(ref.varRefValueSlot());
                } else {
                    visitor.visitValue(&ref.value);
                }
            },
            .shape => {
                const shape_ref: *shape.Shape = @alignCast(@fieldParentPtr("header", header));
                shape_ref.traceChildEdgesNoFail(rt, visitor);
            },
            else => {},
        }
    }

    inline fn headerHasTraceableChildren(header: *const gc.Header) bool {
        return header.metaConst().kind == .object or header.metaConst().kind == .function_bytecode or header.metaConst().kind == .var_ref or header.metaConst().kind == .shape;
    }

    const DecrefVisitor = struct {
        rt: *JSRuntime,

        pub fn visitValue(self: DecrefVisitor, val: *JSValue) void {
            if (val.refCountHeader()) |h| {
                self.visitHeader(h);
            }
        }

        pub fn visitObject(self: DecrefVisitor, obj_ptr: *?*Object) void {
            if (obj_ptr.*) |obj| {
                if (@intFromPtr(obj) == 0) return;
                self.visitHeader(&obj.header);
            }
        }

        pub fn visitShape(self: DecrefVisitor, shape_ref: *shape.Shape) void {
            self.visitHeader(&shape_ref.header);
        }

        pub fn visitSymbol(self: DecrefVisitor, symbol: *u32) void {
            _ = self;
            _ = symbol;
        }

        pub fn visitWeakCollectionEntry(self: DecrefVisitor, entry: *WeakCollectionEntry) void {
            _ = self;
            _ = entry;
        }

        pub fn visitFinalizationCell(self: DecrefVisitor, entry: *FinalizationRegistryCell) void {
            if (entry.keepsHeldValuesAlive()) self.visitValue(&entry.held_value);
        }

        fn visitHeader(self: DecrefVisitor, h: *gc.Header) void {
            _ = self;
            if (h.meta().rc == 0) return;
            h.meta().rc -= 1;
        }
    };

    const ScanIncrefVisitor = struct {
        registry: *gc.Registry,
        garbage: *gc.HeaderList,

        pub fn visitValue(self: ScanIncrefVisitor, val: *JSValue) void {
            if (val.refCountHeader()) |h| {
                self.visitHeader(h);
            }
        }

        pub fn visitObject(self: ScanIncrefVisitor, obj_ptr: *?*Object) void {
            if (obj_ptr.*) |obj| {
                if (@intFromPtr(obj) == 0) return;
                self.visitHeader(&obj.header);
            }
        }

        pub fn visitShape(self: ScanIncrefVisitor, shape_ref: *shape.Shape) void {
            self.visitHeader(&shape_ref.header);
        }

        pub fn visitSymbol(self: ScanIncrefVisitor, symbol: *u32) void {
            _ = self;
            _ = symbol;
        }

        pub fn visitWeakCollectionEntry(self: ScanIncrefVisitor, entry: *WeakCollectionEntry) void {
            _ = self;
            _ = entry;
        }

        pub fn visitFinalizationCell(self: ScanIncrefVisitor, entry: *FinalizationRegistryCell) void {
            if (entry.keepsHeldValuesAlive()) self.visitValue(&entry.held_value);
        }

        fn visitHeader(self: ScanIncrefVisitor, h: *gc.Header) void {
            const was_zero = h.meta().rc == 0;
            h.meta().rc += 1;
            if (was_zero and headerHasTraceableChildren(h) and h.meta().flags.mark) {
                self.garbage.remove(h);
                h.meta().flags.mark = false;
                // Moving a newly revived zero-ref node to the main-list tail
                // makes the enclosing list walk visit its children later,
                // exactly like QuickJS gc_scan_incref_child.
                self.registry.restoreCycleCandidate(h);
            }
        }
    };

    const ScanRestoreVisitor = struct {
        rt: *JSRuntime,

        pub fn visitValue(self: ScanRestoreVisitor, val: *JSValue) void {
            if (val.refCountHeader()) |h| {
                self.visitHeader(h);
            }
        }

        pub fn visitObject(self: ScanRestoreVisitor, obj_ptr: *?*Object) void {
            if (obj_ptr.*) |obj| {
                if (@intFromPtr(obj) == 0) return;
                self.visitHeader(&obj.header);
            }
        }

        pub fn visitShape(self: ScanRestoreVisitor, shape_ref: *shape.Shape) void {
            self.visitHeader(&shape_ref.header);
        }

        pub fn visitSymbol(self: ScanRestoreVisitor, symbol: *u32) void {
            _ = self;
            _ = symbol;
        }

        pub fn visitWeakCollectionEntry(self: ScanRestoreVisitor, entry: *WeakCollectionEntry) void {
            _ = self;
            _ = entry;
        }

        pub fn visitFinalizationCell(self: ScanRestoreVisitor, entry: *FinalizationRegistryCell) void {
            if (entry.keepsHeldValuesAlive()) self.visitValue(&entry.held_value);
        }

        fn visitHeader(self: ScanRestoreVisitor, h: *gc.Header) void {
            _ = self;
            h.meta().rc += 1;
        }
    };

    fn gcRemoveWeakObjects(rt: *JSRuntime) ObjectGraphError!void {
        sweepDeadWeakRootSlots(rt);

        // Match qjs gc_remove_weak_objects: the payload-resident holder list is
        // traversed exactly once while zero-ref destruction is deferred. Empty
        // weak holders stay linked for their full lifetime, so this traversal
        // has no allocation and no registry rescans or mark-bit side effects.
        rt.gc.beginDecrefPhase();
        defer rt.gc.endDecrefPhase(rt);
        var current = rt.weak_reference_holder_head;
        while (current) |holder| {
            const next = holder.weakReferenceHolderNext();
            try holder.sweepDeadWeakPayloadReferences(rt);
            current = next;
        }
    }

    fn sweepDeadWeakRootSlots(rt: *JSRuntime) void {
        for (rt.weak_root_slots) |slot| {
            const identity = slot.identity orelse continue;
            if (!weakIdentityIsLive(rt, identity)) {
                rt.clearWeakRootSlot(slot, true);
            }
        }
    }

    fn sweepDeadWeakPayloadReferences(self: *Object, rt: *JSRuntime) ObjectGraphError!void {
        if (self.weakRefPayload()) |payload| {
            if (payload.weak_target_identity) |identity| {
                if (!weakIdentityIsLive(rt, identity)) {
                    rt.clearWeakIdentitySlot(&payload.weak_target_identity);
                }
            }
        }

        if (self.collectionPayload()) |payload| {
            var read_index: usize = 0;
            var write_index: usize = 0;
            var removed_weak_entry = false;
            while (read_index < payload.weak_entries.len) : (read_index += 1) {
                const entry = payload.weak_entries[read_index];
                if (weakIdentityIsLive(rt, entry.key_identity)) {
                    if (write_index != read_index) payload.weak_entries[write_index] = entry;
                    write_index += 1;
                    continue;
                }

                rt.releaseWeakIdentity(entry.key_identity);
                entry.value.free(rt);
                removed_weak_entry = true;
            }
            if (removed_weak_entry) {
                payload.weak_entries = payload.weak_entries.ptr[0..write_index];
                self.clearCollectionIndex(rt);
            }
        }

        const finalization_payload = self.finalizationRegistryPayload() orelse {
            self.pruneBorrowedReferenceHolderIfEmpty(rt);
            return;
        };
        var index: usize = 0;
        while (index < finalization_payload.cells.len) {
            const cell = &finalization_payload.cells[index];
            if (cell.unregister_token_identity) |identity| {
                if (!weakIdentityIsLive(rt, identity)) {
                    rt.clearWeakIdentitySlot(&cell.unregister_token_identity);
                }
            }
            const target_identity = cell.target_identity orelse {
                index += 1;
                continue;
            };
            if (weakIdentityIsLive(rt, target_identity)) {
                cell.state = .active;
                index += 1;
                continue;
            }

            if (cell.isActive()) cell.state = .pending_enqueue;
            enqueueFinalizationCleanup(rt, finalization_payload.cleanup_callback, cell.held_value) catch |err| switch (err) {
                error.OutOfMemory => {
                    index += 1;
                    continue;
                },
                error.PayloadMarkFailed => return error.PayloadMarkFailed,
            };
            cell.state = .queued;
            const removed = finalization_payload.cells[index];
            removed.destroy(rt);
            const last_idx = finalization_payload.cells.len - 1;
            if (index < last_idx) {
                finalization_payload.cells[index] = finalization_payload.cells[last_idx];
            }
            finalization_payload.cells = finalization_payload.cells.ptr[0..last_idx];
        }
        self.pruneBorrowedReferenceHolderIfEmpty(rt);
    }

    fn weakIdentityIsLive(rt: *const JSRuntime, identity: usize) bool {
        if ((identity & 1) != 0) {
            const atom_id = identity >> 1;
            if (atom_id > std.math.maxInt(atom.Atom)) return false;
            return rt.atoms.kind(@intCast(atom_id)) == .symbol;
        }
        return rt.liveObjectFromWeakIdentity(identity) != null;
    }

    pub fn destroyRuntimeCyclesWithValueRoots(rt: *JSRuntime, roots: ?*const runtime_mod.ValueRootFrame) ObjectGraphError!usize {
        _ = roots;
        rt.gc.stats.collections += 1;
        try gcRemoveWeakObjects(rt);

        var garbage: gc.HeaderList = .{};
        var garbage_committed = false;
        defer {
            // Every fallible operation happens before destruction begins. If
            // one fails, refcounts have already been restored; splice the
            // condemned partition back into the registry before returning.
            if (!garbage_committed) {
                while (garbage.popFront()) |h| {
                    h.meta().flags.mark = false;
                    h.meta().flags.cycle_visited = false;
                    rt.gc.restoreCycleCandidate(h);
                }
            }
            var gc_iter = rt.gc.objectIterator();
            while (gc_iter.next()) |h| {
                h.meta().flags.mark = false;
                h.meta().flags.cycle_visited = false;
            }
        }

        // Phase 1: gc_decref
        {
            var gc_iter = rt.gc.objectIterator();
            while (gc_iter.next()) |h| {
                h.meta().flags.mark = true;
            }

            gc_iter = rt.gc.objectIterator();
            while (gc_iter.next()) |h| {
                traceChildren(rt, h, DecrefVisitor{ .rt = rt });
            }

            // QJS moves trial-zero nodes to tmp_obj_list. Partitioning after
            // the decref walk is equivalent and keeps the visitor itself tiny.
            var cursor = rt.gc.gc_object_head;
            while (cursor) |h| {
                const next = h.next;
                if (h.meta().rc == 0) {
                    rt.gc.detachCycleCandidate(h);
                    garbage.append(h);
                }
                cursor = next;
            }
        }

        // Phase 2: gc_scan
        {
            // Walk the live list dynamically: reviving a trial-zero child moves
            // it from `garbage` to the registry tail, so it is visited without
            // recursion or an auxiliary worklist.
            var cursor = rt.gc.gc_object_head;
            while (cursor) |h| {
                std.debug.assert(h.meta().rc > 0);
                h.meta().flags.mark = false;
                traceChildren(rt, h, ScanIncrefVisitor{
                    .registry = &rt.gc,
                    .garbage = &garbage,
                });
                cursor = h.next;
            }
        }

        // Phase 3: restore refcounts of the detached dead-cycle partition.
        {
            var cursor = garbage.head;
            while (cursor) |h| : (cursor = h.next) {
                traceChildren(rt, h, ScanRestoreVisitor{ .rt = rt });
            }
        }

        {
            var gc_iter = rt.gc.objectIterator();
            while (gc_iter.next()) |h| {
                h.meta().flags.cycle_visited = false;
            }
            var cursor = garbage.head;
            while (cursor) |h| : (cursor = h.next) {
                h.meta().flags.cycle_visited = true;
            }
        }

        sweepCycleGarbageWeakCollectionEntries(rt);

        var garbage_count: usize = 0;
        {
            var cursor = garbage.head;
            while (cursor) |h| : (cursor = h.next) {
                if (h.meta().kind == .object or h.meta().kind == .var_ref or h.meta().kind == .shape) garbage_count += 1;
            }
        }

        // No fallible operation is allowed after this point. Split the detached
        // partition by teardown order, reusing the same header links for each
        // staging list and later for Registry's Pass-B deferred list.
        var garbage_objects: gc.HeaderList = .{};
        var garbage_bytecodes: gc.HeaderList = .{};
        var garbage_var_refs: gc.HeaderList = .{};
        var garbage_shapes: gc.HeaderList = .{};
        garbage_committed = true;
        while (garbage.popFront()) |h| {
            switch (h.meta().kind) {
                .object => garbage_objects.append(h),
                .function_bytecode => garbage_bytecodes.append(h),
                .var_ref => garbage_var_refs.append(h),
                .shape => garbage_shapes.append(h),
                else => unreachable,
            }
        }

        const old_phase = rt.gc.phase;
        rt.gc.phase = .remove_cycles;
        defer rt.gc.phase = old_phase;

        // STEP 3 (qjs faithful): no edge-nulling pre-pass. qjs has none — its
        // cascade defense is the REMOVE_CYCLES gate in __JS_FreeValueRT
        // (quickjs.c:6476), which we mirror in `gc.releaseAndDestroy`. With that
        // gate, a garbage->garbage reference released during the destroy pass is a
        // pure decref (no recursive free), and the restored refcounts (Phase 3b /
        // gc_scan_incref_child2) net to zero. Weak-collection entries are handled
        // by `sweepCycleGarbageWeakCollectionEntries` above; internal bytecode
        // cpool edges are released by the gated fb teardown.

        const freed = garbage_count;

        // Resource teardown has a real ownership order even though every struct
        // survives until Pass B. A bytecode function object derives the length
        // of its `u.func.var_refs` allocation from its owning FB, exactly like
        // qjs `free_object`; therefore every Object must consume that metadata
        // before FunctionBytecode.deinit clears `var_refs_len`. The old mixed
        // gc-list order could deinit an FB first and leak the capture-pointer
        // allocation when the closure followed. VarRef structs also stay valid
        // until their object owners have released the capture edges.
        while (garbage_objects.popFront()) |h| {
            destroyFromHeader(rt, h);
        }
        while (garbage_bytecodes.popFront()) |h| {
            rt.gc.unlinkObjectWithBytes(h, gc.Registry.heapByteSizeFromHeader(rt, h));
            function_bytecode_mod.destroyFromHeader(rt, h);
        }
        while (garbage_var_refs.popFront()) |h| {
            rt.gc.unlinkObjectWithBytes(h, gc.Registry.heapByteSizeFromHeader(rt, h));
            var_ref_mod.VarRef.destroyFromHeader(rt, h);
        }

        while (garbage_shapes.popFront()) |h| {
            if (h.meta().flags.finalizing) continue;
            rt.shapes.destroyFromHeader(h);
        }

        // Pass B: now every garbage object's resources are gone AND every shape
        // (whose teardown re-releases protos) has run. If class-payload
        // finalizers were deferred, keep the resource-stripped object husks until
        // those finalizers drain: payloads may still hold JSValues into the
        // condemned cycle and must be able to release them without dereferencing
        // freed object memory.
        if (!rt.hasPendingDeferredClassPayloadFinalizers()) drainCycleDeferredFrees(rt);

        return freed;
    }

    /// Free the struct memory of every cycle-deferred GC object (objects /
    /// var_refs / function-bytecodes whose resources were torn down during the
    /// REMOVE_CYCLES resource pass). Mirrors qjs Pass B (quickjs.c:6797-6810).
    pub fn drainCycleDeferredFrees(rt: *JSRuntime) void {
        while (rt.gc.popCycleDeferredFree()) |h| {
            switch (h.meta().kind) {
                .object => {
                    const obj: *Object = @alignCast(@fieldParentPtr("header", h));
                    if (rt.gc.phase == .remove_cycles and (h.meta().rc != 0 or obj.weakref_count != 0)) {
                        // qjs keeps a cycle-freed object's stripped struct while
                        // either strong teardown edges or weak identities still
                        // point at it. It is no longer a GC-list member; the last
                        // weak release reclaims an rc-zero husk.
                        h.meta().flags.mark = false;
                        h.meta().flags.cycle_visited = false;
                        h.meta().flags.finalizing = false;
                        continue;
                    }
                    freeCycleDeferredStruct(rt, obj);
                },
                .var_ref => var_ref_mod.VarRef.freeCycleDeferredStruct(rt, h),
                .function_bytecode => function_bytecode_mod.freeCycleDeferredStruct(rt, h),
                else => {},
            }
        }
    }

    pub fn releaseCallbackOwnedFunctionBytecodeCycles(rt: *JSRuntime) void {
        var candidates = ObjectVisitSet.init(rt.memory.allocator);
        defer candidates.deinit();

        var gc_iter = rt.gc.objectIterator();
        while (gc_iter.next()) |h| {
            const function_bytecode = functionBytecodeFromGcHeader(h) orelse continue;
            candidates.put(@intFromPtr(function_bytecode), {}) catch return;
        }
        if (candidates.count() == 0) return;

        pruneCallbackOwnedFunctionBytecodeCycles(&candidates) catch return;
        if (candidates.count() == 0) return;

        retainFunctionBytecodeGuards(&candidates);
        defer releaseFunctionBytecodeGuards(rt, &candidates);

        var iterator = candidates.keyIterator();
        while (iterator.next()) |address| {
            const function_bytecode: *FunctionBytecode = @ptrFromInt(address.*);
            clearCallbackOwnedFunctionBytecodeCycleRefs(rt, function_bytecode, &candidates);
        }
    }

    fn pruneCallbackOwnedFunctionBytecodeCycles(candidates: *ObjectVisitSet) ObjectGraphError!void {
        while (true) {
            var removed = false;
            var iterator = candidates.keyIterator();
            while (iterator.next()) |address| {
                const function_bytecode: *const FunctionBytecode = @ptrFromInt(address.*);
                const internal_refs = countFunctionBytecodeRefsFromFunctionBytecodes(function_bytecode, candidates);
                const ref_count = function_bytecode.header.metaConst().rc;
                if (ref_count == internal_refs or (ref_count != 0 and ref_count - 1 == internal_refs)) continue;

                _ = candidates.remove(address.*);
                removed = true;
                break;
            }
            if (!removed) return;
        }
    }

    fn retainFunctionBytecodeGuards(candidates: *const ObjectVisitSet) void {
        var iterator = candidates.keyIterator();
        while (iterator.next()) |address| {
            const function_bytecode: *FunctionBytecode = @ptrFromInt(address.*);
            function_bytecode.header.retain();
        }
    }

    fn releaseFunctionBytecodeGuards(rt: *JSRuntime, candidates: *const ObjectVisitSet) void {
        var iterator = candidates.keyIterator();
        while (iterator.next()) |address| {
            const function_bytecode: *FunctionBytecode = @ptrFromInt(address.*);
            if (rt.gc.containsHeader(&function_bytecode.header)) {
                gc.release(rt, &function_bytecode.header);
            }
        }
    }

    fn clearCallbackOwnedFunctionBytecodeCycleRefs(
        rt: *JSRuntime,
        function_bytecode: *FunctionBytecode,
        candidates: *const ObjectVisitSet,
    ) void {
        if (function_bytecode.class_fields_init) |boxed| {
            if (valueReferencesFunctionBytecodeCandidate(boxed.*, candidates)) {
                const old_value = boxed.*;
                function_bytecode.class_fields_init = null;
                old_value.free(rt);
                rt.memory.destroy(JSValue, boxed);
            }
        }
        for (function_bytecode.cpoolSlice()) |*stored| {
            if (!valueReferencesFunctionBytecodeCandidate(stored.*, candidates)) continue;
            const old_value = stored.*;
            stored.* = JSValue.undefinedValue();
            old_value.free(rt);
        }
    }

    fn valueReferencesFunctionBytecodeCandidate(stored: JSValue, candidates: *const ObjectVisitSet) bool {
        const function_bytecode = functionBytecodeFromValue(stored) orelse return false;
        return candidates.contains(@intFromPtr(function_bytecode));
    }

    fn objectFromValue(stored: JSValue) ?*Object {
        const stored_header = stored.refHeader() orelse return null;
        if (stored_header.meta().kind != .object) return null;
        return @fieldParentPtr("header", stored_header);
    }

    const PayloadCollectContext = struct {
        rt: *JSRuntime,
        visited: *ObjectVisitSet,
    };

    const PayloadIncomingContext = struct {
        visited: *const ObjectVisitSet,
        incoming: *ObjectIncomingMap,
        internal_bytecodes: *const ObjectVisitSet,
        processed_bytecodes: *ObjectVisitSet,
    };

    const PayloadClearContext = struct {
        rt: *JSRuntime,
        visited: *const ObjectVisitSet,
        internal_bytecodes: *const ObjectVisitSet,
    };

    const PayloadBytecodeRefCountContext = struct {
        function_bytecode: *const FunctionBytecode,
        count: usize = 0,
    };

    fn markClassPayload(self: *Object, rt: *JSRuntime, visitor: *class.PayloadVisitor) bool {
        // Arrays keep `array_values` (not a payload) in the union; short-circuit
        // so markPayload never reinterprets that pointer (array classes register
        // no payload_mark today, but keep the union access discriminant-correct).
        if (self.isArray() or self.u.payload == null) return false;
        return rt.classes.markPayload(self.class_id, @ptrCast(rt), @ptrCast(self), &self.u.payload, visitor);
    }

    fn countPayloadFunctionBytecodeRef(context_ptr: *anyopaque, value_ptr: *anyopaque) void {
        const context: *PayloadBytecodeRefCountContext = @ptrCast(@alignCast(context_ptr));
        const stored: *JSValue = @ptrCast(@alignCast(value_ptr));
        context.count += countFunctionBytecodeValueRef(stored.*, context.function_bytecode);
    }

    fn collectReachableObjects(rt: *JSRuntime, visited: *ObjectVisitSet, current: *Object) ObjectGraphError!void {
        if (current.header.meta().rc == 0) return;
        const visit = try visited.getOrPut(@intFromPtr(current));
        if (visit.found_existing) return;
        try current.collectDirectChildObjects(rt, visited);
    }

    pub fn ClassPayloadTraceAdaptor(comptime VisitorType: type) type {
        return struct {
            visitor: VisitorType,

            pub fn visitValue(context_ptr: *anyopaque, value_ptr: *anyopaque) void {
                const self: *ClassPayloadTraceAdaptor(VisitorType) = @ptrCast(@alignCast(context_ptr));
                const stored: *JSValue = @ptrCast(@alignCast(value_ptr));
                const CleanType = comptime if (@typeInfo(VisitorType) == .pointer) @typeInfo(VisitorType).pointer.child else VisitorType;
                if (comptime @hasDecl(CleanType, "visitValue")) {
                    const ReturnType = @typeInfo(@TypeOf(CleanType.visitValue)).@"fn".return_type.?;
                    if (comptime @typeInfo(ReturnType) == .error_union) {
                        self.visitor.visitValue(stored) catch |err| {
                            if (comptime @typeInfo(VisitorType) == .pointer) {
                                if (comptime @hasField(@typeInfo(VisitorType).pointer.child, "err")) {
                                    self.visitor.err = err;
                                }
                            }
                        };
                    } else {
                        self.visitor.visitValue(stored);
                    }
                }
            }

            pub fn visitObject(context_ptr: *anyopaque, object_ptr: *anyopaque) void {
                const self: *ClassPayloadTraceAdaptor(VisitorType) = @ptrCast(@alignCast(context_ptr));
                const slot: *?*Object = @ptrCast(@alignCast(object_ptr));
                const CleanType = comptime if (@typeInfo(VisitorType) == .pointer) @typeInfo(VisitorType).pointer.child else VisitorType;
                if (comptime @hasDecl(CleanType, "visitObject")) {
                    const ReturnType = @typeInfo(@TypeOf(CleanType.visitObject)).@"fn".return_type.?;
                    if (comptime @typeInfo(ReturnType) == .error_union) {
                        self.visitor.visitObject(slot) catch |err| {
                            if (comptime @typeInfo(VisitorType) == .pointer) {
                                if (comptime @hasField(@typeInfo(VisitorType).pointer.child, "err")) {
                                    self.visitor.err = err;
                                }
                            }
                        };
                    } else {
                        self.visitor.visitObject(slot);
                    }
                }
            }
        };
    }

    pub inline fn traceChildEdgesFallible(self: *Object, rt: *JSRuntime, visitor: anytype) !void {
        const Helper = struct {
            inline fn callVisitObject(vis: anytype, obj_ptr: anytype) !void {
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

            inline fn callVisitValue(vis: anytype, val_ptr: anytype) !void {
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

            inline fn callVisitShape(vis: anytype, shape_ref: *shape.Shape) !void {
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

            inline fn traceOptValue(vis: anytype, opt_val: anytype) !void {
                if (opt_val.*) |*stored| try callVisitValue(vis, stored);
            }

            inline fn callVisitSymbol(vis: anytype, sym_ptr: anytype) !void {
                const VisType = @TypeOf(vis);
                const CleanType = comptime if (@typeInfo(VisType) == .pointer) @typeInfo(VisType).pointer.child else VisType;
                if (comptime @hasDecl(CleanType, "visitSymbol")) {
                    const ReturnType = @typeInfo(@TypeOf(CleanType.visitSymbol)).@"fn".return_type.?;
                    if (comptime @typeInfo(ReturnType) == .error_union) {
                        try vis.visitSymbol(sym_ptr);
                    } else {
                        vis.visitSymbol(sym_ptr);
                    }
                }
            }

            inline fn callVisitWeakCollectionEntry(vis: anytype, entry: anytype) !void {
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

            inline fn callVisitFinalizationCell(vis: anytype, entry: anytype) !void {
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
        };

        try Helper.callVisitShape(visitor, self.shape_ref);
        if (self.realmPayload()) |payload| {
            try Helper.callVisitObject(visitor, &payload.global_lexicals);
            // qjs js_global_object_mark (quickjs.c:17062-17067).
            try Helper.callVisitObject(visitor, &payload.uninitialized_vars);
            if (payload.shared_lazy_native_functions) |cache| {
                for (cache) |*maybe_cached| {
                    try Helper.traceOptValue(visitor, maybe_cached);
                }
            }
        }
        if (self.cachedIteratorNextSlotIfPresent(rt)) |slot| {
            try Helper.traceOptValue(visitor, slot);
        }
        // Property key atoms (including symbol keys) live in the shape;
        // visit them from there. Visitors only read symbol atoms (set
        // insertion / no-op), so revisiting a shared shape from several
        // objects is safe.
        for (self.shape_ref.props()[0..self.shape_ref.prop_count]) |*prop| {
            // `atom_id` is a packed-struct field (bit offset 32); visitors only
            // read symbol atoms (set insertion / no-op, never mutate a shared
            // shape's key), so pass a byte-aligned local copy.
            var key_atom = prop.atom_id;
            try Helper.callVisitSymbol(visitor, &key_atom);
        }
        // Only entries with a matching shape property record carry a derivable
        // kind. A property mid-`appendPreparedPropertyEntry` can have an entry
        // pushed before the shape transition completes (the shape-storage alloc
        // can trigger force-GC); such an over-hang entry has no shape prop yet,
        // so clamp to the shape's prop_count (matching `shapeProps()`). Its value
        // is a freshly-created object that is not yet a cycle member, so skipping
        // it for this trace cannot collect it prematurely.
        const traced_prop_count = self.shape_ref.prop_count;
        for (self.prop_values[0..traced_prop_count], 0..) |*entry, index| {
            const slot_flags = self.propFlagsAt(index);
            if (slot_flags.deleted) continue;
            switch (slot_flags.kind) {
                .data => try Helper.callVisitValue(visitor, &entry.slot.data),
                .accessor => {
                    // Accessor getter/setter are `?*gc.Header`, not JSValue, so
                    // round-trip through value space: read -> visit (the visitor
                    // may rewrite under a moving collector) -> sync back.
                    var getter_value = entry.slot.accessor.getterValue();
                    try Helper.callVisitValue(visitor, &getter_value);
                    entry.slot.accessor.syncGetterFromVisitedValue(getter_value);
                    var setter_value = entry.slot.accessor.setterValue();
                    try Helper.callVisitValue(visitor, &setter_value);
                    entry.slot.accessor.syncSetterFromVisitedValue(setter_value);
                },
                // JS_PROP_VARREF: the slot owns a ref on a cell (global lexical
                // bindings). Visit it so GC keeps the cell alive; without this a
                // cell only reachable through ctx.lexicals would be collected
                // (UAF). Visitors read the value by value, so a stack temp is safe.
                .var_ref => {
                    var cell_value = entry.slot.var_ref.valueRef();
                    try Helper.callVisitValue(visitor, &cell_value);
                },
                .auto_init => {},
            }
        }
        if (self.ordinaryPayload()) |payload| {
            try Helper.traceOptValue(visitor, &payload.callsite_file);
            try Helper.traceOptValue(visitor, &payload.callsite_function);
            try Helper.traceOptValue(visitor, &payload.promise_reaction_on_fulfilled);
            try Helper.traceOptValue(visitor, &payload.promise_reaction_on_rejected);
            try Helper.traceOptValue(visitor, &payload.promise_reaction_resolve);
            try Helper.traceOptValue(visitor, &payload.promise_reaction_reject);
            try Helper.traceOptValue(visitor, &payload.promise_capability_resolve);
            try Helper.traceOptValue(visitor, &payload.promise_capability_reject);
            try Helper.traceOptValue(visitor, &payload.promise_combinator_resolve);
            try Helper.traceOptValue(visitor, &payload.promise_combinator_reject);
            try Helper.traceOptValue(visitor, &payload.promise_combinator_values);
            try Helper.traceOptValue(visitor, &payload.promise_combinator_keys);
            try Helper.traceOptValue(visitor, &payload.typed_array_array_buffer_prototype);
            try Helper.traceOptValue(visitor, &payload.error_stack);
            try Helper.traceOptValue(visitor, &payload.error_stack_sites);
        }
        if (self.realmPayload()) |payload| {
            try Helper.callVisitObject(visitor, &payload.cached_function_proto);
            try Helper.callVisitObject(visitor, &payload.cached_promise_proto);
            for (&payload.cached_values) |*slot| {
                try Helper.traceOptValue(visitor, slot);
            }
            if (payload.regexp_legacy_statics) |legacy| {
                try Helper.traceOptValue(visitor, &legacy.input);
                try Helper.traceOptValue(visitor, &legacy.last_match);
                try Helper.traceOptValue(visitor, &legacy.last_paren);
                try Helper.traceOptValue(visitor, &legacy.left_context);
                try Helper.traceOptValue(visitor, &legacy.right_context);
                for (&legacy.captures) |*slot| try Helper.traceOptValue(visitor, slot);
            }
        }
        for (self.arrayElements()) |*stored| {
            try Helper.callVisitValue(visitor, stored);
        }
        if (self.typedArrayPayload()) |payload| {
            try Helper.traceOptValue(visitor, &payload.buffer);
        }
        if (self.objectDataPayload()) |payload| {
            try Helper.traceOptValue(visitor, &payload.data);
        }
        if (class.isBytecodeFunctionClass(self.class_id)) {
            // Save the slice before a clearing visitor can rewrite the FB edge;
            // the capture count is immutable FB metadata.
            const captures = self.u.bytecode_function.captureSlice();
            for (captures) |cell| {
                var cell_value = cell.valueRef();
                try Helper.callVisitValue(visitor, &cell_value);
            }
            if (self.u.bytecode_function.function_bytecode) |fb| {
                var bytecode_value = JSValue.functionBytecode(&fb.header);
                try Helper.callVisitValue(visitor, &bytecode_value);
                self.u.bytecode_function.function_bytecode = if (bytecode_value.objectHeader()) |header|
                    @alignCast(@fieldParentPtr("header", header))
                else
                    null;
            }
            var home_object = self.functionHomeObject();
            try Helper.callVisitObject(visitor, &home_object);
            if (self.bytecodeFunctionAux()) |aux| {
                aux.home_object = home_object;
            } else {
                self.u.bytecode_function.home_or_aux = if (home_object) |home| @ptrCast(home) else null;
            }
        }
        if (self.functionRarePayload()) |rare| {
            try Helper.traceOptValue(visitor, &rare.source);
            try Helper.traceOptValue(visitor, &rare.class_fields_init);
            try Helper.traceOptValue(visitor, &rare.import_meta);
            try Helper.traceOptValue(visitor, &rare.lexical_this);
            try Helper.traceOptValue(visitor, &rare.arrow_constructor_this);
            try Helper.traceOptValue(visitor, &rare.arrow_new_target);
            try Helper.traceOptValue(visitor, &rare.super_constructor);
            try Helper.traceOptValue(visitor, &rare.realm_global);
            for (&rare.primitive_prototypes) |*slot| {
                try Helper.traceOptValue(visitor, slot);
            }
            try Helper.traceOptValue(visitor, &rare.proxy_revoke_target);
            try Helper.traceOptValue(visitor, &rare.promise_capability_slot);
            try Helper.traceOptValue(visitor, &rare.promise_resolving_target);
            try Helper.traceOptValue(visitor, &rare.promise_resolving_state);
            try Helper.traceOptValue(visitor, &rare.promise_thenable_target);
            try Helper.traceOptValue(visitor, &rare.promise_thenable_this);
            try Helper.traceOptValue(visitor, &rare.promise_thenable_then);
            try Helper.traceOptValue(visitor, &rare.promise_reaction_record);
            try Helper.traceOptValue(visitor, &rare.promise_reaction_value);
            try Helper.traceOptValue(visitor, &rare.promise_combinator_state);
            try Helper.traceOptValue(visitor, &rare.promise_finally_payload);
            try Helper.traceOptValue(visitor, &rare.promise_finally_callback);
            try Helper.traceOptValue(visitor, &rare.promise_finally_constructor);
            try Helper.traceOptValue(visitor, &rare.async_dispose_stack);
            try Helper.traceOptValue(visitor, &rare.async_function_continuation);
            try Helper.traceOptValue(visitor, &rare.realm_type_error_constructor);
        }
        if (self.boundFunctionPayload()) |payload| {
            try Helper.traceOptValue(visitor, &payload.target);
            try Helper.traceOptValue(visitor, &payload.this_value);
            try Helper.traceOptValue(visitor, &payload.realm_global);
            for (payload.args) |*stored| try Helper.callVisitValue(visitor, stored);
        }
        if (self.collectionPayload()) |payload| {
            for (payload.entries) |*entry| {
                try Helper.callVisitValue(visitor, &entry.key);
                try Helper.callVisitValue(visitor, &entry.value);
            }
            for (payload.weak_entries) |*entry| {
                try Helper.callVisitWeakCollectionEntry(visitor, entry);
            }
        }
        if (self.finalizationRegistryPayload()) |payload| {
            try Helper.traceOptValue(visitor, &payload.cleanup_callback);
            for (payload.cells) |*entry| {
                try Helper.callVisitFinalizationCell(visitor, entry);
            }
        }
        if (self.disposableStackPayload()) |payload| {
            for (payload.resources) |*resource| {
                try Helper.callVisitValue(visitor, &resource.value);
                try Helper.callVisitValue(visitor, &resource.method);
            }
            try Helper.traceOptValue(visitor, &payload.async_dispose_resolve);
            try Helper.traceOptValue(visitor, &payload.async_dispose_reject);
            try Helper.traceOptValue(visitor, &payload.async_dispose_error);
        }
        if (self.iteratorPayload()) |payload| {
            try Helper.traceOptValue(visitor, &payload.target);
            try Helper.traceOptValue(visitor, &payload.data);
            try Helper.traceOptValue(visitor, &payload.next);
            try Helper.traceOptValue(visitor, &payload.callback);
            try Helper.traceOptValue(visitor, &payload.inner_next);
            try Helper.traceOptValue(visitor, &payload.zip_nexts);
            try Helper.traceOptValue(visitor, &payload.zip_pads);
            try Helper.traceOptValue(visitor, &payload.zip_keys);
        }
        if (self.generatorPayload()) |payload| {
            if (payload.execution) |execution| {
                try Helper.callVisitValue(visitor, &execution.this_value);
                if (!execution.suspended.running_aliases) {
                    for (execution.suspended.storage.stack.values) |*stored| try Helper.callVisitValue(visitor, stored);
                    for (execution.suspended.storage.frame.locals) |*stored| try Helper.callVisitValue(visitor, stored);
                    for (execution.suspended.storage.frame.args) |*stored| try Helper.callVisitValue(visitor, stored);
                    // qjs marks the resident JSAsyncFunctionState frame's var_refs;
                    // there is no second generator-payload capture array.
                    for (execution.suspended.storage.frame.var_refs) |cell| {
                        var cell_value = cell.valueRef();
                        try Helper.callVisitValue(visitor, &cell_value);
                    }
                    for (execution.suspended.storage.frame.open_var_refs) |maybe_cell| {
                        const cell = maybe_cell orelse continue;
                        var cell_value = cell.valueRef();
                        try Helper.callVisitValue(visitor, &cell_value);
                    }
                }
                try Helper.callVisitValue(visitor, &execution.current_function);
                try Helper.callVisitValue(visitor, &execution.yield_star_iterator);
            }
            try Helper.traceOptValue(visitor, &payload.async_promise);
            // Async-generator request queue values (mirrors
            // js_async_generator_mark, quickjs.c:21400-21418).
            for (payload.async_queue) |*req| {
                try Helper.callVisitValue(visitor, &req.result);
                try Helper.callVisitValue(visitor, &req.promise);
                try Helper.callVisitValue(visitor, &req.resolve);
                try Helper.callVisitValue(visitor, &req.reject);
            }
        }
        if (self.varRefPayload()) |payload| {
            try Helper.traceOptValue(visitor, &payload.value);
        }
        if (self.class_id == class.ids.mapped_arguments) {
            for (self.argumentsVarRefs()) |maybe_cell| {
                const cell = maybe_cell orelse continue;
                var cell_value = cell.valueRef();
                try Helper.callVisitValue(visitor, &cell_value);
            }
        }
        if (self.proxyPayload()) |payload| {
            try Helper.traceOptValue(visitor, &payload.target);
            try Helper.traceOptValue(visitor, &payload.handler);
        }
        if (self.promisePayload()) |payload| {
            try Helper.traceOptValue(visitor, &payload.result);
            try Helper.traceOptValue(visitor, &payload.reaction_callback);
            try Helper.traceOptValue(visitor, &payload.reaction_arg);
            for (payload.reactions) |*stored| try Helper.callVisitValue(visitor, stored);
        }
        if (self.moduleNamespacePayload()) |payload| {
            for (payload.cells) |*stored| try Helper.callVisitValue(visitor, stored);
        }
        const Adaptor = ClassPayloadTraceAdaptor(@TypeOf(visitor));
        var adaptor = Adaptor{ .visitor = visitor };
        var class_visitor = class.PayloadVisitor{
            .context = @ptrCast(&adaptor),
            .visit_value = Adaptor.visitValue,
            .visit_object = Adaptor.visitObject,
        };
        _ = self.markClassPayload(rt, &class_visitor);
        if (@typeInfo(@TypeOf(visitor)) == .pointer) {
            if (comptime @hasField(@typeInfo(@TypeOf(visitor)).pointer.child, "err")) {
                if (visitor.err) |err| return err;
            }
        }
    }

    pub inline fn traceChildEdges(self: *Object, rt: *JSRuntime, visitor: anytype) !void {
        return self.traceChildEdgesFallible(rt, visitor);
    }

    pub inline fn traceChildEdgesNoFail(self: *Object, rt: *JSRuntime, visitor: anytype) void {
        self.traceChildEdgesFallible(rt, visitor) catch unreachable;
    }

    fn collectDirectChildObjects(self: *Object, rt: *JSRuntime, visited: *ObjectVisitSet) ObjectGraphError!void {
        const CollectVisitor = struct {
            rt: *JSRuntime,
            visited: *ObjectVisitSet,
            err: ?ObjectGraphError = null,

            pub fn visitObject(cv: *@This(), obj_ptr: *?*Object) !void {
                if (obj_ptr.*) |obj| {
                    if (@intFromPtr(obj) == 0) return;
                    try collectReachableObjects(cv.rt, cv.visited, obj);
                }
            }

            pub fn visitValue(cv: *@This(), val_ptr: *JSValue) !void {
                try collectValueObject(cv.rt, cv.visited, val_ptr.*);
            }

            pub fn visitSymbol(cv: *@This(), sym_ptr: *atom.Atom) !void {
                _ = cv;
                _ = sym_ptr;
            }

            pub fn visitWeakCollectionEntry(cv: *@This(), entry: *WeakCollectionEntry) !void {
                try collectValueObject(cv.rt, cv.visited, entry.value);
            }

            pub fn visitFinalizationCell(cv: *@This(), entry: *FinalizationRegistryCell) !void {
                if (entry.keepsHeldValuesAlive()) {
                    try collectValueObject(cv.rt, cv.visited, entry.held_value);
                }
            }
        };
        var visitor = CollectVisitor{ .rt = rt, .visited = visited };
        try self.traceChildEdgesFallible(rt, &visitor);
    }

    fn collectValueObject(rt: *JSRuntime, visited: *ObjectVisitSet, stored: JSValue) ObjectGraphError!void {
        if (objectFromValue(stored)) |child| {
            try collectReachableObjects(rt, visited, child);
            return;
        }
        const function_bytecode = functionBytecodeFromValue(stored) orelse return;
        try collectFunctionBytecodeChildObjects(rt, visited, function_bytecode);
    }

    fn collectFunctionBytecodeChildObjects(rt: *JSRuntime, visited: *ObjectVisitSet, function_bytecode: *const FunctionBytecode) ObjectGraphError!void {
        if (function_bytecode.class_fields_init) |stored| try collectValueObject(rt, visited, stored.*);
        if (function_bytecode.realm_global_header) |realm_header| {
            const realm_global: *Object = @fieldParentPtr("header", realm_header);
            try collectReachableObjects(rt, visited, realm_global);
        }
        for (function_bytecode.cpoolSlice()) |stored| try collectValueObject(rt, visited, stored);
    }

    fn enqueueFinalizationCleanup(rt: *JSRuntime, cleanup_callback: ?JSValue, held_value: JSValue) ObjectGraphError!void {
        const callback = cleanup_callback orelse return;
        try rt.enqueueFinalizationJob(callback, held_value);
    }

    /// Returns the weak identity for `stored`, registering objects in the
    /// runtime's weak identity registry on first use. Symbols encode as
    /// `(atom << 1) | 1`; objects encode as `weak_id << 1`.
    pub fn weakIdentityFromValue(rt: *JSRuntime, stored: JSValue) !?usize {
        if (stored.asSymbolAtom()) |atom_id| return (@as(usize, @intCast(atom_id)) << 1) | 1;
        const object = objectFromWeakCandidate(stored) orelse return null;
        return try rt.registerWeakObjectIdentity(object);
    }

    /// Like `weakIdentityFromValue` but never registers: returns null for
    /// objects that were never weakly referenced.
    pub fn weakIdentityFromValuePeek(rt: *const JSRuntime, stored: JSValue) ?usize {
        if (stored.asSymbolAtom()) |atom_id| return (@as(usize, @intCast(atom_id)) << 1) | 1;
        const object = objectFromWeakCandidate(stored) orelse return null;
        return rt.peekWeakObjectIdentity(object);
    }

    fn objectFromWeakCandidate(stored: JSValue) ?*Object {
        const header = stored.refHeader() orelse return null;
        if (header.meta().kind != .object) return null;
        return @alignCast(@fieldParentPtr("header", header));
    }

    fn accumulateIncomingReferences(
        self: *Object,
        rt: *JSRuntime,
        visited: *const ObjectVisitSet,
        incoming: *ObjectIncomingMap,
        internal_bytecodes: *const ObjectVisitSet,
        processed_bytecodes: *ObjectVisitSet,
    ) ObjectGraphError!void {
        const AccumulateIncomingVisitor = struct {
            visited: *const ObjectVisitSet,
            incoming: *ObjectIncomingMap,
            internal_bytecodes: *const ObjectVisitSet,
            processed_bytecodes: *ObjectVisitSet,
            err: ?ObjectGraphError = null,

            pub fn visitObject(av: *@This(), obj_ptr: *?*Object) !void {
                if (obj_ptr.*) |obj| {
                    if (@intFromPtr(obj) == 0) return;
                    try incrementIncomingIfVisited(av.visited, av.incoming, obj);
                }
            }

            pub fn visitValue(av: *@This(), val_ptr: *JSValue) !void {
                try accumulateValueIncoming(val_ptr.*, av.visited, av.incoming, av.internal_bytecodes, av.processed_bytecodes);
            }

            pub fn visitSymbol(av: *@This(), sym_ptr: *atom.Atom) !void {
                _ = av;
                _ = sym_ptr;
            }

            pub fn visitWeakCollectionEntry(av: *@This(), entry: *WeakCollectionEntry) !void {
                try accumulateValueIncoming(entry.value, av.visited, av.incoming, av.internal_bytecodes, av.processed_bytecodes);
            }

            pub fn visitFinalizationCell(av: *@This(), entry: *FinalizationRegistryCell) !void {
                if (entry.keepsHeldValuesAlive()) {
                    try accumulateValueIncoming(entry.held_value, av.visited, av.incoming, av.internal_bytecodes, av.processed_bytecodes);
                }
            }
        };
        var visitor = AccumulateIncomingVisitor{
            .visited = visited,
            .incoming = incoming,
            .internal_bytecodes = internal_bytecodes,
            .processed_bytecodes = processed_bytecodes,
        };
        try self.traceChildEdgesFallible(rt, &visitor);
    }

    fn accumulateValueIncoming(
        stored: JSValue,
        visited: *const ObjectVisitSet,
        incoming: *ObjectIncomingMap,
        internal_bytecodes: *const ObjectVisitSet,
        processed_bytecodes: *ObjectVisitSet,
    ) ObjectGraphError!void {
        if (objectFromValue(stored)) |child| {
            try incrementIncomingIfVisited(visited, incoming, child);
            return;
        }
        const function_bytecode = functionBytecodeFromValue(stored) orelse return;
        const bytecode_address = @intFromPtr(function_bytecode);
        if (!internal_bytecodes.contains(bytecode_address)) return;
        const entry = try processed_bytecodes.getOrPut(bytecode_address);
        if (entry.found_existing) return;
        try accumulateFunctionBytecodeChildIncoming(function_bytecode, visited, incoming, internal_bytecodes, processed_bytecodes);
    }

    fn accumulateFunctionBytecodeChildIncoming(
        function_bytecode: *const FunctionBytecode,
        visited: *const ObjectVisitSet,
        incoming: *ObjectIncomingMap,
        internal_bytecodes: *const ObjectVisitSet,
        processed_bytecodes: *ObjectVisitSet,
    ) ObjectGraphError!void {
        if (function_bytecode.class_fields_init) |stored| try accumulateValueIncoming(stored.*, visited, incoming, internal_bytecodes, processed_bytecodes);
        if (function_bytecode.realm_global_header) |realm_header| {
            const realm_global: *Object = @fieldParentPtr("header", realm_header);
            try incrementIncomingIfVisited(visited, incoming, realm_global);
        }
        for (function_bytecode.cpoolSlice()) |stored| try accumulateValueIncoming(stored, visited, incoming, internal_bytecodes, processed_bytecodes);
    }

    fn incrementIncomingIfVisited(visited: *const ObjectVisitSet, incoming: *ObjectIncomingMap, child: *Object) ObjectGraphError!void {
        const address = @intFromPtr(child);
        if (!visited.contains(address)) return;
        const entry = incoming.getPtr(address) orelse return;
        entry.* += 1;
    }

    /// True when `child` is condemned garbage in the current cycle-removal round
    /// (it stayed `cycle_visited` after gc_scan, i.e. was not resurrected).
    inline fn objectIsCycleGarbage(child: *const Object) bool {
        return child.header.metaConst().flags.cycle_visited;
    }

    inline fn headerIsCycleGarbage(header: *const gc.Header) bool {
        return header.metaConst().flags.cycle_visited;
    }

    // `clearValueReferenceToVisited` / `clearFunctionBytecodeReferencesToVisited`
    // / `valueReferencesVisited` survive: they are used by the weak-collection
    // cycle sweep (`sweepCycleGarbageWeakCollectionEntries`). The object/var_ref
    // edge-nulling pre-pass that used to drive them during destruction was deleted
    // (STEP 3) — the REMOVE_CYCLES gate in `gc.releaseAndDestroy` now defends
    // against cascades, exactly as qjs relies on its `__JS_FreeValueRT` gate.
    fn clearValueReferenceToVisited(
        rt: *JSRuntime,
        stored: *JSValue,
    ) void {
        if (valueReferencesVisited(stored.*)) {
            stored.* = JSValue.undefinedValue();
            return;
        }
        if (functionBytecodeFromValue(stored.*)) |function_bytecode| {
            if (!headerIsCycleGarbage(&function_bytecode.header)) return;
            stored.* = JSValue.undefinedValue();
            clearFunctionBytecodeReferencesToVisited(rt, function_bytecode);
            return;
        }
        const cell = varRefCellFromValue(stored.*) orelse return;
        if (valueReferencesVisited(cell.varRefValue())) cell.varRefValueSlot().* = JSValue.undefinedValue();
    }

    fn clearFunctionBytecodeReferencesToVisited(
        rt: *JSRuntime,
        function_bytecode: *FunctionBytecode,
    ) void {
        if (function_bytecode.class_fields_init) |stored| clearValueReferenceToVisited(rt, stored);
        if (function_bytecode.realm_global_header) |realm_header| {
            const realm_global: *Object = @fieldParentPtr("header", realm_header);
            if (objectIsCycleGarbage(realm_global)) function_bytecode.realm_global_header = null;
        }
        for (function_bytecode.cpoolSlice()) |*stored| clearValueReferenceToVisited(rt, stored);
    }

    fn valueReferencesVisited(stored: JSValue) bool {
        if (objectFromValue(stored)) |child| return objectIsCycleGarbage(child);
        if (var_ref_mod.VarRef.fromValue(stored)) |ref| return headerIsCycleGarbage(&ref.header);
        return false;
    }

    fn functionBytecodeFromValue(stored: JSValue) ?*FunctionBytecode {
        const header = stored.objectHeader() orelse return null;
        if (header.meta().kind != .function_bytecode) return null;
        const aligned: *align(16) @TypeOf(header.*) = @alignCast(header);
        return @fieldParentPtr("header", aligned);
    }

    fn collectInternalFunctionBytecodes(
        rt: *JSRuntime,
        visited: *const ObjectVisitSet,
        internal_bytecodes: *ObjectVisitSet,
    ) ObjectGraphError!void {
        try collectFunctionBytecodeCandidates(rt, visited, internal_bytecodes);
        try pruneNonInternalFunctionBytecodes(rt, visited, internal_bytecodes);
    }

    fn collectFunctionBytecodeCandidates(
        rt: *JSRuntime,
        visited: *const ObjectVisitSet,
        candidates: *ObjectVisitSet,
    ) ObjectGraphError!void {
        var changed = true;
        while (changed) {
            changed = false;
            var gc_iter = rt.gc.objectIterator();
            while (gc_iter.next()) |header| {
                const function_bytecode = functionBytecodeFromGcHeader(header) orelse {
                    continue;
                };
                const address = @intFromPtr(function_bytecode);
                if (candidates.contains(address)) {
                    continue;
                }

                const internal_refs =
                    (try countFunctionBytecodeRefsFromVisitedObjects(rt, function_bytecode, visited)) +
                    countFunctionBytecodeRefsFromFunctionBytecodes(function_bytecode, candidates);
                if (internal_refs == 0) {
                    continue;
                }

                try candidates.put(address, {});
                changed = true;
            }
        }
    }

    fn pruneNonInternalFunctionBytecodes(
        rt: *JSRuntime,
        visited: *const ObjectVisitSet,
        internal_bytecodes: *ObjectVisitSet,
    ) ObjectGraphError!void {
        while (true) {
            var removed = false;
            var iterator = internal_bytecodes.keyIterator();
            while (iterator.next()) |address| {
                const function_bytecode: *const FunctionBytecode = @ptrFromInt(address.*);
                const internal_refs =
                    (try countFunctionBytecodeRefsFromVisitedObjects(rt, function_bytecode, visited)) +
                    countFunctionBytecodeRefsFromFunctionBytecodes(function_bytecode, internal_bytecodes);
                if (internal_refs == function_bytecode.header.meta().rc) continue;

                _ = internal_bytecodes.remove(address.*);
                removed = true;
                break;
            }
            if (!removed) return;
        }
    }

    fn functionBytecodeFromGcHeader(header: *gc.GCObjectHeader) ?*const FunctionBytecode {
        if (header.meta().kind != .function_bytecode) return null;
        return @alignCast(@fieldParentPtr("header", header));
    }

    fn countFunctionBytecodeRefsFromVisitedObjects(
        rt: *JSRuntime,
        function_bytecode: *const FunctionBytecode,
        visited: *const ObjectVisitSet,
    ) ObjectGraphError!usize {
        var count: usize = 0;
        var iterator = visited.keyIterator();
        while (iterator.next()) |address| {
            const current: *Object = @ptrFromInt(address.*);
            count += try current.countDirectFunctionBytecodeRefs(rt, function_bytecode);
        }
        return count;
    }

    fn countFunctionBytecodeRefsFromFunctionBytecodes(
        function_bytecode: *const FunctionBytecode,
        owners: *const ObjectVisitSet,
    ) usize {
        var count: usize = 0;
        var iterator = owners.keyIterator();
        while (iterator.next()) |address| {
            const owner: *const FunctionBytecode = @ptrFromInt(address.*);
            count += countFunctionBytecodeChildRefs(owner, function_bytecode);
        }
        return count;
    }

    fn countFunctionBytecodeChildRefs(
        owner: *const FunctionBytecode,
        function_bytecode: *const FunctionBytecode,
    ) usize {
        var count: usize = 0;
        count += countOptionalFunctionBytecodeRef(if (owner.class_fields_init) |boxed| boxed.* else null, function_bytecode);
        for (owner.cpoolSlice()) |stored| count += countFunctionBytecodeValueRef(stored, function_bytecode);
        return count;
    }

    fn countDirectFunctionBytecodeRefs(
        self: *Object,
        rt: *JSRuntime,
        function_bytecode: *const FunctionBytecode,
    ) ObjectGraphError!usize {
        var count: usize = 0;
        count += countOptionalFunctionBytecodeRef(self.cachedIteratorNext(rt), function_bytecode);
        // Clamp to the shape's prop_count: a mid-append over-hang entry has no
        // shape prop yet (no derivable kind) and is a freshly-created value, so
        // it cannot reference this bytecode anyway.
        const counted = self.shape_ref.prop_count;
        for (self.prop_values[0..counted], 0..) |entry, index| count += countSlotFunctionBytecodeRefs(self.propFlagsAt(index), entry.slot, function_bytecode);
        if (self.realmPayloadConst()) |payload| {
            if (payload.shared_lazy_native_functions) |cache| {
                for (cache) |maybe_cached| count += countOptionalFunctionBytecodeRef(maybe_cached, function_bytecode);
            }
        }
        if (self.ordinaryPayloadConst()) |payload| {
            count += countOptionalFunctionBytecodeRef(payload.callsite_file, function_bytecode);
            count += countOptionalFunctionBytecodeRef(payload.callsite_function, function_bytecode);
            count += countOptionalFunctionBytecodeRef(payload.promise_reaction_on_fulfilled, function_bytecode);
            count += countOptionalFunctionBytecodeRef(payload.promise_reaction_on_rejected, function_bytecode);
            count += countOptionalFunctionBytecodeRef(payload.promise_reaction_resolve, function_bytecode);
            count += countOptionalFunctionBytecodeRef(payload.promise_reaction_reject, function_bytecode);
            count += countOptionalFunctionBytecodeRef(payload.promise_capability_resolve, function_bytecode);
            count += countOptionalFunctionBytecodeRef(payload.promise_capability_reject, function_bytecode);
            count += countOptionalFunctionBytecodeRef(payload.promise_combinator_resolve, function_bytecode);
            count += countOptionalFunctionBytecodeRef(payload.promise_combinator_reject, function_bytecode);
            count += countOptionalFunctionBytecodeRef(payload.promise_combinator_values, function_bytecode);
            count += countOptionalFunctionBytecodeRef(payload.promise_combinator_keys, function_bytecode);
            count += countOptionalFunctionBytecodeRef(payload.typed_array_array_buffer_prototype, function_bytecode);
            count += countOptionalFunctionBytecodeRef(payload.error_stack, function_bytecode);
            count += countOptionalFunctionBytecodeRef(payload.error_stack_sites, function_bytecode);
        }
        if (self.realmPayloadConst()) |payload| {
            for (payload.cached_values) |stored| count += countOptionalFunctionBytecodeRef(stored, function_bytecode);
            if (payload.regexp_legacy_statics) |legacy| {
                count += countOptionalFunctionBytecodeRef(legacy.input, function_bytecode);
                count += countOptionalFunctionBytecodeRef(legacy.last_match, function_bytecode);
                count += countOptionalFunctionBytecodeRef(legacy.last_paren, function_bytecode);
                count += countOptionalFunctionBytecodeRef(legacy.left_context, function_bytecode);
                count += countOptionalFunctionBytecodeRef(legacy.right_context, function_bytecode);
                for (legacy.captures) |stored| count += countOptionalFunctionBytecodeRef(stored, function_bytecode);
            }
        }
        for (self.arrayElements()) |stored| count += countFunctionBytecodeValueRef(stored, function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.typedArrayBuffer(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.objectData(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionSource(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.boundTarget(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.boundThis(), function_bytecode);
        for (self.boundArgs()) |stored| count += countFunctionBytecodeValueRef(stored, function_bytecode);
        for (self.collectionEntries()) |entry| {
            count += countFunctionBytecodeValueRef(entry.key, function_bytecode);
            count += countFunctionBytecodeValueRef(entry.value, function_bytecode);
        }
        for (self.weakCollectionEntries()) |entry| count += countFunctionBytecodeValueRef(entry.value, function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.finalizationRegistryCleanupCallback(), function_bytecode);
        for (self.finalizationRegistryCells()) |entry| {
            if (!entry.keepsHeldValuesAlive()) continue;
            count += countFunctionBytecodeValueRef(entry.held_value, function_bytecode);
        }
        if (self.disposableStackPayloadConst()) |payload| {
            for (payload.resources) |resource| {
                count += countFunctionBytecodeValueRef(resource.value, function_bytecode);
                count += countFunctionBytecodeValueRef(resource.method, function_bytecode);
            }
            count += countOptionalFunctionBytecodeRef(payload.async_dispose_resolve, function_bytecode);
            count += countOptionalFunctionBytecodeRef(payload.async_dispose_reject, function_bytecode);
            count += countOptionalFunctionBytecodeRef(payload.async_dispose_error, function_bytecode);
        }
        count += countOptionalFunctionBytecodeRef(self.iteratorTarget(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.iteratorData(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.iteratorNext(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.iteratorCallback(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.iteratorInnerNext(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.iteratorZipNexts(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.iteratorZipPads(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.iteratorZipKeys(), function_bytecode);
        // Count owned edges, not the generator functionBytecode() derived view:
        // a generator owns current_function, and that function owns its FB.
        if (class.isBytecodeFunctionClass(self.class_id)) {
            if (self.u.bytecode_function.function_bytecode == function_bytecode) count += 1;
        }
        count += countOptionalFunctionBytecodeRef(self.functionClassFieldsInit(), function_bytecode);
        for (self.functionCaptures()) |cell| count += countFunctionBytecodeValueRef(cell.valueRef(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionImportMeta(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionLexicalThis(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionArrowConstructorThis(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionArrowNewTarget(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionSuperConstructor(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionRealmGlobal(), function_bytecode);
        if (self.functionRarePayloadConst()) |payload| {
            for (payload.primitive_prototypes) |stored| count += countOptionalFunctionBytecodeRef(stored, function_bytecode);
        }
        count += countOptionalFunctionBytecodeRef(self.functionProxyRevokeTarget(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionPromiseCapabilitySlot(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionPromiseResolvingTarget(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionPromiseResolvingState(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionPromiseThenableTarget(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionPromiseThenableThis(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionPromiseThenableThen(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionPromiseReactionRecord(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionPromiseReactionValue(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionPromiseCombinatorState(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionPromiseFinallyPayload(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionPromiseFinallyCallback(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionPromiseFinallyConstructor(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionAsyncDisposeStack(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionAsyncContinuation(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionRealmTypeErrorConstructor(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.generatorThis(), function_bytecode);
        if (self.generatorPayloadConst()) |payload| {
            if (payload.execution) |execution| {
                if (!execution.suspended.running_aliases) {
                    for (execution.suspended.storage.stack.values) |stored| count += countFunctionBytecodeValueRef(stored, function_bytecode);
                    for (execution.suspended.storage.frame.locals) |stored| count += countFunctionBytecodeValueRef(stored, function_bytecode);
                    for (execution.suspended.storage.frame.args) |stored| count += countFunctionBytecodeValueRef(stored, function_bytecode);
                    for (execution.suspended.storage.frame.var_refs) |cell| count += countFunctionBytecodeValueRef(cell.valueRef(), function_bytecode);
                    for (execution.suspended.storage.frame.open_var_refs) |maybe_cell| {
                        if (maybe_cell) |cell| count += countFunctionBytecodeValueRef(cell.valueRef(), function_bytecode);
                    }
                }
            }
        }
        count += countOptionalFunctionBytecodeRef(self.generatorCurrentFunction(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.generatorYieldStarIterator(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.generatorAsyncPromise(), function_bytecode);
        if (self.varRefPayloadConst()) |payload| {
            if (payload.value) |stored| count += countFunctionBytecodeValueRef(stored, function_bytecode);
        }
        for (self.argumentsVarRefs()) |maybe_cell| {
            const cell = maybe_cell orelse continue;
            count += countFunctionBytecodeValueRef(cell.valueRef(), function_bytecode);
        }
        count += countOptionalFunctionBytecodeRef(self.proxyTarget(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.proxyHandler(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.promiseResult(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.promiseReactionCallback(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.promiseReactionArg(), function_bytecode);
        for (self.promiseReactions()) |stored| count += countFunctionBytecodeValueRef(stored, function_bytecode);
        if (self.moduleNamespacePayloadConst()) |payload| {
            for (payload.cells) |cell| count += countFunctionBytecodeValueRef(cell, function_bytecode);
        }
        count += self.countClassPayloadFunctionBytecodeRefs(rt, function_bytecode);
        return count;
    }

    fn countClassPayloadFunctionBytecodeRefs(
        self: *Object,
        rt: *JSRuntime,
        function_bytecode: *const FunctionBytecode,
    ) usize {
        var context = PayloadBytecodeRefCountContext{ .function_bytecode = function_bytecode };
        var visitor = class.PayloadVisitor{
            .context = @ptrCast(&context),
            .visit_value = countPayloadFunctionBytecodeRef,
        };
        _ = self.markClassPayload(rt, &visitor);
        return context.count;
    }

    fn countSlotFunctionBytecodeRefs(flags: property.Flags, slot: property.Slot, function_bytecode: *const FunctionBytecode) usize {
        if (flags.deleted) return 0;
        return switch (flags.kind) {
            .data => countFunctionBytecodeValueRef(slot.data, function_bytecode),
            .accessor => countFunctionBytecodeValueRef(slot.accessor.getterValue(), function_bytecode) +
                countFunctionBytecodeValueRef(slot.accessor.setterValue(), function_bytecode),
            .var_ref, .auto_init => 0,
        };
    }

    fn countOptionalFunctionBytecodeRef(maybe_value: ?JSValue, function_bytecode: *const FunctionBytecode) usize {
        return if (maybe_value) |stored| countFunctionBytecodeValueRef(stored, function_bytecode) else 0;
    }

    fn countFunctionBytecodeValueRef(stored: JSValue, function_bytecode: *const FunctionBytecode) usize {
        const header = stored.objectHeader() orelse return 0;
        return if (header == &function_bytecode.header) 1 else 0;
    }

    pub fn getPrototype(self: *const Object) ?*Object {
        return self.shape_ref.proto;
    }

    pub fn setPrototype(self: *Object, rt: *JSRuntime, prototype: ?*Object) Error!void {
        if (self.getPrototype() == prototype) return;
        var cursor = prototype;
        while (cursor) |candidate| {
            if (candidate == self) return error.PrototypeCycle;
            cursor = candidate.getPrototype();
        }
        if (!self.flags.extensible) return error.NotExtensible;
        if (prototype) |proto| gc.retain(&proto.header);
        errdefer if (prototype) |proto| proto.value().free(rt);
        markObjectAsPrototype(rt, prototype);
        try rt.shapes.prepareUpdate(&self.shape_ref);
        const old_prototype = rt.shapes.replacePrototypeAssumePrepared(self.shape_ref, prototype);
        if (old_prototype) |old| old.value().free(rt);
    }

    /// Rebind an unexposed, property-empty object to the shared root shape for
    /// its final prototype. Construction paths sometimes must resolve a
    /// user-visible `constructor.prototype` only after preparing class state;
    /// using ordinary `setPrototype` there clones the initial shared root and
    /// leaves every instance with a private empty shape. This is the delayed
    /// equivalent of qjs `JS_NewObjectFromShape` with the final prototype.
    pub fn setFreshObjectPrototype(self: *Object, rt: *JSRuntime, prototype: ?*Object) Error!void {
        std.debug.assert(self.shape_ref.prop_count == 0);
        std.debug.assert(!self.hasPropertyStorage());
        std.debug.assert(self.flags.extensible);
        std.debug.assert(prototype != self);
        if (self.getPrototype() == prototype) return;

        const replacement = try rt.shapes.createObjectRoot(prototype);
        markObjectAsPrototype(rt, prototype);
        const previous = self.shape_ref;
        self.shape_ref = replacement;
        rt.shapes.release(previous);
    }

    pub fn preventExtensions(self: *Object) void {
        self.flags.extensible = false;
    }

    pub fn isExtensible(self: *const Object) bool {
        return self.flags.extensible;
    }

    pub fn markImmutablePrototype(self: *Object) void {
        self.flags.immutable_prototype = true;
    }

    pub fn hasImmutablePrototype(self: *const Object) bool {
        return self.flags.immutable_prototype;
    }

    pub fn getOwnProperty(self: *const Object, rt: *JSRuntime, atom_id: atom.Atom) ?descriptor.Descriptor {
        if (self.exoticMethods(rt)) |methods| {
            if (methods.get_own_property) |hook| {
                if (hook(@constCast(self), atom_id)) |desc| return desc;
            }
        }
        if (self.moduleNamespaceBindingValue(atom_id)) |stored| {
            return descriptor.Descriptor.data(stored, true, true, false);
        }
        if (self.isArray() and atom_id == atom.ids.length) {
            return descriptor.Descriptor.data(arrayLengthValue(self.arrayLength()), self.flags.length_writable, false, false);
        }
        if (self.mappedArgumentsBindingIndexFromAtom(rt, atom_id)) |mapped_index| {
            const mapped_value = self.mappedArgumentsBindingValue(mapped_index) orelse return null;
            if (self.findProperty(atom_id)) |property_index| {
                const flags = self.propFlagsAt(property_index);
                if (!flags.deleted and flags.kind == .data) {
                    return descriptor.Descriptor.data(mapped_value, flags.writable, flags.enumerable, flags.configurable);
                }
            }
            return descriptor.Descriptor.data(mapped_value, true, true, true);
        }
        if (self.findProperty(atom_id)) |index| {
            const entry = self.prop_values[index];
            const entry_flags = self.propFlagsAt(index);
            if (entry_flags.deleted) return null;
            // Auto-init placeholders need to be materialized before
            // the descriptor is built (`fromSlot` cannot synthesize
            // a value from `(name, length, rt)` on its own). This
            // mirrors `getProperty`'s first-access promotion -- after
            // materialization the slot is `.data` or `.accessor` and
            // re-reads are ordinary fast-path loads.
            if (entry_flags.isAutoInit()) {
                const info = property.autoInit(entry.slot.auto_init).*;
                // `materializeAutoInit` returns a fresh ref for
                // `getProperty` semantics. On success the slot is promoted
                // and `fromSlot` dups the stored value(s). On OOM the
                // placeholder stays `.auto_init`, so expose a conservative
                // fallback descriptor directly instead of passing the
                // placeholder to `fromSlot`.
                const transient = materializeAutoInit(@constCast(self), index, info);
                if (self.propFlagsAt(index).isAutoInit()) {
                    // OOM fallback: the placeholder did not promote. An auto_init
                    // that materializes into an accessor is `info.kind ==
                    // .native_accessor` (the only accessor-shaped placeholder);
                    // all others promote to data. The kind flag is still
                    // `.auto_init` here so derive the shape from `info`.
                    if (info.kind == .native_accessor) {
                        return descriptor.Descriptor.accessor(
                            transient,
                            JSValue.undefinedValue(),
                            entry_flags.enumerable,
                            entry_flags.configurable,
                        );
                    }
                    return descriptor.Descriptor.data(
                        transient,
                        entry_flags.writable,
                        entry_flags.enumerable,
                        entry_flags.configurable,
                    );
                }
                transient.free(info.rt);
                return descriptor.Descriptor.fromSlot(self.propFlagsAt(index), self.prop_values[index].slot);
            }
            return descriptor.Descriptor.fromSlot(entry_flags, entry.slot);
        }
        if (self.denseArrayElement(atom_id)) |stored| {
            return descriptor.Descriptor.data(stored.dup(), true, true, true);
        }
        return null;
    }

    /// Snapshot of an own key's enumerable bit, read straight off the shape
    /// flags (or the always-enumerable dense-array slot) without allocating a
    /// `Descriptor`. Mirrors the enumerability that `getOwnProperty` would
    /// report for the cheap, non-throwing, non-exotic cases.
    ///
    /// `.descriptor` means "this key cannot be resolved off the shape cheaply
    /// or could observably throw -- fall back to the full descriptor probe".
    /// This is the same boundary QuickJS draws in `JS_CopyDataProperties`
    /// (quickjs.c:16920): it requests `JS_GPN_ENUM_ONLY` for an ordinary
    /// source so the per-key enumerable test is skipped, but clears it for an
    /// exotic source with a `get_own_property_names` hook so the descriptor
    /// test runs per key.
    pub const OwnEnumerable = enum { enumerable, not_enumerable, descriptor };

    pub fn ownPropertyEnumerableKind(self: *const Object, rt: *const JSRuntime, atom_id: atom.Atom) OwnEnumerable {
        // Exotic get-own-property hooks (test-only in this build) can report
        // an enumerability that differs from the shape, exactly the case
        // QuickJS drops JS_GPN_ENUM_ONLY for -- defer to the descriptor probe.
        if (self.exoticMethods(rt)) |methods| {
            if (methods.get_own_property != null) return .descriptor;
        }
        // Typed arrays (canonical numeric index) and module-namespace bindings
        // need detached/range/TDZ checks that the descriptor path performs and
        // that can observably throw; never snapshot those off the shape.
        if (isTypedArrayObject(self)) return .descriptor;
        if (self.moduleNamespacePayloadConst() != null) return .descriptor;

        if (self.isArray() and atom_id == atom.ids.length) return .not_enumerable;
        if (self.findProperty(atom_id)) |index| {
            return if (self.propFlagsAt(index).enumerable) .enumerable else .not_enumerable;
        }
        if (self.mappedArgumentsBindingIndexFromAtom(rt, atom_id) != null) return .enumerable;
        // Dense array elements are always enumerable (data, w/e/c).
        if (self.denseArrayElement(atom_id) != null) return .enumerable;
        // Key vanished between key enumeration and now: QuickJS's
        // JS_GetOwnPropertyInternal returns 0 here and the copy `continue`s.
        return .not_enumerable;
    }

    pub fn hasOwnProperty(self: *const Object, atom_id: atom.Atom) bool {
        return self.findProperty(atom_id) != null or
            self.denseArrayElement(atom_id) != null or
            self.mappedArgumentsTaggedBindingIndex(atom_id) != null;
    }

    /// Complete existence-only own-property probe -- the desc==NULL mode of
    /// qjs `JS_GetOwnPropertyInternal` (quickjs.c:8854 else-branch). It walks
    /// the SAME kind cascade as `getOwnProperty` but reports only presence,
    /// performing NO `JS_DupValue` and DELAYING auto-init instantiation
    /// ("nothing to do", quickjs.c:8862). It throws `ReferenceError` for an
    /// uninitialized VARREF / module-namespace binding, matching qjs
    /// quickjs.c:8856-8860. Exotic numeric indices (fast/dense arrays) and
    /// module-namespace bindings are covered here; RegExp lastIndex is an
    /// ordinary first shape property.
    /// the typed-array canonical-index existence and the proxy trap live in
    /// the `proxyAware` wrapper, parallel to `getOwnProperty` vs
    /// `proxyAwareOwnPropertyDescriptor`.
    pub fn existsOwnProperty(self: *const Object, rt: *JSRuntime, atom_id: atom.Atom) !bool {
        // Exotic `get_own_property` hook (quickjs.c:8884-8890). The hook
        // builds a full descriptor; we destroy it immediately, but for the
        // non-test class set this hook is never installed (see
        // `exoticMethodsForClassId`) so the cost is paid only by the exotic
        // classes that genuinely need it -- still no dup leaks past us.
        if (self.exoticMethods(rt)) |methods| {
            if (methods.get_own_property) |hook| {
                if (hook(@constCast(self), atom_id)) |desc| {
                    desc.destroy(rt);
                    return true;
                }
            }
        }
        // Module-namespace binding (quickjs.c:8856-8860 VARREF existence
        // path). Presence with NO dup; TDZ raises ReferenceError.
        switch (self.moduleNamespaceBindingExists(atom_id)) {
            .present => return true,
            .uninitialized => return error.ReferenceError,
            .absent => {},
        }
        if (self.isArray() and atom_id == atom.ids.length) return true;
        if (self.findProperty(atom_id)) |index| {
            const entry = self.prop_values[index];
            if (self.propFlagsAt(index).deleted) return false;
            // VARREF existence path (quickjs.c:8856-8860): an uninitialized
            // cell still throws ReferenceError even though desc==NULL.
            if (self.propKindAt(index) == .var_ref) {
                if (entry.slot.var_ref.varRefValue().isUninitialized()) return error.ReferenceError;
            }
            // AUTOINIT: qjs "nothing to do" (quickjs.c:8862) -- report
            // presence WITHOUT materializing the placeholder.
            return true;
        }
        if (self.denseArrayElement(atom_id) != null) return true;
        if (self.mappedArgumentsBindingIndexFromAtom(rt, atom_id) != null) return true;
        return false;
    }

    /// Read just the enumerable bit of an own property, mirroring the
    /// `prs->flags & JS_PROP_ENUMERABLE` inline test in qjs's
    /// `JS_GetOwnPropertyNamesInternal` ENUM_ONLY shape walk
    /// (quickjs.c:8628). Returns `null` when the key is absent. This
    /// reads the flag straight off the shape without materializing a
    /// `Descriptor` (no value dup, no getter), which is what lets
    /// `Object.assign` collapse to a single ENUM_ONLY pass for ordinary
    /// objects. Only valid for non-proxy/non-exotic sources; proxy/exotic
    /// sources keep the descriptor path (qjs clears ENUM_ONLY there).
    pub fn ownPropertyEnumerable(self: *const Object, atom_id: atom.Atom) ?bool {
        // Synthetic Array length carries no JS_PROP_ENUMERABLE flag. RegExp
        // lastIndex is an ordinary shape entry, matching QuickJS.
        if (self.isArray() and atom_id == atom.ids.length) return false;
        if (self.findProperty(atom_id)) |index| {
            return self.propFlagsAt(index).enumerable;
        }
        // Dense array index elements are enumerable data properties in
        // qjs's fast_array (the GPN walk includes them unconditionally
        // under ENUM_ONLY).
        if (self.denseArrayElement(atom_id) != null) return true;
        if (self.mappedArgumentsTaggedBindingIndex(atom_id) != null) return true;
        return null;
    }

    pub fn hasProperty(self: *const Object, atom_id: atom.Atom) bool {
        profile.recordPropLookup(self.isGlobal());
        if (self.hasOwnProperty(atom_id)) return true;
        if (self.getPrototype()) |proto| return proto.hasProperty(atom_id);
        return false;
    }

    pub fn getProperty(self: *const Object, atom_id: atom.Atom) JSValue {
        profile.recordPropLookup(self.isGlobal());
        if (self.moduleNamespaceBindingValue(atom_id)) |stored| return stored;
        if (self.isArray() and atom_id == atom.ids.length) return arrayLengthValue(self.arrayLength());
        if (self.mappedArgumentsTaggedBindingIndex(atom_id)) |mapped_index| {
            if (self.mappedArgumentsBindingValue(mapped_index)) |mapped| return mapped;
        }
        if (self.findProperty(atom_id)) |index| {
            const entry = self.prop_values[index];
            return switch (self.propKindAt(index)) {
                .data => entry.slot.data.dup(),
                .accessor => entry.slot.accessor.getterValue().dup(),
                // First-access materialization for `auto_init`
                // placeholders. We need to mutate `self.prop_values[index]`
                // to replace the placeholder with the real value;
                // `self` is `Object` (by value) here -- the same
                // 300+-callsite shape as the rest of `getProperty`.
                // The slice header is a copy but the underlying entries
                // live on the heap and are shared, so `@constCast`
                // gives us a writable handle without changing every
                // caller. Matches QuickJS's `JS_AutoInitProperty` which
                // also mutates the property record in place on read.
                .auto_init => materializeAutoInit(@constCast(self), index, property.autoInit(entry.slot.auto_init).*),
                // JS_PROP_VARREF: auto-deref the cell (qjs JS_GetPropertyInternal
                // 8281-8285). TDZ (uninitialized) is surfaced to the caller; the
                // dedicated getVar path does the ReferenceError throw.
                .var_ref => entry.slot.var_ref.varRefValue().dup(),
            };
        }
        if (self.denseArrayElement(atom_id)) |stored| return stored.dup();
        if (self.getPrototype()) |proto| return proto.getProperty(atom_id);
        return JSValue.undefinedValue();
    }

    /// First-access materialization for an `auto_init` placeholder.
    /// Builds the underlying value once, promotes the slot from `auto_init`
    /// to `data` or `accessor`, and returns a fresh ref for the caller.
    ///
    /// The slot now owns one ref; the caller receives another via
    /// `.dup()`. On builder failure we fall back to `undefined` to
    /// keep `getProperty` infallible, mirroring the rest of the
    /// non-throwing read path. (The only failure mode is `OutOfMemory`
    /// from the function-object alloc, which would already be lethal
    /// to the running script anyway.)
    fn materializeAutoInit(self: *Object, index: usize, info: property.AutoInit) JSValue {
        if (info.kind == .function_prototype) {
            const materialized = self.materializeFunctionPrototypeAutoInit(info) orelse return JSValue.undefinedValue();
            return self.finishMaterializedAutoInit(index, info, materialized);
        }
        if (info.kind == .console) {
            const materialized = materializeConsoleAutoInit(info) orelse return JSValue.undefinedValue();
            return self.finishMaterializedAutoInit(index, info, materialized);
        }
        if (info.kind == .math_namespace or
            info.kind == .json_namespace or
            info.kind == .reflect_namespace or
            info.kind == .atomics_namespace)
        {
            const materialized = materializeBuiltinNamespaceAutoInit(info) orelse return JSValue.undefinedValue();
            return self.finishMaterializedAutoInit(index, info, materialized);
        }
        if (info.kind == .navigator) {
            const materialized = materializeNavigatorAutoInit(info) orelse return JSValue.undefinedValue();
            return self.finishMaterializedAutoInit(index, info, materialized);
        }
        if (info.kind == .performance) {
            const materialized = materializePerformanceAutoInit(info) orelse return JSValue.undefinedValue();
            return self.finishMaterializedAutoInit(index, info, materialized);
        }

        if (info.kind == .array_unscopables) {
            const materialized = materializeArrayUnscopablesAutoInit(info) orelse return JSValue.undefinedValue();
            return self.finishMaterializedAutoInit(index, info, materialized);
        }
        if (info.kind == .number_constant) {
            const materialized = materializeNumberConstantAutoInit(info) orelse return JSValue.undefinedValue();
            return self.finishMaterializedAutoInit(index, info, materialized);
        }
        if (info.kind == .int32_constant) {
            const materialized = JSValue.int32(info.length);
            return self.finishMaterializedAutoInit(index, info, materialized);
        }
        if (info.kind == .string_constant) {
            const materialized = materializeStringConstantAutoInit(info) orelse return JSValue.undefinedValue();
            return self.finishMaterializedAutoInit(index, info, materialized);
        }
        if (info.kind == .empty_array) {
            const materialized = materializeEmptyArrayAutoInit(info) orelse return JSValue.undefinedValue();
            return self.finishMaterializedAutoInit(index, info, materialized);
        }
        if (info.kind == .native_accessor) {
            const materialized = self.materializeNativeAccessorAutoInit(info) orelse return JSValue.undefinedValue();
            return self.finishMaterializedAccessorAutoInit(index, info, materialized);
        }
        if (info.host_function_kind != 0) {
            const materialized = materializeHostFunctionAutoInit(info) orelse return JSValue.undefinedValue();
            return self.finishMaterializedAutoInit(index, info, materialized);
        }
        const cache_slot = sharedLazyNativeFunctionSlotForAutoInit(info);
        if (cache_slot) |slot| {
            if (slot.*) |cached| {
                if (!self.prepareAutoInitNativeFunction(info, cached, info.native_builtin_id, true)) {
                    return JSValue.undefinedValue();
                }
                const cached_value = cached.dup();
                if (!self.installMaterializedAutoInit(info.rt, index, cached_value)) {
                    cached_value.free(info.rt);
                    return JSValue.undefinedValue();
                }
                return cached_value.dup();
            }
        }
        const materialized = self.materializeNativeFunctionAutoInit(info) orelse return JSValue.undefinedValue();
        if (cache_slot) |slot| {
            self.setOptionalValueSlot(info.rt, slot, materialized.dup()) catch {
                materialized.free(info.rt);
                return JSValue.undefinedValue();
            };
        }
        // Promote the placeholder to a real data slot. Flags stay the
        // same (writable / enumerable / configurable came from the
        // descriptor used when the placeholder was installed).
        return self.finishMaterializedAutoInit(index, info, materialized);
    }

    fn finishMaterializedAutoInit(self: *Object, index: usize, info: property.AutoInit, materialized: JSValue) JSValue {
        if (!self.installMaterializedAutoInit(info.rt, index, materialized)) {
            materialized.free(info.rt);
            return JSValue.undefinedValue();
        }
        return materialized.dup();
    }

    fn finishMaterializedAccessorAutoInit(self: *Object, index: usize, info: property.AutoInit, materialized: property.Accessor) JSValue {
        if (!self.installMaterializedAccessorAutoInit(info.rt, index, materialized)) {
            materialized.destroy(info.rt);
            return JSValue.undefinedValue();
        }
        return materialized.getterValue().dup();
    }

    /// Promote an auto_init placeholder to a real `.data` slot AND flip the
    /// shape `Flags.kind` from `.auto_init` to `.data` in lockstep. The shape
    /// is made unique first so a placeholder shared by several objects is not
    /// corrupted. Returns false (without installing) if the shape clone OOMs;
    /// the caller then falls back to `undefined` and leaves the placeholder
    /// intact for a later retry. Mirrors qjs `JS_AutoInitProperty` clearing the
    /// `JS_PROP_TMASK` to NORMAL on materialization.
    fn installMaterializedAutoInit(self: *Object, rt: *JSRuntime, index: usize, materialized: JSValue) bool {
        const new_flags = self.propFlagsAt(index).withKind(.data);
        self.ensureUniqueShapeForMutation(rt) catch return false;
        self.prop_values[index].slot = .{ .data = materialized };
        rt.shapes.updatePropertyFlags(self.shape_ref, index, new_flags.bits());
        return true;
    }

    fn installMaterializedAccessorAutoInit(self: *Object, rt: *JSRuntime, index: usize, materialized: property.Accessor) bool {
        const new_flags = self.propFlagsAt(index).withKind(.accessor);
        self.ensureUniqueShapeForMutation(rt) catch return false;
        self.prop_values[index].slot = .{ .accessor = materialized };
        rt.shapes.updatePropertyFlags(self.shape_ref, index, new_flags.bits());
        return true;
    }

    fn materializeAutoInitEntryForMutation(self: *Object, index: usize) !void {
        if (index >= self.shape_ref.prop_count) return error.IncompatibleDescriptor;
        if (!self.isAutoInitAt(index)) return;
        const info = property.autoInit(self.prop_values[index].slot.auto_init).*;
        const transient = materializeAutoInit(self, index, info);
        transient.free(info.rt);
        if (self.isAutoInitAt(index)) return error.OutOfMemory;
    }

    /// True if the own property at `index` is an accessor — either a
    /// materialized accessor, or an auto_init placeholder destined to
    /// materialize into one (`info.kind == .native_accessor`). Lets the
    /// set/define paths preserve lazy materialization for data placeholders
    /// while still forcing accessor placeholders through their accessor branch.
    fn isAccessorOrAccessorPlaceholderAt(self: *const Object, index: usize) bool {
        const flags = self.propFlagsAt(index);
        if (flags.deleted) return false;
        if (flags.kind == .accessor) return true;
        if (flags.kind == .auto_init) {
            return property.autoInit(self.prop_values[index].slot.auto_init).kind == .native_accessor;
        }
        return false;
    }

    fn materializeNumberConstantAutoInit(info: property.AutoInit) ?JSValue {
        if (std.mem.eql(u8, info.name, "NaN")) return JSValue.number(std.math.nan(f64));
        if (std.mem.eql(u8, info.name, "POSITIVE_INFINITY")) return JSValue.number(std.math.inf(f64));
        if (std.mem.eql(u8, info.name, "NEGATIVE_INFINITY")) return JSValue.number(-std.math.inf(f64));
        if (std.mem.eql(u8, info.name, "MAX_VALUE")) return JSValue.number(std.math.floatMax(f64));
        if (std.mem.eql(u8, info.name, "MIN_VALUE")) return JSValue.number(@as(f64, @bitCast(@as(u64, 1))));
        if (std.mem.eql(u8, info.name, "MAX_SAFE_INTEGER")) return JSValue.number(9007199254740991.0);
        if (std.mem.eql(u8, info.name, "MIN_SAFE_INTEGER")) return JSValue.number(-9007199254740991.0);
        if (std.mem.eql(u8, info.name, "EPSILON")) return JSValue.number(2.220446049250313e-16);
        return null;
    }

    fn materializeStringConstantAutoInit(info: property.AutoInit) ?JSValue {
        if (info.name.len == 0) {
            const cached = info.rt.emptyString() catch return null;
            return cached.value().dup();
        }
        const created = string.String.createAscii(info.rt, info.name) catch return null;
        return created.value();
    }

    fn materializeEmptyArrayAutoInit(info: property.AutoInit) ?JSValue {
        const global: *Object = if (info.host_function_realm_global != 0)
            @ptrFromInt(info.host_function_realm_global)
        else
            return null;
        const array_proto = arrayPrototypeFromGlobalForAutoInit(info.rt, global);
        const object = Object.createArray(info.rt, array_proto) catch return null;
        return object.value();
    }

    fn functionPrototypeForAutoInit(self: *Object, info: property.AutoInit) ?*Object {
        const realm_global: ?*Object = if (info.host_function_realm_global != 0)
            @ptrFromInt(info.host_function_realm_global)
        else
            self.functionRealmGlobalPtr();
        return if (realm_global) |global| global.cachedFunctionProto() else null;
    }

    fn materializeNativeFunctionAutoInit(self: *Object, info: property.AutoInit) ?JSValue {
        return self.materializeNativeFunctionAutoInitOnce(info) orelse
            self.materializeNativeFunctionAutoInitOnce(info);
    }

    fn materializeNativeFunctionAutoInitOnce(self: *Object, info: property.AutoInit) ?JSValue {
        const materialized = function.nativeFunction(info.rt, info.name, info.length) catch return null;
        if (!self.prepareAutoInitNativeFunction(info, materialized, info.native_builtin_id, true)) {
            materialized.free(info.rt);
            return null;
        }
        return materialized;
    }

    fn materializeNativeAccessorAutoInit(self: *Object, info: property.AutoInit) ?property.Accessor {
        const getter = function.nativeFunction(info.rt, info.name, info.length) catch return null;
        if (!self.prepareAutoInitNativeFunction(info, getter, info.native_builtin_id, true)) {
            getter.free(info.rt);
            return null;
        }
        const setter = if (nativeAccessorAutoInitSetterLength(info)) |setter_length| setter: {
            var setter_name_buf: [128]u8 = undefined;
            const setter_name = nativeAccessorAutoInitSetterName(info.name, &setter_name_buf) orelse {
                getter.free(info.rt);
                return null;
            };
            const setter_value = function.nativeFunction(info.rt, setter_name, setter_length) catch {
                getter.free(info.rt);
                return null;
            };
            const setter_native_id: i32 = @intCast(info.external_host_function_id);
            if (!self.prepareAutoInitNativeFunction(info, setter_value, setter_native_id, true)) {
                getter.free(info.rt);
                setter_value.free(info.rt);
                return null;
            }
            break :setter setter_value;
        } else JSValue.undefinedValue();
        return property.Accessor.fromOwnedValues(getter, setter);
    }

    fn nativeAccessorAutoInitSetterLength(info: property.AutoInit) ?i32 {
        if (info.kind != .native_accessor or info.host_function_kind <= 0) return null;
        return info.host_function_kind;
    }

    fn nativeAccessorAutoInitSetterName(getter_name: []const u8, buffer: []u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, getter_name, "get ")) return null;
        return std.fmt.bufPrint(buffer, "set {s}", .{getter_name["get ".len..]}) catch null;
    }

    fn prepareAutoInitNativeFunction(
        self: *Object,
        info: property.AutoInit,
        function_value: JSValue,
        native_builtin_id: i32,
        apply_markers: bool,
    ) bool {
        if (native_builtin_id != 0) {
            if (function_value.refHeader()) |header| {
                const obj: *Object = @fieldParentPtr("header", header);
                obj.setNativeBuiltinIdAndRecord(info.rt, native_builtin_id);
            }
        }
        if (apply_markers) {
            applyAutoInitArrayBuiltinMarker(info.rt, function_value, info.array_builtin_marker);
            applyAutoInitTypedArrayBuiltinMarker(info.rt, function_value, info.typed_array_builtin_marker);
            applyAutoInitArrayIteratorKind(info.rt, function_value, info.array_iterator_kind);
            applyAutoInitIteratorIdentity(info.rt, function_value, info.iterator_identity);
            applyAutoInitCollectionMethodOwner(info.rt, function_value, info.collection_method_owner_class);
            applyAutoInitDisposableStackMethod(info.rt, function_value, info.disposable_stack_method);
            applyAutoInitAsyncDisposableStackMethod(info.rt, function_value, info.async_disposable_stack_method);
        }
        // Self-wire `[[Prototype]]` to Function.prototype. The lazy
        // install path skips the eager
        // `wireNativeFunctionPropertyPrototypes` pass that would have
        // done this for us, so each materialization sets it here. The
        // cache is populated by `installStandardGlobals` once the
        // Function constructor exists; for very early calls (e.g.
        // materializing an Object.prototype method while Function is
        // still being built) the cache is null and we leave the
        // prototype as the default `null`, matching the behavior of
        // the eager path before constructor-graph wiring.
        if (functionPrototypeForAutoInit(self, info)) |fp| {
            if (function_value.refHeader()) |header| {
                const obj: *Object = @fieldParentPtr("header", header);
                const realm_global: ?*Object = if (info.host_function_realm_global != 0)
                    @ptrFromInt(info.host_function_realm_global)
                else
                    self.functionRealmGlobalPtr();
                if (obj.functionRealmGlobalPtrSlot().* == null) {
                    obj.setFunctionRealmGlobalPtr(info.rt, realm_global) catch return false;
                }
                if (obj != fp and !obj.hasOwnProperty(atom.ids.prototype) and obj.hostFunctionKind() == 0) {
                    obj.setPrototype(info.rt, fp) catch {};
                }
            }
        }
        return true;
    }

    fn sharedLazyNativeFunctionSlotForAutoInit(info: property.AutoInit) ?*?JSValue {
        if (info.shared_native_cache_slot == 0) return null;
        if (info.host_function_realm_global == 0) return null;
        const global: *Object = @ptrFromInt(info.host_function_realm_global);
        global.ensureSharedLazyNativeFunctionCache(info.rt) catch return null;
        return global.sharedLazyNativeFunctionSlot(info.shared_native_cache_slot);
    }

    fn materializeArrayUnscopablesAutoInit(info: property.AutoInit) ?JSValue {
        const rt = info.rt;
        const object = Object.create(rt, class.ids.object, null) catch return null;
        const unscopables_value = object.value();
        // qjs js_array_unscopables (order incl. "at"; spec 23.1.3.41).
        const names = [_][]const u8{
            "at",
            "copyWithin",
            "entries",
            "fill",
            "find",
            "findIndex",
            "findLast",
            "findLastIndex",
            "flat",
            "flatMap",
            "includes",
            "keys",
            "toReversed",
            "toSorted",
            "toSpliced",
            "values",
        };
        for (names) |name| {
            const key = rt.internAtom(name) catch {
                unscopables_value.free(rt);
                return null;
            };
            defer rt.atoms.free(key);
            object.defineOwnPropertyAssumingNew(
                rt,
                key,
                descriptor.Descriptor.data(JSValue.boolean(true), true, true, true),
            ) catch {
                unscopables_value.free(rt);
                return null;
            };
        }
        return unscopables_value;
    }

    fn applyAutoInitArrayBuiltinMarker(rt: *JSRuntime, function_value: JSValue, marker: ArrayBuiltinMarker) void {
        if (marker == .none) return;
        const header = function_value.refHeader() orelse return;
        const function_object: *Object = @fieldParentPtr("header", header);
        _ = function_object.addArrayBuiltinMarker(rt, marker);
    }

    fn applyAutoInitTypedArrayBuiltinMarker(rt: *JSRuntime, function_value: JSValue, marker: TypedArrayBuiltinMarker) void {
        if (marker == .none) return;
        const header = function_value.refHeader() orelse return;
        const function_object: *Object = @fieldParentPtr("header", header);
        _ = function_object.addTypedArrayBuiltinMarker(rt, marker);
    }

    fn applyAutoInitArrayIteratorKind(rt: *JSRuntime, function_value: JSValue, kind: u8) void {
        if (kind == 0) return;
        const header = function_value.refHeader() orelse return;
        const function_object: *Object = @fieldParentPtr("header", header);
        _ = function_object.addArrayIteratorKind(rt, kind);
    }

    fn applyAutoInitIteratorIdentity(rt: *JSRuntime, function_value: JSValue, is_identity: bool) void {
        if (!is_identity) return;
        const header = function_value.refHeader() orelse return;
        const function_object: *Object = @fieldParentPtr("header", header);
        _ = function_object.addIteratorIdentityFunction(rt);
    }

    fn applyAutoInitCollectionMethodOwner(rt: *JSRuntime, function_value: JSValue, owner_class: class.ClassId) void {
        if (owner_class == class.invalid_class_id) return;
        const header = function_value.refHeader() orelse return;
        const function_object: *Object = @fieldParentPtr("header", header);
        _ = function_object.addCollectionMethodOwnerClass(rt, owner_class);
    }

    fn applyAutoInitDisposableStackMethod(rt: *JSRuntime, function_value: JSValue, method_id: u8) void {
        if (method_id == 0) return;
        const header = function_value.refHeader() orelse return;
        const function_object: *Object = @fieldParentPtr("header", header);
        _ = function_object.addDisposableStackMethod(rt, method_id);
    }

    fn applyAutoInitAsyncDisposableStackMethod(rt: *JSRuntime, function_value: JSValue, method_id: u8) void {
        if (method_id == 0) return;
        const header = function_value.refHeader() orelse return;
        const function_object: *Object = @fieldParentPtr("header", header);
        _ = function_object.addAsyncDisposableStackMethod(rt, method_id);
    }

    fn materializeHostFunctionAutoInit(info: property.AutoInit) ?JSValue {
        const rt = info.rt;
        const function_capacity: usize = 2 + if (info.host_function_prototype) @as(usize, 1) else 0;
        const function_object = Object.createWithOwnPropertyCapacity(rt, class.ids.c_function, null, function_capacity) catch return null;
        const function_value = function_object.value();
        function_object.hostFunctionKindSlot().* = info.host_function_kind;
        if (info.external_host_function_id != 0) {
            if (info.host_function_kind != host_function.ids.external_host) {
                function_value.free(rt);
                return null;
            }
            function_object.externalHostFunctionIdSlot().* = info.external_host_function_id;
        }
        if (info.host_function_realm_global != 0) {
            function_object.setFunctionRealmGlobalPtr(rt, @ptrFromInt(info.host_function_realm_global)) catch {
                function_value.free(rt);
                return null;
            };
        }

        const name_string = string.String.createAscii(rt, info.name) catch {
            function_value.free(rt);
            return null;
        };
        const name_value = name_string.value();
        defer name_value.free(rt);
        const name_key = atom.predefinedId("name", .string).?;
        function_object.defineOwnPropertyAssumingNew(rt, name_key, descriptor.Descriptor.data(name_value, true, true, true)) catch {
            function_value.free(rt);
            return null;
        };

        const length_key = atom.predefinedId("length", .string).?;
        function_object.defineOwnPropertyAssumingNew(rt, length_key, descriptor.Descriptor.data(JSValue.int32(info.length), true, true, true)) catch {
            function_value.free(rt);
            return null;
        };

        if (info.host_function_prototype) {
            const prototype = Object.createWithOwnPropertyCapacity(rt, class.ids.object, null, 0) catch {
                function_value.free(rt);
                return null;
            };
            const prototype_value = prototype.value();
            defer prototype_value.free(rt);
            const prototype_key = atom.ids.prototype;
            function_object.defineOwnPropertyAssumingNew(rt, prototype_key, descriptor.Descriptor.data(prototype_value, true, true, true)) catch {
                function_value.free(rt);
                return null;
            };
        }

        return function_value;
    }

    fn materializeBuiltinNamespaceAutoInit(info: property.AutoInit) ?JSValue {
        const global: *Object = if (info.host_function_realm_global != 0)
            @ptrFromInt(info.host_function_realm_global)
        else
            return null;
        const cb = info.rt.materialize_builtin_namespace_cb orelse return null;
        return cb(info.rt, global, info.kind) catch null;
    }

    fn defineHostAutoInitDataPropertyByName(
        rt: *JSRuntime,
        target: *Object,
        name: []const u8,
        length: i32,
        host_function_kind: i32,
        external_host_function_id: u32,
        realm_global: ?*Object,
    ) !void {
        const key = try rt.internAtom(name);
        defer rt.atoms.free(key);
        try target.defineHostAutoInitPropertyWithExternalId(
            rt,
            key,
            name,
            length,
            property.Flags.data(true, true, true),
            host_function_kind,
            false,
            realm_global,
            external_host_function_id,
        );
    }

    fn materializeConsoleAutoInit(info: property.AutoInit) ?JSValue {
        const rt = info.rt;
        if (info.host_function_kind == 0) return null;
        const console = Object.createWithOwnPropertyCapacity(rt, class.ids.object, null, 3) catch return null;
        const console_value = console.value();
        const methods = [_][]const u8{ "log", "warn", "error" };
        for (methods) |name| {
            defineHostAutoInitDataPropertyByName(rt, console, name, 1, info.host_function_kind, info.external_host_function_id, null) catch {
                console_value.free(rt);
                return null;
            };
        }
        return console_value;
    }

    fn materializeNavigatorAutoInit(info: property.AutoInit) ?JSValue {
        const rt = info.rt;
        const global: *Object = if (info.host_function_realm_global != 0)
            @ptrFromInt(info.host_function_realm_global)
        else
            return null;
        const object_proto = objectPrototypeFromGlobalForAutoInit(rt, global);
        const proto = Object.createWithOwnPropertyCapacity(rt, class.ids.object, object_proto, 2) catch return null;
        var proto_owned = true;
        defer if (proto_owned) proto.value().free(rt);

        const tag = string.String.createAscii(rt, "Navigator") catch return null;
        const tag_value = tag.value();
        defer tag_value.free(rt);
        proto.defineOwnPropertyAssumingNew(
            rt,
            atom.predefinedId("Symbol.toStringTag", .symbol).?,
            descriptor.Descriptor.data(tag_value, false, false, true),
        ) catch return null;

        const getter = function.nativeFunction(rt, "get userAgent", 0) catch return null;
        defer getter.free(rt);
        if (getter.refHeader()) |getter_header| {
            const getter_object: *Object = @fieldParentPtr("header", getter_header);
            getter_object.setNativeBuiltinIdAndRecord(rt, function.nativeBuiltinId(.host, @intFromEnum(function.HostGlobalMethod.navigator_user_agent_get)));
        }
        const user_agent = rt.internAtom("userAgent") catch return null;
        defer rt.atoms.free(user_agent);
        proto.defineOwnPropertyAssumingNew(
            rt,
            user_agent,
            descriptor.Descriptor.accessor(getter, JSValue.undefinedValue(), true, true),
        ) catch return null;

        const navigator = Object.createWithOwnPropertyCapacity(rt, class.ids.object, proto, 0) catch return null;
        proto.value().free(rt);
        proto_owned = false;
        return navigator.value();
    }

    fn materializePerformanceAutoInit(info: property.AutoInit) ?JSValue {
        const rt = info.rt;
        const global: *Object = if (info.host_function_realm_global != 0)
            @ptrFromInt(info.host_function_realm_global)
        else
            return null;
        if (rt.performance_time_origin_ms == 0) rt.performance_time_origin_ms = performanceAutoInitNowMs();
        const performance = Object.createWithOwnPropertyCapacity(rt, class.ids.object, objectPrototypeFromGlobalForAutoInit(rt, global), 2) catch return null;
        const performance_value = performance.value();

        const now_key = atom.predefinedId("now", .string).?;
        const method_flags = property.Flags.data(true, false, true);
        performance.defineAutoInitPropertyWithRealmAndNative(
            rt,
            now_key,
            "now",
            0,
            method_flags,
            null,
            function.nativeBuiltinId(.performance, 1),
        ) catch {
            performance_value.free(rt);
            return null;
        };

        const origin_key = atom.predefinedId("timeOrigin", .string).?;
        performance.defineOwnPropertyAssumingNew(
            rt,
            origin_key,
            descriptor.Descriptor.data(JSValue.float64(rt.performance_time_origin_ms), true, true, true),
        ) catch {
            performance_value.free(rt);
            return null;
        };

        return performance_value;
    }

    fn performanceAutoInitNowMs() f64 {
        const io = std.Io.Threaded.global_single_threaded.io();
        const ns = std.Io.Clock.Timestamp.now(io, .awake).raw.toNanoseconds();
        return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
    }

    fn objectPrototypeFromGlobalForAutoInit(rt: *JSRuntime, global: *Object) ?*Object {
        if (global.cachedRealmValue(.object_prototype)) |stored| {
            if (objectFromValue(stored)) |prototype| return prototype;
        }
        const object_ctor_value = global.getProperty(atom.predefinedId("Object", .string).?);
        defer object_ctor_value.free(rt);
        if (!object_ctor_value.isObject()) return null;
        const prototype_value = objectFromValue(object_ctor_value).?.getProperty(atom.ids.prototype);
        defer prototype_value.free(rt);
        return objectFromValue(prototype_value);
    }

    /// Materialize a lazy `function.prototype` placeholder (qjs
    /// `js_instantiate_prototype`, quickjs.c:17341). `self` is the owner
    /// function object; the prototype's [[Prototype]] is the function's realm
    /// `Object.prototype`, and `constructor` points back at `self`
    /// (writable, non-enumerable, configurable) — installed only here, so the
    /// `func <-> prototype.constructor` cycle forms lazily, never for a
    /// function whose `.prototype` is never observed.
    fn materializeFunctionPrototypeAutoInit(self: *Object, info: property.AutoInit) ?JSValue {
        const rt = info.rt;
        const parent: ?*Object = if (self.functionRealmGlobalPtr()) |realm_global|
            objectPrototypeFromGlobalForAutoInit(rt, realm_global)
        else
            null;
        const prototype = Object.create(rt, class.ids.object, parent) catch return null;
        var prototype_owned = true;
        errdefer if (prototype_owned) Object.destroyFromHeader(rt, &prototype.header);
        prototype.defineOwnProperty(rt, atom.ids.constructor, descriptor.Descriptor.data(self.value(), true, false, true)) catch return null;
        prototype_owned = false;
        return prototype.value();
    }

    /// Install the lazy `function.prototype` auto-init placeholder on a freshly
    /// created function object. Shares the single interned descriptor so the
    /// `auto_init_table` does not grow per function.
    pub fn defineFunctionPrototypeAutoInit(self: *Object, rt: *JSRuntime, flags: property.Flags) !void {
        const ref = try rt.functionPrototypeAutoInitRef();
        try self.appendPreparedPropertyEntry(rt, atom.ids.prototype, flags.withKind(.auto_init), .{ .auto_init = ref });
    }

    fn arrayPrototypeFromGlobalForAutoInit(rt: *JSRuntime, global: *Object) ?*Object {
        if (global.cachedRealmValue(.array_prototype)) |stored| {
            if (objectFromValue(stored)) |prototype| return prototype;
        }
        const array_key = atom.predefinedId("Array", .string) orelse return null;
        const array_ctor_value = global.getProperty(array_key);
        defer array_ctor_value.free(rt);
        if (!array_ctor_value.isObject()) return null;
        const prototype_value = objectFromValue(array_ctor_value).?.getProperty(atom.ids.prototype);
        defer prototype_value.free(rt);
        return objectFromValue(prototype_value);
    }

    pub fn getOwnDataPropertyValue(self: *const Object, atom_id: atom.Atom) ?JSValue {
        if (self.getOwnDataPropertyLookup(atom_id)) |lookup| return lookup.value;
        return null;
    }

    pub fn getOwnDataObjectBorrowed(self: *const Object, atom_id: atom.Atom) ?*Object {
        if (self.hasExoticMethods()) return null;
        if (self.findProperty(atom_id)) |index| {
            const stored = self.asDataAt(index) orelse return null;
            return objectFromValue(stored);
        }
        return null;
    }

    pub fn getOwnDataPropertyLookup(self: *const Object, atom_id: atom.Atom) ?DataPropertyLookup {
        if (self.hasExoticMethods()) return null;
        if (self.findProperty(atom_id)) |index| {
            const stored = self.asDataAt(index) orelse return null;
            return .{ .index = index, .value = stored.dup() };
        }
        return null;
    }

    pub fn getOwnDataPropertyValueAt(self: *const Object, index: usize, atom_id: atom.Atom) ?JSValue {
        if (self.hasExoticMethods() or index >= self.shapeProps().len) return null;
        const prop = self.shape_ref.props()[index];
        const prop_flags = property.Flags.fromBits(prop.flags);
        if (prop.atom_id != atom_id or prop_flags.deleted or prop_flags.kind != .data) return null;
        return self.prop_values[index].slot.data.dup();
    }

    pub fn getDenseArrayElementValue(self: *const Object, index: u32) ?JSValue {
        return self.fastArrayElementDup(index);
    }

    pub fn defineOwnProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void {
        if (self.exoticMethods(rt)) |methods| {
            if (methods.define_own_property) |hook| {
                if (!hook(self, atom_id, desc)) return error.IncompatibleDescriptor;
                return;
            }
        }
        if (try self.defineModuleNamespaceProperty(rt, atom_id, desc)) return;
        var actual_desc = desc;
        const destroy_actual_desc = try self.prepareMappedArgumentsDescriptorForDefine(rt, atom_id, &actual_desc);
        defer if (destroy_actual_desc) actual_desc.destroy(rt);

        if (self.isArray() and atom_id == atom.ids.length) {
            try self.defineArrayLength(rt, actual_desc);
            return;
        }

        if (self.isArray()) {
            if (array.arrayIndexFromAtom(&rt.atoms, atom_id)) |index| {
                if (index >= self.arrayLength() and !self.flags.length_writable) return error.ReadOnly;
                const old_length = self.arrayLength();
                if (self.flags.fast_array) try self.convertDenseArrayElementsToSparseProperties(rt);
                try self.defineOrdinaryOwnProperty(rt, atom_id, actual_desc);
                if (index >= old_length) self.setArrayLength(index + 1);
                self.updateArrayStorageMode(index);
                return;
            }
        }

        try self.defineOrdinaryOwnProperty(rt, atom_id, actual_desc);
        try self.updateMappedArgumentsBinding(rt, atom_id, actual_desc);
    }

    /// Fast-path property define for builtins setup, callable when the
    /// caller can guarantee the property is brand-new on the object and
    /// the object is a plain (non-exotic, non-array,
    /// non-mapped-arguments) ordinary object. Skips the
    /// `findProperty` linear scan (O(n) per insert -> O(n^2) over
    /// `installStandardGlobals`) and the array / regexp / arguments
    /// preludes of `defineOwnProperty`. Hot during global-object setup
    /// where ~700 native functions and ~50 namespace properties are
    /// installed per fresh global; converts the per-call cost from
    /// O(existing-property-count) to O(1).
    ///
    /// Caller must ensure: object is plain (no exotic methods, not an
    /// array, not mapped-arguments) and the
    /// property does not already exist on the object. Cheap structural
    /// checks are asserted; the no-duplicate precondition is the
    /// caller's responsibility to keep this fast (asserting it would
    /// reintroduce the O(n) scan we are trying to avoid).
    pub fn defineOwnPropertyAssumingNew(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void {
        std.debug.assert(!self.hasExoticMethods());
        std.debug.assert(self.supportsPlainNamedPropertyStorage());
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.flags.extensible);
        try self.addProperty(rt, atom_id, desc);
    }

    /// Fast-path property define for freshly-created ordinary objects or
    /// arrays when the caller can guarantee the key is brand-new and is not
    /// an array index / `length`. This keeps array length and indexed storage
    /// semantics out of the path for fixed metadata properties such as RegExp
    /// match-array `index`, `input`, and `groups`.
    pub fn defineOwnNonIndexPropertyAssumingNew(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void {
        std.debug.assert(!self.hasExoticMethods());
        std.debug.assert(!(self.isArray() and atom_id == atom.ids.length));
        std.debug.assert(array.arrayIndexFromAtom(&rt.atoms, atom_id) == null);
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.flags.extensible);
        try self.addProperty(rt, atom_id, desc);
    }

    pub fn defineRegExpMatchMetadataPropertiesAssumingNew(self: *Object, rt: *JSRuntime, match_index: i32, input_value: JSValue, groups_value: JSValue) !void {
        std.debug.assert(!self.hasExoticMethods());
        std.debug.assert(self.isArray());
        std.debug.assert(self.flags.extensible);

        const index_atom = comptime atom.predefinedId("index", .string).?;
        const input_atom = comptime atom.predefinedId("input", .string).?;
        const groups_atom = comptime atom.predefinedId("groups", .string).?;
        const enumerable_flags = property.Flags.data(true, true, true);
        try self.appendPreparedPropertyEntry(rt, index_atom, enumerable_flags, .{ .data = JSValue.int32(match_index) });
        try self.appendPreparedPropertyEntry(rt, input_atom, enumerable_flags, .{ .data = input_value.dup() });
        try self.appendPreparedPropertyEntry(rt, groups_atom, enumerable_flags, .{ .data = groups_value.dup() });
    }

    pub fn defineJsonParseDataProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, new_value: JSValue) !void {
        std.debug.assert(!self.hasExoticMethods());
        std.debug.assert(self.supportsPlainNamedPropertyStorage());
        std.debug.assert(self.class_id == class.ids.object);
        std.debug.assert(self.flags.extensible);

        if (self.findProperty(atom_id)) |index| {
            try self.ensureUniqueShapeForMutation(rt);
            const old_flags = self.propFlagsAt(index);
            const entry = &self.prop_values[index];
            const next_value = dupPropertyDataValue(&rt.atoms, atom_id, new_value);
            errdefer next_value.free(rt);
            const old_slot = entry.slot;
            entry.slot = .{ .data = next_value };
            rt.shapes.updatePropertyFlags(self.shape_ref, index, property.Flags.data(true, true, true).bits());
            destroyPropertySlot(rt, atom_id, old_flags, old_slot);
            self.pruneBorrowedReferenceHolderIfEmpty(rt);
            return;
        }

        try self.addProperty(rt, atom_id, descriptor.Descriptor.data(new_value, true, true, true));
    }

    pub fn reserveOwnPropertyCapacityAssumingPlain(self: *Object, rt: *JSRuntime, needed: usize) !void {
        std.debug.assert(!self.hasExoticMethods());
        // %Array.prototype% is a real JS_CLASS_ARRAY in qjs, but remains
        // non-dense while its intrinsic methods are installed.
        std.debug.assert(self.supportsPlainNamedPropertyStorage());
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.flags.extensible);
        if (needed <= self.propertyStorageCapacity() and rt.shapes.hasReservedOwnPropertyCapacity(self.shape_ref, needed)) return;
        // Bulk install paths build fresh ordinary objects. Once capacity is
        // reserved, keep their shapes unique and append in place instead of
        // creating a transition node per property.
        try self.ensureUniqueShapeForMutation(rt);
        try self.ensurePropertyCapacity(rt, needed);
        try rt.shapes.reservePropertyHash(&self.shape_ref, needed);
    }

    /// Install a placeholder property whose backing value is computed
    /// lazily the first time the property is read (mirrors QuickJS's
    /// `JS_DefineAutoInitProperty` + `JS_AUTOINIT_ID_PROP`). Used by
    /// `installStandardGlobals` to skip eagerly constructing ~700
    /// native function objects per fresh global; the function object
    /// is built only if some script actually observes the property
    /// (e.g. `Array.prototype.indexOf`).
    ///
    /// `name` is a static string slice (built-in method name) -- the
    /// placeholder borrows it without copying. `length` is the
    /// function's reported arity. The standard `flags` for method
    /// installs (writable/configurable, non-enumerable) follow the
    /// caller's `flags` argument, just like the eager path.
    ///
    /// Same plain-object preconditions as `defineOwnPropertyAssumingNew`;
    /// no-duplicate precondition is the caller's responsibility.
    pub fn defineAutoInitProperty(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        name: []const u8,
        length: i32,
        flags: property.Flags,
    ) !void {
        try self.defineAutoInitPropertyWithRealm(rt, atom_id, name, length, flags, null);
    }

    pub fn defineAutoInitPropertyWithRealm(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        name: []const u8,
        length: i32,
        flags: property.Flags,
        realm_global: ?*Object,
    ) !void {
        try self.defineAutoInitPropertyWithRealmAndNative(rt, atom_id, name, length, flags, realm_global, 0);
    }

    pub fn defineAutoInitPropertyWithRealmAndNative(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        name: []const u8,
        length: i32,
        flags: property.Flags,
        realm_global: ?*Object,
        native_builtin_id: i32,
    ) !void {
        try self.defineAutoInitPropertyWithRealmNativeAndCache(rt, atom_id, name, length, flags, realm_global, native_builtin_id, 0);
    }

    pub fn defineAutoInitPropertyWithRealmNativeAndCache(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        name: []const u8,
        length: i32,
        flags: property.Flags,
        realm_global: ?*Object,
        native_builtin_id: i32,
        shared_native_cache_slot: u8,
    ) !void {
        std.debug.assert(!self.hasExoticMethods());
        std.debug.assert(self.supportsPlainNamedPropertyStorage());
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.flags.extensible);
        const inserted_holder = if (realm_global != null)
            try registerBorrowedHolderForPendingMutation(rt, self)
        else
            false;
        errdefer rollbackBorrowedHolderRegistration(rt, self, inserted_holder);
        // Inlined to skip `entryFromDescriptor`'s value-dup / accessor-
        // dup work: the placeholder has no JSValue to retain, just the
        // (name, length, rt) triple stored in the runtime auto-init table.
        // The atom is still retained the same way `addProperty` would, via
        // `rt.shapes.addProperty` -> `atoms.dup`.
        try self.appendPreparedPropertyEntry(rt, atom_id, flags.withKind(.auto_init), .{ .auto_init = try property.internAutoInit(rt, .{
            .name = name,
            .length = length,
            .rt = rt,
            .host_function_realm_global = if (realm_global) |realm| @intFromPtr(realm) else 0,
            .native_builtin_id = native_builtin_id,
            .shared_native_cache_slot = shared_native_cache_slot,
        }) });
        if (realm_global != null) try rt.registerBorrowedReferenceHolder(self);
    }

    pub fn defineAutoInitNonIndexPropertyWithRealmNativeAndCache(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        name: []const u8,
        length: i32,
        flags: property.Flags,
        realm_global: ?*Object,
        native_builtin_id: i32,
        shared_native_cache_slot: u8,
    ) !void {
        std.debug.assert(!self.hasExoticMethods());
        std.debug.assert(!(self.isArray() and atom_id == atom.ids.length));
        std.debug.assert(array.arrayIndexFromAtom(&rt.atoms, atom_id) == null);
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.flags.extensible);
        const inserted_holder = if (realm_global != null)
            try registerBorrowedHolderForPendingMutation(rt, self)
        else
            false;
        errdefer rollbackBorrowedHolderRegistration(rt, self, inserted_holder);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags.withKind(.auto_init), .{ .auto_init = try property.internAutoInit(rt, .{
            .name = name,
            .length = length,
            .rt = rt,
            .host_function_realm_global = if (realm_global) |realm| @intFromPtr(realm) else 0,
            .native_builtin_id = native_builtin_id,
            .shared_native_cache_slot = shared_native_cache_slot,
        }) });
        if (realm_global != null) try rt.registerBorrowedReferenceHolder(self);
    }

    pub fn defineNativeAccessorAutoInitPropertyWithRealmAndNative(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        getter_name: []const u8,
        getter_length: i32,
        flags: property.Flags,
        realm_global: ?*Object,
        getter_native_builtin_id: i32,
    ) !void {
        std.debug.assert(flags.isAccessor());
        std.debug.assert(!self.hasExoticMethods());
        std.debug.assert(self.supportsPlainNamedPropertyStorage());
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.flags.extensible);
        const inserted_holder = if (realm_global != null)
            try registerBorrowedHolderForPendingMutation(rt, self)
        else
            false;
        errdefer rollbackBorrowedHolderRegistration(rt, self, inserted_holder);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags.withKind(.auto_init), .{ .auto_init = try property.internAutoInit(rt, .{
            .name = getter_name,
            .length = getter_length,
            .rt = rt,
            .kind = .native_accessor,
            .host_function_realm_global = if (realm_global) |realm| @intFromPtr(realm) else 0,
            .native_builtin_id = getter_native_builtin_id,
        }) });
        if (realm_global != null) try rt.registerBorrowedReferenceHolder(self);
    }

    pub fn defineNativeAccessorAutoInitPairPropertyWithRealmAndNative(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        getter_name: []const u8,
        getter_length: i32,
        setter_length: i32,
        flags: property.Flags,
        realm_global: ?*Object,
        getter_native_builtin_id: i32,
        setter_native_builtin_id: i32,
    ) !void {
        std.debug.assert(flags.isAccessor());
        std.debug.assert(setter_length > 0);
        std.debug.assert(setter_native_builtin_id >= 0);
        std.debug.assert(!self.hasExoticMethods());
        std.debug.assert(self.supportsPlainNamedPropertyStorage());
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.flags.extensible);
        const inserted_holder = if (realm_global != null)
            try registerBorrowedHolderForPendingMutation(rt, self)
        else
            false;
        errdefer rollbackBorrowedHolderRegistration(rt, self, inserted_holder);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags.withKind(.auto_init), .{ .auto_init = try property.internAutoInit(rt, .{
            .name = getter_name,
            .length = getter_length,
            .rt = rt,
            .kind = .native_accessor,
            .host_function_kind = setter_length,
            .external_host_function_id = @intCast(setter_native_builtin_id),
            .host_function_realm_global = if (realm_global) |realm| @intFromPtr(realm) else 0,
            .native_builtin_id = getter_native_builtin_id,
        }) });
        if (realm_global != null) try rt.registerBorrowedReferenceHolder(self);
    }

    pub fn replaceAutoInitPropertyWithRealmNativeAndCache(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        name: []const u8,
        length: i32,
        flags: property.Flags,
        realm_global: ?*Object,
        native_builtin_id: i32,
        shared_native_cache_slot: u8,
    ) !void {
        const inserted_holder = if (realm_global != null)
            try registerBorrowedHolderForPendingMutation(rt, self)
        else
            false;
        errdefer rollbackBorrowedHolderRegistration(rt, self, inserted_holder);
        if (self.findProperty(atom_id)) |index| {
            if (!self.isAutoInitAt(index)) return error.TypeError;
            const ai_flags = flags.withKind(.auto_init);
            if (self.propFlagsAt(index).bits() != ai_flags.bits()) {
                try self.ensureUniqueShapeForMutation(rt);
                rt.shapes.updatePropertyFlags(self.shape_ref, index, ai_flags.bits());
            }
            self.prop_values[index].slot = .{ .auto_init = try property.internAutoInit(rt, .{
                .name = name,
                .length = length,
                .rt = rt,
                .host_function_realm_global = if (realm_global) |realm| @intFromPtr(realm) else 0,
                .native_builtin_id = native_builtin_id,
                .shared_native_cache_slot = shared_native_cache_slot,
            }) };
            self.pruneBorrowedReferenceHolderIfEmpty(rt);
            if (realm_global != null) try rt.registerBorrowedReferenceHolder(self);
            return;
        }
        try self.defineAutoInitPropertyWithRealmNativeAndCache(rt, atom_id, name, length, flags, realm_global, native_builtin_id, shared_native_cache_slot);
    }

    pub fn defineNavigatorAutoInitProperty(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        flags: property.Flags,
        realm_global: *Object,
    ) !void {
        std.debug.assert(!self.hasExoticMethods());
        std.debug.assert(self.supportsPlainNamedPropertyStorage());
        std.debug.assert(self.flags.extensible);
        const inserted_holder = try registerBorrowedHolderForPendingMutation(rt, self);
        errdefer rollbackBorrowedHolderRegistration(rt, self, inserted_holder);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags.withKind(.auto_init), .{ .auto_init = try property.internAutoInit(rt, .{
            .name = "navigator",
            .length = 0,
            .rt = rt,
            .kind = .navigator,
            .host_function_realm_global = @intFromPtr(realm_global),
        }) });
        try rt.registerBorrowedReferenceHolder(self);
    }

    pub fn defineConsoleAutoInitProperty(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        flags: property.Flags,
        host_function_kind: i32,
        external_host_function_id: u32,
    ) !void {
        std.debug.assert(host_function_kind != 0);
        std.debug.assert(external_host_function_id == 0 or host_function_kind == host_function.ids.external_host);
        std.debug.assert(!self.hasExoticMethods());
        std.debug.assert(self.supportsPlainNamedPropertyStorage());
        std.debug.assert(self.flags.extensible);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags.withKind(.auto_init), .{ .auto_init = try property.internAutoInit(rt, .{
            .name = "console",
            .length = 0,
            .rt = rt,
            .kind = .console,
            .host_function_kind = host_function_kind,
            .external_host_function_id = external_host_function_id,
        }) });
    }

    pub fn definePerformanceAutoInitProperty(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        flags: property.Flags,
        realm_global: *Object,
    ) !void {
        std.debug.assert(!self.hasExoticMethods());
        std.debug.assert(self.supportsPlainNamedPropertyStorage());
        std.debug.assert(self.flags.extensible);
        const inserted_holder = try registerBorrowedHolderForPendingMutation(rt, self);
        errdefer rollbackBorrowedHolderRegistration(rt, self, inserted_holder);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags.withKind(.auto_init), .{ .auto_init = try property.internAutoInit(rt, .{
            .name = "performance",
            .length = 0,
            .rt = rt,
            .kind = .performance,
            .host_function_realm_global = @intFromPtr(realm_global),
        }) });
        try rt.registerBorrowedReferenceHolder(self);
    }

    pub fn defineBuiltinNamespaceAutoInitProperty(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        name: []const u8,
        flags: property.Flags,
        realm_global: *Object,
        kind: property.AutoInitKind,
    ) !void {
        std.debug.assert(kind == .math_namespace or
            kind == .json_namespace or
            kind == .reflect_namespace or
            kind == .atomics_namespace);
        std.debug.assert(!self.hasExoticMethods());
        std.debug.assert(self.supportsPlainNamedPropertyStorage());
        std.debug.assert(self.flags.extensible);
        const inserted_holder = try registerBorrowedHolderForPendingMutation(rt, self);
        errdefer rollbackBorrowedHolderRegistration(rt, self, inserted_holder);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags.withKind(.auto_init), .{ .auto_init = try property.internAutoInit(rt, .{
            .name = name,
            .length = 0,
            .rt = rt,
            .kind = kind,
            .host_function_realm_global = @intFromPtr(realm_global),
        }) });
        try rt.registerBorrowedReferenceHolder(self);
    }

    pub fn defineArrayUnscopablesAutoInitProperty(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        flags: property.Flags,
    ) !void {
        std.debug.assert(!self.hasExoticMethods());
        std.debug.assert(self.flags.extensible);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags.withKind(.auto_init), .{ .auto_init = try property.internAutoInit(rt, .{
            .name = "[Symbol.unscopables]",
            .length = 0,
            .rt = rt,
            .kind = .array_unscopables,
        }) });
    }

    pub fn defineNumberConstantAutoInitProperty(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        name: []const u8,
        flags: property.Flags,
    ) !void {
        std.debug.assert(!self.hasExoticMethods());
        std.debug.assert(self.supportsPlainNamedPropertyStorage());
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.flags.extensible);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags.withKind(.auto_init), .{ .auto_init = try property.internAutoInit(rt, .{
            .name = name,
            .length = 0,
            .rt = rt,
            .kind = .number_constant,
        }) });
    }

    pub fn defineInt32ConstantAutoInitProperty(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        name: []const u8,
        constant_value: i32,
        flags: property.Flags,
    ) !void {
        std.debug.assert(!self.hasExoticMethods());
        std.debug.assert(self.supportsPlainNamedPropertyStorage());
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.flags.extensible);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags.withKind(.auto_init), .{ .auto_init = try property.internAutoInit(rt, .{
            .name = name,
            .length = constant_value,
            .rt = rt,
            .kind = .int32_constant,
        }) });
    }

    pub fn defineStringConstantAutoInitProperty(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        bytes: []const u8,
        flags: property.Flags,
    ) !void {
        std.debug.assert(!self.hasExoticMethods());
        std.debug.assert(self.supportsPlainNamedPropertyStorage());
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.flags.extensible);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags.withKind(.auto_init), .{ .auto_init = try property.internAutoInit(rt, .{
            .name = bytes,
            .length = 0,
            .rt = rt,
            .kind = .string_constant,
        }) });
    }

    pub fn defineEmptyArrayAutoInitProperty(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        flags: property.Flags,
        realm_global: *Object,
    ) !void {
        std.debug.assert(!self.hasExoticMethods());
        std.debug.assert(self.supportsPlainNamedPropertyStorage());
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.flags.extensible);
        std.debug.assert(!flags.isAccessor());
        const inserted_holder = try registerBorrowedHolderForPendingMutation(rt, self);
        errdefer rollbackBorrowedHolderRegistration(rt, self, inserted_holder);
        if (self.findProperty(atom_id)) |index| {
            if (!self.propFlagsAt(index).configurable) return error.IncompatibleDescriptor;
            try self.ensureUniqueShapeForMutation(rt);
            const old_flags = self.propFlagsAt(index);
            const entry = &self.prop_values[index];
            const old_slot = entry.slot;
            entry.slot = .{ .auto_init = try property.internAutoInit(rt, .{
                .name = "empty array",
                .length = 0,
                .rt = rt,
                .kind = .empty_array,
                .host_function_realm_global = @intFromPtr(realm_global),
            }) };
            rt.shapes.updatePropertyFlags(self.shape_ref, index, flags.withKind(.auto_init).bits());
            destroyPropertySlot(rt, atom_id, old_flags, old_slot);
            self.pruneBorrowedReferenceHolderIfEmpty(rt);
            try rt.registerBorrowedReferenceHolder(self);
            return;
        }
        try self.appendPreparedPropertyEntry(rt, atom_id, flags.withKind(.auto_init), .{ .auto_init = try property.internAutoInit(rt, .{
            .name = "empty array",
            .length = 0,
            .rt = rt,
            .kind = .empty_array,
            .host_function_realm_global = @intFromPtr(realm_global),
        }) });
        try rt.registerBorrowedReferenceHolder(self);
    }

    pub fn defineHostAutoInitProperty(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        name: []const u8,
        length: i32,
        flags: property.Flags,
        host_function_kind: i32,
        host_function_prototype: bool,
        host_function_realm_global: ?*Object,
    ) !void {
        try self.defineHostAutoInitPropertyWithExternalId(
            rt,
            atom_id,
            name,
            length,
            flags,
            host_function_kind,
            host_function_prototype,
            host_function_realm_global,
            0,
        );
    }

    pub fn defineHostAutoInitPropertyWithExternalId(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        name: []const u8,
        length: i32,
        flags: property.Flags,
        host_function_kind: i32,
        host_function_prototype: bool,
        host_function_realm_global: ?*Object,
        external_host_function_id: u32,
    ) !void {
        std.debug.assert(host_function_kind != 0);
        std.debug.assert(external_host_function_id == 0 or host_function_kind == host_function.ids.external_host);
        std.debug.assert(!self.hasExoticMethods());
        std.debug.assert(self.supportsPlainNamedPropertyStorage());
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.flags.extensible);
        const inserted_holder = if (host_function_realm_global != null)
            try registerBorrowedHolderForPendingMutation(rt, self)
        else
            false;
        errdefer rollbackBorrowedHolderRegistration(rt, self, inserted_holder);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags.withKind(.auto_init), .{ .auto_init = try property.internAutoInit(rt, .{
            .name = name,
            .length = length,
            .rt = rt,
            .host_function_kind = host_function_kind,
            .external_host_function_id = external_host_function_id,
            .host_function_prototype = host_function_prototype,
            .host_function_realm_global = if (host_function_realm_global) |realm| @intFromPtr(realm) else 0,
        }) });
        if (host_function_realm_global != null) try rt.registerBorrowedReferenceHolder(self);
    }

    pub fn writeDenseArrayIndex(self: *Object, rt: *JSRuntime, index: u32, atom_id: atom.Atom, new_value: JSValue) !bool {
        if (!self.isArray() or !self.flags.length_writable) return false;
        if (self.arrayElementStorageMode() != .dense) return false;
        if (self.shape_ref.prop_count != 0 and self.findProperty(atom_id) != null) return false;
        const elements = self.arrayElements();
        if (index >= elements.len) return false;
        if (self.getPrototype()) |proto| {
            if (!arrayAppendPrototypeChainHasNoIndexedProperties(proto, rt) and proto.hasProperty(atom_id)) return false;
        }

        return self.setFastArrayElementDup(rt, index, new_value);
    }

    pub fn appendDenseArrayIndex(self: *Object, rt: *JSRuntime, index: u32, atom_id: atom.Atom, new_value: JSValue) !bool {
        // qjs add_fast_array_element (quickjs.c:9542-9570): the dense append
        // gate is `idx == count`, NOT `idx == length`. A holey array (length >
        // count) can append at `count`; `length` is bumped to `index+1` only
        // when it grows past the current length.
        if (!self.isArray() or index != self.u.array.count or !self.flags.length_writable) return false;
        if (self.hasExoticMethods() or self.arrayElementStorageMode() != .dense) return false;
        if (!self.flags.extensible) return false;
        if (self.shape_ref.prop_count != 0 and self.findProperty(atom_id) != null) return false;
        if (self.getPrototype()) |proto| {
            // Filling a hole (`index < array_length`) is an ordinary [[Set]] of a
            // missing index that must consult inherited setters / proxy traps; a
            // proxy or exotic anywhere in the chain can intercept it, so bail to
            // the full [[Set]] path. (A true logical-end append `index ==
            // array_length` needs only the inherited-data-property guard below.)
            if (index < self.u.array.length and arrayPrototypeChainHasInterceptingSet(proto)) return false;
            if (!arrayAppendPrototypeChainHasNoIndexedProperties(proto, rt) and proto.hasProperty(atom_id)) return false;
        }

        const element_slot = try self.appendUninitializedFastArraySlot(rt);
        element_slot.* = new_value.dup();
        if (index + 1 > self.u.array.length) self.u.array.length = index + 1;
        self.markIndexedProperties(rt);
        return true;
    }

    pub fn appendDenseArrayValues(self: *Object, rt: *JSRuntime, start: u32, values: []const JSValue) !bool {
        // Dense append gate keys off the dense extent (array_count), not the
        // logical length: a holey array appends at count. See add_fast_array_element.
        if (!self.isArray() or start != self.u.array.count or !self.flags.length_writable) return false;
        if (self.hasExoticMethods() or self.arrayElementStorageMode() != .dense) return false;
        if (!self.flags.extensible) return false;
        const added: u32 = std.math.cast(u32, values.len) orelse return false;
        const limit = std.math.add(u32, start, added) catch return false;
        if (limit > array.max_array_length) return false;

        const indexed_proto = if (self.getPrototype()) |proto| blk: {
            break :blk if (arrayAppendPrototypeChainHasNoIndexedProperties(proto, rt)) null else proto;
        } else null;
        // Apply the eligibility checks above even for an empty append. qjs
        // `js_array_push` admits `push()` to its fast case only
        // when the receiver is the same extendable, fully-dense Array shape
        // used for non-empty pushes; otherwise it performs the required
        // ordinary length Set through the generic path.
        if (values.len == 0) return true;
        var guard_index = start;
        while (guard_index < limit) : (guard_index += 1) {
            const atom_id = atom.atomFromUInt32(guard_index);
            if (self.shape_ref.prop_count != 0 and self.findProperty(atom_id) != null) return false;
            if (indexed_proto) |proto| {
                if (proto.hasProperty(atom_id)) return false;
            }
        }

        try self.ensureArrayElementCapacity(rt, @intCast(limit));
        var element_index: usize = @intCast(start);
        for (values) |item| {
            self.u.array.values[element_index] = item.dup();
            element_index += 1;
        }
        self.setFastArrayCountAssumeCapacity(limit);
        if (limit > self.u.array.length) self.u.array.length = limit;
        self.markIndexedProperties(rt);
        return true;
    }

    pub fn initDenseArrayIndexZeroAssumingEmpty(self: *Object, rt: *JSRuntime, new_value: JSValue) !void {
        std.debug.assert(self.isArray());
        std.debug.assert(self.u.array.count == 0);
        std.debug.assert(self.flags.length_writable);
        std.debug.assert(self.flags.extensible);
        std.debug.assert(self.arrayElements().len == 0);
        std.debug.assert(self.arrayElementsCapacity() == 0);

        const element_slot = try self.appendUninitializedFastArraySlot(rt);
        element_slot.* = new_value.dup();
        if (self.u.array.length < 1) self.u.array.length = 1;
        self.markIndexedProperties(rt);
    }

    pub fn appendDenseArrayLiteralIndex(self: *Object, rt: *JSRuntime, index: u32, new_value: JSValue) !bool {
        return self.appendDenseArrayDefineIndex(rt, index, atom.atomFromUInt32(index), new_value);
    }

    /// Dense CreateDataProperty append. Unlike ordinary [[Set]], defining a
    /// fresh own index never consults inherited setters or indexed properties.
    /// Mirrors qjs JS_CreateProperty -> add_fast_array_element.
    pub fn appendDenseArrayDefineIndex(self: *Object, rt: *JSRuntime, index: u32, atom_id: atom.Atom, new_value: JSValue) !bool {
        return self.appendDenseArrayDefineIndexMode(rt, index, atom_id, new_value, false);
    }

    /// Owned-value counterpart of `appendDenseArrayDefineIndex`. The value is
    /// consumed only when this returns true; false/error leave ownership with
    /// the caller. This matches QuickJS's consuming JS_DefinePropertyValue
    /// contract without adding a retain/release pair to dense appends.
    pub fn appendDenseArrayDefineIndexOwned(self: *Object, rt: *JSRuntime, index: u32, atom_id: atom.Atom, new_value: JSValue) !bool {
        return self.appendDenseArrayDefineIndexMode(rt, index, atom_id, new_value, true);
    }

    fn appendDenseArrayDefineIndexMode(self: *Object, rt: *JSRuntime, index: u32, atom_id: atom.Atom, new_value: JSValue, comptime take_ownership: bool) !bool {
        if (!self.isArray() or index != self.u.array.count or !self.flags.length_writable) return false;
        if (self.arrayElementStorageMode() != .dense) return false;
        if (!self.flags.extensible) return false;
        if (self.shape_ref.prop_count != 0 and self.findPropertyIndexTrusted(atom_id) != null) return false;

        const element_slot = try self.appendUninitializedFastArraySlot(rt);
        element_slot.* = if (take_ownership) new_value else new_value.dup();
        if (index + 1 > self.u.array.length) self.u.array.length = index + 1;
        self.markIndexedProperties(rt);
        return true;
    }

    pub fn initDenseArrayLiteralValuesAssumingEmpty(self: *Object, rt: *JSRuntime, values: []const JSValue) !bool {
        if (!self.isArray() or !self.flags.length_writable or !self.flags.extensible) return false;
        if (self.u.array.count != 0 or self.u.array.length != 0 or self.shape_ref.prop_count != 0) return false;
        if (self.arrayElementStorageMode() != .dense) return false;
        if (values.len > array.max_array_length) return false;

        try self.ensureArrayElementCapacity(rt, values.len);
        self.setFastArrayCountAssumeCapacity(@intCast(values.len));
        self.u.array.length = @intCast(values.len);
        for (values, 0..) |item, index| {
            const element_slot = &self.u.array.values[index];
            element_slot.* = item.dup();
        }
        if (values.len != 0) self.markIndexedProperties(rt);
        return true;
    }

    pub fn appendDenseArrayInt32Range(self: *Object, rt: *JSRuntime, start: u32, limit: u32) !bool {
        if (!self.isArray() or self.hasExoticMethods() or self.arrayElementStorageMode() != .dense) return false;
        if (start != self.u.array.count or start >= limit or !self.flags.length_writable or !self.flags.extensible) return false;
        if (self.getPrototype()) |proto| {
            if (!arrayAppendPrototypeChainHasNoIndexedProperties(proto, rt)) return false;
        }

        const start_index: usize = @intCast(start);
        const limit_index: usize = @intCast(limit);

        try self.ensureArrayElementCapacity(rt, limit_index);
        self.setFastArrayCountAssumeCapacity(limit);
        if (limit > self.u.array.length) self.u.array.length = limit;
        self.markIndexedProperties(rt);

        var index = start_index;
        while (index < limit_index) : (index += 1) {
            self.u.array.values[index] = JSValue.int32(@intCast(index));
        }
        return true;
    }

    pub fn appendDenseArrayInt32ValueRange(self: *Object, rt: *JSRuntime, start_index: u32, start_value: i32, count: u32) !bool {
        if (count == 0) return true;
        if (!self.isArray() or self.hasExoticMethods() or self.arrayElementStorageMode() != .dense) return false;
        if (start_index != self.u.array.count or !self.flags.length_writable or !self.flags.extensible) return false;
        if (self.getPrototype()) |proto| {
            if (!arrayAppendPrototypeChainHasNoIndexedProperties(proto, rt)) return false;
        }

        const limit = try std.math.add(u32, start_index, count);
        if (limit > array.max_array_length) return false;
        const last_offset = count - 1;
        if (last_offset > @as(u32, @intCast(std.math.maxInt(i32)))) return false;
        const last_delta: i32 = @intCast(last_offset);
        _ = std.math.add(i32, start_value, last_delta) catch return false;

        const start_element: usize = @intCast(start_index);
        const limit_element: usize = @intCast(limit);

        try self.ensureArrayElementCapacity(rt, limit_element);
        self.setFastArrayCountAssumeCapacity(limit);
        if (limit > self.u.array.length) self.u.array.length = limit;
        self.markIndexedProperties(rt);

        var offset: u32 = 0;
        while (offset < count) : (offset += 1) {
            const index = start_element + @as(usize, @intCast(offset));
            const element_delta: i32 = @intCast(offset);
            const element_value = start_value + element_delta;
            self.u.array.values[index] = JSValue.int32(element_value);
        }
        return true;
    }

    pub fn appendDenseArrayInt32MulAndMaskRange(self: *Object, rt: *JSRuntime, start_index: u32, limit: u32, multiplier: i32, mask: i32) !bool {
        if (start_index >= limit) return true;
        if (multiplier < 0 or mask < 0) return false;
        if (!self.isArray() or self.hasExoticMethods() or self.arrayElementStorageMode() != .dense) return false;
        if (start_index != self.u.array.count or !self.flags.length_writable or !self.flags.extensible) return false;
        if (self.getPrototype()) |proto| {
            if (!arrayAppendPrototypeChainHasNoIndexedProperties(proto, rt)) return false;
        }

        if (limit > array.max_array_length) return false;
        const max_safe_integer: i128 = 9007199254740991;
        const last_index = limit - 1;
        const last_product = @as(i128, @intCast(last_index)) * @as(i128, multiplier);
        if (last_product > max_safe_integer) return false;

        const start_element: usize = @intCast(start_index);
        const limit_element: usize = @intCast(limit);

        try self.ensureArrayElementCapacity(rt, limit_element);
        self.setFastArrayCountAssumeCapacity(limit);
        if (limit > self.u.array.length) self.u.array.length = limit;
        self.markIndexedProperties(rt);

        var index = start_element;
        while (index < limit_element) : (index += 1) {
            const product_exact = @as(i128, @intCast(index)) * @as(i128, multiplier);
            const product: i32 = @truncate(product_exact);
            const element_value = product & mask;
            self.u.array.values[index] = JSValue.int32(element_value);
        }
        return true;
    }

    pub fn overwriteDenseArrayInt32MaskedIndexRange(self: *Object, rt: *JSRuntime, start: u32, limit: u32, mask: u32) !bool {
        if (start >= limit) return true;
        if (limit > @as(u32, @intCast(std.math.maxInt(i32)))) return false;
        if (mask > atom.max_int_atom) return false;
        if (!self.isArray() or !self.flags.length_writable) return false;
        if (self.hasExoticMethods() or self.arrayElementStorageMode() != .dense) return false;
        if (self.getPrototype()) |proto| {
            if (!arrayAppendPrototypeChainHasNoIndexedProperties(proto, rt)) return false;
        }

        const mask_index: usize = @intCast(mask);
        if (mask_index >= self.u.array.count) return false;

        var guard_index: u32 = 0;
        while (guard_index <= mask) : (guard_index += 1) {
            const atom_id = atom.atomFromUInt32(guard_index);
            if (self.shape_ref.prop_count != 0 and self.findProperty(atom_id) != null) return false;
            if (guard_index == std.math.maxInt(u32)) break;
        }

        var value_index = start;
        while (value_index < limit) : (value_index += 1) {
            const element_index: usize = @intCast(value_index & mask);
            const element_slot = &self.u.array.values[element_index];
            const old = element_slot.*;
            const new_value = JSValue.int32(@intCast(value_index));
            element_slot.* = new_value;
            old.free(rt);
        }
        return true;
    }

    pub fn reserveDenseArrayElements(self: *Object, rt: *JSRuntime, needed: u32) !void {
        if (!self.isArray()) return;
        try self.ensureArrayElementCapacity(rt, @intCast(needed));
    }

    pub fn defineDenseArrayDataProperty(self: *Object, rt: *JSRuntime, index: u32, new_value: JSValue) !bool {
        if (!self.isArray() or self.hasExoticMethods() or self.arrayElementStorageMode() != .dense) return false;
        const atom_id = atom.atomFromUInt32(index);
        if (self.findProperty(atom_id) != null) return false;

        const element_index: usize = @intCast(index);
        if (element_index > self.u.array.count) return false;
        const appended = element_index == self.u.array.count;
        if (appended) {
            if (!self.flags.extensible) return false;
            if (index >= self.arrayLength() and !self.flags.length_writable) return false;
            // Dense append stays on the fully-dense end (index == count == length);
            // a holey array (count < length) falls through to the caller's slow
            // path. This preserves the qjs add_fast_array_element invariant.
            if (index != self.arrayLength()) return false;
            try self.ensureArrayElementCapacity(rt, element_index + 1);
            self.setFastArrayCountAssumeCapacity(index + 1);
            if (index + 1 > self.u.array.length) self.u.array.length = index + 1;
        }

        const next_value = new_value.dup();
        errdefer next_value.free(rt);
        const element_slot = &self.u.array.values[element_index];
        const old = if (appended) JSValue.undefinedValue() else element_slot.*;
        element_slot.* = next_value;
        self.markIndexedProperties(rt);
        if (!appended) old.free(rt);
        return true;
    }

    pub fn markIndexedProperties(self: *Object, rt: *JSRuntime) void {
        self.flags.may_have_indexed_properties = true;
        if (self.flags.is_prototype) {
            rt.any_prototype_may_have_indexed_properties = true;
        }
    }

    fn arrayAppendPrototypeChainHasNoIndexedProperties(proto: *Object, rt: *JSRuntime) bool {
        if (!rt.any_prototype_may_have_indexed_properties) return true;
        var cursor: ?*Object = proto;
        while (cursor) |object| {
            if (object.flags.may_have_indexed_properties) return false;
            cursor = object.getPrototype();
        }
        return true;
    }

    /// True if any object in the prototype chain is a proxy or carries exotic
    /// methods that could intercept a [[Set]] of an arbitrary key (e.g. a proxy
    /// `set` trap). A dense fast-array append into a HOLE position relies on the
    /// generic [[Set]] having found no inherited setter (faithful to qjs, which
    /// reaches add_fast_array_element only after the prototype walk); such an
    /// interceptor must be honored, so the dense append bails to the full path.
    fn arrayPrototypeChainHasInterceptingSet(proto: *Object) bool {
        var cursor: ?*Object = proto;
        while (cursor) |object| {
            if (object.proxyTarget() != null or object.hasExoticMethods()) return true;
            cursor = object.getPrototype();
        }
        return false;
    }

    pub fn canDefineDenseArrayDataPropertiesUnchecked(self: Object) bool {
        return self.isArray() and
            !self.hasExoticMethods() and
            self.arrayElementStorageMode() == .dense and
            self.flags.fast_array and
            self.flags.extensible and
            self.shape_ref.prop_count == 0;
    }

    pub fn defineDenseArrayDataPropertyUnchecked(self: *Object, rt: *JSRuntime, index: u32, new_value: JSValue) !void {
        std.debug.assert(self.canDefineDenseArrayDataPropertiesUnchecked());
        std.debug.assert(index < self.arrayLength() or self.flags.length_writable);

        const element_index: usize = @intCast(index);
        if (element_index > self.u.array.count) return;
        const appended = element_index == self.u.array.count;
        if (appended) {
            try self.ensureArrayElementCapacity(rt, element_index + 1);
            self.setFastArrayCountAssumeCapacity(index + 1);
            if (index + 1 > self.u.array.length) self.u.array.length = index + 1;
        }

        const next_value = new_value.dup();
        errdefer next_value.free(rt);
        const element_slot = &self.u.array.values[element_index];
        const old = if (appended) JSValue.undefinedValue() else element_slot.*;
        element_slot.* = next_value;
        self.markIndexedProperties(rt);
        if (!appended) old.free(rt);
    }

    pub fn setProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, new_value: JSValue) !void {
        if (self.class_id == class.ids.module_ns) {
            if (self.moduleNamespaceBindingValue(atom_id)) |stored| {
                stored.free(rt);
                return error.ReadOnly;
            }
        }
        if (self.isArray() and atom_id == atom.ids.length) {
            if (!self.flags.length_writable) return error.ReadOnly;
            try self.defineArrayLength(rt, descriptor.Descriptor.data(new_value, true, false, false));
            return;
        }
        if (self.findProperty(atom_id)) |index| {
            // Accessor (or accessor-destined placeholder): materialize so the
            // real getter/setter exist, then route to the setter.
            if (self.isAccessorOrAccessorPlaceholderAt(index)) {
                try self.materializeAutoInitEntryForMutation(index);
                const entry = &self.prop_values[index];
                if (entry.slot.accessor.setterIsUndefined()) return error.AccessorWithoutSetter;
                return;
            }
            const entry_flags = self.propFlagsAt(index);
            if (!entry_flags.writable) return error.ReadOnly;
            const entry = &self.prop_values[index];
            if (entry_flags.kind == .var_ref) {
                const cell = entry.slot.var_ref;
                const next_value = dupPropertyDataValue(&rt.atoms, atom_id, new_value);
                errdefer next_value.free(rt);
                cell.setVarRefValue(rt, next_value);
                return;
            }
            // Data or data-destined auto_init placeholder: overwrite with the
            // new value. A placeholder's lazy default is simply discarded; flip
            // the kind to `.data` in lockstep so the cell and shape stay in sync.
            const next_value = dupPropertyDataValue(&rt.atoms, atom_id, new_value);
            errdefer next_value.free(rt);
            if (entry_flags.kind == .data) {
                const old_slot = entry.slot;
                entry.slot = .{ .data = next_value };
                destroyPropertySlot(rt, atom_id, entry_flags, old_slot);
            } else {
                // auto_init data placeholder: needs the shape kind flip.
                try self.ensureUniqueShapeForMutation(rt);
                self.setEntryKindAndSlot(rt, atom_id, index, entry_flags.withKind(.data), .{ .data = next_value });
            }
            self.pruneBorrowedReferenceHolderIfEmpty(rt);
            return;
        }
        if (array.arrayIndexFromAtom(&rt.atoms, atom_id)) |index| {
            if (try self.setDenseArrayElement(rt, index, new_value)) return;
        }
        var prototype = self.getPrototype();
        while (prototype) |proto| {
            if (proto.findProperty(atom_id)) |index| {
                const is_accessor = proto.isAccessorOrAccessorPlaceholderAt(index);
                if (is_accessor) {
                    try proto.materializeAutoInitEntryForMutation(index);
                    const inherited = proto.prop_values[index];
                    if (inherited.slot.accessor.setterIsUndefined()) return error.AccessorWithoutSetter;
                } else if (!proto.propFlagsAt(index).writable) {
                    return error.ReadOnly;
                }
            }
            prototype = proto.getPrototype();
        }

        try self.defineOwnDataPropertyForSetKnownNoOwn(rt, atom_id, new_value);
    }

    pub fn setOwnWritableDataProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, new_value: JSValue) !bool {
        if (self.class_id == class.ids.module_ns) {
            if (self.moduleNamespaceBindingValue(atom_id)) |stored| {
                stored.free(rt);
                return false;
            }
        }
        // QJS's JS_SetPropertyInternal consumes the shape flags and matching
        // value cell returned by one `find_own_property` probe. Keep that pair
        // together here as well; the old path re-ran defensive/indexed shape
        // reads after the successful hash lookup.
        const lookup = self.findPropertyProbeTrusted(atom_id) orelse return false;
        const index = lookup.index;
        const entry_flags = property.Flags.fromBits(lookup.prop.flags);
        if (entry_flags.deleted or !entry_flags.writable) return false;
        const entry = &self.prop_values[index];

        switch (entry_flags.kind) {
            .accessor => return false,
            .var_ref => {
                const cell = entry.slot.var_ref;
                const next_value = dupPropertyDataValue(&rt.atoms, atom_id, new_value);
                errdefer next_value.free(rt);
                cell.setVarRefValue(rt, next_value);
                return true;
            },
            .auto_init => {
                // Native accessor placeholders must materialize and invoke the
                // setter; only data-destined placeholders may be overwritten.
                if (property.autoInit(entry.slot.auto_init).kind == .native_accessor) return false;
                const next_value = dupPropertyDataValue(&rt.atoms, atom_id, new_value);
                errdefer next_value.free(rt);
                try self.ensureUniqueShapeForMutation(rt);
                self.setEntryKindAndSlot(rt, atom_id, index, entry_flags.withKind(.data), .{ .data = next_value });
                self.pruneBorrowedReferenceHolderIfEmpty(rt);
                return true;
            },
            .data => {},
        }

        const stored = &entry.slot.data;
        if (atom_id != atom.ids.Private_brand and !stored.requiresRefCount() and !new_value.requiresRefCount()) {
            stored.* = new_value;
            return true;
        }
        const next_value = dupPropertyDataValue(&rt.atoms, atom_id, new_value);
        errdefer next_value.free(rt);
        const old_slot = entry.slot;
        entry.slot = .{ .data = next_value };
        destroyPropertySlot(rt, atom_id, entry_flags, old_slot);
        self.pruneBorrowedReferenceHolderIfEmpty(rt);
        return true;
    }

    pub inline fn setOwnDataPropertyAtForLexicalSyncOwned(self: *Object, rt: *JSRuntime, index: usize, atom_id: atom.Atom, new_value: JSValue) !bool {
        if (self.hasExoticMethods() or index >= self.shapeProps().len) return false;
        const prop = self.shape_ref.props()[index];
        const prop_flags = property.Flags.fromBits(prop.flags);
        if (prop.atom_id != atom_id or prop_flags.deleted or prop_flags.kind != .data) return false;
        const entry = &self.prop_values[index];
        const stored = &entry.slot.data;
        if (!prop_flags.writable and !stored.isUninitialized()) return false;
        if (atom_id == atom.ids.Private_brand) return false;
        const old = stored.*;
        stored.* = new_value;
        old.free(rt);
        return true;
    }

    pub fn setOrDefineOwnDataPropertyForSimpleSet(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, new_value: JSValue) !bool {
        if (self.class_id == class.ids.module_ns) {
            if (self.moduleNamespaceBindingValue(atom_id)) |stored| {
                stored.free(rt);
                return false;
            }
        }
        if (self.findProperty(atom_id)) |index| {
            const entry_flags = self.propFlagsAt(index);
            if (self.isAccessorOrAccessorPlaceholderAt(index)) return false;
            if (!entry_flags.writable) return false;
            const entry = &self.prop_values[index];
            if (atom_id != atom.ids.Private_brand) {
                switch (entry_flags.kind) {
                    .data => {
                        const stored = &entry.slot.data;
                        if (!stored.requiresRefCount() and !new_value.requiresRefCount()) {
                            stored.* = new_value;
                            return true;
                        }
                    },
                    // VARREF slots are written through the cell via putVar, never
                    // here; refuse the fast path so we never overwrite the slot.
                    .var_ref => return false,
                    // Data-destined auto_init placeholder: overwrite + flip kind.
                    .auto_init => {
                        const next_value = dupPropertyDataValue(&rt.atoms, atom_id, new_value);
                        errdefer next_value.free(rt);
                        try self.ensureUniqueShapeForMutation(rt);
                        self.setEntryKindAndSlot(rt, atom_id, index, entry_flags.withKind(.data), .{ .data = next_value });
                        self.pruneBorrowedReferenceHolderIfEmpty(rt);
                        return true;
                    },
                    .accessor => unreachable, // excluded above
                }
            }
            const next_value = dupPropertyDataValue(&rt.atoms, atom_id, new_value);
            errdefer next_value.free(rt);
            const old_slot = entry.slot;
            entry.slot = .{ .data = next_value };
            destroyPropertySlot(rt, atom_id, entry_flags, old_slot);
            self.pruneBorrowedReferenceHolderIfEmpty(rt);
            return true;
        }
        return try self.defineNewOwnDataPropertyForSimpleSetKnownNoOwn(rt, atom_id, new_value);
    }

    pub fn defineNewOwnDataPropertyForSimpleSet(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, new_value: JSValue) !bool {
        if (self.findProperty(atom_id) != null) return false;
        return try self.defineNewOwnDataPropertyForSimpleSetKnownNoOwn(rt, atom_id, new_value);
    }

    fn defineOwnDataPropertyForSetKnownNoOwn(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, new_value: JSValue) !void {
        const desc = descriptor.Descriptor.data(new_value, true, true, true);
        if (self.exoticMethods(rt)) |methods| {
            if (methods.define_own_property) |hook| {
                if (!hook(self, atom_id, desc)) return error.IncompatibleDescriptor;
                return;
            }
        }
        if (try self.defineModuleNamespaceProperty(rt, atom_id, desc)) return;

        if (self.isArray() and atom_id == atom.ids.length) {
            try self.defineArrayLength(rt, desc);
            return;
        }

        if (self.isArray()) {
            if (array.arrayIndexFromAtom(&rt.atoms, atom_id)) |index| {
                if (index >= self.arrayLength() and !self.flags.length_writable) return error.ReadOnly;
                const old_length = self.arrayLength();
                if (self.flags.fast_array) try self.convertDenseArrayElementsToSparseProperties(rt);
                try self.defineOrdinaryOwnPropertyKnownNoOwn(rt, atom_id, desc);
                if (index >= old_length) self.setArrayLength(index + 1);
                self.updateArrayStorageMode(index);
                return;
            }
        }

        try self.defineOrdinaryOwnPropertyKnownNoOwn(rt, atom_id, desc);
        try self.updateMappedArgumentsBinding(rt, atom_id, desc);
    }

    fn defineNewOwnDataPropertyForSimpleSetKnownNoOwn(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, new_value: JSValue) !bool {
        if (self.hasExoticMethods() or self.proxyTarget() != null or self.isGlobal() or self.flags.is_with_environment) return false;
        if (!self.flags.extensible) return false;
        if (self.class_id == class.ids.module_ns or self.class_id == class.ids.mapped_arguments) return false;
        if (isTypedArrayObjectForSetFastPath(self)) return false;
        if (self.isArray() and atom_id == atom.ids.length) return false;
        if (array.arrayIndexFromAtom(&rt.atoms, atom_id) != null) return false;

        var prototype = self.getPrototype();
        while (prototype) |proto| {
            if (proto.hasExoticMethods() or proto.proxyTarget() != null) return false;
            if (isTypedArrayObjectForSetFastPath(proto)) return false;
            if (proto.findProperty(atom_id) != null) return false;
            prototype = proto.getPrototype();
        }

        try self.addProperty(rt, atom_id, descriptor.Descriptor.data(new_value, true, true, true));
        return true;
    }

    fn defineModuleNamespaceProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: descriptor.Descriptor) !bool {
        if (self.class_id != class.ids.module_ns) return false;
        const current = self.moduleNamespaceBindingValue(atom_id) orelse return false;
        defer current.free(rt);

        if (desc.kind == .accessor) return error.IncompatibleDescriptor;
        if (desc.configurable orelse false) return error.IncompatibleDescriptor;
        if (desc.enumerable) |enumerable| {
            if (!enumerable) return error.IncompatibleDescriptor;
        }
        if (desc.writable) |writable| {
            if (!writable) return error.IncompatibleDescriptor;
        }
        if (desc.kind == .data and desc.value_present and !current.sameValue(desc.value)) {
            return error.ReadOnly;
        }
        return true;
    }

    fn deleteOrdinaryPropertyAt(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, index: usize) bool {
        const old_flags = self.propFlagsAt(index);
        if (!old_flags.configurable) return false;
        self.ensureUniqueShapeForMutation(rt) catch return false;
        const entry = &self.prop_values[index];
        const old_slot = entry.slot;
        // `deleted` is a flag bit, not a kind/arm: keep a harmless data cell.
        entry.slot = .{ .data = JSValue.undefinedValue() };
        rt.shapes.markPropertyDeleted(self.shape_ref, index, old_flags.asDeleted().bits());
        if (self.class_id == class.ids.mapped_arguments) {
            if (array.arrayIndexFromAtom(&rt.atoms, atom_id)) |mapped_index| {
                if (mapped_index < self.argumentsVarRefs().len) self.deleteMappedArgumentsBinding(rt, mapped_index);
            }
        }
        // qjs remove_global_object_property (quickjs.c:9289-9309): deleting a
        // global-object VARREF property parks the shared cell at UNINITIALIZED
        // (clearing is_lexical/is_const) so every capturing frame's reader
        // routes through the uninitialized slow path (OP_get_var's generic
        // global lookup / OP_put_var's global set). qjs additionally files the
        // cell in the uninitialized_vars side table so a later re-declaration
        // reuses it; zjs has no side table — re-declaration creates a fresh
        // property and parked captures reach it through the same name-based
        // slow path, so the observable semantics match.
        if (self.isGlobal() and old_flags.kind == .var_ref and !old_flags.deleted) {
            const cell = old_slot.var_ref;
            const old_value = cell.varRefValueSlot().*;
            cell.varRefValueSlot().* = JSValue.uninitialized();
            cell.is_lexical = false;
            cell.is_const = false;
            old_value.free(rt);
        }
        destroyPropertySlot(rt, atom_id, old_flags, old_slot);
        self.pruneBorrowedReferenceHolderIfEmpty(rt);
        return true;
    }

    pub fn deleteProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom) bool {
        if (self.exoticMethods(rt)) |methods| {
            if (methods.delete_property) |hook| return hook(self, atom_id);
        }
        if (self.isArray() and atom_id == atom.ids.length) return false;

        if (self.findProperty(atom_id)) |index| {
            return self.deleteOrdinaryPropertyAt(rt, atom_id, index);
        }

        if (self.mappedArgumentsBindingIndexFromAtom(rt, atom_id)) |mapped_index| {
            self.deleteMappedArgumentsBinding(rt, mapped_index);
            return true;
        }

        if (array.arrayIndexFromAtom(&rt.atoms, atom_id)) |array_index| {
            const element_index: usize = @intCast(array_index);
            if (element_index < self.arrayElements().len) {
                // T2: delete an in-dense element. We materialize the dense run
                // to sparse index properties and delete the one index. This is
                // observationally identical to qjs's tail-delete cheap hole
                // (the index becomes absent, `.length` is preserved because the
                // convert now restores `array_length`), and crucially it routes
                // the element's finalizer through the deferred class-payload
                // machinery instead of finalizing inline (finalizer-reentrancy
                // safety — see "dense array delete defers element finalizer
                // reentry"). The cheap inline tail-hole would re-enter.
                self.convertDenseArrayElementsToSparseProperties(rt) catch return false;
                const index = self.findProperty(atom_id) orelse return true;
                return self.deleteOrdinaryPropertyAt(rt, atom_id, index);
            }
        }

        return true;
    }

    pub fn ownKeys(self: Object, rt: *JSRuntime) OwnKeysError![]atom.Atom {
        if (self.exoticMethods(rt)) |methods| {
            if (methods.own_keys) |hook| return try hook(@constCast(&self), rt);
        }
        if (self.class_id == class.ids.module_ns) {
            if (@constCast(&self).moduleNamespacePayload()) |payload| {
                var keys: []atom.Atom = &.{};
                errdefer freeKeys(rt, keys);
                for (payload.names) |name| try appendAtom(rt, &keys, name);
                if (atom.predefinedId("Symbol.toStringTag", .symbol)) |tag_atom| {
                    if (self.findProperty(tag_atom) != null) try appendAtom(rt, &keys, tag_atom);
                }
                return keys;
            }
        }

        var keys: []atom.Atom = &.{};
        errdefer freeKeys(rt, keys);

        const has_property_index_keys = hasPropertyIndexKeys(self, rt) or self.class_id == class.ids.mapped_arguments;
        if (!has_property_index_keys) {
            var dense_index: u32 = 0;
            while (dense_index < self.arrayElements().len) : (dense_index += 1) {
                try appendAtom(rt, &keys, atom.atomFromUInt32(dense_index));
            }
        } else {
            var index_keys = std.ArrayList(IndexKey).empty;
            defer index_keys.deinit(rt.memory.allocator);
            if (self.class_id == class.ids.mapped_arguments) {
                for (self.argumentsVarRefs(), 0..) |mapped, mapped_index| {
                    if (mapped == null) continue;
                    try index_keys.append(rt.memory.allocator, .{
                        .index = @intCast(mapped_index),
                        .atom_id = atom.atomFromUInt32(@intCast(mapped_index)),
                    });
                }
            }
            var dense_index: u32 = 0;
            while (dense_index < self.arrayElements().len) : (dense_index += 1) {
                try index_keys.append(rt.memory.allocator, .{
                    .index = dense_index,
                    .atom_id = atom.atomFromUInt32(dense_index),
                });
            }
            for (self.shapeProps()) |prop| {
                if (property.Flags.fromBits(prop.flags).deleted) continue;
                const index = array.arrayIndexFromAtom(&rt.atoms, prop.atom_id) orelse continue;
                if (self.hasDenseArrayElement(index)) continue;
                try index_keys.append(rt.memory.allocator, .{
                    .index = index,
                    .atom_id = prop.atom_id,
                });
            }
            std.mem.sort(IndexKey, index_keys.items, {}, indexKeyLessThan);
            var previous_index: ?u32 = null;
            for (index_keys.items) |index_key| {
                if (previous_index) |previous| {
                    if (previous == index_key.index) continue;
                }
                try appendAtom(rt, &keys, index_key.atom_id);
                previous_index = index_key.index;
            }
        }

        if (self.isArray()) try appendAtom(rt, &keys, atom.ids.length);

        for (self.shapeProps()) |prop| {
            if (property.Flags.fromBits(prop.flags).deleted) continue;
            if (array.arrayIndexFromAtom(&rt.atoms, prop.atom_id) != null) continue;
            const atom_kind = rt.atoms.kind(prop.atom_id);
            if (atom_kind) |kind| {
                if (atom.isPublicSymbolKind(kind) or kind == .private) continue;
            }
            try appendAtom(rt, &keys, prop.atom_id);
        }

        for (self.shapeProps()) |prop| {
            if (property.Flags.fromBits(prop.flags).deleted) continue;
            if (!rt.atoms.isPublicSymbol(prop.atom_id)) continue;
            try appendAtom(rt, &keys, prop.atom_id);
        }

        return keys;
    }

    pub fn freeKeys(rt: *JSRuntime, keys: []atom.Atom) void {
        for (keys) |key| rt.atoms.free(key);
        if (keys.len != 0) rt.memory.free(atom.Atom, keys);
    }

    pub fn seal(self: *Object, rt: *JSRuntime) !void {
        // qjs materializes fast elements before changing integrity-level
        // descriptor flags. This is required for both Arrays and unmapped
        // arguments: dense slots implicitly have writable/enumerable/
        // configurable=true and need real shape entries before sealing.
        if (self.flags.fast_array and self.u.array.count != 0) {
            try self.convertDenseArrayElementsToSparseProperties(rt);
        }
        try self.materializeAllMappedArgumentsProperties(rt);
        self.flags.extensible = false;
        try self.ensureUniqueShapeForMutation(rt);
        for (0..self.shape_ref.prop_count) |index| {
            var entry_flags = self.propFlagsAt(index);
            if (entry_flags.deleted or !entry_flags.configurable) continue;
            entry_flags.configurable = false;
            rt.shapes.updatePropertyFlags(self.shape_ref, index, entry_flags.bits());
        }
    }

    pub fn freeze(self: *Object, rt: *JSRuntime) !void {
        try self.seal(rt);
        self.detachAllMappedArgumentsBindings(rt);
        for (0..self.shape_ref.prop_count) |index| {
            var entry_flags = self.propFlagsAt(index);
            if (entry_flags.deleted or entry_flags.isAccessor() or !entry_flags.writable) continue;
            entry_flags.writable = false;
            rt.shapes.updatePropertyFlags(self.shape_ref, index, entry_flags.bits());
        }
        if (self.isArray()) self.flags.length_writable = false;
    }

    fn defineOrdinaryOwnProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void {
        try self.materializeMappedArgumentsProperty(rt, atom_id);
        if (array.arrayIndexFromAtom(&rt.atoms, atom_id)) |array_index| {
            const element_index: usize = @intCast(array_index);
            if (element_index < self.arrayElements().len) {
                try self.convertDenseArrayElementsToSparseProperties(rt);
            }
        }
        if (self.findProperty(atom_id)) |index| {
            try self.materializeAutoInitEntryForMutation(index);
            if (!isCompatible(self.propFlagsAt(index), self.prop_values[index].slot, desc)) return error.IncompatibleDescriptor;
            try self.replaceProperty(rt, index, desc);
            return;
        }

        if (!self.flags.extensible) return error.NotExtensible;
        try self.addProperty(rt, atom_id, desc);
    }

    fn defineOrdinaryOwnPropertyKnownNoOwn(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void {
        if (array.arrayIndexFromAtom(&rt.atoms, atom_id)) |array_index| {
            const element_index: usize = @intCast(array_index);
            if (element_index < self.arrayElements().len) {
                try self.convertDenseArrayElementsToSparseProperties(rt);
            }
        }

        if (!self.flags.extensible) return error.NotExtensible;
        try self.addProperty(rt, atom_id, desc);
    }

    fn defineArrayLength(self: *Object, rt: *JSRuntime, desc: descriptor.Descriptor) !void {
        if (desc.kind == .accessor) return error.IncompatibleDescriptor;
        const new_len = if (desc.value_present)
            try arrayLengthFromValue(rt, desc.value) orelse return error.InvalidLength
        else
            null;
        if (desc.configurable orelse false) return error.IncompatibleDescriptor;
        if (desc.enumerable orelse false) return error.IncompatibleDescriptor;
        if (!desc.value_present) {
            if (desc.writable) |writable| {
                if (self.flags.length_writable or !writable) {
                    self.flags.length_writable = writable;
                } else {
                    return error.IncompatibleDescriptor;
                }
            }
            return;
        }
        const target_len = new_len.?;
        if (!self.flags.length_writable) {
            if (target_len != self.arrayLength() or (desc.writable orelse false)) return error.IncompatibleDescriptor;
        }
        if (target_len > self.arrayLength() and !self.flags.length_writable) return error.ReadOnly;
        // Growing `.length` keeps the fast array and just creates tail holes in
        // `[count, target_len)` — faithful to set_array_length (quickjs.c:9447-9455),
        // which leaves count untouched and never drops to sparse. (The trailing
        // setArrayLength(target_len) below performs the grow.)
        if (target_len < self.arrayLength()) {
            var i = self.shape_ref.prop_count;
            while (i > 0) {
                i -= 1;
                if (self.propFlagsAt(i).deleted) continue;
                const prop_atom = self.propAtomAt(i);
                const index = array.arrayIndexFromAtom(&rt.atoms, prop_atom) orelse continue;
                if (index >= target_len and !self.deleteProperty(rt, prop_atom)) {
                    const adjusted_len = index + 1;
                    self.truncateArrayElements(rt, adjusted_len);
                    self.setArrayLength(adjusted_len);
                    self.recomputeArrayStorageMode(rt);
                    if (desc.writable == false) self.flags.length_writable = false;
                    return error.IncompatibleDescriptor;
                }
            }
        }
        self.truncateArrayElements(rt, target_len);
        self.setArrayLength(target_len);
        self.recomputeArrayStorageMode(rt);
        if (desc.writable) |writable| self.flags.length_writable = writable;
    }

    pub fn truncateArrayElements(self: *Object, rt: *JSRuntime, new_len: u32) void {
        if (!self.isArray() or !self.flags.fast_array) return;
        const len: usize = @min(@as(usize, @intCast(new_len)), self.u.array.count);
        while (self.u.array.count > len) {
            self.u.array.count -= 1;
            const old = self.u.array.values[@intCast(self.u.array.count)];
            old.free(rt);
        }
    }

    pub fn convertDenseArrayElementsToSparseProperties(self: *Object, rt: *JSRuntime) !void {
        if (!self.flags.fast_array) return;
        // Preserve the JS-observable Array length, not the dense extent. qjs
        // convert_fast_array_to_array (quickjs.c:9244) materializes only the
        // live `[0, count)` slots into index properties; Array holes in
        // `[count, length)` stay absent. For arguments this internal length is
        // unobservable; their own `length` property is already in the shape.
        const saved_length = self.u.array.length;
        const elements = self.arrayElements();
        for (elements, 0..) |stored, index| {
            const atom_id = atom.atomFromUInt32(@intCast(index));
            if (self.findProperty(atom_id) != null) continue;
            try self.addProperty(rt, atom_id, descriptor.Descriptor.data(stored, true, true, true));
        }
        for (elements) |stored| stored.free(rt);
        self.u.array.count = 0;
        self.freeArrayElementBufferAfterMove(rt);
        // Sparse array: count stays 0, length is the JS-observable `.length`.
        self.u.array.length = saved_length;
    }

    fn denseArrayElement(self: *const Object, atom_id: atom.Atom) ?JSValue {
        if (!self.flags.fast_array) return null;
        if (!atom.isTaggedInt(atom_id)) return null;
        const index = atom.atomToUInt32(atom_id);
        if (index >= self.u.array.count) return null;
        return self.u.array.values[@intCast(index)];
    }

    fn hasDenseArrayElement(self: *const Object, index: u32) bool {
        return self.isFastArrayIndexInBounds(index);
    }

    fn setDenseArrayElement(self: *Object, rt: *JSRuntime, index: u32, new_value: JSValue) !bool {
        if (!self.flags.fast_array) return false;
        if (!self.setFastArrayElementDup(rt, index, new_value)) return false;
        self.markIndexedProperties(rt);
        return true;
    }

    fn ensureArrayElementCapacity(self: *Object, rt: *JSRuntime, needed_len: usize) !void {
        try self.ensureArrayBufferCapacity(rt, needed_len);
    }

    fn updateArrayStorageMode(self: *Object, index: u32) void {
        if (!self.isArray()) return;
        _ = index;
        self.flags.fast_array = false;
    }

    fn recomputeArrayStorageMode(self: *Object, rt: *JSRuntime) void {
        if (!self.isArray()) return;
        self.flags.fast_array = self.u.array.capacity >= self.u.array.count;
        for (self.shapeProps()) |prop| {
            if (property.Flags.fromBits(prop.flags).deleted) continue;
            const index = array.arrayIndexFromAtom(&rt.atoms, prop.atom_id) orelse continue;
            self.updateArrayStorageMode(index);
        }
    }

    inline fn addProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void {
        const slot = slotFromDescriptor(&rt.atoms, atom_id, desc);
        try self.appendPreparedPropertyEntry(rt, atom_id, flagsFromDescriptor(desc), slot);
    }

    /// Trusted variant of `addProperty` for callers that already hold a live
    /// `atom_id` ref across the whole call (see `appendPreparedPropertyEntryTrusted`
    /// for the guard-elision rationale). Used only by
    /// `definePlainDataPropertyKnownFast` on the object-literal `OP_define_field`
    /// path, where `atom_id` is the executing function bytecode's inline operand
    /// and is rooted for the entire opcode.
    fn addPropertyTrusted(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void {
        const slot = slotFromDescriptor(&rt.atoms, atom_id, desc);
        try self.appendPreparedPropertyEntryTrusted(rt, atom_id, flagsFromDescriptor(desc), slot);
    }

    /// Lean plain-object define for the object-literal fast path (OP_define_field
    /// on a fresh ordinary object). Mirrors qjs JS_DefineProperty -> JS_CreateProperty
    /// for a NON-exotic object (quickjs.c:10164 `if (p->is_exotic)` gates the whole
    /// array/typed-array/exotic prelude, which a plain object skips): one
    /// find_own_property hash probe, then straight to add_property on a miss.
    /// Skips the array-length / mapped-arguments / module-namespace
    /// preludes and the duplicate arrayIndexFromAtom of defineOwnProperty+
    /// defineOrdinaryOwnProperty. Preserves duplicate-literal-key semantics
    /// (`{a:1,a:2}`) via the findProperty branch. Caller guarantees:
    /// class_id==object, !hasExoticMethods, !is_array, extensible.
    pub inline fn definePlainDataPropertyKnownFast(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void {
        if (self.findPropertyIndexTrusted(atom_id)) |index| {
            try self.materializeAutoInitEntryForMutation(index);
            if (!isCompatible(self.propFlagsAt(index), self.prop_values[index].slot, desc)) return error.IncompatibleDescriptor;
            try self.replaceProperty(rt, index, desc);
            return;
        }
        // Both call sites (vm_literal.zig defineFieldFast + the cold defineField
        // shell) read `atom_id` from `function.code[frame.pc..]` — the executing
        // bytecode's inline OP_define_field operand — which the finalized
        // FunctionBytecode holds a ref on (dupBytecodeAtoms) and the frame's
        // current_function ref keeps live for the whole opcode. That external
        // root makes appendPreparedPropertyEntry's own atom guard redundant here,
        // so use the trusted (guard-free) add.
        try self.addPropertyTrusted(rt, atom_id, desc);
    }

    /// Default entry point: the caller does NOT guarantee an independent live
    /// `atom_id` ref, so a local dup/free guard roots the atom across the shape
    /// allocations below (which can trigger GC, whose object/shape sweep frees
    /// prop atoms — dropping an otherwise-unrooted atom to ref_count 0 mid-call).
    pub fn appendPreparedPropertyEntry(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, entry_flags: property.Flags, slot: property.Slot) !void {
        return self.appendPreparedPropertyEntryImpl(false, rt, atom_id, entry_flags, slot);
    }

    /// Trusted entry point: the caller already holds a live `atom_id` ref for
    /// the whole call (e.g. the object-literal `OP_define_field` path, whose atom
    /// is the executing function bytecode's inline operand — rooted by the
    /// finalized-bytecode atom-retention walk + the frame's `current_function`
    /// ref). With that external root the local dup/free guard is pure redundancy
    /// (the atom cannot reach ref_count 0 under a GC from the shape allocations),
    /// so elide it. qjs add_property likewise relies on the single caller-held
    /// atom ref through add_shape_property (the one owning JS_DupAtom) and has no
    /// per-property guard. MUST NOT be used with a transient/just-interned atom
    /// that has no other root than the (removed) guard.
    pub fn appendPreparedPropertyEntryTrusted(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, entry_flags: property.Flags, slot: property.Slot) !void {
        return self.appendPreparedPropertyEntryImpl(true, rt, atom_id, entry_flags, slot);
    }

    inline fn appendPreparedPropertyEntryImpl(self: *Object, comptime caller_holds_atom_ref: bool, rt: *JSRuntime, atom_id: atom.Atom, entry_flags: property.Flags, slot: property.Slot) !void {
        // Root the atom across the shape allocations below unless the caller
        // already holds a live ref. The dup/free must span the WHOLE function
        // (defer at function scope), so gate via comptime rather than a runtime
        // `if` block — a `defer` inside an `if` would fire at the block's end,
        // before the allocations it must protect.
        if (!caller_holds_atom_ref) _ = rt.atoms.dup(atom_id);
        defer if (!caller_holds_atom_ref) rt.atoms.free(atom_id);
        var slot_owned = true;
        errdefer if (slot_owned) destroyPropertySlot(rt, atom_id, entry_flags, slot);

        const old_len = self.shape_ref.prop_count;
        const old_capacity = self.propertyStorageCapacity();
        const old_properties: []property.Entry = if (old_capacity != 0) self.prop_values[0..old_capacity] else &.{};
        var current_capacity = old_capacity;
        var grew_properties = false;
        if (old_len + 1 > old_capacity) {
            const next_capacity = shape.propertyCapacityForNeeded(old_len + 1);
            const next = try rt.allocRuntime(property.Entry, next_capacity);
            errdefer rt.memory.free(property.Entry, next);
            @memcpy(next[0..old_len], self.prop_values[0..old_len]);
            self.prop_values = next.ptr;
            current_capacity = next_capacity;
            grew_properties = true;
        }

        const old_may_have_indexed_properties = self.flags.may_have_indexed_properties;
        // Over-hang: write the value at index `old_len` (== current prop_count)
        // BEFORE adoptShapeForNewProperty below commits prop_count = old_len + 1.
        // Until that commit the entry is EXCLUDED from propertyEntries(); a GC
        // triggered by the shape allocation skips it (a fresh, not-yet-cyclic
        // value, so skipping cannot collect it prematurely).
        self.prop_values[old_len] = .{ .slot = slot };
        slot_owned = false;

        var inserted = true;
        errdefer if (inserted) {
            destroyPropertySlot(rt, atom_id, entry_flags, self.prop_values[old_len].slot);
            self.prop_values[old_len] = .{};
            self.flags.may_have_indexed_properties = old_may_have_indexed_properties;
            if (grew_properties) {
                const new_properties = self.prop_values[0..current_capacity];
                // The no-storage state is represented by an exact dangling
                // sentinel, not by an arbitrary zero-length slice pointer.
                // Restore that contract when the first property append grows
                // the value buffer but the following shape allocation fails.
                self.prop_values = if (old_capacity == 0)
                    @ptrFromInt(@alignOf(property.Entry))
                else
                    old_properties.ptr;
                rt.memory.free(property.Entry, new_properties);
            }
        };

        // Only the boolean "is this atom an array index?" is needed here (the
        // index value is never consumed): `markIndexedProperties` is a flag flip
        // and `adoptShapeForNewProperty` only tests `!= null`. Route through the
        // lean `atomIsArrayIndex` predicate, which — unlike `arrayIndexFromAtom` —
        // does not resolve `name()` for the common named-key case (a/b/c). qjs
        // `add_property` (quickjs.c:9184) likewise pays only `__JS_AtomIsTaggedInt`
        // per add for a plain object.
        const is_array_index = rt.atoms.atomIsArrayIndex(atom_id);
        if (is_array_index) {
            self.markIndexedProperties(rt);
        }
        try self.adoptShapeForNewProperty(rt, atom_id, entry_flags.bits(), current_capacity, is_array_index);
        if (grew_properties and old_capacity != 0) rt.memory.free(property.Entry, old_properties);
        inserted = false;
    }

    fn shapeNeedsMutationCopy(self: Object) bool {
        return self.shape_ref.refCount() != 1;
    }

    fn ensureUniqueShapeForMutation(self: *Object, rt: *JSRuntime) !void {
        if (!self.shapeNeedsMutationCopy()) return;
        const next_shape = try rt.shapes.cloneForMutation(self.shape_ref);
        const old_shape = self.shape_ref;
        self.shape_ref = next_shape;
        rt.shapes.release(old_shape);
    }

    fn adoptShapeForNewProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, flags: u6, property_capacity: usize, is_array_index: bool) !void {
        // No local atom guard: the sole caller `appendPreparedPropertyEntry`
        // already holds an `atoms.dup(atom_id)` guard live across this entire
        // call (its `defer atoms.free` runs only after we return), so `atom_id`
        // cannot be collected under a GC triggered by the shape allocations
        // below. A second dup/free here just duplicated that root — qjs
        // add_property likewise relies on the single caller-held atom ref
        // through add_shape_property (which does the one owning JS_DupAtom).
        // Indexed properties mutate a unique sparse shape in place. Named
        // properties use the qjs transition triage: cache hit, shared clone, or
        // rc==1 in-place append. transitionProperty owns replacement releases
        // and threads relocation back through self.shape_ref.
        if (is_array_index) {
            try self.ensureUniqueShapeForMutation(rt);
            try rt.shapes.addProperty(&self.shape_ref, atom_id, flags);
            return;
        }
        try rt.shapes.transitionProperty(&self.shape_ref, atom_id, flags, property_capacity);
    }

    fn ensurePropertyCapacity(self: *Object, rt: *JSRuntime, needed: usize) !void {
        const old_capacity = self.propertyStorageCapacity();
        if (needed <= old_capacity) return;
        const next_capacity = shape.propertyCapacityForNeeded(needed);
        const next = try rt.allocRuntime(property.Entry, next_capacity);
        errdefer rt.memory.free(property.Entry, next);
        const used = self.shape_ref.prop_count;
        @memcpy(next[0..used], self.propertyEntries());
        const old_properties: []property.Entry = if (old_capacity != 0) self.prop_values[0..old_capacity] else &.{};
        try rt.shapes.reserveProperties(&self.shape_ref, next_capacity);
        self.prop_values = next.ptr;
        if (old_capacity != 0) rt.memory.free(property.Entry, old_properties);
    }

    fn propertyStorageCapacity(self: *const Object) usize {
        return if (self.hasPropertyStorage()) self.shape_ref.prop_size else 0;
    }

    /// The live property VALUE entries `prop_values[0..prop_count]`. Count comes
    /// from the owning shape (qjs JSObject reads count from JSShape). During the
    /// brief `appendPreparedPropertyEntry` over-hang (a value written at index
    /// `prop_count` before the shape transition commits), the pending entry sits
    /// at `prop_values[prop_count]` and is intentionally EXCLUDED here — callers
    /// that need it (the append path itself) index `prop_values` directly.
    pub inline fn propertyEntries(self: *const Object) []property.Entry {
        if (!self.hasPropertyStorage()) return &.{};
        return self.prop_values[0..self.shape_ref.prop_count];
    }

    fn replaceProperty(self: *Object, rt: *JSRuntime, index: usize, desc: descriptor.Descriptor) !void {
        const atom_id = self.propAtomAt(index);
        const old_flags = self.propFlagsAt(index);
        const merged = mergeDescriptor(old_flags, self.prop_values[index].slot, desc);
        const next_flags = flagsFromDescriptor(merged);
        if (old_flags.kind == .var_ref and merged.kind == .data) {
            // Redefining a VARREF property as data writes THROUGH the cell and
            // keeps the var_ref slot (so closures still alias it). The kind flag
            // therefore stays `.var_ref` — only w/e/c bits update; flipping the
            // kind to `.data` here would desync the cell (slot=var_ref) from the
            // shape (kind=data) and crash the next read.
            const cell = self.prop_values[index].slot.var_ref;
            const next_value = dupPropertyDataValue(&rt.atoms, atom_id, merged.value);
            errdefer next_value.free(rt);
            try self.ensureUniqueShapeForMutation(rt);
            cell.setVarRefValue(rt, next_value);
            rt.shapes.updatePropertyFlags(self.shape_ref, index, next_flags.withKind(.var_ref).bits());
            return;
        }
        const next_slot = slotFromDescriptor(&rt.atoms, atom_id, merged);
        var next_owned = true;
        errdefer if (next_owned) destroyPropertySlot(rt, atom_id, next_flags, next_slot);
        try self.ensureUniqueShapeForMutation(rt);
        const old_slot = self.prop_values[index].slot;
        self.prop_values[index] = .{ .slot = next_slot };
        next_owned = false;
        rt.shapes.updatePropertyFlags(self.shape_ref, index, next_flags.bits());
        destroyPropertySlot(rt, atom_id, old_flags, old_slot);
        self.pruneBorrowedReferenceHolderIfEmpty(rt);
    }

    /// Key atom for the own property stored at `index`. Property
    /// metadata (atom + flags) lives in the shape; `self.properties`
    /// holds only the value slots, indexed 1:1 with the shape props.
    pub inline fn propAtomAt(self: *const Object, index: usize) atom.Atom {
        return self.shape_ref.props()[index].atom_id;
    }

    /// Flags for the own property stored at `index` (see `propAtomAt`).
    pub inline fn propFlagsAt(self: *const Object, index: usize) property.Flags {
        return property.Flags.fromBits(self.shape_ref.props()[index].flags);
    }

    // --- Typed property-slot API (L2 chokepoint) --------------------------
    //
    // The property value cell (`property.Slot`) is a 16B untagged union whose
    // active arm is NOT discriminated in the cell; it is derived from the
    // owning shape's `Flags.kind` (read via `propFlagsAt`). To keep the arm and
    // the kind in lockstep, NO call site reads the union by tag — every kind
    // decision flows through `propKindAt`/the typed getters below, and every
    // slot+flag write flows through `setEntryKindAndSlot` (or the paired
    // `slotFromDescriptor`/`flagsFromDescriptor` constructor).

    /// Active arm of the property cell at `index` (derived from shape flags).
    pub inline fn propKindAt(self: *const Object, index: usize) property.Kind {
        return self.propFlagsAt(index).kind;
    }

    /// The stored data value at `index`, or null if the cell is not a data
    /// property (accessor / var_ref / auto_init / deleted). Borrowed (no dup).
    pub inline fn asDataAt(self: *const Object, index: usize) ?JSValue {
        const flags = self.propFlagsAt(index);
        if (flags.deleted or flags.kind != .data) return null;
        return self.prop_values[index].slot.data;
    }

    /// Replace a known data slot by index, transferring ownership of
    /// `new_value`. Intended for freshly cloned property templates whose shape
    /// fixes both the key and descriptor flags (for example qjs's arguments
    /// shape, where only the per-call `length` value changes).
    pub inline fn replaceOwnDataPropertyValueAtAssumingShapeOwned(self: *Object, rt: *JSRuntime, index: usize, new_value: JSValue) void {
        std.debug.assert(index < self.shape_ref.prop_count);
        const prop = self.shape_ref.props()[index];
        const flags = property.Flags.fromBits(prop.flags);
        std.debug.assert(!flags.deleted and flags.kind == .data);
        const old_slot = self.prop_values[index].slot;
        self.prop_values[index].slot = .{ .data = new_value };
        destroyPropertySlot(rt, prop.atom_id, flags, old_slot);
    }

    /// The stored accessor at `index`, or null if not an accessor property.
    pub inline fn asAccessorAt(self: *const Object, index: usize) ?property.Accessor {
        const flags = self.propFlagsAt(index);
        if (flags.deleted or flags.kind != .accessor) return null;
        return self.prop_values[index].slot.accessor;
    }

    /// The var_ref cell at `index`, or null if not a var_ref property.
    pub inline fn asVarRefAt(self: *const Object, index: usize) ?*var_ref_mod.VarRef {
        const flags = self.propFlagsAt(index);
        if (flags.deleted or flags.kind != .var_ref) return null;
        return self.prop_values[index].slot.var_ref;
    }

    pub inline fn isAutoInitAt(self: *const Object, index: usize) bool {
        return self.propFlagsAt(index).isAutoInit();
    }

    pub inline fn isVarRefAt(self: *const Object, index: usize) bool {
        return self.propFlagsAt(index).isVarRef();
    }

    /// Replace an existing ordinary property with the supplied VarRef cell.
    /// The property takes its own cell ref; the caller keeps its ref.  This is
    /// the object-side half of QuickJS `js_closure_define_global_var`: global
    /// declaration construction fixes the slot identity and descriptor before
    /// hoist bytecode writes the declaration value through the cell.
    pub fn replaceOwnPropertyWithVarRefCell(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        index: usize,
        next_flags: property.Flags,
        cell: *var_ref_mod.VarRef,
    ) !void {
        if (index >= self.shape_ref.prop_count or
            self.propAtomAt(index) != atom_id or
            self.propFlagsAt(index).deleted or
            next_flags.kind != .var_ref or
            next_flags.deleted or
            self.propFlagsAt(index).kind == .auto_init)
        {
            return error.IncompatibleDescriptor;
        }

        // Clone first: after this succeeds, refcount changes and slot teardown
        // are non-failing, so an OOM leaves the old property and parked cell
        // untouched.
        try self.ensureUniqueShapeForMutation(rt);
        const old_flags = self.propFlagsAt(index);
        const old_slot = self.prop_values[index].slot;
        if (old_flags.kind == .data) {
            cell.setVarRefValue(rt, old_slot.data.dup());
        }
        cell.is_lexical = false;
        cell.varRefIsConstSlot().* = !next_flags.writable;
        cell.varRefIsDeletableSlot().* = next_flags.configurable;

        self.prop_values[index].slot = .{ .var_ref = cell.dupCell() };
        rt.shapes.updatePropertyFlags(self.shape_ref, index, next_flags.bits());
        destroyPropertySlot(rt, atom_id, old_flags, old_slot);
        self.pruneBorrowedReferenceHolderIfEmpty(rt);
    }

    /// The single paired mutator for an EXISTING property entry: writes the
    /// new slot arm AND the shape `Flags.kind` in lockstep, then releases the
    /// old slot using the OLD flags. The caller must have ensured a unique
    /// shape for mutation. `next_flags` carries the new kind; `next_slot` must
    /// match `next_flags.kind`.
    fn setEntryKindAndSlot(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        index: usize,
        next_flags: property.Flags,
        next_slot: property.Slot,
    ) void {
        const old_flags = self.propFlagsAt(index);
        const old_slot = self.prop_values[index].slot;
        self.prop_values[index].slot = next_slot;
        rt.shapes.updatePropertyFlags(self.shape_ref, index, next_flags.bits());
        destroyPropertySlot(rt, atom_id, old_flags, old_slot);
    }

    pub const OwnDataPropertyFastLookup = struct {
        index: usize,
        flags: property.Flags,
        value: JSValue,
    };

    pub const OwnDataPropertyFastResult = union(enum) {
        value: OwnDataPropertyFastLookup,
        missing,
        slow,
    };

    pub const WritableOwnDataPropertyFastLookup = struct {
        index: usize,
        flags: property.Flags,
        value: *JSValue,
    };

    const PropertyProbe = struct {
        index: usize,
        prop: shape.Property,
    };

    /// qjs `find_own_property`-style paired result: the shape flags and their
    /// matching value cell come from one hash-chain probe. Keeping them paired
    /// avoids re-reading the same shape property through `propKindAt` and then
    /// again through a kind-specific getter.
    pub const OwnPropertySlotLookup = struct {
        flags: property.Flags,
        entry: *const property.Entry,
    };

    /// Shape-side metadata records matching `self.properties` by index.
    /// Clamped to the entry count so a partially appended property
    /// (entry pushed, shape not yet transitioned) is never exposed.
    pub inline fn shapeProps(self: *const Object) []const shape.Property {
        return self.shape_ref.props()[0..self.shape_ref.prop_count];
    }

    fn findPropertyProbeTrusted(self: *const Object, atom_id: atom.Atom) ?PropertyProbe {
        const prop_count = self.shape_ref.prop_count;
        std.debug.assert(prop_count <= self.shape_ref.prop_count);
        const props = self.shape_ref.props().ptr;
        std.debug.assert(self.shape_ref.hasPropertyHash());
        var shape_index = self.shape_ref.firstPropertyIndex(atom_id);
        while (shape_index != shape.no_property_index) {
            const index: usize = @intCast(shape_index);
            std.debug.assert(index < prop_count);
            const prop = props[index];
            shape_index = prop.hash_next;
            if (prop.atom_id == atom_id) return .{ .index = index, .prop = prop };
        }
        return null;
    }

    pub fn findOwnDataPropertyFast(self: *const Object, atom_id: atom.Atom) OwnDataPropertyFastResult {
        const lookup = self.findPropertyProbeTrusted(atom_id) orelse return .missing;
        const flags = property.Flags.fromBits(lookup.prop.flags);
        if (flags.kind != .data) return .slow;
        return .{ .value = .{ .index = lookup.index, .flags = flags, .value = self.prop_values[lookup.index].slot.data } };
    }

    pub inline fn findOwnPropertySlotTrusted(self: *const Object, atom_id: atom.Atom) ?OwnPropertySlotLookup {
        const lookup = self.findPropertyProbeTrusted(atom_id) orelse return null;
        return .{
            .flags = property.Flags.fromBits(lookup.prop.flags),
            .entry = &self.prop_values[lookup.index],
        };
    }

    /// Lean own-data-property lookup for the hot get_field path: returns just the
    /// BORROWED slot value instead of materializing a 3-way result union. Mirrors
    /// qjs find_own_property plus the data-kind guard; qjs then feeds the borrowed
    /// value directly to JS_DupValue (quickjs.c:19131, quickjs.h:707).
    /// `slow` is written only for the non-data-property case; the caller initializes
    /// it to false so missing can continue the prototype walk without another tag.
    pub inline fn findOwnDataValueFast(self: *const Object, atom_id: atom.Atom, slow: *bool) ?JSValue {
        const props = self.shape_ref.props().ptr;
        var shape_index = self.shape_ref.firstPropertyIndex(atom_id);
        while (shape_index != shape.no_property_index) {
            const index: usize = @intCast(shape_index);
            const prop = props[index];
            shape_index = prop.hash_next;
            if (prop.atom_id == atom_id) {
                const flags = property.Flags.fromBits(prop.flags);
                if (flags.kind != .data) {
                    slow.* = true;
                    return null;
                }
                return self.prop_values[index].slot.data;
            }
        }
        return null;
    }

    pub fn findWritableOwnDataPropertyFast(self: *Object, atom_id: atom.Atom) ?WritableOwnDataPropertyFastLookup {
        const lookup = self.findPropertyProbeTrusted(atom_id) orelse return null;
        const flags = property.Flags.fromBits(lookup.prop.flags);
        if (flags.kind != .data or !flags.writable) return null;
        const entry = &self.prop_values[lookup.index];
        return .{ .index = lookup.index, .flags = flags, .value = &entry.slot.data };
    }

    /// Trusted engine-internal shape probe. Returns just the property index and
    /// drops the runtime `steps < prop_count` / repeated bounds guards carried
    /// by the defensive public `findProperty`. Faithful to qjs
    /// `find_own_property` (quickjs.c:6135), which is force-inlined and trusts
    /// that every shape hash-chain index is valid and non-cyclic.
    pub inline fn findPropertyIndexTrusted(self: *const Object, atom_id: atom.Atom) ?usize {
        const probe = self.findPropertyProbeTrusted(atom_id) orelse return null;
        return probe.index;
    }

    pub fn findProperty(self: *const Object, atom_id: atom.Atom) ?usize {
        const props = self.shapeProps();
        std.debug.assert(self.shape_ref.hasPropertyHash());
        var shape_index = self.shape_ref.firstPropertyIndex(atom_id);
        var steps: usize = 0;
        while (shape_index != shape.no_property_index and steps < self.shape_ref.prop_count) : (steps += 1) {
            const index: usize = @intCast(shape_index);
            if (index >= self.shape_ref.prop_count) break;
            shape_index = self.shape_ref.props()[index].hash_next;
            if (index >= props.len) continue;
            const prop = props[index];
            if (prop.atom_id == atom_id) return index;
        }
        return null;
    }

    fn updateMappedArgumentsBinding(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void {
        if (self.class_id != class.ids.mapped_arguments) return;
        const index = array.arrayIndexFromAtom(&rt.atoms, atom_id) orelse return;
        const refs = self.argumentsVarRefs();
        if (index >= refs.len) return;
        if (refs[index] == null) return;

        if (desc.kind == .accessor) {
            self.deleteMappedArgumentsBinding(rt, index);
            return;
        }

        if (desc.kind == .data and desc.value_present) {
            try self.setMappedArgumentsBindingValue(rt, index, desc.value);
        }

        if (desc.kind == .data and desc.writable != null and desc.writable.? == false) {
            self.deleteMappedArgumentsBinding(rt, index);
        }
    }

    fn prepareMappedArgumentsDescriptorForDefine(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: *descriptor.Descriptor) !bool {
        if (self.class_id != class.ids.mapped_arguments) return false;
        if (desc.kind != .data or desc.value_present) return false;
        if (desc.writable == null or desc.writable.? != false) return false;
        const index = array.arrayIndexFromAtom(&rt.atoms, atom_id) orelse return false;
        const mapped_value = self.mappedArgumentsBindingValue(index) orelse return false;
        desc.value = mapped_value;
        desc.value_present = true;
        return true;
    }

    fn setMappedArgumentsBindingValue(self: *Object, rt: *JSRuntime, index: u32, new_value: JSValue) !void {
        const slot_index: usize = @intCast(index);
        const refs = self.argumentsVarRefsMut();
        const cell = refs[slot_index] orelse return;
        cell.setVarRefValue(rt, new_value.dup());
    }

    fn deleteMappedArgumentsBinding(self: *Object, rt: *JSRuntime, index: u32) void {
        const slot_index: usize = @intCast(index);
        const refs = self.argumentsVarRefsMut();
        const cell = refs[slot_index] orelse return;
        refs[slot_index] = null;
        cell.release(rt);
    }

    fn mappedArgumentsBindingValue(self: *const Object, index: u32) ?JSValue {
        const slot_index: usize = @intCast(index);
        const refs = self.argumentsVarRefs();
        if (slot_index >= refs.len) return null;
        const cell = refs[slot_index] orelse return null;
        return cell.varRefValue().dup();
    }

    fn mappedArgumentsBindingIndexFromAtom(self: *const Object, rt: *const JSRuntime, atom_id: atom.Atom) ?u32 {
        if (self.class_id != class.ids.mapped_arguments) return null;
        const index = array.arrayIndexFromAtom(&rt.atoms, atom_id) orelse return null;
        return if (self.hasMappedArgumentsBinding(index)) index else null;
    }

    fn mappedArgumentsTaggedBindingIndex(self: *const Object, atom_id: atom.Atom) ?u32 {
        if (self.class_id != class.ids.mapped_arguments or !atom.isTaggedInt(atom_id)) return null;
        const index = atom.atomToUInt32(atom_id);
        return if (self.hasMappedArgumentsBinding(index)) index else null;
    }

    fn hasMappedArgumentsBinding(self: *const Object, index: u32) bool {
        const slot_index: usize = @intCast(index);
        const refs = self.argumentsVarRefs();
        return slot_index < refs.len and refs[slot_index] != null;
    }

    fn materializeMappedArgumentsProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom) !void {
        const index = self.mappedArgumentsBindingIndexFromAtom(rt, atom_id) orelse return;
        if (self.findProperty(atom_id) != null) return;
        const mapped_value = self.mappedArgumentsBindingValue(index) orelse return;
        defer mapped_value.free(rt);
        try self.addProperty(rt, atom_id, descriptor.Descriptor.data(mapped_value, true, true, true));
    }

    fn materializeAllMappedArgumentsProperties(self: *Object, rt: *JSRuntime) !void {
        if (self.class_id != class.ids.mapped_arguments) return;
        for (self.argumentsVarRefs(), 0..) |mapped, index| {
            if (mapped == null) continue;
            try self.materializeMappedArgumentsProperty(rt, atom.atomFromUInt32(@intCast(index)));
        }
    }

    fn detachAllMappedArgumentsBindings(self: *Object, rt: *JSRuntime) void {
        if (self.class_id != class.ids.mapped_arguments) return;
        for (self.argumentsVarRefs(), 0..) |mapped, index| {
            if (mapped == null) continue;
            self.deleteMappedArgumentsBinding(rt, @intCast(index));
        }
    }
};

test "object value refs keep nested symbol bodies without external symbol roots" {
    const rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const object = try Object.create(rt, class.ids.object, null);
    var object_value = object.value();
    defer object_value.free(rt);

    const key = try rt.internAtom("external-object-root-symbol-slot");
    defer rt.atoms.free(key);
    const nested_value = try rt.newSymbolValue("external-object-root-nested-symbol");
    const nested_symbol = nested_value.asSymbolAtom().?;
    try object.defineOwnProperty(rt, key, descriptor.Descriptor.data(nested_value, true, true, true));
    nested_value.free(rt);

    try std.testing.expect(!try rt.registerExternalValueSymbolRoot(object_value));
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(nested_symbol) != null);
    rt.unregisterExternalValueSymbolRoot(object_value);

    object_value.free(rt);
    object_value = JSValue.undefinedValue();
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(nested_symbol) == null);
}

fn flagsFromDescriptor(desc: descriptor.Descriptor) property.Flags {
    return switch (desc.kind) {
        .generic => property.Flags.data(false, desc.enumerable orelse false, desc.configurable orelse false),
        .data => property.Flags.data(desc.writable orelse false, desc.enumerable orelse false, desc.configurable orelse false),
        .accessor => property.Flags.accessorFlags(desc.enumerable orelse false, desc.configurable orelse false),
    };
}

fn slotFromDescriptor(atoms: *atom.AtomTable, atom_id: atom.Atom, desc: descriptor.Descriptor) property.Slot {
    return switch (desc.kind) {
        .generic => .{ .data = JSValue.undefinedValue() },
        .data => .{ .data = dupPropertyDataValue(atoms, atom_id, desc.value) },
        .accessor => .{ .accessor = property.Accessor.fromBorrowedValues(desc.getter, desc.setter) },
    };
}

pub fn dupPropertyDataValue(atoms: *atom.AtomTable, atom_id: atom.Atom, value: JSValue) JSValue {
    if (atom_id == atom.ids.Private_brand) {
        if (value.asSymbolAtom()) |brand_atom| {
            if (atoms.kind(brand_atom) == .private) return value.dup();
        }
    }
    return value.dup();
}

pub fn destroyPropertySlot(rt: *JSRuntime, atom_id: atom.Atom, flags: property.Flags, slot: property.Slot) void {
    if (atom_id == atom.ids.Private_brand and !flags.deleted and flags.kind == .data) {
        if (slot.data.asSymbolAtom()) |brand_atom| {
            if (rt.atoms.kind(brand_atom) == .private) rt.atoms.free(brand_atom);
        }
    }
    slot.destroy(flags, rt);
}

fn isTypedArrayObjectForSetFastPath(object: *const Object) bool {
    return isTypedArrayObject(object);
}

// --- TypedArray element mechanism (engine core) -----------------------------
//
// QuickJS source map: the typed-array length/bounds/detach helpers live in the
// engine core (quickjs.c), with builtins as clients. These are thin predicates
// over the core typed-array storage slots (`Object.typedArrayBuffer()`,
// `typedArrayByteOffset()`, `typedArrayElementSize()`, `typedArrayFixedLength()`,
// `arrayBufferDetached()`, ...); this block holds the storage-shape mechanism
// the VM consults directly. The element read/write *value coercion*
// (ToNumber/ToBigInt over primitives, shared with the DataView and ArrayBuffer
// paths) and the buffer storage operations live in `src/core/typed_array.zig`,
// which imports these predicates. `src/exec/buffer_ops.zig` owns the
// JS-visible record surface that uses both blocks.

fn typedArrayBackingBufferObject(object: *Object) !*Object {
    const value = object.typedArrayBuffer() orelse return error.TypeError;
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    const buffer: *Object = @fieldParentPtr("header", header);
    if (buffer.class_id != class.ids.array_buffer and buffer.class_id != class.ids.shared_array_buffer) return error.TypeError;
    return buffer;
}

pub fn isTypedArrayObject(object: *const Object) bool {
    return object.typedArrayBuffer() != null and object.typedArrayElementSize() != 0;
}

pub fn typedArrayOutOfBounds(object: *Object) !bool {
    const buffer = try typedArrayBackingBufferObject(object);
    if (object.typedArrayByteOffset() > buffer.byteStorage().len) return true;
    if (object.typedArrayFixedLength()) |fixed| {
        const bytes = @as(usize, fixed) * object.typedArrayElementSize();
        return bytes > buffer.byteStorage().len - object.typedArrayByteOffset();
    }
    return false;
}

pub fn typedArrayDetached(object: *Object) !bool {
    const buffer = try typedArrayBackingBufferObject(object);
    return buffer.arrayBufferDetached();
}

pub fn typedArrayLength(rt: *JSRuntime, object: *Object) !u32 {
    _ = rt;
    const buffer = try typedArrayBackingBufferObject(object);
    if (buffer.arrayBufferDetached()) return 0;
    if (object.typedArrayByteOffset() > buffer.byteStorage().len) return 0;
    if (object.typedArrayFixedLength()) |fixed| {
        const bytes = @as(usize, fixed) * object.typedArrayElementSize();
        if (bytes > buffer.byteStorage().len - object.typedArrayByteOffset()) return 0;
        return fixed;
    }
    return @intCast(@divTrunc(buffer.byteStorage().len - object.typedArrayByteOffset(), object.typedArrayElementSize()));
}

pub fn typedArrayByteLength(rt: *JSRuntime, object: *Object) !usize {
    const length = try typedArrayLength(rt, object);
    return @as(usize, length) * object.typedArrayElementSize();
}

pub fn typedArrayEffectiveByteOffset(object: *Object) !usize {
    if (try typedArrayDetached(object)) return 0;
    if (try typedArrayOutOfBounds(object)) return 0;
    return object.typedArrayByteOffset();
}

pub fn typedArrayIndexValid(rt: *JSRuntime, object: *Object, index: u32) !bool {
    const length = try typedArrayLength(rt, object);
    return index < length;
}

pub const TypedArrayCanonicalIndex = union(enum) {
    none,
    invalid,
    index: u32,
};

pub fn typedArrayCanonicalNumericIndex(rt: *JSRuntime, atom_id: atom.Atom) !TypedArrayCanonicalIndex {
    if (array.arrayIndexFromAtom(&rt.atoms, atom_id)) |index| return .{ .index = index };
    if (rt.atoms.kind(atom_id) != .string) return .none;
    const name = rt.atoms.name(atom_id) orelse return .none;
    if (name.len == 0) return .none;
    if (std.mem.eql(u8, name, "-0")) return .invalid;

    const number: f64 = if (std.mem.eql(u8, name, "NaN"))
        std.math.nan(f64)
    else if (std.mem.eql(u8, name, "Infinity"))
        std.math.inf(f64)
    else if (std.mem.eql(u8, name, "-Infinity"))
        -std.math.inf(f64)
    else
        std.fmt.parseFloat(f64, name) catch return .none;

    var buf: [64]u8 = undefined;
    const printed = if (std.math.isNan(number))
        "NaN"
    else if (std.math.isPositiveInf(number))
        "Infinity"
    else if (std.math.isNegativeInf(number))
        "-Infinity"
    else
        try value_format.formatFiniteNumber(&buf, number);
    if (!std.mem.eql(u8, name, printed)) return .none;
    if (!std.math.isFinite(number) or @trunc(number) != number or number < 0 or number > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return .invalid;
    return .{ .index = @intFromFloat(number) };
}

pub fn typedArrayBackedByResizableBuffer(object: *Object) bool {
    if (!isTypedArrayObject(object)) return false;
    const buffer = typedArrayBackingBufferObject(object) catch return false;
    return buffer.arrayBufferMaxByteLength() != null;
}

pub fn arrayBufferIsImmutable(rt: *JSRuntime, object: *Object) bool {
    _ = rt;
    return object.arrayBufferImmutable();
}

pub fn markArrayBufferImmutable(rt: *JSRuntime, object: *Object) !void {
    _ = rt;
    object.arrayBufferImmutableSlot().* = true;
}

pub fn typedArrayImmutableBuffer(rt: *JSRuntime, object: *Object) !bool {
    const buffer = try typedArrayBackingBufferObject(object);
    return arrayBufferIsImmutable(rt, buffer);
}

pub fn typedArrayRejectImmutableBuffer(rt: *JSRuntime, object: *Object) !void {
    if (try typedArrayImmutableBuffer(rt, object)) return error.TypeError;
}

fn isCompatible(current_flags: property.Flags, current_slot: property.Slot, desc: descriptor.Descriptor) bool {
    if (current_flags.configurable) return true;
    if (desc.configurable orelse false) return false;
    if (desc.enumerable) |enumerable| {
        if (enumerable != current_flags.enumerable) return false;
    }
    if (desc.kind == .generic) return true;

    const current_is_accessor = current_flags.isAccessor();
    if ((desc.kind == .accessor) != current_is_accessor) return false;
    if (!current_is_accessor and !current_flags.writable) {
        if (desc.writable orelse false) return false;
        if (desc.kind == .data and desc.value_present) {
            const current_value = switch (current_flags.kind) {
                .data => current_slot.data,
                .var_ref => current_slot.var_ref.varRefValue(),
                .accessor, .auto_init => JSValue.undefinedValue(),
            };
            if (!current_value.sameValue(desc.value)) return false;
        }
    }
    if (current_is_accessor and desc.kind == .accessor) {
        if (desc.getter_present and !current_slot.accessor.getterValue().sameValue(desc.getter)) return false;
        if (desc.setter_present and !current_slot.accessor.setterValue().sameValue(desc.setter)) return false;
    }
    return true;
}

fn mergeDescriptor(current_flags: property.Flags, current_slot: property.Slot, desc: descriptor.Descriptor) descriptor.Descriptor {
    return switch (desc.kind) {
        .generic => switch (current_flags.kind) {
            .data => descriptor.Descriptor.data(
                current_slot.data,
                current_flags.writable,
                desc.enumerable orelse current_flags.enumerable,
                desc.configurable orelse current_flags.configurable,
            ),
            .accessor => descriptor.Descriptor.accessor(
                current_slot.accessor.getterValue(),
                current_slot.accessor.setterValue(),
                desc.enumerable orelse current_flags.enumerable,
                desc.configurable orelse current_flags.configurable,
            ),
            .var_ref => descriptor.Descriptor.data(
                current_slot.var_ref.varRefValue(),
                current_flags.writable,
                desc.enumerable orelse current_flags.enumerable,
                desc.configurable orelse current_flags.configurable,
            ),
            // Auto-init placeholders should be materialized by the
            // caller before reaching `mergeDescriptor`; defining
            // `Object.defineProperty(global, "Array", {})` (the only
            // way to hit this with a placeholder) materializes first
            // through the same getProperty path.
            .auto_init => desc,
        },
        .data => descriptor.Descriptor.data(
            if (desc.value_present) desc.value else switch (current_flags.kind) {
                .data => current_slot.data,
                .var_ref => current_slot.var_ref.varRefValue(),
                .accessor, .auto_init => desc.value,
            },
            desc.writable orelse if (current_flags.isAccessor()) false else current_flags.writable,
            desc.enumerable orelse current_flags.enumerable,
            desc.configurable orelse current_flags.configurable,
        ),
        .accessor => descriptor.Descriptor.accessor(
            if (desc.getter_present) desc.getter else switch (current_flags.kind) {
                .accessor => current_slot.accessor.getterValue(),
                .data, .var_ref, .auto_init => desc.getter,
            },
            if (desc.setter_present) desc.setter else switch (current_flags.kind) {
                .accessor => current_slot.accessor.setterValue(),
                .data, .var_ref, .auto_init => desc.setter,
            },
            desc.enumerable orelse current_flags.enumerable,
            desc.configurable orelse current_flags.configurable,
        ),
    };
}

fn arrayLengthValue(length: u32) JSValue {
    if (length <= @as(u32, @intCast(std.math.maxInt(i32)))) {
        return JSValue.int32(@intCast(length));
    }
    return JSValue.float64(@floatFromInt(length));
}

fn arrayLengthFromValue(rt: *JSRuntime, value: JSValue) !?u32 {
    const number = try arrayLengthNumber(rt, value) orelse return null;
    if (std.math.isNan(number) or !std.math.isFinite(number)) return null;
    if (number < 0 or number > @as(f64, @floatFromInt(array.max_array_length))) return null;
    const truncated = @trunc(number);
    if (truncated != number) return null;
    return @intFromFloat(truncated);
}

fn arrayLengthNumber(rt: *JSRuntime, value: JSValue) !?f64 {
    if (value.asInt32()) |int_value| return @floatFromInt(int_value);
    if (value.asFloat64()) |float_value| return float_value;
    if (value.asBool()) |bool_value| return if (bool_value) 1 else 0;
    if (value.isNull()) return 0;
    if (value.isUndefined() or value.isSymbol() or value.isBigInt()) return null;
    if (value.isString()) return try arrayLengthStringNumber(rt, value);
    if (value.isObject()) {
        const header = value.refHeader() orelse return null;
        const object: *Object = @fieldParentPtr("header", header);
        if (object.class_id == class.ids.string) {
            const data = object.objectData() orelse return null;
            return try arrayLengthStringNumber(rt, data);
        }
        if (object.class_id == class.ids.number or object.class_id == class.ids.boolean) {
            const primitive = (object.objectData() orelse return null).dup();
            defer primitive.free(rt);
            return try arrayLengthNumber(rt, primitive);
        }
    }
    return null;
}

fn arrayLengthStringNumber(rt: *JSRuntime, value: JSValue) !f64 {
    const string_value = value.asStringBody() orelse return std.math.nan(f64);
    try string_value.ensureFlat(rt);
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try bytes.ensureTotalCapacity(rt.memory.allocator, string_value.len());
    var index: usize = 0;
    while (index < string_value.len()) : (index += 1) {
        const unit = string_value.codeUnitAt(index);
        if (unit > 0x7f) return std.math.nan(f64);
        bytes.appendAssumeCapacity(@intCast(unit));
    }
    const trimmed = std.mem.trim(u8, bytes.items, " \t\r\n");
    if (trimmed.len == 0) return 0;
    if (std.mem.eql(u8, trimmed, "Infinity") or std.mem.eql(u8, trimmed, "+Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, trimmed, "-Infinity")) return -std.math.inf(f64);
    if (trimmed.len >= 2 and trimmed[0] == '0' and (trimmed[1] == 'x' or trimmed[1] == 'X')) {
        const parsed = std.fmt.parseUnsigned(u64, trimmed[2..], 16) catch return std.math.nan(f64);
        return @floatFromInt(parsed);
    }
    return std.fmt.parseFloat(f64, trimmed) catch std.math.nan(f64);
}

fn varRefCellFromValue(value: JSValue) ?*var_ref_mod.VarRef {
    return var_ref_mod.VarRef.fromValue(value);
}

fn appendAtom(rt: *JSRuntime, keys: *[]atom.Atom, atom_id: atom.Atom) OwnKeysError!void {
    const next = try rt.allocRuntime(atom.Atom, keys.*.len + 1);
    errdefer rt.memory.free(atom.Atom, next);
    @memcpy(next[0..keys.*.len], keys.*);
    next[keys.*.len] = rt.atoms.dup(atom_id);
    const old = keys.*;
    keys.* = next;
    if (old.len != 0) rt.memory.free(atom.Atom, old);
}

const IndexKey = struct {
    index: u32,
    atom_id: atom.Atom,
};

fn hasPropertyIndexKeys(self: Object, rt: *JSRuntime) bool {
    for (self.shapeProps()) |prop| {
        if (property.Flags.fromBits(prop.flags).deleted) continue;
        const index = array.arrayIndexFromAtom(&rt.atoms, prop.atom_id) orelse continue;
        if (!self.hasDenseArrayElement(index)) return true;
    }
    return false;
}

fn indexKeyLessThan(_: void, lhs: IndexKey, rhs: IndexKey) bool {
    return lhs.index < rhs.index;
}

// --- Object.keys/values/entries own-property iteration ----------------------
//
// `ownEntriesArray` builds the result array for the bare-runtime
// Object.keys/values/entries fallback. Relocated to engine core in Phase 6b-3
// STEP 2 (it is a pure property-iteration constructor with no exec/VM deps);
// `exec/object_builtin_ops.zig` re-exports `EntriesMode`/`ownEntriesArray`
// unchanged for Object native records.

/// Selects which projection `ownEntriesArray` produces.
pub const EntriesMode = enum {
    keys,
    values,
    entries,
};

fn ownEntriesExpectObject(value: JSValue) !*Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    return @fieldParentPtr("header", header);
}

fn entriesAtomToStringValue(rt: *JSRuntime, atom_id: atom.Atom) !JSValue {
    return rt.atoms.toStringValue(rt, atom_id);
}

fn entryArrayValue(rt: *JSRuntime, key: atom.Atom, value: JSValue) !JSValue {
    var rooted_value = value;
    defer rooted_value.free(rt);
    var root_values = [_]runtime_mod.ValueRootValue{
        .{ .value = &rooted_value },
    };
    const root_frame = runtime_mod.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const arr = try Object.createArray(rt, null);
    errdefer Object.destroyFromHeader(rt, &arr.header);
    const key_value = try entriesAtomToStringValue(rt, key);
    defer key_value.free(rt);
    // qjs js_create_array (quickjs.c:9601): pre-sized dense fast array instead of
    // two per-element defineOwnProperty. key_value/rooted_value stay rooted (the
    // root_frame above + the local defer) across the slice alloc; dups precede adopt.
    const elements = try rt.memory.alloc(JSValue, 2);
    elements[0] = key_value.dup();
    elements[1] = rooted_value.dup();
    arr.adoptDenseArrayElementsAssumingEmpty(elements);
    arr.flags.may_have_indexed_properties = true;
    return arr.value();
}

pub fn ownEntriesArray(rt: *JSRuntime, value: JSValue, mode: EntriesMode) !JSValue {
    var rooted_value = value;
    var out_value = JSValue.undefinedValue();
    var element_val = JSValue.undefinedValue();
    var root_values = [_]runtime_mod.ValueRootValue{
        .{ .value = &rooted_value },
        .{ .value = &out_value },
        .{ .value = &element_val },
    };
    const root_frame = runtime_mod.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const object = try ownEntriesExpectObject(rooted_value);
    const owned_keys = try object.ownKeys(rt);
    defer Object.freeKeys(rt, owned_keys);

    const out = try Object.createArray(rt, null);
    out_value = out.value();
    errdefer {
        Object.destroyFromHeader(rt, &out.header);
        out_value = JSValue.undefinedValue();
    }
    var out_index: u32 = 0;
    for (owned_keys) |key| {
        if (rt.atoms.isPublicSymbol(key)) continue;
        const desc = object.getOwnProperty(rt, key) orelse continue;
        defer desc.destroy(rt);
        if (!(desc.enumerable orelse false)) continue;
        element_val = switch (mode) {
            .keys => try entriesAtomToStringValue(rt, key),
            .values => object.getProperty(key),
            .entries => try entryArrayValue(rt, key, object.getProperty(key)),
        };
        defer {
            element_val.free(rt);
            element_val = JSValue.undefinedValue();
        }
        try out.defineOwnProperty(rt, atom.atomFromUInt32(out_index), descriptor.Descriptor.data(element_val, true, true, true));
        out_index += 1;
    }
    return out_value;
}

// --- String Iterator factory ------------------------------------------------
//
// `stringIterator` builds a fresh String Iterator object for a string (or
// String wrapper) receiver. It is the fast-path engine primitive the exec
// iteration machinery (for-of, spread, async-from-sync) uses instead of the
// `String.prototype[Symbol.iterator]` property lookup. Relocated to engine core
// in Phase 6b-3 STEP 6: it is a pure object/native-function constructor that
// touches only core string/object/function primitives (no exec/VM deps and no
// realm/global state). The produced iterator's `next` carries the
// `(.string, iterator_next)` native id, so the actual `next` body still
// dispatches through the record table into `exec/string_builtin_ops.zig`.

/// Extract the primitive string value from a string or String-wrapper receiver.
fn stringIteratorPrimitiveValue(value: JSValue) !JSValue {
    if (value.isString()) return value.dup();
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    const object: *Object = @fieldParentPtr("header", header);
    if (object.class_id != class.ids.string) return error.TypeError;
    return (object.objectData() orelse return error.TypeError).dup();
}

fn defineStringIteratorToStringTag(rt: *JSRuntime, object: *Object, tag_name: []const u8) !void {
    const tag_atom = atom.predefinedId("Symbol.toStringTag", .symbol) orelse return error.TypeError;
    const tag_value = try string.String.createUtf8(rt, tag_name);
    defer tag_value.value().free(rt);
    try object.defineOwnProperty(rt, tag_atom, descriptor.Descriptor.data(tag_value.value(), false, false, true));
}

fn stringIteratorPrototype(rt: *JSRuntime, tag_name: []const u8) !*Object {
    const base = try Object.create(rt, class.ids.object, null);
    var base_raw_owned = true;
    errdefer if (base_raw_owned) Object.destroyFromHeader(rt, &base.header);
    try defineStringIteratorToStringTag(rt, base, "Iterator");
    const specific = try Object.create(rt, class.ids.object, base);
    errdefer Object.destroyFromHeader(rt, &specific.header);
    base_raw_owned = false;
    base.value().free(rt);
    try defineStringIteratorToStringTag(rt, specific, tag_name);
    const next = try function.nativeFunction(rt, "next", 0);
    defer next.free(rt);
    const next_object = (next.refHeader() orelse return error.TypeError);
    if (!next.isObject()) return error.TypeError;
    const next_function: *Object = @fieldParentPtr("header", next_object);
    next_function.setNativeBuiltinIdAndRecord(rt, function.nativeBuiltinId(.string, @intFromEnum(host_function.builtin_method_ids.string.PrototypeMethod.iterator_next)));
    try specific.defineOwnProperty(rt, atom.predefinedId("next", .string).?, descriptor.Descriptor.data(next, true, false, true));
    return specific;
}

pub fn stringIterator(rt: *JSRuntime, receiver: JSValue) !JSValue {
    var rooted_receiver = receiver;
    var target = JSValue.undefinedValue();
    var prototype_value = JSValue.undefinedValue();
    var object_value = JSValue.undefinedValue();
    var root_values = [_]runtime_mod.ValueRootValue{
        .{ .value = &rooted_receiver },
        .{ .value = &target },
        .{ .value = &prototype_value },
        .{ .value = &object_value },
    };
    const root_frame = runtime_mod.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    target = try stringIteratorPrimitiveValue(rooted_receiver);
    defer target.free(rt);
    const prototype = try stringIteratorPrototype(rt, "String Iterator");
    prototype_value = prototype.value();
    defer prototype_value.free(rt);
    const object = try Object.create(rt, class.ids.string_iterator, prototype);
    object_value = object.value();
    errdefer {
        const failed_object = object_value;
        object_value = JSValue.undefinedValue();
        failed_object.free(rt);
    }
    try object.setOptionalValueSlot(rt, object.iteratorTargetSlot(), target.dup());
    object.iteratorIndexSlot().* = 0;
    return object_value;
}

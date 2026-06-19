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
const JSRuntime = runtime_mod.JSRuntime;
const JSValue = @import("value.zig").JSValue;
const function_bytecode_mod = @import("function_bytecode.zig");
const FunctionBytecode = function_bytecode_mod.FunctionBytecode;
const std = @import("std");
const builtin = @import("builtin");

extern "c" fn pclose(stream: *std.c.FILE) c_int;

const ObjectVisitSet = std.AutoHashMap(usize, void);
const ObjectIncomingMap = std.AutoHashMap(usize, usize);
const SymbolRootSet = std.AutoHashMap(atom.Atom, void);
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
    unregister_token: JSValue = JSValue.undefinedValue(),
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
        self.held_value.free(rt);
        self.unregister_token.free(rt);
    }
};

fn destroyOptionalValue(rt: *JSRuntime, slot: *?JSValue) void {
    const old_value = slot.*;
    slot.* = null;
    if (old_value) |stored| stored.free(rt);
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
    promise_already_resolved: bool = false,
    promise_combinator_remaining: i32 = 0,
    realm_global_ptr: ?*Object = null,
    global_lexicals: ?*Object = null,
    shared_lazy_native_functions: ?*[runtime_mod.shared_lazy_native_function_slots]?JSValue = null,

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
        const global_lexicals = self.global_lexicals;
        self.global_lexicals = null;
        if (global_lexicals) |env| {
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
        self.* = .{};
    }
};

pub const IteratorPayload = struct {
    target: ?JSValue = null,
    data: ?JSValue = null,
    next: ?JSValue = null,
    cached_next: ?JSValue = null,
    callback: ?JSValue = null,
    inner_next: ?JSValue = null,
    zip_nexts: ?JSValue = null,
    zip_pads: ?JSValue = null,
    zip_keys: ?JSValue = null,
    atom_keys: []atom.Atom = &.{},
    index: usize = 0,
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
        destroyOptionalValue(rt, &self.cached_next);
        destroyOptionalValue(rt, &self.callback);
        destroyOptionalValue(rt, &self.inner_next);
        destroyOptionalValue(rt, &self.zip_nexts);
        destroyOptionalValue(rt, &self.zip_pads);
        destroyOptionalValue(rt, &self.zip_keys);
        destroyAtomSlice(rt, &self.atom_keys);
    }
};

pub const CollectionPayload = struct {
    entries: []CollectionEntry = &.{},
    entries_capacity: usize = 0,
    bucket_heads: []usize = &.{},
    active_count: usize = 0,
    weak_entries: []WeakCollectionEntry = &.{},
    weak_entries_capacity: usize = 0,
    realm_global_ptr: ?*Object = null,

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
            const prequeued_identity = rt.prequeueBorrowedWeakCleanupIdentityForLastRefValue(entry.value);
            rt.enqueueDeferredWeakValueFreeWithPrequeuedIdentity(entry.value, prequeued_identity) catch |err| switch (err) {
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

pub const RegExpPayload = struct {
    source: ?JSValue = null,
    flags: ?JSValue = null,
    last_index: ?JSValue = null,
    compiled_bytecode: []u8 = &.{},
    fast_pattern_kind: RegExpFastPatternKind = .none,
    fast_simple_class_alternation: RegExpSimpleClassAlternationPattern = .{},
    fast_simple_capture_sequence: RegExpSimpleCaptureSequencePattern = .{},
    last_index_writable: bool = true,
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *RegExpPayload, rt: *JSRuntime) void {
        destroyOptionalValue(rt, &self.source);
        destroyOptionalValue(rt, &self.flags);
        destroyOptionalValue(rt, &self.last_index);
        const old_bytecode = self.compiled_bytecode;
        self.compiled_bytecode = &.{};
        self.fast_pattern_kind = .none;
        self.fast_simple_class_alternation = .{};
        self.fast_simple_capture_sequence = .{};
        if (old_bytecode.len != 0) rt.memory.free(u8, old_bytecode);
    }
};

pub const RegExpFastPatternKind = enum(u8) {
    none,
    simple_class_alternation,
    simple_capture_sequence,
};

pub const RegExpSimpleClassPredicate = enum(u8) {
    generic,
    ascii_digit,
    ascii_not_digit,
    ascii_word,
    ascii_not_word,
    ascii_lower,
    ascii_alpha,
    ascii_decimal,
};

pub const RegExpSimpleClassAtomKind = enum(u8) {
    literal,
    class,
};

pub const RegExpSimpleClassSequenceAtom = struct {
    kind: RegExpSimpleClassAtomKind = .literal,
    literal: u16 = 0,
    class_source: []const u8 = "",
    class_predicate: RegExpSimpleClassPredicate = .generic,
    min_repeat: usize = 1,
    max_repeat: usize = 1,
};

pub const RegExpSimpleClassSequencePattern = struct {
    atoms: [16]RegExpSimpleClassSequenceAtom = undefined,
    len: usize = 0,
    anchor_start: bool = false,
    anchor_end: bool = false,
};

pub const RegExpSimpleClassAlternationPattern = struct {
    alternatives: [8]RegExpSimpleClassSequencePattern = undefined,
    len: usize = 0,
};

pub const RegExpSimpleCaptureSequenceAtom = struct {
    kind: RegExpSimpleClassAtomKind = .literal,
    literal: u16 = 0,
    class_source: []const u8 = "",
    class_predicate: RegExpSimpleClassPredicate = .generic,
    capture_index: ?usize = null,
    min_repeat: usize = 1,
    max_repeat: usize = 1,
};

pub const RegExpSimpleCaptureSequencePattern = struct {
    atoms: [16]RegExpSimpleCaptureSequenceAtom = undefined,
    len: usize = 0,
    capture_count: usize = 0,
    anchor_start: bool = false,
    anchor_end: bool = false,
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
    weak_target_identity: ?usize = null,
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *ObjectDataPayload, rt: *JSRuntime) void {
        destroyOptionalValue(rt, &self.data);
        self.weak_target_identity = null;
    }
};

pub const VarRefPayload = struct {
    value: ?JSValue = null,
    is_const: bool = false,
    is_function_name: bool = false,
    is_deletable: bool = false,
    is_deleted: bool = false,
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
    callsite_prototype,
    count,
};

const realm_value_slot_count: usize = @intFromEnum(RealmValueSlot.count);

pub const RealmPayload = struct {
    cached_function_proto: ?*Object = null,
    cached_promise_proto: ?*Object = null,
    cached_values: [realm_value_slot_count]?JSValue = @splat(null),

    pub fn destroy(self: *RealmPayload, rt: *JSRuntime) void {
        destroyOptionalObjectRef(rt, &self.cached_function_proto);
        destroyOptionalObjectRef(rt, &self.cached_promise_proto);
        destroyOptionalValueSlots(rt, &self.cached_values);
        self.* = .{};
    }
};

pub const ArrayPayload = struct {
    storage_mode: ArrayStorageMode = .dense,
    elements: []?JSValue = &.{},
    elements_capacity: usize = 0,
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *ArrayPayload, rt: *JSRuntime) void {
        destroyOptionalValueSlice(rt, &self.elements, &self.elements_capacity);
        self.storage_mode = .dense;
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

pub const GeneratorPayload = struct {
    bytecode: ?JSValue = null,
    captures: []JSValue = &.{},
    eval_local_names: []atom.Atom = &.{},
    eval_local_refs: []JSValue = &.{},
    home_object: ?*Object = null,
    realm_global_ptr: ?*Object = null,
    this_value: ?JSValue = null,
    args: []JSValue = &.{},
    stack: []JSValue = &.{},
    stack_capacity: usize = 0,
    frame_locals: []JSValue = &.{},
    frame_args: []JSValue = &.{},
    frame_var_refs: []JSValue = &.{},
    frame_locals_uninit: []bool = &.{},
    current_function: ?JSValue = null,
    yield_star_iterator: ?JSValue = null,
    async_promise: ?JSValue = null,
    pc: usize = 0,
    resume_completion_type: i32 = 0,
    done: bool = false,
    executing: bool = false,
    started: bool = false,
    just_yielded: bool = false,
    yield_star_suspended: bool = false,

    pub fn destroy(self: *GeneratorPayload, rt: *JSRuntime) void {
        destroyOptionalValue(rt, &self.bytecode);
        destroyValueSlice(rt, &self.captures);
        destroyAtomSlice(rt, &self.eval_local_names);
        destroyValueSlice(rt, &self.eval_local_refs);
        destroyOptionalObjectRef(rt, &self.home_object);
        destroyOptionalValue(rt, &self.this_value);
        destroyValueSlice(rt, &self.args);
        destroyValueSliceWithCapacity(rt, &self.stack, &self.stack_capacity);
        destroyValueSlice(rt, &self.frame_locals);
        destroyValueSlice(rt, &self.frame_args);
        destroyValueSlice(rt, &self.frame_var_refs);
        const old_frame_locals_uninit = self.frame_locals_uninit;
        self.frame_locals_uninit = &.{};
        if (old_frame_locals_uninit.len != 0) rt.memory.free(bool, old_frame_locals_uninit);
        destroyOptionalValue(rt, &self.current_function);
        destroyOptionalValue(rt, &self.yield_star_iterator);
        destroyOptionalValue(rt, &self.async_promise);
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

pub const FunctionPayload = struct {
    source: ?JSValue = null,
    host_function_kind: i32 = 0,
    native_function_id: i32 = 0,
    external_host_function_id: u32 = 0,
    native_dispatch_name: atom.Atom = atom.null_atom,
    array_builtin_marker: ArrayBuiltinMarker = .none,
    typed_array_builtin_marker: TypedArrayBuiltinMarker = .none,
    array_iterator_kind: u8 = 0,
    iterator_identity: bool = false,
    array_iterator_next: bool = false,
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
    bytecode: ?JSValue = null,
    class_fields_init: ?JSValue = null,
    captures: []JSValue = &.{},
    eval_local_names: []atom.Atom = &.{},
    eval_local_refs: []JSValue = &.{},
    eval_parent_function: ?JSValue = null,
    import_meta: ?JSValue = null,
    lexical_this: ?JSValue = null,
    arrow_constructor_this: ?JSValue = null,
    arrow_new_target: ?JSValue = null,
    super_constructor: ?JSValue = null,
    home_object: ?*Object = null,
    private_remap_from: []atom.Atom = &.{},
    private_remap_to: []atom.Atom = &.{},
    realm_global: ?JSValue = null,
    realm_global_ptr: ?*Object = null,
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
    realm_type_error_constructor: ?JSValue = null,
    regexp_legacy_statics: ?*RegExpLegacyStatics = null,

    pub fn destroy(self: *FunctionPayload, rt: *JSRuntime) void {
        destroyOptionalValue(rt, &self.source);
        destroyOptionalValue(rt, &self.bytecode);
        destroyOptionalValue(rt, &self.class_fields_init);
        const native_dispatch_name = self.native_dispatch_name;
        self.native_dispatch_name = atom.null_atom;
        rt.atoms.free(native_dispatch_name);
        destroyValueSlice(rt, &self.captures);
        destroyAtomSlice(rt, &self.eval_local_names);
        destroyValueSlice(rt, &self.eval_local_refs);
        destroyOptionalValue(rt, &self.eval_parent_function);
        destroyOptionalValue(rt, &self.import_meta);
        destroyOptionalValue(rt, &self.lexical_this);
        destroyOptionalValue(rt, &self.arrow_constructor_this);
        destroyOptionalValue(rt, &self.arrow_new_target);
        destroyOptionalValue(rt, &self.super_constructor);
        destroyOptionalObjectRef(rt, &self.home_object);
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
        const legacy_statics = self.regexp_legacy_statics;
        self.regexp_legacy_statics = null;
        if (legacy_statics) |legacy| {
            legacy.destroy(rt);
            rt.memory.destroy(RegExpLegacyStatics, legacy);
        }
        destroyOptionalValueSlots(rt, &self.primitive_prototypes);
        self.* = .{};
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

pub fn destroyDetachedClassPayload(rt: *JSRuntime, payload_kind: class.PayloadKind, payload: *class.Payload) void {
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
        .var_ref => {
            const typed: *VarRefPayload = @ptrCast(@alignCast(ptr));
            typed.destroy(rt);
            rt.memory.destroy(VarRefPayload, typed);
        },
        .array => {
            const typed: *ArrayPayload = @ptrCast(@alignCast(ptr));
            typed.destroy(rt);
            rt.memory.destroy(ArrayPayload, typed);
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
            typed.destroy(rt);
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
    null_prototype: bool = false,
    extensible: bool = true,
    immutable_prototype: bool = false,
    is_array: bool = false,
    is_proxy: bool = false,
    is_global: bool = false,
    is_html_dda: bool = false,
    may_have_indexed_properties: bool = false,
    length_writable: bool = true,
    is_with_environment: bool = false,
    is_prototype: bool = false,
    reserved_class_payload_finalizer_slot: bool = false,
    /// Set once the object has been assigned a weak id in the runtime's weak
    /// identity registry, so destruction can skip the registry lookup for the
    /// common case of objects that were never weakly referenced.
    has_weak_id: bool = false,
    is_borrowed_reference_holder: bool = false,
    _padding: u2 = 0,
};

pub const Object = struct {
    header: gc.GCObjectHeader,
    gc: gc.GcNode = .{},
    class_id: class.ClassId,
    class_payload: class.Payload = null,
    class_payload_kind: class.PayloadKind = .none,
    owner_runtime: *JSRuntime,
    shape_ref: *shape.Shape,
    prototype: ?*Object = null,
    flags: ObjectFlags = .{},
    length: u32 = 0,
    properties: []property.Entry = &.{},

    property_capacity: usize = 0,
    exotic: ?*ExoticMethods = null,

    pub fn expect(val: JSValue) !*Object {
        const header = val.refHeader() orelse return error.TypeError;
        if (!val.isObject()) return error.TypeError;
        return @fieldParentPtr("header", header);
    }

    pub fn create(rt: *JSRuntime, class_id: class.ClassId, prototype: ?*Object) !*Object {
        return createInternal(rt, class_id, prototype, 0);
    }

    pub fn createWithOwnPropertyCapacity(rt: *JSRuntime, class_id: class.ClassId, prototype: ?*Object, capacity: usize) !*Object {
        return createInternal(rt, class_id, prototype, capacity);
    }

    fn createInternal(rt: *JSRuntime, class_id: class.ClassId, prototype: ?*Object, own_property_capacity: usize) !*Object {
        const class_record = rt.classes.record(class_id);
        const inline_layout = inlineClassPayloadLayout(class_record);
        const self = if (inline_layout) |layout| blk: {
            const bytes = try rt.memory.allocAlignedBytes(layout.total_size, layout.allocation_alignment);
            break :blk @as(*Object, @ptrCast(@alignCast(bytes.ptr)));
        } else try rt.memory.create(Object);
        var initialized = false;
        errdefer {
            if (initialized) {
                destroyFromHeader(rt, &self.header);
            } else {
                freeObjectAllocation(rt, self, inline_layout);
            }
        }
        const proto_id = if (prototype) |proto| @intFromPtr(proto) else null;
        // qjs shape model (faithful): start from the SHARED, transition-cacheable
        // empty root shape (qjs hash-consed shapes) so objects adding the same
        // properties converge on one shared shape via cached transitions, instead
        // of each getting a fresh unique shape mutated in place (the old
        // createObjectRootWithPropertyCapacity → ~1:1 shapes + per-object
        // appendProperty/rehashShape). The property VALUE array is still
        // pre-reserved below; only the SHAPE is shared.
        const shape_ref = try rt.shapes.createObjectRoot(proto_id);
        var shape_owned = true;
        errdefer if (shape_owned) rt.shapes.release(shape_ref);
        var property_storage: []property.Entry = &.{};
        var property_storage_owned = false;
        errdefer if (property_storage_owned) rt.memory.free(property.Entry, property_storage);
        if (own_property_capacity != 0) {
            property_storage = try rt.memory.alloc(property.Entry, own_property_capacity);
            property_storage_owned = true;
        }
        var class_payload: class.Payload = null;
        var class_payload_kind: class.PayloadKind = .none;
        const payload_kind = if (class_record) |record|
            record.payload_kind
        else
            class.standardPayloadKind(class_id);
        switch (payload_kind) {
            .iterator => {
                const payload = try rt.memory.create(IteratorPayload);
                errdefer rt.memory.destroy(IteratorPayload, payload);
                payload.* = .{};
                class_payload = @ptrCast(payload);
                class_payload_kind = .iterator;
            },
            .collection => {
                const payload = try rt.memory.create(CollectionPayload);
                errdefer rt.memory.destroy(CollectionPayload, payload);
                payload.* = .{};
                class_payload = @ptrCast(payload);
                class_payload_kind = .collection;
            },
            .buffer => {
                const payload = try rt.memory.create(BufferPayload);
                errdefer rt.memory.destroy(BufferPayload, payload);
                payload.* = .{};
                class_payload = @ptrCast(payload);
                class_payload_kind = .buffer;
            },
            .typed_array => {
                const payload = try rt.memory.create(TypedArrayPayload);
                errdefer rt.memory.destroy(TypedArrayPayload, payload);
                payload.* = .{};
                class_payload = @ptrCast(payload);
                class_payload_kind = .typed_array;
            },
            .regexp => {
                const payload = try rt.memory.create(RegExpPayload);
                errdefer rt.memory.destroy(RegExpPayload, payload);
                payload.* = .{};
                class_payload = @ptrCast(payload);
                class_payload_kind = .regexp;
            },
            .bound_function => {
                const payload = try rt.memory.create(BoundFunctionPayload);
                errdefer rt.memory.destroy(BoundFunctionPayload, payload);
                payload.* = .{};
                class_payload = @ptrCast(payload);
                class_payload_kind = .bound_function;
            },
            .proxy => {
                const payload = try rt.memory.create(ProxyPayload);
                errdefer rt.memory.destroy(ProxyPayload, payload);
                payload.* = .{};
                class_payload = @ptrCast(payload);
                class_payload_kind = .proxy;
            },
            .arguments => {
                const payload = try rt.memory.create(ArgumentsPayload);
                errdefer rt.memory.destroy(ArgumentsPayload, payload);
                payload.* = .{};
                class_payload = @ptrCast(payload);
                class_payload_kind = .arguments;
            },
            .object_data => {
                const payload = try rt.memory.create(ObjectDataPayload);
                errdefer rt.memory.destroy(ObjectDataPayload, payload);
                payload.* = .{};
                class_payload = @ptrCast(payload);
                class_payload_kind = .object_data;
            },
            .var_ref => {
                const payload = try rt.memory.create(VarRefPayload);
                errdefer rt.memory.destroy(VarRefPayload, payload);
                payload.* = .{};
                class_payload = @ptrCast(payload);
                class_payload_kind = .var_ref;
            },
            .array => {
                const payload = try rt.memory.create(ArrayPayload);
                errdefer rt.memory.destroy(ArrayPayload, payload);
                payload.* = .{};
                class_payload = @ptrCast(payload);
                class_payload_kind = .array;
            },
            .promise => {
                const payload = try rt.memory.create(PromisePayload);
                errdefer rt.memory.destroy(PromisePayload, payload);
                payload.* = .{};
                class_payload = @ptrCast(payload);
                class_payload_kind = .promise;
            },
            .generator => {
                const payload = try rt.memory.create(GeneratorPayload);
                errdefer rt.memory.destroy(GeneratorPayload, payload);
                payload.* = .{};
                class_payload = @ptrCast(payload);
                class_payload_kind = .generator;
            },
            .function => {
                const payload = try rt.memory.create(FunctionPayload);
                errdefer rt.memory.destroy(FunctionPayload, payload);
                payload.* = .{};
                class_payload = @ptrCast(payload);
                class_payload_kind = .function;
            },
            .module_namespace => {
                const payload = try rt.memory.create(ModuleNamespacePayload);
                errdefer rt.memory.destroy(ModuleNamespacePayload, payload);
                payload.* = .{};
                class_payload = @ptrCast(payload);
                class_payload_kind = .module_namespace;
            },
            .finalization_registry => {
                const payload = try rt.memory.create(FinalizationRegistryPayload);
                errdefer rt.memory.destroy(FinalizationRegistryPayload, payload);
                payload.* = .{};
                class_payload = @ptrCast(payload);
                class_payload_kind = .finalization_registry;
            },
            .std_file => {
                const payload = try rt.memory.create(StdFilePayload);
                errdefer rt.memory.destroy(StdFilePayload, payload);
                payload.* = .{};
                class_payload = @ptrCast(payload);
                class_payload_kind = .std_file;
            },
            .disposable_stack => {
                const payload = try rt.memory.create(DisposableStackPayload);
                errdefer rt.memory.destroy(DisposableStackPayload, payload);
                payload.* = .{};
                class_payload = @ptrCast(payload);
                class_payload_kind = .disposable_stack;
            },
            else => {},
        }
        if (inline_layout) |layout| {
            class_payload = inlineClassPayloadPtr(self, layout);
            class_payload_kind = .none;
        }
        var reserved_class_payload_finalizer_slot = false;
        errdefer if (reserved_class_payload_finalizer_slot) rt.releaseDeferredClassPayloadFinalizerSlot();
        if (class_record) |record| {
            if (record.payload_finalizer != null and !record.hasInlinePayload()) {
                try rt.reserveDeferredClassPayloadFinalizerSlot();
                reserved_class_payload_finalizer_slot = true;
            }
        }
        if (prototype) |proto| {
            gc.retain(&proto.header);
            proto.flags.is_prototype = true;
            if (proto.flags.may_have_indexed_properties) {
                rt.any_prototype_may_have_indexed_properties = true;
            }
        }
        self.* = .{
            .header = .{ .kind = .object },
            .class_id = class_id,
            .class_payload = class_payload,
            .class_payload_kind = class_payload_kind,
            .owner_runtime = rt,
            .flags = .{ .reserved_class_payload_finalizer_slot = reserved_class_payload_finalizer_slot },
            .shape_ref = shape_ref,
            .prototype = prototype,
            .properties = property_storage[0..0],
            .property_capacity = own_property_capacity,
        };
        property_storage_owned = false;
        reserved_class_payload_finalizer_slot = false;
        shape_owned = false;
        initialized = true;
        try rt.registerObject(self);
        initialized = false;
        return self;
    }

    const InlineClassPayloadLayout = struct {
        payload_offset: usize,
        total_size: usize,
        allocation_alignment: std.mem.Alignment,
    };

    fn inlineClassPayloadLayout(maybe_record: ?class.Record) ?InlineClassPayloadLayout {
        const record = maybe_record orelse return null;
        if (!record.hasInlinePayload()) return null;
        const payload_align = std.mem.Alignment.fromByteUnits(record.inline_payload_align);
        const object_align = std.mem.Alignment.of(Object);
        const allocation_alignment = if (payload_align.compare(.gt, object_align)) payload_align else object_align;
        const payload_offset = std.mem.alignForward(usize, @sizeOf(Object), payload_align.toByteUnits());
        const total_size = std.math.add(usize, payload_offset, record.inline_payload_size) catch return null;
        return .{
            .payload_offset = payload_offset,
            .total_size = total_size,
            .allocation_alignment = allocation_alignment,
        };
    }

    fn inlineClassPayloadPtr(self: *Object, layout: InlineClassPayloadLayout) *anyopaque {
        const bytes: [*]u8 = @ptrCast(self);
        return @ptrCast(bytes + layout.payload_offset);
    }

    fn freeObjectAllocation(rt: *JSRuntime, self: *Object, inline_layout: ?InlineClassPayloadLayout) void {
        if (inline_layout) |layout| {
            const bytes: [*]u8 = @ptrCast(self);
            rt.memory.freeAlignedBytes(bytes[0..layout.total_size], layout.allocation_alignment);
            return;
        }
        rt.memory.destroy(Object, self);
    }

    pub fn allocationSize(self: *const Object, rt: *JSRuntime) usize {
        if (inlineClassPayloadLayout(rt.classes.record(self.class_id))) |layout| return layout.total_size;
        return @sizeOf(Object);
    }

    pub fn createArray(rt: *JSRuntime, prototype: ?*Object) !*Object {
        const self = try create(rt, class.ids.array, prototype);
        self.flags.is_array = true;
        return self;
    }

    pub fn createArrayWithOwnPropertyCapacity(rt: *JSRuntime, prototype: ?*Object, capacity: usize) !*Object {
        const self = try createWithOwnPropertyCapacity(rt, class.ids.array, prototype, capacity);
        self.flags.is_array = true;
        return self;
    }

    pub fn value(self: *Object) JSValue {
        return JSValue.object(&self.header);
    }

    pub fn cachedIteratorNextSlot(self: *Object) *?JSValue {
        if (self.iteratorPayload()) |payload| return &payload.cached_next;
        std.debug.assert(self.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn cachedIteratorNext(self: *const Object) ?JSValue {
        if (self.iteratorPayloadConst()) |payload| return payload.cached_next;
        return null;
    }

    pub fn clearCachedIteratorNext(self: *Object, rt: *JSRuntime) void {
        if (self.iteratorPayload()) |payload| {
            const old_cached = payload.cached_next;
            payload.cached_next = null;
            if (old_cached) |stored| stored.free(rt);
        }
    }

    pub fn ensureSharedLazyNativeFunctionCache(self: *Object, rt: *JSRuntime) !void {
        const payload = try self.ensureOrdinaryPayload(rt);
        if (payload.shared_lazy_native_functions != null) return;
        const cache = try rt.memory.create([runtime_mod.shared_lazy_native_function_slots]?JSValue);
        cache.* = @splat(null);
        payload.shared_lazy_native_functions = cache;
    }

    pub fn ensureOrdinaryPayload(self: *Object, rt: *JSRuntime) !*OrdinaryPayload {
        if (self.ordinaryPayload()) |payload| return payload;
        std.debug.assert(self.class_payload == null);
        const payload = try rt.memory.create(OrdinaryPayload);
        payload.* = .{};
        self.class_payload = @ptrCast(payload);
        self.class_payload_kind = .ordinary;
        return payload;
    }

    pub fn globalLexicals(self: *const Object) ?*Object {
        return if (self.ordinaryPayloadConst()) |payload| payload.global_lexicals else null;
    }

    pub fn setGlobalLexicals(self: *Object, rt: *JSRuntime, v: ?*Object) !void {
        (try self.ensureOrdinaryPayload(rt)).global_lexicals = v;
    }

    pub fn ensureRealmPayload(self: *Object, rt: *JSRuntime) !*RealmPayload {
        if (self.realmPayload()) |payload| return payload;
        const payload = try rt.memory.create(RealmPayload);
        payload.* = .{};
        self.class_payload = @ptrCast(payload);
        self.class_payload_kind = .realm;
        return payload;
    }

    pub fn installExternalClassPayload(self: *Object, payload: *anyopaque) void {
        std.debug.assert(self.class_payload == null);
        self.class_payload = payload;
        self.class_payload_kind = .none;
    }

    pub fn externalClassPayload(self: *Object) ?*anyopaque {
        if (self.class_payload_kind != .none) return null;
        return self.class_payload;
    }

    pub fn externalClassPayloadConst(self: *const Object) ?*anyopaque {
        if (self.class_payload_kind != .none) return null;
        return self.class_payload;
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
        const payload = self.ordinaryPayload() orelse return null;
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

        const job = rt.memory.create(DeferredStdFileClose) catch {
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
        rt.unregisterObject(self);
        clearBorrowedReferencesForDestroyedObject(rt, self);
        self.enqueueDeferredStdFileClose(rt);
        if (!self.finalizeInlineClassPayload(rt)) self.enqueueClassPayloadFinalizer(rt);
        const old_properties = self.properties;
        const old_property_capacity = self.property_capacity;
        const old_shape_props = self.shape_ref.props[0..@min(self.shape_ref.prop_count, old_properties.len)];
        self.properties = &.{};
        self.property_capacity = 0;
        for (old_properties, 0..) |entry, index| {
            const entry_atom = if (index < old_shape_props.len) old_shape_props[index].atom_id else atom.null_atom;
            destroyPropertySlot(rt, entry_atom, entry.slot);
        }
        if (old_property_capacity != 0) rt.memory.free(property.Entry, old_properties.ptr[0..old_property_capacity]);
        self.destroyOrdinaryPayload(rt);
        self.destroyArrayPayload(rt);
        self.destroyBufferPayload(rt);
        self.destroyTypedArrayPayload(rt);
        self.destroyObjectDataPayload(rt);
        self.destroyVarRefPayload(rt);
        self.destroyFunctionPayload(rt);
        self.destroyBoundFunctionPayload(rt);
        self.destroyCollectionPayload(rt);
        self.destroyIteratorPayload(rt);
        self.destroyGeneratorPayload(rt);
        self.destroyArgumentsPayload(rt);
        self.destroyProxyPayload(rt);
        self.destroyModuleNamespacePayload(rt);
        self.destroyFinalizationRegistryPayload(rt);
        self.destroyStdFilePayload(rt);
        self.destroyDisposableStackPayload(rt);
        self.destroyRealmPayload(rt);
        self.destroyPromisePayload(rt);
        self.destroyRegExpPayload(rt);
        if (self.exotic) |ex| {
            self.exotic = null;
            rt.memory.destroy(ExoticMethods, ex);
        }
        const old_prototype = self.prototype;
        self.prototype = null;
        if (old_prototype) |proto| {
            if (rt.gc.phase != .deinit) proto.value().free(rt);
        }
        rt.shapes.release(self.shape_ref);
        freeObjectAllocation(rt, self, inlineClassPayloadLayout(rt.classes.record(self.class_id)));
    }

    fn finalizeInlineClassPayload(self: *Object, rt: *JSRuntime) bool {
        const record = rt.classes.record(self.class_id) orelse return false;
        if (!record.hasInlinePayload()) return false;
        const finalizer = record.payload_finalizer orelse {
            self.class_payload = null;
            self.class_payload_kind = .none;
            return true;
        };
        finalizer(@ptrCast(rt), @ptrCast(self), &self.class_payload);
        self.class_payload = null;
        self.class_payload_kind = .none;
        return true;
    }

    fn enqueueClassPayloadFinalizer(self: *Object, rt: *JSRuntime) void {
        if (!self.flags.reserved_class_payload_finalizer_slot) return;
        const payload = self.class_payload;
        const payload_kind = self.class_payload_kind;
        const object_identity = @intFromPtr(&self.header) & ~@as(usize, 1);
        self.flags.reserved_class_payload_finalizer_slot = false;
        const enqueued = rt.enqueueReservedDeferredClassPayloadFinalizer(self.class_id, payload, payload_kind, object_identity);
        if (!enqueued) return;
        self.class_payload = null;
        self.class_payload_kind = .none;
    }

    fn clearBorrowedReferencesForDestroyedObject(rt: *JSRuntime, destroyed: *Object) void {
        if (rt.gc.phase == .deinit) return;
        // The address identity drives realm-global clearing (and the OOM
        // fallback for realm identities); the registered weak identity, if
        // any, drives weak slot invalidation. Taking the weak identity here
        // removes the registry entry so stale ids can never resolve again.
        const destroyed_identity = @intFromPtr(&destroyed.header) & ~@as(usize, 1);
        const weak_identity = rt.takeWeakObjectIdentity(destroyed);
        if (rt.borrowed_reference_holders.len == 0) return;
        if (weak_identity == null and !destroyed.flags.is_global) return;
        if (rt.borrowedWeakCleanupActive()) {
            if (destroyed.flags.is_global) rt.enqueueBorrowedWeakCleanupRealmIdentity(destroyed_identity);
            if (rt.isCurrentDeferredWeakValueFreeIdentity(destroyed_identity)) return;
            rt.enqueueBorrowedWeakCleanupIdentity(destroyed_identity) catch {
                clearBorrowedReferencesForDestroyedIdentity(rt, destroyed_identity);
            };
            if (weak_identity) |identity| {
                rt.enqueueBorrowedWeakCleanupIdentity(identity) catch {
                    clearBorrowedReferencesForDestroyedIdentity(rt, identity);
                };
            }
            return;
        }

        rt.beginBorrowedWeakCleanup();
        defer rt.endBorrowedWeakCleanup();
        if (destroyed.flags.is_global) rt.enqueueBorrowedWeakCleanupRealmIdentity(destroyed_identity);
        rt.enqueueBorrowedWeakCleanupIdentity(destroyed_identity) catch {
            clearBorrowedReferencesForDestroyedIdentity(rt, destroyed_identity);
        };
        if (weak_identity) |identity| {
            rt.enqueueBorrowedWeakCleanupIdentity(identity) catch {
                clearBorrowedReferencesForDestroyedIdentity(rt, identity);
            };
        }

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
            if (current.header.rc == 0) {
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
            if (current.header.rc != 0 and current.hasBorrowedReferences()) {
                if (write_index != read_index) rt.borrowed_reference_holders[write_index] = current;
                write_index += 1;
                continue;
            }
            current.flags.is_borrowed_reference_holder = false;
        }
        rt.borrowed_reference_holders = rt.borrowed_reference_holders.ptr[0..write_index];
    }

    fn runtimeBorrowedReferenceHolderIndex(rt: *JSRuntime, object: *Object) ?usize {
        if (!object.flags.is_borrowed_reference_holder) return null;
        for (rt.borrowed_reference_holders, 0..) |candidate, index| {
            if (candidate == object) return index;
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
        if (!self.hasBorrowedReferences()) rt.unregisterBorrowedReferenceHolder(self);
    }

    fn hasBorrowedReferences(self: *const Object) bool {
        if (self.objectDataPayloadConst()) |payload| {
            if (payload.weak_target_identity != null) return true;
        }
        if (self.collectionPayloadConst()) |payload| {
            if (payload.weak_entries.len != 0) return true;
        }
        if (self.finalizationRegistryPayloadConst()) |payload| {
            if (payload.cells.len != 0) return true;
        }
        if (self.functionRealmGlobalPtr() != null) return true;
        for (self.properties) |entry| {
            switch (entry.slot) {
                .auto_init => |id| {
                    const info = property.autoInitAt(self.owner_runtime, id).*;
                    if (info.host_function_realm_global != 0) return true;
                },
                else => {},
            }
        }
        return false;
    }

    fn mayContainBorrowedReferences(self: *const Object, rt: *JSRuntime) bool {
        if (self.objectDataPayloadConst()) |payload| {
            if (payload.weak_target_identity != null) return true;
        }
        if (self.collectionPayloadConst()) |payload| {
            if (payload.weak_entries.len != 0) return true;
        }
        if (self.finalizationRegistryPayloadConst()) |payload| {
            if (payload.cells.len != 0) return true;
        }
        if (rt.borrowedWeakCleanupMayMatchRealmIdentity()) {
            if (self.functionRealmGlobalPtr()) |realm_global| {
                const identity = @intFromPtr(&realm_global.header) & ~@as(usize, 1);
                if (rt.borrowedWeakCleanupRealmIdentityMatches(identity)) return true;
            }
            for (self.properties) |entry| {
                switch (entry.slot) {
                    .auto_init => |id| {
                        const info = property.autoInitAt(rt, id).*;
                        if (info.host_function_realm_global != 0 and rt.borrowedWeakCleanupRealmIdentityMatches(info.host_function_realm_global)) return true;
                    },
                    else => {},
                }
            }
        }
        return false;
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
        if (self.objectDataPayload()) |payload| {
            if (payload.weak_target_identity) |identity| {
                if (matcher.matches(rt, identity)) payload.weak_target_identity = null;
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
        const prequeued_identity = prequeueBorrowedWeakCleanupIdentityForOwnedValue(rt, entry.value);
        rt.enqueueDeferredWeakValueFreeWithPrequeuedIdentity(entry.value, prequeued_identity) catch |err| switch (err) {
            error.OutOfMemory => entry.value.free(rt),
        };
    }

    fn prequeueBorrowedWeakCleanupIdentityForOwnedValue(rt: *JSRuntime, stored_value: JSValue) ?usize {
        return rt.prequeueBorrowedWeakCleanupIdentityForLastRefValue(stored_value);
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
        if (self.varRefPayload()) |payload| clearObjectPtr(&payload.realm_global_ptr, rt, matcher);
        if (self.finalizationRegistryPayload()) |payload| clearObjectPtr(&payload.realm_global_ptr, rt, matcher);
        if (self.stdFilePayload()) |payload| clearObjectPtr(&payload.realm_global_ptr, rt, matcher);
        if (self.disposableStackPayload()) |payload| clearObjectPtr(&payload.realm_global_ptr, rt, matcher);
        if (self.arrayPayload()) |payload| clearObjectPtr(&payload.realm_global_ptr, rt, matcher);
        if (self.promisePayload()) |payload| clearObjectPtr(&payload.realm_global_ptr, rt, matcher);
        if (self.generatorPayload()) |payload| clearObjectPtr(&payload.realm_global_ptr, rt, matcher);
        if (self.functionPayload()) |payload| clearObjectPtr(&payload.realm_global_ptr, rt, matcher);
        if (self.moduleNamespacePayload()) |payload| clearObjectPtr(&payload.realm_global_ptr, rt, matcher);
    }

    fn clearObjectPtr(slot: *?*Object, rt: *JSRuntime, matcher: BorrowedIdentityMatcher) void {
        if (slot.*) |stored| {
            const identity = @intFromPtr(&stored.header) & ~@as(usize, 1);
            if (matcher.matches(rt, identity)) slot.* = null;
        }
    }

    fn clearAutoInitRealmGlobals(self: *Object, rt: *JSRuntime, matcher: BorrowedIdentityMatcher) void {
        for (self.properties) |*entry| {
            switch (entry.slot) {
                .auto_init => |id| {
                    const info = property.autoInitAt(rt, id);
                    if (matcher.matches(rt, info.host_function_realm_global)) info.host_function_realm_global = 0;
                },
                else => {},
            }
        }
    }

    pub const post_a_object_size_baseline: usize = 224;
    comptime {
        std.debug.assert(@sizeOf(Object) <= post_a_object_size_baseline / 2);
    }

    pub fn iteratorTargetSlot(self: *Object) *?JSValue {
        if (self.iteratorPayload()) |payload| return &payload.target;
        std.debug.assert(self.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorTarget(self: *const Object) ?JSValue {
        if (self.iteratorPayloadConst()) |payload| return payload.target;
        return null;
    }

    pub fn iteratorDataSlot(self: *Object) *?JSValue {
        if (self.iteratorPayload()) |payload| return &payload.data;
        std.debug.assert(self.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorData(self: *const Object) ?JSValue {
        if (self.iteratorPayloadConst()) |payload| return payload.data;
        return null;
    }

    pub fn iteratorNextSlot(self: *Object) *?JSValue {
        if (self.iteratorPayload()) |payload| return &payload.next;
        std.debug.assert(self.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorNext(self: *const Object) ?JSValue {
        if (self.iteratorPayloadConst()) |payload| return payload.next;
        return null;
    }

    pub fn iteratorCallbackSlot(self: *Object) *?JSValue {
        if (self.iteratorPayload()) |payload| return &payload.callback;
        std.debug.assert(self.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorCallback(self: *const Object) ?JSValue {
        if (self.iteratorPayloadConst()) |payload| return payload.callback;
        return null;
    }

    pub fn iteratorInnerNextSlot(self: *Object) *?JSValue {
        if (self.iteratorPayload()) |payload| return &payload.inner_next;
        std.debug.assert(self.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorInnerNext(self: *const Object) ?JSValue {
        if (self.iteratorPayloadConst()) |payload| return payload.inner_next;
        return null;
    }

    pub fn iteratorZipNextsSlot(self: *Object) *?JSValue {
        if (self.iteratorPayload()) |payload| return &payload.zip_nexts;
        std.debug.assert(self.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorZipNexts(self: *const Object) ?JSValue {
        if (self.iteratorPayloadConst()) |payload| return payload.zip_nexts;
        return null;
    }

    pub fn iteratorZipPadsSlot(self: *Object) *?JSValue {
        if (self.iteratorPayload()) |payload| return &payload.zip_pads;
        std.debug.assert(self.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorZipPads(self: *const Object) ?JSValue {
        if (self.iteratorPayloadConst()) |payload| return payload.zip_pads;
        return null;
    }

    pub fn iteratorZipKeysSlot(self: *Object) *?JSValue {
        if (self.iteratorPayload()) |payload| return &payload.zip_keys;
        std.debug.assert(self.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorZipKeys(self: *const Object) ?JSValue {
        if (self.iteratorPayloadConst()) |payload| return payload.zip_keys;
        return null;
    }

    pub fn iteratorAtomKeysSlot(self: *Object) *[]atom.Atom {
        if (self.iteratorPayload()) |payload| return &payload.atom_keys;
        std.debug.assert(self.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorAtomKeys(self: *const Object) []const atom.Atom {
        if (self.iteratorPayloadConst()) |payload| return payload.atom_keys;
        return &.{};
    }

    pub fn iteratorIndexSlot(self: *Object) *usize {
        if (self.iteratorPayload()) |payload| return &payload.index;
        std.debug.assert(self.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorKindSlot(self: *Object) *u8 {
        if (self.iteratorPayload()) |payload| return &payload.kind;
        std.debug.assert(self.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorZipAliveSlot(self: *Object) *usize {
        if (self.iteratorPayload()) |payload| return &payload.zip_alive;
        std.debug.assert(self.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorZipModeSlot(self: *Object) *u8 {
        if (self.iteratorPayload()) |payload| return &payload.zip_mode;
        std.debug.assert(self.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorZipStateSlot(self: *Object) *u8 {
        if (self.iteratorPayload()) |payload| return &payload.zip_state;
        std.debug.assert(self.class_payload_kind == .iterator);
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
        std.debug.assert(self.class_payload_kind == .collection);
        unreachable;
    }

    pub fn collectionEntries(self: *const Object) []CollectionEntry {
        if (self.collectionPayloadConst()) |payload| return payload.entries;
        return &.{};
    }

    pub fn collectionEntriesCapacitySlot(self: *Object) *usize {
        if (self.collectionPayload()) |payload| return &payload.entries_capacity;
        std.debug.assert(self.class_payload_kind == .collection);
        unreachable;
    }

    pub fn collectionEntriesCapacity(self: *const Object) usize {
        if (self.collectionPayloadConst()) |payload| return payload.entries_capacity;
        return 0;
    }

    pub fn collectionBucketHeadsSlot(self: *Object) *[]usize {
        if (self.collectionPayload()) |payload| return &payload.bucket_heads;
        std.debug.assert(self.class_payload_kind == .collection);
        unreachable;
    }

    pub fn collectionBucketHeads(self: *const Object) []usize {
        if (self.collectionPayloadConst()) |payload| return payload.bucket_heads;
        return &.{};
    }

    pub fn collectionActiveCountSlot(self: *Object) *usize {
        if (self.collectionPayload()) |payload| return &payload.active_count;
        std.debug.assert(self.class_payload_kind == .collection);
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

        const next = try rt.memory.alloc(CollectionEntry, next_capacity);
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
        std.debug.assert(self.class_payload_kind == .collection);
        unreachable;
    }

    pub fn weakCollectionEntries(self: *const Object) []WeakCollectionEntry {
        if (self.collectionPayloadConst()) |payload| return payload.weak_entries;
        return &.{};
    }

    pub fn ensureWeakCollectionEntryCapacity(self: *Object, rt: *JSRuntime, min_capacity: usize) !void {
        const payload = self.collectionPayload() orelse {
            std.debug.assert(self.class_payload_kind == .collection);
            unreachable;
        };
        const entries_slot = self.weakCollectionEntriesSlot();
        if (payload.weak_entries_capacity >= min_capacity) return;

        var next_capacity = if (payload.weak_entries_capacity != 0) payload.weak_entries_capacity else entries_slot.*.len;
        if (next_capacity < 4) next_capacity = 4;
        while (next_capacity < min_capacity) next_capacity *= 2;

        const next = try rt.memory.alloc(WeakCollectionEntry, next_capacity);
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
        std.debug.assert(self.class_payload_kind == .finalization_registry);
        unreachable;
    }

    pub fn finalizationRegistryCleanupCallback(self: *const Object) ?JSValue {
        if (self.finalizationRegistryPayloadConst()) |payload| return payload.cleanup_callback;
        return null;
    }

    pub fn finalizationRegistryCellsSlot(self: *Object) *[]FinalizationRegistryCell {
        if (self.finalizationRegistryPayload()) |payload| return &payload.cells;
        std.debug.assert(self.class_payload_kind == .finalization_registry);
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
        const token_stable = token.dup();
        defer token_stable.free(rt);

        const entries = self.finalizationRegistryCellsSlot();
        var removed = false;
        var index: usize = 0;
        while (index < entries.*.len) {
            const entry = &entries.*[index];
            if (!entry.isActive()) {
                index += 1;
                continue;
            }
            if (!entry.unregister_token.same(token_stable)) {
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
            std.debug.assert(self.class_payload_kind == .finalization_registry);
            unreachable;
        };
        if (payload.cells_capacity >= min_capacity) return;

        var next_capacity = if (payload.cells_capacity != 0) payload.cells_capacity else payload.cells.len;
        if (next_capacity < 4) next_capacity = 4;
        while (next_capacity < min_capacity) next_capacity *= 2;

        const next = try rt.memory.alloc(FinalizationRegistryCell, next_capacity);
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
        const entries = self.finalizationRegistryCellsSlot();
        const index = entries.*.len;
        const inserted_holder = !rt.borrowedReferenceHolderRegistered(self);
        try rt.registerBorrowedReferenceHolder(self);
        errdefer if (inserted_holder) rt.unregisterBorrowedReferenceHolder(self);
        try self.ensureFinalizationRegistryCellCapacity(rt, index + 1);
        const refreshed_entries = self.finalizationRegistryCellsSlot();
        refreshed_entries.* = refreshed_entries.*.ptr[0 .. index + 1];
        errdefer refreshed_entries.* = refreshed_entries.*[0..index];
        refreshed_entries.*[index] = .{
            .target_identity = target_identity,
            .held_value = rooted_held_value.dup(),
            .unregister_token = rooted_unregister_token.dup(),
        };
    }

    pub fn stdFileSlot(self: *Object) *?*std.c.FILE {
        if (self.stdFilePayload()) |payload| return &payload.file;
        std.debug.assert(self.class_payload_kind == .std_file);
        unreachable;
    }

    pub fn stdFile(self: *const Object) ?*std.c.FILE {
        if (self.stdFilePayloadConst()) |payload| return payload.file;
        return null;
    }

    pub fn stdFileIsPopenSlot(self: *Object) *bool {
        if (self.stdFilePayload()) |payload| return &payload.is_popen;
        std.debug.assert(self.class_payload_kind == .std_file);
        unreachable;
    }

    pub fn stdFileIsPopen(self: *const Object) bool {
        if (self.stdFilePayloadConst()) |payload| return payload.is_popen;
        return false;
    }

    pub fn stdFileIsStdioSlot(self: *Object) *bool {
        if (self.stdFilePayload()) |payload| return &payload.is_stdio;
        std.debug.assert(self.class_payload_kind == .std_file);
        unreachable;
    }

    pub fn stdFileIsStdio(self: *const Object) bool {
        if (self.stdFilePayloadConst()) |payload| return payload.is_stdio;
        return false;
    }

    pub fn disposableStackDisposedSlot(self: *Object) *bool {
        if (self.disposableStackPayload()) |payload| return &payload.disposed;
        std.debug.assert(self.class_payload_kind == .disposable_stack);
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
            std.debug.assert(self.class_payload_kind == .disposable_stack);
            unreachable;
        };
        if (payload.resources.len == payload.resource_capacity) {
            const new_capacity = if (payload.resource_capacity == 0) @as(usize, 4) else payload.resource_capacity * 2;
            const next = try rt.memory.alloc(DisposableResource, new_capacity);
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
        std.debug.assert(self.class_payload_kind == .disposable_stack);
        unreachable;
    }

    pub fn disposableStackAsyncRejectSlot(self: *Object) *?JSValue {
        if (self.disposableStackPayload()) |payload| return &payload.async_dispose_reject;
        std.debug.assert(self.class_payload_kind == .disposable_stack);
        unreachable;
    }

    pub fn disposableStackAsyncErrorSlot(self: *Object) *?JSValue {
        if (self.disposableStackPayload()) |payload| return &payload.async_dispose_error;
        std.debug.assert(self.class_payload_kind == .disposable_stack);
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
            std.debug.assert(self.class_payload_kind == .disposable_stack);
            unreachable;
        };
        const target_payload = target.disposableStackPayload() orelse {
            std.debug.assert(target.class_payload_kind == .disposable_stack);
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
        std.debug.assert(self.class_payload == null);
        const payload = try rt.memory.create(VarRefPayload);
        payload.* = .{};
        self.class_payload = @ptrCast(payload);
        self.class_payload_kind = .var_ref;
        return payload;
    }

    pub fn initVarRefPayload(self: *Object, rt: *JSRuntime, initial_value: JSValue) !void {
        const payload = try self.ensureVarRefPayload(rt);
        try self.setVarRefValue(rt, initial_value);
        payload.is_deleted = false;
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
        try self.setOptionalValueSlot(rt, self.functionPromiseCapabilitySlotSlot(), next_value);
    }

    pub fn setFunctionPromiseResolvingTarget(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, self.functionPromiseResolvingTargetSlot(), next_value);
    }

    pub fn setFunctionPromiseResolvingState(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, self.functionPromiseResolvingStateSlot(), next_value);
    }

    pub fn setFunctionPromiseThenableTarget(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, self.functionPromiseThenableTargetSlot(), next_value);
    }

    pub fn setFunctionPromiseThenableThis(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, self.functionPromiseThenableThisSlot(), next_value);
    }

    pub fn setFunctionPromiseThenableThen(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, self.functionPromiseThenableThenSlot(), next_value);
    }

    pub fn setFunctionPromiseReactionRecord(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, self.functionPromiseReactionRecordSlot(), next_value);
    }

    pub fn setFunctionPromiseReactionValue(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, self.functionPromiseReactionValueSlot(), next_value);
    }

    pub fn setFunctionPromiseCombinatorState(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, self.functionPromiseCombinatorStateSlot(), next_value);
    }

    pub fn setFunctionPromiseFinallyPayload(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, self.functionPromiseFinallyPayloadSlot(), next_value);
    }

    pub fn setFunctionPromiseFinallyCallback(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, self.functionPromiseFinallyCallbackSlot(), next_value);
    }

    pub fn setFunctionPromiseFinallyConstructor(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void {
        try self.setOptionalValueSlot(rt, self.functionPromiseFinallyConstructorSlot(), next_value);
    }

    pub fn varRefValueSlot(self: *Object) *?JSValue {
        if (self.varRefPayload()) |payload| return &payload.value;
        std.debug.assert(self.class_payload_kind == .var_ref);
        unreachable;
    }

    pub fn varRefValue(self: *const Object) ?JSValue {
        if (self.varRefPayloadConst()) |payload| return payload.value;
        return null;
    }

    pub fn varRefIsConstSlot(self: *Object) *bool {
        if (self.varRefPayload()) |payload| return &payload.is_const;
        std.debug.assert(self.class_payload_kind == .var_ref);
        unreachable;
    }

    pub fn varRefIsFunctionNameSlot(self: *Object) *bool {
        if (self.varRefPayload()) |payload| return &payload.is_function_name;
        std.debug.assert(self.class_payload_kind == .var_ref);
        unreachable;
    }

    pub fn varRefIsDeletableSlot(self: *Object) *bool {
        if (self.varRefPayload()) |payload| return &payload.is_deletable;
        std.debug.assert(self.class_payload_kind == .var_ref);
        unreachable;
    }

    pub fn varRefIsDeletedSlot(self: *Object) *bool {
        if (self.varRefPayload()) |payload| return &payload.is_deleted;
        std.debug.assert(self.class_payload_kind == .var_ref);
        unreachable;
    }

    pub fn ensureTypedArrayPayload(self: *Object, rt: *JSRuntime) !void {
        if (self.typedArrayPayload() != null) return;
        const payload = try rt.memory.create(TypedArrayPayload);
        payload.* = .{};
        self.class_payload = @ptrCast(payload);
        self.class_payload_kind = .typed_array;
    }

    pub fn byteStorageSlot(self: *Object) *[]u8 {
        if (self.bufferPayload()) |payload| return &payload.bytes;
        std.debug.assert(self.class_payload_kind == .buffer);
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
        std.debug.assert(self.class_payload_kind == .buffer);
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
        std.debug.assert(self.class_payload_kind == .buffer);
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
        std.debug.assert(self.class_payload_kind == .buffer);
        unreachable;
    }

    pub fn detachByteStorage(self: *Object, rt: *JSRuntime) void {
        if (self.bufferPayload()) |payload| {
            if (payload.shared_store != null) return;
            payload.releaseStorage(rt);
            payload.detached = true;
            return;
        }
        std.debug.assert(self.class_payload_kind == .buffer);
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
        std.debug.assert(self.class_payload_kind == .buffer);
        unreachable;
    }

    pub fn arrayBufferDetachedSlot(self: *Object) *bool {
        if (self.bufferPayload()) |payload| return &payload.detached;
        std.debug.assert(self.class_payload_kind == .buffer);
        unreachable;
    }

    pub fn arrayBufferDetached(self: *const Object) bool {
        if (self.bufferPayloadConst()) |payload| return payload.detached;
        return false;
    }

    pub fn arrayBufferImmutableSlot(self: *Object) *bool {
        if (self.bufferPayload()) |payload| return &payload.immutable;
        std.debug.assert(self.class_payload_kind == .buffer);
        unreachable;
    }

    pub fn arrayBufferImmutable(self: *const Object) bool {
        if (self.bufferPayloadConst()) |payload| return payload.immutable;
        return false;
    }

    pub fn arrayBufferMaxByteLengthSlot(self: *Object) *?usize {
        if (self.bufferPayload()) |payload| return &payload.max_byte_length;
        std.debug.assert(self.class_payload_kind == .buffer);
        unreachable;
    }

    pub fn arrayBufferMaxByteLength(self: *const Object) ?usize {
        if (self.bufferPayloadConst()) |payload| return payload.max_byte_length;
        return null;
    }

    pub fn typedArrayBufferSlot(self: *Object) *?JSValue {
        if (self.typedArrayPayload()) |payload| return &payload.buffer;
        std.debug.assert(self.class_payload_kind == .typed_array);
        unreachable;
    }

    pub fn typedArrayBuffer(self: *const Object) ?JSValue {
        if (self.typedArrayPayloadConst()) |payload| return payload.buffer;
        return null;
    }

    pub fn typedArrayByteOffsetSlot(self: *Object) *usize {
        if (self.typedArrayPayload()) |payload| return &payload.byte_offset;
        std.debug.assert(self.class_payload_kind == .typed_array);
        unreachable;
    }

    pub fn typedArrayByteOffset(self: *const Object) usize {
        if (self.typedArrayPayloadConst()) |payload| return payload.byte_offset;
        return 0;
    }

    pub fn typedArrayElementSizeSlot(self: *Object) *u32 {
        if (self.typedArrayPayload()) |payload| return &payload.element_size;
        if (self.functionPayload()) |payload| return &payload.typed_array_element_size;
        std.debug.assert(self.class_payload_kind == .typed_array);
        unreachable;
    }

    pub fn typedArrayElementSize(self: *const Object) u32 {
        if (self.typedArrayPayloadConst()) |payload| return payload.element_size;
        if (self.functionPayloadConst()) |payload| return payload.typed_array_element_size;
        return 0;
    }

    pub fn typedArrayFixedLengthSlot(self: *Object) *?u32 {
        if (self.typedArrayPayload()) |payload| return &payload.fixed_length;
        std.debug.assert(self.class_payload_kind == .typed_array);
        unreachable;
    }

    pub fn typedArrayFixedLength(self: *const Object) ?u32 {
        if (self.typedArrayPayloadConst()) |payload| return payload.fixed_length;
        return null;
    }

    pub fn typedArrayKindSlot(self: *Object) *u8 {
        if (self.typedArrayPayload()) |payload| return &payload.kind;
        if (self.functionPayload()) |payload| return &payload.typed_array_kind;
        std.debug.assert(self.class_payload_kind == .typed_array);
        unreachable;
    }

    pub fn typedArrayKind(self: *const Object) u8 {
        if (self.typedArrayPayloadConst()) |payload| return payload.kind;
        if (self.functionPayloadConst()) |payload| return payload.typed_array_kind;
        return 0;
    }

    pub fn regexpSourceSlot(self: *Object) *?JSValue {
        if (self.regExpPayload()) |payload| return &payload.source;
        std.debug.assert(self.class_payload_kind == .regexp);
        unreachable;
    }

    pub fn regexpSource(self: *const Object) ?JSValue {
        if (self.regExpPayloadConst()) |payload| return payload.source;
        return null;
    }

    pub fn regexpFlagsSlot(self: *Object) *?JSValue {
        if (self.regExpPayload()) |payload| return &payload.flags;
        std.debug.assert(self.class_payload_kind == .regexp);
        unreachable;
    }

    pub fn regexpFlags(self: *const Object) ?JSValue {
        if (self.regExpPayloadConst()) |payload| return payload.flags;
        return null;
    }

    pub fn regexpLastIndexSlot(self: *Object) *?JSValue {
        if (self.regExpPayload()) |payload| return &payload.last_index;
        std.debug.assert(self.class_payload_kind == .regexp);
        unreachable;
    }

    pub fn regexpLastIndex(self: *const Object) ?JSValue {
        if (self.regExpPayloadConst()) |payload| return payload.last_index;
        return null;
    }

    pub fn regexpLastIndexWritableSlot(self: *Object) *bool {
        if (self.regExpPayload()) |payload| return &payload.last_index_writable;
        std.debug.assert(self.class_payload_kind == .regexp);
        unreachable;
    }

    pub fn regexpLastIndexWritable(self: *const Object) bool {
        if (self.regExpPayloadConst()) |payload| return payload.last_index_writable;
        return true;
    }

    pub fn regexpCompiledBytecode(self: *const Object) []const u8 {
        if (self.regExpPayloadConst()) |payload| return payload.compiled_bytecode;
        return &.{};
    }

    pub fn regexpSimpleClassAlternationCache(self: *const Object) ?RegExpSimpleClassAlternationPattern {
        const payload = self.regExpPayloadConst() orelse return null;
        if (payload.fast_pattern_kind != .simple_class_alternation) return null;
        return payload.fast_simple_class_alternation;
    }

    pub fn setRegexpSimpleClassAlternationCache(self: *Object, pattern: RegExpSimpleClassAlternationPattern) void {
        if (self.regExpPayload()) |payload| {
            payload.fast_pattern_kind = .simple_class_alternation;
            payload.fast_simple_class_alternation = pattern;
            return;
        }
        std.debug.assert(self.class_payload_kind == .regexp);
        unreachable;
    }

    pub fn regexpSimpleCaptureSequenceCache(self: *const Object) ?RegExpSimpleCaptureSequencePattern {
        const payload = self.regExpPayloadConst() orelse return null;
        if (payload.fast_pattern_kind != .simple_capture_sequence) return null;
        return payload.fast_simple_capture_sequence;
    }

    pub fn setRegexpSimpleCaptureSequenceCache(self: *Object, pattern: RegExpSimpleCaptureSequencePattern) void {
        if (self.regExpPayload()) |payload| {
            payload.fast_pattern_kind = .simple_capture_sequence;
            payload.fast_simple_capture_sequence = pattern;
            return;
        }
        std.debug.assert(self.class_payload_kind == .regexp);
        unreachable;
    }

    pub fn clearRegexpCompiledBytecode(self: *Object, rt: *JSRuntime) void {
        if (self.regExpPayload()) |payload| {
            if (payload.compiled_bytecode.len != 0) {
                const compiled_bytecode = payload.compiled_bytecode;
                payload.compiled_bytecode = &.{};
                rt.memory.free(u8, compiled_bytecode);
            }
            payload.fast_pattern_kind = .none;
            payload.fast_simple_class_alternation = .{};
            payload.fast_simple_capture_sequence = .{};
            return;
        }
        std.debug.assert(self.class_payload_kind == .regexp);
        unreachable;
    }

    pub fn setRegexpCompiledBytecode(self: *Object, rt: *JSRuntime, bytecode: []const u8) !void {
        if (self.regExpPayload()) |payload| {
            if (bytecode.len == 0) {
                self.clearRegexpCompiledBytecode(rt);
                return;
            }

            const owned = try rt.memory.alloc(u8, bytecode.len);
            @memcpy(owned, bytecode);
            const old_bytecode = payload.compiled_bytecode;
            payload.compiled_bytecode = owned;
            payload.fast_pattern_kind = .none;
            payload.fast_simple_class_alternation = .{};
            payload.fast_simple_capture_sequence = .{};
            if (old_bytecode.len != 0) rt.memory.free(u8, old_bytecode);
        } else {
            std.debug.assert(self.class_payload_kind == .regexp);
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
        if (self.proxyPayload() != null) return;
        const payload = try rt.memory.create(ProxyPayload);
        payload.* = .{};
        self.class_payload = @ptrCast(payload);
        self.class_payload_kind = .proxy;
    }

    pub fn proxyTargetSlot(self: *Object) *?JSValue {
        if (self.proxyPayload()) |payload| return &payload.target;
        std.debug.assert(self.flags.is_proxy);
        unreachable;
    }

    pub fn proxyTarget(self: *const Object) ?JSValue {
        if (self.proxyPayloadConst()) |payload| return payload.target;
        return null;
    }

    pub fn proxyHandlerSlot(self: *Object) *?JSValue {
        if (self.proxyPayload()) |payload| return &payload.handler;
        std.debug.assert(self.flags.is_proxy);
        unreachable;
    }

    pub fn proxyHandler(self: *const Object) ?JSValue {
        if (self.proxyPayloadConst()) |payload| return payload.handler;
        return null;
    }

    pub fn argumentsVarRefsSlot(self: *Object) *[]JSValue {
        if (self.argumentsPayload()) |payload| return &payload.var_refs;
        std.debug.assert(self.class_id == class.ids.arguments or self.class_id == class.ids.mapped_arguments);
        unreachable;
    }

    pub fn argumentsVarRefs(self: *const Object) []JSValue {
        if (self.argumentsPayloadConst()) |payload| return payload.var_refs;
        return &.{};
    }

    pub fn objectDataSlot(self: *Object) *?JSValue {
        if (self.objectDataPayload()) |payload| return &payload.data;
        std.debug.assert(self.class_payload_kind == .object_data);
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
        const payload = self.objectDataPayload() orelse {
            std.debug.assert(self.class_payload_kind == .object_data);
            unreachable;
        };
        const old_target = payload.data;
        payload.data = null;
        payload.weak_target_identity = weak_target_identity;
        if (old_target) |stored| stored.free(rt);
        self.pruneBorrowedReferenceHolderIfEmpty(rt);
    }

    pub fn weakRefDeref(self: *const Object, rt: *JSRuntime) JSValue {
        std.debug.assert(self.class_id == class.ids.weak_ref);
        const payload = self.objectDataPayloadConst() orelse return JSValue.undefinedValue();
        const identity = payload.weak_target_identity orelse return JSValue.undefinedValue();
        if ((identity & 1) != 0) {
            const atom_id = identity >> 1;
            if (atom_id > std.math.maxInt(atom.Atom)) return JSValue.undefinedValue();
            const symbol_atom: atom.Atom = @intCast(atom_id);
            return if (rt.atoms.kind(symbol_atom) == .symbol) JSValue.symbol(symbol_atom) else JSValue.undefinedValue();
        }
        const target = rt.liveObjectFromWeakIdentity(identity) orelse return JSValue.undefinedValue();
        return target.value().dup();
    }

    pub fn arrayStorageModeSlot(self: *Object) *ArrayStorageMode {
        if (self.arrayPayload()) |payload| return &payload.storage_mode;
        std.debug.assert(self.flags.is_array);
        unreachable;
    }

    pub fn arrayElementStorageMode(self: *const Object) ArrayStorageMode {
        if (self.arrayPayloadConst()) |payload| return payload.storage_mode;
        return .dense;
    }

    pub fn arrayElementsSlot(self: *Object) *[]?JSValue {
        if (self.arrayPayload()) |payload| return &payload.elements;
        std.debug.assert(self.flags.is_array);
        unreachable;
    }

    pub fn arrayElements(self: *const Object) []?JSValue {
        if (self.arrayPayloadConst()) |payload| return payload.elements;
        return &.{};
    }

    pub fn arrayElementsCapacitySlot(self: *Object) *usize {
        if (self.arrayPayload()) |payload| return &payload.elements_capacity;
        std.debug.assert(self.flags.is_array);
        unreachable;
    }

    pub fn arrayElementsCapacity(self: *const Object) usize {
        if (self.arrayPayloadConst()) |payload| return payload.elements_capacity;
        return 0;
    }

    pub fn promiseResultSlot(self: *Object) *?JSValue {
        if (self.promisePayload()) |payload| return &payload.result;
        std.debug.assert(self.class_payload_kind == .promise);
        unreachable;
    }

    pub fn promiseResult(self: *const Object) ?JSValue {
        if (self.promisePayloadConst()) |payload| return payload.result;
        return null;
    }

    pub fn promiseReactionCallbackSlot(self: *Object) *?JSValue {
        if (self.promisePayload()) |payload| return &payload.reaction_callback;
        std.debug.assert(self.class_payload_kind == .promise);
        unreachable;
    }

    pub fn promiseReactionCallback(self: *const Object) ?JSValue {
        if (self.promisePayloadConst()) |payload| return payload.reaction_callback;
        return null;
    }

    pub fn promiseReactionArgSlot(self: *Object) *?JSValue {
        if (self.promisePayload()) |payload| return &payload.reaction_arg;
        std.debug.assert(self.class_payload_kind == .promise);
        unreachable;
    }

    pub fn promiseReactionArg(self: *const Object) ?JSValue {
        if (self.promisePayloadConst()) |payload| return payload.reaction_arg;
        return null;
    }

    pub fn promiseReactionsSlot(self: *Object) *[]JSValue {
        if (self.promisePayload()) |payload| return &payload.reactions;
        std.debug.assert(self.class_payload_kind == .promise);
        unreachable;
    }

    pub fn promiseReactions(self: *const Object) []JSValue {
        if (self.promisePayloadConst()) |payload| return payload.reactions;
        return &.{};
    }

    pub fn promiseIsRejectedSlot(self: *Object) *bool {
        if (self.promisePayload()) |payload| return &payload.is_rejected;
        std.debug.assert(self.class_payload_kind == .promise);
        unreachable;
    }

    pub fn promiseIsRejected(self: *const Object) bool {
        if (self.promisePayloadConst()) |payload| return payload.is_rejected;
        return false;
    }

    pub fn promiseAtomicsWaitAsyncSlot(self: *Object) *bool {
        if (self.promisePayload()) |payload| return &payload.atomics_wait_async;
        std.debug.assert(self.class_payload_kind == .promise);
        unreachable;
    }

    pub fn promiseAtomicsWaitAsync(self: *const Object) bool {
        if (self.promisePayloadConst()) |payload| return payload.atomics_wait_async;
        return false;
    }

    pub fn generatorThisSlot(self: *Object) *?JSValue {
        if (self.generatorPayload()) |payload| return &payload.this_value;
        std.debug.assert(self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorThis(self: *const Object) ?JSValue {
        if (self.generatorPayloadConst()) |payload| return payload.this_value;
        return null;
    }

    pub fn generatorArgsSlot(self: *Object) *[]JSValue {
        if (self.generatorPayload()) |payload| return &payload.args;
        std.debug.assert(self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorArgs(self: *const Object) []JSValue {
        if (self.generatorPayloadConst()) |payload| return payload.args;
        return &.{};
    }

    pub fn generatorStackSlot(self: *Object) *[]JSValue {
        if (self.generatorPayload()) |payload| return &payload.stack;
        std.debug.assert(self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorStack(self: *const Object) []JSValue {
        if (self.generatorPayloadConst()) |payload| return payload.stack;
        return &.{};
    }

    pub fn generatorStackCapacitySlot(self: *Object) *usize {
        if (self.generatorPayload()) |payload| return &payload.stack_capacity;
        std.debug.assert(self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorStackCapacity(self: *const Object) usize {
        if (self.generatorPayloadConst()) |payload| return payload.stack_capacity;
        return 0;
    }

    pub fn generatorFrameLocalsSlot(self: *Object) *[]JSValue {
        if (self.generatorPayload()) |payload| return &payload.frame_locals;
        std.debug.assert(self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorFrameLocals(self: *const Object) []JSValue {
        if (self.generatorPayloadConst()) |payload| return payload.frame_locals;
        return &.{};
    }

    pub fn generatorFrameArgsSlot(self: *Object) *[]JSValue {
        if (self.generatorPayload()) |payload| return &payload.frame_args;
        std.debug.assert(self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorFrameArgs(self: *const Object) []JSValue {
        if (self.generatorPayloadConst()) |payload| return payload.frame_args;
        return &.{};
    }

    pub fn generatorFrameVarRefsSlot(self: *Object) *[]JSValue {
        if (self.generatorPayload()) |payload| return &payload.frame_var_refs;
        std.debug.assert(self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorFrameVarRefs(self: *const Object) []JSValue {
        if (self.generatorPayloadConst()) |payload| return payload.frame_var_refs;
        return &.{};
    }

    pub fn generatorFrameLocalsUninitSlot(self: *Object) *[]bool {
        if (self.generatorPayload()) |payload| return &payload.frame_locals_uninit;
        std.debug.assert(self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorFrameLocalsUninit(self: *const Object) []bool {
        if (self.generatorPayloadConst()) |payload| return payload.frame_locals_uninit;
        return &.{};
    }

    pub fn generatorCurrentFunctionSlot(self: *Object) *?JSValue {
        if (self.generatorPayload()) |payload| return &payload.current_function;
        std.debug.assert(self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorCurrentFunction(self: *const Object) ?JSValue {
        if (self.generatorPayloadConst()) |payload| return payload.current_function;
        return null;
    }

    pub fn generatorYieldStarIteratorSlot(self: *Object) *?JSValue {
        if (self.generatorPayload()) |payload| return &payload.yield_star_iterator;
        std.debug.assert(self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorYieldStarIterator(self: *const Object) ?JSValue {
        if (self.generatorPayloadConst()) |payload| return payload.yield_star_iterator;
        return null;
    }

    pub fn generatorAsyncPromiseSlot(self: *Object) *?JSValue {
        if (self.generatorPayload()) |payload| return &payload.async_promise;
        std.debug.assert(self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorAsyncPromise(self: *const Object) ?JSValue {
        if (self.generatorPayloadConst()) |payload| return payload.async_promise;
        return null;
    }

    pub fn generatorPcSlot(self: *Object) *usize {
        if (self.generatorPayload()) |payload| return &payload.pc;
        std.debug.assert(self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorPc(self: *const Object) usize {
        if (self.generatorPayloadConst()) |payload| return payload.pc;
        return 0;
    }

    pub fn generatorResumeCompletionTypeSlot(self: *Object) *i32 {
        if (self.generatorPayload()) |payload| return &payload.resume_completion_type;
        std.debug.assert(self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorResumeCompletionType(self: *const Object) i32 {
        if (self.generatorPayloadConst()) |payload| return payload.resume_completion_type;
        return 0;
    }

    pub fn generatorDoneSlot(self: *Object) *bool {
        if (self.generatorPayload()) |payload| return &payload.done;
        std.debug.assert(self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorDone(self: *const Object) bool {
        if (self.generatorPayloadConst()) |payload| return payload.done;
        return false;
    }

    pub fn generatorExecutingSlot(self: *Object) *bool {
        if (self.generatorPayload()) |payload| return &payload.executing;
        if (self.iteratorPayload()) |payload| return &payload.executing;
        std.debug.assert(self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorExecuting(self: *const Object) bool {
        if (self.generatorPayloadConst()) |payload| return payload.executing;
        if (self.iteratorPayloadConst()) |payload| return payload.executing;
        return false;
    }

    pub fn generatorStartedSlot(self: *Object) *bool {
        if (self.generatorPayload()) |payload| return &payload.started;
        std.debug.assert(self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorStarted(self: *const Object) bool {
        if (self.generatorPayloadConst()) |payload| return payload.started;
        return false;
    }

    pub fn generatorJustYieldedSlot(self: *Object) *bool {
        if (self.generatorPayload()) |payload| return &payload.just_yielded;
        std.debug.assert(self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorJustYielded(self: *const Object) bool {
        if (self.generatorPayloadConst()) |payload| return payload.just_yielded;
        return false;
    }

    pub fn generatorYieldStarSuspendedSlot(self: *Object) *bool {
        if (self.generatorPayload()) |payload| return &payload.yield_star_suspended;
        std.debug.assert(self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorYieldStarSuspended(self: *const Object) bool {
        if (self.generatorPayloadConst()) |payload| return payload.yield_star_suspended;
        return false;
    }

    pub fn functionSourceSlot(self: *Object) *?JSValue {
        if (self.functionPayload()) |payload| return &payload.source;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionSource(self: *const Object) ?JSValue {
        if (self.functionPayloadConst()) |payload| return payload.source;
        return null;
    }

    pub fn hostFunctionKindSlot(self: *Object) *i32 {
        if (self.functionPayload()) |payload| return &payload.host_function_kind;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn hostFunctionKind(self: *const Object) i32 {
        if (self.functionPayloadConst()) |payload| return payload.host_function_kind;
        return 0;
    }

    pub fn nativeFunctionIdSlot(self: *Object) *i32 {
        if (self.functionPayload()) |payload| return &payload.native_function_id;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn nativeFunctionId(self: *const Object) i32 {
        if (self.functionPayloadConst()) |payload| return payload.native_function_id;
        return 0;
    }

    pub fn externalHostFunctionIdSlot(self: *Object) *u32 {
        if (self.functionPayload()) |payload| return &payload.external_host_function_id;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn externalHostFunctionId(self: *const Object) u32 {
        if (self.functionPayloadConst()) |payload| return payload.external_host_function_id;
        return 0;
    }

    pub fn functionIteratorWrapMethodSlot(self: *Object) *u8 {
        if (self.functionPayload()) |payload| return &payload.iterator_wrap_method;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionIteratorWrapMethod(self: *const Object) u8 {
        if (self.functionPayloadConst()) |payload| return payload.iterator_wrap_method;
        return 0;
    }

    pub fn functionPrimitivePrototypeSlot(self: *Object, slot: PrimitivePrototypeSlot) *?JSValue {
        if (self.functionPayload()) |payload| return &payload.primitive_prototypes[@intFromEnum(slot)];
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPrimitivePrototype(self: *const Object, slot: PrimitivePrototypeSlot) ?JSValue {
        if (self.functionPayloadConst()) |payload| return payload.primitive_prototypes[@intFromEnum(slot)];
        return null;
    }

    pub fn nativeDispatchNameSlot(self: *Object) *atom.Atom {
        if (self.functionPayload()) |payload| return &payload.native_dispatch_name;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn nativeDispatchName(self: *const Object) atom.Atom {
        if (self.functionPayloadConst()) |payload| return payload.native_dispatch_name;
        return atom.null_atom;
    }

    pub fn ensureRegExpLegacyStatics(self: *Object, rt: *JSRuntime) !*RegExpLegacyStatics {
        if (self.functionPayload()) |payload| {
            if (payload.regexp_legacy_statics) |legacy| return legacy;
            const legacy = try rt.memory.create(RegExpLegacyStatics);
            legacy.* = .{};
            payload.regexp_legacy_statics = legacy;
            return legacy;
        }
        return error.TypeError;
    }

    pub fn regExpLegacyStatics(self: *Object) ?*RegExpLegacyStatics {
        if (self.functionPayload()) |payload| return payload.regexp_legacy_statics;
        return null;
    }

    pub fn regExpLegacyStaticsConst(self: *const Object) ?*const RegExpLegacyStatics {
        if (self.functionPayloadConst()) |payload| return payload.regexp_legacy_statics;
        return null;
    }

    pub fn arrayBuiltinMarkerSlot(self: *Object) *ArrayBuiltinMarker {
        if (self.functionPayload()) |payload| return &payload.array_builtin_marker;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn arrayBuiltinMarker(self: *const Object) ArrayBuiltinMarker {
        if (self.functionPayloadConst()) |payload| return payload.array_builtin_marker;
        return .none;
    }

    pub fn typedArrayBuiltinMarker(self: *const Object) TypedArrayBuiltinMarker {
        if (self.functionPayloadConst()) |payload| return payload.typed_array_builtin_marker;
        return .none;
    }

    pub fn arrayIteratorKind(self: *const Object) u8 {
        if (self.functionPayloadConst()) |payload| return payload.array_iterator_kind;
        return 0;
    }

    pub fn isIteratorIdentityFunction(self: *const Object) bool {
        if (self.functionPayloadConst()) |payload| return payload.iterator_identity;
        return false;
    }

    pub fn isArrayIteratorNextFunction(self: *const Object) bool {
        if (self.functionPayloadConst()) |payload| return payload.array_iterator_next;
        return false;
    }

    pub fn isThrowTypeErrorIntrinsicFunction(self: *const Object) bool {
        if (self.functionPayloadConst()) |payload| return payload.throw_type_error_intrinsic;
        return false;
    }

    pub fn isAsyncIteratorAsyncDisposeFunction(self: *const Object) bool {
        if (self.functionPayloadConst()) |payload| return payload.async_iterator_async_dispose;
        return false;
    }

    pub fn isAsyncGeneratorPrototypeMethod(self: *const Object) bool {
        if (self.functionPayloadConst()) |payload| return payload.async_generator_method;
        return false;
    }

    pub fn iteratorHelperMethod(self: *const Object) u8 {
        if (self.functionPayloadConst()) |payload| return payload.iterator_helper_method;
        return 0;
    }

    pub fn asyncFromSyncIteratorMethod(self: *const Object) u8 {
        if (self.functionPayloadConst()) |payload| return payload.async_from_sync_iterator_method;
        return 0;
    }

    pub fn disposableStackMethod(self: *const Object) u8 {
        if (self.functionPayloadConst()) |payload| return payload.disposable_stack_method;
        return 0;
    }

    pub fn asyncDisposableStackMethod(self: *const Object) u8 {
        if (self.functionPayloadConst()) |payload| return payload.async_disposable_stack_method;
        return 0;
    }

    pub fn addArrayBuiltinMarker(self: *Object, marker: ArrayBuiltinMarker) bool {
        if (marker == .none) return true;
        if (self.functionPayload()) |payload| return setArrayBuiltinMarker(payload, marker);
        return false;
    }

    pub fn addTypedArrayBuiltinMarker(self: *Object, marker: TypedArrayBuiltinMarker) bool {
        if (marker == .none) return true;
        if (self.functionPayload()) |payload| return setTypedArrayBuiltinMarker(payload, marker);
        return false;
    }

    pub fn addArrayIteratorKind(self: *Object, kind: u8) bool {
        if (kind == 0) return true;
        if (self.functionPayload()) |payload| return setArrayIteratorKind(payload, kind);
        return false;
    }

    pub fn addIteratorIdentityFunction(self: *Object) bool {
        if (self.functionPayload()) |payload| {
            payload.iterator_identity = true;
            return true;
        }
        return false;
    }

    pub fn addArrayIteratorNextFunction(self: *Object) bool {
        if (self.functionPayload()) |payload| {
            payload.array_iterator_next = true;
            return true;
        }
        return false;
    }

    pub fn addThrowTypeErrorIntrinsicFunction(self: *Object) bool {
        if (self.functionPayload()) |payload| {
            payload.throw_type_error_intrinsic = true;
            return true;
        }
        return false;
    }

    pub fn addAsyncIteratorAsyncDisposeFunction(self: *Object) bool {
        if (self.functionPayload()) |payload| {
            payload.async_iterator_async_dispose = true;
            return true;
        }
        return false;
    }

    pub fn addAsyncGeneratorPrototypeMethod(self: *Object) bool {
        if (self.functionPayload()) |payload| {
            payload.async_generator_method = true;
            return true;
        }
        return false;
    }

    pub fn addIteratorHelperMethod(self: *Object, method_id: u8) bool {
        if (method_id == 0) return true;
        if (self.functionPayload()) |payload| {
            if (payload.iterator_helper_method != 0 and payload.iterator_helper_method != method_id) return false;
            payload.iterator_helper_method = method_id;
            return true;
        }
        return false;
    }

    pub fn addAsyncFromSyncIteratorMethod(self: *Object, method_id: u8) bool {
        if (method_id == 0) return true;
        if (self.functionPayload()) |payload| {
            if (payload.async_from_sync_iterator_method != 0 and payload.async_from_sync_iterator_method != method_id) return false;
            payload.async_from_sync_iterator_method = method_id;
            return true;
        }
        return false;
    }

    pub fn addDisposableStackMethod(self: *Object, method_id: u8) bool {
        if (method_id == 0) return true;
        if (self.functionPayload()) |payload| return setDisposableStackMethod(payload, method_id);
        return false;
    }

    pub fn addAsyncDisposableStackMethod(self: *Object, method_id: u8) bool {
        if (method_id == 0) return true;
        if (self.functionPayload()) |payload| return setAsyncDisposableStackMethod(payload, method_id);
        return false;
    }

    pub fn addCollectionMethodOwnerClass(self: *Object, owner_class: class.ClassId) bool {
        if (owner_class == class.invalid_class_id) return true;
        if (self.functionPayload()) |payload| return setCollectionMethodOwnerClass(payload, owner_class);
        return false;
    }

    fn setArrayBuiltinMarker(payload: *FunctionPayload, marker: ArrayBuiltinMarker) bool {
        if (payload.array_builtin_marker != .none and payload.array_builtin_marker != marker) return false;
        payload.array_builtin_marker = marker;
        return true;
    }

    fn setTypedArrayBuiltinMarker(payload: *FunctionPayload, marker: TypedArrayBuiltinMarker) bool {
        if (payload.typed_array_builtin_marker != .none and payload.typed_array_builtin_marker != marker) return false;
        payload.typed_array_builtin_marker = marker;
        return true;
    }

    fn setArrayIteratorKind(payload: *FunctionPayload, kind: u8) bool {
        if (payload.array_iterator_kind != 0 and payload.array_iterator_kind != kind) return false;
        payload.array_iterator_kind = kind;
        return true;
    }

    fn setDisposableStackMethod(payload: *FunctionPayload, method_id: u8) bool {
        if (payload.disposable_stack_method != 0 and payload.disposable_stack_method != method_id) return false;
        payload.disposable_stack_method = method_id;
        return true;
    }

    fn setAsyncDisposableStackMethod(payload: *FunctionPayload, method_id: u8) bool {
        if (payload.async_disposable_stack_method != 0 and payload.async_disposable_stack_method != method_id) return false;
        payload.async_disposable_stack_method = method_id;
        return true;
    }

    fn setCollectionMethodOwnerClass(payload: *FunctionPayload, owner_class: class.ClassId) bool {
        if (payload.collection_method_owner_class != class.invalid_class_id and payload.collection_method_owner_class != owner_class) return false;
        payload.collection_method_owner_class = owner_class;
        return true;
    }

    pub fn collectionMethodOwnerClassSlot(self: *Object) *class.ClassId {
        if (self.functionPayload()) |payload| return &payload.collection_method_owner_class;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn collectionMethodOwnerClass(self: *const Object) class.ClassId {
        if (self.functionPayloadConst()) |payload| return payload.collection_method_owner_class;
        return class.invalid_class_id;
    }

    pub fn functionBytecodeSlot(self: *Object) *?JSValue {
        if (self.functionPayload()) |payload| return &payload.bytecode;
        if (self.generatorPayload()) |payload| return &payload.bytecode;
        std.debug.assert(self.class_payload_kind == .function or self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn functionBytecode(self: *const Object) ?JSValue {
        if (self.functionPayloadConst()) |payload| return payload.bytecode;
        if (self.generatorPayloadConst()) |payload| return payload.bytecode;
        return null;
    }

    pub fn functionClassFieldsInitSlot(self: *Object) *?JSValue {
        if (self.functionPayload()) |payload| return &payload.class_fields_init;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionClassFieldsInit(self: *const Object) ?JSValue {
        if (self.functionPayloadConst()) |payload| return payload.class_fields_init;
        return null;
    }

    pub fn functionEvalParentFunctionSlot(self: *Object) *?JSValue {
        if (self.functionPayload()) |payload| return &payload.eval_parent_function;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionEvalParentFunction(self: *const Object) ?JSValue {
        if (self.functionPayloadConst()) |payload| return payload.eval_parent_function;
        return null;
    }

    pub fn functionImportMetaSlot(self: *Object) *?JSValue {
        if (self.functionPayload()) |payload| return &payload.import_meta;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionImportMeta(self: *const Object) ?JSValue {
        if (self.functionPayloadConst()) |payload| return payload.import_meta;
        return null;
    }

    pub fn functionProxyRevokeTargetSlot(self: *Object) *?JSValue {
        if (self.functionPayload()) |payload| return &payload.proxy_revoke_target;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionProxyRevokeTarget(self: *const Object) ?JSValue {
        if (self.functionPayloadConst()) |payload| return payload.proxy_revoke_target;
        return null;
    }

    pub fn functionPromiseCapabilitySlotSlot(self: *Object) *?JSValue {
        if (self.functionPayload()) |payload| return &payload.promise_capability_slot;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseCapabilitySlot(self: *const Object) ?JSValue {
        if (self.functionPayloadConst()) |payload| return payload.promise_capability_slot;
        return null;
    }

    pub fn functionPromiseResolvingTargetSlot(self: *Object) *?JSValue {
        if (self.functionPayload()) |payload| return &payload.promise_resolving_target;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseResolvingTarget(self: *const Object) ?JSValue {
        if (self.functionPayloadConst()) |payload| return payload.promise_resolving_target;
        return null;
    }

    pub fn functionPromiseResolvingStateSlot(self: *Object) *?JSValue {
        if (self.functionPayload()) |payload| return &payload.promise_resolving_state;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseResolvingState(self: *const Object) ?JSValue {
        if (self.functionPayloadConst()) |payload| return payload.promise_resolving_state;
        return null;
    }

    pub fn functionPromiseResolvingRejectSlot(self: *Object) *bool {
        if (self.functionPayload()) |payload| return &payload.promise_resolving_reject;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseResolvingReject(self: *const Object) bool {
        if (self.functionPayloadConst()) |payload| return payload.promise_resolving_reject;
        return false;
    }

    pub fn functionPromiseThenableTargetSlot(self: *Object) *?JSValue {
        if (self.functionPayload()) |payload| return &payload.promise_thenable_target;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseThenableTarget(self: *const Object) ?JSValue {
        if (self.functionPayloadConst()) |payload| return payload.promise_thenable_target;
        return null;
    }

    pub fn functionPromiseThenableThisSlot(self: *Object) *?JSValue {
        if (self.functionPayload()) |payload| return &payload.promise_thenable_this;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseThenableThis(self: *const Object) ?JSValue {
        if (self.functionPayloadConst()) |payload| return payload.promise_thenable_this;
        return null;
    }

    pub fn functionPromiseThenableThenSlot(self: *Object) *?JSValue {
        if (self.functionPayload()) |payload| return &payload.promise_thenable_then;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseThenableThen(self: *const Object) ?JSValue {
        if (self.functionPayloadConst()) |payload| return payload.promise_thenable_then;
        return null;
    }

    pub fn functionPromiseReactionRecordSlot(self: *Object) *?JSValue {
        if (self.functionPayload()) |payload| return &payload.promise_reaction_record;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseReactionRecord(self: *const Object) ?JSValue {
        if (self.functionPayloadConst()) |payload| return payload.promise_reaction_record;
        return null;
    }

    pub fn functionPromiseReactionValueSlot(self: *Object) *?JSValue {
        if (self.functionPayload()) |payload| return &payload.promise_reaction_value;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseReactionValue(self: *const Object) ?JSValue {
        if (self.functionPayloadConst()) |payload| return payload.promise_reaction_value;
        return null;
    }

    pub fn functionPromiseReactionIsRejectedSlot(self: *Object) *bool {
        if (self.functionPayload()) |payload| return &payload.promise_reaction_is_rejected;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseReactionIsRejected(self: *const Object) bool {
        if (self.functionPayloadConst()) |payload| return payload.promise_reaction_is_rejected;
        return false;
    }

    pub fn functionPromiseCombinatorStateSlot(self: *Object) *?JSValue {
        if (self.functionPayload()) |payload| return &payload.promise_combinator_state;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseCombinatorState(self: *const Object) ?JSValue {
        if (self.functionPayloadConst()) |payload| return payload.promise_combinator_state;
        return null;
    }

    pub fn functionPromiseCombinatorModeSlot(self: *Object) *u8 {
        if (self.functionPayload()) |payload| return &payload.promise_combinator_mode;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseCombinatorMode(self: *const Object) u8 {
        if (self.functionPayloadConst()) |payload| return payload.promise_combinator_mode;
        return 0;
    }

    pub fn functionPromiseCombinatorIndexSlot(self: *Object) *u32 {
        if (self.functionPayload()) |payload| return &payload.promise_combinator_index;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseCombinatorIndex(self: *const Object) u32 {
        if (self.functionPayloadConst()) |payload| return payload.promise_combinator_index;
        return 0;
    }

    pub fn functionPromiseCombinatorCalledSlot(self: *Object) *bool {
        if (self.functionPayload()) |payload| return &payload.promise_combinator_called;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseCombinatorCalled(self: *const Object) bool {
        if (self.functionPayloadConst()) |payload| return payload.promise_combinator_called;
        return false;
    }

    pub fn functionPromiseFinallyPayloadSlot(self: *Object) *?JSValue {
        if (self.functionPayload()) |payload| return &payload.promise_finally_payload;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseFinallyPayload(self: *const Object) ?JSValue {
        if (self.functionPayloadConst()) |payload| return payload.promise_finally_payload;
        return null;
    }

    pub fn functionPromiseFinallyCallbackSlot(self: *Object) *?JSValue {
        if (self.functionPayload()) |payload| return &payload.promise_finally_callback;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseFinallyCallback(self: *const Object) ?JSValue {
        if (self.functionPayloadConst()) |payload| return payload.promise_finally_callback;
        return null;
    }

    pub fn functionPromiseFinallyConstructorSlot(self: *Object) *?JSValue {
        if (self.functionPayload()) |payload| return &payload.promise_finally_constructor;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseFinallyConstructor(self: *const Object) ?JSValue {
        if (self.functionPayloadConst()) |payload| return payload.promise_finally_constructor;
        return null;
    }

    pub fn functionPromiseFinallyModeSlot(self: *Object) *u8 {
        if (self.functionPayload()) |payload| return &payload.promise_finally_mode;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseFinallyMode(self: *const Object) u8 {
        if (self.functionPayloadConst()) |payload| return payload.promise_finally_mode;
        return 0;
    }

    pub fn functionAsyncDisposeStackSlot(self: *Object) *?JSValue {
        if (self.functionPayload()) |payload| return &payload.async_dispose_stack;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionAsyncDisposeStack(self: *const Object) ?JSValue {
        if (self.functionPayloadConst()) |payload| return payload.async_dispose_stack;
        return null;
    }

    pub fn functionAsyncDisposeRejectedSlot(self: *Object) *bool {
        if (self.functionPayload()) |payload| return &payload.async_dispose_rejected;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionAsyncDisposeRejected(self: *const Object) bool {
        if (self.functionPayloadConst()) |payload| return payload.async_dispose_rejected;
        return false;
    }

    pub fn functionAsyncContinuationSlot(self: *Object) *?JSValue {
        if (self.functionPayload()) |payload| return &payload.async_function_continuation;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionAsyncContinuation(self: *const Object) ?JSValue {
        if (self.functionPayloadConst()) |payload| return payload.async_function_continuation;
        return null;
    }

    pub fn functionAsyncContinuationRejectedSlot(self: *Object) *bool {
        if (self.functionPayload()) |payload| return &payload.async_function_rejected;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionAsyncContinuationRejected(self: *const Object) bool {
        if (self.functionPayloadConst()) |payload| return payload.async_function_rejected;
        return false;
    }

    pub fn functionAsyncFromSyncUnwrapDoneSlot(self: *Object) *u8 {
        if (self.functionPayload()) |payload| return &payload.async_from_sync_unwrap_done;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionAsyncFromSyncUnwrapDone(self: *const Object) u8 {
        if (self.functionPayloadConst()) |payload| return payload.async_from_sync_unwrap_done;
        return 0;
    }

    pub fn functionRealmTypeErrorConstructorSlot(self: *Object) *?JSValue {
        if (self.functionPayload()) |payload| return &payload.realm_type_error_constructor;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionRealmTypeErrorConstructor(self: *const Object) ?JSValue {
        if (self.functionPayloadConst()) |payload| return payload.realm_type_error_constructor;
        return null;
    }

    pub fn functionArrowConstructorThisSlot(self: *Object) *?JSValue {
        if (self.functionPayload()) |payload| return &payload.arrow_constructor_this;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionArrowConstructorThis(self: *const Object) ?JSValue {
        if (self.functionPayloadConst()) |payload| return payload.arrow_constructor_this;
        return null;
    }

    pub fn functionArrowNewTargetSlot(self: *Object) *?JSValue {
        if (self.functionPayload()) |payload| return &payload.arrow_new_target;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionArrowNewTarget(self: *const Object) ?JSValue {
        if (self.functionPayloadConst()) |payload| return payload.arrow_new_target;
        return null;
    }

    pub fn functionSuperConstructorSlot(self: *Object) *?JSValue {
        if (self.functionPayload()) |payload| return &payload.super_constructor;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionSuperConstructor(self: *const Object) ?JSValue {
        if (self.functionPayloadConst()) |payload| return payload.super_constructor;
        return null;
    }

    pub fn functionCapturesSlot(self: *Object) *[]JSValue {
        if (self.functionPayload()) |payload| return &payload.captures;
        if (self.generatorPayload()) |payload| return &payload.captures;
        std.debug.assert(self.class_payload_kind == .function or self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn functionCaptures(self: *const Object) []JSValue {
        if (self.functionPayloadConst()) |payload| return payload.captures;
        if (self.generatorPayloadConst()) |payload| return payload.captures;
        return &.{};
    }

    pub fn functionEvalLocalNamesSlot(self: *Object) *[]atom.Atom {
        if (self.functionPayload()) |payload| return &payload.eval_local_names;
        if (self.generatorPayload()) |payload| return &payload.eval_local_names;
        std.debug.assert(self.class_payload_kind == .function or self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn functionEvalLocalNames(self: *const Object) []atom.Atom {
        if (self.functionPayloadConst()) |payload| return payload.eval_local_names;
        if (self.generatorPayloadConst()) |payload| return payload.eval_local_names;
        return &.{};
    }

    pub fn functionEvalLocalRefsSlot(self: *Object) *[]JSValue {
        if (self.functionPayload()) |payload| return &payload.eval_local_refs;
        if (self.generatorPayload()) |payload| return &payload.eval_local_refs;
        std.debug.assert(self.class_payload_kind == .function or self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn functionEvalLocalRefs(self: *const Object) []JSValue {
        if (self.functionPayloadConst()) |payload| return payload.eval_local_refs;
        if (self.generatorPayloadConst()) |payload| return payload.eval_local_refs;
        return &.{};
    }

    pub fn functionLexicalThisSlot(self: *Object) *?JSValue {
        if (self.functionPayload()) |payload| return &payload.lexical_this;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionLexicalThis(self: *const Object) ?JSValue {
        if (self.functionPayloadConst()) |payload| return payload.lexical_this;
        return null;
    }

    pub fn functionHomeObjectSlot(self: *Object) *?*Object {
        if (self.functionPayload()) |payload| return &payload.home_object;
        if (self.generatorPayload()) |payload| return &payload.home_object;
        std.debug.assert(self.class_payload_kind == .function or self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn functionHomeObject(self: *const Object) ?*Object {
        if (self.functionPayloadConst()) |payload| return payload.home_object;
        if (self.generatorPayloadConst()) |payload| return payload.home_object;
        return null;
    }

    /// Stores a strong `[[HomeObject]]` edge; callers must not write the slot directly.
    pub fn setFunctionHomeObject(self: *Object, rt: *JSRuntime, home_object: ?*Object) !void {
        const slot = self.functionHomeObjectSlot();
        if (slot.* == home_object) return;
        if (home_object) |next| gc.retain(&next.header);
        errdefer if (home_object) |next| next.value().free(rt);
        const old_home_object = slot.*;
        slot.* = home_object;
        if (old_home_object) |old| old.value().free(rt);
    }

    pub fn privateRemapFromSlot(self: *Object) *[]atom.Atom {
        if (self.ordinaryPayload()) |payload| return &payload.private_remap_from;
        if (self.functionPayload()) |payload| return &payload.private_remap_from;
        std.debug.assert(self.class_payload_kind == .ordinary or self.class_payload_kind == .function);
        unreachable;
    }

    pub fn privateRemapFromSlotEnsured(self: *Object, rt: *JSRuntime) !*[]atom.Atom {
        if (self.ordinaryPayload()) |payload| return &payload.private_remap_from;
        if (self.functionPayload()) |payload| return &payload.private_remap_from;
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.private_remap_from;
    }

    pub fn privateRemapFrom(self: *const Object) []atom.Atom {
        if (self.ordinaryPayloadConst()) |payload| return payload.private_remap_from;
        if (self.functionPayloadConst()) |payload| return payload.private_remap_from;
        return &.{};
    }

    pub fn privateRemapToSlot(self: *Object) *[]atom.Atom {
        if (self.ordinaryPayload()) |payload| return &payload.private_remap_to;
        if (self.functionPayload()) |payload| return &payload.private_remap_to;
        std.debug.assert(self.class_payload_kind == .ordinary or self.class_payload_kind == .function);
        unreachable;
    }

    pub fn privateRemapToSlotEnsured(self: *Object, rt: *JSRuntime) !*[]atom.Atom {
        if (self.ordinaryPayload()) |payload| return &payload.private_remap_to;
        if (self.functionPayload()) |payload| return &payload.private_remap_to;
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.private_remap_to;
    }

    pub fn privateRemapTo(self: *const Object) []atom.Atom {
        if (self.ordinaryPayloadConst()) |payload| return payload.private_remap_to;
        if (self.functionPayloadConst()) |payload| return payload.private_remap_to;
        return &.{};
    }

    pub fn setCallSiteMetadata(
        self: *Object,
        rt: *JSRuntime,
        file: JSValue,
        function_name: JSValue,
        line: i32,
        column: i32,
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
        return if (sites.flags.is_array) @intCast(sites.length) else 0;
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

    pub fn functionRealmGlobalSlot(self: *Object) *?JSValue {
        if (self.functionPayload()) |payload| return &payload.realm_global;
        if (self.boundFunctionPayload()) |payload| return &payload.realm_global;
        std.debug.assert(self.class_payload_kind == .function or self.class_payload_kind == .bound_function);
        unreachable;
    }

    pub fn functionRealmGlobal(self: *const Object) ?JSValue {
        if (self.functionPayloadConst()) |payload| return payload.realm_global;
        if (self.boundFunctionPayloadConst()) |payload| return payload.realm_global;
        return null;
    }

    pub fn functionRealmGlobalPtrSlot(self: *Object) *?*Object {
        if (self.ordinaryPayload()) |payload| return &payload.realm_global_ptr;
        if (self.arrayPayload()) |payload| return &payload.realm_global_ptr;
        if (self.objectDataPayload()) |payload| return &payload.realm_global_ptr;
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
        if (self.functionPayload()) |payload| return &payload.realm_global_ptr;
        if (self.generatorPayload()) |payload| return &payload.realm_global_ptr;
        std.debug.assert(self.class_payload_kind != .none);
        unreachable;
    }

    pub fn functionRealmGlobalPtrSlotEnsured(self: *Object, rt: *JSRuntime) !*?*Object {
        if (self.class_payload_kind == .none) {
            const payload = try self.ensureOrdinaryPayload(rt);
            return &payload.realm_global_ptr;
        }
        return self.functionRealmGlobalPtrSlot();
    }

    pub fn setFunctionRealmGlobalPtr(self: *Object, rt: *JSRuntime, realm_global: ?*Object) !void {
        const slot = try self.functionRealmGlobalPtrSlotEnsured(rt);
        if (realm_global != null) try rt.registerBorrowedReferenceHolder(self);
        slot.* = realm_global;
        if (realm_global == null) self.pruneBorrowedReferenceHolderIfEmpty(rt);
    }

    pub fn setFunctionRealmGlobalPtrIfNull(self: *Object, rt: *JSRuntime, realm_global: ?*Object) !void {
        const slot = try self.functionRealmGlobalPtrSlotEnsured(rt);
        if (slot.* == null) {
            if (realm_global != null) try rt.registerBorrowedReferenceHolder(self);
            slot.* = realm_global;
            if (realm_global == null) self.pruneBorrowedReferenceHolderIfEmpty(rt);
        }
    }

    pub fn functionRealmGlobalPtr(self: *const Object) ?*Object {
        if (self.ordinaryPayloadConst()) |payload| return payload.realm_global_ptr;
        if (self.arrayPayloadConst()) |payload| return payload.realm_global_ptr;
        if (self.objectDataPayloadConst()) |payload| return payload.realm_global_ptr;
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
        if (self.functionPayloadConst()) |payload| return payload.realm_global_ptr;
        if (self.generatorPayloadConst()) |payload| return payload.realm_global_ptr;
        return null;
    }

    fn ordinaryPayload(self: *Object) ?*OrdinaryPayload {
        if (self.class_payload_kind != .ordinary) return null;
        return @ptrCast(@alignCast(self.class_payload.?));
    }

    fn ordinaryPayloadConst(self: *const Object) ?*const OrdinaryPayload {
        if (self.class_payload_kind != .ordinary) return null;
        return @ptrCast(@alignCast(self.class_payload.?));
    }

    fn destroyOrdinaryPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.ordinaryPayload() orelse return;
        self.class_payload = null;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(OrdinaryPayload, payload);
    }

    fn iteratorPayload(self: *Object) ?*IteratorPayload {
        if (self.class_payload_kind != .iterator) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn iteratorPayloadConst(self: *const Object) ?*const IteratorPayload {
        if (self.class_payload_kind != .iterator) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyIteratorPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.iteratorPayload() orelse return;
        self.class_payload = null;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(IteratorPayload, payload);
    }

    fn collectionPayload(self: *Object) ?*CollectionPayload {
        if (self.class_payload_kind != .collection) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn collectionPayloadConst(self: *const Object) ?*const CollectionPayload {
        if (self.class_payload_kind != .collection) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyCollectionPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.collectionPayload() orelse return;
        self.class_payload = null;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(CollectionPayload, payload);
    }

    fn finalizationRegistryPayload(self: *Object) ?*FinalizationRegistryPayload {
        if (self.class_payload_kind != .finalization_registry) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn finalizationRegistryPayloadConst(self: *const Object) ?*const FinalizationRegistryPayload {
        if (self.class_payload_kind != .finalization_registry) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyFinalizationRegistryPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.finalizationRegistryPayload() orelse return;
        self.class_payload = null;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(FinalizationRegistryPayload, payload);
    }

    fn stdFilePayload(self: *Object) ?*StdFilePayload {
        if (self.class_payload_kind != .std_file) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn stdFilePayloadConst(self: *const Object) ?*const StdFilePayload {
        if (self.class_payload_kind != .std_file) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyStdFilePayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.stdFilePayload() orelse return;
        self.class_payload = null;
        self.class_payload_kind = .none;
        payload.destroy();
        rt.memory.destroy(StdFilePayload, payload);
    }

    fn disposableStackPayload(self: *Object) ?*DisposableStackPayload {
        if (self.class_payload_kind != .disposable_stack) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn disposableStackPayloadConst(self: *const Object) ?*const DisposableStackPayload {
        if (self.class_payload_kind != .disposable_stack) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyDisposableStackPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.disposableStackPayload() orelse return;
        self.class_payload = null;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(DisposableStackPayload, payload);
    }

    fn realmPayload(self: *Object) ?*RealmPayload {
        if (self.class_payload_kind != .realm) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn realmPayloadConst(self: *const Object) ?*const RealmPayload {
        if (self.class_payload_kind != .realm) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyRealmPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.realmPayload() orelse return;
        self.class_payload = null;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(RealmPayload, payload);
    }

    fn bufferPayload(self: *Object) ?*BufferPayload {
        if (self.class_payload_kind != .buffer) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn bufferPayloadConst(self: *const Object) ?*const BufferPayload {
        if (self.class_payload_kind != .buffer) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyBufferPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.bufferPayload() orelse return;
        self.class_payload = null;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(BufferPayload, payload);
    }

    fn typedArrayPayload(self: *Object) ?*TypedArrayPayload {
        if (self.class_payload_kind != .typed_array) return null;
        return @ptrCast(@alignCast(self.class_payload.?));
    }

    fn typedArrayPayloadConst(self: *const Object) ?*const TypedArrayPayload {
        if (self.class_payload_kind != .typed_array) return null;
        return @ptrCast(@alignCast(self.class_payload.?));
    }

    fn destroyTypedArrayPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.typedArrayPayload() orelse return;
        self.class_payload = null;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(TypedArrayPayload, payload);
    }

    fn regExpPayload(self: *Object) ?*RegExpPayload {
        if (self.class_payload_kind != .regexp) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn regExpPayloadConst(self: *const Object) ?*const RegExpPayload {
        if (self.class_payload_kind != .regexp) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyRegExpPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.regExpPayload() orelse return;
        self.class_payload = null;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(RegExpPayload, payload);
    }

    fn boundFunctionPayload(self: *Object) ?*BoundFunctionPayload {
        if (self.class_payload_kind != .bound_function) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn boundFunctionPayloadConst(self: *const Object) ?*const BoundFunctionPayload {
        if (self.class_payload_kind != .bound_function) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyBoundFunctionPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.boundFunctionPayload() orelse return;
        self.class_payload = null;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(BoundFunctionPayload, payload);
    }

    fn proxyPayload(self: *Object) ?*ProxyPayload {
        if (self.class_payload_kind != .proxy) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn proxyPayloadConst(self: *const Object) ?*const ProxyPayload {
        if (self.class_payload_kind != .proxy) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyProxyPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.proxyPayload() orelse return;
        self.class_payload = null;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(ProxyPayload, payload);
    }

    fn argumentsPayload(self: *Object) ?*ArgumentsPayload {
        if (self.class_payload_kind != .arguments) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn argumentsPayloadConst(self: *const Object) ?*const ArgumentsPayload {
        if (self.class_payload_kind != .arguments) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyArgumentsPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.argumentsPayload() orelse return;
        self.class_payload = null;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(ArgumentsPayload, payload);
    }

    fn objectDataPayload(self: *Object) ?*ObjectDataPayload {
        if (self.class_payload_kind != .object_data) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn objectDataPayloadConst(self: *const Object) ?*const ObjectDataPayload {
        if (self.class_payload_kind != .object_data) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyObjectDataPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.objectDataPayload() orelse return;
        self.class_payload = null;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(ObjectDataPayload, payload);
    }

    fn varRefPayload(self: *Object) ?*VarRefPayload {
        if (self.class_payload_kind != .var_ref) return null;
        return @ptrCast(@alignCast(self.class_payload.?));
    }

    fn varRefPayloadConst(self: *const Object) ?*const VarRefPayload {
        if (self.class_payload_kind != .var_ref) return null;
        return @ptrCast(@alignCast(self.class_payload.?));
    }

    fn destroyVarRefPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.varRefPayload() orelse return;
        self.class_payload = null;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(VarRefPayload, payload);
    }

    fn arrayPayload(self: *Object) ?*ArrayPayload {
        if (self.class_payload_kind != .array) return null;
        return @ptrCast(@alignCast(self.class_payload.?));
    }

    fn arrayPayloadConst(self: *const Object) ?*const ArrayPayload {
        if (self.class_payload_kind != .array) return null;
        return @ptrCast(@alignCast(self.class_payload.?));
    }

    fn destroyArrayPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.arrayPayload() orelse return;
        self.class_payload = null;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(ArrayPayload, payload);
    }

    fn promisePayload(self: *Object) ?*PromisePayload {
        if (self.class_payload_kind != .promise) return null;
        return @ptrCast(@alignCast(self.class_payload.?));
    }

    fn promisePayloadConst(self: *const Object) ?*const PromisePayload {
        if (self.class_payload_kind != .promise) return null;
        return @ptrCast(@alignCast(self.class_payload.?));
    }

    fn destroyPromisePayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.promisePayload() orelse return;
        self.class_payload = null;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(PromisePayload, payload);
    }

    fn generatorPayload(self: *Object) ?*GeneratorPayload {
        if (self.class_payload_kind != .generator) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn generatorPayloadConst(self: *const Object) ?*const GeneratorPayload {
        if (self.class_payload_kind != .generator) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyGeneratorPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.generatorPayload() orelse return;
        self.class_payload = null;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(GeneratorPayload, payload);
    }

    fn functionPayload(self: *Object) ?*FunctionPayload {
        if (self.class_payload_kind != .function) return null;
        return @ptrCast(@alignCast(self.class_payload.?));
    }

    fn functionPayloadConst(self: *const Object) ?*const FunctionPayload {
        if (self.class_payload_kind != .function) return null;
        return @ptrCast(@alignCast(self.class_payload.?));
    }

    fn destroyFunctionPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.functionPayload() orelse return;
        self.class_payload = null;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(FunctionPayload, payload);
    }

    pub fn moduleNamespacePayload(self: *Object) ?*ModuleNamespacePayload {
        if (self.class_payload_kind != .module_namespace) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    pub fn setModuleNamespaceCells(self: *Object, rt: *JSRuntime, next_cells: []JSValue) !void {
        const payload = self.moduleNamespacePayload() orelse {
            std.debug.assert(self.class_payload_kind == .module_namespace);
            unreachable;
        };
        try self.setValueSlice(rt, &payload.cells, next_cells);
    }

    fn moduleNamespacePayloadConst(self: *const Object) ?*const ModuleNamespacePayload {
        if (self.class_payload_kind != .module_namespace) return null;
        const ptr = self.class_payload orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn moduleNamespaceBindingValue(self: Object, atom_id: atom.Atom) ?JSValue {
        if (self.class_id != class.ids.module_ns) return null;
        const payload = @constCast(&self).moduleNamespacePayload() orelse return null;
        for (payload.names, 0..) |name, idx| {
            if (name != atom_id or idx >= payload.cells.len) continue;
            const cell = varRefCellFromValue(payload.cells[idx]) orelse return JSValue.undefinedValue();
            return if (cell.varRefValueSlot().*) |stored| stored.dup() else JSValue.undefinedValue();
        }
        return null;
    }

    pub fn moduleNamespaceOwnBindingValue(self: Object, atom_id: atom.Atom) ?JSValue {
        return self.moduleNamespaceBindingValue(atom_id);
    }

    fn destroyModuleNamespacePayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.moduleNamespacePayload() orelse return;
        self.class_payload = null;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(ModuleNamespacePayload, payload);
    }

    pub fn destroyRuntimeCycles(rt: *JSRuntime) usize {
        return rt.runObjectCycleRemoval();
    }

    fn traceChildren(rt: *JSRuntime, header: *gc.Header, visitor: anytype) void {
        switch (header.kind) {
            .object => {
                const obj: *Object = @alignCast(@fieldParentPtr("header", header));
                obj.traceChildEdgesNoFail(rt, visitor);
            },
            .function_bytecode => {
                const fb: *FunctionBytecode = @alignCast(@fieldParentPtr("header", header));
                if (fb.class_fields_init) |*stored| visitor.visitValue(stored);
                for (fb.cpool) |*stored| visitor.visitValue(stored);
            },
            else => {},
        }
    }

    const DecrefVisitor = struct {
        rt: *JSRuntime,

        pub fn visitValue(self: DecrefVisitor, val: *JSValue) void {
            if (val.refHeader()) |h| {
                if (h.kind == .object or h.kind == .function_bytecode) {
                    self.visitHeader(h);
                }
            } else if (val.objectHeader()) |h| {
                self.visitHeader(h);
            }
        }

        pub fn visitObject(self: DecrefVisitor, obj_ptr: *?*Object) void {
            if (obj_ptr.*) |obj| {
                if (@intFromPtr(obj) == 0) return;
                self.visitHeader(&obj.header);
            }
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
            _ = self;
            _ = entry;
        }

        fn visitHeader(self: DecrefVisitor, h: *gc.Header) void {
            _ = self;
            if (h.rc == 0) return;
            h.rc -= 1;
        }
    };

    const ScanIncrefVisitor = struct {
        rt: *JSRuntime,

        pub fn visitValue(self: ScanIncrefVisitor, val: *JSValue) void {
            if (val.refHeader()) |h| {
                if (h.kind == .object or h.kind == .function_bytecode) {
                    self.visitHeader(h);
                }
            } else if (val.objectHeader()) |h| {
                self.visitHeader(h);
            }
        }

        pub fn visitObject(self: ScanIncrefVisitor, obj_ptr: *?*Object) void {
            if (obj_ptr.*) |obj| {
                if (@intFromPtr(obj) == 0) return;
                self.visitHeader(&obj.header);
            }
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
            _ = self;
            _ = entry;
        }

        fn visitHeader(self: ScanIncrefVisitor, h: *gc.Header) void {
            h.rc += 1;
            if (h.flags.mark) {
                h.flags.mark = false;
                traceChildren(self.rt, h, self);
            }
        }
    };

    const ScanRestoreVisitor = struct {
        rt: *JSRuntime,

        pub fn visitValue(self: ScanRestoreVisitor, val: *JSValue) void {
            if (val.refHeader()) |h| {
                if (h.kind == .object or h.kind == .function_bytecode) {
                    self.visitHeader(h);
                }
            } else if (val.objectHeader()) |h| {
                self.visitHeader(h);
            }
        }

        pub fn visitObject(self: ScanRestoreVisitor, obj_ptr: *?*Object) void {
            if (obj_ptr.*) |obj| {
                if (@intFromPtr(obj) == 0) return;
                self.visitHeader(&obj.header);
            }
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
            _ = self;
            _ = entry;
        }

        fn visitHeader(self: ScanRestoreVisitor, h: *gc.Header) void {
            _ = self;
            h.rc += 1;
        }
    };

    fn unlinkNodeFromList(head: *?*gc.GcNode, tail: *?*gc.GcNode, node: *gc.GcNode) void {
        if (node.prev) |prev| {
            prev.next = node.next;
        } else {
            head.* = node.next;
        }
        if (node.next) |next| {
            next.prev = node.prev;
        } else {
            tail.* = node.prev;
        }
        node.prev = null;
        node.next = null;
    }

    fn linkNodeToList(head: *?*gc.GcNode, tail: *?*gc.GcNode, node: *gc.GcNode) void {
        node.prev = tail.*;
        node.next = null;
        if (tail.*) |t| {
            t.next = node;
        } else {
            head.* = node;
        }
        tail.* = node;
    }

    pub fn destroyRuntimeCyclesWithValueRoots(rt: *JSRuntime, roots: ?*const runtime_mod.ValueRootFrame) ObjectGraphError!usize {
        rt.gc.stats.collections += 1;

        // Phase 1: gc_decref
        {
            var current = rt.gc.gc_obj_list_head;
            while (current) |node| : (current = node.next) {
                const h = gc.headerFromGcNode(node);
                h.flags.mark = true;
            }

            current = rt.gc.gc_obj_list_head;
            while (current) |node| : (current = node.next) {
                const h = gc.headerFromGcNode(node);
                traceChildren(rt, h, DecrefVisitor{ .rt = rt });
            }
        }

        // Phase 2: gc_scan
        {
            var current = rt.gc.gc_obj_list_head;
            while (current) |node| : (current = node.next) {
                const h = gc.headerFromGcNode(node);
                if (h.rc > 0 and h.flags.mark) {
                    h.flags.mark = false;
                    traceChildren(rt, h, ScanIncrefVisitor{ .rt = rt });
                }
            }
        }

        // Phase 3: move dead cycles to tmp_head
        var tmp_head: ?*gc.GcNode = null;
        var tmp_tail: ?*gc.GcNode = null;
        defer {
            var current = tmp_head;
            while (current) |node| {
                const next = node.next;
                const h = gc.headerFromGcNode(node);
                unlinkNodeFromList(&tmp_head, &tmp_tail, node);
                linkNodeToList(&rt.gc.gc_obj_list_head, &rt.gc.gc_obj_list_tail, node);
                h.flags.mark = false;
                current = next;
            }
        }
        {
            var current = rt.gc.gc_obj_list_head;
            while (current) |node| {
                const next = node.next;
                const h = gc.headerFromGcNode(node);
                if (h.flags.mark) {
                    unlinkNodeFromList(&rt.gc.gc_obj_list_head, &rt.gc.gc_obj_list_tail, node);
                    linkNodeToList(&tmp_head, &tmp_tail, node);
                }
                current = next;
            }
        }

        // Phase 3b: restore refcounts of all objects in tmp_head (to be deleted)
        {
            var current = tmp_head;
            while (current) |node| : (current = node.next) {
                const h = gc.headerFromGcNode(node);
                traceChildren(rt, h, ScanRestoreVisitor{ .rt = rt });
            }
        }

        // Initialize the per-header cycle-scan bits. These traversals touch every
        // candidate node, so bits possibly left set by a previous (early-exited)
        // round are unconditionally reset here before any query.
        // visited bit: object participates in this scan.
        // preserved bit: object is currently known live.
        // Free/garbage membership is derived as (cycle_visited and !cycle_preserved).
        var preserved_count: usize = 0;
        {
            var current = rt.gc.gc_obj_list_head;
            while (current) |node| : (current = node.next) {
                const h = gc.headerFromGcNode(node);
                if (h.kind == .object) {
                    h.flags.cycle_visited = true;
                    h.flags.cycle_preserved = true;
                    preserved_count += 1;
                }
            }
        }
        {
            var current = tmp_head;
            while (current) |node| : (current = node.next) {
                const h = gc.headerFromGcNode(node);
                if (h.kind == .object) {
                    h.flags.cycle_visited = true;
                    h.flags.cycle_preserved = false;
                }
            }
        }

        var symbol_roots = SymbolRootSet.init(rt.memory.allocator);
        defer symbol_roots.deinit();
        try seedSymbolRootsFromRuntimeHeldValues(rt, roots, &symbol_roots);

        try scanPreservedWeakAndFinalizationEdges(rt, tmp_head, &symbol_roots, &preserved_count);

        const ResurrectHelper = struct {
            pub fn scanAndPreserveValue(
                runtime: *JSRuntime,
                preserved_bytecodes: *ObjectVisitSet,
                symbol_roots_set: *SymbolRootSet,
                object_worklist: *std.ArrayList(*Object),
                bytecode_worklist: *std.ArrayList(*FunctionBytecode),
                val: JSValue,
            ) ObjectGraphError!void {
                try preserveSymbolValue(runtime, symbol_roots_set, val);
                if (objectFromValue(val)) |obj| {
                    if (obj.header.flags.cycle_visited and !obj.header.flags.cycle_preserved) {
                        obj.header.flags.cycle_preserved = true;
                        try object_worklist.append(runtime.memory.persistent_allocator, obj);
                        runtime.gc.recordMarkStackDepth(object_worklist.items.len + bytecode_worklist.items.len);
                    }
                } else if (functionBytecodeFromValue(val)) |const_fb| {
                    const fb = @constCast(const_fb);
                    const addr = @intFromPtr(fb);
                    const entry = try preserved_bytecodes.getOrPut(addr);
                    if (!entry.found_existing) {
                        try bytecode_worklist.append(runtime.memory.persistent_allocator, fb);
                        runtime.gc.recordMarkStackDepth(object_worklist.items.len + bytecode_worklist.items.len);
                    }
                }
            }

            pub fn scanBytecodeChildObjectsAndBytecodes(
                runtime: *JSRuntime,
                preserved_bytecodes: *ObjectVisitSet,
                symbol_roots_set: *SymbolRootSet,
                object_worklist: *std.ArrayList(*Object),
                bytecode_worklist: *std.ArrayList(*FunctionBytecode),
                fb: *FunctionBytecode,
            ) ObjectGraphError!void {
                if (fb.class_fields_init) |val| {
                    try scanAndPreserveValue(runtime, preserved_bytecodes, symbol_roots_set, object_worklist, bytecode_worklist, val);
                }
                for (fb.cpool) |val| {
                    try scanAndPreserveValue(runtime, preserved_bytecodes, symbol_roots_set, object_worklist, bytecode_worklist, val);
                }
            }
        };

        const ObjectResurrectVisitor = struct {
            rt: *JSRuntime,
            preserved_bytecodes: *ObjectVisitSet,
            symbol_roots_set: *SymbolRootSet,
            object_worklist: *std.ArrayList(*Object),
            bytecode_worklist: *std.ArrayList(*FunctionBytecode),
            err: ?ObjectGraphError = null,

            pub fn visitObject(self: *@This(), obj_ptr: *?*Object) ObjectGraphError!void {
                if (obj_ptr.*) |obj| {
                    if (@intFromPtr(obj) == 0) return;
                    if (obj.header.flags.cycle_visited and !obj.header.flags.cycle_preserved) {
                        obj.header.flags.cycle_preserved = true;
                        try self.object_worklist.append(self.rt.memory.persistent_allocator, obj);
                        self.rt.gc.recordMarkStackDepth(self.object_worklist.items.len + self.bytecode_worklist.items.len);
                    }
                }
            }

            pub fn visitValue(self: *@This(), val_ptr: *JSValue) ObjectGraphError!void {
                try ResurrectHelper.scanAndPreserveValue(
                    self.rt,
                    self.preserved_bytecodes,
                    self.symbol_roots_set,
                    self.object_worklist,
                    self.bytecode_worklist,
                    val_ptr.*,
                );
            }

            pub fn visitSymbol(self: *@This(), sym_ptr: *atom.Atom) ObjectGraphError!void {
                try preserveSymbolAtom(self.rt, self.symbol_roots_set, sym_ptr.*);
            }

            pub fn visitWeakCollectionEntry(self: *@This(), entry: *WeakCollectionEntry) ObjectGraphError!void {
                _ = self;
                _ = entry;
            }

            pub fn visitFinalizationCell(self: *@This(), entry: *FinalizationRegistryCell) ObjectGraphError!void {
                _ = self;
                _ = entry;
            }
        };

        var preserved_bytecodes = &rt.gc.preserved_bytecodes;
        preserved_bytecodes.clearRetainingCapacity();

        var object_worklist = &rt.gc.object_worklist;
        object_worklist.clearRetainingCapacity();

        var bytecode_worklist = &rt.gc.bytecode_worklist;
        bytecode_worklist.clearRetainingCapacity();

        // Initialize object worklist with all objects currently preserved. At this
        // point preserved objects live either on the live list (all of them) or on
        // the garbage list (resurrected via weak/finalization edges, not yet moved).
        {
            const list_heads = [2]?*gc.GcNode{ rt.gc.gc_obj_list_head, tmp_head };
            for (list_heads) |list_head| {
                var current = list_head;
                while (current) |node| : (current = node.next) {
                    const h = gc.headerFromGcNode(node);
                    if (h.kind == .object and h.flags.cycle_preserved) {
                        const obj: *Object = @alignCast(@fieldParentPtr("header", h));
                        try object_worklist.append(rt.memory.persistent_allocator, obj);
                        rt.gc.recordMarkStackDepth(object_worklist.items.len + bytecode_worklist.items.len);
                    }
                }
            }
        }

        // Fixed-point transitive resurrection loop
        while (object_worklist.items.len > 0 or bytecode_worklist.items.len > 0) {
            while (object_worklist.items.len > 0) {
                const obj = object_worklist.pop().?;
                rt.gc.recordMarkStackDepth(object_worklist.items.len + bytecode_worklist.items.len);
                var visitor = ObjectResurrectVisitor{
                    .rt = rt,
                    .preserved_bytecodes = preserved_bytecodes,
                    .symbol_roots_set = &symbol_roots,
                    .object_worklist = object_worklist,
                    .bytecode_worklist = bytecode_worklist,
                };
                try obj.traceChildEdgesFallible(rt, &visitor);
            }

            while (bytecode_worklist.items.len > 0) {
                const fb = bytecode_worklist.pop().?;
                rt.gc.recordMarkStackDepth(object_worklist.items.len + bytecode_worklist.items.len);
                try ResurrectHelper.scanBytecodeChildObjectsAndBytecodes(
                    rt,
                    preserved_bytecodes,
                    &symbol_roots,
                    object_worklist,
                    bytecode_worklist,
                    fb,
                );
            }
        }

        // Move newly-preserved objects and bytecodes back to live list
        {
            var current = tmp_head;
            while (current) |node| {
                const next = node.next;
                const h = gc.headerFromGcNode(node);
                if (h.kind == .object) {
                    if (h.flags.cycle_preserved) {
                        unlinkNodeFromList(&tmp_head, &tmp_tail, node);
                        linkNodeToList(&rt.gc.gc_obj_list_head, &rt.gc.gc_obj_list_tail, node);
                        h.flags.mark = false;
                    }
                } else if (h.kind == .function_bytecode) {
                    const fb: *FunctionBytecode = @alignCast(@fieldParentPtr("header", h));
                    if (preserved_bytecodes.contains(@intFromPtr(fb))) {
                        unlinkNodeFromList(&tmp_head, &tmp_tail, node);
                        linkNodeToList(&rt.gc.gc_obj_list_head, &rt.gc.gc_obj_list_tail, node);
                        h.flags.mark = false;
                    }
                }
                current = next;
            }
        }

        // Free/garbage membership needs no re-sync: it is derived from the header
        // bits as (cycle_visited and !cycle_preserved), which now exactly matches
        // the objects remaining on the garbage list.

        var free_internal_bytecodes = ObjectVisitSet.init(rt.memory.allocator);
        defer free_internal_bytecodes.deinit();
        {
            var current = tmp_head;
            while (current) |node| : (current = node.next) {
                const h = gc.headerFromGcNode(node);
                if (h.kind == .function_bytecode) {
                    const fb: *FunctionBytecode = @alignCast(@fieldParentPtr("header", h));
                    try free_internal_bytecodes.put(@intFromPtr(fb), {});
                }
            }
        }

        // Snapshot all preserved objects (after the move-back they are exactly the
        // live-list objects with the preserved bit set). The snapshot keeps the
        // guard/unguard loops below safe against list mutation while weak sweeping
        // and guard release may destroy nodes. The object worklist is empty here,
        // so reuse its buffer.
        std.debug.assert(object_worklist.items.len == 0);
        {
            var current = rt.gc.gc_obj_list_head;
            while (current) |node| : (current = node.next) {
                const h = gc.headerFromGcNode(node);
                if (h.kind == .object and h.flags.cycle_preserved) {
                    const obj: *Object = @alignCast(@fieldParentPtr("header", h));
                    try object_worklist.append(rt.memory.persistent_allocator, obj);
                }
            }
        }
        const preserved_objects: []const *Object = object_worklist.items;

        // Temporarily increment ref counts of all preserved objects and bytecodes
        // to prevent them from being destroyed/freed during weak entries sweeping.
        for (preserved_objects) |current| {
            current.header.rc += 1;
        }
        {
            var iterator = preserved_bytecodes.keyIterator();
            while (iterator.next()) |address| {
                const fb: *FunctionBytecode = @ptrFromInt(address.*);
                fb.header.rc += 1;
            }
        }

        sweepDeadWeakEntries(rt, preserved_objects, &symbol_roots, &free_internal_bytecodes);
        const WeakPersistentSweepContext = struct {
            rt: *const JSRuntime,
            symbol_roots: *const SymbolRootSet,

            pub fn isWeakIdentityAlive(self: @This(), identity: usize) bool {
                return weakEntryKeyIsPreserved(self.rt, self.symbol_roots, identity);
            }
        };
        rt.sweepDeadWeakPersistentSlots(WeakPersistentSweepContext{
            .rt = rt,
            .symbol_roots = &symbol_roots,
        });
        _ = rt.atoms.sweepUnrootedUniqueSymbols(&symbol_roots);

        // Decrement protected ref counts back to normal and release any that reached 0.
        for (preserved_objects) |current| {
            current.header.rc -= 1;
            if (current.header.rc == 0) {
                current.header.rc = 1;
                gc.release(rt, &current.header);
            }
        }
        {
            var iterator = preserved_bytecodes.keyIterator();
            while (iterator.next()) |address| {
                const fb: *FunctionBytecode = @ptrFromInt(address.*);
                fb.header.rc -= 1;
                if (fb.header.rc == 0) {
                    fb.header.rc = 1;
                    gc.release(rt, &fb.header);
                }
            }
        }

        var garbage_count: usize = 0;
        {
            var current = tmp_head;
            while (current) |node| : (current = node.next) {
                const h = gc.headerFromGcNode(node);
                if (h.kind == .object) garbage_count += 1;
            }
        }

        const old_phase = rt.gc.phase;
        rt.gc.phase = .remove_cycles;
        defer rt.gc.phase = old_phase;

        if (garbage_count == 0) {
            var current = tmp_head;
            while (current) |node| : (current = node.next) {
                const h = gc.headerFromGcNode(node);
                if (h.kind == .function_bytecode) {
                    const fb: *FunctionBytecode = @alignCast(@fieldParentPtr("header", h));
                    clearFunctionBytecodeReferencesToVisited(rt, fb, &free_internal_bytecodes);
                }
            }

            current = tmp_head;
            while (current) |node| {
                const next = node.next;
                const h = gc.headerFromGcNode(node);
                if (h.kind == .function_bytecode) {
                    unlinkNodeFromList(&tmp_head, &tmp_tail, node);
                    rt.gc.unlinkObjectWithBytes(h, gc.Registry.heapByteSizeFromHeader(rt, h));
                    function_bytecode_mod.destroyFromHeader(rt, h);
                }
                current = next;
            }
            return 0;
        }

        var current_garbage = tmp_head;
        while (current_garbage) |node| : (current_garbage = node.next) {
            const h = gc.headerFromGcNode(node);
            if (h.kind == .object) {
                const obj: *Object = @alignCast(@fieldParentPtr("header", h));
                try obj.clearReferencesToVisited(rt, &free_internal_bytecodes);
            } else if (h.kind == .function_bytecode) {
                const fb: *FunctionBytecode = @alignCast(@fieldParentPtr("header", h));
                clearFunctionBytecodeReferencesToVisited(rt, fb, &free_internal_bytecodes);
            }
        }

        const freed = garbage_count;

        current_garbage = tmp_head;
        while (current_garbage) |node| {
            const next = node.next;
            const h = gc.headerFromGcNode(node);
            unlinkNodeFromList(&tmp_head, &tmp_tail, node);
            if (h.kind == .object) {
                destroyFromHeader(rt, h);
            } else if (h.kind == .function_bytecode) {
                rt.gc.unlinkObjectWithBytes(h, gc.Registry.heapByteSizeFromHeader(rt, h));
                function_bytecode_mod.destroyFromHeader(rt, h);
            }
            current_garbage = next;
        }

        return freed;
    }

    pub fn releaseCallbackOwnedFunctionBytecodeCycles(rt: *JSRuntime) void {
        var candidates = ObjectVisitSet.init(rt.memory.allocator);
        defer candidates.deinit();

        var current = rt.gc.gc_obj_list_head;
        while (current) |node| : (current = node.next) {
            const h = gc.headerFromGcNode(node);
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
                const ref_count = function_bytecode.header.rc;
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
        var current = rt.gc.gc_obj_list_tail;
        while (current) |node| {
            const prev = node.prev;
            const h = gc.headerFromGcNode(node);
            const fb_ptr = if (h.kind == .function_bytecode) @as(*FunctionBytecode, @alignCast(@fieldParentPtr("header", h))) else null;
            if (fb_ptr) |fb| {
                if (candidates.contains(@intFromPtr(fb))) {
                    gc.release(rt, h);
                }
            }
            current = prev;
        }
    }

    fn clearCallbackOwnedFunctionBytecodeCycleRefs(
        rt: *JSRuntime,
        function_bytecode: *FunctionBytecode,
        candidates: *const ObjectVisitSet,
    ) void {
        if (function_bytecode.class_fields_init) |*stored| {
            if (valueReferencesFunctionBytecodeCandidate(stored.*, candidates)) {
                const old_value = stored.*;
                function_bytecode.class_fields_init = null;
                old_value.free(rt);
            }
        }
        for (function_bytecode.cpool) |*stored| {
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
        if (stored_header.kind != .object) return null;
        return @fieldParentPtr("header", stored_header);
    }

    const PayloadCollectContext = struct {
        rt: *JSRuntime,
        visited: *ObjectVisitSet,
    };

    const PayloadPreserveContext = struct {
        rt: *JSRuntime,
        visited: *const ObjectVisitSet,
        preserved: *ObjectVisitSet,
        symbol_roots: *SymbolRootSet,
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
        if (self.class_payload == null) return false;
        return rt.classes.markPayload(self.class_id, @ptrCast(rt), @ptrCast(self), &self.class_payload, visitor);
    }

    fn countPayloadFunctionBytecodeRef(context_ptr: *anyopaque, value_ptr: *anyopaque) void {
        const context: *PayloadBytecodeRefCountContext = @ptrCast(@alignCast(context_ptr));
        const stored: *JSValue = @ptrCast(@alignCast(value_ptr));
        context.count += countFunctionBytecodeValueRef(stored.*, context.function_bytecode);
    }

    fn collectReachableObjects(rt: *JSRuntime, visited: *ObjectVisitSet, current: *Object) ObjectGraphError!void {
        if (current.header.rc == 0) return;
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

        try Helper.callVisitObject(visitor, &self.prototype);
        if (self.ordinaryPayload()) |payload| {
            try Helper.callVisitObject(visitor, &payload.global_lexicals);
            if (payload.shared_lazy_native_functions) |cache| {
                for (cache) |*maybe_cached| {
                    try Helper.traceOptValue(visitor, maybe_cached);
                }
            }
        }
        if (self.iteratorPayload()) |payload| try Helper.traceOptValue(visitor, &payload.cached_next);
        // Property key atoms (including symbol keys) live in the shape;
        // visit them from there. Visitors only read symbol atoms (set
        // insertion / no-op), so revisiting a shared shape from several
        // objects is safe.
        for (self.shape_ref.props[0..self.shape_ref.prop_count]) |*prop| {
            try Helper.callVisitSymbol(visitor, &prop.atom_id);
        }
        for (self.properties) |*entry| {
            switch (entry.slot) {
                .data => |*stored| try Helper.callVisitValue(visitor, stored),
                .accessor => |*stored_accessor| {
                    try Helper.callVisitValue(visitor, &stored_accessor.getter);
                    try Helper.callVisitValue(visitor, &stored_accessor.setter);
                },
                else => {},
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
        }
        for (self.arrayElements()) |*maybe_value| {
            try Helper.traceOptValue(visitor, maybe_value);
        }
        if (self.typedArrayPayload()) |payload| {
            try Helper.traceOptValue(visitor, &payload.buffer);
        }
        if (self.objectDataPayload()) |payload| {
            try Helper.traceOptValue(visitor, &payload.data);
        }
        if (self.functionPayload()) |payload| {
            try Helper.traceOptValue(visitor, &payload.source);
            try Helper.traceOptValue(visitor, &payload.bytecode);
            try Helper.traceOptValue(visitor, &payload.class_fields_init);
            for (payload.captures) |*stored| try Helper.callVisitValue(visitor, stored);
            for (payload.eval_local_refs) |*stored| try Helper.callVisitValue(visitor, stored);
            try Helper.traceOptValue(visitor, &payload.eval_parent_function);
            try Helper.traceOptValue(visitor, &payload.import_meta);
            try Helper.traceOptValue(visitor, &payload.lexical_this);
            try Helper.traceOptValue(visitor, &payload.arrow_constructor_this);
            try Helper.traceOptValue(visitor, &payload.arrow_new_target);
            try Helper.traceOptValue(visitor, &payload.super_constructor);
            try Helper.callVisitObject(visitor, &payload.home_object);
            try Helper.traceOptValue(visitor, &payload.realm_global);
            for (&payload.primitive_prototypes) |*slot| {
                try Helper.traceOptValue(visitor, slot);
            }
            try Helper.traceOptValue(visitor, &payload.proxy_revoke_target);
            try Helper.traceOptValue(visitor, &payload.promise_capability_slot);
            try Helper.traceOptValue(visitor, &payload.promise_resolving_target);
            try Helper.traceOptValue(visitor, &payload.promise_resolving_state);
            try Helper.traceOptValue(visitor, &payload.promise_thenable_target);
            try Helper.traceOptValue(visitor, &payload.promise_thenable_this);
            try Helper.traceOptValue(visitor, &payload.promise_thenable_then);
            try Helper.traceOptValue(visitor, &payload.promise_reaction_record);
            try Helper.traceOptValue(visitor, &payload.promise_reaction_value);
            try Helper.traceOptValue(visitor, &payload.promise_combinator_state);
            try Helper.traceOptValue(visitor, &payload.promise_finally_payload);
            try Helper.traceOptValue(visitor, &payload.promise_finally_callback);
            try Helper.traceOptValue(visitor, &payload.promise_finally_constructor);
            try Helper.traceOptValue(visitor, &payload.async_dispose_stack);
            try Helper.traceOptValue(visitor, &payload.async_function_continuation);
            try Helper.traceOptValue(visitor, &payload.realm_type_error_constructor);
            if (payload.regexp_legacy_statics) |legacy| {
                try Helper.traceOptValue(visitor, &legacy.input);
                try Helper.traceOptValue(visitor, &legacy.last_match);
                try Helper.traceOptValue(visitor, &legacy.last_paren);
                try Helper.traceOptValue(visitor, &legacy.left_context);
                try Helper.traceOptValue(visitor, &legacy.right_context);
                for (&legacy.captures) |*slot| {
                    try Helper.traceOptValue(visitor, slot);
                }
            }
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
            try Helper.traceOptValue(visitor, &payload.bytecode);
            for (payload.captures) |*stored| try Helper.callVisitValue(visitor, stored);
            for (payload.eval_local_refs) |*stored| try Helper.callVisitValue(visitor, stored);
            try Helper.traceOptValue(visitor, &payload.this_value);
            for (payload.args) |*stored| try Helper.callVisitValue(visitor, stored);
            for (payload.stack) |*stored| try Helper.callVisitValue(visitor, stored);
            for (payload.frame_locals) |*stored| try Helper.callVisitValue(visitor, stored);
            for (payload.frame_args) |*stored| try Helper.callVisitValue(visitor, stored);
            for (payload.frame_var_refs) |*stored| try Helper.callVisitValue(visitor, stored);
            try Helper.traceOptValue(visitor, &payload.current_function);
            try Helper.traceOptValue(visitor, &payload.yield_star_iterator);
            try Helper.traceOptValue(visitor, &payload.async_promise);
            try Helper.callVisitObject(visitor, &payload.home_object);
        }
        if (self.varRefPayload()) |payload| {
            try Helper.traceOptValue(visitor, &payload.value);
        }
        if (self.argumentsPayload()) |payload| {
            for (payload.var_refs) |*stored| try Helper.callVisitValue(visitor, stored);
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
        if (self.regExpPayload()) |payload| {
            try Helper.traceOptValue(visitor, &payload.source);
            try Helper.traceOptValue(visitor, &payload.flags);
            try Helper.traceOptValue(visitor, &payload.last_index);
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
                    try collectValueObject(cv.rt, cv.visited, entry.unregister_token);
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
        if (function_bytecode.class_fields_init) |stored| try collectValueObject(rt, visited, stored);
        for (function_bytecode.cpool) |stored| try collectValueObject(rt, visited, stored);
    }

    fn seedSymbolRootsFromRuntimeHeldValues(rt: *JSRuntime, roots: ?*const runtime_mod.ValueRootFrame, symbol_roots: *SymbolRootSet) ObjectGraphError!void {
        var function_bytecodes = ObjectVisitSet.init(rt.memory.allocator);
        defer function_bytecodes.deinit();

        for (rt.external_symbol_roots) |atom_id| try preserveSymbolAtom(rt, symbol_roots, atom_id);

        const ContextRootVisitor = struct {
            rt: *JSRuntime,
            symbol_roots: *SymbolRootSet,
            function_bytecodes: *ObjectVisitSet,

            fn visitValue(context: *anyopaque, slot: *JSValue) runtime_mod.RootTraceError!void {
                const self: *@This() = @ptrCast(@alignCast(context));
                try scanSymbolRootValue(self.rt, self.symbol_roots, self.function_bytecodes, slot.*);
            }

            fn visitObject(context: *anyopaque, slot: *?*Object) runtime_mod.RootTraceError!void {
                const self: *@This() = @ptrCast(@alignCast(context));
                if (slot.*) |object| try scanSymbolRootObject(self.rt, self.symbol_roots, self.function_bytecodes, object);
            }
        };
        var context_root_visitor_state = ContextRootVisitor{
            .rt = rt,
            .symbol_roots = symbol_roots,
            .function_bytecodes = &function_bytecodes,
        };
        var context_root_visitor = runtime_mod.RootVisitor{
            .context = &context_root_visitor_state,
            .visit_value = ContextRootVisitor.visitValue,
            .visit_object = ContextRootVisitor.visitObject,
        };
        try rt.traceRoots(roots, &context_root_visitor);
        try scanSymbolRootModuleRegistry(rt, symbol_roots, &function_bytecodes);
    }

    fn scanSymbolRootModuleRegistry(
        rt: *JSRuntime,
        symbol_roots: *SymbolRootSet,
        function_bytecodes: *ObjectVisitSet,
    ) ObjectGraphError!void {
        for (rt.modules.modules) |record| {
            if (record.import_meta) |stored| try scanSymbolRootValue(rt, symbol_roots, function_bytecodes, stored);
            for (record.local_bindings) |binding| {
                try scanSymbolRootValue(rt, symbol_roots, function_bytecodes, binding.cell);
            }
        }
    }

    fn preserveSymbolValue(rt: *JSRuntime, symbol_roots: *SymbolRootSet, stored: JSValue) ObjectGraphError!void {
        const atom_id = stored.asSymbolAtom() orelse return;
        try preserveSymbolAtom(rt, symbol_roots, atom_id);
    }

    fn scanSymbolRootValue(
        rt: *JSRuntime,
        symbol_roots: *SymbolRootSet,
        function_bytecodes: *ObjectVisitSet,
        stored: JSValue,
    ) ObjectGraphError!void {
        try preserveSymbolValue(rt, symbol_roots, stored);
        if (objectFromValue(stored)) |child| {
            try scanSymbolRootObject(rt, symbol_roots, function_bytecodes, child);
            return;
        }
        const function_bytecode = functionBytecodeFromValue(stored) orelse return;
        try scanSymbolRootFunctionBytecode(rt, symbol_roots, function_bytecodes, function_bytecode);
    }

    fn scanSymbolRootObject(
        rt: *JSRuntime,
        symbol_roots: *SymbolRootSet,
        visited: *ObjectVisitSet,
        self: *Object,
    ) ObjectGraphError!void {
        const address = @intFromPtr(self);
        const visit = try visited.getOrPut(address);
        if (visit.found_existing) return;

        const ScanSymbolRootVisitor = struct {
            rt: *JSRuntime,
            symbol_roots: *SymbolRootSet,
            visited: *ObjectVisitSet,
            err: ?ObjectGraphError = null,

            pub fn visitObject(sv: *@This(), obj_ptr: *?*Object) !void {
                if (obj_ptr.*) |obj| {
                    if (@intFromPtr(obj) == 0) return;
                    try scanSymbolRootObject(sv.rt, sv.symbol_roots, sv.visited, obj);
                }
            }

            pub fn visitValue(sv: *@This(), val_ptr: *JSValue) !void {
                try scanSymbolRootValue(sv.rt, sv.symbol_roots, sv.visited, val_ptr.*);
            }

            pub fn visitSymbol(sv: *@This(), sym_ptr: *atom.Atom) !void {
                try preserveSymbolAtom(sv.rt, sv.symbol_roots, sym_ptr.*);
            }

            pub fn visitWeakCollectionEntry(sv: *@This(), entry: *WeakCollectionEntry) !void {
                _ = sv;
                _ = entry;
            }

            pub fn visitFinalizationCell(sv: *@This(), entry: *FinalizationRegistryCell) !void {
                if (entry.keepsHeldValuesAlive()) {
                    try scanSymbolRootValue(sv.rt, sv.symbol_roots, sv.visited, entry.held_value);
                    try scanSymbolRootValue(sv.rt, sv.symbol_roots, sv.visited, entry.unregister_token);
                }
            }
        };
        var visitor = ScanSymbolRootVisitor{ .rt = rt, .symbol_roots = symbol_roots, .visited = visited };
        try self.traceChildEdgesFallible(rt, &visitor);
    }

    fn scanSymbolRootFunctionBytecode(
        rt: *JSRuntime,
        symbol_roots: *SymbolRootSet,
        function_bytecodes: *ObjectVisitSet,
        function_bytecode: *const FunctionBytecode,
    ) ObjectGraphError!void {
        const visit = try function_bytecodes.getOrPut(@intFromPtr(&function_bytecode.header));
        if (visit.found_existing) return;
        if (function_bytecode.class_fields_init) |stored| try scanSymbolRootValue(rt, symbol_roots, function_bytecodes, stored);
        for (function_bytecode.cpool) |stored| try scanSymbolRootValue(rt, symbol_roots, function_bytecodes, stored);
    }

    fn preserveSymbolAtom(rt: *JSRuntime, symbol_roots: *SymbolRootSet, atom_id: atom.Atom) ObjectGraphError!void {
        if (rt.atoms.kind(atom_id) != .symbol) return;
        try symbol_roots.put(atom_id, {});
    }

    fn scanPreservedObjects(
        rt: *JSRuntime,
        symbol_roots: *SymbolRootSet,
        preserved_count: *usize,
        current: *Object,
    ) ObjectGraphError!void {
        if (!current.header.flags.cycle_visited) return;
        if (current.header.flags.cycle_preserved) return;
        current.header.flags.cycle_preserved = true;
        preserved_count.* += 1;
        try current.scanPreservedChildObjects(rt, symbol_roots, preserved_count);
    }

    fn scanPreservedChildObjects(
        self: *Object,
        rt: *JSRuntime,
        symbol_roots: *SymbolRootSet,
        preserved_count: *usize,
    ) ObjectGraphError!void {
        const ScanPreservedVisitor = struct {
            rt: *JSRuntime,
            symbol_roots: *SymbolRootSet,
            preserved_count: *usize,
            err: ?ObjectGraphError = null,

            pub fn visitObject(sv: *@This(), obj_ptr: *?*Object) !void {
                if (obj_ptr.*) |obj| {
                    if (@intFromPtr(obj) == 0) return;
                    try scanPreservedObjects(sv.rt, sv.symbol_roots, sv.preserved_count, obj);
                }
            }

            pub fn visitValue(sv: *@This(), val_ptr: *JSValue) !void {
                try scanPreservedValueObject(sv.rt, sv.symbol_roots, sv.preserved_count, val_ptr.*);
            }

            pub fn visitSymbol(sv: *@This(), sym_ptr: *atom.Atom) !void {
                try preserveSymbolAtom(sv.rt, sv.symbol_roots, sym_ptr.*);
            }

            pub fn visitWeakCollectionEntry(sv: *@This(), entry: *WeakCollectionEntry) !void {
                _ = sv;
                _ = entry;
            }

            pub fn visitFinalizationCell(sv: *@This(), entry: *FinalizationRegistryCell) !void {
                _ = sv;
                _ = entry;
            }
        };
        var visitor = ScanPreservedVisitor{
            .rt = rt,
            .symbol_roots = symbol_roots,
            .preserved_count = preserved_count,
        };
        try self.traceChildEdgesFallible(rt, &visitor);
    }

    fn scanPreservedValueObject(
        rt: *JSRuntime,
        symbol_roots: *SymbolRootSet,
        preserved_count: *usize,
        stored: JSValue,
    ) ObjectGraphError!void {
        try preserveSymbolValue(rt, symbol_roots, stored);
        if (objectFromValue(stored)) |child| {
            try scanPreservedObjects(rt, symbol_roots, preserved_count, child);
            return;
        }
        const function_bytecode = functionBytecodeFromValue(stored) orelse return;
        try scanPreservedFunctionBytecodeChildObjects(rt, symbol_roots, preserved_count, function_bytecode);
    }

    fn scanPreservedFunctionBytecodeChildObjects(
        rt: *JSRuntime,
        symbol_roots: *SymbolRootSet,
        preserved_count: *usize,
        function_bytecode: *const FunctionBytecode,
    ) ObjectGraphError!void {
        if (function_bytecode.class_fields_init) |stored| try scanPreservedValueObject(rt, symbol_roots, preserved_count, stored);
        for (function_bytecode.cpool) |stored| try scanPreservedValueObject(rt, symbol_roots, preserved_count, stored);
    }

    fn scanPreservedWeakEdges(
        rt: *JSRuntime,
        tmp_head: ?*gc.GcNode,
        symbol_roots: *SymbolRootSet,
        preserved_count: *usize,
    ) ObjectGraphError!void {
        var changed = true;
        while (changed) {
            changed = false;
            // Preserved objects live on the live list or (if resurrected via
            // weak/finalization edges and not yet moved back) the garbage list.
            const list_heads = [2]?*gc.GcNode{ rt.gc.gc_obj_list_head, tmp_head };
            for (list_heads) |list_head| {
                var node_it = list_head;
                while (node_it) |node| : (node_it = node.next) {
                    const h = gc.headerFromGcNode(node);
                    if (h.kind != .object or !h.flags.cycle_preserved) continue;
                    const current: *Object = @alignCast(@fieldParentPtr("header", h));
                    for (current.weakCollectionEntries()) |entry| {
                        if (!weakEntryKeyIsPreserved(rt, symbol_roots, entry.key_identity)) continue;
                        const before = preserved_count.*;
                        const before_symbols = symbol_roots.count();
                        try scanPreservedValueObject(rt, symbol_roots, preserved_count, entry.value);
                        if (preserved_count.* != before or symbol_roots.count() != before_symbols) changed = true;
                    }
                    for (current.finalizationRegistryCells()) |entry| {
                        if (!entry.isActive()) continue;
                        const target_identity = entry.target_identity orelse continue;
                        if (!weakEntryKeyIsPreserved(rt, symbol_roots, target_identity)) continue;
                        const before = preserved_count.*;
                        const before_symbols = symbol_roots.count();
                        try scanPreservedValueObject(rt, symbol_roots, preserved_count, entry.held_value);
                        try scanPreservedValueObject(rt, symbol_roots, preserved_count, entry.unregister_token);
                        if (preserved_count.* != before or symbol_roots.count() != before_symbols) changed = true;
                    }
                }
            }
        }
    }

    fn scanPreservedWeakAndFinalizationEdges(
        rt: *JSRuntime,
        tmp_head: ?*gc.GcNode,
        symbol_roots: *SymbolRootSet,
        preserved_count: *usize,
    ) ObjectGraphError!void {
        while (true) {
            const before_objects = preserved_count.*;
            const before_symbols = symbol_roots.count();
            try scanPreservedWeakEdges(rt, tmp_head, symbol_roots, preserved_count);
            try queueFinalizationCleanupJobs(rt, symbol_roots, preserved_count);
            if (preserved_count.* == before_objects and symbol_roots.count() == before_symbols) return;
        }
    }

    fn queueFinalizationCleanupJobs(
        rt: *JSRuntime,
        symbol_roots: *SymbolRootSet,
        preserved_count: *usize,
    ) ObjectGraphError!void {
        var current_node = rt.gc.gc_obj_list_head;
        while (current_node) |node| {
            const next = node.next;
            const header = gc.headerFromGcNode(node);
            if (header.kind == .object) {
                const current: *Object = @alignCast(@fieldParentPtr("header", header));
                if (header.flags.cycle_preserved) {
                    const finalization_payload = current.finalizationRegistryPayload() orelse {
                        current.pruneBorrowedReferenceHolderIfEmpty(rt);
                        current_node = next;
                        continue;
                    };
                    var cell_index: usize = 0;
                    while (cell_index < finalization_payload.cells.len) : (cell_index += 1) {
                        const cell = &finalization_payload.cells[cell_index];
                        if (!cell.isActive() and !cell.isPending()) continue;
                        const target_identity = cell.target_identity orelse continue;
                        if (weakEntryKeyIsPreserved(rt, symbol_roots, target_identity)) {
                            cell.state = .active;
                            continue;
                        }

                        cell.state = .pending_enqueue;
                        try scanPreservedValueObject(rt, symbol_roots, preserved_count, cell.held_value);
                        try scanPreservedValueObject(rt, symbol_roots, preserved_count, cell.unregister_token);
                        if (weakEntryKeyIsPreserved(rt, symbol_roots, target_identity)) {
                            cell.state = .active;
                            continue;
                        }
                        try enqueueFinalizationCleanup(rt, finalization_payload.cleanup_callback, cell.held_value);
                        cell.state = .queued;
                    }
                }
            }
            current_node = next;
        }
    }

    fn sweepDeadWeakEntries(
        rt: *JSRuntime,
        preserved_objects: []const *Object,
        symbol_roots: *const SymbolRootSet,
        internal_bytecodes: *const ObjectVisitSet,
    ) void {
        for (preserved_objects) |current| {
            var index: usize = 0;
            if (current.collectionPayload()) |payload| {
                var removed_weak_entry = false;
                while (index < payload.weak_entries.len) {
                    if (weakEntryKeyIsPreserved(rt, symbol_roots, payload.weak_entries[index].key_identity)) {
                        index += 1;
                        continue;
                    }

                    clearValueReferenceToVisited(rt, &payload.weak_entries[index].value, internal_bytecodes);
                    payload.weak_entries[index].destroy(rt);
                    const last_idx = payload.weak_entries.len - 1;
                    if (index < last_idx) {
                        payload.weak_entries[index] = payload.weak_entries[last_idx];
                    }
                    payload.weak_entries = payload.weak_entries.ptr[0..last_idx];
                    removed_weak_entry = true;
                }
                if (removed_weak_entry) current.clearCollectionIndex(rt);
            }

            if (current.objectDataPayload()) |payload| {
                if (payload.weak_target_identity) |target_identity| {
                    if (!weakEntryKeyIsPreserved(rt, symbol_roots, target_identity)) {
                        payload.weak_target_identity = null;
                    }
                }
            }

            const finalization_payload = current.finalizationRegistryPayload() orelse continue;
            index = 0;
            while (index < finalization_payload.cells.len) {
                const target_identity = finalization_payload.cells[index].target_identity;
                if (finalization_payload.cells[index].isPending()) {
                    index += 1;
                    continue;
                }
                if (finalization_payload.cells[index].isActive() and target_identity != null and
                    weakEntryKeyIsPreserved(rt, symbol_roots, target_identity.?))
                {
                    index += 1;
                    continue;
                }

                clearValueReferenceToVisited(rt, &finalization_payload.cells[index].held_value, internal_bytecodes);
                clearValueReferenceToVisited(rt, &finalization_payload.cells[index].unregister_token, internal_bytecodes);
                finalization_payload.cells[index].destroy(rt);
                const last_idx = finalization_payload.cells.len - 1;
                if (index < last_idx) {
                    finalization_payload.cells[index] = finalization_payload.cells[last_idx];
                }
                finalization_payload.cells = finalization_payload.cells.ptr[0..last_idx];
            }
            current.pruneBorrowedReferenceHolderIfEmpty(rt);
        }
    }

    fn enqueueFinalizationCleanup(rt: *JSRuntime, cleanup_callback: ?JSValue, held_value: JSValue) ObjectGraphError!void {
        const callback = cleanup_callback orelse return;
        try rt.enqueueFinalizationJob(callback, held_value);
    }

    fn weakEntryKeyIsPreserved(
        rt: *const JSRuntime,
        symbol_roots: *const SymbolRootSet,
        key_identity: usize,
    ) bool {
        if ((key_identity & 1) != 0) {
            const atom_id = key_identity >> 1;
            if (atom_id > std.math.maxInt(atom.Atom)) return false;
            return symbol_roots.contains(@intCast(atom_id));
        }
        const object = rt.liveObjectFromWeakIdentity(key_identity) orelse return false;
        return object.header.flags.cycle_visited and object.header.flags.cycle_preserved;
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
        if (header.kind != .object) return null;
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
                    try accumulateValueIncoming(entry.unregister_token, av.visited, av.incoming, av.internal_bytecodes, av.processed_bytecodes);
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
        if (function_bytecode.class_fields_init) |stored| try accumulateValueIncoming(stored, visited, incoming, internal_bytecodes, processed_bytecodes);
        for (function_bytecode.cpool) |stored| try accumulateValueIncoming(stored, visited, incoming, internal_bytecodes, processed_bytecodes);
    }

    fn incrementIncomingIfVisited(visited: *const ObjectVisitSet, incoming: *ObjectIncomingMap, child: *Object) ObjectGraphError!void {
        const address = @intFromPtr(child);
        if (!visited.contains(address)) return;
        const entry = incoming.getPtr(address) orelse return;
        entry.* += 1;
    }

    /// True when `child` is condemned garbage in the current cycle-removal round
    /// (it was scanned and was not preserved/resurrected).
    inline fn objectIsCycleGarbage(child: *const Object) bool {
        return child.header.flags.cycle_visited and !child.header.flags.cycle_preserved;
    }

    fn clearReferencesToVisited(
        self: *Object,
        rt: *JSRuntime,
        internal_bytecodes: *const ObjectVisitSet,
    ) ObjectGraphError!void {
        const ClearReferencesVisitor = struct {
            rt: *JSRuntime,
            internal_bytecodes: *const ObjectVisitSet,

            pub fn visitObject(cv: @This(), obj_ptr: *?*Object) !void {
                _ = cv;
                if (obj_ptr.*) |obj| {
                    if (@intFromPtr(obj) == 0) return;
                    if (objectIsCycleGarbage(obj)) {
                        obj_ptr.* = null;
                    }
                }
            }

            pub fn visitValue(cv: @This(), val_ptr: *JSValue) !void {
                clearValueReferenceToVisited(cv.rt, val_ptr, cv.internal_bytecodes);
            }

            pub fn visitSymbol(cv: @This(), sym_ptr: *atom.Atom) !void {
                _ = cv;
                _ = sym_ptr;
            }

            pub fn visitWeakCollectionEntry(cv: @This(), entry: *WeakCollectionEntry) !void {
                clearValueReferenceToVisited(cv.rt, &entry.value, cv.internal_bytecodes);
            }

            pub fn visitFinalizationCell(cv: @This(), entry: *FinalizationRegistryCell) !void {
                clearValueReferenceToVisited(cv.rt, &entry.held_value, cv.internal_bytecodes);
                clearValueReferenceToVisited(cv.rt, &entry.unregister_token, cv.internal_bytecodes);
            }
        };
        try self.traceChildEdgesFallible(rt, ClearReferencesVisitor{
            .rt = rt,
            .internal_bytecodes = internal_bytecodes,
        });
    }

    fn clearOptionalReferenceToVisited(
        rt: *JSRuntime,
        maybe_value: *?JSValue,
        internal_bytecodes: *const ObjectVisitSet,
    ) void {
        if (maybe_value.*) |*stored| {
            if (valueReferencesVisited(stored.*)) {
                maybe_value.* = null;
                return;
            }
            if (functionBytecodeFromValue(stored.*)) |function_bytecode| {
                if (!internal_bytecodes.contains(@intFromPtr(function_bytecode))) return;
                maybe_value.* = null;
                clearFunctionBytecodeReferencesToVisited(rt, function_bytecode, internal_bytecodes);
            }
        }
    }

    fn clearValueReferenceToVisited(
        rt: *JSRuntime,
        stored: *JSValue,
        internal_bytecodes: *const ObjectVisitSet,
    ) void {
        if (valueReferencesVisited(stored.*)) {
            stored.* = JSValue.undefinedValue();
            return;
        }
        if (functionBytecodeFromValue(stored.*)) |function_bytecode| {
            if (!internal_bytecodes.contains(@intFromPtr(function_bytecode))) return;
            stored.* = JSValue.undefinedValue();
            clearFunctionBytecodeReferencesToVisited(rt, function_bytecode, internal_bytecodes);
            return;
        }
        const cell = varRefCellFromValue(stored.*) orelse return;
        if (cell.varRefValueSlot().*) |cell_value| {
            if (valueReferencesVisited(cell_value)) cell.varRefValueSlot().* = JSValue.undefinedValue();
        }
    }

    fn clearFunctionBytecodeReferencesToVisited(
        rt: *JSRuntime,
        function_bytecode: *FunctionBytecode,
        internal_bytecodes: *const ObjectVisitSet,
    ) void {
        if (function_bytecode.class_fields_init) |*stored| clearValueReferenceToVisited(rt, stored, internal_bytecodes);
        for (function_bytecode.cpool) |*stored| clearValueReferenceToVisited(rt, stored, internal_bytecodes);
    }

    fn valueReferencesVisited(stored: JSValue) bool {
        const child = objectFromValue(stored) orelse return false;
        return objectIsCycleGarbage(child);
    }

    fn functionBytecodeFromValue(stored: JSValue) ?*FunctionBytecode {
        const header = stored.objectHeader() orelse return null;
        if (header.kind != .function_bytecode) return null;
        return @fieldParentPtr("header", header);
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
            var current_node = rt.gc.gc_obj_list_head;
            while (current_node) |node| {
                const next = node.next;
                const header = gc.headerFromGcNode(node);
                const function_bytecode = functionBytecodeFromGcHeader(header) orelse {
                    current_node = next;
                    continue;
                };
                const address = @intFromPtr(function_bytecode);
                if (candidates.contains(address)) {
                    current_node = next;
                    continue;
                }

                const internal_refs =
                    (try countFunctionBytecodeRefsFromVisitedObjects(rt, function_bytecode, visited)) +
                    countFunctionBytecodeRefsFromFunctionBytecodes(function_bytecode, candidates);
                if (internal_refs == 0) {
                    current_node = next;
                    continue;
                }

                try candidates.put(address, {});
                changed = true;
                current_node = next;
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
                if (internal_refs == function_bytecode.header.rc) continue;

                _ = internal_bytecodes.remove(address.*);
                removed = true;
                break;
            }
            if (!removed) return;
        }
    }

    fn functionBytecodeFromGcHeader(header: *gc.GCObjectHeader) ?*const FunctionBytecode {
        if (header.kind != .function_bytecode) return null;
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
        count += countOptionalFunctionBytecodeRef(owner.class_fields_init, function_bytecode);
        for (owner.cpool) |stored| count += countFunctionBytecodeValueRef(stored, function_bytecode);
        return count;
    }

    fn countDirectFunctionBytecodeRefs(
        self: *Object,
        rt: *JSRuntime,
        function_bytecode: *const FunctionBytecode,
    ) ObjectGraphError!usize {
        var count: usize = 0;
        if (self.iteratorPayloadConst()) |payload| count += countOptionalFunctionBytecodeRef(payload.cached_next, function_bytecode);
        for (self.properties) |entry| count += countSlotFunctionBytecodeRefs(entry.slot, function_bytecode);
        if (self.ordinaryPayloadConst()) |payload| {
            if (payload.shared_lazy_native_functions) |cache| {
                for (cache) |maybe_cached| count += countOptionalFunctionBytecodeRef(maybe_cached, function_bytecode);
            }
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
        }
        for (self.arrayElements()) |maybe_value| count += countOptionalFunctionBytecodeRef(maybe_value, function_bytecode);
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
            count += countFunctionBytecodeValueRef(entry.unregister_token, function_bytecode);
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
        count += countOptionalFunctionBytecodeRef(self.functionBytecode(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionClassFieldsInit(), function_bytecode);
        for (self.functionCaptures()) |stored| count += countFunctionBytecodeValueRef(stored, function_bytecode);
        for (self.functionEvalLocalRefs()) |stored| count += countFunctionBytecodeValueRef(stored, function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionEvalParentFunction(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionImportMeta(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionLexicalThis(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionArrowConstructorThis(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionArrowNewTarget(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionSuperConstructor(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.functionRealmGlobal(), function_bytecode);
        if (self.functionPayloadConst()) |payload| {
            for (payload.primitive_prototypes) |stored| count += countOptionalFunctionBytecodeRef(stored, function_bytecode);
            if (payload.regexp_legacy_statics) |legacy| {
                count += countOptionalFunctionBytecodeRef(legacy.input, function_bytecode);
                count += countOptionalFunctionBytecodeRef(legacy.last_match, function_bytecode);
                count += countOptionalFunctionBytecodeRef(legacy.last_paren, function_bytecode);
                count += countOptionalFunctionBytecodeRef(legacy.left_context, function_bytecode);
                count += countOptionalFunctionBytecodeRef(legacy.right_context, function_bytecode);
                for (legacy.captures) |stored| count += countOptionalFunctionBytecodeRef(stored, function_bytecode);
            }
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
        for (self.generatorArgs()) |stored| count += countFunctionBytecodeValueRef(stored, function_bytecode);
        for (self.generatorStack()) |stored| count += countFunctionBytecodeValueRef(stored, function_bytecode);
        for (self.generatorFrameLocals()) |stored| count += countFunctionBytecodeValueRef(stored, function_bytecode);
        for (self.generatorFrameArgs()) |stored| count += countFunctionBytecodeValueRef(stored, function_bytecode);
        for (self.generatorFrameVarRefs()) |stored| count += countFunctionBytecodeValueRef(stored, function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.generatorCurrentFunction(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.generatorYieldStarIterator(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.generatorAsyncPromise(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.varRefValue(), function_bytecode);
        for (self.argumentsVarRefs()) |stored| count += countFunctionBytecodeValueRef(stored, function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.proxyTarget(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.proxyHandler(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.promiseResult(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.promiseReactionCallback(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.promiseReactionArg(), function_bytecode);
        for (self.promiseReactions()) |stored| count += countFunctionBytecodeValueRef(stored, function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.regexpSource(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.regexpFlags(), function_bytecode);
        count += countOptionalFunctionBytecodeRef(self.regexpLastIndex(), function_bytecode);
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

    fn countSlotFunctionBytecodeRefs(slot: property.Slot, function_bytecode: *const FunctionBytecode) usize {
        return switch (slot) {
            .data => |stored| countFunctionBytecodeValueRef(stored, function_bytecode),
            .accessor => |entry| countFunctionBytecodeValueRef(entry.getter, function_bytecode) +
                countFunctionBytecodeValueRef(entry.setter, function_bytecode),
            .auto_init, .deleted => 0,
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
        return self.prototype;
    }

    pub fn setPrototype(self: *Object, rt: *JSRuntime, prototype: ?*Object) Error!void {
        var cursor = prototype;
        while (cursor) |candidate| {
            if (candidate == self) return error.PrototypeCycle;
            cursor = candidate.prototype;
        }
        if (!self.flags.extensible and self.prototype != prototype) return error.NotExtensible;
        const proto_id = if (prototype) |proto| @intFromPtr(proto) else null;
        const next_shape = if (self.shapeNeedsMutationCopy())
            try rt.shapes.cloneWithPrototype(self.shape_ref, proto_id)
        else
            null;
        errdefer if (next_shape) |shape_ref| rt.shapes.release(shape_ref);
        if (prototype) |proto| gc.retain(&proto.header);
        errdefer if (prototype) |proto| proto.value().free(rt);
        if (prototype) |proto| {
            proto.flags.is_prototype = true;
            if (proto.flags.may_have_indexed_properties) {
                rt.any_prototype_may_have_indexed_properties = true;
            }
        }
        const old_prototype = self.prototype;
        self.prototype = prototype;
        if (old_prototype) |old| old.value().free(rt);
        if (next_shape) |shape_ref| {
            const old_shape = self.shape_ref;
            self.shape_ref = shape_ref;
            rt.shapes.release(old_shape);
        } else {
            rt.shapes.updatePrototype(self.shape_ref, proto_id);
        }
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

    pub fn getOwnProperty(self: *const Object, atom_id: atom.Atom) ?descriptor.Descriptor {
        if (self.exotic) |methods| {
            if (methods.get_own_property) |hook| {
                if (hook(@constCast(self), atom_id)) |desc| return desc;
            }
        }
        if (self.moduleNamespaceBindingValue(atom_id)) |stored| {
            return descriptor.Descriptor.data(stored, true, true, false);
        }
        if (self.flags.is_array and atom_id == atom.ids.length) {
            return descriptor.Descriptor.data(arrayLengthValue(self.length), self.flags.length_writable, false, false);
        }
        if (self.class_id == class.ids.regexp and atom_id == atom.ids.lastIndex) {
            if (self.regexpLastIndex()) |stored| return descriptor.Descriptor.data(stored.dup(), self.regexpLastIndexWritable(), false, false);
        }
        if (self.findProperty(atom_id)) |index| {
            const entry = self.properties[index];
            const entry_flags = self.propFlagsAt(index);
            if (entry_flags.deleted) return null;
            // Auto-init placeholders need to be materialized before
            // the descriptor is built (`fromSlot` cannot synthesize
            // a value from `(name, length, rt)` on its own). This
            // mirrors `getProperty`'s first-access promotion -- after
            // materialization the slot is `.data` or `.accessor` and
            // re-reads are ordinary fast-path loads.
            if (entry.slot == .auto_init) {
                const info = property.autoInitAt(self.owner_runtime, entry.slot.auto_init).*;
                // `materializeAutoInit` returns a fresh ref for
                // `getProperty` semantics. On success the slot is promoted
                // and `fromSlot` dups the stored value(s). On OOM the
                // placeholder stays `.auto_init`, so expose a conservative
                // fallback descriptor directly instead of passing the
                // placeholder to `fromSlot`.
                const transient = materializeAutoInit(@constCast(self), index, info);
                const after_materialize = self.properties[index];
                if (after_materialize.slot == .auto_init) {
                    if (entry_flags.accessor) {
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
                return descriptor.Descriptor.fromSlot(self.propFlagsAt(index), after_materialize.slot);
            }
            return descriptor.Descriptor.fromSlot(entry_flags, entry.slot);
        }
        if (self.denseArrayElement(atom_id)) |stored| {
            return descriptor.Descriptor.data(stored.dup(), true, true, true);
        }
        return null;
    }

    pub fn hasOwnProperty(self: *const Object, atom_id: atom.Atom) bool {
        if (self.class_id == class.ids.regexp and atom_id == atom.ids.lastIndex and self.regexpLastIndex() != null) return true;
        return self.findProperty(atom_id) != null or self.denseArrayElement(atom_id) != null;
    }

    pub fn hasProperty(self: *const Object, atom_id: atom.Atom) bool {
        profile.recordPropLookup(self.flags.is_global);
        if (self.hasOwnProperty(atom_id)) return true;
        if (self.prototype) |proto| return proto.hasProperty(atom_id);
        return false;
    }

    pub fn getProperty(self: *const Object, atom_id: atom.Atom) JSValue {
        profile.recordPropLookup(self.flags.is_global);
        if (self.moduleNamespaceBindingValue(atom_id)) |stored| return stored;
        if (self.flags.is_array and atom_id == atom.ids.length) return arrayLengthValue(self.length);
        if (self.findProperty(atom_id)) |index| {
            const entry = self.properties[index];
            return switch (entry.slot) {
                .data => |stored_value| stored_value.dup(),
                .accessor => |accessor| accessor.getter.dup(),
                // First-access materialization for `auto_init`
                // placeholders. We need to mutate `self.properties[index]`
                // to replace the placeholder with the real value;
                // `self` is `Object` (by value) here -- the same
                // 300+-callsite shape as the rest of `getProperty`.
                // The slice header is a copy but the underlying entries
                // live on the heap and are shared, so `@constCast`
                // gives us a writable handle without changing every
                // caller. Matches QuickJS's `JS_AutoInitProperty` which
                // also mutates the property record in place on read.
                .auto_init => |id| materializeAutoInit(@constCast(self), index, property.autoInitAt(self.owner_runtime, id).*),
                .deleted => JSValue.undefinedValue(),
            };
        }
        if (self.class_id == class.ids.regexp and atom_id == atom.ids.lastIndex) {
            if (self.regexpLastIndex()) |stored| return stored.dup();
        }
        if (self.denseArrayElement(atom_id)) |stored| return stored.dup();
        if (self.prototype) |proto| return proto.getProperty(atom_id);
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
                self.installMaterializedAutoInit(index, cached_value);
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
        _ = info;
        self.installMaterializedAutoInit(index, materialized);
        return materialized.dup();
    }

    fn finishMaterializedAccessorAutoInit(self: *Object, index: usize, info: property.AutoInit, materialized: property.Accessor) JSValue {
        _ = info;
        self.installMaterializedAccessorAutoInit(index, materialized);
        return materialized.getter.dup();
    }

    fn installMaterializedAutoInit(self: *Object, index: usize, materialized: JSValue) void {
        self.properties[index].slot = .{ .data = materialized };
    }

    fn installMaterializedAccessorAutoInit(self: *Object, index: usize, materialized: property.Accessor) void {
        // Accessor auto-init placeholders are installed with
        // `flags.accessor` already set (asserted by the define paths),
        // so the shape-side flags need no update here.
        std.debug.assert(self.propFlagsAt(index).accessor);
        self.properties[index].slot = .{ .accessor = materialized };
    }

    fn materializeAutoInitEntryForMutation(self: *Object, index: usize) !void {
        if (index >= self.properties.len) return error.IncompatibleDescriptor;
        const entry = self.properties[index];
        if (entry.slot != .auto_init) return;
        const info = property.autoInitAt(self.owner_runtime, entry.slot.auto_init).*;
        const transient = materializeAutoInit(self, index, info);
        transient.free(info.rt);
        if (self.properties[index].slot == .auto_init) return error.OutOfMemory;
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
        return .{
            .getter = getter,
            .setter = setter,
        };
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
                obj.nativeFunctionIdSlot().* = native_builtin_id;
            }
        }
        if (apply_markers) {
            applyAutoInitArrayBuiltinMarker(function_value, info.array_builtin_marker);
            applyAutoInitTypedArrayBuiltinMarker(function_value, info.typed_array_builtin_marker);
            applyAutoInitArrayIteratorKind(function_value, info.array_iterator_kind);
            applyAutoInitIteratorIdentity(function_value, info.iterator_identity);
            applyAutoInitCollectionMethodOwner(function_value, info.collection_method_owner_class);
            applyAutoInitDisposableStackMethod(function_value, info.disposable_stack_method);
            applyAutoInitAsyncDisposableStackMethod(function_value, info.async_disposable_stack_method);
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
        const names = [_][]const u8{
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

    fn applyAutoInitArrayBuiltinMarker(function_value: JSValue, marker: ArrayBuiltinMarker) void {
        if (marker == .none) return;
        const header = function_value.refHeader() orelse return;
        const function_object: *Object = @fieldParentPtr("header", header);
        _ = function_object.addArrayBuiltinMarker(marker);
    }

    fn applyAutoInitTypedArrayBuiltinMarker(function_value: JSValue, marker: TypedArrayBuiltinMarker) void {
        if (marker == .none) return;
        const header = function_value.refHeader() orelse return;
        const function_object: *Object = @fieldParentPtr("header", header);
        _ = function_object.addTypedArrayBuiltinMarker(marker);
    }

    fn applyAutoInitArrayIteratorKind(function_value: JSValue, kind: u8) void {
        if (kind == 0) return;
        const header = function_value.refHeader() orelse return;
        const function_object: *Object = @fieldParentPtr("header", header);
        _ = function_object.addArrayIteratorKind(kind);
    }

    fn applyAutoInitIteratorIdentity(function_value: JSValue, is_identity: bool) void {
        if (!is_identity) return;
        const header = function_value.refHeader() orelse return;
        const function_object: *Object = @fieldParentPtr("header", header);
        _ = function_object.addIteratorIdentityFunction();
    }

    fn applyAutoInitCollectionMethodOwner(function_value: JSValue, owner_class: class.ClassId) void {
        if (owner_class == class.invalid_class_id) return;
        const header = function_value.refHeader() orelse return;
        const function_object: *Object = @fieldParentPtr("header", header);
        _ = function_object.addCollectionMethodOwnerClass(owner_class);
    }

    fn applyAutoInitDisposableStackMethod(function_value: JSValue, method_id: u8) void {
        if (method_id == 0) return;
        const header = function_value.refHeader() orelse return;
        const function_object: *Object = @fieldParentPtr("header", header);
        _ = function_object.addDisposableStackMethod(method_id);
    }

    fn applyAutoInitAsyncDisposableStackMethod(function_value: JSValue, method_id: u8) void {
        if (method_id == 0) return;
        const header = function_value.refHeader() orelse return;
        const function_object: *Object = @fieldParentPtr("header", header);
        _ = function_object.addAsyncDisposableStackMethod(method_id);
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
            getter_object.nativeFunctionIdSlot().* = function.nativeBuiltinId(.host, @intFromEnum(function.HostGlobalMethod.navigator_user_agent_get));
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
        if (self.exotic != null) return null;
        if (self.findProperty(atom_id)) |index| {
            if (self.propFlagsAt(index).accessor) return null;
            return switch (self.properties[index].slot) {
                .data => |stored| objectFromValue(stored),
                .auto_init, .accessor, .deleted => null,
            };
        }
        return null;
    }

    pub fn getOwnDataPropertyLookup(self: *const Object, atom_id: atom.Atom) ?DataPropertyLookup {
        if (self.exotic != null) return null;
        if (self.findProperty(atom_id)) |index| {
            if (self.propFlagsAt(index).accessor) return null;
            return switch (self.properties[index].slot) {
                .data => |stored| .{ .index = index, .value = stored.dup() },
                .auto_init, .accessor, .deleted => null,
            };
        }
        return null;
    }

    pub fn getOwnDataPropertyValueAt(self: *const Object, index: usize, atom_id: atom.Atom) ?JSValue {
        if (self.exotic != null or index >= self.shapeProps().len) return null;
        const prop = self.shape_ref.props[index];
        const prop_flags = property.Flags.fromBits(prop.flags);
        if (prop.atom_id != atom_id or prop_flags.deleted or prop_flags.accessor) return null;
        return switch (self.properties[index].slot) {
            .data => |stored| stored.dup(),
            .auto_init, .accessor, .deleted => null,
        };
    }

    pub fn getDenseArrayElementValue(self: *const Object, index: u32) ?JSValue {
        if (!self.flags.is_array or self.arrayElementStorageMode() != .dense) return null;
        const atom_id = atom.atomFromUInt32(index);
        if (self.properties.len != 0 and self.findProperty(atom_id) != null) return null;
        const element_index: usize = @intCast(index);
        const elements = self.arrayElements();
        if (element_index >= elements.len) return null;
        if (elements[element_index]) |stored| return stored.dup();
        return null;
    }

    pub fn defineOwnProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void {
        if (self.exotic) |methods| {
            if (methods.define_own_property) |hook| {
                if (!hook(self, atom_id, desc)) return error.IncompatibleDescriptor;
                return;
            }
        }
        if (try self.defineModuleNamespaceProperty(rt, atom_id, desc)) return;
        var actual_desc = desc;
        const destroy_actual_desc = try self.prepareMappedArgumentsDescriptorForDefine(rt, atom_id, &actual_desc);
        defer if (destroy_actual_desc) actual_desc.destroy(rt);

        if (self.flags.is_array and atom_id == atom.ids.length) {
            try self.defineArrayLength(rt, actual_desc);
            return;
        }

        if (self.class_id == class.ids.regexp and atom_id == atom.ids.lastIndex and self.regexpLastIndex() != null) {
            try self.defineRegExpLastIndex(rt, actual_desc);
            return;
        }

        if (self.flags.is_array) {
            if (array.arrayIndexFromAtom(&rt.atoms, atom_id)) |index| {
                if (index >= self.length and !self.flags.length_writable) return error.ReadOnly;
                try self.defineOrdinaryOwnProperty(rt, atom_id, actual_desc);
                if (index >= self.length) self.length = index + 1;
                self.updateArrayStorageMode(index);
                return;
            }
        }

        try self.defineOrdinaryOwnProperty(rt, atom_id, actual_desc);
        try self.updateMappedArgumentsBinding(rt, atom_id, actual_desc);
    }

    /// Fast-path property define for builtins setup, callable when the
    /// caller can guarantee the property is brand-new on the object and
    /// the object is a plain (non-exotic, non-array, non-regexp,
    /// non-mapped-arguments) ordinary object. Skips the
    /// `findProperty` linear scan (O(n) per insert -> O(n^2) over
    /// `installStandardGlobals`) and the array / regexp / arguments
    /// preludes of `defineOwnProperty`. Hot during global-object setup
    /// where ~700 native functions and ~50 namespace properties are
    /// installed per fresh global; converts the per-call cost from
    /// O(existing-property-count) to O(1).
    ///
    /// Caller must ensure: object is plain (no exotic methods, not an
    /// array, not regexp w/ lastIndex, not mapped-arguments) and the
    /// property does not already exist on the object. Cheap structural
    /// checks are asserted; the no-duplicate precondition is the
    /// caller's responsibility to keep this fast (asserting it would
    /// reintroduce the O(n) scan we are trying to avoid).
    pub fn defineOwnPropertyAssumingNew(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void {
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.flags.is_array);
        std.debug.assert(self.class_id != class.ids.regexp or self.regexpLastIndex() == null);
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
        std.debug.assert(self.exotic == null);
        std.debug.assert(!(self.flags.is_array and atom_id == atom.ids.length));
        std.debug.assert(array.arrayIndexFromAtom(&rt.atoms, atom_id) == null);
        std.debug.assert(self.class_id != class.ids.regexp or atom_id != atom.ids.lastIndex or self.regexpLastIndex() == null);
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.flags.extensible);
        try self.addProperty(rt, atom_id, desc);
    }

    pub fn defineRegExpMatchMetadataPropertiesAssumingNew(self: *Object, rt: *JSRuntime, match_index: i32, input_value: JSValue, groups_value: JSValue) !void {
        std.debug.assert(self.exotic == null);
        std.debug.assert(self.flags.is_array);
        std.debug.assert(self.flags.extensible);

        const index_atom = atom.predefinedId("index", .string).?;
        const input_atom = atom.predefinedId("input", .string).?;
        const groups_atom = atom.predefinedId("groups", .string).?;
        const enumerable_flags = property.Flags.data(true, true, true);
        try self.appendPreparedPropertyEntry(rt, index_atom, enumerable_flags, .{ .data = JSValue.int32(match_index) });
        try self.appendPreparedPropertyEntry(rt, input_atom, enumerable_flags, .{ .data = input_value.dup() });
        try self.appendPreparedPropertyEntry(rt, groups_atom, enumerable_flags, .{ .data = groups_value.dup() });
    }

    pub fn defineJsonParseDataProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, new_value: JSValue) !void {
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.flags.is_array);
        std.debug.assert(self.class_id == class.ids.object);
        std.debug.assert(self.flags.extensible);

        if (self.findProperty(atom_id)) |index| {
            try self.ensureUniqueShapeForMutation(rt);
            const entry = &self.properties[index];
            const next_value = dupPropertyDataValue(&rt.atoms, atom_id, new_value);
            errdefer next_value.free(rt);
            const old_slot = entry.slot;
            entry.slot = .{ .data = next_value };
            rt.shapes.updatePropertyFlags(self.shape_ref, index, property.Flags.data(true, true, true).bits());
            destroyPropertySlot(rt, atom_id, old_slot);
            self.pruneBorrowedReferenceHolderIfEmpty(rt);
            return;
        }

        try self.addProperty(rt, atom_id, descriptor.Descriptor.data(new_value, true, true, true));
    }

    pub fn reserveOwnPropertyCapacityAssumingPlain(self: *Object, rt: *JSRuntime, needed: usize) !void {
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.flags.is_array);
        std.debug.assert(self.class_id != class.ids.regexp or self.regexpLastIndex() == null);
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.flags.extensible);
        if (needed <= self.property_capacity and rt.shapes.hasReservedOwnPropertyCapacity(self.shape_ref, needed)) return;
        // Bulk install paths build fresh ordinary objects. Once capacity is
        // reserved, keep their shapes unique and append in place instead of
        // creating a transition node per property.
        try self.ensureUniqueShapeForMutation(rt);
        try self.ensurePropertyCapacity(rt, needed);
        try rt.shapes.reserveProperties(self.shape_ref, needed);
        try rt.shapes.reservePropertyHash(self.shape_ref, needed);
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
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.flags.is_array);
        std.debug.assert(self.class_id != class.ids.regexp or self.regexpLastIndex() == null);
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
        try self.appendPreparedPropertyEntry(rt, atom_id, flags, .{ .auto_init = try property.internAutoInit(rt, .{
            .name = name,
            .length = length,
            .rt = rt,
            .host_function_realm_global = if (realm_global) |realm| @intFromPtr(realm) else 0,
            .native_builtin_id = native_builtin_id,
            .shared_native_cache_slot = shared_native_cache_slot,
        }) });
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
        std.debug.assert(self.exotic == null);
        std.debug.assert(!(self.flags.is_array and atom_id == atom.ids.length));
        std.debug.assert(array.arrayIndexFromAtom(&rt.atoms, atom_id) == null);
        std.debug.assert(self.class_id != class.ids.regexp or atom_id != atom.ids.lastIndex or self.regexpLastIndex() == null);
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.flags.extensible);
        const inserted_holder = if (realm_global != null)
            try registerBorrowedHolderForPendingMutation(rt, self)
        else
            false;
        errdefer rollbackBorrowedHolderRegistration(rt, self, inserted_holder);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags, .{ .auto_init = try property.internAutoInit(rt, .{
            .name = name,
            .length = length,
            .rt = rt,
            .host_function_realm_global = if (realm_global) |realm| @intFromPtr(realm) else 0,
            .native_builtin_id = native_builtin_id,
            .shared_native_cache_slot = shared_native_cache_slot,
        }) });
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
        std.debug.assert(flags.accessor);
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.flags.is_array);
        std.debug.assert(self.class_id != class.ids.regexp or self.regexpLastIndex() == null);
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.flags.extensible);
        const inserted_holder = if (realm_global != null)
            try registerBorrowedHolderForPendingMutation(rt, self)
        else
            false;
        errdefer rollbackBorrowedHolderRegistration(rt, self, inserted_holder);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags, .{ .auto_init = try property.internAutoInit(rt, .{
            .name = getter_name,
            .length = getter_length,
            .rt = rt,
            .kind = .native_accessor,
            .host_function_realm_global = if (realm_global) |realm| @intFromPtr(realm) else 0,
            .native_builtin_id = getter_native_builtin_id,
        }) });
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
        std.debug.assert(flags.accessor);
        std.debug.assert(setter_length > 0);
        std.debug.assert(setter_native_builtin_id >= 0);
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.flags.is_array);
        std.debug.assert(self.class_id != class.ids.regexp or self.regexpLastIndex() == null);
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.flags.extensible);
        const inserted_holder = if (realm_global != null)
            try registerBorrowedHolderForPendingMutation(rt, self)
        else
            false;
        errdefer rollbackBorrowedHolderRegistration(rt, self, inserted_holder);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags, .{ .auto_init = try property.internAutoInit(rt, .{
            .name = getter_name,
            .length = getter_length,
            .rt = rt,
            .kind = .native_accessor,
            .host_function_kind = setter_length,
            .external_host_function_id = @intCast(setter_native_builtin_id),
            .host_function_realm_global = if (realm_global) |realm| @intFromPtr(realm) else 0,
            .native_builtin_id = getter_native_builtin_id,
        }) });
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
            if (self.properties[index].slot != .auto_init) return error.TypeError;
            if (self.propFlagsAt(index).bits() != flags.bits()) {
                try self.ensureUniqueShapeForMutation(rt);
                rt.shapes.updatePropertyFlags(self.shape_ref, index, flags.bits());
            }
            self.properties[index].slot = .{ .auto_init = try property.internAutoInit(rt, .{
                .name = name,
                .length = length,
                .rt = rt,
                .host_function_realm_global = if (realm_global) |realm| @intFromPtr(realm) else 0,
                .native_builtin_id = native_builtin_id,
                .shared_native_cache_slot = shared_native_cache_slot,
            }) };
            self.pruneBorrowedReferenceHolderIfEmpty(rt);
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
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.flags.is_array);
        std.debug.assert(self.flags.extensible);
        const inserted_holder = try registerBorrowedHolderForPendingMutation(rt, self);
        errdefer rollbackBorrowedHolderRegistration(rt, self, inserted_holder);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags, .{ .auto_init = try property.internAutoInit(rt, .{
            .name = "navigator",
            .length = 0,
            .rt = rt,
            .kind = .navigator,
            .host_function_realm_global = @intFromPtr(realm_global),
        }) });
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
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.flags.is_array);
        std.debug.assert(self.flags.extensible);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags, .{ .auto_init = try property.internAutoInit(rt, .{
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
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.flags.is_array);
        std.debug.assert(self.flags.extensible);
        const inserted_holder = try registerBorrowedHolderForPendingMutation(rt, self);
        errdefer rollbackBorrowedHolderRegistration(rt, self, inserted_holder);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags, .{ .auto_init = try property.internAutoInit(rt, .{
            .name = "performance",
            .length = 0,
            .rt = rt,
            .kind = .performance,
            .host_function_realm_global = @intFromPtr(realm_global),
        }) });
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
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.flags.is_array);
        std.debug.assert(self.flags.extensible);
        const inserted_holder = try registerBorrowedHolderForPendingMutation(rt, self);
        errdefer rollbackBorrowedHolderRegistration(rt, self, inserted_holder);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags, .{ .auto_init = try property.internAutoInit(rt, .{
            .name = name,
            .length = 0,
            .rt = rt,
            .kind = kind,
            .host_function_realm_global = @intFromPtr(realm_global),
        }) });
    }

    pub fn defineArrayUnscopablesAutoInitProperty(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        flags: property.Flags,
    ) !void {
        std.debug.assert(self.exotic == null);
        std.debug.assert(self.flags.extensible);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags, .{ .auto_init = try property.internAutoInit(rt, .{
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
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.flags.is_array);
        std.debug.assert(self.class_id != class.ids.regexp or self.regexpLastIndex() == null);
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.flags.extensible);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags, .{ .auto_init = try property.internAutoInit(rt, .{
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
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.flags.is_array);
        std.debug.assert(self.class_id != class.ids.regexp or self.regexpLastIndex() == null);
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.flags.extensible);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags, .{ .auto_init = try property.internAutoInit(rt, .{
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
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.flags.is_array);
        std.debug.assert(self.class_id != class.ids.regexp or self.regexpLastIndex() == null);
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.flags.extensible);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags, .{ .auto_init = try property.internAutoInit(rt, .{
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
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.flags.is_array);
        std.debug.assert(self.class_id != class.ids.regexp or self.regexpLastIndex() == null);
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.flags.extensible);
        std.debug.assert(!flags.accessor);
        const inserted_holder = try registerBorrowedHolderForPendingMutation(rt, self);
        errdefer rollbackBorrowedHolderRegistration(rt, self, inserted_holder);
        if (self.findProperty(atom_id)) |index| {
            if (!self.propFlagsAt(index).configurable) return error.IncompatibleDescriptor;
            try self.ensureUniqueShapeForMutation(rt);
            const entry = &self.properties[index];
            const old_slot = entry.slot;
            entry.slot = .{ .auto_init = try property.internAutoInit(rt, .{
                .name = "empty array",
                .length = 0,
                .rt = rt,
                .kind = .empty_array,
                .host_function_realm_global = @intFromPtr(realm_global),
            }) };
            rt.shapes.updatePropertyFlags(self.shape_ref, index, flags.bits());
            destroyPropertySlot(rt, atom_id, old_slot);
            self.pruneBorrowedReferenceHolderIfEmpty(rt);
            return;
        }
        try self.appendPreparedPropertyEntry(rt, atom_id, flags, .{ .auto_init = try property.internAutoInit(rt, .{
            .name = "empty array",
            .length = 0,
            .rt = rt,
            .kind = .empty_array,
            .host_function_realm_global = @intFromPtr(realm_global),
        }) });
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
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.flags.is_array);
        std.debug.assert(self.class_id != class.ids.regexp or self.regexpLastIndex() == null);
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.flags.extensible);
        const inserted_holder = if (host_function_realm_global != null)
            try registerBorrowedHolderForPendingMutation(rt, self)
        else
            false;
        errdefer rollbackBorrowedHolderRegistration(rt, self, inserted_holder);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags, .{ .auto_init = try property.internAutoInit(rt, .{
            .name = name,
            .length = length,
            .rt = rt,
            .host_function_kind = host_function_kind,
            .external_host_function_id = external_host_function_id,
            .host_function_prototype = host_function_prototype,
            .host_function_realm_global = if (host_function_realm_global) |realm| @intFromPtr(realm) else 0,
        }) });
    }

    pub fn writeDenseArrayIndex(self: *Object, rt: *JSRuntime, index: u32, atom_id: atom.Atom, new_value: JSValue) !bool {
        if (!self.flags.is_array or !self.flags.length_writable) return false;
        if (self.arrayElementStorageMode() != .dense) return false;
        if (self.properties.len != 0 and self.findProperty(atom_id) != null) return false;
        const elements = self.arrayElements();
        if (index >= elements.len) return false;
        if (self.prototype) |proto| {
            if (!arrayAppendPrototypeChainHasNoIndexedProperties(proto, rt) and proto.hasProperty(atom_id)) return false;
        }

        const element_slot = &self.arrayElementsSlot().*[@intCast(index)];
        const old_value = element_slot.*;
        element_slot.* = new_value.dup();
        if (old_value) |old| old.free(rt);
        return true;
    }

    pub fn appendDenseArrayIndex(self: *Object, rt: *JSRuntime, index: u32, atom_id: atom.Atom, new_value: JSValue) !bool {
        if (!self.flags.is_array or index != self.length or !self.flags.length_writable) return false;
        if (self.exotic != null or self.arrayElementStorageMode() != .dense) return false;
        if (!self.flags.extensible) return false;
        if (self.properties.len != 0 and self.findProperty(atom_id) != null) return false;
        if (self.prototype) |proto| {
            if (!arrayAppendPrototypeChainHasNoIndexedProperties(proto, rt) and proto.hasProperty(atom_id)) return false;
        }

        try self.ensureArrayElementCapacity(rt, index + 1);
        const elements = self.arrayElementsSlot();
        const old_len = elements.*.len;
        elements.* = elements.*.ptr[0 .. @as(usize, @intCast(index)) + 1];
        if (elements.*.len > old_len) @memset(elements.*[old_len..], null);
        const element_slot = &elements.*[@intCast(index)];
        element_slot.* = new_value.dup();
        self.markIndexedProperties(rt);
        self.length = index + 1;
        return true;
    }

    pub fn initDenseArrayIndexZeroAssumingEmpty(self: *Object, rt: *JSRuntime, new_value: JSValue) !void {
        std.debug.assert(self.flags.is_array);
        std.debug.assert(self.length == 0);
        std.debug.assert(self.flags.length_writable);
        std.debug.assert(self.flags.extensible);
        std.debug.assert(self.arrayElements().len == 0);
        std.debug.assert(self.arrayElementsCapacity() == 0);

        const elements = try rt.memory.alloc(?JSValue, 1);
        errdefer rt.memory.free(?JSValue, elements);
        elements[0] = new_value.dup();
        self.arrayElementsSlot().* = elements[0..1];
        self.arrayElementsCapacitySlot().* = 1;
        self.markIndexedProperties(rt);
        self.length = 1;
    }

    pub fn appendDenseArrayLiteralIndex(self: *Object, rt: *JSRuntime, index: u32, new_value: JSValue) !bool {
        if (!self.flags.is_array or index != self.length or !self.flags.length_writable) return false;
        if (!self.flags.extensible) return false;

        try self.ensureArrayElementCapacity(rt, index + 1);
        const elements = self.arrayElementsSlot();
        const old_len = elements.*.len;
        elements.* = elements.*.ptr[0 .. @as(usize, @intCast(index)) + 1];
        if (elements.*.len > old_len) @memset(elements.*[old_len..], null);
        const element_slot = &elements.*[@intCast(index)];
        element_slot.* = new_value.dup();
        self.markIndexedProperties(rt);
        self.length = index + 1;
        return true;
    }

    pub fn initDenseArrayLiteralValuesAssumingEmpty(self: *Object, rt: *JSRuntime, values: []const JSValue) !bool {
        if (!self.flags.is_array or !self.flags.length_writable or !self.flags.extensible) return false;
        if (self.length != 0 or self.properties.len != 0) return false;
        if (self.arrayElementStorageMode() != .dense) return false;
        if (values.len > array.max_array_length) return false;

        try self.ensureArrayElementCapacity(rt, @intCast(values.len));
        const elements = self.arrayElementsSlot();
        elements.* = elements.*.ptr[0..values.len];
        for (values, 0..) |item, index| {
            const element_slot = &elements.*[index];
            element_slot.* = item.dup();
        }
        if (values.len != 0) self.markIndexedProperties(rt);
        self.length = @intCast(values.len);
        return true;
    }

    pub fn appendDenseArrayInt32Range(self: *Object, rt: *JSRuntime, start: u32, limit: u32) !bool {
        if (!self.flags.is_array or self.exotic != null or self.arrayElementStorageMode() != .dense) return false;
        if (start != self.length or start >= limit or !self.flags.length_writable or !self.flags.extensible) return false;
        if (self.prototype) |proto| {
            if (!arrayAppendPrototypeChainHasNoIndexedProperties(proto, rt)) return false;
        }

        const start_index: usize = @intCast(start);
        const limit_index: usize = @intCast(limit);
        const elements = self.arrayElementsSlot();
        if (start_index < elements.*.len and elements.*[start_index] != null) return false;

        const old_len = elements.*.len;
        const capacity = self.arrayElementsCapacitySlot();
        if (limit_index > capacity.*) {
            var next_capacity = if (capacity.* == 0) @as(usize, 16) else capacity.* * 2;
            while (next_capacity < limit_index) : (next_capacity *= 2) {}
            const next = try rt.memory.alloc(?JSValue, next_capacity);
            errdefer rt.memory.free(?JSValue, next);
            @memcpy(next[0..old_len], elements.*);
            const old_capacity = capacity.*;
            const old_elements: []?JSValue = if (old_capacity != 0) elements.*.ptr[0..old_capacity] else elements.*[0..0];
            elements.* = next[0..old_len];
            capacity.* = next_capacity;
            if (old_capacity != 0) rt.memory.free(?JSValue, old_elements);
        }
        elements.* = elements.*.ptr[0..limit_index];
        if (start_index > old_len) @memset(elements.*[old_len..start_index], null);
        self.markIndexedProperties(rt);
        self.length = limit;

        if (start_index >= old_len) {
            var index = start_index;
            while (index < limit_index) : (index += 1) {
                elements.*[index] = JSValue.int32(@intCast(index));
            }
        } else {
            var index = start_index;
            while (index < limit_index) : (index += 1) {
                const old = elements.*[index];
                elements.*[index] = JSValue.int32(@intCast(index));
                if (old) |stored| stored.free(rt);
            }
        }
        return true;
    }

    pub fn appendDenseArrayInt32ValueRange(self: *Object, rt: *JSRuntime, start_index: u32, start_value: i32, count: u32) !bool {
        if (count == 0) return true;
        if (!self.flags.is_array or self.exotic != null or self.arrayElementStorageMode() != .dense) return false;
        if (start_index != self.length or !self.flags.length_writable or !self.flags.extensible) return false;
        if (self.prototype) |proto| {
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
        const elements = self.arrayElementsSlot();
        if (start_element < elements.*.len and elements.*[start_element] != null) return false;

        try self.ensureArrayElementCapacity(rt, limit);
        const old_len = elements.*.len;
        elements.* = elements.*.ptr[0..limit_element];
        if (start_element > old_len) @memset(elements.*[old_len..start_element], null);
        self.markIndexedProperties(rt);
        self.length = limit;

        var offset: u32 = 0;
        while (offset < count) : (offset += 1) {
            const index = start_element + @as(usize, @intCast(offset));
            const element_delta: i32 = @intCast(offset);
            const element_value = start_value + element_delta;
            if (index < old_len) {
                const old = elements.*[index];
                elements.*[index] = JSValue.int32(element_value);
                if (old) |stored| stored.free(rt);
            } else {
                elements.*[index] = JSValue.int32(element_value);
            }
        }
        return true;
    }

    pub fn appendDenseArrayInt32MulAndMaskRange(self: *Object, rt: *JSRuntime, start_index: u32, limit: u32, multiplier: i32, mask: i32) !bool {
        if (start_index >= limit) return true;
        if (multiplier < 0 or mask < 0) return false;
        if (!self.flags.is_array or self.exotic != null or self.arrayElementStorageMode() != .dense) return false;
        if (start_index != self.length or !self.flags.length_writable or !self.flags.extensible) return false;
        if (self.prototype) |proto| {
            if (!arrayAppendPrototypeChainHasNoIndexedProperties(proto, rt)) return false;
        }

        if (limit > array.max_array_length) return false;
        const max_safe_integer: i128 = 9007199254740991;
        const last_index = limit - 1;
        const last_product = @as(i128, @intCast(last_index)) * @as(i128, multiplier);
        if (last_product > max_safe_integer) return false;

        const start_element: usize = @intCast(start_index);
        const limit_element: usize = @intCast(limit);
        const elements = self.arrayElementsSlot();
        if (start_element < elements.*.len and elements.*[start_element] != null) return false;

        try self.ensureArrayElementCapacity(rt, limit);
        const old_len = elements.*.len;
        elements.* = elements.*.ptr[0..limit_element];
        if (start_element > old_len) @memset(elements.*[old_len..start_element], null);
        self.markIndexedProperties(rt);
        self.length = limit;

        var index = start_element;
        while (index < limit_element) : (index += 1) {
            const product_exact = @as(i128, @intCast(index)) * @as(i128, multiplier);
            const product: i32 = @truncate(product_exact);
            const element_value = product & mask;
            if (index < old_len) {
                const old = elements.*[index];
                elements.*[index] = JSValue.int32(element_value);
                if (old) |stored| stored.free(rt);
            } else {
                elements.*[index] = JSValue.int32(element_value);
            }
        }
        return true;
    }

    pub fn overwriteDenseArrayInt32MaskedIndexRange(self: *Object, rt: *JSRuntime, start: u32, limit: u32, mask: u32) !bool {
        if (start >= limit) return true;
        if (limit > @as(u32, @intCast(std.math.maxInt(i32)))) return false;
        if (mask > atom.max_int_atom) return false;
        if (!self.flags.is_array or !self.flags.length_writable) return false;
        if (self.exotic != null or self.arrayElementStorageMode() != .dense) return false;
        if (self.prototype) |proto| {
            if (!arrayAppendPrototypeChainHasNoIndexedProperties(proto, rt)) return false;
        }

        const elements = self.arrayElementsSlot();
        const mask_index: usize = @intCast(mask);
        if (mask_index >= elements.*.len) return false;

        var guard_index: u32 = 0;
        while (guard_index <= mask) : (guard_index += 1) {
            const atom_id = atom.atomFromUInt32(guard_index);
            if (self.properties.len != 0 and self.findProperty(atom_id) != null) return false;
            if (elements.*[@intCast(guard_index)] == null) return false;
            if (guard_index == std.math.maxInt(u32)) break;
        }

        var value_index = start;
        while (value_index < limit) : (value_index += 1) {
            const element_index: usize = @intCast(value_index & mask);
            const element_slot = &elements.*[element_index];
            const old = element_slot.*;
            const new_value = JSValue.int32(@intCast(value_index));
            element_slot.* = new_value;
            if (old) |stored| stored.free(rt);
        }
        return true;
    }

    pub fn reserveDenseArrayElements(self: *Object, rt: *JSRuntime, needed: u32) !void {
        if (!self.flags.is_array) return;
        try self.ensureArrayElementCapacity(rt, needed);
    }

    pub fn defineDenseArrayDataProperty(self: *Object, rt: *JSRuntime, index: u32, new_value: JSValue) !bool {
        if (!self.flags.is_array or self.exotic != null or self.arrayElementStorageMode() != .dense) return false;
        const atom_id = atom.atomFromUInt32(index);
        if (self.findProperty(atom_id) != null) return false;

        const element_index: usize = @intCast(index);
        const elements = self.arrayElementsSlot();
        if (element_index >= elements.*.len) {
            if (!self.flags.extensible) return false;
            if (index >= self.length and !self.flags.length_writable) return false;
            try self.ensureArrayElementCapacity(rt, index + 1);
            const old_len = elements.*.len;
            elements.* = elements.*.ptr[0 .. element_index + 1];
            if (elements.*.len > old_len) @memset(elements.*[old_len..], null);
        } else if (elements.*[element_index] == null and !self.flags.extensible) {
            return false;
        }

        const next_value = new_value.dup();
        errdefer next_value.free(rt);
        const element_slot = &elements.*[element_index];
        const old = element_slot.*;
        element_slot.* = next_value;
        self.markIndexedProperties(rt);
        if (index >= self.length) self.length = index + 1;
        if (old) |stored| stored.free(rt);
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

    pub fn canDefineDenseArrayDataPropertiesUnchecked(self: Object) bool {
        return self.flags.is_array and
            self.exotic == null and
            self.arrayElementStorageMode() == .dense and
            self.flags.extensible and
            self.properties.len == 0;
    }

    pub fn defineDenseArrayDataPropertyUnchecked(self: *Object, rt: *JSRuntime, index: u32, new_value: JSValue) !void {
        std.debug.assert(self.canDefineDenseArrayDataPropertiesUnchecked());
        std.debug.assert(index < self.length or self.flags.length_writable);

        const element_index: usize = @intCast(index);
        const elements = self.arrayElementsSlot();
        if (element_index >= elements.*.len) {
            try self.ensureArrayElementCapacity(rt, index + 1);
            const old_len = elements.*.len;
            elements.* = elements.*.ptr[0 .. element_index + 1];
            if (elements.*.len > old_len) @memset(elements.*[old_len..], null);
        }

        const next_value = new_value.dup();
        errdefer next_value.free(rt);
        const element_slot = &elements.*[element_index];
        const old = element_slot.*;
        element_slot.* = next_value;
        self.markIndexedProperties(rt);
        if (index >= self.length) self.length = index + 1;
        if (old) |stored| stored.free(rt);
    }

    pub fn setProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, new_value: JSValue) !void {
        if (self.class_id == class.ids.module_ns) {
            if (self.moduleNamespaceBindingValue(atom_id)) |stored| {
                stored.free(rt);
                return error.ReadOnly;
            }
        }
        if (self.flags.is_array and atom_id == atom.ids.length) {
            if (!self.flags.length_writable) return error.ReadOnly;
            try self.defineArrayLength(rt, descriptor.Descriptor.data(new_value, true, false, false));
            return;
        }
        if (self.class_id == class.ids.regexp and atom_id == atom.ids.lastIndex and self.regexpLastIndex() != null) {
            if (!self.regexpLastIndexWritable()) return error.ReadOnly;
            const last_index = self.regexpLastIndexSlot();
            const next_value = new_value.dup();
            errdefer next_value.free(rt);
            const old_value = last_index.*.?;
            last_index.* = next_value;
            old_value.free(rt);
            return;
        }
        if (self.findProperty(atom_id)) |index| {
            const entry_flags = self.propFlagsAt(index);
            if (entry_flags.accessor) {
                try self.materializeAutoInitEntryForMutation(index);
                const entry = &self.properties[index];
                if (entry.slot.accessor.setter.isUndefined()) return error.AccessorWithoutSetter;
                return;
            }
            if (!entry_flags.writable) return error.ReadOnly;
            const entry = &self.properties[index];
            const next_value = dupPropertyDataValue(&rt.atoms, atom_id, new_value);
            errdefer next_value.free(rt);
            const old_slot = entry.slot;
            entry.slot = .{ .data = next_value };
            destroyPropertySlot(rt, atom_id, old_slot);
            self.pruneBorrowedReferenceHolderIfEmpty(rt);
            return;
        }
        if (array.arrayIndexFromAtom(&rt.atoms, atom_id)) |index| {
            if (try self.setDenseArrayElement(rt, index, new_value)) return;
        }
        var prototype = self.prototype;
        while (prototype) |proto| {
            if (proto.findProperty(atom_id)) |index| {
                const inherited_flags = proto.propFlagsAt(index);
                if (inherited_flags.accessor) {
                    try proto.materializeAutoInitEntryForMutation(index);
                }
                const inherited = proto.properties[index];
                if (inherited_flags.accessor and inherited.slot.accessor.setter.isUndefined()) return error.AccessorWithoutSetter;
                if (!inherited_flags.accessor and !inherited_flags.writable) return error.ReadOnly;
            }
            prototype = proto.prototype;
        }

        try self.defineOwnProperty(rt, atom_id, descriptor.Descriptor.data(new_value, true, true, true));
    }

    pub fn setOwnWritableDataProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, new_value: JSValue) !bool {
        if (self.class_id == class.ids.module_ns) {
            if (self.moduleNamespaceBindingValue(atom_id)) |stored| {
                stored.free(rt);
                return false;
            }
        }
        if (self.findProperty(atom_id)) |index| {
            const entry_flags = self.propFlagsAt(index);
            if (entry_flags.accessor) return false;
            if (!entry_flags.writable) return false;
            const entry = &self.properties[index];
            if (atom_id != atom.ids.Private_brand) {
                switch (entry.slot) {
                    .data => |*stored| {
                        if (!stored.requiresRefCount() and !new_value.requiresRefCount()) {
                            stored.* = new_value;
                            return true;
                        }
                    },
                    .auto_init, .accessor, .deleted => {},
                }
            }
            const next_value = dupPropertyDataValue(&rt.atoms, atom_id, new_value);
            errdefer next_value.free(rt);
            const old_slot = entry.slot;
            entry.slot = .{ .data = next_value };
            destroyPropertySlot(rt, atom_id, old_slot);
            self.pruneBorrowedReferenceHolderIfEmpty(rt);
            return true;
        }
        return false;
    }

    pub inline fn setOwnDataPropertyAtForLexicalSync(self: *Object, rt: *JSRuntime, index: usize, atom_id: atom.Atom, new_value: JSValue) !bool {
        if (self.exotic != null or index >= self.shapeProps().len) return false;
        const prop = self.shape_ref.props[index];
        const prop_flags = property.Flags.fromBits(prop.flags);
        if (prop.atom_id != atom_id or prop_flags.deleted or prop_flags.accessor) return false;
        const entry = &self.properties[index];
        switch (entry.slot) {
            .data => |*stored| {
                if (!prop_flags.writable and !stored.isUninitialized()) return false;
                if (atom_id == atom.ids.Private_brand) {
                    const next = dupPropertyDataValue(&rt.atoms, atom_id, new_value);
                    errdefer next.free(rt);
                    const old = stored.*;
                    stored.* = next;
                    destroyPropertySlot(rt, atom_id, .{ .data = old });
                    return true;
                }
                if (!stored.requiresRefCount() and !new_value.requiresRefCount()) {
                    stored.* = new_value;
                    return true;
                }
                const next = new_value.dup();
                errdefer next.free(rt);
                const old = stored.*;
                stored.* = next;
                old.free(rt);
                return true;
            },
            .auto_init, .accessor, .deleted => return false,
        }
    }

    pub inline fn setOwnDataPropertyAtForLexicalSyncOwned(self: *Object, rt: *JSRuntime, index: usize, atom_id: atom.Atom, new_value: JSValue) !bool {
        if (self.exotic != null or index >= self.shapeProps().len) return false;
        const prop = self.shape_ref.props[index];
        const prop_flags = property.Flags.fromBits(prop.flags);
        if (prop.atom_id != atom_id or prop_flags.deleted or prop_flags.accessor) return false;
        const entry = &self.properties[index];
        switch (entry.slot) {
            .data => |*stored| {
                if (!prop_flags.writable and !stored.isUninitialized()) return false;
                if (atom_id == atom.ids.Private_brand) return false;
                const old = stored.*;
                stored.* = new_value;
                old.free(rt);
                return true;
            },
            .auto_init, .accessor, .deleted => return false,
        }
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
            if (entry_flags.accessor) return false;
            if (!entry_flags.writable) return false;
            const entry = &self.properties[index];
            if (atom_id != atom.ids.Private_brand) {
                switch (entry.slot) {
                    .data => |*stored| {
                        if (!stored.requiresRefCount() and !new_value.requiresRefCount()) {
                            stored.* = new_value;
                            return true;
                        }
                    },
                    .auto_init, .accessor, .deleted => {},
                }
            }
            const next_value = dupPropertyDataValue(&rt.atoms, atom_id, new_value);
            errdefer next_value.free(rt);
            const old_slot = entry.slot;
            entry.slot = .{ .data = next_value };
            destroyPropertySlot(rt, atom_id, old_slot);
            self.pruneBorrowedReferenceHolderIfEmpty(rt);
            return true;
        }
        return try self.defineNewOwnDataPropertyForSimpleSetKnownNoOwn(rt, atom_id, new_value);
    }

    pub fn defineNewOwnDataPropertyForSimpleSet(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, new_value: JSValue) !bool {
        if (self.findProperty(atom_id) != null) return false;
        return try self.defineNewOwnDataPropertyForSimpleSetKnownNoOwn(rt, atom_id, new_value);
    }

    fn defineNewOwnDataPropertyForSimpleSetKnownNoOwn(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, new_value: JSValue) !bool {
        if (self.exotic != null or self.proxyTarget() != null or self.flags.is_global or self.flags.is_with_environment) return false;
        if (!self.flags.extensible) return false;
        if (self.class_id == class.ids.module_ns or self.class_id == class.ids.regexp or self.class_id == class.ids.mapped_arguments) return false;
        if (isTypedArrayObjectForSetFastPath(self)) return false;
        if (self.flags.is_array and atom_id == atom.ids.length) return false;
        if (array.arrayIndexFromAtom(&rt.atoms, atom_id) != null) return false;

        var prototype = self.prototype;
        while (prototype) |proto| {
            if (proto.exotic != null or proto.proxyTarget() != null) return false;
            if (isTypedArrayObjectForSetFastPath(proto)) return false;
            if (proto.findProperty(atom_id) != null) return false;
            prototype = proto.prototype;
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

    pub fn deleteProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom) bool {
        if (self.exotic) |methods| {
            if (methods.delete_property) |hook| return hook(self, atom_id);
        }
        if (self.flags.is_array and atom_id == atom.ids.length) return false;
        if (self.class_id == class.ids.regexp and atom_id == atom.ids.lastIndex and self.regexpLastIndex() != null) return false;

        if (self.findProperty(atom_id)) |index| {
            if (!self.propFlagsAt(index).configurable) return false;
            self.ensureUniqueShapeForMutation(rt) catch return false;
            const entry = &self.properties[index];
            const old_slot = entry.slot;
            entry.slot = .deleted;
            var entry_flags = self.propFlagsAt(index);
            entry_flags.deleted = true;
            entry_flags.accessor = false;
            entry_flags.writable = false;
            rt.shapes.markPropertyDeleted(self.shape_ref, index, entry_flags.bits());
            if (self.class_id == class.ids.mapped_arguments) {
                if (array.arrayIndexFromAtom(&rt.atoms, atom_id)) |mapped_index| {
                    if (mapped_index < self.argumentsVarRefs().len) self.deleteMappedArgumentsBinding(rt, mapped_index);
                }
            }
            destroyPropertySlot(rt, atom_id, old_slot);
            self.pruneBorrowedReferenceHolderIfEmpty(rt);
            return true;
        }

        if (array.arrayIndexFromAtom(&rt.atoms, atom_id)) |array_index| {
            const element_index: usize = @intCast(array_index);
            if (element_index < self.arrayElements().len) {
                if (self.arrayElements()[element_index]) |stored| {
                    self.arrayElements()[element_index] = null;
                    stored.free(rt);
                    return true;
                }
            }
        }

        return true;
    }

    pub fn ownKeys(self: Object, rt: *JSRuntime) OwnKeysError![]atom.Atom {
        if (self.exotic) |methods| {
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

        const has_property_index_keys = hasPropertyIndexKeys(self, rt);
        if (!has_property_index_keys) {
            var dense_index: u32 = 0;
            while (dense_index < self.arrayElements().len) : (dense_index += 1) {
                if (self.arrayElements()[dense_index] != null) try appendAtom(rt, &keys, atom.atomFromUInt32(dense_index));
            }
        } else {
            var index_keys = std.ArrayList(IndexKey).empty;
            defer index_keys.deinit(rt.memory.allocator);
            var dense_index: u32 = 0;
            while (dense_index < self.arrayElements().len) : (dense_index += 1) {
                if (self.arrayElements()[dense_index] != null) try index_keys.append(rt.memory.allocator, .{
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

        if (self.flags.is_array) try appendAtom(rt, &keys, atom.ids.length);
        if (self.class_id == class.ids.regexp and self.regexpLastIndex() != null) try appendAtom(rt, &keys, atom.ids.lastIndex);

        for (self.shapeProps()) |prop| {
            if (property.Flags.fromBits(prop.flags).deleted) continue;
            if (array.arrayIndexFromAtom(&rt.atoms, prop.atom_id) != null) continue;
            const atom_kind = rt.atoms.kind(prop.atom_id);
            if (atom_kind == .symbol or atom_kind == .private) continue;
            try appendAtom(rt, &keys, prop.atom_id);
        }

        for (self.shapeProps()) |prop| {
            if (property.Flags.fromBits(prop.flags).deleted) continue;
            if (rt.atoms.kind(prop.atom_id) != .symbol) continue;
            try appendAtom(rt, &keys, prop.atom_id);
        }

        return keys;
    }

    pub fn freeKeys(rt: *JSRuntime, keys: []atom.Atom) void {
        for (keys) |key| rt.atoms.free(key);
        if (keys.len != 0) rt.memory.free(atom.Atom, keys);
    }

    pub fn seal(self: *Object, rt: *JSRuntime) !void {
        self.flags.extensible = false;
        try self.ensureUniqueShapeForMutation(rt);
        for (0..self.properties.len) |index| {
            var entry_flags = self.propFlagsAt(index);
            if (entry_flags.deleted or !entry_flags.configurable) continue;
            entry_flags.configurable = false;
            rt.shapes.updatePropertyFlags(self.shape_ref, index, entry_flags.bits());
        }
    }

    pub fn freeze(self: *Object, rt: *JSRuntime) !void {
        try self.seal(rt);
        for (0..self.properties.len) |index| {
            var entry_flags = self.propFlagsAt(index);
            if (entry_flags.deleted or entry_flags.accessor or !entry_flags.writable) continue;
            entry_flags.writable = false;
            rt.shapes.updatePropertyFlags(self.shape_ref, index, entry_flags.bits());
        }
        if (self.flags.is_array) self.flags.length_writable = false;
    }

    fn defineOrdinaryOwnProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void {
        if (self.findProperty(atom_id)) |index| {
            try self.materializeAutoInitEntryForMutation(index);
            if (!isCompatible(self.propFlagsAt(index), self.properties[index].slot, desc)) return error.IncompatibleDescriptor;
            try self.replaceProperty(rt, index, desc);
            return;
        }

        if (array.arrayIndexFromAtom(&rt.atoms, atom_id)) |array_index| {
            const element_index: usize = @intCast(array_index);
            if (element_index < self.arrayElements().len) {
                if (self.arrayElements()[element_index]) |stored| {
                    const current_flags = property.Flags.data(true, true, true);
                    const current_slot = property.Slot{ .data = stored };
                    if (!isCompatible(current_flags, current_slot, desc)) return error.IncompatibleDescriptor;
                    try self.addProperty(rt, atom_id, mergeDescriptor(current_flags, current_slot, desc));
                    self.arrayElements()[element_index] = null;
                    stored.free(rt);
                    return;
                }
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
            if (target_len != self.length or (desc.writable orelse false)) return error.IncompatibleDescriptor;
        }
        if (target_len > self.length and !self.flags.length_writable) return error.ReadOnly;
        if (target_len < self.length) {
            var i = self.properties.len;
            while (i > 0) {
                i -= 1;
                if (self.propFlagsAt(i).deleted) continue;
                const prop_atom = self.propAtomAt(i);
                const index = array.arrayIndexFromAtom(&rt.atoms, prop_atom) orelse continue;
                if (index >= target_len and !self.deleteProperty(rt, prop_atom)) {
                    const adjusted_len = index + 1;
                    self.truncateArrayElements(rt, adjusted_len);
                    self.length = adjusted_len;
                    self.recomputeArrayStorageMode(rt);
                    if (desc.writable == false) self.flags.length_writable = false;
                    return error.IncompatibleDescriptor;
                }
            }
        }
        self.truncateArrayElements(rt, target_len);
        self.length = target_len;
        self.recomputeArrayStorageMode(rt);
        if (desc.writable) |writable| self.flags.length_writable = writable;
    }

    fn defineRegExpLastIndex(self: *Object, rt: *JSRuntime, desc: descriptor.Descriptor) !void {
        if (desc.kind == .accessor) return error.IncompatibleDescriptor;
        if (desc.configurable orelse false) return error.IncompatibleDescriptor;
        if (desc.enumerable orelse false) return error.IncompatibleDescriptor;
        const last_index = self.regexpLastIndexSlot();
        const last_index_writable = self.regexpLastIndexWritableSlot();
        if (!desc.value_present) {
            if (!last_index_writable.* and (desc.writable orelse false)) return error.IncompatibleDescriptor;
            if (desc.writable) |writable| last_index_writable.* = writable;
            return;
        }
        if (!last_index_writable.*) {
            if (desc.writable orelse false) return error.IncompatibleDescriptor;
            if (desc.value_present and !last_index.*.?.sameValue(desc.value)) return error.ReadOnly;
            return;
        }
        if (desc.value_present) {
            const next_value = desc.value.dup();
            errdefer next_value.free(rt);
            const old_value = last_index.*.?;
            last_index.* = next_value;
            old_value.free(rt);
        }
        if (desc.writable) |writable| last_index_writable.* = writable;
    }

    pub fn truncateArrayElements(self: *Object, rt: *JSRuntime, new_len: u32) void {
        const elements = self.arrayElementsSlot();
        const len: usize = @min(@as(usize, @intCast(new_len)), elements.*.len);
        while (elements.*.len > len) {
            const index = elements.*.len - 1;
            const old = elements.*[index];
            elements.*[index] = null;
            elements.* = elements.*.ptr[0..index];
            if (old) |stored| stored.free(rt);
        }
    }

    fn denseArrayElement(self: *const Object, atom_id: atom.Atom) ?JSValue {
        if (!self.flags.is_array) return null;
        if (!atom.isTaggedInt(atom_id)) return null;
        const index: usize = @intCast(atom.atomToUInt32(atom_id));
        if (index >= self.arrayElements().len) return null;
        return self.arrayElements()[index];
    }

    fn hasDenseArrayElement(self: *const Object, index: u32) bool {
        const element_index: usize = @intCast(index);
        if (element_index >= self.arrayElements().len) return false;
        return self.arrayElements()[element_index] != null;
    }

    fn setDenseArrayElement(self: *Object, rt: *JSRuntime, index: u32, new_value: JSValue) !bool {
        if (!self.flags.is_array) return false;
        const element_index: usize = @intCast(index);
        const elements = self.arrayElementsSlot();
        if (element_index >= elements.*.len or elements.*[element_index] == null) return false;
        const next_value = new_value.dup();
        errdefer next_value.free(rt);
        const element_slot = &elements.*[element_index];
        const old = element_slot.*;
        element_slot.* = next_value;
        self.markIndexedProperties(rt);
        if (old) |stored| stored.free(rt);
        return true;
    }

    fn ensureArrayElementCapacity(self: *Object, rt: *JSRuntime, needed: u32) !void {
        const needed_len: usize = @intCast(needed);
        const elements = self.arrayElementsSlot();
        const capacity = self.arrayElementsCapacitySlot();
        if (needed_len <= capacity.*) return;
        var next_capacity = if (capacity.* == 0) @as(usize, 16) else capacity.* * 2;
        while (next_capacity < needed_len) : (next_capacity *= 2) {}
        const next = try rt.memory.alloc(?JSValue, next_capacity);
        errdefer rt.memory.free(?JSValue, next);
        @memset(next, null);
        @memcpy(next[0..elements.*.len], elements.*);
        const old_capacity = capacity.*;
        const old_elements: []?JSValue = if (old_capacity != 0) elements.*.ptr[0..old_capacity] else elements.*[0..0];
        elements.* = next[0..elements.*.len];
        capacity.* = next_capacity;
        if (old_capacity != 0) rt.memory.free(?JSValue, old_elements);
    }

    fn updateArrayStorageMode(self: *Object, index: u32) void {
        if (!self.flags.is_array) return;
        if (index > self.properties.len * 2 + 8) self.arrayStorageModeSlot().* = .sparse;
    }

    fn recomputeArrayStorageMode(self: *Object, rt: *JSRuntime) void {
        if (!self.flags.is_array) return;
        self.arrayStorageModeSlot().* = .dense;
        for (self.shapeProps()) |prop| {
            if (property.Flags.fromBits(prop.flags).deleted) continue;
            const index = array.arrayIndexFromAtom(&rt.atoms, prop.atom_id) orelse continue;
            self.updateArrayStorageMode(index);
        }
    }

    fn addProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void {
        const slot = slotFromDescriptor(&rt.atoms, atom_id, desc);
        try self.appendPreparedPropertyEntry(rt, atom_id, flagsFromDescriptor(desc), slot);
    }

    fn appendPreparedPropertyEntry(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, entry_flags: property.Flags, slot: property.Slot) !void {
        var slot_owned = true;
        errdefer if (slot_owned) destroyPropertySlot(rt, atom_id, slot);

        const old_len = self.properties.len;
        const old_capacity = self.property_capacity;
        const old_properties: []property.Entry = if (old_capacity != 0) self.properties.ptr[0..old_capacity] else self.properties[0..0];
        var grew_properties = false;
        if (old_len + 1 > old_capacity) {
            var next_capacity = if (old_capacity == 0) @as(usize, 4) else old_capacity * 2;
            while (next_capacity < old_len + 1) : (next_capacity *= 2) {}
            const next = try rt.memory.alloc(property.Entry, next_capacity);
            errdefer rt.memory.free(property.Entry, next);
            @memcpy(next[0..old_len], self.properties);
            self.properties = next[0..old_len];
            self.property_capacity = next_capacity;
            grew_properties = true;
        }

        const old_may_have_indexed_properties = self.flags.may_have_indexed_properties;
        self.properties = self.properties.ptr[0 .. old_len + 1];
        self.properties[old_len] = .{ .slot = slot };
        slot_owned = false;

        var inserted = true;
        errdefer if (inserted) {
            destroyPropertySlot(rt, atom_id, self.properties[old_len].slot);
            self.properties[old_len] = .{};
            self.properties = self.properties.ptr[0..old_len];
            self.flags.may_have_indexed_properties = old_may_have_indexed_properties;
            if (grew_properties) {
                const new_properties = self.properties.ptr[0..self.property_capacity];
                self.properties = old_properties[0..old_len];
                self.property_capacity = old_capacity;
                rt.memory.free(property.Entry, new_properties);
            }
        };

        if (array.arrayIndexFromAtom(&rt.atoms, atom_id) != null) {
            self.markIndexedProperties(rt);
        }
        try self.adoptShapeForNewProperty(rt, atom_id, entry_flags.bits());
        if (grew_properties and old_capacity != 0) rt.memory.free(property.Entry, old_properties);
        inserted = false;
    }

    fn shapeNeedsMutationCopy(self: Object) bool {
        return self.shape_ref.ref_count != 1 or self.shape_ref.is_transition_cacheable or self.shape_ref.parent != null;
    }

    fn ensureUniqueShapeForMutation(self: *Object, rt: *JSRuntime) !void {
        if (!self.shapeNeedsMutationCopy()) return;
        const next_shape = try rt.shapes.cloneForMutation(self.shape_ref);
        const old_shape = self.shape_ref;
        self.shape_ref = next_shape;
        rt.shapes.release(old_shape);
    }

    fn adoptShapeForNewProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, flags: u6) !void {
        if (array.arrayIndexFromAtom(&rt.atoms, atom_id) != null) {
            try self.ensureUniqueShapeForMutation(rt);
            try rt.shapes.addProperty(self.shape_ref, atom_id, flags);
            return;
        }
        if (!self.shapeNeedsMutationCopy()) {
            try rt.shapes.addProperty(self.shape_ref, atom_id, flags);
            return;
        }
        const next_shape = try rt.shapes.transitionProperty(self.shape_ref, atom_id, flags);
        const old_shape = self.shape_ref;
        self.shape_ref = next_shape;
        rt.shapes.release(old_shape);
    }

    fn ensurePropertyCapacity(self: *Object, rt: *JSRuntime, needed: usize) !void {
        if (needed <= self.property_capacity) return;
        var next_capacity = if (self.property_capacity == 0) @as(usize, 4) else self.property_capacity * 2;
        while (next_capacity < needed) : (next_capacity *= 2) {}
        const next = try rt.memory.alloc(property.Entry, next_capacity);
        errdefer rt.memory.free(property.Entry, next);
        @memcpy(next[0..self.properties.len], self.properties);
        const old_capacity = self.property_capacity;
        const old_properties: []property.Entry = if (old_capacity != 0) self.properties.ptr[0..old_capacity] else self.properties[0..0];
        self.properties = next[0..self.properties.len];
        self.property_capacity = next_capacity;
        if (old_capacity != 0) rt.memory.free(property.Entry, old_properties);
    }

    fn replaceProperty(self: *Object, rt: *JSRuntime, index: usize, desc: descriptor.Descriptor) !void {
        const atom_id = self.propAtomAt(index);
        const merged = mergeDescriptor(self.propFlagsAt(index), self.properties[index].slot, desc);
        const next_flags = flagsFromDescriptor(merged);
        const next_slot = slotFromDescriptor(&rt.atoms, atom_id, merged);
        var next_owned = true;
        errdefer if (next_owned) destroyPropertySlot(rt, atom_id, next_slot);
        try self.ensureUniqueShapeForMutation(rt);
        const old_slot = self.properties[index].slot;
        self.properties[index] = .{ .slot = next_slot };
        next_owned = false;
        rt.shapes.updatePropertyFlags(self.shape_ref, index, next_flags.bits());
        destroyPropertySlot(rt, atom_id, old_slot);
        self.pruneBorrowedReferenceHolderIfEmpty(rt);
    }

    /// Key atom for the own property stored at `index`. Property
    /// metadata (atom + flags) lives in the shape; `self.properties`
    /// holds only the value slots, indexed 1:1 with the shape props.
    pub inline fn propAtomAt(self: *const Object, index: usize) atom.Atom {
        return self.shape_ref.props[index].atom_id;
    }

    /// Flags for the own property stored at `index` (see `propAtomAt`).
    pub inline fn propFlagsAt(self: *const Object, index: usize) property.Flags {
        return property.Flags.fromBits(self.shape_ref.props[index].flags);
    }

    /// Shape-side metadata records matching `self.properties` by index.
    /// Clamped to the entry count so a partially appended property
    /// (entry pushed, shape not yet transitioned) is never exposed.
    pub inline fn shapeProps(self: *const Object) []const shape.Property {
        return self.shape_ref.props[0..@min(self.shape_ref.prop_count, self.properties.len)];
    }

    pub fn findProperty(self: *const Object, atom_id: atom.Atom) ?usize {
        const props = self.shapeProps();
        if (self.shape_ref.hasPropertyHash()) {
            var shape_index = self.shape_ref.firstPropertyIndex(atom_id);
            var steps: usize = 0;
            while (shape_index != shape.no_property_index and steps < self.shape_ref.prop_count) : (steps += 1) {
                const index: usize = @intCast(shape_index);
                if (index >= self.shape_ref.prop_count) break;
                shape_index = self.shape_ref.props[index].hash_next;
                if (index >= props.len) continue;
                const prop = props[index];
                if (prop.atom_id == atom_id and !property.Flags.fromBits(prop.flags).deleted) return index;
            }
            return null;
        }
        for (props, 0..) |prop, index| {
            if (prop.atom_id == atom_id and !property.Flags.fromBits(prop.flags).deleted) return index;
        }
        return null;
    }

    fn updateMappedArgumentsBinding(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void {
        if (self.class_id != class.ids.mapped_arguments) return;
        const index = array.arrayIndexFromAtom(&rt.atoms, atom_id) orelse return;
        const refs = self.argumentsVarRefs();
        if (index >= refs.len) return;
        if (refs[index].isUninitialized()) return;

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
        const refs = self.argumentsVarRefsSlot();
        if (varRefCellFromValue(refs.*[slot_index])) |cell| {
            const next_value = new_value.dup();
            errdefer next_value.free(rt);
            try cell.setVarRefValue(rt, next_value);
            return;
        }
        const next_value = new_value.dup();
        errdefer next_value.free(rt);
        const value_slot = &refs.*[slot_index];
        const old_value = value_slot.*;
        value_slot.* = next_value;
        old_value.free(rt);
    }

    fn deleteMappedArgumentsBinding(self: *Object, rt: *JSRuntime, index: u32) void {
        const slot_index: usize = @intCast(index);
        const refs = self.argumentsVarRefsSlot();
        const old_value = refs.*[slot_index];
        refs.*[slot_index] = JSValue.uninitialized();
        old_value.free(rt);
    }

    fn mappedArgumentsBindingValue(self: *Object, index: u32) ?JSValue {
        const slot_index: usize = @intCast(index);
        const refs = self.argumentsVarRefs();
        if (slot_index >= refs.len) return null;
        const mapped = refs[slot_index];
        if (mapped.isUninitialized()) return null;
        if (varRefCellFromValue(mapped)) |cell| {
            return if (cell.varRefValueSlot().*) |stored| stored.dup() else JSValue.undefinedValue();
        }
        return mapped.dup();
    }
};

fn testSymbolRootSeeded(rt: *JSRuntime, atom_id: atom.Atom) ObjectGraphError!bool {
    var symbol_roots = SymbolRootSet.init(rt.memory.allocator);
    defer symbol_roots.deinit();
    try Object.seedSymbolRootsFromRuntimeHeldValues(rt, rt.active_value_roots, &symbol_roots);
    return symbol_roots.contains(atom_id);
}

test "external object value roots seed nested symbol roots" {
    const rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const object = try Object.create(rt, class.ids.object, null);
    var object_value = object.value();
    var object_value_alive = true;
    defer if (object_value_alive) object_value.free(rt);

    const key = try rt.internAtom("external-object-root-symbol-slot");
    defer rt.atoms.free(key);
    const nested_symbol = try rt.atoms.newValueSymbol("external-object-root-nested-symbol");
    try object.defineOwnProperty(rt, key, descriptor.Descriptor.data(JSValue.symbol(nested_symbol), true, true, true));

    try std.testing.expect(!try testSymbolRootSeeded(rt, nested_symbol));
    try std.testing.expect(try rt.registerExternalValueSymbolRoot(object_value));
    try std.testing.expect(try testSymbolRootSeeded(rt, nested_symbol));

    rt.unregisterExternalValueSymbolRoot(object_value);
    try std.testing.expect(!try testSymbolRootSeeded(rt, nested_symbol));

    object_value.free(rt);
    object_value_alive = false;
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
        .accessor => .{ .accessor = .{
            .getter = desc.getter.dup(),
            .setter = desc.setter.dup(),
        } },
    };
}

pub fn dupPropertyDataValue(atoms: *atom.AtomTable, atom_id: atom.Atom, value: JSValue) JSValue {
    if (atom_id == atom.ids.Private_brand) {
        if (value.asSymbolAtom()) |brand_atom| {
            if (atoms.kind(brand_atom) == .private) return JSValue.symbol(atoms.dup(brand_atom));
        }
    }
    return value.dup();
}

pub fn destroyPropertySlot(rt: *JSRuntime, atom_id: atom.Atom, slot: property.Slot) void {
    if (atom_id == atom.ids.Private_brand) {
        switch (slot) {
            .data => |value| {
                if (value.asSymbolAtom()) |brand_atom| {
                    if (rt.atoms.kind(brand_atom) == .private) rt.atoms.free(brand_atom);
                }
            },
            .accessor, .auto_init, .deleted => {},
        }
    }
    slot.destroy(rt);
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
// which imports these predicates. `src/builtins/buffer.zig` re-exports both
// blocks under their original names.

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

    const current_is_accessor = current_flags.accessor;
    if ((desc.kind == .accessor) != current_is_accessor) return false;
    if (!current_is_accessor and !current_flags.writable) {
        if (desc.writable orelse false) return false;
        if (desc.kind == .data and desc.value_present and !current_slot.data.sameValue(desc.value)) return false;
    }
    if (current_is_accessor and desc.kind == .accessor) {
        if (current_slot != .accessor) return false;
        if (desc.getter_present and !current_slot.accessor.getter.sameValue(desc.getter)) return false;
        if (desc.setter_present and !current_slot.accessor.setter.sameValue(desc.setter)) return false;
    }
    return true;
}

fn mergeDescriptor(current_flags: property.Flags, current_slot: property.Slot, desc: descriptor.Descriptor) descriptor.Descriptor {
    return switch (desc.kind) {
        .generic => switch (current_slot) {
            .data => |value| descriptor.Descriptor.data(
                value,
                current_flags.writable,
                desc.enumerable orelse current_flags.enumerable,
                desc.configurable orelse current_flags.configurable,
            ),
            .accessor => |accessor| descriptor.Descriptor.accessor(
                accessor.getter,
                accessor.setter,
                desc.enumerable orelse current_flags.enumerable,
                desc.configurable orelse current_flags.configurable,
            ),
            // Auto-init placeholders should be materialized by the
            // caller before reaching `mergeDescriptor`; defining
            // `Object.defineProperty(global, "Array", {})` (the only
            // way to hit this with a placeholder) materializes first
            // through the same getProperty path.
            .auto_init => desc,
            .deleted => desc,
        },
        .data => descriptor.Descriptor.data(
            if (desc.value_present) desc.value else switch (current_slot) {
                .data => |value| value,
                else => desc.value,
            },
            desc.writable orelse if (current_flags.accessor) false else current_flags.writable,
            desc.enumerable orelse current_flags.enumerable,
            desc.configurable orelse current_flags.configurable,
        ),
        .accessor => descriptor.Descriptor.accessor(
            if (desc.getter_present) desc.getter else switch (current_slot) {
                .accessor => |accessor| accessor.getter,
                else => desc.getter,
            },
            if (desc.setter_present) desc.setter else switch (current_slot) {
                .accessor => |accessor| accessor.setter,
                else => desc.setter,
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
    const header = value.refHeader() orelse return std.math.nan(f64);
    const string_value: *@import("string.zig").String = @fieldParentPtr("header", header);
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

fn varRefCellFromValue(value: JSValue) ?*Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    const object: *Object = @fieldParentPtr("header", header);
    if (object.varRefPayload() == null) return null;
    return object;
}

fn appendAtom(rt: *JSRuntime, keys: *[]atom.Atom, atom_id: atom.Atom) OwnKeysError!void {
    const next = try rt.memory.alloc(atom.Atom, keys.*.len + 1);
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
// `builtins/object.zig` re-exports `EntriesMode`/`ownEntriesArray` unchanged.

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
    try arr.defineOwnProperty(rt, atom.atomFromUInt32(0), descriptor.Descriptor.data(key_value, true, true, true));
    try arr.defineOwnProperty(rt, atom.atomFromUInt32(1), descriptor.Descriptor.data(rooted_value, true, true, true));
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
        if (rt.atoms.kind(key) == .symbol) continue;
        const desc = object.getOwnProperty(key) orelse continue;
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
// dispatches through the record table into `builtins/string.zig`.

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
    next_function.nativeFunctionIdSlot().* = function.nativeBuiltinId(.string, @intFromEnum(host_function.builtin_method_ids.string.PrototypeMethod.iterator_next));
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

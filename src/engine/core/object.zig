const array = @import("array.zig");
const atom = @import("atom.zig");
const class = @import("class.zig");
const descriptor = @import("descriptor.zig");
const function = @import("function.zig");
const gc = @import("gc.zig");
const host_function = @import("host_function.zig");
const property = @import("property.zig");
const profile = @import("profile.zig");
const runtime_mod = @import("runtime.zig");
const shape = @import("shape.zig");
const string = @import("string.zig");
const Runtime = runtime_mod.Runtime;
const Value = @import("value.zig").Value;
const bytecode_function = @import("../bytecode/function.zig");
const std = @import("std");

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
    own_keys: ?*const fn (*Object, *Runtime) OwnKeysError![]atom.Atom = null,
};

pub const ArrayStorageMode = enum {
    dense,
    sparse,
};

pub const collection_no_entry: usize = std.math.maxInt(usize);

pub const CollectionEntry = struct {
    key: Value,
    value: Value,
    active: bool = true,
    hash: u64 = 0,
    hash_next: usize = collection_no_entry,

    pub fn destroy(self: CollectionEntry, rt: *Runtime) void {
        self.key.free(rt);
        self.value.free(rt);
    }
};

pub const WeakCollectionEntry = struct {
    key_identity: usize,
    value: Value,
    hash: u64 = 0,
    hash_next: usize = collection_no_entry,

    pub fn destroy(self: WeakCollectionEntry, rt: *Runtime) void {
        self.value.free(rt);
    }
};

pub const FinalizationRegistryCell = struct {
    target_identity: ?usize = null,
    held_value: Value = Value.undefinedValue(),
    unregister_token: Value = Value.undefinedValue(),
    active: bool = true,

    pub fn destroy(self: FinalizationRegistryCell, rt: *Runtime) void {
        self.held_value.free(rt);
        self.unregister_token.free(rt);
    }
};

fn destroyOptionalValue(rt: *Runtime, slot: *?Value) void {
    const old_value = slot.*;
    slot.* = null;
    if (old_value) |stored| stored.free(rt);
}

fn destroyOptionalObjectRef(rt: *Runtime, slot: *?*Object) void {
    const old_object = slot.*;
    slot.* = null;
    if (old_object) |stored| stored.value().free(rt);
}

fn destroyOptionalValueSlots(rt: *Runtime, slots: []?Value) void {
    for (slots) |*slot| destroyOptionalValue(rt, slot);
}

fn destroyValueSlice(rt: *Runtime, slot: *[]Value) void {
    const values = slot.*;
    slot.* = &.{};
    for (values) |stored| stored.free(rt);
    if (values.len != 0) rt.memory.free(Value, values);
}

fn destroyValueSliceWithCapacity(rt: *Runtime, slot: *[]Value, capacity: *usize) void {
    const values = slot.*;
    const old_capacity = capacity.*;
    slot.* = &.{};
    capacity.* = 0;
    for (values) |stored| stored.free(rt);
    if (old_capacity != 0) {
        rt.memory.free(Value, values.ptr[0..old_capacity]);
    } else if (values.len != 0) {
        rt.memory.free(Value, values);
    }
}

fn destroyOptionalValueSlice(rt: *Runtime, slot: *[]?Value, capacity: *usize) void {
    const values = slot.*;
    const old_capacity = capacity.*;
    slot.* = &.{};
    capacity.* = 0;
    for (values) |maybe_value| {
        if (maybe_value) |stored| stored.free(rt);
    }
    if (old_capacity != 0) {
        rt.memory.free(?Value, values.ptr[0..old_capacity]);
    } else if (values.len != 0) {
        rt.memory.free(?Value, values);
    }
}

fn destroyAtomSlice(rt: *Runtime, slot: *[]atom.Atom) void {
    const atoms = slot.*;
    slot.* = &.{};
    for (atoms) |atom_id| rt.atoms.free(atom_id);
    if (atoms.len != 0) rt.memory.free(atom.Atom, atoms);
}

pub const DataPropertyLookup = struct {
    index: usize,
    value: Value,
};

pub const OrdinaryPayload = struct {
    private_remap_from: []atom.Atom = &.{},
    private_remap_to: []atom.Atom = &.{},
    callsite_file: ?Value = null,
    callsite_function: ?Value = null,
    promise_reaction_on_fulfilled: ?Value = null,
    promise_reaction_on_rejected: ?Value = null,
    promise_reaction_resolve: ?Value = null,
    promise_reaction_reject: ?Value = null,
    promise_capability_resolve: ?Value = null,
    promise_capability_reject: ?Value = null,
    promise_combinator_resolve: ?Value = null,
    promise_combinator_reject: ?Value = null,
    promise_combinator_values: ?Value = null,
    promise_combinator_keys: ?Value = null,
    typed_array_array_buffer_prototype: ?Value = null,
    error_stack: ?Value = null,
    error_stack_sites: ?Value = null,
    error_stack_site_count: usize = 0,
    callsite_line: i32 = 1,
    callsite_column: i32 = 1,
    is_callsite: bool = false,
    promise_already_resolved: bool = false,
    promise_combinator_remaining: i32 = 0,
    worker_id: ?i32 = null,
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *OrdinaryPayload, rt: *Runtime) void {
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
    target: ?Value = null,
    data: ?Value = null,
    next: ?Value = null,
    callback: ?Value = null,
    inner_next: ?Value = null,
    zip_nexts: ?Value = null,
    zip_pads: ?Value = null,
    zip_keys: ?Value = null,
    index: usize = 0,
    zip_alive: usize = 0,
    kind: u8 = 0,
    zip_mode: u8 = 0,
    zip_state: u8 = 0,
    executing: bool = false,
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *IteratorPayload, rt: *Runtime) void {
        destroyOptionalValue(rt, &self.target);
        destroyOptionalValue(rt, &self.data);
        destroyOptionalValue(rt, &self.next);
        destroyOptionalValue(rt, &self.callback);
        destroyOptionalValue(rt, &self.inner_next);
        destroyOptionalValue(rt, &self.zip_nexts);
        destroyOptionalValue(rt, &self.zip_pads);
        destroyOptionalValue(rt, &self.zip_keys);
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

    pub fn destroy(self: *CollectionPayload, rt: *Runtime) void {
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

    pub fn create(byte_length: usize) !*SharedBufferStore {
        const allocator = std.heap.page_allocator;
        const store = try allocator.create(SharedBufferStore);
        errdefer allocator.destroy(store);
        const bytes = try allocator.alloc(u8, byte_length);
        @memset(bytes, 0);
        store.* = .{
            .ref_count = .init(1),
            .bytes = bytes,
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
        self.bytes = &.{};
        allocator.free(bytes);
        allocator.destroy(self);
    }
};

pub const BufferPayload = struct {
    bytes: []u8 = &.{},
    shared_store: ?*SharedBufferStore = null,
    detached: bool = false,
    immutable: bool = false,
    max_byte_length: ?usize = null,
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *BufferPayload, rt: *Runtime) void {
        if (self.shared_store) |store| {
            store.release();
        } else if (self.bytes.len != 0) {
            rt.memory.free(u8, self.bytes);
        }
        self.bytes = &.{};
        self.shared_store = null;
    }
};

pub const TypedArrayPayload = struct {
    buffer: ?Value = null,
    byte_offset: usize = 0,
    element_size: u32 = 0,
    fixed_length: ?u32 = null,
    kind: u8 = 0,
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *TypedArrayPayload, rt: *Runtime) void {
        destroyOptionalValue(rt, &self.buffer);
    }
};

pub const RegExpPayload = struct {
    source: ?Value = null,
    flags: ?Value = null,
    last_index: ?Value = null,
    compiled_bytecode: []u8 = &.{},
    fast_pattern_kind: RegExpFastPatternKind = .none,
    fast_simple_class_alternation: RegExpSimpleClassAlternationPattern = .{},
    fast_simple_capture_sequence: RegExpSimpleCaptureSequencePattern = .{},
    last_index_writable: bool = true,
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *RegExpPayload, rt: *Runtime) void {
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
    target: ?Value = null,
    this_value: ?Value = null,
    realm_global: ?Value = null,
    realm_global_ptr: ?*Object = null,
    args: []Value = &.{},

    pub fn destroy(self: *BoundFunctionPayload, rt: *Runtime) void {
        destroyOptionalValue(rt, &self.target);
        destroyOptionalValue(rt, &self.this_value);
        destroyOptionalValue(rt, &self.realm_global);
        destroyValueSlice(rt, &self.args);
    }
};

pub const ProxyPayload = struct {
    target: ?Value = null,
    handler: ?Value = null,
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *ProxyPayload, rt: *Runtime) void {
        destroyOptionalValue(rt, &self.target);
        destroyOptionalValue(rt, &self.handler);
    }
};

pub const ArgumentsPayload = struct {
    var_refs: []Value = &.{},
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *ArgumentsPayload, rt: *Runtime) void {
        destroyValueSlice(rt, &self.var_refs);
    }
};

pub const ObjectDataPayload = struct {
    data: ?Value = null,
    weak_target_identity: ?usize = null,
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *ObjectDataPayload, rt: *Runtime) void {
        destroyOptionalValue(rt, &self.data);
        self.weak_target_identity = null;
    }
};

pub const VarRefPayload = struct {
    value: ?Value = null,
    is_const: bool = false,
    is_function_name: bool = false,
    is_deletable: bool = false,
    is_deleted: bool = false,
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *VarRefPayload, rt: *Runtime) void {
        destroyOptionalValue(rt, &self.value);
        self.* = .{};
    }
};

pub const FinalizationRegistryPayload = struct {
    cleanup_callback: ?Value = null,
    cells: []FinalizationRegistryCell = &.{},
    cells_capacity: usize = 0,
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *FinalizationRegistryPayload, rt: *Runtime) void {
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

pub const DisposableResourceKind = enum(u8) {
    use,
    adopt,
    defer_,
};

pub const DisposableResource = struct {
    value: Value = Value.undefinedValue(),
    method: Value = Value.undefinedValue(),
    kind: DisposableResourceKind = .defer_,
    await_result: bool = false,

    pub fn destroy(self: DisposableResource, rt: *Runtime) void {
        self.value.free(rt);
        self.method.free(rt);
    }
};

pub const DisposableStackPayload = struct {
    resources: []DisposableResource = &.{},
    resource_capacity: usize = 0,
    disposed: bool = false,
    async_dispose_resolve: ?Value = null,
    async_dispose_reject: ?Value = null,
    async_dispose_error: ?Value = null,
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *DisposableStackPayload, rt: *Runtime) void {
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
    cached_values: [realm_value_slot_count]?Value = @splat(null),

    pub fn destroy(self: *RealmPayload, rt: *Runtime) void {
        destroyOptionalObjectRef(rt, &self.cached_function_proto);
        destroyOptionalObjectRef(rt, &self.cached_promise_proto);
        destroyOptionalValueSlots(rt, &self.cached_values);
        self.* = .{};
    }
};

pub const ArrayPayload = struct {
    storage_mode: ArrayStorageMode = .dense,
    elements: []?Value = &.{},
    elements_capacity: usize = 0,
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *ArrayPayload, rt: *Runtime) void {
        destroyOptionalValueSlice(rt, &self.elements, &self.elements_capacity);
        self.storage_mode = .dense;
    }
};

pub const PromisePayload = struct {
    result: ?Value = null,
    reaction_callback: ?Value = null,
    reaction_arg: ?Value = null,
    reactions: []Value = &.{},
    is_rejected: bool = false,
    atomics_wait_async: bool = false,
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *PromisePayload, rt: *Runtime) void {
        destroyOptionalValue(rt, &self.result);
        destroyOptionalValue(rt, &self.reaction_callback);
        destroyOptionalValue(rt, &self.reaction_arg);
        destroyValueSlice(rt, &self.reactions);
        self.is_rejected = false;
        self.atomics_wait_async = false;
    }
};

pub const GeneratorPayload = struct {
    bytecode: ?Value = null,
    captures: []Value = &.{},
    eval_local_names: []atom.Atom = &.{},
    eval_local_refs: []Value = &.{},
    home_object: ?*Object = null,
    realm_global_ptr: ?*Object = null,
    this_value: ?Value = null,
    args: []Value = &.{},
    stack: []Value = &.{},
    stack_capacity: usize = 0,
    frame_locals: []Value = &.{},
    frame_args: []Value = &.{},
    frame_var_refs: []Value = &.{},
    frame_locals_uninit: []bool = &.{},
    current_function: ?Value = null,
    yield_star_iterator: ?Value = null,
    async_promise: ?Value = null,
    pc: usize = 0,
    resume_completion_type: i32 = 0,
    done: bool = false,
    executing: bool = false,
    started: bool = false,
    just_yielded: bool = false,
    yield_star_suspended: bool = false,

    pub fn destroy(self: *GeneratorPayload, rt: *Runtime) void {
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
    input: ?Value = null,
    last_match: ?Value = null,
    last_paren: ?Value = null,
    left_context: ?Value = null,
    right_context: ?Value = null,
    captures: [9]?Value = @splat(null),
    lazy_no_capture_match: bool = false,
    lazy_match_index: usize = 0,
    lazy_match_len: usize = 0,
    lazy_input_len: usize = 0,

    pub fn destroy(self: *RegExpLegacyStatics, rt: *Runtime) void {
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
    source: ?Value = null,
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
    worker_post_target: u8 = 0,
    iterator_wrap_method: u8 = 0,
    async_from_sync_unwrap_done: u8 = 0,
    primitive_prototypes: [primitive_prototype_slot_count]?Value = @splat(null),
    bytecode: ?Value = null,
    class_fields_init: ?Value = null,
    captures: []Value = &.{},
    eval_local_names: []atom.Atom = &.{},
    eval_local_refs: []Value = &.{},
    eval_parent_function: ?Value = null,
    import_meta: ?Value = null,
    lexical_this: ?Value = null,
    arrow_constructor_this: ?Value = null,
    arrow_new_target: ?Value = null,
    super_constructor: ?Value = null,
    home_object: ?*Object = null,
    private_remap_from: []atom.Atom = &.{},
    private_remap_to: []atom.Atom = &.{},
    realm_global: ?Value = null,
    realm_global_ptr: ?*Object = null,
    proxy_revoke_target: ?Value = null,
    promise_capability_slot: ?Value = null,
    promise_resolving_target: ?Value = null,
    promise_resolving_state: ?Value = null,
    promise_resolving_reject: bool = false,
    promise_thenable_target: ?Value = null,
    promise_thenable_this: ?Value = null,
    promise_thenable_then: ?Value = null,
    promise_reaction_record: ?Value = null,
    promise_reaction_value: ?Value = null,
    promise_reaction_is_rejected: bool = false,
    promise_combinator_state: ?Value = null,
    promise_combinator_index: u32 = 0,
    promise_combinator_mode: u8 = 0,
    promise_combinator_called: bool = false,
    promise_finally_payload: ?Value = null,
    promise_finally_callback: ?Value = null,
    promise_finally_constructor: ?Value = null,
    promise_finally_mode: u8 = 0,
    async_dispose_stack: ?Value = null,
    async_dispose_rejected: bool = false,
    async_function_continuation: ?Value = null,
    async_function_rejected: bool = false,
    realm_type_error_constructor: ?Value = null,
    regexp_legacy_statics: ?*RegExpLegacyStatics = null,

    pub fn destroy(self: *FunctionPayload, rt: *Runtime) void {
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
    cells: []Value = &.{},
    realm_global_ptr: ?*Object = null,

    pub fn destroy(self: *ModuleNamespacePayload, rt: *Runtime) void {
        destroyAtomSlice(rt, &self.names);
        destroyValueSlice(rt, &self.cells);
        self.* = .{};
    }
};

pub const Object = struct {
    header: gc.GCObjectHeader,
    gc: gc.GcNode = .{},
    class_id: class.ClassId,
    class_payload: class.Payload = .none,
    class_payload_kind: class.PayloadKind = .none,
    shape_ref: *shape.Shape,
    prototype: ?*Object = null,
    null_prototype: bool = false,
    extensible: bool = true,
    immutable_prototype: bool = false,
    is_array: bool = false,
    is_proxy: bool = false,
    is_global: bool = false,
    shared_lazy_native_functions: ?*[runtime_mod.shared_lazy_native_function_slots]?Value = null,
    cached_iterator_next: ?Value = null,
    global_lexical_env: ?*Object = null,
    is_html_dda: bool = false,
    may_have_indexed_properties: bool = false,
    length: u32 = 0,
    length_writable: bool = true,
    is_with_environment: bool = false,
    properties: []property.Entry = &.{},
    property_capacity: usize = 0,
    exotic: ?ExoticMethods = null,

    pub fn create(rt: *Runtime, class_id: class.ClassId, prototype: ?*Object) !*Object {
        const self = try rt.memory.create(Object);
        var initialized = false;
        errdefer {
            if (initialized) {
                destroyFromHeader(rt, &self.header);
            } else {
                rt.memory.destroy(Object, self);
            }
        }
        const proto_id = if (prototype) |proto| @intFromPtr(proto) else null;
        const shape_ref = try rt.shapes.createObjectRoot(proto_id);
        var shape_owned = true;
        errdefer if (shape_owned) rt.shapes.release(shape_ref);
        var class_payload: class.Payload = .none;
        var class_payload_kind: class.PayloadKind = .none;
        const payload_kind = if (rt.classes.record(class_id)) |record|
            record.payload_kind
        else
            class.standardPayloadKind(class_id);
        switch (payload_kind) {
            .iterator => {
                const payload = try rt.memory.create(IteratorPayload);
                errdefer rt.memory.destroy(IteratorPayload, payload);
                payload.* = .{};
                class_payload = .{ .external = @ptrCast(payload) };
                class_payload_kind = .iterator;
            },
            .collection => {
                const payload = try rt.memory.create(CollectionPayload);
                errdefer rt.memory.destroy(CollectionPayload, payload);
                payload.* = .{};
                class_payload = .{ .external = @ptrCast(payload) };
                class_payload_kind = .collection;
            },
            .buffer => {
                const payload = try rt.memory.create(BufferPayload);
                errdefer rt.memory.destroy(BufferPayload, payload);
                payload.* = .{};
                class_payload = .{ .external = @ptrCast(payload) };
                class_payload_kind = .buffer;
            },
            .typed_array => {
                const payload = try rt.memory.create(TypedArrayPayload);
                errdefer rt.memory.destroy(TypedArrayPayload, payload);
                payload.* = .{};
                class_payload = .{ .external = @ptrCast(payload) };
                class_payload_kind = .typed_array;
            },
            .regexp => {
                const payload = try rt.memory.create(RegExpPayload);
                errdefer rt.memory.destroy(RegExpPayload, payload);
                payload.* = .{};
                class_payload = .{ .external = @ptrCast(payload) };
                class_payload_kind = .regexp;
            },
            .bound_function => {
                const payload = try rt.memory.create(BoundFunctionPayload);
                errdefer rt.memory.destroy(BoundFunctionPayload, payload);
                payload.* = .{};
                class_payload = .{ .external = @ptrCast(payload) };
                class_payload_kind = .bound_function;
            },
            .proxy => {
                const payload = try rt.memory.create(ProxyPayload);
                errdefer rt.memory.destroy(ProxyPayload, payload);
                payload.* = .{};
                class_payload = .{ .external = @ptrCast(payload) };
                class_payload_kind = .proxy;
            },
            .arguments => {
                const payload = try rt.memory.create(ArgumentsPayload);
                errdefer rt.memory.destroy(ArgumentsPayload, payload);
                payload.* = .{};
                class_payload = .{ .external = @ptrCast(payload) };
                class_payload_kind = .arguments;
            },
            .object_data => {
                const payload = try rt.memory.create(ObjectDataPayload);
                errdefer rt.memory.destroy(ObjectDataPayload, payload);
                payload.* = .{};
                class_payload = .{ .external = @ptrCast(payload) };
                class_payload_kind = .object_data;
            },
            .var_ref => {
                const payload = try rt.memory.create(VarRefPayload);
                errdefer rt.memory.destroy(VarRefPayload, payload);
                payload.* = .{};
                class_payload = .{ .external = @ptrCast(payload) };
                class_payload_kind = .var_ref;
            },
            .array => {
                const payload = try rt.memory.create(ArrayPayload);
                errdefer rt.memory.destroy(ArrayPayload, payload);
                payload.* = .{};
                class_payload = .{ .external = @ptrCast(payload) };
                class_payload_kind = .array;
            },
            .promise => {
                const payload = try rt.memory.create(PromisePayload);
                errdefer rt.memory.destroy(PromisePayload, payload);
                payload.* = .{};
                class_payload = .{ .external = @ptrCast(payload) };
                class_payload_kind = .promise;
            },
            .generator => {
                const payload = try rt.memory.create(GeneratorPayload);
                errdefer rt.memory.destroy(GeneratorPayload, payload);
                payload.* = .{};
                class_payload = .{ .external = @ptrCast(payload) };
                class_payload_kind = .generator;
            },
            .function => {
                const payload = try rt.memory.create(FunctionPayload);
                errdefer rt.memory.destroy(FunctionPayload, payload);
                payload.* = .{};
                class_payload = .{ .external = @ptrCast(payload) };
                class_payload_kind = .function;
            },
            .module_namespace => {
                const payload = try rt.memory.create(ModuleNamespacePayload);
                errdefer rt.memory.destroy(ModuleNamespacePayload, payload);
                payload.* = .{};
                class_payload = .{ .external = @ptrCast(payload) };
                class_payload_kind = .module_namespace;
            },
            .finalization_registry => {
                const payload = try rt.memory.create(FinalizationRegistryPayload);
                errdefer rt.memory.destroy(FinalizationRegistryPayload, payload);
                payload.* = .{};
                class_payload = .{ .external = @ptrCast(payload) };
                class_payload_kind = .finalization_registry;
            },
            .std_file => {
                const payload = try rt.memory.create(StdFilePayload);
                errdefer rt.memory.destroy(StdFilePayload, payload);
                payload.* = .{};
                class_payload = .{ .external = @ptrCast(payload) };
                class_payload_kind = .std_file;
            },
            .disposable_stack => {
                const payload = try rt.memory.create(DisposableStackPayload);
                errdefer rt.memory.destroy(DisposableStackPayload, payload);
                payload.* = .{};
                class_payload = .{ .external = @ptrCast(payload) };
                class_payload_kind = .disposable_stack;
            },
            else => {},
        }
        if (prototype) |proto| gc.retain(&proto.header);
        self.* = .{
            .header = .{ .kind = .object },
            .class_id = class_id,
            .class_payload = class_payload,
            .class_payload_kind = class_payload_kind,
            .shape_ref = shape_ref,
            .prototype = prototype,
        };
        shape_owned = false;
        initialized = true;
        try rt.registerObject(self);
        initialized = false;
        return self;
    }

    pub fn createArray(rt: *Runtime, prototype: ?*Object) !*Object {
        const self = try create(rt, class.ids.array, prototype);
        self.is_array = true;
        return self;
    }

    pub fn value(self: *Object) Value {
        return Value.object(&self.header);
    }

    pub fn cachedIteratorNextSlot(self: *Object) *?Value {
        return &self.cached_iterator_next;
    }

    pub fn cachedIteratorNext(self: *const Object) ?Value {
        return self.cached_iterator_next;
    }

    pub fn clearCachedIteratorNext(self: *Object, rt: *Runtime) void {
        const old_cached = self.cached_iterator_next;
        self.cached_iterator_next = null;
        if (old_cached) |stored| stored.free(rt);
    }

    pub fn ensureSharedLazyNativeFunctionCache(self: *Object, rt: *Runtime) !void {
        if (self.shared_lazy_native_functions != null) return;
        const cache = try rt.memory.create([runtime_mod.shared_lazy_native_function_slots]?Value);
        cache.* = @splat(null);
        self.shared_lazy_native_functions = cache;
    }

    pub fn ensureOrdinaryPayload(self: *Object, rt: *Runtime) !*OrdinaryPayload {
        if (self.ordinaryPayload()) |payload| return payload;
        std.debug.assert(self.class_payload == .none);
        const payload = try rt.memory.create(OrdinaryPayload);
        payload.* = .{};
        self.class_payload = .{ .external = @ptrCast(payload) };
        self.class_payload_kind = .ordinary;
        return payload;
    }

    pub fn ensureRealmPayload(self: *Object, rt: *Runtime) !*RealmPayload {
        if (self.realmPayload()) |payload| return payload;
        const payload = try rt.memory.create(RealmPayload);
        payload.* = .{};
        self.class_payload = .{ .external = @ptrCast(payload) };
        self.class_payload_kind = .realm;
        return payload;
    }

    pub fn cachedFunctionProtoSlot(self: *Object, rt: *Runtime) !*?*Object {
        const payload = try self.ensureRealmPayload(rt);
        return &payload.cached_function_proto;
    }

    pub fn setCachedFunctionProto(self: *Object, rt: *Runtime, prototype: ?*Object) !void {
        const payload = try self.ensureRealmPayload(rt);
        if (prototype) |stored| gc.retain(&stored.header);
        const old_prototype = payload.cached_function_proto;
        payload.cached_function_proto = prototype;
        if (old_prototype) |old| old.value().free(rt);
    }

    pub fn cachedFunctionProto(self: *const Object) ?*Object {
        if (self.realmPayloadConst()) |payload| return payload.cached_function_proto;
        return null;
    }

    pub fn cachedPromiseProtoSlot(self: *Object, rt: *Runtime) !*?*Object {
        const payload = try self.ensureRealmPayload(rt);
        return &payload.cached_promise_proto;
    }

    pub fn setCachedPromiseProto(self: *Object, rt: *Runtime, prototype: ?*Object) !void {
        const payload = try self.ensureRealmPayload(rt);
        if (prototype) |stored| gc.retain(&stored.header);
        const old_prototype = payload.cached_promise_proto;
        payload.cached_promise_proto = prototype;
        if (old_prototype) |old| old.value().free(rt);
    }

    pub fn cachedPromiseProto(self: *const Object) ?*Object {
        if (self.realmPayloadConst()) |payload| return payload.cached_promise_proto;
        return null;
    }

    pub fn cachedRealmValueSlot(self: *Object, rt: *Runtime, slot: RealmValueSlot) !*?Value {
        const payload = try self.ensureRealmPayload(rt);
        return &payload.cached_values[@intFromEnum(slot)];
    }

    pub fn cachedRealmValue(self: *const Object, slot: RealmValueSlot) ?Value {
        if (self.realmPayloadConst()) |payload| return payload.cached_values[@intFromEnum(slot)];
        return null;
    }

    pub fn cachedThrowTypeErrorIntrinsicSlot(self: *Object, rt: *Runtime) !*?Value {
        return self.cachedRealmValueSlot(rt, .throw_type_error_intrinsic);
    }

    pub fn cachedThrowTypeErrorIntrinsic(self: *const Object) ?Value {
        return self.cachedRealmValue(.throw_type_error_intrinsic);
    }

    fn sharedLazyNativeFunctionSlot(self: *Object, slot: u8) ?*?Value {
        if (slot == 0 or slot > runtime_mod.shared_lazy_native_function_slots) return null;
        const cache = self.shared_lazy_native_functions orelse return null;
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
        if (payload.is_popen) {
            const rc = pclose(file);
            return if (rc == -1) -@as(c_int, @intCast(@intFromEnum(std.c.errno(-1)))) else rc;
        } else {
            const rc = std.c.fclose(file);
            return if (rc == -1) -@as(c_int, @intCast(@intFromEnum(std.c.errno(-1)))) else rc;
        }
    }

    pub fn destroyFromHeader(rt: *Runtime, header: *gc.Header) void {
        const self: *Object = @alignCast(@fieldParentPtr("header", header));
        rt.unregisterObject(self);
        clearBorrowedReferencesForDestroyedObject(rt, self);
        self.closeStdFile();
        self.runClassPayloadFinalizer(rt);
        const global_lexical_env = self.global_lexical_env;
        self.global_lexical_env = null;
        const old_properties = self.properties;
        const old_property_capacity = self.property_capacity;
        self.properties = &.{};
        self.property_capacity = 0;
        for (old_properties) |entry| destroyPropertyEntry(rt, entry);
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
        const shared_lazy_native_functions = self.shared_lazy_native_functions;
        self.shared_lazy_native_functions = null;
        if (shared_lazy_native_functions) |cache| {
            for (cache) |*slot| {
                const cached = slot.*;
                slot.* = null;
                if (cached) |stored| stored.free(rt);
            }
            rt.memory.destroy([runtime_mod.shared_lazy_native_function_slots]?Value, cache);
        }
        const cached_iterator_next = self.cached_iterator_next;
        self.cached_iterator_next = null;
        if (cached_iterator_next) |stored| {
            if (rt.gc.phase != .deinit) stored.free(rt);
        }
        if (global_lexical_env) |env| {
            if (rt.gc.phase != .deinit) env.value().free(rt);
        }
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
        const old_prototype = self.prototype;
        self.prototype = null;
        if (old_prototype) |proto| {
            if (rt.gc.phase != .deinit) proto.value().free(rt);
        }
        rt.shapes.release(self.shape_ref);
        rt.memory.destroy(Object, self);
    }

    fn runClassPayloadFinalizer(self: *Object, rt: *Runtime) void {
        if (rt.classes.runPayloadFinalizer(self.class_id, @ptrCast(rt), @ptrCast(self), &self.class_payload) and self.class_payload == .none) {
            self.class_payload_kind = .none;
        }
    }

    fn clearBorrowedReferencesForDestroyedObject(rt: *Runtime, destroyed: *Object) void {
        if (rt.gc.phase == .deinit) return;
        const destroyed_identity = @intFromPtr(&destroyed.header) & ~@as(usize, 1);
        if (rt.borrowedWeakCleanupActive()) {
            if (destroyed.is_global) rt.enqueueBorrowedWeakCleanupRealmIdentity(destroyed_identity);
            if (rt.isCurrentDeferredWeakValueFreeIdentity(destroyed_identity)) return;
            rt.enqueueBorrowedWeakCleanupIdentity(destroyed_identity) catch {
                clearBorrowedReferencesForDestroyedIdentity(rt, destroyed_identity);
            };
            return;
        }

        rt.beginBorrowedWeakCleanup();
        defer rt.endBorrowedWeakCleanup();
        if (destroyed.is_global) rt.enqueueBorrowedWeakCleanupRealmIdentity(destroyed_identity);
        rt.enqueueBorrowedWeakCleanupIdentity(destroyed_identity) catch {
            clearBorrowedReferencesForDestroyedIdentity(rt, destroyed_identity);
        };

        drainBorrowedWeakCleanup(rt);
    }

    pub fn drainBorrowedWeakCleanup(rt: *Runtime) void {
        var scanned_identity_count: usize = 0;
        while (scanned_identity_count < rt.borrowedWeakCleanupIdentityCount() or rt.hasDeferredWeakValueFrees()) {
            while (scanned_identity_count < rt.borrowedWeakCleanupIdentityCount()) {
                const pass_end = rt.borrowedWeakCleanupIdentityCount();
                clearBorrowedReferencesForBorrowedWeakCleanup(rt);
                if (rt.takeBorrowedWeakCleanupNeedsRescan()) {
                    scanned_identity_count = pass_end;
                } else {
                    scanned_identity_count = rt.borrowedWeakCleanupIdentityCount();
                }
            }
            rt.drainDeferredWeakValueFrees();
        }
    }

    fn clearBorrowedReferencesForBorrowedWeakCleanup(rt: *Runtime) void {
        clearBorrowedReferencesForMatcher(rt, .runtime_batch);
    }

    fn clearBorrowedReferencesForDestroyedIdentity(rt: *Runtime, destroyed_identity: usize) void {
        clearBorrowedReferencesForMatcher(rt, .{ .single = destroyed_identity });
    }

    fn clearBorrowedReferencesForMatcher(rt: *Runtime, matcher: BorrowedIdentityMatcher) void {
        var index: usize = 0;
        while (index < rt.borrowed_reference_holders.len) {
            const current = rt.borrowed_reference_holders[index];
            if (current.header.rc == 0) {
                index += 1;
                continue;
            }
            if (!current.mayContainBorrowedReferences(rt)) {
                index += 1;
                continue;
            }
            gc.retain(&current.header);
            current.clearBorrowedReferencesToDestroyedIdentities(rt, matcher);
            rt.markBorrowedWeakCleanupHolderSeen();
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

    fn runtimeBorrowedReferenceHolderIndex(rt: *Runtime, object: *Object) ?usize {
        for (rt.borrowed_reference_holders, 0..) |candidate, index| {
            if (candidate == object) return index;
        }
        return null;
    }

    fn registerBorrowedHolderForPendingMutation(rt: *Runtime, object: *Object) !bool {
        const was_registered = rt.borrowedReferenceHolderRegistered(object);
        try rt.registerBorrowedReferenceHolder(object);
        return !was_registered;
    }

    fn rollbackBorrowedHolderRegistration(rt: *Runtime, object: *Object, inserted: bool) void {
        if (inserted) rt.unregisterBorrowedReferenceHolder(object);
    }

    pub fn pruneBorrowedReferenceHolderIfEmpty(self: *Object, rt: *Runtime) void {
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
                .auto_init => |info| {
                    if (info.host_function_realm_global != 0) return true;
                },
                else => {},
            }
        }
        return false;
    }

    fn mayContainBorrowedReferences(self: *const Object, rt: *Runtime) bool {
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
                    .auto_init => |info| {
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
        runtime_batch: void,

        fn matches(self: BorrowedIdentityMatcher, rt: *Runtime, identity: usize) bool {
            return switch (self) {
                .single => |stored| stored == identity,
                .runtime_batch => rt.borrowedWeakCleanupIdentityMatches(identity),
            };
        }
    };

    fn clearBorrowedReferencesToDestroyedIdentities(self: *Object, rt: *Runtime, matcher: BorrowedIdentityMatcher) void {
        self.clearWeakIdentities(rt, matcher);
        self.clearRealmGlobalPtrs(rt, matcher);
        self.clearAutoInitRealmGlobals(rt, matcher);
        self.pruneBorrowedReferenceHolderIfEmpty(rt);
    }

    fn clearWeakIdentities(self: *Object, rt: *Runtime, matcher: BorrowedIdentityMatcher) void {
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
            const cell = finalization_payload.cells[read_index];
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

            if (cell.active) enqueueFinalizationCleanup(rt, finalization_payload.cleanup_callback, cell.held_value);
            cell.destroy(rt);
        }
        finalization_payload.cells = finalization_payload.cells.ptr[0..write_index];
    }

    fn deferWeakEntryValueFree(rt: *Runtime, entry: WeakCollectionEntry) void {
        const prequeued_identity = prequeueBorrowedWeakCleanupIdentityForOwnedValue(rt, entry.value);
        rt.enqueueDeferredWeakValueFreeWithPrequeuedIdentity(entry.value, prequeued_identity) catch |err| switch (err) {
            error.OutOfMemory => entry.value.free(rt),
        };
    }

    fn prequeueBorrowedWeakCleanupIdentityForOwnedValue(rt: *Runtime, stored_value: Value) ?usize {
        return rt.prequeueBorrowedWeakCleanupIdentityForLastRefValue(stored_value);
    }

    fn clearRealmGlobalPtrs(self: *Object, rt: *Runtime, matcher: BorrowedIdentityMatcher) void {
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

    fn clearObjectPtr(slot: *?*Object, rt: *Runtime, matcher: BorrowedIdentityMatcher) void {
        if (slot.*) |stored| {
            const identity = @intFromPtr(&stored.header) & ~@as(usize, 1);
            if (matcher.matches(rt, identity)) slot.* = null;
        }
    }

    fn clearAutoInitRealmGlobals(self: *Object, rt: *Runtime, matcher: BorrowedIdentityMatcher) void {
        for (self.properties) |*entry| {
            switch (entry.slot) {
                .auto_init => |*info| {
                    if (matcher.matches(rt, info.host_function_realm_global)) info.host_function_realm_global = 0;
                },
                else => {},
            }
        }
    }

    pub const post_a_object_size_baseline: usize = 432;
    comptime {
        std.debug.assert(@sizeOf(Object) <= post_a_object_size_baseline / 2);
    }

    pub fn iteratorTargetSlot(self: *Object) *?Value {
        if (self.iteratorPayload()) |payload| return &payload.target;
        std.debug.assert(self.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorTarget(self: *const Object) ?Value {
        if (self.iteratorPayloadConst()) |payload| return payload.target;
        return null;
    }

    pub fn iteratorDataSlot(self: *Object) *?Value {
        if (self.iteratorPayload()) |payload| return &payload.data;
        std.debug.assert(self.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorData(self: *const Object) ?Value {
        if (self.iteratorPayloadConst()) |payload| return payload.data;
        return null;
    }

    pub fn iteratorNextSlot(self: *Object) *?Value {
        if (self.iteratorPayload()) |payload| return &payload.next;
        std.debug.assert(self.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorNext(self: *const Object) ?Value {
        if (self.iteratorPayloadConst()) |payload| return payload.next;
        return null;
    }

    pub fn iteratorCallbackSlot(self: *Object) *?Value {
        if (self.iteratorPayload()) |payload| return &payload.callback;
        std.debug.assert(self.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorCallback(self: *const Object) ?Value {
        if (self.iteratorPayloadConst()) |payload| return payload.callback;
        return null;
    }

    pub fn iteratorInnerNextSlot(self: *Object) *?Value {
        if (self.iteratorPayload()) |payload| return &payload.inner_next;
        std.debug.assert(self.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorInnerNext(self: *const Object) ?Value {
        if (self.iteratorPayloadConst()) |payload| return payload.inner_next;
        return null;
    }

    pub fn iteratorZipNextsSlot(self: *Object) *?Value {
        if (self.iteratorPayload()) |payload| return &payload.zip_nexts;
        std.debug.assert(self.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorZipNexts(self: *const Object) ?Value {
        if (self.iteratorPayloadConst()) |payload| return payload.zip_nexts;
        return null;
    }

    pub fn iteratorZipPadsSlot(self: *Object) *?Value {
        if (self.iteratorPayload()) |payload| return &payload.zip_pads;
        std.debug.assert(self.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorZipPads(self: *const Object) ?Value {
        if (self.iteratorPayloadConst()) |payload| return payload.zip_pads;
        return null;
    }

    pub fn iteratorZipKeysSlot(self: *Object) *?Value {
        if (self.iteratorPayload()) |payload| return &payload.zip_keys;
        std.debug.assert(self.class_payload_kind == .iterator);
        unreachable;
    }

    pub fn iteratorZipKeys(self: *const Object) ?Value {
        if (self.iteratorPayloadConst()) |payload| return payload.zip_keys;
        return null;
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

    pub fn clearIteratorTarget(self: *Object, rt: *Runtime) void {
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

    pub fn ensureCollectionEntryCapacity(self: *Object, rt: *Runtime, min_capacity: usize) !void {
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

    pub fn appendCollectionEntryUnindexed(self: *Object, rt: *Runtime, entry: CollectionEntry) !usize {
        const entries_slot = self.collectionEntriesSlot();
        const index = entries_slot.*.len;
        try self.ensureCollectionEntryCapacity(rt, index + 1);
        const refreshed_entries = self.collectionEntriesSlot();
        refreshed_entries.* = refreshed_entries.*.ptr[0 .. index + 1];
        refreshed_entries.*[index] = entry;
        return index;
    }

    pub fn clearCollectionIndex(self: *Object, rt: *Runtime) void {
        const heads = self.collectionBucketHeadsSlot();
        const old_heads = heads.*;
        heads.* = &.{};
        if (old_heads.len != 0) rt.memory.free(usize, old_heads);
        for (self.collectionEntriesSlot().*) |*entry| entry.hash_next = collection_no_entry;
        for (self.weakCollectionEntriesSlot().*) |*entry| entry.hash_next = collection_no_entry;
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

    pub fn ensureWeakCollectionEntryCapacity(self: *Object, rt: *Runtime, min_capacity: usize) !void {
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

    pub fn finalizationRegistryCleanupCallbackSlot(self: *Object) *?Value {
        if (self.finalizationRegistryPayload()) |payload| return &payload.cleanup_callback;
        std.debug.assert(self.class_payload_kind == .finalization_registry);
        unreachable;
    }

    pub fn finalizationRegistryCleanupCallback(self: *const Object) ?Value {
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

    pub fn unregisterFinalizationRegistryCells(self: *Object, rt: *Runtime, token: Value) bool {
        std.debug.assert(self.class_id == class.ids.finalization_registry);
        const token_stable = token.dup();
        defer token_stable.free(rt);

        const entries = self.finalizationRegistryCellsSlot();
        var removed = false;
        var index: usize = 0;
        while (index < entries.*.len) {
            const entry = &entries.*[index];
            if (!entry.active) {
                index += 1;
                continue;
            }
            if (!entry.unregister_token.same(token_stable)) {
                index += 1;
                continue;
            }

            const removed_cell = entry.*;
            if (index + 1 < entries.*.len) {
                @memmove(entries.*[index .. entries.*.len - 1], entries.*[index + 1 ..]);
            }
            entries.* = entries.*.ptr[0 .. entries.*.len - 1];
            removed = true;
            removed_cell.destroy(rt);
            index = 0;
        }
        if (removed) self.pruneBorrowedReferenceHolderIfEmpty(rt);
        return removed;
    }

    pub fn ensureFinalizationRegistryCellCapacity(self: *Object, rt: *Runtime, min_capacity: usize) !void {
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
        rt: *Runtime,
        target: Value,
        held_value: Value,
        unregister_token: Value,
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

        const entries = self.finalizationRegistryCellsSlot();
        const index = entries.*.len;
        const inserted_holder = !rt.borrowedReferenceHolderRegistered(self);
        try rt.registerBorrowedReferenceHolder(self);
        errdefer if (inserted_holder) rt.unregisterBorrowedReferenceHolder(self);
        try self.ensureFinalizationRegistryCellCapacity(rt, index + 1);
        const refreshed_entries = self.finalizationRegistryCellsSlot();
        refreshed_entries.* = refreshed_entries.*.ptr[0 .. index + 1];
        refreshed_entries.*[index] = .{
            .target_identity = weakIdentityFromValue(rooted_target),
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
        rt: *Runtime,
        resource_value: Value,
        method: Value,
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
        payload.resources[index] = .{
            .value = resource_value.dup(),
            .method = method.dup(),
            .kind = kind,
            .await_result = await_result,
        };
    }

    pub fn disposableStackAsyncResolveSlot(self: *Object) *?Value {
        if (self.disposableStackPayload()) |payload| return &payload.async_dispose_resolve;
        std.debug.assert(self.class_payload_kind == .disposable_stack);
        unreachable;
    }

    pub fn disposableStackAsyncRejectSlot(self: *Object) *?Value {
        if (self.disposableStackPayload()) |payload| return &payload.async_dispose_reject;
        std.debug.assert(self.class_payload_kind == .disposable_stack);
        unreachable;
    }

    pub fn disposableStackAsyncErrorSlot(self: *Object) *?Value {
        if (self.disposableStackPayload()) |payload| return &payload.async_dispose_error;
        std.debug.assert(self.class_payload_kind == .disposable_stack);
        unreachable;
    }

    pub fn clearDisposableStackAsyncCapability(self: *Object, rt: *Runtime) void {
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

    pub fn moveDisposableResourcesTo(self: *Object, target: *Object) void {
        const source_payload = self.disposableStackPayload() orelse {
            std.debug.assert(self.class_payload_kind == .disposable_stack);
            unreachable;
        };
        const target_payload = target.disposableStackPayload() orelse {
            std.debug.assert(target.class_payload_kind == .disposable_stack);
            unreachable;
        };
        std.debug.assert(target_payload.resources.len == 0 and target_payload.resource_capacity == 0);
        target_payload.resources = source_payload.resources;
        target_payload.resource_capacity = source_payload.resource_capacity;
        source_payload.resources = &.{};
        source_payload.resource_capacity = 0;
    }

    pub fn ensureVarRefPayload(self: *Object, rt: *Runtime) !*VarRefPayload {
        if (self.varRefPayload()) |payload| return payload;
        std.debug.assert(self.class_payload == .none);
        const payload = try rt.memory.create(VarRefPayload);
        payload.* = .{};
        self.class_payload = .{ .external = @ptrCast(payload) };
        self.class_payload_kind = .var_ref;
        return payload;
    }

    pub fn initVarRefPayload(self: *Object, rt: *Runtime, initial_value: Value) !void {
        const payload = try self.ensureVarRefPayload(rt);
        const old_value = payload.value;
        payload.value = initial_value;
        payload.is_deleted = false;
        if (old_value) |stored| stored.free(rt);
    }

    pub fn varRefValueSlot(self: *Object) *?Value {
        if (self.varRefPayload()) |payload| return &payload.value;
        std.debug.assert(self.class_payload_kind == .var_ref);
        unreachable;
    }

    pub fn varRefValue(self: *const Object) ?Value {
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

    pub fn ensureTypedArrayPayload(self: *Object, rt: *Runtime) !void {
        if (self.typedArrayPayload() != null) return;
        const payload = try rt.memory.create(TypedArrayPayload);
        payload.* = .{};
        self.class_payload = .{ .external = @ptrCast(payload) };
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

    pub fn sharedByteStorageStore(self: *const Object) ?*SharedBufferStore {
        const payload = self.bufferPayloadConst() orelse return null;
        return payload.shared_store;
    }

    pub fn installSharedByteStorage(self: *Object, rt: *Runtime, store: *SharedBufferStore) void {
        if (self.bufferPayload()) |payload| {
            if (payload.shared_store) |old_store| {
                old_store.release();
            } else if (payload.bytes.len != 0) {
                rt.memory.free(u8, payload.bytes);
            }
            payload.shared_store = store;
            payload.bytes = store.bytes;
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

    pub fn typedArrayBufferSlot(self: *Object) *?Value {
        if (self.typedArrayPayload()) |payload| return &payload.buffer;
        std.debug.assert(self.class_payload_kind == .typed_array);
        unreachable;
    }

    pub fn typedArrayBuffer(self: *const Object) ?Value {
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

    pub fn regexpSourceSlot(self: *Object) *?Value {
        if (self.regExpPayload()) |payload| return &payload.source;
        std.debug.assert(self.class_payload_kind == .regexp);
        unreachable;
    }

    pub fn regexpSource(self: *const Object) ?Value {
        if (self.regExpPayloadConst()) |payload| return payload.source;
        return null;
    }

    pub fn regexpFlagsSlot(self: *Object) *?Value {
        if (self.regExpPayload()) |payload| return &payload.flags;
        std.debug.assert(self.class_payload_kind == .regexp);
        unreachable;
    }

    pub fn regexpFlags(self: *const Object) ?Value {
        if (self.regExpPayloadConst()) |payload| return payload.flags;
        return null;
    }

    pub fn regexpLastIndexSlot(self: *Object) *?Value {
        if (self.regExpPayload()) |payload| return &payload.last_index;
        std.debug.assert(self.class_payload_kind == .regexp);
        unreachable;
    }

    pub fn regexpLastIndex(self: *const Object) ?Value {
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

    pub fn clearRegexpCompiledBytecode(self: *Object, rt: *Runtime) void {
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

    pub fn setRegexpCompiledBytecode(self: *Object, rt: *Runtime, bytecode: []const u8) !void {
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

    pub fn boundTargetSlot(self: *Object) *?Value {
        if (self.boundFunctionPayload()) |payload| return &payload.target;
        std.debug.assert(self.class_id == class.ids.bound_function);
        unreachable;
    }

    pub fn boundTarget(self: *const Object) ?Value {
        if (self.boundFunctionPayloadConst()) |payload| return payload.target;
        return null;
    }

    pub fn boundThisSlot(self: *Object) *?Value {
        if (self.boundFunctionPayload()) |payload| return &payload.this_value;
        std.debug.assert(self.class_id == class.ids.bound_function);
        unreachable;
    }

    pub fn boundThis(self: *const Object) ?Value {
        if (self.boundFunctionPayloadConst()) |payload| return payload.this_value;
        return null;
    }

    pub fn boundArgsSlot(self: *Object) *[]Value {
        if (self.boundFunctionPayload()) |payload| return &payload.args;
        std.debug.assert(self.class_id == class.ids.bound_function);
        unreachable;
    }

    pub fn boundArgs(self: *const Object) []Value {
        if (self.boundFunctionPayloadConst()) |payload| return payload.args;
        return &.{};
    }

    pub fn ensureProxyPayload(self: *Object, rt: *Runtime) !void {
        if (self.proxyPayload() != null) return;
        const payload = try rt.memory.create(ProxyPayload);
        payload.* = .{};
        self.class_payload = .{ .external = @ptrCast(payload) };
        self.class_payload_kind = .proxy;
    }

    pub fn proxyTargetSlot(self: *Object) *?Value {
        if (self.proxyPayload()) |payload| return &payload.target;
        std.debug.assert(self.is_proxy);
        unreachable;
    }

    pub fn proxyTarget(self: *const Object) ?Value {
        if (self.proxyPayloadConst()) |payload| return payload.target;
        return null;
    }

    pub fn proxyHandlerSlot(self: *Object) *?Value {
        if (self.proxyPayload()) |payload| return &payload.handler;
        std.debug.assert(self.is_proxy);
        unreachable;
    }

    pub fn proxyHandler(self: *const Object) ?Value {
        if (self.proxyPayloadConst()) |payload| return payload.handler;
        return null;
    }

    pub fn argumentsVarRefsSlot(self: *Object) *[]Value {
        if (self.argumentsPayload()) |payload| return &payload.var_refs;
        std.debug.assert(self.class_id == class.ids.arguments or self.class_id == class.ids.mapped_arguments);
        unreachable;
    }

    pub fn argumentsVarRefs(self: *const Object) []Value {
        if (self.argumentsPayloadConst()) |payload| return payload.var_refs;
        return &.{};
    }

    pub fn objectDataSlot(self: *Object) *?Value {
        if (self.objectDataPayload()) |payload| return &payload.data;
        std.debug.assert(self.class_payload_kind == .object_data);
        unreachable;
    }

    pub fn objectData(self: *const Object) ?Value {
        if (self.objectDataPayloadConst()) |payload| return payload.data;
        return null;
    }

    pub fn setWeakRefTarget(self: *Object, rt: *Runtime, target: Value) !void {
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

        try rt.registerBorrowedReferenceHolder(self);
        const payload = self.objectDataPayload() orelse {
            std.debug.assert(self.class_payload_kind == .object_data);
            unreachable;
        };
        const old_target = payload.data;
        payload.data = null;
        payload.weak_target_identity = weakIdentityFromValue(rooted_target);
        if (old_target) |stored| stored.free(rt);
        self.pruneBorrowedReferenceHolderIfEmpty(rt);
    }

    pub fn weakRefDeref(self: *const Object, rt: *Runtime) Value {
        std.debug.assert(self.class_id == class.ids.weak_ref);
        const payload = self.objectDataPayloadConst() orelse return Value.undefinedValue();
        const identity = payload.weak_target_identity orelse return Value.undefinedValue();
        if ((identity & 1) != 0) {
            const atom_id = identity >> 1;
            if (atom_id > std.math.maxInt(atom.Atom)) return Value.undefinedValue();
            const symbol_atom: atom.Atom = @intCast(atom_id);
            return if (rt.atoms.kind(symbol_atom) == .symbol) Value.symbol(symbol_atom) else Value.undefinedValue();
        }
        const target = liveObjectFromWeakIdentity(rt, identity) orelse return Value.undefinedValue();
        return target.value().dup();
    }

    pub fn arrayStorageModeSlot(self: *Object) *ArrayStorageMode {
        if (self.arrayPayload()) |payload| return &payload.storage_mode;
        std.debug.assert(self.is_array);
        unreachable;
    }

    pub fn arrayElementStorageMode(self: *const Object) ArrayStorageMode {
        if (self.arrayPayloadConst()) |payload| return payload.storage_mode;
        return .dense;
    }

    pub fn arrayElementsSlot(self: *Object) *[]?Value {
        if (self.arrayPayload()) |payload| return &payload.elements;
        std.debug.assert(self.is_array);
        unreachable;
    }

    pub fn arrayElements(self: *const Object) []?Value {
        if (self.arrayPayloadConst()) |payload| return payload.elements;
        return &.{};
    }

    pub fn arrayElementsCapacitySlot(self: *Object) *usize {
        if (self.arrayPayload()) |payload| return &payload.elements_capacity;
        std.debug.assert(self.is_array);
        unreachable;
    }

    pub fn arrayElementsCapacity(self: *const Object) usize {
        if (self.arrayPayloadConst()) |payload| return payload.elements_capacity;
        return 0;
    }

    pub fn promiseResultSlot(self: *Object) *?Value {
        if (self.promisePayload()) |payload| return &payload.result;
        std.debug.assert(self.class_payload_kind == .promise);
        unreachable;
    }

    pub fn promiseResult(self: *const Object) ?Value {
        if (self.promisePayloadConst()) |payload| return payload.result;
        return null;
    }

    pub fn promiseReactionCallbackSlot(self: *Object) *?Value {
        if (self.promisePayload()) |payload| return &payload.reaction_callback;
        std.debug.assert(self.class_payload_kind == .promise);
        unreachable;
    }

    pub fn promiseReactionCallback(self: *const Object) ?Value {
        if (self.promisePayloadConst()) |payload| return payload.reaction_callback;
        return null;
    }

    pub fn promiseReactionArgSlot(self: *Object) *?Value {
        if (self.promisePayload()) |payload| return &payload.reaction_arg;
        std.debug.assert(self.class_payload_kind == .promise);
        unreachable;
    }

    pub fn promiseReactionArg(self: *const Object) ?Value {
        if (self.promisePayloadConst()) |payload| return payload.reaction_arg;
        return null;
    }

    pub fn promiseReactionsSlot(self: *Object) *[]Value {
        if (self.promisePayload()) |payload| return &payload.reactions;
        std.debug.assert(self.class_payload_kind == .promise);
        unreachable;
    }

    pub fn promiseReactions(self: *const Object) []Value {
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

    pub fn generatorThisSlot(self: *Object) *?Value {
        if (self.generatorPayload()) |payload| return &payload.this_value;
        std.debug.assert(self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorThis(self: *const Object) ?Value {
        if (self.generatorPayloadConst()) |payload| return payload.this_value;
        return null;
    }

    pub fn generatorArgsSlot(self: *Object) *[]Value {
        if (self.generatorPayload()) |payload| return &payload.args;
        std.debug.assert(self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorArgs(self: *const Object) []Value {
        if (self.generatorPayloadConst()) |payload| return payload.args;
        return &.{};
    }

    pub fn generatorStackSlot(self: *Object) *[]Value {
        if (self.generatorPayload()) |payload| return &payload.stack;
        std.debug.assert(self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorStack(self: *const Object) []Value {
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

    pub fn generatorFrameLocalsSlot(self: *Object) *[]Value {
        if (self.generatorPayload()) |payload| return &payload.frame_locals;
        std.debug.assert(self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorFrameLocals(self: *const Object) []Value {
        if (self.generatorPayloadConst()) |payload| return payload.frame_locals;
        return &.{};
    }

    pub fn generatorFrameArgsSlot(self: *Object) *[]Value {
        if (self.generatorPayload()) |payload| return &payload.frame_args;
        std.debug.assert(self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorFrameArgs(self: *const Object) []Value {
        if (self.generatorPayloadConst()) |payload| return payload.frame_args;
        return &.{};
    }

    pub fn generatorFrameVarRefsSlot(self: *Object) *[]Value {
        if (self.generatorPayload()) |payload| return &payload.frame_var_refs;
        std.debug.assert(self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorFrameVarRefs(self: *const Object) []Value {
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

    pub fn generatorCurrentFunctionSlot(self: *Object) *?Value {
        if (self.generatorPayload()) |payload| return &payload.current_function;
        std.debug.assert(self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorCurrentFunction(self: *const Object) ?Value {
        if (self.generatorPayloadConst()) |payload| return payload.current_function;
        return null;
    }

    pub fn generatorYieldStarIteratorSlot(self: *Object) *?Value {
        if (self.generatorPayload()) |payload| return &payload.yield_star_iterator;
        std.debug.assert(self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorYieldStarIterator(self: *const Object) ?Value {
        if (self.generatorPayloadConst()) |payload| return payload.yield_star_iterator;
        return null;
    }

    pub fn generatorAsyncPromiseSlot(self: *Object) *?Value {
        if (self.generatorPayload()) |payload| return &payload.async_promise;
        std.debug.assert(self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn generatorAsyncPromise(self: *const Object) ?Value {
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

    pub fn functionSourceSlot(self: *Object) *?Value {
        if (self.functionPayload()) |payload| return &payload.source;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionSource(self: *const Object) ?Value {
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

    pub fn functionWorkerPostTargetSlot(self: *Object) *u8 {
        if (self.functionPayload()) |payload| return &payload.worker_post_target;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionWorkerPostTarget(self: *const Object) u8 {
        if (self.functionPayloadConst()) |payload| return payload.worker_post_target;
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

    pub fn functionPrimitivePrototypeSlot(self: *Object, slot: PrimitivePrototypeSlot) *?Value {
        if (self.functionPayload()) |payload| return &payload.primitive_prototypes[@intFromEnum(slot)];
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPrimitivePrototype(self: *const Object, slot: PrimitivePrototypeSlot) ?Value {
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

    pub fn ensureRegExpLegacyStatics(self: *Object, rt: *Runtime) !*RegExpLegacyStatics {
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

    pub fn functionBytecodeSlot(self: *Object) *?Value {
        if (self.functionPayload()) |payload| return &payload.bytecode;
        if (self.generatorPayload()) |payload| return &payload.bytecode;
        std.debug.assert(self.class_payload_kind == .function or self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn functionBytecode(self: *const Object) ?Value {
        if (self.functionPayloadConst()) |payload| return payload.bytecode;
        if (self.generatorPayloadConst()) |payload| return payload.bytecode;
        return null;
    }

    pub fn functionClassFieldsInitSlot(self: *Object) *?Value {
        if (self.functionPayload()) |payload| return &payload.class_fields_init;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionClassFieldsInit(self: *const Object) ?Value {
        if (self.functionPayloadConst()) |payload| return payload.class_fields_init;
        return null;
    }

    pub fn functionEvalParentFunctionSlot(self: *Object) *?Value {
        if (self.functionPayload()) |payload| return &payload.eval_parent_function;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionEvalParentFunction(self: *const Object) ?Value {
        if (self.functionPayloadConst()) |payload| return payload.eval_parent_function;
        return null;
    }

    pub fn functionImportMetaSlot(self: *Object) *?Value {
        if (self.functionPayload()) |payload| return &payload.import_meta;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionImportMeta(self: *const Object) ?Value {
        if (self.functionPayloadConst()) |payload| return payload.import_meta;
        return null;
    }

    pub fn functionProxyRevokeTargetSlot(self: *Object) *?Value {
        if (self.functionPayload()) |payload| return &payload.proxy_revoke_target;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionProxyRevokeTarget(self: *const Object) ?Value {
        if (self.functionPayloadConst()) |payload| return payload.proxy_revoke_target;
        return null;
    }

    pub fn functionPromiseCapabilitySlotSlot(self: *Object) *?Value {
        if (self.functionPayload()) |payload| return &payload.promise_capability_slot;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseCapabilitySlot(self: *const Object) ?Value {
        if (self.functionPayloadConst()) |payload| return payload.promise_capability_slot;
        return null;
    }

    pub fn functionPromiseResolvingTargetSlot(self: *Object) *?Value {
        if (self.functionPayload()) |payload| return &payload.promise_resolving_target;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseResolvingTarget(self: *const Object) ?Value {
        if (self.functionPayloadConst()) |payload| return payload.promise_resolving_target;
        return null;
    }

    pub fn functionPromiseResolvingStateSlot(self: *Object) *?Value {
        if (self.functionPayload()) |payload| return &payload.promise_resolving_state;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseResolvingState(self: *const Object) ?Value {
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

    pub fn functionPromiseThenableTargetSlot(self: *Object) *?Value {
        if (self.functionPayload()) |payload| return &payload.promise_thenable_target;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseThenableTarget(self: *const Object) ?Value {
        if (self.functionPayloadConst()) |payload| return payload.promise_thenable_target;
        return null;
    }

    pub fn functionPromiseThenableThisSlot(self: *Object) *?Value {
        if (self.functionPayload()) |payload| return &payload.promise_thenable_this;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseThenableThis(self: *const Object) ?Value {
        if (self.functionPayloadConst()) |payload| return payload.promise_thenable_this;
        return null;
    }

    pub fn functionPromiseThenableThenSlot(self: *Object) *?Value {
        if (self.functionPayload()) |payload| return &payload.promise_thenable_then;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseThenableThen(self: *const Object) ?Value {
        if (self.functionPayloadConst()) |payload| return payload.promise_thenable_then;
        return null;
    }

    pub fn functionPromiseReactionRecordSlot(self: *Object) *?Value {
        if (self.functionPayload()) |payload| return &payload.promise_reaction_record;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseReactionRecord(self: *const Object) ?Value {
        if (self.functionPayloadConst()) |payload| return payload.promise_reaction_record;
        return null;
    }

    pub fn functionPromiseReactionValueSlot(self: *Object) *?Value {
        if (self.functionPayload()) |payload| return &payload.promise_reaction_value;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseReactionValue(self: *const Object) ?Value {
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

    pub fn functionPromiseCombinatorStateSlot(self: *Object) *?Value {
        if (self.functionPayload()) |payload| return &payload.promise_combinator_state;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseCombinatorState(self: *const Object) ?Value {
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

    pub fn functionPromiseFinallyPayloadSlot(self: *Object) *?Value {
        if (self.functionPayload()) |payload| return &payload.promise_finally_payload;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseFinallyPayload(self: *const Object) ?Value {
        if (self.functionPayloadConst()) |payload| return payload.promise_finally_payload;
        return null;
    }

    pub fn functionPromiseFinallyCallbackSlot(self: *Object) *?Value {
        if (self.functionPayload()) |payload| return &payload.promise_finally_callback;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseFinallyCallback(self: *const Object) ?Value {
        if (self.functionPayloadConst()) |payload| return payload.promise_finally_callback;
        return null;
    }

    pub fn functionPromiseFinallyConstructorSlot(self: *Object) *?Value {
        if (self.functionPayload()) |payload| return &payload.promise_finally_constructor;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionPromiseFinallyConstructor(self: *const Object) ?Value {
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

    pub fn functionAsyncDisposeStackSlot(self: *Object) *?Value {
        if (self.functionPayload()) |payload| return &payload.async_dispose_stack;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionAsyncDisposeStack(self: *const Object) ?Value {
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

    pub fn functionAsyncContinuationSlot(self: *Object) *?Value {
        if (self.functionPayload()) |payload| return &payload.async_function_continuation;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionAsyncContinuation(self: *const Object) ?Value {
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

    pub fn functionRealmTypeErrorConstructorSlot(self: *Object) *?Value {
        if (self.functionPayload()) |payload| return &payload.realm_type_error_constructor;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionRealmTypeErrorConstructor(self: *const Object) ?Value {
        if (self.functionPayloadConst()) |payload| return payload.realm_type_error_constructor;
        return null;
    }

    pub fn functionArrowConstructorThisSlot(self: *Object) *?Value {
        if (self.functionPayload()) |payload| return &payload.arrow_constructor_this;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionArrowConstructorThis(self: *const Object) ?Value {
        if (self.functionPayloadConst()) |payload| return payload.arrow_constructor_this;
        return null;
    }

    pub fn functionArrowNewTargetSlot(self: *Object) *?Value {
        if (self.functionPayload()) |payload| return &payload.arrow_new_target;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionArrowNewTarget(self: *const Object) ?Value {
        if (self.functionPayloadConst()) |payload| return payload.arrow_new_target;
        return null;
    }

    pub fn functionSuperConstructorSlot(self: *Object) *?Value {
        if (self.functionPayload()) |payload| return &payload.super_constructor;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionSuperConstructor(self: *const Object) ?Value {
        if (self.functionPayloadConst()) |payload| return payload.super_constructor;
        return null;
    }

    pub fn functionCapturesSlot(self: *Object) *[]Value {
        if (self.functionPayload()) |payload| return &payload.captures;
        if (self.generatorPayload()) |payload| return &payload.captures;
        std.debug.assert(self.class_payload_kind == .function or self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn functionCaptures(self: *const Object) []Value {
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

    pub fn functionEvalLocalRefsSlot(self: *Object) *[]Value {
        if (self.functionPayload()) |payload| return &payload.eval_local_refs;
        if (self.generatorPayload()) |payload| return &payload.eval_local_refs;
        std.debug.assert(self.class_payload_kind == .function or self.class_payload_kind == .generator);
        unreachable;
    }

    pub fn functionEvalLocalRefs(self: *const Object) []Value {
        if (self.functionPayloadConst()) |payload| return payload.eval_local_refs;
        if (self.generatorPayloadConst()) |payload| return payload.eval_local_refs;
        return &.{};
    }

    pub fn functionLexicalThisSlot(self: *Object) *?Value {
        if (self.functionPayload()) |payload| return &payload.lexical_this;
        std.debug.assert(self.class_payload_kind == .function);
        unreachable;
    }

    pub fn functionLexicalThis(self: *const Object) ?Value {
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
    pub fn setFunctionHomeObject(self: *Object, rt: *Runtime, home_object: ?*Object) void {
        const slot = self.functionHomeObjectSlot();
        if (slot.* == home_object) return;
        if (home_object) |next| gc.retain(&next.header);
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

    pub fn privateRemapFromSlotEnsured(self: *Object, rt: *Runtime) !*[]atom.Atom {
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

    pub fn privateRemapToSlotEnsured(self: *Object, rt: *Runtime) !*[]atom.Atom {
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
        rt: *Runtime,
        file: Value,
        function_name: Value,
        line: i32,
        column: i32,
    ) !void {
        const payload = try self.ensureOrdinaryPayload(rt);
        const next_file = file.dup();
        const next_function = function_name.dup();
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

    pub fn callSiteFile(self: *const Object) ?Value {
        if (self.ordinaryPayloadConst()) |payload| return payload.callsite_file;
        return null;
    }

    pub fn callSiteFunctionName(self: *const Object) ?Value {
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

    pub fn setErrorStack(self: *Object, rt: *Runtime, stack_value: Value) !void {
        const payload = try self.ensureOrdinaryPayload(rt);
        const next_value = stack_value.dup();
        const old_value = payload.error_stack;
        const old_sites = payload.error_stack_sites;
        payload.error_stack = next_value;
        payload.error_stack_sites = null;
        payload.error_stack_site_count = 0;
        if (old_value) |stored| stored.free(rt);
        if (old_sites) |stored| stored.free(rt);
    }

    pub fn errorStack(self: *const Object) ?Value {
        if (self.ordinaryPayloadConst()) |payload| return payload.error_stack;
        return null;
    }

    pub fn setErrorStackSites(self: *Object, rt: *Runtime, sites_value: Value) !void {
        const payload = try self.ensureOrdinaryPayload(rt);
        const next_value = sites_value.dup();
        const old_stack = payload.error_stack;
        const old_sites = payload.error_stack_sites;
        payload.error_stack = null;
        payload.error_stack_sites = next_value;
        payload.error_stack_site_count = capturedStackSiteCount(sites_value);
        if (old_stack) |stored| stored.free(rt);
        if (old_sites) |stored| stored.free(rt);
    }

    pub fn errorStackSites(self: *const Object) ?Value {
        if (self.ordinaryPayloadConst()) |payload| return payload.error_stack_sites;
        return null;
    }

    pub fn errorStackSiteCount(self: *const Object) usize {
        if (self.ordinaryPayloadConst()) |payload| return payload.error_stack_site_count;
        return 0;
    }

    fn capturedStackSiteCount(sites_value: Value) usize {
        const sites = objectFromValue(sites_value) orelse return 0;
        return if (sites.is_array) @intCast(sites.length) else 0;
    }

    pub fn promiseReactionOnFulfilledSlot(self: *Object, rt: *Runtime) !*?Value {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.promise_reaction_on_fulfilled;
    }

    pub fn promiseReactionOnFulfilled(self: *const Object) ?Value {
        if (self.ordinaryPayloadConst()) |payload| return payload.promise_reaction_on_fulfilled;
        return null;
    }

    pub fn promiseReactionOnRejectedSlot(self: *Object, rt: *Runtime) !*?Value {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.promise_reaction_on_rejected;
    }

    pub fn promiseReactionOnRejected(self: *const Object) ?Value {
        if (self.ordinaryPayloadConst()) |payload| return payload.promise_reaction_on_rejected;
        return null;
    }

    pub fn promiseReactionResolveSlot(self: *Object, rt: *Runtime) !*?Value {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.promise_reaction_resolve;
    }

    pub fn promiseReactionResolve(self: *const Object) ?Value {
        if (self.ordinaryPayloadConst()) |payload| return payload.promise_reaction_resolve;
        return null;
    }

    pub fn promiseReactionRejectSlot(self: *Object, rt: *Runtime) !*?Value {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.promise_reaction_reject;
    }

    pub fn promiseReactionReject(self: *const Object) ?Value {
        if (self.ordinaryPayloadConst()) |payload| return payload.promise_reaction_reject;
        return null;
    }

    pub fn promiseAlreadyResolvedSlot(self: *Object, rt: *Runtime) !*bool {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.promise_already_resolved;
    }

    pub fn promiseAlreadyResolved(self: *const Object) bool {
        if (self.ordinaryPayloadConst()) |payload| return payload.promise_already_resolved;
        return false;
    }

    pub fn promiseCapabilityResolveSlot(self: *Object, rt: *Runtime) !*?Value {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.promise_capability_resolve;
    }

    pub fn promiseCapabilityResolve(self: *const Object) ?Value {
        if (self.ordinaryPayloadConst()) |payload| return payload.promise_capability_resolve;
        return null;
    }

    pub fn promiseCapabilityRejectSlot(self: *Object, rt: *Runtime) !*?Value {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.promise_capability_reject;
    }

    pub fn promiseCapabilityReject(self: *const Object) ?Value {
        if (self.ordinaryPayloadConst()) |payload| return payload.promise_capability_reject;
        return null;
    }

    pub fn promiseCombinatorResolveSlot(self: *Object, rt: *Runtime) !*?Value {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.promise_combinator_resolve;
    }

    pub fn promiseCombinatorResolve(self: *const Object) ?Value {
        if (self.ordinaryPayloadConst()) |payload| return payload.promise_combinator_resolve;
        return null;
    }

    pub fn promiseCombinatorRejectSlot(self: *Object, rt: *Runtime) !*?Value {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.promise_combinator_reject;
    }

    pub fn promiseCombinatorReject(self: *const Object) ?Value {
        if (self.ordinaryPayloadConst()) |payload| return payload.promise_combinator_reject;
        return null;
    }

    pub fn promiseCombinatorValuesSlot(self: *Object, rt: *Runtime) !*?Value {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.promise_combinator_values;
    }

    pub fn promiseCombinatorValues(self: *const Object) ?Value {
        if (self.ordinaryPayloadConst()) |payload| return payload.promise_combinator_values;
        return null;
    }

    pub fn promiseCombinatorKeysSlot(self: *Object, rt: *Runtime) !*?Value {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.promise_combinator_keys;
    }

    pub fn promiseCombinatorKeys(self: *const Object) ?Value {
        if (self.ordinaryPayloadConst()) |payload| return payload.promise_combinator_keys;
        return null;
    }

    pub fn typedArrayArrayBufferPrototypeSlot(self: *Object, rt: *Runtime) !*?Value {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.typed_array_array_buffer_prototype;
    }

    pub fn typedArrayArrayBufferPrototype(self: *const Object) ?Value {
        if (self.ordinaryPayloadConst()) |payload| return payload.typed_array_array_buffer_prototype;
        return null;
    }

    pub fn promiseCombinatorRemainingSlot(self: *Object, rt: *Runtime) !*i32 {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.promise_combinator_remaining;
    }

    pub fn promiseCombinatorRemaining(self: *const Object) i32 {
        if (self.ordinaryPayloadConst()) |payload| return payload.promise_combinator_remaining;
        return 0;
    }

    pub fn workerIdSlot(self: *Object, rt: *Runtime) !*?i32 {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.worker_id;
    }

    pub fn workerId(self: *const Object) ?i32 {
        if (self.ordinaryPayloadConst()) |payload| return payload.worker_id;
        return null;
    }

    pub fn functionRealmGlobalSlot(self: *Object) *?Value {
        if (self.functionPayload()) |payload| return &payload.realm_global;
        if (self.boundFunctionPayload()) |payload| return &payload.realm_global;
        std.debug.assert(self.class_payload_kind == .function or self.class_payload_kind == .bound_function);
        unreachable;
    }

    pub fn functionRealmGlobal(self: *const Object) ?Value {
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

    pub fn functionRealmGlobalPtrSlotEnsured(self: *Object, rt: *Runtime) !*?*Object {
        if (self.class_payload_kind == .none) {
            const payload = try self.ensureOrdinaryPayload(rt);
            return &payload.realm_global_ptr;
        }
        return self.functionRealmGlobalPtrSlot();
    }

    pub fn setFunctionRealmGlobalPtr(self: *Object, rt: *Runtime, realm_global: ?*Object) !void {
        const slot = try self.functionRealmGlobalPtrSlotEnsured(rt);
        if (realm_global != null) try rt.registerBorrowedReferenceHolder(self);
        slot.* = realm_global;
        if (realm_global == null) self.pruneBorrowedReferenceHolderIfEmpty(rt);
    }

    pub fn setFunctionRealmGlobalPtrIfNull(self: *Object, rt: *Runtime, realm_global: ?*Object) !void {
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
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn ordinaryPayloadConst(self: *const Object) ?*const OrdinaryPayload {
        if (self.class_payload_kind != .ordinary) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn destroyOrdinaryPayload(self: *Object, rt: *Runtime) void {
        const payload = self.ordinaryPayload() orelse return;
        self.class_payload = .none;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(OrdinaryPayload, payload);
    }

    fn iteratorPayload(self: *Object) ?*IteratorPayload {
        if (self.class_payload_kind != .iterator) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn iteratorPayloadConst(self: *const Object) ?*const IteratorPayload {
        if (self.class_payload_kind != .iterator) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn destroyIteratorPayload(self: *Object, rt: *Runtime) void {
        const payload = self.iteratorPayload() orelse return;
        self.class_payload = .none;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(IteratorPayload, payload);
    }

    fn collectionPayload(self: *Object) ?*CollectionPayload {
        if (self.class_payload_kind != .collection) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn collectionPayloadConst(self: *const Object) ?*const CollectionPayload {
        if (self.class_payload_kind != .collection) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn destroyCollectionPayload(self: *Object, rt: *Runtime) void {
        const payload = self.collectionPayload() orelse return;
        self.class_payload = .none;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(CollectionPayload, payload);
    }

    fn finalizationRegistryPayload(self: *Object) ?*FinalizationRegistryPayload {
        if (self.class_payload_kind != .finalization_registry) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn finalizationRegistryPayloadConst(self: *const Object) ?*const FinalizationRegistryPayload {
        if (self.class_payload_kind != .finalization_registry) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn destroyFinalizationRegistryPayload(self: *Object, rt: *Runtime) void {
        const payload = self.finalizationRegistryPayload() orelse return;
        self.class_payload = .none;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(FinalizationRegistryPayload, payload);
    }

    fn stdFilePayload(self: *Object) ?*StdFilePayload {
        if (self.class_payload_kind != .std_file) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn stdFilePayloadConst(self: *const Object) ?*const StdFilePayload {
        if (self.class_payload_kind != .std_file) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn destroyStdFilePayload(self: *Object, rt: *Runtime) void {
        const payload = self.stdFilePayload() orelse return;
        self.class_payload = .none;
        self.class_payload_kind = .none;
        payload.destroy();
        rt.memory.destroy(StdFilePayload, payload);
    }

    fn disposableStackPayload(self: *Object) ?*DisposableStackPayload {
        if (self.class_payload_kind != .disposable_stack) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn disposableStackPayloadConst(self: *const Object) ?*const DisposableStackPayload {
        if (self.class_payload_kind != .disposable_stack) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn destroyDisposableStackPayload(self: *Object, rt: *Runtime) void {
        const payload = self.disposableStackPayload() orelse return;
        self.class_payload = .none;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(DisposableStackPayload, payload);
    }

    fn realmPayload(self: *Object) ?*RealmPayload {
        if (self.class_payload_kind != .realm) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn realmPayloadConst(self: *const Object) ?*const RealmPayload {
        if (self.class_payload_kind != .realm) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn destroyRealmPayload(self: *Object, rt: *Runtime) void {
        const payload = self.realmPayload() orelse return;
        self.class_payload = .none;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(RealmPayload, payload);
    }

    fn bufferPayload(self: *Object) ?*BufferPayload {
        if (self.class_payload_kind != .buffer) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn bufferPayloadConst(self: *const Object) ?*const BufferPayload {
        if (self.class_payload_kind != .buffer) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn destroyBufferPayload(self: *Object, rt: *Runtime) void {
        const payload = self.bufferPayload() orelse return;
        self.class_payload = .none;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(BufferPayload, payload);
    }

    fn typedArrayPayload(self: *Object) ?*TypedArrayPayload {
        if (self.class_payload_kind != .typed_array) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn typedArrayPayloadConst(self: *const Object) ?*const TypedArrayPayload {
        if (self.class_payload_kind != .typed_array) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn destroyTypedArrayPayload(self: *Object, rt: *Runtime) void {
        const payload = self.typedArrayPayload() orelse return;
        self.class_payload = .none;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(TypedArrayPayload, payload);
    }

    fn regExpPayload(self: *Object) ?*RegExpPayload {
        if (self.class_payload_kind != .regexp) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn regExpPayloadConst(self: *const Object) ?*const RegExpPayload {
        if (self.class_payload_kind != .regexp) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn destroyRegExpPayload(self: *Object, rt: *Runtime) void {
        const payload = self.regExpPayload() orelse return;
        self.class_payload = .none;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(RegExpPayload, payload);
    }

    fn boundFunctionPayload(self: *Object) ?*BoundFunctionPayload {
        if (self.class_payload_kind != .bound_function) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn boundFunctionPayloadConst(self: *const Object) ?*const BoundFunctionPayload {
        if (self.class_payload_kind != .bound_function) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn destroyBoundFunctionPayload(self: *Object, rt: *Runtime) void {
        const payload = self.boundFunctionPayload() orelse return;
        self.class_payload = .none;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(BoundFunctionPayload, payload);
    }

    fn proxyPayload(self: *Object) ?*ProxyPayload {
        if (self.class_payload_kind != .proxy) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn proxyPayloadConst(self: *const Object) ?*const ProxyPayload {
        if (self.class_payload_kind != .proxy) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn destroyProxyPayload(self: *Object, rt: *Runtime) void {
        const payload = self.proxyPayload() orelse return;
        self.class_payload = .none;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(ProxyPayload, payload);
    }

    fn argumentsPayload(self: *Object) ?*ArgumentsPayload {
        if (self.class_payload_kind != .arguments) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn argumentsPayloadConst(self: *const Object) ?*const ArgumentsPayload {
        if (self.class_payload_kind != .arguments) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn destroyArgumentsPayload(self: *Object, rt: *Runtime) void {
        const payload = self.argumentsPayload() orelse return;
        self.class_payload = .none;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(ArgumentsPayload, payload);
    }

    fn objectDataPayload(self: *Object) ?*ObjectDataPayload {
        if (self.class_payload_kind != .object_data) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn objectDataPayloadConst(self: *const Object) ?*const ObjectDataPayload {
        if (self.class_payload_kind != .object_data) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn destroyObjectDataPayload(self: *Object, rt: *Runtime) void {
        const payload = self.objectDataPayload() orelse return;
        self.class_payload = .none;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(ObjectDataPayload, payload);
    }

    fn varRefPayload(self: *Object) ?*VarRefPayload {
        if (self.class_payload_kind != .var_ref) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn varRefPayloadConst(self: *const Object) ?*const VarRefPayload {
        if (self.class_payload_kind != .var_ref) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn destroyVarRefPayload(self: *Object, rt: *Runtime) void {
        const payload = self.varRefPayload() orelse return;
        self.class_payload = .none;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(VarRefPayload, payload);
    }

    fn arrayPayload(self: *Object) ?*ArrayPayload {
        if (self.class_payload_kind != .array) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn arrayPayloadConst(self: *const Object) ?*const ArrayPayload {
        if (self.class_payload_kind != .array) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn destroyArrayPayload(self: *Object, rt: *Runtime) void {
        const payload = self.arrayPayload() orelse return;
        self.class_payload = .none;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(ArrayPayload, payload);
    }

    fn promisePayload(self: *Object) ?*PromisePayload {
        if (self.class_payload_kind != .promise) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn promisePayloadConst(self: *const Object) ?*const PromisePayload {
        if (self.class_payload_kind != .promise) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn destroyPromisePayload(self: *Object, rt: *Runtime) void {
        const payload = self.promisePayload() orelse return;
        self.class_payload = .none;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(PromisePayload, payload);
    }

    fn generatorPayload(self: *Object) ?*GeneratorPayload {
        if (self.class_payload_kind != .generator) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn generatorPayloadConst(self: *const Object) ?*const GeneratorPayload {
        if (self.class_payload_kind != .generator) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn destroyGeneratorPayload(self: *Object, rt: *Runtime) void {
        const payload = self.generatorPayload() orelse return;
        self.class_payload = .none;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(GeneratorPayload, payload);
    }

    fn functionPayload(self: *Object) ?*FunctionPayload {
        if (self.class_payload_kind != .function) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn functionPayloadConst(self: *const Object) ?*const FunctionPayload {
        if (self.class_payload_kind != .function) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn destroyFunctionPayload(self: *Object, rt: *Runtime) void {
        const payload = self.functionPayload() orelse return;
        self.class_payload = .none;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(FunctionPayload, payload);
    }

    pub fn moduleNamespacePayload(self: *Object) ?*ModuleNamespacePayload {
        if (self.class_payload_kind != .module_namespace) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn moduleNamespacePayloadConst(self: *const Object) ?*const ModuleNamespacePayload {
        if (self.class_payload_kind != .module_namespace) return null;
        return switch (self.class_payload) {
            .external => |ptr| @ptrCast(@alignCast(ptr)),
            else => null,
        };
    }

    fn moduleNamespaceBindingValue(self: Object, atom_id: atom.Atom) ?Value {
        if (self.class_id != class.ids.module_ns) return null;
        const payload = @constCast(&self).moduleNamespacePayload() orelse return null;
        for (payload.names, 0..) |name, idx| {
            if (name != atom_id or idx >= payload.cells.len) continue;
            const cell = varRefCellFromValue(payload.cells[idx]) orelse return Value.undefinedValue();
            return if (cell.varRefValueSlot().*) |stored| stored.dup() else Value.undefinedValue();
        }
        return null;
    }

    pub fn moduleNamespaceOwnBindingValue(self: Object, atom_id: atom.Atom) ?Value {
        return self.moduleNamespaceBindingValue(atom_id);
    }

    fn destroyModuleNamespacePayload(self: *Object, rt: *Runtime) void {
        const payload = self.moduleNamespacePayload() orelse return;
        self.class_payload = .none;
        self.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(ModuleNamespacePayload, payload);
    }

    fn destroyIfOnlyClosedReachableGraph(rt: *Runtime, header: *gc.Header) bool {
        const self: *Object = @fieldParentPtr("header", header);
        var visited = ObjectVisitSet.init(rt.memory.allocator);
        defer visited.deinit();
        collectReachableObjects(rt, &visited, self) catch return false;
        if (visited.count() <= 1) return false;

        var incoming = ObjectIncomingMap.init(rt.memory.allocator);
        defer incoming.deinit();
        var internal_bytecodes = ObjectVisitSet.init(rt.memory.allocator);
        defer internal_bytecodes.deinit();
        collectInternalFunctionBytecodes(rt, &visited, &internal_bytecodes) catch return false;
        var processed_bytecodes = ObjectVisitSet.init(rt.memory.allocator);
        defer processed_bytecodes.deinit();

        var iterator = visited.keyIterator();
        while (iterator.next()) |address| {
            incoming.put(address.*, 0) catch return false;
        }

        iterator = visited.keyIterator();
        while (iterator.next()) |address| {
            const current: *Object = @ptrFromInt(address.*);
            current.accumulateIncomingReferences(rt, &visited, &incoming, &internal_bytecodes, &processed_bytecodes) catch return false;
        }

        var preserved = ObjectVisitSet.init(rt.memory.allocator);
        defer preserved.deinit();
        var symbol_roots = SymbolRootSet.init(rt.memory.allocator);
        defer symbol_roots.deinit();
        seedSymbolRootsFromRuntimeHeldValues(rt, &symbol_roots) catch return false;
        seedSymbolRootsFromValueRoots(rt, rt.active_value_roots, &symbol_roots) catch return false;
        seedSymbolRootsFromPendingFinalizationJobs(rt, &symbol_roots) catch return false;

        iterator = visited.keyIterator();
        while (iterator.next()) |address| {
            const current: *Object = @ptrFromInt(address.*);
            const internal_refs = incoming.get(address.*) orelse return false;
            if (internal_refs > current.header.rc) return false;
            const external_refs = current.header.rc - internal_refs;
            if (external_refs != 0) scanPreservedObjects(rt, &visited, &preserved, &symbol_roots, current) catch return false;
        }
        scanPreservedWeakAndFinalizationEdges(rt, &visited, &preserved, &symbol_roots) catch return false;

        if (preserved.contains(@intFromPtr(self))) return false;

        var free_set = ObjectVisitSet.init(rt.memory.allocator);
        defer free_set.deinit();
        iterator = visited.keyIterator();
        while (iterator.next()) |address| {
            if (!preserved.contains(address.*)) free_set.put(address.*, {}) catch return false;
        }
        var free_internal_bytecodes = ObjectVisitSet.init(rt.memory.allocator);
        defer free_internal_bytecodes.deinit();
        collectInternalFunctionBytecodes(rt, &free_set, &free_internal_bytecodes) catch return false;
        retainFunctionBytecodeGuards(&free_internal_bytecodes);
        defer releaseFunctionBytecodeGuards(rt, &free_internal_bytecodes);
        sweepDeadWeakEntries(rt, &visited, &preserved, &symbol_roots, &free_set, &free_internal_bytecodes);
        if (free_set.count() == 0) return false;

        iterator = free_set.keyIterator();
        while (iterator.next()) |address| {
            const current: *Object = @ptrFromInt(address.*);
            current.clearReferencesToVisited(rt, &free_set, &free_internal_bytecodes) catch return false;
        }

        iterator = free_set.keyIterator();
        while (iterator.next()) |address| {
            const current: *Object = @ptrFromInt(address.*);
            current.header.rc = 0;
        }

        iterator = free_set.keyIterator();
        while (iterator.next()) |address| {
            const current: *Object = @ptrFromInt(address.*);
            destroyFromHeader(rt, &current.header);
        }
        return true;
    }

    pub fn destroyRuntimeCycles(rt: *Runtime) usize {
        return destroyRuntimeCyclesWithValueRoots(rt, null) catch 0;
    }

    fn traceChildren(rt: *Runtime, header: *gc.Header, visitor: anytype) void {
        switch (header.kind) {
            .object => {
                const obj: *Object = @alignCast(@fieldParentPtr("header", header));
                obj.traceChildEdges(rt, visitor) catch {};
            },
            .function_bytecode => {
                const fb: *bytecode_function.FunctionBytecode = @alignCast(@fieldParentPtr("header", header));
                if (fb.class_fields_init) |*stored| visitor.visitValue(stored);
                for (fb.cpool) |*stored| visitor.visitValue(stored);
            },
            else => {},
        }
    }

    const DecrefVisitor = struct {
        rt: *Runtime,

        pub fn visitValue(self: DecrefVisitor, val: *Value) void {
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
        rt: *Runtime,

        pub fn visitValue(self: ScanIncrefVisitor, val: *Value) void {
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
        rt: *Runtime,

        pub fn visitValue(self: ScanRestoreVisitor, val: *Value) void {
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

    pub fn destroyRuntimeCyclesWithValueRoots(rt: *Runtime, roots: ?*const runtime_mod.ValueRootFrame) ObjectGraphError!usize {
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

        var visited = ObjectVisitSet.init(rt.memory.allocator);
        defer visited.deinit();
        var preserved = ObjectVisitSet.init(rt.memory.allocator);
        defer preserved.deinit();
        var free_set = ObjectVisitSet.init(rt.memory.allocator);
        defer free_set.deinit();

        // Populate visited and preserved from live list
        {
            var current = rt.gc.gc_obj_list_head;
            while (current) |node| : (current = node.next) {
                const h = gc.headerFromGcNode(node);
                if (h.kind == .object) {
                    const obj: *Object = @alignCast(@fieldParentPtr("header", h));
                    try visited.put(@intFromPtr(obj), {});
                    try preserved.put(@intFromPtr(obj), {});
                }
            }
        }
        // Populate visited and free_set from garbage list
        {
            var current = tmp_head;
            while (current) |node| : (current = node.next) {
                const h = gc.headerFromGcNode(node);
                if (h.kind == .object) {
                    const obj: *Object = @alignCast(@fieldParentPtr("header", h));
                    try visited.put(@intFromPtr(obj), {});
                    try free_set.put(@intFromPtr(obj), {});
                }
            }
        }

        var symbol_roots = SymbolRootSet.init(rt.memory.allocator);
        defer symbol_roots.deinit();
        try seedSymbolRootsFromRuntimeHeldValues(rt, &symbol_roots);
        try seedSymbolRootsFromValueRoots(rt, roots, &symbol_roots);
        try seedSymbolRootsFromPendingFinalizationJobs(rt, &symbol_roots);

        try scanPreservedWeakAndFinalizationEdges(rt, &visited, &preserved, &symbol_roots);

        const ResurrectHelper = struct {
            pub fn scanAndPreserveValue(
                runtime: *Runtime,
                visited_set: *const ObjectVisitSet,
                preserved_set: *ObjectVisitSet,
                preserved_bytecodes: *ObjectVisitSet,
                symbol_roots_set: *SymbolRootSet,
                object_worklist: *std.ArrayList(*Object),
                bytecode_worklist: *std.ArrayList(*bytecode_function.FunctionBytecode),
                val: Value,
            ) ObjectGraphError!void {
                try preserveSymbolValue(runtime, symbol_roots_set, val);
                if (objectFromValue(val)) |obj| {
                    const addr = @intFromPtr(obj);
                    if (visited_set.contains(addr)) {
                        const entry = try preserved_set.getOrPut(addr);
                        if (!entry.found_existing) {
                            try object_worklist.append(runtime.memory.allocator, obj);
                        }
                    }
                } else if (functionBytecodeFromValue(val)) |const_fb| {
                    const fb = @constCast(const_fb);
                    const addr = @intFromPtr(fb);
                    const entry = try preserved_bytecodes.getOrPut(addr);
                    if (!entry.found_existing) {
                        try bytecode_worklist.append(runtime.memory.allocator, fb);
                    }
                }
            }

            pub fn scanBytecodeChildObjectsAndBytecodes(
                runtime: *Runtime,
                visited_set: *const ObjectVisitSet,
                preserved_set: *ObjectVisitSet,
                preserved_bytecodes: *ObjectVisitSet,
                symbol_roots_set: *SymbolRootSet,
                object_worklist: *std.ArrayList(*Object),
                bytecode_worklist: *std.ArrayList(*bytecode_function.FunctionBytecode),
                fb: *bytecode_function.FunctionBytecode,
            ) ObjectGraphError!void {
                if (fb.class_fields_init) |val| {
                    try scanAndPreserveValue(runtime, visited_set, preserved_set, preserved_bytecodes, symbol_roots_set, object_worklist, bytecode_worklist, val);
                }
                for (fb.cpool) |val| {
                    try scanAndPreserveValue(runtime, visited_set, preserved_set, preserved_bytecodes, symbol_roots_set, object_worklist, bytecode_worklist, val);
                }
            }
        };

        const ObjectResurrectVisitor = struct {
            rt: *Runtime,
            visited_set: *const ObjectVisitSet,
            preserved_set: *ObjectVisitSet,
            preserved_bytecodes: *ObjectVisitSet,
            symbol_roots_set: *SymbolRootSet,
            object_worklist: *std.ArrayList(*Object),
            bytecode_worklist: *std.ArrayList(*bytecode_function.FunctionBytecode),
            err: ?ObjectGraphError = null,

            pub fn visitObject(self: *@This(), obj_ptr: *?*Object) ObjectGraphError!void {
                if (obj_ptr.*) |obj| {
                    if (@intFromPtr(obj) == 0) return;
                    const addr = @intFromPtr(obj);
                    if (self.visited_set.contains(addr)) {
                        const entry = try self.preserved_set.getOrPut(addr);
                        if (!entry.found_existing) {
                            try self.object_worklist.append(self.rt.memory.allocator, obj);
                        }
                    }
                }
            }

            pub fn visitValue(self: *@This(), val_ptr: *Value) ObjectGraphError!void {
                try ResurrectHelper.scanAndPreserveValue(
                    self.rt,
                    self.visited_set,
                    self.preserved_set,
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

        var preserved_bytecodes = ObjectVisitSet.init(rt.memory.allocator);
        defer preserved_bytecodes.deinit();

        var object_worklist = std.ArrayList(*Object).empty;
        defer object_worklist.deinit(rt.memory.allocator);

        var bytecode_worklist = std.ArrayList(*bytecode_function.FunctionBytecode).empty;
        defer bytecode_worklist.deinit(rt.memory.allocator);

        // Initialize object worklist with all objects currently in preserved
        {
            var iterator = preserved.keyIterator();
            while (iterator.next()) |address| {
                const obj: *Object = @ptrFromInt(address.*);
                try object_worklist.append(rt.memory.allocator, obj);
            }
        }

        // Fixed-point transitive resurrection loop
        while (object_worklist.items.len > 0 or bytecode_worklist.items.len > 0) {
            while (object_worklist.items.len > 0) {
                const obj = object_worklist.pop().?;
                var visitor = ObjectResurrectVisitor{
                    .rt = rt,
                    .visited_set = &visited,
                    .preserved_set = &preserved,
                    .preserved_bytecodes = &preserved_bytecodes,
                    .symbol_roots_set = &symbol_roots,
                    .object_worklist = &object_worklist,
                    .bytecode_worklist = &bytecode_worklist,
                };
                try obj.traceChildEdges(rt, &visitor);
            }

            while (bytecode_worklist.items.len > 0) {
                const fb = bytecode_worklist.pop().?;
                try ResurrectHelper.scanBytecodeChildObjectsAndBytecodes(
                    rt,
                    &visited,
                    &preserved,
                    &preserved_bytecodes,
                    &symbol_roots,
                    &object_worklist,
                    &bytecode_worklist,
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
                    const obj: *Object = @alignCast(@fieldParentPtr("header", h));
                    if (preserved.contains(@intFromPtr(obj))) {
                        unlinkNodeFromList(&tmp_head, &tmp_tail, node);
                        linkNodeToList(&rt.gc.gc_obj_list_head, &rt.gc.gc_obj_list_tail, node);
                        h.flags.mark = false;
                    }
                } else if (h.kind == .function_bytecode) {
                    const fb: *bytecode_function.FunctionBytecode = @alignCast(@fieldParentPtr("header", h));
                    if (preserved_bytecodes.contains(@intFromPtr(fb))) {
                        unlinkNodeFromList(&tmp_head, &tmp_tail, node);
                        linkNodeToList(&rt.gc.gc_obj_list_head, &rt.gc.gc_obj_list_tail, node);
                        h.flags.mark = false;
                    }
                }
                current = next;
            }
        }

        // Re-sync free_set
        free_set.clearRetainingCapacity();
        {
            var current = tmp_head;
            while (current) |node| : (current = node.next) {
                const h = gc.headerFromGcNode(node);
                if (h.kind == .object) {
                    const obj: *Object = @alignCast(@fieldParentPtr("header", h));
                    try free_set.put(@intFromPtr(obj), {});
                }
            }
        }

        var free_internal_bytecodes = ObjectVisitSet.init(rt.memory.allocator);
        defer free_internal_bytecodes.deinit();
        {
            var current = tmp_head;
            while (current) |node| : (current = node.next) {
                const h = gc.headerFromGcNode(node);
                if (h.kind == .function_bytecode) {
                    const fb: *bytecode_function.FunctionBytecode = @alignCast(@fieldParentPtr("header", h));
                    try free_internal_bytecodes.put(@intFromPtr(fb), {});
                }
            }
        }

        // Temporarily increment ref counts of all preserved objects and bytecodes
        // to prevent them from being destroyed/freed during weak entries sweeping.
        {
            var iterator = preserved.keyIterator();
            while (iterator.next()) |address| {
                const current: *Object = @ptrFromInt(address.*);
                current.header.rc += 1;
            }
        }
        {
            var iterator = preserved_bytecodes.keyIterator();
            while (iterator.next()) |address| {
                const fb: *bytecode_function.FunctionBytecode = @ptrFromInt(address.*);
                fb.header.rc += 1;
            }
        }

        sweepDeadWeakEntries(rt, &visited, &preserved, &symbol_roots, &free_set, &free_internal_bytecodes);
        _ = rt.atoms.sweepUnrootedUniqueSymbols(&symbol_roots);

        // Decrement protected ref counts back to normal and release any that reached 0.
        {
            var iterator = preserved.keyIterator();
            while (iterator.next()) |address| {
                const current: *Object = @ptrFromInt(address.*);
                current.header.rc -= 1;
                if (current.header.rc == 0) {
                    current.header.rc = 1;
                    gc.release(rt, &current.header);
                }
            }
        }
        {
            var iterator = preserved_bytecodes.keyIterator();
            while (iterator.next()) |address| {
                const fb: *bytecode_function.FunctionBytecode = @ptrFromInt(address.*);
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
                    const fb: *bytecode_function.FunctionBytecode = @alignCast(@fieldParentPtr("header", h));
                    clearFunctionBytecodeReferencesToVisited(rt, fb, &free_set, &free_internal_bytecodes);
                }
            }

            current = tmp_head;
            while (current) |node| {
                const next = node.next;
                const h = gc.headerFromGcNode(node);
                if (h.kind == .function_bytecode) {
                    unlinkNodeFromList(&tmp_head, &tmp_tail, node);
                    bytecode_function.destroyFromHeader(rt, h);
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
                try obj.clearReferencesToVisited(rt, &free_set, &free_internal_bytecodes);
            } else if (h.kind == .function_bytecode) {
                const fb: *bytecode_function.FunctionBytecode = @alignCast(@fieldParentPtr("header", h));
                clearFunctionBytecodeReferencesToVisited(rt, fb, &free_set, &free_internal_bytecodes);
            }
        }

        const freed = garbage_count;
        rt.gc.stats.freed_objects += freed;

        current_garbage = tmp_head;
        while (current_garbage) |node| {
            const next = node.next;
            const h = gc.headerFromGcNode(node);
            unlinkNodeFromList(&tmp_head, &tmp_tail, node);
            if (h.kind == .object) {
                destroyFromHeader(rt, h);
            } else if (h.kind == .function_bytecode) {
                bytecode_function.destroyFromHeader(rt, h);
            }
            current_garbage = next;
        }

        return freed;
    }

    pub fn releaseCallbackOwnedFunctionBytecodeCycles(rt: *Runtime) void {
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
            const function_bytecode: *bytecode_function.FunctionBytecode = @ptrFromInt(address.*);
            clearCallbackOwnedFunctionBytecodeCycleRefs(rt, function_bytecode, &candidates);
        }
    }

    fn pruneCallbackOwnedFunctionBytecodeCycles(candidates: *ObjectVisitSet) ObjectGraphError!void {
        while (true) {
            var removed = false;
            var iterator = candidates.keyIterator();
            while (iterator.next()) |address| {
                const function_bytecode: *const bytecode_function.FunctionBytecode = @ptrFromInt(address.*);
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
            const function_bytecode: *bytecode_function.FunctionBytecode = @ptrFromInt(address.*);
            function_bytecode.header.retain();
        }
    }

    fn releaseFunctionBytecodeGuards(rt: *Runtime, candidates: *const ObjectVisitSet) void {
        var current = rt.gc.gc_obj_list_tail;
        while (current) |node| {
            const prev = node.prev;
            const h = gc.headerFromGcNode(node);
            const fb_ptr = if (h.kind == .function_bytecode) @as(*bytecode_function.FunctionBytecode, @alignCast(@fieldParentPtr("header", h))) else null;
            if (fb_ptr) |fb| {
                if (candidates.contains(@intFromPtr(fb))) {
                    gc.release(rt, h);
                }
            }
            current = prev;
        }
    }

    fn clearCallbackOwnedFunctionBytecodeCycleRefs(
        rt: *Runtime,
        function_bytecode: *bytecode_function.FunctionBytecode,
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
            stored.* = Value.undefinedValue();
            old_value.free(rt);
        }
    }

    fn valueReferencesFunctionBytecodeCandidate(stored: Value, candidates: *const ObjectVisitSet) bool {
        const function_bytecode = functionBytecodeFromValue(stored) orelse return false;
        return candidates.contains(@intFromPtr(function_bytecode));
    }

    fn objectFromValue(stored: Value) ?*Object {
        const stored_header = stored.refHeader() orelse return null;
        if (stored_header.kind != .object) return null;
        return @fieldParentPtr("header", stored_header);
    }

    const PayloadCollectContext = struct {
        rt: *Runtime,
        visited: *ObjectVisitSet,
    };

    const PayloadPreserveContext = struct {
        rt: *Runtime,
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
        rt: *Runtime,
        visited: *const ObjectVisitSet,
        internal_bytecodes: *const ObjectVisitSet,
    };

    const PayloadBytecodeRefCountContext = struct {
        function_bytecode: *const bytecode_function.FunctionBytecode,
        count: usize = 0,
    };

    fn markClassPayload(self: *Object, rt: *Runtime, visitor: *class.PayloadVisitor) bool {
        if (self.class_payload == .none) return false;
        return rt.classes.markPayload(self.class_id, @ptrCast(rt), @ptrCast(self), &self.class_payload, visitor);
    }

    fn countPayloadFunctionBytecodeRef(context_ptr: *anyopaque, value_ptr: *anyopaque) void {
        const context: *PayloadBytecodeRefCountContext = @ptrCast(@alignCast(context_ptr));
        const stored: *Value = @ptrCast(@alignCast(value_ptr));
        context.count += countFunctionBytecodeValueRef(stored.*, context.function_bytecode);
    }

    fn collectReachableObjects(rt: *Runtime, visited: *ObjectVisitSet, current: *Object) ObjectGraphError!void {
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
                const stored: *Value = @ptrCast(@alignCast(value_ptr));
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

    pub inline fn traceChildEdges(self: *Object, rt: *Runtime, visitor: anytype) !void {
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
        try Helper.callVisitObject(visitor, &self.global_lexical_env);
        try Helper.traceOptValue(visitor, &self.cached_iterator_next);
        if (self.shared_lazy_native_functions) |cache| {
            for (cache) |*maybe_cached| {
                try Helper.traceOptValue(visitor, maybe_cached);
            }
        }
        for (self.properties) |*entry| {
            try Helper.callVisitSymbol(visitor, &entry.atom_id);
            switch (entry.slot) {
                .data => |*stored| try Helper.callVisitValue(visitor, stored),
                .accessor => |*acc| {
                    try Helper.callVisitValue(visitor, &acc.getter);
                    try Helper.callVisitValue(visitor, &acc.setter);
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

    fn collectDirectChildObjects(self: *Object, rt: *Runtime, visited: *ObjectVisitSet) ObjectGraphError!void {
        const CollectVisitor = struct {
            rt: *Runtime,
            visited: *ObjectVisitSet,
            err: ?ObjectGraphError = null,

            pub fn visitObject(cv: *@This(), obj_ptr: *?*Object) !void {
                if (obj_ptr.*) |obj| {
                    if (@intFromPtr(obj) == 0) return;
                    try collectReachableObjects(cv.rt, cv.visited, obj);
                }
            }

            pub fn visitValue(cv: *@This(), val_ptr: *Value) !void {
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
                if (entry.active) {
                    try collectValueObject(cv.rt, cv.visited, entry.held_value);
                    try collectValueObject(cv.rt, cv.visited, entry.unregister_token);
                }
            }
        };
        var visitor = CollectVisitor{ .rt = rt, .visited = visited };
        try self.traceChildEdges(rt, &visitor);
    }

    fn collectValueObject(rt: *Runtime, visited: *ObjectVisitSet, stored: Value) ObjectGraphError!void {
        if (objectFromValue(stored)) |child| {
            try collectReachableObjects(rt, visited, child);
            return;
        }
        const function_bytecode = functionBytecodeFromValue(stored) orelse return;
        try collectFunctionBytecodeChildObjects(rt, visited, function_bytecode);
    }

    fn collectFunctionBytecodeChildObjects(rt: *Runtime, visited: *ObjectVisitSet, function_bytecode: *const bytecode_function.FunctionBytecode) ObjectGraphError!void {
        if (function_bytecode.class_fields_init) |stored| try collectValueObject(rt, visited, stored);
        for (function_bytecode.cpool) |stored| try collectValueObject(rt, visited, stored);
    }

    fn seedSymbolRootsFromValueRoots(
        rt: *Runtime,
        roots: ?*const runtime_mod.ValueRootFrame,
        symbol_roots: *SymbolRootSet,
    ) ObjectGraphError!void {
        var function_bytecodes = ObjectVisitSet.init(rt.memory.allocator);
        defer function_bytecodes.deinit();

        try scanSymbolRootFrame(rt, symbol_roots, &function_bytecodes, roots);
    }

    fn seedSymbolRootsFromRuntimeHeldValues(rt: *Runtime, symbol_roots: *SymbolRootSet) ObjectGraphError!void {
        var function_bytecodes = ObjectVisitSet.init(rt.memory.allocator);
        defer function_bytecodes.deinit();

        try scanSymbolRootValue(rt, symbol_roots, &function_bytecodes, rt.current_exception);
        for (rt.internal_destructuring_helpers) |maybe_helper| {
            if (maybe_helper) |stored| try scanSymbolRootValue(rt, symbol_roots, &function_bytecodes, stored);
        }
        for (rt.external_symbol_roots) |atom_id| try preserveSymbolAtom(rt, symbol_roots, atom_id);
        for (rt.external_value_roots) |stored| try scanSymbolRootValue(rt, symbol_roots, &function_bytecodes, stored);
        for (rt.context_value_roots) |roots| {
            try scanSymbolRootFrame(rt, symbol_roots, &function_bytecodes, roots);
        }
        try scanSymbolRootModuleRegistry(rt, symbol_roots, &function_bytecodes);
    }

    fn scanSymbolRootModuleRegistry(
        rt: *Runtime,
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

    fn scanSymbolRootFrame(
        rt: *Runtime,
        symbol_roots: *SymbolRootSet,
        function_bytecodes: *ObjectVisitSet,
        roots: ?*const runtime_mod.ValueRootFrame,
    ) ObjectGraphError!void {
        var frame = roots;
        while (frame) |current| {
            for (current.values) |root| try scanSymbolRootValue(rt, symbol_roots, function_bytecodes, root.value.*);
            for (current.slices) |root| {
                const values: []const Value = switch (root) {
                    .mutable => |values| values.*,
                    .constant => |values| values.*,
                };
                for (values) |stored| try scanSymbolRootValue(rt, symbol_roots, function_bytecodes, stored);
            }
            frame = current.previous;
        }
    }

    fn seedSymbolRootsFromPendingFinalizationJobs(rt: *Runtime, symbol_roots: *SymbolRootSet) ObjectGraphError!void {
        var function_bytecodes = ObjectVisitSet.init(rt.memory.allocator);
        defer function_bytecodes.deinit();

        for (rt.pending_finalization_jobs) |job| {
            try scanSymbolRootValue(rt, symbol_roots, &function_bytecodes, job.callback);
            try scanSymbolRootValue(rt, symbol_roots, &function_bytecodes, job.held_value);
        }
    }

    fn preserveSymbolValue(rt: *Runtime, symbol_roots: *SymbolRootSet, stored: Value) ObjectGraphError!void {
        const atom_id = stored.asSymbolAtom() orelse return;
        try preserveSymbolAtom(rt, symbol_roots, atom_id);
    }

    fn scanSymbolRootValue(
        rt: *Runtime,
        symbol_roots: *SymbolRootSet,
        function_bytecodes: *ObjectVisitSet,
        stored: Value,
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
        rt: *Runtime,
        symbol_roots: *SymbolRootSet,
        visited: *ObjectVisitSet,
        self: *Object,
    ) ObjectGraphError!void {
        const address = @intFromPtr(self);
        const visit = try visited.getOrPut(address);
        if (visit.found_existing) return;

        const ScanSymbolRootVisitor = struct {
            rt: *Runtime,
            symbol_roots: *SymbolRootSet,
            visited: *ObjectVisitSet,
            err: ?ObjectGraphError = null,

            pub fn visitObject(sv: *@This(), obj_ptr: *?*Object) !void {
                if (obj_ptr.*) |obj| {
                    if (@intFromPtr(obj) == 0) return;
                    try scanSymbolRootObject(sv.rt, sv.symbol_roots, sv.visited, obj);
                }
            }

            pub fn visitValue(sv: *@This(), val_ptr: *Value) !void {
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
                if (entry.active) {
                    try scanSymbolRootValue(sv.rt, sv.symbol_roots, sv.visited, entry.held_value);
                    try scanSymbolRootValue(sv.rt, sv.symbol_roots, sv.visited, entry.unregister_token);
                }
            }
        };
        var visitor = ScanSymbolRootVisitor{ .rt = rt, .symbol_roots = symbol_roots, .visited = visited };
        try self.traceChildEdges(rt, &visitor);
    }

    fn scanSymbolRootFunctionBytecode(
        rt: *Runtime,
        symbol_roots: *SymbolRootSet,
        function_bytecodes: *ObjectVisitSet,
        function_bytecode: *const bytecode_function.FunctionBytecode,
    ) ObjectGraphError!void {
        const visit = try function_bytecodes.getOrPut(@intFromPtr(&function_bytecode.header));
        if (visit.found_existing) return;
        if (function_bytecode.class_fields_init) |stored| try scanSymbolRootValue(rt, symbol_roots, function_bytecodes, stored);
        for (function_bytecode.cpool) |stored| try scanSymbolRootValue(rt, symbol_roots, function_bytecodes, stored);
    }

    fn preserveSymbolAtom(rt: *Runtime, symbol_roots: *SymbolRootSet, atom_id: atom.Atom) ObjectGraphError!void {
        if (rt.atoms.kind(atom_id) != .symbol) return;
        try symbol_roots.put(atom_id, {});
    }

    fn scanPreservedObjects(
        rt: *Runtime,
        visited: *const ObjectVisitSet,
        preserved: *ObjectVisitSet,
        symbol_roots: *SymbolRootSet,
        current: *Object,
    ) ObjectGraphError!void {
        const address = @intFromPtr(current);
        if (!visited.contains(address)) return;
        const entry = try preserved.getOrPut(address);
        if (entry.found_existing) return;
        try current.scanPreservedChildObjects(rt, visited, preserved, symbol_roots);
    }

    fn scanPreservedChildObjects(
        self: *Object,
        rt: *Runtime,
        visited: *const ObjectVisitSet,
        preserved: *ObjectVisitSet,
        symbol_roots: *SymbolRootSet,
    ) ObjectGraphError!void {
        const ScanPreservedVisitor = struct {
            rt: *Runtime,
            visited: *const ObjectVisitSet,
            preserved: *ObjectVisitSet,
            symbol_roots: *SymbolRootSet,
            err: ?ObjectGraphError = null,

            pub fn visitObject(sv: *@This(), obj_ptr: *?*Object) !void {
                if (obj_ptr.*) |obj| {
                    if (@intFromPtr(obj) == 0) return;
                    try scanPreservedObjects(sv.rt, sv.visited, sv.preserved, sv.symbol_roots, obj);
                }
            }

            pub fn visitValue(sv: *@This(), val_ptr: *Value) !void {
                try scanPreservedValueObject(sv.rt, sv.visited, sv.preserved, sv.symbol_roots, val_ptr.*);
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
            .visited = visited,
            .preserved = preserved,
            .symbol_roots = symbol_roots,
        };
        try self.traceChildEdges(rt, &visitor);
    }

    fn scanPreservedValueObject(
        rt: *Runtime,
        visited: *const ObjectVisitSet,
        preserved: *ObjectVisitSet,
        symbol_roots: *SymbolRootSet,
        stored: Value,
    ) ObjectGraphError!void {
        try preserveSymbolValue(rt, symbol_roots, stored);
        if (objectFromValue(stored)) |child| {
            try scanPreservedObjects(rt, visited, preserved, symbol_roots, child);
            return;
        }
        const function_bytecode = functionBytecodeFromValue(stored) orelse return;
        try scanPreservedFunctionBytecodeChildObjects(rt, visited, preserved, symbol_roots, function_bytecode);
    }

    fn scanPreservedFunctionBytecodeChildObjects(
        rt: *Runtime,
        visited: *const ObjectVisitSet,
        preserved: *ObjectVisitSet,
        symbol_roots: *SymbolRootSet,
        function_bytecode: *const bytecode_function.FunctionBytecode,
    ) ObjectGraphError!void {
        if (function_bytecode.class_fields_init) |stored| try scanPreservedValueObject(rt, visited, preserved, symbol_roots, stored);
        for (function_bytecode.cpool) |stored| try scanPreservedValueObject(rt, visited, preserved, symbol_roots, stored);
    }

    fn scanPreservedWeakEdges(
        rt: *Runtime,
        visited: *const ObjectVisitSet,
        preserved: *ObjectVisitSet,
        symbol_roots: *SymbolRootSet,
    ) ObjectGraphError!void {
        var changed = true;
        while (changed) {
            changed = false;
            var iterator = visited.keyIterator();
            while (iterator.next()) |address| {
                if (!preserved.contains(address.*)) continue;
                const current: *Object = @ptrFromInt(address.*);
                for (current.weakCollectionEntries()) |entry| {
                    if (!weakEntryKeyIsPreserved(visited, preserved, symbol_roots, entry.key_identity)) continue;
                    const before = preserved.count();
                    const before_symbols = symbol_roots.count();
                    try scanPreservedValueObject(rt, visited, preserved, symbol_roots, entry.value);
                    if (preserved.count() != before or symbol_roots.count() != before_symbols) changed = true;
                }
                for (current.finalizationRegistryCells()) |entry| {
                    if (!entry.active) continue;
                    const target_identity = entry.target_identity orelse continue;
                    if (!weakEntryKeyIsPreserved(visited, preserved, symbol_roots, target_identity)) continue;
                    const before = preserved.count();
                    const before_symbols = symbol_roots.count();
                    try scanPreservedValueObject(rt, visited, preserved, symbol_roots, entry.held_value);
                    try scanPreservedValueObject(rt, visited, preserved, symbol_roots, entry.unregister_token);
                    if (preserved.count() != before or symbol_roots.count() != before_symbols) changed = true;
                }
            }
        }
    }

    fn scanPreservedWeakAndFinalizationEdges(
        rt: *Runtime,
        visited: *const ObjectVisitSet,
        preserved: *ObjectVisitSet,
        symbol_roots: *SymbolRootSet,
    ) ObjectGraphError!void {
        while (true) {
            const before_objects = preserved.count();
            const before_symbols = symbol_roots.count();
            try scanPreservedWeakEdges(rt, visited, preserved, symbol_roots);
            try queueFinalizationCleanupJobs(rt, visited, preserved, symbol_roots);
            if (preserved.count() == before_objects and symbol_roots.count() == before_symbols) return;
        }
    }

    fn queueFinalizationCleanupJobs(
        rt: *Runtime,
        visited: *const ObjectVisitSet,
        preserved: *ObjectVisitSet,
        symbol_roots: *SymbolRootSet,
    ) ObjectGraphError!void {
        var current_node = rt.gc.gc_obj_list_head;
        while (current_node) |node| {
            const next = node.next;
            const header = gc.headerFromGcNode(node);
            if (header.kind == .object) {
                const current: *Object = @alignCast(@fieldParentPtr("header", header));
                if (preserved.contains(@intFromPtr(current))) {
                    const finalization_payload = current.finalizationRegistryPayload() orelse {
                        current.pruneBorrowedReferenceHolderIfEmpty(rt);
                        current_node = next;
                        continue;
                    };
                    var cell_index: usize = 0;
                    while (cell_index < finalization_payload.cells.len) : (cell_index += 1) {
                        const cell = &finalization_payload.cells[cell_index];
                        if (!cell.active) continue;
                        const target_identity = cell.target_identity orelse continue;
                        if (weakEntryKeyIsPreserved(visited, preserved, symbol_roots, target_identity)) continue;

                        try scanPreservedValueObject(rt, visited, preserved, symbol_roots, cell.held_value);
                        try scanPreservedValueObject(rt, visited, preserved, symbol_roots, cell.unregister_token);
                        if (weakEntryKeyIsPreserved(visited, preserved, symbol_roots, target_identity)) continue;
                        enqueueFinalizationCleanup(rt, finalization_payload.cleanup_callback, cell.held_value);
                        cell.active = false;
                    }
                }
            }
            current_node = next;
        }
    }

    fn sweepDeadWeakEntries(
        rt: *Runtime,
        visited: *const ObjectVisitSet,
        preserved: *const ObjectVisitSet,
        symbol_roots: *const SymbolRootSet,
        free_set: *const ObjectVisitSet,
        internal_bytecodes: *const ObjectVisitSet,
    ) void {
        var iterator = preserved.keyIterator();
        while (iterator.next()) |address| {
            const current: *Object = @ptrFromInt(address.*);
            var index: usize = 0;
            if (current.collectionPayload()) |payload| {
                var removed_weak_entry = false;
                while (index < payload.weak_entries.len) {
                    if (weakEntryKeyIsPreserved(visited, preserved, symbol_roots, payload.weak_entries[index].key_identity)) {
                        index += 1;
                        continue;
                    }

                    clearValueReferenceToVisited(rt, &payload.weak_entries[index].value, free_set, internal_bytecodes);
                    payload.weak_entries[index].destroy(rt);
                    if (index + 1 < payload.weak_entries.len) {
                        @memmove(payload.weak_entries[index .. payload.weak_entries.len - 1], payload.weak_entries[index + 1 ..]);
                    }
                    payload.weak_entries = payload.weak_entries.ptr[0 .. payload.weak_entries.len - 1];
                    removed_weak_entry = true;
                }
                if (removed_weak_entry) current.clearCollectionIndex(rt);
            }

            if (current.objectDataPayload()) |payload| {
                if (payload.weak_target_identity) |target_identity| {
                    if (!weakEntryKeyIsPreserved(visited, preserved, symbol_roots, target_identity)) {
                        payload.weak_target_identity = null;
                    }
                }
            }

            const finalization_payload = current.finalizationRegistryPayload() orelse continue;
            index = 0;
            while (index < finalization_payload.cells.len) {
                const target_identity = finalization_payload.cells[index].target_identity;
                if (finalization_payload.cells[index].active and target_identity != null and
                    weakEntryKeyIsPreserved(visited, preserved, symbol_roots, target_identity.?))
                {
                    index += 1;
                    continue;
                }

                clearValueReferenceToVisited(rt, &finalization_payload.cells[index].held_value, free_set, internal_bytecodes);
                clearValueReferenceToVisited(rt, &finalization_payload.cells[index].unregister_token, free_set, internal_bytecodes);
                finalization_payload.cells[index].destroy(rt);
                if (index + 1 < finalization_payload.cells.len) {
                    @memmove(finalization_payload.cells[index .. finalization_payload.cells.len - 1], finalization_payload.cells[index + 1 ..]);
                }
                finalization_payload.cells = finalization_payload.cells.ptr[0 .. finalization_payload.cells.len - 1];
            }
            current.pruneBorrowedReferenceHolderIfEmpty(rt);
        }
    }

    fn enqueueFinalizationCleanup(rt: *Runtime, cleanup_callback: ?Value, held_value: Value) void {
        const callback = cleanup_callback orelse return;
        rt.enqueueFinalizationJob(callback, held_value) catch |err| switch (err) {
            // GC cannot surface an allocation failure through the JS call that
            // triggered it, so preserve heap consistency and drop this cleanup.
            error.OutOfMemory => {},
        };
    }

    fn weakEntryKeyIsPreserved(
        visited: *const ObjectVisitSet,
        preserved: *const ObjectVisitSet,
        symbol_roots: *const SymbolRootSet,
        key_identity: usize,
    ) bool {
        if ((key_identity & 1) != 0) {
            const atom_id = key_identity >> 1;
            if (atom_id > std.math.maxInt(atom.Atom)) return false;
            return symbol_roots.contains(@intCast(atom_id));
        }
        return visited.contains(key_identity) and preserved.contains(key_identity);
    }

    pub fn weakIdentityFromValue(stored: Value) ?usize {
        if (stored.asSymbolAtom()) |atom_id| return (@as(usize, @intCast(atom_id)) << 1) | 1;
        const header = stored.refHeader() orelse return null;
        if (header.kind != .object) return null;
        return @intFromPtr(header) & ~@as(usize, 1);
    }

    fn liveObjectFromWeakIdentity(rt: *Runtime, key_identity: usize) ?*Object {
        if ((key_identity & 1) != 0) return null;
        var current = rt.gc.gc_obj_list_head;
        while (current) |node| {
            const next = node.next;
            const header = gc.headerFromGcNode(node);
            if (header.rc > 0 and header.kind == .object) {
                if ((@intFromPtr(header) & ~@as(usize, 1)) == key_identity) {
                    const obj: *Object = @alignCast(@fieldParentPtr("header", header));
                    return obj;
                }
            }
            current = next;
        }
        return null;
    }

    fn accumulateIncomingReferences(
        self: *Object,
        rt: *Runtime,
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

            pub fn visitValue(av: *@This(), val_ptr: *Value) !void {
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
                if (entry.active) {
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
        try self.traceChildEdges(rt, &visitor);
    }

    fn accumulateValueIncoming(
        stored: Value,
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
        function_bytecode: *const bytecode_function.FunctionBytecode,
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

    fn clearReferencesToVisited(
        self: *Object,
        rt: *Runtime,
        visited: *const ObjectVisitSet,
        internal_bytecodes: *const ObjectVisitSet,
    ) ObjectGraphError!void {
        const ClearReferencesVisitor = struct {
            rt: *Runtime,
            visited: *const ObjectVisitSet,
            internal_bytecodes: *const ObjectVisitSet,

            pub fn visitObject(cv: @This(), obj_ptr: *?*Object) !void {
                if (obj_ptr.*) |obj| {
                    if (@intFromPtr(obj) == 0) return;
                    if (cv.visited.contains(@intFromPtr(obj))) {
                        obj_ptr.* = null;
                    }
                }
            }

            pub fn visitValue(cv: @This(), val_ptr: *Value) !void {
                clearValueReferenceToVisited(cv.rt, val_ptr, cv.visited, cv.internal_bytecodes);
            }

            pub fn visitSymbol(cv: @This(), sym_ptr: *atom.Atom) !void {
                _ = cv;
                _ = sym_ptr;
            }

            pub fn visitWeakCollectionEntry(cv: @This(), entry: *WeakCollectionEntry) !void {
                clearValueReferenceToVisited(cv.rt, &entry.value, cv.visited, cv.internal_bytecodes);
            }

            pub fn visitFinalizationCell(cv: @This(), entry: *FinalizationRegistryCell) !void {
                clearValueReferenceToVisited(cv.rt, &entry.held_value, cv.visited, cv.internal_bytecodes);
                clearValueReferenceToVisited(cv.rt, &entry.unregister_token, cv.visited, cv.internal_bytecodes);
            }
        };
        try self.traceChildEdges(rt, ClearReferencesVisitor{
            .rt = rt,
            .visited = visited,
            .internal_bytecodes = internal_bytecodes,
        });
    }

    fn clearOptionalReferenceToVisited(
        rt: *Runtime,
        maybe_value: *?Value,
        visited: *const ObjectVisitSet,
        internal_bytecodes: *const ObjectVisitSet,
    ) void {
        if (maybe_value.*) |*stored| {
            if (valueReferencesVisited(stored.*, visited)) {
                maybe_value.* = null;
                return;
            }
            if (functionBytecodeFromValue(stored.*)) |function_bytecode| {
                if (!internal_bytecodes.contains(@intFromPtr(function_bytecode))) return;
                maybe_value.* = null;
                clearFunctionBytecodeReferencesToVisited(rt, function_bytecode, visited, internal_bytecodes);
            }
        }
    }

    fn clearValueReferenceToVisited(
        rt: *Runtime,
        stored: *Value,
        visited: *const ObjectVisitSet,
        internal_bytecodes: *const ObjectVisitSet,
    ) void {
        if (valueReferencesVisited(stored.*, visited)) {
            stored.* = Value.undefinedValue();
            return;
        }
        if (functionBytecodeFromValue(stored.*)) |function_bytecode| {
            if (!internal_bytecodes.contains(@intFromPtr(function_bytecode))) return;
            stored.* = Value.undefinedValue();
            clearFunctionBytecodeReferencesToVisited(rt, function_bytecode, visited, internal_bytecodes);
            return;
        }
        const cell = varRefCellFromValue(stored.*) orelse return;
        if (cell.varRefValueSlot().*) |cell_value| {
            if (valueReferencesVisited(cell_value, visited)) cell.varRefValueSlot().* = Value.undefinedValue();
        }
    }

    fn clearFunctionBytecodeReferencesToVisited(
        rt: *Runtime,
        function_bytecode: *bytecode_function.FunctionBytecode,
        visited: *const ObjectVisitSet,
        internal_bytecodes: *const ObjectVisitSet,
    ) void {
        if (function_bytecode.class_fields_init) |*stored| clearValueReferenceToVisited(rt, stored, visited, internal_bytecodes);
        for (function_bytecode.cpool) |*stored| clearValueReferenceToVisited(rt, stored, visited, internal_bytecodes);
    }

    fn valueReferencesVisited(stored: Value, visited: *const ObjectVisitSet) bool {
        const child = objectFromValue(stored) orelse return false;
        return visited.contains(@intFromPtr(child));
    }

    fn functionBytecodeFromValue(stored: Value) ?*bytecode_function.FunctionBytecode {
        const header = stored.objectHeader() orelse return null;
        if (header.kind != .function_bytecode) return null;
        return @fieldParentPtr("header", header);
    }

    fn collectInternalFunctionBytecodes(
        rt: *Runtime,
        visited: *const ObjectVisitSet,
        internal_bytecodes: *ObjectVisitSet,
    ) ObjectGraphError!void {
        try collectFunctionBytecodeCandidates(rt, visited, internal_bytecodes);
        try pruneNonInternalFunctionBytecodes(rt, visited, internal_bytecodes);
    }

    fn collectFunctionBytecodeCandidates(
        rt: *Runtime,
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
        rt: *Runtime,
        visited: *const ObjectVisitSet,
        internal_bytecodes: *ObjectVisitSet,
    ) ObjectGraphError!void {
        while (true) {
            var removed = false;
            var iterator = internal_bytecodes.keyIterator();
            while (iterator.next()) |address| {
                const function_bytecode: *const bytecode_function.FunctionBytecode = @ptrFromInt(address.*);
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

    fn functionBytecodeFromGcHeader(header: *gc.GCObjectHeader) ?*const bytecode_function.FunctionBytecode {
        if (header.kind != .function_bytecode) return null;
        return @alignCast(@fieldParentPtr("header", header));
    }

    fn countFunctionBytecodeRefsFromVisitedObjects(
        rt: *Runtime,
        function_bytecode: *const bytecode_function.FunctionBytecode,
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
        function_bytecode: *const bytecode_function.FunctionBytecode,
        owners: *const ObjectVisitSet,
    ) usize {
        var count: usize = 0;
        var iterator = owners.keyIterator();
        while (iterator.next()) |address| {
            const owner: *const bytecode_function.FunctionBytecode = @ptrFromInt(address.*);
            count += countFunctionBytecodeChildRefs(owner, function_bytecode);
        }
        return count;
    }

    fn countFunctionBytecodeChildRefs(
        owner: *const bytecode_function.FunctionBytecode,
        function_bytecode: *const bytecode_function.FunctionBytecode,
    ) usize {
        var count: usize = 0;
        count += countOptionalFunctionBytecodeRef(owner.class_fields_init, function_bytecode);
        for (owner.cpool) |stored| count += countFunctionBytecodeValueRef(stored, function_bytecode);
        return count;
    }

    fn countDirectFunctionBytecodeRefs(
        self: *Object,
        rt: *Runtime,
        function_bytecode: *const bytecode_function.FunctionBytecode,
    ) ObjectGraphError!usize {
        var count: usize = 0;
        count += countOptionalFunctionBytecodeRef(self.cachedIteratorNext(), function_bytecode);
        if (self.shared_lazy_native_functions) |cache| {
            for (cache) |maybe_cached| count += countOptionalFunctionBytecodeRef(maybe_cached, function_bytecode);
        }
        for (self.properties) |entry| count += countSlotFunctionBytecodeRefs(entry.slot, function_bytecode);
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
            if (!entry.active) continue;
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
        rt: *Runtime,
        function_bytecode: *const bytecode_function.FunctionBytecode,
    ) usize {
        var context = PayloadBytecodeRefCountContext{ .function_bytecode = function_bytecode };
        var visitor = class.PayloadVisitor{
            .context = @ptrCast(&context),
            .visit_value = countPayloadFunctionBytecodeRef,
        };
        _ = self.markClassPayload(rt, &visitor);
        return context.count;
    }

    fn countSlotFunctionBytecodeRefs(slot: property.Slot, function_bytecode: *const bytecode_function.FunctionBytecode) usize {
        return switch (slot) {
            .data => |stored| countFunctionBytecodeValueRef(stored, function_bytecode),
            .accessor => |entry| countFunctionBytecodeValueRef(entry.getter, function_bytecode) +
                countFunctionBytecodeValueRef(entry.setter, function_bytecode),
            .auto_init, .deleted => 0,
        };
    }

    fn countOptionalFunctionBytecodeRef(maybe_value: ?Value, function_bytecode: *const bytecode_function.FunctionBytecode) usize {
        return if (maybe_value) |stored| countFunctionBytecodeValueRef(stored, function_bytecode) else 0;
    }

    fn countFunctionBytecodeValueRef(stored: Value, function_bytecode: *const bytecode_function.FunctionBytecode) usize {
        const header = stored.objectHeader() orelse return 0;
        return if (header == &function_bytecode.header) 1 else 0;
    }

    pub fn getPrototype(self: Object) ?*Object {
        return self.prototype;
    }

    pub fn setPrototype(self: *Object, rt: *Runtime, prototype: ?*Object) Error!void {
        var cursor = prototype;
        while (cursor) |candidate| {
            if (candidate == self) return error.PrototypeCycle;
            cursor = candidate.prototype;
        }
        if (!self.extensible and self.prototype != prototype) return error.NotExtensible;
        const proto_id = if (prototype) |proto| @intFromPtr(proto) else null;
        const next_shape = if (self.shapeNeedsMutationCopy())
            try rt.shapes.cloneWithPrototype(self.shape_ref, proto_id)
        else
            null;
        if (prototype) |proto| gc.retain(&proto.header);
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
        self.extensible = false;
    }

    pub fn isExtensible(self: Object) bool {
        return self.extensible;
    }

    pub fn markImmutablePrototype(self: *Object) void {
        self.immutable_prototype = true;
    }

    pub fn hasImmutablePrototype(self: *const Object) bool {
        return self.immutable_prototype;
    }

    pub fn getOwnProperty(self: Object, atom_id: atom.Atom) ?descriptor.Descriptor {
        if (self.exotic) |methods| {
            if (methods.get_own_property) |hook| {
                if (hook(@constCast(&self), atom_id)) |desc| return desc;
            }
        }
        if (self.moduleNamespaceBindingValue(atom_id)) |stored| {
            return descriptor.Descriptor.data(stored, true, true, false);
        }
        if (self.is_array and atom_id == atom.ids.length) {
            return descriptor.Descriptor.data(arrayLengthValue(self.length), self.length_writable, false, false);
        }
        if (self.class_id == class.ids.regexp and atom_id == atom.ids.lastIndex) {
            if (self.regexpLastIndex()) |stored| return descriptor.Descriptor.data(stored.dup(), self.regexpLastIndexWritable(), false, false);
        }
        if (self.findProperty(atom_id)) |index| {
            const entry = self.properties[index];
            if (entry.flags.deleted) return null;
            // Auto-init placeholders need to be materialized before
            // the descriptor is built (`fromEntry` cannot synthesize
            // a value from `(name, length, rt)` on its own). This
            // mirrors `getProperty`'s first-access promotion -- after
            // materialization the slot is `.data` and re-reads are
            // ordinary fast-path data loads.
            if (entry.slot == .auto_init) {
                // `materializeAutoInit` returns a fresh ref for
                // `getProperty` semantics. On success the slot is promoted
                // to `.data` and `fromEntry` dups that stored value. On OOM
                // the placeholder stays `.auto_init`, so expose the
                // fallback value directly instead of passing the placeholder
                // to `fromEntry`.
                const transient = materializeAutoInit(@constCast(&self), index, entry.slot.auto_init);
                const after_materialize = self.properties[index];
                if (after_materialize.slot == .auto_init) {
                    return descriptor.Descriptor.data(
                        transient,
                        entry.flags.writable,
                        entry.flags.enumerable,
                        entry.flags.configurable,
                    );
                }
                transient.free(entry.slot.auto_init.rt);
                return descriptor.Descriptor.fromEntry(after_materialize);
            }
            return descriptor.Descriptor.fromEntry(entry);
        }
        if (self.denseArrayElement(atom_id)) |stored| {
            return descriptor.Descriptor.data(stored.dup(), true, true, true);
        }
        return null;
    }

    pub fn hasOwnProperty(self: Object, atom_id: atom.Atom) bool {
        if (self.class_id == class.ids.regexp and atom_id == atom.ids.lastIndex and self.regexpLastIndex() != null) return true;
        return self.findProperty(atom_id) != null or self.denseArrayElement(atom_id) != null;
    }

    pub fn hasProperty(self: Object, atom_id: atom.Atom) bool {
        profile.recordPropLookup(self.is_global);
        if (self.hasOwnProperty(atom_id)) return true;
        if (self.prototype) |proto| return proto.hasProperty(atom_id);
        return false;
    }

    pub fn getProperty(self: Object, atom_id: atom.Atom) Value {
        profile.recordPropLookup(self.is_global);
        if (self.moduleNamespaceBindingValue(atom_id)) |stored| return stored;
        if (self.is_array and atom_id == atom.ids.length) return arrayLengthValue(self.length);
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
                .auto_init => |info| materializeAutoInit(@constCast(&self), index, info),
                .deleted => Value.undefinedValue(),
            };
        }
        if (self.class_id == class.ids.regexp and atom_id == atom.ids.lastIndex) {
            if (self.regexpLastIndex()) |stored| return stored.dup();
        }
        if (self.denseArrayElement(atom_id)) |stored| return stored.dup();
        if (self.prototype) |proto| return proto.getProperty(atom_id);
        return Value.undefinedValue();
    }

    /// First-access materialization for an `auto_init` placeholder.
    /// Builds the underlying value once (always a native function in
    /// the current scheme), promotes the slot from `auto_init` to
    /// `data`, and returns a fresh ref for the caller.
    ///
    /// The slot now owns one ref; the caller receives another via
    /// `.dup()`. On builder failure we fall back to `undefined` to
    /// keep `getProperty` infallible, mirroring the rest of the
    /// non-throwing read path. (The only failure mode is `OutOfMemory`
    /// from the function-object alloc, which would already be lethal
    /// to the running script anyway.)
    fn materializeAutoInit(self: *Object, index: usize, info: property.AutoInit) Value {
        if (info.kind == .console) {
            const materialized = materializeConsoleAutoInit(info) orelse return Value.undefinedValue();
            self.properties[index].slot = .{ .data = materialized };
            return materialized.dup();
        }
        if (info.kind == .assert) {
            const materialized = materializeAssertAutoInit(info) orelse return Value.undefinedValue();
            self.properties[index].slot = .{ .data = materialized };
            return materialized.dup();
        }
        if (info.kind == .math_namespace or
            info.kind == .json_namespace or
            info.kind == .reflect_namespace or
            info.kind == .atomics_namespace)
        {
            const materialized = materializeBuiltinNamespaceAutoInit(info) orelse return Value.undefinedValue();
            self.properties[index].slot = .{ .data = materialized };
            return materialized.dup();
        }
        if (info.kind == .navigator) {
            const materialized = materializeNavigatorAutoInit(info) orelse return Value.undefinedValue();
            self.properties[index].slot = .{ .data = materialized };
            return materialized.dup();
        }
        if (info.kind == .performance) {
            const materialized = materializePerformanceAutoInit(info) orelse return Value.undefinedValue();
            self.properties[index].slot = .{ .data = materialized };
            return materialized.dup();
        }
        if (info.kind == .test262_namespace) {
            const materialized = materializeTest262NamespaceAutoInit(info) orelse return Value.undefinedValue();
            self.properties[index].slot = .{ .data = materialized };
            return materialized.dup();
        }
        if (info.kind == .array_unscopables) {
            const materialized = materializeArrayUnscopablesAutoInit(info) orelse return Value.undefinedValue();
            self.properties[index].slot = .{ .data = materialized };
            return materialized.dup();
        }
        if (info.kind == .cli_global) {
            const materialized = materializeCliGlobalAutoInit(info) orelse return Value.undefinedValue();
            self.properties[index].slot = .{ .data = materialized };
            return materialized.dup();
        }
        if (info.kind == .number_constant) {
            const materialized = materializeNumberConstantAutoInit(info) orelse return Value.undefinedValue();
            self.properties[index].slot = .{ .data = materialized };
            return materialized.dup();
        }
        if (info.kind == .int32_constant) {
            const materialized = Value.int32(info.length);
            self.properties[index].slot = .{ .data = materialized };
            return materialized.dup();
        }
        if (info.host_function_kind != 0) {
            const materialized = materializeHostFunctionAutoInit(info) orelse return Value.undefinedValue();
            self.properties[index].slot = .{ .data = materialized };
            return materialized.dup();
        }
        const builtins = @import("../builtins/root.zig");
        const materialized = builtins.function.nativeFunction(info.rt, info.name, info.length) catch return Value.undefinedValue();
        if (info.native_builtin_id != 0) {
            if (materialized.refHeader()) |header| {
                const obj: *Object = @fieldParentPtr("header", header);
                obj.nativeFunctionIdSlot().* = info.native_builtin_id;
            }
        }
        applyAutoInitArrayBuiltinMarker(materialized, info.array_builtin_marker);
        applyAutoInitTypedArrayBuiltinMarker(materialized, info.typed_array_builtin_marker);
        applyAutoInitArrayIteratorKind(materialized, info.array_iterator_kind);
        applyAutoInitIteratorIdentity(materialized, info.iterator_identity);
        applyAutoInitCollectionMethodOwner(materialized, info.collection_method_owner_class);
        applyAutoInitDisposableStackMethod(materialized, info.disposable_stack_method);
        applyAutoInitAsyncDisposableStackMethod(materialized, info.async_disposable_stack_method);
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
            const fn_obj_value = materialized;
            if (fn_obj_value.refHeader()) |header| {
                const obj: *Object = @fieldParentPtr("header", header);
                const realm_global: ?*Object = if (info.host_function_realm_global != 0)
                    @ptrFromInt(info.host_function_realm_global)
                else
                    self.functionRealmGlobalPtr();
                if (obj.functionRealmGlobalPtrSlot().* == null) {
                    obj.setFunctionRealmGlobalPtr(info.rt, realm_global) catch {
                        materialized.free(info.rt);
                        return Value.undefinedValue();
                    };
                }
                if (obj != fp and !obj.hasOwnProperty(atom.ids.prototype) and obj.hostFunctionKind() == 0) {
                    obj.setPrototype(info.rt, fp) catch {};
                }
            }
        }
        if (sharedLazyNativeFunctionSlotForAutoInit(info)) |cache_slot| {
            if (cache_slot.*) |cached| {
                const cached_value = cached.dup();
                self.properties[index].slot = .{ .data = cached_value };
                materialized.free(info.rt);
                return cached_value.dup();
            }
            cache_slot.* = materialized.dup();
        }
        // Promote the placeholder to a real data slot. Flags stay the
        // same (writable / enumerable / configurable came from the
        // descriptor used when the placeholder was installed).
        self.properties[index].slot = .{ .data = materialized };
        return materialized.dup();
    }

    fn materializeCliGlobalAutoInit(info: property.AutoInit) ?Value {
        const rt = info.rt;
        if (std.mem.eql(u8, info.name, "argv0")) {
            return @import("../exec/value_ops.zig").createStringValue(rt, rt.cli_argv0) catch null;
        }
        const global: *Object = if (info.host_function_realm_global != 0)
            @ptrFromInt(info.host_function_realm_global)
        else
            return null;
        const items = if (std.mem.eql(u8, info.name, "execArgv"))
            rt.cli_exec_argv
        else if (std.mem.eql(u8, info.name, "scriptArgs"))
            rt.cli_script_args
        else
            return null;
        const array_prototype = arrayPrototypeFromGlobalForCli(rt, global) orelse return null;
        const cli_array = Object.createArray(rt, array_prototype) catch return null;
        for (items, 0..) |item, index| {
            const string_value = @import("../exec/value_ops.zig").createStringValue(rt, item) catch {
                cli_array.value().free(rt);
                return null;
            };
            defer string_value.free(rt);
            cli_array.defineOwnProperty(
                rt,
                atom.atomFromUInt32(@intCast(index)),
                descriptor.Descriptor.data(string_value, true, true, true),
            ) catch {
                cli_array.value().free(rt);
                return null;
            };
        }
        cli_array.length = @intCast(items.len);
        return cli_array.value();
    }

    fn materializeNumberConstantAutoInit(info: property.AutoInit) ?Value {
        const value_ops = @import("../exec/value_ops.zig");
        if (std.mem.eql(u8, info.name, "NaN")) return value_ops.numberToValue(std.math.nan(f64));
        if (std.mem.eql(u8, info.name, "POSITIVE_INFINITY")) return value_ops.numberToValue(std.math.inf(f64));
        if (std.mem.eql(u8, info.name, "NEGATIVE_INFINITY")) return value_ops.numberToValue(-std.math.inf(f64));
        if (std.mem.eql(u8, info.name, "MAX_VALUE")) return value_ops.numberToValue(std.math.floatMax(f64));
        if (std.mem.eql(u8, info.name, "MIN_VALUE")) return value_ops.numberToValue(@as(f64, @bitCast(@as(u64, 1))));
        if (std.mem.eql(u8, info.name, "MAX_SAFE_INTEGER")) return value_ops.numberToValue(9007199254740991.0);
        if (std.mem.eql(u8, info.name, "MIN_SAFE_INTEGER")) return value_ops.numberToValue(-9007199254740991.0);
        if (std.mem.eql(u8, info.name, "EPSILON")) return value_ops.numberToValue(2.220446049250313e-16);
        return null;
    }

    fn arrayPrototypeFromGlobalForCli(rt: *Runtime, global: *Object) ?*Object {
        const array_atom = atom.predefinedId("Array", .string).?;
        const prototype_atom = atom.ids.prototype;
        if (global.getOwnDataObjectBorrowed(array_atom)) |array_ctor| {
            if (array_ctor.getOwnDataObjectBorrowed(prototype_atom)) |prototype| return prototype;
        }
        const array_value = global.getProperty(array_atom);
        defer array_value.free(rt);
        if (!array_value.isObject()) return null;
        const array_ctor = objectFromValue(array_value) orelse return null;
        if (array_ctor.getOwnDataObjectBorrowed(prototype_atom)) |prototype| return prototype;
        const prototype_value = array_ctor.getProperty(prototype_atom);
        defer prototype_value.free(rt);
        return objectFromValue(prototype_value);
    }

    fn functionPrototypeForAutoInit(self: *Object, info: property.AutoInit) ?*Object {
        const realm_global: ?*Object = if (info.host_function_realm_global != 0)
            @ptrFromInt(info.host_function_realm_global)
        else
            self.functionRealmGlobalPtr();
        return if (realm_global) |global| global.cachedFunctionProto() else null;
    }

    fn sharedLazyNativeFunctionSlotForAutoInit(info: property.AutoInit) ?*?Value {
        if (info.shared_native_cache_slot == 0) return null;
        if (info.host_function_realm_global == 0) return null;
        const global: *Object = @ptrFromInt(info.host_function_realm_global);
        global.ensureSharedLazyNativeFunctionCache(info.rt) catch return null;
        return global.sharedLazyNativeFunctionSlot(info.shared_native_cache_slot);
    }

    fn materializeArrayUnscopablesAutoInit(info: property.AutoInit) ?Value {
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
                descriptor.Descriptor.data(Value.boolean(true), true, true, true),
            ) catch {
                unscopables_value.free(rt);
                return null;
            };
        }
        return unscopables_value;
    }

    fn applyAutoInitArrayBuiltinMarker(function_value: Value, marker: ArrayBuiltinMarker) void {
        if (marker == .none) return;
        const header = function_value.refHeader() orelse return;
        const function_object: *Object = @fieldParentPtr("header", header);
        _ = function_object.addArrayBuiltinMarker(marker);
    }

    fn applyAutoInitTypedArrayBuiltinMarker(function_value: Value, marker: TypedArrayBuiltinMarker) void {
        if (marker == .none) return;
        const header = function_value.refHeader() orelse return;
        const function_object: *Object = @fieldParentPtr("header", header);
        _ = function_object.addTypedArrayBuiltinMarker(marker);
    }

    fn applyAutoInitArrayIteratorKind(function_value: Value, kind: u8) void {
        if (kind == 0) return;
        const header = function_value.refHeader() orelse return;
        const function_object: *Object = @fieldParentPtr("header", header);
        _ = function_object.addArrayIteratorKind(kind);
    }

    fn applyAutoInitIteratorIdentity(function_value: Value, is_identity: bool) void {
        if (!is_identity) return;
        const header = function_value.refHeader() orelse return;
        const function_object: *Object = @fieldParentPtr("header", header);
        _ = function_object.addIteratorIdentityFunction();
    }

    fn applyAutoInitCollectionMethodOwner(function_value: Value, owner_class: class.ClassId) void {
        if (owner_class == class.invalid_class_id) return;
        const header = function_value.refHeader() orelse return;
        const function_object: *Object = @fieldParentPtr("header", header);
        _ = function_object.addCollectionMethodOwnerClass(owner_class);
    }

    fn applyAutoInitDisposableStackMethod(function_value: Value, method_id: u8) void {
        if (method_id == 0) return;
        const header = function_value.refHeader() orelse return;
        const function_object: *Object = @fieldParentPtr("header", header);
        _ = function_object.addDisposableStackMethod(method_id);
    }

    fn applyAutoInitAsyncDisposableStackMethod(function_value: Value, method_id: u8) void {
        if (method_id == 0) return;
        const header = function_value.refHeader() orelse return;
        const function_object: *Object = @fieldParentPtr("header", header);
        _ = function_object.addAsyncDisposableStackMethod(method_id);
    }

    fn materializeHostFunctionAutoInit(info: property.AutoInit) ?Value {
        const rt = info.rt;
        const function_object = Object.create(rt, class.ids.c_function, null) catch return null;
        const function_value = function_object.value();
        function_object.hostFunctionKindSlot().* = info.host_function_kind;
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
        function_object.defineOwnPropertyAssumingNew(rt, length_key, descriptor.Descriptor.data(Value.int32(info.length), true, true, true)) catch {
            function_value.free(rt);
            return null;
        };

        if (info.host_function_prototype) {
            const prototype = Object.create(rt, class.ids.object, null) catch {
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

    fn materializeBuiltinNamespaceAutoInit(info: property.AutoInit) ?Value {
        const global: *Object = if (info.host_function_realm_global != 0)
            @ptrFromInt(info.host_function_realm_global)
        else
            return null;
        const builtins = @import("../builtins/root.zig");
        return builtins.registry.materializeBuiltinNamespaceAutoInit(info.rt, global, info.kind) catch null;
    }

    fn defineHostAutoInitDataPropertyByName(
        rt: *Runtime,
        target: *Object,
        name: []const u8,
        length: i32,
        host_function_kind: i32,
        realm_global: ?*Object,
    ) !void {
        const key = try rt.internAtom(name);
        defer rt.atoms.free(key);
        try target.defineHostAutoInitProperty(
            rt,
            key,
            name,
            length,
            property.Flags.data(true, true, true),
            host_function_kind,
            false,
            realm_global,
        );
    }

    fn materializeAssertAutoInit(info: property.AutoInit) ?Value {
        const rt = info.rt;
        if (info.host_function_kind != host_function.ids.test262_assert) return null;
        const assert_value = materializeHostFunctionAutoInit(info) orelse return null;
        const assert_object = objectFromValue(assert_value) orelse {
            assert_value.free(rt);
            return null;
        };
        assert_object.reserveOwnPropertyCapacityAssumingPlain(rt, 6) catch {
            assert_value.free(rt);
            return null;
        };
        const methods = [_]struct {
            name: []const u8,
            kind: i32,
        }{
            .{ .name = "sameValue", .kind = host_function.ids.test262_same_value },
            .{ .name = "notSameValue", .kind = host_function.ids.test262_not_same_value },
            .{ .name = "compareArray", .kind = host_function.ids.test262_compare_array },
            .{ .name = "throws", .kind = host_function.ids.test262_throws },
        };
        for (methods) |method| {
            defineHostAutoInitDataPropertyByName(rt, assert_object, method.name, 2, method.kind, null) catch {
                assert_value.free(rt);
                return null;
            };
        }
        return assert_value;
    }

    fn materializeConsoleAutoInit(info: property.AutoInit) ?Value {
        const rt = info.rt;
        if (info.host_function_kind == 0) return null;
        const console = Object.create(rt, class.ids.object, null) catch return null;
        const console_value = console.value();
        console.reserveOwnPropertyCapacityAssumingPlain(rt, 3) catch {
            console_value.free(rt);
            return null;
        };
        const methods = [_][]const u8{ "log", "warn", "error" };
        for (methods) |name| {
            defineHostAutoInitDataPropertyByName(rt, console, name, 1, info.host_function_kind, null) catch {
                console_value.free(rt);
                return null;
            };
        }
        return console_value;
    }

    fn materializeNavigatorAutoInit(info: property.AutoInit) ?Value {
        const rt = info.rt;
        const builtins = @import("../builtins/root.zig");
        const global: *Object = if (info.host_function_realm_global != 0)
            @ptrFromInt(info.host_function_realm_global)
        else
            return null;
        const object_proto = objectPrototypeFromGlobalForAutoInit(rt, global);
        const proto = Object.create(rt, class.ids.object, object_proto) catch return null;
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

        const getter = builtins.function.nativeFunction(rt, "get userAgent", 0) catch return null;
        defer getter.free(rt);
        const user_agent = rt.internAtom("userAgent") catch return null;
        defer rt.atoms.free(user_agent);
        proto.defineOwnPropertyAssumingNew(
            rt,
            user_agent,
            descriptor.Descriptor.accessor(getter, Value.undefinedValue(), true, true),
        ) catch return null;

        const navigator = Object.create(rt, class.ids.object, proto) catch return null;
        proto.value().free(rt);
        proto_owned = false;
        return navigator.value();
    }

    fn materializePerformanceAutoInit(info: property.AutoInit) ?Value {
        const rt = info.rt;
        const global: *Object = if (info.host_function_realm_global != 0)
            @ptrFromInt(info.host_function_realm_global)
        else
            return null;
        if (rt.performance_time_origin_ms == 0) rt.performance_time_origin_ms = performanceAutoInitNowMs();
        const performance = Object.create(rt, class.ids.object, objectPrototypeFromGlobalForAutoInit(rt, global)) catch return null;
        const performance_value = performance.value();
        performance.reserveOwnPropertyCapacityAssumingPlain(rt, 2) catch {
            performance_value.free(rt);
            return null;
        };

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
            descriptor.Descriptor.data(Value.float64(rt.performance_time_origin_ms), true, true, true),
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

    fn objectPrototypeFromGlobalForAutoInit(rt: *Runtime, global: *Object) ?*Object {
        const object_ctor_value = global.getProperty(atom.predefinedId("Object", .string).?);
        defer object_ctor_value.free(rt);
        if (!object_ctor_value.isObject()) return null;
        const prototype_value = objectFromValue(object_ctor_value).?.getProperty(atom.ids.prototype);
        defer prototype_value.free(rt);
        return objectFromValue(prototype_value);
    }

    fn materializeTest262NamespaceAutoInit(info: property.AutoInit) ?Value {
        const rt = info.rt;
        const global: *Object = if (info.host_function_realm_global != 0)
            @ptrFromInt(info.host_function_realm_global)
        else
            return null;
        const namespace = Object.create(rt, class.ids.object, null) catch return null;
        const namespace_value = namespace.value();
        namespace.reserveOwnPropertyCapacityAssumingPlain(rt, 6) catch {
            namespace_value.free(rt);
            return null;
        };

        defineHostAutoInitDataPropertyByName(rt, namespace, "createRealm", 0, host_function.ids.test262_create_realm, null) catch {
            namespace_value.free(rt);
            return null;
        };
        defineHostAutoInitDataPropertyByName(rt, namespace, "evalScript", 1, host_function.ids.test262_eval_script, global) catch {
            namespace_value.free(rt);
            return null;
        };
        defineHostAutoInitDataPropertyByName(rt, namespace, "detachArrayBuffer", 1, host_function.ids.test262_detach_array_buffer, null) catch {
            namespace_value.free(rt);
            return null;
        };
        defineHostAutoInitDataPropertyByName(rt, namespace, "gc", 0, host_function.ids.std_gc, null) catch {
            namespace_value.free(rt);
            return null;
        };

        const agent = Object.create(rt, class.ids.object, null) catch {
            namespace_value.free(rt);
            return null;
        };
        const agent_value = agent.value();
        agent.reserveOwnPropertyCapacityAssumingPlain(rt, 9) catch {
            agent_value.free(rt);
            namespace_value.free(rt);
            return null;
        };
        const agent_methods = [_]struct {
            name: []const u8,
            length: i32,
            kind: i32,
        }{
            .{ .name = "start", .length = 1, .kind = host_function.ids.test262_agent_start },
            .{ .name = "broadcast", .length = 1, .kind = host_function.ids.test262_agent_broadcast },
            .{ .name = "receiveBroadcast", .length = 1, .kind = host_function.ids.test262_agent_receive_broadcast },
            .{ .name = "report", .length = 1, .kind = host_function.ids.test262_agent_report },
            .{ .name = "getReport", .length = 0, .kind = host_function.ids.test262_agent_get_report },
            .{ .name = "leaving", .length = 0, .kind = host_function.ids.test262_agent_leaving },
            .{ .name = "sleep", .length = 1, .kind = host_function.ids.test262_agent_sleep },
            .{ .name = "monotonicNow", .length = 0, .kind = host_function.ids.test262_agent_monotonic_now },
            .{ .name = "setTimeout", .length = 2, .kind = host_function.ids.test262_agent_set_timeout },
        };
        for (agent_methods) |method| {
            defineHostAutoInitDataPropertyByName(rt, agent, method.name, method.length, method.kind, null) catch {
                agent_value.free(rt);
                namespace_value.free(rt);
                return null;
            };
        }
        const agent_key = rt.internAtom("agent") catch {
            agent_value.free(rt);
            namespace_value.free(rt);
            return null;
        };
        defer rt.atoms.free(agent_key);
        namespace.defineOwnPropertyAssumingNew(rt, agent_key, descriptor.Descriptor.data(agent_value, true, true, true)) catch {
            agent_value.free(rt);
            namespace_value.free(rt);
            return null;
        };
        agent_value.free(rt);

        const is_html_dda_info: property.AutoInit = .{
            .name = "IsHTMLDDA",
            .length = 0,
            .rt = rt,
            .host_function_kind = host_function.ids.test262_is_html_dda,
        };
        const is_html_dda_value = materializeHostFunctionAutoInit(is_html_dda_info) orelse {
            namespace_value.free(rt);
            return null;
        };
        const is_html_dda = objectFromValue(is_html_dda_value) orelse {
            is_html_dda_value.free(rt);
            namespace_value.free(rt);
            return null;
        };
        is_html_dda.is_html_dda = true;
        const is_html_dda_key = rt.internAtom("IsHTMLDDA") catch {
            is_html_dda_value.free(rt);
            namespace_value.free(rt);
            return null;
        };
        defer rt.atoms.free(is_html_dda_key);
        namespace.defineOwnPropertyAssumingNew(rt, is_html_dda_key, descriptor.Descriptor.data(is_html_dda_value, true, true, true)) catch {
            is_html_dda_value.free(rt);
            namespace_value.free(rt);
            return null;
        };
        is_html_dda_value.free(rt);

        return namespace_value;
    }

    pub fn getOwnDataPropertyValue(self: Object, atom_id: atom.Atom) ?Value {
        if (self.getOwnDataPropertyLookup(atom_id)) |lookup| return lookup.value;
        return null;
    }

    pub fn getOwnDataObjectBorrowed(self: Object, atom_id: atom.Atom) ?*Object {
        if (self.exotic != null) return null;
        if (self.findProperty(atom_id)) |index| {
            const entry = self.properties[index];
            if (entry.flags.deleted or entry.flags.accessor) return null;
            return switch (entry.slot) {
                .data => |stored| objectFromValue(stored),
                .auto_init, .accessor, .deleted => null,
            };
        }
        return null;
    }

    pub fn getOwnDataPropertyLookup(self: Object, atom_id: atom.Atom) ?DataPropertyLookup {
        if (self.exotic != null) return null;
        if (self.findProperty(atom_id)) |index| {
            const entry = self.properties[index];
            if (entry.flags.deleted or entry.flags.accessor) return null;
            return switch (entry.slot) {
                .data => |stored| .{ .index = index, .value = stored.dup() },
                .auto_init, .accessor, .deleted => null,
            };
        }
        return null;
    }

    pub fn getOwnDataPropertyValueAt(self: Object, index: usize, atom_id: atom.Atom) ?Value {
        if (self.exotic != null or index >= self.properties.len) return null;
        const entry = self.properties[index];
        if (entry.atom_id != atom_id or entry.flags.deleted or entry.flags.accessor) return null;
        return switch (entry.slot) {
            .data => |stored| stored.dup(),
            .auto_init, .accessor, .deleted => null,
        };
    }

    pub fn getDenseArrayElementValue(self: Object, index: u32) ?Value {
        if (!self.is_array or self.arrayElementStorageMode() != .dense) return null;
        const element_index: usize = @intCast(index);
        const elements = self.arrayElements();
        if (element_index >= elements.len) return null;
        if (elements[element_index]) |stored| return stored.dup();
        return null;
    }

    pub fn defineOwnProperty(self: *Object, rt: *Runtime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void {
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

        if (self.is_array and atom_id == atom.ids.length) {
            try self.defineArrayLength(rt, actual_desc);
            return;
        }

        if (self.class_id == class.ids.regexp and atom_id == atom.ids.lastIndex and self.regexpLastIndex() != null) {
            try self.defineRegExpLastIndex(rt, actual_desc);
            return;
        }

        if (self.is_array) {
            if (array.arrayIndexFromAtom(&rt.atoms, atom_id)) |index| {
                if (index >= self.length and !self.length_writable) return error.ReadOnly;
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
    pub fn defineOwnPropertyAssumingNew(self: *Object, rt: *Runtime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void {
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.is_array);
        std.debug.assert(self.class_id != class.ids.regexp or self.regexpLastIndex() == null);
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.extensible);
        try self.addProperty(rt, atom_id, desc);
    }

    /// Fast-path property define for freshly-created ordinary objects or
    /// arrays when the caller can guarantee the key is brand-new and is not
    /// an array index / `length`. This keeps array length and indexed storage
    /// semantics out of the path for fixed metadata properties such as RegExp
    /// match-array `index`, `input`, and `groups`.
    pub fn defineOwnNonIndexPropertyAssumingNew(self: *Object, rt: *Runtime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void {
        std.debug.assert(self.exotic == null);
        std.debug.assert(!(self.is_array and atom_id == atom.ids.length));
        std.debug.assert(array.arrayIndexFromAtom(&rt.atoms, atom_id) == null);
        std.debug.assert(self.class_id != class.ids.regexp or atom_id != atom.ids.lastIndex or self.regexpLastIndex() == null);
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.extensible);
        try self.addProperty(rt, atom_id, desc);
    }

    pub fn defineRegExpMatchMetadataPropertiesAssumingNew(self: *Object, rt: *Runtime, match_index: i32, input_value: Value, groups_value: Value) !void {
        std.debug.assert(self.exotic == null);
        std.debug.assert(self.is_array);
        std.debug.assert(self.extensible);

        const index_atom = atom.predefinedId("index", .string).?;
        const input_atom = atom.predefinedId("input", .string).?;
        const groups_atom = atom.predefinedId("groups", .string).?;
        const enumerable_flags = property.Flags.data(true, true, true);
        try self.appendPreparedPropertyEntry(rt, .{
            .atom_id = rt.atoms.dup(index_atom),
            .flags = enumerable_flags,
            .slot = .{ .data = Value.int32(match_index) },
        });
        try self.appendPreparedPropertyEntry(rt, .{
            .atom_id = rt.atoms.dup(input_atom),
            .flags = enumerable_flags,
            .slot = .{ .data = input_value.dup() },
        });
        try self.appendPreparedPropertyEntry(rt, .{
            .atom_id = rt.atoms.dup(groups_atom),
            .flags = enumerable_flags,
            .slot = .{ .data = groups_value.dup() },
        });
    }

    pub fn defineJsonParseDataProperty(self: *Object, rt: *Runtime, atom_id: atom.Atom, new_value: Value) !void {
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.is_array);
        std.debug.assert(self.class_id == class.ids.object);
        std.debug.assert(self.extensible);

        if (self.findProperty(atom_id)) |index| {
            var entry = &self.properties[index];
            try self.ensureUniqueShapeForMutation(rt);
            const next_value = dupPropertyDataValue(&rt.atoms, entry.atom_id, new_value);
            const old_slot = entry.slot;
            entry.flags = property.Flags.data(true, true, true);
            entry.slot = .{ .data = next_value };
            rt.shapes.updatePropertyFlags(self.shape_ref, index, entry.flags.bits());
            destroyPropertySlot(rt, entry.atom_id, old_slot);
            self.pruneBorrowedReferenceHolderIfEmpty(rt);
            return;
        }

        try self.addProperty(rt, atom_id, descriptor.Descriptor.data(new_value, true, true, true));
    }

    pub fn reserveOwnPropertyCapacityAssumingPlain(self: *Object, rt: *Runtime, needed: usize) !void {
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.is_array);
        std.debug.assert(self.class_id != class.ids.regexp or self.regexpLastIndex() == null);
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.extensible);
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
        rt: *Runtime,
        atom_id: atom.Atom,
        name: []const u8,
        length: i32,
        flags: property.Flags,
    ) !void {
        try self.defineAutoInitPropertyWithRealm(rt, atom_id, name, length, flags, null);
    }

    pub fn defineAutoInitPropertyWithRealm(
        self: *Object,
        rt: *Runtime,
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
        rt: *Runtime,
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
        rt: *Runtime,
        atom_id: atom.Atom,
        name: []const u8,
        length: i32,
        flags: property.Flags,
        realm_global: ?*Object,
        native_builtin_id: i32,
        shared_native_cache_slot: u8,
    ) !void {
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.is_array);
        std.debug.assert(self.class_id != class.ids.regexp or self.regexpLastIndex() == null);
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.extensible);
        const inserted_holder = if (realm_global != null)
            try registerBorrowedHolderForPendingMutation(rt, self)
        else
            false;
        errdefer rollbackBorrowedHolderRegistration(rt, self, inserted_holder);
        // Inlined to skip `entryFromDescriptor`'s value-dup / accessor-
        // dup work: the placeholder has no Value to retain, just the
        // (name, length, rt) triple stored in the slot's `auto_init`
        // payload. The atom is still retained the same way `addProperty`
        // would, via `rt.shapes.addProperty` -> `atoms.dup`.
        try self.appendPreparedPropertyEntry(rt, .{
            .atom_id = rt.atoms.dup(atom_id),
            .flags = flags,
            .slot = .{ .auto_init = .{
                .name = name,
                .length = length,
                .rt = rt,
                .host_function_realm_global = if (realm_global) |realm| @intFromPtr(realm) else 0,
                .native_builtin_id = native_builtin_id,
                .shared_native_cache_slot = shared_native_cache_slot,
            } },
        });
    }

    pub fn replaceAutoInitPropertyWithRealmNativeAndCache(
        self: *Object,
        rt: *Runtime,
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
        for (self.properties) |*entry| {
            if (entry.flags.deleted or entry.atom_id != atom_id) continue;
            if (entry.slot != .auto_init) return error.TypeError;
            entry.flags = flags;
            entry.slot = .{ .auto_init = .{
                .name = name,
                .length = length,
                .rt = rt,
                .host_function_realm_global = if (realm_global) |realm| @intFromPtr(realm) else 0,
                .native_builtin_id = native_builtin_id,
                .shared_native_cache_slot = shared_native_cache_slot,
            } };
            self.pruneBorrowedReferenceHolderIfEmpty(rt);
            return;
        }
        try self.defineAutoInitPropertyWithRealmNativeAndCache(rt, atom_id, name, length, flags, realm_global, native_builtin_id, shared_native_cache_slot);
    }

    pub fn defineNavigatorAutoInitProperty(
        self: *Object,
        rt: *Runtime,
        atom_id: atom.Atom,
        flags: property.Flags,
        realm_global: *Object,
    ) !void {
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.is_array);
        std.debug.assert(self.extensible);
        const inserted_holder = try registerBorrowedHolderForPendingMutation(rt, self);
        errdefer rollbackBorrowedHolderRegistration(rt, self, inserted_holder);
        try self.appendPreparedPropertyEntry(rt, .{
            .atom_id = rt.atoms.dup(atom_id),
            .flags = flags,
            .slot = .{ .auto_init = .{
                .name = "navigator",
                .length = 0,
                .rt = rt,
                .kind = .navigator,
                .host_function_realm_global = @intFromPtr(realm_global),
            } },
        });
    }

    pub fn defineConsoleAutoInitProperty(
        self: *Object,
        rt: *Runtime,
        atom_id: atom.Atom,
        flags: property.Flags,
        host_function_kind: i32,
    ) !void {
        std.debug.assert(host_function_kind != 0);
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.is_array);
        std.debug.assert(self.extensible);
        try self.appendPreparedPropertyEntry(rt, .{
            .atom_id = rt.atoms.dup(atom_id),
            .flags = flags,
            .slot = .{ .auto_init = .{
                .name = "console",
                .length = 0,
                .rt = rt,
                .kind = .console,
                .host_function_kind = host_function_kind,
            } },
        });
    }

    pub fn defineAssertAutoInitProperty(
        self: *Object,
        rt: *Runtime,
        atom_id: atom.Atom,
        flags: property.Flags,
        host_function_kind: i32,
    ) !void {
        std.debug.assert(host_function_kind == host_function.ids.test262_assert);
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.is_array);
        std.debug.assert(self.extensible);
        try self.appendPreparedPropertyEntry(rt, .{
            .atom_id = rt.atoms.dup(atom_id),
            .flags = flags,
            .slot = .{ .auto_init = .{
                .name = "assert",
                .length = 1,
                .rt = rt,
                .kind = .assert,
                .host_function_kind = host_function_kind,
            } },
        });
    }

    pub fn defineTest262NamespaceAutoInitProperty(
        self: *Object,
        rt: *Runtime,
        atom_id: atom.Atom,
        flags: property.Flags,
        realm_global: *Object,
    ) !void {
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.is_array);
        std.debug.assert(self.extensible);
        const inserted_holder = try registerBorrowedHolderForPendingMutation(rt, self);
        errdefer rollbackBorrowedHolderRegistration(rt, self, inserted_holder);
        try self.appendPreparedPropertyEntry(rt, .{
            .atom_id = rt.atoms.dup(atom_id),
            .flags = flags,
            .slot = .{ .auto_init = .{
                .name = "$262",
                .length = 0,
                .rt = rt,
                .kind = .test262_namespace,
                .host_function_realm_global = @intFromPtr(realm_global),
            } },
        });
    }

    pub fn definePerformanceAutoInitProperty(
        self: *Object,
        rt: *Runtime,
        atom_id: atom.Atom,
        flags: property.Flags,
        realm_global: *Object,
    ) !void {
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.is_array);
        std.debug.assert(self.extensible);
        const inserted_holder = try registerBorrowedHolderForPendingMutation(rt, self);
        errdefer rollbackBorrowedHolderRegistration(rt, self, inserted_holder);
        try self.appendPreparedPropertyEntry(rt, .{
            .atom_id = rt.atoms.dup(atom_id),
            .flags = flags,
            .slot = .{ .auto_init = .{
                .name = "performance",
                .length = 0,
                .rt = rt,
                .kind = .performance,
                .host_function_realm_global = @intFromPtr(realm_global),
            } },
        });
    }

    pub fn defineBuiltinNamespaceAutoInitProperty(
        self: *Object,
        rt: *Runtime,
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
        std.debug.assert(!self.is_array);
        std.debug.assert(self.extensible);
        const inserted_holder = try registerBorrowedHolderForPendingMutation(rt, self);
        errdefer rollbackBorrowedHolderRegistration(rt, self, inserted_holder);
        try self.appendPreparedPropertyEntry(rt, .{
            .atom_id = rt.atoms.dup(atom_id),
            .flags = flags,
            .slot = .{ .auto_init = .{
                .name = name,
                .length = 0,
                .rt = rt,
                .kind = kind,
                .host_function_realm_global = @intFromPtr(realm_global),
            } },
        });
    }

    pub fn defineArrayUnscopablesAutoInitProperty(
        self: *Object,
        rt: *Runtime,
        atom_id: atom.Atom,
        flags: property.Flags,
    ) !void {
        std.debug.assert(self.exotic == null);
        std.debug.assert(self.extensible);
        try self.appendPreparedPropertyEntry(rt, .{
            .atom_id = rt.atoms.dup(atom_id),
            .flags = flags,
            .slot = .{ .auto_init = .{
                .name = "[Symbol.unscopables]",
                .length = 0,
                .rt = rt,
                .kind = .array_unscopables,
            } },
        });
    }

    pub fn defineCliGlobalAutoInitProperty(
        self: *Object,
        rt: *Runtime,
        atom_id: atom.Atom,
        name: []const u8,
        flags: property.Flags,
        realm_global: *Object,
    ) !void {
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.is_array);
        std.debug.assert(self.extensible);
        const inserted_holder = try registerBorrowedHolderForPendingMutation(rt, self);
        errdefer rollbackBorrowedHolderRegistration(rt, self, inserted_holder);
        try self.appendPreparedPropertyEntry(rt, .{
            .atom_id = rt.atoms.dup(atom_id),
            .flags = flags,
            .slot = .{ .auto_init = .{
                .name = name,
                .length = 0,
                .rt = rt,
                .kind = .cli_global,
                .host_function_realm_global = @intFromPtr(realm_global),
            } },
        });
    }

    pub fn defineNumberConstantAutoInitProperty(
        self: *Object,
        rt: *Runtime,
        atom_id: atom.Atom,
        name: []const u8,
        flags: property.Flags,
    ) !void {
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.is_array);
        std.debug.assert(self.class_id != class.ids.regexp or self.regexpLastIndex() == null);
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.extensible);
        try self.appendPreparedPropertyEntry(rt, .{
            .atom_id = rt.atoms.dup(atom_id),
            .flags = flags,
            .slot = .{ .auto_init = .{
                .name = name,
                .length = 0,
                .rt = rt,
                .kind = .number_constant,
            } },
        });
    }

    pub fn defineInt32ConstantAutoInitProperty(
        self: *Object,
        rt: *Runtime,
        atom_id: atom.Atom,
        name: []const u8,
        constant_value: i32,
        flags: property.Flags,
    ) !void {
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.is_array);
        std.debug.assert(self.class_id != class.ids.regexp or self.regexpLastIndex() == null);
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.extensible);
        try self.appendPreparedPropertyEntry(rt, .{
            .atom_id = rt.atoms.dup(atom_id),
            .flags = flags,
            .slot = .{ .auto_init = .{
                .name = name,
                .length = constant_value,
                .rt = rt,
                .kind = .int32_constant,
            } },
        });
    }

    pub fn defineHostAutoInitProperty(
        self: *Object,
        rt: *Runtime,
        atom_id: atom.Atom,
        name: []const u8,
        length: i32,
        flags: property.Flags,
        host_function_kind: i32,
        host_function_prototype: bool,
        host_function_realm_global: ?*Object,
    ) !void {
        std.debug.assert(host_function_kind != 0);
        std.debug.assert(self.exotic == null);
        std.debug.assert(!self.is_array);
        std.debug.assert(self.class_id != class.ids.regexp or self.regexpLastIndex() == null);
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.extensible);
        const inserted_holder = if (host_function_realm_global != null)
            try registerBorrowedHolderForPendingMutation(rt, self)
        else
            false;
        errdefer rollbackBorrowedHolderRegistration(rt, self, inserted_holder);
        try self.appendPreparedPropertyEntry(rt, .{
            .atom_id = rt.atoms.dup(atom_id),
            .flags = flags,
            .slot = .{ .auto_init = .{
                .name = name,
                .length = length,
                .rt = rt,
                .host_function_kind = host_function_kind,
                .host_function_prototype = host_function_prototype,
                .host_function_realm_global = if (host_function_realm_global) |realm| @intFromPtr(realm) else 0,
            } },
        });
    }

    pub fn appendDenseArrayIndex(self: *Object, rt: *Runtime, index: u32, atom_id: atom.Atom, new_value: Value) !bool {
        if (!self.is_array or index != self.length or !self.length_writable) return false;
        if (!self.extensible) return false;
        if (self.prototype) |proto| {
            if (!arrayAppendPrototypeChainHasNoIndexedProperties(proto) and proto.hasProperty(atom_id)) return false;
        }

        try self.ensureArrayElementCapacity(rt, index + 1);
        const elements = self.arrayElementsSlot();
        const old_len = elements.*.len;
        elements.* = elements.*.ptr[0 .. @as(usize, @intCast(index)) + 1];
        if (elements.*.len > old_len) @memset(elements.*[old_len..], null);
        elements.*[@intCast(index)] = new_value.dup();
        self.may_have_indexed_properties = true;
        self.length = index + 1;
        return true;
    }

    pub fn initDenseArrayIndexZeroAssumingEmpty(self: *Object, rt: *Runtime, new_value: Value) !void {
        std.debug.assert(self.is_array);
        std.debug.assert(self.length == 0);
        std.debug.assert(self.length_writable);
        std.debug.assert(self.extensible);
        std.debug.assert(self.arrayElements().len == 0);
        std.debug.assert(self.arrayElementsCapacity() == 0);

        const elements = try rt.memory.alloc(?Value, 1);
        elements[0] = new_value.dup();
        self.arrayElementsSlot().* = elements[0..1];
        self.arrayElementsCapacitySlot().* = 1;
        self.may_have_indexed_properties = true;
        self.length = 1;
    }

    pub fn appendDenseArrayLiteralIndex(self: *Object, rt: *Runtime, index: u32, new_value: Value) !bool {
        if (!self.is_array or index != self.length or !self.length_writable) return false;
        if (!self.extensible) return false;

        try self.ensureArrayElementCapacity(rt, index + 1);
        const elements = self.arrayElementsSlot();
        const old_len = elements.*.len;
        elements.* = elements.*.ptr[0 .. @as(usize, @intCast(index)) + 1];
        if (elements.*.len > old_len) @memset(elements.*[old_len..], null);
        elements.*[@intCast(index)] = new_value.dup();
        self.may_have_indexed_properties = true;
        self.length = index + 1;
        return true;
    }

    pub fn initDenseArrayLiteralValuesAssumingEmpty(self: *Object, rt: *Runtime, values: []const Value) !bool {
        if (!self.is_array or !self.length_writable or !self.extensible) return false;
        if (self.length != 0 or self.properties.len != 0) return false;
        if (self.arrayElementStorageMode() != .dense) return false;
        if (values.len > array.max_array_length) return false;

        try self.ensureArrayElementCapacity(rt, @intCast(values.len));
        const elements = self.arrayElementsSlot();
        elements.* = elements.*.ptr[0..values.len];
        for (values, 0..) |item, index| {
            elements.*[index] = item.dup();
        }
        if (values.len != 0) self.may_have_indexed_properties = true;
        self.length = @intCast(values.len);
        return true;
    }

    pub fn appendDenseArrayInt32Range(self: *Object, rt: *Runtime, start: u32, limit: u32) !bool {
        if (!self.is_array or self.exotic != null or self.arrayElementStorageMode() != .dense) return false;
        if (start != self.length or start >= limit or !self.length_writable or !self.extensible) return false;
        if (self.prototype) |proto| {
            if (!arrayAppendPrototypeChainHasNoIndexedProperties(proto)) return false;
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
            const next = try rt.memory.alloc(?Value, next_capacity);
            errdefer rt.memory.free(?Value, next);
            @memcpy(next[0..old_len], elements.*);
            const old_capacity = capacity.*;
            const old_elements: []?Value = if (old_capacity != 0) elements.*.ptr[0..old_capacity] else elements.*[0..0];
            elements.* = next[0..old_len];
            capacity.* = next_capacity;
            if (old_capacity != 0) rt.memory.free(?Value, old_elements);
        }
        elements.* = elements.*.ptr[0..limit_index];
        if (start_index > old_len) @memset(elements.*[old_len..start_index], null);
        self.may_have_indexed_properties = true;
        self.length = limit;

        if (start_index >= old_len) {
            var index = start_index;
            while (index < limit_index) : (index += 1) {
                elements.*[index] = Value.int32(@intCast(index));
            }
        } else {
            var index = start_index;
            while (index < limit_index) : (index += 1) {
                const old = elements.*[index];
                elements.*[index] = Value.int32(@intCast(index));
                if (old) |stored| stored.free(rt);
            }
        }
        return true;
    }

    pub fn appendDenseArrayInt32ValueRange(self: *Object, rt: *Runtime, start_index: u32, start_value: i32, count: u32) !bool {
        if (count == 0) return true;
        if (!self.is_array or self.exotic != null or self.arrayElementStorageMode() != .dense) return false;
        if (start_index != self.length or !self.length_writable or !self.extensible) return false;
        if (self.prototype) |proto| {
            if (!arrayAppendPrototypeChainHasNoIndexedProperties(proto)) return false;
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
        self.may_have_indexed_properties = true;
        self.length = limit;

        var offset: u32 = 0;
        while (offset < count) : (offset += 1) {
            const index = start_element + @as(usize, @intCast(offset));
            const element_delta: i32 = @intCast(offset);
            const element_value = start_value + element_delta;
            if (index < old_len) {
                const old = elements.*[index];
                elements.*[index] = Value.int32(element_value);
                if (old) |stored| stored.free(rt);
            } else {
                elements.*[index] = Value.int32(element_value);
            }
        }
        return true;
    }

    pub fn reserveDenseArrayElements(self: *Object, rt: *Runtime, needed: u32) !void {
        if (!self.is_array) return;
        try self.ensureArrayElementCapacity(rt, needed);
    }

    pub fn defineDenseArrayDataProperty(self: *Object, rt: *Runtime, index: u32, new_value: Value) !bool {
        if (!self.is_array or self.exotic != null or self.arrayElementStorageMode() != .dense) return false;
        const atom_id = atom.atomFromUInt32(index);
        if (self.findProperty(atom_id) != null) return false;

        const element_index: usize = @intCast(index);
        const elements = self.arrayElementsSlot();
        if (element_index >= elements.*.len) {
            if (!self.extensible) return false;
            if (index >= self.length and !self.length_writable) return false;
            try self.ensureArrayElementCapacity(rt, index + 1);
            const old_len = elements.*.len;
            elements.* = elements.*.ptr[0 .. element_index + 1];
            if (elements.*.len > old_len) @memset(elements.*[old_len..], null);
        } else if (elements.*[element_index] == null and !self.extensible) {
            return false;
        }

        const next_value = new_value.dup();
        const old = elements.*[element_index];
        elements.*[element_index] = next_value;
        self.may_have_indexed_properties = true;
        if (index >= self.length) self.length = index + 1;
        if (old) |stored| stored.free(rt);
        return true;
    }

    fn arrayAppendPrototypeChainHasNoIndexedProperties(proto: *Object) bool {
        var cursor: ?*Object = proto;
        while (cursor) |object| {
            if (object.may_have_indexed_properties) return false;
            cursor = object.getPrototype();
        }
        return true;
    }

    pub fn canDefineDenseArrayDataPropertiesUnchecked(self: Object) bool {
        return self.is_array and
            self.exotic == null and
            self.arrayElementStorageMode() == .dense and
            self.extensible and
            self.properties.len == 0;
    }

    pub fn defineDenseArrayDataPropertyUnchecked(self: *Object, rt: *Runtime, index: u32, new_value: Value) !void {
        std.debug.assert(self.canDefineDenseArrayDataPropertiesUnchecked());
        std.debug.assert(index < self.length or self.length_writable);

        const element_index: usize = @intCast(index);
        const elements = self.arrayElementsSlot();
        if (element_index >= elements.*.len) {
            try self.ensureArrayElementCapacity(rt, index + 1);
            const old_len = elements.*.len;
            elements.* = elements.*.ptr[0 .. element_index + 1];
            if (elements.*.len > old_len) @memset(elements.*[old_len..], null);
        }

        const next_value = new_value.dup();
        const old = elements.*[element_index];
        elements.*[element_index] = next_value;
        self.may_have_indexed_properties = true;
        if (index >= self.length) self.length = index + 1;
        if (old) |stored| stored.free(rt);
    }

    pub fn setProperty(self: *Object, rt: *Runtime, atom_id: atom.Atom, new_value: Value) !void {
        if (self.class_id == class.ids.module_ns) {
            if (self.moduleNamespaceBindingValue(atom_id)) |stored| {
                stored.free(rt);
                return error.ReadOnly;
            }
        }
        if (self.is_array and atom_id == atom.ids.length) {
            if (!self.length_writable) return error.ReadOnly;
            try self.defineArrayLength(rt, descriptor.Descriptor.data(new_value, true, false, false));
            return;
        }
        if (self.class_id == class.ids.regexp and atom_id == atom.ids.lastIndex and self.regexpLastIndex() != null) {
            if (!self.regexpLastIndexWritable()) return error.ReadOnly;
            const last_index = self.regexpLastIndexSlot();
            const next_value = new_value.dup();
            const old_value = last_index.*.?;
            last_index.* = next_value;
            old_value.free(rt);
            return;
        }
        if (self.findProperty(atom_id)) |index| {
            var entry = &self.properties[index];
            if (entry.flags.accessor) {
                if (entry.slot.accessor.setter.isUndefined()) return error.AccessorWithoutSetter;
                return;
            }
            if (!entry.flags.writable) return error.ReadOnly;
            const next_value = dupPropertyDataValue(&rt.atoms, entry.atom_id, new_value);
            const old_slot = entry.slot;
            entry.slot = .{ .data = next_value };
            destroyPropertySlot(rt, entry.atom_id, old_slot);
            self.pruneBorrowedReferenceHolderIfEmpty(rt);
            return;
        }
        if (array.arrayIndexFromAtom(&rt.atoms, atom_id)) |index| {
            if (self.setDenseArrayElement(rt, index, new_value)) return;
        }
        var prototype = self.prototype;
        while (prototype) |proto| {
            if (proto.findProperty(atom_id)) |index| {
                const inherited = proto.properties[index];
                if (inherited.flags.accessor and inherited.slot.accessor.setter.isUndefined()) return error.AccessorWithoutSetter;
                if (!inherited.flags.accessor and !inherited.flags.writable) return error.ReadOnly;
            }
            prototype = proto.prototype;
        }

        try self.defineOwnProperty(rt, atom_id, descriptor.Descriptor.data(new_value, true, true, true));
    }

    pub fn setOwnWritableDataProperty(self: *Object, rt: *Runtime, atom_id: atom.Atom, new_value: Value) !bool {
        if (self.class_id == class.ids.module_ns) {
            if (self.moduleNamespaceBindingValue(atom_id)) |stored| {
                stored.free(rt);
                return false;
            }
        }
        if (self.findProperty(atom_id)) |index| {
            var entry = &self.properties[index];
            if (entry.flags.accessor) return false;
            if (!entry.flags.writable) return false;
            const next_value = dupPropertyDataValue(&rt.atoms, entry.atom_id, new_value);
            const old_slot = entry.slot;
            entry.slot = .{ .data = next_value };
            destroyPropertySlot(rt, entry.atom_id, old_slot);
            self.pruneBorrowedReferenceHolderIfEmpty(rt);
            return true;
        }
        return false;
    }

    pub inline fn setOwnDataPropertyAtForLexicalSync(self: *Object, rt: *Runtime, index: usize, atom_id: atom.Atom, new_value: Value) bool {
        if (self.exotic != null or index >= self.properties.len) return false;
        var entry = &self.properties[index];
        if (entry.atom_id != atom_id or entry.flags.deleted or entry.flags.accessor) return false;
        switch (entry.slot) {
            .data => |*stored| {
                if (!entry.flags.writable and !stored.isUninitialized()) return false;
                if (entry.atom_id == atom.ids.Private_brand) {
                    const next = dupPropertyDataValue(&rt.atoms, entry.atom_id, new_value);
                    const old = stored.*;
                    stored.* = next;
                    destroyPropertySlot(rt, entry.atom_id, .{ .data = old });
                    return true;
                }
                if (!stored.requiresRefCount() and !new_value.requiresRefCount()) {
                    stored.* = new_value;
                    return true;
                }
                const next = new_value.dup();
                const old = stored.*;
                stored.* = next;
                old.free(rt);
                return true;
            },
            .auto_init, .accessor, .deleted => return false,
        }
    }

    pub fn setOrDefineOwnDataPropertyForSimpleSet(self: *Object, rt: *Runtime, atom_id: atom.Atom, new_value: Value) !bool {
        if (self.class_id == class.ids.module_ns) {
            if (self.moduleNamespaceBindingValue(atom_id)) |stored| {
                stored.free(rt);
                return false;
            }
        }
        if (self.findProperty(atom_id)) |index| {
            var entry = &self.properties[index];
            if (entry.flags.accessor) return false;
            if (!entry.flags.writable) return false;
            const next_value = dupPropertyDataValue(&rt.atoms, entry.atom_id, new_value);
            const old_slot = entry.slot;
            entry.slot = .{ .data = next_value };
            destroyPropertySlot(rt, entry.atom_id, old_slot);
            self.pruneBorrowedReferenceHolderIfEmpty(rt);
            return true;
        }
        return try self.defineNewOwnDataPropertyForSimpleSetKnownNoOwn(rt, atom_id, new_value);
    }

    pub fn defineNewOwnDataPropertyForSimpleSet(self: *Object, rt: *Runtime, atom_id: atom.Atom, new_value: Value) !bool {
        if (self.findProperty(atom_id) != null) return false;
        return try self.defineNewOwnDataPropertyForSimpleSetKnownNoOwn(rt, atom_id, new_value);
    }

    fn defineNewOwnDataPropertyForSimpleSetKnownNoOwn(self: *Object, rt: *Runtime, atom_id: atom.Atom, new_value: Value) !bool {
        if (self.exotic != null or self.proxyTarget() != null or self.is_global or self.is_with_environment) return false;
        if (!self.extensible) return false;
        if (self.class_id == class.ids.module_ns or self.class_id == class.ids.regexp or self.class_id == class.ids.mapped_arguments) return false;
        if (isTypedArrayObjectForSetFastPath(self)) return false;
        if (self.is_array and atom_id == atom.ids.length) return false;
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

    fn defineModuleNamespaceProperty(self: *Object, rt: *Runtime, atom_id: atom.Atom, desc: descriptor.Descriptor) !bool {
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
        if (desc.kind == .data and desc.value_present and !sameValue(current, desc.value)) {
            return error.ReadOnly;
        }
        return true;
    }

    pub fn deleteProperty(self: *Object, rt: *Runtime, atom_id: atom.Atom) bool {
        if (self.exotic) |methods| {
            if (methods.delete_property) |hook| return hook(self, atom_id);
        }
        if (self.is_array and atom_id == atom.ids.length) return false;
        if (self.class_id == class.ids.regexp and atom_id == atom.ids.lastIndex and self.regexpLastIndex() != null) return false;

        if (self.findProperty(atom_id)) |index| {
            var entry = &self.properties[index];
            if (!entry.flags.configurable) return false;
            self.ensureUniqueShapeForMutation(rt) catch return false;
            const old_slot = entry.slot;
            entry.slot = .deleted;
            entry.flags.deleted = true;
            entry.flags.accessor = false;
            entry.flags.writable = false;
            rt.shapes.markPropertyDeleted(self.shape_ref, index, entry.flags.bits());
            if (self.class_id == class.ids.mapped_arguments) {
                if (array.arrayIndexFromAtom(&rt.atoms, atom_id)) |mapped_index| {
                    if (mapped_index < self.argumentsVarRefs().len) self.deleteMappedArgumentsBinding(rt, mapped_index);
                }
            }
            destroyPropertySlot(rt, entry.atom_id, old_slot);
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

    pub fn ownKeys(self: Object, rt: *Runtime) OwnKeysError![]atom.Atom {
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
            for (self.properties) |entry| {
                if (entry.flags.deleted) continue;
                const index = array.arrayIndexFromAtom(&rt.atoms, entry.atom_id) orelse continue;
                if (self.hasDenseArrayElement(index)) continue;
                try index_keys.append(rt.memory.allocator, .{
                    .index = index,
                    .atom_id = entry.atom_id,
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

        if (self.is_array) try appendAtom(rt, &keys, atom.ids.length);
        if (self.class_id == class.ids.regexp and self.regexpLastIndex() != null) try appendAtom(rt, &keys, atom.ids.lastIndex);

        for (self.properties) |entry| {
            if (entry.flags.deleted) continue;
            if (array.arrayIndexFromAtom(&rt.atoms, entry.atom_id) != null) continue;
            const atom_kind = rt.atoms.kind(entry.atom_id);
            if (atom_kind == .symbol or atom_kind == .private) continue;
            try appendAtom(rt, &keys, entry.atom_id);
        }

        for (self.properties) |entry| {
            if (entry.flags.deleted) continue;
            if (rt.atoms.kind(entry.atom_id) != .symbol) continue;
            try appendAtom(rt, &keys, entry.atom_id);
        }

        return keys;
    }

    pub fn freeKeys(rt: *Runtime, keys: []atom.Atom) void {
        for (keys) |key| rt.atoms.free(key);
        if (keys.len != 0) rt.memory.free(atom.Atom, keys);
    }

    pub fn seal(self: *Object, rt: *Runtime) !void {
        self.extensible = false;
        try self.ensureUniqueShapeForMutation(rt);
        for (self.properties, 0..) |*entry, index| {
            if (entry.flags.deleted or !entry.flags.configurable) continue;
            entry.flags.configurable = false;
            rt.shapes.updatePropertyFlags(self.shape_ref, index, entry.flags.bits());
        }
    }

    pub fn freeze(self: *Object, rt: *Runtime) !void {
        try self.seal(rt);
        for (self.properties, 0..) |*entry, index| {
            if (entry.flags.deleted or entry.flags.accessor or !entry.flags.writable) continue;
            entry.flags.writable = false;
            rt.shapes.updatePropertyFlags(self.shape_ref, index, entry.flags.bits());
        }
        if (self.is_array) self.length_writable = false;
    }

    fn defineOrdinaryOwnProperty(self: *Object, rt: *Runtime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void {
        if (self.findProperty(atom_id)) |index| {
            if (!isCompatible(self.properties[index], desc)) return error.IncompatibleDescriptor;
            try self.replaceProperty(rt, index, desc);
            return;
        }

        if (array.arrayIndexFromAtom(&rt.atoms, atom_id)) |array_index| {
            const element_index: usize = @intCast(array_index);
            if (element_index < self.arrayElements().len) {
                if (self.arrayElements()[element_index]) |stored| {
                    const current = property.Entry{
                        .atom_id = atom_id,
                        .flags = property.Flags.data(true, true, true),
                        .slot = .{ .data = stored },
                    };
                    if (!isCompatible(current, desc)) return error.IncompatibleDescriptor;
                    try self.addProperty(rt, atom_id, mergeDescriptor(current, desc));
                    self.arrayElements()[element_index] = null;
                    stored.free(rt);
                    return;
                }
            }
        }

        if (!self.extensible) return error.NotExtensible;
        try self.addProperty(rt, atom_id, desc);
    }

    fn defineArrayLength(self: *Object, rt: *Runtime, desc: descriptor.Descriptor) !void {
        if (desc.kind == .accessor) return error.IncompatibleDescriptor;
        const new_len = if (desc.value_present)
            try arrayLengthFromValue(rt, desc.value) orelse return error.InvalidLength
        else
            null;
        if (desc.configurable orelse false) return error.IncompatibleDescriptor;
        if (desc.enumerable orelse false) return error.IncompatibleDescriptor;
        if (!desc.value_present) {
            if (desc.writable) |writable| {
                if (self.length_writable or !writable) {
                    self.length_writable = writable;
                } else {
                    return error.IncompatibleDescriptor;
                }
            }
            return;
        }
        const target_len = new_len.?;
        if (!self.length_writable) {
            if (target_len != self.length or (desc.writable orelse false)) return error.IncompatibleDescriptor;
        }
        if (target_len > self.length and !self.length_writable) return error.ReadOnly;
        if (target_len < self.length) {
            var i = self.properties.len;
            while (i > 0) {
                i -= 1;
                const entry = self.properties[i];
                if (entry.flags.deleted) continue;
                const index = array.arrayIndexFromAtom(&rt.atoms, entry.atom_id) orelse continue;
                if (index >= target_len and !self.deleteProperty(rt, entry.atom_id)) {
                    const adjusted_len = index + 1;
                    self.truncateArrayElements(rt, adjusted_len);
                    self.length = adjusted_len;
                    self.recomputeArrayStorageMode(rt);
                    if (desc.writable == false) self.length_writable = false;
                    return error.IncompatibleDescriptor;
                }
            }
        }
        self.truncateArrayElements(rt, target_len);
        self.length = target_len;
        self.recomputeArrayStorageMode(rt);
        if (desc.writable) |writable| self.length_writable = writable;
    }

    fn defineRegExpLastIndex(self: *Object, rt: *Runtime, desc: descriptor.Descriptor) !void {
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
            if (desc.value_present and !sameValue(last_index.*.?, desc.value)) return error.ReadOnly;
            return;
        }
        if (desc.value_present) {
            const next_value = desc.value.dup();
            const old_value = last_index.*.?;
            last_index.* = next_value;
            old_value.free(rt);
        }
        if (desc.writable) |writable| last_index_writable.* = writable;
    }

    pub fn truncateArrayElements(self: *Object, rt: *Runtime, new_len: u32) void {
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

    fn denseArrayElement(self: Object, atom_id: atom.Atom) ?Value {
        if (!self.is_array) return null;
        if (!atom.isTaggedInt(atom_id)) return null;
        const index: usize = @intCast(atom.atomToUInt32(atom_id));
        if (index >= self.arrayElements().len) return null;
        return self.arrayElements()[index];
    }

    fn hasDenseArrayElement(self: Object, index: u32) bool {
        const element_index: usize = @intCast(index);
        if (element_index >= self.arrayElements().len) return false;
        return self.arrayElements()[element_index] != null;
    }

    fn setDenseArrayElement(self: *Object, rt: *Runtime, index: u32, new_value: Value) bool {
        if (!self.is_array) return false;
        const element_index: usize = @intCast(index);
        const elements = self.arrayElementsSlot();
        if (element_index >= elements.*.len or elements.*[element_index] == null) return false;
        const next_value = new_value.dup();
        const old = elements.*[element_index];
        elements.*[element_index] = next_value;
        self.may_have_indexed_properties = true;
        if (old) |stored| stored.free(rt);
        return true;
    }

    fn ensureArrayElementCapacity(self: *Object, rt: *Runtime, needed: u32) !void {
        const needed_len: usize = @intCast(needed);
        const elements = self.arrayElementsSlot();
        const capacity = self.arrayElementsCapacitySlot();
        if (needed_len <= capacity.*) return;
        var next_capacity = if (capacity.* == 0) @as(usize, 16) else capacity.* * 2;
        while (next_capacity < needed_len) : (next_capacity *= 2) {}
        const next = try rt.memory.alloc(?Value, next_capacity);
        errdefer rt.memory.free(?Value, next);
        @memset(next, null);
        @memcpy(next[0..elements.*.len], elements.*);
        const old_capacity = capacity.*;
        const old_elements: []?Value = if (old_capacity != 0) elements.*.ptr[0..old_capacity] else elements.*[0..0];
        elements.* = next[0..elements.*.len];
        capacity.* = next_capacity;
        if (old_capacity != 0) rt.memory.free(?Value, old_elements);
    }

    fn updateArrayStorageMode(self: *Object, index: u32) void {
        if (!self.is_array) return;
        if (index > self.properties.len * 2 + 8) self.arrayStorageModeSlot().* = .sparse;
    }

    fn recomputeArrayStorageMode(self: *Object, rt: *Runtime) void {
        if (!self.is_array) return;
        self.arrayStorageModeSlot().* = .dense;
        for (self.properties) |entry| {
            if (entry.flags.deleted) continue;
            const index = array.arrayIndexFromAtom(&rt.atoms, entry.atom_id) orelse continue;
            self.updateArrayStorageMode(index);
        }
    }

    fn addProperty(self: *Object, rt: *Runtime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void {
        const entry = try entryFromDescriptor(&rt.atoms, atom_id, desc);
        try self.appendPreparedPropertyEntry(rt, entry);
    }

    fn appendPreparedPropertyEntry(self: *Object, rt: *Runtime, entry: property.Entry) !void {
        var entry_owned = true;
        errdefer if (entry_owned) destroyPropertyEntry(rt, entry);

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

        const old_may_have_indexed_properties = self.may_have_indexed_properties;
        self.properties = self.properties.ptr[0 .. old_len + 1];
        self.properties[old_len] = entry;
        entry_owned = false;

        var inserted = true;
        errdefer if (inserted) {
            destroyPropertyEntry(rt, self.properties[old_len]);
            self.properties[old_len] = .{};
            self.properties = self.properties.ptr[0..old_len];
            self.may_have_indexed_properties = old_may_have_indexed_properties;
            if (grew_properties) {
                const new_properties = self.properties.ptr[0..self.property_capacity];
                self.properties = old_properties[0..old_len];
                self.property_capacity = old_capacity;
                rt.memory.free(property.Entry, new_properties);
            }
        };

        const entry_atom = self.properties[old_len].atom_id;
        if (array.arrayIndexFromAtom(&rt.atoms, entry_atom) != null) {
            self.may_have_indexed_properties = true;
        }
        try self.adoptShapeForNewProperty(rt, entry_atom, self.properties[old_len].flags.bits());
        if (grew_properties and old_capacity != 0) rt.memory.free(property.Entry, old_properties);
        inserted = false;
    }

    fn shapeNeedsMutationCopy(self: Object) bool {
        return self.shape_ref.ref_count != 1 or self.shape_ref.is_transition_cacheable or self.shape_ref.parent != null;
    }

    fn ensureUniqueShapeForMutation(self: *Object, rt: *Runtime) !void {
        if (!self.shapeNeedsMutationCopy()) return;
        const next_shape = try rt.shapes.cloneForMutation(self.shape_ref);
        const old_shape = self.shape_ref;
        self.shape_ref = next_shape;
        rt.shapes.release(old_shape);
    }

    fn adoptShapeForNewProperty(self: *Object, rt: *Runtime, atom_id: atom.Atom, flags: u6) !void {
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

    fn ensurePropertyCapacity(self: *Object, rt: *Runtime, needed: usize) !void {
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

    fn replaceProperty(self: *Object, rt: *Runtime, index: usize, desc: descriptor.Descriptor) !void {
        const atom_id = self.properties[index].atom_id;
        const next = try entryFromDescriptor(&rt.atoms, atom_id, mergeDescriptor(self.properties[index], desc));
        var next_owned = true;
        errdefer if (next_owned) destroyPropertyEntry(rt, next);
        try self.ensureUniqueShapeForMutation(rt);
        const old = self.properties[index];
        self.properties[index] = next;
        next_owned = false;
        rt.shapes.updatePropertyFlags(self.shape_ref, index, next.flags.bits());
        destroyPropertyEntry(rt, old);
        self.pruneBorrowedReferenceHolderIfEmpty(rt);
    }

    fn findProperty(self: Object, atom_id: atom.Atom) ?usize {
        if (self.shape_ref.hasPropertyHash()) {
            var shape_index = self.shape_ref.firstPropertyIndex(atom_id);
            var steps: usize = 0;
            while (shape_index != shape.no_property_index and steps < self.shape_ref.prop_count) : (steps += 1) {
                const index: usize = @intCast(shape_index);
                if (index >= self.shape_ref.prop_count) break;
                shape_index = self.shape_ref.props[index].hash_next;
                if (index >= self.properties.len) continue;
                const entry = self.properties[index];
                if (!entry.flags.deleted and entry.atom_id == atom_id) return index;
            }
        }
        for (self.properties, 0..) |entry, index| {
            if (!entry.flags.deleted and entry.atom_id == atom_id) return index;
        }
        return null;
    }

    fn updateMappedArgumentsBinding(self: *Object, rt: *Runtime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void {
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
            self.setMappedArgumentsBindingValue(rt, index, desc.value);
        }

        if (desc.kind == .data and desc.writable != null and desc.writable.? == false) {
            self.deleteMappedArgumentsBinding(rt, index);
        }
    }

    fn prepareMappedArgumentsDescriptorForDefine(self: *Object, rt: *Runtime, atom_id: atom.Atom, desc: *descriptor.Descriptor) !bool {
        if (self.class_id != class.ids.mapped_arguments) return false;
        if (desc.kind != .data or desc.value_present) return false;
        if (desc.writable == null or desc.writable.? != false) return false;
        const index = array.arrayIndexFromAtom(&rt.atoms, atom_id) orelse return false;
        const mapped_value = self.mappedArgumentsBindingValue(index) orelse return false;
        desc.value = mapped_value;
        desc.value_present = true;
        return true;
    }

    fn setMappedArgumentsBindingValue(self: *Object, rt: *Runtime, index: u32, new_value: Value) void {
        const slot_index: usize = @intCast(index);
        const refs = self.argumentsVarRefsSlot();
        if (varRefCellFromValue(refs.*[slot_index])) |cell| {
            const next_value = new_value.dup();
            const old_value = cell.varRefValueSlot().*;
            cell.varRefValueSlot().* = next_value;
            if (old_value) |stored| stored.free(rt);
            return;
        }
        const next_value = new_value.dup();
        const old_value = refs.*[slot_index];
        refs.*[slot_index] = next_value;
        old_value.free(rt);
    }

    fn deleteMappedArgumentsBinding(self: *Object, rt: *Runtime, index: u32) void {
        const slot_index: usize = @intCast(index);
        const refs = self.argumentsVarRefsSlot();
        const old_value = refs.*[slot_index];
        refs.*[slot_index] = Value.uninitialized();
        old_value.free(rt);
    }

    fn mappedArgumentsBindingValue(self: *Object, index: u32) ?Value {
        const slot_index: usize = @intCast(index);
        const refs = self.argumentsVarRefs();
        if (slot_index >= refs.len) return null;
        const mapped = refs[slot_index];
        if (mapped.isUninitialized()) return null;
        if (varRefCellFromValue(mapped)) |cell| {
            return if (cell.varRefValueSlot().*) |stored| stored.dup() else Value.undefinedValue();
        }
        return mapped.dup();
    }
};

fn testSymbolRootSeeded(rt: *Runtime, atom_id: atom.Atom) ObjectGraphError!bool {
    var symbol_roots = SymbolRootSet.init(rt.memory.allocator);
    defer symbol_roots.deinit();
    try Object.seedSymbolRootsFromRuntimeHeldValues(rt, &symbol_roots);
    try Object.seedSymbolRootsFromValueRoots(rt, rt.active_value_roots, &symbol_roots);
    try Object.seedSymbolRootsFromPendingFinalizationJobs(rt, &symbol_roots);
    return symbol_roots.contains(atom_id);
}

test "external object value roots seed nested symbol roots" {
    const rt = try Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const object = try Object.create(rt, class.ids.object, null);
    var object_value = object.value();
    var object_value_alive = true;
    defer if (object_value_alive) object_value.free(rt);

    const key = try rt.internAtom("external-object-root-symbol-slot");
    defer rt.atoms.free(key);
    const nested_symbol = try rt.atoms.newValueSymbol("external-object-root-nested-symbol");
    try object.defineOwnProperty(rt, key, descriptor.Descriptor.data(Value.symbol(nested_symbol), true, true, true));

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

fn entryFromDescriptor(atoms: *atom.AtomTable, atom_id: atom.Atom, desc: descriptor.Descriptor) !property.Entry {
    const retained_atom = atoms.dup(atom_id);
    return switch (desc.kind) {
        .generic => .{
            .atom_id = retained_atom,
            .flags = property.Flags.data(false, desc.enumerable orelse false, desc.configurable orelse false),
            .slot = .{ .data = Value.undefinedValue() },
        },
        .data => .{
            .atom_id = retained_atom,
            .flags = property.Flags.data(desc.writable orelse false, desc.enumerable orelse false, desc.configurable orelse false),
            .slot = .{ .data = dupPropertyDataValue(atoms, atom_id, desc.value) },
        },
        .accessor => .{
            .atom_id = retained_atom,
            .flags = property.Flags.accessorFlags(desc.enumerable orelse false, desc.configurable orelse false),
            .slot = .{ .accessor = .{
                .getter = desc.getter.dup(),
                .setter = desc.setter.dup(),
            } },
        },
    };
}

fn destroyPropertyEntry(rt: *Runtime, entry: property.Entry) void {
    destroyPropertySlot(rt, entry.atom_id, entry.slot);
    if (entry.atom_id != atom.null_atom) rt.atoms.free(entry.atom_id);
}

pub fn dupPropertyDataValue(atoms: *atom.AtomTable, atom_id: atom.Atom, value: Value) Value {
    if (atom_id == atom.ids.Private_brand) {
        if (value.asSymbolAtom()) |brand_atom| {
            if (atoms.kind(brand_atom) == .private) return Value.symbol(atoms.dup(brand_atom));
        }
    }
    return value.dup();
}

pub fn destroyPropertySlot(rt: *Runtime, atom_id: atom.Atom, slot: property.Slot) void {
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
    return object.typedArrayBuffer() != null and object.typedArrayElementSize() != 0;
}

fn isCompatible(current: property.Entry, desc: descriptor.Descriptor) bool {
    if (current.flags.configurable) return true;
    if (desc.configurable orelse false) return false;
    if (desc.enumerable) |enumerable| {
        if (enumerable != current.flags.enumerable) return false;
    }
    if (desc.kind == .generic) return true;

    const current_is_accessor = current.flags.accessor;
    if ((desc.kind == .accessor) != current_is_accessor) return false;
    if (!current_is_accessor and !current.flags.writable) {
        if (desc.writable orelse false) return false;
        if (desc.kind == .data and desc.value_present and !sameValue(current.slot.data, desc.value)) return false;
    }
    if (current_is_accessor and desc.kind == .accessor) {
        if (desc.getter_present and !sameValue(current.slot.accessor.getter, desc.getter)) return false;
        if (desc.setter_present and !sameValue(current.slot.accessor.setter, desc.setter)) return false;
    }
    return true;
}

fn mergeDescriptor(current: property.Entry, desc: descriptor.Descriptor) descriptor.Descriptor {
    return switch (desc.kind) {
        .generic => switch (current.slot) {
            .data => |value| descriptor.Descriptor.data(
                value,
                current.flags.writable,
                desc.enumerable orelse current.flags.enumerable,
                desc.configurable orelse current.flags.configurable,
            ),
            .accessor => |accessor| descriptor.Descriptor.accessor(
                accessor.getter,
                accessor.setter,
                desc.enumerable orelse current.flags.enumerable,
                desc.configurable orelse current.flags.configurable,
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
            if (desc.value_present) desc.value else switch (current.slot) {
                .data => |value| value,
                else => desc.value,
            },
            desc.writable orelse if (current.flags.accessor) false else current.flags.writable,
            desc.enumerable orelse current.flags.enumerable,
            desc.configurable orelse current.flags.configurable,
        ),
        .accessor => descriptor.Descriptor.accessor(
            if (desc.getter_present) desc.getter else switch (current.slot) {
                .accessor => |accessor| accessor.getter,
                else => desc.getter,
            },
            if (desc.setter_present) desc.setter else switch (current.slot) {
                .accessor => |accessor| accessor.setter,
                else => desc.setter,
            },
            desc.enumerable orelse current.flags.enumerable,
            desc.configurable orelse current.flags.configurable,
        ),
    };
}

fn sameValue(a: Value, b: Value) bool {
    if (numberValue(a)) |lhs| {
        if (numberValue(b)) |rhs| {
            if (std.math.isNan(lhs) and std.math.isNan(rhs)) return true;
            if (lhs == 0 and rhs == 0) return isNegativeZero(lhs) == isNegativeZero(rhs);
            return lhs == rhs;
        }
    }
    if (a.isString() and b.isString()) {
        if (a.same(b)) return true;
        const a_header = a.refHeader() orelse return false;
        const b_header = b.refHeader() orelse return false;
        const a_string: *const @import("string.zig").String = @fieldParentPtr("header", a_header);
        const b_string: *const @import("string.zig").String = @fieldParentPtr("header", b_header);
        return a_string.eqlString(b_string.*);
    }
    return a.same(b);
}

fn numberValue(value: Value) ?f64 {
    if (value.asInt32()) |int_value| return @floatFromInt(int_value);
    if (value.asFloat64()) |float_value| return float_value;
    return null;
}

fn isNegativeZero(value: f64) bool {
    return value == 0 and std.math.signbit(value);
}

fn arrayLengthValue(length: u32) Value {
    if (length <= @as(u32, @intCast(std.math.maxInt(i32)))) {
        return Value.int32(@intCast(length));
    }
    return Value.float64(@floatFromInt(length));
}

fn arrayLengthFromValue(rt: *Runtime, value: Value) !?u32 {
    const number = try arrayLengthNumber(rt, value) orelse return null;
    if (std.math.isNan(number) or !std.math.isFinite(number)) return null;
    if (number < 0 or number > @as(f64, @floatFromInt(array.max_array_length))) return null;
    const truncated = @trunc(number);
    if (truncated != number) return null;
    return @intFromFloat(truncated);
}

fn arrayLengthNumber(rt: *Runtime, value: Value) !?f64 {
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

fn arrayLengthStringNumber(rt: *Runtime, value: Value) !f64 {
    const header = value.refHeader() orelse return std.math.nan(f64);
    const string_value: *const @import("string.zig").String = @fieldParentPtr("header", header);
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

fn varRefCellFromValue(value: Value) ?*Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    const object: *Object = @fieldParentPtr("header", header);
    if (object.varRefPayload() == null) return null;
    return object;
}

fn appendAtom(rt: *Runtime, keys: *[]atom.Atom, atom_id: atom.Atom) OwnKeysError!void {
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

fn hasPropertyIndexKeys(self: Object, rt: *Runtime) bool {
    for (self.properties) |entry| {
        if (entry.flags.deleted) continue;
        const index = array.arrayIndexFromAtom(&rt.atoms, entry.atom_id) orelse continue;
        if (!self.hasDenseArrayElement(index)) return true;
    }
    return false;
}

fn indexKeyLessThan(_: void, lhs: IndexKey, rhs: IndexKey) bool {
    return lhs.index < rhs.index;
}

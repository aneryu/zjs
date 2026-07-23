const std = @import("std");
const atom = @import("atom.zig");
const memory = @import("memory.zig");
const builtin = @import("builtin");

comptime {
    @setEvalBranchQuota(5000);
}

pub const ClassId = u16;
pub const invalid_class_id: ClassId = 0;
pub const MutationError = error{WrongRuntimeThread};

/// QuickJS class identities are process-global: a runtime owns the class
/// definition registered at an id, while the id itself belongs to the caller
/// (normally a static `JSClassID` slot).  Keep the allocator widened so the
/// final legal u16 id is usable and exhaustion can never wrap/reuse an id.
var dynamic_class_id_lock: std.atomic.Value(bool) = .init(false);
var next_dynamic_class_id: u32 = ids.init_count;

fn lockDynamicClassIds() void {
    while (dynamic_class_id_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
}

fn unlockDynamicClassIds() void {
    dynamic_class_id_lock.store(false, .release);
}

fn allocateDynamicClassIdLocked() error{ClassIdExhausted}!ClassId {
    if (next_dynamic_class_id > std.math.maxInt(ClassId)) return error.ClassIdExhausted;
    const id: ClassId = @intCast(next_dynamic_class_id);
    next_dynamic_class_id += 1;
    return id;
}

pub fn allocateDynamicClassId() error{ClassIdExhausted}!ClassId {
    lockDynamicClassIds();
    defer unlockDynamicClassIds();
    return allocateDynamicClassIdLocked();
}

/// Caller-owned stable class identity, mirroring `JS_NewClassID(&slot)`.
/// Definitions remain independently registered in each `JSRuntime`.
pub const ClassIdSlot = struct {
    value: ClassId = invalid_class_id,

    pub fn getOrAllocate(self: *ClassIdSlot) error{ClassIdExhausted}!ClassId {
        lockDynamicClassIds();
        defer unlockDynamicClassIds();
        if (self.value == invalid_class_id) self.value = try allocateDynamicClassIdLocked();
        return self.value;
    }
};

pub const ids = struct {
    pub const object: ClassId = 1;
    pub const array: ClassId = 2;
    pub const error_: ClassId = 3;
    pub const number: ClassId = 4;
    pub const string: ClassId = 5;
    pub const boolean: ClassId = 6;
    pub const symbol: ClassId = 7;
    pub const arguments: ClassId = 8;
    pub const mapped_arguments: ClassId = 9;
    pub const date: ClassId = 10;
    pub const module_ns: ClassId = 11;
    pub const c_function: ClassId = 12;
    pub const bytecode_function: ClassId = 13;
    pub const bound_function: ClassId = 14;
    pub const c_function_data: ClassId = 15;
    pub const c_closure: ClassId = 16;
    pub const generator_function: ClassId = 17;
    pub const for_in_iterator: ClassId = 18;
    pub const regexp: ClassId = 19;
    pub const array_buffer: ClassId = 20;
    pub const shared_array_buffer: ClassId = 21;
    pub const uint8c_array: ClassId = 22;
    pub const int8_array: ClassId = 23;
    pub const uint8_array: ClassId = 24;
    pub const int16_array: ClassId = 25;
    pub const uint16_array: ClassId = 26;
    pub const int32_array: ClassId = 27;
    pub const uint32_array: ClassId = 28;
    pub const big_int64_array: ClassId = 29;
    pub const big_uint64_array: ClassId = 30;
    pub const float16_array: ClassId = 31;
    pub const float32_array: ClassId = 32;
    pub const float64_array: ClassId = 33;
    pub const dataview: ClassId = 34;
    pub const big_int: ClassId = 35;
    pub const map: ClassId = 36;
    pub const set: ClassId = 37;
    pub const weakmap: ClassId = 38;
    pub const weakset: ClassId = 39;
    pub const iterator: ClassId = 40;
    pub const iterator_concat: ClassId = 41;
    pub const iterator_helper: ClassId = 42;
    pub const iterator_wrap: ClassId = 43;
    pub const map_iterator: ClassId = 44;
    pub const set_iterator: ClassId = 45;
    pub const array_iterator: ClassId = 46;
    pub const string_iterator: ClassId = 47;
    pub const regexp_string_iterator: ClassId = 48;
    pub const generator: ClassId = 49;
    pub const proxy: ClassId = 50;
    pub const promise: ClassId = 51;
    pub const promise_resolve_function: ClassId = 52;
    pub const promise_reject_function: ClassId = 53;
    pub const async_function: ClassId = 54;
    pub const async_function_resolve: ClassId = 55;
    pub const async_function_reject: ClassId = 56;
    pub const async_from_sync_iterator: ClassId = 57;
    pub const async_generator_function: ClassId = 58;
    pub const async_generator: ClassId = 59;
    pub const weak_ref: ClassId = 60;
    pub const finalization_registry: ClassId = 61;
    pub const dom_exception: ClassId = 62;
    pub const call_site: ClassId = 63;
    pub const raw_json: ClassId = 64;
    pub const std_file: ClassId = 65;
    pub const disposable_stack: ClassId = 66;
    pub const async_disposable_stack: ClassId = 67;
    /// Internal identity for the realm's global object.  Realm state itself
    /// lives on `RealmContext`; this class only selects global-object storage.
    pub const global_object: ClassId = 68;
    pub const init_count: ClassId = 69;
};

/// Object-resident payload discriminator. Keep the tag within five bits so it
/// can share the compact JSObject metadata word with the hot object flags,
/// matching QuickJS's 8-byte flags/class/weakref prefix.
pub const PayloadKind = enum(u5) {
    none,
    ordinary,
    arguments,
    object_data,
    function,
    bound_function,
    var_ref,
    generator,
    promise,
    proxy,
    regexp,
    iterator,
    collection,
    buffer,
    typed_array,
    finalization_registry,
    std_file,
    disposable_stack,
    global,
    realm_record,
    weak_ref,
};

pub const Payload = ?*anyopaque;

/// Function classes whose `.function` payload uses the bytecode arm. Mirrors
/// QuickJS's `JSObject.u.func` discriminator: every other `.function` payload
/// class uses the mutually-exclusive native/c-function arm.
pub inline fn isBytecodeFunctionClass(id: ClassId) bool {
    return switch (id) {
        ids.bytecode_function,
        ids.generator_function,
        ids.async_function,
        ids.async_generator_function,
        => true,
        else => false,
    };
}

pub const PayloadVisitor = struct {
    context: *anyopaque,
    visit_value: ?*const fn (context: *anyopaque, value: *anyopaque) void = null,
    /// Visits a nullable strong object slot. Payload mark hooks pass a pointer
    /// to `?*Object`; the object module owns the concrete cast.
    visit_object: ?*const fn (context: *anyopaque, object: *anyopaque) void = null,

    pub fn value(self: *PayloadVisitor, value_ptr: *anyopaque) void {
        const visit = self.visit_value orelse return;
        visit(self.context, value_ptr);
    }

    pub fn object(self: *PayloadVisitor, object_ptr: *anyopaque) void {
        const visit = self.visit_object orelse return;
        visit(self.context, object_ptr);
    }
};

pub const LegacyFinalizer = *const fn () void;
pub const PayloadFinalizer = *const fn (runtime: *anyopaque, object: *anyopaque, payload: *Payload) void;
pub const PayloadMark = *const fn (runtime: *anyopaque, object: *anyopaque, payload: *Payload, visitor: *PayloadVisitor) void;
pub const Call = *const fn () void;
pub const BindingDataFinalizer = *const fn (data: *anyopaque) void;

pub const Definition = struct {
    class_name: []const u8,
    binding_identity: ?[]const u8 = null,
    binding_data: ?*anyopaque = null,
    binding_data_finalizer: ?BindingDataFinalizer = null,
    payload_kind: PayloadKind = .none,
    inline_payload_size: u32 = 0,
    inline_payload_align: u16 = 1,
    finalizer: ?LegacyFinalizer = null,
    payload_finalizer: ?PayloadFinalizer = null,
    payload_mark: ?PayloadMark = null,
    call: ?Call = null,
    has_exotic: bool = false,
    exotic_methods: ?*const anyopaque = null,
};

pub const Record = struct {
    id: ClassId = invalid_class_id,
    class_name: atom.Atom = atom.null_atom,
    binding_identity: ?[]const u8 = null,
    binding_data: ?*anyopaque = null,
    binding_data_finalizer: ?BindingDataFinalizer = null,
    payload_kind: PayloadKind = .none,
    inline_payload_size: u32 = 0,
    inline_payload_align: u16 = 1,
    finalizer: ?LegacyFinalizer = null,
    payload_finalizer: ?PayloadFinalizer = null,
    payload_mark: ?PayloadMark = null,
    call: ?Call = null,
    has_exotic: bool = false,
    exotic_methods: ?*const anyopaque = null,

    pub fn isRegistered(self: Record) bool {
        return self.id != invalid_class_id;
    }

    pub fn hasInlinePayload(self: Record) bool {
        return self.inline_payload_size != 0;
    }

    pub fn finalizeBindingData(self: Record) void {
        const data = self.binding_data orelse return;
        const finalizer = self.binding_data_finalizer orelse return;
        finalizer(data);
    }
};

/// Mutable lifetime state lives beside the immutable class definition. A
/// `Record *` is only a transient table view: growing `Table.records` may move
/// every record, while this state is always reacquired by class id.
const RegistrationState = struct {
    generation: u64 = 0,
    construction_pins: usize = 0,
    live_object_pins: usize = 0,
    callback_pins: usize = 0,
    unregister_pending: bool = false,

    fn isPinned(self: RegistrationState) bool {
        return self.construction_pins != 0 or self.live_object_pins != 0 or self.callback_pins != 0;
    }
};

pub const Table = struct {
    pub const DefinitionPlan = struct {
        generation: u64 = 0,
        payload_kind: PayloadKind = .none,
        inline_payload_size: u32 = 0,
        inline_payload_align: u16 = 1,
        has_payload_finalizer: bool = false,
        has_exotic: bool = false,
    };

    /// Pins a dynamic definition while object construction may allocate,
    /// collect, or invoke a reentrant host hook. It stores no pointer into a
    /// movable table buffer.
    pub const Construction = struct {
        table: *Table,
        class_id: ClassId,
        definition: DefinitionPlan,
        dynamic_pin_active: bool,

        /// Transfer the construction pin to the initialized object immediately
        /// before publishing it to the GC registry.
        pub fn publishObject(self: *Construction) void {
            self.table.assertOwnerThread();
            if (!self.dynamic_pin_active) return;
            const state = &self.table.registration_states[self.class_id];
            // The construction pin makes unregister defer record removal. Other
            // class registrations may still move the table, so reacquire by id
            // and validate the generation before publication.
            const record_view = self.table.recordPtr(self.class_id) orelse unreachable;
            std.debug.assert(state.generation == self.definition.generation);
            std.debug.assert(record_view.id == self.class_id);
            std.debug.assert(state.construction_pins != 0);
            state.construction_pins -= 1;
            state.live_object_pins += 1;
            self.dynamic_pin_active = false;
        }

        /// Release an unpublished construction view. Callers declare this
        /// before their prepared-resource errdefers so pending unregister only
        /// completes after those resources have unwound.
        pub fn abort(self: *Construction) void {
            self.table.assertOwnerThread();
            if (!self.dynamic_pin_active) return;
            const state = &self.table.registration_states[self.class_id];
            std.debug.assert(state.generation == self.definition.generation);
            std.debug.assert(state.construction_pins != 0);
            state.construction_pins -= 1;
            self.dynamic_pin_active = false;
            self.table.completePendingUnregister(self.class_id);
        }
    };

    /// Function pointers copied into a deferred payload-finalizer node. The
    /// callback pin owns the definition until the callback returns.
    pub const DeferredPayloadCallbacks = struct {
        generation: u64,
        finalizer: PayloadFinalizer,
        mark: ?PayloadMark,
    };

    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,
    owner_thread_id: std.Thread.Id,
    records: []Record = &.{},
    records_inline: [ids.init_count]Record = @splat(.{}),
    registration_states: []RegistrationState = &.{},
    registration_states_inline: [ids.init_count]RegistrationState = @splat(.{}),

    pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable) !Table {
        var table = Table{
            .memory = account,
            .atoms = atoms,
            .owner_thread_id = std.Thread.getCurrentId(),
        };
        errdefer table.deinit();
        try table.ensureCapacity(ids.init_count);
        try table.registerStandardClasses();
        return table;
    }

    pub fn initInPlace(self: *Table, account: *memory.MemoryAccount, atoms: *atom.AtomTable) !void {
        self.* = .{
            .memory = account,
            .atoms = atoms,
            .owner_thread_id = std.Thread.getCurrentId(),
        };
        self.records = self.records_inline[0..ids.init_count];
        self.registration_states = self.registration_states_inline[0..ids.init_count];
        @memset(self.records, .{});
        @memset(self.registration_states, .{});
        errdefer self.deinit();
        try self.registerStandardClasses();
    }

    fn registerStandardClasses(self: *Table) !void {
        for (standard_classes) |entry| {
            try self.registerAtom(entry.id, entry.name_atom, .{
                .class_name = "",
                .payload_kind = standardPayloadKind(entry.id),
            });
        }
    }

    fn usingInlineRecords(self: *const Table) bool {
        return self.records.ptr == self.records_inline[0..].ptr;
    }

    fn usingInlineRegistrationStates(self: *const Table) bool {
        return self.registration_states.ptr == self.registration_states_inline[0..].ptr;
    }

    pub fn isOwnerThread(self: *const Table) bool {
        return self.owner_thread_id == std.Thread.getCurrentId();
    }

    pub fn requireOwnerThread(self: *const Table) MutationError!void {
        if (!self.isOwnerThread()) return error.WrongRuntimeThread;
    }

    pub fn assertOwnerThread(self: *const Table) void {
        if (!self.isOwnerThread()) @panic("class table mutation from non-owner Runtime thread");
    }

    pub fn deinit(self: *Table) void {
        self.assertOwnerThread();
        const records = self.records;
        const using_inline = self.usingInlineRecords();
        const registration_states = self.registration_states;
        const using_inline_states = self.usingInlineRegistrationStates();
        self.records = &.{};
        self.registration_states = &.{};
        for (records) |rec| {
            if (rec.isRegistered()) {
                rec.finalizeBindingData();
                self.atoms.free(rec.class_name);
            }
        }
        for (registration_states) |state| std.debug.assert(!state.isPinned());
        if (using_inline) {
            @memset(records, .{});
        } else if (records.len != 0) {
            self.memory.free(Record, records);
        }
        if (using_inline_states) {
            @memset(registration_states, .{});
        } else if (registration_states.len != 0) {
            self.memory.free(RegistrationState, registration_states);
        }
    }

    pub fn register(self: *Table, id: ClassId, def: Definition) !void {
        try self.requireOwnerThread();
        const name_atom = try self.atoms.internString(def.class_name);
        defer self.atoms.free(name_atom);
        try self.registerAtom(id, name_atom, def);
    }

    pub fn unregisterDynamic(self: *Table, id: ClassId) void {
        self.assertOwnerThread();
        self.unregisterDynamicOwned(id);
    }

    /// Checked unregistration for embedding boundaries. Rejection happens
    /// before the pending bit or class record is touched.
    pub fn tryUnregisterDynamic(self: *Table, id: ClassId) MutationError!void {
        try self.requireOwnerThread();
        self.unregisterDynamicOwned(id);
    }

    fn unregisterDynamicOwned(self: *Table, id: ClassId) void {
        if (id < ids.init_count or id >= self.records.len) return;
        if (!self.records[id].isRegistered()) return;
        self.registration_states[id].unregister_pending = true;
        self.completePendingUnregister(id);
    }

    /// Snapshot the immutable scalars required during construction and pin a
    /// dynamic definition. Standard definitions are runtime-lifetime and avoid
    /// the counter traffic entirely.
    pub fn beginConstruction(self: *Table, id: ClassId) error{InvalidClassId}!Construction {
        self.assertOwnerThread();
        if (id < ids.init_count) {
            const generation = if (id < self.registration_states.len) self.registration_states[id].generation else 0;
            return .{
                .table = self,
                .class_id = id,
                .definition = definitionPlan(self.recordPtr(id), id, generation),
                .dynamic_pin_active = false,
            };
        }
        if (id >= self.records.len or !self.records[id].isRegistered()) return error.InvalidClassId;
        const definition_view = self.recordPtr(id).?;
        const state = &self.registration_states[id];
        // Once removal is published, only constructions that already own this
        // generation may finish. A later Object.create must not indefinitely
        // extend a retired definition's lifetime.
        if (state.unregister_pending) return error.InvalidClassId;
        // An in-flight construction may finish from the exact pinned
        // generation even after unregister was requested. Later unregister
        // completion waits for the resulting live-object pin.
        state.construction_pins += 1;
        return .{
            .table = self,
            .class_id = id,
            .definition = definitionPlan(definition_view, id, state.generation),
            .dynamic_pin_active = true,
        };
    }

    /// Reacquire the immutable destruction scalars for an object without
    /// retaining a pointer across cleanup or finalizer callbacks.
    pub fn destructionPlan(self: *const Table, id: ClassId) ?DefinitionPlan {
        if (id < ids.init_count) {
            const generation = if (id < self.registration_states.len) self.registration_states[id].generation else 0;
            return definitionPlan(self.recordPtr(id), id, generation);
        }
        if (id >= self.records.len) return null;
        const state = self.registration_states[id];
        if (state.live_object_pins == 0) return null;
        return definitionPlan(self.recordPtr(id) orelse return null, id, state.generation);
    }

    /// Release a dynamic object's definition pin only after its allocation is
    /// gone (including weak-husk and cycle pass-B lifetimes).
    pub fn releaseObjectDefinition(self: *Table, id: ClassId, generation: u64) void {
        self.assertOwnerThread();
        if (id < ids.init_count) return;
        std.debug.assert(id < self.registration_states.len);
        const state = &self.registration_states[id];
        std.debug.assert(state.generation == generation);
        std.debug.assert(state.live_object_pins != 0);
        state.live_object_pins -= 1;
        self.completePendingUnregister(id);
    }

    /// Copy the callbacks for a deferred node and retain the definition from
    /// enqueue until callback completion.
    pub fn pinDeferredPayloadCallbacks(self: *Table, id: ClassId, generation: u64) ?DeferredPayloadCallbacks {
        self.assertOwnerThread();
        const definition_view = self.recordPtr(id) orelse return null;
        const finalizer = definition_view.payload_finalizer orelse return null;
        if (id >= ids.init_count) {
            const state = &self.registration_states[id];
            if (state.generation != generation or state.live_object_pins == 0) return null;
            state.callback_pins += 1;
        }
        return .{
            .generation = generation,
            .finalizer = finalizer,
            .mark = definition_view.payload_mark,
        };
    }

    pub fn releaseDeferredPayloadCallbacks(self: *Table, id: ClassId, generation: u64) void {
        self.assertOwnerThread();
        if (id < ids.init_count) return;
        std.debug.assert(id < self.registration_states.len);
        const state = &self.registration_states[id];
        std.debug.assert(state.generation == generation);
        std.debug.assert(state.callback_pins != 0);
        state.callback_pins -= 1;
        self.completePendingUnregister(id);
    }

    pub fn unregisterPending(self: *const Table, id: ClassId) bool {
        if (id >= self.registration_states.len) return false;
        return self.registration_states[id].unregister_pending;
    }

    pub fn isRegistered(self: Table, id: ClassId) bool {
        if (id >= self.records.len) return false;
        return self.records[id].isRegistered();
    }

    pub fn className(self: *Table, id: ClassId) ?atom.Atom {
        self.assertOwnerThread();
        if (!self.isRegistered(id)) return null;
        return self.atoms.dup(self.records[id].class_name);
    }

    pub fn findByName(self: *const Table, name: []const u8) ?ClassId {
        for (self.records) |rec| {
            if (!rec.isRegistered()) continue;
            const stored = self.atoms.name(rec.class_name) orelse continue;
            if (std.mem.eql(u8, stored, name)) return rec.id;
        }
        return null;
    }

    pub fn findByIdentity(self: *const Table, identity: []const u8) ?ClassId {
        for (self.records) |rec| {
            if (!rec.isRegistered()) continue;
            const stored = rec.binding_identity orelse continue;
            if (std.mem.eql(u8, stored, identity)) return rec.id;
        }
        return null;
    }

    pub fn record(self: *const Table, id: ClassId) ?Record {
        if (id >= self.records.len) return null;
        const rec = self.records[id];
        if (!rec.isRegistered()) return null;
        return rec;
    }

    /// Pointer-only view of a class record for no-GC/no-allocation/no-callback
    /// windows.
    /// qjs `JS_NewObjectFromShape` reads `ctx->rt->class_array[class_id]` fields
    /// in place (`.exotic`, ...) — it never materializes the whole `JSClass` on
    /// the stack. Mirror that: return `*const Record` so callers touch just the
    /// fields they need (payload_kind / payload_finalizer / exotic) via scalar
    /// loads instead of an 88B by-value SIMD block copy. Dynamic registration
    /// may move the complete table and unregister may clear a record, so this
    /// pointer is not a stable handle. Spanning callers use the scalar plan plus
    /// generation/pin APIs above.
    pub fn recordPtr(self: *const Table, id: ClassId) ?*const Record {
        if (id >= self.records.len) return null;
        const rec = &self.records[id];
        if (!rec.isRegistered()) return null;
        return rec;
    }

    pub fn runFinalizer(self: *Table, id: ClassId) bool {
        self.assertOwnerThread();
        const generation = self.pinCallback(id) orelse return false;
        defer self.releaseCallback(id, generation);
        const finalizer = (self.recordPtr(id) orelse return false).finalizer orelse return false;
        finalizer();
        return true;
    }

    pub fn runPayloadFinalizerForTest(
        self: *Table,
        id: ClassId,
        runtime: *anyopaque,
        object: *anyopaque,
        payload: *Payload,
    ) bool {
        self.assertOwnerThread();
        if (!builtin.is_test) @compileError("runPayloadFinalizerForTest is only available in tests");
        const generation = self.pinCallback(id) orelse return false;
        defer self.releaseCallback(id, generation);
        const finalizer = (self.recordPtr(id) orelse return false).payload_finalizer orelse return false;
        finalizer(runtime, object, payload);
        return true;
    }

    pub fn runPayloadFinalizer(
        self: *Table,
        id: ClassId,
        expected_generation: u64,
        runtime: *anyopaque,
        object: *anyopaque,
        payload: *Payload,
    ) bool {
        self.assertOwnerThread();
        const generation = self.pinCallback(id) orelse return false;
        defer self.releaseCallback(id, generation);
        if (id >= ids.init_count and generation != expected_generation) return false;
        const finalizer = (self.recordPtr(id) orelse return false).payload_finalizer orelse return false;
        finalizer(runtime, object, payload);
        return true;
    }

    pub fn markPayload(
        self: *Table,
        id: ClassId,
        runtime: *anyopaque,
        object: *anyopaque,
        payload: *Payload,
        visitor: *PayloadVisitor,
    ) bool {
        self.assertOwnerThread();
        const generation = self.pinCallback(id) orelse return false;
        defer self.releaseCallback(id, generation);
        const mark = (self.recordPtr(id) orelse return false).payload_mark orelse return false;
        mark(runtime, object, payload, visitor);
        return true;
    }

    fn registerAtom(self: *Table, id: ClassId, name_atom: atom.Atom, def: Definition) !void {
        try self.requireOwnerThread();
        if (id == invalid_class_id) return error.InvalidClassId;
        // `ClassId` is already u16, so 65535 is QuickJS's final legal id.
        // Widen before adding one to avoid wrapping the capacity bound.
        try self.ensureCapacity(@as(usize, id) + 1);
        if (self.records[id].isRegistered()) return error.DuplicateClass;
        const state = &self.registration_states[id];
        std.debug.assert(!state.isPinned());
        std.debug.assert(!state.unregister_pending);
        state.generation +%= 1;
        if (state.generation == 0) state.generation = 1;
        self.records[id] = .{
            .id = id,
            .class_name = self.atoms.dup(name_atom),
            .binding_identity = def.binding_identity,
            .binding_data = def.binding_data,
            .binding_data_finalizer = def.binding_data_finalizer,
            .payload_kind = def.payload_kind,
            .inline_payload_size = def.inline_payload_size,
            .inline_payload_align = def.inline_payload_align,
            .finalizer = def.finalizer,
            .payload_finalizer = def.payload_finalizer,
            .payload_mark = def.payload_mark,
            .call = def.call,
            .has_exotic = def.has_exotic or def.exotic_methods != null,
            .exotic_methods = def.exotic_methods,
        };
    }

    fn ensureCapacity(self: *Table, needed: usize) !void {
        try self.requireOwnerThread();
        if (needed <= self.records.len) return;
        var new_len = if (self.records.len == 0) @as(usize, ids.init_count) else self.records.len + self.records.len / 2;
        if (new_len < needed) new_len = needed;

        const next = try self.memory.alloc(Record, new_len);
        errdefer self.memory.free(Record, next);
        const next_states = try self.memory.alloc(RegistrationState, new_len);
        errdefer self.memory.free(RegistrationState, next_states);
        @memset(next, .{});
        @memset(next_states, .{});
        const old_records = self.records;
        const old_states = self.registration_states;
        if (old_records.len != 0) @memcpy(next[0..old_records.len], old_records);
        if (old_states.len != 0) @memcpy(next_states[0..old_states.len], old_states);
        const old_using_inline = self.usingInlineRecords();
        const old_states_using_inline = self.usingInlineRegistrationStates();
        self.records = next;
        self.registration_states = next_states;
        if (old_using_inline) {
            @memset(old_records, .{});
        } else if (old_records.len != 0) {
            self.memory.free(Record, old_records);
        }
        if (old_states_using_inline) {
            @memset(old_states, .{});
        } else if (old_states.len != 0) {
            self.memory.free(RegistrationState, old_states);
        }
    }

    fn definitionPlan(definition_view: ?*const Record, id: ClassId, generation: u64) DefinitionPlan {
        if (definition_view) |registered| {
            return .{
                .generation = generation,
                .payload_kind = registered.payload_kind,
                .inline_payload_size = registered.inline_payload_size,
                .inline_payload_align = registered.inline_payload_align,
                .has_payload_finalizer = registered.payload_finalizer != null,
                .has_exotic = registered.has_exotic or registered.exotic_methods != null,
            };
        }
        return .{
            .generation = generation,
            .payload_kind = standardPayloadKind(id),
        };
    }

    fn pinCallback(self: *Table, id: ClassId) ?u64 {
        _ = self.recordPtr(id) orelse return null;
        if (id < ids.init_count) return self.registration_states[id].generation;
        const state = &self.registration_states[id];
        state.callback_pins += 1;
        return state.generation;
    }

    fn releaseCallback(self: *Table, id: ClassId, generation: u64) void {
        if (id < ids.init_count) return;
        const state = &self.registration_states[id];
        std.debug.assert(state.generation == generation);
        std.debug.assert(state.callback_pins != 0);
        state.callback_pins -= 1;
        self.completePendingUnregister(id);
    }

    fn completePendingUnregister(self: *Table, id: ClassId) void {
        if (id < ids.init_count or id >= self.records.len) return;
        const state = &self.registration_states[id];
        if (!state.unregister_pending or state.isPinned()) return;
        const old_definition = self.records[id];
        std.debug.assert(old_definition.isRegistered());
        self.records[id] = .{};
        state.unregister_pending = false;
        // Publish the empty slot before invoking/freeing definition-owned data:
        // reentrant registration never observes a half-cleared old definition.
        old_definition.finalizeBindingData();
        self.atoms.free(old_definition.class_name);
    }
};

const StandardClass = struct {
    id: ClassId,
    name_atom: atom.Atom,
};

pub const standard_classes = [_]StandardClass{
    .{ .id = ids.object, .name_atom = atom.ids.Object },
    .{ .id = ids.array, .name_atom = atom.ids.Array },
    .{ .id = ids.error_, .name_atom = atom.ids.Error },
    .{ .id = ids.number, .name_atom = atom.predefinedId("Number", .string).? },
    .{ .id = ids.string, .name_atom = atom.predefinedId("String", .string).? },
    .{ .id = ids.boolean, .name_atom = atom.predefinedId("Boolean", .string).? },
    .{ .id = ids.symbol, .name_atom = atom.predefinedId("Symbol", .string).? },
    .{ .id = ids.arguments, .name_atom = atom.predefinedId("Arguments", .string).? },
    .{ .id = ids.mapped_arguments, .name_atom = atom.predefinedId("Arguments", .string).? },
    .{ .id = ids.date, .name_atom = atom.predefinedId("Date", .string).? },
    .{ .id = ids.module_ns, .name_atom = atom.ids.Object },
    .{ .id = ids.c_function, .name_atom = atom.ids.Function },
    .{ .id = ids.bytecode_function, .name_atom = atom.ids.Function },
    .{ .id = ids.bound_function, .name_atom = atom.ids.Function },
    .{ .id = ids.c_function_data, .name_atom = atom.ids.Function },
    .{ .id = ids.c_closure, .name_atom = atom.ids.Function },
    .{ .id = ids.generator_function, .name_atom = atom.predefinedId("GeneratorFunction", .string).? },
    .{ .id = ids.for_in_iterator, .name_atom = atom.predefinedId("ForInIterator", .string).? },
    .{ .id = ids.regexp, .name_atom = atom.predefinedId("RegExp", .string).? },
    .{ .id = ids.array_buffer, .name_atom = atom.predefinedId("ArrayBuffer", .string).? },
    .{ .id = ids.shared_array_buffer, .name_atom = atom.predefinedId("SharedArrayBuffer", .string).? },
    .{ .id = ids.uint8c_array, .name_atom = atom.predefinedId("Uint8ClampedArray", .string).? },
    .{ .id = ids.int8_array, .name_atom = atom.predefinedId("Int8Array", .string).? },
    .{ .id = ids.uint8_array, .name_atom = atom.predefinedId("Uint8Array", .string).? },
    .{ .id = ids.int16_array, .name_atom = atom.predefinedId("Int16Array", .string).? },
    .{ .id = ids.uint16_array, .name_atom = atom.predefinedId("Uint16Array", .string).? },
    .{ .id = ids.int32_array, .name_atom = atom.predefinedId("Int32Array", .string).? },
    .{ .id = ids.uint32_array, .name_atom = atom.predefinedId("Uint32Array", .string).? },
    .{ .id = ids.big_int64_array, .name_atom = atom.predefinedId("BigInt64Array", .string).? },
    .{ .id = ids.big_uint64_array, .name_atom = atom.predefinedId("BigUint64Array", .string).? },
    .{ .id = ids.float16_array, .name_atom = atom.predefinedId("Float16Array", .string).? },
    .{ .id = ids.float32_array, .name_atom = atom.predefinedId("Float32Array", .string).? },
    .{ .id = ids.float64_array, .name_atom = atom.predefinedId("Float64Array", .string).? },
    .{ .id = ids.dataview, .name_atom = atom.predefinedId("DataView", .string).? },
    .{ .id = ids.big_int, .name_atom = atom.predefinedId("BigInt", .string).? },
    .{ .id = ids.map, .name_atom = atom.ids.Map },
    .{ .id = ids.set, .name_atom = atom.ids.Set },
    .{ .id = ids.weakmap, .name_atom = atom.ids.WeakMap },
    .{ .id = ids.weakset, .name_atom = atom.ids.WeakSet },
    .{ .id = ids.iterator, .name_atom = atom.predefinedId("Iterator", .string).? },
    .{ .id = ids.iterator_concat, .name_atom = atom.predefinedId("Iterator Concat", .string).? },
    .{ .id = ids.iterator_helper, .name_atom = atom.predefinedId("Iterator Helper", .string).? },
    .{ .id = ids.iterator_wrap, .name_atom = atom.predefinedId("Iterator Wrap", .string).? },
    .{ .id = ids.map_iterator, .name_atom = atom.predefinedId("Map Iterator", .string).? },
    .{ .id = ids.set_iterator, .name_atom = atom.predefinedId("Set Iterator", .string).? },
    .{ .id = ids.array_iterator, .name_atom = atom.predefinedId("Array Iterator", .string).? },
    .{ .id = ids.string_iterator, .name_atom = atom.predefinedId("String Iterator", .string).? },
    .{ .id = ids.regexp_string_iterator, .name_atom = atom.predefinedId("RegExp String Iterator", .string).? },
    .{ .id = ids.generator, .name_atom = atom.predefinedId("Generator", .string).? },
};

pub fn standardPayloadKind(id: ClassId) PayloadKind {
    return switch (id) {
        ids.object,
        ids.error_,
        ids.dom_exception,
        ids.call_site,
        ids.raw_json,
        => .ordinary,
        ids.global_object => .global,
        ids.std_file => .std_file,
        ids.disposable_stack, ids.async_disposable_stack => .disposable_stack,

        ids.array => .none,
        ids.arguments, ids.mapped_arguments => .ordinary,
        ids.number, ids.string, ids.boolean, ids.symbol, ids.date, ids.big_int => .object_data,
        ids.module_ns => .none,
        ids.c_function,
        ids.bytecode_function,
        ids.c_function_data,
        ids.c_closure,
        ids.generator_function,
        ids.async_function,
        ids.async_generator_function,
        ids.async_function_resolve,
        ids.async_function_reject,
        => .function,
        ids.bound_function => .bound_function,
        ids.for_in_iterator,
        ids.iterator,
        ids.iterator_concat,
        ids.iterator_helper,
        ids.iterator_wrap,
        ids.map_iterator,
        ids.set_iterator,
        ids.array_iterator,
        ids.string_iterator,
        ids.regexp_string_iterator,
        ids.async_from_sync_iterator,
        => .iterator,
        ids.regexp => .regexp,
        ids.array_buffer, ids.shared_array_buffer => .buffer,
        ids.uint8c_array,
        ids.int8_array,
        ids.uint8_array,
        ids.int16_array,
        ids.uint16_array,
        ids.int32_array,
        ids.uint32_array,
        ids.big_int64_array,
        ids.big_uint64_array,
        ids.float16_array,
        ids.float32_array,
        ids.float64_array,
        ids.dataview,
        => .typed_array,
        ids.map, ids.set, ids.weakmap, ids.weakset => .collection,
        ids.generator, ids.async_generator => .generator,
        ids.proxy => .proxy,
        ids.promise, ids.promise_resolve_function, ids.promise_reject_function => .promise,
        ids.weak_ref => .weak_ref,
        ids.finalization_registry => .finalization_registry,
        else => .none,
    };
}

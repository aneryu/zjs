//! JavaScript class identities, runtime-local definitions, and builtin taxonomy.
//!
//! Dynamic class ids and immutable definitions belong to one Runtime.
//! Published ids are never reused; definitions live until Runtime teardown. Finalizer/mark callbacks therefore receive runtime-owned
//! objects but do not own the id itself. The builtin id matrix and payload-kind
//! mapping are load-bearing for ObjectStorage dispatch. This is core metadata:
//! exec/binding register and consume classes through it, while it must not
//! import either higher layer.

const std = @import("std");
const context_registry = @import("context_registry.zig");
const atom = @import("atom.zig");
const builtin = @import("builtin");

comptime {
    @setEvalBranchQuota(5000);
}

pub const ClassId = u16;
pub const invalid_class_id: ClassId = 0;
pub const MutationError = error{WrongRuntimeThread};

/// A definition is meaningful only in its registering Runtime.
pub const Binding = struct {
    owner: *@import("../runtime.zig").JSRuntime,
    id: ClassId,
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
    /// Retired synthetic-callable class; id 16 is a reserved hole.
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
    /// Reserved legacy slot. DOMException belongs to the embedding host.
    pub const reserved_62: ClassId = 62;
    pub const call_site: ClassId = 63;
    pub const raw_json: ClassId = 64;
    /// Reserved legacy slot. File handles belong to the embedding host.
    pub const reserved_65: ClassId = 65;
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
    disposable_stack,
    global,
    realm_record,
    weak_ref,
    promise_reaction_record,
};

pub const Payload = ?*anyopaque;

/// Numeric TypedArray classes whose `[i]` read is allocation-free
/// (qjs JS_GetPropertyValue INT8..FLOAT64 arms). BigInt64/BigUint64
/// and DataView stay off this predicate so they keep the allocating path.
pub inline fn isNumericTypedArrayClass(id: ClassId) bool {
    return switch (id) {
        ids.uint8c_array,
        ids.int8_array,
        ids.uint8_array,
        ids.int16_array,
        ids.uint16_array,
        ids.int32_array,
        ids.uint32_array,
        ids.float16_array,
        ids.float32_array,
        ids.float64_array,
        => true,
        else => false,
    };
}

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

/// Internal Await reaction handlers, with one continuation edge in Object.u.
pub inline fn isAsyncFunctionResumeClass(id: ClassId) bool {
    return id == ids.async_function_resolve or id == ids.async_function_reject;
}

/// Every function object class: native, native-with-data, bytecode, bound,
/// and the internal Await reaction handlers. Proxies are not included.
pub inline fn isFunctionClass(id: ClassId) bool {
    return id == ids.c_function or
        id == ids.c_function_data or
        id == ids.bound_function or
        isBytecodeFunctionClass(id) or
        isAsyncFunctionResumeClass(id);
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

pub const PayloadFinalizer = *const fn (runtime: *anyopaque, object: *anyopaque, payload: *Payload) void;
pub const PayloadMark = *const fn (runtime: *anyopaque, object: *anyopaque, payload: *Payload, visitor: *PayloadVisitor) void;
pub const BindingDataFinalizer = *const fn (data: *anyopaque) void;

pub const Definition = struct {
    class_name: []const u8,
    binding_data: ?*anyopaque = null,
    binding_data_finalizer: ?BindingDataFinalizer = null,
    payload_kind: PayloadKind = .none,
    inline_payload_size: u32 = 0,
    inline_payload_align: u16 = 1,
    payload_finalizer: ?PayloadFinalizer = null,
    payload_mark: ?PayloadMark = null,
    has_exotic: bool = false,
    exotic_methods: ?*const anyopaque = null,
    /// NB2 §8.1: set iff this class is a `NativeObject` family member; the
    /// pointer is the runtime-owned `native_object.NativeType` (opaque here so
    /// class metadata stays below the object layer). Instances keep `self` in
    /// the payload arm word and `nativeSelf` reads it after one class check.
    native_type: ?*const anyopaque = null,
};

pub const Record = struct {
    id: ClassId = invalid_class_id,
    class_name: atom.Atom = atom.null_atom,
    /// Copy of the registration definition. `has_exotic` is normalized once
    /// in `registerAtom` (`def.has_exotic or def.exotic_methods != null`).
    def: Definition = .{ .class_name = "" },

    pub fn isRegistered(self: Record) bool {
        return self.id != invalid_class_id;
    }

    pub fn finalizeBindingData(self: Record) void {
        const data = self.def.binding_data orelse return;
        const finalizer = self.def.binding_data_finalizer orelse return;
        finalizer(data);
    }
};

/// An unregistered record is the zero pattern plus `def.inline_payload_align
/// = 1`. `Record{}` also points `def.class_name` at `""`; nothing reads that
/// slice until `registerAtom` replaces `def`, and a zero pointer with length
/// 0 is the same empty name. Filling `[ids.init_count]Record` from `Record{}`
/// would emit a `.rodata` image of `@sizeOf(Record) * ids.init_count`.
fn fillDefaultRecords(records: []Record) void {
    @memset(records, std.mem.zeroes(Record));
    for (records) |*rec| {
        rec.def.inline_payload_align = 1;
    }
}

/// Mutable lifetime state lives beside the immutable class definition. A
/// `Record *` is only a transient table view: growing `Table.records` may move
/// every record, while this state is always reacquired by class id.
const RegistrationState = struct {
    generation: u64 = 0,
    construction_pins: usize = 0,
    live_object_pins: usize = 0,
    callback_pins: usize = 0,

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
            // Other class registrations may move the table, so reacquire by id
            // and validate the generation before publication.
            const record_view = self.table.recordPtr(self.class_id).?;
            std.debug.assert(state.generation == self.definition.generation);
            std.debug.assert(record_view.id == self.class_id);
            std.debug.assert(state.construction_pins != 0);
            state.construction_pins -= 1;
            state.live_object_pins += 1;
            self.dynamic_pin_active = false;
        }

        /// Release an unpublished construction view. Callers declare this
        /// before their prepared-resource errdefers to keep lifetime checks paired.
        pub fn abort(self: *Construction) void {
            self.table.assertOwnerThread();
            if (!self.dynamic_pin_active) return;
            const state = &self.table.registration_states[self.class_id];
            std.debug.assert(state.generation == self.definition.generation);
            std.debug.assert(state.construction_pins != 0);
            state.construction_pins -= 1;
            self.dynamic_pin_active = false;
        }
    };

    atoms: *atom.AtomTable,
    storage_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
    owner_thread_id: std.Thread.Id,
    next_dynamic_id: u32 = ids.init_count,
    records: []Record = &.{},
    records_inline: [ids.init_count]Record = @splat(.{}),
    registration_states: []RegistrationState = &.{},
    registration_states_inline: [ids.init_count]RegistrationState = @splat(.{}),
    /// Registration-time cache of every standard id's immutable DefinitionPlan.
    /// Standard classes are runtime-lifetime, so `registerAtom` writes each entry at most once
    /// and every allocation/destruction reads one indexed struct instead of the
    /// recordPtr + per-field load chain — mirroring how qjs reads its immutable
    /// `rt->class_array` scalars with no per-alloc bookkeeping. Ids below
    /// `ids.proxy` are registered from `standard_meta`. Later standard ids stay
    /// unregistered, so their plans remain the `standardPayloadKind` fallback.
    standard_plans: [ids.init_count]DefinitionPlan = undefined,

    /// Create the owned class table, including standard definitions, without
    /// reading Runtime storage. Borrows atoms and storage_allocator; caller
    /// releases with destroy. Dynamic definitions receive their owner explicitly.
    pub fn create(allocator: std.mem.Allocator, storage_allocator: std.mem.Allocator, atoms: *atom.AtomTable) !*Table {
        const self = try allocator.create(Table);
        self.* = .{
            .allocator = allocator,
            .storage_allocator = storage_allocator,
            .owner_thread_id = std.Thread.getCurrentId(),
            .atoms = atoms,
            .records_inline = undefined,
            .standard_plans = undefined,
        };
        fillStandardPlanFallbacks(&self.standard_plans);
        self.records = self.records_inline[0..ids.init_count];
        self.registration_states = self.registration_states_inline[0..ids.init_count];
        fillDefaultRecords(self.records);
        @memset(self.registration_states, .{});
        errdefer self.destroy();
        try self.registerStandardClasses();
        return self;
    }

    pub fn destroy(self: *Table) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    /// Reserve before any allocation or callback. Failed ids remain consumed.
    pub fn registerDefinition(self: *Table, rt: *@import("../runtime.zig").JSRuntime, definition: Definition) !Binding {
        try self.requireOwnerThread();
        if (rt.classes != self) return error.WrongRuntime;
        if (self.next_dynamic_id > std.math.maxInt(ClassId)) return error.ClassIdExhausted;
        const id: ClassId = @intCast(self.next_dynamic_id);
        self.next_dynamic_id += 1;
        try context_registry.ensureClassPrototypeCapacity(rt, id);
        try self.register(id, definition);
        return .{ .owner = rt, .id = id };
    }

    fn registerStandardClasses(self: *Table) !void {
        for (standard_meta[1..ids.proxy], 1..) |meta, id| {
            try self.registerAtom(@intCast(id), meta.name, .{
                .class_name = "",
                .payload_kind = meta.kind,
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

    /// ReleaseFast compiles this to a no-op: the body is an explicit `@panic`,
    /// not `std.debug.assert`, so it used to survive `-Dzjs_ownership_audit=off`
    /// production builds (that flag only gates atom-slot quarantine). The
    /// gettid TLS probe then showed up on every GC `markPayload` and on
    /// mutation tails. ReleaseSafe/Debug keep the panic. `noinline` on the
    /// checked arm still stops LLVM hoisting gettid above a standard-id
    /// early-out (releaseObjectDefinition).
    pub inline fn assertOwnerThread(self: *const Table) void {
        if (comptime !std.debug.runtime_safety) return;
        assertOwnerThreadChecked(self);
    }

    noinline fn assertOwnerThreadChecked(self: *const Table) void {
        if (!self.isOwnerThread()) @panic("class table mutation from non-owner Runtime thread");
    }

    pub fn deinit(self: *Table) void {
        // `create` rolls its own records back before the caller observes
        // the error. A second deinit from a later errdefer must not free them
        // again. An untouched table is not empty; only a completed deinit is.
        if (self.records.len == 0 and self.registration_states.len == 0) return;
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
            }
        }
        for (registration_states) |state| std.debug.assert(!state.isPinned());
        if (using_inline) {
            fillDefaultRecords(records);
        } else if (records.len != 0) {
            self.storage_allocator.free(records);
        }
        if (using_inline_states) {
            @memset(registration_states, .{});
        } else if (registration_states.len != 0) {
            self.storage_allocator.free(registration_states);
        }
    }

    fn register(self: *Table, id: ClassId, def: Definition) !void {
        try self.requireOwnerThread();
        // TGC S3 §4 class B: `name_atom` is a bare id and this file sits below
        // runtime.zig, so it cannot name an `AtomRootFrame`. Grow the record
        // table first instead -- then the only allocation left between the
        // intern and `registerAtom`'s store is gone and the id spans no collection
        // point at all. `registerAtom` re-checks both, idempotently.
        if (id == invalid_class_id) return error.InvalidClassId;
        try self.ensureCapacity(@as(usize, id) + 1);
        const name_atom = try self.atoms.internString(def.class_name);
        try self.registerAtom(id, name_atom, def);
    }

    /// Snapshot the immutable scalars required during construction and pin a
    /// dynamic definition. Standard definitions are runtime-lifetime and avoid
    /// the counter traffic entirely.
    pub fn beginConstruction(self: *Table, id: ClassId) error{InvalidClassId}!Construction {
        if (id < ids.init_count) return self.beginStandardConstruction(id);
        self.assertOwnerThread();
        if (id >= self.records.len or !self.records[id].isRegistered()) return error.InvalidClassId;
        const definition_view = self.recordPtr(id).?;
        const state = &self.registration_states[id];
        // Definitions are immutable until teardown; pins still verify that
        // construction, object release and deferred callbacks are balanced.
        state.construction_pins += 1;
        return .{
            .table = self,
            .class_id = id,
            .definition = definitionPlan(definition_view, id, state.generation),
            .dynamic_pin_active = true,
        };
    }

    /// Standard-id construction: runtime-lifetime definitions have no failure
    /// path and no pin traffic — the registration-time plan cache is the whole
    /// read (qjs js_create_object reads rt->class_array scalars the same way).
    pub fn beginStandardConstruction(self: *Table, id: ClassId) Construction {
        self.assertOwnerThread();
        return .{
            .table = self,
            .class_id = id,
            .definition = self.standardPlan(id),
            .dynamic_pin_active = false,
        };
    }

    /// By-value plan read for a standard id. Callers that never pin (standard
    /// construction and destruction) use this directly so no `Construction`
    /// address ever escapes into a defer — the plan stays register-resident.
    pub fn standardPlan(self: *const Table, id: ClassId) DefinitionPlan {
        std.debug.assert(id < ids.init_count);
        return self.standard_plans[id];
    }

    /// Reacquire the immutable destruction scalars for an object without
    /// retaining a pointer across cleanup or finalizer callbacks.
    pub fn destructionPlan(self: *const Table, id: ClassId) ?DefinitionPlan {
        if (id < ids.init_count) return self.standard_plans[id];
        if (id >= self.records.len) return null;
        const state = self.registration_states[id];
        if (state.live_object_pins == 0) return null;
        return definitionPlan(self.recordPtr(id) orelse return null, id, state.generation);
    }

    /// Release a dynamic object's definition pin only after its allocation is
    /// gone (including weak-husk and cycle pass-B lifetimes).
    pub fn releaseObjectDefinition(self: *Table, id: ClassId, generation: u64) void {
        // Standard ids carry no pin bookkeeping, so return before touching
        // registration state. `assertOwnerThread` is a no-op in ReleaseFast
        // (`!std.debug.runtime_safety`); Debug and ReleaseSafe still pay the
        // gettid probe on this tail. qjs free_object has no thread check.
        if (id < ids.init_count) return;
        self.assertOwnerThread();
        std.debug.assert(id < self.registration_states.len);
        const state = &self.registration_states[id];
        std.debug.assert(state.generation == generation);
        std.debug.assert(state.live_object_pins != 0);
        state.live_object_pins -= 1;
    }

    pub fn isRegistered(self: Table, id: ClassId) bool {
        if (id >= self.records.len) return false;
        return self.records[id].isRegistered();
    }

    pub fn className(self: *Table, id: ClassId) ?atom.Atom {
        self.assertOwnerThread();
        if (self.isRegistered(id)) return self.records[id].class_name;
        // Unregistered standard ids (50-68) still have inspector names. The
        // only caller is the host printer; it does not treat null as special
        // beyond printing `<null>`.
        if (id < ids.init_count) {
            const name = standard_meta[id].name;
            if (name != atom.null_atom) return name;
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
    /// may move the complete table, so this
    /// pointer is not a stable handle. Spanning callers use the scalar plan plus
    /// generation/pin APIs above.
    pub fn recordPtr(self: *const Table, id: ClassId) ?*const Record {
        if (id >= self.records.len) return null;
        const rec = &self.records[id];
        if (!rec.isRegistered()) return null;
        return rec;
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
        const finalizer = (self.recordPtr(id) orelse return false).def.payload_finalizer orelse return false;
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
        // Parallel GC workers may inspect immutable class records while the
        // mutator is stopped. Almost every standard object has no embedder
        // payload marker, so reject that common case before entering the
        // owner-only callback pin protocol (and before looking the record up a
        // second time). A real callback remains owner-affine and pinned across
        // invocation exactly as before.
        const mark = (self.recordPtr(id) orelse return false).def.payload_mark orelse return false;
        self.assertOwnerThread();
        const generation = self.pinCallback(id) orelse return false;
        defer self.releaseCallback(id, generation);
        const rt: *@import("../runtime.zig").JSRuntime = @ptrCast(@alignCast(runtime));
        rt.roots.beginTrace();
        defer rt.roots.endTrace();
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
        state.generation +%= 1;
        if (state.generation == 0) state.generation = 1;
        var stored = def;
        stored.has_exotic = def.has_exotic or def.exotic_methods != null;
        self.records[id] = .{
            .id = id,
            .class_name = self.atoms.noteHolderStore(name_atom),
            .def = stored,
        };
        if (id < ids.init_count) {
            self.standard_plans[id] = definitionPlan(&self.records[id], id, state.generation);
        }
    }

    fn ensureCapacity(self: *Table, needed: usize) !void {
        try self.requireOwnerThread();
        if (needed <= self.records.len) return;
        var new_len = if (self.records.len == 0) @as(usize, ids.init_count) else self.records.len + self.records.len / 2;
        if (new_len < needed) new_len = needed;

        const next = try self.storage_allocator.alloc(Record, new_len);
        errdefer self.storage_allocator.free(next);
        const next_states = try self.storage_allocator.alloc(RegistrationState, new_len);
        errdefer self.storage_allocator.free(next_states);
        // Allocation callbacks may have completed a nested registration.
        // Its larger published table wins; never overwrite it with this stale capacity.
        if (self.records.len >= needed) {
            self.storage_allocator.free(next_states);
            self.storage_allocator.free(next);
            return;
        }
        fillDefaultRecords(next);
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
            fillDefaultRecords(old_records);
        } else if (old_records.len != 0) {
            self.storage_allocator.free(old_records);
        }
        if (old_states_using_inline) {
            @memset(old_states, .{});
        } else if (old_states.len != 0) {
            self.storage_allocator.free(old_states);
        }
    }

    fn fillStandardPlanFallbacks(plans: *[ids.init_count]DefinitionPlan) void {
        for (plans, 0..) |*plan, id| {
            plan.* = .{ .payload_kind = standardPayloadKind(@intCast(id)) };
        }
    }

    fn definitionPlan(definition_view: ?*const Record, id: ClassId, generation: u64) DefinitionPlan {
        if (definition_view) |registered| {
            const stored = registered.def;
            return .{
                .generation = generation,
                .payload_kind = stored.payload_kind,
                .inline_payload_size = stored.inline_payload_size,
                .inline_payload_align = stored.inline_payload_align,
                .has_payload_finalizer = stored.payload_finalizer != null,
                // Already `has_exotic or exotic_methods != null` from registerAtom.
                .has_exotic = stored.has_exotic,
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
    }
};

fn standardName(comptime bytes: []const u8) atom.Atom {
    return atom.predefinedId(bytes, .string) orelse @compileError("no predefined class atom: " ++ bytes);
}

const StandardMeta = struct {
    name: atom.Atom,
    /// Inspector text for a standard id that has no predefined atom.
    literal: ?[]const u8,
    kind: PayloadKind,
};

const standard_meta: [ids.init_count]StandardMeta = blk: {
    const Item = struct {
        id: ClassId,
        name: atom.Atom = atom.null_atom,
        literal: ?[]const u8 = null,
        kind: PayloadKind,
    };
    const items = [_]Item{
        .{ .id = invalid_class_id, .kind = .none },
        .{ .id = ids.object, .name = atom.ids.Object, .kind = .ordinary },
        .{ .id = ids.array, .name = atom.ids.Array, .kind = .none },
        .{ .id = ids.error_, .name = atom.ids.Error, .kind = .ordinary },
        .{ .id = ids.number, .name = standardName("Number"), .kind = .object_data },
        .{ .id = ids.string, .name = standardName("String"), .kind = .object_data },
        .{ .id = ids.boolean, .name = standardName("Boolean"), .kind = .object_data },
        .{ .id = ids.symbol, .name = standardName("Symbol"), .kind = .object_data },
        .{ .id = ids.arguments, .name = standardName("Arguments"), .kind = .ordinary },
        .{ .id = ids.mapped_arguments, .name = standardName("Arguments"), .kind = .ordinary },
        .{ .id = ids.date, .name = standardName("Date"), .kind = .object_data },
        .{ .id = ids.module_ns, .name = atom.ids.Object, .kind = .none },
        .{ .id = ids.c_function, .name = atom.ids.Function, .kind = .function },
        .{ .id = ids.bytecode_function, .name = atom.ids.Function, .kind = .function },
        .{ .id = ids.bound_function, .name = atom.ids.Function, .kind = .bound_function },
        .{ .id = ids.c_function_data, .name = atom.ids.Function, .kind = .function },
        .{ .id = ids.c_closure, .name = atom.ids.Function, .kind = .function },
        .{ .id = ids.generator_function, .name = standardName("GeneratorFunction"), .kind = .function },
        .{ .id = ids.for_in_iterator, .name = standardName("ForInIterator"), .kind = .iterator },
        .{ .id = ids.regexp, .name = standardName("RegExp"), .kind = .regexp },
        .{ .id = ids.array_buffer, .name = standardName("ArrayBuffer"), .kind = .buffer },
        .{ .id = ids.shared_array_buffer, .name = standardName("SharedArrayBuffer"), .kind = .buffer },
        .{ .id = ids.uint8c_array, .name = standardName("Uint8ClampedArray"), .kind = .typed_array },
        .{ .id = ids.int8_array, .name = standardName("Int8Array"), .kind = .typed_array },
        .{ .id = ids.uint8_array, .name = standardName("Uint8Array"), .kind = .typed_array },
        .{ .id = ids.int16_array, .name = standardName("Int16Array"), .kind = .typed_array },
        .{ .id = ids.uint16_array, .name = standardName("Uint16Array"), .kind = .typed_array },
        .{ .id = ids.int32_array, .name = standardName("Int32Array"), .kind = .typed_array },
        .{ .id = ids.uint32_array, .name = standardName("Uint32Array"), .kind = .typed_array },
        .{ .id = ids.big_int64_array, .name = standardName("BigInt64Array"), .kind = .typed_array },
        .{ .id = ids.big_uint64_array, .name = standardName("BigUint64Array"), .kind = .typed_array },
        .{ .id = ids.float16_array, .name = standardName("Float16Array"), .kind = .typed_array },
        .{ .id = ids.float32_array, .name = standardName("Float32Array"), .kind = .typed_array },
        .{ .id = ids.float64_array, .name = standardName("Float64Array"), .kind = .typed_array },
        .{ .id = ids.dataview, .name = standardName("DataView"), .kind = .typed_array },
        .{ .id = ids.big_int, .name = standardName("BigInt"), .kind = .object_data },
        .{ .id = ids.map, .name = atom.ids.Map, .kind = .collection },
        .{ .id = ids.set, .name = atom.ids.Set, .kind = .collection },
        .{ .id = ids.weakmap, .name = atom.ids.WeakMap, .kind = .collection },
        .{ .id = ids.weakset, .name = atom.ids.WeakSet, .kind = .collection },
        .{ .id = ids.iterator, .name = standardName("Iterator"), .kind = .iterator },
        .{ .id = ids.iterator_concat, .name = standardName("Iterator Concat"), .kind = .iterator },
        .{ .id = ids.iterator_helper, .name = standardName("Iterator Helper"), .kind = .iterator },
        .{ .id = ids.iterator_wrap, .name = standardName("Iterator Wrap"), .kind = .iterator },
        .{ .id = ids.map_iterator, .name = standardName("Map Iterator"), .kind = .iterator },
        .{ .id = ids.set_iterator, .name = standardName("Set Iterator"), .kind = .iterator },
        .{ .id = ids.array_iterator, .name = standardName("Array Iterator"), .kind = .iterator },
        .{ .id = ids.string_iterator, .name = standardName("String Iterator"), .kind = .iterator },
        .{ .id = ids.regexp_string_iterator, .name = standardName("RegExp String Iterator"), .kind = .iterator },
        .{ .id = ids.generator, .name = standardName("Generator"), .kind = .generator },
        .{ .id = ids.proxy, .name = atom.ids.Object, .kind = .proxy },
        .{ .id = ids.promise, .name = standardName("Promise"), .kind = .promise },
        .{ .id = ids.promise_resolve_function, .name = standardName("PromiseResolveFunction"), .kind = .promise },
        .{ .id = ids.promise_reject_function, .name = standardName("PromiseRejectFunction"), .kind = .promise },
        .{ .id = ids.async_function, .name = standardName("AsyncFunction"), .kind = .function },
        .{ .id = ids.async_function_resolve, .name = standardName("AsyncFunctionResolve"), .kind = .none },
        .{ .id = ids.async_function_reject, .name = standardName("AsyncFunctionReject"), .kind = .none },
        .{ .id = ids.async_from_sync_iterator, .name = standardName(""), .kind = .iterator },
        .{ .id = ids.async_generator_function, .name = standardName("AsyncGeneratorFunction"), .kind = .function },
        .{ .id = ids.async_generator, .name = standardName("AsyncGenerator"), .kind = .generator },
        .{ .id = ids.weak_ref, .name = standardName("WeakRef"), .kind = .weak_ref },
        .{ .id = ids.finalization_registry, .name = standardName("FinalizationRegistry"), .kind = .finalization_registry },
        .{ .id = ids.reserved_62, .kind = .none },
        .{ .id = ids.call_site, .name = standardName("CallSite"), .kind = .ordinary },
        .{ .id = ids.raw_json, .literal = "RawJSON", .kind = .ordinary },
        .{ .id = ids.reserved_65, .kind = .none },
        .{ .id = ids.disposable_stack, .name = standardName("DisposableStack"), .kind = .disposable_stack },
        .{ .id = ids.async_disposable_stack, .name = standardName("AsyncDisposableStack"), .kind = .disposable_stack },
        .{ .id = ids.global_object, .name = atom.ids.Object, .kind = .global },
    };
    var table: [ids.init_count]StandardMeta = undefined;
    var seen = [_]bool{false} ** ids.init_count;
    for (items) |item| {
        if (seen[item.id]) @compileError(std.fmt.comptimePrint("duplicate standard class id {d}", .{item.id}));
        seen[item.id] = true;
        table[item.id] = .{ .name = item.name, .literal = item.literal, .kind = item.kind };
    }
    for (seen, 0..) |present, index| {
        if (!present) @compileError(std.fmt.comptimePrint("missing standard class id {d}", .{index}));
    }
    for (table[1..ids.proxy]) |meta| {
        if (meta.name == atom.null_atom) @compileError("ids below proxy require a class name");
    }
    break :blk table;
};

pub fn standardPayloadKind(id: ClassId) PayloadKind {
    if (id >= ids.init_count) return .none;
    return standard_meta[id].kind;
}

pub fn standardLiteralName(id: ClassId) ?[]const u8 {
    if (id >= ids.init_count) return null;
    return standard_meta[id].literal;
}

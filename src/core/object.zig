//! QuickJS-shaped object model. Out-of-line payload representations and
//! generator suspension storage live in `object_payloads.zig` and
//! `generator_state.zig`; their public names are re-exported here so existing
//! users retain one object-model namespace. `Object` is a 24-byte head
//! `extern struct` (`ObjectGcToken` is size 0); class data trails the head.
//! For property behavior start at
//! `shape.zig` and `property.zig`, then the call site in `src/exec/`.

const array = @import("array.zig");
const atom = @import("atom.zig");
const class = @import("class.zig");
const context_mod = @import("context.zig");
const errors = @import("errors.zig");
const value_format = @import("value_format.zig");
const descriptor = @import("descriptor.zig");
const function = @import("function.zig");
const gc = @import("gc.zig");
const gc_block_heap = @import("gc_block_heap.zig");
const host_function = @import("host_function.zig");
const module_mod = @import("module.zig");
const object_gc = @import("object_gc.zig");
const object_payloads = @import("object_payloads.zig");
const property = @import("property.zig");
const profile = @import("profile.zig");
const runtime_mod = @import("runtime.zig");
const shape = @import("shape.zig");
const string = @import("string.zig");
const var_ref_mod = @import("var_ref.zig");
const generator_state = @import("generator_state.zig");
const JSRuntime = runtime_mod.JSRuntime;
const JSValue = @import("value.zig").JSValue;
const function_bytecode_mod = @import("../bytecode.zig").function_bytecode;
const FunctionBytecode = function_bytecode_mod.FunctionBytecode;
const memory_mod = @import("memory.zig");
const std = @import("std");
const builtin = @import("builtin");

const ObjectVisitSet = std.AutoHashMap(usize, void);
const ObjectIncomingMap = std.AutoHashMap(usize, usize);
const ObjectGraphError = std.mem.Allocator.Error || error{PayloadMarkFailed};
const OwnKeysError = std.mem.Allocator.Error;
const PropertyReadError = errors.RuntimeError;

// ===== Object-model support and re-exported payload types =====

/// Process-lifetime empty shape exposed only while a class finalizer inspects
/// an object whose own property buffer and original shape have already been
/// released. QuickJS publishes `shape = NULL` / `prop = NULL` before invoking
/// the class finalizer; zjs's public read helpers require a non-null Shape, so
/// this valid FAM-backed tombstone gives them the equivalent empty view without
/// leaving `Object.shape_ref` pointed at freed storage.
///
/// The Metadata prefix is intentional: a reentrant GC/read helper may inspect
/// the Shape header even though the tombstone is never linked into a runtime's
/// GC registry. Its high refcount makes accidental retain/release benign;
/// object mutation from a class finalizer remains outside the callback contract.
const FinalizingShapeStorage = extern struct {
    metadata: gc.Metadata = .{
        .alloc_info = .{ .standalone = true },
        .flags = .{ .kind = .shape, .is_pinned = true },
        .lifetime = .{ .trace = .{} },
    },
    value: shape.Shape = .{
        .ownership = .{ .trace_ref_count = std.math.maxInt(i32) / 2 },
        .prop_hash_mask = shape.initial_hash_size - 1,
        .prop_size = shape.initial_prop_size,
    },
    buckets: [shape.initial_hash_size]u32 = @splat(shape.no_property_index),
    properties: [shape.initial_prop_size]shape.Property = @splat(.{}),

    comptime {
        std.debug.assert(@offsetOf(@This(), "value") == gc.metadata_prefix_size);
        std.debug.assert(@offsetOf(@This(), "buckets") == gc.metadata_prefix_size + @sizeOf(shape.Shape));
        std.debug.assert(
            @offsetOf(@This(), "properties") ==
                gc.metadata_prefix_size + @sizeOf(shape.Shape) + @sizeOf(u32) * shape.initial_hash_size,
        );
    }
};

threadlocal var finalizing_shape_storage = FinalizingShapeStorage{};

/// Shadow write audit of Slot-bypassing persistent heap stores. Comptime-erased
/// in default `rc` so production `.text` is unchanged. Hits are Stage 6
/// candidates, not a failure.
inline fn auditWrite(comptime kind: anytype, comptime site: anytype) void {
    if (comptime builtin.is_test) {
        @import("gc_write_audit.zig").hit(kind, site);
    }
}

fn finalizingShape() *shape.Shape {
    return &finalizing_shape_storage.value;
}

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

pub const collection_no_entry = object_payloads.collection_no_entry;
pub const CollectionEntry = object_payloads.CollectionEntry;
pub const WeakCollectionEntry = object_payloads.WeakCollectionEntry;
pub const FinalizationRegistryCellState = object_payloads.FinalizationRegistryCellState;
pub const FinalizationRegistryCell = object_payloads.FinalizationRegistryCell;
pub const DataPropertyLookup = object_payloads.DataPropertyLookup;
pub const OrdinaryPayload = object_payloads.OrdinaryPayload;
pub const IteratorPayload = object_payloads.IteratorPayload;
pub const WeakReferenceHolderLink = object_payloads.WeakReferenceHolderLink;
pub const CollectionPayload = object_payloads.CollectionPayload;
pub const SharedBufferStore = object_payloads.SharedBufferStore;
pub const ExternalByteStorageDeinit = object_payloads.ExternalByteStorageDeinit;
pub const BufferPayload = object_payloads.BufferPayload;
pub const TypedArrayPayload = object_payloads.TypedArrayPayload;
pub const RegExpPayload = object_payloads.RegExpPayload;
pub const BoundFunctionPayload = object_payloads.BoundFunctionPayload;
pub const ProxyPayload = object_payloads.ProxyPayload;
pub const ArgumentsPayload = object_payloads.ArgumentsPayload;
pub const ObjectDataPayload = object_payloads.ObjectDataPayload;
pub const WeakRefPayload = object_payloads.WeakRefPayload;
pub const VarRefPayload = object_payloads.VarRefPayload;
pub const FinalizationRegistryPayload = object_payloads.FinalizationRegistryPayload;
pub const StdFilePayload = object_payloads.StdFilePayload;
pub const DisposableResourceKind = object_payloads.DisposableResourceKind;
pub const DisposalHint = object_payloads.DisposalHint;
pub const DisposableMethodKind = object_payloads.DisposableMethodKind;
pub const DisposableResource = object_payloads.DisposableResource;
pub const DisposableStackPayload = object_payloads.DisposableStackPayload;
pub const RealmValueSlot = context_mod.RealmValueSlot;
pub const GlobalPayload = object_payloads.GlobalPayload;
pub const RealmRecordPayload = object_payloads.RealmRecordPayload;
pub const PromisePayload = object_payloads.PromisePayload;
pub const AsyncGeneratorRequest = generator_state.AsyncGeneratorRequest;
pub const GeneratorSuspendKind = generator_state.GeneratorSuspendKind;
pub const SuspendedStackStorage = generator_state.SuspendedStackStorage;
pub const SuspendedFrameStorage = generator_state.SuspendedFrameStorage;
pub const SuspendedExecutionStorage = generator_state.SuspendedExecutionStorage;
pub const SuspendedExecutionState = generator_state.SuspendedExecutionState;
pub const GeneratorExecutionState = generator_state.GeneratorExecutionState;
pub const GeneratorPayload = generator_state.GeneratorPayload;
pub const ArrayBuiltinMarker = object_payloads.ArrayBuiltinMarker;
pub const TypedArrayBuiltinMarker = object_payloads.TypedArrayBuiltinMarker;
pub const RegExpLegacyStatics = object_payloads.RegExpLegacyStatics;
pub const FunctionRarePayload = object_payloads.FunctionRarePayload;
pub const FunctionPayload = object_payloads.FunctionPayload;
pub const BytecodeFunctionAux = object_payloads.BytecodeFunctionAux;
pub const BytecodeFunctionStorage = object_payloads.BytecodeFunctionStorage;

const destroyOwnedValue = object_payloads.destroyOwnedValue;
const replaceOwnedValue = object_payloads.replaceOwnedValue;
const destroyValueSlice = object_payloads.destroyValueSlice;
const destroyValueSliceWithCapacity = object_payloads.destroyValueSliceWithCapacity;
const destroyOptionalVarRefCellSlice = object_payloads.destroyOptionalVarRefCellSlice;
const createGeneratorExecutionStateWithStorage = generator_state.createGeneratorExecutionStateWithStorage;
const destroyGeneratorExecutionState = generator_state.destroyGeneratorExecutionState;
const empty_suspended_execution_state = generator_state.empty_suspended_execution_state;

pub fn destroyDetachedClassPayload(rt: *JSRuntime, class_id: class.ClassId, payload_kind: class.PayloadKind, payload: *class.Payload) void {
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
            Object.releaseIteratorCollectionCursor(class_id, typed);
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
        .global => {
            const typed: *GlobalPayload = @ptrCast(@alignCast(ptr));
            typed.destroy(rt);
            rt.memory.destroy(GlobalPayload, typed);
        },
        .realm_record => {
            const typed: *RealmRecordPayload = @ptrCast(@alignCast(ptr));
            typed.destroy();
            rt.destroyRuntime(RealmRecordPayload, typed);
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
    /// QuickJS `JSObject.is_std_array_prototype`: published only on a realm's
    /// intrinsic %Array.prototype% and cleared permanently by mutations that
    /// can make dense Array extension observe the prototype chain.
    is_std_array_prototype: bool = false,
    /// Weak-identity table membership. Moved here from the GC metadata prefix
    /// when the prefix kind/flags byte collapsed to the qjs single-byte
    /// `gc_obj_type:7|mark:1` shape (quickjs.c:276); this bit is object-only,
    /// and it reuses the reserved lifecycle bit so the packed ABI stays 16 bits.
    has_weak_id: bool = false,
    has_exotic_methods: bool = false,
    is_borrowed_reference_holder: bool = false,
    /// Actual active payload state. This is distinct from the class's declared
    /// payload kind because ordinary/global payloads are attached lazily.
    class_payload_kind: class.PayloadKind = .none,
};

var test_standard_exotic_methods: [class.ids.init_count]?*const ExoticMethods = @splat(null);

fn classHasExoticMethods(class_id: class.ClassId, definition_has_exotic: bool) bool {
    if (exoticMethodsForClassId(class_id) != null) return true;
    return definition_has_exotic;
}

fn classNeedsSlowPropertyAccess(class_id: class.ClassId, has_exotic_methods: bool) bool {
    if (has_exotic_methods) return true;
    return switch (class_id) {
        class.ids.array,
        // Unmapped Arguments (strict / non-simple) store indices in the dense
        // fast_array arm. qjs marks them is_exotic + fast_array so
        // JS_GetPropertyInternal consults the exotic arm after a shape miss
        // (quickjs.c:8296-8303). Without this, Get of args[0] skips
        // getOwnProperty's denseArrayElement probe and returns undefined.
        class.ids.arguments,
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

/// Classes whose instances can own dense element storage (`u.array`) or
/// materialized index properties with element semantics: only for these does
/// an array-index-form atom need the full `array.arrayIndexFromAtom` probe
/// (whose string leg parses the >= 10-digit "2147483648".."4294967294"
/// window) before a plain shape add. qjs's set/add path likewise asks the
/// index question only in the fast_array class arm — the inline
/// `__JS_AtomIsTaggedInt` bit test (quickjs.c:9868-9877) — while the ordinary
/// object add_property runs with no index probe at all (quickjs.c:9884-9890).
fn classOwnsIndexedElementStorage(class_id: class.ClassId) bool {
    return switch (class_id) {
        class.ids.array,
        class.ids.arguments,
        class.ids.mapped_arguments,
        class.ids.string,
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

/// Dense-array arm of QuickJS's 24-byte `JSObject.u`. ZJS retains an explicit
/// capacity in addition to the visible length/count, so the final scalar is
/// padding rather than observable state.
pub const DenseArrayStorage = extern struct {
    values: [*]JSValue = @ptrFromInt(@alignOf(JSValue)),
    count: u32 = 0,
    capacity: u32 = 0,
    /// JS-observable `.length` for arrays, distinct from the dense element
    /// extent in `count`: an array may carry `length > count`, with the slots
    /// `[count, length)` being holes (resolved up the prototype chain, never
    /// owned, and not enumerated). This mirrors qjs `p->prop[0].u.value` in
    /// set_array_length/add_fast_array_element; `length >= count` for arrays.
    /// Unmapped arguments keep it equal to `count` solely as dense-storage
    /// metadata; their visible `length` is an ordinary own property.
    length: u32 = 0,
    _padding: u32 = 0,
};

/// Full 24-byte class-data union, matching qjs `JSObject.u`. Payload-backed
/// classes use only the first pointer; dense arrays use the complete array arm.
/// Bytecode functions will use the same three-word budget for FB/var_refs/home.
///
/// `ObjectFlags.class_payload_kind == .none` is intentionally tri-state: the
/// object may have no payload, may carry an embedder-external or trailing-inline
/// payload pointer in word 0, or may use a non-payload inline/dense union arm.
/// `externalClassPayload` owns the manual class/flag exclusion for the last
/// case; a new inline/dense arm must join it before storing non-payload bytes.
/// Payload-pointer objects must use `initPayload`: it zeroes union bytes 8..24
/// before writing word 0. Some cross-arm checks (for example the ordinary
/// Array.prototype path reading `u.array.capacity`) rely on those bytes staying
/// zero even while the payload arm is active.
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

/// Widest union arm; the storage a class may actually own is
/// `unionArmBytes(class_id)` and may be narrower (obj64 knife ③).
pub const union_arm_max_bytes: usize = @sizeOf(ObjectStorage);
/// Narrowest arm: the payload word every class owns unconditionally.
pub const union_arm_min_bytes: usize = @sizeOf(class.Payload);

/// The cell-resident class-data width, in bytes, for `class_id`.
///
/// This is the SIZING AUTHORITY for every `.object` allocation and free, and it
/// MUST be a pure function of `class_id`: the cell width is fixed when the cell
/// is taken, while `flags.fast_array` is recomputed after construction
/// (`recomputeArrayStorageMode`), so flags can never be the discriminator.
/// `class_id` is immutable for the object's whole lifetime.
///
/// Wide (24 B) classes are exactly the ones with a non-payload arm:
///   * dense element storage  -> `DenseArrayStorage` (24 B)
///   * bytecode callables     -> `BytecodeFunctionStorage` (24 B)
///   * RegExp                 -> `RegExpPayload` (16 B, rounded to the wide arm
///     so the knife introduces exactly two widths rather than three)
///   * String exotics         -> defensive: `classOwnsIndexedElementStorage`
///     admits `ids.string` to the index-probe path, and no narrowing is worth
///     the audit of every indexed read reached from there.
/// Everything else owns only the payload word.
pub fn unionArmBytes(class_id: class.ClassId) usize {
    return switch (class_id) {
        class.ids.array,
        class.ids.arguments,
        class.ids.mapped_arguments,
        class.ids.string,
        class.ids.regexp,
        class.ids.bytecode_function,
        class.ids.generator_function,
        class.ids.async_function,
        class.ids.async_generator_function,
        => union_arm_max_bytes,
        else => union_arm_min_bytes,
    };
}

comptime {
    // The wide set must cover every arm the union can actually name.
    std.debug.assert(union_arm_max_bytes == 24);
    std.debug.assert(union_arm_min_bytes == 8);
    std.debug.assert(@sizeOf(DenseArrayStorage) <= union_arm_max_bytes);
    std.debug.assert(@sizeOf(BytecodeFunctionStorage) <= union_arm_max_bytes);
    std.debug.assert(@sizeOf(RegExpPayload) <= union_arm_max_bytes);
    std.debug.assert(@sizeOf(class.Payload) <= union_arm_min_bytes);
}

pub const Object = extern struct {
    pub const gc_kind_tag: u8 = @intFromEnum(gc.GcKind.object);
    pub const trailing_property_capacity: usize = 2;
    pub const trailing_property_bytes: usize = trailing_property_capacity * @sizeOf(property.Entry);
    const trailing_property_allocation_bit: u32 = 1 << 31;
    const weakref_count_mask: u32 = trailing_property_allocation_bit - 1;
    comptime {
        // GC prefix model: BlockHeader.meta() reads objectPtr-8, so header MUST
        // be at offset 0. `extern struct` fixes the declared field order while
        // preserving each concrete GC object's natural alignment.
        std.debug.assert(@offsetOf(@This(), "header") == 0);
        // The FIXED head. The class-data union is no longer a struct field: it
        // trails the head at `unionArmBytes(class_id)` bytes wide, so
        // `@sizeOf(Object)` is the head only and is NEVER an allocation size.
        // Use `bodyBytes()` / `objectBodyBytes(class_id)` for that.
        // ① step 2: ObjectGcToken is size 0, so the live head is 24 bytes.
        std.debug.assert(@sizeOf(@This()) == 24);
        std.debug.assert(@sizeOf(ObjectFlags) == 2);
        std.debug.assert(@sizeOf(ObjectStorage) == 24);
        const header_bytes = @sizeOf(gc.ObjectGcToken);
        std.debug.assert(@offsetOf(@This(), "weakref_count") == header_bytes);
        std.debug.assert(@offsetOf(@This(), "class_id") == header_bytes + 4);
        std.debug.assert(@offsetOf(@This(), "flags") == header_bytes + 6);
        std.debug.assert(@offsetOf(@This(), "shape_ref") == header_bytes + 8);
        std.debug.assert(@offsetOf(@This(), "prop_values") == header_bytes + 16);
        std.debug.assert(trailing_property_allocation_bit & weakref_count_mask == 0);
        // The widest body must still be what the pre-knife fixed struct was, so
        // no wide class silently changed size class.
        std.debug.assert(@sizeOf(@This()) + union_arm_max_bytes == 48);
        // Size-class contract: after ① step 2 the trailing-property form
        // (only `ids.object` may have one) is 64 used (24+8+32) and still
        // rounds to the 80-byte cell class until ④. Dense arm classes must
        // NOT fall into the 48-byte class (whose 64-byte-grid phase costs
        // 1.5 lines/object -- a net regression for 33% of the traced
        // population).
        if (builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall) {
            std.debug.assert(trailing_property_bytes == 32);
            std.debug.assert(objectBodyBytes(class.ids.object) + trailing_property_bytes == 64);
            std.debug.assert(objectBodyBytes(class.ids.array) == 48);
        } else {
            std.debug.assert(trailing_property_bytes == 48);
        }
    }
    header: gc.ObjectGcToken = .{},
    weakref_count: u32 = 0,
    class_id: class.ClassId,
    flags: ObjectFlags = .{},
    shape_ref: *shape.Shape,
    // Bare pointer to the property VALUE array (qjs `JSObject.prop`, a bare
    // `JSProperty *`). The element count is shape authority. An aligned
    // dangling sentinel means no storage; the compiler-proven slots2 form
    // points this same field at the allocation's trailing entries.
    prop_values: [*]property.Entry = emptyPropertyStorageBase(),
    // NOTE: the qjs 24-byte class union `u` used to live here. It is now a
    // class-sized trailing region reached through `payloadArm`/`arrayArm`/
    // `bytecodeArm`/`regexpArm`.

    /// Re-exports so representation snapshots and cross-module checkers can
    /// name the two arm widths without reaching into the file scope.
    pub const arm_min_bytes: usize = union_arm_min_bytes;
    pub const arm_max_bytes: usize = union_arm_max_bytes;

    /// Object identity is the cell address. `ObjectGcToken` is size 0 at
    /// offset 0, so a GC `*Header` for kind `.object` is already `*Object`.
    pub inline fn fromHeader(header: anytype) *Object {
        return @ptrCast(@alignCast(header));
    }

    pub inline fn fromHeaderConst(header: anytype) *const Object {
        return @ptrCast(@alignCast(header));
    }

    pub inline fn gcHeader(self: *Object) *gc.Header {
        return self.header.asHeader();
    }

    pub inline fn gcHeaderConst(self: *const Object) *const gc.Header {
        return self.header.asHeaderConst();
    }

    /// Head + class-data arm. The single authority for how many bytes an
    /// `.object` allocation owns before its optional trailing property FAM.
    pub inline fn objectBodyBytes(class_id: class.ClassId) usize {
        return @sizeOf(Object) + unionArmBytes(class_id);
    }

    pub inline fn bodyBytes(self: *const Object) usize {
        return objectBodyBytes(self.class_id);
    }

    /// Bytes trailing the fixed head: the class-data arm plus the optional
    /// property FAM. This is the flexible-array size every `.object`
    /// allocation and every matching free MUST pass, and the reason ③ cannot
    /// silently corrupt the heap: alloc and free derive it from the same pure
    /// function of the same immutable `class_id`.
    pub inline fn objectTailBytes(class_id: class.ClassId, has_trailing_properties: bool) usize {
        return unionArmBytes(class_id) +
            @as(usize, if (has_trailing_properties) trailing_property_bytes else 0);
    }

    inline fn allocCell(rt: *JSRuntime, class_id: class.ClassId, comptime has_trailing: bool) !*Object {
        return rt.memory.createWithFamNoTrigger(Object, objectTailBytes(class_id, has_trailing));
    }

    /// `allocCell` for the constructors whose class is a literal. The tail is
    /// then a compile-time constant, which is what keeps the block heap's
    /// specialized `allocCellFixedPtr` route (and the comptime slab class)
    /// alive after ③ turned the cell size into a function of `class_id`.
    inline fn allocCellConst(
        rt: *JSRuntime,
        comptime class_id: class.ClassId,
        comptime has_trailing: bool,
    ) !*Object {
        return rt.memory.createConstFamNoTrigger(Object, comptime objectTailBytes(class_id, has_trailing));
    }

    inline fn freeRawCellConst(
        rt: *JSRuntime,
        self: *Object,
        comptime class_id: class.ClassId,
        comptime has_trailing: bool,
    ) void {
        rt.memory.destroyConstFam(Object, comptime objectTailBytes(class_id, has_trailing), self);
    }

    /// Free a cell whose head was never initialized past `class_id`: the
    /// construction error paths. `has_trailing` is the caller's own allocation
    /// decision, not a header read.
    inline fn freeRawCell(rt: *JSRuntime, self: *Object, class_id: class.ClassId, comptime has_trailing: bool) void {
        rt.memory.destroyWithFam(Object, self, objectTailBytes(class_id, has_trailing));
    }

    /// The class-data region's base. Always in bounds: every class owns at
    /// least the payload word.
    inline fn armBase(self: *const Object) usize {
        return @intFromPtr(self) + @sizeOf(Object);
    }

    /// Checker for the silent out-of-bounds class ③ creates: a narrow class
    /// reaching a wide arm reads (or writes) the trailing property entries or
    /// the next cell. Compiled away in ReleaseFast, where the arms are already
    /// proven by the guards this assertion audits.
    ///
    /// The kind probe below is deliberately weak and is NOT the guard for the
    /// second hazard (a by-value `Object`, which copies only the head and
    /// leaves the arm behind). It was tried as one and measured useless:
    /// `GcKind.object` is tag 0, so a zeroed stack slot reads back as a valid
    /// kind and the injected by-value copy sailed through the whole test
    /// suite. That hazard is caught textually instead, by the
    /// `Object passed by value` rule in `tools/perf/lint_anti_goals.sh`.
    inline fn assertArmReadable(self: *const Object, comptime T: type) void {
        if (comptime !std.debug.runtime_safety) return;
        std.debug.assert(unionArmBytes(self.class_id) >= @sizeOf(T));
    }

    /// Word 0 of the class-data region: the out-of-line class payload pointer
    /// (qjs `JSObject.u.opaque`). Valid for every class.
    pub inline fn payloadArm(self: *const Object) *class.Payload {
        return @ptrFromInt(self.armBase());
    }

    pub inline fn arrayArm(self: *const Object) *DenseArrayStorage {
        self.assertArmReadable(DenseArrayStorage);
        return @ptrFromInt(self.armBase());
    }

    pub inline fn bytecodeArm(self: *const Object) *BytecodeFunctionStorage {
        self.assertArmReadable(BytecodeFunctionStorage);
        return @ptrFromInt(self.armBase());
    }

    pub inline fn regexpArm(self: *const Object) *RegExpPayload {
        self.assertArmReadable(RegExpPayload);
        return @ptrFromInt(self.armBase());
    }

    /// Install the class-data region for a freshly allocated cell.
    ///
    /// Replaces the old `ObjectStorage.initPayload` whole-union store: word 0
    /// takes the payload, and the remaining arm bytes are zeroed only when the
    /// class actually owns them. Cross-arm checks that read `arrayArm().count`
    /// on a payload-arm object depend on that zero fill, so it must cover the
    /// whole owned arm and nothing beyond it.
    inline fn initArmPayload(self: *Object, payload: class.Payload) void {
        const arm = unionArmBytes(self.class_id);
        if (arm > union_arm_min_bytes) {
            const bytes: [*]u8 = @ptrFromInt(self.armBase() + union_arm_min_bytes);
            @memset(bytes[0 .. arm - union_arm_min_bytes], 0);
        }
        self.payloadArm().* = payload;
    }

    // Trace-only Shape projection stored in the low seven bits of Metadata
    // byte 6. The high bit is leased to the generational write barrier's
    // remembered-set membership fast check (and, since audit §10, to every
    // other `gc.traceRememberedCacheEligible` carrier as well); every summary
    // writer must preserve it and every summary reader/audit must mask it out. The low two bits keep
    // exact property counts 0..2; low-bit value 3 is the overflow sentinel.
    // A traced slot has five states (four live kinds plus deleted, whose kind is
    // irrelevant), so the two-slot payload fits in five bits as base-5
    // `slot0 + 5 * slot1`. Descriptor W/E/C bits intentionally stay cold in
    // Shape. Canonical all-live-data summaries remain 0/1/2, preserving the
    // marker and object-literal hot paths that justified this projection.
    pub const trace_shape_summary_count_mask: u8 = 0b11;
    pub const trace_shape_summary_overflow: u8 = trace_shape_summary_count_mask;
    pub const trace_shape_summary_storage_mask: u8 = gc.trace_object_shape_summary_mask;
    const trace_shape_summary_payload_shift: u3 = 2;
    const trace_shape_slot_state_radix: u8 = 5;
    const trace_shape_slot_deleted_state: u8 = 4;

    comptime {
        std.debug.assert(trace_shape_summary_storage_mask | gc.trace_remembered_mask == std.math.maxInt(u8));
        std.debug.assert(trace_shape_summary_storage_mask & gc.trace_remembered_mask == 0);
        std.debug.assert(@intFromEnum(property.Kind.data) == 0);
        std.debug.assert(@intFromEnum(property.Kind.accessor) == 1);
        std.debug.assert(@intFromEnum(property.Kind.var_ref) == 2);
        std.debug.assert(@intFromEnum(property.Kind.auto_init) == 3);
        std.debug.assert(trace_shape_slot_deleted_state == 4);
        const max_exact_summary =
            ((trace_shape_slot_state_radix * trace_shape_slot_state_radix - 1) << trace_shape_summary_payload_shift) |
            @as(u8, @intCast(trailing_property_capacity));
        std.debug.assert(max_exact_summary < gc.trace_remembered_mask);
        // The third append increments the full byte from exact count 2 to the
        // low-bit overflow sentinel. Even the maximum base-5 payload must not
        // carry into the leased remembered bit.
        std.debug.assert(max_exact_summary + 1 < gc.trace_remembered_mask);
    }

    pub inline fn traceShapeSummary(self: *const Object) u8 {
        return self.header.metaConst().lifetime.trace.object_shape_summary & trace_shape_summary_storage_mask;
    }

    pub inline fn traceShapeSummaryIsExact(summary: u8) bool {
        return summary & trace_shape_summary_count_mask != trace_shape_summary_overflow;
    }

    pub inline fn traceShapeSummaryCount(summary: u8) usize {
        std.debug.assert(traceShapeSummaryIsExact(summary));
        return summary & trace_shape_summary_count_mask;
    }

    pub inline fn traceShapeSummaryFlagsAt(summary: u8, index: usize) property.Flags {
        const shape_summary = summary & trace_shape_summary_storage_mask;
        std.debug.assert(traceShapeSummaryIsExact(shape_summary));
        std.debug.assert(index < traceShapeSummaryCount(shape_summary));
        const payload = shape_summary >> trace_shape_summary_payload_shift;
        const slot_state = if (index == 0)
            payload % trace_shape_slot_state_radix
        else
            payload / trace_shape_slot_state_radix;
        if (slot_state == trace_shape_slot_deleted_state)
            return property.Flags.fromBits(@as(u6, 1) << 5);
        return property.Flags.fromBits(@as(u6, @intCast(slot_state)) << 3);
    }

    inline fn traceShapeSlotState(flags: property.Flags) u8 {
        return if (flags.deleted)
            trace_shape_slot_deleted_state
        else
            @intFromEnum(flags.kind);
    }

    fn shapeSummaryFor(shape_ref: *const shape.Shape) u8 {
        const count: usize = shape_ref.prop_count;
        if (count > trailing_property_capacity) return trace_shape_summary_overflow;
        var payload: u8 = 0;
        if (count != 0)
            payload = traceShapeSlotState(property.Flags.fromBits(shape_ref.props()[0].flags));
        if (count == trailing_property_capacity)
            payload += trace_shape_slot_state_radix * traceShapeSlotState(property.Flags.fromBits(shape_ref.props()[1].flags));
        return @as(u8, @intCast(count)) | (payload << trace_shape_summary_payload_shift);
    }

    inline fn storeTraceShapeSummary(self: *Object, summary: u8) void {
        std.debug.assert(summary & ~trace_shape_summary_storage_mask == 0);
        const state = &self.header.meta().lifetime.trace;
        state.object_shape_summary =
            (state.object_shape_summary & gc.trace_remembered_mask) | summary;
    }

    /// Publication and the rare whole-layout replacement use a full refresh.
    /// Property append/update paths below maintain the same byte incrementally
    /// so raytrace does not pay a Shape reread after every transition.
    pub inline fn refreshTraceShapeSummary(self: *Object) void {
        self.storeTraceShapeSummary(shapeSummaryFor(self.shape_ref));
    }

    pub fn traceShapeSummaryMatches(self: *const Object) bool {
        const stored_summary = self.header.metaConst().lifetime.trace.object_shape_summary &
            trace_shape_summary_storage_mask;
        const expected_summary = shapeSummaryFor(self.shape_ref);
        // Overflow traces the Shape descriptors and ignores payload bits. The
        // exact->overflow transition deliberately preserves that don't-care
        // payload so bit7 can survive with one byte increment on the third
        // property append; audit therefore validates only the count sentinel.
        if (expected_summary == trace_shape_summary_overflow)
            return !traceShapeSummaryIsExact(stored_summary);
        return stored_summary == expected_summary;
    }

    inline fn commitTraceShapeAppend(self: *Object, old_len: usize, flags: property.Flags) void {
        const state = &self.header.meta().lifetime.trace;
        if (old_len >= trailing_property_capacity) {
            if (old_len == trailing_property_capacity)
                // Exact count 2 ends in binary `10`; incrementing makes the
                // overflow sentinel `11` while retaining both the remembered
                // bit and now-ignored payload. This keeps the third live-data
                // append at the same load/add/store shape as the first two.
                state.object_shape_summary +%= 1;
            return;
        }
        const previous = state.object_shape_summary & trace_shape_summary_storage_mask;
        std.debug.assert(traceShapeSummaryIsExact(previous));
        std.debug.assert(traceShapeSummaryCount(previous) == old_len);
        // For the dominant live-data append the low count transitions are
        // exactly 00 -> 01 and 01 -> 10. Incrementing the whole byte therefore
        // updates the count without carrying into the upper slot summaries,
        // and preserves any unusual/deleted predecessor. This is also cheaper
        // than testing whether the predecessor was canonical on every object-
        // literal field append (raytrace's allocation hot path).
        const next_slot_state = traceShapeSlotState(flags);
        if (next_slot_state == 0) {
            state.object_shape_summary +%= 1;
            return;
        }
        const previous_payload = previous >> trace_shape_summary_payload_shift;
        const next_payload = if (old_len == 0)
            next_slot_state
        else
            previous_payload + trace_shape_slot_state_radix * next_slot_state;
        self.storeTraceShapeSummary(
            @as(u8, @intCast(old_len + 1)) |
                (next_payload << trace_shape_summary_payload_shift),
        );
    }

    inline fn syncTraceShapePropertyFlags(self: *Object, index: usize, flags: property.Flags) void {
        const previous = self.traceShapeSummary();
        if (!traceShapeSummaryIsExact(previous)) return;
        std.debug.assert(index < traceShapeSummaryCount(previous));
        const previous_payload = previous >> trace_shape_summary_payload_shift;
        const slot0_state = previous_payload % trace_shape_slot_state_radix;
        const next_slot_state = traceShapeSlotState(flags);
        const next_payload = if (index == 0)
            previous_payload - slot0_state + next_slot_state
        else
            slot0_state + trace_shape_slot_state_radix * next_slot_state;
        self.storeTraceShapeSummary(
            @as(u8, @intCast(traceShapeSummaryCount(previous))) |
                (next_payload << trace_shape_summary_payload_shift),
        );
    }

    inline fn updateShapePropertyFlags(self: *Object, rt: *JSRuntime, index: usize, flags: property.Flags) void {
        rt.shapes.updatePropertyFlags(self.shape_ref, index, flags.bits());
        self.syncTraceShapePropertyFlags(index, flags);
    }
    // ===== create / construction =====
    pub fn expect(val: JSValue) !*Object {
        const header = val.refHeader() orelse return error.TypeError;
        if (!val.isObject()) return error.TypeError;
        return fromHeader(header);
    }

    pub fn create(rt: *JSRuntime, class_id: class.ClassId, prototype: ?*Object) !*Object {
        // The bare plain-object allocation (`{}` — qjs JS_NewObject) is the
        // hottest create form. Route it to the dedicated
        // JS_NewObjectFromShape mirror instead of the general class-payload
        // constructor (createArrayFromInitialShape precedent for arrays).
        if (class_id == class.ids.object) return createPlainObject(rt, prototype);
        return createInternal(rt, class_id, prototype, 0, null);
    }

    /// Construct a FinalizationRegistry with its QJS-style Realm owner already
    /// installed. Retaining the Realm is infallible and happens before the
    /// object can be published by the caller, so a production registry never
    /// exists with a borrowed or missing construction context.
    pub fn createFinalizationRegistry(
        rt: *JSRuntime,
        realm: *context_mod.RealmContext,
        prototype: ?*Object,
    ) !*Object {
        std.debug.assert(realm.runtime == rt);
        const registry = try createInternal(rt, class.ids.finalization_registry, prototype, 0, null);
        const payload = registry.finalizationRegistryPayload() orelse unreachable;
        std.debug.assert(payload.realm.borrow() == null);
        payload.realm = context_mod.RealmRef.retain(realm);
        return registry;
    }

    pub fn createWithOwnPropertyCapacity(rt: *JSRuntime, class_id: class.ClassId, prototype: ?*Object, capacity: usize) !*Object {
        return createInternal(rt, class_id, prototype, capacity, null);
    }

    /// Grow the named-property value buffer without changing the shared empty
    /// root shape. Constructor allocation profiles use this so later put_field
    /// transitions stay on the qjs-mirrored hash-consed chain.
    pub fn reserveOwnPropertyCapacity(self: *Object, rt: *JSRuntime, needed: usize) !void {
        try self.ensurePropertyCapacity(rt, needed);
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
        // Generator ids are standard: no pin traffic, so the by-value plan
        // avoids materializing a Construction across the fallible window.
        const definition = rt.classes.standardPlan(class_id);
        std.debug.assert(inlineClassPayloadLayoutForDefinition(definition) == null);
        std.debug.assert(definition.payload_kind == .generator);

        // The detached path knows the finalized operand-stack size and installs
        // a variable-sized execution record immediately afterwards. Allocate
        // only the compact JSGeneratorData analogue here; Object.create keeps
        // using allocClassPayload for internal continuations with no bytecode
        // sizing context.
        const generator_payload = try rt.createRuntime(GeneratorPayload);
        generator_payload.* = .{};
        const class_payload: class.Payload = @ptrCast(generator_payload);
        errdefer freeClassPayloadAllocation(rt, class_payload, .generator);

        // The construction pin is published after the cell is initialized, so
        // reserve its ledger slot now. This is the last fallible side
        // allocation before the qjs-style object boundary.
        try rt.gc.prepareConstructionRoot();

        // qjs creates the public generator object through js_create_from_ctor →
        // JS_NewObjectFromShape, whose js_trigger_gc(sizeof(JSObject))
        // (quickjs.c:5619) runs BEFORE the JSObject allocation. Complete the
        // fallible payload allocation first, then service the boundary and take
        // the block cell as the final fallible step. No collection can observe
        // a raw, uninitialized cell in between.
        const alloc_size = objectBodyBytes(class_id);
        rt.collectBeforeObjectAllocation(alloc_size);
        const self = try allocCell(rt, class_id, false);
        errdefer freeRawCell(rt, self, class_id, false);

        const has_exotic_methods = classHasExoticMethods(class_id, definition.has_exotic);
        self.* = .{
            .header = .{},
            .class_id = class_id,
            // These fields become readable only after finishGeneratorShell.
            .shape_ref = undefined,
            .prop_values = emptyPropertyStorageBase(),
            .flags = .{
                .class_payload_kind = .generator,
                .has_exotic_methods = has_exotic_methods,
            },
        };
        // The final Shape cannot be resolved until parameter initialization
        // finishes. Name this complete payload-only shell explicitly so a
        // collection in that window marks its block cell and payload edges
        // without trying to read the deliberately undefined shape_ref.
        self.initArmPayload(class_payload);
        rt.gc.addConstructionRoot(&self.header);
        return self;
    }

    /// Turn a detached generator shell into the registered public object using
    /// its final prototype. No temporary null-prototype Shape is ever created.
    pub fn finishGeneratorShell(self: *Object, rt: *JSRuntime, prototype: ?*Object) !void {
        std.debug.assert(self.class_id == class.ids.generator or self.class_id == class.ids.async_generator);
        std.debug.assert(self.flags.class_payload_kind == .generator);
        std.debug.assert(!self.header.meta().alloc_info.heap_accounted);
        const final_shape = try rt.shapes.createObjectRoot(prototype);
        std.debug.assert(final_shape.prop_count == 0);
        self.shape_ref = final_shape;
        rt.gc.removeConstructionRoot(&self.header);
        rt.registerObjectWithBytes(self, self.bodyBytes()) catch |err| {
            self.header.meta().lifetime.trace.object_shape_summary = 0;
            rt.gc.addConstructionRoot(&self.header);
            self.shape_ref = undefined;
            rt.shapes.release(final_shape);
            return err;
        };
        // Parameter initialization parks the frame while this shell is still
        // detached. Publish first (the shell's raw owner keeps it alive), then
        // install the open-cell -> generator edges so registry publication
        // retains its fresh-header rc==1 contract.
        self.attachGeneratorOpenVarRefOwners(rt);
    }

    /// Error-path counterpart for a shell that has not been registered yet.
    pub fn destroyGeneratorShell(self: *Object, rt: *JSRuntime) void {
        std.debug.assert(self.class_id == class.ids.generator or self.class_id == class.ids.async_generator);
        std.debug.assert(!self.header.meta().alloc_info.heap_accounted);
        rt.gc.removeConstructionRoot(&self.header);
        if (self.flags.is_borrowed_reference_holder) rt.unregisterBorrowedReferenceHolder(self);
        freeClassPayloadAllocation(rt, self.payloadArm().*, self.flags.class_payload_kind);
        self.payloadArm().* = null;
        self.flags.class_payload_kind = .none;
        freeRawCell(rt, self, self.class_id, false);
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

    /// Allocate from a context-owned initial Shape. The caller supplies the
    /// per-object property cells; no hidden template Object participates.
    pub fn createFromShape(
        rt: *JSRuntime,
        class_id: class.ClassId,
        shape_ref: *shape.Shape,
        entries: []const property.Entry,
    ) !*Object {
        std.debug.assert(entries.len == shape_ref.prop_count);
        return createInternal(rt, class_id, shape_ref.proto, shape_ref.prop_size, .{
            .shape_ref = shape_ref,
            .entries = entries,
        });
    }

    pub fn createArrayFromShape(rt: *JSRuntime, shape_ref: *shape.Shape, entries: []const property.Entry) !*Object {
        // The realm's initial array shape carries no named properties (length
        // is header storage in zjs), so the common fresh-array allocation takes
        // the dedicated JS_NewObjectFromShape mirror below instead of paying
        // the general class-payload constructor.
        if (entries.len == 0 and shape_ref.prop_count == 0) {
            return createArrayFromInitialShape(rt, shape_ref);
        }
        const self = try createFromShape(rt, class.ids.array, shape_ref, entries);
        self.flags.fast_array = true;
        return self;
    }

    /// Allocate a fresh dense array straight from the realm's initial array
    /// Shape — the zjs analogue of qjs `JS_NewArray` = `JS_NewObjectFromShape(
    /// ctx, js_dup_shape(ctx->array_shape), JS_CLASS_ARRAY)` (quickjs.c:5575,
    /// 5610-5680): retain the prepared Shape, run the pre-allocation GC
    /// boundary, allocate the JSObject plus the shape-sized property buffer,
    /// and initialize the JS_CLASS_ARRAY arm inline (`p->is_exotic = 1;
    /// p->fast_array = 1; u.array = empty`, quickjs.c:5644-5657). The general
    /// `createInternal` re-derives all of this per call through the class
    /// definition plan; the array class is standard and its layout facts are
    /// compile-time constants, exactly like qjs's hardcoded switch arm.
    /// `createPreparedPropertyTemplate` is the same mirror for property-shaped
    /// templates; this is its dense-array sibling (no entries, header length).
    pub fn createArrayFromInitialShape(rt: *JSRuntime, initial_shape: *shape.Shape) !*Object {
        std.debug.assert(initial_shape.prop_count == 0);
        if (builtin.mode == .Debug) {
            // The hardcoded layout facts below must stay in lockstep with the
            // registered array class definition the generic path consults.
            const definition = rt.classes.standardPlan(class.ids.array);
            std.debug.assert(inlineClassPayloadLayoutForDefinition(definition) == null);
            std.debug.assert(definition.payload_kind == .none);
            std.debug.assert(!classHasExoticMethods(class.ids.array, definition.has_exotic));
        }
        initial_shape.retain();
        var shape_owned = true;
        errdefer if (shape_owned) rt.shapes.release(initial_shape);

        // qjs allocates `prop[shape->prop_size]` for every object built from a
        // shape (quickjs.c:5630); the initial array shape's buffer is reused by
        // later named-property appends, which trust `shape.prop_size` slots.
        // Prepare it before taking the collector-owned cell: a limit or
        // test-injected collection inside this allocation must not see an
        // allocated-but-unpublished block cell.
        const property_capacity: usize = initial_shape.prop_size;
        var property_storage: []property.Entry = &.{};
        var property_storage_owned = false;
        errdefer if (property_storage_owned) rt.memory.free(property.Entry, property_storage);
        if (property_capacity != 0) {
            property_storage = try rt.allocRuntime(property.Entry, property_capacity);
            property_storage_owned = true;
        }

        const alloc_size = objectBodyBytes(class.ids.array);
        rt.collectBeforeObjectAllocation(alloc_size);
        const self = try allocCellConst(rt, class.ids.array, false);
        var initialized = false;
        errdefer if (initialized)
            destroyFromHeader(rt, &self.header)
        else
            freeRawCellConst(rt, self, class.ids.array, false);

        self.* = .{
            .header = .{},
            .class_id = class.ids.array,
            .flags = .{
                .class_payload_kind = .none,
                // qjs JS_CLASS_ARRAY arm sets p->fast_array = 1. qjs's
                // `p->is_exotic` has NO zjs mirror bit for arrays: zjs derives
                // array length/index exotics from the class id itself
                // (`classNeedsSlowPropertyAccess`), and the registered array
                // class definition carries has_exotic = false — the
                // hasExoticMethods() guards on the dense fast paths depend on
                // it (hardcoding true regressed dense_array fills 4x).
                .has_exotic_methods = false,
                .fast_array = true,
            },
            .shape_ref = initial_shape,
            .prop_values = if (property_capacity == 0) emptyPropertyStorageBase() else property_storage.ptr,
        };
        // Null first word = qjs empty array pointer + no-payload sentinel;
        // count/capacity/length stay zero (see createInternal's array arm).
        self.initArmPayload(null);
        std.debug.assert(!self.isWeakReferenceHolderClass());
        std.debug.assert(self.shape_ref.prop_count == 0);
        property_storage_owned = false;
        shape_owned = false;
        initialized = true;
        try rt.registerObjectWithBytes(self, alloc_size);
        initialized = false;
        return self;
    }

    /// Pre-allocation GC for a constructor that already holds `shape_ref`.
    /// Publish a cache-miss Shape before entering the reentrant boundary: a
    /// deferred plugin finalizer can allocate, find this fully initialized
    /// Shape in the hash table, and retain it. Leaving it hash-visible but
    /// unpublished across that callback would let the nested constructor
    /// observe an impossible half-state. The local header root protects both
    /// a newly published Shape and a pre-existing hash hit from collection.
    fn collectBeforeObjectAllocationPublishingShape(rt: *JSRuntime, shape_ref: *shape.Shape, alloc_size: usize) void {
        if (!shape_ref.header.meta().alloc_info.heap_accounted) rt.shapes.publish(shape_ref);
        if (comptime !runtime_mod.value_root_link_containers_only) {
            var header_roots = [_]runtime_mod.HeaderRootValue{.{ .header = &shape_ref.header }};
            var frame = runtime_mod.ValueRootFrame{ .headers = &header_roots };
            frame.activate(rt);
            defer frame.deactivate(rt);
        }
        rt.collectBeforeObjectAllocation(alloc_size);
    }

    /// Allocate a bare plain object straight from the runtime's hashed root
    /// Shape for `prototype` — the zjs analogue of qjs `JS_NewObject` =
    /// `JS_NewObjectProtoClass(ctx, proto, JS_CLASS_OBJECT)` (quickjs.c:5847,
    /// 5743-5759): find_hashed_shape_proto/js_new_shape (both mirrored inside
    /// `createObjectRoot`), then JS_NewObjectFromShape's pre-allocation GC
    /// boundary, the raw JSObject allocation, and the EMPTY `JS_CLASS_OBJECT`
    /// switch arm (quickjs.c:5651-5653 — scalar flag init only, no payload, no
    /// exotics). The general `createInternal` re-derives all of this per call
    /// through the class definition plan (plan load + payload-kind triage +
    /// template loop + the union-of-arms spill frame); the object class is
    /// standard and its layout facts are compile-time constants, exactly like
    /// qjs's hardcoded arm. `createArrayFromInitialShape` is the same mirror
    /// for dense arrays; `createPreparedPropertyTemplate` for property-shaped
    /// templates. Non-plain classes and capacity/template forms keep the
    /// general constructor.
    pub fn createPlainObject(rt: *JSRuntime, prototype: ?*Object) !*Object {
        if (builtin.mode == .Debug) {
            // The hardcoded layout facts below must stay in lockstep with the
            // registered object class definition the generic path consults.
            const definition = rt.classes.standardPlan(class.ids.object);
            std.debug.assert(inlineClassPayloadLayoutForDefinition(definition) == null);
            std.debug.assert(definition.payload_kind == .ordinary);
            std.debug.assert(!payloadKindAllocates(definition.payload_kind));
            std.debug.assert(!classHasExoticMethods(class.ids.object, definition.has_exotic));
        }
        const shape_ref = try rt.shapes.createObjectRootReserved(prototype);
        var shape_owned = true;
        errdefer if (shape_owned) rt.shapes.release(shape_ref);

        const alloc_size = objectBodyBytes(class.ids.object);
        collectBeforeObjectAllocationPublishingShape(rt, shape_ref, alloc_size);
        const self = try allocCellConst(rt, class.ids.object, false);
        var initialized = false;
        errdefer if (initialized)
            destroyFromHeader(rt, &self.header)
        else
            freeRawCellConst(rt, self, class.ids.object, false);

        self.* = .{
            .header = .{},
            .class_id = class.ids.object,
            .flags = .{
                .class_payload_kind = .none,
                .has_exotic_methods = false,
            },
            .shape_ref = shape_ref,
            // A fresh root-shape object defers its property VALUE buffer to
            // the first append (ensurePropertyCapacity), matching
            // createInternal's `own_property_capacity == 0` path: the dangling
            // aligned sentinel means no storage yet.
            .prop_values = emptyPropertyStorageBase(),
        };
        // Null payload pointer: the object class's declared `.ordinary`
        // payload is attached lazily, so a fresh `{}` carries no payload
        // allocation and `class_payload_kind` stays `.none` (identical to
        // createInternal's non-allocating ordinary path).
        self.initArmPayload(null);
        std.debug.assert(!self.isWeakReferenceHolderClass());
        std.debug.assert(self.shape_ref.prop_count == 0);
        shape_owned = false;
        initialized = true;
        try rt.registerObjectWithBytes(self, alloc_size);
        initialized = false;
        return self;
    }

    /// Object-literal allocation for a compiler-proven one/two-slot Shape.
    /// The Shape capacity is exactly two, so its value entries trail the
    /// Object in the same GC allocation. This does not add dormant slots to
    /// `{}`: the ordinary zero-capacity constructor above remains 64 bytes.
    pub fn createPlainObjectReserved2(rt: *JSRuntime, prototype: ?*Object) !*Object {
        if (builtin.mode == .Debug) {
            const definition = rt.classes.standardPlan(class.ids.object);
            std.debug.assert(inlineClassPayloadLayoutForDefinition(definition) == null);
            std.debug.assert(definition.payload_kind == .ordinary);
            std.debug.assert(!payloadKindAllocates(definition.payload_kind));
            std.debug.assert(!classHasExoticMethods(class.ids.object, definition.has_exotic));
        }
        const shape_ref = blk: {
            // The direct-slot Shape capacity is qjs's ordinary root capacity
            // (`initial_prop_size == 2`), so take the same root lookup as `{}`
            // and constructor instances. The old exact-capacity entry point
            // duplicated that hot walk and dominated the Reserved2 route.
            //
            // Capacity remains part of the Object/Shape storage contract: an
            // over-reserved empty root can share this prototype and sit first
            // in the weak hash bucket. Keep the exact lookup as a cold repair
            // instead of adopting a Shape that claims more slots than the
            // trailing allocation owns.
            const ordinary_root = try rt.shapes.createObjectRootReserved(prototype);
            if (ordinary_root.prop_size == trailing_property_capacity) {
                @branchHint(.likely);
                break :blk ordinary_root;
            }
            rt.shapes.release(ordinary_root);
            break :blk try rt.shapes.createObjectRootWithPropertyCapacityReserved(
                prototype,
                trailing_property_capacity,
            );
        };
        std.debug.assert(shape_ref.prop_size == trailing_property_capacity);
        var shape_owned = true;
        errdefer if (shape_owned) rt.shapes.release(shape_ref);

        const alloc_size = objectBodyBytes(class.ids.object) + trailing_property_bytes;
        collectBeforeObjectAllocationPublishingShape(rt, shape_ref, alloc_size);
        const self = try allocCellConst(rt, class.ids.object, true);
        var initialized = false;
        errdefer if (initialized)
            destroyFromHeader(rt, &self.header)
        else
            freeRawCellConst(rt, self, class.ids.object, true);

        self.* = .{
            .header = .{},
            .weakref_count = trailing_property_allocation_bit,
            .class_id = class.ids.object,
            .flags = .{
                .class_payload_kind = .none,
                .has_exotic_methods = false,
            },
            .shape_ref = shape_ref,
            .prop_values = trailingPropertyStorageBase(self),
        };
        self.initArmPayload(null);
        std.debug.assert(!self.isWeakReferenceHolderClass());
        std.debug.assert(self.shape_ref.prop_count == 0);
        shape_owned = false;
        initialized = true;
        try rt.registerObjectWithBytes(self, alloc_size);
        initialized = false;
        return self;
    }

    pub fn createRegExpFromShape(rt: *JSRuntime, shape_ref: *shape.Shape) !*Object {
        std.debug.assert(shape_ref.prop_count == 1);
        std.debug.assert(shape_ref.props()[0].atom_id == atom.ids.lastIndex);
        const entries = [_]property.Entry{.{ .slot = .{ .data = JSValue.int32(0) } }};
        return createFromShape(rt, class.ids.regexp, shape_ref, &entries);
    }

    pub fn createRegExpMatchArrayFromShape(
        rt: *JSRuntime,
        shape_ref: *shape.Shape,
        match_index: i32,
        input_value: JSValue,
        groups_value: JSValue,
    ) !*Object {
        std.debug.assert(shape_ref.prop_count == 3);
        const entries = [_]property.Entry{
            .{ .slot = .{ .data = JSValue.int32(match_index) } },
            .{ .slot = .{ .data = input_value } },
            .{ .slot = .{ .data = groups_value } },
        };
        return createArrayFromShape(rt, shape_ref, &entries);
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

    /// Allocate an arguments object (unmapped or mapped) straight from its
    /// realm-owned initial Shape, consuming caller-prepared property cells —
    /// the zjs analogue of qjs js_build_arguments / js_build_mapped_arguments
    /// filling `JSProperty props[3]` with already-owned refs and transferring
    /// them wholesale into `JS_NewObjectFromShape` (quickjs.c:16154-16168,
    /// 16215-16232), whose props arm block-copies the cells (quickjs.c:
    /// 5727-5730). The general `createInternal` path re-derives class layout
    /// per call through the class definition plan and re-dups every borrowed
    /// slot against the shape FAM flags; both arguments classes are standard
    /// (`.ordinary` declared payload, no exotic methods, no inline layout), so
    /// their layout facts are hardcoded here exactly like qjs's
    /// JS_CLASS_ARGUMENTS/JS_CLASS_MAPPED_ARGUMENTS switch arm (quickjs.c:
    /// 5679-5698, empty fast-array union; the caller adopts the dense/var-ref
    /// window afterwards). `createArrayFromInitialShape` is the same mirror
    /// for dense arrays; `createPreparedPropertyTemplate` for property-shaped
    /// templates.
    pub fn createArgumentsFromShape(
        rt: *JSRuntime,
        class_id: class.ClassId,
        initial_shape: *shape.Shape,
        entries: []const property.Entry,
    ) !*Object {
        std.debug.assert(class_id == class.ids.arguments or class_id == class.ids.mapped_arguments);
        std.debug.assert(entries.len == initial_shape.prop_count);
        if (builtin.mode == .Debug) {
            // The hardcoded layout facts below must stay in lockstep with the
            // registered arguments class definitions the generic path
            // (createInternal) consults: `.ordinary` declared payload attaches
            // lazily (class_payload_kind stays `.none`), no inline payload, no
            // exotic methods, and construction leaves `fast_array` false (the
            // caller's dense/var-ref adoption flips it, exactly as after the
            // generic path). Divergence here would reroute mapped-arguments
            // index redefine/delete off the exotic slow path that nulls the
            // bound cell — the invariant apply's fully-bound window check
            // relies on to fall back to observable [[Get]].
            const definition = rt.classes.standardPlan(class_id);
            std.debug.assert(inlineClassPayloadLayoutForDefinition(definition) == null);
            std.debug.assert(definition.payload_kind == .ordinary);
            std.debug.assert(!payloadKindAllocates(definition.payload_kind));
            std.debug.assert(!classHasExoticMethods(class_id, definition.has_exotic));
        }

        // qjs JS_NewObjectFromShape consumes `props` unconditionally: copied
        // into the object on success, destroyed by the shape flags on
        // allocation failure (quickjs.c:5639-5646).
        var owned_entries_pending = true;
        errdefer if (owned_entries_pending) {
            const props = initial_shape.props();
            for (entries, 0..) |entry, index| {
                const entry_flags = property.Flags.fromBits(props[index].flags);
                destroyPropertySlot(rt, props[index].atom_id, entry_flags, entry.slot);
            }
        };

        // js_dup_shape on entry (quickjs.c:16165/16229); JS_NewObjectFromShape
        // consumes the Shape on every failure path (quickjs.c:5647).
        initial_shape.retain();
        var shape_owned = true;
        errdefer if (shape_owned) rt.shapes.release(initial_shape);

        // qjs allocates `prop[shape->prop_size]` (quickjs.c:5635); later named
        // appends trust `shape.prop_size` slots. The arguments shapes always
        // carry the three named cells, so the zero-capacity sentinel arm of
        // the generic path is dead here. Allocate the buffer before the block
        // cell so an allocation-triggered collection sees no unpublished cell.
        const property_capacity: usize = initial_shape.prop_size;
        std.debug.assert(property_capacity >= entries.len and entries.len != 0);
        const property_storage = try rt.allocRuntime(property.Entry, property_capacity);
        var property_storage_owned = true;
        errdefer if (property_storage_owned) rt.memory.free(property.Entry, property_storage);

        const alloc_size = objectBodyBytes(class_id);
        rt.collectBeforeObjectAllocation(alloc_size);
        const self = try allocCell(rt, class_id, false);
        var initialized = false;
        errdefer if (initialized)
            destroyFromHeader(rt, &self.header)
        else
            freeRawCell(rt, self, class_id, false);

        self.* = .{
            .header = .{},
            .class_id = class_id,
            .flags = .{
                .class_payload_kind = .none,
                .has_exotic_methods = false,
            },
            .shape_ref = initial_shape,
            .prop_values = property_storage.ptr,
        };
        // Null first word: qjs's empty fast-array union (quickjs.c:
        // 5695-5697) doubling as the no-payload sentinel — identical to
        // createInternal's arguments storage arm.
        self.initArmPayload(null);
        std.debug.assert(!self.isWeakReferenceHolderClass());
        if (comptime builtin.is_test) {
            auditWrite(.memcpy_bulk, .object_prop_values_memcpy);
            @memcpy(self.propertyStorageEntries(entries.len), entries);
        } else {
            @memcpy(self.propertyStorageEntries(entries.len), entries);
        }
        owned_entries_pending = false;
        property_storage_owned = false;
        shape_owned = false;
        self.refreshTraceShapeSummary();
        initialized = true;
        try rt.registerObjectWithBytes(self, alloc_size);
        initialized = false;
        return self;
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

        // qjs JS_NewObjectFromShape enters with an owned Shape and consumes it
        // on every failure path. Retain the prepared Shape before mirroring its
        // object-allocation GC boundary.
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

        // Side storage is the only fallible preparation after retaining the
        // shape. Finish it first, then service the qjs object boundary and take
        // the block cell immediately before initialization/publication.
        const alloc_size = objectBodyBytes(template.class_id);
        rt.collectBeforeObjectAllocation(alloc_size);
        const self = try allocCell(rt, template.class_id, false);
        var initialized = false;
        errdefer if (initialized)
            destroyFromHeader(rt, &self.header)
        else
            freeRawCell(rt, self, template.class_id, false);

        self.* = .{
            .header = .{},
            .class_id = template.class_id,
            .flags = .{
                .has_exotic_methods = template.flags.has_exotic_methods,
                .class_payload_kind = template.flags.class_payload_kind,
            },
            .shape_ref = shape_ref,
            .prop_values = if (property_capacity == 0) emptyPropertyStorageBase() else property_storage.ptr,
        };
        self.initArmPayload(null);
        switch (entry_ownership) {
            .borrowed => {
                const props = shape_ref.props();
                if (comptime builtin.is_test) {
                    auditWrite(.fam_slice, .object_prop_slot);
                    for (entries, 0..) |entry, index| {
                        const entry_flags = property.Flags.fromBits(props[index].flags);
                        self.propertyEntry(index).* = .{ .slot = entry.slot.dup(entry_flags) };
                    }
                } else {
                    for (entries, 0..) |entry, index| {
                        const entry_flags = property.Flags.fromBits(props[index].flags);
                        self.propertyEntry(index).* = .{ .slot = entry.slot.dup(entry_flags) };
                    }
                }
            },
            .owned => {
                if (comptime builtin.is_test) {
                    auditWrite(.memcpy_bulk, .object_prop_values_memcpy);
                    @memcpy(self.propertyStorageEntries(entries.len), entries);
                } else {
                    @memcpy(self.propertyStorageEntries(entries.len), entries);
                }
                owned_entries_pending = false;
            },
        }

        property_storage_owned = false;
        shape_owned = false;
        self.refreshTraceShapeSummary();
        initialized = true;
        try rt.registerObjectWithBytes(self, alloc_size);
        initialized = false;
        return self;
    }

    const PropertyTemplate = struct {
        shape_ref: *shape.Shape,
        entries: []const property.Entry,
    };

    fn createInternal(
        rt: *JSRuntime,
        class_id: class.ClassId,
        prototype: ?*Object,
        own_property_capacity: usize,
        property_template: ?PropertyTemplate,
    ) !*Object {
        // The class table may move while GC or any fallible preparation runs.
        // Keep only the minimal immutable scalars plus a generation-bearing
        // construction pin; never retain a `Record *` across that window.
        // Standard ids read the registration-time plan by value and skip the
        // pin object entirely: `abort`/`publishObject` take *Construction, so
        // touching one on the hot path escapes its alloca and pins every plan
        // field access to memory. Only dynamic ids materialize it.
        const is_standard_class = class_id < class.ids.init_count;
        var construction: class.Table.Construction = if (is_standard_class)
            undefined
        else
            try rt.classes.beginConstruction(class_id);
        defer if (!is_standard_class) construction.abort();
        const definition: class.Table.DefinitionPlan = if (is_standard_class)
            rt.classes.standardPlan(class_id)
        else
            construction.definition;
        const inline_layout = inlineClassPayloadLayoutForDefinition(definition);
        const alloc_size = if (inline_layout) |layout| layout.object_size else objectBodyBytes(class_id);
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
            try rt.shapes.createObjectRootReserved(prototype)
        else
            try rt.shapes.createObjectRootWithPropertyCapacityReserved(prototype, property_capacity);
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
        const payload_kind = definition.payload_kind;
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

        // zjs's property buffer and out-of-line class payload can each invoke
        // the memory-limit collector. Complete those fallible preparations
        // before taking a block cell. Then mirror qjs's js_trigger_gc boundary
        // immediately before the raw JSObject allocation, leaving only scalar
        // initialization, ownership transfers and no-fail publication after it.
        // The helper publishes a reserved cache-miss Shape before entering the
        // reentrant boundary, then roots it exactly like a published hash hit.
        collectBeforeObjectAllocationPublishingShape(rt, shape_ref, alloc_size);
        // obj64 ① step 2: fitting inline-payload classes take a block cell
        // (bitmap-enumerated, never linked). Over-aligned or oversized
        // leftovers keep the standalone aligned blob and live in the
        // `standalone_objects` side table, not on `gc_obj_list`.
        var inline_via_fam = false;
        const self = if (inline_layout) |layout| blk: {
            // The object-level threshold/force-GC hook just ran above. Enter
            // MemoryAccount directly so this same allocation does not request
            // a second collection (observable to test allocation probes and
            // unnecessarily expensive in force-GC builds).
            if (inlinePayloadBlockHeapFam(layout)) |fam| {
                inline_via_fam = true;
                break :blk try rt.memory.createWithFamNoTrigger(Object, fam);
            }
            try rt.gc.prepareStandaloneObject();
            const bytes = try rt.memory.allocAlignedBytesNoTrigger(layout.allocation_size, layout.allocation_alignment);
            break :blk @as(*Object, @ptrFromInt(@intFromPtr(bytes.ptr) + layout.object_offset));
        } else try allocCell(rt, class_id, false);
        var initialized = false;
        errdefer {
            if (initialized) {
                destroyFromHeader(rt, &self.header);
            } else if (inline_layout) |layout| {
                if (inline_via_fam) {
                    rt.memory.destroyWithFam(Object, self, layout.object_size - @sizeOf(Object));
                } else {
                    const bytes: [*]u8 = @ptrFromInt(@intFromPtr(self) - layout.object_offset);
                    rt.memory.freeAlignedBytes(bytes[0..layout.allocation_size], layout.allocation_alignment);
                }
            } else {
                freeRawCell(rt, self, class_id, false);
            }
        }
        if (inline_layout) |layout| {
            class_payload = inlineClassPayloadPtr(self, layout);
            class_payload_kind = .none;
        }
        const has_exotic_methods = classHasExoticMethods(class_id, definition.has_exotic);
        // Reacquire by id after the complete fallible window and validate the
        // pinned generation. An unregister requested mid-construction remains
        // pending; this exact in-flight object atomically transfers that pin to
        // its allocation before the object reaches the GC list. Standard ids
        // never pin, so publish (like the deferred abort) is dynamic-only.
        if (!is_standard_class) construction.publishObject();
        self.* = .{
            .header = .{},
            .class_id = class_id,
            .flags = .{
                .class_payload_kind = class_payload_kind,
                .has_exotic_methods = has_exotic_methods,
            },
            .shape_ref = shape_ref,
            .prop_values = if (property_capacity == 0) emptyPropertyStorageBase() else property_storage.ptr,
        };
        switch (class_id) {
            class.ids.bytecode_function,
            class.ids.generator_function,
            class.ids.async_function,
            class.ids.async_generator_function,
            => self.bytecodeArm().* = .{},
            // A null first word is simultaneously qjs's empty array pointer and
            // the no-payload sentinel. Counts/length stay zero in the remaining
            // words; Array.prototype may later use the pointer word for its
            // cold realm metadata while remaining non-dense.
            class.ids.array,
            class.ids.arguments,
            class.ids.mapped_arguments,
            => self.initArmPayload(null),
            class.ids.regexp => self.regexpArm().* = .{},
            else => self.initArmPayload(class_payload),
        }
        if (property_template) |template| {
            const props = template.shape_ref.props();
            if (comptime builtin.is_test) {
                auditWrite(.fam_slice, .object_prop_slot);
                for (template.entries, 0..) |entry, index| {
                    const entry_flags = property.Flags.fromBits(props[index].flags);
                    self.propertyEntry(index).* = .{ .slot = entry.slot.dup(entry_flags) };
                }
            } else {
                for (template.entries, 0..) |entry, index| {
                    const entry_flags = property.Flags.fromBits(props[index].flags);
                    self.propertyEntry(index).* = .{ .slot = entry.slot.dup(entry_flags) };
                }
            }
        }
        // Block-cell / slab FAM prefixes are already stamped; overwriting them
        // with standalone=true would destroy the block-cell marker and put the
        // object back on gc_obj_list.
        if (inline_layout != null and !inline_via_fam) self.initInlineClassPayloadGcPrefix();
        property_storage_owned = false;
        shape_owned = false;
        if (property_template != null) {
            self.refreshTraceShapeSummary();
        } else {
            std.debug.assert(self.shape_ref.prop_count == 0);
        }
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
            .none, .ordinary, .global => false,
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
            .realm_record => {
                const payload = try rt.createRuntime(RealmRecordPayload);
                payload.* = .{};
                return @ptrCast(payload);
            },
            .none, .ordinary, .global => unreachable,
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
            .finalization_registry => rt.memory.destroy(FinalizationRegistryPayload, @ptrCast(@alignCast(ptr))),
            .std_file => rt.memory.destroy(StdFilePayload, @ptrCast(@alignCast(ptr))),
            .disposable_stack => rt.memory.destroy(DisposableStackPayload, @ptrCast(@alignCast(ptr))),
            .realm_record => rt.destroyRuntime(RealmRecordPayload, @ptrCast(@alignCast(ptr))),
            .none, .ordinary, .global => {},
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
        const definition_view = maybe_record orelse return null;
        return inlineClassPayloadLayoutFromScalars(definition_view.inline_payload_size, definition_view.inline_payload_align);
    }

    fn inlineClassPayloadLayoutForDefinition(definition: class.Table.DefinitionPlan) ?InlineClassPayloadLayout {
        return inlineClassPayloadLayoutFromScalars(definition.inline_payload_size, definition.inline_payload_align);
    }

    /// Inline class payloads exist only for embedder-registered classes
    /// (`binding.zig`), which never select a wide union arm, so the body they
    /// trail is the narrow one. Asserted at every consumer that also holds the
    /// class id.
    pub const inline_payload_body_bytes: usize = @sizeOf(Object) + union_arm_min_bytes;

    fn inlineClassPayloadLayoutFromScalars(inline_payload_size: u32, inline_payload_align: u16) ?InlineClassPayloadLayout {
        if (inline_payload_size == 0) return null;
        const payload_align = std.mem.Alignment.fromByteUnits(inline_payload_align);
        const object_align = std.mem.Alignment.of(Object);
        const allocation_alignment = if (payload_align.compare(.gt, object_align)) payload_align else object_align;
        const object_offset = std.mem.alignForward(usize, 8, allocation_alignment.toByteUnits());
        const payload_offset = std.mem.alignForward(usize, inline_payload_body_bytes, payload_align.toByteUnits());
        const object_size = std.math.add(usize, payload_offset, inline_payload_size) catch return null;
        const allocation_size = std.math.add(usize, object_offset, object_size) catch return null;
        return .{
            .object_offset = object_offset,
            .payload_offset = payload_offset,
            .object_size = object_size,
            .allocation_size = allocation_size,
            .allocation_alignment = allocation_alignment,
        };
    }

    /// FAM bytes when this inline-payload class can live in the collector
    /// block heap with the payload's required alignment. `null` keeps the
    /// standalone aligned path (R5 leftover: over-aligned or oversized).
    fn inlinePayloadBlockHeapFam(layout: InlineClassPayloadLayout) ?usize {
        if (comptime !gc.block_heap_enabled) return null;
        const cell = gc.metadata_prefix_size + layout.object_size;
        if (!gc_block_heap.canAllocCellSize(cell)) return null;
        const payload_abs = gc.metadata_prefix_size + layout.payload_offset;
        if (payload_abs % layout.allocation_alignment.toByteUnits() != 0) return null;
        return layout.object_size - @sizeOf(Object);
    }

    fn initInlineClassPayloadGcPrefix(self: *Object) void {
        // Leftover inline-payload objects (over-aligned / oversized) live in a
        // raw aligned allocation and are freed via freeAlignedBytes, so their
        // prefix is a standalone one: no slab class to stamp, size_class
        // carries encoded heap bytes once registered. Fitting classes never
        // reach this helper; they keep the block-cell prefix from createWithFam.
        const meta: *gc.Metadata = @ptrFromInt(@intFromPtr(self) - 8);
        meta.* = .{ .alloc_info = .{ .standalone = true }, .flags = .{ .kind = .object } };
    }

    fn inlineClassPayloadPtr(self: *Object, layout: InlineClassPayloadLayout) *anyopaque {
        const bytes: [*]u8 = @ptrCast(self);
        return @ptrCast(bytes + layout.payload_offset);
    }

    /// Free the object's raw allocation from its immutable destruction plan.
    /// Plain (non-inline-payload) objects — ~every object — go straight to the
    /// typed slab free (the qjs `js_free_rt(rt, p)` tail of free_object,
    /// quickjs.c:6382); only inline-payload classes rederive the aligned
    /// layout, in the cold outlined arm.
    /// inline: without it LLVM outlines the three-caller body and the hot
    /// destroy tail pays a call that ships the whole spilled DefinitionPlan by
    /// pointer; inlined, the plain-object arm is the bare typed slab free and
    /// only `inline_payload_size` stays live across the teardown calls.
    inline fn freeObjectAllocation(rt: *JSRuntime, self: *Object, definition: class.Table.DefinitionPlan) void {
        if (definition.inline_payload_size != 0) {
            return freeInlinePayloadObjectAllocation(rt, self, definition);
        }
        // ③'s alloc/free size contract: both ends derive the tail from
        // `unionArmBytes(class_id)`, and `class_id` cannot change after
        // construction, so the free can never hand the allocator a size the
        // alloc did not request.
        if (self.hasTrailingPropertyAllocation()) {
            std.debug.assert(self.class_id == class.ids.object);
            return rt.memory.destroyConstFam(Object, comptime objectTailBytes(class.ids.object, true), self);
        }
        if (self.class_id == class.ids.object) {
            return rt.memory.destroyConstFam(Object, comptime objectTailBytes(class.ids.object, false), self);
        }
        rt.memory.destroyWithFam(Object, self, objectTailBytes(self.class_id, false));
    }

    noinline fn freeInlinePayloadObjectAllocation(rt: *JSRuntime, self: *Object, definition: class.Table.DefinitionPlan) void {
        const layout = inlineClassPayloadLayoutForDefinition(definition) orelse unreachable;
        // Block cells and any createWithFam slab fallback share the FAM free;
        // only the leftover standalone aligned blob uses object_offset.
        if (gc.Registry.isBlockCellHeader(&self.header) or !self.header.metaConst().alloc_info.standalone) {
            rt.memory.destroyWithFam(Object, self, layout.object_size - @sizeOf(Object));
            return;
        }
        const bytes: [*]u8 = @ptrFromInt(@intFromPtr(self) - layout.object_offset);
        rt.memory.freeAlignedBytes(bytes[0..layout.allocation_size], layout.allocation_alignment);
    }

    /// `InlineClassPayloadLayout.object_size` (== the byte count the register
    /// side stored via `registerObjectWithBytes`) as a bare scalar: the payload
    /// trails the Object struct at the payload's own alignment. The layout
    /// helper's overflow arm cannot fire for a registered u32 size + u16
    /// power-of-two alignment on a 64-bit target, so unlike
    /// `inlineClassPayloadLayoutFromScalars` there is no failure path — and no
    /// Alignment-enum round trip (rbit/clz) on the destroy hot path.
    fn inlineClassObjectSize(definition: class.Table.DefinitionPlan) usize {
        comptime std.debug.assert(@bitSizeOf(usize) == 64);
        std.debug.assert(definition.inline_payload_size != 0);
        std.debug.assert(std.math.isPowerOfTwo(definition.inline_payload_align));
        const payload_offset = std.mem.alignForward(usize, inline_payload_body_bytes, definition.inline_payload_align);
        return payload_offset + definition.inline_payload_size;
    }

    pub fn allocationSize(self: *const Object, rt: *const JSRuntime) usize {
        if (inlineClassPayloadLayout(rt.classes.recordPtr(self.class_id))) |layout| {
            std.debug.assert(unionArmBytes(self.class_id) == union_arm_min_bytes);
            return layout.object_size;
        }
        return @sizeOf(Object) + objectTailBytes(self.class_id, self.hasTrailingPropertyAllocation());
    }

    pub fn createArray(rt: *JSRuntime, prototype: ?*Object) !*Object {
        if (rt.initialArrayShapeForPrototype(prototype)) |initial_shape| {
            return createArrayFromShape(rt, initial_shape, &.{});
        }
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
            if (comptime builtin.is_test) {
                auditWrite(.memcpy_bulk, .object_iterator_cache_memcpy);
                @memcpy(next[0..len], rt.cached_iterator_next_entries);
            } else {
                @memcpy(next[0..len], rt.cached_iterator_next_entries);
            }
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
        if (rt.cached_iterator_next_entries.len == 0) return null;
        const slot = self.cachedIteratorNextSlotIfPresent(rt) orelse return null;
        return slot.*;
    }

    pub fn clearCachedIteratorNext(self: *Object, rt: *JSRuntime) void {
        if (rt.cached_iterator_next_entries.len == 0) return;
        const index = cachedIteratorNextEntryIndex(rt, self) orelse return;
        const old_cached = rt.cached_iterator_next_entries[index].value;
        rt.cached_iterator_next_entries[index].value = null;
        removeCachedIteratorNextEntryAt(rt, index);
        if (old_cached) |stored| stored.free(rt);
    }

    fn clearCachedIteratorNextWithoutFree(rt: *JSRuntime, self: *Object) void {
        if (rt.cached_iterator_next_entries.len == 0) return;
        const index = cachedIteratorNextEntryIndex(rt, self) orelse return;
        rt.cached_iterator_next_entries[index].value = null;
        removeCachedIteratorNextEntryAt(rt, index);
    }

    fn cachedIteratorNextSlotIfPresent(self: *const Object, rt: *JSRuntime) ?*?JSValue {
        if (rt.cached_iterator_next_entries.len == 0) return null;
        const index = cachedIteratorNextEntryIndex(rt, self) orelse return null;
        return &rt.cached_iterator_next_entries[index].value;
    }

    /// Narrow cross-file seam for the cycle collector's cached-edge walk.
    pub fn cachedIteratorNextSlotForCycleGc(self: *const Object, rt: *JSRuntime) ?*?JSValue {
        return self.cachedIteratorNextSlotIfPresent(rt);
    }

    fn cachedIteratorNextEntryIndex(rt: *const JSRuntime, self: *const Object) ?usize {
        if (rt.cached_iterator_next_entries.len == 0) return null;
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

    pub fn ensureOrdinaryPayload(self: *Object, rt: *JSRuntime) !*OrdinaryPayload {
        if (self.ordinaryPayload()) |payload| return payload;
        std.debug.assert(self.payloadArm().* == null);
        const payload = try rt.createRuntime(OrdinaryPayload);
        payload.* = .{};
        self.payloadArm().* = @ptrCast(payload);
        self.flags.class_payload_kind = .ordinary;
        return payload;
    }

    pub fn globalLexicals(self: *const Object, rt: *const JSRuntime) ?*Object {
        const ctx = rt.contextForGlobalIncludingConstructing(self) orelse return null;
        return ctx.lexicals;
    }

    pub fn setGlobalLexicals(self: *Object, rt: *JSRuntime, v: ?*Object) !void {
        const ctx = rt.contextForGlobalIncludingConstructing(self) orelse return error.InvalidBuiltinRegistry;
        ctx.lexicals = v;
    }

    // qjs u.global_object.uninitialized_vars accessors (quickjs.c:17069).
    pub fn globalUninitializedVars(self: *const Object) ?*Object {
        return if (self.globalPayloadConst()) |payload| payload.uninitialized_vars else null;
    }

    pub fn setGlobalUninitializedVars(self: *Object, rt: *JSRuntime, v: ?*Object) !void {
        (try self.ensureGlobalPayload(rt)).uninitialized_vars = v;
        // The side table is created on demand, the first time a global name is
        // captured before it is declared -- arbitrarily long after the global
        // object itself went old. It is a payload field, so no property funnel
        // covers it.
        if (v) |env| rt.gc.generationalBarrier(&self.header, &env.header);
    }

    pub fn ensureGlobalPayload(self: *Object, rt: *JSRuntime) !*GlobalPayload {
        if (self.globalPayload()) |payload| return payload;
        std.debug.assert(self.class_id == class.ids.global_object);
        const payload = try rt.createRuntime(GlobalPayload);
        payload.* = .{};
        self.payloadArm().* = @ptrCast(payload);
        self.flags.class_payload_kind = .global;
        return payload;
    }

    /// Transitional source-compatible spelling for internal fixtures.  It now
    /// establishes explicit global-object class identity; no realm state is
    /// attached to the object.
    pub fn ensureRealmPayload(self: *Object, rt: *JSRuntime) !*GlobalPayload {
        if (self.class_id == class.ids.object) self.class_id = class.ids.global_object;
        return self.ensureGlobalPayload(rt);
    }

    pub fn installOwnedRealmRef(self: *Object, rt: *JSRuntime, owner: *context_mod.RealmRef) !void {
        std.debug.assert(self.payloadArm().* == null);
        std.debug.assert(owner.borrow() != null);
        const payload = try rt.createRuntime(RealmRecordPayload);
        payload.* = .{ .realm = owner.* };
        owner.* = .{};
        self.payloadArm().* = @ptrCast(payload);
        self.flags.class_payload_kind = .realm_record;
    }

    pub fn realmContext(self: *const Object) ?*context_mod.RealmContext {
        if (self.flags.class_payload_kind != .realm_record) return null;
        const ptr = self.payloadArm().* orelse return null;
        const payload: *const RealmRecordPayload = @ptrCast(@alignCast(ptr));
        return payload.realm.borrow();
    }

    const bytecode_function_aux_tag: usize = 1;

    inline fn bytecodeFunctionAux(self: *Object) ?*BytecodeFunctionAux {
        if (!class.isBytecodeFunctionClass(self.class_id)) return null;
        const stored = self.bytecodeArm().*.home_or_aux orelse return null;
        const raw = @intFromPtr(stored);
        if ((raw & bytecode_function_aux_tag) == 0) return null;
        return @ptrFromInt(raw & ~bytecode_function_aux_tag);
    }

    inline fn bytecodeFunctionAuxConst(self: *const Object) ?*const BytecodeFunctionAux {
        if (!class.isBytecodeFunctionClass(self.class_id)) return null;
        const stored = self.bytecodeArm().*.home_or_aux orelse return null;
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
            if (self.bytecodeArm().*.home_or_aux) |stored| {
                std.debug.assert((@intFromPtr(stored) & bytecode_function_aux_tag) == 0);
                aux.home_object = @ptrCast(@alignCast(stored));
            }
            self.bytecodeArm().*.home_or_aux = encodeBytecodeFunctionAux(aux);
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
        std.debug.assert(self.payloadArm().* == null);
        self.payloadArm().* = payload;
        self.flags.class_payload_kind = .none;
    }

    /// The proof that word 0 really is a payload pointer and nothing else in
    /// the class-data region is live.
    ///
    /// Before obj64 ③ this was three "union bytes 8..24 are zero" assertions.
    /// The arm is now class-sized, so for a narrow class those bytes are NOT
    /// this object's memory and reading them is the out-of-bounds the knife
    /// introduces: the statement to check is the ARM WIDTH. Wide-armed classes
    /// that still reach here (String exotics keep a 24-byte arm defensively)
    /// keep the original zero proof, so no coverage is lost.
    inline fn assertOnlyPayloadWordIsLive(self: *const Object) void {
        if (comptime !std.debug.runtime_safety) return;
        if (unionArmBytes(self.class_id) == union_arm_min_bytes) return;
        std.debug.assert(self.arrayArm().*.count == 0);
        std.debug.assert(self.arrayArm().*.capacity == 0);
        std.debug.assert(self.arrayArm().*.length == 0);
    }

    pub fn externalClassPayload(self: *Object) ?*anyopaque {
        // `.none` is tri-state (ObjectStorage contract). This list excludes
        // non-payload inline/dense arms; trailing-inline payload classes stay
        // eligible because their word 0 really is the payload pointer. A new
        // inline/dense arm must join this exclusion before storing union data.
        if (self.isArray() or self.flags.fast_array or self.class_id == class.ids.mapped_arguments or self.flags.class_payload_kind != .none) return null;
        assertOnlyPayloadWordIsLive(self);
        std.debug.assert(self.payloadArm().* == null or @intFromPtr(self.payloadArm().*.?) != @alignOf(JSValue));
        return self.payloadArm().*;
    }

    pub fn externalClassPayloadConst(self: *const Object) ?*anyopaque {
        // Keep this exclusion and its Debug proof paired with the mutable arm.
        if (self.isArray() or self.flags.fast_array or self.class_id == class.ids.mapped_arguments or self.flags.class_payload_kind != .none) return null;
        assertOnlyPayloadWordIsLive(self);
        std.debug.assert(self.payloadArm().* == null or @intFromPtr(self.payloadArm().*.?) != @alignOf(JSValue));
        return self.payloadArm().*;
    }

    pub fn cachedFunctionProtoSlot(self: *Object, rt: *JSRuntime) !*?*Object {
        const ctx = rt.contextForGlobalIncludingConstructing(self) orelse return error.InvalidBuiltinRegistry;
        return &ctx.cached_function_proto;
    }

    pub fn setCachedFunctionProto(self: *Object, rt: *JSRuntime, prototype: ?*Object) !void {
        const ctx = rt.contextForGlobalIncludingConstructing(self) orelse return error.InvalidBuiltinRegistry;
        if (prototype) |stored| gc.retain(&stored.header);
        errdefer if (prototype) |stored| stored.value().free(rt);
        const old_prototype = ctx.cached_function_proto;
        ctx.cached_function_proto = prototype;
        if (old_prototype) |old| old.value().free(rt);
    }

    pub fn cachedFunctionProto(self: *const Object, rt: *const JSRuntime) ?*Object {
        const ctx = rt.contextForGlobalIncludingConstructing(self) orelse return null;
        return ctx.cached_function_proto;
    }

    pub fn cachedPromiseProtoSlot(self: *Object, rt: *JSRuntime) !*?*Object {
        const ctx = rt.contextForGlobalIncludingConstructing(self) orelse return error.InvalidBuiltinRegistry;
        return &ctx.cached_promise_proto;
    }

    pub fn setCachedPromiseProto(self: *Object, rt: *JSRuntime, prototype: ?*Object) !void {
        const ctx = rt.contextForGlobalIncludingConstructing(self) orelse return error.InvalidBuiltinRegistry;
        if (prototype) |stored| gc.retain(&stored.header);
        errdefer if (prototype) |stored| stored.value().free(rt);
        const old_prototype = ctx.cached_promise_proto;
        ctx.cached_promise_proto = prototype;
        if (old_prototype) |old| old.value().free(rt);
    }

    pub fn cachedPromiseProto(self: *const Object, rt: *const JSRuntime) ?*Object {
        const ctx = rt.contextForGlobalIncludingConstructing(self) orelse return null;
        return ctx.cached_promise_proto;
    }

    pub fn cachedRealmValueSlot(self: *Object, rt: *JSRuntime, slot: RealmValueSlot) !*?JSValue {
        const ctx = rt.contextForGlobalIncludingConstructing(self) orelse return error.InvalidBuiltinRegistry;
        return &ctx.cached_values[@intFromEnum(slot)];
    }

    pub fn cachedRealmValue(self: *const Object, rt: *const JSRuntime, slot: RealmValueSlot) ?JSValue {
        const ctx = rt.contextForGlobalIncludingConstructing(self) orelse return null;
        return ctx.cached_values[@intFromEnum(slot)];
    }

    pub fn cachedThrowTypeErrorIntrinsicSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        return self.cachedRealmValueSlot(rt, .throw_type_error_intrinsic);
    }

    pub fn cachedThrowTypeErrorIntrinsic(self: *const Object, rt: *const JSRuntime) ?JSValue {
        return self.cachedRealmValue(rt, .throw_type_error_intrinsic);
    }

    pub fn closeStdFile(self: *Object) void {
        _ = self.closeStdFileWithResult();
    }

    pub fn closeStdFileWithResult(self: *Object) c_int {
        const payload = self.stdFilePayload() orelse return 0;
        const file = payload.file orelse return 0;
        if (payload.is_stdio) return 0;
        payload.file = null;
        return runtime_mod.closeStdFileHandle(file, payload.is_popen);
    }

    fn enqueueDeferredStdFileClose(self: *Object, rt: *JSRuntime) void {
        const payload = self.stdFilePayload() orelse return;
        const file = payload.file orelse return;
        if (payload.is_stdio) return;
        payload.file = null;

        runtime_mod.enqueueDeferredStdFileClose(rt, file, payload.is_popen);
    }

    // ===== destroy / teardown =====
    pub fn destroyFromHeader(rt: *JSRuntime, header: anytype) align(16) void {
        const h: *gc.Header = gc.headerPtr(header);
        const self: *Object = fromHeader(h);
        const weakref_state = self.weakref_count;
        // qjs free_object (quickjs.c:6340-6391) for a plain JS Object: mark,
        // free slots, free prop[], js_free_shape, remove_gc_object, js_free.
        // Guards match K1: class_id==object, payload .none, no weakrefs,
        // not cycle/deinit. Extra has_weak_id / borrowed bits fall back so
        // this arm never skips table cleanup the general path still owns.
        // The general teardown is outlined — leaving it in this function
        // would keep the 0xf0 prologue on every sc_Pair.
        if (self.class_id == class.ids.object and
            self.flags.class_payload_kind == .none and
            weakReferenceCountFromState(weakref_state) == 0 and
            !self.flags.has_weak_id and
            !self.flags.is_borrowed_reference_holder)
        {
            const phase = rt.gc.phase;
            // Only `.deinit` is excluded. `.remove_cycles` used to be
            // excluded beside it -- refcounting's cycle collector needed more
            // from teardown than this arm provides, and an earlier attempt to
            // admit it tripped `enqueueZeroRef`'s `phase == .decref`
            // assertion. `.tracer_destroy` became a separate value precisely
            // so it could be admitted here: the tracer frees every object
            // inside such a window, so lumping the two together meant the
            // tracing build never once used its own fast teardown. Measured:
            // destruction cost the tracer 1.52 s of stopped time on raytrace
            // against rc's 0.50 s for the same objects. `.remove_cycles`
            // retired with rc; the exclusion is now `.deinit` alone.
            if (phase != .deinit) {
                @branchHint(.likely);
                destroyPlainObjectFast(
                    rt,
                    self,
                    phase == .tracer_destroy,
                    hasTrailingPropertyAllocationFromState(weakref_state),
                );
                return;
            }
        }
        destroyFromHeaderSlow(rt, h);
    }

    /// qjs free_object 6340-6391 ordinary-object arm. Inlined into
    /// `destroyFromHeader` so the hot symbol stays the same.
    /// `two_pass` folds in the only two things the general teardown does
    /// differently inside a two-pass window: a shape condemned by the same
    /// pass is not ours to decref, and the struct free waits for pass B
    /// because a sibling not yet processed may still dereference this
    /// header.
    inline fn destroyPlainObjectFast(rt: *JSRuntime, self: *Object, two_pass: bool, has_trailing_allocation: bool) void {
        self.header.meta().flags.mark = true;
        self.header.meta().flags.finalizing = true;

        const object_shape = self.shape_ref;
        const old_storage = self.prop_values;
        const alloc_size = @sizeOf(Object) + objectTailBytes(self.class_id, has_trailing_allocation);
        const old_property_capacity = self.propertyStorageCapacity();
        const old_storage_entries = self.propertyStorageEntries(old_property_capacity);
        const old_properties = old_storage_entries[0..object_shape.prop_count];
        const old_shape_props = object_shape.props()[0..@min(object_shape.prop_count, old_properties.len)];
        self.prop_values = if (has_trailing_allocation) trailingPropertyStorageBase(self) else emptyPropertyStorageBase();
        for (old_properties, 0..) |entry, index| {
            // qjs free_property (quickjs.c:6097-6113): data arm is !TMASK.
            // kind==data && !deleted is bits 3..5 == 0 (TMASK in 3-4, deleted in 5).
            const raw_flags: u6 = if (index < old_shape_props.len) old_shape_props[index].flags else 0;
            if (raw_flags & 0b111000 == 0) {
                entry.slot.data.freeFromPlainObjectDestroy(rt);
                continue;
            }
            const entry_flags = property.Flags.fromBits(raw_flags);
            if (entry_flags.deleted) continue;
            const entry_atom = if (index < old_shape_props.len) old_shape_props[index].atom_id else atom.null_atom;
            destroyPropertySlot(rt, entry_atom, entry_flags, entry.slot);
        }
        if (propertyStoragePointerIsExternal(self, old_storage)) rt.memory.free(property.Entry, old_storage_entries);
        // js_free_shape (quickjs.c:5320-5325): --rc, last-ref outlined.
        if (!(two_pass and headerIsCycleGarbage(&object_shape.header))) {
            rt.shapes.release(object_shape);
        }
        // No finalizer on this arm (qjs 6365-6367 is NULL for JS_CLASS_OBJECT).
        // qjs still writes shape=NULL as a fail-safe before the callback; the
        // allocation is about to be freed, so the tombstone would be a dead store.
        if (rt.cached_iterator_next_entries.len != 0) {
            @call(.never_inline, Object.clearCachedIteratorNext, .{ self, rt });
        }
        rt.unregisterObjectWithBytes(self, alloc_size);
        if (two_pass) {
            // Stage 3: this arm's own guards already established everything the
            // settlement predicate needs about the object (class 1, no weak
            // state), and `alloc_size` is the exact debit Pass B would make.
            if (object_gc.trySettleTracerBlockCorpse(rt, self, true, alloc_size)) return;
            rt.gc.deferCycleStructFree(&self.header);
            return;
        }
        // `destroyFromHeader` enters this arm only for `class.ids.object`, so
        // both tails are compile-time constants.
        std.debug.assert(self.class_id == class.ids.object);
        if (has_trailing_allocation) {
            rt.memory.destroyConstFam(Object, comptime objectTailBytes(class.ids.object, true), self);
        } else {
            rt.memory.destroyConstFam(Object, comptime objectTailBytes(class.ids.object, false), self);
        }
    }

    noinline fn destroyFromHeaderSlow(rt: *JSRuntime, header: *gc.Header) void {
        const self: *Object = fromHeader(header);
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
        header.meta().flags.finalizing = true;
        // Keep only immutable scalar destruction data across recursive cleanup.
        // A dynamic object's allocation owns its definition pin until the
        // allocation itself is freed, so the callback can be reacquired by id
        // and generation immediately before invocation.
        const destroying_class_id = self.class_id;
        const definition = rt.classes.destructionPlan(destroying_class_id) orelse unreachable;
        // qjs free_object never derives a layout at teardown: the malloc block
        // header already carries what the free needs (quickjs.c:1613-1617).
        // The full InlineClassPayloadLayout (offsets + Alignment enum +
        // overflow-checked adds) is only needed by the rare inline-payload
        // free, so it is rederived inside `freeObjectAllocation`'s cold arm
        // instead of being materialized (and spilled as a stack aggregate) on
        // every plain-object destroy.
        const has_inline_payload = definition.inline_payload_size != 0;
        // Size for GC free-accounting must be bit-for-bit the value the
        // register side stored (`layout.object_size` for inline-payload
        // classes, else @sizeOf(Object)); `inlineClassObjectSize` computes
        // exactly that scalar without the rest of the layout.
        const alloc_size = if (has_inline_payload)
            inlineClassObjectSize(definition)
        else
            @sizeOf(Object) + objectTailBytes(destroying_class_id, self.hasTrailingPropertyAllocation());
        // These intrusive/side-table links borrow storage owned by class
        // payloads, so detach them before that storage is destroyed. Heap-list
        // unlink and live-byte accounting deliberately remain at the qjs
        // remove_gc_object boundary below, after the class finalizer.
        rt.unregisterWeakReferenceHolder(self);
        // Same hoisted-entry-guard shape as the borrowed/std-file calls below:
        // the callee's own first check is `!flags.is_borrowed_reference_holder
        // -> return`, so the ~every-object destroy keeps the test inline and
        // never pays the outlined call.
        if (self.flags.is_borrowed_reference_holder) rt.unregisterBorrowedReferenceHolder(self);
        // qjs free_object keeps no borrowed-ref / std-file side tables, so the
        // plain-object hot free path must not call into either scan. Hoist each
        // helper's own entry guard to the call site: an object with no realm-
        // global borrowed identity (is_global, false for ~every object) and no
        // .std_file payload skips BOTH calls — the helpers keep their internal
        // guards for the rare live-resource path. (borrowed guard already no-ops
        // for non-global; pure dispatch-shape change, zero behavioral risk.)
        if (self.isGlobal() and rt.borrowed_reference_holders.len != 0) clearBorrowedReferencesForDestroyedObject(rt, self);
        if (self.flags.class_payload_kind == .std_file) self.enqueueDeferredStdFileClose(rt);
        const old_storage = self.prop_values;
        const has_trailing_allocation = self.hasTrailingPropertyAllocation();
        const old_property_capacity = self.propertyStorageCapacity();
        const old_storage_entries = self.propertyStorageEntries(old_property_capacity);
        const old_properties = old_storage_entries[0..self.shape_ref.prop_count];
        const old_shape_props = self.shape_ref.props()[0..@min(self.shape_ref.prop_count, old_properties.len)];
        self.prop_values = if (has_trailing_allocation) trailingPropertyStorageBase(self) else emptyPropertyStorageBase();
        for (old_properties, 0..) |entry, index| {
            const entry_flags = if (index < old_shape_props.len) property.Flags.fromBits(old_shape_props[index].flags) else property.Flags{};
            // qjs free_property (quickjs.c:6097-6113): one unlikely TMASK test,
            // then the untagged plain-data arm frees the slot value inline.
            // Only the tagged arms (accessor/var_ref/auto_init) take the
            // out-of-line path; a deleted entry (`atom == JS_ATOM_NULL` in
            // qjs, an undefined data slot there) has nothing to free.
            if (entry_flags.isData()) {
                entry.slot.data.free(rt);
                continue;
            }
            if (entry_flags.deleted) continue;
            const entry_atom = if (index < old_shape_props.len) old_shape_props[index].atom_id else atom.null_atom;
            destroyPropertySlot(rt, entry_atom, entry_flags, entry.slot);
        }
        if (propertyStoragePointerIsExternal(self, old_storage)) rt.memory.free(property.Entry, old_storage_entries);
        const object_shape = self.shape_ref;
        if (!(gc.phaseIsTwoPassTeardown(rt.gc.phase) and headerIsCycleGarbage(&object_shape.header))) {
            rt.shapes.release(object_shape);
        }
        self.shape_ref = finalizingShape();
        self.refreshTraceShapeSummary();
        // qjs free_object strips property storage and releases the shape before
        // reacquiring class_array[class_id].finalizer. The generation-bearing
        // live pin keeps this definition available while recursive cleanup runs;
        // only now may the callback observe the stripped but still registered
        // object. qjs runs this callback synchronously, before remove_gc_object
        // and before the raw allocation is freed.
        if (definition.has_payload_finalizer) {
            self.finalizeClassPayload(rt, definition.generation, has_inline_payload);
        }
        // Array elements live in qjs's class-specific union arm and are released
        // by the Array class finalizer, after the shape/prototype edge. Keep the
        // same order for zjs's direct dense-storage teardown. The iterator cache
        // is likewise class-specific state rather than an own-property slot.
        self.destroyArrayElements(rt);
        if (rt.gc.phase != .deinit) self.clearCachedIteratorNext(rt) else clearCachedIteratorNextWithoutFree(rt, self);
        // The non-array class payloads all share the single `u.payload`
        // union slot, discriminated by `class_payload_kind` — at most ONE is
        // ever live per object. A synchronous callback clears that payload and
        // its discriminant above, so this switch handles only definitions
        // without a payload finalizer.
        //
        // qjs free_object reaches class teardown through one nullable pointer
        // pair (class_array[p->class_id].finalizer / p->u.opaque). Mirror that
        // for the dominant teardown — an ordinary object that never allocated
        // a side payload — instead of paying the 21-arm jump-table dispatch:
        // `.none`, and `.ordinary` with a null payload, have nothing to
        // release (destroyOrdinaryPayload's own first check).
        const payload_kind = self.flags.class_payload_kind;
        const payload_dead = payload_kind == .none or
            (payload_kind == .ordinary and self.payloadArm().* == null);
        if (!payload_dead) switch (payload_kind) {
            .none => unreachable,
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
            .finalization_registry => self.destroyFinalizationRegistryPayload(rt),
            .std_file => self.destroyStdFilePayload(rt),
            .disposable_stack => self.destroyDisposableStackPayload(rt),
            .global => self.destroyGlobalPayload(rt),
            .realm_record => self.destroyRealmRecordPayload(rt),
        };
        // The callback and every class-specific owned edge run while the object
        // is still heap-accounted. This is qjs free_object's remove_gc_object
        // boundary: after it returns, callbacks must no longer observe the
        // object as live even when a weak husk keeps the raw struct allocated.
        rt.unregisterObjectWithBytes(self, alloc_size);
        // Cycle removal and runtime deinit both use a resource pass followed by
        // a struct-free pass: a not-yet-processed sibling (or a held Shape)
        // may still decref and therefore dereference this header. Defer the
        // allocation free until that resource pass completes (qjs free_object,
        // quickjs.c:6382).
        if (gc.phaseIsTwoPassTeardown(rt.gc.phase) or rt.gc.phase == .deinit) {
            // Stage 3, generic-teardown twin of the fast arm above. The class
            // predicate is spelled from state this path already loaded:
            // `has_inline_payload` comes from the same `destructionPlan` read
            // the widened Pass-B fast arm would repeat, and a standard id makes
            // `releaseObjectDefinition` a compare-and-return with no pin to
            // drop. Dynamic ids own a definition pin and stay on the park path.
            // Census §3.2: this arm carried 25.6%-31.6% of all block corpses
            // (array, mapped_arguments, bytecode_function, date), and on
            // raytrace their 3.1% sprinkle is what made whole-block settlement
            // impossible before the fast arm was widened.
            if (object_gc.trySettleTracerBlockCorpse(
                rt,
                self,
                destroying_class_id < class.ids.init_count and !has_inline_payload,
                alloc_size,
            )) return;
            rt.gc.deferCycleStructFree(&self.header);
            return;
        }
        // Outside cycle removal, zero-ref destruction may need to leave the
        // resource-stripped object as a weak husk. During REMOVE_CYCLES the
        // restored refcount must remain intact until every condemned incoming
        // edge has been released; Pass B below makes the keep/free decision,
        // exactly like qjs free_object + gc_free_cycles.
        if (self.weakReferenceCount() != 0) {
            gc.setHeaderWeakHusk(&self.header);
            self.header.meta().flags.mark = false;
            self.header.meta().flags.finalizing = false;
            return;
        }
        // qjs releases the weak-id mapping in its weak sweep, never per plain
        // object; only objects handed a weak id (has_weak_id) have an entry, so
        // gate the call — a plain object never enters takeWeakObjectIdentity just
        // to load the flag and return.
        if (self.flags.has_weak_id) _ = rt.takeWeakObjectIdentity(self);
        freeObjectAllocation(rt, self, definition);
        rt.classes.releaseObjectDefinition(destroying_class_id, definition.generation);
    }

    /// Pass-B fast-arm predicate: the corpse's physical release is exactly
    /// `MemoryAccount.destroy{,WithFam}` on the Object allocation, with no
    /// class-table release call and no inline-payload base fixup.
    ///
    /// Class 1 answers without touching the class table at all: `Object` is
    /// registered once by `Table.init` and re-registration returns
    /// `DuplicateClass`, so its plan is a compile-time known zero-payload
    /// record. Every other standard id needs the `standard_plans[id]` load
    /// because ids outside `standard_classes` (50..68) are unregistered and an
    /// embedding could in principle register one with an inline payload -- for
    /// those the allocation base is BEFORE the Object and a plain
    /// `destroy(Object, self)` would free the wrong address. The load is not a
    /// new cost: it is exactly the load the generic arm below already performs,
    /// so the widened arm is strictly fewer instructions than the generic arm
    /// for the ids it takes over (it drops the `destructionPlan` null/range
    /// branch and the `releaseObjectDefinition` call).
    ///
    /// Dynamic ids (>= `init_count`) stay on the generic arm: they own a
    /// definition pin that `releaseObjectDefinition` must drop.
    /// Public so the corpse census classifies against the predicate the code
    /// actually branches on rather than a restatement of it.
    pub inline fn passBFastArmEligible(rt: *const JSRuntime, class_id: class.ClassId) bool {
        if (class_id == class.ids.object) return true;
        if (class_id >= class.ids.init_count) return false;
        return rt.classes.standardPlan(class_id).inline_payload_size == 0;
    }

    /// Pass-B drain of a cycle-deferred object: its resources were freed by the
    /// resource pass; only the struct memory remains. Mirrors qjs Pass B
    /// (quickjs.c:6797). Pass B keeps only live-weakref husks before calling this.
    pub fn freeCycleDeferredStruct(rt: *JSRuntime, self: *Object) void {
        const class_id = self.class_id;
        // Constructor-created splay nodes are ordinary Objects, but the corpse
        // census (docs/corpse-census-2026-08-29.md §3.3) showed the remaining
        // 3%-26% are standard classes too -- array, mapped_arguments,
        // bytecode_function, date, for_in_iterator -- and for a standard id
        // `releaseObjectDefinition` is a single compare-and-return. Their only
        // real cost was that they made a corpse ineligible for the block-level
        // settlement stage 3 wants: on raytrace a 3.1% `mapped_arguments`
        // sprinkle took the share of whole-run-clean blocks from ~97% to 0.
        // The trailing two-slot allocation remains a physical property of the
        // object and is handled exactly as in the generic arm.
        if (passBFastArmEligible(rt, class_id)) {
            if (comptime std.debug.runtime_safety) {
                const definition = rt.classes.destructionPlan(class_id) orelse unreachable;
                std.debug.assert(definition.inline_payload_size == 0);
                // Load-bearing for the FAM accounting below: the debit must
                // be `@sizeOf(Object) + trailing_property_bytes`, and that
                // constant is only the right trailing size for the class-1
                // property layout (`verifyObjectPropertyStorageLayouts`
                // enforces the same rule from the arena checker side).
                std.debug.assert(!self.hasTrailingPropertyAllocation() or
                    class_id == class.ids.object);
            }
            if (self.flags.has_weak_id) _ = rt.takeWeakObjectIdentity(self);
            if (self.hasTrailingPropertyAllocation()) {
                return rt.memory.destroyConstFam(Object, comptime objectTailBytes(class.ids.object, true), self);
            }
            // The overwhelmingly common Pass-B corpse is a plain object; give
            // it the constant tail and leave the class switch to the rest.
            if (class_id == class.ids.object) {
                return rt.memory.destroyConstFam(Object, comptime objectTailBytes(class.ids.object, false), self);
            }
            rt.memory.destroyWithFam(Object, self, objectTailBytes(class_id, false));
            return;
        }
        const definition = rt.classes.destructionPlan(class_id) orelse unreachable;
        // The flag test belongs here, not behind the call. Almost no object
        // has a weak identity, and this runs on every corpse -- 41 M on
        // raytrace, 72 M on earley-boyer -- so the outlined call's prologue
        // was the whole cost for nearly all of them.
        if (self.flags.has_weak_id) _ = rt.takeWeakObjectIdentity(self);
        freeObjectAllocation(rt, self, definition);
        rt.classes.releaseObjectDefinition(class_id, definition.generation);
    }

    pub fn destroyDeadWeakHusk(rt: *JSRuntime, self: *Object) void {
        std.debug.assert(gc.headerIsReclaimableWeakHusk(&self.header));
        std.debug.assert(self.weakReferenceCount() == 0);
        std.debug.assert(!self.header.meta().flags.mark);
        const class_id = self.class_id;
        const definition = rt.classes.destructionPlan(class_id) orelse unreachable;
        _ = rt.takeWeakObjectIdentity(self);
        freeObjectAllocation(rt, self, definition);
        rt.classes.releaseObjectDefinition(class_id, definition.generation);
    }

    fn finalizeClassPayload(self: *Object, rt: *JSRuntime, generation: u64, inline_payload: bool) void {
        const payload_kind = self.flags.class_payload_kind;
        const finalized = rt.classes.runPayloadFinalizer(
            self.class_id,
            generation,
            @ptrCast(rt),
            @ptrCast(self),
            &self.payloadArm().*,
        );
        std.debug.assert(finalized);
        if (inline_payload) {
            // The callback owns only the contents; the bytes are part of the
            // Object allocation and are reclaimed by freeObjectAllocation.
            self.payloadArm().* = null;
            self.flags.class_payload_kind = .none;
            return;
        }
        var remaining_payload = self.payloadArm().*;
        self.payloadArm().* = null;
        self.flags.class_payload_kind = .none;
        destroyDetachedClassPayload(rt, self.class_id, payload_kind, &remaining_payload);
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
        var finalization_enqueue_blocked = false;
        var index: usize = 0;
        while (index < rt.borrowed_reference_holders.len) {
            const current = rt.borrowed_reference_holders[index];
            if (gc.headerRefCountIsZeroOrHusk(&current.header)) {
                rt.unregisterBorrowedReferenceHolder(current);
                continue;
            }
            if (!current.mayContainBorrowedReferences(rt)) {
                index += 1;
                continue;
            }
            gc.retain(&current.header);
            rt.markBorrowedWeakCleanupHolderSeen();
            current.clearBorrowedReferencesToDestroyedIdentities(rt, matcher, &finalization_enqueue_blocked);
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
            if (!gc.headerRefCountIsZeroOrHusk(&current.header)) {
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

    pub fn pruneBorrowedReferenceHolderIfEmpty(self: *Object, rt: *JSRuntime) void {
        if (!self.flags.is_borrowed_reference_holder) return;
        if (!self.hasBorrowedReferences(rt)) rt.unregisterBorrowedReferenceHolder(self);
    }

    fn hasBorrowedReferences(self: *const Object, _: *JSRuntime) bool {
        if (self.weakRefPayloadConst()) |payload| {
            if (payload.weak_target_identity != null) return true;
        }
        if (self.collectionPayloadConst()) |payload| {
            if (payload.weak_entries.len != 0) return true;
        }
        if (self.finalizationRegistryPayloadConst()) |payload| {
            if (payload.cells.len != 0) return true;
        }
        return false;
    }

    fn mayContainBorrowedReferences(self: *const Object, _: *JSRuntime) bool {
        if (self.weakRefPayloadConst()) |payload| {
            if (payload.weak_target_identity != null) return true;
        }
        if (self.collectionPayloadConst()) |payload| {
            if (payload.weak_entries.len != 0) return true;
        }
        if (self.finalizationRegistryPayloadConst()) |payload| {
            if (payload.cells.len != 0) return true;
        }
        return false;
    }

    /// Remove weak entries whose keys are in the condemned cycle partition.
    pub fn sweepCycleGarbageWeakCollectionEntriesForCycleGc(rt: *JSRuntime) void {
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

    fn clearBorrowedReferencesToDestroyedIdentities(
        self: *Object,
        rt: *JSRuntime,
        matcher: BorrowedIdentityMatcher,
        finalization_enqueue_blocked: *bool,
    ) void {
        self.clearWeakIdentities(rt, matcher, finalization_enqueue_blocked);
        self.pruneBorrowedReferenceHolderIfEmpty(rt);
    }

    fn clearWeakIdentities(
        self: *Object,
        rt: *JSRuntime,
        matcher: BorrowedIdentityMatcher,
        finalization_enqueue_blocked: *bool,
    ) void {
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
            if (cell.isPending()) finalization_enqueue_blocked.* = true;
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

            if (cell.state == .queued) continue;
            if (cell.isActive()) {
                cell.state = .pending_enqueue;
                if (finalization_enqueue_blocked.*) {
                    finalization_payload.cells[write_index] = cell;
                    write_index += 1;
                    continue;
                }
                finalization_payload.cells[read_index].state = .queued;
                object_gc.enqueueFinalizationCleanup(rt, finalization_payload, cell.held_value);
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

    pub const post_a_object_size_baseline: usize = 192;
    comptime {
        std.debug.assert(@sizeOf(Object) + union_arm_max_bytes <= post_a_object_size_baseline / 2);
    }

    // ===== iterator* =====
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
        return &self.arrayArm().*.length;
    }

    pub fn arrayLength(self: *const Object) u32 {
        return if (self.isArray()) self.arrayArm().*.length else 0;
    }

    /// Set the JS-observable `.length` only. Faithful to qjs `set_array_length`
    /// (quickjs.c:9447-9455): growing length above capacity keeps `fast_array`
    /// (the slots `[array_count, length)` simply become holes), it does NOT
    /// drop to sparse and it NEVER touches `array_count`. Callers that must
    /// also shrink the dense extent pair this with `truncateArrayElements`.
    pub fn setArrayLength(self: *Object, length: u32) void {
        std.debug.assert(self.isArray());
        self.arrayArm().*.length = length;
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
            self.arrayArm().*.capacity == 0;
    }

    pub inline fn isProxy(self: *const Object) bool {
        return self.class_id == class.ids.proxy;
    }

    /// Global-object identity is a class, independent of the owning realm
    /// context's state and lifetime.
    pub inline fn isGlobal(self: *const Object) bool {
        return self.class_id == class.ids.global_object;
    }

    pub inline fn hasNullPrototype(self: *const Object) bool {
        return self.shape_ref.proto == null;
    }

    pub inline fn hasPropertyStorage(self: *const Object) bool {
        return self.prop_values != emptyPropertyStorageBase();
    }

    inline fn weakReferenceCountFromState(state: u32) u32 {
        return state & weakref_count_mask;
    }

    inline fn hasTrailingPropertyAllocationFromState(state: u32) bool {
        return state & trailing_property_allocation_bit != 0;
    }

    pub inline fn weakReferenceCount(self: *const Object) u32 {
        return weakReferenceCountFromState(self.weakref_count);
    }

    pub inline fn retainWeakReference(self: *Object) void {
        std.debug.assert(self.weakReferenceCount() != weakref_count_mask);
        self.weakref_count += 1;
    }

    pub inline fn releaseWeakReference(self: *Object) void {
        std.debug.assert(self.weakReferenceCount() != 0);
        self.weakref_count -= 1;
    }

    pub inline fn hasTrailingPropertyAllocation(self: *const Object) bool {
        return hasTrailingPropertyAllocationFromState(self.weakref_count);
    }

    pub inline fn propertyStorageIsInline(self: *const Object) bool {
        return self.prop_values == trailingPropertyStorageBase(self);
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

    // ===== collection* / weak* =====
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

    /// Park a cursor inside this collection's entry array. Mirrors the
    /// `mr->ref_count++` an enumerator takes on the record it is sitting on
    /// (js_map_iterator_next quickjs.c:52605, js_map_forEach quickjs.c:52320).
    pub fn retainCollectionCursor(self: *Object) void {
        const payload = self.collectionPayload() orelse return;
        payload.live_cursors += 1;
    }

    /// Mirrors `map_decref_record` (quickjs.c:52089-52096). The
    /// `collectionPayload() orelse return` guard is the zjs form of qjs's
    /// `JS_IsLiveObject(rt, it->obj)` check in js_map_iterator_finalizer
    /// (quickjs.c:52521): during a cycle-collector resource pass the target map
    /// may already have shed its payload, and then there is nothing left to
    /// unpin.
    pub fn releaseCollectionCursor(self: *Object) void {
        const payload = self.collectionPayload() orelse return;
        if (payload.live_cursors != 0) payload.live_cursors -= 1;
    }

    pub fn collectionLiveCursors(self: *const Object) usize {
        if (self.collectionPayloadConst()) |payload| return payload.live_cursors;
        return 0;
    }

    /// Park this Map/Set iterator's cursor on its target collection, once.
    /// Mirrors `mr->ref_count++` in js_map_iterator_next (quickjs.c:52605):
    /// taken when the iterator settles on a position, not when it is created,
    /// so an iterator that never stepped pins nothing.
    pub fn retainCollectionIteratorCursor(self: *Object) void {
        const payload = self.iteratorPayload() orelse return;
        if (payload.collection_cursor_held) return;
        if (self.class_id != class.ids.map_iterator and self.class_id != class.ids.set_iterator) return;
        const target = payload.target orelse return;
        const target_object = objectFromValue(target) orelse return;
        target_object.retainCollectionCursor();
        payload.collection_cursor_held = true;
    }

    /// Drop a Map/Set iterator's hold on its target collection: releases the
    /// entry-array cursor and then the target reference itself. Mirrors
    /// js_map_iterator_next's end-of-enumeration arm (quickjs.c:52608-52613),
    /// which decrefs the current record before dropping `it->obj`.
    pub fn detachCollectionIteratorTarget(self: *Object, rt: *JSRuntime) void {
        const payload = self.iteratorPayload() orelse return;
        const target = payload.target orelse return;
        releaseIteratorCollectionCursor(self.class_id, payload);
        payload.target = null;
        target.free(rt);
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
        if (comptime builtin.is_test) {
            auditWrite(.memcpy_bulk, .object_collection_memcpy);
            @memcpy(next[0..entries_slot.*.len], entries_slot.*);
        } else {
            @memcpy(next[0..entries_slot.*.len], entries_slot.*);
        }
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
        if (comptime builtin.is_test) {
            auditWrite(.fam_slice, .object_collection_store);
            refreshed_entries.*[index] = entry;
        } else {
            refreshed_entries.*[index] = entry;
        }
        // Map/Set entries live in a payload slice, not in property slots, so
        // they miss every property-store barrier. This is the single point
        // every strong entry is appended through.
        rt.gc.generationalBarrier(&self.header, entry.key.cycleMarkHeader());
        rt.gc.generationalBarrier(&self.header, entry.value.cycleMarkHeader());
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
        if (comptime builtin.is_test) {
            auditWrite(.memcpy_bulk, .object_weak_collection_memcpy);
            @memcpy(next[0..entries_slot.*.len], entries_slot.*);
        } else {
            @memcpy(next[0..entries_slot.*.len], entries_slot.*);
        }
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

    pub fn finalizationRegistryRealmContext(self: *const Object) ?*context_mod.RealmContext {
        const payload = self.finalizationRegistryPayloadConst() orelse return null;
        return payload.realm.borrow();
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
        var read_index: usize = 0;
        var write_index: usize = 0;
        while (read_index < entries.*.len) : (read_index += 1) {
            const cell = entries.*[read_index];
            const matches = cell.isActive() and
                cell.unregister_token_identity != null and
                cell.unregister_token_identity.? == token_identity;
            if (matches) {
                removed = true;
                cell.destroy(rt);
                continue;
            }

            if (write_index != read_index) entries.*[write_index] = cell;
            write_index += 1;
        }
        entries.* = entries.*.ptr[0..write_index];
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
        if (comptime builtin.is_test) {
            auditWrite(.memcpy_bulk, .object_finalization_memcpy);
            @memcpy(next[0..payload.cells.len], payload.cells);
        } else {
            @memcpy(next[0..payload.cells.len], payload.cells);
        }
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
        var root_frame = runtime_mod.ValueRootFrame{
            .values = &root_values,
        };
        root_frame.activate(rt);
        defer root_frame.deactivate(rt);

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
        // §9.3: reserve the cleanup job slot at registration so sweep never
        // allocates a record. The cell owns the reservation until enqueue or
        // destroy.
        try rt.job_queue.reserveEntries(1);
        errdefer rt.job_queue.releaseReservedEntries(1);
        refreshed_entries.*[index] = .{
            .target_identity = target_identity,
            .held_value = rooted_held_value.dup(),
            .unregister_token_identity = unregister_token_identity,
        };
        // `held_value` is the cell's one strong edge (the target and the
        // unregister token are weak identities, not traced). A registry is
        // registered against for as long as it lives, so every `register()`
        // after the first minor is an old-to-young store, and the sticky mark on
        // the registry stops the trace before `visitFinalizationCell` runs.
        rt.gc.generationalBarrier(&self.header, rooted_held_value.cycleMarkHeader());
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
        hint: DisposalHint,
        method_kind: DisposableMethodKind,
    ) !void {
        const payload = self.disposableStackPayload() orelse {
            std.debug.assert(self.flags.class_payload_kind == .disposable_stack);
            unreachable;
        };
        if (payload.resources.len == payload.resource_capacity) {
            const new_capacity = if (payload.resource_capacity == 0) @as(usize, 4) else payload.resource_capacity * 2;
            const next = try rt.allocRuntime(DisposableResource, new_capacity);
            errdefer rt.memory.free(DisposableResource, next);
            if (payload.resources.len != 0) {
                if (comptime builtin.is_test) {
                    auditWrite(.memcpy_bulk, .object_disposable_memcpy);
                    @memcpy(next[0..payload.resources.len], payload.resources);
                } else {
                    @memcpy(next[0..payload.resources.len], payload.resources);
                }
            }
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
            .hint = hint,
            .method_kind = method_kind,
        };
        // The resource list lives in this object's payload, so the stack owns
        // both values.
        rt.gc.generationalBarrier(&self.header, resource_value.cycleMarkHeader());
        rt.gc.generationalBarrier(&self.header, method.cycleMarkHeader());
    }

    pub fn disposableStackHasAsyncHint(self: *const Object) bool {
        const payload = self.disposableStackPayloadConst() orelse return false;
        for (payload.resources) |resource| {
            if (resource.hint == .async) return true;
        }
        return false;
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
        std.debug.assert(self.payloadArm().* == null);
        const payload = try rt.createRuntime(VarRefPayload);
        payload.* = .{};
        self.payloadArm().* = @ptrCast(payload);
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
        // The slot lives in this object's own var_ref payload, so the object is
        // the owner. (Not to be confused with `VarRef.setVarRefValue`, which
        // stores into a cell and takes the barrier there.)
        rt.gc.generationalBarrier(&self.header, next_value.cycleMarkHeader());
        if (old_value) |stored| stored.free(rt);
    }

    pub fn setOptionalValueSlot(self: *Object, rt: *JSRuntime, slot: *?JSValue, next_value: ?JSValue) !void {
        errdefer if (next_value) |stored_value| stored_value.free(rt);
        const old_value = slot.*;
        slot.* = next_value;
        // The receiver is the owner, which is what the generational barrier
        // needs (§8.3): a minor re-traces owners, so an old object gaining a
        // young child has to be remembered. Compiles away outside generational
        // builds.
        if (next_value) |stored| rt.gc.generationalBarrier(&self.header, stored.cycleMarkHeader());
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

    // ===== typed* / byte storage =====
    pub fn ensureTypedArrayPayload(self: *Object, rt: *JSRuntime) !void {
        if (self.typedArrayPayload() != null) return;
        const payload = try rt.createRuntime(TypedArrayPayload);
        payload.* = .{};
        self.payloadArm().* = @ptrCast(payload);
        self.flags.class_payload_kind = .typed_array;
    }

    /// Initialize a TypedArray/DataView payload and link it into its backing
    /// ArrayBuffer's weak view list. Takes ownership of `buffer_value`.
    ///
    /// This is the zjs counterpart of QuickJS `typed_array_init`: all view
    /// constructors go through one operation so cached count/data state and
    /// finalizer-safe list membership cannot diverge from the strong buffer
    /// edge.
    pub fn initTypedArrayView(
        self: *Object,
        rt: *JSRuntime,
        buffer_value: JSValue,
        byte_offset: usize,
        element_size: u32,
        fixed_length: ?u32,
        kind: u8,
    ) !void {
        var owned_buffer = buffer_value;
        errdefer owned_buffer.free(rt);

        const backing_object = objectFromValue(owned_buffer) orelse return error.TypeError;
        if (backing_object.class_id != class.ids.array_buffer and backing_object.class_id != class.ids.shared_array_buffer) {
            return error.TypeError;
        }
        const backing_payload = backing_object.bufferPayload() orelse return error.TypeError;

        try self.ensureTypedArrayPayload(rt);
        const payload = self.typedArrayPayload() orelse unreachable;
        if (payload.backing_payload) |old_backing| old_backing.detachView(payload);

        // Publish the owned edge before the weak link. Replacing an old edge
        // can immediately finalize its ArrayBuffer; it is already unlinked.
        const next_buffer = owned_buffer;
        owned_buffer = JSValue.undefinedValue();
        try self.setOptionalValueSlot(rt, &payload.buffer, next_buffer);
        payload.byte_offset = byte_offset;
        payload.element_size = element_size;
        payload.fixed_length = fixed_length;
        payload.kind = kind;
        backing_payload.attachView(payload);
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
            payload.updateViews();
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
            payload.updateViews();
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
            payload.updateViews();
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
            payload.updateViews();
            return;
        }
        std.debug.assert(self.flags.class_payload_kind == .buffer);
        unreachable;
    }

    /// Change the visible prefix of an already-committed SharedArrayBuffer
    /// store, then refresh all linked view state. This is QuickJS's shared
    /// resize branch: the store identity and pointer stay stable.
    pub fn setSharedByteStorageLength(self: *Object, new_length: usize) !void {
        const payload = self.bufferPayload() orelse return error.TypeError;
        const store = payload.shared_store orelse return error.TypeError;
        if (new_length > store.bytes.len) return error.RangeError;
        payload.bytes = store.bytes[0..new_length];
        payload.updateViews();
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

    /// Single-lookup view of the typed-array payload for the hot element
    /// read/write legs — qjs reads its cached `u.array` state once per access;
    /// this returns the payload pointer so the interpreter fast legs read
    /// kind/element_size/byte_offset/fixed_length/buffer without re-resolving
    /// the payload through five separate accessors.
    pub fn typedArrayPayloadFast(self: *const Object) ?*const TypedArrayPayload {
        return self.typedArrayPayloadConst();
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
        return &self.propertyEntry(0).*.slot.data;
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
        self.payloadArm().* = @ptrCast(payload);
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
        std.debug.assert(self.arrayArm().*.count == 0 and self.arrayArm().*.capacity == 0);
        if (count == 0) return &.{};

        const backing = try rt.memory.alloc(JSValue, count);
        self.arrayArm().*.values = backing.ptr;
        self.arrayArm().*.count = @intCast(count);
        self.arrayArm().*.capacity = @intCast(count);
        self.arrayArm().*.length = @intCast(count);
        self.markIndexedProperties(rt);

        const refs = self.argumentsVarRefsMut();
        @memset(refs, null);
        return refs;
    }

    /// Dense element buffer of an UNMAPPED arguments object, for
    /// `build_arg_list`'s JS_CLASS_ARGUMENTS arm (quickjs.c:41185-41196), which
    /// reads `p->u.array.u.values[i]` directly instead of running [[Get]] per
    /// index. `fast_array` is the same dense-extent guard qjs tests, so an
    /// arguments object that lost its dense representation falls back.
    pub fn unmappedArgumentsDenseValues(self: *const Object) []const JSValue {
        if (self.class_id != class.ids.arguments or !self.flags.fast_array) return &.{};
        if (self.arrayArm().*.count == 0) return &.{};
        std.debug.assert(self.arrayArm().*.capacity >= self.arrayArm().*.count);
        return self.arrayArm().*.values[0..@as(usize, @intCast(self.arrayArm().*.count))];
    }

    /// Var-ref window of a MAPPED arguments object whose every index is still
    /// bound to its frame slot, for `build_arg_list`'s JS_CLASS_MAPPED_ARGUMENTS
    /// arm (quickjs.c:41188-41191). qjs guards that arm with `p->fast_array`,
    /// which redefining or deleting an index clears; zjs records the same fact
    /// per element by nulling the cell (`deleteMappedArgumentsBinding`, reached
    /// from delete and from any accessor/non-writable redefine). A single
    /// unbound index therefore has to send the whole list back to observable
    /// [[Get]] — that index may now resolve to an own accessor or to the
    /// prototype chain.
    pub fn fullyBoundMappedArgumentsVarRefs(self: *const Object) ?[]const ?*var_ref_mod.VarRef {
        if (self.hasExoticMethods() or self.proxyTarget() != null) return null;
        const refs = self.argumentsVarRefs();
        if (refs.len == 0) return null;
        for (refs) |cell| {
            if (cell == null) return null;
        }
        return refs;
    }

    pub fn argumentsVarRefs(self: *const Object) []const ?*var_ref_mod.VarRef {
        if (self.class_id != class.ids.mapped_arguments or self.arrayArm().*.count == 0) return &.{};
        std.debug.assert(self.arrayArm().*.capacity >= self.arrayArm().*.count);
        const backing = self.arrayArm().*.values[0..@as(usize, @intCast(self.arrayArm().*.capacity))];
        const cells = std.mem.bytesAsSlice(?*var_ref_mod.VarRef, std.mem.sliceAsBytes(backing));
        return cells[0..@as(usize, @intCast(self.arrayArm().*.count))];
    }

    pub fn argumentsVarRefsMut(self: *Object) []?*var_ref_mod.VarRef {
        if (self.class_id != class.ids.mapped_arguments or self.arrayArm().*.count == 0) return &.{};
        std.debug.assert(self.arrayArm().*.capacity >= self.arrayArm().*.count);
        const backing = self.arrayArm().*.values[0..@as(usize, @intCast(self.arrayArm().*.capacity))];
        const cells = std.mem.bytesAsSlice(?*var_ref_mod.VarRef, std.mem.sliceAsBytes(backing));
        return cells[0..@as(usize, @intCast(self.arrayArm().*.count))];
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
        var root_frame = runtime_mod.rootValues(.{&rooted_target});
        root_frame.activate(rt);
        defer root_frame.deactivate(rt);

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
        const retained = target.value().dup();
        rt.keepAliveWeakRefTarget(retained);
        return retained;
    }

    // ===== fast* array paths =====
    pub fn arrayElementStorageMode(self: *const Object) ArrayStorageMode {
        return if (self.flags.fast_array) .dense else .sparse;
    }

    pub fn arrayElements(self: *const Object) []JSValue {
        if (!self.flags.fast_array or self.arrayArm().*.count == 0) return &.{};
        std.debug.assert(self.arrayArm().*.capacity >= self.arrayArm().*.count);
        std.debug.assert(self.arrayArm().*.length >= self.arrayArm().*.count);
        return self.arrayArm().*.values[0..@as(usize, @intCast(self.arrayArm().*.count))];
    }

    fn arrayElementsMut(self: *Object) []JSValue {
        if (!self.flags.fast_array or self.arrayArm().*.count == 0) return &.{};
        std.debug.assert(self.arrayArm().*.capacity >= self.arrayArm().*.count);
        std.debug.assert(self.arrayArm().*.length >= self.arrayArm().*.count);
        return self.arrayArm().*.values[0..@as(usize, @intCast(self.arrayArm().*.count))];
    }

    fn allocatedArrayElements(self: *Object) []JSValue {
        if (self.arrayArm().*.capacity == 0) return &.{};
        return self.arrayArm().*.values[0..@as(usize, @intCast(self.arrayArm().*.capacity))];
    }

    pub fn arrayElementsCapacity(self: *const Object) usize {
        return @intCast(self.arrayArm().*.capacity);
    }

    pub fn isFastArray(self: *const Object) bool {
        return self.isArray() and self.flags.fast_array;
    }

    pub fn isFastArrayIndexInBounds(self: *const Object, index: u32) bool {
        return self.flags.fast_array and index < self.arrayArm().*.count;
    }

    pub fn fastArrayElementAt(self: *const Object, index: u32) JSValue {
        std.debug.assert(self.isFastArrayIndexInBounds(index));
        return self.arrayArm().*.values[@intCast(index)];
    }

    pub fn fastArrayElementSlot(self: *Object, index: u32) *JSValue {
        std.debug.assert(self.isFastArrayIndexInBounds(index));
        return &self.arrayArm().*.values[@intCast(index)];
    }

    pub fn fastArrayElementDup(self: *const Object, index: u32) ?JSValue {
        if (!self.isFastArrayIndexInBounds(index)) return null;
        return self.arrayArm().*.values[@intCast(index)].dup();
    }

    /// Indexed read of a MAPPED arguments object — qjs JS_GetPropertyValue's
    /// JS_CLASS_MAPPED_ARGUMENTS arm (quickjs.c:9047-9049), which sits beside
    /// the JS_CLASS_ARRAY/ARGUMENTS arms and dereferences the element's var-ref
    /// cell (`*p->u.array.u.var_refs[idx]->pvalue`). The dense arm cannot serve
    /// this class: `u.array.values` holds JSVarRef pointers, not JSValues.
    ///
    /// qjs takes a whole object out of the fast representation when any index is
    /// redefined (convert_fast_array_to_array, quickjs.c:9262); zjs records the
    /// same fact per element by nulling the cell, so an unbound index falls
    /// through to the full path while its neighbours keep the fast read.
    /// noinline: this is the rarest of the indexed-read arms, and letting it
    /// inline into `fastDenseArrayElementValue` grew that hot helper enough to
    /// cost 26% cycles on a plain-call benchmark that never touches arguments
    /// (instructions unchanged — pure layout). The hot `OP_get_array_el`
    /// handler uses `mappedArgumentsIntElementDup` directly (qjs
    /// JS_GetPropertyValue JS_CLASS_MAPPED_ARGUMENTS, quickjs.c:9047-9049).
    pub noinline fn mappedArgumentsElementDup(self: *const Object, index: u32) ?JSValue {
        return mappedArgumentsIntElementDup(self, index);
    }

    /// qjs JS_GetPropertyValue mapped arm (quickjs.c:9047-9049):
    /// `JS_DupValue(ctx, *p->u.array.u.var_refs[idx]->pvalue)` after
    /// `idx >= count` reject. Inlined into `op_get_array_el` only.
    pub inline fn mappedArgumentsIntElementDup(self: *const Object, index: u32) ?JSValue {
        if (self.class_id != class.ids.mapped_arguments) return null;
        const refs = self.argumentsVarRefs();
        if (index >= refs.len) return null;
        const cell = refs[index] orelse return null;
        return cell.pvalue.*.dup();
    }

    pub fn setFastArrayElementDup(self: *Object, rt: *JSRuntime, index: u32, new_value: JSValue) bool {
        if (!self.isFastArrayIndexInBounds(index)) return false;
        const slot = &self.arrayArm().*.values[@intCast(index)];
        const old = slot.*;
        if (comptime builtin.is_test) {
            auditWrite(.fam_slice, .object_dense_store);
            slot.* = new_value.dup();
        } else {
            slot.* = new_value.dup();
        }
        rt.gc.generationalBarrier(&self.header, new_value.cycleMarkHeader());
        old.free(rt);
        return true;
    }

    /// Owned-value counterpart of `setFastArrayElementDup`. The value is
    /// consumed only when this returns true; false leaves ownership with the
    /// caller. Mirrors QuickJS `set_value` for OP_put_array_el.
    pub fn setFastArrayElementOwned(self: *Object, rt: *JSRuntime, index: u32, new_value: JSValue) bool {
        if (!self.isFastArrayIndexInBounds(index)) return false;
        if (comptime builtin.is_test) {
            auditWrite(.fam_slice, .object_dense_store);
            replaceOwnedValue(rt, &self.arrayArm().*.values[@intCast(index)], new_value);
        } else {
            replaceOwnedValue(rt, &self.arrayArm().*.values[@intCast(index)], new_value);
        }
        rt.gc.generationalBarrier(&self.header, new_value.cycleMarkHeader());
        return true;
    }

    /// Active-bytecode counterpart of `setFastArrayElementOwned`. The VM owns
    /// `new_value` and has already established the runtime-teardown exclusion
    /// carried by `freeDuringActiveBytecode`; false still leaves ownership with
    /// the caller.
    pub fn setFastArrayElementOwnedDuringActiveBytecode(self: *Object, rt: *JSRuntime, index: u32, new_value: JSValue) bool {
        if (!self.isFastArrayIndexInBounds(index)) return false;
        const slot = &self.arrayArm().*.values[@intCast(index)];
        const old_value = slot.*;
        if (comptime builtin.is_test) {
            auditWrite(.fam_slice, .object_dense_store);
            slot.* = new_value;
        } else {
            slot.* = new_value;
        }
        rt.gc.generationalBarrier(&self.header, new_value.cycleMarkHeader());
        old_value.freeDuringActiveBytecode(rt);
        return true;
    }

    pub fn adoptDenseArrayElementsAssumingEmpty(self: *Object, elements: []JSValue) void {
        std.debug.assert(self.isArray());
        std.debug.assert(self.arrayArm().*.count == 0);
        std.debug.assert(self.arrayArm().*.capacity == 0);
        self.arrayArm().*.values = elements.ptr;
        self.arrayArm().*.count = @intCast(elements.len);
        self.arrayArm().*.capacity = @intCast(elements.len);
        // Fully-dense adoption: the logical length equals the dense extent.
        self.arrayArm().*.length = @intCast(elements.len);
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
        std.debug.assert(self.arrayArm().*.count == 0);
        std.debug.assert(self.arrayArm().*.capacity == 0);
        if (elements.len != 0) self.arrayArm().*.values = elements.ptr;
        self.arrayArm().*.count = @intCast(elements.len);
        self.arrayArm().*.capacity = @intCast(elements.len);
        self.arrayArm().*.length = @intCast(elements.len);
        self.flags.fast_array = true;
        if (elements.len != 0) self.markIndexedProperties(rt);
    }

    pub fn clearFastArray(self: *Object) void {
        if (!self.isArray()) return;
        std.debug.assert(self.arrayArm().*.capacity == 0);
        self.flags.fast_array = false;
    }

    pub fn setArraySparseLength(self: *Object, length: u32) void {
        std.debug.assert(self.isArray());
        std.debug.assert(self.arrayArm().*.capacity == 0);
        // Sparse arrays carry no dense extent: count is 0, length is the
        // JS-observable `.length`. (Invariant 5: sparse => array_count == 0.)
        self.arrayArm().*.count = 0;
        self.arrayArm().*.length = length;
        self.flags.fast_array = false;
    }

    pub fn resetFastArrayEmpty(self: *Object) void {
        std.debug.assert(self.isArray());
        std.debug.assert(self.arrayArm().*.capacity == 0);
        self.arrayArm().*.count = 0;
        self.arrayArm().*.length = 0;
        self.flags.fast_array = true;
    }

    pub fn takeLastFastArrayElement(self: *Object) ?JSValue {
        if (!self.isArray() or !self.flags.fast_array or self.arrayArm().*.count == 0) return null;
        self.arrayArm().*.count -= 1;
        return self.arrayArm().*.values[@intCast(self.arrayArm().*.count)];
    }

    /// Pop the last element of a FULLY DENSE fast array (count == length),
    /// lowering BOTH the dense extent and the JS `.length` by one. Returns null
    /// for an empty or holey array (`length > count`) so the caller falls back
    /// to the generic [[Delete last]] + set-length path that handles tail holes.
    /// Mirrors the pop fast path's "delete last, length-=1" pair.
    pub fn takeLastFullyDenseFastArrayElement(self: *Object) ?JSValue {
        if (!self.isArray() or !self.flags.fast_array) return null;
        if (self.arrayArm().*.count == 0 or self.arrayArm().*.count != self.arrayArm().*.length) return null;
        self.arrayArm().*.count -= 1;
        self.arrayArm().*.length -= 1;
        return self.arrayArm().*.values[@intCast(self.arrayArm().*.count)];
    }

    pub fn borrowLastFastArrayElement(self: *Object) ?*JSValue {
        if (!self.isArray() or !self.flags.fast_array or self.arrayArm().*.count == 0) return null;
        return &self.arrayArm().*.values[@intCast(self.arrayArm().*.count - 1)];
    }

    pub fn shrinkFastArrayByOne(self: *Object) void {
        std.debug.assert(self.isArray() and self.flags.fast_array and self.arrayArm().*.count != 0);
        self.arrayArm().*.count -= 1;
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
            self.arrayArm().*.count = 0;
            self.arrayArm().*.capacity = 0;
            self.arrayArm().*.length = 0;
            if (allocated.len != 0) rt.memory.free(JSValue, allocated);
            return;
        }
        if (!self.flags.fast_array and self.arrayArm().*.capacity == 0) return;
        if (self.flags.fast_array) {
            var index: usize = 0;
            const count: usize = @intCast(self.arrayArm().*.count);
            while (index < count) : (index += 1) self.arrayArm().*.values[index].free(rt);
        } else {
            std.debug.assert(self.arrayArm().*.capacity == 0);
        }
        const allocated = self.allocatedArrayElements();
        self.arrayArm().*.count = 0;
        self.arrayArm().*.capacity = 0;
        self.arrayArm().*.length = 0;
        self.flags.fast_array = false;
        if (allocated.len != 0) rt.memory.free(JSValue, allocated);
    }

    fn freeArrayElementBufferAfterMove(self: *Object, rt: *JSRuntime) void {
        std.debug.assert(!self.flags.fast_array or self.arrayArm().*.count == 0);
        const allocated = self.allocatedArrayElements();
        self.arrayArm().*.capacity = 0;
        self.flags.fast_array = false;
        if (allocated.len != 0) rt.memory.free(JSValue, allocated);
    }

    fn ensureArrayBufferCapacity(self: *Object, rt: *JSRuntime, needed_len: usize) !void {
        const old_capacity: usize = @intCast(self.arrayArm().*.capacity);
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
                self.arrayArm().*.values = next.ptr;
                self.arrayArm().*.capacity = @intCast(next_capacity);
                return;
            }
        }
        const next = try rt.allocRuntime(JSValue, next_capacity);
        errdefer rt.memory.free(JSValue, next);
        if (self.flags.fast_array and self.arrayArm().*.count != 0) {
            const count: usize = @intCast(self.arrayArm().*.count);
            if (comptime builtin.is_test) {
                auditWrite(.memcpy_bulk, .object_dense_memcpy);
                @memcpy(next[0..count], self.arrayArm().*.values[0..count]);
            } else {
                @memcpy(next[0..count], self.arrayArm().*.values[0..count]);
            }
        }
        self.arrayArm().*.values = next.ptr;
        self.arrayArm().*.capacity = @intCast(next_capacity);
        if (old_allocated.len != 0) rt.memory.free(JSValue, old_allocated);
    }

    pub fn appendUninitializedFastArraySlot(self: *Object, rt: *JSRuntime) !*JSValue {
        const index = self.arrayArm().*.count;
        try self.ensureArrayBufferCapacity(rt, @as(usize, @intCast(index)) + 1);
        self.arrayArm().*.count = index + 1;
        self.flags.fast_array = true;
        // Every dense append reaches its storage through here and then writes
        // the slot itself, in four different callers. Remembering the owner at
        // the one shared point is what keeps a young element reachable from an
        // old array visible to the minor, whose sticky marks stop the trace at
        // the array.
        rt.gc.rememberOwnerForBulkWrite(&self.header);
        return &self.arrayArm().*.values[@intCast(index)];
    }

    pub fn fastArrayEnsureCapacity(self: *Object, rt: *JSRuntime, needed: u32) !void {
        try self.ensureArrayBufferCapacity(rt, @intCast(needed));
    }

    pub fn fastArrayValuesPtr(self: *const Object) ?[*]JSValue {
        if (!self.isFastArray() or self.arrayArm().*.count == 0) return null;
        return self.arrayArm().*.values;
    }

    pub fn fastArrayCount(self: *const Object) u32 {
        return if (self.isFastArray()) self.arrayArm().*.count else 0;
    }

    pub fn fastArrayCapacity(self: *const Object) u32 {
        return self.arrayArm().*.capacity;
    }

    pub fn fastArrayValues(self: *const Object) []JSValue {
        return self.arrayElements();
    }

    pub fn fastArrayValuesMut(self: *Object) []JSValue {
        return self.arrayElementsMut();
    }

    pub fn arrayElementsForCount(self: *const Object) []const JSValue {
        if (!self.flags.fast_array or self.arrayArm().*.count == 0) return &.{};
        return self.arrayArm().*.values[0..@as(usize, @intCast(self.arrayArm().*.count))];
    }

    pub fn setFastArrayCountAssumeCapacity(self: *Object, count: u32) void {
        std.debug.assert(count <= self.arrayArm().*.capacity);
        self.arrayArm().*.count = count;
        self.flags.fast_array = true;
    }

    pub fn fastArraySlotAssumeCapacity(self: *Object, index: u32) *JSValue {
        std.debug.assert(index < self.arrayArm().*.capacity);
        return &self.arrayArm().*.values[@intCast(index)];
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

    // ===== promise* =====
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

    pub fn promiseReactionsCapacitySlot(self: *Object) *usize {
        if (self.promisePayload()) |payload| return &payload.reactions_capacity;
        std.debug.assert(self.flags.class_payload_kind == .promise);
        unreachable;
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
        return @ptrCast(@alignCast(self.payloadArm().*.?));
    }

    /// Attach every open cell in this generator's parked frame to the object
    /// that owns its backing storage. Idempotent across repeated suspensions.
    pub fn attachGeneratorOpenVarRefOwners(self: *Object, rt: *JSRuntime) void {
        const execution = self.generatorPayloadPtr().execution orelse return;
        const owner = self.value();
        for (execution.suspended.storage.frame.open_var_refs) |maybe_cell| {
            const cell = maybe_cell orelse continue;
            cell.attachOpenOwner(rt, owner);
        }
    }

    // ===== generator* =====
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

    // ===== function* =====
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
        return self.nativeRecordAssumeCFunction();
    }

    /// Caller already proved `class_id == c_function` (K1: skip the repeat).
    pub fn nativeRecordAssumeCFunction(self: *const Object) ?*const host_function.InternalRecord {
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
        realm: *context_mod.RealmContext,
    };

    pub fn nativeCallTarget(self: *const Object) ?NativeCallTarget {
        if (self.class_id != class.ids.c_function) return null;
        const payload = self.functionPayloadConst() orelse return null;
        const record = payload.native.call_cache orelse return null;
        const realm = payload.native.realm.borrow() orelse return null;
        return .{
            .record = record,
            .realm = realm,
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
    /// share one RealmContext lookup, mirroring a direct JSContext field read.
    pub inline fn installedRealmRegExpLegacyStatics(self: *Object, rt: *JSRuntime) ?*RegExpLegacyStatics {
        const ctx = rt.contextForGlobalIncludingConstructing(self) orelse return null;
        if (ctx.cached_values[@intFromEnum(RealmValueSlot.regexp_constructor)] == null) return null;
        return ctx.regexp_legacy_statics;
    }

    pub fn ensureInstalledRealmRegExpLegacyStatics(self: *Object, rt: *JSRuntime) !?*RegExpLegacyStatics {
        const ctx = rt.contextForGlobalIncludingConstructing(self) orelse return null;
        if (ctx.cached_values[@intFromEnum(RealmValueSlot.regexp_constructor)] == null) return null;
        if (ctx.regexp_legacy_statics) |legacy| return legacy;
        const legacy = try rt.createRuntime(RegExpLegacyStatics);
        legacy.* = .{};
        ctx.regexp_legacy_statics = legacy;
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
        if (tag != .none) {
            const expected_class = if (tag.usesCallerRealm()) class.ids.c_function_data else class.ids.c_function;
            std.debug.assert(self.class_id == expected_class);
        }
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

    pub fn addArrayBuiltinMarker(self: *Object, rt: *JSRuntime, marker: ArrayBuiltinMarker) !bool {
        if (marker == .none) return true;
        const payload = try self.ensureFunctionRarePayload(rt);
        return setArrayBuiltinMarker(payload, marker);
    }

    pub fn addTypedArrayBuiltinMarker(self: *Object, rt: *JSRuntime, marker: TypedArrayBuiltinMarker) !bool {
        if (marker == .none) return true;
        const payload = try self.ensureFunctionRarePayload(rt);
        return setTypedArrayBuiltinMarker(payload, marker);
    }

    pub fn addArrayIteratorKind(self: *Object, rt: *JSRuntime, kind: u8) !bool {
        if (kind == 0) return true;
        const payload = try self.ensureFunctionRarePayload(rt);
        return setArrayIteratorKind(payload, kind);
    }

    pub fn addIteratorIdentityFunction(self: *Object, rt: *JSRuntime) !bool {
        const payload = try self.ensureFunctionRarePayload(rt);
        payload.iterator_identity = true;
        return true;
    }

    pub fn addArrayIteratorNextFunction(self: *Object, rt: *JSRuntime) !bool {
        const payload = try self.ensureFunctionRarePayload(rt);
        payload.array_iterator_next = true;
        return true;
    }

    pub fn addThrowTypeErrorIntrinsicFunction(self: *Object, rt: *JSRuntime) !void {
        const payload = try self.ensureFunctionRarePayload(rt);
        payload.throw_type_error_intrinsic = true;
        payload.internal_callable_tag = .throw_type_error_intrinsic;
    }

    pub fn addAsyncIteratorAsyncDisposeFunction(self: *Object, rt: *JSRuntime) !bool {
        const payload = try self.ensureFunctionRarePayload(rt);
        payload.async_iterator_async_dispose = true;
        return true;
    }

    pub fn addAsyncGeneratorPrototypeMethod(self: *Object, rt: *JSRuntime) !bool {
        const payload = try self.ensureFunctionRarePayload(rt);
        payload.async_generator_method = true;
        return true;
    }

    pub fn addIteratorHelperMethod(self: *Object, rt: *JSRuntime, method_id: u8) !bool {
        if (method_id == 0) return true;
        const payload = try self.ensureFunctionRarePayload(rt);
        if (payload.iterator_helper_method != 0 and payload.iterator_helper_method != method_id) return false;
        payload.iterator_helper_method = method_id;
        return true;
    }

    pub fn addAsyncFromSyncIteratorMethod(self: *Object, rt: *JSRuntime, method_id: u8) !bool {
        if (method_id == 0) return true;
        const payload = try self.ensureFunctionRarePayload(rt);
        if (payload.async_from_sync_iterator_method != 0 and payload.async_from_sync_iterator_method != method_id) return false;
        payload.async_from_sync_iterator_method = method_id;
        return true;
    }

    pub fn addDisposableStackMethod(self: *Object, rt: *JSRuntime, method_id: u8) !bool {
        if (method_id == 0) return true;
        const payload = try self.ensureFunctionRarePayload(rt);
        return setDisposableStackMethod(payload, method_id);
    }

    pub fn addAsyncDisposableStackMethod(self: *Object, rt: *JSRuntime, method_id: u8) !bool {
        if (method_id == 0) return true;
        const payload = try self.ensureFunctionRarePayload(rt);
        return setAsyncDisposableStackMethod(payload, method_id);
    }

    pub fn addCollectionMethodOwnerClass(self: *Object, rt: *JSRuntime, owner_class: class.ClassId) !bool {
        if (owner_class == class.invalid_class_id) return true;
        const payload = try self.ensureFunctionRarePayload(rt);
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
        // `next_value` is owned and consumed on both success and failure. The
        // finalized FunctionBytecode is already the execution record, so
        // attachment is a no-allocation pointer publication just like qjs
        // `js_closure2`'s `p->u.func.function_bytecode = b` transfer.
        errdefer next_value.free(rt);
        if (!next_value.isFunctionBytecode()) return error.InvalidBytecode;
        std.debug.assert(class.isBytecodeFunctionClass(self.class_id));
        const header = next_value.objectHeader() orelse return error.InvalidBytecode;
        std.debug.assert(header.meta().flags.kind == .function_bytecode);
        const fb: *FunctionBytecode = @alignCast(@fieldParentPtr("header", header));
        const old_fb = self.bytecodeArm().*.function_bytecode;
        self.bytecodeArm().*.function_bytecode = fb;
        // A FunctionBytecode is a traced heap object, and a closure gaining one
        // is an ordinary owner-to-child store. Closures are created lazily and
        // repeatedly against long-lived function objects, so this is the
        // old-to-young direction far more often than not.
        rt.gc.generationalBarrier(&self.header, &fb.header);
        if (old_fb) |old| gc.release(rt, &old.header);
    }

    /// Direct qjs `u.func` view for a proven bytecode-function object.
    pub inline fn bytecodeFunctionStoragePtr(self: *Object) *BytecodeFunctionStorage {
        std.debug.assert(class.isBytecodeFunctionClass(self.class_id));
        std.debug.assert(self.flags.class_payload_kind == .function);
        return &self.bytecodeArm().*;
    }

    pub inline fn bytecodeFunctionStoragePtrConst(self: *const Object) *const BytecodeFunctionStorage {
        std.debug.assert(class.isBytecodeFunctionClass(self.class_id));
        std.debug.assert(self.flags.class_payload_kind == .function);
        return &self.bytecodeArm().*;
    }

    pub fn functionBytecode(self: *const Object) ?JSValue {
        if (!class.isBytecodeFunctionClass(self.class_id)) return null;
        const fb = self.bytecodeArm().*.function_bytecode orelse return null;
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

    /// Realm global for an active generator/async continuation, derived from
    /// the saved current function just like qjs
    /// `JSAsyncFunctionState.frame.cur_func -> JSFunctionBytecode.realm`.
    /// Completed generators have released that execution owner and therefore
    /// return null; their prototype method continues in its current call view.
    pub fn generatorFunctionRealmGlobalPtr(self: *const Object) ?*Object {
        const stored = self.generatorFunctionBytecode() orelse return null;
        const function_bytecode = functionBytecodeFromValue(stored) orelse return null;
        const realm = function_bytecode.realmContext() orelse return null;
        return realm.global;
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

    pub fn functionCaptures(self: *const Object) []*var_ref_mod.VarRef {
        if (!class.isBytecodeFunctionClass(self.class_id)) return &.{};
        return self.bytecodeArm().*.captureSlice();
    }

    /// Borrow the nullable module closure table during construction/linking.
    /// Callers must mutate it only through the owned replace/clear helpers below;
    /// ordinary execution uses `functionCaptures` after `sealModuleCaptures`.
    pub fn moduleCaptureSlots(self: *const Object) []const ?*var_ref_mod.VarRef {
        if (!class.isBytecodeFunctionClass(self.class_id)) return &.{};
        return self.bytecodeArm().*.captureSlots();
    }

    /// qjs `js_closure2` (quickjs.c:17276-17280): `js_mallocz` the capture
    /// array and attach it to the function object *before* the fill loop so
    /// the object is the sole GC root. Null slots are skipped by mark/destroy.
    /// Inline: qjs does this mallocz inside js_closure2, not as a sibling call.
    pub inline fn allocateNullCaptureSlots(self: *Object, rt: *JSRuntime, count: usize) !void {
        if (!class.isBytecodeFunctionClass(self.class_id)) return error.InvalidBytecode;
        const storage = &self.bytecodeArm().*;
        const fb = storage.function_bytecode orelse return error.InvalidBytecode;
        if (count != fb.closureVarCount()) return error.InvalidBytecode;
        if (storage.var_refs != BytecodeFunctionStorage.emptyVarRefs()) return error.InvalidBytecode;
        if (count == 0) return;

        const slots = try rt.memory.alloc(?*var_ref_mod.VarRef, count);
        @memset(slots, null);
        storage.var_refs = slots.ptr;
    }

    /// Allocate the one and only module capture array with every slot null.
    /// The attached FB fixes its exact length; a mismatch or second allocation
    /// is invalid bytecode and leaves the function untouched.
    pub fn allocateNullModuleCaptureSlots(self: *Object, rt: *JSRuntime, count: usize) !void {
        return allocateNullCaptureSlots(self, rt, count);
    }

    /// Mutable view of the attached capture array during js_closure2 fill.
    pub inline fn mutableCaptureSlots(self: *Object) []?*var_ref_mod.VarRef {
        std.debug.assert(class.isBytecodeFunctionClass(self.class_id));
        return self.bytecodeArm().*.captureSlots();
    }

    /// Replace one module capture slot, transferring the caller's owned cell
    /// reference on success.  An out-of-range index does not consume `cell`.
    pub fn replaceModuleCaptureSlotOwned(
        self: *Object,
        rt: *JSRuntime,
        index: usize,
        cell: *var_ref_mod.VarRef,
    ) !void {
        if (!class.isBytecodeFunctionClass(self.class_id)) return error.InvalidBytecode;
        const slots = self.bytecodeArm().*.captureSlots();
        if (index >= slots.len) return error.InvalidBytecode;

        const old = slots[index];
        slots[index] = cell;
        if (old) |old_cell| old_cell.freeCell(rt);
    }

    /// Roll one indexed module-import slot back to its pre-link null state.
    /// The previously installed cell is consumed on success; an invalid index
    /// changes nothing.
    pub fn clearModuleImportCaptureSlot(self: *Object, rt: *JSRuntime, index: usize) !void {
        if (!class.isBytecodeFunctionClass(self.class_id)) return error.InvalidBytecode;
        const slots = self.bytecodeArm().*.captureSlots();
        if (index >= slots.len) return error.InvalidBytecode;

        const old = slots[index];
        slots[index] = null;
        if (old) |old_cell| old_cell.freeCell(rt);
    }

    /// Validate the module capture table before ordinary execution.  Sealing is
    /// allocation-free and records no parallel state: rollback may clear an
    /// import slot and a later successful link may validate the same array again.
    pub fn sealModuleCaptures(self: *const Object) !void {
        if (!class.isBytecodeFunctionClass(self.class_id)) return error.InvalidBytecode;
        const fb = self.bytecodeArm().*.function_bytecode orelse return error.InvalidBytecode;
        const slots = self.bytecodeArm().*.captureSlots();
        if (slots.len != fb.closureVarCount()) return error.InvalidBytecode;
        for (slots) |slot| {
            if (slot == null) return error.InvalidBytecode;
        }
    }

    /// Find one closure cell by its immutable FB metadata. Used for the
    /// language's hidden arrow captures (`this` / `new.target`) on cold semantic
    /// paths such as direct eval and super; ordinary opcodes index cells
    /// directly and never scan.
    pub fn functionCaptureCell(self: *const Object, name: atom.Atom) ?*var_ref_mod.VarRef {
        if (!class.isBytecodeFunctionClass(self.class_id)) return null;
        const fb = self.bytecodeArm().*.function_bytecode orelse return null;
        const captures = self.bytecodeArm().*.captureSlots();
        for (fb.closureVar(), 0..) |capture, index| {
            if (capture.var_name == name and index < captures.len) return captures[index];
        }
        return null;
    }

    /// Replace the closure-captures slice, releasing the previous cells —
    /// the cell-typed `setValueSlice` (ownership of `next_cells` transfers).
    pub fn setFunctionCaptures(self: *Object, rt: *JSRuntime, next_cells: []*var_ref_mod.VarRef) void {
        std.debug.assert(class.isBytecodeFunctionClass(self.class_id));
        var old_cells = self.bytecodeArm().*.captureSlots();
        if (self.bytecodeArm().*.function_bytecode) |fb| {
            std.debug.assert(next_cells.len == fb.closureVarCount());
        }
        self.bytecodeArm().*.var_refs = if (next_cells.len == 0)
            BytecodeFunctionStorage.emptyVarRefs()
        else
            @ptrCast(next_cells.ptr);
        destroyOptionalVarRefCellSlice(rt, &old_cells);
    }

    pub fn functionHomeObject(self: *const Object) ?*Object {
        if (!class.isBytecodeFunctionClass(self.class_id)) return null;
        if (self.bytecodeFunctionAuxConst()) |aux| return aux.home_object;
        const stored = self.bytecodeArm().*.home_or_aux orelse return null;
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
            self.bytecodeArm().*.home_or_aux = if (home_object) |next| @ptrCast(next) else null;
        }
        if (old_home_object) |old| old.value().free(rt);
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
        // The sites array is built after the Error instance exists, so a minor
        // in between promotes the instance and leaves this an old-to-young
        // payload store with no funnel to catch it. `setErrorStack` next to it
        // needs nothing: its value is a string, and strings are not registered
        // with the collector at all, so they are never condemned.
        rt.gc.generationalBarrier(&self.header, next_value.cycleMarkHeader());
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

    pub fn promiseCombinatorRemainingSlot(self: *Object, rt: *JSRuntime) !*i32 {
        const payload = try self.ensureOrdinaryPayload(rt);
        return &payload.promise_combinator_remaining;
    }

    pub fn promiseCombinatorRemaining(self: *const Object) i32 {
        if (self.ordinaryPayloadConst()) |payload| return payload.promise_combinator_remaining;
        return 0;
    }

    pub fn functionRealmGlobalSlot(self: *Object, rt: *JSRuntime) !*?JSValue {
        std.debug.assert(self.flags.class_payload_kind == .function);
        return &(try self.ensureFunctionRarePayload(rt)).realm_global;
    }

    pub fn functionRealmGlobal(self: *const Object) ?JSValue {
        if (self.functionRarePayloadConst()) |payload| return payload.realm_global;
        return null;
    }

    pub fn setFunctionRealmGlobalPtr(self: *Object, rt: *JSRuntime, realm_global: ?*Object) !void {
        if (class.isBytecodeFunctionClass(self.class_id)) {
            const expected = self.bytecodeFunctionRealmGlobalPtr() orelse return error.InvalidBuiltinRegistry;
            if (realm_global != expected) return error.InvalidBytecode;
            return;
        }
        if (self.class_id == class.ids.c_function) {
            const global = realm_global orelse return error.InvalidBuiltinRegistry;
            const realm = rt.contextForGlobalIncludingConstructing(global) orelse return error.InvalidBuiltinRegistry;
            self.setNativeFunctionRealm(realm);
            return;
        }
        // Every remaining class is a caller-semantics object or a non-callable
        // payload. Neither owns nor borrows a Realm.
    }

    pub fn setFunctionRealmGlobalPtrIfNull(self: *Object, rt: *JSRuntime, realm_global: ?*Object) !void {
        if (class.isBytecodeFunctionClass(self.class_id)) {
            return self.setFunctionRealmGlobalPtr(rt, realm_global);
        }
        if (self.class_id == class.ids.c_function) {
            if (self.nativeFunctionRealm() == null) try self.setFunctionRealmGlobalPtr(rt, realm_global);
            return;
        }
    }

    pub fn borrowedReferenceHolderIndex(self: *const Object) ?usize {
        const compact_encoded = if (self.functionPayloadConst()) |payload|
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
        }
        const link = self.weakReferenceHolderLink() orelse return;
        link.borrowed_holder_index = if (index) |holder_index|
            if (holder_index < std.math.maxInt(u32)) @intCast(holder_index + 1) else 0
        else
            0;
    }

    /// Realm-global pointer for a proven bytecode-function object. The shared
    /// FunctionBytecode owns the RealmContext directly, exactly like qjs
    /// `b->realm`; closure objects only derive this live global.
    pub fn bytecodeFunctionRealmGlobalPtr(self: *const Object) ?*Object {
        const realm = self.bytecodeFunctionRealmContext() orelse return null;
        return realm.global;
    }

    pub fn bytecodeFunctionRealmContext(self: *const Object) ?*context_mod.RealmContext {
        if (!class.isBytecodeFunctionClass(self.class_id)) return null;
        const fb = self.bytecodeArm().*.function_bytecode orelse return null;
        return fb.realmContext();
    }

    /// Install the construction realm owned by a true C_FUNCTION. Retain the
    /// replacement before dropping the old owner so assigning the same realm
    /// remains safe even when this object is its last external owner.
    pub fn setNativeFunctionRealm(self: *Object, realm: *context_mod.RealmContext) void {
        std.debug.assert(self.class_id == class.ids.c_function);
        const payload = self.functionPayload() orelse unreachable;
        if (payload.native.realm.borrow() == realm) return;
        const next = context_mod.RealmRef.retain(realm);
        payload.native.realm.deinit();
        payload.native.realm = next;
    }

    /// Finalize a true C_FUNCTION's owned realm edge during final Runtime
    /// teardown. The caller must retain `realm` across its object-list scan so
    /// dropping the last native edge cannot destroy the context mid-iteration.
    /// Caller-semantics carriers never enter this path and keep owning no realm.
    pub fn releaseNativeFunctionRealmForRuntimeTeardown(self: *Object, realm: *context_mod.RealmContext) void {
        if (self.class_id != class.ids.c_function) return;
        const payload = self.functionPayload() orelse unreachable;
        if (payload.native.realm.borrow() != realm) return;
        payload.native.realm.deinit();
    }

    /// Direct realm read for the native-C-function call path — qjs `ctx =
    /// p->u.cfunc.realm` (quickjs.c:17586). C_FUNCTION_DATA deliberately
    /// returns null because it consumes the caller's context.
    pub fn nativeFunctionRealm(self: *const Object) ?*context_mod.RealmContext {
        if (self.class_id != class.ids.c_function) return null;
        return self.nativeFunctionRealmAssumeCFunction();
    }

    /// Caller already proved `class_id == c_function` (K1).
    pub fn nativeFunctionRealmAssumeCFunction(self: *const Object) ?*context_mod.RealmContext {
        const payload = self.functionPayloadConst() orelse return null;
        return payload.native.realm.borrow();
    }

    pub fn nativeFunctionRealmGlobalPtr(self: *const Object) ?*Object {
        const realm = self.nativeFunctionRealm() orelse return null;
        return realm.global;
    }

    pub fn functionRealmGlobalPtr(self: *const Object) ?*Object {
        if (class.isBytecodeFunctionClass(self.class_id)) return self.bytecodeFunctionRealmGlobalPtr();
        if (self.class_id == class.ids.c_function) return self.nativeFunctionRealmGlobalPtr();
        return null;
    }

    fn ordinaryPayload(self: *Object) ?*OrdinaryPayload {
        if (self.flags.class_payload_kind != .ordinary) return null;
        return @ptrCast(@alignCast(self.payloadArm().*.?));
    }

    fn ordinaryPayloadConst(self: *const Object) ?*const OrdinaryPayload {
        if (self.flags.class_payload_kind != .ordinary) return null;
        return @ptrCast(@alignCast(self.payloadArm().*.?));
    }

    fn destroyOrdinaryPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.ordinaryPayload() orelse return;
        self.payloadArm().* = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(OrdinaryPayload, payload);
    }

    fn iteratorPayload(self: *Object) ?*IteratorPayload {
        if (self.flags.class_payload_kind != .iterator) return null;
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn iteratorPayloadConst(self: *const Object) ?*const IteratorPayload {
        if (self.flags.class_payload_kind != .iterator) return null;
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    /// Release the entry-array cursor a Map/Set iterator holds on its target,
    /// if it still has one. Mirrors js_map_iterator_finalizer
    /// (quickjs.c:52515-52528): the finalizer decrefs the parked record before
    /// releasing `it->obj`, guarded by a liveness check because the map's own
    /// teardown may have run first.
    fn releaseIteratorCollectionCursor(class_id: class.ClassId, payload: *IteratorPayload) void {
        if (!payload.collection_cursor_held) return;
        payload.collection_cursor_held = false;
        if (class_id != class.ids.map_iterator and class_id != class.ids.set_iterator) return;
        const target = payload.target orelse return;
        const target_object = objectFromValue(target) orelse return;
        target_object.releaseCollectionCursor();
    }

    fn destroyIteratorPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.iteratorPayload() orelse return;
        releaseIteratorCollectionCursor(self.class_id, payload);
        self.payloadArm().* = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(IteratorPayload, payload);
    }

    fn collectionPayload(self: *Object) ?*CollectionPayload {
        if (self.flags.class_payload_kind != .collection) return null;
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    /// Narrow cross-file seam for weak-entry processing during cycle GC.
    pub fn collectionPayloadForCycleGc(self: *Object) ?*CollectionPayload {
        return self.collectionPayload();
    }

    fn collectionPayloadConst(self: *const Object) ?*const CollectionPayload {
        if (self.flags.class_payload_kind != .collection) return null;
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyCollectionPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.collectionPayload() orelse return;
        self.payloadArm().* = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(CollectionPayload, payload);
    }

    fn finalizationRegistryPayload(self: *Object) ?*FinalizationRegistryPayload {
        if (self.flags.class_payload_kind != .finalization_registry) return null;
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    /// Narrow cross-file seam for finalization-cell processing during cycle GC.
    pub fn finalizationRegistryPayloadForCycleGc(self: *Object) ?*FinalizationRegistryPayload {
        return self.finalizationRegistryPayload();
    }

    fn finalizationRegistryPayloadConst(self: *const Object) ?*const FinalizationRegistryPayload {
        if (self.flags.class_payload_kind != .finalization_registry) return null;
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyFinalizationRegistryPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.finalizationRegistryPayload() orelse return;
        self.payloadArm().* = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(FinalizationRegistryPayload, payload);
    }

    fn weakRefPayload(self: *Object) ?*WeakRefPayload {
        if (self.flags.class_payload_kind != .weak_ref) return null;
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    /// Narrow cross-file seam for weak-target processing during cycle GC.
    pub fn weakRefPayloadForCycleGc(self: *Object) ?*WeakRefPayload {
        return self.weakRefPayload();
    }

    fn weakRefPayloadConst(self: *const Object) ?*const WeakRefPayload {
        if (self.flags.class_payload_kind != .weak_ref) return null;
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyWeakRefPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.weakRefPayload() orelse return;
        self.payloadArm().* = null;
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
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn stdFilePayloadConst(self: *const Object) ?*const StdFilePayload {
        if (self.flags.class_payload_kind != .std_file) return null;
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyStdFilePayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.stdFilePayload() orelse return;
        self.payloadArm().* = null;
        self.flags.class_payload_kind = .none;
        payload.destroy();
        rt.memory.destroy(StdFilePayload, payload);
    }

    fn disposableStackPayload(self: *Object) ?*DisposableStackPayload {
        if (self.flags.class_payload_kind != .disposable_stack) return null;
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn disposableStackPayloadConst(self: *const Object) ?*const DisposableStackPayload {
        if (self.flags.class_payload_kind != .disposable_stack) return null;
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyDisposableStackPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.disposableStackPayload() orelse return;
        self.payloadArm().* = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(DisposableStackPayload, payload);
    }

    fn globalPayload(self: *Object) ?*GlobalPayload {
        if (self.flags.class_payload_kind != .global) return null;
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn globalPayloadConst(self: *const Object) ?*const GlobalPayload {
        if (self.flags.class_payload_kind != .global) return null;
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyGlobalPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.globalPayload() orelse return;
        self.payloadArm().* = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.destroyRuntime(GlobalPayload, payload);
    }

    fn destroyRealmRecordPayload(self: *Object, rt: *JSRuntime) void {
        if (self.flags.class_payload_kind != .realm_record) return;
        const ptr = self.payloadArm().* orelse return;
        const payload: *RealmRecordPayload = @ptrCast(@alignCast(ptr));
        self.payloadArm().* = null;
        self.flags.class_payload_kind = .none;
        payload.destroy();
        rt.destroyRuntime(RealmRecordPayload, payload);
    }

    fn bufferPayload(self: *Object) ?*BufferPayload {
        if (self.flags.class_payload_kind != .buffer) return null;
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn bufferPayloadConst(self: *const Object) ?*const BufferPayload {
        if (self.flags.class_payload_kind != .buffer) return null;
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyBufferPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.bufferPayload() orelse return;
        self.payloadArm().* = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(BufferPayload, payload);
    }

    fn typedArrayPayload(self: *Object) ?*TypedArrayPayload {
        if (self.flags.class_payload_kind != .typed_array) return null;
        return @ptrCast(@alignCast(self.payloadArm().*.?));
    }

    fn typedArrayPayloadConst(self: *const Object) ?*const TypedArrayPayload {
        if (self.flags.class_payload_kind != .typed_array) return null;
        return @ptrCast(@alignCast(self.payloadArm().*.?));
    }

    fn destroyTypedArrayPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.typedArrayPayload() orelse return;
        self.payloadArm().* = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(TypedArrayPayload, payload);
    }

    fn regExpPayload(self: *Object) ?*RegExpPayload {
        if (self.flags.class_payload_kind != .regexp) return null;
        if (self.class_id == class.ids.regexp) return &self.regexpArm().*;
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn regExpPayloadConst(self: *const Object) ?*const RegExpPayload {
        if (self.flags.class_payload_kind != .regexp) return null;
        if (self.class_id == class.ids.regexp) return &self.regexpArm().*;
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyRegExpPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.regExpPayload() orelse return;
        if (self.class_id == class.ids.regexp) {
            payload.destroy(rt);
            self.regexpArm().* = .{};
            self.flags.class_payload_kind = .none;
            return;
        }
        self.payloadArm().* = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(RegExpPayload, payload);
    }

    fn boundFunctionPayload(self: *Object) ?*BoundFunctionPayload {
        if (self.flags.class_payload_kind != .bound_function) return null;
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn boundFunctionPayloadConst(self: *const Object) ?*const BoundFunctionPayload {
        if (self.flags.class_payload_kind != .bound_function) return null;
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyBoundFunctionPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.boundFunctionPayload() orelse return;
        self.payloadArm().* = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(BoundFunctionPayload, payload);
    }

    fn proxyPayload(self: *Object) ?*ProxyPayload {
        if (self.flags.class_payload_kind != .proxy) return null;
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn proxyPayloadConst(self: *const Object) ?*const ProxyPayload {
        if (self.flags.class_payload_kind != .proxy) return null;
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyProxyPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.proxyPayload() orelse return;
        self.payloadArm().* = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(ProxyPayload, payload);
    }

    fn argumentsPayload(self: *Object) ?*ArgumentsPayload {
        if (self.flags.class_payload_kind != .arguments) return null;
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn argumentsPayloadConst(self: *const Object) ?*const ArgumentsPayload {
        if (self.flags.class_payload_kind != .arguments) return null;
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyArgumentsPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.argumentsPayload() orelse return;
        self.payloadArm().* = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(ArgumentsPayload, payload);
    }

    fn objectDataPayload(self: *Object) ?*ObjectDataPayload {
        if (self.flags.class_payload_kind != .object_data) return null;
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn objectDataPayloadConst(self: *const Object) ?*const ObjectDataPayload {
        if (self.flags.class_payload_kind != .object_data) return null;
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyObjectDataPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.objectDataPayload() orelse return;
        self.payloadArm().* = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(ObjectDataPayload, payload);
    }

    fn varRefPayload(self: *Object) ?*VarRefPayload {
        if (self.flags.class_payload_kind != .var_ref) return null;
        return @ptrCast(@alignCast(self.payloadArm().*.?));
    }

    fn varRefPayloadConst(self: *const Object) ?*const VarRefPayload {
        if (self.flags.class_payload_kind != .var_ref) return null;
        return @ptrCast(@alignCast(self.payloadArm().*.?));
    }

    fn destroyVarRefPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.varRefPayload() orelse return;
        self.payloadArm().* = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(VarRefPayload, payload);
    }

    pub fn promisePayload(self: *Object) ?*PromisePayload {
        if (self.flags.class_payload_kind != .promise) return null;
        return @ptrCast(@alignCast(self.payloadArm().*.?));
    }

    fn promisePayloadConst(self: *const Object) ?*const PromisePayload {
        if (self.flags.class_payload_kind != .promise) return null;
        return @ptrCast(@alignCast(self.payloadArm().*.?));
    }

    fn destroyPromisePayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.promisePayload() orelse return;
        self.payloadArm().* = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(PromisePayload, payload);
    }

    fn generatorPayload(self: *Object) ?*GeneratorPayload {
        if (self.flags.class_payload_kind != .generator) return null;
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn generatorPayloadConst(self: *const Object) ?*const GeneratorPayload {
        if (self.flags.class_payload_kind != .generator) return null;
        const ptr = self.payloadArm().* orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyGeneratorPayload(self: *Object, rt: *JSRuntime) void {
        const payload = self.generatorPayload() orelse return;
        self.payloadArm().* = null;
        self.flags.class_payload_kind = .none;
        payload.destroy(rt);
        rt.memory.destroy(GeneratorPayload, payload);
    }

    fn functionPayload(self: *Object) ?*FunctionPayload {
        if (self.flags.class_payload_kind != .function) return null;
        if (class.isBytecodeFunctionClass(self.class_id)) return null;
        return @ptrCast(@alignCast(self.payloadArm().*.?));
    }

    fn functionPayloadConst(self: *const Object) ?*const FunctionPayload {
        if (self.flags.class_payload_kind != .function) return null;
        if (class.isBytecodeFunctionClass(self.class_id)) return null;
        return @ptrCast(@alignCast(self.payloadArm().*.?));
    }

    fn destroyFunctionPayload(self: *Object, rt: *JSRuntime) void {
        if (class.isBytecodeFunctionClass(self.class_id)) {
            var captures = self.bytecodeArm().*.captureSlots();
            self.bytecodeArm().*.var_refs = BytecodeFunctionStorage.emptyVarRefs();
            destroyOptionalVarRefCellSlice(rt, &captures);

            if (self.bytecodeFunctionAux()) |aux| {
                self.bytecodeArm().*.home_or_aux = null;
                aux.destroy(rt);
                rt.memory.destroy(BytecodeFunctionAux, aux);
            } else if (self.functionHomeObject()) |home| {
                self.bytecodeArm().*.home_or_aux = null;
                home.value().free(rt);
            }

            if (self.bytecodeArm().*.function_bytecode) |fb| {
                self.bytecodeArm().*.function_bytecode = null;
                gc.release(rt, &fb.header);
            }
            self.flags.class_payload_kind = .none;
            return;
        }
        const payload = self.functionPayload() orelse return;
        self.payloadArm().* = null;
        self.flags.class_payload_kind = .none;
        payload.destroyNative(rt);
        rt.memory.destroy(FunctionPayload, payload);
    }

    // ===== visit* / cycle GC =====
    pub const drainCycleDeferredFrees = object_gc.drainCycleDeferredFrees;
    pub const drainCycleDeferredFreesBudgeted = object_gc.drainCycleDeferredFreesBudgeted;
    pub const CycleMarkPathForTest = object_gc.CycleMarkPathForTest;
    pub const collectCycleMarkChildHeadersForTest = object_gc.collectCycleMarkChildHeadersForTest;

    fn weakIdentityIsLive(rt: *const JSRuntime, identity: usize) bool {
        if ((identity & 1) != 0) {
            const atom_id = identity >> 1;
            if (atom_id > std.math.maxInt(atom.Atom)) return false;
            return rt.atoms.kind(@intCast(atom_id)) == .symbol;
        }
        return rt.liveObjectFromWeakIdentity(identity) != null;
    }

    // mirror of value_semantics.objectFromValue (kind check included), keep
    // in sync — kept local: object.zig <-> value_semantics import cycle.
    fn objectFromValue(stored: JSValue) ?*Object {
        const stored_header = stored.refHeader() orelse return null;
        if (stored_header.meta().flags.kind != .object) return null;
        return fromHeader(stored_header);
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
        // Arrays keep `array_values` (not a payload) in the union; bytecode
        // functions keep `u.func` (qjs JSObject.u.func). Neither is a host
        // payload pointer — do not pun the union into markPayload.
        if (self.isArray() or class.isBytecodeFunctionClass(self.class_id) or self.payloadArm().* == null)
            return false;
        return rt.classes.markPayload(self.class_id, @ptrCast(rt), @ptrCast(self), &self.payloadArm().*, visitor);
    }

    fn countPayloadFunctionBytecodeRef(context_ptr: *anyopaque, value_ptr: *anyopaque) void {
        const context: *PayloadBytecodeRefCountContext = @ptrCast(@alignCast(context_ptr));
        const stored: *JSValue = @ptrCast(@alignCast(value_ptr));
        context.count += countFunctionBytecodeValueRef(stored.*, context.function_bytecode);
    }

    fn collectReachableObjects(rt: *JSRuntime, visited: *ObjectVisitSet, current: *Object) ObjectGraphError!void {
        if (gc.headerRefCountIsZeroOrHusk(&current.header)) return;
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

    /// Trace only the embedder payload edges, without promoting the wrapper's
    /// ordinary properties or shape. Deferred plugin finalizers use this as a
    /// temporary-root contract: the wrapper may die, while the payload graph
    /// that its callback will inspect must stay alive until callback return.
    pub fn traceClassPayloadRootEdges(self: *Object, rt: *JSRuntime, root_visitor: *runtime_mod.RootVisitor) runtime_mod.RootTraceError!void {
        const Adaptor = struct {
            visitor: *runtime_mod.RootVisitor,
            err: ?runtime_mod.RootTraceError = null,

            fn visitValue(context_ptr: *anyopaque, value_ptr: *anyopaque) void {
                const adaptor: *@This() = @ptrCast(@alignCast(context_ptr));
                const stored: *JSValue = @ptrCast(@alignCast(value_ptr));
                adaptor.visitor.value(stored) catch |err| {
                    adaptor.err = err;
                };
            }

            fn visitObject(context_ptr: *anyopaque, object_ptr: *anyopaque) void {
                const adaptor: *@This() = @ptrCast(@alignCast(context_ptr));
                const stored: *?*Object = @ptrCast(@alignCast(object_ptr));
                adaptor.visitor.optionalObject(stored) catch |err| {
                    adaptor.err = err;
                };
            }
        };
        var adaptor = Adaptor{ .visitor = root_visitor };
        var class_visitor = class.PayloadVisitor{
            .context = @ptrCast(&adaptor),
            .visit_value = Adaptor.visitValue,
            .visit_object = Adaptor.visitObject,
        };
        _ = self.markClassPayload(rt, &class_visitor);
        if (adaptor.err) |err| return err;
    }

    /// Edge kinds the ordinary-object / fast-array / shape cycle-mark contracts
    /// cover. `object_gc` hot arms comptime-assert they declare the same set.
    /// Runtime membership of any one kind still depends on the live payload
    /// (empty property lists, absent iterator-next cache, null proto).
    pub const CycleHotEdgeKind = enum(u8) {
        shape,
        property_slots,
        array_elements,
        iterator_next_cache,
        proto,
    };

    pub const ordinary_object_cycle_hot_edges = [_]CycleHotEdgeKind{
        .shape,
        .property_slots,
        .iterator_next_cache,
    };
    pub const fast_array_cycle_hot_edges = [_]CycleHotEdgeKind{
        .shape,
        .property_slots,
        .array_elements,
        .iterator_next_cache,
    };
    pub const shape_cycle_hot_edges = [_]CycleHotEdgeKind{.proto};

    pub fn isDetachedGeneratorShellForGc(self: *const Object) bool {
        return (self.class_id == class.ids.generator or self.class_id == class.ids.async_generator) and
            self.flags.class_payload_kind == .generator and
            !self.header.metaConst().alloc_info.heap_accounted;
    }

    /// Trace the only initialized portion of a detached generator shell. Its
    /// final shape_ref and property storage are intentionally unavailable until
    /// finishGeneratorShell; the construction-root protocol calls this method
    /// instead of the ordinary Object edge walk during that interval.
    pub fn traceDetachedGeneratorShellEdges(self: *Object, visitor: anytype) !void {
        std.debug.assert(self.class_id == class.ids.generator or self.class_id == class.ids.async_generator);
        std.debug.assert(self.flags.class_payload_kind == .generator);
        std.debug.assert(!self.header.metaConst().alloc_info.heap_accounted);
        try self.generatorPayloadPtr().traceChildEdges(visitor);
    }

    /// Describe the storage allocations read by `traceChildEdgesFallible` for
    /// this object's current class and live payload. The recorder is generic
    /// so the object model does not import the collector (which already
    /// imports this file). Keep this beside the trace authority: a new
    /// allocation-bearing trace arm must be reflected here and in the
    /// `--gc-stats` parser contract.
    pub fn recordTraceStorageFootprint(self: *const Object, rt: *const JSRuntime, recorder: anytype) void {
        const Helper = struct {
            fn allocation(rec: anytype, component: anytype, ptr: anytype, allocated: usize, touched: usize) void {
                if (allocated == 0 or touched == 0) return;
                const address = @intFromPtr(ptr);
                rec.noteAllocation(component, allocated, address, touched);
            }

            fn backing(rec: anytype, ptr: anytype, capacity: usize, live: usize, comptime T: type) void {
                if (capacity == 0 or live == 0) return;
                allocation(rec, .payload_backing, ptr, capacity * @sizeOf(T), live * @sizeOf(T));
            }
        };

        if (self.class_id == class.ids.object and self.flags.class_payload_kind == .none) {
            recorder.beginTraceClass(.ordinary_object);
        } else if (class.isBytecodeFunctionClass(self.class_id)) {
            recorder.beginTraceClass(.bytecode_function);
        } else if (self.isArray() and self.flags.fast_array) {
            recorder.beginTraceClass(.fast_array);
        } else {
            recorder.beginTraceClass(.exotic_object);
        }

        const object_address = @intFromPtr(&self.header) - gc.metadata_prefix_size;
        const object_bytes = gc.metadata_prefix_size + self.allocationSize(rt);
        recorder.noteAllocation(.base, object_bytes, object_address, object_bytes);

        if (rt.cached_iterator_next_entries.len != 0) {
            Helper.allocation(
                recorder,
                .payload_backing,
                rt.cached_iterator_next_entries.ptr,
                rt.cached_iterator_next_entries_capacity * @sizeOf(runtime_mod.CachedIteratorNextEntry),
                rt.cached_iterator_next_entries.len * @sizeOf(runtime_mod.CachedIteratorNextEntry),
            );
        }

        // Every Object trace still marks the Shape edge and therefore reads its
        // first allocation line. Exact 0..2-slot summaries avoid the separate
        // inline property-descriptor line; overflow objects retain the Shape
        // FAM walk. Keep the census identical to the actual trace branch.
        const shape_address = @intFromPtr(self.shape_ref) - gc.metadata_prefix_size;
        const shape_allocated = gc.metadata_prefix_size + self.shape_ref.allocationSize();
        const summary_exact = traceShapeSummaryIsExact(self.traceShapeSummary());
        const shape_touched = @sizeOf(shape.Shape) + if (summary_exact)
            0
        else
            @as(usize, self.shape_ref.prop_count) * @sizeOf(shape.Property);
        recorder.noteAllocation(
            .shape,
            shape_allocated,
            shape_address,
            gc.metadata_prefix_size + shape_touched,
        );

        const prop_count: usize = self.shape_ref.prop_count;
        const prop_capacity: usize = self.shape_ref.prop_size;
        if (prop_capacity != 0 and prop_count != 0) {
            const prop_address = @intFromPtr(self.prop_values);
            const allocated = prop_capacity * @sizeOf(property.Entry);
            const touched = prop_count * @sizeOf(property.Entry);
            recorder.noteAllocation(.property_slots, allocated, prop_address, touched);
            recorder.noteInlinePropertyCandidate(
                prop_count,
                allocated,
                prop_address,
                touched,
                self.hasTrailingPropertyAllocation(),
                self.propertyStorageIsInline(),
            );
        }

        // Fast arrays and mapped arguments share the same allocation-bearing
        // union arm. The latter stores VarRef pointers in JSValue-sized cells.
        if (self.flags.fast_array or self.class_id == class.ids.mapped_arguments) {
            const capacity: usize = self.arrayArm().*.capacity;
            const live: usize = self.arrayArm().*.count;
            if (capacity != 0 and live != 0) {
                Helper.allocation(
                    recorder,
                    .dense_elements,
                    self.arrayArm().*.values,
                    capacity * @sizeOf(JSValue),
                    live * @sizeOf(JSValue),
                );
            }
        }

        // Bytecode-callable state is inline in Object; only the capture array
        // and optional cold aux are separate allocations.
        if (class.isBytecodeFunctionClass(self.class_id)) {
            const captures = self.bytecodeArm().*.captureSlots();
            Helper.backing(recorder, captures.ptr, captures.len, captures.len, ?*var_ref_mod.VarRef);
            if (self.bytecodeFunctionAuxConst()) |aux| {
                Helper.allocation(recorder, .trace_payload, aux, @sizeOf(BytecodeFunctionAux), @sizeOf(BytecodeFunctionAux));
            }
            return;
        }

        switch (self.flags.class_payload_kind) {
            .none => {},
            .ordinary => if (self.ordinaryPayloadConst()) |payload| {
                Helper.allocation(recorder, .trace_payload, payload, @sizeOf(OrdinaryPayload), @sizeOf(OrdinaryPayload));
            },
            .iterator => if (self.iteratorPayloadConst()) |payload| {
                Helper.allocation(recorder, .trace_payload, payload, @sizeOf(IteratorPayload), @sizeOf(IteratorPayload));
            },
            .collection => if (self.collectionPayloadConst()) |payload| {
                Helper.allocation(recorder, .trace_payload, payload, @sizeOf(CollectionPayload), @sizeOf(CollectionPayload));
                Helper.backing(recorder, payload.entries.ptr, payload.entries_capacity, payload.entries.len, CollectionEntry);
                Helper.backing(recorder, payload.weak_entries.ptr, payload.weak_entries_capacity, payload.weak_entries.len, WeakCollectionEntry);
            },
            .buffer, .regexp, .weak_ref, .std_file => {}, // trace methods have no strong-edge loads
            .typed_array => if (self.typedArrayPayloadConst()) |payload| {
                Helper.allocation(recorder, .trace_payload, payload, @sizeOf(TypedArrayPayload), @sizeOf(TypedArrayPayload));
            },
            .bound_function => if (self.boundFunctionPayloadConst()) |payload| {
                Helper.allocation(recorder, .trace_payload, payload, @sizeOf(BoundFunctionPayload), @sizeOf(BoundFunctionPayload));
                Helper.backing(recorder, payload.args.ptr, payload.args.len, payload.args.len, JSValue);
            },
            .proxy => if (self.proxyPayloadConst()) |payload| {
                Helper.allocation(recorder, .trace_payload, payload, @sizeOf(ProxyPayload), @sizeOf(ProxyPayload));
            },
            .arguments => if (self.argumentsPayloadConst()) |payload| {
                Helper.allocation(recorder, .trace_payload, payload, @sizeOf(ArgumentsPayload), @sizeOf(ArgumentsPayload));
                Helper.backing(recorder, payload.var_refs.ptr, payload.var_refs.len, payload.var_refs.len, JSValue);
            },
            .object_data => if (self.objectDataPayloadConst()) |payload| {
                Helper.allocation(recorder, .trace_payload, payload, @sizeOf(ObjectDataPayload), @sizeOf(ObjectDataPayload));
            },
            .var_ref => if (self.varRefPayloadConst()) |payload| {
                Helper.allocation(recorder, .trace_payload, payload, @sizeOf(VarRefPayload), @sizeOf(VarRefPayload));
            },
            .finalization_registry => if (self.finalizationRegistryPayloadConst()) |payload| {
                Helper.allocation(recorder, .trace_payload, payload, @sizeOf(FinalizationRegistryPayload), @sizeOf(FinalizationRegistryPayload));
                Helper.backing(recorder, payload.cells.ptr, payload.cells_capacity, payload.cells.len, FinalizationRegistryCell);
            },
            .disposable_stack => if (self.disposableStackPayloadConst()) |payload| {
                Helper.allocation(recorder, .trace_payload, payload, @sizeOf(DisposableStackPayload), @sizeOf(DisposableStackPayload));
                Helper.backing(recorder, payload.resources.ptr, payload.resource_capacity, payload.resources.len, DisposableResource);
            },
            .global => if (self.globalPayloadConst()) |payload| {
                Helper.allocation(recorder, .trace_payload, payload, @sizeOf(GlobalPayload), @sizeOf(GlobalPayload));
            },
            .realm_record => {
                const ptr = self.payloadArm().* orelse return;
                const payload: *const RealmRecordPayload = @ptrCast(@alignCast(ptr));
                Helper.allocation(recorder, .trace_payload, payload, @sizeOf(RealmRecordPayload), @sizeOf(RealmRecordPayload));
            },
            .promise => if (self.promisePayloadConst()) |payload| {
                Helper.allocation(recorder, .trace_payload, payload, @sizeOf(PromisePayload), @sizeOf(PromisePayload));
                Helper.backing(recorder, payload.reactions.ptr, payload.reactions_capacity, payload.reactions.len, JSValue);
            },
            .generator => if (self.generatorPayloadConst()) |payload| {
                Helper.allocation(recorder, .trace_payload, payload, @sizeOf(GeneratorPayload), @sizeOf(GeneratorPayload));
                if (payload.execution) |execution| {
                    const execution_bytes = execution.allocationSize();
                    Helper.allocation(recorder, .payload_backing, execution, execution_bytes, execution_bytes);
                    if (!execution.suspended.running_aliases) {
                        const storage = &execution.suspended.storage;
                        if (!execution.stackUsesCombinedStorage()) {
                            Helper.backing(recorder, storage.stack.values.ptr, storage.stack.capacity, storage.stack.values.len, JSValue);
                        }
                        if (!execution.frameUsesCombinedStorage()) {
                            if (storage.frame.storage.len != 0) {
                                Helper.backing(recorder, storage.frame.storage.ptr, storage.frame.storage.len, storage.frame.storage.len, JSValue);
                            } else {
                                Helper.backing(recorder, storage.frame.locals.ptr, storage.frame.locals.len, storage.frame.locals.len, JSValue);
                                Helper.backing(recorder, storage.frame.args.ptr, storage.frame.args.len, storage.frame.args.len, JSValue);
                            }
                        }
                    }
                }
                Helper.backing(recorder, payload.async_queue.ptr, payload.async_queue_capacity, payload.async_queue.len, AsyncGeneratorRequest);
            },
            .function => if (self.functionPayloadConst()) |payload| {
                Helper.allocation(recorder, .trace_payload, payload, @sizeOf(FunctionPayload), @sizeOf(FunctionPayload));
                if (payload.rare) |rare| {
                    Helper.allocation(recorder, .payload_backing, rare, @sizeOf(FunctionRarePayload), @sizeOf(FunctionRarePayload));
                }
            },
        }
    }

    /// qjs:6585-6597 TMASK arms (GETSET / VARREF / AUTOINIT). Kept off
    /// the ordinary data-slot loop so the hot OBJECT path is shape +
    /// `JS_MarkValue` (qjs:6598-6600). Still reachable: a plain `{}` may hold
    /// an accessor.
    fn traceUnusualPropertyFallible(visitor: anytype, entry: *property.Entry, slot_flags: property.Flags) !void {
        switch (slot_flags.kind) {
            .data => unreachable,
            .accessor => {
                var getter_value = entry.slot.accessor.getterValue();
                try object_payloads.callVisitValue(visitor, &getter_value);
                entry.slot.accessor.syncGetterFromVisitedValue(getter_value);
                var setter_value = entry.slot.accessor.setterValue();
                try object_payloads.callVisitValue(visitor, &setter_value);
                entry.slot.accessor.syncSetterFromVisitedValue(setter_value);
            },
            .var_ref => {
                var cell_value = entry.slot.var_ref.valueRef();
                try object_payloads.callVisitValue(visitor, &cell_value);
            },
            .auto_init => {
                const realm_header = entry.slot.auto_init.realm_and_id.realmHeader() orelse unreachable;
                var realm: ?*context_mod.RealmContext = @alignCast(@fieldParentPtr("header", realm_header));
                try object_payloads.callVisitRealm(visitor, &realm);
                entry.slot.auto_init.realm_and_id.syncRealmHeader(&(realm orelse unreachable).header);
            },
        }
    }

    inline fn tracePropertyEntriesFallible(
        self: *Object,
        visitor: anytype,
        count: usize,
        comptime from_summary: bool,
        summary: u8,
    ) !void {
        for (self.propertyStorageEntries(count), 0..) |*entry, index| {
            const slot_flags = if (comptime from_summary)
                traceShapeSummaryFlagsAt(summary, index)
            else
                self.propFlagsAt(index);
            if (slot_flags.deleted) continue;
            if (slot_flags.kind == .data) {
                try object_payloads.callVisitValue(visitor, &entry.slot.data);
                continue;
            }
            try traceUnusualPropertyFallible(visitor, entry, slot_flags);
        }
    }

    inline fn traceDataPropertyEntriesFallible(self: *Object, visitor: anytype, count: usize) !void {
        for (self.propertyStorageEntries(count)) |*entry|
            try object_payloads.callVisitValue(visitor, &entry.slot.data);
    }

    inline fn tracePropertyEdgesFallible(self: *Object, visitor: anytype) !void {
        // A mutator barrier may publish remembered bit7 between open
        // incremental/concurrent mark slices. The semantic accessor masks
        // that independent membership cache; begin-time clearing alone is
        // not a sufficient phase invariant for a raw marker read.
        const summary = self.traceShapeSummary();
        // Canonical summary values 0, 1, and 2 mean exactly that many live
        // data slots. This is the splay/raytrace dominant form: one byte
        // load + compare, with no per-slot shift/mask or Shape descriptor
        // read. Only unusual/deleted slots decode the upper six bits.
        if (summary <= trailing_property_capacity) {
            @branchHint(.likely);
            return self.traceDataPropertyEntriesFallible(visitor, @intCast(summary));
        }
        if (traceShapeSummaryIsExact(summary)) {
            return self.tracePropertyEntriesFallible(
                visitor,
                traceShapeSummaryCount(summary),
                true,
                summary,
            );
        }
        return self.tracePropertyEntriesFallible(visitor, self.shape_ref.prop_count, false, 0);
    }

    pub inline fn traceChildEdgesFallible(self: *Object, rt: *JSRuntime, visitor: anytype) !void {
        const Helper = struct {
            inline fn callVisitObject(vis: anytype, obj_ptr: anytype) !void {
                return object_payloads.callVisitObject(vis, obj_ptr);
            }

            inline fn callVisitValue(vis: anytype, val_ptr: anytype) !void {
                return object_payloads.callVisitValue(vis, val_ptr);
            }

            inline fn callVisitShape(vis: anytype, shape_ref: *shape.Shape) !void {
                return object_payloads.callVisitShape(vis, shape_ref);
            }

            inline fn callVisitRealm(vis: anytype, ctx_ptr: *?*context_mod.RealmContext) !void {
                return object_payloads.callVisitRealm(vis, ctx_ptr);
            }

            inline fn traceOptValue(vis: anytype, opt_val: anytype) !void {
                return object_payloads.traceOptValue(vis, opt_val);
            }
        };

        try Helper.callVisitShape(visitor, self.shape_ref);
        // qjs:6568-6611 OBJECT arm: mark shape, then properties, then stop
        // when `class_id == JS_CLASS_OBJECT` (no `gc_mark`). Realm / C-function
        // / global / class-payload probes belong on the non-ordinary path —
        // they cannot fire for `class_id==object && payload_kind==none`.
        if (self.class_id == class.ids.object and self.flags.class_payload_kind == .none) {
            try self.tracePropertyEdgesFallible(visitor);
            // zjs-only iterator-next cache (qjs has no analogue). Empty on
            // the TS/splay/EB hot graphs; keep the len check as the rare tail.
            if (rt.cached_iterator_next_entries.len != 0) {
                if (self.cachedIteratorNextSlotIfPresent(rt)) |slot| {
                    try Helper.traceOptValue(visitor, slot);
                }
            }
            return;
        }
        if (self.flags.class_payload_kind == .realm_record) {
            const ptr = self.payloadArm().* orelse unreachable;
            const payload: *RealmRecordPayload = @ptrCast(@alignCast(ptr));
            try payload.traceChildEdges(visitor);
        }
        if (self.class_id == class.ids.c_function) {
            const payload = self.functionPayload() orelse unreachable;
            try payload.traceNativeRealm(visitor);
        }
        if (self.globalPayload()) |payload| {
            // qjs js_global_object_mark (quickjs.c:17062-17067).
            try payload.traceChildEdges(visitor);
        }
        if (rt.cached_iterator_next_entries.len != 0) {
            if (self.cachedIteratorNextSlotIfPresent(rt)) |slot| {
                try Helper.traceOptValue(visitor, slot);
            }
        }
        // qjs:6568 / qjs:6582 mark_children OBJECT arm marks the shape header
        // then property values. Key atoms (prs->atom) are not GC edges — they
        // live on the atom RC table, held by the shape.
        // Only entries with a matching shape property record carry a derivable
        // kind. A property mid-`appendPreparedPropertyEntry` can have an entry
        // pushed before the shape transition completes (the shape-storage alloc
        // can trigger force-GC); such an over-hang entry has no shape prop yet,
        // so clamp to the shape's prop_count (matching `shapeProps()`). Its value
        // is a freshly-created object that is not yet a cycle member, so skipping
        // it for this trace cannot collect it prematurely.
        try self.tracePropertyEdgesFallible(visitor);
        if (self.ordinaryPayload()) |payload| {
            try payload.traceChildEdges(visitor);
        }
        for (self.arrayElements()) |*stored| {
            try Helper.callVisitValue(visitor, stored);
        }
        // `object_gc.markFastArrayHot` owns the same edge contract and the
        // comptime dual below pins it to shape + properties + elements + the
        // iterator-next cache already visited above. A dense Array cannot own
        // any of the mutually-exclusive class payloads below.
        if (self.isArray() and self.flags.fast_array) return;
        if (self.typedArrayPayload()) |payload| {
            try payload.traceChildEdges(visitor);
        }
        if (self.objectDataPayload()) |payload| {
            try payload.traceChildEdges(visitor);
        }
        if (self.bufferPayload()) |payload| {
            try payload.traceChildEdges(visitor);
        }
        if (self.regExpPayload()) |payload| {
            try payload.traceChildEdges(visitor);
        }
        if (class.isBytecodeFunctionClass(self.class_id)) {
            // qjs js_bytecode_function_mark (quickjs.c:6262-6287), the class
            // gc_mark installed for JS_CLASS_BYTECODE_FUNCTION (1984) and
            // invoked from mark_children when class_id != JS_CLASS_OBJECT
            // (6605-6610). Edges: home_object, var_refs[0..closure_var_count],
            // function_bytecode header. Then stop — do not fall into host
            // markClassPayload (that path is JSClass.gc_mark for exotic
            // host classes, not u.func).
            const captures = self.bytecodeArm().*.captureSlots();
            for (captures) |maybe_cell| {
                const cell = maybe_cell orelse continue;
                var cell_value = cell.valueRef();
                try Helper.callVisitValue(visitor, &cell_value);
            }
            if (self.bytecodeArm().*.function_bytecode) |fb| {
                var bytecode_value = JSValue.functionBytecode(&fb.header);
                try Helper.callVisitValue(visitor, &bytecode_value);
                self.bytecodeArm().*.function_bytecode = if (bytecode_value.objectHeader()) |header|
                    @alignCast(@fieldParentPtr("header", header))
                else
                    null;
            }
            var home_object = self.functionHomeObject();
            try Helper.callVisitObject(visitor, &home_object);
            if (self.bytecodeFunctionAux()) |aux| {
                aux.home_object = home_object;
            } else {
                self.bytecodeArm().*.home_or_aux = if (home_object) |home| @ptrCast(home) else null;
            }
            // zjs-only aux (source / realm_global / promise slots). Absent in
            // qjs 6262; keep so rare cycle edges stay live. Then return: the
            // class mark is done.
            if (self.functionRarePayload()) |rare| {
                try rare.traceChildEdges(visitor);
            }
            return;
        }
        if (self.functionRarePayload()) |rare| {
            try rare.traceChildEdges(visitor);
        }
        if (self.boundFunctionPayload()) |payload| {
            try payload.traceChildEdges(visitor);
        }
        if (self.collectionPayload()) |payload| {
            try payload.traceChildEdges(visitor);
        }
        if (self.finalizationRegistryPayload()) |payload| {
            try payload.traceChildEdges(visitor);
        }
        if (self.disposableStackPayload()) |payload| {
            try payload.traceChildEdges(visitor);
        }
        if (self.iteratorPayload()) |payload| {
            try payload.traceChildEdges(visitor);
        }
        if (self.generatorPayload()) |payload| {
            try payload.traceChildEdges(visitor);
        }
        if (self.argumentsPayload()) |payload| {
            try payload.traceChildEdges(visitor);
        }
        if (self.varRefPayload()) |payload| {
            try payload.traceChildEdges(visitor);
        }
        if (self.class_id == class.ids.mapped_arguments) {
            for (self.argumentsVarRefs()) |maybe_cell| {
                const cell = maybe_cell orelse continue;
                var cell_value = cell.valueRef();
                try Helper.callVisitValue(visitor, &cell_value);
            }
        }
        if (self.proxyPayload()) |payload| {
            try payload.traceChildEdges(visitor);
        }
        if (self.promisePayload()) |payload| {
            try payload.traceChildEdges(visitor);
        }
        if (self.weakRefPayload()) |payload| {
            try payload.traceChildEdges(visitor);
        }
        if (self.stdFilePayload()) |payload| {
            try payload.traceChildEdges(visitor);
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
        // Cycle marking and typed-payload trace tests instantiate this wrapper
        // only with void-returning visit methods. Allocation-bearing graph
        // visitors use traceChildEdgesFallible directly, so no error can reach
        // this catch.
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
        if (function_bytecode.realmContext()) |realm| {
            if (realm.global) |realm_global| try collectReachableObjects(rt, visited, realm_global);
        }
        for (function_bytecode.cpoolSlice()) |stored| try collectValueObject(rt, visited, stored);
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
        if (header.meta().flags.kind != .object) return null;
        return fromHeader(header);
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
        if (function_bytecode.realmContext()) |realm| {
            if (realm.global) |realm_global| try incrementIncomingIfVisited(visited, incoming, realm_global);
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
        if (function_bytecode.realmContext()) |realm| {
            if (headerIsCycleGarbage(&realm.header)) function_bytecode.realm.ptr = null;
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
        if (header.meta().flags.kind != .function_bytecode) return null;
        return @fieldParentPtr("header", header);
    }

    fn countFunctionBytecodeChildRefs(
        owner: *const FunctionBytecode,
        function_bytecode: *const FunctionBytecode,
    ) usize {
        var count: usize = 0;
        for (owner.cpoolSlice()) |stored| count += countFunctionBytecodeValueRef(stored, function_bytecode);
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
        try rt.shapes.prepareUpdate(&self.shape_ref);
        // Every write to `shape_ref` is an owner adopting a Shape: the clone or
        // relocation this call may perform produces a fresh, young one, and a
        // long-lived owner reaching it is an old-to-young edge the minor's
        // sticky marks would otherwise stop short of.
        rt.gc.generationalBarrier(&self.header, &self.shape_ref.header);
        const old_prototype = rt.shapes.replacePrototypeAssumePrepared(self.shape_ref, prototype);
        if (old_prototype) |old| old.value().free(rt);
        self.flags.is_std_array_prototype = false;
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
        const previous = self.shape_ref;
        self.shape_ref = replacement;
        self.refreshTraceShapeSummary();
        rt.gc.generationalBarrier(&self.header, &replacement.header);
        rt.shapes.release(previous);
        self.flags.is_std_array_prototype = false;
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

    pub fn getOwnProperty(self: *const Object, rt: *JSRuntime, atom_id: atom.Atom) PropertyReadError!?descriptor.Descriptor {
        if (self.exoticMethods(rt)) |methods| {
            if (methods.get_own_property) |hook| {
                if (hook(@constCast(self), atom_id)) |desc| return desc;
            }
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
            const entry_flags = self.propFlagsAt(index);
            if (entry_flags.deleted) return null;
            // Auto-init placeholders need to be materialized before
            // the descriptor is built (`fromSlot` cannot synthesize
            // a value from `(name, length, rt)` on its own). This
            // mirrors `getProperty`'s first-access promotion -- after
            // materialization the slot is `.data` or `.accessor` and
            // re-reads are ordinary fast-path loads.
            if (entry_flags.isAutoInit()) {
                // Descriptor reads share the ordinary materialization error
                // channel. A failed builder leaves the placeholder intact for
                // an explicit retry; it must never become a data descriptor
                // containing `undefined`.
                const transient = try materializeAutoInit(@constCast(self), index);
                transient.free(rt);
                return try self.descriptorFromOwnPropertySlot(index);
            }
            return try self.descriptorFromOwnPropertySlot(index);
        }
        if (self.denseArrayElement(atom_id)) |stored| {
            return descriptor.Descriptor.data(stored.dup(), true, true, true);
        }
        return null;
    }

    fn descriptorFromOwnPropertySlot(self: *const Object, index: usize) !descriptor.Descriptor {
        const flags = self.propFlagsAt(index);
        const slot = self.propertyEntry(index).*.slot;
        if (flags.kind == .var_ref and slot.var_ref.varRefValue().isUninitialized()) {
            return error.ReferenceError;
        }
        var desc = descriptor.Descriptor.fromSlot(flags, slot);
        // A module namespace exposes a writable=true data descriptor while its
        // exotic Set/Define behavior protects the underlying live binding.
        // Exporter const-ness belongs to the binding cell and must not leak into
        // the namespace property's descriptor.
        if (self.isModuleNamespaceExportProperty(flags)) desc.writable = true;
        return desc;
    }

    inline fn isModuleNamespaceExportProperty(self: *const Object, flags: property.Flags) bool {
        return self.class_id == class.ids.module_ns and
            !flags.deleted and
            flags.writable and
            flags.enumerable and
            !flags.configurable and
            flags.kind != .accessor;
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
        // Typed arrays (canonical numeric index) need detached/range checks
        // that the descriptor path performs and that can observably throw.
        // Module namespace enumerability is carried by its ordinary shape
        // flags; reading that bit does not materialize an AUTOINIT binding.
        if (isTypedArrayObject(self)) return .descriptor;

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
        if (self.isArray() and atom_id == atom.ids.length) return true;
        if (self.findProperty(atom_id)) |index| {
            const entry = self.propertyEntry(index).*;
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

    /// Ordinary property read. AUTOINIT construction failures are observable
    /// and leave the placeholder intact for an explicit retry; no generic read
    /// path converts them to `undefined`.
    pub fn getProperty(self: *const Object, atom_id: atom.Atom) PropertyReadError!JSValue {
        profile.recordPropLookup(self.isGlobal());
        if (self.isArray() and atom_id == atom.ids.length) return arrayLengthValue(self.arrayLength());
        if (self.mappedArgumentsTaggedBindingIndex(atom_id)) |mapped_index| {
            if (self.mappedArgumentsBindingValue(mapped_index)) |mapped| return mapped;
        }
        if (self.findProperty(atom_id)) |index| {
            const entry = self.propertyEntry(index).*;
            return switch (self.propKindAt(index)) {
                .data => entry.slot.data.dup(),
                .accessor => entry.slot.accessor.getterValue().dup(),
                .auto_init => try materializeAutoInit(@constCast(self), index),
                .var_ref => if (entry.slot.var_ref.varRefValue().isUninitialized())
                    error.ReferenceError
                else
                    entry.slot.var_ref.varRefValue().dup(),
            };
        }
        if (self.denseArrayElement(atom_id)) |stored| return stored.dup();
        if (self.getPrototype()) |proto| return try proto.getProperty(atom_id);
        return JSValue.undefinedValue();
    }

    /// QJS-shaped first-access transaction. Shape preparation uses the caller
    /// Runtime before the stored construction Realm invokes exactly one
    /// builder. Any failure leaves the placeholder and its Realm owner intact;
    /// successful commit is infallible and releases that slot owner exactly
    /// once while the produced C function (if any) keeps its own RealmRef.
    fn materializeAutoInit(self: *Object, index: usize) PropertyReadError!JSValue {
        if (index >= self.shape_ref.prop_count or !self.isAutoInitAt(index)) return error.IncompatibleDescriptor;

        const expected_atom = self.propAtomAt(index);
        const expected_slot = self.propertyEntry(index).*.slot.auto_init;
        const realm_header = expected_slot.realm_and_id.realmHeader() orelse return error.InvalidBuiltinRegistry;
        const realm: *context_mod.RealmContext = @alignCast(@fieldParentPtr("header", realm_header));
        const rt = realm.runtime;

        // This is the only fallible target-shape step. It deliberately occurs
        // before the builder so commit never needs to allocate or clone shape
        // state after user/host code has produced a value.
        try self.ensureUniqueShapeForMutation(rt);
        if (!self.autoInitSlotStillMatches(index, expected_atom, expected_slot)) return error.IncompatibleDescriptor;

        const result: property.AutoInitMaterialization = switch (expected_slot.realm_and_id.id()) {
            .prototype => .{ .value = try self.materializeFunctionPrototypeAutoInit(realm) },
            .module_ns => try materializeModuleAutoInit(
                realm,
                expected_slot.moduleOwner() orelse return error.InvalidBuiltinRegistry,
                expected_atom,
            ),
            .prop => .{ .value = try materializePropAutoInit(realm, expected_slot.descriptor() orelse return error.InvalidBuiltinRegistry) },
        };

        return switch (result) {
            .value => |materialized| blk: {
                errdefer materialized.free(rt);
                if (!self.autoInitSlotStillMatches(index, expected_atom, expected_slot)) return error.IncompatibleDescriptor;
                break :blk try self.commitAutoInitValue(rt, index, expected_atom, materialized);
            },
            .var_ref => |cell| blk: {
                if (expected_slot.realm_and_id.id() != .module_ns) return error.IncompatibleDescriptor;
                if (!self.autoInitSlotStillMatches(index, expected_atom, expected_slot)) return error.IncompatibleDescriptor;
                break :blk self.commitAutoInitVarRef(rt, index, expected_atom, cell);
            },
        };
    }

    fn materializeModuleAutoInit(
        realm: *context_mod.RealmContext,
        owner: *const property.AutoInitModuleOwner,
        atom_id: atom.Atom,
    ) PropertyReadError!property.AutoInitMaterialization {
        return owner.resolve(owner, &realm.header, atom_id) catch |err| return @errorCast(err);
    }

    fn autoInitSlotStillMatches(self: *const Object, index: usize, expected_atom: atom.Atom, expected: property.AutoInitSlot) bool {
        if (index >= self.shape_ref.prop_count) return false;
        if (self.propAtomAt(index) != expected_atom or !self.isAutoInitAt(index)) return false;
        const current = self.propertyEntry(index).*.slot.auto_init;
        return current.realm_and_id.raw == expected.realm_and_id.raw and current.opaque_ptr == expected.opaque_ptr;
    }

    fn commitAutoInitValue(self: *Object, rt: *JSRuntime, index: usize, atom_id: atom.Atom, materialized: JSValue) !JSValue {
        const old_flags = self.propFlagsAt(index);
        const old_slot = self.propertyEntry(index).*.slot;
        if (!self.isGlobal()) {
            if (comptime builtin.is_test) {
                auditWrite(.union_arm, .object_prop_slot);
                self.propertyEntry(index).*.slot = .{ .data = materialized };
            } else {
                self.propertyEntry(index).*.slot = .{ .data = materialized };
            }
            // Materialising a lazily installed builtin turns an inert
            // placeholder into a real edge from an object that has typically
            // been old since realm setup (`Math.floor` is exactly this) to a
            // function created right now.
            rt.gc.generationalBarrier(&self.header, materialized.cycleMarkHeader());
            self.updateShapePropertyFlags(rt, index, old_flags.withKind(.data));
            destroyPropertySlot(rt, atom_id, old_flags, old_slot);
            return materialized.dup();
        }

        // A global AUTOINIT becomes a cell at materialization time, not a data
        // snapshot later repaired by global-closure construction. The caller
        // revalidated the slot immediately before entering this commit. Once
        // createClosed succeeds it owns `materialized`, and every remaining
        // operation is infallible, so there is no second owner/error cleanup.
        const cell = try var_ref_mod.VarRef.createClosed(rt, materialized);
        cell.is_lexical = false;
        cell.varRefIsConstSlot().* = !old_flags.writable;
        cell.varRefIsDeletableSlot().* = old_flags.configurable;
        if (comptime builtin.is_test) {
            auditWrite(.union_arm, .object_prop_slot);
            self.propertyEntry(index).*.slot = .{ .var_ref = cell };
        } else {
            self.propertyEntry(index).*.slot = .{ .var_ref = cell };
        }
        rt.gc.generationalBarrier(&self.header, &cell.header);
        self.updateShapePropertyFlags(rt, index, old_flags.withKind(.var_ref));
        destroyPropertySlot(rt, atom_id, old_flags, old_slot);
        return cell.varRefValue().dup();
    }

    fn commitAutoInitVarRef(self: *Object, rt: *JSRuntime, index: usize, atom_id: atom.Atom, cell: *var_ref_mod.VarRef) JSValue {
        const old_flags = self.propFlagsAt(index);
        const old_slot = self.propertyEntry(index).*.slot;
        if (comptime builtin.is_test) {
            auditWrite(.union_arm, .object_prop_slot);
            self.propertyEntry(index).*.slot = .{ .var_ref = cell.dupCell() };
        } else {
            self.propertyEntry(index).*.slot = .{ .var_ref = cell.dupCell() };
        }
        rt.gc.generationalBarrier(&self.header, &cell.header);
        self.updateShapePropertyFlags(rt, index, old_flags.withKind(.var_ref));
        destroyPropertySlot(rt, atom_id, old_flags, old_slot);
        return cell.varRefValue().dup();
    }

    fn materializeAutoInitEntryForMutation(self: *Object, index: usize) !void {
        if (index >= self.shape_ref.prop_count) return error.IncompatibleDescriptor;
        if (!self.isAutoInitAt(index)) return;
        const realm_header = self.propertyEntry(index).*.slot.auto_init.realm_and_id.realmHeader() orelse return error.InvalidBuiltinRegistry;
        const realm: *context_mod.RealmContext = @alignCast(@fieldParentPtr("header", realm_header));
        const transient = try materializeAutoInit(self, index);
        transient.free(realm.runtime);
    }

    /// True if the own property at `index` is an accessor. Auto-init
    /// placeholders are data-like: native accessors are installed eagerly.
    fn isAccessorOrAccessorPlaceholderAt(self: *const Object, index: usize) bool {
        const flags = self.propFlagsAt(index);
        return !flags.deleted and flags.kind == .accessor;
    }

    fn materializePropAutoInit(realm: *context_mod.RealmContext, info: *const property.AutoInit) PropertyReadError!JSValue {
        if (info.kind == .console) return materializeConsoleAutoInit(realm, info);
        if (info.kind == .math_namespace or
            info.kind == .json_namespace or
            info.kind == .reflect_namespace or
            info.kind == .atomics_namespace)
        {
            return materializeBuiltinNamespaceAutoInit(realm, info);
        }
        if (info.kind == .navigator) return materializeNavigatorAutoInit(realm);
        if (info.kind == .performance) return materializePerformanceAutoInit(realm);
        if (info.kind == .array_unscopables) return materializeArrayUnscopablesAutoInit(realm.runtime);
        if (info.kind == .string_constant) return materializeStringConstantAutoInit(realm.runtime, info);
        if (info.kind == .empty_array) return materializeEmptyArrayAutoInit(realm);
        if (info.host_function_kind != 0) return materializeHostFunctionAutoInit(realm, info);
        return materializeNativeFunctionAutoInit(realm, info);
    }

    fn materializeStringConstantAutoInit(rt: *JSRuntime, info: *const property.AutoInit) !JSValue {
        if (info.name.len == 0) {
            const cached = try rt.emptyString();
            return cached.value().dup();
        }
        const created = try string.String.createAscii(rt, info.name);
        return created.value();
    }

    fn materializeEmptyArrayAutoInit(realm: *context_mod.RealmContext) !JSValue {
        const array_proto_value = try arrayPrototypeValueForAutoInit(realm);
        defer array_proto_value.free(realm.runtime);
        const object = try Object.createArray(realm.runtime, objectFromValue(array_proto_value));
        return object.value();
    }

    fn materializeNativeFunctionAutoInit(realm: *context_mod.RealmContext, info: *const property.AutoInit) !JSValue {
        const function_proto = realm.cached_function_proto orelse return error.InvalidBuiltinRegistry;
        const materialized = try function.nativeFunctionWithPrototypeAndCapacity(realm, function_proto, info.name, info.length, 2);
        errdefer materialized.free(realm.runtime);
        if (comptime runtime_mod.value_root_frames_enabled) {
            var live = materialized;
            var val_roots = runtime_mod.rootValues(.{&live});
            val_roots.activate(realm.runtime);
            defer val_roots.deactivate(realm.runtime);
            try prepareAutoInitNativeFunction(realm.runtime, info, live);
            return live;
        }
        try prepareAutoInitNativeFunction(realm.runtime, info, materialized);
        return materialized;
    }

    fn prepareAutoInitNativeFunction(
        rt: *JSRuntime,
        info: *const property.AutoInit,
        function_value: JSValue,
    ) PropertyReadError!void {
        if (info.native_builtin_id != 0) {
            if (function_value.refHeader()) |header| {
                const obj: *Object = fromHeader(header);
                obj.setNativeBuiltinIdAndRecord(rt, info.native_builtin_id);
            }
        }
        try applyAutoInitFunctionMarkers(rt, function_value, info);
        if (info.prepare_native_function) |prepare| {
            prepare(rt, info, function_value) catch |err| return @errorCast(err);
        }
        // The constructor receives Function.prototype and the RealmRef before
        // metadata publication; there is no post-construction repair phase.
    }

    fn materializeArrayUnscopablesAutoInit(rt: *JSRuntime) !JSValue {
        const object = try Object.create(rt, class.ids.object, null);
        const unscopables_value = object.value();
        errdefer unscopables_value.free(rt);
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
            const key = try rt.internAtom(name);
            defer rt.atoms.free(key);
            try object.defineOwnPropertyAssumingNew(
                rt,
                key,
                descriptor.Descriptor.data(JSValue.boolean(true), true, true, true),
            );
        }
        return unscopables_value;
    }

    fn applyAutoInitFunctionMarkers(rt: *JSRuntime, function_value: JSValue, info: *const property.AutoInit) !void {
        const needs_rare = info.array_builtin_marker != .none or
            info.typed_array_builtin_marker != .none or
            info.array_iterator_kind != 0 or
            info.iterator_identity or
            info.collection_method_owner_class != class.invalid_class_id or
            info.disposable_stack_method != 0 or
            info.async_disposable_stack_method != 0;
        if (!needs_rare) return;
        const function_object = try Object.expect(function_value);
        const payload = try function_object.ensureFunctionRarePayload(rt);
        if ((info.array_builtin_marker != .none and !setArrayBuiltinMarker(payload, info.array_builtin_marker)) or
            (info.typed_array_builtin_marker != .none and !setTypedArrayBuiltinMarker(payload, info.typed_array_builtin_marker)) or
            (info.array_iterator_kind != 0 and !setArrayIteratorKind(payload, info.array_iterator_kind)) or
            (info.collection_method_owner_class != class.invalid_class_id and !setCollectionMethodOwnerClass(payload, info.collection_method_owner_class)) or
            (info.disposable_stack_method != 0 and !setDisposableStackMethod(payload, info.disposable_stack_method)) or
            (info.async_disposable_stack_method != 0 and !setAsyncDisposableStackMethod(payload, info.async_disposable_stack_method)))
        {
            return error.InvalidBuiltinRegistry;
        }
        if (info.iterator_identity) payload.iterator_identity = true;
    }

    fn materializeHostFunctionAutoInit(realm: *context_mod.RealmContext, info: *const property.AutoInit) !JSValue {
        const rt = realm.runtime;
        if (realm.global == null) return error.InvalidBuiltinRegistry;
        const function_proto = realm.cached_function_proto orelse return error.InvalidBuiltinRegistry;
        const function_capacity: usize = 2 + if (info.host_function_prototype) @as(usize, 1) else 0;
        const function_value = try function.nativeFunctionWithPrototypeAndCapacity(realm, function_proto, info.name, info.length, function_capacity);
        errdefer function_value.free(rt);
        const function_object = try Object.expect(function_value);
        function_object.hostFunctionKindSlot().* = info.host_function_kind;
        if (info.external_host_function_id != 0) {
            if (info.host_function_kind != host_function.ids.external_host) return error.InvalidBuiltinRegistry;
            function_object.externalHostFunctionIdSlot().* = info.external_host_function_id;
        }
        if (info.host_function_prototype) {
            const object_proto_value = try objectPrototypeValueForAutoInit(realm);
            defer object_proto_value.free(rt);
            const prototype = try Object.createWithOwnPropertyCapacity(rt, class.ids.object, objectFromValue(object_proto_value), 0);
            const prototype_value = prototype.value();
            defer prototype_value.free(rt);
            const prototype_key = atom.ids.prototype;
            try function_object.defineOwnPropertyAssumingNew(rt, prototype_key, descriptor.Descriptor.data(prototype_value, true, true, true));
        }

        return function_value;
    }

    fn materializeBuiltinNamespaceAutoInit(realm: *context_mod.RealmContext, info: *const property.AutoInit) PropertyReadError!JSValue {
        const global = realm.global orelse return error.InvalidBuiltinRegistry;
        const cb = realm.runtime.materialize_builtin_namespace_cb orelse return error.InvalidBuiltinRegistry;
        const materialized_value = cb(realm.runtime, global, info.kind) catch |err| return @errorCast(err);
        return materialized_value orelse error.InvalidBuiltinRegistry;
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

    fn materializeConsoleAutoInit(realm: *context_mod.RealmContext, info: *const property.AutoInit) !JSValue {
        const rt = realm.runtime;
        if (info.host_function_kind == 0) return error.InvalidBuiltinRegistry;
        const realm_global = realm.global orelse return error.InvalidBuiltinRegistry;
        const object_proto_value = try objectPrototypeValueForAutoInit(realm);
        defer object_proto_value.free(rt);
        const console = try Object.createWithOwnPropertyCapacity(rt, class.ids.object, objectFromValue(object_proto_value), 3);
        const console_value = console.value();
        errdefer console_value.free(rt);
        const methods = [_][]const u8{ "log", "warn", "error" };
        for (methods) |name| {
            try defineHostAutoInitDataPropertyByName(rt, console, name, 1, info.host_function_kind, info.external_host_function_id, realm_global);
        }
        return console_value;
    }

    fn materializeNavigatorAutoInit(realm: *context_mod.RealmContext) !JSValue {
        const rt = realm.runtime;
        const object_proto_value = try objectPrototypeValueForAutoInit(realm);
        defer object_proto_value.free(rt);
        const proto = try Object.createWithOwnPropertyCapacity(rt, class.ids.object, objectFromValue(object_proto_value), 2);
        var proto_owned = true;
        defer if (proto_owned) proto.value().free(rt);

        const tag = try string.String.createAscii(rt, "Navigator");
        const tag_value = tag.value();
        defer tag_value.free(rt);
        try proto.defineOwnPropertyAssumingNew(
            rt,
            atom.predefinedId("Symbol.toStringTag", .symbol).?,
            descriptor.Descriptor.data(tag_value, false, false, true),
        );

        const getter = try function.nativeFunction(realm, "get userAgent", 0);
        defer getter.free(rt);
        if (getter.refHeader()) |getter_header| {
            const getter_object: *Object = fromHeader(getter_header);
            getter_object.setNativeBuiltinIdAndRecord(rt, function.nativeBuiltinId(.host, @intFromEnum(function.HostGlobalMethod.navigator_user_agent_get)));
        }
        const user_agent = try rt.internAtom("userAgent");
        defer rt.atoms.free(user_agent);
        try proto.defineOwnPropertyAssumingNew(
            rt,
            user_agent,
            descriptor.Descriptor.accessor(getter, JSValue.undefinedValue(), true, true),
        );

        const navigator = try Object.createWithOwnPropertyCapacity(rt, class.ids.object, proto, 0);
        proto.value().free(rt);
        proto_owned = false;
        return navigator.value();
    }

    fn materializePerformanceAutoInit(realm: *context_mod.RealmContext) !JSValue {
        const rt = realm.runtime;
        const global = realm.global orelse return error.InvalidBuiltinRegistry;
        if (rt.performance_time_origin_ms == 0) rt.performance_time_origin_ms = performanceAutoInitNowMs();
        const object_proto_value = try objectPrototypeValueForAutoInit(realm);
        defer object_proto_value.free(rt);
        const performance = try Object.createWithOwnPropertyCapacity(rt, class.ids.object, objectFromValue(object_proto_value), 2);
        const performance_value = performance.value();
        errdefer performance_value.free(rt);

        const now_key = atom.predefinedId("now", .string).?;
        const method_flags = property.Flags.data(true, false, true);
        try performance.defineAutoInitPropertyWithRealmAndNative(
            rt,
            now_key,
            "now",
            0,
            method_flags,
            global,
            function.nativeBuiltinId(.performance, 1),
        );

        const origin_key = atom.predefinedId("timeOrigin", .string).?;
        try performance.defineOwnPropertyAssumingNew(
            rt,
            origin_key,
            descriptor.Descriptor.data(JSValue.float64(rt.performance_time_origin_ms), true, true, true),
        );

        return performance_value;
    }

    fn performanceAutoInitNowMs() f64 {
        const io = std.Io.Threaded.global_single_threaded.io();
        const ns = std.Io.Clock.Timestamp.now(io, .awake).raw.toNanoseconds();
        return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
    }

    /// Return an owned value for the realm's Object.prototype.
    ///
    /// The visible-constructor fallback is observable and may produce a fresh
    /// object. Keeping only its raw pointer after freeing the property result
    /// leaves bare/embedder realms with a dangling prototype during the
    /// following allocation. Cached intrinsic values are duplicated so both
    /// branches have the same ownership contract.
    fn objectPrototypeValueForAutoInit(realm: *context_mod.RealmContext) !JSValue {
        const rt = realm.runtime;
        const global = realm.global orelse return error.InvalidBuiltinRegistry;
        if (global.cachedRealmValue(rt, .object_prototype)) |stored| {
            if (stored.isObject()) return stored.dup();
        }
        const object_ctor_value = try global.getProperty(atom.predefinedId("Object", .string).?);
        defer object_ctor_value.free(rt);
        if (!object_ctor_value.isObject()) return error.InvalidBuiltinRegistry;
        const prototype_value = try objectFromValue(object_ctor_value).?.getProperty(atom.ids.prototype);
        if (prototype_value.isObject()) return prototype_value;
        prototype_value.free(rt);
        return JSValue.nullValue();
    }

    /// Materialize a lazy `function.prototype` placeholder (qjs
    /// `js_instantiate_prototype`, quickjs.c:17341). `self` is the owner
    /// function object; the prototype's [[Prototype]] is the function's realm
    /// `Object.prototype`, and `constructor` points back at `self`
    /// (writable, non-enumerable, configurable) — installed only here, so the
    /// `func <-> prototype.constructor` cycle forms lazily, never for a
    /// function whose `.prototype` is never observed.
    fn materializeFunctionPrototypeAutoInit(self: *Object, realm: *context_mod.RealmContext) !JSValue {
        const rt = realm.runtime;
        const object_proto_value = try objectPrototypeValueForAutoInit(realm);
        defer object_proto_value.free(rt);
        const prototype = try Object.create(rt, class.ids.object, objectFromValue(object_proto_value));
        var prototype_owned = true;
        errdefer if (prototype_owned) Object.destroyFromHeader(rt, &prototype.header);
        try prototype.defineOwnProperty(rt, atom.ids.constructor, descriptor.Descriptor.data(self.value(), true, false, true));
        prototype_owned = false;
        return prototype.value();
    }

    /// qjs `JS_DefineAutoInitProperty` (quickjs.c:10648-10675) on a freshly
    /// created function: `find_own_property` is a miss (abort if present), then
    /// `add_property(flags & C_W_E | AUTOINIT)` and
    /// `pr->u.init.realm_and_id = JS_DupContext(ctx) | JS_AUTOINIT_ID_PROTOTYPE`,
    /// `opaque = NULL`. `realm` is the creating context — qjs dups `ctx`, it
    /// does not walk bytecode/native/global to rediscover it.
    ///
    /// `prototype` is a predefined atom and not an array index, so the append
    /// is the named add_property arm (no atom-dup guard, no `atomIsArrayIndex`).
    // ===== define* properties =====
    pub fn defineFunctionPrototypeAutoInit(
        self: *Object,
        rt: *JSRuntime,
        realm: *context_mod.RealmContext,
        flags: property.Flags,
    ) !void {
        std.debug.assert(!self.hasExoticMethods());
        std.debug.assert(self.flags.extensible);
        const slot = property.AutoInitSlot.retainPrototype(&realm.header);
        try self.appendPreparedPropertyEntryImpl(
            true,
            false,
            true,
            rt,
            atom.ids.prototype,
            flags.withKind(.auto_init),
            .{ .auto_init = slot },
        );
    }

    /// qjs `JS_DefinePropertyValue` → `JS_CreateProperty` data arm on a
    /// known-new ordinary object (quickjs.c:10215-10266):
    /// `prop_flags = flags & JS_PROP_C_W_E`, `add_property`, then
    /// `pr->u.value = JS_DupValue(ctx, val)` (the wrapper then frees `val`).
    /// The caller hands over a freshly created value; this path consumes it
    /// into the slot (dup+free of a temp is a no-op on the end state).
    ///
    /// `atom_id` must be a predefined non-index atom (`length` / `name`).
    pub fn defineOwnDataValueAssumingNew(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        data_value: JSValue,
        flags: property.Flags,
    ) !void {
        std.debug.assert(!self.hasExoticMethods());
        std.debug.assert(self.flags.extensible);
        std.debug.assert(flags.kind == .data);
        try self.appendPreparedPropertyEntryImpl(
            true,
            false,
            true,
            rt,
            atom_id,
            flags,
            .{ .data = data_value },
        );
    }

    fn arrayPrototypeValueForAutoInit(realm: *context_mod.RealmContext) !JSValue {
        const rt = realm.runtime;
        const global = realm.global orelse return error.InvalidBuiltinRegistry;
        if (global.cachedRealmValue(rt, .array_prototype)) |stored| {
            if (stored.isObject()) return stored.dup();
        }
        const array_key = atom.predefinedId("Array", .string) orelse return error.InvalidBuiltinRegistry;
        const array_ctor_value = try global.getProperty(array_key);
        defer array_ctor_value.free(rt);
        if (!array_ctor_value.isObject()) return error.InvalidBuiltinRegistry;
        const prototype_value = try objectFromValue(array_ctor_value).?.getProperty(atom.ids.prototype);
        if (prototype_value.isObject()) return prototype_value;
        prototype_value.free(rt);
        return JSValue.nullValue();
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

    /// Borrowed own `.prototype` object for a constructor's [[Construct]].
    /// Normal functions use the same lazy JS_DefineAutoInitProperty mechanism
    /// as qjs, so a bare data read must materialize the placeholder before the
    /// constructor falls back to reflectConstructPrototypeVm. The slot then
    /// becomes a permanent .data object, and every later `new` takes the direct
    /// read. Accessor / var_ref prototypes (or an exotic receiver) return null
    /// to keep the general path. Returns a BORROWED pointer (Object.create dups
    /// it).
    pub fn getOwnConstructorPrototypeObject(self: *Object, rt: *JSRuntime) !?*Object {
        if (self.hasExoticMethods()) return null;
        const index = self.findProperty(atom.ids.prototype) orelse return null;
        const flags = self.propFlagsAt(index);
        if (flags.deleted) return null;
        switch (flags.kind) {
            .data => {},
            .auto_init => {
                const materialized = try self.materializeAutoInit(index);
                materialized.free(rt);
            },
            else => return null,
        }
        const stored = self.asDataAt(index) orelse return null;
        return objectFromValue(stored);
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
        return self.propertyEntry(index).*.slot.data.dup();
    }

    pub fn getDenseArrayElementValue(self: *const Object, index: u32) ?JSValue {
        return self.fastArrayElementDup(index);
    }

    pub fn defineOwnProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void {
        // Generational barrier at the define funnel. Every define path below --
        // ordinary, exotic, array, create-on-miss -- publishes the descriptor's
        // references into this object, and they are spread across a dozen raw
        // slot stores. Recording the owner once here is what makes the set
        // complete rather than a list that has to be kept in step; the
        // individual stores keep their own barriers where they are the only
        // writer.
        if (comptime gc.generation_enabled) {
            rt.gc.generationalBarrier(&self.header, desc.value.cycleMarkHeader());
            rt.gc.generationalBarrier(&self.header, desc.getter.cycleMarkHeader());
            rt.gc.generationalBarrier(&self.header, desc.setter.cycleMarkHeader());
        }
        // qjs JS_DefineProperty resolves a real own shape entry first; only a
        // miss reaches JS_CreateProperty's exotic/array create machinery.
        // Ordinary classes therefore pay one slow-property classification,
        // not the module/mapped/array prelude on every define.
        if (!self.needsSlowPropertyAccess()) {
            try self.defineOrdinaryOwnProperty(rt, atom_id, desc);
            return;
        }
        // Exotic [[DefineOwnProperty]] is a create-on-miss hook in qjs:
        // actual shape entries are updated by JS_DefineProperty before it
        // reaches JS_CreateProperty.
        if (self.findProperty(atom_id) == null) {
            if (self.exoticMethods(rt)) |methods| {
                if (methods.define_own_property) |hook| {
                    if (!hook(self, atom_id, desc)) return error.IncompatibleDescriptor;
                    return;
                }
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
        // Generational barrier at the define funnel. Every define path below --
        // ordinary, exotic, array, create-on-miss -- publishes the descriptor's
        // references into this object, and they are spread across a dozen raw
        // slot stores. Recording the owner once here is what makes the set
        // complete rather than a list that has to be kept in step; the
        // individual stores keep their own barriers where they are the only
        // writer.
        if (comptime gc.generation_enabled) {
            rt.gc.generationalBarrier(&self.header, desc.value.cycleMarkHeader());
            rt.gc.generationalBarrier(&self.header, desc.getter.cycleMarkHeader());
            rt.gc.generationalBarrier(&self.header, desc.setter.cycleMarkHeader());
        }

        std.debug.assert(self.supportsPlainNamedPropertyStorage());
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.flags.extensible);
        try self.addProperty(rt, atom_id, desc);
    }

    /// Publish one new C_W_E data property whose atom is independently rooted
    /// by immutable bytecode for the whole call. This is the ownership shape
    /// of qjs OP_put_field/add_property: the bytecode owns the operand atom and
    /// the new Shape takes the sole additional reference. The value remains a
    /// borrow, so the installed slot retains it exactly as the descriptor path
    /// does. Callers must prove the atom root and the ordinary/new-property
    /// preconditions; this entry deliberately performs no duplicate probe.
    pub fn defineOwnDataPropertyAssumingNewFromRootedAtom(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        data_value: JSValue,
    ) !void {
        std.debug.assert(!self.hasExoticMethods());
        std.debug.assert(self.supportsPlainNamedPropertyStorage());
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.flags.extensible);
        try self.appendPreparedPropertyEntryImpl(
            true,
            false,
            false,
            rt,
            atom_id,
            comptime property.Flags.data(true, true, true),
            .{ .data = data_value.dup() },
        );
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
            const entry = self.propertyEntry(index);
            const next_value = dupPropertyDataValue(&rt.atoms, atom_id, new_value);
            errdefer next_value.free(rt);
            const old_slot = entry.slot;
            if (comptime builtin.is_test) {
                auditWrite(.union_arm, .object_prop_slot);
                entry.slot = .{ .data = next_value };
            } else {
                entry.slot = .{ .data = next_value };
            }
            self.updateShapePropertyFlags(rt, index, property.Flags.data(true, true, true));
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
        // Every write to `shape_ref` is an owner adopting a Shape: the clone or
        // relocation this call may perform produces a fresh, young one, and a
        // long-lived owner reaching it is an old-to-young edge the minor's
        // sticky marks would otherwise stop short of.
        rt.gc.generationalBarrier(&self.header, &self.shape_ref.header);
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
    fn autoInitRealmForDefinition(self: *Object, rt: *JSRuntime, explicit_global: ?*Object) !*context_mod.RealmContext {
        if (explicit_global) |global| {
            return rt.contextForGlobalIncludingConstructing(global) orelse error.InvalidBuiltinRegistry;
        }
        if (self.bytecodeFunctionRealmContext()) |realm| return realm;
        if (self.nativeFunctionRealm()) |realm| return realm;
        if (rt.contextForGlobalIncludingConstructing(self)) |realm| return realm;
        return error.InvalidBuiltinRegistry;
    }

    fn createPropAutoInitSlot(
        self: *Object,
        rt: *JSRuntime,
        explicit_global: ?*Object,
        info: property.AutoInit,
    ) !property.AutoInitSlot {
        // internAutoInit can collect before the AutoInitSlot retains the
        // realm. Name the holder and explicit global for that window (§4.6).
        if (comptime runtime_mod.value_root_frames_enabled) {
            var holder: ?*Object = self;
            var global: ?*Object = explicit_global;
            var obj_roots = runtime_mod.rootObjects(.{ &holder, &global });
            obj_roots.activate(rt);
            defer obj_roots.deactivate(rt);
            return createPropAutoInitSlotWork(self, rt, explicit_global, info);
        }
        return createPropAutoInitSlotWork(self, rt, explicit_global, info);
    }

    inline fn createPropAutoInitSlotWork(
        self: *Object,
        rt: *JSRuntime,
        explicit_global: ?*Object,
        info: property.AutoInit,
    ) !property.AutoInitSlot {
        const realm = try self.autoInitRealmForDefinition(rt, explicit_global);
        const stored = try property.internAutoInit(rt, info);
        return property.AutoInitSlot.retainProp(&realm.header, stored);
    }

    /// Installs a PROP placeholder backed directly by an immutable descriptor
    /// whose lifetime dominates the property. Standard tables pass pointers to
    /// static entries; dynamic host callers use the Runtime arena path below.
    pub fn defineAutoInitPropertyFromDescriptor(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        flags: property.Flags,
        realm_global: ?*Object,
        info: *const property.AutoInit,
    ) !void {
        const realm = try self.autoInitRealmForDefinition(rt, realm_global);
        try self.defineAutoInitPropertyFromDescriptorWithResolvedRealm(rt, atom_id, flags, realm, info);
    }

    /// Internal bootstrap fast path for a caller that has already resolved the
    /// target's Realm. Each property still owns one retained Realm edge; only
    /// the repeated target/global-to-Realm lookup is skipped.
    pub fn defineAutoInitPropertyFromDescriptorWithResolvedRealm(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        flags: property.Flags,
        resolved_realm: *context_mod.RealmContext,
        info: *const property.AutoInit,
    ) !void {
        std.debug.assert(!self.hasExoticMethods());
        std.debug.assert(self.supportsPlainNamedPropertyStorage());
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.flags.extensible);
        std.debug.assert(resolved_realm.runtime == rt);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags.withKind(.auto_init), .{
            .auto_init = property.AutoInitSlot.retainProp(&resolved_realm.header, info),
        });
    }

    /// Install a normal module-namespace export as the exporter-owned VarRef
    /// itself.  The supplied cell reference is consumed on every return path;
    /// the property owns that transferred reference on success.
    pub fn defineModuleVarRefProperty(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        owned_cell: *var_ref_mod.VarRef,
    ) !void {
        const flags = property.Flags.varRef(true, true, false);
        if (self.class_id != class.ids.module_ns or
            !self.flags.extensible or
            self.findProperty(atom_id) != null)
        {
            owned_cell.freeCell(rt);
            return error.IncompatibleDescriptor;
        }
        try self.appendPreparedPropertyEntry(rt, atom_id, flags, .{ .var_ref = owned_cell });
    }

    /// Install a delayed module-namespace export.  The stable owner Interface
    /// is embedded in the originating module record; this slot owns only the
    /// Realm edge that keeps the record and Interface alive.
    pub fn defineModuleAutoInitProperty(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        realm: *context_mod.RealmContext,
        owner: *const property.AutoInitModuleOwner,
    ) !void {
        if (self.class_id != class.ids.module_ns or
            !self.flags.extensible or
            self.findProperty(atom_id) != null)
        {
            return error.IncompatibleDescriptor;
        }
        try self.appendModuleAutoInitProperty(
            rt,
            atom_id,
            property.Flags.data(true, true, false),
            realm,
            owner,
        );
    }

    fn appendModuleAutoInitProperty(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        flags: property.Flags,
        realm: *context_mod.RealmContext,
        owner: *const property.AutoInitModuleOwner,
    ) !void {
        std.debug.assert(realm.runtime == rt);
        std.debug.assert(self.supportsPlainNamedPropertyStorage());
        std.debug.assert(self.flags.extensible);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags.withKind(.auto_init), .{
            .auto_init = property.AutoInitSlot.retainModule(&realm.header, owner),
        });
    }

    /// W1b3d1 fixture seam.  It delegates to the same slot producer as real
    /// module namespace properties and therefore cannot create a parallel
    /// ownership or publication protocol.
    pub fn defineModuleAutoInitPropertyForFixture(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        flags: property.Flags,
        realm: *context_mod.RealmContext,
        owner: *const property.AutoInitModuleOwner,
    ) !void {
        try self.appendModuleAutoInitProperty(rt, atom_id, flags, realm, owner);
    }

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
        std.debug.assert(!self.hasExoticMethods());
        std.debug.assert(self.supportsPlainNamedPropertyStorage());
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.flags.extensible);
        // Inlined to skip `entryFromDescriptor`'s value-dup / accessor-
        // dup work: the placeholder has no JSValue to retain, just the
        // (name, length, rt) triple stored in the runtime auto-init table.
        // The atom is still retained the same way `addProperty` would, via
        // `rt.shapes.addProperty` -> `atoms.dup`.
        try self.appendPreparedPropertyEntry(rt, atom_id, flags.withKind(.auto_init), .{ .auto_init = try self.createPropAutoInitSlot(rt, realm_global, .{
            .name = name,
            .length = length,
            .native_builtin_id = native_builtin_id,
        }) });
    }

    pub fn replaceAutoInitPropertyWithRealmAndNative(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        name: []const u8,
        length: i32,
        flags: property.Flags,
        realm_global: ?*Object,
        native_builtin_id: i32,
    ) !void {
        if (self.findProperty(atom_id)) |index| {
            if (!self.isAutoInitAt(index)) return error.TypeError;
            const ai_flags = flags.withKind(.auto_init);
            // Prepare before publication: every fallible step (unique-shape
            // clone, replacement slot construction) completes before any flag
            // or slot byte is published, so an OOM leaves the entry untouched.
            if (self.propFlagsAt(index).bits() != ai_flags.bits())
                try self.ensureUniqueShapeForMutation(rt);
            const next_slot = try self.createPropAutoInitSlot(rt, realm_global, .{
                .name = name,
                .length = length,
                .native_builtin_id = native_builtin_id,
            });
            self.setEntryKindAndSlot(rt, atom_id, index, ai_flags, .{ .auto_init = next_slot });
            self.pruneBorrowedReferenceHolderIfEmpty(rt);
            return;
        }
        try self.defineAutoInitPropertyWithRealmAndNative(rt, atom_id, name, length, flags, realm_global, native_builtin_id);
    }

    /// Bootstrap alias publication: replace an already-installed AUTOINIT
    /// source entry with the exact same function value obtained from another
    /// property, without materializing the entry being replaced. This mirrors
    /// QJS `JS_DEF_ALIAS` ordering and keeps source/alias properties independent
    /// after publication while sharing the function identity.
    pub fn replaceAutoInitPropertyWithData(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        source_value: JSValue,
        flags: property.Flags,
    ) !void {
        const index = self.findProperty(atom_id) orelse return error.IncompatibleDescriptor;
        const old_flags = self.propFlagsAt(index);
        if (!old_flags.isAutoInit()) return error.IncompatibleDescriptor;
        const next_value = dupPropertyDataValue(&rt.atoms, atom_id, source_value);
        errdefer next_value.free(rt);
        try self.ensureUniqueShapeForMutation(rt);
        const old_slot = self.propertyEntry(index).*.slot;
        if (comptime builtin.is_test) {
            auditWrite(.union_arm, .object_prop_slot);
            self.propertyEntry(index).*.slot = .{ .data = next_value };
        } else {
            self.propertyEntry(index).*.slot = .{ .data = next_value };
        }
        // Publishes the slot itself instead of going through
        // `setEntryKindAndSlot`, so it has to take that funnel's barrier. The
        // direction here is always the dangerous one: an auto-init slot lives
        // on a builtin object that has existed since realm setup, and whatever
        // replaces it was just built.
        rt.gc.generationalBarrier(&self.header, next_value.cycleMarkHeader());
        self.updateShapePropertyFlags(rt, index, flags.withKind(.data));
        destroyPropertySlot(rt, atom_id, old_flags, old_slot);
        self.pruneBorrowedReferenceHolderIfEmpty(rt);
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
        try self.appendPreparedPropertyEntry(rt, atom_id, flags.withKind(.auto_init), .{ .auto_init = try self.createPropAutoInitSlot(rt, realm_global, .{
            .name = "navigator",
            .length = 0,
            .kind = .navigator,
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
        std.debug.assert(!self.hasExoticMethods());
        std.debug.assert(self.supportsPlainNamedPropertyStorage());
        std.debug.assert(self.flags.extensible);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags.withKind(.auto_init), .{ .auto_init = try self.createPropAutoInitSlot(rt, null, .{
            .name = "console",
            .length = 0,
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
        try self.appendPreparedPropertyEntry(rt, atom_id, flags.withKind(.auto_init), .{ .auto_init = try self.createPropAutoInitSlot(rt, realm_global, .{
            .name = "performance",
            .length = 0,
            .kind = .performance,
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
        std.debug.assert(!self.hasExoticMethods());
        std.debug.assert(self.supportsPlainNamedPropertyStorage());
        std.debug.assert(self.flags.extensible);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags.withKind(.auto_init), .{ .auto_init = try self.createPropAutoInitSlot(rt, realm_global, .{
            .name = name,
            .length = 0,
            .kind = kind,
        }) });
    }

    pub fn defineArrayUnscopablesAutoInitProperty(
        self: *Object,
        rt: *JSRuntime,
        atom_id: atom.Atom,
        flags: property.Flags,
    ) !void {
        std.debug.assert(!self.hasExoticMethods());
        std.debug.assert(self.flags.extensible);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags.withKind(.auto_init), .{ .auto_init = try self.createPropAutoInitSlot(rt, null, .{
            .name = "[Symbol.unscopables]",
            .length = 0,
            .kind = .array_unscopables,
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
        try self.appendPreparedPropertyEntry(rt, atom_id, flags.withKind(.auto_init), .{ .auto_init = try self.createPropAutoInitSlot(rt, null, .{
            .name = bytes,
            .length = 0,
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
        // Shape clone and AutoInit intern can collect before the replacement
        // is installed. Name holder and realm global across that window (§4.6).
        if (comptime runtime_mod.value_root_frames_enabled) {
            var holder: ?*Object = self;
            var global: ?*Object = realm_global;
            var obj_roots = runtime_mod.rootObjects(.{ &holder, &global });
            obj_roots.activate(rt);
            defer obj_roots.deactivate(rt);
            return defineEmptyArrayAutoInitPropertyMut(self, rt, atom_id, flags, realm_global);
        }
        return defineEmptyArrayAutoInitPropertyMut(self, rt, atom_id, flags, realm_global);
    }

    inline fn defineEmptyArrayAutoInitPropertyMut(
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
        if (self.findProperty(atom_id)) |index| {
            if (!self.propFlagsAt(index).configurable) return error.IncompatibleDescriptor;
            try self.ensureUniqueShapeForMutation(rt);
            const next_slot = try self.createPropAutoInitSlot(rt, realm_global, .{
                .name = "empty array",
                .length = 0,
                .kind = .empty_array,
            });
            self.setEntryKindAndSlot(
                rt,
                atom_id,
                index,
                flags.withKind(.auto_init),
                .{ .auto_init = next_slot },
            );
            self.pruneBorrowedReferenceHolderIfEmpty(rt);
            return;
        }
        try self.appendPreparedPropertyEntry(rt, atom_id, flags.withKind(.auto_init), .{ .auto_init = try self.createPropAutoInitSlot(rt, realm_global, .{
            .name = "empty array",
            .length = 0,
            .kind = .empty_array,
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
        realm_global: ?*Object,
    ) !void {
        try self.defineHostAutoInitPropertyWithExternalId(
            rt,
            atom_id,
            name,
            length,
            flags,
            host_function_kind,
            host_function_prototype,
            realm_global,
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
        realm_global: ?*Object,
        external_host_function_id: u32,
    ) !void {
        std.debug.assert(host_function_kind != 0);
        std.debug.assert(external_host_function_id == 0 or host_function_kind == host_function.ids.external_host);
        std.debug.assert(!self.hasExoticMethods());
        std.debug.assert(self.supportsPlainNamedPropertyStorage());
        std.debug.assert(self.class_id != class.ids.mapped_arguments);
        std.debug.assert(self.flags.extensible);
        try self.appendPreparedPropertyEntry(rt, atom_id, flags.withKind(.auto_init), .{ .auto_init = try self.createPropAutoInitSlot(rt, realm_global, .{
            .name = name,
            .length = length,
            .host_function_kind = host_function_kind,
            .external_host_function_id = external_host_function_id,
            .host_function_prototype = host_function_prototype,
        }) });
    }

    pub fn writeDenseArrayIndex(self: *Object, rt: *JSRuntime, index: u32, atom_id: atom.Atom, new_value: JSValue) !bool {
        if (!self.isArray() or !self.flags.length_writable) return false;
        if (self.arrayElementStorageMode() != .dense) return false;
        if (self.shape_ref.prop_count != 0 and self.findProperty(atom_id) != null) return false;
        const elements = self.arrayElements();
        if (index >= elements.len) return false;
        return self.setFastArrayElementDup(rt, index, new_value);
    }

    /// QuickJS `can_extend_fast_array`: an ordinary dense Array may append
    /// without a prototype walk only when it is extensible and its direct
    /// prototype is null or the still-pristine intrinsic %Array.prototype%.
    pub fn canExtendFastArray(self: *const Object) bool {
        if (!self.flags.extensible) return false;
        const proto = self.getPrototype() orelse return true;
        return proto.flags.is_std_array_prototype;
    }

    pub fn appendDenseArrayIndex(self: *Object, rt: *JSRuntime, index: u32, atom_id: atom.Atom, new_value: JSValue) !bool {
        return self.appendDenseArrayIndexMode(rt, index, atom_id, new_value, false);
    }

    /// Owned-value counterpart of `appendDenseArrayIndex`. The value is
    /// consumed only when this returns true; false/error leave ownership with
    /// the caller. Mirrors QuickJS OP_put_array_el's direct stack-to-slot move.
    pub fn appendDenseArrayIndexOwned(self: *Object, rt: *JSRuntime, index: u32, atom_id: atom.Atom, new_value: JSValue) !bool {
        return self.appendDenseArrayIndexMode(rt, index, atom_id, new_value, true);
    }

    fn appendDenseArrayIndexMode(self: *Object, rt: *JSRuntime, index: u32, atom_id: atom.Atom, new_value: JSValue, comptime take_ownership: bool) !bool {
        // qjs add_fast_array_element (quickjs.c:9542-9570): the dense append
        // gate is `idx == count`, NOT `idx == length`. A holey array (length >
        // count) can append at `count`; `length` is bumped to `index+1` only
        // when it grows past the current length.
        if (!self.isArray() or index != self.arrayArm().*.count or !self.flags.length_writable) return false;
        if (self.hasExoticMethods() or self.arrayElementStorageMode() != .dense) return false;
        if (!self.canExtendFastArray()) return false;
        if (self.shape_ref.prop_count != 0 and self.findProperty(atom_id) != null) return false;

        const element_slot = try self.appendUninitializedFastArraySlot(rt);
        if (comptime builtin.is_test) {
            auditWrite(.fam_slice, .object_dense_store);
            element_slot.* = if (take_ownership) new_value else new_value.dup();
        } else {
            element_slot.* = if (take_ownership) new_value else new_value.dup();
        }
        if (index + 1 > self.arrayArm().*.length) self.arrayArm().*.length = index + 1;
        self.markIndexedProperties(rt);
        return true;
    }

    pub fn appendDenseArrayValues(self: *Object, rt: *JSRuntime, start: u32, values: []const JSValue) !bool {
        // Dense append gate keys off the dense extent (array_count), not the
        // logical length: a holey array appends at count. See add_fast_array_element.
        if (!self.isArray() or start != self.arrayArm().*.count or !self.flags.length_writable) return false;
        if (self.hasExoticMethods() or self.arrayElementStorageMode() != .dense) return false;
        if (!self.canExtendFastArray()) return false;
        const added: u32 = std.math.cast(u32, values.len) orelse return false;
        const limit = std.math.add(u32, start, added) catch return false;
        if (limit > array.max_array_length) return false;

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
        }

        try self.ensureArrayElementCapacity(rt, @intCast(limit));
        var element_index: usize = @intCast(start);
        if (comptime builtin.is_test) {
            auditWrite(.fam_slice, .object_dense_store);
            for (values) |item| {
                self.arrayArm().*.values[element_index] = item.dup();
                element_index += 1;
            }
        } else {
            for (values) |item| {
                self.arrayArm().*.values[element_index] = item.dup();
                element_index += 1;
            }
        }
        self.setFastArrayCountAssumeCapacity(limit);
        if (limit > self.arrayArm().*.length) self.arrayArm().*.length = limit;
        self.markIndexedProperties(rt);
        return true;
    }

    /// qjs `js_array_push` store (quickjs.c:42776-42787). Caller already
    /// proved `JS_CLASS_ARRAY && fast_array && can_extend_fast_array &&
    /// length==count && writable` and `count + values.len <= INT32_MAX`.
    /// No named-property scan: qjs writes `u.array.u.values` directly.
    pub fn appendFastArrayPushValues(self: *Object, rt: *JSRuntime, values: []const JSValue) !void {
        const added: u32 = @intCast(values.len);
        const new_len = self.arrayArm().*.count + added;
        if (new_len > self.arrayArm().*.capacity) {
            try self.ensureArrayElementCapacity(rt, new_len);
        }
        var element_index: usize = @intCast(self.arrayArm().*.count);
        if (comptime builtin.is_test) {
            auditWrite(.fam_slice, .object_dense_store);
            for (values) |item| {
                self.arrayArm().*.values[element_index] = item.dup();
                element_index += 1;
            }
        } else {
            for (values) |item| {
                self.arrayArm().*.values[element_index] = item.dup();
                element_index += 1;
            }
        }
        if (comptime gc.generation_enabled) {
            for (values) |item| rt.gc.generationalBarrier(&self.header, item.cycleMarkHeader());
        }
        self.setFastArrayCountAssumeCapacity(new_len);
        if (new_len > self.arrayArm().*.length) self.arrayArm().*.length = new_len;
        if (added != 0) self.markIndexedProperties(rt);
    }

    pub fn initDenseArrayIndexZeroAssumingEmpty(self: *Object, rt: *JSRuntime, new_value: JSValue) !void {
        std.debug.assert(self.isArray());
        std.debug.assert(self.arrayArm().*.count == 0);
        std.debug.assert(self.flags.length_writable);
        std.debug.assert(self.flags.extensible);
        std.debug.assert(self.arrayElements().len == 0);
        std.debug.assert(self.arrayElementsCapacity() == 0);

        const element_slot = try self.appendUninitializedFastArraySlot(rt);
        if (comptime builtin.is_test) {
            auditWrite(.fam_slice, .object_dense_store);
            element_slot.* = new_value.dup();
        } else {
            element_slot.* = new_value.dup();
        }
        if (self.arrayArm().*.length < 1) self.arrayArm().*.length = 1;
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
        if (!self.isArray() or index != self.arrayArm().*.count or !self.flags.length_writable) return false;
        if (self.arrayElementStorageMode() != .dense) return false;
        if (!self.flags.extensible) return false;
        if (self.shape_ref.prop_count != 0 and self.findPropertyIndexTrusted(atom_id) != null) return false;

        const element_slot = try self.appendUninitializedFastArraySlot(rt);
        if (comptime builtin.is_test) {
            auditWrite(.fam_slice, .object_dense_store);
            element_slot.* = if (take_ownership) new_value else new_value.dup();
        } else {
            element_slot.* = if (take_ownership) new_value else new_value.dup();
        }
        if (index + 1 > self.arrayArm().*.length) self.arrayArm().*.length = index + 1;
        self.markIndexedProperties(rt);
        return true;
    }

    pub fn initDenseArrayLiteralValuesAssumingEmpty(self: *Object, rt: *JSRuntime, values: []const JSValue) !bool {
        if (!self.isArray() or !self.flags.length_writable or !self.flags.extensible) return false;
        if (self.arrayArm().*.count != 0 or self.arrayArm().*.length != 0 or self.shape_ref.prop_count != 0) return false;
        if (self.arrayElementStorageMode() != .dense) return false;
        if (values.len > array.max_array_length) return false;

        try self.ensureArrayElementCapacity(rt, values.len);
        self.setFastArrayCountAssumeCapacity(@intCast(values.len));
        self.arrayArm().*.length = @intCast(values.len);
        if (comptime builtin.is_test) {
            auditWrite(.fam_slice, .object_dense_store);
            for (values, 0..) |item, index| {
                const element_slot = &self.arrayArm().*.values[index];
                element_slot.* = item.dup();
            }
        } else {
            for (values, 0..) |item, index| {
                const element_slot = &self.arrayArm().*.values[index];
                element_slot.* = item.dup();
            }
        }
        if (values.len != 0) self.markIndexedProperties(rt);
        return true;
    }

    /// Owned-move fill for a FRESH literal array — qjs `js_create_array_free`'s
    /// post-`JS_NewArray` body (quickjs.c:9636-9650): `expand_fast_array` +
    /// `p->u.array.count = len` + a plain move of every element (`u.values[i] =
    /// tab[i]`, no dup) + the length publication. The caller guarantees the
    /// array came straight from the initial-shape allocator (dense, empty,
    /// extensible, writable length, zero named properties), so the sibling
    /// borrow-mode guard chain collapses to Debug asserts, exactly like qjs
    /// trusting JS_NewArray's output. On success the values are consumed; on
    /// error they remain owned by the caller (the cold shell re-runs the op on
    /// the untouched operand window — qjs frees tab on its inline fail path,
    /// which our caller's error route performs instead).
    pub fn initDenseArrayLiteralValuesOwnedTrusted(self: *Object, rt: *JSRuntime, values: []const JSValue) !void {
        std.debug.assert(self.isArray() and self.flags.length_writable and self.flags.extensible);
        std.debug.assert(self.arrayArm().*.count == 0 and self.arrayArm().*.length == 0);
        std.debug.assert(self.shape_ref.prop_count == 0);
        std.debug.assert(self.arrayElementStorageMode() == .dense);
        std.debug.assert(values.len <= array.max_array_length);
        if (values.len == 0) return;
        try self.ensureArrayElementCapacity(rt, values.len);
        self.setFastArrayCountAssumeCapacity(@intCast(values.len));
        self.arrayArm().*.length = @intCast(values.len);
        if (comptime builtin.is_test) {
            auditWrite(.memcpy_bulk, .object_dense_memcpy);
            @memcpy(self.arrayArm().*.values[0..values.len], values);
        } else {
            @memcpy(self.arrayArm().*.values[0..values.len], values);
        }
        self.markIndexedProperties(rt);
    }

    pub fn appendDenseArrayInt32Range(self: *Object, rt: *JSRuntime, start: u32, limit: u32) !bool {
        if (!self.isArray() or self.hasExoticMethods() or self.arrayElementStorageMode() != .dense) return false;
        if (start != self.arrayArm().*.count or start >= limit or !self.flags.length_writable or !self.flags.extensible) return false;
        if (self.getPrototype()) |proto| {
            if (!arrayPrototypeChainAllowsBulkIndexedSet(proto)) return false;
        }

        const start_index: usize = @intCast(start);
        const limit_index: usize = @intCast(limit);

        try self.ensureArrayElementCapacity(rt, limit_index);
        self.setFastArrayCountAssumeCapacity(limit);
        if (limit > self.arrayArm().*.length) self.arrayArm().*.length = limit;
        self.markIndexedProperties(rt);

        var index = start_index;
        if (comptime builtin.is_test) {
            auditWrite(.fam_slice, .object_dense_store);
            while (index < limit_index) : (index += 1) {
                self.arrayArm().*.values[index] = JSValue.int32(@intCast(index));
            }
        } else {
            while (index < limit_index) : (index += 1) {
                self.arrayArm().*.values[index] = JSValue.int32(@intCast(index));
            }
        }
        return true;
    }

    pub fn appendDenseArrayInt32ValueRange(self: *Object, rt: *JSRuntime, start_index: u32, start_value: i32, count: u32) !bool {
        if (count == 0) return true;
        if (!self.isArray() or self.hasExoticMethods() or self.arrayElementStorageMode() != .dense) return false;
        if (start_index != self.arrayArm().*.count or !self.flags.length_writable or !self.flags.extensible) return false;
        if (self.getPrototype()) |proto| {
            if (!arrayPrototypeChainAllowsBulkIndexedSet(proto)) return false;
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
        if (limit > self.arrayArm().*.length) self.arrayArm().*.length = limit;
        self.markIndexedProperties(rt);

        var offset: u32 = 0;
        if (comptime builtin.is_test) {
            auditWrite(.fam_slice, .object_dense_store);
            while (offset < count) : (offset += 1) {
                const index = start_element + @as(usize, @intCast(offset));
                const element_delta: i32 = @intCast(offset);
                const element_value = start_value + element_delta;
                self.arrayArm().*.values[index] = JSValue.int32(element_value);
            }
        } else {
            while (offset < count) : (offset += 1) {
                const index = start_element + @as(usize, @intCast(offset));
                const element_delta: i32 = @intCast(offset);
                const element_value = start_value + element_delta;
                self.arrayArm().*.values[index] = JSValue.int32(element_value);
            }
        }
        return true;
    }

    pub fn appendDenseArrayInt32MulAndMaskRange(self: *Object, rt: *JSRuntime, start_index: u32, limit: u32, multiplier: i32, mask: i32) !bool {
        if (start_index >= limit) return true;
        if (multiplier < 0 or mask < 0) return false;
        if (!self.isArray() or self.hasExoticMethods() or self.arrayElementStorageMode() != .dense) return false;
        if (start_index != self.arrayArm().*.count or !self.flags.length_writable or !self.flags.extensible) return false;
        if (self.getPrototype()) |proto| {
            if (!arrayPrototypeChainAllowsBulkIndexedSet(proto)) return false;
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
        if (limit > self.arrayArm().*.length) self.arrayArm().*.length = limit;
        self.markIndexedProperties(rt);

        var index = start_element;
        if (comptime builtin.is_test) {
            auditWrite(.fam_slice, .object_dense_store);
            while (index < limit_element) : (index += 1) {
                const product_exact = @as(i128, @intCast(index)) * @as(i128, multiplier);
                const product: i32 = @truncate(product_exact);
                const element_value = product & mask;
                self.arrayArm().*.values[index] = JSValue.int32(element_value);
            }
        } else {
            while (index < limit_element) : (index += 1) {
                const product_exact = @as(i128, @intCast(index)) * @as(i128, multiplier);
                const product: i32 = @truncate(product_exact);
                const element_value = product & mask;
                self.arrayArm().*.values[index] = JSValue.int32(element_value);
            }
        }
        return true;
    }

    pub fn overwriteDenseArrayInt32MaskedIndexRange(self: *Object, rt: *JSRuntime, start: u32, limit: u32, mask: u32) !bool {
        if (start >= limit) return true;
        if (limit > @as(u32, @intCast(std.math.maxInt(i32)))) return false;
        if (mask > atom.max_int_atom) return false;
        if (!self.isArray() or !self.flags.length_writable) return false;
        if (self.hasExoticMethods() or self.arrayElementStorageMode() != .dense) return false;

        const mask_index: usize = @intCast(mask);
        if (mask_index >= self.arrayArm().*.count) return false;

        var guard_index: u32 = 0;
        while (guard_index <= mask) : (guard_index += 1) {
            const atom_id = atom.atomFromUInt32(guard_index);
            if (self.shape_ref.prop_count != 0 and self.findProperty(atom_id) != null) return false;
            if (guard_index == std.math.maxInt(u32)) break;
        }

        var value_index = start;
        if (comptime builtin.is_test) {
            auditWrite(.fam_slice, .object_dense_store);
            while (value_index < limit) : (value_index += 1) {
                const element_index: usize = @intCast(value_index & mask);
                const element_slot = &self.arrayArm().*.values[element_index];
                const old = element_slot.*;
                const new_value = JSValue.int32(@intCast(value_index));
                element_slot.* = new_value;
                old.free(rt);
            }
        } else {
            while (value_index < limit) : (value_index += 1) {
                const element_index: usize = @intCast(value_index & mask);
                const element_slot = &self.arrayArm().*.values[element_index];
                const old = element_slot.*;
                const new_value = JSValue.int32(@intCast(value_index));
                element_slot.* = new_value;
                old.free(rt);
            }
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
        if (element_index > self.arrayArm().*.count) return false;
        const appended = element_index == self.arrayArm().*.count;
        if (appended) {
            if (!self.flags.extensible) return false;
            if (index >= self.arrayLength() and !self.flags.length_writable) return false;
            // Dense append stays on the fully-dense end (index == count == length);
            // a holey array (count < length) falls through to the caller's slow
            // path. This preserves the qjs add_fast_array_element invariant.
            if (index != self.arrayLength()) return false;
            try self.ensureArrayElementCapacity(rt, element_index + 1);
            self.setFastArrayCountAssumeCapacity(index + 1);
            if (index + 1 > self.arrayArm().*.length) self.arrayArm().*.length = index + 1;
        }

        const next_value = new_value.dup();
        errdefer next_value.free(rt);
        const element_slot = &self.arrayArm().*.values[element_index];
        const old = if (appended) JSValue.undefinedValue() else element_slot.*;
        if (comptime builtin.is_test) {
            auditWrite(.fam_slice, .object_dense_store);
            element_slot.* = next_value;
        } else {
            element_slot.* = next_value;
        }
        // These helpers write the dense slot themselves, reaching storage
        // through `ensureArrayElementCapacity` rather than the remembering
        // `appendUninitializedFastArraySlot`, so they inherit no barrier.
        // `[].map(f)` filling a result array that has already gone old is
        // exactly the old-to-young edge the minor's sticky marks stop at.
        rt.gc.generationalBarrier(&self.header, next_value.cycleMarkHeader());
        self.markIndexedProperties(rt);
        if (!appended) old.free(rt);
        return true;
    }

    pub fn markIndexedProperties(self: *Object, _: *JSRuntime) void {
        // This is the local conservative lookup summary, not the realm guard
        // invalidation hook. QuickJS invalidates `is_std_array_prototype` in
        // `add_property` only for tagged integer atoms (0...INT32_MAX), while
        // this flag also covers the wider ArrayIndex string-atom range.
        self.flags.may_have_indexed_properties = true;
    }

    fn invalidateStandardArrayPrototypeForTaggedIndexMutation(self: *Object, rt: *JSRuntime) void {
        if (self.flags.is_std_array_prototype) {
            self.flags.is_std_array_prototype = false;
        } else if (self.flags.immutable_prototype) {
            rt.invalidateStandardArrayPrototypeForObjectPrototype(self);
        }
    }

    pub fn publishStandardArrayPrototype(self: *Object) void {
        std.debug.assert(self.isArray());
        std.debug.assert(!self.flags.may_have_indexed_properties);
        self.flags.is_std_array_prototype = true;
    }

    pub fn isStandardArrayPrototype(self: *const Object) bool {
        return self.flags.is_std_array_prototype;
    }

    /// Conservative proof for zjs-only bulk Set optimizations. Unlike qjs's
    /// four `can_extend_fast_array` readers, these transforms may skip many
    /// distinct Set operations and therefore inspect the actual chain.
    fn arrayPrototypeChainAllowsBulkIndexedSet(proto: *Object) bool {
        var cursor: ?*Object = proto;
        while (cursor) |object| {
            if (object.proxyTarget() != null or object.hasExoticMethods()) return false;
            if (object.flags.may_have_indexed_properties) return false;
            cursor = object.getPrototype();
        }
        return true;
    }

    pub fn canDefineDenseArrayDataPropertiesUnchecked(self: *const Object) bool {
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
        if (element_index > self.arrayArm().*.count) return;
        const appended = element_index == self.arrayArm().*.count;
        if (appended) {
            try self.ensureArrayElementCapacity(rt, element_index + 1);
            self.setFastArrayCountAssumeCapacity(index + 1);
            if (index + 1 > self.arrayArm().*.length) self.arrayArm().*.length = index + 1;
        }

        const next_value = new_value.dup();
        errdefer next_value.free(rt);
        const element_slot = &self.arrayArm().*.values[element_index];
        const old = if (appended) JSValue.undefinedValue() else element_slot.*;
        if (comptime builtin.is_test) {
            auditWrite(.fam_slice, .object_dense_store);
            element_slot.* = next_value;
        } else {
            element_slot.* = next_value;
        }
        // These helpers write the dense slot themselves, reaching storage
        // through `ensureArrayElementCapacity` rather than the remembering
        // `appendUninitializedFastArraySlot`, so they inherit no barrier.
        // `[].map(f)` filling a result array that has already gone old is
        // exactly the old-to-young edge the minor's sticky marks stop at.
        rt.gc.generationalBarrier(&self.header, next_value.cycleMarkHeader());
        self.markIndexedProperties(rt);
        if (!appended) old.free(rt);
    }

    // ===== set* properties =====
    pub fn setProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, new_value: JSValue) !void {
        if (self.class_id == class.ids.module_ns) return error.ReadOnly;
        if (self.isArray() and atom_id == atom.ids.length) {
            if (!self.flags.length_writable) return error.ReadOnly;
            // Fast path: fast_array length assignment mirrors qjs set_array_length
            // (quickjs.c:9447-9455). A fast array's elements live in u.array.values,
            // NOT in the shape property table, so the generic defineArrayLength
            // path does two full shape-prop scans (the shrink loop + recomputeArrayStorageMode)
            // that touch zero relevant entries. This fast path does only:
            //   1. arrayLengthFromValue (number→uint32, no side effects on pre-coerced values)
            //   2. truncateArrayElements (free tail values on shrink)
            //   3. set u.array.length
            // Non-fast arrays, invalid lengths, and side-effecting coercions fall
            // through to defineArrayLength unchanged.
            if (self.flags.fast_array) {
                if (try arrayLengthFromValue(rt, new_value)) |len| {
                    self.truncateArrayElements(rt, len);
                    self.arrayArm().*.length = len;
                    return;
                }
                return error.InvalidLength;
            }
            try self.defineArrayLength(rt, descriptor.Descriptor.data(new_value, true, false, false));
            return;
        }
        if (self.findProperty(atom_id)) |index| {
            // Accessor (or accessor-destined placeholder): materialize so the
            // real getter/setter exist, then route to the setter.
            if (self.isAccessorOrAccessorPlaceholderAt(index)) {
                try self.materializeAutoInitEntryForMutation(index);
                const entry = self.propertyEntry(index);
                if (entry.slot.accessor.setterIsUndefined()) return error.AccessorWithoutSetter;
                return;
            }
            const entry_flags = self.propFlagsAt(index);
            if (!entry_flags.writable) return error.ReadOnly;
            const entry = self.propertyEntry(index);
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
                if (comptime builtin.is_test) {
                    auditWrite(.union_arm, .object_prop_slot);
                    entry.slot = .{ .data = next_value };
                } else {
                    entry.slot = .{ .data = next_value };
                }
                destroyPropertySlot(rt, atom_id, entry_flags, old_slot);
            } else {
                // auto_init data placeholder: needs the shape kind flip.
                try self.ensureUniqueShapeForMutation(rt);
                self.setEntryKindAndSlot(rt, atom_id, index, entry_flags.withKind(.data), .{ .data = next_value });
            }
            self.pruneBorrowedReferenceHolderIfEmpty(rt);
            return;
        }
        // Hoisted fast_array gate (setDenseArrayElement's own first check):
        // only a dense-element receiver can consume the index, so a plain
        // object's named set skips the out-of-line arrayIndexFromAtom probe
        // entirely (qjs asks the index question only inside its fast_array
        // arms, quickjs.c:9741-9750, 9868-9877).
        if (self.flags.fast_array) {
            if (array.arrayIndexFromAtom(&rt.atoms, atom_id)) |index| {
                if (try self.setDenseArrayElement(rt, index, new_value)) return;
            }
        }
        var prototype = self.getPrototype();
        while (prototype) |proto| {
            if (proto.findProperty(atom_id)) |index| {
                const is_accessor = proto.isAccessorOrAccessorPlaceholderAt(index);
                if (is_accessor) {
                    try proto.materializeAutoInitEntryForMutation(index);
                    const inherited = proto.propertyEntry(index).*;
                    if (inherited.slot.accessor.setterIsUndefined()) return error.AccessorWithoutSetter;
                } else if (!proto.propFlagsAt(index).writable) {
                    return error.ReadOnly;
                }
                // qjs JS_SetPropertyInternal retry2 (quickjs.c:9839-9853):
                // first own hit on the proto chain stops the walk. A closer
                // writable data property shadows a farther readonly / no-setter
                // descriptor; continuing would incorrectly honor the far one.
                break;
            }
            prototype = proto.getPrototype();
        }

        try self.defineOwnDataPropertyForSetKnownNoOwn(rt, atom_id, new_value);
    }

    pub fn setOwnWritableDataProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, new_value: JSValue) !bool {
        if (self.class_id == class.ids.module_ns) return false;
        // QJS's JS_SetPropertyInternal consumes the shape flags and matching
        // value cell returned by one `find_own_property` probe. Keep that pair
        // together here as well; the old path re-ran defensive/indexed shape
        // reads after the successful hash lookup.
        const lookup = self.findPropertyProbeTrusted(atom_id) orelse return false;
        const index = lookup.index;
        const entry_flags = property.Flags.fromBits(lookup.prop.flags);
        if (entry_flags.deleted or !entry_flags.writable) return false;
        const entry = self.propertyEntry(index);

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
            if (comptime builtin.is_test) {
                auditWrite(.union_arm, .object_prop_slot);
                stored.* = new_value;
            } else {
                stored.* = new_value;
            }
            return true;
        }
        const next_value = dupPropertyDataValue(&rt.atoms, atom_id, new_value);
        errdefer next_value.free(rt);
        const old_slot = entry.slot;
        if (comptime builtin.is_test) {
            auditWrite(.union_arm, .object_prop_slot);
            entry.slot = .{ .data = next_value };
        } else {
            entry.slot = .{ .data = next_value };
        }
        // Replacing a property value on a long-lived object is an
        // old-to-young edge; the non-refcounted fast arms above store
        // primitives and need none.
        rt.gc.generationalBarrier(&self.header, next_value.cycleMarkHeader());
        destroyPropertySlot(rt, atom_id, entry_flags, old_slot);
        self.pruneBorrowedReferenceHolderIfEmpty(rt);
        return true;
    }

    pub inline fn setOwnDataPropertyAtForLexicalSyncOwned(self: *Object, rt: *JSRuntime, index: usize, atom_id: atom.Atom, new_value: JSValue) !bool {
        if (self.hasExoticMethods() or index >= self.shapeProps().len) return false;
        const prop = self.shape_ref.props()[index];
        const prop_flags = property.Flags.fromBits(prop.flags);
        if (prop.atom_id != atom_id or prop_flags.deleted or prop_flags.kind != .data) return false;
        const entry = self.propertyEntry(index);
        const stored = &entry.slot.data;
        if (!prop_flags.writable and !stored.isUninitialized()) return false;
        if (atom_id == atom.ids.Private_brand) return false;
        const old = stored.*;
        stored.* = new_value;
        rt.gc.generationalBarrier(&self.header, new_value.cycleMarkHeader());
        old.free(rt);
        return true;
    }

    pub fn setOrDefineOwnDataPropertyForSimpleSet(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, new_value: JSValue) !bool {
        // Generational barrier at the property funnels (§8.3). These carry
        // both owner and child, which the raw slot stores below do not, so
        // this is where an old-to-young edge can still be recorded without
        // rewriting every prop_values write. The remaining direct and memcpy
        // stores belong to §6.4's snapshot domain.
        rt.gc.generationalBarrier(&self.header, new_value.cycleMarkHeader());
        if (self.class_id == class.ids.module_ns) return false;
        if (self.findProperty(atom_id)) |index| {
            const entry_flags = self.propFlagsAt(index);
            if (self.isAccessorOrAccessorPlaceholderAt(index)) return false;
            if (entry_flags.deleted or !entry_flags.writable) return false;
            const entry = self.propertyEntry(index);
            if (atom_id != atom.ids.Private_brand) {
                switch (entry_flags.kind) {
                    .data => {
                        const stored = &entry.slot.data;
                        if (!stored.requiresRefCount() and !new_value.requiresRefCount()) {
                            if (comptime builtin.is_test) {
                                auditWrite(.union_arm, .object_prop_slot);
                                stored.* = new_value;
                            } else {
                                stored.* = new_value;
                            }
                            return true;
                        }
                    },
                    // VARREF: write THROUGH the cell (never overwrite the
                    // slot), mirroring setOwnWritableDataProperty and qjs
                    // JS_SetPropertyInternal's JS_PROP_VARREF set_value leg
                    // (quickjs.c:9720-9726). Needed since the merged caller
                    // (setValuePropertyWithThrow) replaced its leading
                    // setOwnWritableDataProperty probe with this one.
                    .var_ref => {
                        const cell = entry.slot.var_ref;
                        const next_value = dupPropertyDataValue(&rt.atoms, atom_id, new_value);
                        errdefer next_value.free(rt);
                        cell.setVarRefValue(rt, next_value);
                        return true;
                    },
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
            if (comptime builtin.is_test) {
                auditWrite(.union_arm, .object_prop_slot);
                entry.slot = .{ .data = next_value };
            } else {
                entry.slot = .{ .data = next_value };
            }
            rt.gc.generationalBarrier(&self.header, next_value.cycleMarkHeader());
            destroyPropertySlot(rt, atom_id, entry_flags, old_slot);
            self.pruneBorrowedReferenceHolderIfEmpty(rt);
            return true;
        }
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
        // Index-form atoms: the tagged-int bit test runs for every class (a
        // folded `o['5'] = x` computed key reaches the set path with a
        // tagged-int atom), but only dense-storage-capable classes pay the
        // out-of-line string-leg probe — an ordinary object's add never asks
        // (qjs add_property, quickjs.c:9884-9890; the index question lives in
        // the fast_array arm's __JS_AtomIsTaggedInt, quickjs.c:9868-9877).
        if (atom.isTaggedInt(atom_id)) return false;
        if (classOwnsIndexedElementStorage(self.class_id) and
            array.arrayIndexFromAtom(&rt.atoms, atom_id) != null) return false;

        var prototype = self.getPrototype();
        while (prototype) |proto| {
            if (proto.hasExoticMethods() or proto.proxyTarget() != null) return false;
            if (isTypedArrayObjectForSetFastPath(proto)) return false;
            if (proto.findProperty(atom_id)) |proto_index| {
                // qjs JS_SetPropertyInternal's prototype loop (quickjs.c:9840-
                // 9853) stops at the FIRST prototype that owns the key and reads
                // `prs->flags` straight off the shape. A GETSET accessor takes
                // the setter path, an AUTOINIT/VARREF entry needs
                // materialization, and a non-writable data entry is read-only --
                // all of those must defer to the full resolver. A plain WRITABLE
                // DATA property does NOT shadow the create: qjs `break`s and
                // `add_property`s an own C_W_E data property on the receiver
                // (quickjs.c:9852, 9884). Mirror that here so the ubiquitous
                // "assign an instance field whose prototype declares a default"
                // pattern (raytrace `this.x = ...`, `result.red = ...`) creates
                // the own slot directly instead of falling through to
                // `callAccessorSetter`, whose `findPropertyDescriptor` ->
                // `getOwnProperty` rebuilds an allocating Descriptor up the same
                // chain only to discover the entry is data, not an accessor.
                const proto_flags = proto.propFlagsAt(proto_index);
                if (proto_flags.deleted or proto_flags.kind != .data or !proto_flags.writable) return false;
                break;
            }
            prototype = proto.getPrototype();
        }

        try self.addProperty(rt, atom_id, descriptor.Descriptor.data(new_value, true, true, true));
        return true;
    }

    /// Result of `setOrDefineOwnDataPropertyForPutFieldOwned`. Not an error
    /// union: `.slow` is a decline (no mutation, caller keeps `new_value`).
    /// Auto-init clone / new-property append OOM also returns `.slow` so the
    /// still-`!T` `setValueProperty` resolver stays the OOM channel.
    pub const PutFieldFast = enum { done, slow };

    /// qjs JS_SetPropertyInternal's single-walk core (quickjs.c:9706-9890) for
    /// the put_field cold shell: ONE trusted own probe that classifies the hit
    /// (plain writable data / var_ref / auto_init handled here; accessor and
    /// read-only hits defer), ONE prototype walk that `break`s at the first
    /// plain writable data holder (quickjs.c:9840-9853), then add_property
    /// with C_W_E flags straight into the slot (quickjs.c:9884-9890) — no
    /// Descriptor materialization and no re-probing. The old cold cascade
    /// re-ran an equivalent admission gate set and own probe up to four times
    /// per new-property write (setObjectDataPropertyForPutFieldFastPath ->
    /// setValuePropertyWithThrow -> setOwnWritableDataProperty ->
    /// defineNewOwnDataPropertyForSimpleSet).
    ///
    /// Returns `.done` when the write was fully performed; `.slow` defers to
    /// the full setValueProperty resolver with NO state mutated. OWNED value
    /// contract: `new_value` is consumed on `.done` and left with the caller
    /// on `.slow`. Allocation failure on the auto_init / append legs rolls
    /// the object back and returns `.slow` (no consume) so the resolver can
    /// still surface `error.OutOfMemory`.
    ///
    /// Deliberate defers that pin the resolver's semantic order:
    /// - with-environment receivers: the strict-miss ReferenceError door in
    ///   setValuePropertyWithThrow must stay ahead of any own probe;
    /// - mapped-arguments receivers (via needsSlowPropertyAccess): both the
    ///   own-hit setMappedArgumentsValue hook and the new-property
    ///   updateMappedArgumentsBinding hook live in the resolver;
    /// - accessor/read-only hits anywhere on the chain: setter invocation and
    ///   throw_on_set_failure polarity need the caller frame;
    /// - exotic proto miss after find: TA canonical-index / oob and
    ///   set_property / get_own_property traps stay in the resolver (SPI
    ///   2f80c). Named miss on a fast_array proto falls through like qjs.
    /// - a global receiver may take the own-hit write but never the add — qjs
    ///   likewise routes JS_CLASS_GLOBAL_OBJECT to generic_create_prop
    ///   (quickjs.c:9882-9883);
    /// - the extensible check sits AFTER the prototype walk (qjs order,
    ///   quickjs.c:9862-9865): a non-extensible receiver whose chain holds a
    ///   setter must reach that setter, never a synthesized failure.
    pub fn setOrDefineOwnDataPropertyForPutFieldOwned(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, new_value: JSValue) align(16) PutFieldFast {
        // Generational barrier at the property funnels (§8.3). These carry
        // both owner and child, which the raw slot stores below do not, so
        // this is where an old-to-young edge can still be recorded without
        // rewriting every prop_values write. The remaining direct and memcpy
        // stores belong to §6.4's snapshot domain.
        rt.gc.generationalBarrier(&self.header, new_value.cycleMarkHeader());
        // Admission runs ONCE: needsSlowPropertyAccess covers the exotic bit
        // plus the array/typed-array/dataview/mapped-arguments/module_ns/proxy
        // classes, whose set semantics (length, canonical numeric indices,
        // binding mirrors, traps) all live in the resolver.
        if (self.needsSlowPropertyAccess()) return .slow;
        if (self.proxyTarget() != null) return .slow;
        if (self.flags.is_with_environment) return .slow;

        if (self.findPropertyProbeTrusted(atom_id)) |lookup| {
            const entry_flags = property.Flags.fromBits(lookup.prop.flags);
            if (entry_flags.deleted or !entry_flags.writable) return .slow;
            const entry = self.propertyEntry(lookup.index);
            switch (entry_flags.kind) {
                // qjs's single-mask fast case (quickjs.c:9708-9713): swap the
                // slot, free the old value. The owned store consumes new_value.
                .data => {
                    const old_slot = entry.slot;
                    if (comptime builtin.is_test) {
                        auditWrite(.union_arm, .object_prop_slot);
                        entry.slot = .{ .data = new_value };
                    } else {
                        entry.slot = .{ .data = new_value };
                    }
                    destroyPropertySlot(rt, atom_id, entry_flags, old_slot);
                    return .done;
                },
                // JS_PROP_VARREF: set_value through the cell
                // (quickjs.c:9720-9726); module_ns cells were excluded by the
                // class gate and const cells carry writable == false.
                .var_ref => {
                    entry.slot.var_ref.setVarRefValue(rt, new_value);
                    return .done;
                },
                // Data-destined AUTOINIT (quickjs.c:9727-9733 instantiates and
                // retries; the retry lands in the fast case): discard the lazy
                // default and flip the kind in lockstep. Auto-init entries are
                // always data-destined (native accessors install eagerly, see
                // isAccessorOrAccessorPlaceholderAt); non-writable placeholders
                // were deferred above.
                .auto_init => {
                    // Shape-clone OOM: leave new_value with the caller and
                    // decline so setValueProperty (still `!T`) is the OOM
                    // channel. The object is unchanged.
                    self.ensureUniqueShapeForMutation(rt) catch return .slow;
                    self.setEntryKindAndSlot(rt, atom_id, lookup.index, entry_flags.withKind(.data), .{ .data = new_value });
                    self.pruneBorrowedReferenceHolderIfEmpty(rt);
                    return .done;
                },
                .accessor => return .slow,
            }
        }

        // Own miss: new-property leg. Index-form atoms keep the resolver's
        // element/length machinery — a folded computed key (`o['5'] = x`) can
        // still reach put_field with a tagged-int atom. Ordinary classes pay
        // only the bit test; the string-leg probe (>= 10-digit index names)
        // runs for dense-storage-capable classes alone, mirroring qjs's
        // fast_array-arm-only __JS_AtomIsTaggedInt (quickjs.c:9868-9877)
        // against the probe-free ordinary add (quickjs.c:9884-9890).
        if (atom.isTaggedInt(atom_id)) return .slow;
        if (classOwnsIndexedElementStorage(self.class_id) and
            array.arrayIndexFromAtom(&rt.atoms, atom_id) != null) return .slow;
        if (self.isGlobal()) return .slow;

        // qjs prototype walk (quickjs.c:9739-9854 / SPI 2f8ec-2f9f8):
        // find_own first, then is_exotic. Empty/end is tested locally as
        // `idx ^ u26max` (lowers to hoisted-sentinel `cmp` / `cbz`-class
        // flag test). The stored 0-based / no_property_index ABI is
        // untouched. Non-exotic protos do not pay typed/proxy cmps.
        // Exotic miss follows SPI control-flow (named fast_array
        // fallthrough; TA / trap classes decline) — not an unconditional
        // `.slow` before find.
        var prototype = self.getPrototype();
        var proto_writable_data = false;
        const empty_bucket: u32 = comptime @as(u32, shape.no_property_index);
        while (prototype) |proto| {
            const props = proto.shape_ref.props().ptr;
            var idx: u32 = proto.shape_ref.firstPropertyIndex(atom_id);
            // Local empty test: `idx ^ u26max == 0`. LLVM hoists the
            // sentinel and `cmp`s (cbz-class flag test). ABI untouched.
            while (idx ^ empty_bucket != 0) {
                const prop = props[idx];
                if (prop.atom_id == atom_id) {
                    const proto_flags = property.Flags.fromBits(prop.flags);
                    if (proto_flags.deleted or proto_flags.kind != .data or !proto_flags.writable)
                        return .slow;
                    proto_writable_data = true;
                    break;
                }
                idx = prop.hash_next;
            }
            if (proto_writable_data) break;
            // find miss → SPI 2f80c `ldrh is_exotic`. Ordinary proto: next.
            if (proto.flags.has_exotic_methods) {
                // fast_array + non-TA named miss: qjs falls through (atom
                // already rejected tagged-int). TA canonical-index / oob
                // and non-fast_array traps stay in the resolver.
                if (!proto.flags.fast_array or isTypedArrayObjectForSetFastPath(proto))
                    return .slow;
            }
            // Proxy is not `has_exotic_methods` (traps live in the class
            // switch, not the exotic-methods table). Skipping it here
            // created an own data slot and never ran [[Set]].
            if (proto.isProxy()) return .slow;
            prototype = proto.getPrototype();
        }

        // Extensibility AFTER the walk (quickjs.c:9862-9865, see doc note).
        if (!self.flags.extensible) return .slow;

        // add_property(C_W_E) + direct slot store (quickjs.c:9884-9890).
        // `slot_borrowed_until_commit`: on append OOM the staged value is
        // un-staged without destroy, so `.slow` can leave ownership with the
        // caller and the resolver remains the OOM channel. Success MOVEs the
        // caller's ref into the committed slot (same consume-on-success
        // contract as the previous owned-slot append). Both callers decode
        // `atom_id` from the active immutable bytecode's OP_put_field
        // operand, whose FunctionBytecode owns the atom across this
        // allocation/GC window. qjs add_property relies on that same operand
        // root and retains only the Shape's reference.
        //
        // `named_put_no_index`: tagged-int and indexed-class array-index
        // atoms already returned `.slow` above. qjs's ordinary add_property
        // (9884-9890) has no JS_AtomIsArrayIndex; a `bl atomIsArrayIndex`
        // here was TS ~144M on identifier keys.
        self.appendPreparedPropertyEntryImpl(
            true,
            true,
            true,
            rt,
            atom_id,
            comptime property.Flags.data(true, true, true),
            .{ .data = new_value },
        ) catch return .slow;
        return .done;
    }

    fn defineModuleNamespaceProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: descriptor.Descriptor) !bool {
        if (self.class_id != class.ids.module_ns) return false;
        const index = self.findProperty(atom_id) orelse return false;
        var flags = self.propFlagsAt(index);
        if (!self.isModuleNamespaceExportProperty(flags)) return false;

        // Namespace [[DefineOwnProperty]] first obtains the current descriptor.
        // QuickJS therefore instantiates an AUTOINIT export before validating
        // `desc`; a materialization failure remains the observable result.
        if (flags.kind == .auto_init) {
            const transient = try self.materializeAutoInit(index);
            transient.free(rt);
            flags = self.propFlagsAt(index);
            if (!self.isModuleNamespaceExportProperty(flags)) return error.IncompatibleDescriptor;
        }

        const current = try self.descriptorFromOwnPropertySlot(index);
        defer current.destroy(rt);

        if (desc.kind == .accessor) return error.IncompatibleDescriptor;
        if (desc.configurable orelse false) return error.IncompatibleDescriptor;
        if (desc.enumerable) |enumerable| {
            if (!enumerable) return error.IncompatibleDescriptor;
        }
        if (desc.writable) |writable| {
            if (!writable) return error.IncompatibleDescriptor;
        }
        if (desc.value_present and !current.value.sameValue(desc.value)) return error.ReadOnly;
        return true;
    }

    fn deleteOrdinaryPropertyAt(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, index: usize) bool {
        const old_flags = self.propFlagsAt(index);
        if (!old_flags.configurable) return false;
        rt.shapes.prepareUpdate(&self.shape_ref) catch return false;
        // Every write to `shape_ref` is an owner adopting a Shape: the clone or
        // relocation this call may perform produces a fresh, young one, and a
        // long-lived owner reaching it is an old-to-young edge the minor's
        // sticky marks would otherwise stop short of.
        rt.gc.generationalBarrier(&self.header, &self.shape_ref.header);
        const entry = self.propertyEntry(index);
        const old_slot = entry.slot;
        // `deleted` is a flag bit, not a kind/arm: keep a harmless data cell.
        if (comptime builtin.is_test) {
            auditWrite(.union_arm, .object_prop_slot);
            entry.slot = .{ .data = JSValue.undefinedValue() };
        } else {
            entry.slot = .{ .data = JSValue.undefinedValue() };
        }
        const deleted_flags = old_flags.asDeleted();
        rt.shapes.markPropertyDeleted(self.shape_ref, index, deleted_flags.bits());
        self.syncTraceShapePropertyFlags(index, deleted_flags);
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
        const object_shape = self.shape_ref;
        if (object_shape.deletedPropCount() >= 8 and
            object_shape.deletedPropCount() >= object_shape.prop_count / 2)
        {
            // qjs ignores compact_properties OOM after the deletion is already
            // committed; retaining tombstones is a valid fallback.
            rt.shapes.compactProperties(self) catch {};
        }
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
                // the element's zero-ref callback through the outer FIFO drain,
                // after the sparse-property mutation is fully published. The
                // cheap inline tail-hole would re-enter before that boundary.
                self.convertDenseArrayElementsToSparseProperties(rt) catch return false;
                const index = self.findProperty(atom_id) orelse return true;
                return self.deleteOrdinaryPropertyAt(rt, atom_id, index);
            }
        }

        return true;
    }

    pub fn ownKeys(self: *const Object, rt: *JSRuntime) OwnKeysError![]atom.Atom {
        if (self.exoticMethods(rt)) |methods| {
            if (methods.own_keys) |hook| return try hook(@constCast(self), rt);
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
            std.sort.heap(IndexKey, index_keys.items, {}, indexKeyLessThan);
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
        if (self.flags.fast_array and self.arrayArm().*.count != 0) {
            try self.convertDenseArrayElementsToSparseProperties(rt);
        }
        try self.materializeAllMappedArgumentsProperties(rt);
        self.flags.extensible = false;
        try self.ensureUniqueShapeForMutation(rt);
        for (0..self.shape_ref.prop_count) |index| {
            var entry_flags = self.propFlagsAt(index);
            if (entry_flags.deleted or !entry_flags.configurable) continue;
            entry_flags.configurable = false;
            self.updateShapePropertyFlags(rt, index, entry_flags);
        }
    }

    pub fn freeze(self: *Object, rt: *JSRuntime) !void {
        try self.seal(rt);
        if (self.class_id == class.ids.module_ns) {
            for (0..self.shape_ref.prop_count) |index| {
                if (self.isModuleNamespaceExportProperty(self.propFlagsAt(index))) {
                    // Module namespace descriptors report writable=true, but
                    // their exotic DefineOwnProperty rejects making it false.
                    return error.IncompatibleDescriptor;
                }
            }
        }
        self.detachAllMappedArgumentsBindings(rt);
        for (0..self.shape_ref.prop_count) |index| {
            var entry_flags = self.propFlagsAt(index);
            if (entry_flags.deleted or entry_flags.isAccessor() or !entry_flags.writable) continue;
            entry_flags.writable = false;
            self.updateShapePropertyFlags(rt, index, entry_flags);
        }
        if (self.isArray()) self.flags.length_writable = false;
    }

    fn defineOrdinaryOwnProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void {
        if (self.findProperty(atom_id)) |index| {
            try self.materializeAutoInitEntryForMutation(index);
            if (!isCompatible(self.propFlagsAt(index), self.propertyEntry(index).*.slot, desc)) return error.IncompatibleDescriptor;
            try self.replaceProperty(rt, index, desc);
            return;
        }

        if (self.class_id == class.ids.mapped_arguments) {
            try self.materializeMappedArgumentsProperty(rt, atom_id);
            if (self.findProperty(atom_id)) |index| {
                try self.materializeAutoInitEntryForMutation(index);
                if (!isCompatible(self.propFlagsAt(index), self.propertyEntry(index).*.slot, desc)) return error.IncompatibleDescriptor;
                try self.replaceProperty(rt, index, desc);
                return;
            }
        }
        if (classOwnsIndexedElementStorage(self.class_id)) {
            if (array.arrayIndexFromAtom(&rt.atoms, atom_id)) |array_index| {
                const element_index: usize = @intCast(array_index);
                if (element_index < self.arrayElements().len) {
                    try self.convertDenseArrayElementsToSparseProperties(rt);
                    const index = self.findProperty(atom_id) orelse unreachable;
                    try self.materializeAutoInitEntryForMutation(index);
                    if (!isCompatible(self.propFlagsAt(index), self.propertyEntry(index).*.slot, desc)) return error.IncompatibleDescriptor;
                    try self.replaceProperty(rt, index, desc);
                    return;
                }
            }
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
        // qjs set_array_length never re-densifies: a non-fast array stays
        // non-fast after a length change. The retired recomputeArrayStorageMode
        // was a zjs-specific O(prop_count) shape scan on every length
        // assignment that tried to re-densify arrays whose indexed shape props
        // were all deleted by the shrink loop — but that scan dominated
        // pdfjs's `arr.length = n` hot path (16+ samples self-time). qjs pays
        // zero here; matching it keeps semantics identical (the shrink loop
        // above already handles non-configurable prop fallback).
        if (desc.writable) |writable| self.flags.length_writable = writable;
    }

    pub fn truncateArrayElements(self: *Object, rt: *JSRuntime, new_len: u32) void {
        if (!self.isArray() or !self.flags.fast_array) return;
        const len: usize = @min(@as(usize, @intCast(new_len)), self.arrayArm().*.count);
        while (self.arrayArm().*.count > len) {
            self.arrayArm().*.count -= 1;
            const old = self.arrayArm().*.values[@intCast(self.arrayArm().*.count)];
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
        const saved_length = self.arrayArm().*.length;
        const elements = self.arrayElements();
        for (elements, 0..) |stored, index| {
            const atom_id = atom.atomFromUInt32(@intCast(index));
            if (self.findProperty(atom_id) != null) continue;
            try self.addProperty(rt, atom_id, descriptor.Descriptor.data(stored, true, true, true));
        }
        for (elements) |stored| stored.free(rt);
        self.arrayArm().*.count = 0;
        self.freeArrayElementBufferAfterMove(rt);
        // Sparse array: count stays 0, length is the JS-observable `.length`.
        self.arrayArm().*.length = saved_length;
        self.flags.is_std_array_prototype = false;
    }

    fn denseArrayElement(self: *const Object, atom_id: atom.Atom) ?JSValue {
        if (!self.flags.fast_array) return null;
        if (!atom.isTaggedInt(atom_id)) return null;
        const index = atom.atomToUInt32(atom_id);
        if (index >= self.arrayArm().*.count) return null;
        return self.arrayArm().*.values[@intCast(index)];
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
        self.flags.fast_array = self.arrayArm().*.capacity >= self.arrayArm().*.count;
        for (self.shapeProps()) |prop| {
            if (property.Flags.fromBits(prop.flags).deleted) continue;
            const index = array.arrayIndexFromAtom(&rt.atoms, prop.atom_id) orelse continue;
            self.updateArrayStorageMode(index);
        }
    }

    /// Remember this object as the owner of whatever a property slot holds.
    ///
    /// Every kind but `auto_init` carries a traced reference, and a slot write
    /// on a long-lived object is an old-to-young edge the minor cannot
    /// rediscover -- its sticky marks stop the trace at the owner. Callers that
    /// build a slot and publish it must go through here; the shape transition
    /// takes its own separate barrier for the Shape.
    inline fn barrierPropertySlot(self: *Object, rt: *JSRuntime, flags: property.Flags, slot: property.Slot) void {
        if (comptime !gc.generation_enabled) return;
        if (flags.deleted) return;
        switch (flags.kind) {
            .data => rt.gc.generationalBarrier(&self.header, slot.data.cycleMarkHeader()),
            .accessor => {
                if (slot.accessor.getter) |g| rt.gc.generationalBarrier(&self.header, g);
                if (slot.accessor.setter) |st| rt.gc.generationalBarrier(&self.header, st);
            },
            .var_ref => rt.gc.generationalBarrier(&self.header, &slot.var_ref.header),
            .auto_init => {},
        }
    }

    inline fn addProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void {
        const slot = slotFromDescriptor(&rt.atoms, atom_id, desc);
        try self.appendPreparedPropertyEntry(rt, atom_id, flagsFromDescriptor(desc), slot);
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
    ///
    /// Ownership contract (any value shape, refcounted included — qjs
    /// OP_define_field, quickjs.c:19269, has no value-form gate):
    /// `data_value` is CONSUMED on success and NOT consumed on ANY failure.
    /// The hot caller (defineFieldFast) turns every error into a cold-shell
    /// RE-EXECUTION of the opcode with the value still owned by the VM stack
    /// slot, so the append leg installs the slot borrow-until-commit (its
    /// failure unwind must not destroy the caller's ref) and the duplicate-key
    /// leg goes through replaceProperty's borrow (`slotFromDescriptor` dups)
    /// and then frees the caller's ref only after the replace committed.
    ///
    /// Takes the bare value instead of a `Descriptor`: qjs OP_define_field
    /// carries its property flags as the constant int `JS_PROP_C_W_E`
    /// (quickjs.c:19269) straight into add_property — no descriptor record is
    /// ever materialized on the literal path. The Descriptor round-trip
    /// (96B stack build in the handler + kind/flag re-derivation in the add
    /// path) is confined to the rare duplicate-key branch, which feeds the
    /// generic isCompatible/replaceProperty machinery.
    ///
    /// OUTLINED (`noinline`) as the one publish body behind the resident
    /// op_define_field arm — the qjs frame shape: CASE(OP_define_field) makes a
    /// single call into the define chain (JS_DefinePropertyValue,
    /// quickjs.c:19269) and keeps only pc/sp live across it. Inlining this into
    /// the handler dragged the duplicate-key Descriptor build and the append
    /// marshaling into the hot arm (a 176-byte frame + 10 callee-saved
    /// registers per literal property); the probe/append run here instead, and
    /// `appendPreparedPropertyEntryImpl` folds INTO this body so the 16-byte
    /// property slot is assembled in registers rather than spilled through a
    /// by-pointer call boundary (the loadSlotAsIntPair store-forward hazard).
    pub noinline fn definePlainDataPropertyKnownFast(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, data_value: JSValue) !void {
        // Do not barrier `data_value` before the property probe. Both commit
        // legs publish it at the actual slot write: `replaceProperty` for a
        // duplicate key and `barrierPropertySlot` for an append. An entry
        // barrier was therefore duplicate fixed work, including on failures;
        // it also cannot replace the commit barrier because a major may begin
        // during the allocations between the probe and the eventual store.
        // §4.6 rooted construction: the over-hang value is excluded from
        // `propertyEntries()` until the shape transition commits, and the
        // holder is only a Zig `*Object`. Trial deletion treated the live RC
        // as an external root; tracing needs the mutation window named.
        if (comptime runtime_mod.value_root_frames_enabled) {
            var holder: ?*Object = self;
            var in_flight = data_value;
            var obj_roots = runtime_mod.rootObjects(.{&holder});
            var val_roots = runtime_mod.rootValues(.{&in_flight});
            obj_roots.activate(rt);
            defer obj_roots.deactivate(rt);
            val_roots.activate(rt);
            defer val_roots.deactivate(rt);
            return definePlainDataPropertyKnownFastMut(self, rt, atom_id, in_flight);
        }
        return definePlainDataPropertyKnownFastMut(self, rt, atom_id, data_value);
    }

    inline fn definePlainDataPropertyKnownFastMut(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, data_value: JSValue) !void {
        if (self.findPropertyIndexTrusted(atom_id)) |index| {
            const desc = descriptor.Descriptor.data(data_value, true, true, true);
            try self.materializeAutoInitEntryForMutation(index);
            if (!isCompatible(self.propFlagsAt(index), self.propertyEntry(index).*.slot, desc)) return error.IncompatibleDescriptor;
            try self.replaceProperty(rt, index, desc);
            // replaceProperty is BORROW semantics (slotFromDescriptor dups the
            // value into the new slot, object.zig:12284-ish); the define
            // contract is consume-on-success (qjs JS_DefinePropertyValue frees
            // its `val` argument), so retire the caller's ref here — without
            // this, every duplicate refcounted literal key (`({a:o1,a:o2})`)
            // leaked one ref. Failure paths above did not consume: the
            // materialize/compat/replace errors leave ownership with the
            // caller (replaceProperty's own errdefer frees only its dup).
            data_value.free(rt);
            return;
        }
        // Both call sites (vm_literal.zig defineFieldFast + the cold defineField
        // shell) read `atom_id` from `function.code[frame.pc..]` — the executing
        // bytecode's inline OP_define_field operand — which the finalized
        // FunctionBytecode holds a ref on (dupBytecodeAtoms) and the frame's
        // current_function ref keeps live for the whole opcode. That external
        // root makes appendPreparedPropertyEntry's own atom guard redundant here,
        // so use the trusted (guard-free) add. Flags are the comptime C_W_E
        // constant. No `.dup()` on the slot install: the value MOVES into the
        // slot pre-owned, exactly qjs OP_define_field handing sp[-1] to
        // JS_DefinePropertyValue with no extra dup (quickjs.c:19269). The move
        // only COMMITS with the shape transition: `slot_borrowed_until_commit`
        // keeps the failure unwind from destroying the caller's ref (the cold
        // shell re-executes the opcode still owning the value — destroying it
        // here would double-free a refcounted value on OOM mid-append). Tracing
        // names the in-flight value through the mutation-window roots in
        // `definePlainDataPropertyKnownFast`. Trial deletion still treats the
        // live RC as an external root.
        try self.appendPreparedPropertyEntryImpl(
            true, // caller_holds_atom_ref: the bytecode operand root (see above)
            true, // slot_borrowed_until_commit: consume-on-success contract (see above)
            false,
            rt,
            atom_id,
            comptime property.Flags.data(true, true, true),
            .{ .data = data_value },
        );
    }

    /// Default entry point: the caller does NOT guarantee an independent live
    /// `atom_id` ref, so a local dup/free guard roots the atom across the shape
    /// allocations below (which can trigger GC, whose object/shape sweep frees
    /// prop atoms — dropping an otherwise-unrooted atom to ref_count 0 mid-call).
    pub fn appendPreparedPropertyEntry(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, entry_flags: property.Flags, slot: property.Slot) !void {
        return self.appendPreparedPropertyEntryImpl(false, false, false, rt, atom_id, entry_flags, slot);
    }

    /// `caller_holds_atom_ref == true` is the trusted bytecode-operand leg: the
    /// caller already holds a live `atom_id` ref for the whole call. That is
    /// true for OP_define_field, OP_put_field, and the simple-constructor field
    /// table: all three borrow atoms from immutable FunctionBytecode retained
    /// by the active function/frame. With that external root the local dup/free
    /// guard is pure redundancy (the atom cannot reach ref_count 0 under a GC
    /// from the shape allocations), so elide it. qjs add_property likewise
    /// relies on the caller-held bytecode atom and takes only the Shape's owning
    /// JS_DupAtom. MUST NOT be used with a transient/just-interned atom that has
    /// no other root than the elided guard.
    ///
    /// `slot_borrowed_until_commit == true` (the definePlainDataPropertyKnownFast
    /// leg only): the slot's data value is a BORROW of the caller's live ref
    /// until the shape transition commits — on ANY failure the unwind restores
    /// the pre-call object state WITHOUT destroying the slot value (ownership
    /// stays with the caller, whose cold-shell re-execution still holds it on
    /// the VM stack). On success the value is committed as MOVED (the caller's
    /// consume-on-success contract). `false` keeps the historical owned-slot
    /// unwind: failure destroys the prepared slot via destroyPropertySlot.
    ///
    /// `named_put_no_index == true` is the OP_put_field ordinary miss
    /// (`setOrDefineOwnDataPropertyForPutFieldOwned`): tagged-int and
    /// indexed-class array-index atoms already declined, so this monomorph
    /// matches qjs add_property's probe-free named add (quickjs.c:9884-9890)
    /// and must not `bl atomIsArrayIndex`.
    inline fn appendPreparedPropertyEntryImpl(self: *Object, comptime caller_holds_atom_ref: bool, comptime slot_borrowed_until_commit: bool, comptime named_put_no_index: bool, rt: *JSRuntime, atom_id: atom.Atom, entry_flags: property.Flags, slot: property.Slot) !void {
        if (comptime runtime_mod.value_root_frames_enabled) {
            var holder: ?*Object = self;
            var in_flight: JSValue = if (entry_flags.kind == .data) slot.data else JSValue.undefinedValue();
            var obj_roots = runtime_mod.rootObjects(.{&holder});
            var val_roots = runtime_mod.rootValues(.{&in_flight});
            obj_roots.activate(rt);
            defer obj_roots.deactivate(rt);
            val_roots.activate(rt);
            defer val_roots.deactivate(rt);
            const live_slot: property.Slot = if (entry_flags.kind == .data) .{ .data = in_flight } else slot;
            return appendPreparedPropertyEntryWork(
                caller_holds_atom_ref,
                slot_borrowed_until_commit,
                named_put_no_index,
                self,
                rt,
                atom_id,
                entry_flags,
                live_slot,
            );
        }
        return appendPreparedPropertyEntryWork(
            caller_holds_atom_ref,
            slot_borrowed_until_commit,
            named_put_no_index,
            self,
            rt,
            atom_id,
            entry_flags,
            slot,
        );
    }

    inline fn appendPreparedPropertyEntryWork(comptime caller_holds_atom_ref: bool, comptime slot_borrowed_until_commit: bool, comptime named_put_no_index: bool, self: *Object, rt: *JSRuntime, atom_id: atom.Atom, entry_flags: property.Flags, slot: property.Slot) !void {
        // Root the atom across the shape allocations below unless the caller
        // already holds a live ref. The dup/free must span the WHOLE function
        // (defer at function scope), so gate via comptime rather than a runtime
        // `if` block — a `defer` inside an `if` would fire at the block's end,
        // before the allocations it must protect.
        if (!caller_holds_atom_ref) _ = rt.atoms.dup(atom_id);
        defer if (!caller_holds_atom_ref) rt.atoms.free(atom_id);
        // qjs add_property invalidates the standard Array-prototype marker
        // before any fallible shape/property growth. The invalidation is
        // intentionally sticky even if the later allocation fails.
        // named_put_no_index: tagged-int never reaches here.
        if (comptime !named_put_no_index) {
            if (atom.isTaggedInt(atom_id)) self.invalidateStandardArrayPrototypeForTaggedIndexMutation(rt);
        }
        const is_array_index = if (comptime named_put_no_index) false else rt.atoms.atomIsArrayIndex(atom_id);
        var slot_owned = true;
        errdefer if (!slot_borrowed_until_commit and slot_owned) destroyPropertySlot(rt, atom_id, entry_flags, slot);

        const old_len = self.shape_ref.prop_count;
        const old_storage = self.prop_values;
        const old_capacity = self.propertyStorageCapacity();
        const old_properties = self.propertyStorageEntries(old_capacity);
        var current_capacity = old_capacity;
        var grew_properties = false;
        if (old_len + 1 > old_capacity) {
            // `Shape.prop_size` is the object's capacity record, so the buffer
            // has to come out equal to it, not merely large enough for the
            // count. An adopted shape can already claim more than
            // `propertyCapacityForNeeded` would allocate -- the empty-root
            // cache matches on `prop_count == 0` alone, so it can hand back a
            // shape another owner grew in place -- and
            // `reservePropertyAppend` only ever grows `prop_size`, never
            // shrinks it to what this caller allocated. Starting them equal is
            // what keeps them equal: both sides double from the same base on
            // every later append.
            const next_capacity = @max(
                shape.propertyCapacityForNeeded(old_len + 1),
                @as(usize, self.shape_ref.prop_size),
            );
            const next = try rt.allocRuntime(property.Entry, next_capacity);
            errdefer rt.memory.free(property.Entry, next);
            // The dominant grow is a fresh object's FIRST property (old_len ==
            // 0, no storage yet): skip the memcpy-runtime call for the empty
            // copy instead of paying a zero-length `bl memcpy` per literal.
            if (old_len != 0) {
                if (comptime builtin.is_test) {
                    auditWrite(.memcpy_bulk, .object_prop_values_memcpy);
                    @memcpy(next[0..old_len], self.propertyStorageEntries(old_len));
                } else {
                    @memcpy(next[0..old_len], self.propertyStorageEntries(old_len));
                }
            }
            self.prop_values = next.ptr;
            current_capacity = next_capacity;
            grew_properties = true;
        }

        const old_may_have_indexed_properties = self.flags.may_have_indexed_properties;
        // Over-hang: write the value at index `old_len` (== current prop_count)
        // BEFORE adoptShapeForNewProperty below commits prop_count = old_len + 1.
        // Until that commit the entry is EXCLUDED from propertyEntries(); a GC
        // triggered by the shape allocation skips it. Tracing keeps the value
        // through the mutation-window ValueRootFrame (§4.6). Trial deletion
        // keeps it because the untraced RC is an external root.
        if (comptime builtin.is_test) {
            auditWrite(.fam_slice, .object_prop_slot);
            self.propertyEntry(old_len).* = .{ .slot = slot };
        } else {
            self.propertyEntry(old_len).* = .{ .slot = slot };
        }
        slot_owned = false;
        // A new property on a long-lived object is an old-to-young edge like
        // any other store. The shape transition below takes its own barrier for
        // the Shape; this one is for whatever the slot holds. The two
        // pointer-shaped kinds (accessor functions, a bound cell) matter as
        // much as a plain value: a lazily installed native accessor on a
        // built-in prototype is exactly this shape.
        self.barrierPropertySlot(rt, entry_flags, slot);

        var inserted = true;
        errdefer if (inserted) {
            // Borrow-until-commit: the pending value at old_len is the
            // caller's ref (not ours to destroy); just un-stage the entry.
            if (!slot_borrowed_until_commit)
                destroyPropertySlot(rt, atom_id, entry_flags, self.propertyEntry(old_len).*.slot);
            self.propertyEntry(old_len).* = .{};
            self.flags.may_have_indexed_properties = old_may_have_indexed_properties;
            if (grew_properties) {
                const new_properties = self.propertyStorageEntries(current_capacity);
                self.prop_values = old_storage;
                rt.memory.free(property.Entry, new_properties);
            }
        };

        // Only the boolean "is this atom an array index?" is needed for zjs's
        // local lookup summary and sparse-shape policy; the index value is never
        // consumed. Keep that full ArrayIndex predicate separate from the
        // tagged-integer realm-guard trigger above: high string-atom indexes
        // update this local summary but do not perform qjs add_property's
        // `is_std_array_prototype` invalidation.
        if (is_array_index) {
            self.flags.may_have_indexed_properties = true;
        }
        // qjs add_property (quickjs.c:9209-9222) probes the transition cache
        // and commits a hit (js_dup_shape + swap + js_free_shape) inline in its
        // own frame; only the miss triage (shared clone / rc==1 in-place
        // append) and the sparse array-index path pay an outlined call.
        if (is_array_index or !rt.shapes.tryCachedTransition(&self.shape_ref, atom_id, entry_flags.bits(), current_capacity)) {
            try self.adoptShapeForNewProperty(rt, atom_id, entry_flags.bits(), current_capacity, is_array_index);
        } else {
            // A cache HIT swaps `shape_ref` here and never reaches
            // `adoptShapeForNewProperty`, which is where the miss path takes
            // its barrier. A long-lived object adopting a Shape that is still
            // young is an old-to-young edge either way: the minor's sticky
            // marks stop the trace at the owner, so without this the Shape is
            // condemned while the owner still points at it, and the owner's
            // eventual teardown releases a refcount through freed memory.
            rt.gc.generationalBarrier(&self.header, &self.shape_ref.header);
        }
        // Both the cached transition and miss path have now committed the new
        // Shape. Publish its trace projection before any later safepoint can
        // observe the object; no fallible operation remains in this append.
        self.commitTraceShapeAppend(old_len, entry_flags);
        if (grew_properties and propertyStoragePointerIsExternal(self, old_storage))
            rt.memory.free(property.Entry, old_properties);
        inserted = false;
    }

    fn shapeNeedsMutationCopy(self: *const Object) bool {
        return self.shape_ref.refCount() != 1;
    }

    fn ensureUniqueShapeForMutation(self: *Object, rt: *JSRuntime) !void {
        if (!self.shapeNeedsMutationCopy()) return;
        const next_shape = try rt.shapes.cloneForMutation(self.shape_ref);
        const old_shape = self.shape_ref;
        self.shape_ref = next_shape;
        // The clone is freshly allocated and therefore young; the owner that
        // adopts it here may be long dead to the minor's sticky marks.
        rt.gc.generationalBarrier(&self.header, &next_shape.header);
        rt.shapes.release(old_shape);
    }

    fn adoptShapeForNewProperty(self: *Object, rt: *JSRuntime, atom_id: atom.Atom, flags: u6, property_capacity: usize, is_array_index: bool) !void {
        // No local atom guard: appendPreparedPropertyEntryImpl reaches this
        // either with its own `atoms.dup(atom_id)` guard or through a trusted
        // bytecode-operand leg whose FunctionBytecode independently roots the
        // atom. In both cases `atom_id` survives any GC triggered by the shape
        // allocations below. A second dup/free here would duplicate that root;
        // qjs add_property likewise relies on the caller-held atom while
        // add_shape_property takes the one new owning JS_DupAtom.
        // Indexed properties mutate a unique sparse shape in place. Named
        // properties reach here only after the caller's inline
        // `tryCachedTransition` probe MISSED (qjs add_property cache-hit leg,
        // quickjs.c:9209-9222, runs in the append frame); the remaining triage
        // is shared clone or rc==1 in-place append. transitionPropertyUncached
        // owns replacement releases and threads relocation back through
        // self.shape_ref.
        if (is_array_index) {
            try self.ensureUniqueShapeForMutation(rt);
            try rt.shapes.addProperty(&self.shape_ref, atom_id, flags);
            rt.gc.generationalBarrier(&self.header, &self.shape_ref.header);
            return;
        }
        try rt.shapes.transitionPropertyUncached(&self.shape_ref, atom_id, flags, property_capacity);
        // A Shape is a traced heap object like any other, and a long-lived
        // object adopting a freshly created one is an old-to-young edge. The
        // minor's sticky marks stop the trace at the old owner, so without
        // this the new Shape is swept and the next property read walks a
        // destroyed `props()` array.
        rt.gc.generationalBarrier(&self.header, &self.shape_ref.header);
    }

    fn ensurePropertyCapacity(self: *Object, rt: *JSRuntime, needed: usize) !void {
        const old_storage = self.prop_values;
        const old_capacity = self.propertyStorageCapacity();
        if (needed <= old_capacity) return;
        // Same invariant as the append path: the buffer must come out equal to
        // whatever `prop_size` the shape already claims, because that number is
        // the object's capacity record and `reserveProperties` below will not
        // shrink it back down to what was allocated here.
        const next_capacity = @max(
            shape.propertyCapacityForNeeded(needed),
            @as(usize, self.shape_ref.prop_size),
        );
        const next = try rt.allocRuntime(property.Entry, next_capacity);
        errdefer rt.memory.free(property.Entry, next);
        const used = self.shape_ref.prop_count;
        if (comptime builtin.is_test) {
            auditWrite(.memcpy_bulk, .object_prop_values_memcpy);
            @memcpy(next[0..used], self.propertyEntries());
        } else {
            @memcpy(next[0..used], self.propertyEntries());
        }
        const old_properties = self.propertyStorageEntries(old_capacity);
        try rt.shapes.reserveProperties(&self.shape_ref, next_capacity);
        // Every write to `shape_ref` is an owner adopting a Shape: the clone or
        // relocation this call may perform produces a fresh, young one, and a
        // long-lived owner reaching it is an old-to-young edge the minor's
        // sticky marks would otherwise stop short of.
        rt.gc.generationalBarrier(&self.header, &self.shape_ref.header);
        self.prop_values = next.ptr;
        if (propertyStoragePointerIsExternal(self, old_storage)) rt.memory.free(property.Entry, old_properties);
    }

    fn propertyStorageCapacity(self: *const Object) usize {
        return if (self.hasPropertyStorage()) self.shape_ref.prop_size else 0;
    }

    inline fn emptyPropertyStorageBase() [*]property.Entry {
        return @ptrFromInt(@alignOf(property.Entry));
    }

    /// After Pass B pops this object, `prop_values` holds the deferred-free
    /// overlay. Restore the empty-storage sentinel so a kept weak husk is a
    /// valid object again.
    pub fn restoreEmptyPropertyStorage(self: *Object) void {
        self.prop_values = emptyPropertyStorageBase();
    }

    /// The trailing property FAM starts right after the class-data arm. Only
    /// `ids.object` may own one (`verifyObjectPropertyStorageLayouts` /
    /// `freeObjectAllocation` both enforce it), so the offset stays a compile-
    /// time constant on this hot path rather than a `class_id` load.
    pub const trailing_property_storage_offset: usize = objectBodyBytes(class.ids.object);

    /// NOTE: `createPlainObjectReserved2` calls this while building the head's
    /// struct literal, i.e. before any field of `self` is written. It must stay
    /// a pure address computation; the "only `ids.object` owns a trailing FAM"
    /// rule is checked by `verifyObjectPropertyStorageLayouts` instead.
    pub inline fn trailingPropertyStorageBase(self: *const Object) [*]property.Entry {
        return @ptrFromInt(@intFromPtr(self) + trailing_property_storage_offset);
    }

    pub inline fn propertyStoragePointerIsExternal(self: *const Object, ptr: [*]property.Entry) bool {
        return ptr != emptyPropertyStorageBase() and ptr != trailingPropertyStorageBase(self);
    }

    /// Base-address choke point for every named-property access. Both external
    /// and trailing storage are recorded as the direct Entry pointer, so this
    /// is the same load/index sequence as the pre-Stage-2 representation.
    pub inline fn propertyStorageBase(self: *const Object) [*]property.Entry {
        std.debug.assert(self.hasPropertyStorage());
        return self.prop_values;
    }

    pub inline fn propertyEntry(self: *const Object, index: usize) *property.Entry {
        return &self.propertyStorageBase()[index];
    }

    pub inline fn propertyStorageEntries(self: *const Object, capacity: usize) []property.Entry {
        return self.prop_values[0..capacity];
    }

    /// Address the immutable trailing region even after growth has installed
    /// an external current buffer. Used only when compaction can move the live
    /// entries back into the allocation's original two-slot tail.
    pub inline fn trailingPropertyStorageEntries(self: *const Object) []property.Entry {
        std.debug.assert(self.hasTrailingPropertyAllocation());
        return self.trailingPropertyStorageBase()[0..trailing_property_capacity];
    }

    /// The live property VALUE entries `prop_values[0..prop_count]`. Count comes
    /// from the owning shape (qjs JSObject reads count from JSShape). During the
    /// brief `appendPreparedPropertyEntry` over-hang (a value written at index
    /// `prop_count` before the shape transition commits), the pending entry sits
    /// at `prop_values[prop_count]` and is intentionally EXCLUDED here — callers
    /// that need it (the append path itself) index `prop_values` directly.
    pub inline fn propertyEntries(self: *const Object) []property.Entry {
        return self.prop_values[0..self.shape_ref.prop_count];
    }

    fn replaceProperty(self: *Object, rt: *JSRuntime, index: usize, desc: descriptor.Descriptor) !void {
        const atom_id = self.propAtomAt(index);
        const old_flags = self.propFlagsAt(index);
        const merged = mergeDescriptor(old_flags, self.propertyEntry(index).*.slot, desc);
        const next_flags = flagsFromDescriptor(merged);
        if (old_flags.kind == .var_ref and merged.kind == .data) {
            // Redefining a VARREF property as data writes THROUGH the cell and
            // keeps the var_ref slot (so closures still alias it). The kind flag
            // therefore stays `.var_ref` — only w/e/c bits update; flipping the
            // kind to `.data` here would desync the cell (slot=var_ref) from the
            // shape (kind=data) and crash the next read.
            const cell = self.propertyEntry(index).*.slot.var_ref;
            const next_value = dupPropertyDataValue(&rt.atoms, atom_id, merged.value);
            errdefer next_value.free(rt);
            const stored_flags = next_flags.withKind(.var_ref);
            if (old_flags.bits() != stored_flags.bits()) try self.ensureUniqueShapeForMutation(rt);
            cell.setVarRefValue(rt, next_value);
            // qjs JS_DefineProperty VARREF + HAS_WRITABLE double-write
            // (quickjs.c:10508-10520): shape flags AND the cell's is_const.
            // Descriptor.fromSlot and OP_put_var both read is_const, matching
            // commitAutoInitValue (object.zig creation path).
            cell.varRefIsConstSlot().* = !stored_flags.writable;
            self.updateShapePropertyFlags(rt, index, stored_flags);
            return;
        }
        const next_slot = slotFromDescriptor(&rt.atoms, atom_id, merged);
        var next_owned = true;
        errdefer if (next_owned) destroyPropertySlot(rt, atom_id, next_flags, next_slot);
        if (old_flags.bits() != next_flags.bits()) try self.ensureUniqueShapeForMutation(rt);
        const old_slot = self.propertyEntry(index).*.slot;
        // qjs convert-to-getset (quickjs.c:10410-10426): VARREF → GETSET
        // calls remove_global_object_property + free_var_ref so bare-identifier
        // readers parked on the old cell see UNINITIALIZED and re-resolve
        // through the global object (now the accessor).
        if (old_flags.kind == .var_ref and merged.kind == .accessor and self.isGlobal()) {
            const cell = old_slot.var_ref;
            const old_value = cell.varRefValueSlot().*;
            cell.varRefValueSlot().* = JSValue.uninitialized();
            cell.is_lexical = false;
            cell.is_const = false;
            old_value.free(rt);
        }
        if (comptime builtin.is_test) {
            auditWrite(.shape_slot, .object_set_entry_kind_and_slot);
            self.propertyEntry(index).* = .{ .slot = next_slot };
        } else {
            self.propertyEntry(index).* = .{ .slot = next_slot };
        }
        next_owned = false;
        self.barrierPropertySlot(rt, next_flags, next_slot);
        self.updateShapePropertyFlags(rt, index, next_flags);
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
        return self.propertyEntry(index).*.slot.data;
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
        const old_slot = self.propertyEntry(index).*.slot;
        if (comptime builtin.is_test) {
            auditWrite(.union_arm, .object_prop_slot);
            self.propertyEntry(index).*.slot = .{ .data = new_value };
        } else {
            self.propertyEntry(index).*.slot = .{ .data = new_value };
        }
        destroyPropertySlot(rt, prop.atom_id, flags, old_slot);
    }

    /// The stored accessor at `index`, or null if not an accessor property.
    pub inline fn asAccessorAt(self: *const Object, index: usize) ?property.Accessor {
        const flags = self.propFlagsAt(index);
        if (flags.deleted or flags.kind != .accessor) return null;
        return self.propertyEntry(index).*.slot.accessor;
    }

    /// The var_ref cell at `index`, or null if not a var_ref property.
    pub inline fn asVarRefAt(self: *const Object, index: usize) ?*var_ref_mod.VarRef {
        const flags = self.propFlagsAt(index);
        if (flags.deleted or flags.kind != .var_ref) return null;
        return self.propertyEntry(index).*.slot.var_ref;
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
        const old_slot = self.propertyEntry(index).*.slot;
        if (old_flags.kind == .data) {
            cell.setVarRefValue(rt, old_slot.data.dup());
        }
        cell.is_lexical = false;
        cell.varRefIsConstSlot().* = !next_flags.writable;
        cell.varRefIsDeletableSlot().* = next_flags.configurable;

        if (comptime builtin.is_test) {
            auditWrite(.union_arm, .object_prop_slot);
            self.propertyEntry(index).*.slot = .{ .var_ref = cell.dupCell() };
        } else {
            self.propertyEntry(index).*.slot = .{ .var_ref = cell.dupCell() };
        }
        // Same bare publication as the auto-init replacement above, and the
        // same direction: the owner is a long-lived environment or global
        // object and the cell is usually brand new.
        rt.gc.generationalBarrier(&self.header, &cell.header);
        self.updateShapePropertyFlags(rt, index, next_flags);
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
        const old_slot = self.propertyEntry(index).*.slot;
        if (comptime builtin.is_test) {
            auditWrite(.shape_slot, .object_set_entry_kind_and_slot);
            self.propertyEntry(index).*.slot = next_slot;
        } else {
            self.propertyEntry(index).*.slot = next_slot;
        }
        self.barrierPropertySlot(rt, next_flags, next_slot);
        self.updateShapePropertyFlags(rt, index, next_flags);
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
        return .{ .value = .{ .index = lookup.index, .flags = flags, .value = self.propertyEntry(lookup.index).*.slot.data } };
    }

    pub inline fn findOwnPropertySlotTrusted(self: *const Object, atom_id: atom.Atom) ?OwnPropertySlotLookup {
        const lookup = self.findPropertyProbeTrusted(atom_id) orelse return null;
        return .{
            .flags = property.Flags.fromBits(lookup.prop.flags),
            .entry = self.propertyEntry(lookup.index),
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
                return self.propertyEntry(index).*.slot.data;
            }
        }
        return null;
    }

    /// Slot-pointer twin of `findOwnDataValueFast` for the resident get_field
    /// handlers. Two deliberate lowerings for the hot hit:
    /// - Returns the BORROWED slot ADDRESS instead of a 16-byte value so the
    ///   caller can re-load it as two 64-bit integer words (loadValueAsIntPair
    ///   precedent): a by-value return makes LLVM round-trip the optional
    ///   through a 128-bit stack slot whose 64-bit tag reload defeats
    ///   store-to-load forwarding (the top cycle sink of op_get_field).
    /// - Tests the kind bits straight off the packed shape word; materializing
    ///   `property.Flags.fromBits` here costs a packed-bitcast alloca spill in
    ///   the handler frame.
    /// Mirrors qjs find_own_property + the JS_PROP_TMASK guard feeding
    /// JS_DupValue(pr->u.value) (quickjs.c:6135, 19125-19133).
    pub inline fn findOwnDataSlotFast(self: *const Object, atom_id: atom.Atom, slow: *bool) ?*const JSValue {
        const object_shape = self.shape_ref;
        // qjs find_own_property (quickjs.c:6115): `h = atom & mask; load; cbz h`.
        // Empty shapes still have the 4-bucket table (`createShape`); a missing
        // hash is an empty bucket, not a second miss (F3).
        const props = object_shape.props().ptr;
        var shape_index = object_shape.firstPropertyIndexAssumeHash(atom_id);
        while (shape_index != shape.no_property_index) {
            const index: usize = @intCast(shape_index);
            const prop = props[index];
            shape_index = prop.hash_next;
            if (prop.atom_id == atom_id) {
                // Kind bits 3-4 of the 6-bit flags field; .data == 0 (qjs
                // JS_PROP_TMASK). Deleted tombstones are unlinked from the
                // hash chain with their atom cleared, so they cannot match.
                if ((prop.flags >> 3) & 0x3 != 0) {
                    slow.* = true;
                    return null;
                }
                return &self.propertyEntry(index).*.slot.data;
            }
        }
        return null;
    }

    /// Write-side twin of `findOwnDataSlotFast` for the resident put_field
    /// handler: returns the MUTABLE own slot address only when the entry is a
    /// plain writable data property. Same two lowerings (slot pointer instead
    /// of a by-value struct + direct bit extraction off the packed shape word
    /// instead of a `property.Flags` materialization, whose packed-bitcast
    /// alloca spill was the write handler's only frame traffic); additionally
    /// folds the writable bit into the same single-mask test, mirroring qjs
    /// OP_put_field's hit condition `(prs->flags & (JS_PROP_TMASK |
    /// JS_PROP_WRITABLE | JS_PROP_LENGTH)) == JS_PROP_WRITABLE`
    /// (quickjs.c:19193-19196). zjs has no JS_PROP_LENGTH shape flag: array
    /// `length` lives in the object header (DenseArrayStorage.length), never
    /// in the shape, so the qjs LENGTH reject leg has no counterpart here —
    /// `arr.length = n` simply misses the own probe and defers to the cold
    /// resolver.
    /// `slow` is written only when the atom matched but the entry cannot take
    /// a direct slot write (accessor/var_ref/auto_init kind or read-only
    /// data); the caller initializes it to false.
    pub inline fn findWritableOwnDataSlotFast(self: *Object, atom_id: atom.Atom, slow: *bool) ?*JSValue {
        const props = self.shape_ref.props().ptr;
        var shape_index = self.shape_ref.firstPropertyIndexAssumeHash(atom_id);
        while (shape_index != shape.no_property_index) {
            const index: usize = @intCast(shape_index);
            const prop = props[index];
            shape_index = prop.hash_next;
            if (prop.atom_id == atom_id) {
                // Kind bits 3-4 (.data == 0, qjs JS_PROP_TMASK) plus writable
                // bit 0 in one mask. Deleted tombstones are unlinked from the
                // hash chain with their atom cleared, so they cannot match.
                if ((prop.flags & 0b011001) != 0b000001) {
                    slow.* = true;
                    return null;
                }
                return &self.propertyEntry(index).*.slot.data;
            }
        }
        return null;
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

    // The owner object is held only by this Zig local; the tracing sweep
    // needs it declared for the keep phase. Deactivated before the release
    // phase so the second collection can observe the symbol body dropping.
    var object_slot: ?*Object = object;
    var live_roots = runtime_mod.rootObjects(.{&object_slot});
    live_roots.activate(rt);
    var roots_active = true;
    defer if (roots_active) live_roots.deactivate(rt);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(nested_symbol) != null);

    live_roots.deactivate(rt);
    roots_active = false;
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

pub fn dupPropertyDataValue(_: *atom.AtomTable, _: atom.Atom, value: JSValue) JSValue {
    return value.dup();
}

pub fn destroyPropertySlot(rt: *JSRuntime, _: atom.Atom, flags: property.Flags, slot: property.Slot) void {
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

pub fn isTypedArrayObject(object: *const Object) bool {
    const payload = object.typedArrayPayloadFast() orelse return false;
    return payload.buffer != null and payload.element_size != 0;
}

pub fn typedArrayOutOfBounds(object: *Object) !bool {
    const payload = object.typedArrayPayloadFast() orelse return error.TypeError;
    const backing = payload.backing_payload orelse return error.TypeError;
    if (payload.byte_offset > backing.bytes.len) return true;
    if (payload.fixed_length) |fixed| {
        const bytes = std.math.mul(usize, fixed, payload.element_size) catch return true;
        return bytes > backing.bytes.len - payload.byte_offset;
    }
    return false;
}

pub fn typedArrayDetached(object: *Object) !bool {
    const payload = object.typedArrayPayloadFast() orelse return error.TypeError;
    const backing = payload.backing_payload orelse return error.TypeError;
    return backing.detached;
}

pub fn typedArrayLength(rt: *JSRuntime, object: *Object) !u32 {
    _ = rt;
    const payload = object.typedArrayPayloadFast() orelse return error.TypeError;
    if (payload.element_size == 0 or payload.buffer == null or payload.backing_payload == null) return error.TypeError;
    return payload.live_length;
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
    _ = rt;
    const payload = object.typedArrayPayloadFast() orelse return error.TypeError;
    if (payload.element_size == 0 or payload.buffer == null or payload.backing_payload == null) return error.TypeError;
    return index < payload.live_length;
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
        value_format.formatFiniteNumberAssumeCapacity(&buf, number);
    if (!std.mem.eql(u8, name, printed)) return .none;
    if (!std.math.isFinite(number) or @trunc(number) != number or number < 0 or number > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return .invalid;
    return .{ .index = @intFromFloat(number) };
}

pub fn typedArrayBackedByResizableBuffer(object: *Object) bool {
    if (!isTypedArrayObject(object)) return false;
    const payload = object.typedArrayPayloadFast() orelse return false;
    const backing = payload.backing_payload orelse return false;
    return backing.max_byte_length != null;
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
    _ = rt;
    const payload = object.typedArrayPayloadFast() orelse return error.TypeError;
    const backing = payload.backing_payload orelse return error.TypeError;
    return backing.immutable;
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
        const object: *Object = Object.fromHeader(header);
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

fn hasPropertyIndexKeys(self: *const Object, rt: *JSRuntime) bool {
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
    return Object.fromHeader(header);
}

fn entriesAtomToStringValue(rt: *JSRuntime, atom_id: atom.Atom) !JSValue {
    return rt.atoms.toStringValue(rt, atom_id);
}

fn entryArrayValue(rt: *JSRuntime, key: atom.Atom, value: JSValue, prototype: ?*Object) !JSValue {
    var rooted_value = value;
    defer rooted_value.free(rt);
    var root_frame = runtime_mod.rootValues(.{&rooted_value});
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const arr = try Object.createArray(rt, prototype);
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

pub fn ownEntriesArray(rt: *JSRuntime, value: JSValue, mode: EntriesMode, prototype: ?*Object) !JSValue {
    var rooted_value = value;
    var out_value = JSValue.undefinedValue();
    var element_val = JSValue.undefinedValue();
    var root_frame = runtime_mod.rootValues(.{ &rooted_value, &out_value, &element_val });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const object = try ownEntriesExpectObject(rooted_value);
    const owned_keys = try object.ownKeys(rt);
    defer Object.freeKeys(rt, owned_keys);

    // qjs js_object_keys/values/entries uses JS_NewArray (quickjs.c:5841):
    // the result walks the realm Array.prototype, not a class-name fallback.
    const out = try Object.createArray(rt, prototype);
    out_value = out.value();
    errdefer {
        Object.destroyFromHeader(rt, &out.header);
        out_value = JSValue.undefinedValue();
    }
    var out_index: u32 = 0;
    for (owned_keys) |key| {
        if (rt.atoms.isPublicSymbol(key)) continue;
        const desc = (try object.getOwnProperty(rt, key)) orelse continue;
        defer desc.destroy(rt);
        if (!(desc.enumerable orelse false)) continue;
        element_val = switch (mode) {
            .keys => try entriesAtomToStringValue(rt, key),
            .values => try object.getProperty(key),
            .entries => try entryArrayValue(rt, key, try object.getProperty(key), prototype),
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
    const object: *Object = Object.fromHeader(header);
    if (object.class_id != class.ids.string) return error.TypeError;
    return (object.objectData() orelse return error.TypeError).dup();
}

fn defineStringIteratorToStringTag(rt: *JSRuntime, object: *Object, tag_name: []const u8) !void {
    const tag_atom = atom.predefinedId("Symbol.toStringTag", .symbol) orelse return error.TypeError;
    const tag_value = try string.String.createUtf8(rt, tag_name);
    defer tag_value.value().free(rt);
    try object.defineOwnProperty(rt, tag_atom, descriptor.Descriptor.data(tag_value.value(), false, false, true));
}

fn stringIteratorPrototype(ctx: *context_mod.RealmContext, tag_name: []const u8) !*Object {
    const rt = ctx.runtime;
    const base = try Object.create(rt, class.ids.object, null);
    var base_raw_owned = true;
    errdefer if (base_raw_owned) Object.destroyFromHeader(rt, &base.header);
    try defineStringIteratorToStringTag(rt, base, "Iterator");
    const specific = try Object.create(rt, class.ids.object, base);
    errdefer Object.destroyFromHeader(rt, &specific.header);
    base_raw_owned = false;
    base.value().free(rt);
    try defineStringIteratorToStringTag(rt, specific, tag_name);
    const next = try function.nativeFunction(ctx, "next", 0);
    defer next.free(rt);
    const next_object = (next.refHeader() orelse return error.TypeError);
    if (!next.isObject()) return error.TypeError;
    const next_function: *Object = Object.fromHeader(next_object);
    next_function.setNativeBuiltinIdAndRecord(rt, function.nativeBuiltinId(.string, @intFromEnum(host_function.builtin_method_ids.string.PrototypeMethod.iterator_next)));
    try specific.defineOwnProperty(rt, atom.predefinedId("next", .string).?, descriptor.Descriptor.data(next, true, false, true));
    return specific;
}

pub fn stringIterator(ctx: *context_mod.RealmContext, receiver: JSValue) !JSValue {
    const rt = ctx.runtime;
    var rooted_receiver = receiver;
    var target = JSValue.undefinedValue();
    var prototype_value = JSValue.undefinedValue();
    var object_value = JSValue.undefinedValue();
    var root_frame = runtime_mod.rootValues(.{
        &rooted_receiver,
        &target,
        &prototype_value,
        &object_value,
    });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    target = try stringIteratorPrimitiveValue(rooted_receiver);
    defer target.free(rt);
    const prototype = try stringIteratorPrototype(ctx, "String Iterator");
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

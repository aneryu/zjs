const class = @import("class.zig");
const gc = @import("gc.zig");
const JSValue = @import("value.zig").JSValue;
const JSRuntime = @import("runtime.zig").JSRuntime;
const VarRef = @import("var_ref.zig").VarRef;
const std = @import("std");

/// Property kind (qjs `JS_PROP_TMASK`, quickjs.h:303-307). The kind is NOT
/// stored in the per-property value cell (qjs `JSProperty`); it lives in the
/// owning shape's per-property flags and is read via `Object.propFlagsAt`.
/// Ordering matches qjs: NORMAL(0)/GETSET(1)/VARREF(2)/AUTOINIT(3).
pub const Kind = enum(u2) {
    data, // JS_PROP_NORMAL   (0 << 4): `JSValue value`
    accessor, // JS_PROP_GETSET   (1 << 4): getter/setter object pair
    var_ref, // JS_PROP_VARREF   (2 << 4): aliased cell (`JSVarRef *`)
    auto_init, // JS_PROP_AUTOINIT (3 << 4): lazy builtin placeholder
};

pub const Flags = packed struct(u6) {
    writable: bool = false, // bit 0  (JS_PROP_WRITABLE analog)
    enumerable: bool = false, // bit 1
    configurable: bool = false, // bit 2
    kind: Kind = .data, // bits 3-4 (== JS_PROP_TMASK >> 4)
    deleted: bool = false, // bit 5  (qjs: atom == JS_ATOM_NULL free entry)

    pub fn data(writable: bool, enumerable: bool, configurable: bool) Flags {
        return .{
            .writable = writable,
            .enumerable = enumerable,
            .configurable = configurable,
            .kind = .data,
        };
    }

    pub fn accessorFlags(enumerable: bool, configurable: bool) Flags {
        return .{
            .enumerable = enumerable,
            .configurable = configurable,
            .kind = .accessor,
        };
    }

    pub fn varRef(writable: bool, enumerable: bool, configurable: bool) Flags {
        return .{
            .writable = writable,
            .enumerable = enumerable,
            .configurable = configurable,
            .kind = .var_ref,
        };
    }

    /// Reproject these flags onto a new kind, clearing the deleted bit.
    pub fn withKind(self: Flags, kind: Kind) Flags {
        var next = self;
        next.kind = kind;
        next.deleted = false;
        return next;
    }

    pub fn asDeleted(self: Flags) Flags {
        var next = self;
        next.kind = .data;
        next.writable = false;
        next.deleted = true;
        return next;
    }

    pub fn isData(self: Flags) bool {
        return !self.deleted and self.kind == .data;
    }

    pub fn isAccessor(self: Flags) bool {
        return !self.deleted and self.kind == .accessor;
    }

    pub fn isVarRef(self: Flags) bool {
        return !self.deleted and self.kind == .var_ref;
    }

    pub fn isAutoInit(self: Flags) bool {
        return !self.deleted and self.kind == .auto_init;
    }

    pub fn bits(self: Flags) u6 {
        return @bitCast(self);
    }

    pub fn fromBits(bits_value: u6) Flags {
        return @bitCast(bits_value);
    }
};

/// qjs `struct { JSObject *getter, *setter; }` (quickjs.c:949-952). Getters and
/// setters are always callable objects or absent; absence is `null` (qjs NULL),
/// surfacing as `undefined`. Two object-header pointers = 16B, faithful to qjs
/// and half the size of the old `{ getter, setter: JSValue }` (32B).
pub const Accessor = struct {
    getter: ?*gc.Header = null, // qjs JSObject *getter; NULL if undefined
    setter: ?*gc.Header = null, // qjs JSObject *setter; NULL if undefined

    /// Build from values that the caller already owns refs on (transfer).
    pub fn fromOwnedValues(getter_value: JSValue, setter_value: JSValue) Accessor {
        return .{
            .getter = accessorHeaderFromValue(getter_value),
            .setter = accessorHeaderFromValue(setter_value),
        };
    }

    /// Build from borrowed values, retaining the 0-2 object headers.
    pub fn fromBorrowedValues(getter_value: JSValue, setter_value: JSValue) Accessor {
        const self = fromOwnedValues(getter_value, setter_value);
        self.retain();
        return self;
    }

    pub fn getterValue(self: Accessor) JSValue {
        return valueFromAccessorHeader(self.getter);
    }

    pub fn setterValue(self: Accessor) JSValue {
        return valueFromAccessorHeader(self.setter);
    }

    pub fn getterIsUndefined(self: Accessor) bool {
        return self.getter == null;
    }

    pub fn setterIsUndefined(self: Accessor) bool {
        return self.setter == null;
    }

    /// GC bridge: the trace visitor reads `getterValue()` into a stack temp,
    /// visits (possibly rewriting it under a moving collector), then writes the
    /// possibly-updated value back through these. The value is always an object
    /// or undefined, so re-deriving the header is lossless.
    pub fn syncGetterFromVisitedValue(self: *Accessor, value: JSValue) void {
        self.getter = accessorHeaderFromValue(value);
    }

    pub fn syncSetterFromVisitedValue(self: *Accessor, value: JSValue) void {
        self.setter = accessorHeaderFromValue(value);
    }

    pub fn retain(self: Accessor) void {
        if (self.getter) |header| gc.retain(header);
        if (self.setter) |header| gc.retain(header);
    }

    pub fn destroy(self: Accessor, rt: anytype) void {
        // Route through JSValue.free so the deinit-phase object skip applies.
        self.getterValue().free(rt);
        self.setterValue().free(rt);
    }

    pub fn dup(self: Accessor) Accessor {
        self.retain();
        return self;
    }
};

fn accessorHeaderFromValue(value: JSValue) ?*gc.Header {
    if (value.isUndefined()) return null;
    std.debug.assert(value.isObject());
    return value.refHeader().?;
}

fn valueFromAccessorHeader(header: ?*gc.Header) JSValue {
    return if (header) |h| JSValue.object(h) else JSValue.undefinedValue();
}

pub const AutoInitKind = enum(u8) {
    native_function,
    native_accessor,
    console,
    math_namespace,
    json_namespace,
    reflect_namespace,
    atomics_namespace,
    navigator,
    performance,
    array_unscopables,
    number_constant,
    int32_constant,
    string_constant,
    empty_array,
    /// Lazy `function.prototype` (qjs `JS_AUTOINIT_ID_PROTOTYPE`,
    /// `js_instantiate_prototype` quickjs.c:17341): the prototype object and its
    /// `constructor` back-reference are materialized only when `.prototype` is
    /// first observed or the function is constructed. Avoids the per-function
    /// prototype allocation AND the `func <-> prototype.constructor` reference
    /// cycle (so a never-constructed closure is reclaimed by refcount instead of
    /// the cycle collector). All payload is derived from the owner function
    /// object at materialization, so a single interned descriptor is shared.
    function_prototype,
};

pub const ArrayBuiltinMarker = enum(u8) {
    none = 0,
    constructor = 1,
    species_getter = 2,
    to_string = 3,
    to_locale_string = 4,
    concat = 5,
};

pub const TypedArrayBuiltinMarker = enum(u8) {
    none = 0,
    prototype_method = 1,
    static_from = 2,
    static_of = 3,
};

/// Lazy-materialization payload for `Slot.auto_init`. The slot holds
/// just enough metadata for the first reader to call `builder`,
/// receive a fresh `JSValue`, and replace the slot with `.data`.
///
/// Borrowed from QuickJS's `JS_PROP_AUTOINIT` mechanism
/// (`JSCFunctionListEntry` + `JS_AutoInitProperty`): the standard
/// builtins are described as compile-time tables and the real
/// function objects are only allocated when JS code observes them.
/// For zjs, this turns `installStandardGlobals` from "build ~700
/// native function objects up front" into "stamp 700 placeholder
/// slots" (no allocation), at the cost of one materialization on the
/// first read of each method.
///
/// `name` and `length` are the same pair that `nativeFunction` would
/// have received eagerly. `rt` is captured so `getProperty` can
/// materialize without threading the JSRuntime through every prop-read
/// call site (zjs's `getProperty(self: Object, ...)` is reached by
/// 300+ callers; we want this change to be local).
pub const AutoInit = struct {
    name: []const u8,
    length: i32,
    rt: *JSRuntime,
    kind: AutoInitKind = .native_function,
    // Kind-specific payload reused by host function autoinit and by native
    // accessor pairs. For `.native_accessor`, `host_function_kind > 0` means
    // an accessor setter exists; it stores the setter length, while
    // `external_host_function_id` stores the setter native-builtin id.
    host_function_kind: i32 = 0,
    external_host_function_id: u32 = 0,
    host_function_prototype: bool = false,
    host_function_realm_global: usize = 0,
    native_builtin_id: i32 = 0,
    array_builtin_marker: ArrayBuiltinMarker = .none,
    typed_array_builtin_marker: TypedArrayBuiltinMarker = .none,
    array_iterator_kind: u8 = 0,
    iterator_identity: bool = false,
    collection_method_owner_class: class.ClassId = class.invalid_class_id,
    disposable_stack_method: u8 = 0,
    async_disposable_stack_method: u8 = 0,
    shared_native_cache_slot: u8 = 0,
};

pub const AutoInitRef = struct {
    rt: *JSRuntime,
    id: u32,
};

/// qjs `JSProperty` (quickjs.c:947-963): a 16B untagged union. The active arm
/// is NOT discriminated by an in-cell tag; the owning shape's `Flags.kind`
/// (read via `Object.propFlagsAt`) selects the arm. Always pair every slot
/// write with the matching `Flags.kind` write (use the `Object` typed API /
/// the paired flags⇄slot constructor) so the active arm and the flag never
/// desync.
///
/// Under Debug/ReleaseSafe Zig adds a hidden safety tag, so reading the wrong
/// arm panics loudly — this is the primary correctness net for the migration.
/// The 16B invariant is exact only in the optimized (shipping) builds; the
/// comptime assert below checks it there.
pub const Slot = union {
    data: JSValue,
    accessor: Accessor,
    auto_init: AutoInitRef,
    // QuickJS `JS_PROP_VARREF`: the property slot HOLDS the cell pointer
    // (qjs `pr->u.var_ref`). Reads/writes of such a property auto-deref
    // `cell.pvalue`. Used for top-level lexical (`let`/`const`) bindings on
    // the global lexical env object, shared by pointer with frame.var_refs.
    var_ref: *VarRef,

    pub fn destroy(self: Slot, flags: Flags, rt: anytype) void {
        if (flags.deleted) return;
        switch (flags.kind) {
            .data => self.data.free(rt),
            .accessor => self.accessor.destroy(rt),
            // Auto-init metadata is owned by JSRuntime.auto_init_table and
            // released when the runtime is torn down.
            .auto_init => {},
            // The slot holds one ref on the cell (qjs add_property ref_count++);
            // release it (qjs free_property VARREF branch -> free_var_ref).
            // PRESERVE the cycle-collector guard: during remove_cycles a
            // visited-but-not-preserved cell is freed by the collector, so we
            // must not double-free it here.
            .var_ref => {
                const cell = self.var_ref;
                if (rt.gc.phase == .remove_cycles and cell.header.meta().flags.cycle_visited) return;
                cell.valueRef().free(rt);
            },
        }
    }

    pub fn dup(self: Slot, flags: Flags) Slot {
        if (flags.deleted) return .{ .data = JSValue.undefinedValue() };
        return switch (flags.kind) {
            .data => .{ .data = self.data.dup() },
            .accessor => .{ .accessor = self.accessor.dup() },
            .auto_init => .{ .auto_init = self.auto_init },
            .var_ref => blk: {
                _ = self.var_ref.valueRef().dup();
                break :blk .{ .var_ref = self.var_ref };
            },
        };
    }
};

comptime {
    // qjs `JSProperty` is a 16B untagged union. Zig adds a hidden safety tag to
    // bare unions under Debug/ReleaseSafe, so the 16B invariant is only exact in
    // the optimized (shipping) builds; assert it there.
    const mode = @import("builtin").mode;
    if (mode == .ReleaseFast or mode == .ReleaseSmall) {
        std.debug.assert(@sizeOf(Slot) == 16);
    }
}

pub fn internAutoInit(rt: *JSRuntime, info: AutoInit) !AutoInitRef {
    try rt.auto_init_table.append(rt.memory.allocator, info);
    return .{ .rt = rt, .id = @intCast(rt.auto_init_table.items.len - 1) };
}

pub fn autoInitAt(rt: *JSRuntime, ref: AutoInitRef) *AutoInit {
    std.debug.assert(ref.rt == rt);
    return autoInit(ref);
}

pub fn autoInit(ref: AutoInitRef) *AutoInit {
    return &ref.rt.auto_init_table.items[ref.id];
}

/// Per-object property storage. Holds only the value side of a
/// property (QuickJS `JSProperty` model); the key atom and the
/// writable/enumerable/configurable/kind/deleted flags live in the
/// owning object's shape (`shape.Property`), indexed 1:1 with this
/// array. Use `Object.propAtomAt` / `Object.propFlagsAt` to read the
/// metadata for an entry.
pub const Entry = struct {
    slot: Slot = .{ .data = JSValue.undefinedValue() },
};

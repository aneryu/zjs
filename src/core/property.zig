const class = @import("class.zig");
const JSValue = @import("value.zig").JSValue;
const JSRuntime = @import("runtime.zig").JSRuntime;
const VarRef = @import("var_ref.zig").VarRef;
const std = @import("std");

pub const Flags = packed struct(u6) {
    writable: bool = false,
    enumerable: bool = false,
    configurable: bool = false,
    accessor: bool = false,
    deleted: bool = false,
    padding: u1 = 0,

    pub fn data(writable: bool, enumerable: bool, configurable: bool) Flags {
        return .{
            .writable = writable,
            .enumerable = enumerable,
            .configurable = configurable,
        };
    }

    pub fn accessorFlags(enumerable: bool, configurable: bool) Flags {
        return .{
            .enumerable = enumerable,
            .configurable = configurable,
            .accessor = true,
        };
    }

    pub fn bits(self: Flags) u6 {
        return @bitCast(self);
    }

    pub fn fromBits(bits_value: u6) Flags {
        return @bitCast(bits_value);
    }
};

pub const Accessor = struct {
    getter: JSValue = JSValue.undefinedValue(),
    setter: JSValue = JSValue.undefinedValue(),
};

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

pub const Slot = union(enum) {
    data: JSValue,
    accessor: Accessor,
    auto_init: AutoInitRef,
    // QuickJS `JS_PROP_VARREF`: the property slot HOLDS the cell pointer
    // (qjs `pr->u.var_ref`). Reads/writes of such a property auto-deref
    // `cell.pvalue`. Used for top-level lexical (`let`/`const`) bindings on
    // the global lexical env object, shared by pointer with frame.var_refs.
    var_ref: *VarRef,
    deleted,

    pub inline fn dataValueForFastPath(self: Slot) ?JSValue {
        if (self != .data) return null;
        return self.data;
    }

    pub fn destroy(self: Slot, rt: anytype) void {
        switch (self) {
            .data => |value| value.free(rt),
            .accessor => |entry| {
                entry.getter.free(rt);
                entry.setter.free(rt);
            },
            // Auto-init metadata is owned by JSRuntime.auto_init_table and
            // released when the runtime is torn down.
            .auto_init => {},
            // The slot holds one ref on the cell (qjs add_property ref_count++);
            // release it (qjs free_property VARREF branch -> free_var_ref).
            .var_ref => |cell| cell.valueRef().free(rt),
            .deleted => {},
        }
    }

    pub fn dup(self: Slot) Slot {
        return switch (self) {
            .data => |value| .{ .data = value.dup() },
            .accessor => |entry| .{ .accessor = .{
                .getter = entry.getter.dup(),
                .setter = entry.setter.dup(),
            } },
            .auto_init => |id| .{ .auto_init = id },
            .var_ref => |cell| blk: {
                _ = cell.valueRef().dup();
                break :blk .{ .var_ref = cell };
            },
            .deleted => .deleted,
        };
    }
};

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
/// writable/enumerable/configurable/accessor/deleted flags live in the
/// owning object's shape (`shape.Property`), indexed 1:1 with this
/// array. Use `Object.propAtomAt` / `Object.propFlagsAt` to read the
/// metadata for an entry.
pub const Entry = struct {
    slot: Slot = .deleted,
};

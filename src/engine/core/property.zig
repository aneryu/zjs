const atom = @import("atom.zig");
const class = @import("class.zig");
const Value = @import("value.zig").Value;
const Runtime = @import("runtime.zig").Runtime;

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
    getter: Value = Value.undefinedValue(),
    setter: Value = Value.undefinedValue(),
};

pub const AutoInitKind = enum(u8) {
    native_function,
    assert,
    console,
    math_namespace,
    json_namespace,
    reflect_namespace,
    atomics_namespace,
    navigator,
    performance,
    test262_namespace,
    array_unscopables,
    cli_global,
    number_constant,
    int32_constant,
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
/// receive a fresh `Value`, and replace the slot with `.data`.
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
/// materialize without threading the Runtime through every prop-read
/// call site (zjs's `getProperty(self: Object, ...)` is reached by
/// 300+ callers; we want this change to be local).
pub const AutoInit = struct {
    name: []const u8,
    length: i32,
    rt: *Runtime,
    kind: AutoInitKind = .native_function,
    host_function_kind: i32 = 0,
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

pub const Slot = union(enum) {
    data: Value,
    accessor: Accessor,
    auto_init: AutoInit,
    deleted,

    pub fn destroy(self: Slot, rt: anytype) void {
        switch (self) {
            .data => |value| value.free(rt),
            .accessor => |entry| {
                entry.getter.free(rt);
                entry.setter.free(rt);
            },
            // `auto_init` is metadata-only (name is static lifetime,
            // length is an int, rt is a borrowed pointer). Nothing to free.
            .auto_init => {},
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
            .auto_init => |info| .{ .auto_init = info },
            .deleted => .deleted,
        };
    }
};

pub const Entry = struct {
    atom_id: atom.Atom = atom.null_atom,
    flags: Flags = .{},
    slot: Slot = .deleted,
};

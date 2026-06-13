const std = @import("std");
const Object = @import("object.zig").Object;
const JSValue = @import("value.zig").JSValue;
const JSContext = @import("context.zig").JSContext;
const global_slots = @import("global_slots.zig");
const class = @import("class.zig");
const ClassId = class.ClassId;

pub const ids = struct {
    pub const output = 1;
    pub const external_host = 119;
};

pub const ExternalCall = struct {
    ctx: *anyopaque,
    output: ?*std.Io.Writer,
    global: ?*Object,
    func_obj: *Object,
    this_value: JSValue,
    args: []const JSValue,
};

pub const ExternalCallFn = *const fn (ptr: *anyopaque, call: ExternalCall) anyerror!JSValue;
pub const ExternalFinalizer = *const fn (ptr: *anyopaque) void;

pub const ExternalRecord = struct {
    ptr: *anyopaque,
    call: ExternalCallFn,
    finalizer: ?ExternalFinalizer = null,
};

// --- Internal builtin records -----------------------------------------------
//
// QuickJS source map: JSCFunctionListEntry (quickjs.h) + JS_CallInternal's
// C-function dispatch. Builtins declare implementation+table side by side in
// `src/builtins/*`; `src/builtins/internal_table.zig` materializes the static
// per-domain record table at comptime, and `JSRuntime.internal_builtins`
// points at it so exec dispatches through `rt.internalBuiltinRecord(...)`
// with zero compile-time knowledge of individual builtins.

/// Per-call selector flags (QuickJS C-function cproto analogue). `constructor`
/// distinguishes the construct (`new X()`) path from a plain call: when set,
/// the record handler runs its construct branch (using `InternalCall.new_target`
/// as the resolved instance `[[Prototype]]`) instead of the call body.
pub const InternalCallFlags = struct {
    constructor: bool = false,
};

/// Argument pack for one internal-builtin invocation. Mirrors the exec-side
/// `HostCall` shape (ctx/output/global/globals/func_obj/this/args) plus the
/// `magic` selector from the record (JSCFunctionListEntry.magic analogue) and
/// the VM caller threading pair. The caller pair is exec's
/// (`?*const bytecode.Bytecode`, `?*Frame`) erased to opaque pointers because
/// core cannot name exec types; `exec/builtin_dispatch.zig` owns the typed
/// erase/recover helpers.
pub const InternalCall = struct {
    ctx: *JSContext,
    output: ?*std.Io.Writer = null,
    global: ?*Object = null,
    globals: []global_slots.Slot = &.{},
    func_obj: ?*Object = null,
    this_value: JSValue,
    args: []const JSValue,
    magic: u16 = 0,
    flags: InternalCallFlags = .{},
    /// Construct [[Prototype]] for the constructor record's construct branch
    /// (only meaningful when `flags.constructor` is set). See
    /// `InternalCallFlags` doc above.
    new_target: ?*Object = null,
    caller_function: ?*const anyopaque = null,
    caller_frame: ?*anyopaque = null,
};

/// Record implementations are declared with concrete error sets in builtins
/// and coerce to `anyerror` at the table boundary; the exec dispatch site
/// narrows back to its host error set (same contract as `ExternalCallFn`).
pub const InternalCallFn = *const fn (call: InternalCall) anyerror!JSValue;

/// One dispatchable builtin. Slots whose `call` is null are unoccupied
/// (unmigrated or gap ids); lookups treat them as missing.
pub const InternalRecord = struct {
    /// Spec `length` of the function (JSCFunctionListEntry.length analogue).
    length: u8 = 0,
    /// Selector forwarded to `call` so one implementation can serve several
    /// ids (JSCFunctionListEntry.magic analogue).
    magic: u16 = 0,
    /// True when the record may be invoked without a materialized function
    /// object (prepared-call eligibility: no func_obj/realm dependence).
    prepared_call_ok: bool = false,
    /// True when the record's `call` honors the construct (`new X()`) path:
    /// its handler branches on `InternalCall.flags.constructor` and uses
    /// `InternalCall.new_target` (the resolved instance prototype). The
    /// QuickJS `JS_CFUNC_constructor` cproto analogue. Construct dispatch
    /// (`exec/builtin_dispatch.callConstructRecord`) only invokes records with
    /// this set; other records report a miss so the caller falls through to
    /// its construct cascade.
    constructor: bool = false,
    call: ?InternalCallFn = null,
};

/// Declaration-side entry: what a builtins file exports per method. The
/// comptime table builder densifies these into `InternalRecord` slots indexed
/// by `id`, and the install path consumes `name`/`length`/`id` directly
/// (QuickJS declares the same data in its JSCFunctionListEntry arrays).
pub const InternalEntry = struct {
    name: []const u8,
    length: u8,
    /// Domain-local method id (the low part of the encoded native builtin id).
    id: u32,
    magic: u16 = 0,
    prepared_call_ok: bool = false,
    /// See `InternalRecord.constructor`: marks a construct-capable record so
    /// the construct dispatch path routes `new X()` here.
    constructor: bool = false,
    call: InternalCallFn,
};

// --- Builtin method-id enums ------------------------------------------------
//
// Domain-local method-id namespace: the low part of the encoded native builtin
// id (`function.nativeBuiltinId(domain, id)`), companion to `NativeBuiltinDomain`
// in `core/function.zig`. These enums are pure data shared by the VM (prepared
// gates + decoded-id comparison in exec) and the builtin dispatch/install side.
// They live in core so exec can reference ids without importing builtins;
// `src/builtins/*` re-exports each enum under its original name, so builtin
// dispatch code keeps using `StaticMethod.foo` unchanged. Enum *values* are
// load-bearing: they are baked into the comptime record tables and into already
// compiled bytecode's native-builtin ids, so they must never change here.
pub const builtin_method_ids = struct {
    pub const array = struct {
        pub const StaticMethod = enum(u32) {
            from = 1,
            is_array = 2,
            of = 3,
        };

        pub const PrototypeMethod = enum(u32) {
            to_string = 100,
            to_locale_string = 101,
            map = 102,
            filter = 103,
            reduce = 104,
            reduce_right = 105,
            for_each = 106,
            push = 107,
            pop = 108,
            shift = 109,
            unshift = 110,
            some = 111,
            every = 112,
            find = 113,
            find_index = 114,
            find_last = 115,
            find_last_index = 116,
            includes = 117,
            index_of = 118,
            last_index_of = 119,
            at = 120,
            copy_within = 121,
            fill = 122,
            slice = 123,
            splice = 124,
            join = 125,
            concat = 126,
            reverse = 127,
            sort = 128,
            flat = 129,
            flat_map = 130,
            to_reversed = 131,
            to_sorted = 132,
            to_spliced = 133,
            with_ = 134,
            keys = 135,
            values = 136,
            entries = 137,
        };
    };

    pub const buffer = struct {
        pub const StaticMethod = enum(u32) {
            is_view = 1,
        };

        pub const ConstructorMethod = enum(u32) {
            array_buffer = 901,
            shared_array_buffer = 902,
        };

        pub const ArrayBufferPrototypeMethod = enum(u32) {
            slice = 101,
            resize = 102,
            transfer = 103,
            transfer_to_fixed_length = 104,
            slice_to_immutable = 105,
            transfer_to_immutable = 106,
        };

        pub const SharedArrayBufferPrototypeMethod = enum(u32) {
            slice = 201,
            grow = 202,
        };

        pub const DataViewGetMethod = enum(u32) {
            int8 = 301,
            uint8 = 302,
            int16 = 303,
            uint16 = 304,
            int32 = 305,
            uint32 = 306,
            float16 = 307,
            float32 = 308,
            float64 = 309,
            big_int64 = 310,
            big_uint64 = 311,
        };

        pub const DataViewSetMethod = enum(u32) {
            int8 = 321,
            uint8 = 322,
            int16 = 323,
            uint16 = 324,
            int32 = 325,
            uint32 = 326,
            float16 = 327,
            float32 = 328,
            float64 = 329,
            big_int64 = 330,
            big_uint64 = 331,
        };

        pub const ArrayBufferAccessorMethod = enum(u32) {
            byte_length = 401,
            detached = 402,
            max_byte_length = 403,
            resizable = 404,
            immutable = 405,
        };

        pub const SharedArrayBufferAccessorMethod = enum(u32) {
            byte_length = 421,
            max_byte_length = 422,
            growable = 423,
        };

        pub const DataViewAccessorMethod = enum(u32) {
            buffer = 441,
            byte_length = 442,
            byte_offset = 443,
        };

        pub const TypedArrayAccessorMethod = enum(u32) {
            buffer = 461,
            byte_length = 462,
            byte_offset = 463,
            length = 464,
            to_string_tag = 465,
        };
    };

    pub const reflect = struct {
        pub const StaticMethod = enum(u32) {
            define_property = 1,
            get_own_property_descriptor = 2,
            delete_property = 3,
            get = 4,
            get_prototype_of = 5,
            set = 6,
            set_prototype_of = 7,
            is_extensible = 8,
            prevent_extensions = 9,
            has = 10,
            own_keys = 11,
            construct = 12,
            apply = 13,
            proxy_revocable = 14,
            proxy_revoke = 15,
        };
    };

    pub const error_object = struct {
        pub const PrototypeMethod = enum(u32) {
            to_string = 1,
            stack_getter = 2,
            stack_setter = 3,
        };
    };

    pub const collection = struct {
        pub const PrototypeMethod = enum(u32) {
            set = 1,
            get = 2,
            has = 3,
            delete = 4,
            clear = 5,
            add = 6,
            keys = 7,
            values = 8,
            entries = 9,
            for_each = 10,
            get_or_insert = 11,
            get_or_insert_computed = 12,
            iterator_next = 13,
            size_getter = 14,
            difference = 15,
            intersection = 16,
            is_disjoint_from = 17,
            is_subset_of = 18,
            is_superset_of = 19,
            symmetric_difference = 20,
            union_ = 21,
        };
    };

    pub const date = struct {
        pub const StaticMethod = enum(u32) {
            utc = 1,
            parse = 2,
            now = 3,
        };

        pub const ConstructorMethod = enum(u32) {
            construct = 100,
        };
    };

    pub const iterator = struct {
        pub const AccessorMethod = enum(u32) {
            constructor_getter = 1,
            constructor_setter = 2,
            to_string_tag_getter = 3,
            to_string_tag_setter = 4,
        };

        pub const StaticMethod = enum(u32) {
            from = 101,
            concat = 102,
            zip = 103,
            zip_keyed = 104,
        };

        pub const PrototypeMethod = enum(u32) {
            to_array = 201,
            every = 202,
            find = 203,
            for_each = 204,
            reduce = 205,
            some = 206,
            map = 207,
            filter = 208,
            take = 209,
            drop = 210,
            flat_map = 211,
            dispose = 212,
        };
    };

    pub const number = struct {
        pub const StaticMethod = enum(u32) {
            parse_int = 1,
            parse_float = 2,
            is_nan = 3,
            is_finite = 4,
            is_integer = 5,
            is_safe_integer = 6,
        };

        pub const PrototypeMethod = enum(u32) {
            to_string = 101,
            to_locale_string = 102,
            to_fixed = 103,
            to_exponential = 104,
            to_precision = 105,
        };
    };

    pub const object = struct {
        pub const StaticMethod = enum(u32) {
            assign = 1,
            create = 2,
            define_property = 3,
            define_properties = 4,
            get_own_property_descriptor = 5,
            get_own_property_descriptors = 6,
            get_own_property_names = 7,
            get_own_property_symbols = 8,
            get_prototype_of = 9,
            has_own = 10,
            is_extensible = 11,
            keys = 12,
            prevent_extensions = 13,
            seal = 14,
            is_sealed = 15,
            is_frozen = 16,
            set_prototype_of = 17,
            values = 18,
            entries = 19,
            is = 20,
            freeze = 21,
            from_entries = 22,
            group_by = 23,
        };
    };

    pub const promise = struct {
        pub const LegacyStaticMethod = enum(u32) {
            resolve = 1,
            all = 2,
            race = 3,
            reject = 4,
            all_settled = 5,
            any = 6,
            try_ = 7,
            with_resolvers = 8,
        };
    };

    pub const regexp = struct {
        pub const StaticMethod = enum(u32) {
            escape = 1,
        };

        pub const ConstructorMethod = enum(u32) {
            construct = 1000,
        };

        pub const PrototypeMethod = enum(u32) {
            to_string = 101,
            test_ = 102,
            exec = 103,
            symbol_search = 104,
            symbol_match = 105,
            symbol_match_all = 106,
            symbol_replace = 107,
            symbol_split = 108,
            compile = 109,
        };

        pub const LegacyAccessorMethod = enum(u32) {
            get_input = 301,
            set_input = 302,
            get_last_match = 303,
            get_last_paren = 304,
            get_left_context = 305,
            get_right_context = 306,
            get_capture_1 = 311,
            get_capture_2 = 312,
            get_capture_3 = 313,
            get_capture_4 = 314,
            get_capture_5 = 315,
            get_capture_6 = 316,
            get_capture_7 = 317,
            get_capture_8 = 318,
            get_capture_9 = 319,
        };
    };

    pub const string = struct {
        pub const StaticMethod = enum(u32) {
            from_char_code = 1,
            from_code_point = 2,
            raw = 3,
        };

        pub const ConstructorMethod = enum(u32) {
            call = 4,
        };

        pub const PrototypeMethod = enum(u32) {
            char_at = 100,
            substring = 101,
            to_upper_case = 102,
            to_lower_case = 103,
            index_of = 104,
            includes = 105,
            starts_with = 106,
            ends_with = 107,
            trim = 108,
            concat = 110,
            trim_start = 121,
            trim_end = 122,
            split = 127,
            last_index_of = 128,
            char_code_at = 129,
            at = 130,
            code_point_at = 131,
            slice = 132,
            repeat = 133,
            pad_start = 134,
            pad_end = 135,
            locale_compare = 136,
            normalize = 137,
            is_well_formed = 138,
            to_well_formed = 139,
            search = 140,
            match = 141,
            replace_all = 142,
            match_all = 143,
            iterator_next = 144,
        };
    };
};

// --- Builtin method-id mapping helpers ---------------------------------------
//
// Pure name<->id / id->name(/kind) lookups over the `builtin_method_ids` enums
// above. These are engine metadata (the QuickJS analogue lives next to the
// JSCFunctionListEntry tables), consulted by the VM prepared-call gates and the
// decoded-id comparison in exec, by the legacy method-call cascade, and by the
// builtins property-install side. They depend only on `std`, the enum values
// here, and `class.ClassId`; they touch no runtime state (no install/registry
// table) and run no VM machinery, so they live in core and exec/builtins are
// clients. `src/builtins/*` re-exports each helper under its original name so
// the dispatch/install code keeps calling them unchanged. The returned *values*
// are load-bearing (baked into comptime record tables, compiled bytecode native
// ids, and the legacy method-id numbering) and must never change here.
pub const builtin_method_id_lookup = struct {
    pub const string = struct {
        const StaticMethod = builtin_method_ids.string.StaticMethod;
        const PrototypeMethod = builtin_method_ids.string.PrototypeMethod;

        pub const legacy_split_method_id: u32 = 27;
        pub const legacy_normalize_method_id: u32 = 37;
        pub const legacy_search_method_id: u32 = 40;
        pub const legacy_match_method_id: u32 = 41;
        pub const legacy_replace_all_method_id: u32 = 42;
        pub const legacy_match_all_method_id: u32 = 43;

        pub fn staticMethodId(name: []const u8) ?u32 {
            if (std.mem.eql(u8, name, "fromCharCode")) return @intFromEnum(StaticMethod.from_char_code);
            if (std.mem.eql(u8, name, "fromCodePoint")) return @intFromEnum(StaticMethod.from_code_point);
            if (std.mem.eql(u8, name, "raw")) return @intFromEnum(StaticMethod.raw);
            return null;
        }

        pub fn prototypeMethodId(name: []const u8) ?u32 {
            if (std.mem.eql(u8, name, "charAt")) return @intFromEnum(PrototypeMethod.char_at);
            if (std.mem.eql(u8, name, "substring")) return @intFromEnum(PrototypeMethod.substring);
            if (std.mem.eql(u8, name, "toUpperCase")) return @intFromEnum(PrototypeMethod.to_upper_case);
            if (std.mem.eql(u8, name, "toLocaleUpperCase")) return @intFromEnum(PrototypeMethod.to_upper_case);
            if (std.mem.eql(u8, name, "toLowerCase")) return @intFromEnum(PrototypeMethod.to_lower_case);
            if (std.mem.eql(u8, name, "toLocaleLowerCase")) return @intFromEnum(PrototypeMethod.to_lower_case);
            if (std.mem.eql(u8, name, "indexOf")) return @intFromEnum(PrototypeMethod.index_of);
            if (std.mem.eql(u8, name, "includes")) return @intFromEnum(PrototypeMethod.includes);
            if (std.mem.eql(u8, name, "startsWith")) return @intFromEnum(PrototypeMethod.starts_with);
            if (std.mem.eql(u8, name, "endsWith")) return @intFromEnum(PrototypeMethod.ends_with);
            if (std.mem.eql(u8, name, "trim")) return @intFromEnum(PrototypeMethod.trim);
            if (std.mem.eql(u8, name, "concat")) return @intFromEnum(PrototypeMethod.concat);
            if (std.mem.eql(u8, name, "lastIndexOf")) return @intFromEnum(PrototypeMethod.last_index_of);
            if (std.mem.eql(u8, name, "charCodeAt")) return @intFromEnum(PrototypeMethod.char_code_at);
            if (std.mem.eql(u8, name, "at")) return @intFromEnum(PrototypeMethod.at);
            if (std.mem.eql(u8, name, "codePointAt")) return @intFromEnum(PrototypeMethod.code_point_at);
            if (std.mem.eql(u8, name, "slice")) return @intFromEnum(PrototypeMethod.slice);
            if (std.mem.eql(u8, name, "repeat")) return @intFromEnum(PrototypeMethod.repeat);
            if (std.mem.eql(u8, name, "padStart")) return @intFromEnum(PrototypeMethod.pad_start);
            if (std.mem.eql(u8, name, "padEnd")) return @intFromEnum(PrototypeMethod.pad_end);
            if (std.mem.eql(u8, name, "localeCompare")) return @intFromEnum(PrototypeMethod.locale_compare);
            if (std.mem.eql(u8, name, "normalize")) return @intFromEnum(PrototypeMethod.normalize);
            if (std.mem.eql(u8, name, "isWellFormed")) return @intFromEnum(PrototypeMethod.is_well_formed);
            if (std.mem.eql(u8, name, "toWellFormed")) return @intFromEnum(PrototypeMethod.to_well_formed);
            if (std.mem.eql(u8, name, "trimStart")) return @intFromEnum(PrototypeMethod.trim_start);
            if (std.mem.eql(u8, name, "trimEnd")) return @intFromEnum(PrototypeMethod.trim_end);
            if (std.mem.eql(u8, name, "split")) return @intFromEnum(PrototypeMethod.split);
            if (std.mem.eql(u8, name, "search")) return @intFromEnum(PrototypeMethod.search);
            if (std.mem.eql(u8, name, "match")) return @intFromEnum(PrototypeMethod.match);
            if (std.mem.eql(u8, name, "matchAll")) return @intFromEnum(PrototypeMethod.match_all);
            if (std.mem.eql(u8, name, "replaceAll")) return @intFromEnum(PrototypeMethod.replace_all);
            return null;
        }

        pub fn decodePrototypeMethodId(id: u32) ?u32 {
            return switch (id) {
                @intFromEnum(PrototypeMethod.char_at) => 0,
                @intFromEnum(PrototypeMethod.substring) => 1,
                @intFromEnum(PrototypeMethod.to_upper_case) => 2,
                @intFromEnum(PrototypeMethod.to_lower_case) => 3,
                @intFromEnum(PrototypeMethod.index_of) => 4,
                @intFromEnum(PrototypeMethod.includes) => 5,
                @intFromEnum(PrototypeMethod.starts_with) => 6,
                @intFromEnum(PrototypeMethod.ends_with) => 7,
                @intFromEnum(PrototypeMethod.trim) => 8,
                @intFromEnum(PrototypeMethod.concat) => 10,
                @intFromEnum(PrototypeMethod.trim_start) => 21,
                @intFromEnum(PrototypeMethod.trim_end) => 22,
                @intFromEnum(PrototypeMethod.split) => legacy_split_method_id,
                @intFromEnum(PrototypeMethod.last_index_of) => 28,
                @intFromEnum(PrototypeMethod.char_code_at) => 29,
                @intFromEnum(PrototypeMethod.at) => 30,
                @intFromEnum(PrototypeMethod.code_point_at) => 31,
                @intFromEnum(PrototypeMethod.slice) => 32,
                @intFromEnum(PrototypeMethod.repeat) => 33,
                @intFromEnum(PrototypeMethod.pad_start) => 34,
                @intFromEnum(PrototypeMethod.pad_end) => 35,
                @intFromEnum(PrototypeMethod.locale_compare) => 36,
                @intFromEnum(PrototypeMethod.normalize) => legacy_normalize_method_id,
                @intFromEnum(PrototypeMethod.is_well_formed) => 38,
                @intFromEnum(PrototypeMethod.to_well_formed) => 39,
                @intFromEnum(PrototypeMethod.search) => legacy_search_method_id,
                @intFromEnum(PrototypeMethod.match) => legacy_match_method_id,
                @intFromEnum(PrototypeMethod.replace_all) => legacy_replace_all_method_id,
                @intFromEnum(PrototypeMethod.match_all) => legacy_match_all_method_id,
                else => null,
            };
        }
    };

    pub const array = struct {
        const PrototypeMethod = builtin_method_ids.array.PrototypeMethod;

        pub fn decodePrototypeMethodId(id: u32) ?u32 {
            return switch (id) {
                @intFromEnum(PrototypeMethod.filter) => 1,
                @intFromEnum(PrototypeMethod.reduce) => 2,
                @intFromEnum(PrototypeMethod.some) => 4,
                @intFromEnum(PrototypeMethod.every) => 5,
                @intFromEnum(PrototypeMethod.index_of) => 6,
                @intFromEnum(PrototypeMethod.includes) => 7,
                @intFromEnum(PrototypeMethod.last_index_of) => 8,
                @intFromEnum(PrototypeMethod.at) => 9,
                @intFromEnum(PrototypeMethod.slice) => 10,
                @intFromEnum(PrototypeMethod.splice) => 11,
                @intFromEnum(PrototypeMethod.reverse) => 12,
                @intFromEnum(PrototypeMethod.push) => 13,
                @intFromEnum(PrototypeMethod.pop) => 14,
                @intFromEnum(PrototypeMethod.concat) => 15,
                @intFromEnum(PrototypeMethod.sort) => 16,
                @intFromEnum(PrototypeMethod.values) => 17,
                @intFromEnum(PrototypeMethod.keys) => 18,
                @intFromEnum(PrototypeMethod.entries) => 19,
                else => null,
            };
        }
    };

    pub const collection = struct {
        const StaticMethod = builtin_method_ids.collection.StaticMethod;
        const PrototypeMethod = builtin_method_ids.collection.PrototypeMethod;

        pub fn prototypeMethodId(name: []const u8) ?u32 {
            if (std.mem.eql(u8, name, "set")) return @intFromEnum(PrototypeMethod.set);
            if (std.mem.eql(u8, name, "get")) return @intFromEnum(PrototypeMethod.get);
            if (std.mem.eql(u8, name, "has")) return @intFromEnum(PrototypeMethod.has);
            if (std.mem.eql(u8, name, "delete")) return @intFromEnum(PrototypeMethod.delete);
            if (std.mem.eql(u8, name, "clear")) return @intFromEnum(PrototypeMethod.clear);
            if (std.mem.eql(u8, name, "add")) return @intFromEnum(PrototypeMethod.add);
            if (std.mem.eql(u8, name, "keys")) return @intFromEnum(PrototypeMethod.keys);
            if (std.mem.eql(u8, name, "values")) return @intFromEnum(PrototypeMethod.values);
            if (std.mem.eql(u8, name, "entries")) return @intFromEnum(PrototypeMethod.entries);
            if (std.mem.eql(u8, name, "forEach")) return @intFromEnum(PrototypeMethod.for_each);
            if (std.mem.eql(u8, name, "getOrInsert")) return @intFromEnum(PrototypeMethod.get_or_insert);
            if (std.mem.eql(u8, name, "getOrInsertComputed")) return @intFromEnum(PrototypeMethod.get_or_insert_computed);
            if (std.mem.eql(u8, name, "next")) return @intFromEnum(PrototypeMethod.iterator_next);
            if (std.mem.eql(u8, name, "get size")) return @intFromEnum(PrototypeMethod.size_getter);
            if (std.mem.eql(u8, name, "difference")) return @intFromEnum(PrototypeMethod.difference);
            if (std.mem.eql(u8, name, "intersection")) return @intFromEnum(PrototypeMethod.intersection);
            if (std.mem.eql(u8, name, "isDisjointFrom")) return @intFromEnum(PrototypeMethod.is_disjoint_from);
            if (std.mem.eql(u8, name, "isSubsetOf")) return @intFromEnum(PrototypeMethod.is_subset_of);
            if (std.mem.eql(u8, name, "isSupersetOf")) return @intFromEnum(PrototypeMethod.is_superset_of);
            if (std.mem.eql(u8, name, "symmetricDifference")) return @intFromEnum(PrototypeMethod.symmetric_difference);
            if (std.mem.eql(u8, name, "union")) return @intFromEnum(PrototypeMethod.union_);
            return null;
        }

        fn legacyBasePrototypeMethodId(id: u32) ?u32 {
            return switch (id) {
                @intFromEnum(PrototypeMethod.set),
                @intFromEnum(PrototypeMethod.get),
                @intFromEnum(PrototypeMethod.has),
                @intFromEnum(PrototypeMethod.delete),
                @intFromEnum(PrototypeMethod.clear),
                @intFromEnum(PrototypeMethod.add),
                @intFromEnum(PrototypeMethod.keys),
                @intFromEnum(PrototypeMethod.values),
                @intFromEnum(PrototypeMethod.entries),
                @intFromEnum(PrototypeMethod.for_each),
                @intFromEnum(PrototypeMethod.get_or_insert),
                @intFromEnum(PrototypeMethod.get_or_insert_computed),
                => id,
                else => null,
            };
        }

        pub fn legacyClosureMethodId(name: []const u8) ?u32 {
            const id = prototypeMethodId(name) orelse return null;
            if (legacyBasePrototypeMethodId(id)) |method_id| return method_id;
            return switch (id) {
                @intFromEnum(PrototypeMethod.iterator_next) => id,
                else => null,
            };
        }

        pub fn fastPrototypeMethodIdForClass(class_id: ClassId, name: []const u8) ?u32 {
            const id = prototypeMethodId(name) orelse return null;
            return switch (class_id) {
                class.ids.map, class.ids.weakmap => switch (id) {
                    @intFromEnum(PrototypeMethod.set),
                    @intFromEnum(PrototypeMethod.get),
                    @intFromEnum(PrototypeMethod.has),
                    @intFromEnum(PrototypeMethod.delete),
                    => id,
                    else => null,
                },
                class.ids.set, class.ids.weakset => switch (id) {
                    @intFromEnum(PrototypeMethod.add),
                    @intFromEnum(PrototypeMethod.has),
                    @intFromEnum(PrototypeMethod.delete),
                    => id,
                    else => null,
                },
                else => null,
            };
        }
    };

    pub const date = struct {
        const StaticMethod = builtin_method_ids.date.StaticMethod;

        pub fn staticMethodId(name: []const u8) ?u32 {
            if (std.mem.eql(u8, name, "UTC")) return @intFromEnum(StaticMethod.utc);
            if (std.mem.eql(u8, name, "parse")) return @intFromEnum(StaticMethod.parse);
            if (std.mem.eql(u8, name, "now")) return @intFromEnum(StaticMethod.now);
            return null;
        }
    };

    pub const buffer = struct {
        const DataViewGetMethod = builtin_method_ids.buffer.DataViewGetMethod;
        const DataViewSetMethod = builtin_method_ids.buffer.DataViewSetMethod;
        const ArrayBufferAccessorMethod = builtin_method_ids.buffer.ArrayBufferAccessorMethod;
        const SharedArrayBufferAccessorMethod = builtin_method_ids.buffer.SharedArrayBufferAccessorMethod;
        const DataViewAccessorMethod = builtin_method_ids.buffer.DataViewAccessorMethod;
        const TypedArrayAccessorMethod = builtin_method_ids.buffer.TypedArrayAccessorMethod;

        pub fn dataViewGetMethodId(name: []const u8) ?u32 {
            if (std.mem.eql(u8, name, "getInt8")) return @intFromEnum(DataViewGetMethod.int8);
            if (std.mem.eql(u8, name, "getUint8")) return @intFromEnum(DataViewGetMethod.uint8);
            if (std.mem.eql(u8, name, "getInt16")) return @intFromEnum(DataViewGetMethod.int16);
            if (std.mem.eql(u8, name, "getUint16")) return @intFromEnum(DataViewGetMethod.uint16);
            if (std.mem.eql(u8, name, "getInt32")) return @intFromEnum(DataViewGetMethod.int32);
            if (std.mem.eql(u8, name, "getUint32")) return @intFromEnum(DataViewGetMethod.uint32);
            if (std.mem.eql(u8, name, "getFloat16")) return @intFromEnum(DataViewGetMethod.float16);
            if (std.mem.eql(u8, name, "getFloat32")) return @intFromEnum(DataViewGetMethod.float32);
            if (std.mem.eql(u8, name, "getFloat64")) return @intFromEnum(DataViewGetMethod.float64);
            if (std.mem.eql(u8, name, "getBigInt64")) return @intFromEnum(DataViewGetMethod.big_int64);
            if (std.mem.eql(u8, name, "getBigUint64")) return @intFromEnum(DataViewGetMethod.big_uint64);
            return null;
        }

        pub fn dataViewSetMethodId(name: []const u8) ?u32 {
            if (std.mem.eql(u8, name, "setInt8")) return @intFromEnum(DataViewSetMethod.int8);
            if (std.mem.eql(u8, name, "setUint8")) return @intFromEnum(DataViewSetMethod.uint8);
            if (std.mem.eql(u8, name, "setInt16")) return @intFromEnum(DataViewSetMethod.int16);
            if (std.mem.eql(u8, name, "setUint16")) return @intFromEnum(DataViewSetMethod.uint16);
            if (std.mem.eql(u8, name, "setInt32")) return @intFromEnum(DataViewSetMethod.int32);
            if (std.mem.eql(u8, name, "setUint32")) return @intFromEnum(DataViewSetMethod.uint32);
            if (std.mem.eql(u8, name, "setFloat16")) return @intFromEnum(DataViewSetMethod.float16);
            if (std.mem.eql(u8, name, "setFloat32")) return @intFromEnum(DataViewSetMethod.float32);
            if (std.mem.eql(u8, name, "setFloat64")) return @intFromEnum(DataViewSetMethod.float64);
            if (std.mem.eql(u8, name, "setBigInt64")) return @intFromEnum(DataViewSetMethod.big_int64);
            if (std.mem.eql(u8, name, "setBigUint64")) return @intFromEnum(DataViewSetMethod.big_uint64);
            return null;
        }

        pub fn arrayBufferAccessorMethodId(name: []const u8) ?u32 {
            if (std.mem.eql(u8, name, "byteLength")) return @intFromEnum(ArrayBufferAccessorMethod.byte_length);
            if (std.mem.eql(u8, name, "detached")) return @intFromEnum(ArrayBufferAccessorMethod.detached);
            if (std.mem.eql(u8, name, "maxByteLength")) return @intFromEnum(ArrayBufferAccessorMethod.max_byte_length);
            if (std.mem.eql(u8, name, "resizable")) return @intFromEnum(ArrayBufferAccessorMethod.resizable);
            if (std.mem.eql(u8, name, "immutable")) return @intFromEnum(ArrayBufferAccessorMethod.immutable);
            return null;
        }

        pub fn sharedArrayBufferAccessorMethodId(name: []const u8) ?u32 {
            if (std.mem.eql(u8, name, "byteLength")) return @intFromEnum(SharedArrayBufferAccessorMethod.byte_length);
            if (std.mem.eql(u8, name, "maxByteLength")) return @intFromEnum(SharedArrayBufferAccessorMethod.max_byte_length);
            if (std.mem.eql(u8, name, "growable")) return @intFromEnum(SharedArrayBufferAccessorMethod.growable);
            return null;
        }

        pub fn dataViewAccessorMethodId(name: []const u8) ?u32 {
            if (std.mem.eql(u8, name, "buffer")) return @intFromEnum(DataViewAccessorMethod.buffer);
            if (std.mem.eql(u8, name, "byteLength")) return @intFromEnum(DataViewAccessorMethod.byte_length);
            if (std.mem.eql(u8, name, "byteOffset")) return @intFromEnum(DataViewAccessorMethod.byte_offset);
            return null;
        }

        pub fn typedArrayAccessorMethodId(name: []const u8) ?u32 {
            if (std.mem.eql(u8, name, "buffer")) return @intFromEnum(TypedArrayAccessorMethod.buffer);
            if (std.mem.eql(u8, name, "byteLength")) return @intFromEnum(TypedArrayAccessorMethod.byte_length);
            if (std.mem.eql(u8, name, "byteOffset")) return @intFromEnum(TypedArrayAccessorMethod.byte_offset);
            if (std.mem.eql(u8, name, "length")) return @intFromEnum(TypedArrayAccessorMethod.length);
            if (std.mem.eql(u8, name, "[Symbol.toStringTag]")) return @intFromEnum(TypedArrayAccessorMethod.to_string_tag);
            return null;
        }

        pub fn dataViewGetKindFromRecordId(id: u32) ?u32 {
            return switch (id) {
                @intFromEnum(DataViewGetMethod.int8) => 1,
                @intFromEnum(DataViewGetMethod.uint8) => 2,
                @intFromEnum(DataViewGetMethod.int16) => 3,
                @intFromEnum(DataViewGetMethod.uint16) => 4,
                @intFromEnum(DataViewGetMethod.int32) => 5,
                @intFromEnum(DataViewGetMethod.uint32) => 6,
                @intFromEnum(DataViewGetMethod.float16) => 11,
                @intFromEnum(DataViewGetMethod.float32) => 7,
                @intFromEnum(DataViewGetMethod.float64) => 8,
                @intFromEnum(DataViewGetMethod.big_int64) => 9,
                @intFromEnum(DataViewGetMethod.big_uint64) => 10,
                else => null,
            };
        }

        pub fn dataViewSetKindFromRecordId(id: u32) ?u32 {
            return switch (id) {
                @intFromEnum(DataViewSetMethod.int8) => 1,
                @intFromEnum(DataViewSetMethod.uint8) => 2,
                @intFromEnum(DataViewSetMethod.int16) => 3,
                @intFromEnum(DataViewSetMethod.uint16) => 4,
                @intFromEnum(DataViewSetMethod.int32) => 5,
                @intFromEnum(DataViewSetMethod.uint32) => 6,
                @intFromEnum(DataViewSetMethod.float16) => 11,
                @intFromEnum(DataViewSetMethod.float32) => 7,
                @intFromEnum(DataViewSetMethod.float64) => 8,
                @intFromEnum(DataViewSetMethod.big_int64) => 9,
                @intFromEnum(DataViewSetMethod.big_uint64) => 10,
                else => null,
            };
        }

        pub fn arrayBufferAccessorNameFromRecordId(id: u32) ?[]const u8 {
            return switch (id) {
                @intFromEnum(ArrayBufferAccessorMethod.byte_length) => "byteLength",
                @intFromEnum(ArrayBufferAccessorMethod.detached) => "detached",
                @intFromEnum(ArrayBufferAccessorMethod.max_byte_length) => "maxByteLength",
                @intFromEnum(ArrayBufferAccessorMethod.resizable) => "resizable",
                @intFromEnum(ArrayBufferAccessorMethod.immutable) => "immutable",
                else => null,
            };
        }

        pub fn sharedArrayBufferAccessorNameFromRecordId(id: u32) ?[]const u8 {
            return switch (id) {
                @intFromEnum(SharedArrayBufferAccessorMethod.byte_length) => "byteLength",
                @intFromEnum(SharedArrayBufferAccessorMethod.max_byte_length) => "maxByteLength",
                @intFromEnum(SharedArrayBufferAccessorMethod.growable) => "growable",
                else => null,
            };
        }

        pub fn dataViewAccessorNameFromRecordId(id: u32) ?[]const u8 {
            return switch (id) {
                @intFromEnum(DataViewAccessorMethod.buffer) => "buffer",
                @intFromEnum(DataViewAccessorMethod.byte_length) => "byteLength",
                @intFromEnum(DataViewAccessorMethod.byte_offset) => "byteOffset",
                else => null,
            };
        }

        pub fn typedArrayAccessorNameFromRecordId(id: u32) ?[]const u8 {
            return switch (id) {
                @intFromEnum(TypedArrayAccessorMethod.buffer) => "buffer",
                @intFromEnum(TypedArrayAccessorMethod.byte_length) => "byteLength",
                @intFromEnum(TypedArrayAccessorMethod.byte_offset) => "byteOffset",
                @intFromEnum(TypedArrayAccessorMethod.length) => "length",
                @intFromEnum(TypedArrayAccessorMethod.to_string_tag) => "[Symbol.toStringTag]",
                else => null,
            };
        }
    };
};

test "builtin method-id helpers preserve load-bearing id values" {
    const testing = std.testing;
    const lookup = builtin_method_id_lookup;

    // string: native enum id vs legacy decoded id are distinct numberings.
    try testing.expectEqual(@as(?u32, 127), lookup.string.prototypeMethodId("split"));
    try testing.expectEqual(@as(?u32, lookup.string.legacy_split_method_id), lookup.string.decodePrototypeMethodId(127));
    try testing.expectEqual(@as(u32, 27), lookup.string.legacy_split_method_id);
    try testing.expectEqual(@as(u32, 43), lookup.string.legacy_match_all_method_id);
    try testing.expectEqual(@as(?u32, 1), lookup.string.staticMethodId("fromCharCode"));
    try testing.expectEqual(@as(?u32, null), lookup.string.prototypeMethodId("nope"));

    // array: decode maps native id -> legacy id.
    try testing.expectEqual(@as(?u32, 13), lookup.array.decodePrototypeMethodId(@intFromEnum(builtin_method_ids.array.PrototypeMethod.push)));
    try testing.expectEqual(@as(?u32, null), lookup.array.decodePrototypeMethodId(0));

    // collection: class-keyed fast-path filter.
    try testing.expectEqual(lookup.collection.prototypeMethodId("get"), lookup.collection.fastPrototypeMethodIdForClass(class.ids.map, "get"));
    try testing.expectEqual(@as(?u32, null), lookup.collection.fastPrototypeMethodIdForClass(class.ids.set, "get"));
    try testing.expect(lookup.collection.legacyClosureMethodId("set") != null);

    // date.
    try testing.expectEqual(@as(?u32, null), lookup.date.staticMethodId("nope"));
    try testing.expect(lookup.date.staticMethodId("now") != null);

    // buffer: record-id round trips.
    const get_int8 = lookup.buffer.dataViewGetMethodId("getInt8").?;
    try testing.expectEqual(@as(u32, 301), get_int8);
    try testing.expectEqual(@as(?u32, 1), lookup.buffer.dataViewGetKindFromRecordId(get_int8));
    try testing.expectEqualStrings("byteLength", lookup.buffer.arrayBufferAccessorNameFromRecordId(401).?);
    try testing.expectEqual(@as(?u32, 465), lookup.buffer.typedArrayAccessorMethodId("[Symbol.toStringTag]"));
}

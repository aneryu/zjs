//! Comptime aggregation of the per-class internal-builtin record tables.
//!
//! QuickJS source map: the js_*_funcs JSCFunctionListEntry arrays in
//! quickjs.c. Builtins are a compile-time closed set, so the dispatch table
//! is materialized statically here (no runtime registration like the
//! external-host registry) and `registry.installStandardGlobals` points
//! `JSRuntime.internal_builtins` at it. Layout: outer index is the
//! `NativeBuiltinDomain` enum value (slot 0 unused), inner index the
//! domain-local method id; unoccupied slots have `call == null`.

const core = @import("../core/root.zig");
const array = @import("array.zig");
const boolean = @import("boolean.zig");
const buffer = @import("buffer.zig");
const collection = @import("collection.zig");
const date = @import("date.zig");
const error_object = @import("error.zig");
const function = @import("function.zig");
const iterator = @import("iterator.zig");
const json = @import("json.zig");
const math = @import("math.zig");
const number = @import("number.zig");
const object = @import("object.zig");
const reflect_proxy = @import("reflect_proxy.zig");
const regexp = @import("regexp.zig");
const string = @import("string.zig");
const symbol = @import("symbol.zig");
const uri = @import("uri.zig");

const InternalEntry = core.host_function.InternalEntry;
const InternalRecord = core.host_function.InternalRecord;
const NativeBuiltinDomain = core.function.NativeBuiltinDomain;

const domain_count = count: {
    var max_value: usize = 0;
    for (@typeInfo(NativeBuiltinDomain).@"enum".fields) |field| {
        max_value = @max(max_value, field.value);
    }
    break :count max_value + 1;
};

fn denseRecords(comptime entries: []const InternalEntry) []const InternalRecord {
    comptime {
        var max_id: u32 = 0;
        for (entries) |entry| max_id = @max(max_id, entry.id);
        var records = [_]InternalRecord{.{}} ** (max_id + 1);
        for (entries) |entry| {
            if (entry.id == 0) @compileError("internal builtin id 0 is reserved");
            if (records[entry.id].call != null) @compileError("duplicate internal builtin id: " ++ entry.name);
            records[entry.id] = .{
                .length = entry.length,
                .magic = entry.magic,
                .prepared_call_ok = entry.prepared_call_ok,
                .constructor = entry.constructor,
                .call = entry.call,
            };
        }
        const frozen = records;
        return &frozen;
    }
}

/// The `.primitive` domain is shared across the five wrapper primitives, so
/// its records are assembled from the per-class slices (boolean.zig owns the
/// Boolean and the generic Number/BigInt/String prototype entries; symbol.zig
/// owns the Symbol ones). Ids are the `class_tag * 10 + method` encoding from
/// `exec/object_ops.qjsPrimitivePrototypeMethod`.
const primitive_entries = boolean.boolean_entries ++ boolean.shared_entries ++ symbol.symbol_entries;

/// The static table `JSRuntime.internal_builtins` points at. Migrated
/// classes contribute their entry arrays here; everything else keeps the
/// transitional enum dispatch in exec until its Phase 6 checkpoint.
pub const table: [domain_count][]const InternalRecord = build: {
    var domains = [_][]const InternalRecord{&.{}} ** domain_count;
    domains[@intFromEnum(NativeBuiltinDomain.math)] = denseRecords(&math.internal_entries);
    domains[@intFromEnum(NativeBuiltinDomain.json)] = denseRecords(&json.internal_entries);
    domains[@intFromEnum(NativeBuiltinDomain.uri)] = denseRecords(&uri.internal_entries);
    domains[@intFromEnum(NativeBuiltinDomain.number)] = denseRecords(&number.internal_entries);
    domains[@intFromEnum(NativeBuiltinDomain.date)] = denseRecords(&date.internal_entries);
    domains[@intFromEnum(NativeBuiltinDomain.error_object)] = denseRecords(&error_object.internal_entries);
    domains[@intFromEnum(NativeBuiltinDomain.function)] = denseRecords(&function.internal_entries);
    domains[@intFromEnum(NativeBuiltinDomain.primitive)] = denseRecords(&primitive_entries);
    domains[@intFromEnum(NativeBuiltinDomain.iterator)] = denseRecords(&iterator.internal_entries);
    domains[@intFromEnum(NativeBuiltinDomain.collection)] = denseRecords(&collection.internal_entries);
    domains[@intFromEnum(NativeBuiltinDomain.reflect)] = denseRecords(&reflect_proxy.internal_entries);
    domains[@intFromEnum(NativeBuiltinDomain.buffer)] = denseRecords(&buffer.internal_entries);
    domains[@intFromEnum(NativeBuiltinDomain.string)] = denseRecords(&string.internal_entries);
    domains[@intFromEnum(NativeBuiltinDomain.object)] = denseRecords(&object.internal_entries);
    domains[@intFromEnum(NativeBuiltinDomain.array)] = denseRecords(&array.internal_entries);
    domains[@intFromEnum(NativeBuiltinDomain.regexp)] = denseRecords(&regexp.internal_entries);
    break :build domains;
};

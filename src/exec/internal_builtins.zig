//! Comptime aggregation of the per-class internal-builtin record tables.
//!
//! QuickJS source map: the js_*_funcs JSCFunctionListEntry arrays in
//! quickjs.c. Standard natives are a compile-time closed set, so the dispatch table
//! is materialized statically here (no runtime registration like the
//! external-host registry) and `standard_globals.installStandardGlobals` points
//! `JSRuntime.internal_builtins` at it. Layout: outer index is the
//! `NativeBuiltinDomain` enum value (slot 0 unused), inner index the
//! domain-local method id; unoccupied slots have `native_function == null`.

const std = @import("std");
const core = @import("../core/root.zig");
const array = @import("array_builtin_ops.zig");
const atomics = @import("atomics_ops.zig");
const buffer = @import("buffer_ops.zig");
const collection = @import("collection_ops.zig");
const date = @import("date_ops.zig");
const error_object = @import("error_ops.zig");
const function = @import("function_ops.zig");
const iterator = @import("iterator_builtin_ops.zig");
const json = @import("json_ops.zig");
const math = @import("math_ops.zig");
const number = @import("number_ops.zig");
const object = @import("object_builtin_ops.zig");
const performance = @import("performance_ops.zig");
const primitive = @import("primitive_ops.zig");
const promise = @import("promise_builtin_ops.zig");
const reflect_proxy = @import("reflect_proxy_ops.zig");
const regexp = @import("regexp_ops.zig");
const string = @import("string_builtin_ops.zig");
const uri = @import("uri_ops.zig");

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
        @setEvalBranchQuota(10_000);
        var max_id: u32 = 0;
        for (entries) |entry| max_id = @max(max_id, entry.id);
        var records = [_]InternalRecord{.{}} ** (max_id + 1);
        for (entries) |entry| {
            if (entry.id == 0) @compileError("internal builtin id 0 is reserved");
            if (records[entry.id].hasCallable()) @compileError("duplicate internal builtin id: " ++ entry.name);
            const native_function = entry.native_function orelse @compileError("native cproto entry missing function: " ++ entry.name);
            if (std.meta.activeTag(native_function) != entry.cproto) {
                @compileError("native function tag does not match cproto: " ++ entry.name);
            }
            if (entry.fallback_function != null and entry.cproto != .f_f and entry.cproto != .f_f_f) {
                @compileError("only numeric cproto entries may set a coercion fallback: " ++ entry.name);
            }
            records[entry.id] = .{
                .length = entry.length,
                .magic = entry.magic,
                .forwards_call = entry.forwards_call,
                .cproto = entry.cproto,
                .native_function = entry.native_function,
                .fallback_function = entry.fallback_function,
            };
        }
        const frozen = records;
        return &frozen;
    }
}

/// The `.primitive` domain is shared across the five wrapper primitives. Ids are
/// the `class_tag * 10 + method` encoding from
/// `exec/object_ops.qjsPrimitivePrototypeMethod`.
const primitive_entries = primitive.boolean_entries ++ primitive.shared_entries ++ primitive.symbol_entries;

/// The static table `JSRuntime.internal_builtins` points at. Every standard
/// native domain contributes its record entries here; exec owns both the
/// table and the JS-visible operation implementations it dispatches to.
pub const table: [domain_count][]const InternalRecord = build: {
    var domains = [_][]const InternalRecord{&.{}} ** domain_count;
    domains[@intFromEnum(NativeBuiltinDomain.math)] = denseRecords(&math.internal_entries);
    domains[@intFromEnum(NativeBuiltinDomain.performance)] = denseRecords(&performance.internal_entries);
    domains[@intFromEnum(NativeBuiltinDomain.json)] = denseRecords(&json.internal_entries);
    domains[@intFromEnum(NativeBuiltinDomain.uri)] = denseRecords(&uri.internal_entries);
    domains[@intFromEnum(NativeBuiltinDomain.number)] = denseRecords(&number.internal_entries);
    domains[@intFromEnum(NativeBuiltinDomain.date)] = denseRecords(&date.internal_entries);
    domains[@intFromEnum(NativeBuiltinDomain.error_object)] = denseRecords(&error_object.internal_entries);
    domains[@intFromEnum(NativeBuiltinDomain.function)] = denseRecords(&function.internal_entries);
    domains[@intFromEnum(NativeBuiltinDomain.primitive)] = denseRecords(&primitive_entries);
    domains[@intFromEnum(NativeBuiltinDomain.promise)] = denseRecords(&promise.internal_entries);
    domains[@intFromEnum(NativeBuiltinDomain.atomics)] = denseRecords(&atomics.internal_entries);
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

test "Promise.resolve has an internal record handler" {
    const testing = @import("std").testing;
    const records = table[@intFromEnum(NativeBuiltinDomain.promise)];
    const resolve_id = @intFromEnum(core.host_function.builtin_method_ids.promise.LegacyStaticMethod.resolve);
    try testing.expect(resolve_id < records.len);
    const record = if (resolve_id < records.len) records[resolve_id] else return error.TestUnexpectedResult;
    try testing.expect(record.native_function != null);
    try testing.expectEqual(core.host_function.NativeCProto.generic_magic, record.cproto);
    try testing.expectEqual(record.cproto, std.meta.activeTag(record.native_function.?));
}

test "Object constructor has a constructor-or-function internal record handler" {
    const testing = @import("std").testing;
    const records = table[@intFromEnum(NativeBuiltinDomain.object)];
    const call_id = @intFromEnum(core.host_function.builtin_method_ids.object.ConstructorMethod.call);
    try testing.expect(call_id < records.len);
    const record = records[call_id];
    try testing.expect(record.native_function != null);
    try testing.expect(record.isConstructor());
    try testing.expectEqual(core.host_function.NativeCProto.constructor_or_func_magic, record.cproto);
    try testing.expectEqual(record.cproto, std.meta.activeTag(record.native_function.?));
}

test "every occupied standard native record has one matching typed payload" {
    const testing = std.testing;
    for (table) |records| {
        for (records) |record| {
            const native = record.native_function orelse continue;
            try testing.expectEqual(record.cproto, std.meta.activeTag(native));
            if (record.fallback_function != null) {
                try testing.expect(record.cproto == .f_f or record.cproto == .f_f_f);
            }
        }
    }
}

test "every engine-owned standard native domain contributes a record table" {
    const testing = std.testing;
    inline for (@typeInfo(NativeBuiltinDomain).@"enum".fields) |field| {
        const domain: NativeBuiltinDomain = @enumFromInt(field.value);
        if (domain == .host) continue;
        try testing.expect(table[field.value].len != 0);
    }
}

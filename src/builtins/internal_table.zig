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
const array = @import("../exec/array_builtin_ops.zig");
const buffer = @import("../exec/buffer_ops.zig");
const collection = @import("../exec/collection_ops.zig");
const date = @import("../exec/date_ops.zig");
const error_object = @import("../exec/error_ops.zig");
const function = @import("../exec/function_ops.zig");
const iterator = @import("../exec/iterator_builtin_ops.zig");
const json = @import("../exec/json_ops.zig");
const math = @import("../exec/math_ops.zig");
const number = @import("../exec/number_ops.zig");
const object = @import("../exec/object_builtin_ops.zig");
const primitive = @import("../exec/primitive_ops.zig");
const promise = @import("../exec/promise_builtin_ops.zig");
const reflect_proxy = @import("../exec/reflect_proxy_ops.zig");
const regexp = @import("../exec/regexp_ops.zig");
const string = @import("../exec/string_builtin_ops.zig");
const uri = @import("../exec/uri_ops.zig");

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
            if (entry.cproto == .zjs_internal_call) {
                if (entry.call == null) @compileError("zjs_internal_call entry missing call: " ++ entry.name);
            } else {
                if (entry.native_function == null) @compileError("native cproto entry missing function: " ++ entry.name);
                if (entry.call != null and entry.cproto != .f_f and entry.cproto != .f_f_f) {
                    @compileError("only numeric cproto entries may set a coercion fallback: " ++ entry.name);
                }
            }
            records[entry.id] = .{
                .length = entry.length,
                .magic = entry.magic,
                .prepared_call_ok = entry.prepared_call_ok,
                .constructor = entry.constructor,
                .forwards_call = entry.forwards_call,
                .cproto = entry.cproto,
                .call = entry.call,
                .native_function = entry.native_function,
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
    domains[@intFromEnum(NativeBuiltinDomain.promise)] = denseRecords(&promise.internal_entries);
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
    try testing.expect(record.call != null);
}

test "Object constructor has a constructor-or-function internal record handler" {
    const testing = @import("std").testing;
    const records = table[@intFromEnum(NativeBuiltinDomain.object)];
    const call_id = @intFromEnum(core.host_function.builtin_method_ids.object.ConstructorMethod.call);
    try testing.expect(call_id < records.len);
    const record = records[call_id];
    try testing.expect(record.call != null);
    try testing.expect(record.constructor);
}

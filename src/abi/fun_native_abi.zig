//! Fun Native ABI (FNABI) v1 schema — the single source of truth (FN-M0I).
//!
//! Every public ABI struct, constant, and id table lives here. The C header
//! `src/abi/fun_native_abi.h` is GENERATED from this file (`zig run
//! src/abi/gen_header.zig`); `src/tests/abi_layout.zig` pins the golden
//! layouts, verifies the checked-in header is fresh, and round-trips the
//! header through @cImport to prove C and Zig agree byte-for-byte.
//!
//! Authority: docs/fun-native-plugin-design.md v0.7 (§11-§15, §33 FN-M0I).
//! v1 target contract (§11.4): 64-bit pointers, little-endian, fixed-width
//! integers only, no implicit padding — compiler-inserted padding positions
//! must be explicit `reservedN` fields, zeroed by producers, verified zero
//! by the loader.

const std = @import("std");

// ---- ABI versions (§11.1/§11.2) -------------------------------------------

pub const plugin_abi_major: u16 = 1;
pub const plugin_abi_minor: u16 = 0;
pub const fast_call_abi: u16 = 1;

/// Value ABI (§11.3) is NOT numbered here: it is (representation-contract
/// version, `JSValue.abi_encoding_revision`) taken from the engine itself.
/// The layout test binds `ZjsJSValue` below to `src/core/value.zig` reality.
pub const value_abi_leaf: u16 = 0; // typed leaf plugins declare 0 (§11.3)

/// M0D ruling 2026-08-26: AsyncToken epochs are u64, per-Runtime, never
/// reused, no wraparound semantics (§21.2). Frozen with v1.
pub const async_epoch_bits: u16 = 64;

// ---- scalar typedefs (§12.1) ----------------------------------------------

pub const FunStatus = u32;
pub const FunExportKind = u16;
pub const FunCallKind = u16;
pub const FunSignatureId = u16;
pub const FunMarshalPolicyId = u16;

/// Generic code pointer; zjs casts to the exact prototype declared by the
/// descriptor before calling (§12.1). Never `void*`.
pub const FunNativeCodePtr = ?*const fn () callconv(.c) void;

// ---- status codes (§12.2) -------------------------------------------------

pub const status = struct {
    pub const ok: FunStatus = 0;
    pub const invalid_argument: FunStatus = 1;
    pub const out_of_memory: FunStatus = 2;
    pub const unsupported: FunStatus = 3;
    pub const cancelled: FunStatus = 4;
    pub const internal: FunStatus = 5;
};

// ---- export kinds (§12.3) -------------------------------------------------

pub const export_kind = struct {
    pub const function: FunExportKind = 1;
    pub const class: FunExportKind = 2;
    pub const const_i32: FunExportKind = 3;
    pub const const_f64: FunExportKind = 4;
    pub const const_bool: FunExportKind = 5;
    pub const const_utf8: FunExportKind = 6;
};

// ---- call kinds (§14) -----------------------------------------------------

pub const call_kind = struct {
    pub const leaf_static: FunCallKind = 1;
    pub const leaf_stateful: FunCallKind = 2;
    pub const leaf_method: FunCallKind = 3;
    pub const managed_fixed: FunCallKind = 4;
    pub const managed_generic: FunCallKind = 5;
    pub const async_entry: FunCallKind = 6;
};

// ---- marshal policies (§15.3) ---------------------------------------------

pub const marshal_policy = struct {
    /// The canonical v1 policy table of §15.3 (strict: no implicit
    /// ToBoolean/ToString; i32 accepts double-represented integral Numbers).
    pub const canonical: FunMarshalPolicyId = 1;
};

// ---- v1 signature table (§15.2) -------------------------------------------
// "实际 ID 由单一 schema 生成，zjs handler、C header、Zig SDK、ABI fixture
// 和 benchmark 共同消费，禁止手工复制。" Ids are frozen once v1 freezes;
// id 0 stays invalid/reserved.

pub const Signature = struct { name: [:0]const u8, id: FunSignatureId };

pub const signatures = [_]Signature{
    .{ .name = "VOID_TO_VOID", .id = 1 },
    .{ .name = "I32_TO_I32", .id = 2 },
    .{ .name = "I32_I32_TO_I32", .id = 3 },
    .{ .name = "F64_TO_F64", .id = 4 },
    .{ .name = "F64_F64_TO_F64", .id = 5 },
    .{ .name = "F64_TO_VOID", .id = 6 },
    .{ .name = "BOOL_TO_BOOL", .id = 7 },
    .{ .name = "STATE_F64_TO_VOID", .id = 8 },
    .{ .name = "SELF_TO_F64", .id = 9 },
    .{ .name = "SELF_F64_TO_VOID", .id = 10 },
    .{ .name = "SELF_F64_F64_TO_VOID", .id = 11 },
    .{ .name = "BUFFER_TO_VOID", .id = 12 },
    .{ .name = "STATE_BUFFER_TO_I32", .id = 13 },
    .{ .name = "SELF_BUFFER_TO_VOID", .id = 14 },
    .{ .name = "MANAGED_VALUE0", .id = 15 },
    .{ .name = "MANAGED_VALUE1", .id = 16 },
    .{ .name = "MANAGED_VALUE2", .id = 17 },
    .{ .name = "MANAGED_VALUE3", .id = 18 },
    .{ .name = "MANAGED_VALUE4", .id = 19 },
    .{ .name = "GENERIC", .id = 20 },
    .{ .name = "ASYNC_VALUE0", .id = 21 },
    .{ .name = "ASYNC_VALUE1", .id = 22 },
    .{ .name = "ASYNC_VALUE2", .id = 23 },
    .{ .name = "ASYNC_VALUE3", .id = 24 },
    .{ .name = "ASYNC_VALUE4", .id = 25 },
};

// ---- opaque ABI types (§13.1; M0I acceptance: defined or explicitly opaque)

pub const FunCallContextV1 = opaque {};
pub const FunAsyncTokenV1 = opaque {};
pub const FunBufferLeaseV1 = opaque {};
pub const FunPluginInitHostV1 = opaque {};
pub const FunManagedHostV1 = opaque {};
pub const FunAsyncHostV1 = opaque {};
pub const FunRuntimeTargetInfoV1 = opaque {};
pub const FunErrorSinkV1 = opaque {};
/// Class metadata carrier (§12.3); field-level contents are FN-M1B scope.
pub const FunClassDescriptorV1 = opaque {};

// ---- public structs (§12.1) -----------------------------------------------
// Field ORDER is normative. The C body tables in `c_struct_bodies` below are
// comptime-checked against these declarations: adding, removing, or
// reordering a Zig field without updating the C table fails the build.

pub const ZjsJSValue = extern struct {
    payload: u64,
    tag: i64,
};

pub const FunUtf8RefV1 = extern struct {
    data: ?[*]const u8,
    length: u32,
    reserved0: u32,
};

pub const FunFunctionDescriptorV1 = extern struct {
    struct_size: u32,
    call_kind: FunCallKind,
    signature: FunSignatureId,
    marshal_policy: FunMarshalPolicyId,
    reserved0: u16,
    flags: u32,
    target: FunNativeCodePtr,
};

pub const FunExportDescriptorV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    name: FunUtf8RefV1,
    kind: FunExportKind,
    metadata_kind: u16,
    reserved1: u32,
    metadata: ?*const anyopaque,
    metadata_size: u32,
    reserved2: u32,
};

pub const FunCreateInstanceFnV1 = ?*const fn (
    context: ?*const FunPluginInitContextV1,
    out_instance: ?*?*anyopaque,
) callconv(.c) FunStatus;

pub const FunShutdownFnV1 = ?*const fn (instance: ?*anyopaque) callconv(.c) void;

pub const FunPluginDescriptorV1 = extern struct {
    struct_size: u32,
    plugin_abi_major: u16,
    plugin_abi_minor: u16,
    fast_call_abi: u16,
    value_abi: u16,
    reserved0: u32,
    required_features: u64,
    optional_features: u64,
    package_name: FunUtf8RefV1,
    module_name: FunUtf8RefV1,
    build_id: FunUtf8RefV1,
    exports: ?[*]const FunExportDescriptorV1,
    export_count: u32,
    reserved1: u32,
    create_instance: FunCreateInstanceFnV1,
    begin_shutdown: FunShutdownFnV1,
    destroy_instance: FunShutdownFnV1,
};

pub const FunPluginInitContextV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    init_host: ?*const FunPluginInitHostV1,
    host_context: ?*anyopaque,
    target_info: ?*const FunRuntimeTargetInfoV1,
    error_sink: ?*const FunErrorSinkV1,
};

/// Structs exported to the C header, in emission order.
pub const public_structs = .{
    ZjsJSValue,
    FunUtf8RefV1,
    FunFunctionDescriptorV1,
    FunExportDescriptorV1,
    FunPluginDescriptorV1,
    FunPluginInitContextV1,
};

// ---- C header generation ---------------------------------------------------
// Layout truth is the Zig declaration; the C spelling of each field is listed
// here and locked to the Zig field order by a comptime name check. Layout
// equality of the emitted C is proven separately by the @cImport round-trip
// in src/tests/abi_layout.zig, so a wrong C type here cannot survive CI.

const CField = struct { name: [:0]const u8, c_type: [:0]const u8 };

fn cBody(comptime T: type, comptime c_name: []const u8, comptime fields: []const CField) []const u8 {
    const info = @typeInfo(T).@"struct";
    if (info.fields.len != fields.len)
        @compileError(c_name ++ ": C field table count differs from the Zig struct");
    comptime var body: []const u8 = "typedef struct " ++ c_name ++ " {\n";
    inline for (info.fields, fields) |zf, cf| {
        if (!std.mem.eql(u8, zf.name, cf.name))
            @compileError(c_name ++ "." ++ cf.name ++ ": C field table order/name differs from the Zig struct (" ++ zf.name ++ ")");
        body = body ++ "    " ++ cf.c_type ++ " " ++ cf.name ++ ";\n";
    }
    return body ++ "} " ++ c_name ++ ";\n\n";
}

fn defineU(comptime name: []const u8, comptime v: u64) []const u8 {
    return "#define " ++ name ++ " " ++ std.fmt.comptimePrint("{d}u", .{v}) ++ "\n";
}

pub const c_header_text: []const u8 = blk: {
    @setEvalBranchQuota(20_000);
    var h: []const u8 =
        \\/* fun_native_abi.h — Fun Native ABI (FNABI) v1.
        \\ *
        \\ * GENERATED from src/abi/fun_native_abi.zig — DO NOT EDIT.
        \\ * Regenerate: zig run src/abi/gen_header.zig  (from the repo root)
        \\ * Freshness and C/Zig layout equality are enforced by
        \\ * src/tests/abi_layout.zig.
        \\ *
        \\ * Target contract (design §11.4): 64-bit pointers, little-endian,
        \\ * fixed-width integers, IEEE-754, platform C ABI. Public structs
        \\ * contain no implicit padding: reservedN fields must be written as
        \\ * zero and are verified zero by the loader.
        \\ */
        \\#ifndef FUN_NATIVE_ABI_H
        \\#define FUN_NATIVE_ABI_H
        \\
        \\#include <stdint.h>
        \\
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\
        \\
    ;
    h = h ++ "/* ---- ABI versions (design §11.1/§11.2) ---- */\n" ++
        defineU("FUN_PLUGIN_ABI_MAJOR", plugin_abi_major) ++
        defineU("FUN_PLUGIN_ABI_MINOR", plugin_abi_minor) ++
        defineU("FUN_FAST_CALL_ABI", fast_call_abi) ++
        "/* Value ABI = (representation-contract version, JSValue.abi_encoding_revision);\n" ++
        " * typed leaf plugins declare value_abi = 0 (design §11.3). */\n" ++
        "/* AsyncToken epoch: u64, per-Runtime, never reused, no wraparound (M0D 2026-08-26). */\n" ++
        defineU("FUN_ASYNC_EPOCH_BITS", async_epoch_bits) ++
        "\n/* ---- scalar typedefs (design §12.1) ---- */\n" ++
        \\typedef uint32_t FunStatus;
        \\typedef uint16_t FunExportKind;
        \\typedef uint16_t FunCallKind;
        \\typedef uint16_t FunSignatureId;
        \\typedef uint16_t FunMarshalPolicyId;
        \\
        \\/* Generic code pointer; zjs casts to the descriptor-declared prototype
        \\ * before calling. Never void*. */
        \\typedef void (*FunNativeCodePtr)(void);
        \\
        \\
    ;
    h = h ++ "/* ---- status codes (design §12.2) ---- */\n" ++
        defineU("FUN_STATUS_OK", status.ok) ++
        defineU("FUN_STATUS_INVALID_ARGUMENT", status.invalid_argument) ++
        defineU("FUN_STATUS_OUT_OF_MEMORY", status.out_of_memory) ++
        defineU("FUN_STATUS_UNSUPPORTED", status.unsupported) ++
        defineU("FUN_STATUS_CANCELLED", status.cancelled) ++
        defineU("FUN_STATUS_INTERNAL", status.internal) ++
        "\n/* ---- export kinds (design §12.3) ---- */\n" ++
        defineU("FUN_EXPORT_FUNCTION", export_kind.function) ++
        defineU("FUN_EXPORT_CLASS", export_kind.class) ++
        defineU("FUN_EXPORT_CONST_I32", export_kind.const_i32) ++
        defineU("FUN_EXPORT_CONST_F64", export_kind.const_f64) ++
        defineU("FUN_EXPORT_CONST_BOOL", export_kind.const_bool) ++
        defineU("FUN_EXPORT_CONST_UTF8", export_kind.const_utf8) ++
        "\n/* ---- call kinds (design §14) ---- */\n" ++
        defineU("FUN_CALL_LEAF_STATIC", call_kind.leaf_static) ++
        defineU("FUN_CALL_LEAF_STATEFUL", call_kind.leaf_stateful) ++
        defineU("FUN_CALL_LEAF_METHOD", call_kind.leaf_method) ++
        defineU("FUN_CALL_MANAGED_FIXED", call_kind.managed_fixed) ++
        defineU("FUN_CALL_MANAGED_GENERIC", call_kind.managed_generic) ++
        defineU("FUN_CALL_ASYNC", call_kind.async_entry) ++
        "\n/* ---- marshal policies (design §15.3) ---- */\n" ++
        defineU("FUN_MARSHAL_CANONICAL", marshal_policy.canonical) ++
        "\n/* ---- v1 signatures (design §15.2; id 0 reserved/invalid) ---- */\n";
    for (signatures) |s| {
        h = h ++ defineU("FUN_SIG_" ++ s.name, s.id);
    }
    h = h ++
        \\
        \\/* ---- opaque ABI types (design §13.1) ----
        \\ * Pointer-only for plugins: never dereferenced, never sized. */
        \\typedef struct FunCallContextV1 FunCallContextV1;
        \\typedef struct FunAsyncTokenV1 FunAsyncTokenV1;
        \\typedef struct FunBufferLeaseV1 FunBufferLeaseV1;
        \\typedef struct FunPluginInitHostV1 FunPluginInitHostV1;
        \\typedef struct FunManagedHostV1 FunManagedHostV1;
        \\typedef struct FunAsyncHostV1 FunAsyncHostV1;
        \\typedef struct FunRuntimeTargetInfoV1 FunRuntimeTargetInfoV1;
        \\typedef struct FunErrorSinkV1 FunErrorSinkV1;
        \\typedef struct FunClassDescriptorV1 FunClassDescriptorV1;
        \\
        \\
    ;
    h = h ++ "/* ---- JSValue (design §11.3/§12.1): zjs's own 16-byte extern tagged\n" ++
        " * representation — no separate plugin value type exists. */\n" ++
        cBody(ZjsJSValue, "zjs_JSValue", &.{
            .{ .name = "payload", .c_type = "uint64_t" },
            .{ .name = "tag", .c_type = "int64_t" },
        }) ++
        \\#ifndef FUN_NATIVE_NO_JSVALUE_ALIAS
        \\typedef zjs_JSValue JSValue;
        \\#endif
        \\
        \\struct FunPluginInitContextV1;
        \\typedef FunStatus (*FunCreateInstanceFnV1)(
        \\    const struct FunPluginInitContextV1* context,
        \\    void** out_instance);
        \\typedef void (*FunShutdownFnV1)(void* instance);
        \\
        \\
    ;
    h = h ++ "/* ---- public structs (design §12.1) ---- */\n" ++
        cBody(FunUtf8RefV1, "FunUtf8RefV1", &.{
            .{ .name = "data", .c_type = "const uint8_t*" },
            .{ .name = "length", .c_type = "uint32_t" },
            .{ .name = "reserved0", .c_type = "uint32_t" },
        }) ++
        cBody(FunFunctionDescriptorV1, "FunFunctionDescriptorV1", &.{
            .{ .name = "struct_size", .c_type = "uint32_t" },
            .{ .name = "call_kind", .c_type = "FunCallKind" },
            .{ .name = "signature", .c_type = "FunSignatureId" },
            .{ .name = "marshal_policy", .c_type = "FunMarshalPolicyId" },
            .{ .name = "reserved0", .c_type = "uint16_t" },
            .{ .name = "flags", .c_type = "uint32_t" },
            .{ .name = "target", .c_type = "FunNativeCodePtr" },
        }) ++
        cBody(FunExportDescriptorV1, "FunExportDescriptorV1", &.{
            .{ .name = "struct_size", .c_type = "uint32_t" },
            .{ .name = "reserved0", .c_type = "uint32_t" },
            .{ .name = "name", .c_type = "FunUtf8RefV1" },
            .{ .name = "kind", .c_type = "FunExportKind" },
            .{ .name = "metadata_kind", .c_type = "uint16_t" },
            .{ .name = "reserved1", .c_type = "uint32_t" },
            .{ .name = "metadata", .c_type = "const void*" },
            .{ .name = "metadata_size", .c_type = "uint32_t" },
            .{ .name = "reserved2", .c_type = "uint32_t" },
        }) ++
        cBody(FunPluginDescriptorV1, "FunPluginDescriptorV1", &.{
            .{ .name = "struct_size", .c_type = "uint32_t" },
            .{ .name = "plugin_abi_major", .c_type = "uint16_t" },
            .{ .name = "plugin_abi_minor", .c_type = "uint16_t" },
            .{ .name = "fast_call_abi", .c_type = "uint16_t" },
            .{ .name = "value_abi", .c_type = "uint16_t" },
            .{ .name = "reserved0", .c_type = "uint32_t" },
            .{ .name = "required_features", .c_type = "uint64_t" },
            .{ .name = "optional_features", .c_type = "uint64_t" },
            .{ .name = "package_name", .c_type = "FunUtf8RefV1" },
            .{ .name = "module_name", .c_type = "FunUtf8RefV1" },
            .{ .name = "build_id", .c_type = "FunUtf8RefV1" },
            .{ .name = "exports", .c_type = "const FunExportDescriptorV1*" },
            .{ .name = "export_count", .c_type = "uint32_t" },
            .{ .name = "reserved1", .c_type = "uint32_t" },
            .{ .name = "create_instance", .c_type = "FunCreateInstanceFnV1" },
            .{ .name = "begin_shutdown", .c_type = "FunShutdownFnV1" },
            .{ .name = "destroy_instance", .c_type = "FunShutdownFnV1" },
        }) ++
        cBody(FunPluginInitContextV1, "FunPluginInitContextV1", &.{
            .{ .name = "struct_size", .c_type = "uint32_t" },
            .{ .name = "reserved0", .c_type = "uint32_t" },
            .{ .name = "init_host", .c_type = "const FunPluginInitHostV1*" },
            .{ .name = "host_context", .c_type = "void*" },
            .{ .name = "target_info", .c_type = "const FunRuntimeTargetInfoV1*" },
            .{ .name = "error_sink", .c_type = "const FunErrorSinkV1*" },
        });
    h = h ++
        \\/* ---- plugin entry point (design §12.4) ---- */
        \\#if defined(_WIN32)
        \\#define FUN_NATIVE_EXPORT __declspec(dllexport)
        \\#else
        \\#define FUN_NATIVE_EXPORT __attribute__((visibility("default")))
        \\#endif
        \\
        \\/* Desktop dynamic libraries export exactly one symbol:
        \\ *   FUN_NATIVE_EXPORT const FunPluginDescriptorV1* fun_native_plugin_v1(void);
        \\ * Static platforms use fun_native_plugin_v1_<artifact-prefix>. */
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif /* FUN_NATIVE_ABI_H */
        \\
    ;
    break :blk h;
};

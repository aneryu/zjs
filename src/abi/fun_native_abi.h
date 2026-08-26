/* fun_native_abi.h — Fun Native ABI (FNABI) v1.
 * FROZEN v1 (FN-M0F, 2026-08-26): evolution is append-only
 * (struct_size + minor) or a major bump.
 *
 * GENERATED from src/abi/fun_native_abi.zig — DO NOT EDIT.
 * Regenerate: zig run src/abi/gen_header.zig  (from the repo root)
 * Freshness and C/Zig layout equality are enforced by
 * src/tests/abi_layout.zig.
 *
 * Target contract (design §11.4): 64-bit pointers, little-endian,
 * fixed-width integers, IEEE-754, platform C ABI. Public structs
 * contain no implicit padding: reservedN fields must be written as
 * zero and are verified zero by the loader.
 */
#ifndef FUN_NATIVE_ABI_H
#define FUN_NATIVE_ABI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- ABI versions (design §11.1/§11.2) ---- */
#define FUN_PLUGIN_ABI_MAJOR 1u
#define FUN_PLUGIN_ABI_MINOR 0u
#define FUN_FAST_CALL_ABI 1u
/* Value ABI = (representation-contract version, JSValue.abi_encoding_revision);
 * typed leaf plugins declare value_abi = 0 (design §11.3). */
/* AsyncToken epoch: u64, per-Runtime, never reused, no wraparound (M0D 2026-08-26). */
#define FUN_ASYNC_EPOCH_BITS 64u

/* ---- scalar typedefs (design §12.1) ---- */
typedef uint32_t FunStatus;
typedef uint16_t FunExportKind;
typedef uint16_t FunCallKind;
typedef uint16_t FunSignatureId;
typedef uint16_t FunMarshalPolicyId;

/* Generic code pointer; zjs casts to the descriptor-declared prototype
 * before calling. Never void*. */
typedef void (*FunNativeCodePtr)(void);

/* ---- status codes (design §12.2) ---- */
#define FUN_STATUS_OK 0u
#define FUN_STATUS_INVALID_ARGUMENT 1u
#define FUN_STATUS_OUT_OF_MEMORY 2u
#define FUN_STATUS_UNSUPPORTED 3u
#define FUN_STATUS_CANCELLED 4u
#define FUN_STATUS_INTERNAL 5u

/* ---- export kinds (design §12.3) ---- */
#define FUN_EXPORT_FUNCTION 1u
#define FUN_EXPORT_CLASS 2u
#define FUN_EXPORT_CONST_I32 3u
#define FUN_EXPORT_CONST_F64 4u
#define FUN_EXPORT_CONST_BOOL 5u
#define FUN_EXPORT_CONST_UTF8 6u

/* ---- call kinds (design §14) ---- */
#define FUN_CALL_LEAF_STATIC 1u
#define FUN_CALL_LEAF_STATEFUL 2u
#define FUN_CALL_LEAF_METHOD 3u
#define FUN_CALL_MANAGED_FIXED 4u
#define FUN_CALL_MANAGED_GENERIC 5u
#define FUN_CALL_ASYNC 6u

/* ---- marshal policies (design §15.3) ---- */
#define FUN_MARSHAL_CANONICAL 1u

/* ---- v1 signatures (design §15.2; id 0 reserved/invalid) ---- */
#define FUN_SIG_VOID_TO_VOID 1u
#define FUN_SIG_I32_TO_I32 2u
#define FUN_SIG_I32_I32_TO_I32 3u
#define FUN_SIG_F64_TO_F64 4u
#define FUN_SIG_F64_F64_TO_F64 5u
#define FUN_SIG_F64_TO_VOID 6u
#define FUN_SIG_BOOL_TO_BOOL 7u
#define FUN_SIG_STATE_F64_TO_VOID 8u
#define FUN_SIG_SELF_TO_F64 9u
#define FUN_SIG_SELF_F64_TO_VOID 10u
#define FUN_SIG_SELF_F64_F64_TO_VOID 11u
#define FUN_SIG_BUFFER_TO_VOID 12u
#define FUN_SIG_STATE_BUFFER_TO_I32 13u
#define FUN_SIG_SELF_BUFFER_TO_VOID 14u
#define FUN_SIG_MANAGED_VALUE0 15u
#define FUN_SIG_MANAGED_VALUE1 16u
#define FUN_SIG_MANAGED_VALUE2 17u
#define FUN_SIG_MANAGED_VALUE3 18u
#define FUN_SIG_MANAGED_VALUE4 19u
#define FUN_SIG_GENERIC 20u
#define FUN_SIG_ASYNC_VALUE0 21u
#define FUN_SIG_ASYNC_VALUE1 22u
#define FUN_SIG_ASYNC_VALUE2 23u
#define FUN_SIG_ASYNC_VALUE3 24u
#define FUN_SIG_ASYNC_VALUE4 25u

/* ---- opaque ABI types (design §13.1) ----
 * Pointer-only for plugins: never dereferenced, never sized. */
typedef struct FunCallContextV1 FunCallContextV1;
typedef struct FunAsyncTokenV1 FunAsyncTokenV1;
typedef struct FunBufferLeaseV1 FunBufferLeaseV1;
typedef struct FunPluginInitHostV1 FunPluginInitHostV1;
typedef struct FunManagedHostV1 FunManagedHostV1;
typedef struct FunAsyncHostV1 FunAsyncHostV1;
typedef struct FunRuntimeTargetInfoV1 FunRuntimeTargetInfoV1;
typedef struct FunErrorSinkV1 FunErrorSinkV1;
typedef struct FunClassDescriptorV1 FunClassDescriptorV1;

/* ---- JSValue (design §11.3/§12.1): zjs's own 16-byte extern tagged
 * representation — no separate plugin value type exists. */
typedef struct zjs_JSValue {
    uint64_t payload;
    int64_t tag;
} zjs_JSValue;

#ifndef FUN_NATIVE_NO_JSVALUE_ALIAS
typedef zjs_JSValue JSValue;
#endif

struct FunPluginInitContextV1;
typedef FunStatus (*FunCreateInstanceFnV1)(
    const struct FunPluginInitContextV1* context,
    void** out_instance);
typedef void (*FunShutdownFnV1)(void* instance);

/* ---- public structs (design §12.1) ---- */
typedef struct FunUtf8RefV1 {
    const uint8_t* data;
    uint32_t length;
    uint32_t reserved0;
} FunUtf8RefV1;

typedef struct FunFunctionDescriptorV1 {
    uint32_t struct_size;
    FunCallKind call_kind;
    FunSignatureId signature;
    FunMarshalPolicyId marshal_policy;
    uint16_t reserved0;
    uint32_t flags;
    FunNativeCodePtr target;
} FunFunctionDescriptorV1;

typedef struct FunExportDescriptorV1 {
    uint32_t struct_size;
    uint32_t reserved0;
    FunUtf8RefV1 name;
    FunExportKind kind;
    uint16_t metadata_kind;
    uint32_t reserved1;
    const void* metadata;
    uint32_t metadata_size;
    uint32_t reserved2;
} FunExportDescriptorV1;

typedef struct FunPluginDescriptorV1 {
    uint32_t struct_size;
    uint16_t plugin_abi_major;
    uint16_t plugin_abi_minor;
    uint16_t fast_call_abi;
    uint16_t value_abi;
    uint32_t reserved0;
    uint64_t required_features;
    uint64_t optional_features;
    FunUtf8RefV1 package_name;
    FunUtf8RefV1 module_name;
    FunUtf8RefV1 build_id;
    const FunExportDescriptorV1* exports;
    uint32_t export_count;
    uint32_t reserved1;
    FunCreateInstanceFnV1 create_instance;
    FunShutdownFnV1 begin_shutdown;
    FunShutdownFnV1 destroy_instance;
} FunPluginDescriptorV1;

typedef struct FunPluginInitContextV1 {
    uint32_t struct_size;
    uint32_t reserved0;
    const FunPluginInitHostV1* init_host;
    void* host_context;
    const FunRuntimeTargetInfoV1* target_info;
    const FunErrorSinkV1* error_sink;
} FunPluginInitContextV1;

/* ---- plugin entry point (design §12.4) ---- */
#if defined(_WIN32)
#define FUN_NATIVE_EXPORT __declspec(dllexport)
#else
#define FUN_NATIVE_EXPORT __attribute__((visibility("default")))
#endif

/* Desktop dynamic libraries export exactly one symbol:
 *   FUN_NATIVE_EXPORT const FunPluginDescriptorV1* fun_native_plugin_v1(void);
 * Static platforms use fun_native_plugin_v1_<artifact-prefix>. */

#ifdef __cplusplus
}
#endif

#endif /* FUN_NATIVE_ABI_H */

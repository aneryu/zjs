//! zjs-private NativeCallPlan and the FNABI descriptor -> plan mapping
//! (FN-M0I; design §10.1, §15.2, §33). Not part of FNABI: plugins never see
//! these types — the frozen surface is src/abi/fun_native_abi.zig and its
//! generated C header. This module is the engine side of the single-schema
//! ruling (design v0.3 / roadmap v1.7): the normalized (call kind, signature,
//! marshal policy, flags) tuple below is the SAME schema the type-directed
//! plan's T3 `NativeCallDescriptor` consumes; builtins registered on the
//! unified NativeEntry and plugins must both produce it through this one
//! validation path (§9: 禁止手工复制 id 表).
//!
//! v1 scope restriction (FN-M0I acceptance item): one Runtime hosts exactly
//! one application realm. Plans, entries, and registrations are
//! Runtime-local; they are never shared with or compared against another
//! Runtime (identity/epoch comparisons are per-Runtime by M0D ruling).

const std = @import("std");
const abi = @import("../abi/fun_native_abi.zig");

/// Machine-visible marker for the v1 restriction above; future runtime
/// asserts and loader checks reference this constant rather than restating
/// the rule.
pub const one_runtime_one_application_realm = true;

pub const PlanError = error{
    /// struct_size smaller than the v1 base layout (§11.1: the loader only
    /// reads within struct_size; a descriptor smaller than v1 cannot carry
    /// the v1 required fields).
    DescriptorTooSmall,
    /// §11.4 verify-zero: a reservedN field carried a non-zero value.
    NonZeroReserved,
    UnknownCallKind,
    UnknownSignature,
    UnknownMarshalPolicy,
    MissingTarget,
};

/// The normalized call-plan schema tuple (design §9 `NativeCallPlanSpec`).
/// fun validates and normalizes descriptors into this shape; zjs builds the
/// private `NativeCallPlan` from it.
pub const NativeCallPlanSpec = struct {
    call_kind: abi.FunCallKind,
    signature: abi.FunSignatureId,
    marshal_policy: abi.FunMarshalPolicyId,
    flags: u32,

    /// The single descriptor -> spec mapping (FN-M0I deliverable). Every
    /// v1 validation rule for `FunFunctionDescriptorV1` lives here; the
    /// loader and any test fixture must call this, never re-implement it.
    pub fn fromFunctionDescriptor(desc: *const abi.FunFunctionDescriptorV1) PlanError!NativeCallPlanSpec {
        // Append-only evolution (§11.1): a LARGER struct_size is a newer
        // minor revision — fields beyond our knowledge are ignored. Smaller
        // than the v1 base cannot satisfy v1.
        if (desc.struct_size < @sizeOf(abi.FunFunctionDescriptorV1))
            return PlanError.DescriptorTooSmall;
        if (desc.reserved0 != 0) return PlanError.NonZeroReserved;
        if (!callKindIsValid(desc.call_kind)) return PlanError.UnknownCallKind;
        if (!signatureIsValid(desc.signature)) return PlanError.UnknownSignature;
        if (desc.marshal_policy != abi.marshal_policy.canonical)
            return PlanError.UnknownMarshalPolicy;
        if (desc.target == null) return PlanError.MissingTarget;
        return .{
            .call_kind = desc.call_kind,
            .signature = desc.signature,
            .marshal_policy = desc.marshal_policy,
            .flags = desc.flags,
        };
    }
};

pub fn callKindIsValid(kind: abi.FunCallKind) bool {
    return kind >= abi.call_kind.leaf_static and kind <= abi.call_kind.async_entry;
}

pub fn signatureIsValid(id: abi.FunSignatureId) bool {
    // The id table is dense starting at 1 (pinned by the abi_layout tests),
    // so validity is a range check — but stated through the table so a table
    // change cannot silently widen the accepted range.
    return id >= abi.signatures[0].id and id <= abi.signatures[abi.signatures.len - 1].id;
}

/// zjs-internal precomputed call plan (design §10.1). v1 skeleton: the spec
/// is the complete steady-state key. Resolved fields (specialized handler
/// pointer, arity, quickening keys) are FN-M1A scope and will be appended
/// here — the plan stays private, so appending is not an ABI event.
pub const NativeCallPlan = struct {
    spec: NativeCallPlanSpec,
};

/// Constant exports (§12.3) materialize at module instantiation; no native
/// call is involved.
pub const ConstValue = union(enum) {
    i32_value: i32,
    f64_value: f64,
    bool_value: bool,
    utf8: []const u8,
};

/// Private fun↔zjs registration shapes (design §9; shape finalized at M0 as
/// the doc requires). `name` is interned to an Atom at registration time —
/// registration input carries the raw bytes so callers need no atom-table
/// access. The `registerNativeModule(runtime, ...)` entry point that consumes
/// these is FN-M1A scope.
pub const NativeExportRegistration = struct {
    name: []const u8,
    kind: abi.FunExportKind,
    plan_spec: NativeCallPlanSpec,
    target: abi.FunNativeCodePtr,
    state: ?*anyopaque = null,
    /// NativeClassRegistration is FN-M1B scope (design §12.3: class metadata
    /// via FunClassDescriptorV1); typed once that lands.
    class_spec: ?*const anyopaque = null,
    const_value: ?ConstValue = null,
};

pub const NativeModuleRegistration = struct {
    module_name: []const u8,
    exports: []const NativeExportRegistration,
};

// ---- tests -----------------------------------------------------------------

fn callbackForTest() callconv(.c) void {}

fn validDescriptor() abi.FunFunctionDescriptorV1 {
    return .{
        .struct_size = @sizeOf(abi.FunFunctionDescriptorV1),
        .call_kind = abi.call_kind.leaf_static,
        .signature = 4, // F64_TO_F64
        .marshal_policy = abi.marshal_policy.canonical,
        .reserved0 = 0,
        .flags = 0,
        .target = &callbackForTest,
    };
}

test "descriptor -> plan spec: valid v1 descriptor normalizes" {
    const desc = validDescriptor();
    const spec = try NativeCallPlanSpec.fromFunctionDescriptor(&desc);
    try std.testing.expectEqual(abi.call_kind.leaf_static, spec.call_kind);
    try std.testing.expectEqual(@as(abi.FunSignatureId, 4), spec.signature);
    try std.testing.expectEqual(abi.marshal_policy.canonical, spec.marshal_policy);
    try std.testing.expectEqual(@as(u32, 0), spec.flags);
}

test "descriptor -> plan spec: a larger struct_size is a newer minor and is accepted" {
    var desc = validDescriptor();
    desc.struct_size = @sizeOf(abi.FunFunctionDescriptorV1) + 16;
    _ = try NativeCallPlanSpec.fromFunctionDescriptor(&desc);
}

test "descriptor -> plan spec: v1 rejection rows" {
    var too_small = validDescriptor();
    too_small.struct_size = @sizeOf(abi.FunFunctionDescriptorV1) - 1;
    try std.testing.expectError(PlanError.DescriptorTooSmall, NativeCallPlanSpec.fromFunctionDescriptor(&too_small));

    var dirty_reserved = validDescriptor();
    dirty_reserved.reserved0 = 1;
    try std.testing.expectError(PlanError.NonZeroReserved, NativeCallPlanSpec.fromFunctionDescriptor(&dirty_reserved));

    var bad_kind = validDescriptor();
    bad_kind.call_kind = 0;
    try std.testing.expectError(PlanError.UnknownCallKind, NativeCallPlanSpec.fromFunctionDescriptor(&bad_kind));
    bad_kind.call_kind = abi.call_kind.async_entry + 1;
    try std.testing.expectError(PlanError.UnknownCallKind, NativeCallPlanSpec.fromFunctionDescriptor(&bad_kind));

    var bad_sig = validDescriptor();
    bad_sig.signature = 0;
    try std.testing.expectError(PlanError.UnknownSignature, NativeCallPlanSpec.fromFunctionDescriptor(&bad_sig));
    bad_sig.signature = abi.signatures[abi.signatures.len - 1].id + 1;
    try std.testing.expectError(PlanError.UnknownSignature, NativeCallPlanSpec.fromFunctionDescriptor(&bad_sig));

    var bad_policy = validDescriptor();
    bad_policy.marshal_policy = 0;
    try std.testing.expectError(PlanError.UnknownMarshalPolicy, NativeCallPlanSpec.fromFunctionDescriptor(&bad_policy));

    var no_target = validDescriptor();
    no_target.target = null;
    try std.testing.expectError(PlanError.MissingTarget, NativeCallPlanSpec.fromFunctionDescriptor(&no_target));
}

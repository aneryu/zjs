//! NativeObject (NB2 boundary design §8.1): the class family behind
//! `zjs.native.Class`. An instance is an ordinary object of a dynamic class id
//! whose payload arm word is the opaque embedder `self` (qjs `u.opaque`, Bun
//! `m_ctx`); null means disposed. The per-runtime `NativeType` (class id,
//! name, finalizer, owner) lives in the class record (`Record.native_type`),
//! never in the object: the K2/K3 handlers only compare `class_id` and load
//! `self` (`Object.nativeSelfAssumeClass`).
//!
//! Lifetime: a `NativeType` is allocated on registration and released by the
//! class table at runtime teardown (after the final sweep, so every instance
//! finalizer has already run). Class ids come from the process-global dynamic
//! allocator through a caller-owned `ClassIdSlot`, so one comptime class keeps
//! one id across runtimes and reloads (hot-reload design §0.2).

const std = @import("std");
const class = @import("class.zig");
const object_mod = @import("object.zig");
const runtime_mod = @import("runtime.zig");
const value = @import("value.zig");
const value_semantics = @import("value_semantics.zig");

const Object = object_mod.Object;
const JSRuntime = runtime_mod.JSRuntime;
const JSValue = value.JSValue;

/// `finalize(self)` runs on the runtime thread when an instance is swept
/// (or at teardown) with a non-null `self`; a disposed instance is skipped.
pub const FinalizeFn = *const fn (self: *anyopaque) callconv(.c) void;

pub const NativeType = struct {
    class_id: class.ClassId,
    name: []const u8,
    finalize: ?FinalizeFn,
    /// The registering runtime (the type's allocation account).
    owner: *JSRuntime,

    pub fn fromRecord(rt: *const JSRuntime, class_id: class.ClassId) ?*const NativeType {
        const record = rt.classes.recordPtr(class_id) orelse return null;
        const raw = record.native_type orelse return null;
        return @ptrCast(@alignCast(raw));
    }
};

/// Register `class_id` as a NativeObject class in `rt` (idempotent per
/// runtime: a second registration of the same id returns the existing type).
/// `name` must outlive the runtime (comptime string in practice).
pub fn registerType(rt: *JSRuntime, class_id: class.ClassId, name: []const u8, finalize: ?FinalizeFn) !*const NativeType {
    if (NativeType.fromRecord(rt, class_id)) |existing| return existing;
    if (rt.classes.isRegistered(class_id)) return error.DuplicateClass;
    const native_type = try rt.memory.create(NativeType);
    errdefer rt.memory.destroy(NativeType, native_type);
    native_type.* = .{
        .class_id = class_id,
        .name = name,
        .finalize = finalize,
        .owner = rt,
    };
    try rt.ensureContextClassPrototypeCapacity(class_id);
    try rt.classes.register(class_id, .{
        .class_name = name,
        .binding_data = @ptrCast(native_type),
        .binding_data_finalizer = destroyType,
        .payload_kind = .none,
        .payload_finalizer = payloadFinalizer,
        .native_type = @ptrCast(native_type),
    });
    return native_type;
}

fn destroyType(data: *anyopaque) void {
    const native_type: *NativeType = @ptrCast(@alignCast(data));
    native_type.owner.memory.destroy(NativeType, native_type);
}

/// Class payload finalizer (sweep / teardown, runtime thread): hand a live
/// `self` to the type's finalizer. The class table pins the record for the
/// duration of the callback, so `fromRecord` is safe here.
fn payloadFinalizer(runtime: *anyopaque, object: *anyopaque, payload: *class.Payload) void {
    const rt: *JSRuntime = @ptrCast(@alignCast(runtime));
    const obj: *Object = @ptrCast(@alignCast(object));
    const self_ptr = payload.* orelse return;
    payload.* = null;
    const native_type = NativeType.fromRecord(rt, obj.class_id) orelse return;
    if (native_type.finalize) |finalize| finalize(self_ptr);
}

/// Create an instance of `native_type` with `[[Prototype]] = prototype` and
/// `self` installed. The object owns `self` from here: the finalizer runs
/// unless `Object.takeNativeSelf` detaches it first.
pub fn create(rt: *JSRuntime, native_type: *const NativeType, prototype: ?*Object, self_ptr: *anyopaque) !*Object {
    const obj = try Object.create(rt, native_type.class_id, prototype);
    obj.installNativeSelf(rt, self_ptr);
    return obj;
}

/// Typed unwrap: `value` must be an object of exactly `class_id` with a live
/// `self`.
pub inline fn unwrap(val: JSValue, class_id: class.ClassId) ?*anyopaque {
    const obj = value_semantics.objectFromValue(val) orelse return null;
    if (obj.class_id != class_id) return null;
    return obj.nativeSelfAssumeClass();
}

//! Phase A2 of the NB2 boundary (docs/perf/native-boundary-design.md §3.3):
//! comptime adapters that turn a legacy `InternalEntry` declaration (qjs
//! `cproto` + typed Zig body returning `HostError!JSValue`) into a
//! `NativeEntry` whose `target` is a `callconv(.c)` thunk of the NB2
//! prototype. Every builtin migrates through here with zero per-function
//! edits; the thunk is inlined around the body, so the cost is the same
//! signature conversion `dispatchTypedRecord` used to do with a runtime
//! switch -- now resolved at comptime per entry.
//!
//! Legacy bodies may still read the stack-local native environment
//! (`builtin_dispatch.nativeCall`), so every entry produced here carries
//! `flags.needs_env`; phase A4 strips it by census.

const std = @import("std");
const core = @import("../core/root.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");

const JSValue = core.JSValue;
const NativeEntry = core.NativeEntry;
const InternalEntry = core.host_function.InternalEntry;

pub const LeafSig = core.LeafSig;
pub const sig_void_to_void = LeafSig.void_to_void;
pub const sig_i32_to_i32 = LeafSig.i32_to_i32;
pub const sig_i32_i32_to_i32 = LeafSig.i32_i32_to_i32;
pub const sig_f64_to_f64 = LeafSig.f64_to_f64;
pub const sig_f64_f64_to_f64 = LeafSig.f64_f64_to_f64;
pub const sig_f64_to_void = LeafSig.f64_to_void;
pub const sig_bool_to_bool = LeafSig.bool_to_bool;
pub const sig_state_f64_to_void = LeafSig.state_f64_to_void;
pub const sig_state_i32_to_i32 = LeafSig.state_i32_to_i32;
pub const sig_string_i32_to_i32 = LeafSig.string_i32_to_i32;
pub const sig_string_i32_to_string = LeafSig.string_i32_to_string;
/// K2 method leaves (NB2 §4.3): `self` = the NativeObject payload pointer.
pub const sig_self_to_f64 = LeafSig.self_to_f64;
pub const sig_self_f64_to_void = LeafSig.self_f64_to_void;
pub const sig_self_f64_f64_to_void = LeafSig.self_f64_f64_to_void;
pub const sig_self_i32_to_i32 = LeafSig.self_i32_to_i32;
pub const sig_self_to_i32 = LeafSig.self_to_i32;
pub const sig_self_i32_to_void = LeafSig.self_i32_to_void;
pub const sig_self_to_void = LeafSig.self_to_void;

/// Leaf C prototypes selected by `NativeEntry.sig`. `STATE_*` prototypes
/// receive `entry.state` as their first argument.
pub const LeafVoidToVoid = *const fn () callconv(.c) void;
pub const LeafI32ToI32 = *const fn (i32) callconv(.c) i32;
pub const LeafI32I32ToI32 = *const fn (i32, i32) callconv(.c) i32;
pub const LeafF64ToF64 = *const fn (f64) callconv(.c) f64;
pub const LeafF64F64ToF64 = *const fn (f64, f64) callconv(.c) f64;
pub const LeafF64ToVoid = *const fn (f64) callconv(.c) void;
pub const LeafBoolToBool = *const fn (bool) callconv(.c) bool;
pub const LeafStateF64ToVoid = *const fn (*anyopaque, f64) callconv(.c) void;
pub const LeafStateI32ToI32 = *const fn (*anyopaque, i32) callconv(.c) i32;
/// Lane K prim_self (design §4.3): `self` is the flat string receiver, the
/// index is the canonical i32 marshal. A negative result means "not on the
/// fast shape" (out of range, surrogate policy, ...) and the arm takes the
/// entry's fallback; a non-negative result is the code value the arm boxes
/// (`STRING_I32_TO_I32`: int32; `STRING_I32_TO_STRING`: one code unit as a
/// fresh string).
pub const LeafStringI32ToI32 = *const fn (*const core.string.String, i32) callconv(.c) i32;
/// `SELF_*` prototypes receive the unwrapped NativeObject `self` first.
pub const LeafSelfToF64 = *const fn (*anyopaque) callconv(.c) f64;
pub const LeafSelfF64ToVoid = *const fn (*anyopaque, f64) callconv(.c) void;
pub const LeafSelfF64F64ToVoid = *const fn (*anyopaque, f64, f64) callconv(.c) void;
pub const LeafSelfI32ToI32 = *const fn (*anyopaque, i32) callconv(.c) i32;
pub const LeafSelfToI32 = *const fn (*anyopaque) callconv(.c) i32;
pub const LeafSelfI32ToVoid = *const fn (*anyopaque, i32) callconv(.c) void;
pub const LeafSelfToVoid = *const fn (*anyopaque) callconv(.c) void;

inline fn args(argv: [*]const JSValue, argc: u32) []const JSValue {
    return argv[0..argc];
}

/// Managed thunk around a `generic` body.
fn managedGeneric(comptime body: core.host_function.NativeGenericFn) core.native_entry.ManagedFn {
    return &struct {
        fn thunk(ctx: *core.JSContext, this: JSValue, argv: [*]const JSValue, argc: u32, entry: *const NativeEntry, func_obj: ?*core.Object) callconv(.c) JSValue {
            _ = entry;
            _ = func_obj;
            return builtin_dispatch.hostResultToValue(ctx, body(ctx, this, args(argv, argc)));
        }
    }.thunk;
}

fn managedGenericMagic(comptime body: core.host_function.NativeGenericMagicFn) core.native_entry.ManagedFn {
    return &struct {
        fn thunk(ctx: *core.JSContext, this: JSValue, argv: [*]const JSValue, argc: u32, entry: *const NativeEntry, func_obj: ?*core.Object) callconv(.c) JSValue {
            _ = func_obj;
            return builtin_dispatch.hostResultToValue(ctx, body(ctx, this, args(argv, argc), @intCast(entry.magic)));
        }
    }.thunk;
}

fn getterThunk(comptime body: core.host_function.NativeGetterFn) core.native_entry.GetterFn {
    return &struct {
        fn thunk(ctx: *core.JSContext, this: JSValue, entry: *const NativeEntry) callconv(.c) JSValue {
            _ = entry;
            return builtin_dispatch.hostResultToValue(ctx, body(ctx, this));
        }
    }.thunk;
}

fn getterMagicThunk(comptime body: core.host_function.NativeGetterMagicFn) core.native_entry.GetterFn {
    return &struct {
        fn thunk(ctx: *core.JSContext, this: JSValue, entry: *const NativeEntry) callconv(.c) JSValue {
            return builtin_dispatch.hostResultToValue(ctx, body(ctx, this, @intCast(entry.magic)));
        }
    }.thunk;
}

fn setterThunk(comptime body: core.host_function.NativeSetterFn) core.native_entry.SetterFn {
    return &struct {
        fn thunk(ctx: *core.JSContext, this: JSValue, new_value: JSValue, entry: *const NativeEntry) callconv(.c) JSValue {
            _ = entry;
            return builtin_dispatch.hostResultToValue(ctx, body(ctx, this, new_value));
        }
    }.thunk;
}

fn setterMagicThunk(comptime body: core.host_function.NativeSetterMagicFn) core.native_entry.SetterFn {
    return &struct {
        fn thunk(ctx: *core.JSContext, this: JSValue, new_value: JSValue, entry: *const NativeEntry) callconv(.c) JSValue {
            return builtin_dispatch.hostResultToValue(ctx, body(ctx, this, new_value, @intCast(entry.magic)));
        }
    }.thunk;
}

fn leafF64(comptime body: core.host_function.NativeF64Fn) LeafF64ToF64 {
    return &struct {
        fn thunk(x: f64) callconv(.c) f64 {
            return body(x);
        }
    }.thunk;
}

fn leafF64F64(comptime body: core.host_function.NativeF64F64Fn) LeafF64F64ToF64 {
    return &struct {
        fn thunk(x: f64, y: f64) callconv(.c) f64 {
            return body(x, y);
        }
    }.thunk;
}

/// The single declaration -> entry mapping. Comptime-memoized per distinct
/// `InternalEntry`, so two tables naming the same body share one thunk (and
/// therefore one `target` pointer, which identity checks rely on).
pub fn entryFromInternal(comptime e: InternalEntry) NativeEntry {
    const native = e.native_function orelse @compileError("native cproto entry missing function: " ++ e.name);
    if (std.meta.activeTag(native) != e.cproto) @compileError("native function tag does not match cproto: " ++ e.name);
    if (e.fallback_function != null and e.cproto != .f_f and e.cproto != .f_f_f) {
        @compileError("only numeric cproto entries may set a coercion fallback: " ++ e.name);
    }
    if (e.managed != null and core.host_function.isConstructorCProto(e.cproto)) {
        @compileError("construct-capable entries may not set a managed body: " ++ e.name);
    }
    const base: NativeEntry = .{
        .target = undefined,
        .kind = .managed,
        .flags = .{ .needs_env = true, .forwards_call = e.forwards_call },
        .arity = e.length,
        .magic = e.magic,
    };
    var entry = base;
    if (e.managed) |body| {
        entry.target = NativeEntry.code(body);
        entry.kind = .managed;
        entry.flags.needs_env = false;
        return primLeafOrManaged(e, entry);
    }
    switch (e.cproto) {
        .generic => {
            entry.target = NativeEntry.code(managedGeneric(native.generic));
            entry.kind = .managed;
        },
        .generic_magic => {
            entry.target = NativeEntry.code(managedGenericMagic(native.generic_magic));
            entry.kind = .managed;
        },
        .constructor => {
            entry.target = NativeEntry.code(managedGeneric(native.constructor));
            entry.kind = .constructor;
        },
        .constructor_magic => {
            entry.target = NativeEntry.code(managedGenericMagic(native.constructor_magic));
            entry.kind = .constructor;
        },
        .constructor_or_func => {
            entry.target = NativeEntry.code(managedGeneric(native.constructor_or_func));
            entry.kind = .constructor_or_func;
        },
        .constructor_or_func_magic => {
            entry.target = NativeEntry.code(managedGenericMagic(native.constructor_or_func_magic));
            entry.kind = .constructor_or_func;
        },
        .getter => {
            entry.target = NativeEntry.code(getterThunk(native.getter));
            entry.kind = .getter;
        },
        .getter_magic => {
            entry.target = NativeEntry.code(getterMagicThunk(native.getter_magic));
            entry.kind = .getter;
        },
        .setter => {
            entry.target = NativeEntry.code(setterThunk(native.setter));
            entry.kind = .setter;
        },
        .setter_magic => {
            entry.target = NativeEntry.code(setterMagicThunk(native.setter_magic));
            entry.kind = .setter;
        },
        .f_f => {
            entry.target = NativeEntry.code(leafF64(native.f_f));
            entry.kind = .leaf;
            entry.sig = sig_f64_to_f64;
            entry.effect = core.native_entry.Effect.leaf;
            entry.fallback = if (e.fallback_function) |fb| managedGenericMagic(fb) else null;
        },
        .f_f_f => {
            entry.target = NativeEntry.code(leafF64F64(native.f_f_f));
            entry.kind = .leaf;
            entry.sig = sig_f64_f64_to_f64;
            entry.effect = core.native_entry.Effect.leaf;
            entry.fallback = if (e.fallback_function) |fb| managedGenericMagic(fb) else null;
        },
    }
    return primLeafOrManaged(e, entry);
}

/// Lane K: wrap a managed entry into its `method_leaf` form when the
/// declaration carries a `prim_leaf`. The managed thunk just built becomes
/// the tag-miss fallback (keeping its `needs_env` reading), the leaf target
/// and signature move into the hot fields.
fn primLeafOrManaged(comptime e: InternalEntry, comptime managed_entry: NativeEntry) NativeEntry {
    const leaf = e.prim_leaf orelse return managed_entry;
    if (managed_entry.kind != .managed) @compileError("prim_leaf requires a plain managed body: " ++ e.name);
    if (leaf.sig == .none) @compileError("prim_leaf requires a typed leaf signature: " ++ e.name);
    var entry = managed_entry;
    entry.fallback = @ptrCast(managed_entry.target);
    entry.target = leaf.target;
    entry.kind = .method_leaf;
    entry.sig = leaf.sig;
    // The string-returning arm allocates the one-unit result; both read the
    // receiver's characters. Neither throws or re-enters JS.
    entry.effect = .{
        .may_throw = false,
        .may_alloc = leaf.sig == sig_string_i32_to_string,
        .may_reenter_js = false,
        .reads_heap = true,
        .writes_heap = false,
    };
    return entry;
}

/// Test/embedding helper: an entry for a bare `generic` body (no table).
pub fn genericEntry(comptime body: core.host_function.NativeGenericFn, comptime length: u8) NativeEntry {
    return .{
        .target = NativeEntry.code(managedGeneric(body)),
        .kind = .managed,
        .flags = .{ .needs_env = true },
        .arity = length,
    };
}

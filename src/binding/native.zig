//! `zjs.native`: the embedder-facing native function API of the NB2 boundary
//! (docs/perf/native-boundary-design.md §9). A host function is a comptime
//! generated `callconv(.c)` thunk over a plain Zig function; the thunk is
//! the `NativeEntry.target`, so an embedder function is dispatched exactly
//! like a builtin (§3, principle 1). There is no per-call arena, handle
//! scope, marshalling framework or registry lookup: the call receives the
//! callee realm, `this`, and a view of the VM operand window, and returns a
//! `JSValue` or a Zig error (mapped to the pending JS exception at the
//! seam).
//!
//! Rooting contract (§7 C2): every `JSValue` in `argv` stays alive for the
//! duration of the call (it is the machine's operand window); values the
//! function creates are covered by the conservative native-stack scan
//! while they live in locals. Only cross-call retention needs a
//! `zjs.value.Persistent`.

const std = @import("std");
const core = @import("../core/root.zig");
const exec = @import("../exec/root.zig");
const context_mod = @import("context.zig");

pub const JSContext = context_mod.JSContext;
pub const JSValue = core.JSValue;
pub const NativeEntry = core.NativeEntry;

/// The error a managed function returns after it already installed a JS
/// exception (`ctx.throwValue` / `ctx.throwError`).
pub const Exception = error{JSException};

/// One managed call (K0, §4.1). Built on the C stack by the thunk; never
/// outlives the call.
pub const Call = struct {
    /// Non-owning facade for the callee realm.
    ctx: JSContext,
    this: JSValue,
    argv: [*]const JSValue,
    argc: u32,
    entry: *const NativeEntry,
    /// The callee function object (null only for engine-internal synthetic
    /// invocations, which never reach an embedder function).
    func_obj: ?*core.Object,

    /// Positional argument; `undefined` past `argc` (JS semantics).
    pub inline fn arg(self: *const Call, index: usize) JSValue {
        return if (index < self.argc) self.argv[index] else JSValue.undefinedValue();
    }

    /// The argument window as a slice (borrowed for this call).
    pub inline fn args(self: *const Call) []const JSValue {
        return self.argv[0..self.argc];
    }

    /// Typed access to the state pointer given at registration.
    pub inline fn state(self: *const Call, comptime T: type) *T {
        return @ptrCast(@alignCast(self.entry.state.?));
    }

    pub inline fn runtime(self: *const Call) *core.JSRuntime {
        return self.ctx.core.runtime;
    }

    /// The realm's global object.
    pub inline fn global(self: *const Call) ?*core.Object {
        return self.ctx.core.global;
    }

    /// The host output writer of the current VM invocation (the `output`
    /// the embedder passed to eval / callFunction), if any.
    pub inline fn output(self: *const Call) ?*std.Io.Writer {
        return exec.builtin_dispatch.vmCallerView(self.ctx.core).output;
    }

    /// Install a JS error of class `name` (TypeError, RangeError, ...) with
    /// `message` and return the error the function must propagate.
    pub fn throwError(self: *const Call, name: []const u8, message: []const u8) Exception {
        var ctx = self.ctx;
        _ = ctx.throwError(name, message, .{}) catch {};
        return error.JSException;
    }

    pub fn throwTypeError(self: *const Call, message: []const u8) Exception {
        return self.throwError("TypeError", message);
    }

    pub fn throwRangeError(self: *const Call, message: []const u8) Exception {
        return self.throwError("RangeError", message);
    }
};

/// Registration-side description produced by the generators below and
/// consumed by `JSContext.defineFunction` / `createFunction`. Comptime
/// constant; `state` / `finalize` are per-registration options.
pub const Spec = struct {
    template: NativeEntry,
};

pub const Options = struct {
    /// JS `length` (arity). Defaults to the Zig function's declared arity
    /// where a generator can infer it, else 0.
    length: ?u8 = null,
    /// Opaque state handed back through `Call.state`.
    state: ?*anyopaque = null,
    /// Runs on the runtime thread when the runtime is destroyed (ownership
    /// registration for `state`).
    finalize: ?*const fn (*anyopaque) void = null,
    /// Also create a `prototype` object with a back-pointing `constructor`.
    with_prototype: bool = false,
    /// Realm to create the function in (defaults to the context's realm).
    realm_global: ?*core.Object = null,
};

/// Build a managed native function from `f: fn (*Call) E!JSValue`. Any
/// error set is accepted: `error.JSException` means "already thrown",
/// engine sentinels (`error.TypeError`, `error.RangeError`, `OutOfMemory`,
/// `Interrupted`, ...) are materialized by the engine, and every other
/// error name becomes `Error: <name>`.
pub fn managed(comptime f: anytype) Spec {
    const F = @TypeOf(f);
    const info = @typeInfo(F);
    if (info != .@"fn") @compileError("zjs.native.managed expects a function");
    const params = info.@"fn".params;
    if (params.len != 1 or params[0].type != *Call) @compileError("zjs.native.managed expects fn (*zjs.native.Call) E!JSValue");
    const Thunk = struct {
        fn thunk(
            ctx: *core.JSContext,
            this: JSValue,
            argv: [*]const JSValue,
            argc: u32,
            entry: *const NativeEntry,
            func_obj: ?*core.Object,
        ) callconv(.c) JSValue {
            var call = Call{
                .ctx = JSContext.borrowCore(ctx),
                .this = this,
                .argv = argv,
                .argc = argc,
                .entry = entry,
                .func_obj = func_obj,
            };
            const Ret = info.@"fn".return_type.?;
            if (@typeInfo(Ret) == .error_union) {
                const value = f(&call) catch |err| return exec.builtin_dispatch.embedderErrorToValue(ctx, err);
                return value;
            } else {
                return f(&call);
            }
        }
    };
    return .{ .template = .{
        .target = NativeEntry.code(&Thunk.thunk),
        .kind = .managed,
        .flags = .{},
        .arity = 0,
    } };
}

/// Build a typed leaf native function (K1, design §4.2) from a plain Zig
/// function over primitives. The signature is inferred from the parameter
/// and return types and must be one of the FNABI schema shapes; anything
/// else is a compile error (no silent generic fallback). The VM performs the
/// canonical marshal checks (int32 / f64 / bool exact, no coercion) and
/// boxing; the target never sees a JSValue, never allocates, never throws
/// and does not appear in `Error().stack`.
///
///   fn (i32, i32) i32   fn (i32) i32   fn (f64) f64   fn (f64, f64) f64
///   fn (f64) void       fn (bool) bool fn () void
pub fn leaf(comptime f: anytype) Spec {
    return leafSpec(f, false);
}

/// Leaf with per-registration state as the first parameter (`*T`, given as
/// `Options.state`): `fn (*T, f64) void`, `fn (*T, i32) i32`.
pub fn leafWithState(comptime f: anytype) Spec {
    return leafSpec(f, true);
}

fn leafSpec(comptime f: anytype, comptime with_state: bool) Spec {
    const F = @TypeOf(f);
    const info = @typeInfo(F);
    if (info != .@"fn") @compileError("zjs.native.leaf expects a function");
    const params = info.@"fn".params;
    const Ret = info.@"fn".return_type.?;
    const first: usize = if (with_state) 1 else 0;
    if (with_state) {
        if (params.len == 0) @compileError("zjs.native.leafWithState expects a *State first parameter");
        const P0 = params[0].type.?;
        if (@typeInfo(P0) != .pointer) @compileError("zjs.native.leafWithState expects a *State first parameter");
    }
    const n = params.len - first;
    const P = struct {
        fn t(comptime i: usize) type {
            return params[first + i].type.?;
        }
    };
    const legacy = exec.native_legacy;
    const State = if (with_state) params[0].type.? else void;
    const T = struct {
        fn stateOf(raw: *anyopaque) State {
            return @ptrCast(@alignCast(raw));
        }
        fn void_to_void() callconv(.c) void {
            f();
        }
        fn i32_to_i32(a: i32) callconv(.c) i32 {
            return f(a);
        }
        fn i32_i32_to_i32(a: i32, b: i32) callconv(.c) i32 {
            return f(a, b);
        }
        fn f64_to_f64(a: f64) callconv(.c) f64 {
            return f(a);
        }
        fn f64_f64_to_f64(a: f64, b: f64) callconv(.c) f64 {
            return f(a, b);
        }
        fn f64_to_void(a: f64) callconv(.c) void {
            f(a);
        }
        fn bool_to_bool(a: bool) callconv(.c) bool {
            return f(a);
        }
        fn state_f64_to_void(state: *anyopaque, a: f64) callconv(.c) void {
            f(stateOf(state), a);
        }
        fn state_i32_to_i32(state: *anyopaque, a: i32) callconv(.c) i32 {
            return f(stateOf(state), a);
        }
    };
    const shape: struct { target: core.native_entry.CodePtr, sig: u16 } = blk: {
        if (!with_state) {
            if (n == 0 and Ret == void) break :blk .{ .target = NativeEntry.code(&T.void_to_void), .sig = legacy.sig_void_to_void };
            if (n == 1 and P.t(0) == i32 and Ret == i32) break :blk .{ .target = NativeEntry.code(&T.i32_to_i32), .sig = legacy.sig_i32_to_i32 };
            if (n == 2 and P.t(0) == i32 and P.t(1) == i32 and Ret == i32) break :blk .{ .target = NativeEntry.code(&T.i32_i32_to_i32), .sig = legacy.sig_i32_i32_to_i32 };
            if (n == 1 and P.t(0) == f64 and Ret == f64) break :blk .{ .target = NativeEntry.code(&T.f64_to_f64), .sig = legacy.sig_f64_to_f64 };
            if (n == 2 and P.t(0) == f64 and P.t(1) == f64 and Ret == f64) break :blk .{ .target = NativeEntry.code(&T.f64_f64_to_f64), .sig = legacy.sig_f64_f64_to_f64 };
            if (n == 1 and P.t(0) == f64 and Ret == void) break :blk .{ .target = NativeEntry.code(&T.f64_to_void), .sig = legacy.sig_f64_to_void };
            if (n == 1 and P.t(0) == bool and Ret == bool) break :blk .{ .target = NativeEntry.code(&T.bool_to_bool), .sig = legacy.sig_bool_to_bool };
        } else {
            if (n == 1 and P.t(0) == f64 and Ret == void) break :blk .{ .target = NativeEntry.code(&T.state_f64_to_void), .sig = legacy.sig_state_f64_to_void };
            if (n == 1 and P.t(0) == i32 and Ret == i32) break :blk .{ .target = NativeEntry.code(&T.state_i32_to_i32), .sig = legacy.sig_state_i32_to_i32 };
        }
        @compileError("zjs.native.leaf: unsupported signature " ++ @typeName(F) ++ " (see the FNABI v1 signature table; use zjs.native.managed for JSValue shapes)");
    };
    return .{ .template = .{
        .target = shape.target,
        .kind = .leaf,
        .sig = shape.sig,
        .effect = core.native_entry.Effect.leaf,
        .arity = @intCast(n),
    } };
}

test "leaf infers the schema signature from the Zig function type" {
    const P = struct {
        fn add(a: i32, b: i32) i32 {
            return a +% b;
        }
        fn half(x: f64) f64 {
            return x / 2;
        }
    };
    try std.testing.expectEqual(exec.native_legacy.sig_i32_i32_to_i32, leaf(P.add).template.sig);
    try std.testing.expectEqual(exec.native_legacy.sig_f64_to_f64, leaf(P.half).template.sig);
    try std.testing.expectEqual(core.native_entry.Kind.leaf, leaf(P.add).template.kind);
    try std.testing.expectEqual(@as(u8, 2), leaf(P.add).template.arity);
}

test "managed produces a managed entry template" {
    const Probe = struct {
        fn f(call: *Call) error{ JSException, TypeError }!JSValue {
            if (call.argc == 0) return error.TypeError;
            return call.arg(0);
        }
    };
    const spec = managed(Probe.f);
    try std.testing.expectEqual(core.native_entry.Kind.managed, spec.template.kind);
    try std.testing.expect(!spec.template.flags.needs_env);
}

// ---- Native classes (design §8.1, §9.2) ------------------------------------

pub const ClassOptions = struct {
    /// Install the constructor on the realm's global object under this name.
    global_name: ?[]const u8 = null,
    /// Realm to install into (defaults to the context's realm).
    realm_global: ?*core.Object = null,
};

pub const MemberKind = enum { method, getter, setter };

/// One prototype member of a native class: a comptime `Spec` (kind /
/// target / signature) plus its JS name. `class_id` is stamped at
/// `defineClass` time (the class id is allocated per process, not comptime).
pub const Member = struct {
    name: []const u8,
    kind: MemberKind,
    spec: Spec,
};

/// A comptime native class description (design §9.2):
///
/// ```zig
/// const World = zjs.native.Class(.{
///     .name = "World",
///     .Self = WorldState,
///     .constructor = WorldState.create,          // fn (*Call) E!*WorldState   (optional)
///     .finalize = WorldState.destroy,            // fn (*WorldState) void      (optional)
///     .methods = .{ .step = WorldState.step },   // fn (*Self, i32) i32 -> K2 typed; fn (*Self, *Call) E!JSValue -> K2 managed
///     .getters = .{ .time = WorldState.time },   // fn (*Self) f64|i32 -> K3 typed; fn (*Self, *Call) E!JSValue -> managed
///     .setters = .{ .gravity = WorldState.setGravity }, // fn (*Self, f64|i32) void; fn (*Self, *Call) E!void
/// });
/// const world = try ctx.defineClass(World, .{ .global_name = "World" });
/// const obj = try world.create(ctx, state_ptr);
/// const st: ?*WorldState = World.unwrap(obj);
/// ```
///
/// Members become ordinary prototype properties (writable / configurable,
/// non-enumerable, like qjs `JS_CFUNC_DEF` / `JS_CGETSET_DEF`); the only
/// guard a call needs is the K2/K3 receiver class check.
pub fn Class(comptime spec: anytype) type {
    const SpecT = @TypeOf(spec);
    comptime {
        if (!@hasField(SpecT, "name")) @compileError("zjs.native.Class: spec needs .name");
        if (!@hasField(SpecT, "Self")) @compileError("zjs.native.Class: spec needs .Self");
    }
    return struct {
        const Cls = @This();
        pub const Self = spec.Self;
        pub const name: []const u8 = spec.name;
        pub const has_constructor = @hasField(SpecT, "constructor");
        pub const has_finalize = @hasField(SpecT, "finalize");

        /// Process-global class identity (qjs `JS_NewClassID` slot): one id
        /// per comptime class, reused across runtimes and reloads.
        var class_id_slot: core.class.ClassIdSlot = .{};

        pub fn classId() error{ClassIdExhausted}!core.ClassId {
            return class_id_slot.getOrAllocate();
        }

        /// class_id check + fixed-offset `self` load; null for a foreign
        /// object, a disposed instance, or a class never defined.
        pub fn unwrap(val: JSValue) ?*Self {
            const raw = core.native_object.unwrap(val, class_id_slot.value) orelse return null;
            return @ptrCast(@alignCast(raw));
        }

        pub const finalize_fn: ?core.native_object.FinalizeFn = if (has_finalize) &struct {
            fn thunk(raw: *anyopaque) callconv(.c) void {
                spec.finalize(@as(*Self, @ptrCast(@alignCast(raw))));
            }
        }.thunk else null;

        pub const methods: []const Member = memberTable(.method, if (@hasField(SpecT, "methods")) spec.methods else .{});
        pub const getters: []const Member = memberTable(.getter, if (@hasField(SpecT, "getters")) spec.getters else .{});
        pub const setters: []const Member = memberTable(.setter, if (@hasField(SpecT, "setters")) spec.setters else .{});

        /// JS `length` of the constructor (0 without one).
        pub const constructor_length: u8 = if (has_constructor and @hasField(SpecT, "constructor_length")) spec.constructor_length else 0;

        /// The constructor entry (K4 through the host-entry construct path:
        /// `new C(...)` hands the thunk the instance the engine created from
        /// `new_target.prototype`, whose prototype the NativeObject takes).
        /// `entry.state` is the runtime `NativeType`.
        pub const constructor_spec: Spec = .{ .template = .{
            .target = NativeEntry.code(&constructThunk),
            .kind = .managed,
            .arity = constructor_length,
        } };

        fn constructThunk(
            ctx: *core.JSContext,
            this: JSValue,
            argv: [*]const JSValue,
            argc: u32,
            entry: *const NativeEntry,
            func_obj: ?*core.Object,
        ) callconv(.c) JSValue {
            const dispatch = exec.builtin_dispatch;
            const native_type: *const core.NativeType = @ptrCast(@alignCast(entry.state.?));
            const instance = core.value_semantics.objectFromValue(this) orelse
                return dispatch.throwTypeErrorSentinel(ctx, "Class constructor " ++ name ++ " cannot be invoked without 'new'");
            if (!has_constructor) return dispatch.throwTypeErrorSentinel(ctx, name ++ " is not constructible from JS");
            var call = Call{
                .ctx = JSContext.borrowCore(ctx),
                .this = this,
                .argv = argv,
                .argc = argc,
                .entry = entry,
                .func_obj = func_obj,
            };
            const CtorRet = @typeInfo(@TypeOf(spec.constructor)).@"fn".return_type.?;
            const self_ptr: *Self = if (@typeInfo(CtorRet) == .error_union)
                spec.constructor(&call) catch |err| return dispatch.embedderErrorToValue(ctx, err)
            else
                spec.constructor(&call);
            const obj = core.native_object.create(ctx.runtime, native_type, instance.getPrototype(), @ptrCast(self_ptr)) catch |err| {
                if (native_type.finalize) |finalize| finalize(@ptrCast(self_ptr));
                return dispatch.embedderErrorToValue(ctx, err);
            };
            return obj.value();
        }

        fn memberTable(comptime kind: MemberKind, comptime table: anytype) []const Member {
            const fields = @typeInfo(@TypeOf(table)).@"struct".fields;
            var out: [fields.len]Member = undefined;
            for (fields, 0..) |field, i| {
                const f = @field(table, field.name);
                out[i] = .{
                    .name = field.name,
                    .kind = kind,
                    .spec = switch (kind) {
                        .method => methodSpec(Self, f),
                        .getter => getterSpec(Self, f),
                        .setter => setterSpec(Self, f),
                    },
                };
            }
            const frozen = out;
            return &frozen;
        }

        /// Runtime handle returned by `JSContext.defineClass`.
        pub const Handle = struct {
            native_type: *const core.NativeType,

            pub inline fn classId(self: Handle) core.ClassId {
                return self.native_type.class_id;
            }

            /// Wrap `self_ptr` in a new instance of this class in `ctx`'s
            /// realm (`[[Prototype]]` = the realm's class prototype). The
            /// object owns `self_ptr`: `finalize` runs at sweep / teardown.
            pub fn create(self: Handle, ctx: *JSContext, self_ptr: *Self) !JSValue {
                const proto = ctx.core.classPrototypeObject(self.native_type.class_id) orelse return error.ClassNotInstalled;
                const obj = try core.native_object.create(ctx.core.runtime, self.native_type, proto, @ptrCast(self_ptr));
                return obj.value();
            }

            pub inline fn unwrap(_: Handle, val: JSValue) ?*Self {
                return Cls.unwrap(val);
            }

            /// Detach `self` from `val` (later calls throw TypeError; the
            /// finalizer will not run for it). Returns the detached pointer.
            pub fn dispose(_: Handle, val: JSValue) ?*Self {
                const obj = core.value_semantics.objectFromValue(val) orelse return null;
                if (obj.class_id != class_id_slot.value) return null;
                const raw = obj.takeNativeSelf() orelse return null;
                return @ptrCast(@alignCast(raw));
            }

            pub fn prototype(self: Handle, ctx: *JSContext) ?*core.Object {
                return ctx.core.classPrototypeObject(self.native_type.class_id);
            }
        };
    };
}

fn selfParamCheck(comptime Self: type, comptime F: type, comptime what: []const u8) void {
    const info = @typeInfo(F);
    if (info != .@"fn") @compileError("zjs.native.Class " ++ what ++ " expects a function");
    const params = info.@"fn".params;
    if (params.len == 0 or params[0].type != *Self) @compileError("zjs.native.Class " ++ what ++ " expects *Self as the first parameter, got " ++ @typeName(F));
}

inline fn selfOf(comptime Self: type, raw: *anyopaque) *Self {
    return @ptrCast(@alignCast(raw));
}

/// K2 method: typed `fn (*Self, ...) ...` over the SELF_* schema shapes ->
/// `method_leaf`; `fn (*Self, *Call) E!JSValue` -> `method_managed`.
pub fn methodSpec(comptime Self: type, comptime f: anytype) Spec {
    const F = @TypeOf(f);
    selfParamCheck(Self, F, "method");
    const info = @typeInfo(F).@"fn";
    const params = info.params;
    const Ret = info.return_type.?;
    const n = params.len - 1;
    if (n == 1 and params[1].type == *Call) {
        const Thunk = struct {
            fn thunk(ctx: *core.JSContext, raw_self: *anyopaque, this: JSValue, argv: [*]const JSValue, argc: u32, entry: *const NativeEntry) callconv(.c) JSValue {
                var call = Call{
                    .ctx = JSContext.borrowCore(ctx),
                    .this = this,
                    .argv = argv,
                    .argc = argc,
                    .entry = entry,
                    .func_obj = null,
                };
                if (@typeInfo(Ret) == .error_union) {
                    return f(selfOf(Self, raw_self), &call) catch |err| return exec.builtin_dispatch.embedderErrorToValue(ctx, err);
                }
                return f(selfOf(Self, raw_self), &call);
            }
        };
        return .{ .template = .{ .target = NativeEntry.code(&Thunk.thunk), .kind = .method_managed, .arity = 0 } };
    }
    const legacy = exec.native_legacy;
    const P = struct {
        fn t(comptime i: usize) type {
            return params[1 + i].type.?;
        }
    };
    const T = struct {
        fn self_to_f64(raw: *anyopaque) callconv(.c) f64 {
            return f(selfOf(Self, raw));
        }
        fn self_f64_to_void(raw: *anyopaque, a: f64) callconv(.c) void {
            f(selfOf(Self, raw), a);
        }
        fn self_f64_f64_to_void(raw: *anyopaque, a: f64, b: f64) callconv(.c) void {
            f(selfOf(Self, raw), a, b);
        }
        fn self_i32_to_i32(raw: *anyopaque, a: i32) callconv(.c) i32 {
            return f(selfOf(Self, raw), a);
        }
        fn self_to_i32(raw: *anyopaque) callconv(.c) i32 {
            return f(selfOf(Self, raw));
        }
        fn self_i32_to_void(raw: *anyopaque, a: i32) callconv(.c) void {
            f(selfOf(Self, raw), a);
        }
        fn self_to_void(raw: *anyopaque) callconv(.c) void {
            f(selfOf(Self, raw));
        }
    };
    const shape: struct { target: core.native_entry.CodePtr, sig: u16 } = blk: {
        if (n == 0 and Ret == f64) break :blk .{ .target = NativeEntry.code(&T.self_to_f64), .sig = legacy.sig_self_to_f64 };
        if (n == 0 and Ret == i32) break :blk .{ .target = NativeEntry.code(&T.self_to_i32), .sig = legacy.sig_self_to_i32 };
        if (n == 0 and Ret == void) break :blk .{ .target = NativeEntry.code(&T.self_to_void), .sig = legacy.sig_self_to_void };
        if (n == 1 and P.t(0) == f64 and Ret == void) break :blk .{ .target = NativeEntry.code(&T.self_f64_to_void), .sig = legacy.sig_self_f64_to_void };
        if (n == 2 and P.t(0) == f64 and P.t(1) == f64 and Ret == void) break :blk .{ .target = NativeEntry.code(&T.self_f64_f64_to_void), .sig = legacy.sig_self_f64_f64_to_void };
        if (n == 1 and P.t(0) == i32 and Ret == i32) break :blk .{ .target = NativeEntry.code(&T.self_i32_to_i32), .sig = legacy.sig_self_i32_to_i32 };
        if (n == 1 and P.t(0) == i32 and Ret == void) break :blk .{ .target = NativeEntry.code(&T.self_i32_to_void), .sig = legacy.sig_self_i32_to_void };
        @compileError("zjs.native.Class method: unsupported signature " ++ @typeName(F) ++ " (SELF_* schema shapes, or fn (*Self, *Call) E!JSValue)");
    };
    return .{ .template = .{
        .target = shape.target,
        .kind = .method_leaf,
        .sig = shape.sig,
        .effect = core.native_entry.Effect.leaf,
        .arity = @intCast(n),
    } };
}

/// K3 getter: typed `fn (*Self) f64|i32` (class check + unwrap + boxing in
/// the thunk) or managed `fn (*Self, *Call) E!JSValue`.
pub fn getterSpec(comptime Self: type, comptime f: anytype) Spec {
    const F = @TypeOf(f);
    selfParamCheck(Self, F, "getter");
    const info = @typeInfo(F).@"fn";
    const params = info.params;
    const Ret = info.return_type.?;
    // Typed shapes take the VM-side K3 typed arm (design §4.4: the entry's
    // `sig` selects the SELF_* prototype; the VM does the class check, the
    // unwrap and the boxing, with no backtrace marker or preflight -- a leaf).
    if (params.len == 1 and (Ret == f64 or Ret == i32)) {
        const legacy = exec.native_legacy;
        const T = struct {
            fn self_to_f64(raw: *anyopaque) callconv(.c) f64 {
                return f(selfOf(Self, raw));
            }
            fn self_to_i32(raw: *anyopaque) callconv(.c) i32 {
                return f(selfOf(Self, raw));
            }
        };
        return .{ .template = .{
            .target = if (Ret == f64) NativeEntry.code(&T.self_to_f64) else NativeEntry.code(&T.self_to_i32),
            .kind = .getter,
            .sig = if (Ret == f64) legacy.sig_self_to_f64 else legacy.sig_self_to_i32,
            .effect = core.native_entry.Effect.leaf,
            .arity = 0,
        } };
    }
    const Thunk = struct {
        fn thunk(ctx: *core.JSContext, this: JSValue, entry: *const NativeEntry) callconv(.c) JSValue {
            const dispatch = exec.builtin_dispatch;
            const raw_self = dispatch.nativeReceiverSelfOrThrow(ctx, this, entry) orelse return JSValue.exception();
            const self = selfOf(Self, raw_self);
            if (params.len == 2 and params[1].type == *Call) {
                var call = Call{
                    .ctx = JSContext.borrowCore(ctx),
                    .this = this,
                    .argv = undefined,
                    .argc = 0,
                    .entry = entry,
                    .func_obj = null,
                };
                if (@typeInfo(Ret) == .error_union) {
                    return f(self, &call) catch |err| return dispatch.embedderErrorToValue(ctx, err);
                }
                return f(self, &call);
            } else if (params.len == 1 and Ret == f64) {
                return exec.value_ops.numberToValue(f(self));
            } else if (params.len == 1 and Ret == i32) {
                return JSValue.int32(f(self));
            } else if (params.len == 1 and Ret == bool) {
                return JSValue.boolean(f(self));
            } else {
                @compileError("zjs.native.Class getter: unsupported signature " ++ @typeName(F) ++ " (fn (*Self) f64|i32|bool, or fn (*Self, *Call) E!JSValue)");
            }
        }
    };
    return .{ .template = .{ .target = NativeEntry.code(&Thunk.thunk), .kind = .getter, .arity = 0 } };
}

/// K3 setter: typed `fn (*Self, f64|i32|bool) void` (canonical marshal, no
/// coercion: a mismatch throws TypeError) or managed `fn (*Self, *Call)
/// E!void` with the value as `call.arg(0)`.
pub fn setterSpec(comptime Self: type, comptime f: anytype) Spec {
    const F = @TypeOf(f);
    selfParamCheck(Self, F, "setter");
    const info = @typeInfo(F).@"fn";
    const params = info.params;
    const Ret = info.return_type.?;
    if (params.len != 2) @compileError("zjs.native.Class setter: expected fn (*Self, value) void, got " ++ @typeName(F));
    // Typed shapes: VM-side K3 typed arm (canonical marshal by the VM).
    if ((params[1].type == f64 or params[1].type == i32) and Ret == void) {
        const legacy = exec.native_legacy;
        const T = struct {
            fn self_f64_to_void(raw: *anyopaque, a: f64) callconv(.c) void {
                f(selfOf(Self, raw), a);
            }
            fn self_i32_to_void(raw: *anyopaque, a: i32) callconv(.c) void {
                f(selfOf(Self, raw), a);
            }
        };
        const is_f64 = params[1].type == f64;
        return .{ .template = .{
            .target = if (is_f64) NativeEntry.code(&T.self_f64_to_void) else NativeEntry.code(&T.self_i32_to_void),
            .kind = .setter,
            .sig = if (is_f64) legacy.sig_self_f64_to_void else legacy.sig_self_i32_to_void,
            .effect = core.native_entry.Effect.leaf,
            .arity = 1,
        } };
    }
    const Thunk = struct {
        fn thunk(ctx: *core.JSContext, this: JSValue, new_value: JSValue, entry: *const NativeEntry) callconv(.c) JSValue {
            const dispatch = exec.builtin_dispatch;
            const raw_self = dispatch.nativeReceiverSelfOrThrow(ctx, this, entry) orelse return JSValue.exception();
            const self = selfOf(Self, raw_self);
            const Arg = params[1].type.?;
            if (Arg == *Call) {
                const argv = [_]JSValue{new_value};
                var call = Call{
                    .ctx = JSContext.borrowCore(ctx),
                    .this = this,
                    .argv = &argv,
                    .argc = 1,
                    .entry = entry,
                    .func_obj = null,
                };
                if (@typeInfo(Ret) == .error_union) {
                    f(self, &call) catch |err| return dispatch.embedderErrorToValue(ctx, err);
                } else {
                    f(self, &call);
                }
                return JSValue.undefinedValue();
            } else if (Arg == f64) {
                const x = dispatch.marshalF64(new_value) orelse return dispatch.throwTypeErrorSentinel(ctx, "number expected");
                f(self, x);
                return JSValue.undefinedValue();
            } else if (Arg == i32) {
                const x = dispatch.marshalI32(new_value) orelse return dispatch.throwTypeErrorSentinel(ctx, "int32 expected");
                f(self, x);
                return JSValue.undefinedValue();
            } else if (Arg == bool) {
                const x = new_value.asBool() orelse return dispatch.throwTypeErrorSentinel(ctx, "boolean expected");
                f(self, x);
                return JSValue.undefinedValue();
            } else {
                @compileError("zjs.native.Class setter: unsupported signature " ++ @typeName(F) ++ " (fn (*Self, f64|i32|bool) void, or fn (*Self, *Call) E!void)");
            }
        }
    };
    return .{ .template = .{ .target = NativeEntry.code(&Thunk.thunk), .kind = .setter, .arity = 1 } };
}

test "Class member tables classify typed and managed shapes" {
    const State = struct {
        n: i32 = 0,
        fn step(self: *@This(), dt: i32) i32 {
            self.n += 1;
            return dt + 1;
        }
        fn query(self: *@This(), call: *Call) JSValue {
            _ = self;
            return call.arg(0);
        }
        fn time(self: *@This()) f64 {
            return @floatFromInt(self.n);
        }
        fn setTime(self: *@This(), t: f64) void {
            self.n = @intFromFloat(t);
        }
    };
    const C = Class(.{
        .name = "Probe",
        .Self = State,
        .methods = .{ .step = State.step, .query = State.query },
        .getters = .{ .time = State.time },
        .setters = .{ .time = State.setTime },
    });
    try std.testing.expectEqual(@as(usize, 2), C.methods.len);
    try std.testing.expectEqual(core.native_entry.Kind.method_leaf, C.methods[0].spec.template.kind);
    try std.testing.expectEqual(exec.native_legacy.sig_self_i32_to_i32, C.methods[0].spec.template.sig);
    try std.testing.expectEqual(core.native_entry.Kind.method_managed, C.methods[1].spec.template.kind);
    try std.testing.expectEqual(core.native_entry.Kind.getter, C.getters[0].spec.template.kind);
    try std.testing.expectEqual(core.native_entry.Kind.setter, C.setters[0].spec.template.kind);
    try std.testing.expectEqualStrings("time", C.setters[0].name);
    try std.testing.expect(!C.has_constructor);
}

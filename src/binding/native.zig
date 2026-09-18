//! Host-function registration: a comptime `callconv(.c)` thunk over a plain
//! Zig function becomes the `NativeEntry.target`, so a host function is
//! dispatched exactly like a builtin. CLI, test262, and in-repo tests
//! install functions with `managed`. There is no per-call arena, handle
//! scope, marshalling framework, or registry lookup.
//!
//! Rooting: every `JSValue` in `argv` stays alive for the duration of the
//! call (the machine's operand window); values the function creates are
//! covered by the conservative native-stack scan while they live in locals.
//! Only cross-call retention needs a persistent handle.

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

/// One managed call. Built on the C stack by the thunk; never outlives
/// the call.
pub const Call = struct {
    /// Non-owning facade for the callee realm.
    ctx: JSContext,
    this: JSValue,
    argv: [*]const JSValue,
    argc: u32,
    entry: *const NativeEntry,
    /// The callee function object (null only for engine-internal synthetic
    /// invocations, which never reach a host function).
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
    /// passed to eval / callFunction), if any.
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

/// Registration-side description produced by `managed` and consumed by
/// `JSContext.defineFunction` / `createFunction`. Comptime constant;
/// `state` / `finalize` are per-registration options.
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

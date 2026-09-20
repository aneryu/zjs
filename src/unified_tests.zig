//! Unified test root. Zig collects `test` declarations from the root module
//! only, so the engine (`src/internal_root.zig`) and the stress + CLI test
//! families all have to sit in this one module. The CLI executable's root is
//! `src/cli/zjs.zig`, so the engine root itself must never import `src/cli/`
//! or `src/stress.zig`; this file is the only place that does.
//!
//! `@import("zjs")` resolves to this file in the unified build (the module
//! imports itself), so every public declaration of `internal_root.zig` is
//! mirrored here. The comptime check at the bottom fails the build if the
//! mirror drifts.

const internal = @import("internal_root.zig");

pub const public_api = internal.public_api;
pub const native = internal.native;
pub const platform_clock = internal.platform_clock;
pub const RuntimeError = internal.RuntimeError;
pub const HostError = internal.HostError;
pub const JSRuntime = internal.JSRuntime;
pub const JSContext = internal.JSContext;
pub const JSValue = internal.JSValue;
pub const Object = internal.Object;
pub const Descriptor = internal.Descriptor;
pub const Atom = internal.Atom;
pub const JSValueHandle = internal.JSValueHandle;
pub const LocalHandle = internal.LocalHandle;
pub const HandleScope = internal.HandleScope;
pub const WeakPersistent = internal.WeakPersistent;
pub const WeakPersistentValue = internal.WeakPersistentValue;
pub const NativePin = internal.NativePin;
pub const RuntimeMemoryUsage = internal.RuntimeMemoryUsage;
pub const JSString = internal.JSString;
pub const JSBytes = internal.JSBytes;
pub const SharedArrayBufferRef = internal.SharedArrayBufferRef;
pub const GCPolicy = internal.GCPolicy;
pub const GCStats = internal.GCStats;
pub const EvalOptions = internal.EvalOptions;
pub const EvalTiming = internal.EvalTiming;
pub const DataPropertyOptions = internal.DataPropertyOptions;
pub const core = internal.core;
pub const sort_erased = internal.sort_erased;
pub const parser = internal.parser;
pub const simple_token = internal.simple_token;
pub const bytecode = internal.bytecode;
pub const exec = internal.exec;
pub const libs = internal.libs;
pub const runtime = internal.runtime;
pub const compiler = internal.compiler;
pub const test262_host = internal.test262_host;
pub const testing = internal.testing;
pub const printSmallInlineProbe = internal.printSmallInlineProbe;

comptime {
    for (@typeInfo(internal).@"struct".decls) |decl| {
        if (!@hasDecl(@This(), decl.name))
            @compileError("src/unified_tests.zig must mirror internal_root." ++ decl.name);
    }
}

test {
    _ = internal;
    _ = @import("stress.zig");
    _ = @import("cli/zjs.zig");
    _ = @import("cli/run_test262.zig");
}

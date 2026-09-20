//! Internal engine root. `src/root.zig` is the CLI / run-test262 host
//! facade (`public_api`); CLI, ReleaseFast artifacts, and the unified Zig
//! test suite compile against this file.

const public_root = @import("root.zig");

pub const public_api = public_root;
pub const native = @import("native.zig");
const js_context = @import("js_context.zig");
/// Monotonic/wall clocks. The CLI roots are their own modules and cannot
/// reach `src/platform_clock.zig` directly, which is how `zjs.zig` ended up
/// with an inlined copy of `monotonicNanos`.
pub const platform_clock = @import("platform_clock.zig");

pub const RuntimeError = exec.exceptions.RuntimeError;
pub const HostError = exec.exceptions.HostError;
pub const JSRuntime = core.JSRuntime;
pub const JSContext = js_context.JSContext;
pub const JSValue = core.JSValue;
pub const Object = core.Object;
pub const Descriptor = core.Descriptor;
pub const Atom = core.Atom;
pub const JSValueHandle = core.JSValueHandle;
pub const LocalHandle = core.LocalHandle;
pub const HandleScope = core.HandleScope;
pub const WeakPersistent = core.WeakPersistent;
pub const WeakPersistentValue = core.WeakPersistentValue;
pub const NativePin = core.NativePin;
pub const RuntimeMemoryUsage = core.RuntimeMemoryUsage;
pub const JSString = core.JSValue.String;
pub const JSBytes = core.JSValue.Bytes;
pub const SharedArrayBufferRef = core.SharedArrayBufferRef;
pub const GCPolicy = core.GCPolicy;
pub const GCStats = core.GCStats;

pub const EvalOptions = core.context.EvalOptions;
pub const EvalTiming = core.context.EvalTiming;
pub const DataPropertyOptions = core.DataPropertyOptions;

pub const core = @import("core/root.zig");
/// Internal type-erased heap. Not part of the public embedder API.
pub const sort_erased = @import("core/sort_erased.zig");
pub const parser = @import("parser.zig");
pub const simple_token = @import("simple_token.zig");
pub const bytecode = @import("bytecode.zig");
pub const exec = @import("exec/root.zig");
pub const libs = @import("libs/root.zig");
pub const runtime = @import("event_loop.zig");
pub const compiler = @import("compiler/root.zig");
/// Test262 `$262` host and agent coordinator. Shared by the `run-test262`
/// CLI and the in-tree test helpers; it depends only on the engine.
pub const test262_host = @import("test262_host.zig");
/// In-tree test helpers (`TestEngine`, fixtures). Test-only; the stress and
/// CLI test families reach it through this export because they live in the
/// unified test root module, not in the engine module.
pub const testing = @import("testing.zig");

/// Internal CLI probe. The public embedder root does not export this.
/// Named for what it does (print to stderr); the exec helper is unchanged.
pub fn printSmallInlineProbe() void {
    exec.small_inline.printProbe();
}

test {
    const std = @import("std");

    try std.testing.expect(Object == core.Object);
    try std.testing.expect(@hasDecl(Object, "create"));
    try std.testing.expect(!@hasDecl(public_api, "object"));
    try std.testing.expect(!@hasDecl(public_api, "core"));

    _ = core;
    _ = parser;
    _ = simple_token;
    _ = bytecode;
    _ = exec;
    _ = libs;
    _ = runtime;
}

test "zjs.pull_test_modules" {
    const std = @import("std");
    const builtin = @import("builtin");
    const raw = std.c.getenv("ZJS_TEST_FILTER") orelse return;
    const filter = std.mem.span(raw);
    if (filter.len == 0) return;
    var matched: usize = 0;
    for (builtin.test_functions) |t| {
        if (std.mem.endsWith(u8, t.name, "zjs.pull_test_modules")) continue;
        if (std.mem.indexOf(u8, t.name, filter) != null) matched += 1;
    }
    if (matched == 0) return error.TestUnexpectedResult;
}

//! Engine module imported as `@import("zjs")`.
//!
//! Embedders use `Runtime`, `Context`, `Value`, `Call`, and `EventLoop`.
//! The same module also re-exports engine layers for the CLI and in-tree
//! tests. The test262 `$262` host lives in `src/cli/run_test262_host.zig`
//! and is imported as `test262_host`, not from this module. Cookbook and
//! embedding examples must stay on the embedder names; they are not a
//! second object model.
const std = @import("std");
const js_context = @import("js_context.zig");
const event_loop = @import("event_loop.zig");

pub const native = @import("native.zig");
/// Monotonic/wall clocks. The CLI roots are their own modules and cannot
/// reach `src/platform_clock.zig` directly, which is how `zjs.zig` ended up
/// with an inlined copy of `monotonicNanos`.
pub const platform_clock = @import("platform_clock.zig");
pub const core = @import("core/root.zig");
/// Internal type-erased heap. Not part of the public embedder API.
pub const sort_erased = @import("core/sort_erased.zig");
pub const parser = @import("parser.zig");
pub const simple_token = @import("simple_token.zig");
pub const bytecode = @import("bytecode.zig");
pub const exec = @import("exec/root.zig");
pub const libs = @import("libs/root.zig");
pub const runtime = event_loop;
pub const compiler = @import("compiler/root.zig");
pub const Runtime = core.JSRuntime;
pub const Context = js_context.JSContext;
pub const Value = core.JSValue;
pub const Call = native.Call;
pub const EventLoop = event_loop.EventLoop;

pub const GCStats = core.GCStats;
pub const GCDetailedStats = core.GCDetailedStats;
pub const GCPauseDistribution = core.GCPauseDistribution;
pub const RuntimeOptions = core.RuntimeOptions;
pub const MicrotaskPolicy = core.runtime.MicrotaskPolicy;
pub const MicrotaskScope = core.runtime.MicrotaskScope;
pub const MicrotaskExceptionHandler = core.runtime.MicrotaskExceptionHandler;
pub const RuntimeMemoryUsage = core.RuntimeMemoryUsage;
pub const OpcodeProfile = core.OpcodeProfile;
pub const default_stack_size = core.runtime.default_stack_size;
pub const default_gc_threshold = core.runtime.default_gc_threshold;

/// True when this binary carries per-opcode profiling scopes
/// (-Dzjs_enable_opcode_profile / the zjs-profile artifact). The CLI fails
/// closed on --profile-opcodes when false instead of emitting zero counts.
pub const opcode_profile_build_enabled: bool = @import("build_options").zjs_enable_opcode_profile;

pub fn activateOpcodeProfile(profile: ?*OpcodeProfile) ?*OpcodeProfile {
    core.profile.setOpcodeNameProvider(exec.opcodeName);
    return core.profile.activate(profile);
}

pub const RuntimeError = exec.exceptions.RuntimeError;
pub const HostError = exec.exceptions.HostError;
pub const JSRuntime = core.JSRuntime;
pub const JSContext = js_context.JSContext;
pub const borrowContext = js_context.borrowCore;
pub const globalObjectPtr = js_context.globalObjectPtr;
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
pub const JSString = core.JSValue.String;
pub const JSBytes = core.JSValue.Bytes;
pub const SharedArrayBufferRef = core.SharedArrayBufferRef;
pub const GCPolicy = core.GCPolicy;

pub const EvalOptions = core.context.EvalOptions;
pub const EvalTiming = core.context.EvalTiming;
pub const DataPropertyOptions = core.DataPropertyOptions;

/// Internal CLI probe. Named for what it does (print to stderr); the exec
/// helper is unchanged.
pub fn printSmallInlineProbe() void {
    exec.small_inline.printProbe();
}

test {
    try std.testing.expect(Object == core.Object);
    try std.testing.expect(@hasDecl(Object, "create"));

    _ = js_context;
    _ = native;
    _ = event_loop;
    _ = core;
    _ = parser;
    _ = simple_token;
    _ = bytecode;
    _ = exec;
    _ = libs;
    _ = runtime;
}

test "root exposes the embedder names and engine layers" {
    try std.testing.expect(@hasDecl(@This(), "Runtime"));
    try std.testing.expect(@hasDecl(@This(), "Context"));
    try std.testing.expect(@hasDecl(@This(), "Value"));
    try std.testing.expect(@hasDecl(@This(), "Call"));
    try std.testing.expect(@hasDecl(@This(), "EventLoop"));
    try std.testing.expect(@hasDecl(Context, "EvalMode"));
    try std.testing.expect(@hasDecl(Context, "EvalTiming"));
    try std.testing.expect(@hasDecl(Context, "FunctionOptions"));
    try std.testing.expect(@hasDecl(Context, "defineScriptArgs"));
    try std.testing.expect(@hasDecl(EventLoop, "runUntilIdle"));
    try std.testing.expect(@hasDecl(EventLoop, "Options"));
    try std.testing.expect(@hasDecl(EventLoop, "RunResult"));

    try std.testing.expect(Runtime == JSRuntime);
    try std.testing.expect(Context == JSContext);
    try std.testing.expect(Value == JSValue);
    try std.testing.expect(@hasDecl(@This(), "native"));
    try std.testing.expect(@hasDecl(@This(), "core"));
    try std.testing.expect(@hasDecl(@This(), "exec"));
    try std.testing.expect(@hasDecl(@This(), "parser"));
    try std.testing.expect(@hasDecl(@This(), "runtime"));
    try std.testing.expect(!@hasDecl(@This(), "test262_host"));

    try std.testing.expect(!@hasDecl(@This(), "testing"));
    try std.testing.expect(!@hasDecl(@This(), "public_api"));
    try std.testing.expect(!@hasDecl(@This(), "host"));
    try std.testing.expect(!@hasDecl(@This(), "context"));
    try std.testing.expect(!@hasDecl(@This(), "value"));
    try std.testing.expect(!@hasDecl(@This(), "object"));
    try std.testing.expect(!@hasDecl(@This(), "module"));
    try std.testing.expect(!@hasDecl(@This(), "job"));
    try std.testing.expect(!@hasDecl(@This(), "internal"));
    try std.testing.expect(!@hasDecl(@This(), "CallSite"));
    try std.testing.expect(!@hasDecl(@This(), "PropertySite"));
    try std.testing.expect(!@hasDecl(Value, "Scope"));
}

test "zjs.pull_test_modules" {
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

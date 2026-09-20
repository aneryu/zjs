//! Host facade used by the CLI and `run-test262`.
//!
//! Production binaries compile against `src/internal_root.zig` and reach this
//! module as `public_api`. Downstream `@import("zjs")` uses this file directly.
//! It re-exports the types those two programs need and the `scriptArgs` helper
//! the CLI installs; it does not wrap core Object, Buffer borrows, job drain,
//! or a second value-constructor namespace.
const std = @import("std");
const js_context = @import("js_context.zig");
pub const runtime = @import("event_loop.zig");
const zjs_core = @import("core/root.zig");
const zjs_exec = @import("exec/root.zig");
const CoreObject = zjs_core.Object;

pub const JSRuntime = zjs_core.JSRuntime;
pub const GCStats = zjs_core.GCStats;
pub const GCPauseDistribution = zjs_core.GCPauseDistribution;
pub const JSContext = js_context.JSContext;
pub const JSValue = zjs_core.JSValue;
pub const RuntimeOptions = zjs_core.RuntimeOptions;
pub const RuntimeMemoryUsage = zjs_core.RuntimeMemoryUsage;
pub const OpcodeProfile = zjs_core.OpcodeProfile;
pub const default_stack_size = zjs_core.runtime.default_stack_size;
pub const default_gc_threshold = zjs_core.runtime.default_gc_threshold;

/// True when this binary carries per-opcode profiling scopes
/// (-Dzjs_enable_opcode_profile / the zjs-profile artifact). The CLI fails
/// closed on --profile-opcodes when false instead of emitting zero counts.
pub const opcode_profile_build_enabled: bool = @import("build_options").zjs_enable_opcode_profile;

pub fn activateOpcodeProfile(profile: ?*OpcodeProfile) ?*OpcodeProfile {
    zjs_core.profile.setOpcodeNameProvider(zjs_exec.opcodeName);
    return zjs_core.profile.activate(profile);
}

pub const native = @import("native.zig");

pub const host = struct {
    pub fn defineScriptArgs(ctx: *JSContext, args: []const []const u8) !void {
        try defineStringArrayGlobal(ctx, "scriptArgs", args);
    }
};

pub const context = struct {
    pub const Options = zjs_core.ContextOptions;
    pub const EvalMode = zjs_core.EvalMode;
    pub const EvalOptions = zjs_core.EvalOptions;
    pub const EvalTiming = zjs_core.EvalTiming;
};

fn defineStringArrayGlobal(ctx: *JSContext, name: []const u8, items: []const []const u8) !void {
    const rt = ctx.runtimePtr();
    const global = try ctx.globalObject();
    if (items.len == 0) {
        const key = try rt.internAtom(name);
        try global.defineEmptyArrayAutoInitProperty(rt, key, zjs_core.property.Flags.data(.all), global);
        return;
    }

    const array_prototype = cachedArrayPrototype(rt, global) orelse try constructorPrototypeObjectByAtom(global, zjs_core.atom.ids.Array);
    const array = try CoreObject.createArrayWithOwnPropertyCapacity(rt, array_prototype, items.len);
    for (items, 0..) |item, index| {
        const item_value = try ctx.createString(item);
        try array.defineOwnProperty(rt, zjs_core.Atom.taggedInt(@intCast(index)), zjs_core.Descriptor.data(item_value, .all));
    }
    array.setArrayLength(@intCast(items.len));
    const key = try rt.internAtom(name);
    try global.defineOwnProperty(rt, key, zjs_core.Descriptor.data(array.value(), .all));
}

fn cachedArrayPrototype(rt: *JSRuntime, global: *CoreObject) ?*CoreObject {
    const stored = global.cachedRealmValue(rt, .array_prototype) orelse return null;
    return objectFromValue(stored);
}

fn constructorPrototypeObjectByAtom(global: *CoreObject, key: zjs_core.Atom) !?*CoreObject {
    const constructor_value = try global.getProperty(key);
    const constructor = objectFromValue(constructor_value) orelse return null;
    const prototype_value = try constructor.getProperty(zjs_core.atom.ids.prototype);
    return objectFromValue(prototype_value);
}

fn objectFromValue(v: JSValue) ?*CoreObject {
    if (!v.is(.object)) return null;
    const header = v.refHeader() orelse return null;
    if (header.meta().flags.kind != .object) return null;
    return CoreObject.fromHeader(header);
}

test "host defineScriptArgs materializes empty array on first read" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try JSContext.create(rt, .{});
    defer ctx.destroy();

    try host.defineScriptArgs(ctx, &.{"stale"});
    try host.defineScriptArgs(ctx, &.{});
    try host.defineScriptArgs(ctx, &.{});
    const result = try ctx.eval(
        \\var desc = Object.getOwnPropertyDescriptor(globalThis, "scriptArgs");
        \\desc.writable === true &&
        \\desc.enumerable === true &&
        \\desc.configurable === true &&
        \\Array.isArray(desc.value) &&
        \\desc.value.length === 0 &&
        \\Object.getPrototypeOf(scriptArgs) === Array.prototype &&
        \\(scriptArgs.push("ok"), scriptArgs.length === 1 && scriptArgs[0] === "ok") &&
        \\delete globalThis.scriptArgs &&
        \\!("scriptArgs" in globalThis);
    , .{});
    try std.testing.expectEqual(true, result.as(.boolean).?);
}

test "host defineScriptArgs installs string items" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try JSContext.create(rt, .{});
    defer ctx.destroy();

    try host.defineScriptArgs(ctx, &.{ "a.js", "--flag" });
    const result = try ctx.eval(
        \\Array.isArray(scriptArgs) &&
        \\scriptArgs.length === 2 &&
        \\scriptArgs[0] === "a.js" &&
        \\scriptArgs[1] === "--flag" &&
        \\Object.getPrototypeOf(scriptArgs) === Array.prototype;
    , .{});
    try std.testing.expectEqual(true, result.as(.boolean).?);
}

test {
    _ = js_context;
    _ = native;
    _ = runtime;
}

test "root exposes the CLI and run-test262 surface" {
    try std.testing.expect(@hasDecl(@This(), "JSRuntime"));
    try std.testing.expect(@hasDecl(@This(), "JSContext"));
    try std.testing.expect(@hasDecl(@This(), "JSValue"));
    try std.testing.expect(@hasDecl(@This(), "native"));
    try std.testing.expect(@hasDecl(@This(), "runtime"));
    try std.testing.expect(@hasDecl(@This(), "host"));
    try std.testing.expect(@hasDecl(host, "defineScriptArgs"));
    try std.testing.expect(@hasDecl(context, "EvalMode"));
    try std.testing.expect(@hasDecl(context, "EvalTiming"));
    try std.testing.expect(@hasDecl(runtime, "EventLoop"));
    try std.testing.expect(@hasDecl(runtime, "runUntilIdle"));

    try std.testing.expect(!@hasDecl(@This(), "value"));
    try std.testing.expect(!@hasDecl(@This(), "object"));
    try std.testing.expect(!@hasDecl(@This(), "module"));
    try std.testing.expect(!@hasDecl(@This(), "job"));
    try std.testing.expect(!@hasDecl(@This(), "core"));
    try std.testing.expect(!@hasDecl(@This(), "exec"));
    try std.testing.expect(!@hasDecl(@This(), "internal"));
    try std.testing.expect(!@hasDecl(host, "defineArgvGlobals"));
    try std.testing.expect(!@hasDecl(host, "evalGlobalScriptSource"));
    try std.testing.expect(!@hasDecl(host, "NativeBinding"));
    try std.testing.expect(!@hasDecl(@This(), "CallSite"));
    try std.testing.expect(!@hasDecl(@This(), "PropertySite"));
    try std.testing.expect(!@hasDecl(native, "leaf"));
    try std.testing.expect(!@hasDecl(native, "Class"));
    try std.testing.expect(!@hasDecl(JSValue, "Scope"));
    try std.testing.expect(!@hasDecl(@This(), "JSValueHandle"));
    try std.testing.expect(!@hasDecl(@This(), "JSBytes"));
    try std.testing.expect(!@hasDecl(@This(), "JSString"));
}

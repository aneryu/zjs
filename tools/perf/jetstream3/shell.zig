//! JetStream diagnostic shell. Host primitives only; workloads remain upstream.
const std = @import("std");
const engine = @import("zjs");
const zjs = engine.binding_root;
comptime {
    engine.config_signature.attest("zjs-jetstream");
}
const State = struct { allocator: std.mem.Allocator, io: std.Io, loop: *engine.runtime.EventLoop };
const limit = 256 * 1024 * 1024;

// Same realm routing contract as src/cli/run_test262_host.zig test262EvalScript.
fn realm(c: *zjs.native.Call) !*zjs.Object {
    return (try c.ctx.functionRealmGlobal(c.func_obj.?.value())) orelse try c.ctx.globalObject();
}
fn source(c: *zjs.native.Call) !zjs.JSValue {
    if (!c.arg(0).isString()) return c.throwTypeError("loadString requires source text");
    return c.ctx.evalScriptValue(c.arg(0), .{ .realm_global = try realm(c), .output = c.output(), .filename = "<loadString>" });
}
fn readBytes(c: *zjs.native.Call) ![]u8 {
    const s = c.state(State);
    if (!c.arg(0).isString()) return c.throwTypeError("file path must be a string");
    const path = try c.ctx.toOwnedUtf8(c.arg(0), s.allocator);
    defer s.allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(s.io, path, s.allocator, .limited(limit)) catch |err| {
        const message = try std.fmt.allocPrint(s.allocator, "cannot read {s}: {s}", .{ path, @errorName(err) });
        defer s.allocator.free(message);
        return c.throwError("Error", message);
    };
}
fn releaseBytes(context: ?*anyopaque, bytes: []u8) void {
    const s: *State = @ptrCast(@alignCast(context.?));
    s.allocator.free(bytes);
}
fn read(c: *zjs.native.Call) !zjs.JSValue {
    const s = c.state(State);
    if (!c.arg(1).isUndefined()) {
        const mode = try c.ctx.toOwnedUtf8(c.arg(1), s.allocator);
        defer s.allocator.free(mode);
        if (!std.mem.eql(u8, mode, "binary")) {
            return c.throwTypeError("read mode must be binary or omitted");
        }
        const bytes = try readBytes(c);
        var backing = zjs.JSBytes.Store.owned(bytes, .{ .deinit = releaseBytes, .context = s });
        errdefer backing.release();
        return c.ctx.arrayBuffer(&backing);
    }
    const bytes = try readBytes(c);
    defer s.allocator.free(bytes);
    return c.ctx.createString(bytes);
}
fn load(c: *zjs.native.Call) !zjs.JSValue {
    const s = c.state(State);
    const bytes = try readBytes(c);
    defer s.allocator.free(bytes);
    const path = try c.ctx.toOwnedUtf8(c.arg(0), s.allocator);
    defer s.allocator.free(path);
    return c.ctx.evalScriptSource(bytes, .{ .realm_global = try realm(c), .output = c.output(), .filename = path });
}
fn runString(c: *zjs.native.Call) !zjs.JSValue {
    if (!c.arg(0).isString()) return c.throwTypeError("runString requires source text");
    const r = try c.ctx.createRealm();
    const global = try c.ctx.realmGlobalObject(r);
    try install(&c.ctx, global, c.state(State));
    _ = try c.ctx.evalScriptValue(c.arg(0), .{ .realm_global = global, .output = c.output(), .filename = "<runString>" });
    return global.value();
}
// Timer scheduling uses the existing host loop; callbacks never run inline.
fn timer(c: *zjs.native.Call) !zjs.JSValue {
    if (!c.ctx.isCallable(c.arg(0))) return c.throwTypeError("timer callback must be callable");
    const delay = try c.ctx.toNumber(c.arg(1));
    const bounded = if (!std.math.isFinite(delay) or delay < 1 or delay > 2147483647) 1 else delay;
    const loop = c.state(State).loop;
    const host = loop.context.hostEventLoop().?;
    const id = host.nextTimerId();
    try host.enqueueTimer(c.ctx.core, id, c.arg(0), @intFromFloat(bounded), (c.arg(2).asBool() orelse return c.throwTypeError("repeat flag must be boolean")));
    return zjs.JSValue.number(@floatFromInt(id));
}
fn clearTimer(c: *zjs.native.Call) !zjs.JSValue {
    const id = try c.ctx.toNumber(c.arg(0));
    if (std.math.isFinite(id) and id >= 1 and id <= 9007199254740991) {
        const loop = c.state(State).loop;
        loop.context.hostEventLoop().?.clearTimer(c.ctx.core, @intFromFloat(id));
    }
    return zjs.JSValue.undefinedValue();
}
fn install(ctx: *zjs.JSContext, global: *zjs.Object, state: *State) !void {
    inline for (.{ .{ "load", load }, .{ "loadString", source }, .{ "read", read }, .{ "readFile", read }, .{ "runString", runString }, .{ "__jetstreamTimer", timer }, .{ "clearTimeout", clearTimer }, .{ "clearInterval", clearTimer } }) |entry| {
        const f = try ctx.createFunction(entry[0], zjs.native.managed(entry[1]), .{ .length = 1, .state = state, .realm_global = global });
        try ctx.defineDataProperty(global.value(), entry[0], f, .{});
    }
    _ = try ctx.evalScriptSource(
        \\(function(schedule, apply) {
        \\globalThis.setTimeout = function(callback, delay, ...args) {
        \\  if (typeof callback !== 'function') throw new TypeError('timer callback must be callable');
        \\  return schedule(() => apply(callback, globalThis, args), delay, false);
        \\};
        \\globalThis.setInterval = function(callback, delay, ...args) {
        \\  if (typeof callback !== 'function') throw new TypeError('timer callback must be callable');
        \\  return schedule(() => apply(callback, globalThis, args), delay, true);
        \\};
        \\})(__jetstreamTimer, Reflect.apply);
    , .{ .realm_global = global, .filename = "<shell-timers>" });
}
fn fail(ctx: *zjs.JSContext, allocator: std.mem.Allocator, err: anyerror) noreturn {
    const value = if (ctx.hasException()) ctx.takeException() else if (ctx.hasUnhandledRejection()) ctx.takeUnhandledRejection() else zjs.JSValue.undefinedValue();
    const text = ctx.toOwnedUtf8(value, allocator) catch "<unprintable>";
    std.debug.print("JetStream shell: {s}: {s}\n", .{ @errorName(err), text });
    std.process.exit(1);
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: zjs-jetstream script.js [arguments]\n", .{});
        std.process.exit(2);
    }
    const rt = try zjs.JSRuntime.create(init.gpa);
    const ctx = try zjs.JSContext.create(rt);
    // Short-lived CLI: OS teardown, matching production CLI normal mode.
    ctx.setPreserveUncaughtException(true);
    ctx.setTrackUnhandledRejections(true);
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    const output = &writer.interface;
    var loop = engine.runtime.EventLoop.init(ctx, .{ .output = output });
    loop.install();
    var state = State{ .allocator = init.gpa, .io = init.io, .loop = &loop };
    const global = try ctx.globalObject();
    try install(ctx, global, &state);
    const script_args = try init.arena.allocator().alloc([]const u8, args.len - 2);
    for (args[2..], 0..) |arg, i| script_args[i] = arg;
    try engine.public_api.host.defineScriptArgs(ctx, script_args);
    _ = try ctx.evalScriptSource("globalThis.arguments = scriptArgs; globalThis.printErr = print;", .{ .output = output });
    var imports = engine.exec.module_graph.DynamicImportState{ .runtime = rt, .output = output, .io = init.io, .allocator = init.gpa, .max_source_size = limit };
    var scope = try engine.exec.module_graph.installDynamicImport(&imports);
    defer scope.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], init.gpa, .limited(limit));
    defer init.gpa.free(bytes);
    _ = ctx.evalScriptSource(bytes, .{ .output = output, .filename = args[1] }) catch |err| {
        try output.flush();
        fail(ctx, init.gpa, err);
    };
    imports.runJobs(ctx.core) catch |err| {
        try output.flush();
        fail(ctx, init.gpa, err);
    };
    try output.flush();
    if (ctx.hasException() or ctx.hasUnhandledRejection()) fail(ctx, init.gpa, error.JSException);
}

//! JS<->native boundary microbench on the public embedding surface (NB2 `zjs.native`).
//!
//! Usage: zjs-boundary-bench <case> [N]
//!        zjs-boundary-bench --list          (prints the supported case names, one per line)
//! Exit codes: 0 ok, 1 failure, 2 unsupported case (sample_embed.py skips those).
//!
//! Cases (each prints one integer so runs can be checksum-compared):
//!   ctrl        JS loop `s += i` (subtract from the others)
//!   builtin     JS loop calling Math.abs (hoisted) -- the in-engine builtin path
//!   host2       JS loop calling a managed host function (zjs.native.managed), 2 int args
//!   host0       JS loop calling a 0-arg managed host function returning undefined
//!   hostm2      JS loop calling the same managed function as a method: host.add(i, 1)
//!   leaf2       JS loop calling a typed leaf (i32, i32) -> i32 host function: host_add_leaf(i, 1)
//!   leaf_state  JS loop calling a typed leaf with state (STATE_I32_TO_I32): host_tick(i)
//!   method_typed   JS loop `world.step(i)`: K2 typed method (zjs.native.Class, fn (*Self, i32) i32)
//!   method_managed JS loop `world.query(i)`: K2 managed method (fn (*Self, *Call) JSValue)
//!   getter_native  JS loop `world.time`: K3 managed getter on the class prototype
//!   getter_typed   JS loop `world.time`: K3 typed getter (fn (*Self) i32)
//!   n2j1 / n2j0  native -> JS one-shot: ctx.callFunction(cb, [i]) / (cb, []) N times
//!   site1 / site0 native -> JS through zjs.CallSite (resolved once): site.call1(i) / site.call0()
//!   prop_site   host loop: ctx.getProperty(obj, "field") N times, s += value
//!
//! Every JS loop is `function main(n) { var s = 0; for (...) { s += <op>; } return s }`.
//!
//! The World cases mirror qjs_boundary_bench.c's opaque class (steps / queries / stride /
//! time_ms; `world.step(i)` = i + stride, `world.time` = time_ms = 1); getter_native and
//! getter_typed run the same JS loop against two class flavours of the `time` getter.
const std = @import("std");
const zjs = @import("zjs");

fn hostAdd(call: *zjs.native.Call) error{JSException}!zjs.JSValue {
    const a = call.arg(0).asInt32() orelse return call.throwTypeError("expected int");
    const b = call.arg(1).asInt32() orelse return call.throwTypeError("expected int");
    return zjs.JSValue.int32(a +% b);
}

/// leaf2: typed leaf `(i32, i32) -> i32`; the VM marshals, the target never sees a JSValue.
fn hostAddLeaf(a: i32, b: i32) i32 {
    return a +% b;
}

const TickState = struct { ticks: i64 = 0, step: i32 = 1 };
var tick_state: TickState = .{};

/// leaf_state: `host_tick(i)` returns i + step and counts (STATE_I32_TO_I32).
fn hostTick(state: *TickState, i: i32) i32 {
    state.ticks += 1;
    return i +% state.step;
}

fn hostNoop(call: *zjs.native.Call) zjs.JSValue {
    _ = call;
    return zjs.JSValue.undefinedValue();
}

const WorldState = struct {
    steps: i64 = 0,
    queries: i64 = 0,
    stride: i32 = 1,
    time_ms: i32 = 1,
};

/// `world.step(i)`: K2 typed method, int in / int out (qjs world_step).
fn worldStep(world: *WorldState, dt: i32) i32 {
    world.steps += 1;
    return dt +% world.stride;
}

/// `world.query(i)`: K2 managed method; returns args[0] unchanged, counts.
fn worldQuery(world: *WorldState, call: *zjs.native.Call) zjs.JSValue {
    world.queries += 1;
    return call.arg(0);
}

/// `world.time` typed getter (fn (*Self) i32).
fn worldTime(world: *WorldState) i32 {
    return world.time_ms;
}

/// `world.time` managed getter (JSValue-returning, the qjs JS_CGETSET_DEF shape).
fn worldTimeManaged(world: *WorldState, call: *zjs.native.Call) zjs.JSValue {
    _ = call;
    return zjs.JSValue.int32(world.time_ms);
}

/// method_typed / method_managed / getter_typed: typed `time` getter.
const WorldTyped = zjs.native.Class(.{
    .name = "World",
    .Self = WorldState,
    .methods = .{ .step = worldStep, .query = worldQuery },
    .getters = .{ .time = worldTime },
});

/// getter_native: the same class with a managed `time` getter.
const WorldManagedGetter = zjs.native.Class(.{
    .name = "WorldM",
    .Self = WorldState,
    .methods = .{ .step = worldStep, .query = worldQuery },
    .getters = .{ .time = worldTimeManaged },
});

var world_state: WorldState = .{};

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}

/// Case names this harness implements; `--list` prints them so the sampler can skip the rest.
const supported_cases = [_][]const u8{ "ctrl", "builtin", "host2", "host0", "hostm2", "leaf2", "leaf_state", "method_typed", "method_managed", "getter_native", "getter_typed", "n2j1", "n2j0", "site1", "site0", "prop_site" };

fn isSupportedCase(name: []const u8) bool {
    for (supported_cases) |c| if (std.mem.eql(u8, c, name)) return true;
    return false;
}

fn jsLoop(comptime op: []const u8) []const u8 {
    return "function main(n) { var s = 0; var abs = Math.abs; for (var i = 0; i < n; i++) { s += " ++ op ++ "; } return s; }";
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    var args_buf: [4][]const u8 = undefined;
    var args_len: usize = 0;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    defer it.deinit();
    while (it.next()) |a| : (args_len += 1) {
        if (args_len == args_buf.len) break;
        args_buf[args_len] = a;
    }
    const args = args_buf[0..args_len];
    if (args.len < 2) fatal("usage: zjs-boundary-bench <case> [N] | --list", .{});
    const case_name = args[1];
    if (std.mem.eql(u8, case_name, "--list")) {
        var list_buffer: [256]u8 = undefined;
        var list_out = std.Io.File.stdout().writer(init.io, &list_buffer);
        for (supported_cases) |name| try list_out.interface.print("{s}\n", .{name});
        try list_out.interface.flush();
        return;
    }
    if (!isSupportedCase(case_name)) {
        std.debug.print("unsupported case {s}\n", .{case_name});
        std.process.exit(2);
    }
    const n: i32 = if (args.len > 2) try std.fmt.parseInt(i32, args[2], 10) else 20_000_000;

    const rt = try zjs.JSRuntime.createWithOptions(allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.JSContext.createWithOptions(rt, .{});
    defer ctx.destroy();
    ctx.setPreserveUncaughtException(true);

    _ = try ctx.defineFunction("host_add", zjs.native.managed(hostAdd), .{ .length = 2 });
    _ = try ctx.defineFunction("host_noop", zjs.native.managed(hostNoop), .{ .length = 0 });
    _ = try ctx.defineFunction("host_add_leaf", zjs.native.leaf(hostAddLeaf), .{});
    _ = try ctx.defineFunction("host_tick", zjs.native.leafWithState(hostTick), .{ .state = @ptrCast(&tick_state) });
    {
        // hostm2: the same managed function reached as a method `host.add(i, 1)`.
        const host_obj = try ctx.createObject();
        const add_fn = try ctx.createFunction("add", zjs.native.managed(hostAdd), .{ .length = 2 });
        try ctx.defineDataProperty(host_obj, "add", add_fn, .{});
        const g = try ctx.globalObject();
        try ctx.defineDataProperty(g.value(), "host", host_obj, .{});
        // World (method_typed / method_managed / getter_*): a native class
        // instance wrapping `world_state`; getter_native swaps in the class
        // whose `time` getter is managed.
        const world_obj = if (std.mem.eql(u8, case_name, "getter_native"))
            try (try ctx.defineClass(WorldManagedGetter, .{ .global_name = "WorldM" })).create(ctx, &world_state)
        else
            try (try ctx.defineClass(WorldTyped, .{ .global_name = "World" })).create(ctx, &world_state);
        try ctx.defineDataProperty(g.value(), "world", world_obj, .{});
    }

    const host_loop = std.mem.startsWith(u8, case_name, "n2j") or std.mem.startsWith(u8, case_name, "site") or std.mem.eql(u8, case_name, "prop_site");
    const source: []const u8 = if (std.mem.eql(u8, case_name, "ctrl"))
        jsLoop("i")
    else if (std.mem.eql(u8, case_name, "builtin"))
        jsLoop("abs(i)")
    else if (std.mem.eql(u8, case_name, "host2"))
        jsLoop("host_add(i, 1)")
    else if (std.mem.eql(u8, case_name, "host0"))
        jsLoop("(host_noop(), i)")
    else if (std.mem.eql(u8, case_name, "hostm2"))
        jsLoop("host.add(i, 1)")
    else if (std.mem.eql(u8, case_name, "leaf2"))
        jsLoop("host_add_leaf(i, 1)")
    else if (std.mem.eql(u8, case_name, "leaf_state"))
        jsLoop("host_tick(i)")
    else if (std.mem.eql(u8, case_name, "method_typed"))
        jsLoop("world.step(i)")
    else if (std.mem.eql(u8, case_name, "method_managed"))
        jsLoop("world.query(i)")
    else if (std.mem.eql(u8, case_name, "getter_native") or std.mem.eql(u8, case_name, "getter_typed"))
        jsLoop("world.time")
    else if (std.mem.eql(u8, case_name, "n2j1") or std.mem.eql(u8, case_name, "site1"))
        "function cb(x) { return x + 1; }"
    else if (std.mem.eql(u8, case_name, "n2j0") or std.mem.eql(u8, case_name, "site0"))
        "function cb() {}"
    else if (std.mem.eql(u8, case_name, "prop_site"))
        "var obj = { x: 1, y: 2, field: 3 };"
    else
        unreachable; // filtered by isSupportedCase above

    const eval_result = try ctx.eval(source, .{
        .mode = .script,
        .filename = "<boundary>",
        .output = null,
        .discard_script_result = true,
    });
    if (eval_result.isException()) fatal("eval threw", .{});

    const global = try ctx.globalObject();
    var stdout_buffer: [256]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    if (host_loop) {
        var s: i64 = 0;
        var i: i32 = 0;
        if (std.mem.eql(u8, case_name, "site1")) {
            // CallSite: resolved once, call1 per iteration.
            const cb = try ctx.getProperty(global.value(), "cb");
            var site = try zjs.CallSite.init(ctx, cb, .{});
            defer site.deinit();
            while (i < n) : (i += 1) {
                const r = try site.call1(zjs.JSValue.int32(i));
                s += r.asInt32() orelse fatal("cb returned non-int", .{});
            }
        } else if (std.mem.eql(u8, case_name, "site0")) {
            const cb = try ctx.getProperty(global.value(), "cb");
            var site = try zjs.CallSite.init(ctx, cb, .{});
            defer site.deinit();
            while (i < n) : (i += 1) {
                const r = try site.call0();
                if (r.isException()) fatal("cb threw", .{});
                s += i;
            }
        } else if (std.mem.eql(u8, case_name, "n2j1")) {
            const cb = try ctx.getProperty(global.value(), "cb");
            while (i < n) : (i += 1) {
                const arg = [_]zjs.JSValue{zjs.JSValue.int32(i)};
                const r = try ctx.callFunction(cb, &arg, .{});
                s += r.asInt32() orelse fatal("cb returned non-int", .{});
            }
        } else if (std.mem.eql(u8, case_name, "prop_site")) {
            const obj = try ctx.getProperty(global.value(), "obj");
            while (i < n) : (i += 1) {
                const v = try ctx.getProperty(obj, "field");
                s += v.asInt32() orelse fatal("field non-int", .{});
            }
        } else {
            const cb = try ctx.getProperty(global.value(), "cb");
            while (i < n) : (i += 1) {
                const r = try ctx.callFunction(cb, &.{}, .{});
                if (r.isException()) fatal("cb threw", .{});
                s += i;
            }
        }
        try out.interface.print("{d}\n", .{s});
        try out.interface.flush();
        return;
    }

    const main_fn = try ctx.getProperty(global.value(), "main");
    const arg = [_]zjs.JSValue{zjs.JSValue.int32(n)};
    const r = try ctx.callFunction(main_fn, &arg, .{});
    if (r.isException()) fatal("main threw", .{});
    const f = r.asFloat64() orelse @as(f64, @floatFromInt(r.asInt32() orelse fatal("main returned non-number", .{})));
    try out.interface.print("{d}\n", .{@as(i64, @intFromFloat(f))});
    try out.interface.flush();
}

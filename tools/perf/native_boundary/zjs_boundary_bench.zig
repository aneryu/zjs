//! JS<->native boundary microbench on the public embedding surface.
//!
//! Usage: zjs-boundary-bench <case> [N] [plugin-so-path]
//!
//! Cases (each prints one integer so runs can be checksum-compared):
//!   ctrl        JS loop `s += i` (subtract from the others)
//!   builtin     JS loop calling Math.abs (hoisted) -- the in-engine builtin path
//!   host2       JS loop calling a host function registered with defineGlobalFunction, 2 int args
//!   host0       JS loop calling a 0-arg host function returning undefined
//!   hostm2      JS loop calling the same external function as a method: host.add(i, 1)
//!   plugin2     JS loop calling `plugin.add(i, 1)` installed from the runtime plugin fixture
//!   n2j1        native -> JS: callFunction(cb, [i]) N times from Zig, cb = function (x) { return x + 1 }
//!   n2j0        native -> JS: callFunction(cb, []) N times, cb = function () {}
//!
//! Every JS loop is `function main(n) { var s = 0; for (...) { s += <op>; } return s }`.
const std = @import("std");
const zjs = @import("zjs");

fn hostAdd(_: *anyopaque, call: zjs.binding_root.ExternalHostCall) anyerror!zjs.JSValue {
    if (call.args.len < 2) return error.TypeError;
    const a = call.args[0].asInt32() orelse return error.TypeError;
    const b = call.args[1].asInt32() orelse return error.TypeError;
    return zjs.JSValue.int32(a +% b);
}

fn hostNoop(_: *anyopaque, call: zjs.binding_root.ExternalHostCall) anyerror!zjs.JSValue {
    _ = call;
    return zjs.JSValue.undefinedValue();
}

var host_state: u8 = 0;

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
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
    if (args.len < 2) fatal("usage: zjs-boundary-bench <case> [N] [plugin.so]", .{});
    const case_name = args[1];
    const n: i32 = if (args.len > 2) try std.fmt.parseInt(i32, args[2], 10) else 20_000_000;

    const rt = try zjs.JSRuntime.createWithOptions(allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.JSContext.createWithOptions(rt, .{});
    defer ctx.destroy();
    ctx.setPreserveUncaughtException(true);

    try ctx.defineGlobalFunction("host_add", 2, @ptrCast(&host_state), hostAdd, null);
    try ctx.defineGlobalFunction("host_noop", 0, @ptrCast(&host_state), hostNoop, null);
    {
        // hostm2: the same external function reached as a method `host.add(i, 1)`.
        const host_obj = try ctx.createObject();
        const add_fn = try ctx.createExternalFunction("add", 2, @ptrCast(&host_state), hostAdd, null, .{});
        try ctx.defineDataProperty(host_obj, "add", add_fn, .{});
        const g = try ctx.globalObject();
        try ctx.defineDataProperty(g.value(), "host", host_obj, .{});
    }

    var plugin_storage: ?zjs.runtime.Plugin = null;
    defer if (plugin_storage) |*p| p.deinit();
    if (std.mem.eql(u8, case_name, "plugin2")) {
        if (args.len < 4) fatal("plugin2 needs the fixture .so path", .{});
        plugin_storage = zjs.runtime.Plugin.load(allocator, args[3]) catch |e| fatal("plugin load: {s}", .{@errorName(e)});
        const target = try ctx.createObject();
        plugin_storage.?.install(ctx.core, target, .{}) catch |e| fatal("plugin install: {s}", .{@errorName(e)});
        const global = try ctx.globalObject();
        ctx.defineDataProperty(global.value(), "plugin", target, .{}) catch |e| fatal("define plugin: {s}", .{@errorName(e)});
    }

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
    else if (std.mem.eql(u8, case_name, "plugin2"))
        jsLoop("plugin.add(i, 1)")
    else if (std.mem.eql(u8, case_name, "n2j1"))
        "function cb(x) { return x + 1; }"
    else if (std.mem.eql(u8, case_name, "n2j0"))
        "function cb() {}"
    else
        fatal("unknown case {s}", .{case_name});

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
    if (std.mem.startsWith(u8, case_name, "n2j")) {
        const cb = try ctx.getProperty(global.value(), "cb");
        var s: i64 = 0;
        var i: i32 = 0;
        if (std.mem.eql(u8, case_name, "n2j1")) {
            while (i < n) : (i += 1) {
                const arg = [_]zjs.JSValue{zjs.JSValue.int32(i)};
                const r = try ctx.callFunction(cb, &arg, .{});
                s += r.asInt32() orelse fatal("cb returned non-int", .{});
            }
        } else {
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

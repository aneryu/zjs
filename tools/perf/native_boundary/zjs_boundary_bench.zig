//! JS<->native boundary microbench on the remaining host-function surface
//! (`zjs.native.managed` and one-shot `JSContext.callFunction`).
//!
//! Usage: zjs-boundary-bench <case> [N]
//!        zjs-boundary-bench --list          (prints the supported case names, one per line)
//! Exit codes: 0 ok, 1 failure, 2 unsupported case (sample_embed.py skips those).
//!
//! Cases (each prints one integer so runs can be checksum-compared):
//!   ctrl        JS loop `s += i` (subtract from the others)
//!   builtin     JS loop calling Math.abs (hoisted) -- the in-engine builtin path
//!   host2       JS loop calling a managed host function, 2 int args
//!   host0       JS loop calling a 0-arg managed host function returning undefined
//!   hostm2      JS loop calling the same managed function as a method: host.add(i, 1)
//!   n2j1 / n2j0  native -> JS one-shot: ctx.callFunction(cb, [i]) / (cb, []) N times
//!   prop_str    host loop: ctx.getProperty(obj, "field") N times
//!
//! Every JS loop is `function main(n) { var s = 0; for (...) { s += <op>; } return s }`.
const std = @import("std");
const zjs = @import("zjs");

fn hostAdd(call: *zjs.native.Call) error{JSException}!zjs.JSValue {
    const a = call.arg(0).as(.int) orelse return call.throwTypeError("expected int");
    const b = call.arg(1).as(.int) orelse return call.throwTypeError("expected int");
    return zjs.JSValue.int32(a +% b);
}

fn hostNoop(call: *zjs.native.Call) zjs.JSValue {
    _ = call;
    return zjs.JSValue.undefinedValue();
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}

const supported_cases = [_][]const u8{ "ctrl", "builtin", "host2", "host0", "hostm2", "n2j1", "n2j0", "prop_str" };

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
    {
        const host_obj = try ctx.createObject();
        const add_fn = try ctx.createFunction("add", zjs.native.managed(hostAdd), .{ .length = 2 });
        try ctx.defineDataProperty(host_obj, "add", add_fn, .{});
        const g = try ctx.globalObject();
        try ctx.defineDataProperty(g.value(), "host", host_obj, .{});
    }

    const host_loop = std.mem.startsWith(u8, case_name, "n2j") or std.mem.eql(u8, case_name, "prop_str");
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
    else if (std.mem.eql(u8, case_name, "n2j1"))
        "function cb(x) { return x + 1; }"
    else if (std.mem.eql(u8, case_name, "n2j0"))
        "function cb() {}"
    else if (std.mem.eql(u8, case_name, "prop_str"))
        "var obj = { x: 1, y: 2, field: 3 };"
    else
        unreachable;

    const eval_result = try ctx.eval(source, .{
        .mode = .script,
        .filename = "<boundary>",
        .output = null,
        .discard_script_result = true,
    });
    if (eval_result.is(.exception)) fatal("eval threw", .{});

    const global = try ctx.globalObject();
    var stdout_buffer: [256]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    if (host_loop) {
        var s: i64 = 0;
        var i: i32 = 0;
        if (std.mem.eql(u8, case_name, "n2j1")) {
            const cb = try ctx.getProperty(global.value(), "cb");
            while (i < n) : (i += 1) {
                const arg = [_]zjs.JSValue{zjs.JSValue.int32(i)};
                const r = try ctx.callFunction(cb, &arg, .{});
                s += r.as(.int) orelse fatal("cb returned non-int", .{});
            }
        } else if (std.mem.eql(u8, case_name, "prop_str")) {
            const obj = try ctx.getProperty(global.value(), "obj");
            while (i < n) : (i += 1) {
                const v = try ctx.getProperty(obj, "field");
                s += v.as(.int) orelse fatal("field non-int", .{});
            }
        } else {
            const cb = try ctx.getProperty(global.value(), "cb");
            while (i < n) : (i += 1) {
                const r = try ctx.callFunction(cb, &.{}, .{});
                if (r.is(.exception)) fatal("cb threw", .{});
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
    if (r.is(.exception)) fatal("main threw", .{});
    const f = r.as(.float64) orelse @as(f64, @floatFromInt(r.as(.int) orelse fatal("main returned non-number", .{})));
    try out.interface.print("{d}\n", .{@as(i64, @intFromFloat(f))});
    try out.interface.flush();
}

const std = @import("std");
const engine = @import("quickjs_zig_engine");

const core = engine.core;
const op = engine.bytecode.opcode.op;

const helpers = @import("exec_helpers.zig");
const oom_helpers = @import("oom_helpers.zig");
const makeFunction = helpers.makeFunction;
const runFunction = helpers.runFunction;

test "Engine eval loop collects object cycles incrementally" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    for (0..8) |_| {
        js.runtime.setGCThreshold(js.runtime.memory.allocated_bytes);
        const result = try js.eval(
            \\for (var i = 0; i < 25; i++) {
            \\    var a = {};
            \\    var b = {};
            \\    a.next = b;
            \\    b.next = a;
            \\    a = null;
            \\    b = null;
            \\}
        );
        result.free(js.runtime);
    }

    js.runtime.setGCThreshold(js.runtime.memory.allocated_bytes);
    const trigger = try js.eval("({});");
    trigger.free(js.runtime);

    try std.testing.expectEqual(@as(usize, 0), js.runtime.runObjectCycleRemoval());
}

test "module top-level await unwraps reassigned Promise then chain" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalModule(
        \\var values = [];
        \\var p = Promise.resolve().then(() => {
        \\    p = Promise.resolve().then(() => {
        \\        p = Promise.resolve().then(() => {
        \\            values.push(3);
        \\            return false;
        \\        });
        \\        values.push(2);
        \\        return true;
        \\    });
        \\    values.push(1);
        \\    return true;
        \\});
        \\while (await p) {}
        \\assert.sameValue(values.length, 3);
        \\assert.sameValue(values[0], 1);
        \\assert.sameValue(values[1], 2);
        \\assert.sameValue(values[2], 3);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "module top-level await condition resumes with awaited value" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalModule(
        \\var completed = 0;
        \\var p = Promise.resolve(true);
        \\if (await p) {
        \\    completed += 1;
        \\}
        \\assert.sameValue(completed, 1);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "module top-level await keeps symbol resume value across promise job GC" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.evalModule(
        \\Promise.resolve().then(function() { gc(); });
        \\var resumed = await Symbol("module-resume-root");
        \\assert.sameValue(String(resumed), "Symbol(module-resume-root)");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "module graph preload OOM releases pending tracked paths" {
    try expectPreloadTrackedPathOOMCleanup(.seen);
    try expectPreloadTrackedPathOOMCleanup(.postorder);
}

test "explicit namespace export OOM releases namespace owner once" {
    var saw_oom = false;
    var saw_success = false;
    const samples = oom_helpers.defaultSampleSet(81);
    var fail_offset: usize = 1;
    while (fail_offset < samples.limit) : (fail_offset += 1) {
        if (!oom_helpers.shouldRunOffset(samples, fail_offset)) continue;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var js = try engine.harness.Engine.init(failing.allocator());
        defer js.deinit();

        const rt = js.runtime;
        const root_name = try rt.internAtom("root-explicit-namespace-oom.mjs");
        defer rt.atoms.free(root_name);
        const dep_name = try rt.internAtom("dep-explicit-namespace-oom.mjs");
        defer rt.atoms.free(dep_name);
        const ns_name = try rt.internAtom("ns");
        defer rt.atoms.free(ns_name);
        const alias_name = try rt.internAtom("alias");
        defer rt.atoms.free(alias_name);
        const value_name = try rt.internAtom("value");
        defer rt.atoms.free(value_name);

        _ = try rt.modules.create(root_name);
        _ = try rt.modules.create(dep_name);
        const root = rt.modules.find(root_name) orelse return error.ModuleNotFound;
        const dep = rt.modules.find(dep_name) orelse return error.ModuleNotFound;
        try root.addRequestedModule(dep_name);
        try root.addStarExport(dep_name, ns_name);
        try root.addExport(alias_name, ns_name);
        try dep.addExport(value_name, value_name);
        try rt.modules.linkModule(rt, root_name);

        failing.fail_index = failing.alloc_index + fail_offset;
        const result = engine.exec.module.moduleNamespaceValue(js.context, root_name);
        failing.fail_index = std.math.maxInt(usize);

        if (result) |value| {
            saw_success = true;
            value.free(rt);
        } else |err| switch (err) {
            error.OutOfMemory => saw_oom = true,
            else => return err,
        }
        if (oom_helpers.shouldStopAfterCoverage(saw_oom, saw_success)) return;
    }
    try std.testing.expect(saw_oom);
    try std.testing.expect(saw_success);
}

const PreloadTrackedPathFailure = enum {
    seen,
    postorder,
};

fn expectPreloadTrackedPathOOMCleanup(kind: PreloadTrackedPathFailure) !void {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var postorder = std.ArrayList([]const u8).empty;
    defer {
        for (postorder.items) |path| failing.allocator().free(path);
        postorder.deinit(failing.allocator());
    }

    const fail_offset: usize = switch (kind) {
        .seen => 1,
        .postorder => 3,
    };
    failing.fail_index = failing.alloc_index + fail_offset;
    const result = engine.exec.module.preloadFileModuleGraphWithOrder(
        std.testing.io,
        failing.allocator(),
        rt,
        "export const value = 1;",
        "/tmp/zjs-preload-oom.mjs",
        1024,
        &postorder,
    );
    failing.fail_index = std.math.maxInt(usize);

    try std.testing.expectError(error.OutOfMemory, result);
}

test "module var declarations do not create global properties" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalModule(
        \\assert.sameValue(test262, undefined);
        \\assert.sameValue(Object.getOwnPropertyDescriptor(globalThis, "test262"), undefined);
        \\var test262 = null;
        \\assert.sameValue(test262, null);
        \\assert.sameValue(Object.getOwnPropertyDescriptor(globalThis, "test262"), undefined);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "module top-level this is undefined" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalModule(
        \\assert.sameValue(this, undefined);
        \\assert.notSameValue(this, Function("return this;")());
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "module top-level using declarations dispose at module completion" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalModule(
        \\globalThis.__zjs_module_using_log = [];
        \\var resource = {
        \\    [Symbol.dispose]: function() {
        \\        globalThis.__zjs_module_using_log.push("resource");
        \\    }
        \\};
        \\using z = resource;
        \\assert.sameValue(z, resource);
        \\function returnsThroughTry(value) {
        \\    try {
        \\        return value;
        \\    } catch (error) {
        \\        return "caught";
        \\    }
        \\}
        \\assert.sameValue(returnsThroughTry(z), resource);
        \\{
        \\    using z = null;
        \\    assert.sameValue(z, null);
        \\}
        \\assert.compareArray(globalThis.__zjs_module_using_log, []);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());

    const check = try js.eval(
        \\assert.compareArray(globalThis.__zjs_module_using_log, ["resource"]);
        \\delete globalThis.__zjs_module_using_log;
    );
    defer check.free(js.runtime);
}

test "await using declarations dispose async resources at function completion" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalModule(
        \\await using moduleResource = null;
        \\var log = [];
        \\async function f() {
        \\    await using asyncResource = {
        \\        [Symbol.asyncDispose]: function() {
        \\            log.push("async-dispose");
        \\            return Promise.resolve().then(function() {
        \\                log.push("async-then");
        \\            });
        \\        }
        \\    };
        \\    await using syncFallback = {
        \\        [Symbol.dispose]: function() {
        \\            log.push("sync-dispose");
        \\        }
        \\    };
        \\    log.push("body");
        \\}
        \\await f();
        \\assert.compareArray(log, ["body", "sync-dispose", "async-dispose", "async-then"]);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "module top-level await using waits for async disposer completion" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalModule(
        \\globalThis.__zjs_module_await_using_log = [];
        \\await using moduleResource = {
        \\    [Symbol.asyncDispose]: function() {
        \\        globalThis.__zjs_module_await_using_log.push("dispose");
        \\        return Promise.resolve().then(function() {
        \\            globalThis.__zjs_module_await_using_log.push("then");
        \\        });
        \\    }
        \\};
        \\globalThis.__zjs_module_await_using_log.push("body");
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());

    const check = try js.eval(
        \\assert.compareArray(globalThis.__zjs_module_await_using_log, ["body", "dispose", "then"]);
        \\delete globalThis.__zjs_module_await_using_log;
    );
    defer check.free(js.runtime);
}

test "await using for-of declarations dispose each iteration" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalModule(
        \\var log = [];
        \\var resources = [
        \\    { name: "a", [Symbol.asyncDispose]: function() { log.push("dispose-" + this.name); } },
        \\    { name: "b", [Symbol.asyncDispose]: function() { log.push("dispose-" + this.name); } },
        \\];
        \\for (await using item of resources) {
        \\    log.push("body-" + item.name);
        \\}
        \\assert.compareArray(log, ["body-a", "dispose-a", "body-b", "dispose-b"]);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "script top-level await using is a syntax error" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    try std.testing.expectError(error.SyntaxError, js.eval("await using x = null;"));
}

test "module top-level await assimilates thenables and catches rejections" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalModule(
        \\var fulfilled = await { then: function (resolve) { resolve(42); } };
        \\assert.sameValue(fulfilled, 42);
        \\var thrown = {};
        \\var caught = null;
        \\try {
        \\    await { then: function () { throw thrown; } };
        \\} catch (e) {
        \\    caught = e;
        \\}
        \\assert.sameValue(caught, thrown);
        \\try {
        \\    await Promise.reject("rejected");
        \\} catch (e) {
        \\    caught = e;
        \\}
        \\assert.sameValue(caught, "rejected");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "module top-level for-await uses AsyncFromSync close ordering" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalModule(
        \\var log = [];
        \\var breakIter = {
        \\    i: 0,
        \\    [Symbol.iterator]: function() {
        \\        log.push("sync-break");
        \\        return this;
        \\    },
        \\    next: function() {
        \\        this.i++;
        \\        return { value: Promise.resolve("v" + this.i), done: false };
        \\    },
        \\    return: function() {
        \\        log.push("close-break");
        \\        return { done: true };
        \\    },
        \\};
        \\for await (const value of breakIter) {
        \\    log.push(value);
        \\    break;
        \\}
        \\
        \\var rejectIter = {
        \\    i: 0,
        \\    [Symbol.iterator]: function() {
        \\        log.push("sync-reject");
        \\        return this;
        \\    },
        \\    next: function() {
        \\        this.i++;
        \\        return { value: Promise.reject(new Error("boom")), done: false };
        \\    },
        \\    return: function() {
        \\        log.push("close-reject");
        \\        return { done: true };
        \\    },
        \\};
        \\try {
        \\    for await (const value of rejectIter) {
        \\        log.push(value);
        \\    }
        \\} catch (error) {
        \\    log.push(error.message);
        \\}
        \\assert.compareArray(log, ["sync-break", "v1", "close-break", "sync-reject", "close-reject", "boom"]);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "module function declarations stay local and keep self-capturing bindings live" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalModule(
        \\function Test262Error(message) { this.message = message || ""; }
        \\Test262Error.prototype.toString = function () { return "Test262Error: " + this.message; };
        \\function assertLocal(mustBeTrue, message) {
        \\    if (message === undefined) message = assertLocal._toString(mustBeTrue);
        \\}
        \\assertLocal._toString = function (value) { return String(value); };
        \\assertLocal._isSameValue = function (a, b) { return a === b; };
        \\assertLocal.sameValue = function (actual, expected) {
        \\    if (!assertLocal._isSameValue(actual, expected)) throw new Test262Error("bad");
        \\};
        \\assert.sameValue(typeof assertLocal, "function");
        \\assert.sameValue(Object.prototype.toString.call(assertLocal), "[object Function]");
        \\var global = Function("return this;")();
        \\function test262() { return "test262"; }
        \\assert.sameValue(test262(), "test262");
        \\assert.sameValue(Object.getOwnPropertyDescriptor(global, "test262"), undefined);
        \\test262 = null;
        \\assert.sameValue(test262, null);
        \\assert.sameValue(Object.getOwnPropertyDescriptor(global, "test262"), undefined);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "module graph preinitializes root function declarations for cyclic dependencies" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const dir = ".zig-cache/module-dfs-function-init-test";
    const root_path = dir ++ "/root.mjs";
    const a_path = dir ++ "/a.mjs";
    const b_path = dir ++ "/b.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);

    const root_source =
        \\import "./a.mjs";
        \\import "./b.mjs";
        \\export function evaluated(name) {
        \\    if (!evaluated.order) evaluated.order = [];
        \\    evaluated.order.push(name);
        \\    print(name);
        \\}
    ;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root_path, .data = root_source });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = a_path, .data =
        \\import { evaluated } from "./root.mjs";
        \\evaluated("A");
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = b_path, .data =
        \\import { evaluated } from "./root.mjs";
        \\evaluated("B");
    });

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithOutput(root_source, &output, root_path, std.testing.io, std.testing.allocator, 1024);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("A\nB\n", output.buffered());
}

test "module graph dynamic import resolves local modules" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const dir = ".zig-cache/module-dynamic-import-test";
    const root_path = dir ++ "/root.mjs";
    const dep_path = dir ++ "/dep.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);

    const root_source =
        \\const ns = await import("./dep.mjs");
        \\print(ns.default);
        \\print(ns.x);
        \\try {
        \\    await import("bare");
        \\} catch (e) {
        \\    print(e instanceof TypeError);
        \\}
    ;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root_path, .data = root_source });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = dep_path, .data =
        \\export default 42;
        \\export const x = "named";
    });

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithOutput(root_source, &output, root_path, std.testing.io, std.testing.allocator, 1024);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("42\nnamed\ntrue\n", output.buffered());
}

test "module graph resolves native std and os modules" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const dir = ".zig-cache/native-std-os-module-test";
    const root_path = dir ++ "/root.mjs";
    const file_path = dir ++ "/data.txt";
    const renamed_path = dir ++ "/renamed.txt";
    const missing_path = dir ++ "/missing.txt";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);

    const root_source =
        \\import * as std from "std";
        \\import { getenv, getcwd, remove, rename } from "os";
        \\print("__zjs_std_file_proto" in globalThis);
        \\print(Object.getOwnPropertyDescriptor(globalThis, "__zjs_std_file_proto") === undefined);
        \\globalThis.__zjs_std_file_proto = { puts: function() { print("bad"); } };
        \\print(typeof std.out.puts);
        \\print(delete globalThis.__zjs_std_file_proto);
        \\std.writeFile(".zig-cache/native-std-os-module-test/data.txt", "hello");
        \\print(std.exists(".zig-cache/native-std-os-module-test/data.txt"));
        \\print(std.loadFile(".zig-cache/native-std-os-module-test/data.txt"));
        \\rename(".zig-cache/native-std-os-module-test/data.txt", ".zig-cache/native-std-os-module-test/renamed.txt");
        \\print(std.exists(".zig-cache/native-std-os-module-test/data.txt"));
        \\print(std.exists(".zig-cache/native-std-os-module-test/renamed.txt"));
        \\remove(".zig-cache/native-std-os-module-test/renamed.txt");
        \\print(std.exists(".zig-cache/native-std-os-module-test/renamed.txt"));
        \\print(std.exists(".zig-cache/native-std-os-module-test/missing.txt"));
        \\print(std.loadFile(".zig-cache/native-std-os-module-test/missing.txt") === null);
        \\print(getenv("__ZJS_NATIVE_MODULE_TEST_MISSING__") === undefined);
        \\print(typeof getcwd() === "string" && getcwd().length > 0);
    ;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root_path, .data = root_source });

    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithOutput(root_source, &output, root_path, std.testing.io, std.testing.allocator, 4096);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("false\ntrue\nfunction\ntrue\ntrue\nhello\nfalse\ntrue\nfalse\nfalse\ntrue\ntrue\ntrue\n", output.buffered());
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, file_path, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, renamed_path, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, missing_path, .{}));
}

test "os stat and readdir result pairs release temporary result objects" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.evalModule(
        \\import { readdir, stat } from "os";
        \\var stat_result = stat(".");
        \\assert.sameValue(stat_result[1], 0);
        \\assert.sameValue(typeof stat_result[0].mode, "number");
        \\var readdir_result = readdir(".");
        \\assert.sameValue(readdir_result[1], 0);
        \\assert.sameValue(Array.isArray(readdir_result[0]), true);
    );
    result.free(js.runtime);
}

test "os Worker posts messages between parent and worker thread" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const dir = ".zig-cache/os-worker-message-test";
    const root_path = dir ++ "/root.mjs";
    const worker_path = dir ++ "/worker.mjs";
    const dep_path = dir ++ "/dep.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = dep_path, .data =
        \\export const prefix = "reply:";
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = worker_path, .data =
        \\import { Worker } from "os";
        \\import { prefix } from "./dep.mjs";
        \\Worker.parent.onmessage = function(ev) {
        \\    var hidden = "__zjs_worker_post_message" in Worker.parent.postMessage;
        \\    Worker.parent.postMessage.__zjs_worker_post_message = 0;
        \\    Worker.parent.postMessage(prefix + ev.data + ":" + ("__zjs_worker_id" in Worker.parent) + ":" + hidden + ":" + delete Worker.parent.postMessage.__zjs_worker_post_message);
        \\};
    });
    const root_source =
        \\import { Worker, poll, sleep } from "os";
        \\var got = "";
        \\var worker = new Worker(".zig-cache/os-worker-message-test/worker.mjs");
        \\print("__zjs_worker_id" in worker);
        \\print("__zjs_worker_post_message" in worker.postMessage);
        \\worker.__zjs_worker_id = -1;
        \\worker.postMessage.__zjs_worker_post_message = 0;
        \\worker.onmessage = function(ev) { got = ev.data; };
        \\worker.postMessage("ping");
        \\for (var i = 0; i < 200 && got === ""; i++) {
        \\    sleep(1);
        \\    poll();
        \\}
        \\print(got);
        \\print(delete worker.__zjs_worker_id);
        \\print(delete worker.postMessage.__zjs_worker_post_message);
    ;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root_path, .data = root_source });

    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithOutput(root_source, &output, root_path, std.testing.io, std.testing.allocator, 4096);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("false\nfalse\nreply:ping:false:false:true\ntrue\ntrue\n", output.buffered());
}

test "os Worker preserves queued message order" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const dir = ".zig-cache/os-worker-message-order-test";
    const root_path = dir ++ "/root.mjs";
    const worker_path = dir ++ "/worker.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = worker_path, .data =
        \\import { Worker } from "os";
        \\Worker.parent.onmessage = function(ev) {
        \\    Worker.parent.postMessage(ev.data);
        \\};
    });
    const root_source =
        \\import { Worker, poll, sleep } from "os";
        \\var got = [];
        \\var worker = new Worker(".zig-cache/os-worker-message-order-test/worker.mjs");
        \\worker.onmessage = function(ev) { got.push(ev.data); };
        \\worker.postMessage("one");
        \\worker.postMessage("two");
        \\worker.postMessage("three");
        \\worker.postMessage("four");
        \\worker.postMessage("five");
        \\for (var i = 0; i < 500 && got.length < 5; i++) {
        \\    sleep(1);
        \\    poll();
        \\}
        \\print(got.join(","));
    ;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root_path, .data = root_source });

    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithOutput(root_source, &output, root_path, std.testing.io, std.testing.allocator, 4096);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("one,two,three,four,five\n", output.buffered());
}

test "os Worker shares SharedArrayBuffer backing store" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const dir = ".zig-cache/os-worker-sab-test";
    const root_path = dir ++ "/root.mjs";
    const worker_path = dir ++ "/worker.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = worker_path, .data =
        \\import { Worker } from "os";
        \\Worker.parent.onmessage = function(ev) {
        \\    var view = new Int32Array(ev.data);
        \\    Atomics.add(view, 0, 2);
        \\    Worker.parent.postMessage(ev.data);
        \\};
    });
    const root_source =
        \\import { Worker, poll, sleep } from "os";
        \\var sab = new SharedArrayBuffer(4);
        \\var view = new Int32Array(sab);
        \\view[0] = 40;
        \\var got = 0;
        \\var worker = new Worker(".zig-cache/os-worker-sab-test/worker.mjs");
        \\worker.onmessage = function(ev) { got = new Int32Array(ev.data)[0]; };
        \\worker.postMessage(sab);
        \\for (var i = 0; i < 200 && got === 0; i++) {
        \\    sleep(1);
        \\    poll();
        \\}
        \\print(view[0], got);
    ;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root_path, .data = root_source });

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithOutput(root_source, &output, root_path, std.testing.io, std.testing.allocator, 4096);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("42 42\n", output.buffered());
}

test "module graph dynamically imports native modules" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const dir = ".zig-cache/native-dynamic-module-test";
    const root_path = dir ++ "/root.mjs";
    const file_path = dir ++ "/dynamic.txt";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);

    const root_source =
        \\const stdNs = await import("std");
        \\const osNs = await import("os");
        \\stdNs.writeFile(".zig-cache/native-dynamic-module-test/dynamic.txt", "dynamic");
        \\print(stdNs.loadFile(".zig-cache/native-dynamic-module-test/dynamic.txt"));
        \\osNs.remove(".zig-cache/native-dynamic-module-test/dynamic.txt");
        \\print(stdNs.exists(".zig-cache/native-dynamic-module-test/dynamic.txt"));
    ;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root_path, .data = root_source });

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithOutput(root_source, &output, root_path, std.testing.io, std.testing.allocator, 4096);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("dynamic\nfalse\n", output.buffered());
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, file_path, .{}));
}

test "module graph exported destructuring initializes module bindings" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const dir = ".zig-cache/module-export-destructuring-test";
    const root_path = dir ++ "/root.mjs";
    const dep_path = dir ++ "/dep.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);

    const root_source =
        \\import { check, renamed } from "./dep.mjs";
        \\print(check);
        \\print(renamed);
    ;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root_path, .data = root_source });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = dep_path, .data =
        \\globalThis.source = { check: false, nested: { renamed: 7 } };
        \\export const { check, nested: { renamed } } = globalThis.source;
    });

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithOutput(root_source, &output, root_path, std.testing.io, std.testing.allocator, 1024);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("false\n7\n", output.buffered());
}

test "module graph top-level await does not block independent siblings and drains promise ticks" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const dir = ".zig-cache/module-tla-scheduler-test";
    const root_path = dir ++ "/root.mjs";
    const async_path = dir ++ "/async.mjs";
    const sync_path = dir ++ "/sync.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);

    const root_source =
        \\import "./async.mjs";
        \\import { check } from "./sync.mjs";
        \\var tick = "before";
        \\Promise.resolve().then(() => tick = "after");
        \\await 1;
        \\print(check);
        \\print(tick);
    ;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root_path, .data = root_source });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = async_path, .data =
        \\globalThis.check = false;
        \\await 0;
        \\globalThis.check = true;
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = sync_path, .data =
        \\export const { check } = globalThis;
    });

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithOutput(root_source, &output, root_path, std.testing.io, std.testing.allocator, 1024);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("false\nafter\n", output.buffered());
}

test "module graph top-level await keeps symbol continuation across promise job GC" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const dir = ".zig-cache/module-tla-symbol-root-test";
    const root_path = dir ++ "/root.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);

    const root_source =
        \\Promise.resolve().then(function() { gc(); });
        \\var resumed = await Symbol("module-continuation-root");
        \\assert.sameValue(String(resumed), "Symbol(module-continuation-root)");
    ;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root_path, .data = root_source });

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithOutput(root_source, &output, root_path, std.testing.io, std.testing.allocator, 1024);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Promise.all custom constructor capability keeps symbol result under GC" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const old_threshold = js.runtime.gcThreshold();
    js.runtime.setGCThreshold(0);
    defer js.runtime.setGCThreshold(old_threshold);

    const result = try js.eval(
        \\var all = Promise.all;
        \\var resolved;
        \\var rejected;
        \\function P(executor) {
        \\  this.created = true;
        \\  executor(function(value) { resolved = value; },
        \\           function(reason) { rejected = reason; });
        \\}
        \\P.resolve = function(value) {
        \\  return { then: function(onFulfilled) { onFulfilled(value); } };
        \\};
        \\var marker = Symbol("promise-capability-custom-constructor");
        \\var promise = all.call(P, [marker]);
        \\assert.sameValue(promise.created, true);
        \\assert.sameValue(resolved[0], marker);
        \\assert.sameValue(rejected, undefined);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Reflect.construct FinalizationRegistry accepts cleanup callback under GC" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const old_threshold = js.runtime.gcThreshold();
    js.runtime.setGCThreshold(0);
    defer js.runtime.setGCThreshold(old_threshold);

    const result = try js.eval(
        \\var marker = Symbol("reflect-finalization-cleanup");
        \\function cleanup() {}
        \\cleanup.marker = marker;
        \\var registry = Reflect.construct(FinalizationRegistry, [cleanup]);
        \\var target = {};
        \\var held = Symbol("reflect-finalization-held");
        \\registry.register(target, held);
        \\assert.sameValue(cleanup.marker, marker);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "module graph top-level await propagates first queued promise rejection" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const dir = ".zig-cache/module-tla-rejection-tick-test";
    const root_path = dir ++ "/root.mjs";
    const dep_path = dir ++ "/dep.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);

    const root_source =
        \\import "./dep.mjs";
    ;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root_path, .data = root_source });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = dep_path, .data =
        \\await Promise.resolve().then(() => Promise.reject(new RangeError()));
        \\await Promise.reject(new TypeError());
    });

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    try std.testing.expectError(error.Test262Error, js.evalFileModuleGraphWithOutput(root_source, &output, root_path, std.testing.io, std.testing.allocator, 1024));
}

test "module graph top-level await resumed throw releases continuation values" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const dir = ".zig-cache/module-tla-resume-throw-lifecycle-test";
    const root_path = dir ++ "/root.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);

    const root_source =
        \\await Promise.resolve({ marker: 1 });
        \\throw new Test262Error("resume");
    ;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root_path, .data = root_source });

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    try std.testing.expectError(error.Test262Error, js.evalFileModuleGraphWithOutput(root_source, &output, root_path, std.testing.io, std.testing.allocator, 1024));
}

test "module export default function declarations bind local names" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const named = try js.evalModule(
        \\export default function F() {}
        \\F.foo = "";
        \\assert.sameValue(F.foo, "");
    );
    defer named.free(js.runtime);
    try std.testing.expect(named.isUndefined());

    const anon = try js.evalModule(
        \\var count = 0;
        \\export default function() {} if (true) { count += 1; }
        \\assert.sameValue(count, 1);
    );
    defer anon.free(js.runtime);
    try std.testing.expect(anon.isUndefined());
}

test "module export default function rejects duplicate lexical binding" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    try std.testing.expectError(error.SyntaxError, js.evalModule(
        \\class F {}
        \\export default function F() {}
    ));
}

test "module import and export declarations are top level only" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    try std.testing.expectError(error.SyntaxError, js.evalModule(
        \\{ export default null; }
    ));
    try std.testing.expectError(error.SyntaxError, js.evalModule(
        \\{ import v from "./module-fixture.js"; }
    ));
}

test "module import bindings reject eval and arguments" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    try std.testing.expectError(error.SyntaxError, js.evalModule(
        \\import { eval } from "./module-fixture.js";
    ));
    try std.testing.expectError(error.SyntaxError, js.evalModule(
        \\import { x as arguments } from "./module-fixture.js";
    ));
}

test "module static imports are linked before evaluation" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    try std.testing.expectError(error.ModuleNotFound, js.evalModule(
        \\import { value } from "./missing-module.js";
        \\value;
    ));
}

test "module missing and ambiguous exports surface as syntax errors" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const fixture_name = try js.runtime.internAtom("./module-fixture.js");
    const ambiguous_name = try js.runtime.internAtom("./ambiguous.js");
    const a_name = try js.runtime.internAtom("./ambiguous-a.js");
    const b_name = try js.runtime.internAtom("./ambiguous-b.js");
    const x_name = try js.runtime.internAtom("x");
    defer {
        js.runtime.atoms.free(fixture_name);
        js.runtime.atoms.free(ambiguous_name);
        js.runtime.atoms.free(a_name);
        js.runtime.atoms.free(b_name);
        js.runtime.atoms.free(x_name);
    }

    _ = try js.runtime.modules.create(fixture_name);
    _ = try js.runtime.modules.create(ambiguous_name);
    _ = try js.runtime.modules.create(a_name);
    _ = try js.runtime.modules.create(b_name);
    const ambiguous = &js.runtime.modules.modules[js.runtime.modules.findIndex(ambiguous_name).?];
    const a = &js.runtime.modules.modules[js.runtime.modules.findIndex(a_name).?];
    const b = &js.runtime.modules.modules[js.runtime.modules.findIndex(b_name).?];
    try a.addExport(x_name, x_name);
    try b.addExport(x_name, x_name);
    try ambiguous.addRequestedModule(a_name);
    try ambiguous.addRequestedModule(b_name);
    try ambiguous.addStarExport(a_name, core.atom.predefinedId("*", .string).?);
    try ambiguous.addStarExport(b_name, core.atom.predefinedId("*", .string).?);

    try std.testing.expectError(error.SyntaxError, js.evalModule(
        \\import { missing } from "./module-fixture.js";
        \\missing;
    ));

    try std.testing.expectError(error.SyntaxError, js.evalModule(
        \\import { x } from "./ambiguous.js";
    ));
}

test "module file eval uses filename as runtime module name" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileWithOutputMode("export const value = 1;", &output, .module, "named-module.mjs");
    defer result.free(js.runtime);

    const module_name = try js.runtime.internAtom("named-module.mjs");
    defer js.runtime.atoms.free(module_name);
    try std.testing.expect(js.runtime.modules.find(module_name) != null);
}

test "module file eval links modules without import export declarations" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileWithOutputMode("print(\"pure\");", &output, .module, "pure-module.mjs");
    defer result.free(js.runtime);

    const module_name = try js.runtime.internAtom("pure-module.mjs");
    defer js.runtime.atoms.free(module_name);
    const record = js.runtime.modules.find(module_name).?;
    try std.testing.expectEqual(core.module.Status.linked, record.status);
    try std.testing.expectEqualStrings("pure\n", output.buffered());
}

test "module file graph reads imported live binding cells" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const dir = ".zig-cache/module-live-binding-test";
    const dep_path = dir ++ "/dep.mjs";
    const main_path = dir ++ "/main.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = dep_path, .data = "export const value = 7;\n" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = main_path, .data = "import { value } from \"./dep.mjs\"; print(value);\n" });

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, main_path, std.testing.allocator, .limited(2048));
    defer std.testing.allocator.free(source);
    const result = try js.evalFileModuleGraphWithOutput(source, &output, main_path, std.testing.io, std.testing.allocator, 1024);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("7\n", output.buffered());
}

test "module var refs reject const and import assignment without freezing exported let" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const dir = ".zig-cache/module-const-import-assignment-test";
    const dep_path = dir ++ "/dep.mjs";
    const main_path = dir ++ "/main.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = dep_path, .data =
        \\export let value = 1;
        \\export function inc(){ value = value + 1; }
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = main_path, .data =
        \\import { value, inc } from "./dep.mjs";
        \\import * as ns from "./dep.mjs";
        \\const immutable = 0;
        \\try { immutable = 1; print("local-ok"); } catch (e) { print(e.name); }
        \\print(immutable);
        \\try { value = 2; print("import-ok"); } catch (e) { print(e.name); }
        \\print(value);
        \\inc();
        \\print(value);
        \\try { ns = 3; print("namespace-ok"); } catch (e) { print(e.name); }
        \\ns.inc();
        \\print(ns.value);
        \\export let writable = 4;
        \\writable = 5;
        \\print(writable);
    });

    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, main_path, std.testing.allocator, .limited(2048));
    defer std.testing.allocator.free(source);
    const result = try js.evalFileModuleGraphWithOutput(source, &output, main_path, std.testing.io, std.testing.allocator, 1024);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("TypeError\n0\nTypeError\n1\n2\nTypeError\n3\n5\n", output.buffered());
}

test "module forward import capture remains immutable in earlier function expressions" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const dir = ".zig-cache/module-forward-import-capture-test";
    const dep_path = dir ++ "/dep.mjs";
    const main_path = dir ++ "/main.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = dep_path, .data =
        \\export function value() { return 23; }
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = main_path, .data =
        \\try {
        \\  (function(){ imported = (print("rhs"), null); })();
        \\  print("assign-ok");
        \\} catch (e) {
        \\  print(e.name);
        \\}
        \\print(imported());
        \\import { value as imported } from "./dep.mjs";
    });

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, main_path, std.testing.allocator, .limited(2048));
    defer std.testing.allocator.free(source);
    const result = try js.evalFileModuleGraphWithOutput(source, &output, main_path, std.testing.io, std.testing.allocator, 1024);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("rhs\nTypeError\n23\n", output.buffered());
}

test "import.meta exposes file url and main flag" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const dir = ".zig-cache/import-meta-test";
    const dep_path = dir ++ "/dep.mjs";
    const main_path = dir ++ "/main.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = dep_path, .data =
        \\print(import.meta.main);
        \\print(import.meta.url.indexOf("/dep.mjs") >= 0);
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = main_path, .data =
        \\import "./dep.mjs";
        \\print(import.meta.main);
        \\print(import.meta.url.indexOf("/main.mjs") >= 0);
        \\print(import.meta.url.indexOf("file://") === 0);
    });

    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, main_path, std.testing.allocator, .limited(2048));
    defer std.testing.allocator.free(source);
    const result = try js.evalFileModuleGraphWithOutput(source, &output, main_path, std.testing.io, std.testing.allocator, 2048);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("false\ntrue\ntrue\ntrue\ntrue\n", output.buffered());
}

test "module file graph creates namespace import objects" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const dir = ".zig-cache/module-namespace-test";
    const dep_path = dir ++ "/dep.mjs";
    const main_path = dir ++ "/main.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = dep_path, .data = "export let value = 7; export function inc(){ value = value + 1; } export const other = 9;\n" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = main_path, .data =
        \\import * as ns from "./dep.mjs";
        \\import * as ns2 from "./dep.mjs";
        \\const desc = Object.getOwnPropertyDescriptor(ns, "value");
        \\print(ns === ns2);
        \\print(ns.value);
        \\ns.inc();
        \\print(ns.value);
        \\print(desc.enumerable);
        \\print(desc.writable);
        \\print(desc.configurable);
        \\print(Object.keys(ns).join(","));
        \\print(Object.getOwnPropertyNames(ns).join(","));
        \\try { ns.value = 99; print("assign-ok"); } catch (e) { print("assign-throw"); }
        \\print(ns.value);
        \\try { Object.defineProperty(ns, "value", { value: 8 }); print("define-same-ok"); } catch (e) { print("define-same-throw"); }
        \\try { Object.defineProperty(ns, "value", { value: 99 }); print("define-change-ok"); } catch (e) { print("define-change-throw"); }
        \\try { Object.defineProperty(ns, "value", { writable: false }); print("define-writable-ok"); } catch (e) { print("define-writable-throw"); }
        \\print(ns.value);
        \\print(Reflect.set(ns, "value", 99));
        \\print(Reflect.set(ns, "0", 99));
        \\print(Reflect.set(ns, 0, 99));
        \\print(Reflect.set(ns, Symbol.toStringTag, "Other"));
        \\print(Reflect.set(ns, Symbol("missing"), 1));
        \\print(ns.value);
        \\const tagDesc = Object.getOwnPropertyDescriptor(ns, Symbol.toStringTag);
        \\print(ns[Symbol.toStringTag]);
        \\print(tagDesc.enumerable);
        \\print(tagDesc.writable);
        \\print(tagDesc.configurable);
        \\print(ns instanceof Object);
        \\print(Object.getPrototypeOf(ns) === null);
    });

    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, main_path, std.testing.allocator, .limited(2048));
    defer std.testing.allocator.free(source);
    const result = try js.evalFileModuleGraphWithOutput(source, &output, main_path, std.testing.io, std.testing.allocator, 1024);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings(
        "true\n7\n8\ntrue\ntrue\nfalse\ninc,other,value\ninc,other,value\nassign-throw\n8\ndefine-same-ok\ndefine-change-throw\ndefine-writable-throw\n8\nfalse\nfalse\nfalse\nfalse\nfalse\n8\nModule\nfalse\nfalse\nfalse\nfalse\ntrue\n",
        output.buffered(),
    );
}

test "module namespace uninitialized exports throw on get and descriptor" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const dir = ".zig-cache/module-namespace-uninit-test";
    const main_path = dir ++ "/main.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = main_path, .data =
        \\import * as ns from "./main.mjs";
        \\function check(fn) {
        \\    try { fn(); print("ok"); } catch (e) { print(e.name); }
        \\}
        \\check(function(){ return ns.local1; });
        \\check(function(){ return Object.getOwnPropertyDescriptor(ns, "local1"); });
        \\check(function(){ return Object.prototype.hasOwnProperty.call(ns, "local1"); });
        \\check(function(){ for (var key in ns) {} });
        \\print(Reflect.deleteProperty(ns, "local1"));
        \\try { delete ns.local1; print("delete-ok"); } catch (e) { print(e.name); }
        \\export let local1 = 23;
    });

    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, main_path, std.testing.allocator, .limited(2048));
    defer std.testing.allocator.free(source);
    const result = try js.evalFileModuleGraphWithOutput(source, &output, main_path, std.testing.io, std.testing.allocator, 1024);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings(
        "ReferenceError\nReferenceError\nReferenceError\nReferenceError\nfalse\nTypeError\n",
        output.buffered(),
    );
}

test "module default exports initialize import and namespace bindings" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const dir = ".zig-cache/module-default-export-test";
    const main_path = dir ++ "/main.mjs";
    const expr_path = dir ++ "/expr.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = main_path, .data =
        \\import f, * as ns from "./main.mjs";
        \\print(f());
        \\print(f.name);
        \\export default function(){ return 23; }
        \\print(ns.default());
        \\print(ns.default.name);
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = expr_path, .data =
        \\import f, * as ns from "./expr.mjs";
        \\export default (function(){ return 7; });
        \\print(f());
        \\print(f.name);
        \\print(ns.default());
        \\print(ns.default.name);
    });

    var main_output_buffer: [64]u8 = undefined;
    var main_output = std.Io.Writer.fixed(&main_output_buffer);
    const main_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, main_path, std.testing.allocator, .limited(2048));
    defer std.testing.allocator.free(main_source);
    const main_result = try js.evalFileModuleGraphWithOutput(main_source, &main_output, main_path, std.testing.io, std.testing.allocator, 1024);
    defer main_result.free(js.runtime);
    try std.testing.expectEqualStrings("23\ndefault\n23\ndefault\n", main_output.buffered());

    var expr_output_buffer: [64]u8 = undefined;
    var expr_output = std.Io.Writer.fixed(&expr_output_buffer);
    const expr_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, expr_path, std.testing.allocator, .limited(2048));
    defer std.testing.allocator.free(expr_source);
    const expr_result = try js.evalFileModuleGraphWithOutput(expr_source, &expr_output, expr_path, std.testing.io, std.testing.allocator, 1024);
    defer expr_result.free(js.runtime);
    try std.testing.expectEqualStrings("7\ndefault\n7\ndefault\n", expr_output.buffered());
}

test "module file graph creates explicit star re-export namespaces" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const dir = ".zig-cache/module-star-namespace-test";
    const dep_path = dir ++ "/dep.mjs";
    const mid_path = dir ++ "/mid.mjs";
    const main_path = dir ++ "/main.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = dep_path, .data = "export let value = 3; export function inc(){ value = value + 1; }\n" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = mid_path, .data = "export * as ns from \"./dep.mjs\";\n" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = main_path, .data =
        \\import { ns } from "./mid.mjs";
        \\print(ns.value);
        \\ns.inc();
        \\print(ns.value);
        \\print(Object.keys(ns).join(","));
    });

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, main_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(source);
    const result = try js.evalFileModuleGraphWithOutput(source, &output, main_path, std.testing.io, std.testing.allocator, 1024);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("3\n4\ninc,value\n", output.buffered());
}

test "module file graph normalizes cyclic relative paths" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const dir = ".zig-cache/module-cycle-path-test";
    const a_path = dir ++ "/a.mjs";
    const b_path = dir ++ "/b.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = a_path, .data =
        \\import { b, incB } from "./b.mjs";
        \\export let a = 1;
        \\export function incA(){ a = a + 1; }
        \\print("a", b);
        \\incB();
        \\print("a2", b);
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = b_path, .data =
        \\import { a, incA } from "./a.mjs";
        \\export let b = 2;
        \\export function incB(){ b = b + 1; }
        \\print("b-ready");
    });

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, a_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(source);
    const result = try js.evalFileModuleGraphWithOutput(source, &output, a_path, std.testing.io, std.testing.allocator, 1024);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("b-ready\na 2\na2 3\n", output.buffered());
}

test "module file graph supports synthesized root source self import" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const dir = ".zig-cache/module-synth-self-test";
    const path = dir ++ "/self.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\import { x as y } from "./self.mjs";
        \\export const x = 23;
    });

    const source =
        \\try { print(typeof y); } catch (e) { print("tdz"); }
        \\import { x as y } from "./self.mjs";
        \\export const x = 23;
        \\print(y);
    ;
    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithOutput(source, &output, path, std.testing.io, std.testing.allocator, 1024);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("tdz\n23\n", output.buffered());
}

test "module file graph treats relative root self imports as the root module" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const dir = ".zig-cache/module-self-once-test";
    const path = dir ++ "/self.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    const source =
        \\import {} from "./self.mjs";
        \\import "./self.mjs";
        \\import * as ns1 from "./self.mjs";
        \\import dflt1 from "./self.mjs";
        \\export {} from "./self.mjs";
        \\import dflt2, {} from "./self.mjs";
        \\export * from "./self.mjs";
        \\export * as ns2 from "./self.mjs";
        \\import dflt3, * as ns from "./self.mjs";
        \\export default null;
        \\if (globalThis.selfOnce === undefined) globalThis.selfOnce = 0;
        \\globalThis.selfOnce = globalThis.selfOnce + 1;
        \\print(globalThis.selfOnce);
        \\print(ns.default === null);
    ;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = source });

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithOutput(source, &output, path, std.testing.io, std.testing.allocator, 1024);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("1\ntrue\n", output.buffered());
}

test "module duplicate lexical and exported names are syntax errors" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    try std.testing.expectError(error.SyntaxError, js.evalModule(
        \\let x;
        \\const x = 0;
    ));
    try std.testing.expectError(error.SyntaxError, js.evalModule(
        \\var x, y;
        \\export { x as z };
        \\export { y as z };
    ));
    try std.testing.expectError(error.SyntaxError, js.evalModule(
        \\function f() {}
        \\function f() {}
    ));
}

test "parsed module metadata instantiates runtime record for resolution" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const main_name = try rt.internAtom("main.mjs");
    const dep_name = try rt.internAtom("dep");
    const value_name = try rt.internAtom("v");
    const dep_local_name = try rt.internAtom("depLocal");
    const indirect_name = try rt.internAtom("vv");
    defer {
        rt.atoms.free(main_name);
        rt.atoms.free(dep_name);
        rt.atoms.free(value_name);
        rt.atoms.free(dep_local_name);
        rt.atoms.free(indirect_name);
    }

    const dep = try rt.modules.create(dep_name);
    try dep.addExport(value_name, dep_local_name);

    var parsed = try engine.frontend.parser.parse(
        rt,
        "import { v as local } from 'dep' with { type: \"json\" }; export { v as vv } from 'dep'; export * from 'dep'; await 0;",
        .{ .mode = .module, .filename = "main.mjs" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    _ = try engine.exec.module.instantiateParsedRecord(rt, main_name, &parsed.function);
    const main = rt.modules.find(main_name).?;
    try std.testing.expectEqual(@as(usize, 3), main.requested_modules.len);
    try std.testing.expectEqual(@as(usize, 1), main.imports.len);
    try std.testing.expectEqual(@as(usize, 1), main.indirect_exports.len);
    try std.testing.expectEqual(@as(usize, 1), main.star_exports.len);
    try std.testing.expectEqual(@as(usize, 1), main.import_attributes.len);
    try std.testing.expect(main.has_top_level_await);

    const indirect = try rt.modules.resolveExport(main_name, indirect_name);
    try std.testing.expectEqual(.resolved, std.meta.activeTag(indirect));
    try std.testing.expectEqual(dep_local_name, indirect.resolved.local_name);

    const star = try rt.modules.resolveExport(main_name, value_name);
    try std.testing.expectEqual(.resolved, std.meta.activeTag(star));
    try std.testing.expectEqual(dep_local_name, star.resolved.local_name);
}

test "RegExp character classes match validator-style sources" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(/[a]/.test("a"));
        \\print(/[a]/.test("b"));
        \\print(/[ab]/.test("b"));
        \\print(/[A-Z]/.test("F"));
        \\print(/[0-9]/.test("5"));
        \\print(/[0-9A-Z_a-z]/.test("f"));
        \\print(/[ ]/.test(" "));
        \\print(/[\u000A\u000D\u2028\u2029]/.test("\n"));
        \\print(/[\u0009\u000B\u000C\u0020\u00A0\uFEFF]/.test(" "));
        \\print(/(?:[A-Za-z]|\uD800[\uDC00-\uDC0B])/.test("f"));
        \\print(/(?:[A-Za-z]|\uD800[\uDC00-\uDC0B])/.test("0"));
        \\print(/^a$/.test("a"));
        \\print(/^a$/.test("ba"));
        \\print(/^[$_a-zA-Z][$_a-zA-Z0-9]*$/u.test("next"));
        \\print(/^[$_a-zA-Z][$_a-zA-Z0-9]*$/u.test("0"));
        \\print(/[$_a-zA-Z][$_a-zA-Z0-9]*/.exec("next")[0]);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\nfalse\ntrue\ntrue\ntrue\ntrue\ntrue\ntrue\ntrue\ntrue\nfalse\ntrue\nfalse\ntrue\nfalse\nnext\n", stream.buffered());
}

test "RegExp character class escapes use the fast class matcher" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\assert.sameValue(/^\d+$/.test("0123456789"), true);
        \\assert.sameValue(/^\D+$/.test("abc-_/"), true);
        \\assert.sameValue(/^\w+$/.test("azAZ09_"), true);
        \\assert.sameValue(/^\W+$/.test("-/:"), true);
        \\assert.sameValue(/^\s+$/.test("\t \n\uFEFF"), true);
        \\assert.sameValue(/^\S+$/.test("abc"), true);
        \\assert.sameValue(/^[\d]+$/.test("123"), true);
        \\assert.sameValue(/^[\D]+$/.exec("abc")[0], "abc");
        \\(function() {
        \\    var re = /\D+/g;
        \\    assert.sameValue(re.exec("12abc")[0], "abc");
        \\    assert.sameValue(re.lastIndex, 5);
        \\    assert.sameValue(re.exec("12abc"), null);
        \\    assert.sameValue(re.lastIndex, 0);
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp compiles and executes Latin-1 source characters" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\assert.sameValue(new RegExp("\u00e9+", "").test("\u00e9\u00e9"), true);
        \\assert.sameValue(new RegExp("\u00e9+", "u").test("\u00e9\u00e9"), true);
        \\assert.sameValue(/\u00e9+/.test("\u00e9\u00e9"), true);
        \\assert.sameValue("\u00e9\u00e9".search(new RegExp("\u00e9+")), 0);
        \\assert.sameValue("\u00e9\u00e9".match(new RegExp("\u00e9+"))[0], "\u00e9\u00e9");
        \\var re = /a/;
        \\re.compile("\u00e9+", "");
        \\assert.sameValue(re.test("\u00e9\u00e9"), true);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp accepts empty modifier groups and rejects duplicate modifiers" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\assert.sameValue(/(?i:)/.test(""), true);
        \\assert.sameValue(/a(?-ims:)b/.test("ab"), true);
        \\assert.sameValue(/(?i:(?s:))/.test(""), true);
        \\assert.sameValue(new RegExp("(?im-s:)").test(""), true);
        \\assert.sameValue(new RegExp("a(?i:)b").test("ab"), true);
        \\assert.sameValue(new RegExp("(?i:a)").test("A"), true);
        \\assert.sameValue(/(?i:a)/.test("A"), true);
        \\assert.throws(SyntaxError, function() { new RegExp("(?i-i:)"); });
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expect(!js.context.hasException());
}

test "RegExp dotAll modifier groups rewrite scoped dot semantics" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\assert.sameValue(/(?s:^.$)/.test("\n"), true);
        \\assert.sameValue(new RegExp("(?s:^.$)").test("\u2028"), true);
        \\assert.sameValue(/a.(?s:b.b).c/.test("a,b\nb,c"), true);
        \\assert.sameValue(/a.(?s:b.b).c/.test("a\nb\nb,c"), false);
        \\assert.sameValue(/(?-s:^.$)/s.test("\n"), false);
        \\assert.sameValue(new RegExp("(?-s:^.$)", "s").test("\r"), false);
        \\assert.sameValue(/a.(?-s:b.b).c/s.test("a\nb,b\nc"), true);
        \\assert.sameValue(/a.(?-s:b.b).c/s.test("a,b\nb,c"), false);
        \\assert.sameValue(/(?-s:(?s:^.$))/s.test("\n"), true);
        \\assert.sameValue(/(?s:(?-s:^.$))/.test("\n"), false);
        \\assert.sameValue(/(?si:^.$)/.test("\n"), true);
        \\assert.sameValue(/(?i:(?s:^.$))/.test("\n"), true);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expect(!js.context.hasException());
}

test "RegExp multiline modifier groups rewrite scoped anchor semantics" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\assert.sameValue(/(?m:es$)/.test("es\ns"), true);
        \\assert.sameValue(new RegExp("(?m:^b$)").test("a\nb\nc"), true);
        \\assert.sameValue(/^a\n(?m:^b$)\nc$/.test("a\nb\nc"), true);
        \\assert.sameValue(/^a\n(?m:^b$)\nc$/.test("\na\nb\nc"), false);
        \\assert.sameValue(/^a\n(?m:^b$)\nc$/.test("a\nb\nc\n"), false);
        \\assert.sameValue(/^(?-m:es$)/m.test("\nes\ns"), false);
        \\assert.sameValue(/^(?-m:es$)/m.test("\nes"), true);
        \\assert.sameValue(/(?-m:es.$)/m.test("esz\n"), false);
        \\assert.sameValue(/(?-m:es.$)/ms.test("es\n\n"), false);
        \\assert.sameValue(/(?-m:^es)$/m.test("e\nes\n"), false);
        \\assert.sameValue(/(?-m:^es)$/m.test("es\n"), true);
        \\assert.sameValue(/(?-m:es(?m:$)|js$)/m.test("es\ns"), true);
        \\assert.sameValue(/(?-m:es(?m:$)|js$)/m.test("js"), true);
        \\assert.sameValue(/(?-m:es(?m:$)|js$)/m.test("js\ns"), false);
        \\assert.sameValue(/(?ms:^.$)/.test("\n"), true);
        \\assert.sameValue(/(?m-i:^a$)/i.test("A\n"), false);
        \\assert.sameValue(/(?m-i:^a$)/i.test("a\n"), true);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expect(!js.context.hasException());
}

test "RegExp ignoreCase modifier groups rewrite ASCII case semantics" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\assert.sameValue(/(?i:a)b/.test("Ab"), true);
        \\assert.sameValue(/(?i:a)b/.test("AB"), false);
        \\assert.sameValue(/a(?i:b)c/.test("aBc"), true);
        \\assert.sameValue(/a(?i:b)c/.test("ABC"), false);
        \\assert.sameValue(/(?i:[ab])c/.test("Ac"), true);
        \\assert.sameValue(/(?i:[^ab])c/.test("Ac"), false);
        \\assert.sameValue(/(?i:\x61)b/.test("Ab"), true);
        \\assert.sameValue(/(?i:\u0061)b/.test("Ab"), true);
        \\assert.sameValue(/(?i:\u{0061})b/u.test("Ab"), true);
        \\assert.sameValue(/(?-i:fo)o/i.test("FOO"), false);
        \\assert.sameValue(/(?-i:fo)o/i.test("foO"), true);
        \\assert.sameValue(/b(?-i:a)z/i.test("bAz"), false);
        \\assert.sameValue(/b(?-i:a)z/i.test("BaZ"), true);
        \\assert.sameValue(/a|b|(?i:c)|d|e/.test("C"), true);
        \\assert.sameValue(/a|b|(?i:c)|d|e/.test("D"), false);
        \\assert.sameValue(/a|b|(?-i:c)|d|e/i.test("C"), false);
        \\assert.sameValue(/a|b|(?-i:c)|d|e/i.test("D"), true);
        \\assert.sameValue(/(?i:es$)/m.test("eS\nz"), true);
        \\assert.sameValue(/(?-i:es$)/im.test("eS\nz"), false);
        \\assert.sameValue(/(?i:.es)/s.test("\neS"), true);
        \\assert.sameValue(/(?-i:.es)/is.test("\neS"), false);
        \\assert.sameValue(/(?i:\b)/u.test("\u017f"), true);
        \\assert.sameValue(/(?i:\b)/u.test("\u212a"), true);
        \\assert.sameValue(/(?i:Z\B)/u.test("Z\u017f"), true);
        \\assert.sameValue(/(?i:Z\B)/u.test("Z\u212a"), true);
        \\assert.sameValue(/(?i:\p{Lu})/u.test("A"), true);
        \\assert.sameValue(/(?i:\p{Lu})/u.test("a"), true);
        \\assert.sameValue(/(?i:\P{Lu})/u.test("A"), true);
        \\assert.sameValue(/(?i:\P{Lu})/u.test("0"), true);
        \\assert.sameValue(/(a)(?i:\1)/.test("aa"), true);
        \\assert.sameValue(/(a)(?i:\1)/.test("aA"), true);
        \\assert.sameValue(/(a)(?i:\1)/.test("AA"), false);
        \\assert.sameValue(/(a)(?i-:\1)/.test("aA"), true);
        \\assert.sameValue(/(ab)(?i:\1)/.test("abAB"), true);
        \\assert.sameValue(/(\x61)(?i:\1)/.test("aA"), true);
        \\assert.throws(SyntaxError, function() { new RegExp("(a+)(?i:\\1)"); });
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expect(!js.context.hasException());
}

test "RegExp unicode classes handle property escapes and surrogate pairs" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\assert.sameValue(/[\p{Hex}\P{Hex}]/u.test("\u{1D306}"), true);
        \\assert.sameValue(/[\p{Hex}]/u.test("F"), true);
        \\assert.sameValue(/[\p{Hex}]/u.test("G"), false);
        \\assert.sameValue(/[\P{Hex}]/u.exec("\u{1D306}")[0], "\u{1D306}");
        \\assert.sameValue(/^[\ud834\udf06]$/u.test("\ud834\udf06"), true);
        \\assert.sameValue(/^[\ud800\udc00]$/u.test("\ud800\udc00"), true);
        \\assert.sameValue(/[\ud800\udc00]/u.test("\ud800"), false);
        \\assert.sameValue(/[\ud800\udc00]/u.test("\udc00"), false);
        \\assert.sameValue(/^\S$/u.test("\ud800\udc00"), true);
        \\assert.sameValue(/\udf06/u.exec("\ud834\udf06"), null);
        \\assert.sameValue(/\udf06/u[Symbol.search]("\ud834\udf06"), -1);
        \\var inferred = /\udf06/;
        \\Object.defineProperty(inferred, "unicode", { value: true });
        \\assert.notSameValue(inferred[Symbol.match]("\ud834\udf06"), null);
        \\var slotted = /\udf06/u;
        \\Object.defineProperty(slotted, "unicode", { value: false });
        \\assert.sameValue(slotted[Symbol.match]("\ud834\udf06"), null);
        \\var sticky = /\udf06/uy;
        \\sticky.lastIndex = 1;
        \\assert.sameValue(sticky.exec("\ud834\udf06")[0], "\udf06");
        \\assert.sameValue(sticky.lastIndex, 2);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp exec handles captures named groups indices and lastIndex" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var re = /(\d+)-(\d+)/dg;
        \\    var match = re.exec("123-456 9-10");
        \\    assert.sameValue(match[0], "123-456");
        \\    assert.sameValue(match[1], "123");
        \\    assert.sameValue(match[2], "456");
        \\    assert.sameValue(match.index, 0);
        \\    assert.sameValue(Object.keys(match).join("|"), "0|1|2|index|input|groups|indices");
        \\    assert.sameValue(Object.getOwnPropertyDescriptor(match, "index").enumerable, true);
        \\    assert.sameValue(Object.getOwnPropertyDescriptor(match, "input").enumerable, true);
        \\    assert.sameValue(re.lastIndex, 7);
        \\    assert.sameValue(match.indices[0][0], 0);
        \\    assert.sameValue(match.indices[0][1], 7);
        \\    assert.sameValue(match.indices[1][0], 0);
        \\    assert.sameValue(match.indices[1][1], 3);
        \\    assert.sameValue(match.indices[2][0], 4);
        \\    assert.sameValue(match.indices[2][1], 7);
        \\
        \\    var named = /(?<lhs>\d+)-(?<rhs>\d+)/d.exec("12-34");
        \\    assert.sameValue(named.groups.lhs, "12");
        \\    assert.sameValue(named.groups.rhs, "34");
        \\    assert.sameValue(named.indices.groups.lhs[0], 0);
        \\    assert.sameValue(named.indices.groups.lhs[1], 2);
        \\    assert.sameValue(named.indices.groups.rhs[0], 3);
        \\    assert.sameValue(named.indices.groups.rhs[1], 5);
        \\
        \\    assert.sameValue(/\d+/.test("abc"), false);
        \\    assert.sameValue("123-456".search(/(\d+)-(\d+)/), 0);
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp executes anchored Unknown script property escapes" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var unknown = String.fromCodePoint(0x0378);
        \\    var lowSurrogate = String.fromCharCode(0xdc00);
        \\    var known = "A";
        \\    var supplementary = String.fromCodePoint(0x1000C);
        \\
        \\    var match = /^\p{Script=Unknown}+$/u.exec(unknown + supplementary);
        \\    assert.sameValue(match[0], unknown + supplementary);
        \\    assert.sameValue(match.index, 0);
        \\    assert.sameValue(/^\p{Script=Unknown}+$/u.test(lowSurrogate), true);
        \\    assert.sameValue(/\p{Script=Unknown}/u.test(lowSurrogate), true);
        \\    assert.sameValue(/^\p{Script=Zzzz}+$/u.test(unknown), true);
        \\    assert.sameValue(/^\p{sc=Unknown}+$/u.test(unknown), true);
        \\    assert.sameValue(/^\p{sc=Zzzz}+$/u.test(unknown), true);
        \\    assert.sameValue(/^\p{Script_Extensions=Unknown}+$/u.test(unknown), true);
        \\    assert.sameValue(/^\p{Script_Extensions=Zzzz}+$/u.test(unknown), true);
        \\    assert.sameValue(/^\p{scx=Unknown}+$/u.test(unknown), true);
        \\    assert.sameValue(/^\p{scx=Zzzz}+$/u.test(unknown), true);
        \\
        \\    assert.sameValue(/^\P{Script=Unknown}+$/u.test(known), true);
        \\    assert.sameValue(/^\P{Script_Extensions=Unknown}+$/u.test(known), true);
        \\    assert.sameValue(/^\P{Script=Unknown}+$/u.test(unknown), false);
        \\
        \\    var global = /^\p{Script=Unknown}+$/gu;
        \\    assert.sameValue(global.test(unknown), true);
        \\    assert.sameValue(global.lastIndex, 1);
        \\    assert.sameValue(global.test(unknown), false);
        \\    assert.sameValue(global.lastIndex, 0);
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp v flag uses Unicode code point execution" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var text = "𠮷a𠮷b𠮷";
        \\
        \\    var literal = /𠮷/.exec(text);
        \\    assert.sameValue(literal[0], "𠮷");
        \\    assert.sameValue(literal.index, 0);
        \\
        \\    var prop = /\p{Script=Han}/v.exec(text);
        \\    assert.sameValue(prop[0], "𠮷");
        \\    assert.sameValue(prop.index, 0);
        \\    assert.sameValue(/\P{ASCII}/v.exec("a𠮷")[0], "𠮷");
        \\
        \\    assert.compareArray(text.match(/\p{Script=Han}/gv), ["𠮷", "𠮷", "𠮷"]);
        \\    assert.sameValue(text.search(/\p{Script=Han}/v), 0);
        \\    assert.sameValue(text.replace(/\p{Script=Han}/gv, "X"), "XaXbX");
        \\    assert.sameValue(text.replace(/𠮷/v, "-"), "-a𠮷b𠮷");
        \\    assert.sameValue(text.replace(/./gv, function (match, index) {
        \\        return "[" + match + ":" + index + "]";
        \\    }), "[𠮷:0][a:2][𠮷:3][b:5][𠮷:6]");
        \\
        \\    var all = Array.from(text.matchAll(/\p{Script=Han}/gv));
        \\    assert.compareArray(all.map(function (m) { return m[0]; }), ["𠮷", "𠮷", "𠮷"]);
        \\    assert.compareArray(all.map(function (m) { return m.index; }), [0, 3, 6]);
        \\    assert.sameValue(Array.from(text.matchAll(/(?:)/gv)).length, 6);
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp v flag supports RGI_Emoji string properties" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var flag = "🇨🇶";
        \\    var zwj = "👨🏻‍🐰‍👨🏼";
        \\
        \\    assert.sameValue(/^\p{RGI_Emoji}+$/v.test(flag), true);
        \\    assert.sameValue(new RegExp("^\\p{RGI_Emoji}+$", "gv").test(flag), true);
        \\    assert.sameValue(/^\p{RGI_Emoji}+$/v.test(zwj), true);
        \\    assert.sameValue(/^\p{RGI_Emoji}+$/v.test(flag + zwj), true);
        \\    assert.sameValue(/^\p{RGI_Emoji}+$/v.test("a"), false);
        \\    assert.sameValue(/^\p{RGI_Emoji}+$/v.test("🏻‍❤️‍💋‍👨🏻"), false);
        \\    assert.sameValue(/^\p{RGI_Emoji}+$/v.test("☎"), false);
        \\    assert.sameValue(/^\p{RGI_Emoji}+$/v.test("☎️"), true);
        \\
        \\    var match = /\p{RGI_Emoji}/v.exec("a" + flag + "b");
        \\    assert.sameValue(match[0], flag);
        \\    assert.sameValue(match.index, 1);
        \\
        \\    var global = /\p{RGI_Emoji}/gv;
        \\    assert.sameValue(global.exec(flag + "x")[0], flag);
        \\    assert.sameValue(global.lastIndex, 4);
        \\    assert.sameValue(global.exec(flag + "x"), null);
        \\    assert.sameValue(global.lastIndex, 0);
        \\
        \\    assert.throws(SyntaxError, function () { eval("/\\p{RGI_Emoji}/u"); });
        \\    assert.throws(SyntaxError, function () { eval("/\\P{RGI_Emoji}/v"); });
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp parser accepts regex literals after arguments references" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var f = function() {
        \\        var seen = arguments;
        \\        var re = /\w/g;
        \\        assert.sameValue(seen.length, 0);
        \\        return re.test("a");
        \\    };
        \\    assert.sameValue(f(), true);
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "string wrapper method lookup and regexp literals handle latin1 and unicode escape group names" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var s = String.fromCharCode(0x80);
        \\    assert.sameValue(s.replace(/\S+/g, "test262"), "test262");
        \\    assert.sameValue(/(?<\u{03C0}>a)/u.exec("bab").groups.π, "a");
        \\    assert.sameValue(/(?<a\u{104A4}>.)/u.test("a"), true);
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "generator next rejects reentry and completes generator" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var iter;
        \\function* g() {
        \\    iter.next();
        \\}
        \\iter = g();
        \\assert.throws(TypeError, function() { iter.next(); });
        \\var result = iter.next();
        \\assert.sameValue(result.value, undefined);
        \\assert.sameValue(result.done, true);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "generator prototype exposes spec methods and tag" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function* g() {}
        \\var Generator = Object.getPrototypeOf(g);
        \\var GeneratorPrototype = Generator.prototype;
        \\assert.sameValue(GeneratorPrototype.next.length, 1);
        \\assert.sameValue(GeneratorPrototype.next.name, "next");
        \\assert.sameValue(GeneratorPrototype.return.length, 1);
        \\assert.sameValue(GeneratorPrototype.throw.name, "throw");
        \\assert.sameValue(GeneratorPrototype.constructor, Generator);
        \\assert.sameValue(GeneratorPrototype[Symbol.toStringTag], "Generator");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "generator iterator results and throw start/completed semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function E() {}
        \\function* g() { yield 1; }
        \\var iter = g();
        \\var first = iter.next();
        \\assert.sameValue(Object.getPrototypeOf(first), Object.prototype);
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(first, "value"), true);
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(first, "done"), true);
        \\var completed = g();
        \\completed.next();
        \\completed.next();
        \\assert.throws(E, function() { completed.throw(new E()); });
        \\assert.sameValue(completed.next().done, true);
        \\var suspendedStart = g();
        \\assert.throws(E, function() { suspendedStart.throw(new E()); });
        \\assert.sameValue(suspendedStart.next().done, true);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Symbol registry keyFor description and toPrimitive surface" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var registered = Symbol.for("zjs-symbol-registry");
        \\assert.sameValue(Symbol.for("zjs-symbol-registry"), registered);
        \\assert.sameValue(Symbol.keyFor(registered), "zjs-symbol-registry");
        \\assert.sameValue(Symbol.keyFor(Symbol("zjs-symbol-registry")), undefined);
        \\assert.sameValue(Symbol.keyFor(Symbol("Symbol.for:zjs-symbol-registry")), undefined);
        \\assert.sameValue(Symbol.for("zjs-symbol-registry") === Symbol("Symbol.for:zjs-symbol-registry"), false);
        \\assert.throws(TypeError, function() { Symbol.keyFor(Object(registered)); });
        \\assert.sameValue(registered.description, "zjs-symbol-registry");
        \\assert.sameValue(String(registered), "Symbol(zjs-symbol-registry)");
        \\assert.sameValue(Symbol.prototype[Symbol.toPrimitive].call(registered, "string"), registered);
        \\assert.sameValue(Symbol.prototype[Symbol.toPrimitive].name, "[Symbol.toPrimitive]");
        \\assert.sameValue(Symbol.prototype[Symbol.toPrimitive].length, 1);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Symbol.for does not retain per returned value" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\for (var i = 0; i < 20; i++) Symbol.for("zjs-symbol-registry-refcount");
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());

    const registered = try js.runtime.atoms.internSymbol("Symbol.for:zjs-symbol-registry-refcount");
    defer js.runtime.atoms.free(registered);
    try std.testing.expectEqual(@as(usize, 2), js.runtime.atoms.refCount(registered).?);
}

test "Symbol registry statics work when detached or reflect-applied" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var detachedFor = Symbol.for;
        \\var detachedKeyFor = Symbol.keyFor;
        \\var registered = detachedFor("zjs-detached-symbol");
        \\assert.sameValue(registered, Symbol.for("zjs-detached-symbol"));
        \\assert.sameValue(detachedKeyFor(registered), "zjs-detached-symbol");
        \\assert.sameValue(Reflect.apply(Symbol.for, undefined, ["zjs-reflect-symbol"]), Symbol.for("zjs-reflect-symbol"));
        \\assert.sameValue(Reflect.apply(Symbol.keyFor, undefined, [registered]), "zjs-detached-symbol");
        \\assert.throws(TypeError, function() { detachedFor(Symbol("bad")); });
        \\assert.throws(TypeError, function() { detachedKeyFor(Object(registered)); });
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Date prototype Symbol.toPrimitive is installed and respects hint order" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(typeof Date.prototype[Symbol.toPrimitive], "function");
        \\assert.sameValue(Date.prototype[Symbol.toPrimitive].name, "[Symbol.toPrimitive]");
        \\assert.sameValue(Date.prototype[Symbol.toPrimitive].length, 1);
        \\verifyProperty(Date.prototype, Symbol.toPrimitive, { writable: false, enumerable: false, configurable: true });
        \\var log = [];
        \\var obj = {
        \\    toString: function() { log.push("toString"); return "string-first"; },
        \\    valueOf: function() { log.push("valueOf"); return 17; }
        \\};
        \\assert.sameValue(Date.prototype[Symbol.toPrimitive].call(obj, "default"), "string-first");
        \\assert.compareArray(log, ["toString"]);
        \\log = [];
        \\assert.sameValue(Date.prototype[Symbol.toPrimitive].call(obj, "string"), "string-first");
        \\assert.compareArray(log, ["toString"]);
        \\log = [];
        \\assert.sameValue(Date.prototype[Symbol.toPrimitive].call(obj, "number"), 17);
        \\assert.compareArray(log, ["valueOf"]);
        \\var fallback = { toString: 1, valueOf: function() { return 23; } };
        \\assert.sameValue(Date.prototype[Symbol.toPrimitive].call(fallback, "string"), 23);
        \\assert.sameValue(Date.prototype[Symbol.toPrimitive].call(new Date(0), "number"), 0);
        \\assert.throws(TypeError, function() { Date.prototype[Symbol.toPrimitive].call(1, "string"); });
        \\assert.throws(TypeError, function() { Date.prototype[Symbol.toPrimitive].call({}, "String"); });
        \\assert.throws(TypeError, function() { Date.prototype[Symbol.toPrimitive].call({}, new String("string")); });
        \\assert.throws(TypeError, function() {
        \\    Date.prototype[Symbol.toPrimitive].call({
        \\        toString: function() { return {}; },
        \\        valueOf: function() { return {}; }
        \\    }, "default");
        \\});
        \\var date = new Date(0);
        \\assert.sameValue(0 + date, 0 + date.toString());
        \\delete Date.prototype[Symbol.toPrimitive];
        \\assert.sameValue(0 + date, 0 + date.valueOf());
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Boolean prototype carries false primitive data and valueOf ignores arguments" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(Boolean.prototype.valueOf(), false);
        \\assert.sameValue(Boolean.prototype.valueOf(true), false);
        \\assert.sameValue((new Boolean()).valueOf(true), false);
        \\assert.sameValue((new Boolean(1)).valueOf(false), true);
        \\assert.sameValue(Boolean.prototype.toString(), "false");
        \\assert.sameValue(Object.prototype.toString.call(Boolean.prototype), "[object Boolean]");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "object literal method name inference does not name the containing object" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var desc = { enumerable: true, configurable: true, get() { return 42; }, set() {} };
        \\assert.compareArray(Object.getOwnPropertyNames(desc), ["enumerable", "configurable", "get", "set"]);
        \\assert.sameValue(desc.get.name, "get");
        \\assert.sameValue(desc.set.name, "set");
        \\var methods = { method() {}, *gen() {}, async asyncMethod() {} };
        \\assert.compareArray(Object.getOwnPropertyNames(methods), ["method", "gen", "asyncMethod"]);
        \\assert.sameValue(methods.method.name, "method");
        \\assert.sameValue(methods.gen.name, "gen");
        \\assert.sameValue(methods.asyncMethod.name, "asyncMethod");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "return conditional expression composes with trailing binary expression" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function label(str, i) {
        \\    return (i === 0 ? "" : "1") + str;
        \\}
        \\assert.sameValue(label("[", 0), "[");
        \\assert.sameValue(label("]", 1), "1]");
        \\assert.sameValue(((str, i) => (i === 0 ? "" : "1") + str)("[", 0), "[");
        \\assert.sameValue(((str, i) => (i === 0 ? "" : "1") + str)("]", 1), "1]");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "rest parameter copies captured argument values instead of var-ref cells" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function outer(...mappers) {
        \\    function x() {
        \\        return typeof mappers[0] + ":" + mappers[0]([1, 2]);
        \\    }
        \\    return { x: x };
        \\}
        \\var result = outer(function(values) { return values.join(","); }).x();
        \\assert.sameValue(result, "function:1,2");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Symbol constructor and Symbol.for perform string-hint ToString" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var calls = "";
        \\var key = { toString: function() { calls += "toString"; return "test262"; } };
        \\var registered = Symbol.for(key);
        \\assert.sameValue(calls, "toString");
        \\assert.sameValue(registered.description, "test262");
        \\assert.sameValue(Symbol.keyFor(registered), "test262");
        \\calls = "";
        \\var desc = {
        \\    toString: function() { calls += "toString"; return {}; },
        \\    valueOf: function() { calls += "valueOf"; return "fallback"; },
        \\};
        \\assert.sameValue(Symbol(desc).description, "fallback");
        \\assert.sameValue(calls, "toStringvalueOf");
        \\assert.sameValue(Symbol().description, undefined);
        \\assert.sameValue(Symbol(undefined).description, undefined);
        \\assert.sameValue(Symbol("").description, "");
        \\assert.throws(TypeError, function() { Symbol(Symbol("x")); });
        \\assert.throws(TypeError, function() { new Symbol(); });
        \\var primitiveDesc = Object.getOwnPropertyDescriptor(Symbol.prototype, Symbol.toPrimitive);
        \\assert.sameValue(primitiveDesc.writable, false);
        \\assert.sameValue(primitiveDesc.enumerable, false);
        \\assert.sameValue(primitiveDesc.configurable, true);
        \\var tagDesc = Object.getOwnPropertyDescriptor(Symbol.prototype, Symbol.toStringTag);
        \\assert.sameValue(tagDesc.value, "Symbol");
        \\assert.sameValue(tagDesc.writable, false);
        \\assert.sameValue(tagDesc.enumerable, false);
        \\assert.sameValue(tagDesc.configurable, true);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "AggregateError converts message before iterable errors and stores list" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var sequence = [];
        \\var message = {
        \\    toString: function() {
        \\        sequence.push(1);
        \\        return "message";
        \\    }
        \\};
        \\var emptyErrors = {
        \\    [Symbol.iterator]: function() {
        \\        sequence.push(2);
        \\        return {
        \\            next: function() {
        \\                sequence.push(3);
        \\                return { done: true };
        \\            }
        \\        };
        \\    }
        \\};
        \\var error = new AggregateError(emptyErrors, message);
        \\assert.compareArray(sequence, [1, 2, 3]);
        \\assert.sameValue(error.message, "message");
        \\assert.compareArray(error.errors, []);
        \\
        \\var count = 0;
        \\var errors = {
        \\    [Symbol.iterator]: function() {
        \\        return {
        \\            next: function() {
        \\                count += 1;
        \\                return { done: count === 3, value: count };
        \\            }
        \\        };
        \\    }
        \\};
        \\var collected = AggregateError(errors).errors;
        \\assert.compareArray(collected, [1, 2]);
        \\assert.throws(TypeError, function() { new AggregateError(); });
        \\assert.throws(TypeError, function() { new AggregateError([], Symbol()); });
        \\assert.throws(Test262Error, function() {
        \\    new AggregateError([], {
        \\        [Symbol.toPrimitive]: function() { throw new Test262Error(); }
        \\    });
        \\});
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "AggregateError iterable failure keeps caught error alive" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\var errors = {
        \\    [Symbol.iterator]: function() {
        \\        return {
        \\            next: function() {
        \\                throw new Test262Error();
        \\            }
        \\        };
        \\    }
        \\};
        \\var caught;
        \\try {
        \\    new AggregateError(errors);
        \\} catch (e) {
        \\    caught = e;
        \\}
        \\assert.sameValue(caught.name, "Test262Error");
        \\caught.marker = 33;
        \\assert.sameValue(caught.marker, 33);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "SuppressedError constructor creates error and suppressed records" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(typeof SuppressedError, "function");
        \\verifyProperty(globalThis, "SuppressedError", {
        \\    writable: true,
        \\    enumerable: false,
        \\    configurable: true
        \\});
        \\assert.sameValue(SuppressedError.length, 3);
        \\assert.sameValue(SuppressedError.name, "SuppressedError");
        \\assert.sameValue(Object.getPrototypeOf(SuppressedError), Error);
        \\assert.sameValue(Object.getPrototypeOf(SuppressedError.prototype), Error.prototype);
        \\verifyProperty(SuppressedError.prototype, "constructor", {
        \\    value: SuppressedError,
        \\    writable: true,
        \\    enumerable: false,
        \\    configurable: true
        \\});
        \\verifyProperty(SuppressedError.prototype, "name", {
        \\    value: "SuppressedError",
        \\    writable: true,
        \\    enumerable: false,
        \\    configurable: true
        \\});
        \\verifyProperty(SuppressedError.prototype, "message", {
        \\    value: "",
        \\    writable: true,
        \\    enumerable: false,
        \\    configurable: true
        \\});
        \\assert.sameValue(SuppressedError.prototype.hasOwnProperty("error"), false);
        \\assert.sameValue(SuppressedError.prototype.hasOwnProperty("suppressed"), false);
        \\
        \\var error = { tag: "error" };
        \\var suppressed = { tag: "suppressed" };
        \\var sequence = [];
        \\var message = {
        \\    toString: function() {
        \\        sequence.push("message");
        \\        return "message";
        \\    }
        \\};
        \\var instance = new SuppressedError(error, suppressed, message);
        \\assert.compareArray(sequence, ["message"]);
        \\assert.sameValue(Object.getPrototypeOf(instance), SuppressedError.prototype);
        \\assert.sameValue(instance instanceof SuppressedError, true);
        \\assert.sameValue(instance instanceof Error, true);
        \\assert.sameValue(instance.hasOwnProperty("name"), false);
        \\verifyProperty(instance, "message", {
        \\    value: "message",
        \\    writable: true,
        \\    enumerable: false,
        \\    configurable: true
        \\});
        \\verifyProperty(instance, "error", {
        \\    value: error,
        \\    writable: true,
        \\    enumerable: false,
        \\    configurable: true
        \\});
        \\verifyProperty(instance, "suppressed", {
        \\    value: suppressed,
        \\    writable: true,
        \\    enumerable: false,
        \\    configurable: true
        \\});
        \\var names = Object.getOwnPropertyNames(instance);
        \\var messageIndex = names.indexOf("message");
        \\assert.sameValue(messageIndex >= 0, true);
        \\assert.sameValue(names[messageIndex + 1], "error");
        \\assert.sameValue(names[messageIndex + 2], "suppressed");
        \\
        \\var called = SuppressedError();
        \\assert.sameValue(Object.getPrototypeOf(called), SuppressedError.prototype);
        \\assert.sameValue(called instanceof SuppressedError, true);
        \\assert.sameValue(called.error, undefined);
        \\assert.sameValue(called.suppressed, undefined);
        \\assert.sameValue(called.hasOwnProperty("message"), false);
        \\
        \\var customProto = {};
        \\function NewTarget() {}
        \\NewTarget.prototype = customProto;
        \\var custom = Reflect.construct(SuppressedError, [error, suppressed, "custom"], NewTarget);
        \\assert.sameValue(Object.getPrototypeOf(custom), customProto);
        \\NewTarget.prototype = 1;
        \\var fallback = Reflect.construct(SuppressedError, [], NewTarget);
        \\assert.sameValue(Object.getPrototypeOf(fallback), SuppressedError.prototype);
        \\
        \\assert.throws(TypeError, function() {
        \\    new SuppressedError(undefined, undefined, Symbol());
        \\});
        \\assert.throws(Test262Error, function() {
        \\    new SuppressedError(undefined, undefined, {
        \\        [Symbol.toPrimitive]: function() { throw new Test262Error(); }
        \\    });
        \\});
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "DisposableStack stores resources in internal payload metadata" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(typeof DisposableStack, "function");
        \\verifyProperty(globalThis, "DisposableStack", {
        \\    writable: true,
        \\    enumerable: false,
        \\    configurable: true
        \\});
        \\assert.sameValue(DisposableStack.length, 0);
        \\assert.sameValue(DisposableStack.name, "DisposableStack");
        \\assert.sameValue(Object.getPrototypeOf(DisposableStack.prototype), Object.prototype);
        \\assert.sameValue(Object.prototype.toString.call(new DisposableStack()), "[object DisposableStack]");
        \\assert.sameValue(DisposableStack.prototype[Symbol.dispose], DisposableStack.prototype.dispose);
        \\
        \\var stack = new DisposableStack();
        \\assert.sameValue(stack.disposed, false);
        \\assert.sameValue(Object.getOwnPropertyNames(stack).some(function(name) {
        \\    return name.indexOf("__zjs_") === 0;
        \\}), false);
        \\
        \\var disposed = [];
        \\var resource = {
        \\    tag: "resource",
        \\    [Symbol.dispose]: function() { disposed.push("use:" + this.tag); }
        \\};
        \\assert.sameValue(stack.use(null), null);
        \\assert.sameValue(stack.use(undefined), undefined);
        \\assert.sameValue(stack.use(resource), resource);
        \\assert.sameValue(stack.adopt("value", function(value) {
        \\    "use strict";
        \\    disposed.push("adopt:" + value + ":" + (this === undefined));
        \\}), "value");
        \\assert.sameValue(stack.defer(function() {
        \\    "use strict";
        \\    disposed.push("defer:" + (this === undefined));
        \\}), undefined);
        \\stack.dispose();
        \\assert.compareArray(disposed, ["defer:true", "adopt:value:true", "use:resource"]);
        \\assert.sameValue(stack.disposed, true);
        \\stack.dispose();
        \\assert.compareArray(disposed, ["defer:true", "adopt:value:true", "use:resource"]);
        \\assert.throws(ReferenceError, function() { stack.use(resource); });
        \\assert.throws(TypeError, function() { DisposableStack.prototype.use.call({}); });
        \\assert.throws(TypeError, function() { DisposableStack.prototype.disposed; });
        \\
        \\class DerivedStack extends DisposableStack {}
        \\var movedFrom = new DerivedStack();
        \\var moveLog = [];
        \\movedFrom.defer(function() { moveLog.push("moved"); });
        \\var moved = movedFrom.move();
        \\assert.sameValue(moved instanceof DisposableStack, true);
        \\assert.sameValue(moved instanceof DerivedStack, false);
        \\assert.sameValue(movedFrom.disposed, true);
        \\assert.sameValue(moved.disposed, false);
        \\assert.throws(ReferenceError, function() { movedFrom.move(); });
        \\moved.dispose();
        \\assert.compareArray(moveLog, ["moved"]);
        \\
        \\var error1 = new Error("first");
        \\var error2 = new Error("second");
        \\var error3 = new Error("third");
        \\var failing = new DisposableStack();
        \\failing.defer(function() { throw error1; });
        \\failing.defer(function() { throw error2; });
        \\failing.defer(function() { throw error3; });
        \\try {
        \\    failing.dispose();
        \\    throw new Test262Error("dispose should throw");
        \\} catch (error) {
        \\    assert.sameValue(error instanceof SuppressedError, true);
        \\    assert.sameValue(error.error, error1);
        \\    assert.sameValue(error.suppressed instanceof SuppressedError, true);
        \\    assert.sameValue(error.suppressed.error, error2);
        \\    assert.sameValue(error.suppressed.suppressed, error3);
        \\}
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "using declarations dispose sync resources from block payload stack" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var disposed = [];
        \\var r1 = { [Symbol.dispose]: function() { disposed.push("r1"); } };
        \\var r2 = { [Symbol.dispose]: function() { disposed.push("r2"); } };
        \\{
        \\    using first = r1, second = r2;
        \\    assert.sameValue(first, r1);
        \\    assert.sameValue(second, r2);
        \\}
        \\assert.compareArray(disposed, ["r2", "r1"]);
        \\
        \\var initializerDisposed = [];
        \\try {
        \\    {
        \\        using kept = { [Symbol.dispose]: function() { initializerDisposed.push("kept"); } };
        \\        using failed = (function() { throw new Error("init"); })();
        \\    }
        \\    throw new Test262Error("initializer should throw");
        \\} catch (error) {
        \\    assert.sameValue(error.message, "init");
        \\}
        \\assert.compareArray(initializerDisposed, ["kept"]);
        \\
        \\try {
        \\    {
        \\        using resource = {
        \\            [Symbol.dispose]: function() { throw new Error("dispose"); }
        \\        };
        \\        throw new Error("body");
        \\    }
        \\    throw new Test262Error("block should throw");
        \\} catch (error) {
        \\    assert.sameValue(error instanceof SuppressedError, true);
        \\    assert.sameValue(error.error.message, "dispose");
        \\    assert.sameValue(error.suppressed.message, "body");
        \\}
        \\
        \\assert.throws(TypeError, function() {
        \\    { using missing = {}; }
        \\});
        \\
        \\assert.sameValue(eval("{using test262id1 = null;}"), undefined);
        \\assert.sameValue(eval("4; {using test262id5 = null;}"), 4);
        \\
        \\var using = 7;
        \\assert.sameValue(using, 7);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "using declarations in for heads dispose at loop boundaries" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var log = [];
        \\function record(name) {
        \\    return {
        \\        [Symbol.dispose]: function() { log.push(name); }
        \\    };
        \\}
        \\
        \\for (using item = record("for-init"); log.length === 0;) {
        \\    assert.compareArray(log, []);
        \\    break;
        \\}
        \\assert.compareArray(log, ["for-init"]);
        \\
        \\log = [];
        \\try {
        \\    for (using first = record("first"), second = (function() { throw new Error("init"); })();;) {
        \\    }
        \\    throw new Test262Error("initializer should throw");
        \\} catch (error) {
        \\    assert.sameValue(error.message, "init");
        \\}
        \\assert.compareArray(log, ["first"]);
        \\
        \\log = [];
        \\for (using item of [record("a"), null, record("c")]) {
        \\    log.push(item === null ? "body:null" : "body");
        \\}
        \\assert.compareArray(log, ["body", "a", "body:null", "body", "c"]);
        \\
        \\log = [];
        \\for (using item of [record("break")]) {
        \\    break;
        \\}
        \\assert.compareArray(log, ["break"]);
        \\
        \\var using, of = [[9], [8], [7]], result = [];
        \\for (using of of [0, 1, 2]) {
        \\    result.push(using);
        \\}
        \\assert.sameValue(result.length, 1);
        \\assert.sameValue(result[0], 7);
        \\
        \\of = "outer";
        \\for (using of = null;;) {
        \\    assert.sameValue(of, null);
        \\    break;
        \\}
        \\assert.sameValue(of, "outer");
        \\assert.throws(SyntaxError, function() {
        \\    eval("for (using x in {}) {}");
        \\});
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "AsyncDisposableStack awaits payload resources and settles chained promises" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [2048]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var chain = [];
        \\Promise.resolve()
        \\    .then(function() {
        \\        chain.push("first");
        \\        return Promise.resolve().then(function() { chain.push("inner"); });
        \\    })
        \\    .then(function() { chain.push("second"); })
        \\    .then(function() {
        \\        print(chain.join("|"));
        \\
        \\        var globalDesc = Object.getOwnPropertyDescriptor(globalThis, "AsyncDisposableStack");
        \\        print([
        \\            typeof AsyncDisposableStack,
        \\            AsyncDisposableStack.length,
        \\            AsyncDisposableStack.name,
        \\            globalDesc.writable,
        \\            globalDesc.enumerable,
        \\            globalDesc.configurable,
        \\            Object.getPrototypeOf(AsyncDisposableStack.prototype) === Object.prototype,
        \\            Object.prototype.toString.call(new AsyncDisposableStack()),
        \\            AsyncDisposableStack.prototype[Symbol.asyncDispose] === AsyncDisposableStack.prototype.disposeAsync
        \\        ].join("|"));
        \\
        \\        var stack = new AsyncDisposableStack();
        \\        print([stack.disposed, Object.getOwnPropertyNames(stack).some(function(name) {
        \\            return name.indexOf("__zjs_") === 0;
        \\        })].join("|"));
        \\
        \\        var disposed = [];
        \\        var asyncResource = {
        \\            tag: "async",
        \\            [Symbol.asyncDispose]: function() {
        \\                disposed.push("async:" + this.tag);
        \\                return Promise.resolve().then(function() { disposed.push("async-awaited"); });
        \\            }
        \\        };
        \\        var syncResource = {
        \\            tag: "sync",
        \\            [Symbol.dispose]: function() { disposed.push("sync:" + this.tag); }
        \\        };
        \\        var useNull = stack.use(null) === null;
        \\        var useUndefined = stack.use(undefined) === undefined;
        \\        var useAsync = stack.use(asyncResource) === asyncResource;
        \\        var useSync = stack.use(syncResource) === syncResource;
        \\        var adoptReturn = stack.adopt("value", function(value) {
        \\            disposed.push("adopt:" + value);
        \\            return Promise.resolve();
        \\        }) === "value";
        \\        var deferReturn = stack.defer(function() {
        \\            disposed.push("defer");
        \\        }) === undefined;
        \\        var disposePromise = stack.disposeAsync();
        \\        print([useNull, useUndefined, useAsync, useSync, adoptReturn, deferReturn, disposePromise instanceof Promise, stack.disposed].join("|"));
        \\        return disposePromise.then(function() {
        \\            print(disposed.join("|"));
        \\            return stack.disposeAsync();
        \\        }).then(function() {
        \\            print(disposed.join("|"));
        \\            var useAfterDisposed = false;
        \\            try { stack.use(syncResource); } catch (error) { useAfterDisposed = error instanceof ReferenceError; }
        \\            var useBadReceiver = false;
        \\            try { AsyncDisposableStack.prototype.use.call({}); } catch (error) { useBadReceiver = error instanceof TypeError; }
        \\            var getBadReceiver = false;
        \\            try { AsyncDisposableStack.prototype.disposed; } catch (error) { getBadReceiver = error instanceof TypeError; }
        \\            print([useAfterDisposed, useBadReceiver, getBadReceiver].join("|"));
        \\            return AsyncDisposableStack.prototype.disposeAsync.call({}).then(
        \\                function() { print("missing receiver rejection"); },
        \\                function(error) { print(error instanceof TypeError); }
        \\            );
        \\        });
        \\    })
        \\    .then(function() {
        \\        class DerivedAsyncStack extends AsyncDisposableStack {}
        \\        var movedFrom = new DerivedAsyncStack();
        \\        var moveLog = [];
        \\        movedFrom.defer(function() { moveLog.push("moved"); });
        \\        var moved = movedFrom.move();
        \\        var moveAgain = false;
        \\        try { movedFrom.move(); } catch (error) { moveAgain = error instanceof ReferenceError; }
        \\        return moved.disposeAsync().then(function() {
        \\            print([moved instanceof AsyncDisposableStack, moved instanceof DerivedAsyncStack, movedFrom.disposed, moved.disposed, moveAgain, moveLog.join("|")].join("|"));
        \\        });
        \\    })
        \\    .then(function() {
        \\        var error1 = new Error("first");
        \\        var error2 = new Error("second");
        \\        var error3 = new Error("third");
        \\        var failing = new AsyncDisposableStack();
        \\        failing.defer(function() { throw error1; });
        \\        failing.defer(function() { return Promise.reject(error2); });
        \\        failing.defer(function() { throw error3; });
        \\        return failing.disposeAsync().then(
        \\            function() { print("missing rejection"); },
        \\            function(error) {
        \\                print([
        \\                    error instanceof SuppressedError,
        \\                    error.error === error1,
        \\                    error.suppressed instanceof SuppressedError,
        \\                    error.suppressed.error === error2,
        \\                    error.suppressed.suppressed === error3
        \\                ].join("|"));
        \\            }
        \\        );
        \\    });
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "first|inner|second\n" ++
            "function|0|AsyncDisposableStack|true|false|true|true|[object AsyncDisposableStack]|true\n" ++
            "false|false\n" ++
            "true|true|true|true|true|true|true|true\n" ++
            "defer|adopt:value|sync:sync|async:async|async-awaited\n" ++
            "defer|adopt:value|sync:sync|async:async|async-awaited\n" ++
            "true|true|true\n" ++
            "true\n" ++
            "true|false|true|true|true|moved\n" ++
            "true|true|true|true|true\n",
        stream.buffered(),
    );
}

test "AsyncDisposableStack ignores promises returned by sync dispose fallback" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var log = [];
        \\var neverResolves = Promise.withResolvers().promise;
        \\var stack = new AsyncDisposableStack();
        \\stack.use({
        \\    [Symbol.dispose]: function() {
        \\        log.push("dispose");
        \\        return neverResolves;
        \\    }
        \\});
        \\stack.disposeAsync().then(function() {
        \\    log.push("done");
        \\    print(log.join("|"));
        \\});
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("dispose|done\n", stream.buffered());
}

test "yield star preserves delegate iterator results and catchable abrupts" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var delegateResults = [{ value: 1 }, { value: 2 }, { done: true, value: 3 }];
        \\var index = 0;
        \\var iterable = {};
        \\iterable[Symbol.iterator] = function() {
        \\    return {
        \\        next: function(value) {
        \\            if (index === 1) assert.sameValue(value, 42);
        \\            return delegateResults[index++];
        \\        }
        \\    };
        \\};
        \\function* values() {
        \\    yield* iterable;
        \\}
        \\var iter = values();
        \\var first = iter.next("ignored");
        \\assert.sameValue(first.value, 1);
        \\assert.sameValue(first.done, undefined);
        \\var second = iter.next(42);
        \\assert.sameValue(second.value, 2);
        \\assert.sameValue(second.done, undefined);
        \\var final = iter.next();
        \\assert.sameValue(final.value, undefined);
        \\assert.sameValue(final.done, true);
        \\
        \\var thrown = new Test262Error();
        \\var caught;
        \\var bad = {};
        \\bad[Symbol.iterator] = function() { throw thrown; };
        \\function* catches() {
        \\    try {
        \\        yield* bad;
        \\    } catch (error) {
        \\        caught = error;
        \\    }
        \\}
        \\var done = catches().next();
        \\assert.sameValue(done.value, undefined);
        \\assert.sameValue(done.done, true);
        \\assert.sameValue(caught, thrown);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "module eval yield star preserves delegate return completion" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.evalModule(
        \\globalThis.__yieldStarLog = [];
        \\try {
        \\    var make = eval("(function*() { return yield* { [Symbol.iterator]: function() { return this; }, next: function(value) { globalThis.__yieldStarLog.push('next:' + value); return { value: 1, done: false }; }, return: function(value) { globalThis.__yieldStarLog.push('return:' + value); return { value: 2, done: true }; } }; })");
        \\    var iter = make();
        \\    assert.sameValue(JSON.stringify(iter.next()), '{"value":1,"done":false}');
        \\    assert.sameValue(JSON.stringify(iter.return(9)), '{"value":2,"done":true}');
        \\    assert.compareArray(globalThis.__yieldStarLog, ["next:undefined", "return:9"]);
        \\} finally {
        \\    delete globalThis.__yieldStarLog;
        \\}
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "String trim preserves non-ASCII Latin-1 interior code units" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue("ab\u0085c".trim(), "ab\u0085c");
        \\assert.sameValue("ab\u00a0c".trim(), "ab\u00a0c");
        \\assert.sameValue("\u00a0ab\u00a0".trim(), "ab");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "String well-formed methods inspect and replace lone surrogates" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var high = "\uD83D";
        \\var low = "\uDCA9";
        \\var pair = high + low;
        \\var repl = "\uFFFD";
        \\assert.sameValue(("a" + high + "c").isWellFormed(), false);
        \\assert.sameValue(("a" + low + "c").isWellFormed(), false);
        \\assert.sameValue(("a" + low + high + "c").isWellFormed(), false);
        \\assert.sameValue(("a" + pair + "c").isWellFormed(), true);
        \\assert.sameValue(pair.slice(0, 1).isWellFormed(), false);
        \\assert.sameValue(pair.slice(1).isWellFormed(), false);
        \\assert.sameValue(("a" + high + "c").toWellFormed(), "a" + repl + "c");
        \\assert.sameValue(("a" + low + high + "c").toWellFormed(), "a" + repl + repl + "c");
        \\assert.sameValue(("a" + pair + "c").toWellFormed(), "a" + pair + "c");
        \\assert.sameValue(pair.slice(0, 1).toWellFormed(), repl);
        \\assert.sameValue(pair.slice(1).toWellFormed(), repl);
        \\assert.throws(TypeError, () => String.prototype.isWellFormed.call(Symbol()));
        \\assert.throws(TypeError, () => String.prototype.toWellFormed.call(Symbol()));
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Math methods use VM ToNumber and QuickJS numeric edge cases" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(Math.max({}), NaN);
        \\assert.sameValue(Math.min({}), NaN);
        \\var maxCalls = 0;
        \\var maxArg = { valueOf: function() { maxCalls += 1; } };
        \\assert.sameValue(Math.max(NaN, maxArg), NaN);
        \\assert.sameValue(maxCalls, 1);
        \\var minCalls = 0;
        \\var minArg = { valueOf: function() { minCalls += 1; } };
        \\assert.sameValue(Math.min(NaN, minArg), NaN);
        \\assert.sameValue(minCalls, 1);
        \\assert.sameValue(Math.hypot(NaN, Infinity), Infinity);
        \\assert.throws(Test262Error, function() {
        \\    Math.hypot(Infinity, { valueOf: function() { throw new Test262Error(); } });
        \\});
        \\assert.sameValue(Math.pow(1, Infinity), NaN);
        \\assert.sameValue(Math.pow(-1, -Infinity), NaN);
        \\assert.sameValue(1 / Math.round(-0), -Infinity);
        \\assert.sameValue(1 / Math.round(-0.25), -Infinity);
        \\assert.sameValue(1 / Math.round(-0.5), -Infinity);
        \\assert.sameValue(Math.exp(1), Math.E);
        \\assert.sameValue(Math.exp(-1), 1 / Math.E);
        \\assert.sameValue(Math.log2(Math.pow(2, -1074)), -1074);
        \\assert.sameValue(Math.log2(Math.pow(2, -1063)), -1063);
        \\assert.sameValue(Math.log2(Math.pow(2, 1022)), 1022);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp string iterator falls back when exec is non-callable" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var original = RegExp.prototype.exec;
        \\var values = [undefined, null, 5, true, Symbol()];
        \\try {
        \\    for (var i = 0; i < values.length; i++) {
        \\        RegExp.prototype.exec = values[i];
        \\        var matches = [];
        \\        var regexp = new RegExp("\\w", "g");
        \\        var iterator = regexp[Symbol.matchAll]("a*b");
        \\        var step = iterator.next();
        \\        while (!step.done) {
        \\            matches.push(step.value[0] + "@" + step.value.index);
        \\            step = iterator.next();
        \\        }
        \\        assert.compareArray(matches, ["a@0", "b@2"]);
        \\    }
        \\} finally {
        \\    RegExp.prototype.exec = original;
        \\}
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp matchAll iterator OOM releases constructed matcher once" {
    try expectRegExpMatchAllIteratorOOMCleanup("/a/g[Symbol.matchAll](\"a\")");
}

fn expectRegExpMatchAllIteratorOOMCleanup(source: []const u8) !void {
    var saw_oom = false;
    var saw_success = false;

    const samples = oom_helpers.defaultSampleSet(220);
    var fail_offset: usize = 0;
    while (fail_offset < samples.limit) : (fail_offset += 1) {
        if (!oom_helpers.shouldRunOffset(samples, fail_offset)) continue;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var js = try engine.harness.Engine.init(failing.allocator());
        defer js.deinit();

        const warmup = try js.eval(source);
        warmup.free(js.runtime);

        failing.fail_index = failing.alloc_index + fail_offset;
        const result = js.eval(source);
        failing.fail_index = std.math.maxInt(usize);

        if (result) |value| {
            saw_success = true;
            value.free(js.runtime);
        } else |err| switch (err) {
            error.OutOfMemory => saw_oom = true,
            else => |unexpected| return unexpected,
        }
        if (oom_helpers.shouldStopAfterCoverage(saw_oom, saw_success)) return;
    }

    try std.testing.expect(saw_oom);
    try std.testing.expect(saw_success);
}

test "String.prototype.matchAll does not over-observe Symbol.match" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var original = RegExp.prototype[Symbol.match];
        \\try {
        \\    var regexp = /a+/g;
        \\    var count = 0;
        \\    Object.defineProperty(RegExp.prototype, Symbol.match, {
        \\        get: function() {
        \\            assert.sameValue(this, regexp);
        \\            count++;
        \\            return original;
        \\        },
        \\        configurable: true
        \\    });
        \\    var iterator = "aabbaa".matchAll(regexp);
        \\    assert.sameValue(count, 2);
        \\    assert.sameValue(iterator.next().value[0], "aa");
        \\} finally {
        \\    Object.defineProperty(RegExp.prototype, Symbol.match, {
        \\        value: original,
        \\        writable: true,
        \\        enumerable: false,
        \\        configurable: true
        \\    });
        \\}
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Error constructors use VM message and cause semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var cause = { message: "inner" };
        \\var error = new Error({ toString: function() { return "outer"; } }, { cause: cause });
        \\assert.sameValue(error.message, "outer");
        \\assert.sameValue(error.cause, cause);
        \\var desc = Object.getOwnPropertyDescriptor(error, "cause");
        \\assert.sameValue(desc.writable, true);
        \\assert.sameValue(desc.enumerable, false);
        \\assert.sameValue(desc.configurable, true);
        \\var sequence = [];
        \\Error({ toString: function() { sequence.push("message"); return "m"; } }, {
        \\    get cause() { sequence.push("cause"); return 1; }
        \\});
        \\assert.compareArray(sequence, ["message", "cause"]);
        \\assert.throws(Test262Error, function() {
        \\    new Error("m", new Proxy({}, {
        \\        has: function(target, key) {
        \\            if (key === "cause") throw new Test262Error();
        \\            return false;
        \\        }
        \\    }));
        \\});
        \\assert.throws(TypeError, function() { Error(Symbol()); });
        \\assert.throws(TypeError, function() { Error({ toString: undefined, valueOf: undefined }); });
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "eval comment-only source is not treated as a regexp literal" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(eval("/* multi line comment */"), undefined);
        \\assert.sameValue((0, eval)("/* multi line comment */"), undefined);
        \\assert.sameValue(eval("// line comment"), undefined);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Date constructor and prototype methods preserve coercion order and invalid-date semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(new Date(6.54321).valueOf(), 6);
        \\assert.sameValue(new Date(-0).getTime(), 0);
        \\assert.sameValue(new Date(2016, 6, 6, 0, 0, 0, -1).getDate(), 5);
        \\var ctorLog = "";
        \\new Date(
        \\    { toString: function() { ctorLog += "y"; return 0; } },
        \\    { toString: function() { ctorLog += "m"; return 0; } },
        \\    { toString: function() { ctorLog += "d"; return 1; } }
        \\);
        \\assert.sameValue(ctorLog, "ymd");
        \\var utcLog = "";
        \\Date.UTC(
        \\    { toString: function() { utcLog += "y"; return 0; } },
        \\    { toString: function() { utcLog += "m"; return 0; } },
        \\    { toString: function() { utcLog += "d"; return 1; } }
        \\);
        \\assert.sameValue(utcLog, "ymd");
        \\assert.sameValue(new Date(NaN).getDate(), NaN);
        \\var invalid = new Date(NaN);
        \\var setterCalls = 0;
        \\assert.sameValue(invalid.setHours({
        \\    valueOf: function() {
        \\        setterCalls++;
        \\        invalid.setTime(0);
        \\        return 1;
        \\    }
        \\}), NaN);
        \\assert.sameValue(setterCalls, 1);
        \\assert.sameValue(invalid.getTime(), 0);
        \\var fullYearTarget = new Date(NaN);
        \\var fullYearResult = fullYearTarget.setFullYear({
        \\    valueOf: function() {
        \\        fullYearTarget.setTime(0);
        \\        return 1;
        \\    }
        \\});
        \\assert.sameValue(fullYearResult, fullYearTarget.getTime());
        \\assert.sameValue(fullYearTarget.getFullYear(), 1);
        \\assert.sameValue(Date.prototype.toJSON.call({
        \\    toISOString: function() { throw new Test262Error(); },
        \\    valueOf: function() { return NaN; }
        \\}), null);
        \\var token = {};
        \\assert.sameValue(Date.prototype.toJSON.call({
        \\    toISOString: function() { return token; }
        \\}), token);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Date UTC and ISO parsing handle defaults, precision, and expanded years" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(Date.UTC(1970), 0);
        \\assert.sameValue(Date.UTC(1970, 0, 1, 80063993375, 29, 1, -288230376151711740), 29312);
        \\assert.sameValue(Date.UTC(1970, 0, 213503982336, 0, 0, 0, -18446744073709552000), 34447360);
        \\assert.sameValue(Date.UTC(Number.MAX_VALUE, Number.MAX_VALUE), NaN);
        \\assert.sameValue(new Date(Number.MAX_VALUE, Number.MAX_VALUE).getTime(), NaN);
        \\var max = new Date(0);
        \\assert.sameValue(max.setUTCFullYear(Number.MAX_VALUE, Number.MAX_VALUE), NaN);
        \\assert.sameValue(max.getTime(), NaN);
        \\assert.sameValue(new Date("1970").toISOString(), "1970-01-01T00:00:00.000Z");
        \\var minDateStr = "-271821-04-20T00:00:00.000Z";
        \\var minDate = new Date(-8640000000000000);
        \\assert.sameValue(minDate.toISOString(), minDateStr);
        \\assert.sameValue(Date.parse(minDateStr), minDate.valueOf());
        \\var maxDateStr = "+275760-09-13T00:00:00.000Z";
        \\var maxDate = new Date(8640000000000000);
        \\assert.sameValue(maxDate.toISOString(), maxDateStr);
        \\assert.sameValue(Date.parse(maxDateStr), maxDate.valueOf());
        \\assert.sameValue(Date.parse("-271821-04-19T23:59:59.999Z"), NaN);
        \\assert.sameValue(Date.parse("+275760-09-13T00:00:00.001Z"), NaN);
        \\var invalidStrings = [
        \\    "-000000-03-31T00:45Z",
        \\    "-000000-03-31T01:45",
        \\    "-000000-03-31T01:45:00+01:00"
        \\];
        \\for (var i = 0; i < invalidStrings.length; i++) {
        \\    assert.sameValue(Date.parse(invalidStrings[i]), NaN);
        \\    assert.sameValue(+new Date(invalidStrings[i]), NaN);
        \\}
        \\assert.sameValue(new Date("0020-01-01T00:00:00Z").toUTCString(), "Wed, 01 Jan 0020 00:00:00 GMT");
        \\assert.sameValue(new Date("-000001-07-01T00:00Z").toUTCString().split(" ")[3], "-0001");
        \\assert.sameValue(new Date("-000001-07-01T00:00Z").toDateString().split(" ")[3], "-0001");
        \\assert.sameValue(new Date("-000001-07-01T00:00Z").toString().split(" ")[3], "-0001");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "async functions use AsyncFunction prototype and are not constructors" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\async function f() {}
        \\var AsyncFunction = Object.getPrototypeOf(f).constructor;
        \\assert.sameValue(AsyncFunction.name, "AsyncFunction");
        \\assert.sameValue(AsyncFunction.length, 1);
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(f, "prototype"), false);
        \\assert.throws(TypeError, function() { new f(); });
        \\var dynamic = new AsyncFunction("return 1;");
        \\assert.sameValue(Object.getPrototypeOf(dynamic), AsyncFunction.prototype);
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(dynamic, "prototype"), false);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "generator constructors can be invoked as functions" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function* g() {}
        \\var GeneratorFunction = Object.getPrototypeOf(g).constructor;
        \\var dynamicGenerator = GeneratorFunction("yield 1;");
        \\assert.sameValue(Object.getPrototypeOf(dynamicGenerator), GeneratorFunction.prototype);
        \\assert.sameValue(dynamicGenerator instanceof GeneratorFunction, true);
        \\var iter = dynamicGenerator();
        \\assert.sameValue(iter.next().value, 1);
        \\assert.sameValue(iter.next().done, true);
        \\async function* ag() {}
        \\var AsyncGeneratorFunction = Object.getPrototypeOf(ag).constructor;
        \\var dynamicAsyncGenerator = AsyncGeneratorFunction("yield 2;");
        \\assert.sameValue(Object.getPrototypeOf(dynamicAsyncGenerator), AsyncGeneratorFunction.prototype);
        \\assert.sameValue(dynamicAsyncGenerator instanceof AsyncGeneratorFunction, true);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "string slice does not get trapped by typed array fast path" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue("abcd".slice(0, 0), "");
        \\assert.sameValue(String.prototype.slice.call("abcd", 1, 3), "bc");
        \\assert.throws(TypeError, function() { TypedArray.prototype.slice.call(1); });
        \\function* localPrefixes(s) {
        \\    for (var i = 0; i <= s.length; ++i) {
        \\        yield s.slice(0, i);
        \\    }
        \\}
        \\var iter = localPrefixes("abcd");
        \\assert.sameValue(iter.next().value, "");
        \\assert.sameValue(iter.next().value, "a");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "typed array by-copy methods keep same typed array kind" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var ta = new Int32Array([3, 1, 2]);
        \\var sorted = ta.toSorted();
        \\assert.sameValue(Object.getPrototypeOf(sorted), Int32Array.prototype);
        \\assert.compareArray([...sorted], [1, 2, 3]);
        \\var reversed = ta.toReversed();
        \\assert.sameValue(Object.getPrototypeOf(reversed), Int32Array.prototype);
        \\assert.compareArray([...reversed], [2, 1, 3]);
        \\var touched = false;
        \\var ignored = new Int32Array([1, 2, 3]);
        \\Object.defineProperty(ignored, "constructor", {
        \\    get: function() {
        \\        touched = true;
        \\        return Uint8Array;
        \\    }
        \\});
        \\ignored.toReversed();
        \\ignored.toSorted();
        \\ignored.with(0, 9);
        \\assert.sameValue(touched, false);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "typed array with coerces index before value and copies after coercion" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var ta = new Int32Array([3, 1, 2]);
        \\var log = [];
        \\var replaced = ta.with(
        \\    { valueOf: function() { log.push("index"); return 1; } },
        \\    { valueOf: function() { log.push("value"); ta[0] = 9; return 4; } }
        \\);
        \\assert.compareArray(log, ["index", "value"]);
        \\assert.sameValue(Object.getPrototypeOf(replaced), Int32Array.prototype);
        \\assert.compareArray([...replaced], [9, 4, 2]);
        \\assert.compareArray([...ta], [9, 1, 2]);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "callable proxies work with Function prototype call apply and bind" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var calls = 0;
        \\var context;
        \\var target = new Proxy(function() {}, {
        \\    apply: function(_target, thisArg, args) {
        \\        calls += 1;
        \\        context = thisArg;
        \\        return args[0] + args[1];
        \\    }
        \\});
        \\var proxy = new Proxy(target, { apply: null });
        \\var thisArg = {};
        \\assert.sameValue(proxy.call(thisArg, 1, 2), 3);
        \\assert.sameValue(context, thisArg);
        \\assert.sameValue(proxy.apply(thisArg, [3, 4]), 7);
        \\assert.sameValue(proxy.bind(thisArg, 5)(6), 11);
        \\assert.sameValue(calls, 3);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Reflect.construct forwards proxy construct with explicit newTarget" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var calls = 0;
        \\var seenNewTarget;
        \\var target = new Proxy(function() {}, {
        \\    construct: function(_target, args, newTarget) {
        \\        calls += 1;
        \\        seenNewTarget = newTarget;
        \\        return { sum: args[0] + args[1] };
        \\    }
        \\});
        \\var proxy = new Proxy(target, { construct: null });
        \\var NewTarget = function() {};
        \\var result = Reflect.construct(proxy, [3, 4], NewTarget);
        \\assert.sameValue(result.sum, 7);
        \\assert.sameValue(calls, 1);
        \\assert.sameValue(seenNewTarget, NewTarget);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "proxy missing traps forward through proxy targets" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var re = /(?:)/i;
        \\var reTarget = new Proxy(re, {});
        \\var reProxy = new Proxy(reTarget, {});
        \\assert.sameValue(Object.create(reProxy).lastIndex, 0);
        \\assert.sameValue(reProxy[Symbol.match], RegExp.prototype[Symbol.match]);
        \\assert.sameValue(Reflect.has(reProxy, "ignoreCase"), true);
        \\assert.sameValue(Symbol.replace in reProxy, true);
        \\
        \\var fnTarget = new Proxy(function(arg) {}, {});
        \\var fnProxy = new Proxy(fnTarget, {});
        \\assert.sameValue(Object.create(fnProxy).length, 1);
        \\assert.sameValue("name" in fnProxy, true);
        \\
        \\var plain = { get foo() {} };
        \\Object.defineProperty(plain, "bar", { configurable: false });
        \\var plainTarget = new Proxy(plain, {});
        \\var plainProxy = new Proxy(plainTarget, {});
        \\assert.sameValue(delete plainProxy.foo, true);
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(plain, "foo"), false);
        \\assert.sameValue(Reflect.deleteProperty(plainProxy, "bar"), false);
        \\
        \\var sym = Symbol();
        \\var string = new String("str");
        \\string[sym] = 1;
        \\var stringTarget = new Proxy(string, {});
        \\var stringProxy = new Proxy(stringTarget, {});
        \\assert.compareArray(Reflect.ownKeys(stringProxy), ["0", "1", "2", "length", sym]);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "proxy revocation and get has invariants" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var revoked = Proxy.revocable({ attr: 1 }, {});
        \\revoked.revoke();
        \\assert.throws(TypeError, function() { delete revoked.proxy.attr; });
        \\assert.throws(TypeError, function() { "attr" in revoked.proxy; });
        \\assert.throws(TypeError, function() { Object.keys(revoked.proxy); });
        \\
        \\var revocation = Proxy.revocable({}, {}).revoke;
        \\assert.sameValue(revocation.name, "");
        \\assert.sameValue(Object.getPrototypeOf(revocation), Function.prototype);
        \\var nameDesc = Object.getOwnPropertyDescriptor(revocation, "name");
        \\assert.sameValue(nameDesc.writable, false);
        \\assert.sameValue(nameDesc.enumerable, false);
        \\assert.sameValue(nameDesc.configurable, true);
        \\
        \\var callableRevoked = Proxy.revocable(function() {}, {});
        \\callableRevoked.revoke();
        \\assert.sameValue(typeof new Proxy(callableRevoked.proxy, {}), "function");
        \\
        \\var target = Object.create(Array.prototype);
        \\var proxy = new Proxy(target, {});
        \\assert.sameValue("foo" in proxy, false);
        \\assert.sameValue("length" in proxy, true);
        \\
        \\var getterTarget = { get attr() { return this; } };
        \\var getterProxy = new Proxy(getterTarget, { get: null });
        \\assert.sameValue(getterProxy.attr, getterProxy);
        \\var parent = Object.create(new Proxy(getterTarget, {}));
        \\assert.sameValue(parent.attr, parent);
        \\
        \\var fixed = {};
        \\Object.defineProperty(fixed, "attr", { configurable: false, writable: false, value: 1 });
        \\var fixedProxy = new Proxy(fixed, { get: function() { return 2; } });
        \\assert.throws(TypeError, function() { fixedProxy.attr; });
        \\
        \\var accessor = {};
        \\Object.defineProperty(accessor, "attr", { configurable: false, get: undefined });
        \\var accessorProxy = new Proxy(accessor, { get: function() { return 2; } });
        \\assert.throws(TypeError, function() { accessorProxy.attr; });
        \\
        \\function Custom() {}
        \\var protoProxy = new Proxy({}, { getPrototypeOf: function() { return Custom.prototype; } });
        \\assert.sameValue(protoProxy instanceof Custom, true);
        \\var fixedProtoTarget = {};
        \\var fixedProtoProxy = new Proxy(fixedProtoTarget, { getPrototypeOf: function() { return Custom.prototype; } });
        \\Object.preventExtensions(fixedProtoTarget);
        \\assert.throws(TypeError, function() { fixedProtoProxy instanceof Custom; });
        \\
        \\var extensibleLog = "";
        \\var nestedTarget = new Proxy({}, {
        \\  isExtensible: function(target) {
        \\    extensibleLog += "i";
        \\    throw new Test262Error();
        \\  },
        \\});
        \\var nestedProtoProxy = new Proxy(nestedTarget, { getPrototypeOf: function() { return null; } });
        \\assert.throws(Test262Error, function() { Object.getPrototypeOf(nestedProtoProxy); });
        \\assert.sameValue(extensibleLog, "i");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "proxy for-in descriptors and set forwarding" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var target = { attr: 1 };
        \\var proxy = new Proxy(target, {});
        \\var seen = false;
        \\for (var key in proxy) {
        \\  if (key === "attr") seen = true;
        \\}
        \\assert.sameValue(seen, true);
        \\var desc = Object.getOwnPropertyDescriptor(proxy, "attr");
        \\assert.sameValue(desc.enumerable, true);
        \\assert.sameValue(desc.writable, true);
        \\
        \\var missingKeyTarget = {};
        \\assert.sameValue(Reflect.set(missingKeyTarget), true);
        \\var missingKeyDesc = Object.getOwnPropertyDescriptor(missingKeyTarget, "undefined");
        \\assert.sameValue(missingKeyDesc.value, undefined);
        \\assert.sameValue(missingKeyDesc.writable, true);
        \\assert.sameValue(missingKeyDesc.enumerable, true);
        \\assert.sameValue(missingKeyDesc.configurable, true);
        \\assert.throws(TypeError, function() { Reflect.set(); });
        \\
        \\var falseProxy = new Proxy({}, { set: function() { return false; } });
        \\assert.sameValue(Reflect.set(falseProxy, "x", 1), false);
        \\
        \\var receiverSeen;
        \\var protoProxy = new Proxy({}, {
        \\  set: function(target, key, value, receiver) {
        \\    receiverSeen = receiver;
        \\    return key === "prop" && value === "value";
        \\  },
        \\});
        \\var receiver = Object.create(protoProxy);
        \\receiver.prop = "value";
        \\assert.sameValue(receiverSeen, receiver);
        \\assert.sameValue(Reflect.set(receiver, "prop", "value"), true);
        \\
        \\var setterLog = "";
        \\var setterTarget = {
        \\  set prop(value) {
        \\    setterLog += "p";
        \\    assert.sameValue(this, setterProxy);
        \\    assert.sameValue(value, "value");
        \\  },
        \\};
        \\var setterProxy = new Proxy(setterTarget, {
        \\  set: function(target, key, value, receiver) {
        \\    setterLog += "s";
        \\    assert.sameValue(target, setterTarget);
        \\    assert.sameValue(receiver, setterProxy);
        \\    return Reflect.set(target, key, value, receiver);
        \\  },
        \\});
        \\assert.sameValue(Reflect.set(setterProxy, "prop", "value"), true);
        \\assert.sameValue(setterLog, "sp");
        \\
        \\var fixed = {};
        \\Object.defineProperty(fixed, "attr", { configurable: false, writable: false, value: 1 });
        \\var fixedProxy = new Proxy(fixed, { set: function() { return true; } });
        \\assert.throws(TypeError, function() { fixedProxy.attr = 2; });
        \\
        \\var array = [1, 2, 3];
        \\var arrayTarget = new Proxy(array, {});
        \\var arrayProxy = new Proxy(arrayTarget, { set: null });
        \\arrayProxy.length = 0;
        \\assert.compareArray(array, []);
        \\Object.preventExtensions(array);
        \\assert.sameValue(Reflect.set(arrayProxy, "foo", 2), false);
        \\
        \\var nestedCalls = 0;
        \\var nestedTarget = new Proxy({}, {
        \\  set: function(target, key) {
        \\    nestedCalls++;
        \\    return key === "foo";
        \\  },
        \\});
        \\var nestedProxy = new Proxy(nestedTarget, { set: undefined });
        \\assert.sameValue(Reflect.set(Object.create(nestedProxy), "foo", 1), true);
        \\assert.sameValue(nestedCalls, 1);
        \\assert.sameValue(Reflect.set(nestedProxy, "bar", 2), false);
        \\assert.sameValue(nestedCalls, 2);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "typed array Reflect.set proxy receiver preserves symbol descriptor value under GC" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const old_threshold = js.runtime.gcThreshold();
    js.runtime.setGCThreshold(0);
    defer js.runtime.setGCThreshold(old_threshold);

    const result = try js.eval(
        \\var stored;
        \\var receiver = new Proxy({}, {
        \\  defineProperty: function(target, key, desc) {
        \\    stored = desc.value;
        \\    return Reflect.defineProperty(target, key, desc);
        \\  },
        \\});
        \\var value = Symbol("typed-array-reflect-set-proxy-value");
        \\var typed = new Uint8Array([1]);
        \\assert.sameValue(Reflect.set(typed, "0", value, receiver), true);
        \\assert.sameValue(stored, value);
        \\assert.sameValue(receiver[0], value);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "proxy get function realm for construct default prototype" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var realm1 = $262.createRealm().global;
        \\var realm2 = $262.createRealm().global;
        \\var realm3 = $262.createRealm().global;
        \\var realm4 = $262.createRealm().global;
        \\
        \\var arrayNewTarget = new realm1.Function();
        \\arrayNewTarget.prototype = false;
        \\var arrayProxy = new realm2.Proxy(arrayNewTarget, {});
        \\var array = Reflect.construct(realm3.Array, [], arrayProxy);
        \\assert.sameValue(Object.getPrototypeOf(array), realm1.Array.prototype);
        \\
        \\var booleanNewTarget = new realm1.Function();
        \\booleanNewTarget.prototype = null;
        \\var booleanProxy = new realm3.Proxy(new realm2.Proxy(booleanNewTarget, {}), {});
        \\var boolean = Reflect.construct(realm4.Boolean, [], booleanProxy);
        \\assert.sameValue(Object.getPrototypeOf(boolean), realm1.Boolean.prototype);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "block lexical shadowing does not overwrite parameter slots" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    const result = try js.evalWithOutput(
        \\function touch() {}
        \\(function(x) {
        \\  try {
        \\    let x = "inner";
        \\    throw 0;
        \\  } catch (e) {
        \\    touch();
        \\    print(x);
        \\  }
        \\})("outer");
    , &output.writer);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("outer\n", output.written());
}

test "block var and lexical declaration names conflict" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    try std.testing.expectError(error.SyntaxError, js.eval("{ var f; let f; }"));
    try std.testing.expectError(error.SyntaxError, js.eval("{ { var f; } const f = 1; }"));
    try std.testing.expectError(error.SyntaxError, js.eval("{ var f; class f {} }"));
    try std.testing.expectError(error.SyntaxError, js.eval("{ var f; function f() {} }"));
}

test "computed public class fields preserve runtime keys" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var x = "b";
        \\class C {
        \\  [x] = 42;
        \\  [10] = "meep";
        \\  ["not initialized"];
        \\}
        \\var c = new C();
        \\assert.sameValue(c.b, 42);
        \\assert.sameValue(c[10], "meep");
        \\assert.sameValue(c["not initialized"], undefined);
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(C.prototype, "b"), false);
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(C, "b"), false);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "derived Date constructors use builtin super construction" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\class D extends Date {}
        \\var d = new D(1859, "10", 24, 11);
        \\assert.sameValue(d instanceof D, true);
        \\assert.sameValue(d instanceof Date, true);
        \\assert.sameValue(d.getFullYear(), 1859);
        \\assert.sameValue(d.getMonth(), 10);
        \\assert.sameValue(d.getDate(), 24);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "String.raw uses raw template segments and substitutions" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(String.raw({ raw: ["a", "b", "c"] }, 1, 2), "a1b2c");
        \\assert.sameValue(String.raw`x${1}y`, "x1y");
        \\assert.sameValue(String.raw({ raw: { length: 0 } }, "ignored"), "");
        \\assert.throws(TypeError, function() { String.raw(null); });
        \\assert.throws(TypeError, function() { String.raw({ raw: null }); });
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "String.prototype.replaceAll validates RegExp global flag first" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var poisoned = 0;
        \\var receiver = { toString: function() { poisoned++; throw "receiver"; } };
        \\var replacement = { toString: function() { poisoned++; throw "replacement"; } };
        \\assert.throws(TypeError, function() { String.prototype.replaceAll.call(receiver, /./, replacement); });
        \\var re = /./g;
        \\Object.defineProperty(re, "flags", { value: null, configurable: true });
        \\assert.throws(TypeError, function() { String.prototype.replaceAll.call(receiver, re, replacement); });
        \\assert.sameValue(poisoned, 0);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "String.prototype.replaceAll applies string substitutions and functional replacers" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var calls = [];
        \\assert.sameValue("abc abc".replaceAll("ab", "[$&:$`:$']"), "[ab::c abc]c [ab:abc :c]c");
        \\assert.sameValue("abc".replaceAll("", "_"), "_a_b_c_");
        \\assert.sameValue("aaaa".replaceAll("aa", "b"), "bb");
        \\assert.sameValue("ab c ab cdab cab c".replaceAll(new String("ab c"), function() {
        \\  calls.push([this, arguments[0], arguments[1], arguments[2]]);
        \\  return "z";
        \\}), "z zdzz");
        \\assert.sameValue(calls.length, 4);
        \\assert.sameValue(calls[0][1], "ab c");
        \\assert.sameValue(calls[0][2], 0);
        \\assert.sameValue(calls[1][2], 5);
        \\var re = /./iyg;
        \\Object.defineProperty(re, Symbol.replace, { value: undefined });
        \\assert.sameValue(String(re), "/./giy");
        \\assert.sameValue("aa /./giy /./iyg /./gyi /./giy aa".replaceAll(re, "z"), "aa z /./iyg /./gyi z aa");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "String.prototype.replace applies string substitutions for string search" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var text = "I once was lost but now am found.";
        \\assert.sameValue(text.replace("found", "...$& $`$'"), "I once was lost but now am ...found I once was lost but now am ..");
        \\assert.sameValue(text.replace("found", "...$$$1$2$3"), "I once was lost but now am ...$$1$2$3.");
        \\var seen;
        \\assert.sameValue(text.replace("found", function(match, index, whole) {
        \\    seen = [match, index, whole, arguments.length];
        \\    return "FOUND";
        \\}), "I once was lost but now am FOUND.");
        \\assert.sameValue(seen[0], "found");
        \\assert.sameValue(seen[1], text.indexOf("found"));
        \\assert.sameValue(seen[2], text);
        \\assert.sameValue(seen[3], 3);
        \\var pair = String.fromCharCode(0xd83d, 0xdca9) + "x";
        \\var unitIndex;
        \\assert.sameValue(pair.replace("x", function(match, index) {
        \\    unitIndex = index;
        \\    return "y";
        \\}), String.fromCharCode(0xd83d, 0xdca9) + "y");
        \\assert.sameValue(unitIndex, 2);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "String.prototype.split does not read Symbol.split from primitives" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\Object.defineProperty(Number.prototype, Symbol.split, { get: function() { throw "number"; } });
        \\Object.defineProperty(Boolean.prototype, Symbol.split, { get: function() { throw "boolean"; } });
        \\Object.defineProperty(String.prototype, Symbol.split, { get: function() { throw "string"; } });
        \\assert.sameValue("a1b1c".split(1).join(","), "a,b,c");
        \\assert.sameValue("atruebtruec".split(true).join(","), "a,b,c");
        \\assert.sameValue("a,b,c".split(",").join("|"), "a|b|c");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "String.prototype pad methods use code units and VM coercion" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var log = "";
        \\var receiver = {
        \\  toString: function() { log += "|receiver.toString"; return {}; },
        \\  valueOf: function() { log += "|receiver.valueOf"; return "abc"; }
        \\};
        \\var maxLength = {
        \\  valueOf: function() { log += "|max.valueOf"; return 6; },
        \\  toString: function() { log += "|max.toString"; return 0; }
        \\};
        \\var fill = {
        \\  toString: function() { log += "|fill.toString"; return "\uD83D\uDCA9"; },
        \\  valueOf: function() { log += "|fill.valueOf"; return ""; }
        \\};
        \\assert.sameValue(String.prototype.padStart.call(receiver, maxLength, fill), "\uD83D\uDCA9\uD83Dabc");
        \\assert.sameValue(log, "|receiver.toString|receiver.valueOf|max.valueOf|fill.toString");
        \\assert.sameValue("abc".padEnd(6, "\uD83D\uDCA9"), "abc\uD83D\uDCA9\uD83D");
        \\assert.throws(TypeError, function() { "abc".padStart(10, Symbol()); });
        \\assert.sameValue("abc".padStart(2, { toString: function() { throw "unreached"; } }), "abc");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "copied String.prototype.slice is not treated as Array.prototype.slice" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\Number.prototype.slice = String.prototype.slice;
        \\assert.sameValue((11.001002).slice(), "11.001002");
        \\var receiver = { toString: function() { return "function(){}"; } };
        \\receiver.slice = String.prototype.slice;
        \\assert.sameValue(receiver.slice(-Infinity, 8).slice(1, Infinity), "unction");
        \\delete Number.prototype.slice;
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "String.prototype.normalize uses QuickJS unicode normalization" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var s = "\u1E9B\u0323";
        \\assert.sameValue(s.normalize("NFC"), "\u1E9B\u0323");
        \\assert.sameValue(s.normalize("NFD"), "\u017F\u0323\u0307");
        \\assert.sameValue(s.normalize("NFKC"), "\u1E69");
        \\assert.sameValue(s.normalize("NFKD"), "s\u0323\u0307");
        \\assert.sameValue("\u00C5\u2ADC\u0958\u2126\u0344".normalize(["NFC"]), "\u00C5\u2ADD\u0338\u0915\u093C\u03A9\u0308\u0301");
        \\assert.throws(RangeError, function() { "x".normalize("BAD"); });
        \\assert.throws(TypeError, function() { "x".normalize(Symbol()); });
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Array length assignment does not consult prototype proxy set trap" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function trap(name) {
        \\    return function() { throw new Error(name); };
        \\}
        \\function proxyProto() {
        \\    return new Proxy(Array.prototype, {
        \\        has: function(target, key) { return key in target; },
        \\        set: trap("set"),
        \\        get: trap("get"),
        \\        getOwnPropertyDescriptor: trap("getOwnPropertyDescriptor")
        \\    });
        \\}
        \\var direct = [1, 2, 3];
        \\Object.setPrototypeOf(direct, proxyProto());
        \\direct.length = 0;
        \\assert.sameValue(direct.length, 0);
        \\
        \\var indexArray = [1, null, 3];
        \\Object.setPrototypeOf(indexArray, proxyProto());
        \\var indexFrom = {
        \\    valueOf: function() {
        \\        indexArray.length = 0;
        \\        return 0;
        \\    }
        \\};
        \\assert.sameValue(Array.prototype.indexOf.call(indexArray, 100, indexFrom), -1);
        \\
        \\var lastArray = [5, undefined, 7];
        \\Object.setPrototypeOf(lastArray, proxyProto());
        \\var lastFrom = {
        \\    valueOf: function() {
        \\        lastArray.length = 0;
        \\        return 2;
        \\    }
        \\};
        \\assert.sameValue(Array.prototype.lastIndexOf.call(lastArray, 100, lastFrom), -1);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "generic Array methods on resizable typed arrays use Array semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var rab = new ArrayBuffer(4, { maxByteLength: 8 });
        \\var fixed = new Uint8Array(rab, 0, 4);
        \\var tracking = new Uint8Array(rab);
        \\fixed[0] = 10;
        \\fixed[1] = 8;
        \\fixed[2] = 6;
        \\fixed[3] = 4;
        \\
        \\Array.prototype.sort.call(fixed);
        \\assert.compareArray(Array.from(tracking), [10, 4, 6, 8]);
        \\
        \\rab.resize(2);
        \\var seen = [];
        \\var mapped = Array.prototype.map.call(fixed, function(value, index) {
        \\    seen.push(index);
        \\    return value;
        \\});
        \\assert.compareArray(seen, []);
        \\assert.compareArray(mapped, []);
        \\
        \\Array.prototype.fill.call(fixed, 1);
        \\assert.compareArray(Array.from(tracking), [10, 4]);
        \\assert.sameValue(Array.prototype.join.call(fixed), "");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "String wrapper indexed properties are UTF-16 code units" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var wrapped = new String("yuck\uD83D\uDCA9");
        \\assert.sameValue(wrapped.length, 6);
        \\assert.sameValue(wrapped[4].length, 1);
        \\assert.sameValue(wrapped[4].charCodeAt(0), 0xD83D);
        \\assert.sameValue(wrapped[5].length, 1);
        \\assert.sameValue(wrapped[5].charCodeAt(0), 0xDCA9);
        \\wrapped[Symbol.isConcatSpreadable] = true;
        \\assert.compareArray([].concat(wrapped), ["y", "u", "c", "k", "\uD83D", "\uDCA9"]);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Function.prototype Symbol.hasInstance follows OrdinaryHasInstance" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var hasInstance = Function.prototype[Symbol.hasInstance];
        \\var own = Object.getOwnPropertyDescriptor(Function.prototype, Symbol.hasInstance);
        \\assert.sameValue(typeof hasInstance, "function");
        \\assert.sameValue(hasInstance.name, "[Symbol.hasInstance]");
        \\assert.sameValue(hasInstance.length, 1);
        \\assert.sameValue(own.writable, false);
        \\assert.sameValue(own.enumerable, false);
        \\assert.sameValue(own.configurable, false);
        \\
        \\function F() {}
        \\var instance = new F();
        \\var child = Object.create(instance);
        \\assert.sameValue(F[Symbol.hasInstance](instance), true);
        \\assert.sameValue(F[Symbol.hasInstance](child), true);
        \\assert.sameValue(F[Symbol.hasInstance]({}), false);
        \\assert.sameValue(hasInstance.call({}, instance), false);
        \\assert.sameValue(F.bind(null)[Symbol.hasInstance](instance), true);
        \\
        \\var poisonedCtor = Object.getOwnPropertyDescriptor({
        \\    get f() {}
        \\}, "f").get;
        \\Object.defineProperty(poisonedCtor, "prototype", {
        \\    get: function() { throw new Test262Error("prototype"); }
        \\});
        \\assert.throws(Test262Error, function() {
        \\    poisonedCtor[Symbol.hasInstance]({});
        \\});
        \\
        \\var proxy = new Proxy({}, {
        \\    getPrototypeOf: function() { throw new Test262Error("prototype chain"); }
        \\});
        \\var proxyChild = Object.create(proxy);
        \\assert.throws(Test262Error, function() {
        \\    F[Symbol.hasInstance](proxy);
        \\});
        \\assert.throws(Test262Error, function() {
        \\    F[Symbol.hasInstance](proxyChild);
        \\});
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Function constructor and apply use observable source and callee realms" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var calls = 0;
        \\var param = {
        \\    toString: function() {
        \\        calls += 1;
        \\        return "a" + calls;
        \\    }
        \\};
        \\var receiver = {};
        \\Function(param, "a2,a3", "this.shifted = a1;").apply(receiver, ["nine", "inch", "nails"]);
        \\assert.sameValue(calls, 1);
        \\assert.sameValue(receiver.shifted, "nine");
        \\
        \\var other = $262.createRealm().global;
        \\var otherApply = other.Function.prototype.apply;
        \\assert.throws(other.TypeError, function() {
        \\    otherApply.call(undefined, {}, []);
        \\});
        \\assert.throws(other.TypeError, function() {
        \\    (new other.Function()).apply(null, false);
        \\});
        \\
        \\var syntax;
        \\try {
        \\    other.Function("'use strict'; var yield = 3;");
        \\} catch (e) {
        \\    syntax = e;
        \\}
        \\assert.sameValue(syntax instanceof other.SyntaxError, true);
        \\assert.sameValue(syntax instanceof SyntaxError, false);
        \\other.Function("for (let yield = 3; ; ) break;");
        \\assert.throws(other.SyntaxError, function() {
        \\    other.Function("'use strict'; for (let yield = 3; ; ) break;");
        \\});
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Reflect methods use spec key ordering receivers and metadata" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var tagDesc = Object.getOwnPropertyDescriptor(Reflect, Symbol.toStringTag);
        \\assert.sameValue(tagDesc.value, "Reflect");
        \\assert.sameValue(tagDesc.writable, false);
        \\assert.sameValue(tagDesc.enumerable, false);
        \\assert.sameValue(tagDesc.configurable, true);
        \\assert.sameValue(Reflect.getPrototypeOf(Object.create(null)), null);
        \\assert.throws(TypeError, function() { Reflect.getPrototypeOf(1); });
        \\assert.throws(TypeError, function() { Reflect.getOwnPropertyDescriptor(Symbol(), "x"); });
        \\
        \\var key = { toString: function() { throw new Test262Error("key"); } };
        \\assert.throws(Test262Error, function() { Reflect.defineProperty({}, key); });
        \\assert.throws(Test262Error, function() { Reflect.deleteProperty({}, key); });
        \\assert.throws(Test262Error, function() { Reflect.get({}, key); });
        \\assert.throws(Test262Error, function() { Reflect.has({}, key); });
        \\assert.throws(Test262Error, function() { Reflect.set({}, key, 1); });
        \\
        \\var receiver = { marker: 42 };
        \\var target = Object.create(Object.defineProperty({}, "value", {
        \\    get: function() { return this.marker; }
        \\}));
        \\assert.sameValue(Reflect.get(target, "value", receiver), 42);
        \\
        \\var proxy = new Proxy({}, {
        \\    getPrototypeOf: function() { throw new Test262Error("proto"); }
        \\});
        \\assert.throws(Test262Error, function() { Reflect.getPrototypeOf(proxy); });
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Error.prototype.toString reads object name and message semantically" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var toString = Error.prototype.toString;
        \\assert.throws(TypeError, function() { toString.call("error"); });
        \\assert.sameValue(toString.call({}), "Error");
        \\assert.sameValue(toString.call({ name: undefined, message: undefined }), "Error");
        \\assert.sameValue(toString.call({ name: "", message: "message" }), "message");
        \\assert.sameValue(toString.call({ name: "Name", message: "" }), "Name");
        \\assert.sameValue(toString.call({ name: "Name", message: "message" }), "Name: message");
        \\assert.throws(Test262Error, function() {
        \\    toString.call({
        \\        get name() { throw new Test262Error("name"); }
        \\    });
        \\});
        \\assert.throws(TypeError, function() {
        \\    toString.call({ name: "Name", message: Symbol("message") });
        \\});
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "BigInt coercion helpers honor ToIndex ToBigInt and radix semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(BigInt.asUintN(NaN, 1n), 0n);
        \\assert.sameValue(BigInt.asUintN(undefined, 1n), 0n);
        \\assert.sameValue(BigInt.asUintN({ valueOf: function() { return 3; } }, { valueOf: function() { return 10n; } }), 2n);
        \\assert.sameValue(BigInt.asIntN("3.9", 10n), 2n);
        \\assert.throws(RangeError, function() { BigInt.asUintN(-1, 1n); });
        \\assert.throws(TypeError, function() { BigInt.asUintN(1n, 1n); });
        \\
        \\assert.sameValue((10n).toString(11), "a");
        \\assert.sameValue((35n).toString(36), "z");
        \\assert.throws(RangeError, function() { (1n).toString(37); });
        \\assert.throws(TypeError, function() { (1n).toString(Symbol("radix")); });
        \\
        \\var BigIntValueOf = BigInt.prototype.valueOf;
        \\var valueOfFunction = null;
        \\Object.defineProperty(BigInt.prototype, "valueOf", {
        \\    get: function() { return valueOfFunction; }
        \\});
        \\Object.defineProperty(BigInt.prototype, "toString", {
        \\    get: function() { return undefined; }
        \\});
        \\assert.throws(TypeError, function() { String(Object(1n)); });
        \\valueOfFunction = function() { return BigIntValueOf.call(this) * 2n; };
        \\assert.sameValue(Object(1n) * 1n, 2n);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "BigInt strict equality compares short and heap limb layouts" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(0x1fffffffffffff01n, 0x1fffffffffffff01n);
        \\var x = 0x1fffffffffffff00n;
        \\x = x + 1n;
        \\assert.sameValue(x, 0x1fffffffffffff01n);
        \\
        \\var y = 0x1fffffffffffff00n;
        \\assert.sameValue(y++, 0x1fffffffffffff00n);
        \\assert.sameValue(y, 0x1fffffffffffff01n);
        \\
        \\var neg = -0x1fffffffffffff01n;
        \\assert.sameValue(neg, -0x1fffffffffffff01n);
        \\assert.sameValue(0n, 0n);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Math.sumPrecise uses iterable numbers and exact final rounding" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var desc = Object.getOwnPropertyDescriptor(Math, "sumPrecise");
        \\assert.sameValue(typeof Math.sumPrecise, "function");
        \\assert.sameValue(Math.sumPrecise.length, 1);
        \\assert.sameValue(Math.sumPrecise.name, "sumPrecise");
        \\assert.sameValue(desc.writable, true);
        \\assert.sameValue(desc.enumerable, false);
        \\assert.sameValue(desc.configurable, true);
        \\assert.sameValue(Math.sumPrecise([]), -0);
        \\assert.sameValue(Math.sumPrecise([-0, -0]), -0);
        \\assert.sameValue(Math.sumPrecise([-0, 0]), 0);
        \\assert.sameValue(Math.sumPrecise([Infinity, -Infinity]), NaN);
        \\assert.sameValue(Math.sumPrecise([1e30, 0.1, -1e30]), 0.1);
        \\assert.sameValue(Math.sumPrecise([
        \\    -1.1442589134409902e+308,
        \\    9.593842098384855e+138,
        \\    4.494232837155791e+307,
        \\    -1.3482698511467367e+308,
        \\    4.494232837155792e+307
        \\]), -1.5936821971565685e+308);
        \\
        \\var returnCalls = 0;
        \\var badIterator = {
        \\    next: function() { return { done: false, value: {} }; },
        \\    return: function() { returnCalls += 1; return {}; }
        \\};
        \\assert.throws(TypeError, function() {
        \\    Math.sumPrecise({ [Symbol.iterator]: function() { return badIterator; } });
        \\});
        \\assert.sameValue(returnCalls, 1);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "FinalizationRegistry constructs and unregisters registered cells" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var cleanup = function() {};
        \\var registry = new FinalizationRegistry(cleanup);
        \\var target1 = {};
        \\var target2 = {};
        \\var token = {};
        \\assert.sameValue(Object.getPrototypeOf(registry), FinalizationRegistry.prototype);
        \\assert.sameValue(FinalizationRegistry.prototype.register.call(registry, target1, undefined, token), undefined);
        \\assert.sameValue(registry.register(target2, "held", token), undefined);
        \\assert.sameValue(registry.unregister({}), false);
        \\assert.sameValue(FinalizationRegistry.prototype.unregister.call(registry, token), true);
        \\assert.sameValue(registry.unregister(token), false);
        \\
        \\var customProto = {};
        \\function NewTarget() {}
        \\NewTarget.prototype = customProto;
        \\var reflected = Reflect.construct(FinalizationRegistry, [cleanup], NewTarget);
        \\assert.sameValue(Object.getPrototypeOf(reflected), customProto);
        \\
        \\var other = $262.createRealm().global;
        \\var otherNewTarget = new other.Function();
        \\otherNewTarget.prototype = undefined;
        \\var cross = Reflect.construct(FinalizationRegistry, [cleanup], otherNewTarget);
        \\assert.sameValue(Object.getPrototypeOf(cross), other.FinalizationRegistry.prototype);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "FinalizationRegistry and WeakRef accept non-registered symbol targets" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var registry = new FinalizationRegistry(function () {});
        \\var target = Symbol("target");
        \\var token = Symbol("token");
        \\assert.sameValue(registry.register(target, undefined, token), undefined);
        \\assert.sameValue(registry.unregister(token), true);
        \\assert.sameValue(new WeakRef(target).deref(), target);
        \\assert.throws(TypeError, function () { registry.register(Symbol.for("registered")); });
        \\assert.throws(TypeError, function () { new WeakRef(Symbol.for("registered")); });
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "FinalizationRegistry cleanup jobs preserve enqueue order" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const setup = try js.eval(
        \\var events = [];
        \\var registry = new FinalizationRegistry(function (value) {
        \\    events.push("cleanup:" + value);
        \\});
        \\
        \\Promise.resolve().then(function () {
        \\    events.push("before");
        \\});
        \\(function () {
        \\    var target = {};
        \\    registry.register(target, "held");
        \\    target = null;
        \\})();
        \\gc();
        \\Promise.resolve().then(function () {
        \\    events.push("after");
        \\});
    );
    defer setup.free(js.runtime);

    const result = try js.eval(
        \\assert.sameValue(events.join(","), "before,cleanup:held,after");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "FinalizationRegistry cleanup jobs handle symbol targets and held symbols" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const setup = try js.eval(
        \\var events = [];
        \\var symbolTargetRef;
        \\var symbolTargetRegistry = new FinalizationRegistry(function (value) {
        \\    events.push("target:" + value);
        \\});
        \\(function () {
        \\    var target = Symbol("target");
        \\    symbolTargetRef = new WeakRef(target);
        \\    symbolTargetRegistry.register(target, "sym-target");
        \\    target = null;
        \\})();
        \\gc();
        \\gc();
        \\
        \\var heldSymbolRegistry = new FinalizationRegistry(function (value) {
        \\    events.push("held:" + typeof value + ":" + String(value));
        \\});
        \\(function () {
        \\    var target = {};
        \\    var held = Symbol("held");
        \\    heldSymbolRegistry.register(target, held);
        \\    target = null;
        \\    held = null;
        \\})();
        \\gc();
        \\gc();
        \\
        \\Promise.resolve().then(function () {
        \\    events.push("after");
        \\});
    );
    defer setup.free(js.runtime);

    const result = try js.eval(
        \\assert.sameValue(symbolTargetRef.deref(), undefined);
        \\assert.sameValue(events.join(","), "target:sym-target,held:symbol:Symbol(held),after");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "FinalizationRegistry keeps collected held object alive for cleanup" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const setup = try js.eval(
        \\var events = [];
        \\var registry = new FinalizationRegistry(function () {
        \\    events.push("cleanup");
        \\});
        \\(function () {
        \\    var target = {};
        \\    var held = {};
        \\    target.self = target;
        \\    held.self = held;
        \\    registry.register(target, held);
        \\    target = null;
        \\    held = null;
        \\})();
        \\gc();
        \\Promise.resolve().then(function () {
        \\    events.push("after");
        \\});
    );
    defer setup.free(js.runtime);

    const result = try js.eval(
        \\assert.sameValue(events.join(","), "cleanup,after");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "FinalizationRegistry holdings and tokens preserve targets" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const setup = try js.eval(
        \\var events = [];
        \\
        \\var holdingsTargetRef;
        \\var holdingsRegistry = new FinalizationRegistry(function () {
        \\    events.push("holdings-cleanup");
        \\});
        \\(function () {
        \\    var target = {};
        \\    var holdings = { target: target };
        \\    holdingsTargetRef = new WeakRef(target);
        \\    holdingsRegistry.register(target, holdings);
        \\    target = null;
        \\    holdings = null;
        \\})();
        \\gc();
        \\gc();
        \\
        \\var tokenTargetRef;
        \\var tokenRegistry = new FinalizationRegistry(function () {
        \\    events.push("token-cleanup");
        \\});
        \\(function () {
        \\    var target = {};
        \\    var token = { target: target };
        \\    tokenTargetRef = new WeakRef(target);
        \\    tokenRegistry.register(target, "held", token);
        \\    target = null;
        \\    token = null;
        \\})();
        \\gc();
        \\gc();
        \\
        \\Promise.resolve().then(function () {
        \\    events.push("after");
        \\});
    );
    defer setup.free(js.runtime);

    const result = try js.eval(
        \\assert.notSameValue(holdingsTargetRef.deref(), undefined);
        \\assert.notSameValue(tokenTargetRef.deref(), undefined);
        \\assert.sameValue(events.join(","), "after");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "WeakRef clears non-registered symbol targets after gc" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var target = Symbol("live");
        \\    var liveRef = new WeakRef(target);
        \\    gc();
        \\    assert.sameValue(liveRef.deref(), target);
        \\})();
        \\
        \\var deadRef;
        \\(function () {
        \\    var target = Symbol("dead");
        \\    deadRef = new WeakRef(target);
        \\    target = null;
        \\})();
        \\gc();
        \\gc();
        \\assert.sameValue(deadRef.deref(), undefined);
        \\
        \\var holder = {};
        \\var propertyKeyRef;
        \\(function () {
        \\    var key = Symbol("property-key");
        \\    holder[key] = 1;
        \\    propertyKeyRef = new WeakRef(key);
        \\    key = null;
        \\})();
        \\gc();
        \\assert.notSameValue(propertyKeyRef.deref(), undefined);
        \\
        \\var weakMap = new WeakMap();
        \\var weakValueRef;
        \\(function () {
        \\    var key = Symbol("weak-key");
        \\    var value = {};
        \\    weakMap.set(key, value);
        \\    weakValueRef = new WeakRef(value);
        \\    key = null;
        \\    value = null;
        \\})();
        \\gc();
        \\gc();
        \\assert.sameValue(weakValueRef.deref(), undefined);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Uint8Array base64 and hex codecs preserve partial writes and option order" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var target = new Uint8Array([255, 255, 255, 255, 255]);
        \\assert.throws(SyntaxError, function() {
        \\    target.setFromBase64("MjYyZm.9v");
        \\});
        \\assert.sameValue(target.length, 5);
        \\assert.sameValue(target[0], 50);
        \\assert.sameValue(target[1], 54);
        \\assert.sameValue(target[2], 50);
        \\assert.sameValue(target[3], 255);
        \\assert.sameValue(target[4], 255);
        \\
        \\target = new Uint8Array([255, 255, 255, 255, 255]);
        \\assert.throws(SyntaxError, function() {
        \\    target.setFromBase64("MjYyZg===");
        \\});
        \\assert.sameValue(target[0], 50);
        \\assert.sameValue(target[1], 54);
        \\assert.sameValue(target[2], 50);
        \\assert.sameValue(target[3], 255);
        \\assert.sameValue(target[4], 255);
        \\
        \\target = new Uint8Array([255, 255, 255, 255, 255]);
        \\assert.throws(SyntaxError, function() {
        \\    target.setFromHex("aaag");
        \\});
        \\assert.sameValue(target[0], 170);
        \\assert.sameValue(target[1], 255);
        \\assert.sameValue(target[2], 255);
        \\assert.sameValue(target[3], 255);
        \\assert.sameValue(target[4], 255);
        \\
        \\var array = new Uint8Array([0]);
        \\var encoded = array.toBase64({
        \\    get alphabet() {
        \\        array[0] = 255;
        \\        return "base64";
        \\    }
        \\});
        \\assert.sameValue(encoded, "/w==");
        \\var decoded = Uint8Array.fromBase64("ZXhhZg", { lastChunkHandling: "stop-before-partial" });
        \\assert.sameValue(decoded.length, 3);
        \\assert.sameValue(decoded[0], 101);
        \\assert.sameValue(decoded[1], 120);
        \\assert.sameValue(decoded[2], 97);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Annex B string HTML methods and substr use VM coercion and UTF-16 units" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var calls = [];
        \\var receiver = {
        \\    toString: function() {
        \\        calls.push("this");
        \\        return "x";
        \\    }
        \\};
        \\var attr = {
        \\    toString: function() {
        \\        calls.push("attr");
        \\        return 'a"b';
        \\    }
        \\};
        \\assert.sameValue(String.prototype.anchor.call(receiver, attr), '<a name="a&quot;b">x</a>');
        \\assert.sameValue(calls.join(","), "this,attr");
        \\
        \\var abrupt = { toString: function() { throw new Test262Error(); } };
        \\assert.throws(Test262Error, function() { String.prototype.bold.call(abrupt); });
        \\assert.throws(Test262Error, function() { "x".link(abrupt); });
        \\
        \\var pair = "\ud834\udf06";
        \\assert.sameValue(pair.substr(0, 1), "\ud834");
        \\assert.sameValue(pair.substr(1), "\udf06");
        \\assert.sameValue("a".substr(-0.5, 1), "a");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp.prototype.compile reinitializes existing regexp objects" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var subject = /abc/gim;
        \\var pattern = /def/;
        \\var observed = 0;
        \\Object.defineProperty(pattern, "flags", {
        \\    get: function() {
        \\        observed += 1;
        \\        return "";
        \\    }
        \\});
        \\subject.lastIndex = 23;
        \\assert.sameValue(subject.compile(pattern), subject);
        \\assert.sameValue(observed, 0);
        \\assert.sameValue(subject.lastIndex, 0);
        \\assert.sameValue(subject.toString(), "/def/");
        \\assert.sameValue(subject.test("DEF"), false);
        \\
        \\subject.compile("a", "i");
        \\assert.sameValue(subject.test("A"), true);
        \\subject.lastIndex = 1;
        \\assert.sameValue(subject.test("A"), true);
        \\
        \\Object.defineProperty(subject, "lastIndex", { value: 45, writable: false });
        \\assert.throws(TypeError, function() {
        \\    subject.compile(/updated/g);
        \\});
        \\assert.sameValue(subject.toString(), "/updated/g");
        \\assert.sameValue(subject.lastIndex, 45);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp.prototype.compile rejects cross-realm instances with callee realm errors" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var other = $262.createRealm().global;
        \\var local = new RegExp("");
        \\var foreign = new other.RegExp("");
        \\assert.throws(TypeError, function() {
        \\    RegExp.prototype.compile.call(foreign);
        \\});
        \\assert.throws(other.TypeError, function() {
        \\    other.RegExp.prototype.compile.call(local);
        \\});
        \\assert.sameValue(foreign.compile(), foreign);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp legacy static accessors track successful matches" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var re = /b(c)?/;
        \\assert.sameValue(re.exec("zbcq")[0], "bc");
        \\assert.sameValue(RegExp.input, "zbcq");
        \\assert.sameValue(RegExp.$_, "zbcq");
        \\assert.sameValue(RegExp.lastMatch, "bc");
        \\assert.sameValue(RegExp["$&"], "bc");
        \\assert.sameValue(RegExp.leftContext, "z");
        \\assert.sameValue(RegExp["$`"], "z");
        \\assert.sameValue(RegExp.rightContext, "q");
        \\assert.sameValue(RegExp["$'"], "q");
        \\assert.sameValue(RegExp.lastParen, "c");
        \\assert.sameValue(RegExp["$+"], "c");
        \\assert.sameValue(RegExp.$1, "c");
        \\assert.sameValue(RegExp.$2, "");
        \\
        \\RegExp.input = 17;
        \\assert.sameValue(RegExp.input, "17");
        \\
        \\var desc = Object.getOwnPropertyDescriptor(RegExp, "lastMatch");
        \\assert.sameValue(typeof desc.get, "function");
        \\assert.sameValue(desc.set, undefined);
        \\assert.throws(TypeError, function() { desc.get.call(/x/); });
        \\assert.throws(TypeError, function() { class R extends RegExp {}; return R.lastMatch; });
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp exec length loop preserves assignment and legacy statics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var re = /[a-z]+|\d+/g;
        \\var s = "a12 bb345";
        \\var c = 0;
        \\var m = "sentinel";
        \\while ((m = re.exec(s)) !== null) c += m[0].length;
        \\assert.sameValue(c, 8);
        \\assert.sameValue(m, null);
        \\assert.sameValue(re.lastIndex, 0);
        \\assert.sameValue(RegExp.input, s);
        \\assert.sameValue(RegExp.lastMatch, "345");
        \\
        \\function orderedAlternation() {
        \\    var re = /\w+|\d+/g;
        \\    var s = "a1 23";
        \\    var c = 0;
        \\    var m = "sentinel";
        \\    while ((m = re.exec(s)) !== null) c += m[0].length;
        \\    assert.sameValue(m, null);
        \\    assert.sameValue(re.lastIndex, 0);
        \\    return c;
        \\}
        \\assert.sameValue(orderedAlternation(), 4);
        \\assert.sameValue(RegExp.lastMatch, "23");
        \\
        \\function stickyAlternation() {
        \\    var re = /[a-z]+|\d+/y;
        \\    var s = "abc123!";
        \\    var c = 0;
        \\    var m = "sentinel";
        \\    while ((m = re.exec(s)) !== null) c += m[0].length;
        \\    assert.sameValue(m, null);
        \\    assert.sameValue(re.lastIndex, 0);
        \\    return c;
        \\}
        \\assert.sameValue(stickyAlternation(), 6);
        \\assert.sameValue(RegExp.input, "abc123!");
        \\assert.sameValue(RegExp.lastMatch, "123");
        \\
        \\function literalScanOnly() {
        \\    var re = /[a-z]+|\d+/g;
        \\    var s = "ab12 cd";
        \\    var c = 0;
        \\    var m = "sentinel";
        \\    while ((m = re.exec(s)) !== null) c += m[0].length;
        \\    return c;
        \\}
        \\assert.sameValue(literalScanOnly(), 6);
        \\assert.sameValue(RegExp.input, "ab12 cd");
        \\assert.sameValue(RegExp.lastMatch, "cd");
        \\
        \\var refSource = "";
        \\for (var refBuild = 0; refBuild < 2; refBuild++) refSource += "ab12 cd34";
        \\var refRe = /[a-z]+|\d+/g;
        \\var refTotal = 0;
        \\for (var refOuter = 0; refOuter < 2; refOuter++) {
        \\    refRe.lastIndex = 0;
        \\    var refMatch;
        \\    while ((refMatch = refRe.exec(refSource)) !== null) refTotal += refMatch[0].length;
        \\}
        \\assert.sameValue(refTotal, 32);
        \\assert.sameValue(refMatch, null);
        \\assert.sameValue(refRe.lastIndex, 0);
        \\assert.sameValue(RegExp.input, refSource);
        \\assert.sameValue(RegExp.lastMatch, "34");
        \\
        \\var lastIndexTotal = 0;
        \\for (var lastIndexI = 0; lastIndexI < 5; lastIndexI++) {
        \\    var lastIndexRe = /[a-z]/g;
        \\    lastIndexTotal += lastIndexRe.lastIndex;
        \\}
        \\assert.sameValue(lastIndexTotal, 0);
        \\assert.sameValue(lastIndexI, 5);
        \\assert.sameValue(lastIndexRe.lastIndex, 0);
        \\assert.sameValue(lastIndexRe.source, "[a-z]");
        \\assert.sameValue(lastIndexRe.flags, "g");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp single class length loop preserves final match state" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var re = /[a-z]/g;
        \\var s = "ab cd";
        \\var c = 0;
        \\var m = "sentinel";
        \\while ((m = re.exec(s)) !== null) c += m[0].length;
        \\assert.sameValue(c, 4);
        \\assert.sameValue(m, null);
        \\assert.sameValue(re.lastIndex, 0);
        \\assert.sameValue(RegExp.input, s);
        \\assert.sameValue(RegExp.lastMatch, "d");
        \\
        \\var before = RegExp.lastMatch;
        \\re.lastIndex = 0;
        \\m = "again";
        \\while ((m = re.exec("12")) !== null) c += m[0].length;
        \\assert.sameValue(m, null);
        \\assert.sameValue(re.lastIndex, 0);
        \\assert.sameValue(RegExp.lastMatch, before);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp capture length loop preserves legacy statics and no-match errors" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function sumCaptures(n) {
        \\    var re = /([A-Za-z]+)-(\d+)-([A-Za-z]+)/;
        \\    var s = "alpha-12345-omega";
        \\    var c = 0;
        \\    for (var i = 0; i < n; i++) {
        \\        var m = re.exec(s);
        \\        c += m[1].length + m[2].length + m[3].length;
        \\    }
        \\    return c;
        \\}
        \\assert.sameValue(sumCaptures(3), 45);
        \\assert.sameValue(RegExp.input, "alpha-12345-omega");
        \\assert.sameValue(RegExp.lastMatch, "alpha-12345-omega");
        \\assert.sameValue(RegExp.$1, "alpha");
        \\assert.sameValue(RegExp.$2, "12345");
        \\assert.sameValue(RegExp.$3, "omega");
        \\
        \\assert.throws(TypeError, function() {
        \\    var re = /([A-Za-z]+)-(\d+)-([A-Za-z]+)/;
        \\    var s = "no match";
        \\    var c = 0;
        \\    for (var i = 0; i < 1; i++) {
        \\        var m = re.exec(s);
        \\        c += m[1].length + m[2].length + m[3].length;
        \\    }
        \\    return c;
        \\});
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp internal slots ignore legacy hidden-like properties" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var r = /abc/g;
        \\r.__regexp_source = "x";
        \\r.__regexp_flags = "";
        \\assert.sameValue(r.source, "abc");
        \\assert.sameValue(r.flags, "g");
        \\assert.sameValue(r.exec("abc")[0], "abc");
        \\r.lastIndex = 0;
        \\assert.sameValue(r.test("x"), false);
        \\
        \\var clone = new RegExp(r);
        \\assert.sameValue(clone.source, "abc");
        \\assert.sameValue(clone.flags, "g");
        \\assert.sameValue(clone.test("abc"), true);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp.prototype.test uses generic RegExpExec before internal slots" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var objectResult = {
        \\    exec: function() {
        \\        return function() {};
        \\    }
        \\};
        \\assert.sameValue(RegExp.prototype.test.call(objectResult, ""), true);
        \\
        \\var nullResult = {
        \\    exec: function() {
        \\        return null;
        \\    }
        \\};
        \\assert.sameValue(RegExp.prototype.test.call(nullResult, ""), false);
        \\
        \\var calls = 0;
        \\var regexp = /x/;
        \\regexp.exec = function(value) {
        \\    calls += 1;
        \\    assert.sameValue(value, "abc");
        \\    return { 0: "x", length: 1 };
        \\};
        \\assert.sameValue(RegExp.prototype.test.call(regexp, "abc"), true);
        \\assert.sameValue(calls, 1);
        \\
        \\var badResult = {
        \\    exec: function() {
        \\        return 1;
        \\    }
        \\};
        \\assert.throws(TypeError, function() {
        \\    RegExp.prototype.test.call(badResult, "");
        \\});
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp unicode character class accepts null escape" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var match = /([\0]+)/u.exec("\u0000");
        \\assert.sameValue(match.length, 2);
        \\assert.sameValue(match[0], "\u0000");
        \\assert.sameValue(match[1], "\u0000");
        \\assert.sameValue(/([\0]+)/u.exec("0"), null);
        \\assert.throws(SyntaxError, function() {
        \\    RegExp("[\\00]", "u");
        \\});
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp constructor reads internal slots before newTarget prototype" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var re = /a/;
        \\var NewTarget = Object.defineProperty(function() {}.bind(null), "prototype", {
        \\    get: function() {
        \\        re.compile("b");
        \\        return RegExp.prototype;
        \\    }
        \\});
        \\var created = Reflect.construct(RegExp, [re], NewTarget);
        \\assert.sameValue(created.source, "a");
        \\assert.sameValue(re.source, "b");
        \\assert.sameValue(created.test("a"), true);
        \\assert.sameValue(created.test("b"), false);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp non-unicode class treats raw astral source as surrogate units" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var pattern = "/[" + "\uD83D\uDC38" + "]/";
        \\var match = eval(pattern).exec("\uD83D\uDC38");
        \\assert.sameValue(match[0], "\uD83D");
        \\assert.sameValue(match[0].length, 1);
        \\
        \\var constructed = new RegExp("[" + "\uD83D\uDC38" + "]", "");
        \\var constructedMatch = constructed.exec("\uD83D\uDC38");
        \\assert.sameValue(constructedMatch[0], "\uD83D");
        \\assert.sameValue(constructedMatch[0].length, 1);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp non-unicode raw astral quantifier applies to trail surrogate" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var frog = "\uD83D\uDC38";
        \\var literal = eval("/" + frog + "?/");
        \\assert.sameValue(literal.exec(frog)[0], frog);
        \\assert.sameValue(literal.exec("\uD83D")[0], "\uD83D");
        \\assert.sameValue(literal.exec(""), null);
        \\
        \\var constructed = new RegExp(frog + "?", "");
        \\assert.sameValue(constructed.exec(frog)[0], frog);
        \\assert.sameValue(constructed.exec("\uD83D")[0], "\uD83D");
        \\assert.sameValue(constructed.exec(""), null);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp unicode braced escape after high surrogate is separate atom" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(/\uD83D\u{3042}/u.exec("\uD83D\u3042")[0], "\uD83D\u3042");
        \\assert.sameValue(/\uD83D\u{3042}*/u.exec("\uD83D\u3042\u3042")[0], "\uD83D\u3042\u3042");
        \\assert.sameValue(/\uD83D\u{DC38}/u.exec("\uD83D\uDC38"), null);
        \\assert.sameValue(/\u{D83D}\uDC38+/u.exec("\uD83D\uDC38\uDC38"), null);
        \\
        \\var constructed = new RegExp("\\uD83D\\u{3042}*", "u");
        \\assert.sameValue(constructed.exec("\uD83D\u3042\u3042")[0], "\uD83D\u3042\u3042");
        \\assert.sameValue(new RegExp("\\u{D83D}\\uDC38+", "u").exec("\uD83D\uDC38\uDC38"), null);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp replace substitution preserves two-byte strings" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function replaced(matched, group1, string, suffix) {
        \\    var replacement = "[$&$`$'$1$2$3$]" + suffix;
        \\    var regexp = {
        \\        get exec() {
        \\            return function() {
        \\                return [matched, group1];
        \\            };
        \\        }
        \\    };
        \\    return RegExp.prototype[Symbol.replace].call(regexp, string, replacement);
        \\}
        \\
        \\assert.sameValue(replaced("A", "B", "\u3046", ""), "[AB$2$3$]");
        \\assert.sameValue(replaced("A", "B", "\u3046", "\u3048"), "[AB$2$3$]\u3048");
        \\assert.sameValue(replaced("\u3042", "\u3044", "C", "\u3048"), "[\u3042\u3044$2$3$]\u3048");
        \\assert.sameValue(replaced("\u3042", "\u3044", "\u3046", "\u3048"), "[\u3042\u3044$2$3$]\u3048");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp exec observes compile side effects during lastIndex coercion" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function call(re, method, input) {
        \\    if (method === Symbol.match) return re[method](input);
        \\    return re[method](input, "pass");
        \\}
        \\
        \\for (var method of [Symbol.match, Symbol.replace]) {
        \\    for (var flag of ["", "y"]) {
        \\        var regExp = new RegExp("a", flag);
        \\        regExp.lastIndex = {
        \\            valueOf() {
        \\                regExp.compile("b");
        \\                return 0;
        \\            }
        \\        };
        \\        var result = call(regExp, method, "b");
        \\        assert.sameValue(method === Symbol.match ? result !== null : result, method === Symbol.match ? true : "pass");
        \\    }
        \\
        \\    var addsGlobal = new RegExp("a", "");
        \\    addsGlobal.lastIndex = {
        \\        valueOf() {
        \\            addsGlobal.compile("a", "g");
        \\            return 0;
        \\        }
        \\    };
        \\    call(addsGlobal, method, "a");
        \\    assert.sameValue(addsGlobal.lastIndex, 1);
        \\
        \\    var removesSticky = new RegExp("a", "y");
        \\    removesSticky.lastIndex = {
        \\        valueOf() {
        \\            removesSticky.compile("a", "");
        \\            removesSticky.lastIndex = 9000;
        \\            return 0;
        \\        }
        \\    };
        \\    call(removesSticky, method, "a");
        \\    assert.sameValue(removesSticky.lastIndex, 9000);
        \\
        \\    var removesStickyNoMatch = new RegExp("a", "y");
        \\    removesStickyNoMatch.lastIndex = {
        \\        valueOf() {
        \\            removesStickyNoMatch.compile("b", "");
        \\            removesStickyNoMatch.lastIndex = 9001;
        \\            return 0;
        \\        }
        \\    };
        \\    call(removesStickyNoMatch, method, "a");
        \\    assert.sameValue(removesStickyNoMatch.lastIndex, 9001);
        \\
        \\    var removesStickyPastEnd = new RegExp("a", "y");
        \\    removesStickyPastEnd.lastIndex = {
        \\        valueOf() {
        \\            removesStickyPastEnd.compile("b", "");
        \\            removesStickyPastEnd.lastIndex = 9002;
        \\            return 10000;
        \\        }
        \\    };
        \\    call(removesStickyPastEnd, method, "a");
        \\    assert.sameValue(removesStickyPastEnd.lastIndex, 9002);
        \\}
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp well-known methods observe inherited flags on RegExp-like receivers" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\class DuckRegExp extends RegExp {
        \\    constructor(pattern, flags) {
        \\        return Object.create(DuckRegExp.prototype, {
        \\            regExp: { value: new RegExp(pattern, flags) },
        \\            flagsReads: { value: 0, writable: true },
        \\            lastIndex: { value: 0, writable: true, configurable: false }
        \\        });
        \\    }
        \\    exec(input) {
        \\        this.regExp.lastIndex = this.lastIndex;
        \\        try {
        \\            return this.regExp.exec(input);
        \\        } finally {
        \\            if (this.global || this.sticky) this.lastIndex = this.regExp.lastIndex;
        \\        }
        \\    }
        \\    get source() { return this.regExp.source; }
        \\    get flags() { this.flagsReads++; return this.regExp.flags; }
        \\    get global() { return this.regExp.global; }
        \\    get sticky() { return this.regExp.sticky; }
        \\    get unicode() { return this.regExp.unicode; }
        \\}
        \\
        \\var matcher = new DuckRegExp(/a/g);
        \\assert.compareArray(RegExp.prototype[Symbol.match].call(matcher, "a"), ["a"]);
        \\assert.sameValue(matcher.lastIndex, 0);
        \\assert.sameValue(matcher.flagsReads > 0, true);
        \\
        \\var replacer = new DuckRegExp(/a/g);
        \\assert.sameValue(RegExp.prototype[Symbol.replace].call(replacer, "a", "b"), "b");
        \\assert.sameValue(replacer.lastIndex, 0);
        \\assert.sameValue(replacer.flagsReads > 0, true);
        \\
        \\var nonWritable = new DuckRegExp(/a/g);
        \\Object.defineProperty(nonWritable, "lastIndex", { value: 0, writable: false });
        \\assert.throws(TypeError, function() {
        \\    RegExp.prototype[Symbol.match].call(nonWritable, "a");
        \\});
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp split generic path preserves UTF-16 code units" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var input = "-\uD83D\uDC38\uDC38\uD83D";
        \\var execCalls = [];
        \\var splitterLike = {
        \\    get constructor() {
        \\        return {
        \\            get [Symbol.species]() {
        \\                return function(pattern, flags) {
        \\                    assert.sameValue(pattern, splitterLike);
        \\                    assert.sameValue(flags, "uy");
        \\                    return {
        \\                        set lastIndex(value) {},
        \\                        get exec() {
        \\                            return function(string) {
        \\                                execCalls.push(string);
        \\                                return null;
        \\                            };
        \\                        }
        \\                    };
        \\                };
        \\            }
        \\        };
        \\    },
        \\    get flags() {
        \\        return "u";
        \\    }
        \\};
        \\
        \\var result = RegExp.prototype[Symbol.split].call(splitterLike, input);
        \\assert.compareArray(result, [input]);
        \\assert.sameValue(execCalls.length, 4);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp.prototype.toString is generic over source and flags properties" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(RegExp.prototype.toString.call({}), "/undefined/undefined");
        \\assert.sameValue(RegExp.prototype.toString.call({ source: "a/b", flags: "gi" }), "/a/b/gi");
        \\assert.sameValue(RegExp.prototype.toString.call({ source: null, flags: undefined }), "/null/undefined");
        \\
        \\var calls = [];
        \\var receiver = {
        \\    get source() {
        \\        calls.push("source");
        \\        return 7;
        \\    },
        \\    get flags() {
        \\        calls.push("flags");
        \\        return "i";
        \\    }
        \\};
        \\assert.sameValue(RegExp.prototype.toString.call(receiver), "/7/i");
        \\assert.sameValue(calls.join(","), "source,flags");
        \\assert.throws(TypeError, function() {
        \\    RegExp.prototype.toString.call(1);
        \\});
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "RegExp function call observes Symbol.match constructor and pattern toString" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var regexp = /(?:)/;
        \\regexp[Symbol.match] = false;
        \\assert.notSameValue(RegExp(regexp), regexp);
        \\
        \\regexp = /(?:)/;
        \\regexp.constructor = null;
        \\assert.notSameValue(RegExp(regexp), regexp);
        \\
        \\var regexpLike = { constructor: RegExp };
        \\regexpLike[Symbol.match] = true;
        \\assert.sameValue(RegExp(regexpLike), regexpLike);
        \\regexpLike[Symbol.match] = "truthy";
        \\assert.sameValue(RegExp(regexpLike), regexpLike);
        \\
        \\var constructorReads = 0;
        \\var throwing = Object.defineProperty({}, "constructor", {
        \\    get: function() {
        \\        constructorReads += 1;
        \\        throw new Test262Error("constructor");
        \\    }
        \\});
        \\throwing[Symbol.match] = true;
        \\assert.throws(Test262Error, function() { RegExp(throwing); });
        \\assert.sameValue(constructorReads, 1);
        \\
        \\var objectPattern = RegExp({ toString: function() { return "[a-c]*"; } }, "gm");
        \\assert.sameValue(objectPattern.source, "[a-c]*");
        \\assert.sameValue(objectPattern.global, true);
        \\assert.sameValue(objectPattern.multiline, true);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Module Namespace resolution under GC pressure keeps namespace bindings alive" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const dir = ".zig-cache/module-ns-gc-test";
    const dep_path = dir ++ "/dep.mjs";
    const main_path = dir ++ "/main.mjs";

    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);

    // 1. Create a dependency module that exports a unique value
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = dep_path, .data =
        \\export const x = { description: "module-ns-retained-value" };
        \\export const y = "other-value";
    });

    // 2. Create a main module that imports the dependency
    const main_source =
        \\import * as ns from "./dep.mjs";
        \\globalThis.__zjs_module_ns_result = ns;
    ;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = main_path, .data = main_source });

    // 3. Force GC threshold to 0 to trigger heavy GC pressure
    const old_threshold = js.runtime.gcThreshold();
    js.runtime.setGCThreshold(0);
    defer js.runtime.setGCThreshold(old_threshold);

    // Evaluate the main module
    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithOutput(main_source, &output, main_path, std.testing.io, std.testing.allocator, 4096);
    defer result.free(js.runtime);

    // 4. Verify that the namespace bindings are perfectly preserved and functioning
    const verify_result = try js.eval(
        \\var ns = globalThis.__zjs_module_ns_result;
        \\assert.sameValue(ns.x.description, "module-ns-retained-value");
        \\assert.sameValue(ns.y, "other-value");
        \\delete globalThis.__zjs_module_ns_result;
    );
    defer verify_result.free(js.runtime);
    try std.testing.expect(verify_result.isUndefined());
}

test "Array.from and Array.prototype.map keep direct symbol results under GC" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const old_threshold = js.runtime.gcThreshold();
    js.runtime.setGCThreshold(0);
    defer js.runtime.setGCThreshold(old_threshold);

    const result = try js.eval(
        \\var source = Symbol("array-from-map-gc");
        \\var fromSet = Array.from(new Set([source]));
        \\assert.sameValue(fromSet.length, 1);
        \\assert.sameValue(fromSet[0], source);
        \\var mapped = [source].map(function(value) { return value; });
        \\assert.sameValue(mapped.length, 1);
        \\assert.sameValue(mapped[0], source);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Rest parameter keeps direct symbol arguments under GC" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const old_threshold = js.runtime.gcThreshold();
    js.runtime.setGCThreshold(0);
    defer js.runtime.setGCThreshold(old_threshold);

    const result = try js.eval(
        \\function capture(first, ...rest) {
        \\  assert.sameValue(rest.length, 2);
        \\  assert.sameValue(rest[0], first);
        \\  assert.sameValue(rest[1], 42);
        \\}
        \\var payload = Symbol("rest-parameter-gc");
        \\capture(payload, payload, 42);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Object literal keeps direct symbol field values under GC" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const old_threshold = js.runtime.gcThreshold();
    js.runtime.setGCThreshold(0);
    defer js.runtime.setGCThreshold(old_threshold);

    const result = try js.eval(
        \\var payload = Symbol("object-literal-field-gc");
        \\var object = { value: payload };
        \\assert.sameValue(object.value, payload);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Class setup keeps superclass private and field values under GC" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const old_threshold = js.runtime.gcThreshold();
    js.runtime.setGCThreshold(0);
    defer js.runtime.setGCThreshold(old_threshold);

    const result = try js.eval(
        \\var payload = Symbol("class-setup-gc");
        \\class Base {
        \\  constructor() { this.base = payload; }
        \\  getBase() { return this.base; }
        \\}
        \\class Derived extends Base {
        \\  #secret = payload;
        \\  field = payload;
        \\  method() { return this.#secret; }
        \\  get value() { return this.field; }
        \\}
        \\var instance = new Derived();
        \\assert.sameValue(Object.getPrototypeOf(Derived), Base);
        \\assert.sameValue(Object.getPrototypeOf(Derived.prototype), Base.prototype);
        \\assert.sameValue(instance.getBase(), payload);
        \\assert.sameValue(instance.method(), payload);
        \\assert.sameValue(instance.value, payload);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "JSON parse stringify and rawJSON preserve nested values under GC" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    const old_threshold = js.runtime.gcThreshold();
    js.runtime.setGCThreshold(0);
    defer js.runtime.setGCThreshold(old_threshold);

    const result = try js.eval(
        \\var sourceText = [];
        \\var parsed = JSON.parse('{"a":[1,"x",true],"b":{"c":2}}', function(key, value, context) {
        \\  if (key === "1") sourceText.push(context.source);
        \\  return value;
        \\});
        \\assert.sameValue(parsed.a[1], "x");
        \\assert.sameValue(parsed.b.c, 2);
        \\assert.sameValue(sourceText[0], '"x"');
        \\var raw = JSON.rawJSON("123");
        \\assert.sameValue(JSON.isRawJSON(raw), true);
        \\assert.sameValue(JSON.stringify({ keep: parsed.a, raw: raw, skip: function() {} }, ["keep", "raw"]), '{"keep":[1,"x",true],"raw":123}');
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

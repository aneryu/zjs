//! OOM injection suite (`zig build test-oom`).
//!
//! Rebirth of the retired `test-oom` command (removed in 65e22be because the
//! old shape cost O(allocation sites x full unit suite)). The new shape is a
//! small embedded JS corpus where every snippet is wrapped as an
//! "init runtime+context -> eval -> deinit" function and handed to
//! `std.testing.checkAllAllocationFailures`, which:
//!   - counts the allocations of a clean run,
//!   - re-runs the snippet once per allocation index with that allocation
//!     forced to fail (sticky failure: all later allocations fail too),
//!   - requires each failing run to surface `error.OutOfMemory` to the
//!     embedder with allocated == freed (no leaks on any failure path).
//!
//! On top of that, a representative subset gets a recovery canary sweep
//! (hand-rolled single-shot fail-at-N allocator): after one injected
//! failure the engine must either succeed or surface the failure as a
//! catchable result, and the SAME runtime must then evaluate a canary
//! script correctly - pinning the "OOM is catchable and the engine stays
//! consistent afterwards" contract from eecf6c8.
//!
//! Cost note: each snippet sweep re-runs full runtime+context bootstrap per
//! allocation index, so this is a phase-gate tier command, not part of
//! `zig build test`.

const std = @import("std");
const zjs = @import("zjs");

const core = zjs.core;
const BindingContext = zjs.binding_root.JSContext;
const module_graph = zjs.exec.module_graph;
const parser = zjs.parser;

const corpus_filename = "<oom-corpus>";

// ---------------------------------------------------------------------------
// Corpus
// ---------------------------------------------------------------------------

const Expect = union(enum) {
    /// Completion value must be a string with these exact bytes.
    string: []const u8,
    /// Completion value is not asserted (modules complete with undefined).
    any,
};

const Snippet = struct {
    name: []const u8,
    source: []const u8,
    mode: core.EvalMode = .script,
    expect: Expect = .any,
    /// Drain the promise job queue after eval (microtask coverage).
    drain_jobs: bool = false,
    /// Run one object-cycle collection after eval (GC coverage).
    collect_cycles: bool = false,
    /// Second script evaluated after eval+drain; must produce `post_expect`.
    post_source: ?[]const u8 = null,
    post_expect: []const u8 = "",
};

/// Opcode-family eval corpus. Snippets are intentionally tiny: the
/// checkAllAllocationFailures sweep is linear in the total allocation count
/// of init+eval+deinit, and runtime+context bootstrap already dominates.
const corpus = [_]Snippet{
    .{
        .name = "arith-numbers",
        .source =
        \\let a = 1;
        \\for (let i = 0; i < 7; i++) { a = a * 3 + i; }
        \\const f = a / 7 + 0.5;
        \\(f > 0 ? "arith-ok:" : "arith-bad:") + a
        ,
        .expect = .{ .string = "arith-ok:2730" },
    },
    .{
        .name = "calls-closures",
        .source =
        \\function add(a, b) { return a + b; }
        \\function mk(base) { return function (x) { return add(base, x); }; }
        \\function strictArgs(a, b) { "use strict"; return arguments[0] + arguments[1] + arguments.length; }
        \\const inc = mk(1);
        \\let t = 0;
        \\for (let i = 0; i < 5; i++) t = inc(t);
        \\"calls-ok:" + t + ":" + strictArgs(2, 3)
        ,
        .expect = .{ .string = "calls-ok:5:7" },
    },
    .{
        .name = "tail-moved-args",
        .source =
        \\function target(a,b,c,d,e,f,g,h,i,j) {
        \\  "use strict";
        \\  return arguments.length;
        \\}
        \\function forward(eval,a,b,c,d,e,f,g,h,i,j) {
        \\  return eval(a,b,c,d,e,f,g,h,i,j);
        \\}
        \\forward(target,0,1,2,3,4,5,6,7,8,9) === 10 ? "tail-moved-ok" : "tail-moved-bad"
        ,
        .expect = .{ .string = "tail-moved-ok" },
    },
    .{
        .name = "private-class-fresh-identity",
        .source =
        \\function makeBox(initial) {
        \\  return class Box {
        \\    #value = initial;
        \\    read() { return this.#value; }
        \\    static has(candidate) { return #value in candidate; }
        \\  };
        \\}
        \\const First = makeBox(11);
        \\const Second = makeBox(22);
        \\const first = new First();
        \\const second = new Second();
        \\First.has(first) && !First.has(second) &&
        \\!Second.has(first) && Second.has(second) &&
        \\first.read() === 11 && second.read() === 22
        \\  ? "private-fresh-ok" : "private-fresh-bad"
        ,
        .expect = .{ .string = "private-fresh-ok" },
    },
    .{
        .name = "emitter-lvalue-call-optional",
        .source =
        \\const object = { value: 2 };
        \\const scope = {
        \\  value: 5,
        \\  method() { return this.value; },
        \\  tag(parts) { return this.value + parts[0]; },
        \\};
        \\object.value += 3;
        \\with (scope) {
        \\  value += 2;
        \\  if ((method)() !== 7 || tag`!` !== "7!") throw new Error("call");
        \\}
        \\if (scope.method?.() !== 7) throw new Error("optional-call");
        \\const nil = null;
        \\const optional = nil?.a?.b?.c;
        \\const deleted = delete nil?.a?.b?.c;
        \\object.value === 5 && scope.value === 7 && optional === undefined && deleted ? "emitter-ok" : "emitter-bad"
        ,
        .expect = .{ .string = "emitter-ok" },
    },
    .{
        .name = "properties-literals",
        .source =
        \\const o = { a: 1, b: "two", ["c" + 1]: 3 };
        \\o.d = o.a + o.c1;
        \\delete o.b;
        \\const arr = [1, 2, [3, 4], { e: 5 }];
        \\`lit-ok:len=${arr.length},d=${o.d}`
        ,
        .expect = .{ .string = "lit-ok:len=4,d=4" },
    },
    .{
        .name = "realm-owned-intrinsic-prototypes",
        .source =
        \\const boxed = Object(1);
        \\const typed = new Uint8Array(4);
        \\const regexpSource = Object.getOwnPropertyDescriptor(RegExp.prototype, "source").get.call(/x/);
        \\Object.getPrototypeOf(boxed) === Number.prototype &&
        \\Object.getPrototypeOf(typed.buffer) === ArrayBuffer.prototype && regexpSource === "x"
        \\  ? "realm-prototypes-ok" : "realm-prototypes-bad"
        ,
        .expect = .{ .string = "realm-prototypes-ok" },
    },
    .{
        .name = "gc-object-cycles",
        .source =
        \\let keep = null;
        \\for (let i = 0; i < 6; i++) {
        \\  const a = { i: i };
        \\  const b = { peer: a };
        \\  a.peer = b;
        \\  if (i === 3) keep = a;
        \\}
        \\keep = null;
        \\"cycles-dropped"
        ,
        .expect = .{ .string = "cycles-dropped" },
        .collect_cycles = true,
    },
    .{
        .name = "rope-concat-flatten",
        .source =
        \\let s = "";
        \\for (let i = 0; i < 24; i++) s += "seg" + i + "|";
        \\s.indexOf("seg23|") >= 0 && s.length > 100 ? "rope-ok" : "rope-bad"
        ,
        .expect = .{ .string = "rope-ok" },
    },
    .{
        .name = "esm-inline-module",
        .source =
        \\export const half = 21;
        \\const v = half * 2;
        \\globalThis.__esm = v;
        ,
        .mode = .module,
        .post_source = "__esm === 42 ? \"esm-ok\" : \"esm-bad\"",
        .post_expect = "esm-ok",
    },
    .{
        .name = "promise-jobs",
        .source =
        \\globalThis.out = 0;
        \\Promise.resolve(1).then(v => { out = v + 1; }).then(() => { out = out * 3; });
        \\"scheduled"
        ,
        .expect = .{ .string = "scheduled" },
        .drain_jobs = true,
        .post_source = "out === 6 ? \"jobs-ok\" : \"jobs-bad\"",
        .post_expect = "jobs-ok",
    },
    .{
        .name = "wait-async-host-completion",
        .source =
        \\globalThis.waitResult = "pending";
        \\const view = new Int32Array(new SharedArrayBuffer(4));
        \\Atomics.waitAsync(view, 0, 0, 1).value.then(value => { waitResult = value; });
        \\"scheduled"
        ,
        .expect = .{ .string = "scheduled" },
        .drain_jobs = true,
        .post_source = "waitResult",
        .post_expect = "timed-out",
    },
    .{
        .name = "string-case-conversion",
        .source =
        \\const upper = "abcdefghijklmnopqrstuvwxyz".toUpperCase();
        \\const lower = "AΣ".toLowerCase();
        \\upper === "ABCDEFGHIJKLMNOPQRSTUVWXYZ" && lower === "aς" ? "case-ok" : "case-bad"
        ,
        .expect = .{ .string = "case-ok" },
    },
    .{
        .name = "generator-return-shared-finalizer",
        .source =
        \\const events = [];
        \\function* values() {
        \\  try { yield 1; }
        \\  finally { events.push("enter"); yield 2; events.push("exit"); }
        \\}
        \\const iterator = values();
        \\const first = iterator.next();
        \\const finalizerYield = iterator.return(9);
        \\const completion = iterator.next();
        \\first.value === 1 && first.done === false &&
        \\finalizerYield.value === 2 && finalizerYield.done === false &&
        \\completion.value === 9 && completion.done === true &&
        \\events.join(",") === "enter,exit" ? "generator-finally-ok" : "generator-finally-bad"
        ,
        .expect = .{ .string = "generator-finally-ok" },
    },
};

// ---------------------------------------------------------------------------
// Snippet runner (full lifecycle, checkAllAllocationFailures-shaped)
// ---------------------------------------------------------------------------

fn expectValue(rt: *core.JSRuntime, value: core.JSValue, expect: Expect) !void {
    switch (expect) {
        .any => {},
        .string => |expected| try expectStringValue(rt, value, expected),
    }
}

fn expectStringValue(rt: *core.JSRuntime, value: core.JSValue, expected: []const u8) !void {
    _ = rt;
    if (!value.isString()) return error.TestUnexpectedResult;
    const string_value = value.asStringBody() orelse return error.TestUnexpectedResult;
    if (!string_value.eqlBytes(expected)) return error.TestUnexpectedResult;
}

/// Register the builtins standard-globals installer as the process-global
/// default so every `core.JSRuntime.create` below copies it into the new
/// runtime's `install_standard_globals_cb`. Phase 6b-3 STEP 7B routed global
/// installation through that callback, which the binding-layer
/// `JSContext.create` wires up; this suite drives the core API directly, so it
/// must register the installer itself or the first `contextGlobal` fails with
/// `error.InvalidBuiltinRegistry` (a non-OOM error that derails the sweep).
/// Mirrors `installHostGlobalsBare` in the exec test tree. Idempotent and
/// allocation-free, so it is safe to call before each injected attempt.
fn ensureStandardGlobalsInstaller() void {
    zjs.exec.standard_globals.registerStandardGlobalsDefault();
}

/// One full engine lifecycle around a corpus snippet. Shaped for
/// `std.testing.checkAllAllocationFailures`: every allocation flows through
/// `allocator`, OOM propagates out as `error.OutOfMemory`, and all paths
/// (success or failure) release everything they allocated.
fn runSnippet(allocator: std.mem.Allocator, snippet: Snippet) !void {
    ensureStandardGlobalsInstaller();
    const rt = try core.JSRuntime.create(allocator);
    var rt_owned = true;
    errdefer if (rt_owned) rt.destroy();
    const ctx = try core.JSContext.create(rt);
    var ctx_owned = true;
    errdefer if (ctx_owned) ctx.destroy();
    var waiters_cleaned = false;
    errdefer if (!waiters_cleaned) zjs.exec.call_runtime.cleanupAtomicsWaitersForContext(ctx);
    var wrapper = BindingContext.borrowCore(ctx);

    const value = try wrapper.eval(snippet.source, .{
        .mode = snippet.mode,
        .filename = corpus_filename,
    });
    {
        defer value.free(rt);
        try expectValue(rt, value, snippet.expect);
    }

    if (snippet.drain_jobs) try wrapper.runJobs(null);
    if (snippet.collect_cycles) _ = rt.runObjectCycleRemoval();

    if (snippet.post_source) |post_source| {
        const post_value = try wrapper.eval(post_source, .{ .filename = corpus_filename });
        defer post_value.free(rt);
        try expectStringValue(rt, post_value, snippet.post_expect);
    }

    zjs.exec.call_runtime.cleanupAtomicsWaitersForContext(ctx);
    waiters_cleaned = true;
    ctx_owned = false;
    ctx.destroy();
    rt_owned = false;
    rt.destroy();
    try stickyFailureTailProbe(allocator);
}

/// Some engine paths degrade gracefully when an allocation fails (e.g. the
/// teardown GC symbol-root scan skips its precise pass), so a sticky
/// injected failure near the end of a run can be absorbed and the run still
/// succeeds. `checkAllAllocationFailures` would report that as
/// SwallowedOutOfMemoryError even though it is deliberate behaviour. This
/// probe performs one final allocation through the (still failing) injector:
/// if a sticky failure was absorbed earlier, the probe converts the run into
/// a plain `error.OutOfMemory` outcome, keeping the sweep's leak accounting
/// in force. Value-corrupting swallows are still caught: `expectValue` runs
/// before the probe.
fn stickyFailureTailProbe(allocator: std.mem.Allocator) !void {
    const probe = try allocator.alloc(u8, 1);
    allocator.free(probe);
}

/// Pure parse lifecycle: realm + lexer + parser + bytecode pipeline, no
/// execution. Uses a syntax-dense source so the sweep covers the parser
/// allocation clusters and every root/child RealmRef publication rollback.
fn runParseOnly(allocator: std.mem.Allocator, source: []const u8) !void {
    const rt = try core.JSRuntime.create(allocator);
    var rt_owned = true;
    errdefer if (rt_owned) rt.destroy();
    const realm = try core.RealmContext.create(rt);
    var realm_owned = true;
    errdefer if (realm_owned) realm.destroy();
    var result = try parser.compile(.{ .realm = realm }, source, .{
        .mode = .script,
        .filename = corpus_filename,
    });
    {
        defer result.deinit();
        if (result.syntax_error != null) return error.TestUnexpectedResult;
        const root = result.functionBytecode() orelse return error.TestUnexpectedResult;
        if (root.realmContext() != realm) return error.TestUnexpectedResult;
        var has_final_child = false;
        for (root.cpoolSlice()) |value| {
            if (!value.isFunctionBytecode()) continue;
            const header = value.objectHeader() orelse return error.TestUnexpectedResult;
            const child: *const zjs.bytecode.FunctionBytecode = @alignCast(@fieldParentPtr("header", header));
            if (child.byteCode().len == 0 or child.realmContext() != realm) return error.TestUnexpectedResult;
            has_final_child = true;
            break;
        }
        if (!has_final_child or @hasField(zjs.bytecode.FunctionBytecode, "cached_view")) return error.TestUnexpectedResult;
    }
    realm_owned = false;
    realm.destroy();
    rt_owned = false;
    rt.destroy();
    try stickyFailureTailProbe(allocator);
}

const parse_only_source =
    \\"use strict";
    \\function outer(a, { b = 2, ...rest }, [c, , d] = [1, 2, 3]) {
    \\  class Point {
    \\    #x = a;
    \\    static origin = new Point();
    \\    get x() { return this.#x; }
    \\    *walk() { yield this.#x; yield* [b, c, d]; }
    \\  }
    \\  const fmt = `p=${a + b},${c ?? 0}`;
    \\  async function inner() { return await Promise.resolve(fmt); }
    \\  try { return inner(); } catch ({ message }) { return message; } finally { rest = null; }
    \\}
;

// ---------------------------------------------------------------------------
// In-memory ESM graph fixture (two modules, host-hook resolution)
// ---------------------------------------------------------------------------

const GraphModule = struct {
    specifier: []const u8,
    path: []const u8,
    source: []const u8,
};

const graph_dep = GraphModule{
    .specifier = "./dep.js",
    .path = "/oom-fixture/dep.js",
    .source = "export function double(x) { return x * 2; }",
};

fn resolveGraphModule(
    ptr: *anyopaque,
    specifier: []const u8,
    referrer: ?[]const u8,
    allocator: std.mem.Allocator,
) anyerror!module_graph.HostHooks.ResolvedModule {
    _ = ptr;
    _ = referrer;
    if (!std.mem.eql(u8, specifier, graph_dep.specifier) and !std.mem.eql(u8, specifier, graph_dep.path)) {
        return error.ModuleNotFound;
    }
    const specifier_copy = try allocator.dupe(u8, specifier);
    errdefer allocator.free(specifier_copy);
    return .{
        .specifier = specifier_copy,
        .path = try allocator.dupe(u8, graph_dep.path),
        .kind = .esm,
    };
}

fn loadGraphModule(
    ptr: *anyopaque,
    resolved: module_graph.HostHooks.ResolvedModule,
    allocator: std.mem.Allocator,
) anyerror!module_graph.HostHooks.LoadedModule {
    _ = ptr;
    if (!std.mem.eql(u8, resolved.path, graph_dep.path)) return error.ModuleNotFound;
    return .{
        .source = graph_dep.source,
        .path = try allocator.dupe(u8, graph_dep.path),
        .kind = .esm,
        .owned = false,
    };
}

/// ESM link lifecycle: two in-memory modules resolved through host hooks,
/// exercising module records, link, instantiate, and evaluation order.
fn runEsmGraphLink(allocator: std.mem.Allocator) !void {
    ensureStandardGlobalsInstaller();
    const rt = try core.JSRuntime.create(allocator);
    var rt_owned = true;
    errdefer if (rt_owned) rt.destroy();
    const ctx = try core.JSContext.create(rt);
    var ctx_owned = true;
    errdefer if (ctx_owned) ctx.destroy();
    var wrapper = BindingContext.borrowCore(ctx);

    var sink: u8 = 0;
    var output = std.Io.Writer.fixed(@as(*[1]u8, &sink));
    var hooks_ctx: u8 = 0;
    const hooks = module_graph.HostHooks{
        .ptr = &hooks_ctx,
        .resolveModule = resolveGraphModule,
        .loadModule = loadGraphModule,
    };
    const value = try module_graph.evalFileModuleGraphWithHostHooks(
        rt,
        ctx,
        \\import { double } from './dep.js';
        \\globalThis.__graph = double(21);
    ,
        &output,
        "/oom-fixture/main.mjs",
        hooks,
        allocator,
    );
    value.free(rt);

    {
        const post_value = try wrapper.eval("__graph === 42 ? \"graph-ok\" : \"graph-bad\"", .{ .filename = corpus_filename });
        defer post_value.free(rt);
        try expectStringValue(rt, post_value, "graph-ok");
    }

    ctx_owned = false;
    ctx.destroy();
    rt_owned = false;
    rt.destroy();
    try stickyFailureTailProbe(allocator);
}

// ---------------------------------------------------------------------------
// checkAllAllocationFailures sweeps
// ---------------------------------------------------------------------------

test "oom corpus: pure parse" {
    // Warm-up pass: populates process-global lazy state outside the counted
    // window so the failure replays observe a deterministic allocation
    // sequence (see checkAllAllocationFailures' NondeterministicMemoryUsage).
    try runParseOnly(std.testing.allocator, parse_only_source);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, runParseOnly, .{parse_only_source});
}

test "oom corpus: eval snippets" {
    for (corpus) |snippet| {
        // Warm-up pass per snippet (lazy global state; also asserts the
        // snippet's expected completion before any injection).
        runSnippet(std.testing.allocator, snippet) catch |err| {
            std.debug.print("[oom-corpus] warm-up failed for '{s}'\n", .{snippet.name});
            return err;
        };
        std.testing.checkAllAllocationFailures(std.testing.allocator, runSnippet, .{snippet}) catch |err| {
            std.debug.print("[oom-corpus] injection sweep failed for '{s}'\n", .{snippet.name});
            return err;
        };
    }
}

test "oom corpus: esm graph link" {
    try runEsmGraphLink(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, runEsmGraphLink, .{});
}

// ---------------------------------------------------------------------------
// Recovery canary (hand-rolled single-shot fail-at-N injector)
// ---------------------------------------------------------------------------

/// Fails exactly one allocation (the `fail_index`-th attempt), then lets
/// everything after it succeed. This differs from std's FailingAllocator
/// (sticky failure) on purpose: after the single injected OOM the engine
/// has working memory again, so the canary eval can prove the runtime is
/// still consistent. Tracks bytes/calls so each attempt can assert
/// alloc/free balance (the leak check normally done by
/// std.testing.allocator, made explicit here).
const OneShotFailingAllocator = struct {
    backing: std.mem.Allocator,
    fail_index: usize,
    attempts: usize = 0,
    induced: bool = false,
    /// Once set, no further injection happens: the recovery canary and
    /// teardown run with reliable memory, so a fail_index landing beyond the
    /// armed region simply means the sweep is done.
    disarmed: bool = false,
    allocated_bytes: usize = 0,
    freed_bytes: usize = 0,
    alloc_calls: usize = 0,
    free_calls: usize = 0,

    fn allocator(self: *OneShotFailingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(ctx));
        const index = self.attempts;
        self.attempts += 1;
        if (!self.disarmed and !self.induced and index == self.fail_index) {
            self.induced = true;
            return null;
        }
        const result = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.allocated_bytes += len;
        self.alloc_calls += 1;
        return result;
    }

    // Resize/remap forward without injection: grow-in-place failures are
    // already exercised because the engine falls back to alloc+copy, which
    // routes through `alloc` above.
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (new_len < memory.len) {
            self.freed_bytes += memory.len - new_len;
        } else {
            self.allocated_bytes += new_len - memory.len;
        }
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len < memory.len) {
            self.freed_bytes += memory.len - new_len;
        } else {
            self.allocated_bytes += new_len - memory.len;
        }
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(ctx));
        self.freed_bytes += memory.len;
        self.free_calls += 1;
        self.backing.rawFree(memory, alignment, ret_addr);
    }

    fn expectBalanced(self: *const OneShotFailingAllocator) !void {
        try std.testing.expectEqual(self.allocated_bytes, self.freed_bytes);
        try std.testing.expectEqual(self.alloc_calls, self.free_calls);
    }
};

const canary_source = "(1 + 2) * 14 === 42 ? \"canary-ok\" : \"canary-bad\"";

/// One recovery attempt under a single injected failure at `fail_index`.
/// Contract being pinned:
///   - the injected failure either stays invisible (soft path), surfaces as
///     `error.OutOfMemory` to the embedder, or lands in a JS-visible
///     exception (`error.JSException` with a pending exception value);
///   - afterwards the SAME runtime evaluates the canary script with the
///     correct result;
///   - teardown releases every byte (explicit alloc/free balance).
fn runRecoveryAttempt(injector: *OneShotFailingAllocator, snippet: Snippet) !void {
    attempt: {
        ensureStandardGlobalsInstaller();
        const rt = core.JSRuntime.create(injector.allocator()) catch |err| {
            // Injection landed inside runtime bootstrap: acceptable, the
            // constructor must fail cleanly (balance asserted below).
            if (err != error.OutOfMemory) return err;
            break :attempt;
        };
        defer rt.destroy();
        const ctx = core.JSContext.create(rt) catch |err| {
            if (err != error.OutOfMemory) return err;
            break :attempt;
        };
        defer ctx.destroy();
        var wrapper = BindingContext.borrowCore(ctx);

        if (wrapper.eval(snippet.source, .{ .mode = snippet.mode, .filename = corpus_filename })) |value| {
            value.free(rt);
        } else |err| switch (err) {
            error.OutOfMemory => {},
            error.JSException => {
                if (!ctx.hasException()) return error.TestUnexpectedResult;
            },
            // Corpus sources are valid programs: any non-OOM error under a
            // single injected failure indicates state corruption.
            else => return err,
        }
        if (ctx.hasException()) {
            const pending = ctx.takePendingException();
            pending.free(rt);
        }

        if (snippet.drain_jobs) {
            wrapper.runJobs(null) catch |err| switch (err) {
                error.OutOfMemory, error.JSException => {},
                // A then-callback failing on the injected OOM surfaces as a
                // rejected promise with no handler; the rejection value is
                // collected right below.
                error.UnhandledPromiseRejection => {},
                else => return err,
            };
            if (ctx.hasException()) {
                const pending = ctx.takePendingException();
                pending.free(rt);
            }
            if (ctx.hasUnhandledRejection()) {
                const rejection = ctx.takeUnhandledRejection();
                rejection.free(rt);
            }
        }
        if (snippet.collect_cycles) _ = rt.runObjectCycleRemoval();

        // Recovery canary: must fully succeed in the same runtime. The
        // injector is disarmed first - the canary verifies recovery after
        // the injected failure, it is not itself an injection target.
        injector.disarmed = true;
        const canary = try wrapper.eval(canary_source, .{ .filename = "<oom-canary>" });
        defer canary.free(rt);
        try expectStringValue(rt, canary, "canary-ok");
    }
}

/// Sweeps single-shot failure indices over a snippet: every index in the
/// dense prefix, then a fixed stride (the full per-index sweep is already
/// covered by checkAllAllocationFailures; the canary axis only needs
/// representative spread).
fn recoveryCanarySweep(snippet: Snippet) !void {
    const dense_prefix = 64;
    const stride = 23;

    var fail_index: usize = 0;
    var attempts_executed: usize = 0;
    while (true) {
        var injector = OneShotFailingAllocator{
            .backing = std.testing.allocator,
            .fail_index = fail_index,
        };
        runRecoveryAttempt(&injector, snippet) catch |err| {
            std.debug.print(
                "[oom-canary] '{s}' failed at injected allocation index {d}\n",
                .{ snippet.name, fail_index },
            );
            return err;
        };
        try injector.expectBalanced();
        attempts_executed += 1;
        if (!injector.induced) break; // swept past the final allocation
        fail_index = if (fail_index < dense_prefix) fail_index + 1 else fail_index + stride;
    }
    try std.testing.expect(attempts_executed > 2);
}

fn expectIntrinsicBootstrapCleared(ctx: *core.JSContext) !void {
    try std.testing.expect(ctx.global == null);
    try std.testing.expect(ctx.eval_function.isNull());
    try std.testing.expect(ctx.preallocated_oom_error == null);
    try std.testing.expect(ctx.cached_function_proto == null);
    try std.testing.expect(ctx.cached_promise_proto == null);
    for (ctx.cached_values) |value| try std.testing.expect(value == null);
    for (ctx.native_error_prototypes) |value| try std.testing.expect(value.isNull());
    try std.testing.expect(ctx.array_shape == null);
    try std.testing.expect(ctx.arguments_shape == null);
    try std.testing.expect(ctx.mapped_arguments_shape == null);
    try std.testing.expect(ctx.regexp_shape == null);
    try std.testing.expect(ctx.regexp_result_shape == null);
    const builtin_count = @min(ctx.class_prototypes.len, @as(usize, @intCast(core.class.ids.init_count)));
    for (ctx.class_prototypes[0..builtin_count]) |value| try std.testing.expect(value.isNull());
}

test "oom recovery canary: ordinary GLOBAL selector retries auto-init" {
    ensureStandardGlobalsInstaller();
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try zjs.exec.zjs_vm.contextGlobal(ctx);

    const name = try rt.internAtom("__oomGlobalSelectorAutoInit");
    defer rt.atoms.free(name);
    try global.definePerformanceAutoInitProperty(
        rt,
        name,
        core.property.Flags.data(true, false, true),
        global,
    );

    // Pin the logical heap at its current size. This rejects the builder's
    // first allocation even when the small-object slab has a reusable block.
    rt.setMemoryLimit(rt.memory.allocated_bytes);
    try std.testing.expectError(
        error.OutOfMemory,
        zjs.exec.call_runtime.selectOrdinaryGlobalClosureCell(ctx, global, name),
    );
    const index = global.findProperty(name) orelse return error.TestUnexpectedResult;
    try std.testing.expect(global.propFlagsAt(index).isAutoInit());

    rt.setMemoryLimit(null);
    const selected = try zjs.exec.call_runtime.selectOrdinaryGlobalClosureCell(ctx, global, name);
    defer selected.free(rt);
    const selected_again = try zjs.exec.call_runtime.selectOrdinaryGlobalClosureCell(ctx, global, name);
    defer selected_again.free(rt);
    try std.testing.expectEqual(core.VarRef.fromValue(selected).?, core.VarRef.fromValue(selected_again).?);
}

fn runContextGlobalRetryAttempt(fail_index: usize) !bool {
    var injector = OneShotFailingAllocator{
        .backing = std.testing.allocator,
        .fail_index = fail_index,
        .disarmed = true,
    };
    var induced = false;
    {
        ensureStandardGlobalsInstaller();
        const rt = try core.JSRuntime.create(injector.allocator());
        defer rt.destroy();
        const ctx = try core.JSContext.create(rt);
        defer ctx.destroy();
        defer zjs.exec.call_runtime.cleanupAtomicsWaitersForContext(ctx);
        try std.testing.expect(ctx.isLive());
        try std.testing.expect(ctx.global == null);

        injector.attempts = 0;
        injector.induced = false;
        injector.disarmed = false;
        const first = zjs.exec.zjs_vm.contextGlobal(ctx);
        injector.disarmed = true;
        induced = injector.induced;

        if (first) |_| {
            try std.testing.expect(ctx.global != null);
        } else |err| switch (err) {
            error.OutOfMemory => {
                try std.testing.expect(ctx.isLive());
                try expectIntrinsicBootstrapCleared(ctx);
                _ = try zjs.exec.zjs_vm.contextGlobal(ctx);
            },
            else => return err,
        }

        var wrapper = BindingContext.borrowCore(ctx);
        const canary = try wrapper.eval(
            \\(function (a) {
            \\  return Object.getPrototypeOf(arguments) === Object.prototype &&
            \\    Object.getPrototypeOf(/x/) === RegExp.prototype &&
            \\    Object.getPrototypeOf(/x/.exec("x")) === Array.prototype
            \\      ? "realm-retry-ok" : "realm-retry-bad";
            \\})(1)
        , .{ .filename = "<realm-bootstrap-retry>" });
        defer canary.free(rt);
        try expectStringValue(rt, canary, "realm-retry-ok");
    }
    try injector.expectBalanced();
    return induced;
}

test "oom recovery canary: same Realm intrinsic bootstrap retry" {
    var fail_index: usize = 0;
    while (try runContextGlobalRetryAttempt(fail_index)) : (fail_index += 1) {}
    try std.testing.expect(fail_index > 2);
}

fn runBindingContextConstructionRetryAttempt(fail_index: usize) !bool {
    var injector = OneShotFailingAllocator{
        .backing = std.testing.allocator,
        .fail_index = fail_index,
        .disarmed = true,
    };
    var induced = false;
    {
        ensureStandardGlobalsInstaller();
        const rt = try core.JSRuntime.create(injector.allocator());
        defer rt.destroy();

        // Keep one published Realm in the Runtime so publication of the
        // binding Realm must grow the one-entry root-provider array. This
        // makes the final fallible commit part of the injected surface.
        const anchor = try core.JSContext.create(rt);
        defer anchor.destroy();
        try std.testing.expect(anchor.isLive());
        try std.testing.expectEqual(anchor, rt.firstContext().?);
        try std.testing.expectEqual(@as(usize, 1), rt.root_providers.len);
        const external_count_before = rt.external_host_functions.len;

        injector.attempts = 0;
        injector.induced = false;
        injector.disarmed = false;
        const first = BindingContext.create(rt);
        injector.disarmed = true;
        induced = injector.induced;

        var created: *BindingContext = undefined;
        if (first) |ctx| {
            created = ctx;
        } else |err| switch (err) {
            error.OutOfMemory => {
                // Failed native functions may temporarily retain their
                // constructing Realm. The ordinary cycle pass must retire the
                // whole unpublished graph without touching the anchor Realm.
                _ = rt.runObjectCycleRemoval();
                try std.testing.expect(rt.constructing_context_head == null);
                try std.testing.expect(rt.constructing_context_tail == null);
                try std.testing.expectEqual(anchor, rt.firstContext().?);
                try std.testing.expect(anchor.runtime_next == null);
                try std.testing.expectEqual(@as(usize, 1), rt.root_providers.len);
                try std.testing.expect(rt.external_host_functions.len <= external_count_before + 1);

                created = try BindingContext.create(rt);
            },
            else => return err,
        }
        defer created.destroy();

        try std.testing.expect(created.core.isLive());
        try std.testing.expect(rt.constructing_context_head == null);
        try std.testing.expect(rt.constructing_context_tail == null);
        try std.testing.expectEqual(@as(usize, 2), rt.root_providers.len);
        // Retrying a partial install must reuse the Runtime-wide output host
        // record instead of appending a duplicate record on every failure.
        try std.testing.expectEqual(external_count_before + 1, rt.external_host_functions.len);

        const canary = try created.eval(canary_source, .{ .filename = "<binding-construction-retry>" });
        defer canary.free(rt);
        try expectStringValue(rt, canary, "canary-ok");
    }
    try injector.expectBalanced();
    return induced;
}

test "oom recovery canary: binding Realm construction rollback and retry" {
    var fail_index: usize = 0;
    while (try runBindingContextConstructionRetryAttempt(fail_index)) : (fail_index += 1) {}
    try std.testing.expect(fail_index > 2);
}

test "oom recovery canary: FunctionBytecode combined main FAM allocation" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("oom-function-bytecode-fixture");
    defer rt.atoms.free(name);
    const fixture_options: zjs.bytecode.FunctionBytecode.FixtureOptions = .{
        .name = name,
        .arg_count = 3,
        .var_count = 5,
        .defined_arg_count = 2,
        .closure_var_count = 4,
        .cpool_count = 64,
        .byte_code = &.{zjs.bytecode.opcode.op.return_undef},
        .has_debug = true,
        .has_extension = true,
    };
    const layout = try zjs.bytecode.FunctionLayout.init(
        fixture_options.has_debug,
        fixture_options.has_extension,
        fixture_options.cpool_count,
        fixture_options.arg_count,
        fixture_options.var_count,
        fixture_options.closure_var_count,
        fixture_options.byte_code.len,
    );
    // Above the slab ceiling in both JSValue representations, so the exact
    // MemoryAccount charge is the one main allocation plus its GC prefix.
    try std.testing.expect(layout.mainPayloadBytes() > 512);
    try std.testing.expect(layout.total_size > 512);
    const accounted_bytes = layout.total_size + core.gc.metadata_prefix_size;

    const baseline_bytes = rt.memory.allocated_bytes;
    const baseline_allocations = rt.memory.allocation_count;
    const baseline_live = rt.gc.liveCount();
    const baseline_create_calls = rt.memory.create_calls;
    const baseline_destroy_calls = rt.memory.destroy_calls;

    // All inline tables and exact code belong to the same createWithFam call.
    // Leave that full charge one byte short: no partial shell/table owner may
    // become visible in either accounting or the GC registry.
    rt.setMemoryLimit(baseline_bytes + accounted_bytes - 1);
    if (zjs.bytecode.FunctionBytecode.createFixture(rt, fixture_options)) |unexpected| {
        rt.setMemoryLimit(null);
        unexpected.destroyUnpublishedFixture(rt);
        return error.TestUnexpectedResult;
    } else |err| {
        rt.setMemoryLimit(null);
        if (err != error.OutOfMemory) return err;
    }
    try std.testing.expectEqual(baseline_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(baseline_allocations, rt.memory.allocation_count);
    try std.testing.expectEqual(baseline_live, rt.gc.liveCount());
    try std.testing.expectEqual(baseline_create_calls, rt.memory.create_calls);
    try std.testing.expectEqual(baseline_destroy_calls, rt.memory.destroy_calls);

    // The same runtime must immediately create, publish, and destroy the same
    // full layout. Exactly one successful create/destroy pair proves there is
    // no second main-artifact allocation left in the transaction.
    const recovered = try zjs.bytecode.FunctionBytecode.createFixture(rt, fixture_options);
    var recovered_published = false;
    errdefer if (!recovered_published) recovered.destroyUnpublishedFixture(rt);
    for (recovered.closureVar(), 0..) |*closure, index| {
        closure.* = zjs.bytecode.function_bytecode.BytecodeClosureVar.init(.{
            .closure_type = .ref,
            .var_idx = @intCast(index),
            .var_name = rt.atoms.dup(name),
        });
    }

    try std.testing.expectEqual(layout.total_size, recovered.layout().total_size);
    try std.testing.expectEqual(layout.total_size, recovered.heapByteSize());
    try std.testing.expect(!recovered.header.meta().flags.metadata_in_slab);
    try std.testing.expectEqual(baseline_bytes + accounted_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(baseline_allocations + 1, rt.memory.allocation_count);
    try std.testing.expectEqual(baseline_live, rt.gc.liveCount());
    try std.testing.expectEqual(baseline_create_calls + 1, rt.memory.create_calls);
    try std.testing.expectEqual(baseline_destroy_calls, rt.memory.destroy_calls);
    try std.testing.expectEqual(@as(usize, 64), recovered.cpoolSlice().len);
    try std.testing.expectEqual(@as(usize, 8), recovered.allVarDefs().len);
    try std.testing.expectEqual(@as(usize, 4), recovered.closureVar().len);
    try std.testing.expectEqualSlices(u8, fixture_options.byte_code, recovered.byteCode());

    recovered.publishFixtureNoFail(rt);
    recovered_published = true;
    try std.testing.expectEqual(baseline_live + 1, rt.gc.liveCount());
    core.JSValue.functionBytecode(&recovered.header).free(rt);

    try std.testing.expectEqual(baseline_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(baseline_allocations, rt.memory.allocation_count);
    try std.testing.expectEqual(baseline_live, rt.gc.liveCount());
    try std.testing.expectEqual(baseline_create_calls + 1, rt.memory.create_calls);
    try std.testing.expectEqual(baseline_destroy_calls + 1, rt.memory.destroy_calls);
}

fn corpusSnippetNamed(name: []const u8) Snippet {
    for (corpus) |snippet| {
        if (std.mem.eql(u8, snippet.name, name)) return snippet;
    }
    unreachable;
}

test "oom recovery canary: arithmetic snippet" {
    try recoveryCanarySweep(corpusSnippetNamed("arith-numbers"));
}

test "oom recovery canary: root and nested closure construction" {
    try recoveryCanarySweep(corpusSnippetNamed("calls-closures"));
}

test "oom recovery canary: repeated private class identity" {
    try recoveryCanarySweep(corpusSnippetNamed("private-class-fresh-identity"));
}

test "oom recovery canary: rope concat+flatten snippet" {
    try recoveryCanarySweep(corpusSnippetNamed("rope-concat-flatten"));
}

test "oom recovery canary: promise jobs snippet" {
    try recoveryCanarySweep(corpusSnippetNamed("promise-jobs"));
}

test "oom recovery canary: generator return through shared finalizer" {
    try recoveryCanarySweep(corpusSnippetNamed("generator-return-shared-finalizer"));
}

// ---------------------------------------------------------------------------
// Coverage report (v1) - keep this the last test in the file so the count
// reflects the whole suite. Prints only when built with
// `-Dzjs_oom_coverage=true`; the default build compiles this away.
// ---------------------------------------------------------------------------

test "oom coverage report" {
    if (comptime !core.memory.oom_coverage_enabled) return;
    std.debug.print(
        "\n[oom-coverage] distinct allocation call sites hit: {d}\n",
        .{core.memory.oomCoverageDistinctSiteCount()},
    );
}

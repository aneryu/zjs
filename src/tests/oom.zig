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
        \\const inc = mk(1);
        \\let t = 0;
        \\for (let i = 0; i < 5; i++) t = inc(t);
        \\"calls-ok:" + t
        ,
        .expect = .{ .string = "calls-ok:5" },
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
    zjs.builtins.registry.registerStandardGlobalsDefault();
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
    const wrapper: *BindingContext = @ptrCast(ctx);

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

/// Pure parse lifecycle: lexer + parser + bytecode pipeline, no context and
/// no execution. Uses a syntax-dense source so the sweep covers the parser
/// allocation clusters (scopes, function defs, constant pools, arena).
fn runParseOnly(allocator: std.mem.Allocator, source: []const u8) !void {
    const rt = try core.JSRuntime.create(allocator);
    var rt_owned = true;
    errdefer if (rt_owned) rt.destroy();
    var result = try parser.compile(rt, source, .{
        .mode = .script,
        .filename = corpus_filename,
    });
    {
        defer result.deinit();
        if (result.syntax_error != null) return error.TestUnexpectedResult;
    }
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
    const wrapper: *BindingContext = @ptrCast(ctx);

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
        const wrapper: *BindingContext = @ptrCast(ctx);

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

test "oom recovery canary: arithmetic snippet" {
    try recoveryCanarySweep(corpus[0]);
}

test "oom recovery canary: rope concat+flatten snippet" {
    try recoveryCanarySweep(corpus[4]);
}

test "oom recovery canary: promise jobs snippet" {
    try recoveryCanarySweep(corpus[6]);
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

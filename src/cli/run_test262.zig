const std = @import("std");
const cli_process = @import("cli_process.zig");
const test262_root = @import("zjs");

/// Message-only panics in ReleaseFast, full traces everywhere else — the
/// `-dev` runner and the `test-runner` artifact are Debug, so they keep them.
pub const panic = @import("panic_policy.zig").policy;

// QCP-1: this root is shared by the `run-test262` / `run-test262-dev`
// executables and by the `test-runner` scoped test artifact, so it proves the
// effective configuration of all three at compile time
// (src/config_signature.zig). It is the reason a test262 sweep can now name
// the configuration it ran: before the signature, a nested gate build silently
// resolved the defaults and still read as a whole-engine result.
comptime {
    test262_root.config_signature.attest("run-test262 / test-runner");
}

const zjs = test262_root.binding_root;
const runtime_layer = test262_root.runtime;
const parser = test262_root.parser;
const core_runtime = test262_root.core.runtime;
const runner_options = @import("run_test262_options.zig");
const runner_reporter = @import("run_test262_reporter.zig");
const runner_names = @import("run_test262_names.zig");
const runner_metadata = @import("run_test262_metadata.zig");
const runner_config = @import("run_test262_config.zig");
const runner_known_errors = @import("run_test262_known_errors.zig");
const runner_source = @import("run_test262_source.zig");
const runner_host = @import("run_test262_host.zig");

pub const Config = runner_options.Config;
pub const FeatureOverrideKind = runner_options.FeatureOverrideKind;
pub const FeatureOverride = runner_options.FeatureOverride;
pub const BoundedFeatureOverrides = runner_options.BoundedFeatureOverrides;
pub const BoundedList = runner_options.BoundedList;
pub const parseArgs = runner_options.parse;
pub const TestRunResult = runner_reporter.TestRunResult;
pub const Reporter = runner_reporter.Reporter;
pub const classifyBucket = runner_reporter.classifyBucket;
pub const deriveDirSegment = runner_reporter.deriveDirSegment;
const renderSortedFailureLog = runner_reporter.renderSortedFailureLog;
const renderSkippedFeaturesJson = runner_reporter.renderSkippedFeaturesJson;
pub const NameList = runner_names.NameList;
pub const compareNames = runner_names.compare;
pub const NegativeMetadata = runner_metadata.NegativeMetadata;
pub const TestMetadata = runner_metadata.TestMetadata;
pub const parseMetadataText = runner_metadata.parse;
pub const LoadedConfig = runner_config.LoadedConfig;
pub const loadConfigText = runner_config.loadText;
pub const loadConfigFile = runner_config.loadFile;
const applyFeatureOverrides = runner_config.applyFeatureOverrides;
const loadKnownErrors = runner_known_errors.load;
const parseKnownErrorsText = runner_known_errors.parseText;
const writeKnownErrors = runner_known_errors.write;
const mergeKnownErrorsForUpdate = runner_known_errors.mergeForUpdate;
const renderKnownErrorsText = runner_known_errors.renderText;
const HarnessCache = runner_source.HarnessCache;
const makeHarnessPrelude = runner_source.makeHarnessPrelude;
const readTestSource = runner_source.readTestSource;
const test262Override = runner_source.test262Override;
const test262OverridePath = runner_source.test262OverridePath;
const test262UpstreamPath = runner_source.test262UpstreamPath;
const test262_override_manifest = runner_source.override_manifest;
const makeTestSourceFromBytes = runner_source.makeTestSourceFromBytes;
const loadMetadataFromFile = runner_source.loadMetadataFromFile;
pub const assertSameValue = runner_host.assertSameValue;
pub const cleanupTest262Agents = runner_host.cleanupTest262Agents;
pub const installTest262Globals = runner_host.installTest262Globals;

extern "c" fn getpid() c_int;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try cli_process.argsToSlice(arena, init.minimal.args);

    var config = parseArgs(args[1..]) catch |err| {
        try cli_process.printError(io, "run-test262: {s}\n", .{@errorName(err)});
        try printUsage(io);
        std.process.exit(2);
    };

    if (config.timeout_ms == null) {
        // 20 seconds per test caps wall-time impact of stuck tests while
        // leaving room for exhaustive URI UTF-8 and legacy regexp literal
        // sweeps. Override with `-T <ms>`.
        config.timeout_ms = 20_000;
    }

    var summary = runSelectedTests(init.gpa, io, config, "zig-out/bin/zjs") catch |err| {
        try cli_process.printError(io, "run-test262: unable to run tests: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer summary.deinit(init.gpa);

    dumpHostDispatchStats(init.environ_map);
    try printSummary(io, summary);
    const has_unexpected = summary.failed != 0 or summary.fixed != 0;
    std.process.exit(if (has_unexpected) 1 else 0);
}

/// The default execution path evaluates tests in-process, so the engine's
/// per-site dispatch hit counters accumulate inside this runner. When built
/// with `-Dzjs_enable_opcode_profile=true` and `ZJS_HOST_DISPATCH_STATS_FILE`
/// is set, append the totals so measurement runs can include test262 slices.
fn dumpHostDispatchStats(environ_map: *std.process.Environ.Map) void {
    const host_dispatch_stats = test262_root.exec.host_dispatch_stats;
    if (comptime !host_dispatch_stats.enabled) return;
    const path = environ_map.get("ZJS_HOST_DISPATCH_STATS_FILE") orelse return;
    var path_buf: [512:0]u8 = undefined;
    if (path.len == 0 or path.len >= path_buf.len) return;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    host_dispatch_stats.appendToFile(&path_buf);
}

fn printUsage(io: std.Io) !void {
    try cli_process.printError(io, runner_options.usage, .{});
}

fn printSummary(io: std.Io, summary: ExecutionSummary) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "run-test262: prepared {d}/{d} tests",
        .{ summary.selection.selected_tests, summary.selection.total_tests },
    );
    if (summary.selection.excluded_tests != 0) try stdout.print(", {d} excluded", .{summary.selection.excluded_tests});
    if (summary.selection.skipped_by_feature != 0) try stdout.print(", {d} skipped by feature", .{summary.selection.skipped_by_feature});
    if (summary.selection.skipped_by_index != 0) try stdout.print(", {d} skipped by index", .{summary.selection.skipped_by_index});
    try stdout.print("\n", .{});
    if (summary.selection.harnessdir) |harnessdir| try stdout.print("harness: {s}\n", .{harnessdir});
    if (summary.selection.errorfile) |errorfile| try stdout.print("known errors: {s}\n", .{errorfile});
    try stdout.print("Result: {d}/{d} errors, passed {d}", .{ summary.failed, summary.selection.selected_tests, summary.passed });
    if (summary.known_failures != 0) try stdout.print(", known {d}", .{summary.known_failures});
    if (summary.fixed != 0) try stdout.print(", fixed {d}", .{summary.fixed});
    try stdout.print("\n", .{});
    try stdout.flush();
}

const stderr_storage_len = 2048;

pub const SelectionSummary = struct {
    total_tests: usize = 0,
    selected_tests: usize = 0,
    excluded_tests: usize = 0,
    skipped_by_feature: usize = 0,
    skipped_by_index: usize = 0,
    harnessdir: ?[]const u8 = null,
    errorfile: ?[]const u8 = null,

    pub fn deinit(self: *SelectionSummary, allocator: std.mem.Allocator) void {
        if (self.harnessdir) |value| allocator.free(value);
        if (self.errorfile) |value| allocator.free(value);
    }
};

pub const PreparedSelection = struct {
    tests: NameList,
    summary: SelectionSummary,
    skipped_features: NameList,

    pub fn deinit(self: *PreparedSelection, allocator: std.mem.Allocator) void {
        self.tests.deinit();
        self.skipped_features.deinit();
        self.summary.deinit(allocator);
    }
};

pub const ExecutionSummary = struct {
    selection: SelectionSummary,
    passed: usize = 0,
    failed: usize = 0,
    known_failures: usize = 0,
    fixed: usize = 0,

    pub fn deinit(self: *ExecutionSummary, allocator: std.mem.Allocator) void {
        self.selection.deinit(allocator);
    }
};

const WorkerResult = struct {
    passed: usize = 0,
    failed: usize = 0,
    known_failures: usize = 0,
    fixed: usize = 0,
    skipped_by_feature: usize = 0,
    current_failures: NameList,
    err: ?anyerror = null,

    fn init(allocator: std.mem.Allocator) WorkerResult {
        return .{ .current_failures = NameList.init(allocator) };
    }

    fn deinit(self: *WorkerResult) void {
        self.current_failures.deinit();
    }
};

/// Runner state shared by the single-worker path and every thread adapter.
/// Cross-thread mutation stays confined to `next_index` and `reporter`, whose
/// implementations own their synchronization.
const WorkerShared = struct {
    io: std.Io,
    engine_path: []const u8,
    use_external_engine: bool,
    harnessdir: ?[]const u8,
    harness_prelude: []const u8,
    tests: []const []const u8,
    known_errors: NameList,
    skipped_features: NameList,
    /// Shared atomic counter used by all workers to claim the next test index.
    next_index: *std.atomic.Value(usize),
    verbose: u8,
    timeout_ms: ?u32,
    global_module: bool,
    reporter: ?*Reporter,
};

/// Per-thread ownership kept separate from the shared run description.
const WorkerThreadContext = struct {
    allocator: std.mem.Allocator,
    shared: *const WorkerShared,
    result: *WorkerResult,

    fn run(context: *WorkerThreadContext) void {
        var summary = ExecutionSummary{ .selection = .{} };
        runWorkerLoop(
            context.shared,
            context.allocator,
            &summary,
            &context.result.current_failures,
        ) catch |err| {
            context.result.err = err;
            return;
        };
        context.result.passed = summary.passed;
        context.result.failed = summary.failed;
        context.result.known_failures = summary.known_failures;
        context.result.fixed = summary.fixed;
        context.result.skipped_by_feature = summary.selection.skipped_by_feature;
    }
};

pub fn runSelectedTests(allocator: std.mem.Allocator, io: std.Io, config: Config, zjs_path: []const u8) !ExecutionSummary {
    return runSelectedTestsWithReporterMode(allocator, io, config, zjs_path, false);
}

fn runSelectedTestsQuiet(allocator: std.mem.Allocator, io: std.Io, config: Config, zjs_path: []const u8) !ExecutionSummary {
    return runSelectedTestsWithReporterMode(allocator, io, config, zjs_path, true);
}

fn runSelectedTestsWithReporterMode(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    zjs_path: []const u8,
    quiet_reporter: bool,
) !ExecutionSummary {
    var prepared = try prepareSelection(allocator, io, config);
    errdefer prepared.deinit(allocator);

    var known_errors = try loadKnownErrors(allocator, io, prepared.summary.errorfile);
    defer known_errors.deinit();
    var current_failures = NameList.init(allocator);
    defer current_failures.deinit();

    var summary = ExecutionSummary{
        .selection = prepared.summary,
    };
    prepared.summary = .{};
    errdefer summary.deinit(allocator);
    const harness_prelude = try makeHarnessPrelude(allocator, io, summary.selection.harnessdir);
    defer allocator.free(harness_prelude);

    var reporter = if (quiet_reporter)
        Reporter.initQuiet(allocator, config.reports_dir)
    else
        Reporter.init(allocator, config.reports_dir);
    defer reporter.deinit();

    const engine_path = config.engine_path orelse zjs_path;
    const use_external_engine = config.engine_path != null;
    const requested_threads: usize = if (config.threads == 0)
        std.Thread.getCpuCount() catch 1
    else
        @intCast(config.threads);
    const worker_count = @max(@as(usize, 1), @min(requested_threads, prepared.tests.items.len));
    var test_gpa = std.heap.DebugAllocator(.{
        .safety = false,
        .stack_trace_frames = 0,
        .thread_safe = false,
    }){};
    defer _ = test_gpa.deinit();
    const test_allocator = test_gpa.allocator();
    var next_index: std.atomic.Value(usize) = .init(0);
    const worker_shared = WorkerShared{
        .io = io,
        .engine_path = engine_path,
        .use_external_engine = use_external_engine,
        .harnessdir = summary.selection.harnessdir,
        .harness_prelude = harness_prelude,
        .tests = prepared.tests.items,
        .known_errors = known_errors,
        .skipped_features = prepared.skipped_features,
        .next_index = &next_index,
        .verbose = config.verbose,
        .timeout_ms = config.timeout_ms,
        .global_module = config.module,
        .reporter = &reporter,
    };
    if (worker_count == 1) {
        try runWorkerLoop(
            &worker_shared,
            test_allocator,
            &summary,
            &current_failures,
        );
    } else {
        var worker_gpas = try allocator.alloc(std.heap.DebugAllocator(.{
            .safety = false,
            .stack_trace_frames = 0,
            .thread_safe = false,
        }), worker_count);
        defer allocator.free(worker_gpas);
        for (worker_gpas) |*gpa| gpa.* = .{};
        defer for (worker_gpas) |*gpa| {
            _ = gpa.deinit();
        };

        var results = try allocator.alloc(WorkerResult, worker_count);
        defer allocator.free(results);
        var contexts = try allocator.alloc(WorkerThreadContext, worker_count);
        defer allocator.free(contexts);
        var threads = try allocator.alloc(std.Thread, worker_count);
        defer allocator.free(threads);

        for (results, 0..) |*result, i| result.* = WorkerResult.init(worker_gpas[i].allocator());
        defer for (results) |*result| result.deinit();

        {
            var spawned: usize = 0;
            errdefer {
                var i: usize = 0;
                while (i < spawned) : (i += 1) threads[i].join();
            }
            while (spawned < worker_count) : (spawned += 1) {
                contexts[spawned] = .{
                    .allocator = worker_gpas[spawned].allocator(),
                    .shared = &worker_shared,
                    .result = &results[spawned],
                };
                threads[spawned] = try std.Thread.spawn(.{}, WorkerThreadContext.run, .{&contexts[spawned]});
            }
        }

        for (threads) |thread| thread.join();

        for (results) |*result| {
            if (result.err) |err| return err;
            summary.passed += result.passed;
            summary.failed += result.failed;
            summary.known_failures += result.known_failures;
            summary.fixed += result.fixed;
            summary.selection.skipped_by_feature += result.skipped_by_feature;
            for (result.current_failures.items) |failure| try current_failures.append(failure);
        }
    }

    if (config.update_errors and summary.selection.errorfile != null) {
        var merged_failures = try mergeKnownErrorsForUpdate(allocator, known_errors, prepared.tests, current_failures);
        defer merged_failures.deinit();
        try writeKnownErrors(allocator, io, summary.selection.errorfile.?, merged_failures);
    }

    try reporter.flush(io);

    prepared.tests.deinit();
    prepared.skipped_features.deinit();
    return summary;
}

fn runWorkerLoop(
    shared: *const WorkerShared,
    allocator: std.mem.Allocator,
    summary: *ExecutionSummary,
    current_failures: *NameList,
) !void {
    var harness_cache = HarnessCache.init(allocator, shared.io, shared.harnessdir);
    defer harness_cache.deinit();

    while (true) {
        const index = shared.next_index.fetchAdd(1, .monotonic);
        if (index >= shared.tests.len) break;
        if (index > 0 and index % 1000 == 0) {
            if (shared.reporter) |reporter| {
                reporter.lockedPrint(shared.io, "Progress: {d}/{d} tests ({d}%)\n", .{ index, shared.tests.len, index * 100 / shared.tests.len }) catch {};
            } else {
                cli_process.printError(shared.io, "Progress: {d}/{d} tests ({d}%)\n", .{ index, shared.tests.len, index * 100 / shared.tests.len }) catch {};
            }
        }
        const test_path = shared.tests[index];

        var run_err: ?anyerror = null;
        const result, const is_known = blk: {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            var stderr_text: []const u8 = "";
            var stderr_storage: [stderr_storage_len]u8 = undefined;
            const res = runOneTest(
                arena_allocator,
                shared.io,
                shared.engine_path,
                shared.use_external_engine,
                &harness_cache,
                shared.harness_prelude,
                test_path,
                index,
                shared.verbose,
                shared.timeout_ms,
                shared.global_module,
                shared.skipped_features,
                shared.reporter,
                &stderr_storage,
                &stderr_text,
            ) catch |err| {
                run_err = err;
                break :blk .{ .skipped, false };
            };

            if (res == .skipped) {
                break :blk .{ .skipped, false };
            }

            const known = shared.known_errors.findSortedExact(test_path) != null;
            if (shared.reporter) |r| {
                r.recordResult(shared.io, test_path, res, stderr_text, known) catch |err| {
                    run_err = err;
                    break :blk .{ .skipped, false };
                };
            }
            break :blk .{ res, known };
        };

        if (run_err) |err| {
            if (shared.reporter) |r| {
                r.lockedPrint(shared.io, "test262 worker error: {s}: {s}\n", .{ test_path, @errorName(err) }) catch {};
            }
            return err;
        }

        if (result == .skipped) {
            summary.selection.skipped_by_feature += 1;
            continue;
        }

        switch (result) {
            .passed => {
                if (is_known) {
                    summary.fixed += 1;
                } else {
                    summary.passed += 1;
                }
            },
            .failed => {
                if (is_known) {
                    summary.known_failures += 1;
                } else {
                    summary.failed += 1;
                }
                try current_failures.append(test_path);
            },
            .skipped => unreachable,
        }
    }
}

pub fn prepareSelection(allocator: std.mem.Allocator, io: std.Io, config: Config) !PreparedSelection {
    var loaded = if (config.config_path) |path| try loadConfigFile(allocator, io, path) else LoadedConfig.init(allocator);
    defer loaded.deinit(allocator);
    try applyFeatureOverrides(&loaded, config.feature_overrides);

    var tests = NameList.init(allocator);
    defer tests.deinit();
    var selected = NameList.init(allocator);
    errdefer selected.deinit();

    var i: usize = 0;
    while (i < config.files.len) : (i += 1) {
        try tests.append(config.files.get(i));
    }

    i = 0;
    while (i < config.dirs.len) : (i += 1) {
        try enumerateTests(allocator, io, &tests, config.dirs.get(i));
    }

    if (config.files.len == 0 and config.dirs.len == 0) {
        if (config.test_root) |root| {
            try enumerateTests(allocator, io, &tests, root);
        } else if (loaded.testdir) |testdir| {
            try enumerateTests(allocator, io, &tests, testdir);
        }
    }

    tests.sortAndDedupe();
    var summary = SelectionSummary{
        .total_tests = tests.items.len,
        .harnessdir = if (loaded.harnessdir) |value| try allocator.dupe(u8, value) else null,
        .errorfile = if (config.known_error_file orelse loaded.errorfile) |value| try allocator.dupe(u8, value) else null,
    };
    errdefer summary.deinit(allocator);

    for (tests.items, 0..) |test_path, index| {
        if (loaded.excludesTest(test_path)) {
            summary.excluded_tests += 1;
            continue;
        }
        const start_index = config.start_index orelse 0;
        if (index < start_index or (config.stop_index != null and index > config.stop_index.?)) {
            summary.skipped_by_index += 1;
            continue;
        }
        summary.selected_tests += 1;
        try selected.append(test_path);
    }

    return .{
        .tests = selected,
        .summary = summary,
        .skipped_features = loaded.skipped_features.move(),
    };
}

fn enumerateTests(allocator: std.mem.Allocator, io: std.Io, tests: *NameList, root: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.indexOf(u8, entry.path, ".zjs-module-") != null) continue;
        if (!std.mem.endsWith(u8, entry.path, ".js")) continue;
        if (std.mem.endsWith(u8, entry.path, "_FIXTURE.js")) continue;
        try tests.appendOwned(try std.fs.path.join(allocator, &.{ root, entry.path }));
    }
}

fn runOneTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    engine_path: []const u8,
    use_external_engine: bool,
    harness_cache: *HarnessCache,
    harness_prelude: []const u8,
    test_path: []const u8,
    test_index: usize,
    verbose: u8,
    timeout_ms: ?u32,
    global_module: bool,
    skipped_features: NameList,
    reporter: ?*Reporter,
    stderr_storage: *[stderr_storage_len]u8,
    stderr_out: *[]const u8,
) !TestRunResult {
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    const test_source = try readTestSource(allocator, io, test_path);
    defer allocator.free(test_source);

    var metadata = try parseMetadataText(allocator, test_source);
    defer metadata.deinit(allocator);
    if (metadata.skippedFeature(skipped_features)) |feature| {
        if (reporter) |r| try r.recordSkippedFeature(io, feature);
        return .skipped;
    }

    const run_as_module = global_module or metadata.hasFlag("module");

    const source = try makeTestSourceFromBytes(allocator, harness_cache, harness_prelude, test_source, metadata);
    defer allocator.free(source);

    var stderr: []const u8 = "";
    // Mirrors qjs run-test262.c:1805: the main test agent defaults to
    // can_block = TRUE (a shell host can block), and only the
    // `CanBlockIsFalse` flag turns it off. The harness's
    // $262.agent.safeBroadcast probes `Atomics.wait` on the main agent and
    // relies on this default; with the engine's faithful js_atomics_wait
    // ordering (can-block TypeError before the value compare) an inverted
    // default fails every wait/notify agent test.
    const can_block = !metadata.hasFlag("CanBlockIsFalse");
    const is_async = metadata.hasFlag("async");
    const exited_zero = if (use_external_engine)
        try runExternalEngine(allocator, io, engine_path, source, test_path, test_index, run_as_module, can_block, is_async, timeout_ms, stderr_storage, &stderr)
    else
        try runEmbeddedEngine(allocator, io, source, test_path, run_as_module, can_block, is_async, stderr_storage, &stderr);
    const elapsed_ms: i64 = started.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.toMilliseconds();
    const passed = if (metadata.negative) |negative|
        negativeResultMatches(negative, exited_zero, stderr)
    else
        exited_zero;
    const is_slow = if (timeout_ms) |timeout| elapsed_ms >= @as(i64, timeout) else false;
    const result: TestRunResult = if (passed) .passed else .failed;

    if (verbose > 1 or is_slow) {
        try printRunResult(io, reporter, test_path, result, elapsed_ms, stderr);
    } else if (result == .failed and verbose != 0) {
        try printFailure(io, reporter, test_path, stderr);
    }
    stderr_out.* = stderr;
    return result;
}

fn runEmbeddedEngine(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    path: []const u8,
    run_as_module: bool,
    can_block: bool,
    is_async: bool,
    stderr_storage: *[stderr_storage_len]u8,
    stderr_out: *[]const u8,
) !bool {
    const rt = try zjs.JSRuntime.createWithOptions(allocator, .{});
    errdefer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    errdefer ctx.destroy();
    var output_buffer: [64 * 1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var event_loop = runtime_layer.EventLoop.init(ctx, .{ .output = &output });
    event_loop.install();
    errdefer event_loop.deinit();
    const global_obj = try ctx.globalObject();
    try installTest262Globals(rt, ctx, global_obj);
    defer {
        event_loop.deinit();
        _ = cleanupTest262Agents(rt);
        runtime_layer.cleanupAtomicsWaitersForContext(ctx);
        ctx.destroy();
        rt.destroy();
    }
    rt.setCanBlock(can_block);
    // Install the file-loader dynamic import (mirrors the CLI src/cli/zjs.zig
    // and qjs's run-test262 providing the module loader): [async] dynamic-import
    // tests are SCRIPTS, so import() must work in script mode. The state must
    // outlive eval + the job drain below (the import job resolves in runJobs).
    var dynamic_import_state = test262_root.exec.module_graph.DynamicImportState{
        .runtime = ctx.runtimePtr(),
        .output = &output,
        .io = io,
        .allocator = allocator,
        .max_source_size = 16 * 1024 * 1024,
    };
    defer dynamic_import_state.deinit();
    var dynamic_import_scope = test262_root.exec.module_graph.installDynamicImport(&dynamic_import_state);
    defer dynamic_import_scope.deinit();
    var value = (if (run_as_module)
        runtime_layer.evalFileModuleGraphWithOutput(ctx, source, &output, path, io, allocator, 16 * 1024 * 1024)
    else
        ctx.eval(source, .{
            .mode = .script,
            .output = &output,
            .discard_script_result = true,
            // Pass the test file path as the script's filename so the dynamic
            // import referrer (vm_eval_module.zig:143 = function.filename) is the
            // test file and `import('./fixture.js')` resolves relative to the
            // test directory, not the runner's cwd. Without this the referrer is
            // "<eval>" and every relative import rejects.
            .filename = path,
        })) catch |err| failed: {
        if (try formatPendingExceptionName(rt, ctx, stderr_storage)) |name| {
            stderr_out.* = name;
            break :failed zjs.JSValue.exception();
        }
        stderr_out.* = try std.fmt.bufPrint(stderr_storage, "{s}", .{@errorName(err)});
        break :failed zjs.JSValue.exception();
    };
    defer value.free(rt);

    if (!value.isException()) {
        try dynamic_import_state.runJobs(ctx.core);
        if (ctx.hasException()) {
            stderr_out.* = "unhandled promise rejection";
            const async_exception = ctx.takePendingException();
            async_exception.free(rt);
            return false;
        }
        if (is_async and !asyncHarnessCompleted(output.buffered())) {
            stderr_out.* = "TypeError: $DONE() not called";
            return false;
        }
    }
    return !value.isException();
}

/// Mirrors the reference runner's async-test oracle: run-test262.c js_print
/// (quickjs run-test262.c:541-545) counts prints of the exact string
/// "Test262:AsyncTestComplete" and forces an error on any print starting with
/// "Test262:AsyncTestFailure"; eval_buf (run-test262.c:1418-1423) then throws
/// TypeError "$DONE() not called" unless the counter is exactly 1 after all
/// pending jobs drained. zjs captures print output per line ("<args>\n"), so
/// the per-print check becomes a per-line check over the captured output.
fn asyncHarnessCompleted(output_bytes: []const u8) bool {
    var async_done: u32 = 0;
    var lines = std.mem.splitScalar(u8, output_bytes, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "Test262:AsyncTestComplete")) {
            async_done += 1;
        } else if (std.mem.startsWith(u8, line, "Test262:AsyncTestFailure")) {
            async_done = 2; // force an error, mirroring run-test262.c:544
        }
    }
    return async_done == 1;
}

fn formatPendingExceptionName(rt: *zjs.JSRuntime, ctx: *zjs.JSContext, storage: *[stderr_storage_len]u8) !?[]const u8 {
    if (!ctx.hasException()) return null;
    const thrown = ctx.takePendingException();
    defer thrown.free(rt);

    if (thrown.isObject()) {
        var owned_name: ?[]u8 = null;
        defer if (owned_name) |name| rt.memory.allocator.free(name);

        if (try exceptionStringProperty(rt, ctx, thrown, "name")) |name| {
            if (name.len != 0) {
                owned_name = name;
            } else {
                rt.memory.allocator.free(name);
            }
        }

        if (owned_name == null) {
            const ctor = ctx.getProperty(thrown, "constructor") catch null;
            if (ctor) |constructor| {
                defer constructor.free(rt);
                if (ctx.isCallable(constructor)) {
                    const maybe_name: ?[]u8 = ctx.functionName(constructor, rt.memory.allocator) catch |err| switch (err) {
                        error.OutOfMemory => return err,
                        else => null,
                    };
                    if (maybe_name) |name| {
                        if (name.len != 0 and !std.mem.eql(u8, name, "Object")) {
                            owned_name = name;
                        } else {
                            rt.memory.allocator.free(name);
                        }
                    }
                }
            }
        }

        if (owned_name) |name| {
            if (try exceptionStringProperty(rt, ctx, thrown, "message")) |message| {
                defer rt.memory.allocator.free(message);
                if (message.len != 0) return try std.fmt.bufPrint(storage, "{s}: {s}", .{ name, message });
            }
            return try std.fmt.bufPrint(storage, "{s}", .{name});
        }
    }

    const formatted = try ctx.formatException(thrown, rt.memory.allocator);
    defer rt.memory.allocator.free(formatted);
    const name = if (std.mem.indexOfScalar(u8, formatted, ':')) |colon|
        formatted[0..colon]
    else
        formatted;
    if (name.len == 0) return null;
    return try std.fmt.bufPrint(storage, "{s}", .{name});
}

fn exceptionStringProperty(rt: *zjs.JSRuntime, ctx: *zjs.JSContext, value: zjs.JSValue, name: []const u8) !?[]u8 {
    const property = ctx.getProperty(value, name) catch return null;
    defer property.free(rt);
    if (!property.isString()) return null;
    const bytes = try ctx.toOwnedUtf8(property, rt.memory.allocator);
    return bytes;
}

fn runExternalEngine(
    allocator: std.mem.Allocator,
    io: std.Io,
    engine_path: []const u8,
    source: []const u8,
    test_path: []const u8,
    test_index: usize,
    run_as_module: bool,
    can_block: bool,
    is_async: bool,
    timeout_ms: ?u32,
    stderr_storage: *[stderr_storage_len]u8,
    stderr_out: *[]const u8,
) !bool {
    // Write the assembled test source to tmpfs when available. This avoids a
    // real disk write per test and is significantly faster than the workspace
    // `.zig-cache/` directory under heavy parallelism. Fallback path stays in
    // `.zig-cache/` so Windows/non-tmpfs systems still work.
    var temp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const temp_path = blk: {
        if (run_as_module) {
            break :blk try moduleTempTestPath(&temp_buf, test_path, test_index);
        }
        if (std.Io.Dir.cwd().access(io, "/dev/shm", .{})) |_| {
            break :blk try tempTestPathShm(&temp_buf, test_path, test_index);
        } else |_| {
            std.Io.Dir.cwd().createDirPath(io, ".zig-cache") catch {};
            break :blk try tempTestPath(&temp_buf, test_path, test_index);
        }
    };
    if (run_as_module) try prepareModuleTempTree(io, temp_path, test_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temp_path, .data = source });
    defer if (run_as_module) {
        if (std.fs.path.dirname(temp_path)) |temp_dir| {
            std.Io.Dir.cwd().deleteTree(io, temp_dir) catch {};
        }
    } else {
        std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
    };

    const argv_script = [_][]const u8{ engine_path, temp_path };
    const argv_script_can_block = [_][]const u8{ engine_path, "--can-block", temp_path };
    const argv_module = [_][]const u8{ engine_path, "-m", temp_path };
    const argv_module_can_block = [_][]const u8{ engine_path, "--can-block", "-m", temp_path };
    const timeout: std.Io.Timeout = if (timeout_ms) |ms|
        if (ms > 0) .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(@intCast(ms)),
            .clock = .awake,
        } } else .none
    else
        .none;

    const result = std.process.run(allocator, io, .{
        .argv = if (run_as_module)
            if (can_block) &argv_module_can_block else &argv_module
        else if (can_block)
            &argv_script_can_block
        else
            &argv_script,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = timeout,
    }) catch |err| switch (err) {
        error.Timeout => {
            stderr_out.* = try std.fmt.bufPrint(stderr_storage, "timed out after {d}ms", .{timeout_ms.?});
            return false;
        },
        else => {
            stderr_out.* = try std.fmt.bufPrint(stderr_storage, "spawn failed: {s}", .{@errorName(err)});
            return false;
        },
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    stderr_out.* = copyStderr(stderr_storage, result.stderr);
    const exited_zero = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (exited_zero and is_async and !asyncHarnessCompleted(result.stdout)) {
        stderr_out.* = copyStderr(stderr_storage, "TypeError: $DONE() not called");
        return false;
    }
    return exited_zero;
}

fn prepareModuleTempTree(io: std.Io, temp_path: []const u8, test_path: []const u8) !void {
    const temp_dir = std.fs.path.dirname(temp_path) orelse return error.InvalidPath;
    const source_dir_path = std.fs.path.dirname(test_path) orelse ".";
    const root_basename = std.fs.path.basename(test_path);

    std.Io.Dir.cwd().deleteTree(io, temp_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, temp_dir);

    var source_dir = try std.Io.Dir.cwd().openDir(io, source_dir_path, .{ .iterate = true });
    defer source_dir.close(io);
    var it = source_dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, root_basename)) continue;
        if (std.mem.startsWith(u8, entry.name, ".zjs-module-")) continue;

        var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const target = try std.fmt.bufPrint(&target_buf, "../{s}", .{entry.name});
        var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const link_path = try std.fmt.bufPrint(&link_buf, "{s}/{s}", .{ temp_dir, entry.name });
        std.Io.Dir.cwd().symLink(io, target, link_path, .{ .is_directory = entry.kind == .directory }) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| return e,
        };
    }
}

fn copyStderr(storage: *[stderr_storage_len]u8, stderr: []const u8) []const u8 {
    const len = @min(storage.len, stderr.len);
    @memcpy(storage[0..len], stderr[0..len]);
    return storage[0..len];
}

fn printRunResult(io: std.Io, reporter: ?*Reporter, test_path: []const u8, result: TestRunResult, elapsed_ms: i64, stderr: []const u8) !void {
    const status = switch (result) {
        .passed => "PASS",
        .failed => "FAIL",
        .skipped => "SKIP",
    };
    const trimmed = std.mem.trim(u8, stderr, " \t\r\n");
    const limit = @min(trimmed.len, 240);
    const detail = trimmed[0..limit];
    if (reporter) |r| {
        if (result == .passed or detail.len == 0) {
            try r.lockedPrint(io, "{s} {s} ({d} ms)\n", .{ status, test_path, elapsed_ms });
        } else {
            try r.lockedPrint(io, "{s} {s} ({d} ms): {s}\n", .{ status, test_path, elapsed_ms, detail });
        }
        return;
    }
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const writer = &stderr_writer.interface;
    if (result == .passed or detail.len == 0) {
        try writer.print("{s} {s} ({d} ms)\n", .{ status, test_path, elapsed_ms });
    } else {
        try writer.print("{s} {s} ({d} ms): {s}\n", .{ status, test_path, elapsed_ms, detail });
    }
    try writer.flush();
}

pub fn negativeResultMatches(negative: NegativeMetadata, exited_zero: bool, stderr: []const u8) bool {
    if (exited_zero) return false;
    if (negative.type_name) |type_name| {
        if (std.mem.indexOf(u8, stderr, type_name) == null) return false;
    }
    if (negative.phase) |phase| {
        if (std.mem.eql(u8, phase, "parse")) {
            return negative.type_name != null and std.mem.eql(u8, negative.type_name.?, "SyntaxError");
        }
        if (std.mem.eql(u8, phase, "runtime") or std.mem.eql(u8, phase, "resolution")) return true;
        return false;
    }
    return true;
}

pub fn tempTestPath(buffer: []u8, test_path: []const u8, test_index: usize) ![]const u8 {
    const hash = std.hash.Wyhash.hash(test_index, test_path);
    return std.fmt.bufPrint(buffer, ".zig-cache/run-test262-{d}-{x}.js", .{ test_index, hash });
}

pub fn moduleTempTestPath(buffer: []u8, test_path: []const u8, test_index: usize) ![]const u8 {
    const hash = std.hash.Wyhash.hash(test_index, test_path);
    const dir = std.fs.path.dirname(test_path) orelse ".";
    const basename = std.fs.path.basename(test_path);
    return std.fmt.bufPrint(buffer, "{s}/.zjs-module-{d}-{d}-{x}/{s}", .{
        dir,
        getpid(),
        test_index,
        hash,
        basename,
    });
}

/// Tmpfs-backed variant used when `/dev/shm` is available. The `zjs-<pid>-`
/// prefix keeps files unique across concurrent runners and cleaned up per
/// process. Staying under `/dev/shm` keeps each test's write/unlink inside
/// memory-backed storage, which is meaningfully faster than the workspace
/// `.zig-cache/` directory on disk.
pub fn tempTestPathShm(buffer: []u8, test_path: []const u8, test_index: usize) ![]const u8 {
    const hash = std.hash.Wyhash.hash(test_index, test_path);
    return std.fmt.bufPrint(buffer, "/dev/shm/zjs-{d}-{d}-{x}.js", .{
        getpid(), test_index, hash,
    });
}

fn printFailure(io: std.Io, reporter: ?*Reporter, test_path: []const u8, stderr: []const u8) !void {
    const trimmed = std.mem.trim(u8, stderr, " \t\r\n");
    const limit = @min(trimmed.len, 240);
    const detail = trimmed[0..limit];
    if (reporter) |r| {
        if (detail.len == 0) {
            try r.lockedPrint(io, "FAIL {s}\n", .{test_path});
        } else {
            try r.lockedPrint(io, "FAIL {s}: {s}\n", .{ test_path, detail });
        }
        return;
    }
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const writer = &stderr_writer.interface;
    if (detail.len == 0) {
        try writer.print("FAIL {s}\n", .{test_path});
    } else {
        try writer.print("FAIL {s}: {s}\n", .{ test_path, detail });
    }
    try writer.flush();
}

test "test262 args parse QuickJS-shaped config and root" {
    const config = try parseArgs(&.{ "-c", "test262.conf", "-m", "-t", "1", "test262/test" });
    try std.testing.expectEqualStrings("test262.conf", config.config_path.?);
    try std.testing.expect(config.module);
    try std.testing.expectEqual(@as(u32, 1), config.threads);
    try std.testing.expectEqualStrings("test262/test", config.test_root.?);
}

test "test262 args parse timeout and verbose levels" {
    const config = try parseArgs(&.{ "-T", "100", "-vv", "-c", "test262.conf", "tests" });
    try std.testing.expectEqual(@as(?u32, 100), config.timeout_ms);
    try std.testing.expectEqual(@as(u8, 2), config.verbose);
    try std.testing.expectEqualStrings("test262.conf", config.config_path.?);
    try std.testing.expectEqualStrings("tests", config.test_root.?);
}

test "test262 args parse direct file and directory selectors" {
    const config = try parseArgs(&.{ "-d", "built-ins/Object", "-f", "language/types/null.js", "-e", "known.txt" });
    try std.testing.expectEqualStrings("built-ins/Object", config.dirs.get(0));
    try std.testing.expectEqualStrings("language/types/null.js", config.files.get(0));
    try std.testing.expectEqualStrings("known.txt", config.known_error_file.?);
}

test "test262 args parse external engine path" {
    const config = try parseArgs(&.{ "--engine", "qjs", "-c", "test262.conf", "0", "20" });
    try std.testing.expectEqualStrings("qjs", config.engine_path.?);
    try std.testing.expectEqualStrings("test262.conf", config.config_path.?);
    try std.testing.expectEqual(@as(?usize, 0), config.start_index);
    try std.testing.expectEqual(@as(?usize, 20), config.stop_index);
}

test "test262 args parse feature overrides" {
    const config = try parseArgs(&.{
        "--enable-feature", "await-dictionary",
        "--skip-feature",   "Temporal",
        "-c",               "test262.conf",
        "0",                "20",
    });
    try std.testing.expectEqual(@as(usize, 2), config.feature_overrides.len);
    try std.testing.expectEqual(FeatureOverrideKind.enable, config.feature_overrides.get(0).kind);
    try std.testing.expectEqualStrings("await-dictionary", config.feature_overrides.get(0).name);
    try std.testing.expectEqual(FeatureOverrideKind.skip, config.feature_overrides.get(1).kind);
    try std.testing.expectEqualStrings("Temporal", config.feature_overrides.get(1).name);
}

test "test262 args parse QuickJS index span" {
    const config = try parseArgs(&.{ "-c", "test262.conf", "0", "20" });
    try std.testing.expectEqual(@as(?usize, 0), config.start_index);
    try std.testing.expectEqual(@as(?usize, 20), config.stop_index);
}

test "test262 config text parses paths features and excludes relative to config" {
    var loaded = try loadConfigText(std.testing.allocator, "",
        \\[config]
        \\testdir=test262/test
        \\harnessdir=test262/harness
        \\errorfile=test262_errors.txt
        \\[features]
        \\Intl.Locale=skip
        \\Map
        \\[exclude]
        \\test262/test/intl402/
        \\! test262/test/intl402/pass/
        \\test262/test/intl402/pass/known-bad.js
    );
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("test262/test", loaded.testdir.?);
    try std.testing.expectEqualStrings("test262/harness", loaded.harnessdir.?);
    try std.testing.expectEqualStrings("test262_errors.txt", loaded.errorfile.?);
    try std.testing.expect(loaded.excludes.contains("test262/test/intl402/foo.js"));
    try std.testing.expect(loaded.reincludes.contains("test262/test/intl402/pass/foo.js"));
    try std.testing.expect(loaded.excludesTest("test262/test/intl402/fail/foo.js"));
    try std.testing.expect(!loaded.excludesTest("test262/test/intl402/pass/foo.js"));
    try std.testing.expect(loaded.excludesTest("test262/test/intl402/pass/known-bad.js"));
    try std.testing.expectEqual(@as(usize, 1), loaded.enabled_features.items.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.skipped_features.items.len);
}

test "test262 feature overrides update loaded feature lists" {
    var loaded = try loadConfigText(std.testing.allocator, "",
        \\[features]
        \\await-dictionary=skip
        \\Temporal
    );
    defer loaded.deinit(std.testing.allocator);

    var overrides = BoundedFeatureOverrides{};
    try overrides.append(.enable, "await-dictionary");
    try overrides.append(.skip, "Temporal");
    try applyFeatureOverrides(&loaded, overrides);

    try std.testing.expect(loaded.enabled_features.containsExact("await-dictionary"));
    try std.testing.expect(!loaded.skipped_features.containsExact("await-dictionary"));
    try std.testing.expect(loaded.skipped_features.containsExact("Temporal"));
    try std.testing.expect(!loaded.enabled_features.containsExact("Temporal"));
}

test "known error text parsing ignores comments and dedupes entries" {
    var known = try parseKnownErrorsText(std.testing.allocator, "",
        \\# keep only test paths
        \\test/a.js
        \\test/b.js ; trailing comment
        \\test/a.js
    );
    defer known.deinit();

    try std.testing.expectEqual(@as(usize, 2), known.items.len);
    try std.testing.expectEqualStrings("test/a.js", known.items[0]);
    try std.testing.expectEqualStrings("test/b.js", known.items[1]);
}

test "known error text parsing keeps only path segment before line marker" {
    var known = try parseKnownErrorsText(std.testing.allocator, "",
        \\test/a.js:14: SyntaxError
        \\test/b.js:7
        \\test/c.js
    );
    defer known.deinit();

    try std.testing.expectEqual(@as(usize, 3), known.items.len);
    try std.testing.expectEqualStrings("test/a.js", known.items[0]);
    try std.testing.expectEqualStrings("test/b.js", known.items[1]);
    try std.testing.expectEqualStrings("test/c.js", known.items[2]);
}

test "known error text parsing resolves entries relative to errorfile directory" {
    var known = try parseKnownErrorsText(std.testing.allocator, "",
        \\test262/test/a.js:14: SyntaxError
        \\test262/test/b.js:7: TypeError
    );
    defer known.deinit();

    try std.testing.expectEqual(@as(usize, 2), known.items.len);
    try std.testing.expectEqualStrings("test262/test/a.js", known.items[0]);
    try std.testing.expectEqualStrings("test262/test/b.js", known.items[1]);
}

test "known error renderer emits sorted unique newline-separated entries" {
    var failures = NameList.init(std.testing.allocator);
    defer failures.deinit();
    try failures.append("test/z.js");
    try failures.append("test/a.js");
    try failures.append("test/z.js");

    const text = try renderKnownErrorsText(std.testing.allocator, failures, "");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("test/a.js\ntest/z.js\n", text);
}

test "test262 natural name comparison keeps equal numeric values distinct" {
    try std.testing.expect(compareNames("test/case-2.js", "test/case-10.js") < 0);
    try std.testing.expect(compareNames("test/case-10.js", "test/case-2.js") > 0);
    try std.testing.expect(compareNames("test/case-2.js", "test/case-02.js") < 0);
    try std.testing.expect(compareNames("test/case-02.js", "test/case-002.js") < 0);
    try std.testing.expectEqual(@as(i32, 0), compareNames("test/case-02.js", "test/case-02.js"));

    var names = NameList.init(std.testing.allocator);
    defer names.deinit();
    try names.append("test/case-02.js");
    try names.append("test/case-2.js");
    try names.append("test/case-02.js");
    names.sortAndDedupe();

    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("test/case-2.js", names.items[0]);
    try std.testing.expectEqualStrings("test/case-02.js", names.items[1]);
}

test "test262 failure log renderer emits sorted lines" {
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(std.testing.allocator);

    try renderSortedFailureLog(
        std.testing.allocator,
        &rendered,
        "test262/test/z.js\tTypeError\tTypeError\n" ++
            "test262/test/a.js\tTest262Error\tTest262Error\n" ++
            "test262/test/m.js\tSyntaxError\tSyntaxError\n",
    );

    try std.testing.expectEqualStrings(
        "test262/test/a.js\tTest262Error\tTest262Error\n" ++
            "test262/test/m.js\tSyntaxError\tSyntaxError\n" ++
            "test262/test/z.js\tTypeError\tTypeError\n",
        rendered.items,
    );
}

test "known error renderer writes paths relative to errorfile directory" {
    var failures = NameList.init(std.testing.allocator);
    defer failures.deinit();
    try failures.append("test262/test/z.js");
    try failures.append("test262/test/a.js");

    const text = try renderKnownErrorsText(std.testing.allocator, failures, "");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("test262/test/a.js\ntest262/test/z.js\n", text);
}

test "known error update preserves unselected existing failures" {
    var known = NameList.init(std.testing.allocator);
    defer known.deinit();
    try known.append("test262/test/a.js");
    try known.append("test262/test/b.js");
    try known.append("test262/test/c.js");

    var selected = NameList.init(std.testing.allocator);
    defer selected.deinit();
    try selected.append("test262/test/a.js");
    try selected.append("test262/test/b.js");

    var current = NameList.init(std.testing.allocator);
    defer current.deinit();
    try current.append("test262/test/b.js");

    var merged = try mergeKnownErrorsForUpdate(std.testing.allocator, known, selected, current);
    defer merged.deinit();

    try std.testing.expectEqual(@as(usize, 2), merged.items.len);
    try std.testing.expectEqualStrings("test262/test/b.js", merged.items[0]);
    try std.testing.expectEqualStrings("test262/test/c.js", merged.items[1]);
}

test "selected known failure that now passes is counted as fixed" {
    var known = NameList.init(std.testing.allocator);
    defer known.deinit();
    try known.append("tests/fixtures/test262/harness/asyncHelpers.js");
    known.sortAndDedupe();

    var skipped = NameList.init(std.testing.allocator);
    defer skipped.deinit();

    var summary = ExecutionSummary{ .selection = .{} };
    var current = NameList.init(std.testing.allocator);
    defer current.deinit();

    var next_index: std.atomic.Value(usize) = .init(0);
    const worker_shared = WorkerShared{
        .io = std.testing.io,
        .engine_path = "zig-out/bin/zjs",
        .use_external_engine = false,
        .harnessdir = null,
        .harness_prelude = "",
        .tests = &.{"tests/fixtures/test262/harness/asyncHelpers.js"},
        .known_errors = known,
        .skipped_features = skipped,
        .next_index = &next_index,
        .verbose = 0,
        .timeout_ms = null,
        .global_module = false,
        .reporter = null,
    };
    try runWorkerLoop(
        &worker_shared,
        std.testing.allocator,
        &summary,
        &current,
    );

    try std.testing.expectEqual(@as(usize, 0), summary.passed);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    try std.testing.expectEqual(@as(usize, 1), summary.fixed);
    try std.testing.expectEqual(@as(usize, 0), current.items.len);
}

test "parallel worker errors return without rejoining finished threads" {
    var config = Config{};
    config.threads = 2;
    try config.files.append("tests/fixtures/test262/missing-worker-a.js");
    try config.files.append("tests/fixtures/test262/missing-worker-b.js");

    try std.testing.expectError(
        error.FileNotFound,
        runSelectedTestsQuiet(std.testing.allocator, std.testing.io, config, "zig-out/bin/zjs"),
    );
}

test "embedded runner reports thrown proxy constructors as test failures" {
    var stderr_storage: [stderr_storage_len]u8 = undefined;
    var stderr: []const u8 = "";
    const passed = try runEmbeddedEngine(
        std.testing.allocator,
        std.testing.io,
        "throw { constructor: new Proxy(function(){}, {}) };",
        "proxy-constructor-throw.js",
        false,
        false,
        false,
        &stderr_storage,
        &stderr,
    );

    try std.testing.expect(!passed);
    try std.testing.expect(stderr.len != 0);
}

test "async harness oracle mirrors run-test262.c $DONE accounting" {
    // Exactly one completion sentinel: pass.
    try std.testing.expect(asyncHarnessCompleted("Test262:AsyncTestComplete\n"));
    try std.testing.expect(asyncHarnessCompleted("some output\nTest262:AsyncTestComplete\n"));
    // No sentinel at all ($DONE never called): fail.
    try std.testing.expect(!asyncHarnessCompleted(""));
    try std.testing.expect(!asyncHarnessCompleted("unrelated output\n"));
    // Failure sentinel forces an error even if completion also printed.
    try std.testing.expect(!asyncHarnessCompleted("Test262:AsyncTestFailure:Test262Error: boom\n"));
    try std.testing.expect(!asyncHarnessCompleted("Test262:AsyncTestFailure:TypeError: x\nTest262:AsyncTestComplete\n"));
    // $DONE called twice: fail (counter must be exactly 1).
    try std.testing.expect(!asyncHarnessCompleted("Test262:AsyncTestComplete\nTest262:AsyncTestComplete\n"));
    // Sentinel must match the whole printed line, not a substring.
    try std.testing.expect(!asyncHarnessCompleted("Test262:AsyncTestComplete extra\n"));
}

test "embedded runner fails async test whose $DONE reports an error" {
    var stderr_storage: [stderr_storage_len]u8 = undefined;
    var stderr: []const u8 = "";
    const passed = try runEmbeddedEngine(
        std.testing.allocator,
        std.testing.io,
        "function $DONE(error){ print(error ? 'Test262:AsyncTestFailure:Test262Error: ' + String(error) : 'Test262:AsyncTestComplete'); }" ++
            "Promise.resolve().then(function(){ $DONE(new Error('boom')); });",
        "async-done-failure.js",
        false,
        false,
        true,
        &stderr_storage,
        &stderr,
    );

    try std.testing.expect(!passed);
    try std.testing.expectEqualStrings("TypeError: $DONE() not called", stderr);
}

test "embedded runner passes async test that completes via $DONE" {
    var stderr_storage: [stderr_storage_len]u8 = undefined;
    var stderr: []const u8 = "";
    const passed = try runEmbeddedEngine(
        std.testing.allocator,
        std.testing.io,
        "function $DONE(error){ print(error ? 'Test262:AsyncTestFailure:Test262Error: ' + String(error) : 'Test262:AsyncTestComplete'); }" ++
            "Promise.resolve().then(function(){ $DONE(); });",
        "async-done-pass.js",
        false,
        false,
        true,
        &stderr_storage,
        &stderr,
    );

    try std.testing.expect(passed);
}

test "embedded Debug runner executes a representative test262 harness within its native stack budget" {
    const allocator = std.testing.allocator;
    const test_path = "test262/test/language/types/null/S8.2_A1_T1.js";
    const test_source = try readTestSource(allocator, std.testing.io, test_path);
    defer allocator.free(test_source);
    var metadata = try parseMetadataText(allocator, test_source);
    defer metadata.deinit(allocator);
    const harness_prelude = try makeHarnessPrelude(allocator, std.testing.io, "test262/harness");
    defer allocator.free(harness_prelude);
    var harness_cache = HarnessCache.init(allocator, std.testing.io, "test262/harness");
    defer harness_cache.deinit();
    const source = try makeTestSourceFromBytes(allocator, &harness_cache, harness_prelude, test_source, metadata);
    defer allocator.free(source);

    var stderr_storage: [stderr_storage_len]u8 = undefined;
    var stderr: []const u8 = "";
    const passed = try runEmbeddedEngine(
        allocator,
        std.testing.io,
        source,
        test_path,
        false,
        true,
        false,
        &stderr_storage,
        &stderr,
    );

    try std.testing.expectEqualStrings("", stderr);
    try std.testing.expect(passed);
}

test "test262 metadata parses includes in order plus features flags and negative data" {
    var metadata = try parseMetadataText(std.testing.allocator,
        \\/*---
        \\description: metadata fixture
        \\includes: [propertyHelper.js, compareArray.js, propertyHelper.js]
        \\features: [Symbol, BigInt]
        \\flags: [onlyStrict, module]
        \\negative:
        \\  phase: runtime
        \\  type: TypeError
        \\---*/
        \\throw new TypeError();
    );
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), metadata.includes.items.len);
    try std.testing.expectEqualStrings("propertyHelper.js", metadata.includes.items[0]);
    try std.testing.expectEqualStrings("compareArray.js", metadata.includes.items[1]);
    try std.testing.expect(metadata.features.contains("Symbol"));
    try std.testing.expect(metadata.features.contains("BigInt"));
    try std.testing.expect(metadata.flags.contains("onlyStrict"));
    try std.testing.expect(metadata.flags.contains("module"));
    try std.testing.expectEqualStrings("runtime", metadata.negative.?.phase.?);
    try std.testing.expectEqualStrings("TypeError", metadata.negative.?.type_name.?);
}

test "test262 metadata parses block list includes features and flags" {
    var metadata = try parseMetadataText(std.testing.allocator,
        \\/*---
        \\description: block list metadata fixture
        \\includes:
        \\  - propertyHelper.js
        \\  - compareArray.js
        \\features:
        \\  - Symbol
        \\  - BigInt
        \\flags:
        \\  - onlyStrict
        \\  - module
        \\---*/
    );
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), metadata.includes.items.len);
    try std.testing.expectEqualStrings("propertyHelper.js", metadata.includes.items[0]);
    try std.testing.expectEqualStrings("compareArray.js", metadata.includes.items[1]);
    try std.testing.expect(metadata.features.contains("Symbol"));
    try std.testing.expect(metadata.features.contains("BigInt"));
    try std.testing.expect(metadata.flags.contains("onlyStrict"));
    try std.testing.expect(metadata.flags.contains("module"));
}

test "test262 metadata parses CR-only line endings" {
    var metadata = try parseMetadataText(
        std.testing.allocator,
        "/*---\rdescription: metadata fixture\rincludes: [nativeFunctionMatcher.js]\rflags: [onlyStrict]\r---*/\r",
    );
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), metadata.includes.items.len);
    try std.testing.expectEqualStrings("nativeFunctionMatcher.js", metadata.includes.items[0]);
    try std.testing.expect(metadata.flags.contains("onlyStrict"));
}

test "test262 async metadata injects $DONE harness" {
    var metadata = try parseMetadataText(std.testing.allocator,
        \\/*---
        \\flags: [async, module]
        \\---*/
        \\$DONE();
    );
    defer metadata.deinit(std.testing.allocator);

    var harness_cache = HarnessCache.init(std.testing.allocator, std.testing.io, "tests/fixtures/test262/harness");
    defer harness_cache.deinit();

    const source = try makeTestSourceFromBytes(
        std.testing.allocator,
        &harness_cache,
        "",
        \\/*---
        \\flags: [async, module]
        \\---*/
        \\$DONE();
    ,
        metadata,
    );
    defer std.testing.allocator.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "function $DONE(error)") != null);
}

test "test262 asyncTest source does not inject $DONE harness without async flag" {
    var metadata = try parseMetadataText(std.testing.allocator,
        \\/*---
        \\includes: [asyncHelpers.js]
        \\features: [await-dictionary]
        \\---*/
        \\asyncTest(function() { return Promise.resolve(); });
    );
    defer metadata.deinit(std.testing.allocator);

    var harness_cache = HarnessCache.init(std.testing.allocator, std.testing.io, "tests/fixtures/test262/harness");
    defer harness_cache.deinit();

    const source = try makeTestSourceFromBytes(
        std.testing.allocator,
        &harness_cache,
        "",
        \\/*---
        \\includes: [asyncHelpers.js]
        \\features: [await-dictionary]
        \\---*/
        \\asyncTest (function() { return Promise.resolve(); });
    ,
        metadata,
    );
    defer std.testing.allocator.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "function $DONE(error)") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "function asyncTest(testFunc)") != null);
}

test "test262 typed array iterator staging source parses after installing globals" {
    const allocator = std.testing.allocator;
    var metadata = TestMetadata.init(allocator);
    defer metadata.deinit(allocator);
    try metadata.includes.appendOwned(try allocator.dupe(u8, "sm/non262-TypedArray-shell.js"));
    try metadata.includes.appendOwned(try allocator.dupe(u8, "deepEqual.js"));

    const harness_prelude = try makeHarnessPrelude(allocator, std.testing.io, "test262/harness");
    defer allocator.free(harness_prelude);
    var harness_cache = HarnessCache.init(allocator, std.testing.io, "test262/harness");
    defer harness_cache.deinit();
    const test_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test262/test/staging/sm/TypedArray/entries.js", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(test_source);
    const source = try makeTestSourceFromBytes(allocator, &harness_cache, harness_prelude, test_source, metadata);
    defer allocator.free(source);

    {
        const rt = try zjs.JSRuntime.create(allocator);
        defer rt.destroy();
        rt.setNativeStackSize(core_runtime.default_native_stack_size * 4);
        const ctx = try zjs.JSContext.create(rt);
        defer ctx.destroy();
        _ = try ctx.globalObject();
        var parsed = try parser.compile(.{ .realm = ctx.core }, source, .{
            .mode = .script,
            .filename = "<eval>",
            .return_completion = true,
        });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error == null);
    }

    {
        const rt = try zjs.JSRuntime.create(allocator);
        defer rt.destroy();
        rt.setNativeStackSize(core_runtime.default_native_stack_size * 4);
        const ctx = try zjs.JSContext.create(rt);
        defer ctx.destroy();
        const global = try ctx.globalObject();
        try installTest262Globals(rt, ctx, global);
        var parsed = try parser.compile(.{ .realm = ctx.core }, source, .{
            .mode = .script,
            .filename = "<eval>",
            .return_completion = true,
        });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error == null);
    }
}

test "test262 negative result matching requires expected type when present" {
    const runtime_type = NegativeMetadata{
        .phase = "runtime",
        .type_name = "TypeError",
    };
    try std.testing.expect(negativeResultMatches(runtime_type, false, "TypeError: bad value"));
    try std.testing.expect(!negativeResultMatches(runtime_type, false, "SyntaxError: bad syntax"));
    try std.testing.expect(!negativeResultMatches(runtime_type, true, ""));

    const parse_type = NegativeMetadata{
        .phase = "parse",
        .type_name = "SyntaxError",
    };
    try std.testing.expect(negativeResultMatches(parse_type, false, "SyntaxError: unexpected token"));
    try std.testing.expect(!negativeResultMatches(parse_type, false, "TypeError: wrong phase"));
}

test "test262 metadata detects skipped config features" {
    var metadata = try parseMetadataText(std.testing.allocator,
        \\/*---
        \\features: [Intl.Locale, ArrayBuffer]
        \\---*/
    );
    defer metadata.deinit(std.testing.allocator);

    var skipped = NameList.init(std.testing.allocator);
    defer skipped.deinit();
    try skipped.append("Intl.Locale");

    try std.testing.expect(metadata.hasSkippedFeature(skipped));
    try std.testing.expectEqualStrings("Intl.Locale", metadata.skippedFeature(skipped).?);
}

test "test262 skipped feature report renders sorted counts" {
    const entries = [_]Reporter.SkippedFeatureEntry{
        .{ .feature = "Temporal", .skipped = 2 },
        .{ .feature = "Zeta", .skipped = 3 },
        .{ .feature = "Intl.Locale", .skipped = 3 },
    };
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(std.testing.allocator);

    try renderSkippedFeaturesJson(std.testing.allocator, &json, &entries);

    try std.testing.expectEqualStrings(
        "{\n" ++
            "  \"total_skipped\": 8,\n" ++
            "  \"features\": [\n" ++
            "    { \"feature\": \"Intl.Locale\", \"skipped\": 3 },\n" ++
            "    { \"feature\": \"Zeta\", \"skipped\": 3 },\n" ++
            "    { \"feature\": \"Temporal\", \"skipped\": 2 }\n" ++
            "  ]\n" ++
            "}\n",
        json.items,
    );
}

test "test262 override path maps only manifest entries" {
    const mapped = try test262OverridePath(std.testing.allocator, test262_override_manifest[0].path);
    defer std.testing.allocator.free(mapped);
    try std.testing.expectEqualStrings("tests/fixtures/test262-overrides/test/built-ins/TypedArray/prototype/slice/speciesctor-return-same-buffer-with-offset.js", mapped);
    const upstream = try test262UpstreamPath(std.testing.allocator, test262_override_manifest[0].path);
    defer std.testing.allocator.free(upstream);
    try std.testing.expectEqualStrings("test262/test/built-ins/TypedArray/prototype/slice/speciesctor-return-same-buffer-with-offset.js", upstream);

    try std.testing.expect(test262Override("test262/test/example.js") == null);
    try std.testing.expect(test262Override("quickjs/test262/test/built-ins/TypedArray/prototype/slice/speciesctor-return-same-buffer-with-offset.js") == null);
    try std.testing.expect(test262Override("tests/fixtures/test262/harness/asyncHelpers.js") == null);
}

test "test262 timeout threshold does not classify passing tests as failure" {
    const config = try parseArgs(&.{ "-T", "0", "-f", "tests/fixtures/test262/harness/asyncHelpers.js" });
    var summary = try runSelectedTestsQuiet(std.testing.allocator, std.testing.io, config, "zig-out/bin/zjs");
    defer summary.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    try std.testing.expectEqual(@as(usize, 1), summary.passed);
    try std.testing.expectEqual(@as(usize, 0), summary.known_failures);
}

test "test262 temp paths are stable and unique per selected test" {
    var first_buf: [128]u8 = undefined;
    var second_buf: [128]u8 = undefined;
    const first = try tempTestPath(&first_buf, "test/a.js", 0);
    const second = try tempTestPath(&second_buf, "test/a.js", 1);

    try std.testing.expect(std.mem.startsWith(u8, first, ".zig-cache/run-test262-0-"));
    try std.testing.expect(std.mem.startsWith(u8, second, ".zig-cache/run-test262-1-"));
    try std.testing.expect(!std.mem.eql(u8, first, second));
}

test "test262 module temp path stays beside selected test" {
    var buffer: [256]u8 = undefined;
    const path = try moduleTempTestPath(&buffer, "test/built-ins/Proxy/module.js", 7);

    try std.testing.expect(std.mem.startsWith(u8, path, "test/built-ins/Proxy/.zjs-module-"));
    try std.testing.expect(std.mem.endsWith(u8, path, ".js"));
}

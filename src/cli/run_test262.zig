const std = @import("std");
const test262_root = @import("zjs");
const zjs = test262_root.binding_root;
const runtime_layer = test262_root.runtime;
const parser = test262_root.parser;
const unicode = test262_root.libs.unicode;
const core_runtime = test262_root.core.runtime;

extern "c" fn getpid() c_int;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try argsToSlice(arena, init.minimal.args);

    var config = parseArgs(args[1..]) catch |err| {
        try printError(io, "run-test262: {s}\n", .{@errorName(err)});
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
        try printError(io, "run-test262: unable to run tests: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer summary.deinit(init.gpa);

    dumpHostDispatchStats(init.environ_map);
    try printSummary(io, summary);
    const baseline_gate = config.regression_baseline != null;
    const has_unexpected = !baseline_gate and (summary.failed != 0 or summary.fixed != 0);
    const has_regression = summary.regressions != 0;
    std.process.exit(if (has_unexpected or has_regression) 1 else 0);
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

fn argsToSlice(arena: std.mem.Allocator, args: std.process.Args) ![]const []const u8 {
    const raw_args = try args.toSlice(arena);
    const result = try arena.alloc([]const u8, raw_args.len);
    for (raw_args, 0..) |arg, i| result[i] = arg;
    return result;
}

fn printUsage(io: std.Io) !void {
    try printError(
        io,
        "usage: run-test262 -c <test262.conf> [options] [test-root] [start [stop]]\n" ++
            "  -d <dir>                 add a test directory selector\n" ++
            "  -f <file>                add a single test file selector\n" ++
            "  -e <file>                use a known-errors file\n" ++
            "  -u                       update the known-errors file from failures\n" ++
            "  -m                       run selected tests as modules\n" ++
            "  -t <n>                   run up to <n> tests in parallel\n" ++
            "  -T <ms>                  per-test timeout in milliseconds\n" ++
            "  -R <dir>                 emit test262-failures.log, test262-buckets.json,\n" ++
            "                           test262-by-dir.json, and\n" ++
            "                           test262-skipped-features.json under <dir>\n" ++
            "  --engine <path>          run prepared tests with an external qjs-compatible\n" ++
            "                           binary instead of the embedded zjs engine\n" ++
            "  --regression-baseline F  exit non-zero if any directory's `passed`\n" ++
            "                           count is lower than F (a previous by-dir.json)\n" ++
            "  --enable-feature <name> temporarily enable a config-skipped feature\n" ++
            "  --skip-feature <name>   temporarily skip a config-enabled feature\n",
        .{},
    );
}

fn printError(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    try stderr.print(fmt, args);
    try stderr.flush();
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
    if (summary.regressions != 0) try stdout.print(", regressed {d}", .{summary.regressions});
    try stdout.print("\n", .{});
    try stdout.flush();
}

const batch_worker_restart_interval = 256;
const stderr_storage_len = 2048;

pub const RunnerArgsError = error{
    Usage,
    MissingValue,
    TooManyItems,
};

pub const RunnerError = error{
    ConfigParse,
};

pub const NegativeMetadata = struct {
    phase: ?[]const u8 = null,
    type_name: ?[]const u8 = null,

    pub fn deinit(self: *NegativeMetadata, allocator: std.mem.Allocator) void {
        if (self.phase) |value| allocator.free(value);
        if (self.type_name) |value| allocator.free(value);
    }
};

pub const TestMetadata = struct {
    includes: NameList,
    features: NameList,
    flags: NameList,
    negative: ?NegativeMetadata = null,

    pub fn init(allocator: std.mem.Allocator) TestMetadata {
        return .{
            .includes = NameList.init(allocator),
            .features = NameList.init(allocator),
            .flags = NameList.init(allocator),
        };
    }

    pub fn deinit(self: *TestMetadata, allocator: std.mem.Allocator) void {
        self.includes.deinit();
        self.features.deinit();
        self.flags.deinit();
        if (self.negative) |*negative| negative.deinit(allocator);
    }

    pub fn hasSkippedFeature(self: TestMetadata, skipped_features: NameList) bool {
        return self.skippedFeature(skipped_features) != null;
    }

    pub fn skippedFeature(self: TestMetadata, skipped_features: NameList) ?[]const u8 {
        for (self.features.items) |feature| {
            if (skipped_features.contains(feature)) return feature;
        }
        return null;
    }

    pub fn hasFlag(self: TestMetadata, name: []const u8) bool {
        for (self.flags.items) |flag| {
            if (std.mem.eql(u8, flag, name)) return true;
        }
        return false;
    }
};

pub const Config = struct {
    config_path: ?[]const u8 = null,
    test_root: ?[]const u8 = null,
    module: bool = false,
    verbose: u8 = 0,
    update_errors: bool = false,
    timeout_ms: ?u32 = null,
    /// Zero means "auto-detect" (CPU count). Any explicit positive value
    /// supplied with `-t` is used verbatim.
    threads: u32 = 0,
    known_error_file: ?[]const u8 = null,
    reports_dir: ?[]const u8 = null,
    /// Optional external qjs-compatible executable. When null, the runner uses
    /// the embedded Zig engine, preserving existing test262 behavior.
    engine_path: ?[]const u8 = null,
    /// Path to a previously committed `test262-by-dir.json` snapshot.
    /// When set, after the run completes `runSelectedTests` compares
    /// per-directory `passed` counts against the baseline; if any
    /// directory's passed count drops, the run records the regression
    /// and the CLI exits non-zero. This is the standing anti-regression
    /// gate for the current test262-driven workflow.
    regression_baseline: ?[]const u8 = null,
    feature_overrides: BoundedFeatureOverrides = .{},
    start_index: ?usize = null,
    stop_index: ?usize = null,
    files: BoundedList = .{},
    dirs: BoundedList = .{},

    pub fn selectedCount(self: Config) usize {
        return self.files.len + self.dirs.len + @as(usize, if (self.test_root != null) 1 else 0);
    }
};

pub const FeatureOverrideKind = enum {
    enable,
    skip,
};

pub const FeatureOverride = struct {
    kind: FeatureOverrideKind,
    name: []const u8,
};

pub const BoundedFeatureOverrides = struct {
    items: [64]FeatureOverride = undefined,
    len: usize = 0,

    pub fn append(self: *BoundedFeatureOverrides, kind: FeatureOverrideKind, name: []const u8) RunnerArgsError!void {
        if (self.len == self.items.len) return error.TooManyItems;
        self.items[self.len] = .{ .kind = kind, .name = name };
        self.len += 1;
    }

    pub fn get(self: BoundedFeatureOverrides, index: usize) FeatureOverride {
        return self.items[index];
    }
};

pub const BoundedList = struct {
    items: [64][]const u8 = undefined,
    len: usize = 0,

    pub fn append(self: *BoundedList, item: []const u8) RunnerArgsError!void {
        if (self.len == self.items.len) return error.TooManyItems;
        self.items[self.len] = item;
        self.len += 1;
    }

    pub fn get(self: BoundedList, index: usize) []const u8 {
        return self.items[index];
    }
};

pub fn parseArgs(args: []const []const u8) RunnerArgsError!Config {
    var config = Config{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-c")) {
            config.config_path = try nextValue(args, &i);
        } else if (std.mem.eql(u8, arg, "-d")) {
            try config.dirs.append(try nextValue(args, &i));
        } else if (std.mem.eql(u8, arg, "-f")) {
            try config.files.append(try nextValue(args, &i));
        } else if (std.mem.eql(u8, arg, "-e")) {
            config.known_error_file = try nextValue(args, &i);
        } else if (std.mem.eql(u8, arg, "-u")) {
            config.update_errors = true;
        } else if (std.mem.eql(u8, arg, "-m")) {
            config.module = true;
        } else if (std.mem.eql(u8, arg, "-v")) {
            config.verbose = @max(config.verbose, 1);
        } else if (std.mem.eql(u8, arg, "-vv")) {
            config.verbose = 2;
        } else if (std.mem.eql(u8, arg, "-T")) {
            config.timeout_ms = try parseU32(try nextValue(args, &i));
        } else if (std.mem.eql(u8, arg, "-t")) {
            config.threads = try parseU32(try nextValue(args, &i));
        } else if (std.mem.eql(u8, arg, "-R")) {
            config.reports_dir = try nextValue(args, &i);
        } else if (std.mem.eql(u8, arg, "--engine")) {
            config.engine_path = try nextValue(args, &i);
        } else if (std.mem.eql(u8, arg, "--regression-baseline")) {
            config.regression_baseline = try nextValue(args, &i);
        } else if (std.mem.eql(u8, arg, "--enable-feature")) {
            try config.feature_overrides.append(.enable, try nextValue(args, &i));
        } else if (std.mem.eql(u8, arg, "--skip-feature")) {
            try config.feature_overrides.append(.skip, try nextValue(args, &i));
        } else if (arg.len != 0 and arg[0] == '-') {
            return error.Usage;
        } else if (isDecimal(arg)) {
            const index = try parseUsize(arg);
            if (config.start_index == null) {
                config.start_index = index;
            } else if (config.stop_index == null) {
                config.stop_index = index;
            } else {
                return error.Usage;
            }
        } else if (config.test_root == null) {
            config.test_root = arg;
        } else {
            return error.Usage;
        }
    }
    if (config.config_path == null and config.selectedCount() == 0) return error.Usage;
    return config;
}

fn nextValue(args: []const []const u8, index: *usize) RunnerArgsError![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.MissingValue;
    return args[index.*];
}

fn parseU32(bytes: []const u8) RunnerArgsError!u32 {
    return std.fmt.parseInt(u32, bytes, 10) catch error.Usage;
}

fn parseUsize(bytes: []const u8) RunnerArgsError!usize {
    return std.fmt.parseInt(usize, bytes, 10) catch error.Usage;
}

fn isDecimal(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |byte| {
        if (byte < '0' or byte > '9') return false;
    }
    return true;
}

pub const LoadedConfig = struct {
    testdir: ?[]const u8 = null,
    harnessdir: ?[]const u8 = null,
    errorfile: ?[]const u8 = null,
    excludes: NameList,
    reincludes: NameList,
    enabled_features: NameList,
    skipped_features: NameList,

    pub fn init(allocator: std.mem.Allocator) LoadedConfig {
        return .{
            .excludes = NameList.init(allocator),
            .reincludes = NameList.init(allocator),
            .enabled_features = NameList.init(allocator),
            .skipped_features = NameList.init(allocator),
        };
    }

    pub fn deinit(self: *LoadedConfig, allocator: std.mem.Allocator) void {
        if (self.testdir) |value| allocator.free(value);
        if (self.harnessdir) |value| allocator.free(value);
        if (self.errorfile) |value| allocator.free(value);
        self.excludes.deinit();
        self.reincludes.deinit();
        self.enabled_features.deinit();
        self.skipped_features.deinit();
    }

    fn excludesTest(self: LoadedConfig, path: []const u8) bool {
        const exclude_len = self.excludes.bestMatchLen(path) orelse return false;
        const reinclude_len = self.reincludes.bestMatchLen(path) orelse return true;
        return exclude_len > reinclude_len;
    }
};

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
    /// Count of directories whose pass rate regressed against the
    /// baseline supplied via `--regression-baseline`. Zero when the
    /// flag is not used or no regressions were detected.
    regressions: usize = 0,

    pub fn deinit(self: *ExecutionSummary, allocator: std.mem.Allocator) void {
        self.selection.deinit(allocator);
    }
};

pub const TestRunResult = enum { passed, failed, skipped };

/// Centralised stderr serialisation, failure-bucket aggregation, and
/// per-directory summary for `run-test262`. Always created by
/// `runSelectedTests`; `reports_dir` controls whether JSON reports are
/// emitted to disk on `flush`. The mutex serialises concurrent worker
/// writes to stderr (F0.3) and protects the failure aggregations (F0.1).
pub const Reporter = struct {
    pub const Bucket = enum {
        syntax_error,
        type_error,
        test262_error,
        range_error,
        reference_error,
        unhandled_promise_rejection,
        other,
        empty,

        pub fn name(self: Bucket) []const u8 {
            return switch (self) {
                .syntax_error => "SyntaxError",
                .type_error => "TypeError",
                .test262_error => "Test262Error",
                .range_error => "RangeError",
                .reference_error => "ReferenceError",
                .unhandled_promise_rejection => "UnhandledPromiseRejection",
                .other => "Other",
                .empty => "Empty",
            };
        }
    };

    pub const DirEntry = struct {
        dir: []const u8,
        passed: usize = 0,
        failed: usize = 0,
        known_failed: usize = 0,
    };

    pub const SkippedFeatureEntry = struct {
        feature: []const u8,
        skipped: usize = 0,
    };

    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    reports_dir: ?[]const u8,
    quiet: bool = false,
    failure_log: std.ArrayList(u8) = .empty,
    buckets: [@typeInfo(Bucket).@"enum".fields.len]usize = @splat(0),
    by_dir: std.ArrayList(DirEntry) = .empty,
    skipped_by_feature: std.ArrayList(SkippedFeatureEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator, reports_dir: ?[]const u8) Reporter {
        return .{ .allocator = allocator, .reports_dir = reports_dir };
    }

    pub fn initQuiet(allocator: std.mem.Allocator, reports_dir: ?[]const u8) Reporter {
        return .{ .allocator = allocator, .reports_dir = reports_dir, .quiet = true };
    }

    pub fn deinit(self: *Reporter) void {
        self.failure_log.deinit(self.allocator);
        for (self.by_dir.items) |entry| self.allocator.free(entry.dir);
        self.by_dir.deinit(self.allocator);
        for (self.skipped_by_feature.items) |entry| self.allocator.free(entry.feature);
        self.skipped_by_feature.deinit(self.allocator);
    }

    /// Lock-protected stderr line emission. All runner-side stderr output
    /// must go through this so multi-threaded runs do not interleave
    /// fragments.
    pub fn lockedPrint(self: *Reporter, io: std.Io, comptime fmt: []const u8, args: anytype) !void {
        if (self.quiet) return;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var stderr_buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
        const writer = &stderr_writer.interface;
        try writer.print(fmt, args);
        try writer.flush();
    }

    pub fn recordResult(
        self: *Reporter,
        io: std.Io,
        test_path: []const u8,
        result: TestRunResult,
        stderr_text: []const u8,
        is_known: bool,
    ) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const dir = deriveDirSegment(test_path);
        const entry = try self.findOrInsertDir(dir);
        switch (result) {
            .passed => entry.passed += 1,
            .failed => {
                if (is_known) entry.known_failed += 1 else entry.failed += 1;
                const bucket = classifyBucket(stderr_text);
                self.buckets[@intFromEnum(bucket)] += 1;
                try self.appendFailureLine(test_path, bucket, stderr_text);
            },
            .skipped => {},
        }
    }

    pub fn recordSkippedFeature(self: *Reporter, io: std.Io, feature: []const u8) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const entry = try self.findOrInsertSkippedFeature(feature);
        entry.skipped += 1;
    }

    fn findOrInsertDir(self: *Reporter, dir: []const u8) !*DirEntry {
        for (self.by_dir.items) |*existing| {
            if (std.mem.eql(u8, existing.dir, dir)) return existing;
        }
        const owned = try self.allocator.dupe(u8, dir);
        errdefer self.allocator.free(owned);
        try self.by_dir.append(self.allocator, .{ .dir = owned });
        return &self.by_dir.items[self.by_dir.items.len - 1];
    }

    fn findOrInsertSkippedFeature(self: *Reporter, feature: []const u8) !*SkippedFeatureEntry {
        for (self.skipped_by_feature.items) |*existing| {
            if (std.mem.eql(u8, existing.feature, feature)) return existing;
        }
        const owned = try self.allocator.dupe(u8, feature);
        errdefer self.allocator.free(owned);
        try self.skipped_by_feature.append(self.allocator, .{ .feature = owned });
        return &self.skipped_by_feature.items[self.skipped_by_feature.items.len - 1];
    }

    fn appendFailureLine(
        self: *Reporter,
        test_path: []const u8,
        bucket: Bucket,
        stderr_text: []const u8,
    ) !void {
        const trimmed = std.mem.trim(u8, stderr_text, " \t\r\n");
        const limit = @min(trimmed.len, 240);
        try self.failure_log.print(self.allocator, "{s}\t{s}\t", .{ test_path, bucket.name() });
        // sanitise newlines/tabs out of the captured stderr fragment.
        for (trimmed[0..limit]) |byte| {
            const safe: u8 = switch (byte) {
                '\n', '\r', '\t' => ' ',
                else => byte,
            };
            try self.failure_log.append(self.allocator, safe);
        }
        try self.failure_log.append(self.allocator, '\n');
    }

    pub fn flush(self: *Reporter, io: std.Io) !void {
        const dir = self.reports_dir orelse return;
        try std.Io.Dir.cwd().createDirPath(io, dir);

        var sorted_failure_log: std.ArrayList(u8) = .empty;
        defer sorted_failure_log.deinit(self.allocator);
        try renderSortedFailureLog(self.allocator, &sorted_failure_log, self.failure_log.items);
        const log_path = try std.fs.path.join(self.allocator, &.{ dir, "test262-failures.log" });
        defer self.allocator.free(log_path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = log_path, .data = sorted_failure_log.items });

        var buckets_json: std.ArrayList(u8) = .empty;
        defer buckets_json.deinit(self.allocator);
        try renderBucketsJson(self.allocator, &buckets_json, &self.buckets);
        const buckets_path = try std.fs.path.join(self.allocator, &.{ dir, "test262-buckets.json" });
        defer self.allocator.free(buckets_path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = buckets_path, .data = buckets_json.items });

        var by_dir_json: std.ArrayList(u8) = .empty;
        defer by_dir_json.deinit(self.allocator);
        try renderByDirJson(self.allocator, &by_dir_json, self.by_dir.items);
        const by_dir_path = try std.fs.path.join(self.allocator, &.{ dir, "test262-by-dir.json" });
        defer self.allocator.free(by_dir_path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = by_dir_path, .data = by_dir_json.items });

        var skipped_features_json: std.ArrayList(u8) = .empty;
        defer skipped_features_json.deinit(self.allocator);
        try renderSkippedFeaturesJson(self.allocator, &skipped_features_json, self.skipped_by_feature.items);
        const skipped_features_path = try std.fs.path.join(self.allocator, &.{ dir, "test262-skipped-features.json" });
        defer self.allocator.free(skipped_features_path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = skipped_features_path, .data = skipped_features_json.items });
    }
};

pub fn classifyBucket(stderr_text: []const u8) Reporter.Bucket {
    const trimmed = std.mem.trim(u8, stderr_text, " \t\r\n");
    if (trimmed.len == 0) return .empty;
    if (std.mem.indexOf(u8, trimmed, "unhandled promise rejection") != null) return .unhandled_promise_rejection;
    if (std.mem.indexOf(u8, trimmed, "Test262Error") != null) return .test262_error;
    if (std.mem.indexOf(u8, trimmed, "SyntaxError") != null) return .syntax_error;
    if (std.mem.indexOf(u8, trimmed, "TypeError") != null) return .type_error;
    if (std.mem.indexOf(u8, trimmed, "RangeError") != null) return .range_error;
    if (std.mem.indexOf(u8, trimmed, "ReferenceError") != null) return .reference_error;
    return .other;
}

/// Returns the `language/<dir>` or `built-ins/<dir>` segment derived from
/// `test_path` (or the first one or two path components when the
/// `/test/` marker is absent). The returned slice points into `test_path`
/// and is valid only as long as that buffer lives.
pub fn deriveDirSegment(test_path: []const u8) []const u8 {
    const marker = "/test/";
    const start: usize = if (std.mem.indexOf(u8, test_path, marker)) |idx| idx + marker.len else 0;
    const tail = test_path[start..];
    return firstTwoComponents(tail);
}

fn firstTwoComponents(path: []const u8) []const u8 {
    const first = std.mem.indexOfScalar(u8, path, '/') orelse return path;
    const after = path[first + 1 ..];
    const second = std.mem.indexOfScalar(u8, after, '/') orelse return path[0 .. first + 1 + after.len];
    return path[0 .. first + 1 + second];
}

fn renderBucketsJson(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    counts: *const [@typeInfo(Reporter.Bucket).@"enum".fields.len]usize,
) !void {
    var total: usize = 0;
    for (counts) |c| total += c;
    try buffer.print(allocator, "{{\n  \"total_failed\": {d},\n  \"buckets\": {{\n", .{total});
    inline for (@typeInfo(Reporter.Bucket).@"enum".fields, 0..) |field, i| {
        const tag: Reporter.Bucket = @enumFromInt(field.value);
        const sep = if (i == @typeInfo(Reporter.Bucket).@"enum".fields.len - 1) "" else ",";
        try buffer.print(allocator, "    \"{s}\": {d}{s}\n", .{ tag.name(), counts[i], sep });
    }
    try buffer.appendSlice(allocator, "  }\n}\n");
}

fn renderSortedFailureLog(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    failure_log: []const u8,
) !void {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, failure_log, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        try lines.append(allocator, line);
    }

    std.mem.sort([]const u8, lines.items, {}, lessThanFailureLogLine);
    for (lines.items) |line| {
        try buffer.appendSlice(allocator, line);
        try buffer.append(allocator, '\n');
    }
}

fn renderByDirJson(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    entries_in: []const Reporter.DirEntry,
) !void {
    const sorted = try allocator.dupe(Reporter.DirEntry, entries_in);
    defer allocator.free(sorted);
    std.mem.sort(Reporter.DirEntry, sorted, {}, lessThanDirEntry);

    try buffer.appendSlice(allocator, "[\n");
    for (sorted, 0..) |entry, i| {
        const sep = if (i == sorted.len - 1) "" else ",";
        try buffer.print(
            allocator,
            "  {{ \"dir\": \"{s}\", \"passed\": {d}, \"failed\": {d}, \"known_failed\": {d} }}{s}\n",
            .{ entry.dir, entry.passed, entry.failed, entry.known_failed, sep },
        );
    }
    try buffer.appendSlice(allocator, "]\n");
}

fn renderSkippedFeaturesJson(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    entries_in: []const Reporter.SkippedFeatureEntry,
) !void {
    const sorted = try allocator.dupe(Reporter.SkippedFeatureEntry, entries_in);
    defer allocator.free(sorted);
    std.mem.sort(Reporter.SkippedFeatureEntry, sorted, {}, lessThanSkippedFeatureEntry);

    var total: usize = 0;
    for (sorted) |entry| total += entry.skipped;

    try buffer.print(allocator, "{{\n  \"total_skipped\": {d},\n  \"features\": [\n", .{total});
    for (sorted, 0..) |entry, i| {
        const sep = if (i == sorted.len - 1) "" else ",";
        try buffer.print(
            allocator,
            "    {{ \"feature\": \"{s}\", \"skipped\": {d} }}{s}\n",
            .{ entry.feature, entry.skipped, sep },
        );
    }
    try buffer.appendSlice(allocator, "  ]\n}\n");
}

fn lessThanDirEntry(_: void, lhs: Reporter.DirEntry, rhs: Reporter.DirEntry) bool {
    return std.mem.lessThan(u8, lhs.dir, rhs.dir);
}

fn lessThanSkippedFeatureEntry(_: void, lhs: Reporter.SkippedFeatureEntry, rhs: Reporter.SkippedFeatureEntry) bool {
    if (lhs.skipped != rhs.skipped) return lhs.skipped > rhs.skipped;
    return std.mem.lessThan(u8, lhs.feature, rhs.feature);
}

fn lessThanFailureLogLine(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

/// Anti-regression baseline machinery (CC-1 / plan §4).
///
/// `BaselineEntry` is the subset of `Reporter.DirEntry` we actually need
/// for the regression check — only the directory path and the passed
/// count. Failure / known_failed columns are ignored on purpose: the
/// gate only fires when `passed` decreases (i.e. a real regression).
pub const BaselineEntry = struct {
    dir: []const u8,
    passed: usize,
};

/// Parse a `test262-by-dir.json` snapshot in the format produced by
/// `renderByDirJson`. Returns owned slice of entries; caller frees with
/// `freeBaseline`. The parser is intentionally tight to that shape
/// (one entry per non-bracket line) — no attempt is made to handle
/// arbitrary JSON.
pub fn parseBaseline(allocator: std.mem.Allocator, bytes: []const u8) ![]BaselineEntry {
    var list: std.ArrayList(BaselineEntry) = .empty;
    errdefer freeBaselineList(allocator, &list);

    var line_iter = std.mem.splitScalar(u8, bytes, '\n');
    while (line_iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] != '{') continue; // skip the bracket lines
        const dir_value = try extractJsonStringField(line, "dir");
        const passed_value = try extractJsonNumberField(line, "passed");
        const dir_owned = try allocator.dupe(u8, dir_value);
        errdefer allocator.free(dir_owned);
        try list.append(allocator, .{ .dir = dir_owned, .passed = passed_value });
    }
    return list.toOwnedSlice(allocator);
}

pub fn freeBaseline(allocator: std.mem.Allocator, entries: []BaselineEntry) void {
    for (entries) |entry| allocator.free(entry.dir);
    allocator.free(entries);
}

fn freeBaselineList(allocator: std.mem.Allocator, list: *std.ArrayList(BaselineEntry)) void {
    for (list.items) |entry| allocator.free(entry.dir);
    list.deinit(allocator);
}

fn extractJsonStringField(line: []const u8, field: []const u8) ![]const u8 {
    var name_buf: [64]u8 = undefined;
    if (field.len + 3 > name_buf.len) return error.InvalidBaseline;
    name_buf[0] = '"';
    @memcpy(name_buf[1 .. 1 + field.len], field);
    name_buf[1 + field.len] = '"';
    name_buf[2 + field.len] = ':';
    const needle = name_buf[0 .. field.len + 3];
    const idx = std.mem.indexOf(u8, line, needle) orelse return error.InvalidBaseline;
    var pos = idx + needle.len;
    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;
    if (pos >= line.len or line[pos] != '"') return error.InvalidBaseline;
    pos += 1;
    const start = pos;
    while (pos < line.len and line[pos] != '"') pos += 1;
    if (pos >= line.len) return error.InvalidBaseline;
    return line[start..pos];
}

fn extractJsonNumberField(line: []const u8, field: []const u8) !usize {
    var name_buf: [64]u8 = undefined;
    if (field.len + 3 > name_buf.len) return error.InvalidBaseline;
    name_buf[0] = '"';
    @memcpy(name_buf[1 .. 1 + field.len], field);
    name_buf[1 + field.len] = '"';
    name_buf[2 + field.len] = ':';
    const needle = name_buf[0 .. field.len + 3];
    const idx = std.mem.indexOf(u8, line, needle) orelse return error.InvalidBaseline;
    var pos = idx + needle.len;
    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;
    const start = pos;
    while (pos < line.len and line[pos] >= '0' and line[pos] <= '9') pos += 1;
    if (pos == start) return error.InvalidBaseline;
    return std.fmt.parseInt(usize, line[start..pos], 10) catch error.InvalidBaseline;
}

pub const RegressionResult = struct {
    /// Number of directories where `current.passed < baseline.passed`.
    count: usize,
    /// Number of baseline directories matched in the current run (used
    /// by tests to verify the comparison covered the input).
    matched: usize,
};

/// Compare the current run's `Reporter.DirEntry` snapshot against a
/// baseline. Prints one line to stderr per regressed directory. The
/// CLI uses the returned `count` to decide the exit code.
pub fn checkRegressions(
    io: std.Io,
    reporter: *Reporter,
    baseline: []const BaselineEntry,
) !RegressionResult {
    var result = RegressionResult{ .count = 0, .matched = 0 };
    for (baseline) |b| {
        const current = findDirEntry(reporter.by_dir.items, b.dir) orelse continue;
        result.matched += 1;
        if (current.passed < b.passed) {
            result.count += 1;
            try reporter.lockedPrint(
                io,
                "regression: {s} passed {d} -> {d} (-{d})\n",
                .{ b.dir, b.passed, current.passed, b.passed - current.passed },
            );
        }
    }
    return result;
}

fn findDirEntry(entries: []const Reporter.DirEntry, dir: []const u8) ?*const Reporter.DirEntry {
    for (entries) |*e| {
        if (std.mem.eql(u8, e.dir, dir)) return e;
    }
    return null;
}

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

const WorkerContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    engine_path: []const u8,
    use_external_engine: bool,
    harnessdir: ?[]const u8,
    harness_prelude: []const u8,
    tests: []const []const u8,
    known_errors: NameList,
    skipped_features: NameList,
    /// Shared atomic counter used by all workers to claim the next test
    /// index. Replaces the previous stride scheme so a stride that lands on
    /// many slow tests cannot leave other workers idle.
    next_index: *std.atomic.Value(usize),
    verbose: u8,
    timeout_ms: ?u32,
    global_module: bool,
    reporter: ?*Reporter,
    result: *WorkerResult,
};

const HarnessCache = struct {
    const Entry = struct {
        name: []const u8,
        bytes: ?[]const u8,
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    harnessdir: ?[]const u8,
    entries: []Entry = &.{},
    capacity: usize = 0,

    fn init(allocator: std.mem.Allocator, io: std.Io, harnessdir: ?[]const u8) HarnessCache {
        return .{
            .allocator = allocator,
            .io = io,
            .harnessdir = harnessdir,
        };
    }

    fn deinit(self: *HarnessCache) void {
        for (self.entries) |entry| {
            self.allocator.free(entry.name);
            if (entry.bytes) |bytes| self.allocator.free(bytes);
        }
        if (self.capacity != 0) self.allocator.free(self.entries.ptr[0..self.capacity]);
        self.entries = &.{};
        self.capacity = 0;
    }

    fn get(self: *HarnessCache, basename: []const u8) !?[]const u8 {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.name, basename)) return entry.bytes;
        }

        const bytes = try readHarnessFile(self.allocator, self.io, self.harnessdir, basename);
        try self.append(.{
            .name = try self.allocator.dupe(u8, basename),
            .bytes = bytes,
        });
        return bytes;
    }

    fn append(self: *HarnessCache, entry: Entry) !void {
        if (self.entries.len == self.capacity) {
            const next_capacity = if (self.capacity == 0) 16 else self.capacity * 2;
            const next = try self.allocator.alloc(Entry, next_capacity);
            @memcpy(next[0..self.entries.len], self.entries);
            if (self.capacity != 0) self.allocator.free(self.entries.ptr[0..self.capacity]);
            self.entries = next[0..self.entries.len];
            self.capacity = next_capacity;
        }
        const storage: []Entry = @constCast(self.entries.ptr[0..self.capacity]);
        storage[self.entries.len] = entry;
        self.entries = storage[0 .. self.entries.len + 1];
    }
};

pub const NameList = struct {
    allocator: std.mem.Allocator,
    items: []const []const u8 = &.{},
    capacity: usize = 0,

    pub fn init(allocator: std.mem.Allocator) NameList {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *NameList) void {
        for (self.items) |item| self.allocator.free(item);
        if (self.capacity != 0) self.allocator.free(self.items.ptr[0..self.capacity]);
        self.items = &.{};
        self.capacity = 0;
    }

    pub fn appendOwned(self: *NameList, item: []const u8) !void {
        if (self.items.len == self.capacity) {
            const next_capacity = if (self.capacity == 0) 8 else self.capacity * 2;
            const next = try self.allocator.alloc([]const u8, next_capacity);
            @memcpy(next[0..self.items.len], self.items);
            if (self.capacity != 0) self.allocator.free(self.items.ptr[0..self.capacity]);
            self.items = next[0..self.items.len];
            self.capacity = next_capacity;
        }
        const storage: [][]const u8 = @constCast(self.items.ptr[0..self.capacity]);
        storage[self.items.len] = item;
        self.items = storage[0 .. self.items.len + 1];
    }

    pub fn append(self: *NameList, item: []const u8) !void {
        try self.appendOwned(try self.allocator.dupe(u8, item));
    }

    pub fn sortAndDedupe(self: *NameList) void {
        if (self.items.len < 2) return;
        const mutable: [][]const u8 = @constCast(self.items);
        std.mem.sort([]const u8, mutable, {}, lessThanName);
        var write: usize = 1;
        var read: usize = 1;
        while (read < mutable.len) : (read += 1) {
            if (compareNames(mutable[write - 1], mutable[read]) == 0) {
                self.allocator.free(mutable[read]);
            } else {
                mutable[write] = mutable[read];
                write += 1;
            }
        }
        self.items = mutable[0..write];
    }

    pub fn dedupePreserveOrder(self: *NameList) void {
        if (self.items.len < 2) return;
        const mutable: [][]const u8 = @constCast(self.items);
        var write: usize = 0;
        for (mutable) |item| {
            var duplicate = false;
            for (mutable[0..write]) |existing| {
                if (std.mem.eql(u8, existing, item)) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) {
                self.allocator.free(item);
            } else {
                mutable[write] = item;
                write += 1;
            }
        }
        self.items = mutable[0..write];
    }

    pub fn contains(self: NameList, needle: []const u8) bool {
        return self.bestMatchLen(needle) != null;
    }

    pub fn bestMatchLen(self: NameList, needle: []const u8) ?usize {
        var best: ?usize = null;
        for (self.items) |item| {
            const matches = std.mem.eql(u8, item, needle) or
                (std.mem.endsWith(u8, item, "/") and std.mem.startsWith(u8, needle, item));
            if (!matches) continue;
            if (best == null or item.len > best.?) best = item.len;
        }
        return best;
    }

    pub fn containsExact(self: NameList, needle: []const u8) bool {
        for (self.items) |item| {
            if (std.mem.eql(u8, item, needle)) return true;
        }
        return false;
    }

    pub fn removeExact(self: *NameList, needle: []const u8) void {
        if (self.items.len == 0) return;
        const mutable: [][]const u8 = @constCast(self.items);
        var write: usize = 0;
        for (mutable) |item| {
            if (std.mem.eql(u8, item, needle)) {
                self.allocator.free(item);
            } else {
                mutable[write] = item;
                write += 1;
            }
        }
        self.items = mutable[0..write];
    }

    pub fn findSortedExact(self: NameList, needle: []const u8) ?usize {
        var low: usize = 0;
        var high: usize = self.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const cmp = compareNames(self.items[mid], needle);
            if (cmp < 0) {
                low = mid + 1;
            } else if (cmp > 0) {
                high = mid;
            } else {
                return mid;
            }
        }
        return null;
    }

    pub fn move(self: *NameList) NameList {
        const out = self.*;
        self.items = &.{};
        self.capacity = 0;
        return out;
    }
};

pub fn loadConfigText(allocator: std.mem.Allocator, base_dir: []const u8, text: []const u8) !LoadedConfig {
    var loaded = LoadedConfig.init(allocator);
    errdefer loaded.deinit(allocator);

    var section: enum { none, config, features, exclude, tests } = .none;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const no_cr = std.mem.trim(u8, raw_line, "\r");
        const line = stripComment(std.mem.trim(u8, no_cr, " \t"));
        if (line.len == 0) continue;

        if (std.mem.eql(u8, line, "[config]")) {
            section = .config;
            continue;
        }
        if (std.mem.eql(u8, line, "[features]")) {
            section = .features;
            continue;
        }
        if (std.mem.eql(u8, line, "[exclude]")) {
            section = .exclude;
            continue;
        }
        if (std.mem.eql(u8, line, "[tests]")) {
            section = .tests;
            continue;
        }

        switch (section) {
            .config => try parseConfigEntry(allocator, &loaded, base_dir, line),
            .features => try parseFeatureEntry(&loaded, line),
            .exclude => try parseExcludeEntry(allocator, &loaded, base_dir, line),
            .tests, .none => {},
        }
    }

    loaded.excludes.sortAndDedupe();
    loaded.reincludes.sortAndDedupe();
    loaded.enabled_features.sortAndDedupe();
    loaded.skipped_features.sortAndDedupe();
    return loaded;
}

pub fn loadConfigFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !LoadedConfig {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(bytes);
    const base_dir = dirname(path);
    return loadConfigText(allocator, base_dir, bytes);
}

pub fn collectSelection(allocator: std.mem.Allocator, io: std.Io, config: Config) !SelectionSummary {
    var prepared = try prepareSelection(allocator, io, config);
    defer prepared.deinit(allocator);
    return .{
        .total_tests = prepared.summary.total_tests,
        .selected_tests = prepared.summary.selected_tests,
        .excluded_tests = prepared.summary.excluded_tests,
        .skipped_by_feature = prepared.summary.skipped_by_feature,
        .skipped_by_index = prepared.summary.skipped_by_index,
        .harnessdir = if (prepared.summary.harnessdir) |value| try allocator.dupe(u8, value) else null,
        .errorfile = if (prepared.summary.errorfile) |value| try allocator.dupe(u8, value) else null,
    };
}

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
    if (worker_count == 1) {
        try runWorkerStride(
            test_allocator,
            io,
            engine_path,
            use_external_engine,
            summary.selection.harnessdir,
            harness_prelude,
            prepared.tests.items,
            known_errors,
            prepared.skipped_features,
            &next_index,
            config.verbose,
            config.timeout_ms,
            config.module,
            &reporter,
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
        var contexts = try allocator.alloc(WorkerContext, worker_count);
        defer allocator.free(contexts);
        var threads = try allocator.alloc(std.Thread, worker_count);
        defer allocator.free(threads);

        for (results, 0..) |*result, i| result.* = WorkerResult.init(worker_gpas[i].allocator());
        defer for (results) |*result| result.deinit();

        var spawned: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < spawned) : (i += 1) threads[i].join();
        }
        while (spawned < worker_count) : (spawned += 1) {
            contexts[spawned] = .{
                .allocator = worker_gpas[spawned].allocator(),
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
                .result = &results[spawned],
            };
            threads[spawned] = try std.Thread.spawn(.{}, runWorkerThread, .{&contexts[spawned]});
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

    if (config.regression_baseline) |baseline_path| {
        const baseline_bytes = std.Io.Dir.cwd().readFileAlloc(
            io,
            baseline_path,
            allocator,
            .limited(8 * 1024 * 1024),
        ) catch |err| blk: {
            try reporter.lockedPrint(
                io,
                "regression-baseline: unable to read {s}: {s}\n",
                .{ baseline_path, @errorName(err) },
            );
            break :blk null;
        };
        if (baseline_bytes) |bytes| {
            defer allocator.free(bytes);
            const entries = parseBaseline(allocator, bytes) catch |err| {
                try reporter.lockedPrint(
                    io,
                    "regression-baseline: parse error in {s}: {s}\n",
                    .{ baseline_path, @errorName(err) },
                );
                prepared.tests.deinit();
                prepared.skipped_features.deinit();
                return summary;
            };
            defer freeBaseline(allocator, entries);
            const regression_result = try checkRegressions(io, &reporter, entries);
            summary.regressions = regression_result.count;
        }
    }

    prepared.tests.deinit();
    prepared.skipped_features.deinit();
    return summary;
}

fn runWorkerThread(context: *WorkerContext) void {
    var summary = ExecutionSummary{ .selection = .{} };
    runWorkerStride(
        context.allocator,
        context.io,
        context.engine_path,
        context.use_external_engine,
        context.harnessdir,
        context.harness_prelude,
        context.tests,
        context.known_errors,
        context.skipped_features,
        context.next_index,
        context.verbose,
        context.timeout_ms,
        context.global_module,
        context.reporter,
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

fn runWorkerStride(
    allocator: std.mem.Allocator,
    io: std.Io,
    engine_path: []const u8,
    use_external_engine: bool,
    harnessdir: ?[]const u8,
    harness_prelude: []const u8,
    tests: []const []const u8,
    known_errors: NameList,
    skipped_features: NameList,
    next_index: *std.atomic.Value(usize),
    verbose: u8,
    timeout_ms: ?u32,
    global_module: bool,
    reporter: ?*Reporter,
    summary: *ExecutionSummary,
    current_failures: *NameList,
) !void {
    var harness_cache = HarnessCache.init(allocator, io, harnessdir);
    defer harness_cache.deinit();

    while (true) {
        const index = next_index.fetchAdd(1, .monotonic);
        if (index >= tests.len) break;
        if (index > 0 and index % 1000 == 0) {
            printError(io, "Progress: {d}/{d} tests ({d}%)\n", .{ index, tests.len, index * 100 / tests.len }) catch {};
        }
        const test_path = tests[index];

        var run_err: ?anyerror = null;
        const result, const is_known = blk: {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            var stderr_text: []const u8 = "";
            var stderr_storage: [stderr_storage_len]u8 = undefined;
            const res = runOneTest(
                arena_allocator,
                io,
                engine_path,
                use_external_engine,
                &harness_cache,
                harness_prelude,
                test_path,
                index,
                verbose,
                timeout_ms,
                global_module,
                skipped_features,
                reporter,
                &stderr_storage,
                &stderr_text,
            ) catch |err| {
                run_err = err;
                break :blk .{ .skipped, false };
            };

            if (res == .skipped) {
                break :blk .{ .skipped, false };
            }

            const known = known_errors.findSortedExact(test_path) != null;
            if (reporter) |r| {
                r.recordResult(io, test_path, res, stderr_text, known) catch |err| {
                    run_err = err;
                    break :blk .{ .skipped, false };
                };
            }
            break :blk .{ res, known };
        };

        if (run_err) |err| {
            if (reporter) |r| {
                r.lockedPrint(io, "test262 worker error: {s}: {s}\n", .{ test_path, @errorName(err) }) catch {};
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

fn parseExcludeEntry(allocator: std.mem.Allocator, loaded: *LoadedConfig, base_dir: []const u8, line: []const u8) !void {
    if (line[0] == '!') {
        const value = std.mem.trim(u8, line[1..], " \t");
        if (value.len == 0) return;
        try loaded.reincludes.appendOwned(try composePath(allocator, base_dir, value));
        return;
    }
    try loaded.excludes.appendOwned(try composePath(allocator, base_dir, line));
}

fn parseConfigEntry(allocator: std.mem.Allocator, loaded: *LoadedConfig, base_dir: []const u8, line: []const u8) !void {
    const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse return;
    const key = std.mem.trim(u8, line[0..eq_index], " \t");
    const value = std.mem.trim(u8, line[eq_index + 1 ..], " \t");
    if (std.mem.eql(u8, key, "testdir")) {
        if (loaded.testdir) |old| allocator.free(old);
        loaded.testdir = try composePath(allocator, base_dir, value);
    } else if (std.mem.eql(u8, key, "harnessdir")) {
        if (loaded.harnessdir) |old| allocator.free(old);
        loaded.harnessdir = try composePath(allocator, base_dir, value);
    } else if (std.mem.eql(u8, key, "errorfile")) {
        if (loaded.errorfile) |old| allocator.free(old);
        loaded.errorfile = try composePath(allocator, base_dir, value);
    } else if (std.mem.eql(u8, key, "excludefile")) {
        try loaded.excludes.appendOwned(try composePath(allocator, base_dir, value));
    }
}

fn parseFeatureEntry(loaded: *LoadedConfig, line: []const u8) !void {
    const eq_index = std.mem.indexOfScalar(u8, line, '=');
    const name = if (eq_index) |index| std.mem.trim(u8, line[0..index], " \t") else line;
    if (eq_index) |index| {
        const value = std.mem.trim(u8, line[index + 1 ..], " \t");
        if (std.mem.eql(u8, value, "skip")) {
            try loaded.skipped_features.append(name);
            return;
        }
    }
    try loaded.enabled_features.append(name);
}

fn applyFeatureOverrides(loaded: *LoadedConfig, overrides: BoundedFeatureOverrides) !void {
    var i: usize = 0;
    while (i < overrides.len) : (i += 1) {
        const override = overrides.get(i);
        switch (override.kind) {
            .enable => {
                loaded.skipped_features.removeExact(override.name);
                if (!loaded.enabled_features.containsExact(override.name)) try loaded.enabled_features.append(override.name);
            },
            .skip => {
                loaded.enabled_features.removeExact(override.name);
                if (!loaded.skipped_features.containsExact(override.name)) try loaded.skipped_features.append(override.name);
            },
        }
    }
    loaded.enabled_features.sortAndDedupe();
    loaded.skipped_features.sortAndDedupe();
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

fn stripComment(line: []const u8) []const u8 {
    const hash = std.mem.indexOfScalar(u8, line, '#') orelse line.len;
    const semi = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
    return std.mem.trim(u8, line[0..@min(hash, semi)], " \t");
}

fn dirname(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse "";
}

fn composePath(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]const u8 {
    if (base.len == 0 or std.fs.path.isAbsolute(name)) return allocator.dupe(u8, name);
    return std.fs.path.join(allocator, &.{ base, name });
}

fn lessThanName(_: void, lhs: []const u8, rhs: []const u8) bool {
    return compareNames(lhs, rhs) < 0;
}

fn compareNames(lhs: []const u8, rhs: []const u8) i32 {
    var i: usize = 0;
    var j: usize = 0;
    while (i < lhs.len and j < rhs.len) {
        const lc = lhs[i];
        const rc = rhs[j];
        if (unicode.isAsciiDigitByte(lc) and unicode.isAsciiDigitByte(rc)) {
            const lhs_start = i;
            const rhs_start = j;
            i = asciiDigitRunEnd(lhs, lhs_start);
            j = asciiDigitRunEnd(rhs, rhs_start);
            const digits_cmp = compareAsciiDigitRuns(lhs[lhs_start..i], rhs[rhs_start..j]);
            if (digits_cmp != 0) return digits_cmp;
            continue;
        }
        if (lc < rc) return -1;
        if (lc > rc) return 1;
        i += 1;
        j += 1;
    }
    if (i < lhs.len) return 1;
    if (j < rhs.len) return -1;
    return 0;
}

fn asciiDigitRunEnd(bytes: []const u8, start: usize) usize {
    var end = start;
    while (end < bytes.len and unicode.isAsciiDigitByte(bytes[end])) : (end += 1) {}
    return end;
}

fn compareAsciiDigitRuns(lhs: []const u8, rhs: []const u8) i32 {
    const lhs_significant = trimLeadingAsciiZeroes(lhs);
    const rhs_significant = trimLeadingAsciiZeroes(rhs);
    if (lhs_significant.len < rhs_significant.len) return -1;
    if (lhs_significant.len > rhs_significant.len) return 1;

    const significant_order = std.mem.order(u8, lhs_significant, rhs_significant);
    if (significant_order == .lt) return -1;
    if (significant_order == .gt) return 1;

    if (lhs.len < rhs.len) return -1;
    if (lhs.len > rhs.len) return 1;
    return 0;
}

fn trimLeadingAsciiZeroes(bytes: []const u8) []const u8 {
    var start: usize = 0;
    while (start < bytes.len and bytes[start] == '0') : (start += 1) {}
    return bytes[start..];
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
        .context = &ctx.core,
        .output = &output,
        .io = io,
        .allocator = allocator,
        .max_source_size = 16 * 1024 * 1024,
    };
    test262_root.exec.module_graph.installDynamicImport(&dynamic_import_state);
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
        try ctx.runJobs(&output);
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

fn makeHarnessPrelude(allocator: std.mem.Allocator, io: std.Io, harnessdir: ?[]const u8) ![]u8 {
    const eval_script_shim =
        "if (typeof $262 === \"object\" && typeof $262.evalScript !== \"function\") {\n" ++
        "  $262.evalScript = function(source) { return (0, eval)(source); };\n" ++
        "}\n";
    const sta = try readHarnessFile(allocator, io, harnessdir, "sta.js");
    defer if (sta) |bytes| allocator.free(bytes);
    const assert = try readHarnessFile(allocator, io, harnessdir, "assert.js");
    defer if (assert) |bytes| allocator.free(bytes);

    const sta_len = if (sta) |bytes| bytes.len else 0;
    const assert_len = if (assert) |bytes| bytes.len else 0;
    const total_len = sta_len + assert_len +
        @as(usize, if (sta != null) 1 else 0) +
        @as(usize, if (assert != null) 1 else 0) +
        eval_script_shim.len;
    const out = try allocator.alloc(u8, total_len);
    var offset: usize = 0;
    if (sta) |bytes| {
        @memcpy(out[offset..][0..bytes.len], bytes);
        offset += bytes.len;
        out[offset] = '\n';
        offset += 1;
    }
    if (assert) |bytes| {
        @memcpy(out[offset..][0..bytes.len], bytes);
        offset += bytes.len;
        out[offset] = '\n';
        offset += 1;
    }
    @memcpy(out[offset..][0..eval_script_shim.len], eval_script_shim);
    offset += eval_script_shim.len;
    return out[0..offset];
}

fn makeTestSource(allocator: std.mem.Allocator, io: std.Io, harness_cache: *HarnessCache, harness_prelude: []const u8, test_path: []const u8, metadata: TestMetadata) ![]u8 {
    const test_source = try readTestSource(allocator, io, test_path);
    defer allocator.free(test_source);
    return makeTestSourceFromBytes(allocator, harness_cache, harness_prelude, test_source, metadata);
}

const Test262Override = struct {
    path: []const u8,
    upstream_commit: []const u8,
    upstream_sha256: []const u8,
    reason: []const u8,
};

const test262_override_manifest = [_]Test262Override{
    .{
        .path = "test/built-ins/TypedArray/prototype/slice/speciesctor-return-same-buffer-with-offset.js",
        .upstream_commit = "4249661388e5d3f92a85186213da140a6481490f",
        .upstream_sha256 = "2136a50c608ac2dd74815ca4cb4ec6e0eb7bd54d1fc102bec5fe53b322563a6b",
        .reason = "Exclude immutable ArrayBuffer path until upstream covers the proposal interaction.",
    },
    .{
        .path = "test/built-ins/TypedArrayConstructors/internals/Set/BigInt/string-nan-tobigint.js",
        .upstream_commit = "4249661388e5d3f92a85186213da140a6481490f",
        .upstream_sha256 = "20bc0c56378a3c12e7fa38d920648d8f5b57c8e3ab2ea31737b7794ccce8dbfb",
        .reason = "Exclude immutable ArrayBuffer path until upstream covers the proposal interaction.",
    },
    .{
        .path = "test/staging/sm/Error/constructor-proto.js",
        .upstream_commit = "4249661388e5d3f92a85186213da140a6481490f",
        .upstream_sha256 = "e42a648845a28cbcf52adc3c0a437b6afe0a18d8ea0cef5821ba9dcdd3c08738",
        .reason = "Staging SpiderMonkey test has not been updated for Error.prototype.stack accessor.",
    },
    .{
        .path = "test/staging/sm/Error/prototype-properties.js",
        .upstream_commit = "4249661388e5d3f92a85186213da140a6481490f",
        .upstream_sha256 = "e91457931236bdc6fe42d96e96569fd9bfff1ee2c0592aca19c3dc2a4886b5b2",
        .reason = "Staging SpiderMonkey test has not been updated for Error.prototype.stack accessor.",
    },
    .{
        .path = "test/staging/sm/Error/prototype.js",
        .upstream_commit = "4249661388e5d3f92a85186213da140a6481490f",
        .upstream_sha256 = "ee62fb50ca1cee2a3a6de258af03b38a8750dde2e0485101f997db2bd730f770",
        .reason = "Staging SpiderMonkey test has not been updated for Error.prototype.stack accessor.",
    },
};

fn readTestSource(allocator: std.mem.Allocator, io: std.Io, test_path: []const u8) ![]u8 {
    if (test262Override(test_path)) |override| {
        try verifyTest262OverrideUpstream(allocator, io, override);
        const override_path = try test262OverridePath(allocator, test_path);
        defer allocator.free(override_path);
        return std.Io.Dir.cwd().readFileAlloc(io, override_path, allocator, .limited(16 * 1024 * 1024));
    }
    return std.Io.Dir.cwd().readFileAlloc(io, test_path, allocator, .limited(16 * 1024 * 1024));
}

fn test262Override(test_path: []const u8) ?Test262Override {
    const relative_path = test262RelativePath(test_path) orelse return null;
    for (test262_override_manifest) |override| {
        if (std.mem.eql(u8, override.path, relative_path)) return override;
    }
    return null;
}

fn verifyTest262OverrideUpstream(allocator: std.mem.Allocator, io: std.Io, override: Test262Override) !void {
    const upstream_path = try test262UpstreamPath(allocator, override.path);
    defer allocator.free(upstream_path);
    const upstream_source = try std.Io.Dir.cwd().readFileAlloc(io, upstream_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(upstream_source);
    const actual_sha256 = computeSha256Hex(upstream_source);
    if (!std.mem.eql(u8, override.upstream_sha256, &actual_sha256)) {
        std.debug.print(
            "test262 override source drifted: {s}\nexpected upstream {s} sha256 {s}\nactual sha256 {s}\nreason: {s}\n",
            .{ upstream_path, override.upstream_commit, override.upstream_sha256, actual_sha256, override.reason },
        );
        return error.Test262OverrideSourceDrift;
    }
}

fn computeSha256Hex(bytes: []const u8) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(bytes);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var hex: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        hex[i * 2] = hex_chars[b >> 4];
        hex[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return hex;
}

fn test262OverridePath(allocator: std.mem.Allocator, test_path: []const u8) ![]const u8 {
    std.debug.assert(test262Override(test_path) != null);
    const relative_path = test262RelativePath(test_path).?;
    return try std.fs.path.join(allocator, &.{ "tests/fixtures/test262-overrides", relative_path });
}

fn test262UpstreamPath(allocator: std.mem.Allocator, relative_path: []const u8) ![]const u8 {
    return try std.fs.path.join(allocator, &.{ "test262", relative_path });
}

fn test262RelativePath(test_path: []const u8) ?[]const u8 {
    const config_prefix = "test262/";
    if (std.mem.startsWith(u8, test_path, config_prefix)) return test_path[config_prefix.len..];
    if (std.mem.startsWith(u8, test_path, "test/")) return test_path;
    return null;
}

fn makeTestSourceFromBytes(allocator: std.mem.Allocator, harness_cache: *HarnessCache, harness_prelude: []const u8, test_source: []const u8, metadata: TestMetadata) ![]u8 {
    const strict_prefix = "\"use strict\";\n";
    const async_harness = "doneprintHandle.js";
    const strict_len: usize = if (metadata.hasFlag("onlyStrict")) strict_prefix.len else 0;
    if (metadata.hasFlag("raw")) {
        const out = try allocator.alloc(u8, strict_len + test_source.len + 1);
        var offset: usize = 0;
        if (strict_len != 0) {
            @memcpy(out[offset..][0..strict_prefix.len], strict_prefix);
            offset += strict_prefix.len;
        }
        @memcpy(out[offset..][0..test_source.len], test_source);
        offset += test_source.len;
        out[offset] = '\n';
        return out;
    }

    var includes_len: usize = 0;
    const include_async_harness = needsAsyncHarness(metadata, test_source) and !metadata.includes.contains(async_harness);
    if (include_async_harness) {
        if (try harness_cache.get(async_harness)) |bytes| includes_len += bytes.len + 1;
    }
    for (metadata.includes.items) |include_name| {
        if (try harness_cache.get(include_name)) |bytes| includes_len += bytes.len + 1;
    }
    const total_len = strict_len + harness_prelude.len + includes_len + test_source.len + 1;
    const out = try allocator.alloc(u8, total_len);
    var offset: usize = 0;
    if (strict_len != 0) {
        @memcpy(out[offset..][0..strict_prefix.len], strict_prefix);
        offset += strict_prefix.len;
    }
    @memcpy(out[offset..][0..harness_prelude.len], harness_prelude);
    offset += harness_prelude.len;
    if (include_async_harness) {
        if (try harness_cache.get(async_harness)) |bytes| {
            @memcpy(out[offset..][0..bytes.len], bytes);
            offset += bytes.len;
            out[offset] = '\n';
            offset += 1;
        }
    }
    for (metadata.includes.items) |include_name| {
        if (try harness_cache.get(include_name)) |bytes| {
            @memcpy(out[offset..][0..bytes.len], bytes);
            offset += bytes.len;
            out[offset] = '\n';
            offset += 1;
        }
    }
    @memcpy(out[offset..][0..test_source.len], test_source);
    offset += test_source.len;
    out[offset] = '\n';
    offset += 1;
    return out[0..offset];
}

fn needsAsyncHarness(metadata: TestMetadata, test_source: []const u8) bool {
    _ = test_source;
    return metadata.hasFlag("async");
}

fn readHarnessFile(allocator: std.mem.Allocator, io: std.Io, harnessdir: ?[]const u8, basename: []const u8) !?[]u8 {
    const dir = harnessdir orelse return null;
    const path = try std.fs.path.join(allocator, &.{ dir, basename });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| return e,
    };
}

fn loadMetadataFromFile(allocator: std.mem.Allocator, io: std.Io, test_path: []const u8) !TestMetadata {
    const bytes = try readMetadataPrefix(allocator, io, test_path);
    defer allocator.free(bytes);
    return parseMetadataText(allocator, bytes);
}

fn readMetadataPrefix(allocator: std.mem.Allocator, io: std.Io, test_path: []const u8) ![]u8 {
    if (test262Override(test_path) != null) return readTestSource(allocator, io, test_path);

    const max_metadata_probe = 64 * 1024;
    const file = try std.Io.Dir.cwd().openFile(io, test_path, .{});
    defer file.close(io);
    const buffer = try allocator.alloc(u8, max_metadata_probe);
    errdefer allocator.free(buffer);
    const len = try file.readPositionalAll(io, buffer, 0);
    if (len == buffer.len) return buffer;
    const exact = try allocator.dupe(u8, buffer[0..len]);
    allocator.free(buffer);
    return exact;
}

pub fn parseMetadataText(allocator: std.mem.Allocator, source: []const u8) !TestMetadata {
    var metadata = TestMetadata.init(allocator);
    errdefer metadata.deinit(allocator);

    const start_marker = "/*---";
    const end_marker = "---*/";
    const start = std.mem.indexOf(u8, source, start_marker) orelse return metadata;
    const body_start = start + start_marker.len;
    const end = std.mem.indexOfPos(u8, source, body_start, end_marker) orelse return metadata;
    const body = source[body_start..end];

    var in_negative = false;
    var active_list: enum { none, includes, features, flags } = .none;
    var lines = std.mem.tokenizeAny(u8, body, "\r\n");
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (active_list != .none and line[0] == '-') {
            switch (active_list) {
                .none => unreachable,
                .includes => try parseMetadataListItem(&metadata.includes, line[1..]),
                .features => try parseMetadataListItem(&metadata.features, line[1..]),
                .flags => try parseMetadataListItem(&metadata.flags, line[1..]),
            }
            continue;
        }
        active_list = .none;

        if (std.mem.eql(u8, line, "negative:")) {
            if (metadata.negative == null) metadata.negative = .{};
            in_negative = true;
            continue;
        }
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            const key = std.mem.trim(u8, line[0..colon], " \t");
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.mem.eql(u8, key, "includes")) {
                try parseMetadataList(&metadata.includes, value);
                active_list = if (value.len == 0) .includes else .none;
                in_negative = false;
            } else if (std.mem.eql(u8, key, "features")) {
                try parseMetadataList(&metadata.features, value);
                active_list = if (value.len == 0) .features else .none;
                in_negative = false;
            } else if (std.mem.eql(u8, key, "flags")) {
                try parseMetadataList(&metadata.flags, value);
                active_list = if (value.len == 0) .flags else .none;
                in_negative = false;
            } else if (in_negative and std.mem.eql(u8, key, "phase")) {
                if (metadata.negative == null) metadata.negative = .{};
                if (metadata.negative.?.phase) |old| allocator.free(old);
                metadata.negative.?.phase = try allocator.dupe(u8, value);
            } else if (in_negative and std.mem.eql(u8, key, "type")) {
                if (metadata.negative == null) metadata.negative = .{};
                if (metadata.negative.?.type_name) |old| allocator.free(old);
                metadata.negative.?.type_name = try allocator.dupe(u8, value);
            } else {
                in_negative = false;
            }
        }
    }

    metadata.includes.dedupePreserveOrder();
    metadata.features.sortAndDedupe();
    metadata.flags.sortAndDedupe();
    return metadata;
}

fn parseMetadataList(list: *NameList, value: []const u8) !void {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return;
    var entries = std.mem.splitScalar(u8, trimmed[1 .. trimmed.len - 1], ',');
    while (entries.next()) |entry| {
        try parseMetadataListItem(list, entry);
    }
}

fn parseMetadataListItem(list: *NameList, item: []const u8) !void {
    const without_comment = if (std.mem.indexOfScalar(u8, item, '#')) |comment|
        item[0..comment]
    else
        item;
    const name = std.mem.trim(u8, without_comment, " \t\r\n\"'");
    if (name.len != 0) try list.append(name);
}

fn loadKnownErrors(allocator: std.mem.Allocator, io: std.Io, errorfile: ?[]const u8) !NameList {
    const path = errorfile orelse return NameList.init(allocator);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return NameList.init(allocator),
        else => return err,
    };
    defer allocator.free(bytes);
    return parseKnownErrorsText(allocator, dirname(path), bytes);
}

fn parseKnownErrorsText(allocator: std.mem.Allocator, base_dir: []const u8, text: []const u8) !NameList {
    var known = NameList.init(allocator);
    errdefer known.deinit();

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const entry = stripComment(std.mem.trim(u8, line, " \t\r"));
        if (entry.len == 0) continue;
        try known.appendOwned(try normalizeKnownErrorPath(allocator, base_dir, knownErrorPath(entry)));
    }
    known.sortAndDedupe();
    return known;
}

fn writeKnownErrors(allocator: std.mem.Allocator, io: std.Io, errorfile: []const u8, failures: NameList) !void {
    const rendered = try renderKnownErrorsText(allocator, failures, dirname(errorfile));
    defer allocator.free(rendered);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = errorfile, .data = rendered });
}

fn mergeKnownErrorsForUpdate(allocator: std.mem.Allocator, known_failures: NameList, selected_tests: NameList, current_failures: NameList) !NameList {
    var merged = NameList.init(allocator);
    errdefer merged.deinit();

    for (current_failures.items) |test_path| try merged.append(test_path);
    for (known_failures.items) |test_path| {
        if (!selected_tests.contains(test_path)) try merged.append(test_path);
    }
    merged.sortAndDedupe();
    return merged;
}

fn renderKnownErrorsText(allocator: std.mem.Allocator, failures: NameList, base_dir: []const u8) ![]u8 {
    var stable = NameList.init(allocator);
    defer stable.deinit();
    for (failures.items) |test_path| try stable.append(test_path);
    stable.sortAndDedupe();

    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    for (stable.items) |test_path| {
        try buffer.appendSlice(allocator, pathRelativeToBase(base_dir, test_path));
        try buffer.append(allocator, '\n');
    }
    return buffer.toOwnedSlice(allocator);
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

fn knownErrorPath(line: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, line, ':')) |colon| return std.mem.trim(u8, line[0..colon], " \t");
    return line;
}

fn normalizeKnownErrorPath(allocator: std.mem.Allocator, base_dir: []const u8, path: []const u8) ![]const u8 {
    if (base_dir.len == 0 or std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    if (std.mem.eql(u8, path, base_dir)) return allocator.dupe(u8, path);
    if (std.mem.startsWith(u8, path, base_dir) and path.len > base_dir.len and path[base_dir.len] == '/') {
        return allocator.dupe(u8, path);
    }
    return std.fs.path.join(allocator, &.{ base_dir, path });
}

fn pathRelativeToBase(base_dir: []const u8, path: []const u8) []const u8 {
    if (base_dir.len == 0) return path;
    if (std.mem.startsWith(u8, path, base_dir) and path.len > base_dir.len and path[base_dir.len] == '/') {
        return path[base_dir.len + 1 ..];
    }
    return path;
}

pub const ErrorKind = enum {
    test262,
    eval,
    reference,
    syntax,
    range,
};

pub fn raise(kind: ErrorKind) error{ JSException, EvalError, ReferenceError, SyntaxError, RangeError } {
    return switch (kind) {
        .test262 => error.JSException,
        .eval => error.EvalError,
        .reference => error.ReferenceError,
        .syntax => error.SyntaxError,
        .range => error.RangeError,
    };
}

pub fn assertSameValue(actual: zjs.JSValue, expected: zjs.JSValue) !zjs.JSValue {
    if (!actual.sameValue(expected)) return error.JSException;
    return zjs.JSValue.undefinedValue();
}

pub fn qjsTest262EvalScript(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: *zjs.Object,
    function_object: *zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    if (args.len == 0) return zjs.JSValue.undefinedValue();
    if (!args[0].isString()) return error.TypeError;
    const eval_global = (try ctx.functionRealmGlobal(function_object.value())) orelse global;
    return ctx.evalScriptValue(args[0], .{
        .output = output,
        .realm_global = eval_global,
        .filename = "<evalScript>",
    });
}

pub const Test262Agent = struct {
    source: []u8,
    owner_runtime: *zjs.JSRuntime,
    agent_runtime: ?*zjs.JSRuntime = null,
    broadcast_buffer: ?zjs.SharedArrayBufferRef = null,
    done: bool = false,
    thread_done: bool = false,
};

pub const Test262AgentReportEntry = struct {
    owner_runtime: *zjs.JSRuntime,
    bytes: []u8,
};

pub const Test262AgentCoordinator = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    agents: []*Test262Agent = &.{},
    agents_capacity: usize = 0,
    reports: []Test262AgentReportEntry = &.{},
    reports_capacity: usize = 0,
};

pub var test262_agents = Test262AgentCoordinator{};
pub threadlocal var current_test262_agent: ?*Test262Agent = null;
var test262_external_host_context: u8 = 0;

pub var test262_gpa = std.heap.DebugAllocator(.{
    .safety = false,
    .stack_trace_frames = 0,
    .thread_safe = true,
    .retain_metadata = true,
}){};

pub fn test262PageAllocator() std.mem.Allocator {
    return test262_gpa.allocator();
}

pub fn test262AgentIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn test262AgentAppend(agent: *Test262Agent) !void {
    const io = test262AgentIo();
    test262_agents.mutex.lockUncancelable(io);
    defer test262_agents.mutex.unlock(io);
    _ = test262AgentSweepCompletedLocked(agent.owner_runtime);
    try test262AgentEnsureAgentCapacityLocked(test262_agents.agents.len + 1);
    test262_agents.agents = test262_agents.agents.ptr[0 .. test262_agents.agents.len + 1];
    test262_agents.agents[test262_agents.agents.len - 1] = agent;
}

pub fn test262AgentEnqueueReport(owner_runtime: *zjs.JSRuntime, bytes: []u8) !void {
    const io = test262AgentIo();
    test262_agents.mutex.lockUncancelable(io);
    defer test262_agents.mutex.unlock(io);
    try test262AgentEnsureReportCapacityLocked(test262_agents.reports.len + 1);
    test262_agents.reports = test262_agents.reports.ptr[0 .. test262_agents.reports.len + 1];
    test262_agents.reports[test262_agents.reports.len - 1] = .{ .owner_runtime = owner_runtime, .bytes = bytes };
    test262_agents.cond.broadcast(io);
}

pub fn test262AgentDestroy(agent: *Test262Agent) void {
    const allocator = test262PageAllocator();
    allocator.free(agent.source);
    if (agent.broadcast_buffer) |*buffer| {
        buffer.release();
        agent.broadcast_buffer = null;
    }
    allocator.destroy(agent);
}

pub fn test262AgentEnsureAgentCapacityLocked(min_capacity: usize) !void {
    if (test262_agents.agents_capacity >= min_capacity) return;
    const allocator = test262PageAllocator();
    var next_capacity = if (test262_agents.agents_capacity == 0) @as(usize, 4) else test262_agents.agents_capacity * 2;
    while (next_capacity < min_capacity) : (next_capacity *= 2) {}
    const next = try allocator.alloc(*Test262Agent, next_capacity);
    @memcpy(next[0..test262_agents.agents.len], test262_agents.agents);
    if (test262_agents.agents_capacity != 0) allocator.free(test262_agents.agents.ptr[0..test262_agents.agents_capacity]);
    test262_agents.agents = next[0..test262_agents.agents.len];
    test262_agents.agents_capacity = next_capacity;
}

pub fn test262AgentEnsureReportCapacityLocked(min_capacity: usize) !void {
    if (test262_agents.reports_capacity >= min_capacity) return;
    const allocator = test262PageAllocator();
    var next_capacity = if (test262_agents.reports_capacity == 0) @as(usize, 4) else test262_agents.reports_capacity * 2;
    while (next_capacity < min_capacity) : (next_capacity *= 2) {}
    const next = try allocator.alloc(Test262AgentReportEntry, next_capacity);
    @memcpy(next[0..test262_agents.reports.len], test262_agents.reports);
    if (test262_agents.reports_capacity != 0) allocator.free(test262_agents.reports.ptr[0..test262_agents.reports_capacity]);
    test262_agents.reports = next[0..test262_agents.reports.len];
    test262_agents.reports_capacity = next_capacity;
}

pub fn test262AgentRemoveAtLocked(index: usize) void {
    std.debug.assert(index < test262_agents.agents.len);
    const agent = test262_agents.agents[index];
    const old_len = test262_agents.agents.len;
    if (index + 1 < old_len) {
        @memmove(test262_agents.agents[index .. old_len - 1], test262_agents.agents[index + 1 .. old_len]);
    }
    test262_agents.agents = test262_agents.agents.ptr[0 .. old_len - 1];
    if (test262_agents.agents.len == 0 and test262_agents.agents_capacity != 0) {
        const allocator = test262PageAllocator();
        allocator.free(test262_agents.agents.ptr[0..test262_agents.agents_capacity]);
        test262_agents.agents = &.{};
        test262_agents.agents_capacity = 0;
    }
    test262AgentDestroy(agent);
}

pub fn test262AgentRemove(agent: *Test262Agent) void {
    const io = test262AgentIo();
    test262_agents.mutex.lockUncancelable(io);
    defer test262_agents.mutex.unlock(io);
    var index: usize = 0;
    while (index < test262_agents.agents.len) : (index += 1) {
        if (test262_agents.agents[index] != agent) continue;
        test262AgentRemoveAtLocked(index);
        return;
    }
}

pub fn test262AgentSweepCompletedLocked(rt: *zjs.JSRuntime) usize {
    var removed: usize = 0;
    var index: usize = 0;
    while (index < test262_agents.agents.len) {
        const agent = test262_agents.agents[index];
        if (agent.owner_runtime != rt) {
            index += 1;
            continue;
        }
        if (!agent.thread_done) {
            index += 1;
            continue;
        }
        test262AgentRemoveAtLocked(index);
        removed += 1;
    }
    return removed;
}

pub fn test262AgentTakeReportLocked(rt: *zjs.JSRuntime) ?[]u8 {
    for (test262_agents.reports, 0..) |entry, index| {
        if (entry.owner_runtime == rt) {
            const report = entry.bytes;
            const old_len = test262_agents.reports.len;
            if (old_len == 1) {
                const allocator = test262PageAllocator();
                allocator.free(test262_agents.reports.ptr[0..test262_agents.reports_capacity]);
                test262_agents.reports = &.{};
                test262_agents.reports_capacity = 0;
                return report;
            }
            if (index + 1 < old_len) {
                @memmove(test262_agents.reports[index .. old_len - 1], test262_agents.reports[index + 1 .. old_len]);
            }
            test262_agents.reports = test262_agents.reports.ptr[0 .. old_len - 1];
            return report;
        }
    }
    return null;
}

pub fn test262AgentSweepReportsLocked(rt: *zjs.JSRuntime) void {
    const allocator = test262PageAllocator();
    var index: usize = 0;
    while (index < test262_agents.reports.len) {
        const entry = test262_agents.reports[index];
        if (entry.owner_runtime == rt) {
            allocator.free(entry.bytes);
            const old_len = test262_agents.reports.len;
            if (old_len == 1) {
                allocator.free(test262_agents.reports.ptr[0..test262_agents.reports_capacity]);
                test262_agents.reports = &.{};
                test262_agents.reports_capacity = 0;
                break;
            }
            if (index + 1 < old_len) {
                @memmove(test262_agents.reports[index .. old_len - 1], test262_agents.reports[index + 1 .. old_len]);
            }
            test262_agents.reports = test262_agents.reports.ptr[0 .. old_len - 1];
        } else {
            index += 1;
        }
    }
}

pub fn cleanupTest262Agents(rt: *zjs.JSRuntime) usize {
    const io = test262AgentIo();

    var agent_runtimes_buf: [16]*zjs.JSRuntime = undefined;
    var agent_runtimes_count: usize = 0;

    test262_agents.mutex.lockUncancelable(io);
    for (test262_agents.agents) |agent| {
        if (agent.owner_runtime == rt) {
            agent.done = true;
            if (agent.agent_runtime) |art| {
                if (agent_runtimes_count < agent_runtimes_buf.len) {
                    agent_runtimes_buf[agent_runtimes_count] = art;
                    agent_runtimes_count += 1;
                }
            }
        }
    }
    test262_agents.cond.broadcast(io);
    test262_agents.mutex.unlock(io);

    runtime_layer.wakeAtomicsWaitersForRuntimes(rt, agent_runtimes_buf[0..agent_runtimes_count]);

    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        test262_agents.mutex.lockUncancelable(io);
        var all_done = true;
        for (test262_agents.agents) |agent| {
            if (agent.owner_runtime == rt and !agent.thread_done) {
                all_done = false;
                break;
            }
        }
        test262_agents.mutex.unlock(io);
        if (all_done) break;
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }

    test262_agents.mutex.lockUncancelable(io);
    defer test262_agents.mutex.unlock(io);
    test262AgentSweepReportsLocked(rt);
    return test262AgentSweepCompletedLocked(rt);
}

pub fn test262AgentRecordCountForTests() usize {
    const io = test262AgentIo();
    test262_agents.mutex.lockUncancelable(io);
    defer test262_agents.mutex.unlock(io);
    return test262_agents.agents.len;
}

pub fn test262AgentInterruptHandler(rt: *zjs.JSRuntime, context: ?*anyopaque) bool {
    _ = rt;
    const agent: *Test262Agent = @ptrCast(@alignCast(context orelse return false));
    return agent.done;
}

pub fn test262AgentRun(agent: *Test262Agent) void {
    current_test262_agent = agent;
    defer current_test262_agent = null;
    defer {
        const io = test262AgentIo();
        test262_agents.mutex.lockUncancelable(io);
        agent.done = true;
        agent.thread_done = true;
        if (agent.broadcast_buffer) |*buffer| {
            buffer.release();
            agent.broadcast_buffer = null;
        }
        test262_agents.cond.broadcast(io);
        test262_agents.mutex.unlock(io);
    }

    const allocator = test262PageAllocator();
    const rt = zjs.JSRuntime.create(allocator) catch return;
    defer rt.destroy();
    rt.setCanBlock(true);
    rt.setInterruptHandler(test262AgentInterruptHandler, agent);

    {
        const io = test262AgentIo();
        test262_agents.mutex.lockUncancelable(io);
        agent.agent_runtime = rt;
        test262_agents.mutex.unlock(io);
    }

    const ctx = zjs.JSContext.create(rt) catch return;
    defer ctx.destroy();
    var event_loop = runtime_layer.EventLoop.init(ctx, .{});
    event_loop.install();
    defer event_loop.deinit();
    defer runtime_layer.cleanupAtomicsWaitersForContext(ctx);
    const global = ctx.globalObject() catch return;
    installTest262Globals(rt, ctx, global) catch return;
    const result = ctx.eval(agent.source, .{
        .mode = .script,
        .filename = "<test262-agent>",
        .discard_script_result = true,
    }) catch return;
    result.free(rt);
    ctx.runJobs(null) catch {};
    while (!test262AgentIsDone(agent)) {
        std.Io.sleep(test262AgentIo(), std.Io.Duration.fromMilliseconds(1), .awake) catch {};
        ctx.runJobs(null) catch return;
    }
}

pub fn test262AgentIsDone(agent: *Test262Agent) bool {
    const io = test262AgentIo();
    test262_agents.mutex.lockUncancelable(io);
    defer test262_agents.mutex.unlock(io);
    return agent.done;
}

pub fn qjsTest262AgentStart(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    if (args.len == 0) return error.TypeError;
    const source = try test262AgentStringValue(ctx, args[0]);
    var source_owned = true;
    errdefer if (source_owned) test262PageAllocator().free(source);
    const agent = try test262PageAllocator().create(Test262Agent);
    agent.* = .{ .source = source, .owner_runtime = ctx.runtimePtr() };
    source_owned = false;
    var agent_owned = true;
    var agent_registered = false;
    errdefer if (agent_registered) {
        test262AgentRemove(agent);
    } else if (agent_owned) {
        test262AgentDestroy(agent);
    };
    try test262AgentAppend(agent);
    agent_registered = true;
    const thread = try std.Thread.spawn(.{}, test262AgentRun, .{agent});
    thread.detach();
    agent_owned = false;
    agent_registered = false;
    return zjs.JSValue.undefinedValue();
}

pub fn qjsTest262AgentBroadcast(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    if (args.len == 0) return error.TypeError;
    var shared_buffer = try ctx.retainSharedArrayBuffer(args[0]);
    defer shared_buffer.release();
    const io = test262AgentIo();
    test262_agents.mutex.lockUncancelable(io);
    defer test262_agents.mutex.unlock(io);
    _ = test262AgentSweepCompletedLocked(ctx.runtimePtr());
    for (test262_agents.agents) |agent| {
        if (agent.owner_runtime != ctx.runtimePtr()) continue;
        if (agent.done) continue;
        if (agent.broadcast_buffer) |*old| old.release();
        agent.broadcast_buffer = shared_buffer.retain();
    }
    test262_agents.cond.broadcast(io);
    return zjs.JSValue.undefinedValue();
}

pub fn qjsTest262AgentReceiveBroadcast(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    const agent = current_test262_agent orelse return error.TypeError;
    if (args.len == 0 or !ctx.isCallable(args[0])) return error.TypeError;

    const io = test262AgentIo();
    test262_agents.mutex.lockUncancelable(io);
    while (agent.broadcast_buffer == null and !agent.done) {
        test262_agents.cond.waitUncancelable(io, &test262_agents.mutex);
    }
    var shared_buffer = agent.broadcast_buffer orelse {
        test262_agents.mutex.unlock(io);
        return zjs.JSValue.undefinedValue();
    };
    agent.broadcast_buffer = null;
    test262_agents.mutex.unlock(io);
    defer shared_buffer.release();

    const sab = try ctx.sharedArrayBufferFromRef(shared_buffer);
    defer sab.free(ctx.runtimePtr());
    const callback_result = try ctx.callFunction(args[0], &.{sab}, .{
        .output = output,
        .realm_global = global,
    });
    callback_result.free(ctx.runtimePtr());
    return zjs.JSValue.undefinedValue();
}

pub fn qjsTest262AgentReport(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    const value = if (args.len >= 1) args[0] else zjs.JSValue.undefinedValue();
    const bytes = try test262AgentStringValue(ctx, value);
    errdefer test262PageAllocator().free(bytes);
    const owner_runtime = if (current_test262_agent) |agent| agent.owner_runtime else ctx.runtimePtr();
    try test262AgentEnqueueReport(owner_runtime, bytes);
    return zjs.JSValue.undefinedValue();
}

pub fn qjsTest262AgentGetReport(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    _ = args;
    const allocator = test262PageAllocator();
    const io = test262AgentIo();
    test262_agents.mutex.lockUncancelable(io);
    _ = test262AgentSweepCompletedLocked(ctx.runtimePtr());
    const report = test262AgentTakeReportLocked(ctx.runtimePtr()) orelse {
        test262_agents.mutex.unlock(io);
        return zjs.JSValue.nullValue();
    };
    test262_agents.mutex.unlock(io);
    defer allocator.free(report);
    return ctx.createString(report);
}

pub fn qjsTest262AgentLeaving(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = ctx;
    _ = output;
    _ = global;
    _ = args;
    if (current_test262_agent) |agent| {
        const io = test262AgentIo();
        test262_agents.mutex.lockUncancelable(io);
        agent.done = true;
        test262_agents.cond.broadcast(io);
        test262_agents.mutex.unlock(io);
    }
    return zjs.JSValue.undefinedValue();
}

pub fn qjsTest262AgentSleep(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    const value = if (args.len >= 1) args[0] else zjs.JSValue.int32(0);
    const number = value.asNumber() orelse 0;
    if (number > 0) {
        const ms: i64 = @intFromFloat(@min(number, 60_000));
        std.Io.sleep(test262AgentIo(), std.Io.Duration.fromMilliseconds(ms), .awake) catch {};
    }
    _ = ctx;
    return zjs.JSValue.undefinedValue();
}

pub fn qjsTest262AgentMonotonicNow(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = ctx;
    _ = output;
    _ = global;
    _ = args;
    const now = std.Io.Timestamp.now(test262AgentIo(), .awake);
    return zjs.JSValue.float64(@as(f64, @floatFromInt(now.nanoseconds)) / std.time.ns_per_ms);
}

pub fn installTest262Globals(rt: *zjs.JSRuntime, ctx: *zjs.JSContext, global: *zjs.Object) !void {
    try defineGlobalExternalHostFunction(rt, ctx, global, "Test262Error", 1, wrapExternal(hostCallTest262Error), true);
    try defineGlobalExternalHostFunction(rt, ctx, global, "verifyProperty", 3, wrapExternal(hostCallVerifyProperty), false);
    try defineGlobalExternalHostFunction(rt, ctx, global, "verifyCallableProperty", 4, wrapExternal(hostCallVerifyCallableProperty), false);
    try defineGlobalExternalHostFunction(rt, ctx, global, "verifyNotWritable", 2, wrapExternal(hostCallVerifyNotWritable), false);
    try defineGlobalExternalHostFunction(rt, ctx, global, "verifyNotEnumerable", 2, wrapExternal(hostCallVerifyNotEnumerable), false);
    try defineGlobalExternalHostFunction(rt, ctx, global, "verifyConfigurable", 2, wrapExternal(hostCallVerifyConfigurable), false);
    try defineGlobalExternalHostFunction(rt, ctx, global, "isConstructor", 1, wrapExternal(hostCallIsConstructor), false);
    try defineGlobalExternalHostFunction(rt, ctx, global, "setTimeout", 2, wrapExternal(hostCallSetTimeout), false);
    try installAssertObject(rt, ctx, global);

    const ns_val = try ctx.getProperty(global.value(), "$262");
    defer ns_val.free(rt);

    var created_ns = false;
    const ns_target = if (ns_val.isObject()) ns_val else result: {
        const obj_val = try ctx.createObject();
        try ctx.defineDataProperty(global.value(), "$262", obj_val, .{ .enumerable = true });
        created_ns = true;
        break :result obj_val;
    };
    defer if (created_ns) ns_target.free(rt);

    const agent_val = try ctx.createObject();
    defer agent_val.free(rt);

    const agent_methods = [_]struct {
        name: []const u8,
        length: i32,
        call: zjs.ExternalHostCallFn,
    }{
        .{ .name = "start", .length = 1, .call = wrapExternal(qjsTest262AgentStart) },
        .{ .name = "broadcast", .length = 1, .call = wrapExternal(qjsTest262AgentBroadcast) },
        .{ .name = "receiveBroadcast", .length = 0, .call = wrapExternal(qjsTest262AgentReceiveBroadcast) },
        .{ .name = "report", .length = 1, .call = wrapExternal(qjsTest262AgentReport) },
        .{ .name = "getReport", .length = 0, .call = wrapExternal(qjsTest262AgentGetReport) },
        .{ .name = "leaving", .length = 0, .call = wrapExternal(qjsTest262AgentLeaving) },
        .{ .name = "sleep", .length = 1, .call = wrapExternal(qjsTest262AgentSleep) },
        .{ .name = "monotonicNow", .length = 0, .call = wrapExternal(qjsTest262AgentMonotonicNow) },
    };

    inline for (agent_methods) |m| {
        const func_val = try createExternalHostFunction(rt, ctx, m.name, m.length, m.call);
        defer func_val.free(rt);
        try ctx.defineDataProperty(agent_val, m.name, func_val, .{ .enumerable = false });
    }

    try ctx.defineDataProperty(ns_target, "agent", agent_val, .{ .enumerable = false });

    // Register evalScript on $262
    {
        const func_val = try createExternalHostFunction(rt, ctx, "evalScript", 1, wrapExternalWithFunc(qjsTest262EvalScript));
        defer func_val.free(rt);
        try ctx.defineDataProperty(ns_target, "evalScript", func_val, .{ .enumerable = false });
    }

    // Register IsHTMLDDA on $262
    {
        const func_val = try createExternalHostFunction(rt, ctx, "IsHTMLDDA", 0, wrapExternal(hostCallIsHtmlDda));
        defer func_val.free(rt);
        const is_html_dda_obj = test262InternalObjectFromValue(func_val).?;
        is_html_dda_obj.flags.is_html_dda = true;

        try ctx.defineDataProperty(ns_target, "IsHTMLDDA", func_val, .{ .enumerable = false });
    }

    // Register createRealm on $262
    {
        const func_val = try createExternalHostFunction(rt, ctx, "createRealm", 0, wrapExternal(qjsTest262CreateRealm));
        defer func_val.free(rt);
        try ctx.defineDataProperty(ns_target, "createRealm", func_val, .{ .enumerable = false });
    }

    // Register detachArrayBuffer on $262
    {
        const func_val = try createExternalHostFunction(rt, ctx, "detachArrayBuffer", 1, wrapExternal(qjsTest262DetachArrayBuffer));
        defer func_val.free(rt);
        try ctx.defineDataProperty(ns_target, "detachArrayBuffer", func_val, .{ .enumerable = false });
    }

    // Register gc on $262
    {
        const func_val = try createExternalHostFunction(rt, ctx, "gc", 0, wrapExternal(qjsTest262Gc));
        defer func_val.free(rt);
        try ctx.defineDataProperty(ns_target, "gc", func_val, .{ .enumerable = false });
    }
}

fn installAssertObject(rt: *zjs.JSRuntime, ctx: *zjs.JSContext, global: *zjs.Object) !void {
    const assert_val = try createExternalHostFunction(rt, ctx, "assert", 1, wrapExternal(hostCallAssertTrue));
    defer assert_val.free(rt);
    const methods = [_]struct {
        name: []const u8,
        length: i32,
        call: zjs.ExternalHostCallFn,
    }{
        .{ .name = "sameValue", .length = 2, .call = wrapExternal(hostCallAssertSameValue) },
        .{ .name = "notSameValue", .length = 2, .call = wrapExternal(hostCallAssertNotSameValue) },
        .{ .name = "compareArray", .length = 2, .call = wrapExternal(hostCallCompareArray) },
        .{ .name = "throws", .length = 2, .call = wrapExternal(hostCallAssertThrows) },
    };
    inline for (methods) |method| {
        const method_val = try createExternalHostFunction(rt, ctx, method.name, method.length, method.call);
        defer method_val.free(rt);
        try ctx.defineDataProperty(assert_val, method.name, method_val, .{});
    }
    try ctx.defineDataProperty(global.value(), "assert", assert_val, .{});
}

fn defineGlobalExternalHostFunction(
    rt: *zjs.JSRuntime,
    ctx: *zjs.JSContext,
    global: *zjs.Object,
    name: []const u8,
    length: i32,
    call: zjs.ExternalHostCallFn,
    with_prototype: bool,
) !void {
    const func_val = try createExternalHostFunctionWithRealm(rt, ctx, name, length, call, with_prototype, global);
    defer func_val.free(rt);
    try ctx.defineDataProperty(global.value(), name, func_val, .{});
}

fn hostCallTest262Error(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    const message = if (args.len > 0) try stringBytes(ctx, args[0]) else "";
    defer if (args.len > 0) ctx.runtimePtr().memory.allocator.free(message);
    return createTest262ErrorValue(ctx, global, message);
}

fn hostCallAssertSameValue(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = ctx;
    _ = output;
    _ = global;
    return assertSameValueArgs(args);
}

fn hostCallAssertTrue(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = ctx;
    _ = output;
    _ = global;
    if (args.len < 1 or args[0].asBool() != true) return error.JSException;
    return zjs.JSValue.undefinedValue();
}

fn hostCallAssertNotSameValue(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = ctx;
    _ = output;
    _ = global;
    if (args.len < 2) return error.TypeError;
    if (args[0].sameValue(args[1])) return error.JSException;
    return zjs.JSValue.undefinedValue();
}

fn hostCallAssertThrows(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    if (args.len < 2) return error.TypeError;
    const expected_name = try ctx.functionName(args[0], ctx.runtimePtr().memory.allocator);
    defer ctx.runtimePtr().memory.allocator.free(expected_name);
    const result = ctx.callFunction(args[1], &.{}, .{
        .output = output,
        .realm_global = global,
    }) catch |err| {
        if (err == error.JSException and ctx.hasException()) {
            if (try ctx.consumePendingExceptionIfErrorName(expected_name)) {
                return zjs.JSValue.undefinedValue();
            }
            return error.JSException;
        }
        if (ctx.runtimeErrorMatchesErrorName(err, expected_name)) {
            ctx.clearException();
            return zjs.JSValue.undefinedValue();
        }
        return error.JSException;
    };
    defer result.free(ctx.runtimePtr());
    return error.JSException;
}

fn hostCallVerifyProperty(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    return hostVerifyProperty(ctx, args, false);
}

fn hostCallVerifyCallableProperty(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    return hostVerifyProperty(ctx, args, true);
}

fn hostCallIsConstructor(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    if (args.len < 1) return error.TypeError;
    return zjs.JSValue.boolean(ctx.isConstructor(args[0]));
}

fn hostCallVerifyNotWritable(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    return hostVerifyPropertyFlag(ctx, args, .not_writable);
}

fn hostCallVerifyNotEnumerable(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    return hostVerifyPropertyFlag(ctx, args, .not_enumerable);
}

fn hostCallVerifyConfigurable(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    return hostVerifyPropertyFlag(ctx, args, .configurable);
}

fn hostCallCompareArray(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    if (args.len < 2) return error.TypeError;
    if (!try ctx.isArray(args[0]) or !try ctx.isArray(args[1])) return error.JSException;
    const actual_length = try ctx.arrayLength(args[0]);
    if (actual_length != try ctx.arrayLength(args[1])) return error.JSException;
    var index: u32 = 0;
    while (index < actual_length) : (index += 1) {
        const lhs = try ctx.getIndex(args[0], index);
        defer lhs.free(ctx.runtimePtr());
        const rhs = try ctx.getIndex(args[1], index);
        defer rhs.free(ctx.runtimePtr());
        if (!lhs.sameValue(rhs)) return error.JSException;
    }
    return zjs.JSValue.undefinedValue();
}

fn hostCallSetTimeout(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    const active_global = global orelse try ctx.globalObject();
    const callback = if (args.len >= 1) args[0] else zjs.JSValue.undefinedValue();
    if (!ctx.isCallable(callback)) return try ctx.throwError("TypeError", "not a function", .{ .realm_global = active_global });
    var delay = try test262Int64Arg(ctx, args, 1);
    if (delay < 1) delay = 1;
    const host_event_loop = ctx.hostEventLoop() orelse return error.TypeError;
    const id = host_event_loop.nextTimerId();
    try host_event_loop.enqueueTimer(&ctx.core, id, callback, @intCast(delay), false);
    return int64ResultValue(id);
}

fn assertSameValueArgs(values: []const zjs.JSValue) !zjs.JSValue {
    if (values.len < 2) return error.TypeError;
    if (!values[0].sameValue(values[1])) return error.JSException;
    return zjs.JSValue.undefinedValue();
}

fn hostVerifyProperty(ctx: *zjs.JSContext, values: []const zjs.JSValue, callable: bool) !zjs.JSValue {
    const rt = ctx.runtimePtr();
    const desc_index: usize = if (callable) 4 else 2;
    if ((!callable and values.len <= desc_index) or (callable and values.len < 4)) return error.TypeError;

    var original = (try ctx.ownPropertyDescriptor(values[0], values[1], .{})) orelse {
        if (values[desc_index].isUndefined()) return zjs.JSValue.boolean(true);
        return error.JSException;
    };
    defer original.destroy(rt);

    if (callable) {
        const actual = try ctx.getPropertyKey(values[0], values[1], .{});
        defer actual.free(rt);
        if (!ctx.isCallable(actual)) return error.JSException;
        const expected_name = try stringBytes(ctx, values[2]);
        defer rt.memory.allocator.free(expected_name);
        const actual_name = try ctx.functionName(actual, rt.memory.allocator);
        defer rt.memory.allocator.free(actual_name);
        if (!std.mem.eql(u8, expected_name, actual_name)) return error.JSException;
        const expected_length = values[3].asInt32() orelse return error.JSException;
        const length_value = try ctx.getProperty(actual, "length");
        defer length_value.free(rt);
        if (length_value.asInt32() != expected_length) return error.JSException;
        if (values.len <= desc_index or values[desc_index].isUndefined()) return zjs.JSValue.boolean(true);
    }

    try verifyDescriptorObject(ctx, original, values[desc_index]);
    return zjs.JSValue.boolean(true);
}

const VerifyFlag = enum {
    not_writable,
    not_enumerable,
    configurable,
};

fn hostVerifyPropertyFlag(ctx: *zjs.JSContext, values: []const zjs.JSValue, flag: VerifyFlag) !zjs.JSValue {
    const rt = ctx.runtimePtr();
    if (values.len < 2) return error.TypeError;
    const desc = (try ctx.ownPropertyDescriptor(values[0], values[1], .{})) orelse return error.JSException;
    defer desc.destroy(rt);
    switch (flag) {
        .not_writable => if (desc.kind == .data and (desc.writable orelse false)) return error.JSException,
        .not_enumerable => if (desc.enumerable orelse false) return error.JSException,
        .configurable => if (!(desc.configurable orelse false)) return error.JSException,
    }
    return zjs.JSValue.undefinedValue();
}

fn verifyDescriptorObject(ctx: *zjs.JSContext, actual: zjs.PropertyDescriptor, expected: zjs.JSValue) !void {
    const rt = ctx.runtimePtr();
    if (try expectedHas(ctx, expected, "value")) {
        const expected_value = try expectedValue(ctx, expected, "value");
        defer expected_value.free(rt);
        if (!actual.value.sameValue(expected_value)) return error.JSException;
    }
    if (try expectedHas(ctx, expected, "writable")) {
        const writable_value = try expectedValue(ctx, expected, "writable");
        defer writable_value.free(rt);
        const expected_writable = writable_value.asBool() orelse return error.JSException;
        if (actual.writable != expected_writable) return error.JSException;
    }
    if (try expectedHas(ctx, expected, "enumerable")) {
        const enumerable_value = try expectedValue(ctx, expected, "enumerable");
        defer enumerable_value.free(rt);
        const expected_enumerable = enumerable_value.asBool() orelse return error.JSException;
        if (actual.enumerable != expected_enumerable) return error.JSException;
    }
    if (try expectedHas(ctx, expected, "configurable")) {
        const configurable_value = try expectedValue(ctx, expected, "configurable");
        defer configurable_value.free(rt);
        const expected_configurable = configurable_value.asBool() orelse return error.JSException;
        if (actual.configurable != expected_configurable) return error.JSException;
    }
    if (try expectedHas(ctx, expected, "get")) {
        const expected_getter = try expectedValue(ctx, expected, "get");
        defer expected_getter.free(rt);
        if (!actual.getter.sameValue(expected_getter)) return error.JSException;
    }
    if (try expectedHas(ctx, expected, "set")) {
        const expected_setter = try expectedValue(ctx, expected, "set");
        defer expected_setter.free(rt);
        if (!actual.setter.sameValue(expected_setter)) return error.JSException;
    }
}

fn expectedHas(ctx: *zjs.JSContext, object: zjs.JSValue, name: []const u8) !bool {
    return ctx.hasOwnProperty(object, name);
}

fn expectedValue(ctx: *zjs.JSContext, object: zjs.JSValue, name: []const u8) !zjs.JSValue {
    return ctx.getProperty(object, name);
}

fn stringBytes(ctx: *zjs.JSContext, value: zjs.JSValue) ![]u8 {
    const string = value.asString() orelse return error.TypeError;
    return string.toOwnedUtf8(ctx.runtimePtr().memory.allocator);
}

fn test262Int64Arg(ctx: *zjs.JSContext, args: []const zjs.JSValue, index: usize) !i64 {
    const value = if (index < args.len) args[index] else zjs.JSValue.undefinedValue();
    const number = try ctx.toIntegerOrInfinity(value);
    if (!std.math.isFinite(number) or std.math.isNan(number)) return 0;
    return @intFromFloat(number);
}

fn int64ResultValue(value: i64) zjs.JSValue {
    return zjs.JSValue.number(@floatFromInt(value));
}

fn test262InternalObjectFromValue(value: zjs.JSValue) ?*zjs.Object {
    const header = value.refHeader() orelse return null;
    if (header.meta().kind != .object) return null;
    return @fieldParentPtr("header", header);
}

fn hostCallIsHtmlDda(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = ctx;
    _ = output;
    _ = global;
    _ = args;
    return zjs.JSValue.nullValue();
}

fn qjsTest262CreateRealm(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    _ = args;
    const realm_value = try ctx.createRealm();
    errdefer realm_value.free(ctx.runtimePtr());
    const realm_global = try ctx.realmGlobalObject(realm_value);
    const eval_func = try createExternalHostFunctionWithRealm(ctx.runtimePtr(), ctx, "evalScript", 1, wrapExternalWithFunc(qjsTest262EvalScript), false, realm_global);
    defer eval_func.free(ctx.runtimePtr());
    try ctx.defineDataProperty(realm_value, "evalScript", eval_func, .{});
    return realm_value;
}

fn qjsTest262DetachArrayBuffer(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    if (args.len < 1) return error.TypeError;
    return try runtime_layer.detachArrayBuffer(&ctx.core, args[0]);
}

fn qjsTest262Gc(
    ctx: *zjs.JSContext,
    output: ?*std.Io.Writer,
    global: ?*zjs.Object,
    args: []const zjs.JSValue,
) !zjs.JSValue {
    _ = output;
    _ = global;
    _ = args;
    _ = ctx.runtimePtr().runObjectCycleRemoval();
    return zjs.JSValue.undefinedValue();
}

fn wrapExternal(comptime f: anytype) zjs.ExternalHostCallFn {
    return struct {
        fn call(ptr: *anyopaque, c: zjs.ExternalHostCall) anyerror!zjs.JSValue {
            _ = ptr;
            const ctx: *zjs.JSContext = @ptrCast(@alignCast(c.ctx));
            return f(ctx, c.output, c.global, c.args) catch |err| {
                try ensureTest262HarnessException(ctx, c.global, err);
                return err;
            };
        }
    }.call;
}

fn wrapExternalWithFunc(comptime f: anytype) zjs.ExternalHostCallFn {
    return struct {
        fn call(ptr: *anyopaque, c: zjs.ExternalHostCall) anyerror!zjs.JSValue {
            _ = ptr;
            const ctx: *zjs.JSContext = @ptrCast(@alignCast(c.ctx));
            const global = c.global orelse c.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
            return f(ctx, c.output, global, c.func_obj, c.args) catch |err| {
                try ensureTest262HarnessException(ctx, global, err);
                return err;
            };
        }
    }.call;
}

fn ensureTest262HarnessException(ctx: *zjs.JSContext, global: ?*zjs.Object, err: anyerror) !void {
    if (err != error.JSException or ctx.hasException()) return;
    _ = throwTest262HarnessError(ctx, global, "") catch |throw_err| switch (throw_err) {
        error.JSException => return,
        else => return throw_err,
    };
}

fn throwTest262HarnessError(ctx: *zjs.JSContext, global: ?*zjs.Object, message: []const u8) !zjs.JSValue {
    return ctx.throwError("Test262Error", message, .{ .realm_global = global });
}

fn createTest262ErrorValue(ctx: *zjs.JSContext, global: ?*zjs.Object, message: []const u8) !zjs.JSValue {
    return ctx.createError("Test262Error", message, .{ .realm_global = global });
}

fn createExternalHostFunction(
    runtime: *zjs.JSRuntime,
    context: *zjs.JSContext,
    name: []const u8,
    length: i32,
    call: zjs.ExternalHostCallFn,
) !zjs.JSValue {
    return createExternalHostFunctionWithRealm(runtime, context, name, length, call, false, null);
}

fn createExternalHostFunctionWithRealm(
    runtime: *zjs.JSRuntime,
    context: *zjs.JSContext,
    name: []const u8,
    length: i32,
    call: zjs.ExternalHostCallFn,
    with_prototype: bool,
    realm_global: ?*zjs.Object,
) !zjs.JSValue {
    std.debug.assert(runtime == context.runtimePtr());
    return context.createExternalFunction(name, length, &test262_external_host_context, call, null, .{
        .with_prototype = with_prototype,
        .realm_global = realm_global,
    });
}

pub fn test262AgentStringValue(ctx: *zjs.JSContext, value: zjs.JSValue) ![]u8 {
    return ctx.toOwnedUtf8(value, test262PageAllocator());
}

test "test262 args parse QuickJS-shaped config and root" {
    const config = try parseArgs(&.{ "-c", "test262.conf", "-m", "-t", "1", "test262/test" });
    try std.testing.expectEqualStrings("test262.conf", config.config_path.?);
    try std.testing.expect(config.module);
    try std.testing.expectEqual(@as(u32, 1), config.threads);
    try std.testing.expectEqualStrings("test262/test", config.test_root.?);
}

test "test262 globals do not retain local namespace object reference" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();
    const global = try ctx.globalObject();

    try installTest262Globals(rt, ctx, global);

    const ns_key = try rt.internAtom("$262");
    defer rt.atoms.free(ns_key);
    const ns_val = global.getProperty(ns_key);
    var weak = try rt.createWeakPersistentValue(ns_val, null, null);
    defer weak.deinit();
    ns_val.free(rt);

    try std.testing.expect(weak.isAlive());
    try std.testing.expect(try ctx.deleteProperty(global.value(), "$262"));
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(!weak.isAlive());
}

test "test262 evalScript uses the installed function realm" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();
    const global = try ctx.globalObject();

    const realm = try ctx.createRealm();
    defer realm.free(rt);
    const realm_global = try ctx.realmGlobal(realm);
    defer realm_global.free(rt);
    const realm_global_object = try ctx.realmGlobalObject(realm);
    try ctx.defineDataProperty(realm_global, "realmMarker", zjs.JSValue.int32(30), .{});

    const eval_func = try createExternalHostFunctionWithRealm(rt, ctx, "evalScript", 1, wrapExternalWithFunc(qjsTest262EvalScript), false, realm_global_object);
    defer eval_func.free(rt);

    const source = try ctx.createString("realmMarker + 12");
    defer source.free(rt);
    const result = try ctx.callFunction(eval_func, &.{source}, .{ .realm_global = global });
    defer result.free(rt);
    try std.testing.expectEqual(@as(?i32, 42), result.asInt32());
}

test "test262 agent string conversion follows JavaScript ToString" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const numeric = try test262AgentStringValue(ctx, zjs.JSValue.int32(123));
    defer test262PageAllocator().free(numeric);
    try std.testing.expectEqualStrings("123", numeric);

    const object = try ctx.eval("({ toString() { return 'agent-object-string'; } })", .{});
    defer object.free(rt);
    const object_text = try test262AgentStringValue(ctx, object);
    defer test262PageAllocator().free(object_text);
    try std.testing.expectEqualStrings("agent-object-string", object_text);
}

test "test262 timer integer conversion follows JavaScript ToNumber" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const object = try ctx.eval("({ valueOf() { return 7.9; } })", .{});
    defer object.free(rt);

    const converted = try test262Int64Arg(ctx, &.{ zjs.JSValue.undefinedValue(), object }, 1);
    try std.testing.expectEqual(@as(i64, 7), converted);
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
    try runWorkerStride(
        std.testing.allocator,
        std.testing.io,
        "zig-out/bin/zjs",
        false,
        null,
        "",
        &.{"tests/fixtures/test262/harness/asyncHelpers.js"},
        known,
        skipped,
        &next_index,
        0,
        null,
        false,
        null,
        &summary,
        &current,
    );

    try std.testing.expectEqual(@as(usize, 0), summary.passed);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    try std.testing.expectEqual(@as(usize, 1), summary.fixed);
    try std.testing.expectEqual(@as(usize, 0), current.items.len);
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
        var parsed = try parser.compile(rt, source, .{
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
        var parsed = try parser.compile(rt, source, .{
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

test "test262 args parse --regression-baseline" {
    const config = try parseArgs(&.{
        "-c",                    "test262.conf",
        "--regression-baseline", "reports/test262-baseline/test262-by-dir.json",
        "test262/test",
    });
    try std.testing.expectEqualStrings(
        "reports/test262-baseline/test262-by-dir.json",
        config.regression_baseline.?,
    );
}

test "test262 baseline parser reads dir + passed pairs from by-dir.json" {
    const sample =
        \\[
        \\  { "dir": "annexB/built-ins", "passed": 2, "failed": 212, "known_failed": 0 },
        \\  { "dir": "built-ins/Array", "passed": 233, "failed": 2848, "known_failed": 0 },
        \\  { "dir": "language/expressions", "passed": 100, "failed": 50, "known_failed": 5 }
        \\]
    ;
    const entries = try parseBaseline(std.testing.allocator, sample);
    defer freeBaseline(std.testing.allocator, entries);

    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("annexB/built-ins", entries[0].dir);
    try std.testing.expectEqual(@as(usize, 2), entries[0].passed);
    try std.testing.expectEqualStrings("built-ins/Array", entries[1].dir);
    try std.testing.expectEqual(@as(usize, 233), entries[1].passed);
    try std.testing.expectEqualStrings("language/expressions", entries[2].dir);
    try std.testing.expectEqual(@as(usize, 100), entries[2].passed);
}

test "test262 checkRegressions detects passed-count drops" {
    var reporter = Reporter.initQuiet(std.testing.allocator, null);
    defer reporter.deinit();

    try reporter.recordResult(std.testing.io, "test/A/x1.js", .passed, "", false);
    try reporter.recordResult(std.testing.io, "test/B/x1.js", .passed, "", false);
    try reporter.recordResult(std.testing.io, "test/B/x2.js", .passed, "", false);
    try reporter.recordResult(std.testing.io, "test/B/x3.js", .passed, "", false);
    try reporter.recordResult(std.testing.io, "test/B/x4.js", .passed, "", false);
    try reporter.recordResult(std.testing.io, "test/B/x5.js", .passed, "", false);
    try reporter.recordResult(std.testing.io, "test/C/x1.js", .passed, "", false);
    try reporter.recordResult(std.testing.io, "test/C/x2.js", .passed, "", false);
    try reporter.recordResult(std.testing.io, "test/C/x3.js", .passed, "", false);
    try reporter.recordResult(std.testing.io, "test/C/x4.js", .passed, "", false);
    try reporter.recordResult(std.testing.io, "test/C/x5.js", .passed, "", false);
    try reporter.recordResult(std.testing.io, "test/C/x6.js", .passed, "", false);
    try reporter.recordResult(std.testing.io, "test/C/x7.js", .passed, "", false);

    const baseline = [_]BaselineEntry{
        .{ .dir = "test/A", .passed = 2 },
        .{ .dir = "test/B", .passed = 5 },
        .{ .dir = "test/C", .passed = 3 },
        .{ .dir = "test/D", .passed = 9 },
    };
    const result = try checkRegressions(std.testing.io, &reporter, &baseline);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqual(@as(usize, 3), result.matched);
}

test "test262 checkRegressions returns zero when all dirs hold or improve" {
    var reporter = Reporter.init(std.testing.allocator, null);
    defer reporter.deinit();
    try reporter.recordResult(std.testing.io, "test/A/x1.js", .passed, "", false);
    try reporter.recordResult(std.testing.io, "test/A/x2.js", .passed, "", false);
    const baseline = [_]BaselineEntry{
        .{ .dir = "test/A", .passed = 2 },
    };
    const result = try checkRegressions(std.testing.io, &reporter, &baseline);
    try std.testing.expectEqual(@as(usize, 0), result.count);
    try std.testing.expectEqual(@as(usize, 1), result.matched);
}

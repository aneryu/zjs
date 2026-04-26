const std = @import("std");
const engine = @import("quickjs_zig_engine");

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
        for (self.features.items) |feature| {
            if (skipped_features.contains(feature)) return true;
        }
        return false;
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
    threads: u32 = 1,
    known_error_file: ?[]const u8 = null,
    start_index: ?usize = null,
    stop_index: ?usize = null,
    files: BoundedList = .{},
    dirs: BoundedList = .{},

    pub fn selectedCount(self: Config) usize {
        return self.files.len + self.dirs.len + @as(usize, if (self.test_root != null) 1 else 0);
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
            if (config.threads == 0) return error.Usage;
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
    enabled_features: NameList,
    skipped_features: NameList,

    pub fn init(allocator: std.mem.Allocator) LoadedConfig {
        return .{
            .excludes = NameList.init(allocator),
            .enabled_features = NameList.init(allocator),
            .skipped_features = NameList.init(allocator),
        };
    }

    pub fn deinit(self: *LoadedConfig, allocator: std.mem.Allocator) void {
        if (self.testdir) |value| allocator.free(value);
        if (self.harnessdir) |value| allocator.free(value);
        if (self.errorfile) |value| allocator.free(value);
        self.excludes.deinit();
        self.enabled_features.deinit();
        self.skipped_features.deinit();
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

const WorkerContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    zjs_path: []const u8,
    harnessdir: ?[]const u8,
    harness_prelude: []const u8,
    tests: []const []const u8,
    known_errors: NameList,
    skipped_features: NameList,
    worker_index: usize,
    worker_count: usize,
    verbose: u8,
    timeout_ms: ?u32,
    global_module: bool,
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
        for (self.items) |item| {
            if (std.mem.eql(u8, item, needle)) return true;
            if (std.mem.endsWith(u8, item, "/") and std.mem.startsWith(u8, needle, item)) return true;
        }
        return false;
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
            .exclude => try loaded.excludes.appendOwned(try composePath(allocator, base_dir, line)),
            .tests, .none => {},
        }
    }

    loaded.excludes.sortAndDedupe();
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

    const worker_count = @max(@as(usize, 1), @min(@as(usize, @intCast(config.threads)), prepared.tests.items.len));
    const test_allocator = std.heap.smp_allocator;
    if (worker_count == 1) {
        try runWorkerStride(
            test_allocator,
            io,
            zjs_path,
            summary.selection.harnessdir,
            harness_prelude,
            prepared.tests.items,
            known_errors,
            prepared.skipped_features,
            0,
            1,
            config.verbose,
            config.timeout_ms,
            config.module,
            &summary,
            &current_failures,
        );
    } else {
        var results = try allocator.alloc(WorkerResult, worker_count);
        defer allocator.free(results);
        var contexts = try allocator.alloc(WorkerContext, worker_count);
        defer allocator.free(contexts);
        var threads = try allocator.alloc(std.Thread, worker_count);
        defer allocator.free(threads);

        for (results) |*result| result.* = WorkerResult.init(test_allocator);
        defer for (results) |*result| result.deinit();

        var spawned: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < spawned) : (i += 1) threads[i].join();
        }
        while (spawned < worker_count) : (spawned += 1) {
            contexts[spawned] = .{
                .allocator = test_allocator,
                .io = io,
                .zjs_path = zjs_path,
                .harnessdir = summary.selection.harnessdir,
                .harness_prelude = harness_prelude,
                .tests = prepared.tests.items,
                .known_errors = known_errors,
                .skipped_features = prepared.skipped_features,
                .worker_index = spawned,
                .worker_count = worker_count,
                .verbose = config.verbose,
                .timeout_ms = config.timeout_ms,
                .global_module = config.module,
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

    prepared.tests.deinit();
    prepared.skipped_features.deinit();
    return summary;
}

fn runWorkerThread(context: *WorkerContext) void {
    var summary = ExecutionSummary{ .selection = .{} };
    runWorkerStride(
        context.allocator,
        context.io,
        context.zjs_path,
        context.harnessdir,
        context.harness_prelude,
        context.tests,
        context.known_errors,
        context.skipped_features,
        context.worker_index,
        context.worker_count,
        context.verbose,
        context.timeout_ms,
        context.global_module,
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
    zjs_path: []const u8,
    harnessdir: ?[]const u8,
    harness_prelude: []const u8,
    tests: []const []const u8,
    known_errors: NameList,
    skipped_features: NameList,
    worker_index: usize,
    worker_count: usize,
    verbose: u8,
    timeout_ms: ?u32,
    global_module: bool,
    summary: *ExecutionSummary,
    current_failures: *NameList,
) !void {
    var harness_cache = HarnessCache.init(allocator, io, harnessdir);
    defer harness_cache.deinit();

    var index = worker_index;
    while (index < tests.len) : (index += worker_count) {
        const test_path = tests[index];
        const result = try runOneTest(allocator, io, zjs_path, &harness_cache, harness_prelude, test_path, verbose, timeout_ms, global_module, skipped_features);
        if (result == .skipped) {
            summary.selection.skipped_by_feature += 1;
            continue;
        }
        const is_known = known_errors.findSortedExact(test_path) != null;
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
        if (loaded.excludes.contains(test_path)) {
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

fn enumerateTests(allocator: std.mem.Allocator, io: std.Io, tests: *NameList, root: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
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
    while (true) {
        const lc: u8 = if (i < lhs.len) lhs[i] else 0;
        const rc: u8 = if (j < rhs.len) rhs[j] else 0;
        i += @as(usize, if (i < lhs.len) 1 else 0);
        j += @as(usize, if (j < rhs.len) 1 else 0);
        if (std.ascii.isDigit(lc) and std.ascii.isDigit(rc)) {
            var ln: usize = lc - '0';
            var rn: usize = rc - '0';
            while (i < lhs.len and std.ascii.isDigit(lhs[i])) : (i += 1) ln = ln * 10 + lhs[i] - '0';
            while (j < rhs.len and std.ascii.isDigit(rhs[j])) : (j += 1) rn = rn * 10 + rhs[j] - '0';
            if (ln < rn) return -1;
            if (ln > rn) return 1;
        }
        if (lc < rc) return -1;
        if (lc > rc) return 1;
        if (lc == 0) return 0;
    }
}

const TestRunResult = enum { passed, failed, skipped };

fn runOneTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    zjs_path: []const u8,
    harness_cache: *HarnessCache,
    harness_prelude: []const u8,
    test_path: []const u8,
    verbose: u8,
    timeout_ms: ?u32,
    global_module: bool,
    skipped_features: NameList,
) !TestRunResult {
    _ = zjs_path;
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    const test_source = try std.Io.Dir.cwd().readFileAlloc(io, test_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(test_source);

    var metadata = try parseMetadataText(allocator, test_source);
    defer metadata.deinit(allocator);
    if (metadata.hasSkippedFeature(skipped_features)) return .skipped;

    const run_as_module = global_module or metadata.hasFlag("module");

    const source = try makeTestSourceFromBytes(allocator, harness_cache, harness_prelude, test_source, metadata);
    defer allocator.free(source);

    var js = try engine.Engine.init(allocator);
    defer js.deinit();
    var output_buffer: [64 * 1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var error_buffer: [128]u8 = undefined;
    var stderr: []const u8 = "";
    var has_async_exception = false;
    var value = js.evalWithOutputMode(source, &output, if (run_as_module) .module else .script) catch |err| failed: {
        stderr = try std.fmt.bufPrint(&error_buffer, "{s}", .{@errorName(err)});
        break :failed engine.core.Value.exception();
    };
    defer value.free(js.runtime);

    if (!value.isException()) {
        js.runJobs();
        if (js.context.hasException()) {
            has_async_exception = true;
            stderr = "unhandled promise rejection";
            const async_exception = js.takeException();
            async_exception.free(js.runtime);
        }
    }
    const elapsed_ms: i64 = started.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.toMilliseconds();
    const exited_zero = !value.isException() and !has_async_exception;
    const passed = if (metadata.negative) |negative|
        negativeResultMatches(negative, exited_zero, stderr)
    else
        exited_zero;
    const is_slow = if (timeout_ms) |timeout| elapsed_ms >= @as(i64, timeout) else false;
    const result: TestRunResult = if (passed) .passed else .failed;

    if (verbose > 1 or is_slow) {
        try printRunResult(io, test_path, result, elapsed_ms, stderr);
    } else if (result == .failed and verbose != 0) {
        try printFailure(io, test_path, stderr);
    }
    return result;
}

fn printRunResult(io: std.Io, test_path: []const u8, result: TestRunResult, elapsed_ms: i64, stderr: []const u8) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const writer = &stderr_writer.interface;
    const status = switch (result) {
        .passed => "PASS",
        .failed => "FAIL",
        .skipped => "SKIP",
    };
    if (result == .passed) {
        try writer.print("{s} {s} ({d} ms)\n", .{ status, test_path, elapsed_ms });
    } else {
        try writer.print("{s} {s} ({d} ms)", .{ status, test_path, elapsed_ms });
        const trimmed = std.mem.trim(u8, stderr, " \t\r\n");
        if (trimmed.len != 0) {
            const limit = @min(trimmed.len, 240);
            try writer.print(": {s}", .{trimmed[0..limit]});
        }
        try writer.print("\n", .{});
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

fn makeHarnessPrelude(allocator: std.mem.Allocator, io: std.Io, harnessdir: ?[]const u8) ![]u8 {
    const sta = try readHarnessFile(allocator, io, harnessdir, "sta.js");
    defer if (sta) |bytes| allocator.free(bytes);
    const assert = try readHarnessFile(allocator, io, harnessdir, "assert.js");
    defer if (assert) |bytes| allocator.free(bytes);

    const sta_len = if (sta) |bytes| bytes.len else 0;
    const assert_len = if (assert) |bytes| bytes.len else 0;
    const total_len = sta_len + assert_len +
        @as(usize, if (sta != null) 1 else 0) +
        @as(usize, if (assert != null) 1 else 0);
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
    return out[0..offset];
}

fn makeTestSource(allocator: std.mem.Allocator, io: std.Io, harness_cache: *HarnessCache, harness_prelude: []const u8, test_path: []const u8, metadata: TestMetadata) ![]u8 {
    const test_source = try std.Io.Dir.cwd().readFileAlloc(io, test_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(test_source);
    return makeTestSourceFromBytes(allocator, harness_cache, harness_prelude, test_source, metadata);
}

fn makeTestSourceFromBytes(allocator: std.mem.Allocator, harness_cache: *HarnessCache, harness_prelude: []const u8, test_source: []const u8, metadata: TestMetadata) ![]u8 {
    if (metadata.hasFlag("raw")) {
        const out = try allocator.alloc(u8, test_source.len + 1);
        @memcpy(out[0..test_source.len], test_source);
        out[test_source.len] = '\n';
        return out;
    }

    var includes_len: usize = 0;
    for (metadata.includes.items) |include_name| {
        if (try harness_cache.get(include_name)) |bytes| includes_len += bytes.len + 1;
    }
    const total_len = harness_prelude.len + includes_len + test_source.len + 1;
    const out = try allocator.alloc(u8, total_len);
    var offset: usize = 0;
    @memcpy(out[offset..][0..harness_prelude.len], harness_prelude);
    offset += harness_prelude.len;
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
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

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
                in_negative = false;
            } else if (std.mem.eql(u8, key, "features")) {
                try parseMetadataList(&metadata.features, value);
                in_negative = false;
            } else if (std.mem.eql(u8, key, "flags")) {
                try parseMetadataList(&metadata.flags, value);
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
        const name = std.mem.trim(u8, entry, " \t\r\n\"");
        if (name.len != 0) try list.append(name);
    }
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

fn printFailure(io: std.Io, test_path: []const u8, stderr: []const u8) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const writer = &stderr_writer.interface;
    try writer.print("FAIL {s}", .{test_path});
    const trimmed = std.mem.trim(u8, stderr, " \t\r\n");
    if (trimmed.len != 0) {
        const limit = @min(trimmed.len, 240);
        try writer.print(": {s}", .{trimmed[0..limit]});
    }
    try writer.print("\n", .{});
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

test "test262 args parse QuickJS-shaped config and root" {
    const config = try parseArgs(&.{ "-c", "quickjs/test262.conf", "-m", "-t", "1", "quickjs/test262/test" });
    try std.testing.expectEqualStrings("quickjs/test262.conf", config.config_path.?);
    try std.testing.expect(config.module);
    try std.testing.expectEqual(@as(u32, 1), config.threads);
    try std.testing.expectEqualStrings("quickjs/test262/test", config.test_root.?);
}

test "test262 args parse timeout and verbose levels" {
    const config = try parseArgs(&.{ "-T", "100", "-vv", "-c", "quickjs/test262.conf", "tests" });
    try std.testing.expectEqual(@as(?u32, 100), config.timeout_ms);
    try std.testing.expectEqual(@as(u8, 2), config.verbose);
    try std.testing.expectEqualStrings("quickjs/test262.conf", config.config_path.?);
    try std.testing.expectEqualStrings("tests", config.test_root.?);
}

test "test262 args parse direct file and directory selectors" {
    const config = try parseArgs(&.{ "-d", "built-ins/Object", "-f", "language/types/null.js", "-e", "known.txt" });
    try std.testing.expectEqualStrings("built-ins/Object", config.dirs.get(0));
    try std.testing.expectEqualStrings("language/types/null.js", config.files.get(0));
    try std.testing.expectEqualStrings("known.txt", config.known_error_file.?);
}

test "test262 args parse QuickJS index span" {
    const config = try parseArgs(&.{ "-c", "quickjs/test262.conf", "0", "20" });
    try std.testing.expectEqual(@as(?usize, 0), config.start_index);
    try std.testing.expectEqual(@as(?usize, 20), config.stop_index);
}

test "test262 config text parses paths features and excludes relative to config" {
    var loaded = try loadConfigText(std.testing.allocator, "quickjs",
        \\[config]
        \\testdir=test262/test
        \\harnessdir=test262/harness
        \\errorfile=test262_errors.txt
        \\[features]
        \\Intl.Locale=skip
        \\Map
        \\[exclude]
        \\test262/test/intl402/
    );
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("quickjs/test262/test", loaded.testdir.?);
    try std.testing.expectEqualStrings("quickjs/test262/harness", loaded.harnessdir.?);
    try std.testing.expectEqualStrings("quickjs/test262_errors.txt", loaded.errorfile.?);
    try std.testing.expect(loaded.excludes.contains("quickjs/test262/test/intl402/foo.js"));
    try std.testing.expectEqual(@as(usize, 1), loaded.enabled_features.items.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.skipped_features.items.len);
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
    var known = try parseKnownErrorsText(std.testing.allocator, "quickjs",
        \\test262/test/a.js:14: SyntaxError
        \\quickjs/test262/test/b.js:7: TypeError
    );
    defer known.deinit();

    try std.testing.expectEqual(@as(usize, 2), known.items.len);
    try std.testing.expectEqualStrings("quickjs/test262/test/a.js", known.items[0]);
    try std.testing.expectEqualStrings("quickjs/test262/test/b.js", known.items[1]);
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

test "known error renderer writes paths relative to errorfile directory" {
    var failures = NameList.init(std.testing.allocator);
    defer failures.deinit();
    try failures.append("quickjs/test262/test/z.js");
    try failures.append("quickjs/test262/test/a.js");

    const text = try renderKnownErrorsText(std.testing.allocator, failures, "quickjs");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("test262/test/a.js\ntest262/test/z.js\n", text);
}

test "known error update preserves unselected existing failures" {
    var known = NameList.init(std.testing.allocator);
    defer known.deinit();
    try known.append("quickjs/test262/test/a.js");
    try known.append("quickjs/test262/test/b.js");
    try known.append("quickjs/test262/test/c.js");

    var selected = NameList.init(std.testing.allocator);
    defer selected.deinit();
    try selected.append("quickjs/test262/test/a.js");
    try selected.append("quickjs/test262/test/b.js");

    var current = NameList.init(std.testing.allocator);
    defer current.deinit();
    try current.append("quickjs/test262/test/b.js");

    var merged = try mergeKnownErrorsForUpdate(std.testing.allocator, known, selected, current);
    defer merged.deinit();

    try std.testing.expectEqual(@as(usize, 2), merged.items.len);
    try std.testing.expectEqualStrings("quickjs/test262/test/b.js", merged.items[0]);
    try std.testing.expectEqualStrings("quickjs/test262/test/c.js", merged.items[1]);
}

test "selected known failure that now passes is counted as fixed" {
    var known = NameList.init(std.testing.allocator);
    defer known.deinit();
    try known.append("tests/zig-smoke/arith.js");
    known.sortAndDedupe();

    var skipped = NameList.init(std.testing.allocator);
    defer skipped.deinit();

    var summary = ExecutionSummary{ .selection = .{} };
    var current = NameList.init(std.testing.allocator);
    defer current.deinit();

    try runWorkerStride(
        std.testing.allocator,
        std.testing.io,
        "zig-out/bin/zjs",
        null,
        "",
        &.{"tests/zig-smoke/arith.js"},
        known,
        skipped,
        0,
        1,
        0,
        null,
        false,
        &summary,
        &current,
    );

    try std.testing.expectEqual(@as(usize, 0), summary.passed);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    try std.testing.expectEqual(@as(usize, 1), summary.fixed);
    try std.testing.expectEqual(@as(usize, 0), current.items.len);
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
}

test "test262 timeout threshold does not classify passing tests as failure" {
    const config = try parseArgs(&.{ "-vv", "-T", "0", "-f", "tests/zig-smoke/arith.js" });
    var summary = try runSelectedTests(std.testing.allocator, std.testing.io, config, "zig-out/bin/zjs");
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

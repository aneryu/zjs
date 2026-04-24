const std = @import("std");

pub const RunnerArgsError = error{
    Usage,
    MissingValue,
    TooManyItems,
};

pub const RunnerError = error{
    ConfigParse,
};

pub const Config = struct {
    config_path: ?[]const u8 = null,
    test_root: ?[]const u8 = null,
    module: bool = false,
    verbose: u8 = 0,
    update_errors: bool = false,
    timeout_seconds: ?u32 = null,
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
            config.timeout_seconds = try parseU32(try nextValue(args, &i));
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

    pub fn deinit(self: *PreparedSelection, allocator: std.mem.Allocator) void {
        self.tests.deinit();
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

pub const NameList = struct {
    allocator: std.mem.Allocator,
    items: []const []const u8 = &.{},

    pub fn init(allocator: std.mem.Allocator) NameList {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *NameList) void {
        for (self.items) |item| self.allocator.free(item);
        if (self.items.len != 0) self.allocator.free(self.items);
        self.items = &.{};
    }

    pub fn appendOwned(self: *NameList, item: []const u8) !void {
        const next = try self.allocator.alloc([]const u8, self.items.len + 1);
        @memcpy(next[0..self.items.len], self.items);
        if (self.items.len != 0) self.allocator.free(self.items);
        next[self.items.len] = item;
        self.items = next;
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

    pub fn contains(self: NameList, needle: []const u8) bool {
        for (self.items) |item| {
            if (std.mem.eql(u8, item, needle)) return true;
            if (std.mem.endsWith(u8, item, "/") and std.mem.startsWith(u8, needle, item)) return true;
        }
        return false;
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

    for (prepared.tests.items) |test_path| {
        const passed = try runOneTest(allocator, io, zjs_path, summary.selection.harnessdir, test_path, config.verbose);
        const is_known = known_errors.contains(test_path);
        if (passed and is_known) {
            summary.fixed += 1;
        } else if (passed) {
            summary.passed += 1;
        } else if (is_known) {
            summary.known_failures += 1;
            try current_failures.append(test_path);
        } else {
            summary.failed += 1;
            try current_failures.append(test_path);
        }
    }

    if (config.update_errors and summary.selection.errorfile != null) {
        var merged_failures = try mergeKnownErrorsForUpdate(allocator, known_errors, prepared.tests, current_failures);
        defer merged_failures.deinit();
        try writeKnownErrors(allocator, io, summary.selection.errorfile.?, merged_failures);
    }

    prepared.tests.deinit();
    return summary;
}

pub fn prepareSelection(allocator: std.mem.Allocator, io: std.Io, config: Config) !PreparedSelection {
    var loaded = if (config.config_path) |path| try loadConfigFile(allocator, io, path) else LoadedConfig.init(allocator);
    defer loaded.deinit(allocator);

    var tests = NameList.init(allocator);
    errdefer tests.deinit();
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

fn runOneTest(allocator: std.mem.Allocator, io: std.Io, zjs_path: []const u8, harnessdir: ?[]const u8, test_path: []const u8, verbose: u8) !bool {
    const source = try makeTestSource(allocator, io, harnessdir, test_path);
    defer allocator.free(source);

    const temp_path = ".zig-cache/run-test262-current.js";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temp_path, .data = source });
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    const result = try std.process.run(allocator, io, .{
        .argv = &.{ zjs_path, temp_path },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const passed = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!passed and verbose != 0) try printFailure(io, test_path, result.stderr);
    return passed;
}

fn makeTestSource(allocator: std.mem.Allocator, io: std.Io, harnessdir: ?[]const u8, test_path: []const u8) ![]u8 {
    const sta = try readHarnessFile(allocator, io, harnessdir, "sta.js");
    defer if (sta) |bytes| allocator.free(bytes);
    const assert = try readHarnessFile(allocator, io, harnessdir, "assert.js");
    defer if (assert) |bytes| allocator.free(bytes);
    const test_source = try std.Io.Dir.cwd().readFileAlloc(io, test_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(test_source);

    const sta_len = if (sta) |bytes| bytes.len else 0;
    const assert_len = if (assert) |bytes| bytes.len else 0;
    const total_len = sta_len + assert_len + test_source.len +
        @as(usize, if (sta != null) 1 else 0) +
        @as(usize, if (assert != null) 1 else 0) + 1;
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

fn loadKnownErrors(allocator: std.mem.Allocator, io: std.Io, errorfile: ?[]const u8) !NameList {
    const path = errorfile orelse return NameList.init(allocator);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return NameList.init(allocator),
        else => return err,
    };
    defer allocator.free(bytes);
    return parseKnownErrorsText(allocator, bytes);
}

fn parseKnownErrorsText(allocator: std.mem.Allocator, text: []const u8) !NameList {
    var known = NameList.init(allocator);
    errdefer known.deinit();

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const entry = stripComment(std.mem.trim(u8, line, " \t\r"));
        if (entry.len == 0) continue;
        try known.append(entry);
    }
    known.sortAndDedupe();
    return known;
}

fn writeKnownErrors(allocator: std.mem.Allocator, io: std.Io, errorfile: []const u8, failures: NameList) !void {
    const rendered = try renderKnownErrorsText(allocator, failures);
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

fn renderKnownErrorsText(allocator: std.mem.Allocator, failures: NameList) ![]u8 {
    var stable = NameList.init(allocator);
    defer stable.deinit();
    for (failures.items) |test_path| try stable.append(test_path);
    stable.sortAndDedupe();

    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    for (stable.items) |test_path| {
        try buffer.appendSlice(allocator, test_path);
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

test "test262 args parse QuickJS-shaped config and root" {
    const config = try parseArgs(&.{ "-c", "quickjs/test262.conf", "-m", "-t", "1", "quickjs/test262/test" });
    try std.testing.expectEqualStrings("quickjs/test262.conf", config.config_path.?);
    try std.testing.expect(config.module);
    try std.testing.expectEqual(@as(u32, 1), config.threads);
    try std.testing.expectEqualStrings("quickjs/test262/test", config.test_root.?);
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
    var known = try parseKnownErrorsText(std.testing.allocator,
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

test "known error renderer emits sorted unique newline-separated entries" {
    var failures = NameList.init(std.testing.allocator);
    defer failures.deinit();
    try failures.append("test/z.js");
    try failures.append("test/a.js");
    try failures.append("test/z.js");

    const text = try renderKnownErrorsText(std.testing.allocator, failures);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("test/a.js\ntest/z.js\n", text);
}

test "known error update preserves unselected existing failures" {
    var known = NameList.init(std.testing.allocator);
    defer known.deinit();
    try known.append("test/a.js");
    try known.append("test/b.js");
    try known.append("test/c.js");

    var selected = NameList.init(std.testing.allocator);
    defer selected.deinit();
    try selected.append("test/a.js");
    try selected.append("test/b.js");

    var current = NameList.init(std.testing.allocator);
    defer current.deinit();
    try current.append("test/b.js");

    var merged = try mergeKnownErrorsForUpdate(std.testing.allocator, known, selected, current);
    defer merged.deinit();

    try std.testing.expectEqual(@as(usize, 2), merged.items.len);
    try std.testing.expectEqualStrings("test/b.js", merged.items[0]);
    try std.testing.expectEqualStrings("test/c.js", merged.items[1]);
}

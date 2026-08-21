const std = @import("std");

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

pub fn renderSortedFailureLog(
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

    std.sort.heap([]const u8, lines.items, {}, lessThanFailureLogLine);
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
    std.sort.heap(Reporter.DirEntry, sorted, {}, lessThanDirEntry);

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

pub fn renderSkippedFeaturesJson(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    entries_in: []const Reporter.SkippedFeatureEntry,
) !void {
    const sorted = try allocator.dupe(Reporter.SkippedFeatureEntry, entries_in);
    defer allocator.free(sorted);
    std.sort.heap(Reporter.SkippedFeatureEntry, sorted, {}, lessThanSkippedFeatureEntry);

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

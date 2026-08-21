const std = @import("std");
const NameList = @import("run_test262_names.zig").NameList;
const BoundedFeatureOverrides = @import("run_test262_options.zig").BoundedFeatureOverrides;

pub const Error = error{
    ConfigParse,
};

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

    pub fn excludesTest(self: LoadedConfig, path: []const u8) bool {
        const exclude_len = self.excludes.bestMatchLen(path) orelse return false;
        const reinclude_len = self.reincludes.bestMatchLen(path) orelse return true;
        return exclude_len > reinclude_len;
    }
};

pub fn loadText(allocator: std.mem.Allocator, base_dir: []const u8, text: []const u8) !LoadedConfig {
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

pub fn loadFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !LoadedConfig {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(bytes);
    const base_dir = std.fs.path.dirname(path) orelse "";
    return loadText(allocator, base_dir, bytes);
}

pub fn applyFeatureOverrides(loaded: *LoadedConfig, overrides: BoundedFeatureOverrides) !void {
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

pub fn stripComment(line: []const u8) []const u8 {
    const hash = std.mem.indexOfScalar(u8, line, '#') orelse line.len;
    const semi = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
    return std.mem.trim(u8, line[0..@min(hash, semi)], " \t");
}

fn composePath(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]const u8 {
    if (base.len == 0 or std.fs.path.isAbsolute(name)) return allocator.dupe(u8, name);
    return std.fs.path.join(allocator, &.{ base, name });
}

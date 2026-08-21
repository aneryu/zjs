const std = @import("std");

pub const usage =
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
    "  --enable-feature <name> temporarily enable a config-skipped feature\n" ++
    "  --skip-feature <name>   temporarily skip a config-enabled feature\n";

pub const Error = error{
    Usage,
    MissingValue,
    TooManyItems,
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

    pub fn append(self: *BoundedFeatureOverrides, kind: FeatureOverrideKind, name: []const u8) Error!void {
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

    pub fn append(self: *BoundedList, item: []const u8) Error!void {
        if (self.len == self.items.len) return error.TooManyItems;
        self.items[self.len] = item;
        self.len += 1;
    }

    pub fn get(self: BoundedList, index: usize) []const u8 {
        return self.items[index];
    }
};

pub fn parse(args: []const []const u8) Error!Config {
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

fn nextValue(args: []const []const u8, index: *usize) Error![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.MissingValue;
    return args[index.*];
}

fn parseU32(bytes: []const u8) Error!u32 {
    return std.fmt.parseInt(u32, bytes, 10) catch error.Usage;
}

fn parseUsize(bytes: []const u8) Error!usize {
    return std.fmt.parseInt(usize, bytes, 10) catch error.Usage;
}

fn isDecimal(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |byte| {
        if (byte < '0' or byte > '9') return false;
    }
    return true;
}

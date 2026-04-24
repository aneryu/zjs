const std = @import("std");

pub const RunnerArgsError = error{
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
    timeout_seconds: ?u32 = null,
    threads: u32 = 1,
    known_error_file: ?[]const u8 = null,
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

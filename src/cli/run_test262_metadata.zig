const std = @import("std");
const NameList = @import("run_test262_names.zig").NameList;

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

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !TestMetadata {
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
                .includes => try parseListItem(&metadata.includes, line[1..]),
                .features => try parseListItem(&metadata.features, line[1..]),
                .flags => try parseListItem(&metadata.flags, line[1..]),
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
                try parseList(&metadata.includes, value);
                active_list = if (value.len == 0) .includes else .none;
                in_negative = false;
            } else if (std.mem.eql(u8, key, "features")) {
                try parseList(&metadata.features, value);
                active_list = if (value.len == 0) .features else .none;
                in_negative = false;
            } else if (std.mem.eql(u8, key, "flags")) {
                try parseList(&metadata.flags, value);
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

fn parseList(list: *NameList, value: []const u8) !void {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return;
    var entries = std.mem.splitScalar(u8, trimmed[1 .. trimmed.len - 1], ',');
    while (entries.next()) |entry| {
        try parseListItem(list, entry);
    }
}

fn parseListItem(list: *NameList, item: []const u8) !void {
    const without_comment = if (std.mem.indexOfScalar(u8, item, '#')) |comment|
        item[0..comment]
    else
        item;
    const name = std.mem.trim(u8, without_comment, " \t\r\n\"'");
    if (name.len != 0) try list.append(name);
}

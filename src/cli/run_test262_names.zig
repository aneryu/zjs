//! Owned-name storage shared by the test262 runner configuration modules.
const std = @import("std");
/// Owned names used by the test262 runner. This type owns both its strings and
/// backing storage; callers may move ownership explicitly with `move`.
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
        std.sort.heap([]const u8, mutable, {}, lessThan);
        var write: usize = 1;
        var read: usize = 1;
        while (read < mutable.len) : (read += 1) {
            if (compare(mutable[write - 1], mutable[read]) == 0) {
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
            const order = compare(self.items[mid], needle);
            if (order < 0) {
                low = mid + 1;
            } else if (order > 0) {
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

/// Natural byte ordering for test names. Decimal runs are compared by numeric
/// value without integer parsing, then by run length so distinct spellings
/// such as `2`, `02`, and `002` remain distinct and deterministic.
pub fn compare(lhs: []const u8, rhs: []const u8) i32 {
    var i: usize = 0;
    var j: usize = 0;
    while (i < lhs.len and j < rhs.len) {
        const lc = lhs[i];
        const rc = rhs[j];
        if (isAsciiDigit(lc) and isAsciiDigit(rc)) {
            const lhs_start = i;
            const rhs_start = j;
            i = asciiDigitRunEnd(lhs, lhs_start);
            j = asciiDigitRunEnd(rhs, rhs_start);
            const digits_order = compareAsciiDigitRuns(lhs[lhs_start..i], rhs[rhs_start..j]);
            if (digits_order != 0) return digits_order;
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

fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return compare(lhs, rhs) < 0;
}

fn isAsciiDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn asciiDigitRunEnd(bytes: []const u8, start: usize) usize {
    var end = start;
    while (end < bytes.len and isAsciiDigit(bytes[end])) : (end += 1) {}
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

//! Live address → allocation map for conservative candidate validation
//! (tracing-gc-design.md §4.2 / §4.3 / §7.2).
//!
//! Independent of the block heap: this round indexes the compatibility
//! allocator's published GC objects. Lookup is a page radix (4 KiB) plus a
//! per-page occupant list, not a linear walk of live objects. Large extents
//! occupy every overlapping page. Candidates are never dereferenced as guessed
//! headers.
//!
//! Default `rc` production does not compile this module.

const std = @import("std");

const gc = @import("gc.zig");

pub const enabled = gc.address_registry_enabled;

pub const page_shift: u6 = 12;
pub const page_size: usize = 1 << page_shift;

pub const Occupant = struct {
    lo: usize,
    hi: usize,
    header: *gc.Header,
};

pub const Stats = struct {
    live: usize = 0,
    pages: usize = 0,
    register_calls: usize = 0,
    unregister_calls: usize = 0,
    lookup_calls: usize = 0,
    lookup_hits: usize = 0,
    failed_inserts: usize = 0,

    pub fn reset(self: *Stats) void {
        self.* = .{};
    }
};

const PageBucket = struct {
    occupants: std.ArrayListUnmanaged(Occupant) = .empty,
};

pub const Table = struct {
    pages: std.AutoHashMapUnmanaged(usize, PageBucket) = .empty,
    by_header: std.AutoHashMapUnmanaged(usize, Occupant) = .empty,
    stats: Stats = .{},

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        var iterator = self.pages.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.occupants.deinit(allocator);
        }
        self.pages.deinit(allocator);
        self.by_header.deinit(allocator);
        self.* = .{};
    }

    pub fn occupantFor(header: *gc.Header, bytes: usize) Occupant {
        const header_addr = @intFromPtr(header);
        const lo = header_addr - gc.metadata_prefix_size;
        const hi = header_addr + bytes + 1;
        return .{ .lo = lo, .hi = hi, .header = header };
    }

    pub fn insert(self: *Table, allocator: std.mem.Allocator, header: *gc.Header, bytes: usize) std.mem.Allocator.Error!void {
        self.stats.register_calls += 1;
        const key = @intFromPtr(header);
        if (self.by_header.contains(key)) return;
        const occupant = occupantFor(header, bytes);
        try self.by_header.put(allocator, key, occupant);
        errdefer _ = self.by_header.remove(key);

        const first_page = occupant.lo >> page_shift;
        const last_page = (occupant.hi - 1) >> page_shift;
        var page = first_page;
        var registered: usize = 0;
        errdefer self.rollbackPages(allocator, occupant, first_page, registered);
        while (page <= last_page) : (page += 1) {
            const gop = try self.pages.getOrPut(allocator, page);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{};
                self.stats.pages += 1;
            }
            try gop.value_ptr.occupants.append(allocator, occupant);
            registered += 1;
        }
        self.stats.live += 1;
    }

    pub fn remove(self: *Table, allocator: std.mem.Allocator, header: *gc.Header) void {
        self.stats.unregister_calls += 1;
        const key = @intFromPtr(header);
        const occupant = self.by_header.fetchRemove(key) orelse return;
        const range = occupant.value;
        const first_page = range.lo >> page_shift;
        const last_page = (range.hi - 1) >> page_shift;
        var page = first_page;
        while (page <= last_page) : (page += 1) {
            const bucket = self.pages.getPtr(page) orelse continue;
            var index: usize = 0;
            while (index < bucket.occupants.items.len) : (index += 1) {
                if (bucket.occupants.items[index].header != header) continue;
                _ = bucket.occupants.swapRemove(index);
                break;
            }
            if (bucket.occupants.items.len == 0) {
                bucket.occupants.deinit(allocator);
                _ = self.pages.remove(page);
                self.stats.pages -= 1;
            }
        }
        self.stats.live -= 1;
    }

    pub fn resolve(self: *Table, addr: usize) ?*gc.Header {
        self.stats.lookup_calls += 1;
        if (addr < 4096) return null;
        const bucket = self.pages.getPtr(addr >> page_shift) orelse return null;
        // One-past-end of object A can equal the metadata prefix of object B.
        // Census snapshot lookup picked the last range with `lo <= addr`
        // (greatest lo). First-match would shade A and let B be swept.
        var best: ?Occupant = null;
        for (bucket.occupants.items) |occupant| {
            if (addr < occupant.lo or addr >= occupant.hi) continue;
            if (best == null or occupant.lo > best.?.lo) best = occupant;
        }
        if (best) |occupant| {
            self.stats.lookup_hits += 1;
            return occupant.header;
        }
        return null;
    }

    pub fn containsHeader(self: *const Table, header: *const gc.Header) bool {
        return self.by_header.contains(@intFromPtr(header));
    }

    fn rollbackPages(
        self: *Table,
        allocator: std.mem.Allocator,
        occupant: Occupant,
        first_page: usize,
        registered: usize,
    ) void {
        var page = first_page;
        var remaining = registered;
        while (remaining > 0) : ({
            page += 1;
            remaining -= 1;
        }) {
            const bucket = self.pages.getPtr(page) orelse continue;
            if (bucket.occupants.items.len != 0 and
                bucket.occupants.items[bucket.occupants.items.len - 1].header == occupant.header)
            {
                _ = bucket.occupants.pop();
            }
            if (bucket.occupants.items.len == 0) {
                bucket.occupants.deinit(allocator);
                _ = self.pages.remove(page);
                self.stats.pages -= 1;
            }
        }
    }
};

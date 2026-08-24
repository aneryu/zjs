//! Live address → allocation map for conservative candidate validation
//! (tracing-gc-design.md §4.2 / §4.3 / §7.2).
//!
//! Page radix (4 KiB) plus per-page occupant lists. GC objects, flat strings,
//! and rope nodes are intervals in the same table; string/rope registration
//! does not change the 4-byte RC prefix. Large extents occupy every
//! overlapping page. Candidates are never dereferenced as guessed headers.
//!
//! Default `rc` production does not compile this module.

const std = @import("std");

const gc = @import("gc.zig");

pub const enabled = gc.address_registry_enabled;

pub const page_shift: u6 = 12;
pub const page_size: usize = 1 << page_shift;

pub const Kind = enum(u8) {
    gc_object,
    string,
    rope,
};

pub const Occupant = struct {
    lo: usize,
    hi: usize,
    kind: Kind,
    ptr: usize,

    pub fn gcHeader(self: Occupant) ?*gc.Header {
        if (self.kind != .gc_object) return null;
        return @ptrFromInt(self.ptr);
    }
};

pub const Hit = union(Kind) {
    gc_object: *gc.Header,
    string: *gc.StringHeader,
    rope: *gc.StringHeader,
};

pub const Stats = struct {
    live: usize = 0,
    string_live: usize = 0,
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
    /// Union of every registered range, so a conservative candidate outside
    /// the heap is rejected by two compares instead of a hash probe. The
    /// bounds never shrink; a stale-wide window only costs a probe that
    /// would have happened anyway.
    bounds_lo: usize = std.math.maxInt(usize),
    bounds_hi: usize = 0,

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
        return .{ .lo = lo, .hi = hi, .kind = .gc_object, .ptr = header_addr };
    }

    pub fn rangeForBytes(kind: Kind, base: usize, bytes: usize, identity: usize) Occupant {
        return .{ .lo = base, .hi = base + bytes + 1, .kind = kind, .ptr = identity };
    }

    pub fn insert(self: *Table, allocator: std.mem.Allocator, header: *gc.Header, bytes: usize) std.mem.Allocator.Error!void {
        return self.insertOccupant(allocator, occupantFor(header, bytes));
    }

    pub fn insertRange(
        self: *Table,
        allocator: std.mem.Allocator,
        kind: Kind,
        base: usize,
        bytes: usize,
        identity: usize,
    ) std.mem.Allocator.Error!void {
        return self.insertOccupant(allocator, rangeForBytes(kind, base, bytes, identity));
    }

    fn insertOccupant(self: *Table, allocator: std.mem.Allocator, occupant: Occupant) std.mem.Allocator.Error!void {
        self.stats.register_calls += 1;
        const key = occupant.ptr;
        // One hash probe, not two: `contains` followed by `put` hashed the
        // same key twice on every publication, which is the mutator's
        // allocation path.
        const entry = try self.by_header.getOrPut(allocator, key);
        if (entry.found_existing) return;
        entry.value_ptr.* = occupant;
        errdefer _ = self.by_header.remove(key);

        if (occupant.lo < self.bounds_lo) self.bounds_lo = occupant.lo;
        if (occupant.hi > self.bounds_hi) self.bounds_hi = occupant.hi;

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
        if (occupant.kind != .gc_object) self.stats.string_live += 1;
    }

    pub fn remove(self: *Table, allocator: std.mem.Allocator, header: *gc.Header) void {
        self.removePtr(allocator, @intFromPtr(header));
    }

    pub fn removePtr(self: *Table, allocator: std.mem.Allocator, identity: usize) void {
        self.stats.unregister_calls += 1;
        const occupant = self.by_header.fetchRemove(identity) orelse return;
        const range = occupant.value;
        const first_page = range.lo >> page_shift;
        const last_page = (range.hi - 1) >> page_shift;
        var page = first_page;
        while (page <= last_page) : (page += 1) {
            const bucket = self.pages.getPtr(page) orelse continue;
            var index: usize = 0;
            while (index < bucket.occupants.items.len) : (index += 1) {
                if (bucket.occupants.items[index].ptr != identity) continue;
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
        if (range.kind != .gc_object) self.stats.string_live -= 1;
    }

    pub fn resolve(self: *Table, addr: usize) ?*gc.Header {
        return switch (self.resolveAny(addr) orelse return null) {
            .gc_object => |header| header,
            .string, .rope => null,
        };
    }

    /// Every occupant containing `addr`, not just the greatest-`lo` one.
    ///
    /// `resolveAny` has to pick a single winner, and picks the greatest `lo`
    /// so that a metadata-prefix hit beats the neighbour whose one-past-end
    /// coincides with it. For a conservative root scan that choice is unsafe
    /// in the other direction: a native one-past-end pointer to object A is a
    /// real reference to A, and returning only B leaves A unshaded and
    /// sweepable. JSC probes and marks both sides for exactly this case
    /// (ConservativeRoots.cpp:135-146, and :162-166 refuses to return early
    /// for kinds that can be pointed past). Shading a few extra objects is
    /// the conservative direction; missing one is a use-after-free.
    pub fn forEachGcObjectAt(
        self: *Table,
        addr: usize,
        context: *anyopaque,
        visit: *const fn (*anyopaque, *gc.Header) void,
    ) usize {
        self.stats.lookup_calls += 1;
        if (addr < self.bounds_lo or addr >= self.bounds_hi) return 0;
        const bucket = self.pages.getPtr(addr >> page_shift) orelse return 0;
        var hits: usize = 0;
        for (bucket.occupants.items) |occupant| {
            if (addr < occupant.lo or addr >= occupant.hi) continue;
            if (occupant.kind != .gc_object) continue;
            hits += 1;
            visit(context, @ptrFromInt(occupant.ptr));
        }
        if (hits != 0) self.stats.lookup_hits += 1;
        return hits;
    }

    pub fn resolveAny(self: *Table, addr: usize) ?Hit {
        self.stats.lookup_calls += 1;
        if (addr < self.bounds_lo or addr >= self.bounds_hi) return null;
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
            return switch (occupant.kind) {
                .gc_object => .{ .gc_object = @ptrFromInt(occupant.ptr) },
                .string => .{ .string = @ptrFromInt(occupant.ptr) },
                .rope => .{ .rope = @ptrFromInt(occupant.ptr) },
            };
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
                bucket.occupants.items[bucket.occupants.items.len - 1].ptr == occupant.ptr)
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

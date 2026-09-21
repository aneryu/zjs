//! The young generation: bump-allocated pages, collected by copying the
//! survivors out and reclaiming everything else in one stroke.
//!
//! A dead object costs nothing here. That is the whole point of the shape:
//! the sticky-mark minor it replaces had to walk every young block's
//! allocation bitmap, derive `alloc & ~mark`, and run a destructor per
//! corpse; a copying minor never touches a corpse at all.
//!
//! Pages rather than one span, for one reason: a conservative stack scan can
//! pin an object, and a pinned object cannot be moved. The page holding it is
//! RETAINED -- its objects become old in place -- and every other page goes
//! back to the free list. That bounds the waste at one page per pin instead
//! of leaking the whole region, and it is the same shape Chrome uses while
//! its conservative scanning and its moving young generation coexist. Once
//! the precise-root work drives the pin count to zero, retention stops
//! happening and the region is always reclaimed whole.

const std = @import("std");

/// Bump pages. Large enough that the per-page bookkeeping and the end-of-page
/// waste are both noise against the allocation stream, small enough that one
/// pin retains little.
pub const page_bytes: usize = 64 * 1024;

/// The largest allocation the nursery serves. Anything bigger goes straight to
/// the old generation: it would waste most of a page, and an object that large
/// is not the short-lived kind a young generation exists to reclaim.
pub const max_object_bytes: usize = page_bytes / 8;

/// How much the nursery may hand out before a minor is worth running. Sized
/// off pages rather than object counts: what a copying minor costs is the
/// survivors it copies, and what it reclaims is pages, so bytes are the
/// honest unit on both sides.
pub const collection_trigger_bytes: usize = 4 * page_bytes;

pub const Page = struct {
    base: usize,
    /// First free byte. Between collections this is also the page's live end,
    /// so a linear walk of `base..top` visits every object in allocation
    /// order -- which is how the finalizer sweep finds corpses without a
    /// membership structure.
    top: usize,
    /// Set when a pinned object was found on this page. The page leaves the
    /// nursery instead of being reclaimed.
    retained: bool = false,

    pub inline fn limit(self: Page) usize {
        return self.base + page_bytes;
    }

    pub inline fn contains(self: Page, addr: usize) bool {
        return addr >= self.base and addr < self.top;
    }

    pub inline fn used(self: Page) usize {
        return self.top - self.base;
    }
};

pub const Nursery = struct {
    /// Off until the copying young generation owns the young path. The
    /// allocation fork reads this rather than a module global so a runtime
    /// that never installs a nursery pays nothing.
    enabled: bool = false,
    /// Temporarily route allocation to the old generation.
    ///
    /// Realm construction is the case this exists for. Its intrinsics -- the
    /// global, the prototypes, the constructors -- are long-lived BY
    /// DEFINITION, and the engine holds them as bare pointers through call
    /// chains that allocate at every step. Putting them in a region that
    /// relocates buys nothing (they never die young) and costs exactly the
    /// root coverage the engine does not yet have.
    suspended: bool = false,
    /// Page source. Independent of the JS heap allocator for the same reason
    /// the address registry is: this grows on the allocation path. Defaulted
    /// rather than left undefined so a Registry torn down before it ever
    /// served objects still has a valid allocator to hand back pages to.
    page_allocator: std.mem.Allocator = std.heap.smp_allocator,
    /// Pages currently holding young objects, in allocation order.
    pages: std.ArrayListUnmanaged(Page) = .empty,
    /// Pages mapped but empty, kept for reuse so a minor does not return
    /// memory to the OS it is about to ask for again.
    spare: std.ArrayListUnmanaged(usize) = .empty,
    /// Index into `pages` of the page `alloc` is filling. Equal to
    /// `pages.items.len` when there is no open page.
    open: usize = 0,
    /// Total bytes handed out since the last collection. The scheduler's
    /// trigger reads this rather than counting objects: a page of small
    /// objects and a page of large ones cost the same to reclaim.
    allocated_bytes: usize = 0,
    /// Cumulative, for `--gc-stats`.
    stats: Stats = .{},
    /// Page bases handed back by the last collection, in safety builds.
    ///
    /// A reference that still names one of these is the defect a copying
    /// collector has to find, and finding it at the RECLAIM is not enough:
    /// the audit there sees a legal forwarding record. Finding it on the next
    /// trace names the holder, which is the thing that needed a root.
    recently_reclaimed: if (std.debug.runtime_safety) [8]usize else void =
        if (std.debug.runtime_safety) @splat(0) else {},
    recently_reclaimed_len: if (std.debug.runtime_safety) usize else void =
        if (std.debug.runtime_safety) 0 else {},

    pub const Stats = struct {
        pages_mapped: usize = 0,
        pages_retained: usize = 0,
        collections: usize = 0,
        copied_objects: usize = 0,
        copied_bytes: usize = 0,
        pinned_objects: usize = 0,
    };

    /// Was `addr` on a page the previous collection reclaimed?
    pub fn wasReclaimed(self: *const Nursery, addr: usize) bool {
        if (comptime !std.debug.runtime_safety) return false;
        for (self.recently_reclaimed[0..self.recently_reclaimed_len]) |base| {
            if (addr >= base and addr < base + page_bytes) return true;
        }
        return false;
    }

    pub inline fn serving(self: Nursery) bool {
        return self.enabled and !self.suspended;
    }

    pub fn deinit(self: *Nursery, allocator: std.mem.Allocator) void {
        for (self.pages.items) |page| freePage(allocator, page.base);
        for (self.spare.items) |base| freePage(allocator, base);
        self.pages.deinit(allocator);
        self.spare.deinit(allocator);
        self.* = .{};
    }

    /// Bump `bytes` out of the open page, opening one if needed. Null means
    /// the caller must collect or fall back to the old generation; it is never
    /// an error, because a nursery that cannot grow is a pacing signal rather
    /// than an allocation failure.
    pub fn alloc(self: *Nursery, allocator: std.mem.Allocator, bytes: usize) ?[*]u8 {
        if (bytes > max_object_bytes) return null;
        const aligned = std.mem.alignForward(usize, bytes, 8);
        if (self.open < self.pages.items.len) {
            const page = &self.pages.items[self.open];
            if (page.top + aligned <= page.limit()) {
                const addr = page.top;
                page.top += aligned;
                self.allocated_bytes += aligned;
                return zeroed(addr, aligned);
            }
        }
        const base = self.openPage(allocator) orelse return null;
        const page = &self.pages.items[self.pages.items.len - 1];
        std.debug.assert(page.base == base);
        const addr = page.top;
        page.top += aligned;
        self.allocated_bytes += aligned;
        return zeroed(addr, aligned);
    }

    fn openPage(self: *Nursery, allocator: std.mem.Allocator) ?usize {
        const base = if (self.spare.pop()) |reused| blk: {
            // Once a page is serving again, an address on it is a live object,
            // not a stale reference. Drop it from the reclaimed set or the
            // check below reports every new allocation on a recycled page.
            if (comptime std.debug.runtime_safety) {
                var i: usize = 0;
                while (i < self.recently_reclaimed_len) : (i += 1) {
                    if (self.recently_reclaimed[i] != reused) continue;
                    self.recently_reclaimed[i] = self.recently_reclaimed[self.recently_reclaimed_len - 1];
                    self.recently_reclaimed_len -= 1;
                    break;
                }
            }
            break :blk reused;
        }
        else blk: {
            const mapped = mapPage(allocator) orelse return null;
            self.stats.pages_mapped += 1;
            break :blk mapped;
        };
        self.pages.append(allocator, .{ .base = base, .top = base }) catch {
            self.spare.append(allocator, base) catch freePage(allocator, base);
            return null;
        };
        self.open = self.pages.items.len - 1;
        return base;
    }

    /// Is `addr` inside a live young object? Answered by scanning the page
    /// list, which is short by construction: at the default trigger a nursery
    /// holds a handful of pages, and this is asked once per conservative
    /// candidate rather than per allocation.
    pub fn contains(self: *const Nursery, addr: usize) bool {
        for (self.pages.items) |page| {
            if (page.contains(addr)) return true;
        }
        return false;
    }

    /// `contains` restricted to the pages a collection is responsible for.
    pub fn containsBefore(self: *const Nursery, addr: usize, at: Boundary) bool {
        const limit_pages = @min(at.pages, self.pages.items.len);
        for (self.pages.items[0..limit_pages]) |page| {
            if (page.contains(addr)) return true;
        }
        return false;
    }

    /// The page holding `addr`, for the pin path.
    pub fn pageOf(self: *Nursery, addr: usize) ?*Page {
        for (self.pages.items) |*page| {
            if (page.contains(addr)) return page;
        }
        return null;
    }

    pub fn liveBytes(self: *const Nursery) usize {
        var total: usize = 0;
        for (self.pages.items) |page| total += page.used();
        return total;
    }

    /// The nursery as it stood when a collection began.
    ///
    /// Destructors run inside the sweep and may allocate, so objects appear in
    /// the nursery AFTER the trace that decided what is live. Those are not
    /// garbage -- nothing traced them because nothing had made them yet -- and
    /// reclaiming their page would free live memory. The boundary is what
    /// separates the two populations.
    pub const Boundary = struct { pages: usize };

    pub fn boundary(self: *const Nursery) Boundary {
        return .{ .pages = self.pages.items.len };
    }

    /// Hand back every page a collection did not retain. Retained pages are
    /// removed from the nursery too -- their objects are old now -- and the
    /// caller owns their memory from here on.
    ///
    /// Returns the retained bases so the caller can register them with the old
    /// generation before this returns to service.
    pub fn reclaim(
        self: *Nursery,
        allocator: std.mem.Allocator,
        at: Boundary,
    ) void {
        // The page the boundary falls in is kept whole rather than split: a
        // bump region has no way to return part of a page, and carrying one
        // page of garbage into the next collection is cheaper than the
        // bookkeeping that would avoid it.
        const reclaimable = @min(at.pages, self.pages.items.len);
        if (comptime std.debug.runtime_safety) self.recently_reclaimed_len = 0;
        var index: usize = 0;
        var seen: usize = 0;
        while (index < self.pages.items.len and seen < reclaimable) : (seen += 1) {
            const page = self.pages.items[index];
            if (page.retained) {
                // Keep the page AND keep it in the nursery. The objects on it
                // did not move, so they are still young cells with the
                // nursery as their membership; clearing the flag lets the next
                // collection ask again, and a page nothing pins any more is
                // reclaimed then. Retaining it out of the nursery instead
                // would make the waste permanent.
                self.pages.items[index].retained = false;
                self.stats.pages_retained += 1;
                index += 1;
                continue;
            }
            // Poison before recycling, in safety builds. A page goes back
            // because the collection decided nothing live is on it; if that
            // was wrong, the next read through the stale reference sees the
            // poison instead of whatever object the page is reused for, and
            // fails where the reference is used rather than much later with
            // plausible-looking data.
            if (comptime std.debug.runtime_safety) {
                const bytes: [*]u8 = @ptrFromInt(page.base);
                @memset(bytes[0..page_bytes], 0xDD);
                if (self.recently_reclaimed_len < self.recently_reclaimed.len) {
                    self.recently_reclaimed[self.recently_reclaimed_len] = page.base;
                    self.recently_reclaimed_len += 1;
                }
            }
            self.spare.append(allocator, page.base) catch freePage(allocator, page.base);
            _ = self.pages.orderedRemove(index);
        }
        // What survives is the retained pages plus whatever the sweep's
        // destructors allocated; together they are the next collection's
        // young population.
        self.open = if (self.pages.items.len == 0) 0 else self.pages.items.len - 1;
        self.allocated_bytes = 0;
        for (self.pages.items) |page| self.allocated_bytes += page.used();
        self.stats.collections += 1;
    }

    /// Walk every object start in allocation order. `size_of` reports the
    /// bytes an object occupies, which is how the walk finds the next start;
    /// the nursery itself stores no per-object size.
    pub fn Walker(comptime Context: type) type {
        return struct {
            nursery: *const Nursery,
            context: Context,
            page_index: usize = 0,
            cursor: usize = 0,

            const Self = @This();

            pub fn next(self: *Self, size_of: *const fn (Context, usize) usize) ?usize {
                while (self.page_index < self.nursery.pages.items.len) {
                    const page = self.nursery.pages.items[self.page_index];
                    if (self.cursor == 0) self.cursor = page.base;
                    if (self.cursor < page.top) {
                        const addr = self.cursor;
                        const size = size_of(self.context, addr);
                        std.debug.assert(size != 0);
                        self.cursor += std.mem.alignForward(usize, size, 8);
                        return addr;
                    }
                    self.page_index += 1;
                    self.cursor = 0;
                }
                return null;
            }
        };
    }
};

/// Pages come from the caller's allocator rather than straight from the OS:
/// the block heap learned the same lesson (`releaseFreeBlockPages`) -- an
/// mmap/munmap pair per collection is a syscall bill the reuse list exists to
/// avoid, and an allocator keeps the nursery testable with a leak-checking one.
const page_align: std.mem.Alignment = .fromByteUnits(8);

/// A recycled page carries the previous round's bytes (and, in safety builds,
/// its poison). Object construction does not write every byte of every layout
/// -- inline property tails and unused union arms are left for the collector
/// to read as zero -- so a bump region has to hand out cleared memory the way
/// a fresh mapping does.
inline fn zeroed(addr: usize, bytes: usize) [*]u8 {
    const cell: [*]u8 = @ptrFromInt(addr);
    @memset(cell[0..bytes], 0);
    return cell;
}

fn mapPage(allocator: std.mem.Allocator) ?usize {
    const raw = allocator.rawAlloc(page_bytes, page_align, @returnAddress()) orelse return null;
    return @intFromPtr(raw);
}

fn freePage(allocator: std.mem.Allocator, base: usize) void {
    const ptr: [*]u8 = @ptrFromInt(base);
    allocator.rawFree(ptr[0..page_bytes], page_align, @returnAddress());
}

test "bump allocation stays inside a page and opens the next one" {
    var nursery: Nursery = .{};
    defer nursery.deinit(std.testing.allocator);

    const first = nursery.alloc(std.testing.allocator, 64) orelse return error.OutOfMemory;
    const second = nursery.alloc(std.testing.allocator, 64) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 64), @intFromPtr(second) - @intFromPtr(first));
    try std.testing.expectEqual(@as(usize, 1), nursery.pages.items.len);

    // Fill the rest of the page; the next request opens a second one.
    var remaining = page_bytes - 128;
    while (remaining >= 128) : (remaining -= 128) {
        _ = nursery.alloc(std.testing.allocator, 128) orelse return error.OutOfMemory;
    }
    _ = nursery.alloc(std.testing.allocator, 128) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 2), nursery.pages.items.len);
    try std.testing.expect(nursery.contains(@intFromPtr(first)));
    try std.testing.expect(!nursery.contains(@intFromPtr(first) + page_bytes * 4));
}

test "an object larger than the page budget is refused rather than split" {
    var nursery: Nursery = .{};
    defer nursery.deinit(std.testing.allocator);
    try std.testing.expect(nursery.alloc(std.testing.allocator, max_object_bytes + 1) == null);
    try std.testing.expect(nursery.alloc(std.testing.allocator, max_object_bytes) != null);
}

test "reclaim keeps pinned pages and recycles the rest" {
    var nursery: Nursery = .{};
    defer nursery.deinit(std.testing.allocator);

    _ = nursery.alloc(std.testing.allocator, 64) orelse return error.OutOfMemory;
    // Force a second page, then pin an object on the first.
    var remaining = page_bytes;
    while (remaining >= 4096) : (remaining -= 4096) {
        _ = nursery.alloc(std.testing.allocator, 4096) orelse return error.OutOfMemory;
    }
    try std.testing.expect(nursery.pages.items.len >= 2);
    nursery.pages.items[0].retained = true;
    const retained_base = nursery.pages.items[0].base;
    const recycled = nursery.pages.items.len - 1;

    nursery.reclaim(std.testing.allocator, nursery.boundary());

    // The pinned page stays in the nursery with its flag cleared, so the next
    // collection can reclaim it once nothing pins it.
    try std.testing.expectEqual(@as(usize, 1), nursery.pages.items.len);
    try std.testing.expectEqual(retained_base, nursery.pages.items[0].base);
    try std.testing.expect(!nursery.pages.items[0].retained);
    try std.testing.expectEqual(recycled, nursery.spare.items.len);

    // The recycled mappings are reused rather than re-mapped.
    const mapped_before = nursery.stats.pages_mapped;
    _ = nursery.alloc(std.testing.allocator, 64) orelse return error.OutOfMemory;
    try std.testing.expectEqual(mapped_before, nursery.stats.pages_mapped);
}

test "the walker visits every object start in allocation order" {
    var nursery: Nursery = .{};
    defer nursery.deinit(std.testing.allocator);

    var expected: [8]usize = undefined;
    for (&expected, 0..) |*slot, index| {
        const size: usize = 32 + index * 8;
        slot.* = @intFromPtr(nursery.alloc(std.testing.allocator, size) orelse return error.OutOfMemory);
    }

    var walker: Nursery.Walker(*const [8]usize) = .{ .nursery = &nursery, .context = &expected };
    const sizeOf = struct {
        fn f(context: *const [8]usize, addr: usize) usize {
            for (context, 0..) |start, index| {
                if (start == addr) return 32 + index * 8;
            }
            unreachable;
        }
    }.f;

    var seen: usize = 0;
    while (walker.next(sizeOf)) |addr| : (seen += 1) {
        try std.testing.expectEqual(expected[seen], addr);
    }
    try std.testing.expectEqual(@as(usize, 8), seen);
}

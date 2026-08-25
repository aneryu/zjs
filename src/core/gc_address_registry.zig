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
const memory = @import("memory.zig");

const Slab = memory.SmallObjectSlab;

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
    /// Slab arenas currently resolvable by mask.
    arenas_live: usize = 0,
    /// Arena bases that could not be recorded. Kept apart from
    /// `failed_inserts` because the blast radius is different by two orders of
    /// magnitude: one is a single object, the other is a whole 4 KiB arena.
    arena_insert_failures: usize = 0,
    /// Recovery attempts after such a failure.
    arena_resyncs: usize = 0,
    /// Tombstone compactions. Expect roughly `unregister_calls / (capacity/4)`;
    /// a count of zero on a churning workload means the budget never fired.
    rehashes: usize = 0,
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
    /// Live slab arena bases (`Slab.arena_size`-aligned, so one 4 KiB page).
    ///
    /// This is the structure that replaces per-object registration. An arena
    /// holds one size class with its header at the base, so an interior
    /// pointer masked down to its arena resolves to an owning block by
    /// arithmetic, and that block's first eight bytes are the GC metadata
    /// prefix whose `heap_accounted` bit says whether it is a live GC object.
    /// Nothing has to be recorded when an object is published.
    ///
    /// The set is still needed because masking alone cannot be trusted: a
    /// conservative candidate can name an unmapped address, and reading a
    /// magic out of it would fault rather than return false. But it changes on
    /// arena lifetime, not object lifetime -- at 4 KiB per arena against
    /// ~64-byte objects, roughly two orders of magnitude less traffic, and it
    /// is not a churn pattern that degenerates.
    arenas: std.AutoHashMapUnmanaged(usize, void) = .empty,

    /// An arena base failed to enter `arenas` and has not been recovered.
    ///
    /// Sticky. While set, some live objects may be unresolvable from a
    /// conservative candidate, so sweeping is unsound; the collector marks
    /// only. See `noteArenaCreated`.
    arenas_incomplete: bool = false,

    /// One-word bloom filter over every 4 KiB base a candidate could resolve
    /// through: arena bases OR'd with occupant-table page bases. `ruleOut` is
    /// two ALU ops, and it rejects almost every stack word before any hash
    /// probe runs -- JSC's TinyBloomFilter over its MarkedBlock set
    /// (ConservativeRoots.cpp:168-173), which it also rebuilds per collection
    /// because a bloom filter cannot forget.
    ///
    /// Soundness constraint, learned by review before it shipped: the filter
    /// MUST cover both populations. A filter built from arenas alone would
    /// early-out on words pointing into standalone-prefix allocations and the
    /// scan would miss live objects -- a use-after-free, not an optimization.
    /// Arena size and page size are both 4096, so one mask serves both.
    scan_filter: usize = 0,

    /// Removals since `by_header` and `pages` were last compacted.
    ///
    /// Zig's open-addressed map marks a removed slot as a TOMBSTONE and adds
    /// the slot back to `available` (hash_map.zig:957,1231), so a map under
    /// balanced churn never grows and therefore never rehashes. Its probe loop
    /// stops at a FREE slot (`while (!metadata[0].isFree())`, :984,:1155) and a
    /// tombstone is not free. This table sees one insert and one remove per GC
    /// object, so once every slot has been occupied at least once there is no
    /// free slot left anywhere and EVERY probe degenerates to a full-capacity
    /// scan -- for a live set of ~4.5k entries that is ~8k slots walked per
    /// allocation, measured at ~4.9us and 76% of raytrace's whole runtime.
    ///
    /// `rehash` is the only way to clear tombstones; there is no incremental
    /// reclaim. Compacting on a removal budget makes its O(capacity) cost
    /// amortise to a constant per removal.
    ///
    /// Historical note, because the first attempt at this was measured and
    /// rejected: that A/B ran against a build whose major collection never
    /// triggered, so almost nothing was ever freed, the maps barely churned,
    /// and the compaction was pure overhead against a disease that had not yet
    /// appeared. Fixing the collection policy is what exposed this.
    removes_since_rehash: usize = 0,

    /// A slab arena has been created. Its blocks become resolvable by mask.
    ///
    /// Failure here is not a lost statistic. An arena absent from the set is
    /// invisible to the conservative scanner for its whole life, and it holds up
    /// to 253 blocks, so one dropped insert can hide hundreds of live objects
    /// from a stack scan -- a use-after-free, not a leak, and one that would
    /// surface far from here. `arenas_incomplete` is therefore sticky and the
    /// collector must clear it (by re-walking the slab) before it is allowed to
    /// sweep again.
    pub fn noteArenaCreated(self: *Table, allocator: std.mem.Allocator, base: usize) void {
        self.arenas.put(allocator, base, {}) catch {
            self.stats.arena_insert_failures += 1;
            self.arenas_incomplete = true;
            return;
        };
        // `+ 1` so that a one-past-end pointer to an object in the arena's last
        // block is inside the window. The occupant table this replaces carried
        // the same `+ 1` (`occupantFor`: `hi = header_addr + bytes + 1`) for the
        // same reason. Without it, when a size class divides the block region
        // exactly, an object filling the final block of the highest arena has a
        // one-past-end address equal to `bounds_hi`, and the range check rejects
        // it before the `addr - 1` probe can resolve it.
        if (base < self.bounds_lo) self.bounds_lo = base;
        if (base + Slab.arena_size + 1 > self.bounds_hi) self.bounds_hi = base + Slab.arena_size + 1;
        self.stats.arenas_live += 1;
    }

    /// Re-register every arena the slab currently owns.
    ///
    /// Called by the collector when `arenas_incomplete` is set. Returns true if
    /// the set is whole again. Idempotent: `put` on a base already present is a
    /// no-op, so this can run as often as the collector likes.
    pub fn resyncArenas(self: *Table, allocator: std.mem.Allocator, slab: *Slab) bool {
        const Sync = struct {
            table: *Table,
            allocator: std.mem.Allocator,
            ok: bool = true,
            fn visit(ctx: *anyopaque, base: usize) void {
                const sync: *@This() = @ptrCast(@alignCast(ctx));
                if (sync.table.arenas.contains(base)) return;
                sync.table.arenas.put(sync.allocator, base, {}) catch {
                    sync.ok = false;
                    return;
                };
                if (base < sync.table.bounds_lo) sync.table.bounds_lo = base;
                if (base + Slab.arena_size + 1 > sync.table.bounds_hi) {
                    sync.table.bounds_hi = base + Slab.arena_size + 1;
                }
                sync.table.stats.arenas_live += 1;
            }
        };
        var sync: Sync = .{ .table = self, .allocator = allocator };
        slab.forEachArena(&sync, Sync.visit);
        if (sync.ok) self.arenas_incomplete = false;
        self.stats.arena_resyncs += 1;
        return sync.ok;
    }

    /// A slab arena is being returned to the backing allocator.
    pub fn noteArenaReleased(self: *Table, base: usize) void {
        if (self.arenas.remove(base)) self.stats.arenas_live -= 1;
    }

    /// Resolve a candidate through the arena geometry.
    ///
    /// Probes `addr` and `addr - 1`: a pointer one past the end of the object
    /// in the preceding block lands on this block's first byte, and that is a
    /// real reference to the preceding object. Reporting both is the same
    /// choice `resolveAny`'s greatest-`lo` rule and JSC's ConservativeRoots
    /// make, in the direction that retains rather than frees.
    ///
    /// Accepts an address anywhere in the owning block, including the slack
    /// between the object's end and the size class boundary. That is wider
    /// than the interval the occupant table recorded, and wider in the
    /// conservative direction.
    fn forEachGcObjectInArena(
        self: *Table,
        addr: usize,
        context: *anyopaque,
        visit: *const fn (*anyopaque, *gc.Header) void,
    ) usize {
        if (self.arenas.count() == 0) return 0;
        var hits: usize = 0;
        var reported: usize = 0;
        var probe = addr;
        while (true) {
            const base = probe & ~(Slab.arena_size - 1);
            if (self.arenas.contains(base)) resolve: {
                const user = Slab.userPtrWithinArena(base, probe) orelse break :resolve;
                const header: *gc.Header = @ptrCast(@alignCast(user));
                if (!header.metaConst().alloc_info.heap_accounted) break :resolve;
                if (reported == @intFromPtr(user)) break :resolve;
                reported = @intFromPtr(user);
                hits += 1;
                visit(context, header);
            }
            if (probe != addr or addr == 0) break;
            probe = addr - 1;
        }
        return hits;
    }

    /// Same geometry as `forEachGcObjectInArena`, single winner, for the
    /// `resolveAny` shape. Only the block containing `addr` itself.
    fn resolveInArena(self: *Table, addr: usize) ?*gc.Header {
        if (self.arenas.count() == 0) return null;
        // `addr` first, then `addr - 1`. Containment beats one-past-end, which
        // is the same tie-break `resolveAny`'s greatest-`lo` rule makes: a
        // pointer that is inside object B and also one past object A is a
        // reference to B. Only when nothing owns `addr` itself does the
        // preceding block get to claim it.
        if (self.resolveExactlyInArena(addr)) |header| return header;
        if (addr == 0) return null;
        return self.resolveExactlyInArena(addr - 1);
    }

    fn resolveExactlyInArena(self: *Table, addr: usize) ?*gc.Header {
        const base = addr & ~(Slab.arena_size - 1);
        if (!self.arenas.contains(base)) return null;
        const user = Slab.userPtrWithinArena(base, addr) orelse return null;
        const header: *gc.Header = @ptrCast(@alignCast(user));
        if (!header.metaConst().alloc_info.heap_accounted) return null;
        return header;
    }

    /// Audit the invariant candidate validation rests on, over every arena.
    ///
    /// Two directions, and they fail differently. A block that is FREE but
    /// reads `heap_accounted` makes the tracer treat unowned memory as an
    /// object: that is the hard SEGV this collector already produced once, from
    /// arena memory recycled with a stale byte. A block that holds a live
    /// object but does NOT resolve makes the conservative scan miss a real
    /// reference: that one frees a live object and surfaces far from its cause,
    /// which is why it needs a checker rather than a test per suspected site.
    ///
    /// Returns the number of violations, and reports the first few. Costs a
    /// walk of every block of every arena, so it is opt-in: `ZJS_GC_ARENA_AUDIT=1`.
    pub fn auditArenas(self: *Table) usize {
        const Audit = struct {
            violations: usize = 0,
            reported: usize = 0,
            free_but_accounted: usize = 0,
            fn visit(ctx: *anyopaque, user: [*]u8, is_free: bool) void {
                const audit: *@This() = @ptrCast(@alignCast(ctx));
                if (!is_free) return;
                const header: *const gc.Header = @ptrCast(@alignCast(user));
                if (!header.metaConst().alloc_info.heap_accounted) return;
                audit.violations += 1;
                audit.free_but_accounted += 1;
                if (audit.reported < 8) {
                    audit.reported += 1;
                    std.debug.print(
                        "gc: ARENA AUDIT free block at 0x{x} reads heap_accounted (kind {any}, rc {d})\n",
                        .{ @intFromPtr(user), header.metaConst().flags.kind, header.metaConst().rc },
                    );
                }
            }
        };
        var audit: Audit = .{};
        var it = self.arenas.keyIterator();
        while (it.next()) |base| Slab.forEachArenaBlock(base.*, &audit, Audit.visit);
        return audit.violations;
    }

    /// Rebuild the scan filter from the live sets. Called at the start of
    /// each conservative scan; a few hundred keys, so the rebuild is cheaper
    /// than a handful of the probes it saves.
    pub fn rebuildScanFilter(self: *Table) void {
        var bits: usize = 0;
        var arena_it = self.arenas.keyIterator();
        while (arena_it.next()) |base| bits |= base.*;
        var page_it = self.pages.keyIterator();
        while (page_it.next()) |page| bits |= page.* << page_shift;
        self.scan_filter = bits;
    }

    /// Two ALU ops: can this 4 KiB base possibly be registered?
    inline fn filterRulesOut(self: *const Table, base: usize) bool {
        return (base & self.scan_filter) != base;
    }

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        self.arenas.deinit(allocator);
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
        self.compactIfTombstoned();
    }

    /// Clear accumulated tombstones once they have cost enough to pay for it.
    ///
    /// The budget is a quarter of capacity, so one O(capacity) rehash is bought
    /// by capacity/4 removals: a constant per removal, against probes that
    /// would otherwise be O(capacity) each. Both maps are compacted together
    /// because `removePtr` deletes from both.
    fn compactIfTombstoned(self: *Table) void {
        self.removes_since_rehash += 1;
        const budget = self.by_header.capacity() / 4;
        if (budget == 0 or self.removes_since_rehash < budget) return;
        self.removes_since_rehash = 0;
        self.by_header.rehash(std.hash_map.AutoContext(usize){});
        self.pages.rehash(std.hash_map.AutoContext(usize){});
        self.stats.rehashes += 1;
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
        // The `addr - 1` probe can land in the PREVIOUS page when `addr` is
        // page-aligned, so both bases must clear the filter before the word
        // can be dismissed.
        const base = addr & ~(Slab.arena_size - 1);
        const prev_base = (addr -% 1) & ~(Slab.arena_size - 1);
        if (self.filterRulesOut(base) and self.filterRulesOut(prev_base)) return 0;
        var hits: usize = self.forEachGcObjectInArena(addr, context, visit);
        // The occupant table now holds only what the arena geometry cannot
        // reach: standalone-prefix allocations (over the slab's 512-byte class
        // ceiling or over-aligned) and, in shadow builds, strings and ropes.
        const bucket = self.pages.getPtr(addr >> page_shift) orelse {
            if (hits != 0) self.stats.lookup_hits += 1;
            return hits;
        };
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
        if (self.resolveInArena(addr)) |header| {
            self.stats.lookup_hits += 1;
            return .{ .gc_object = header };
        }
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

    /// Is this a live, published GC object as far as candidate validation is
    /// concerned? Answers for arena-resolvable objects too, not just the ones
    /// the occupant table still holds.
    pub fn containsHeader(self: *const Table, header: *const gc.Header) bool {
        const addr = @intFromPtr(header);
        const base = addr & ~(Slab.arena_size - 1);
        if (self.arenas.contains(base)) {
            if (Slab.userPtrWithinArena(base, addr)) |user| {
                if (@intFromPtr(user) == addr and header.metaConst().alloc_info.heap_accounted) return true;
            }
        }
        return self.by_header.contains(addr);
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

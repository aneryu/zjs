//! Sticky-mark generational state for the stop-the-world tracer.
//!
//! Stage 5 needs to tell young objects from old ones, and the object header
//! cannot carry that bit: `BlockFlags` is a full `u8` whose layout `memory.zig`
//! writes by position, and §4.5 keeps header changes in their own tranche. So
//! generation lives beside the heap instead of inside it.
//!
//! The sticky rule (§8.2) within one mark epoch is `allocated && !marked` is
//! young, `allocated && marked` is old: a young object that survives one minor
//! becomes old with no copy, age counter or promotion queue. Here that reads
//! as "an address in `young` has not survived a collection yet".
//!
//! Old-to-young edges are remembered by owner, not by slot (§8.3), because the
//! owner is what a minor has to re-trace. `rememberOwner` is idempotent and
//! never allocates on the mutator path beyond the set's own growth.

const std = @import("std");
const gc = @import("gc.zig");

pub const Stats = struct {
    young_count: usize = 0,
    remembered_owners: usize = 0,
    minor_collections: usize = 0,
    promoted: usize = 0,
    /// Owners re-traced by a minor that turned out to hold no young child.
    /// A high share means the remembered set is being written too eagerly.
    remembered_without_young: usize = 0,
    /// Barrier call breakdown: why an edge was or was not remembered.
    barrier_calls: usize = 0,
    barrier_young_owner: usize = 0,
    barrier_old_target: usize = 0,

    /// Minor pause samples, kept separately from the major distribution: a
    /// minor's whole purpose is to be short, so averaging it with whole-heap
    /// pauses would hide exactly the number Stage 5 is judged on.
    pause_ns_total: u64 = 0,
    pause_ns_max: u64 = 0,
    /// Young objects present when each minor started, summed. Divided by
    /// `minor_collections` this is the average young-list size a minor had to
    /// walk -- the scaling figure.
    young_at_start_total: usize = 0,
    young_at_start_max: usize = 0,
    /// Young objects a minor kept only because their refcount was live rather
    /// than because the trace reached them. This is the conservative-promotion
    /// figure: high values mean roots are still missing.
    survived_by_refcount: usize = 0,
};

pub const State = struct {
    young: std.AutoHashMapUnmanaged(usize, void) = .{},
    remembered: std.AutoHashMapUnmanaged(usize, void) = .{},
    stats: Stats = .{},

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.young.deinit(allocator);
        self.remembered.deinit(allocator);
        self.* = .{};
    }

    /// Record a freshly published object as young. Allocation failure is not
    /// fatal: losing a young entry only means the object is treated as old and
    /// collected by a major instead, which is the safe direction.
    pub fn noteAllocated(self: *State, allocator: std.mem.Allocator, header: *gc.Header) void {
        self.young.put(allocator, @intFromPtr(header), {}) catch return;
        self.stats.young_count = self.young.count();
    }

    pub fn isYoung(self: *const State, header: *const gc.Header) bool {
        return self.young.contains(@intFromPtr(header));
    }

    /// An old owner that now points at a young child. Recorded by owner so a
    /// minor can re-trace it; see §8.3 on why `tryMark(owner)` would be wrong
    /// (a sticky old mark would make the walk skip its children).
    pub fn rememberOwner(self: *State, allocator: std.mem.Allocator, owner: *gc.Header) void {
        self.remembered.put(allocator, @intFromPtr(owner), {}) catch return;
        self.stats.remembered_owners = self.remembered.count();
    }

    pub fn forget(self: *State, header: *const gc.Header) void {
        const key = @intFromPtr(header);
        _ = self.young.remove(key);
        _ = self.remembered.remove(key);
        self.stats.young_count = self.young.count();
        self.stats.remembered_owners = self.remembered.count();
    }

    /// Everything that survived is old now, so the whole young set clears and
    /// the strong remembered set with it (§8.3: new writes rebuild it after
    /// the mutator resumes).
    pub fn promoteSurvivors(self: *State, survivors: usize) void {
        self.stats.promoted += survivors;
        self.young.clearRetainingCapacity();
        self.remembered.clearRetainingCapacity();
        self.stats.young_count = 0;
        self.stats.remembered_owners = 0;
        self.stats.minor_collections += 1;
    }

    pub fn youngIterator(self: *const State) std.AutoHashMapUnmanaged(usize, void).KeyIterator {
        return self.young.keyIterator();
    }

    pub fn rememberedIterator(self: *const State) std.AutoHashMapUnmanaged(usize, void).KeyIterator {
        return self.remembered.keyIterator();
    }
};

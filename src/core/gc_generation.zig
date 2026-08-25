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
    remembered_drops: usize = 0,
    /// Times the minor was suspended for reclaiming too little to be worth its
    /// fixed cost. A workload that keeps its young objects alive is not a
    /// defect, but paying a full root and stack scan to discover that is.
    minor_suspensions: usize = 0,
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
    remembered: std.AutoHashMapUnmanaged(usize, void) = .{},
    low_yield_streak: usize = 0,
    probe_backoff: usize = 1,
    probe_countdown: usize = 0,
    stats: Stats = .{},

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.remembered.deinit(allocator);
        self.* = .{};
    }

    /// Record a freshly published object as young. Allocation failure is not
    /// fatal: losing a young entry only means the object is treated as old and
    /// collected by a major instead, which is the safe direction.
    /// Young is a header bit now, not a set membership: a hash-map insert on
    /// every allocation measured at 28% of benchmark throughput, and a
    /// per-allocation fact has to live somewhere the allocator already
    /// touches.
    pub fn isYoung(self: *const State, header: *const gc.Header) bool {
        _ = self;
        return header.metaConst().flags.young;
    }

    /// An old owner that now points at a young child. Recorded by owner so a
    /// minor can re-trace it; see §8.3 on why `tryMark(owner)` would be wrong
    /// (a sticky old mark would make the walk skip its children).
    pub fn rememberOwner(self: *State, allocator: std.mem.Allocator, owner: *gc.Header) void {
        self.remembered.put(allocator, @intFromPtr(owner), {}) catch {
            // A dropped entry is a silent old-to-young edge: the minor will not
            // re-trace this owner and will condemn the child it just gained.
            // The registry keeps the same counter for the same reason; without
            // one, an allocation failure here is indistinguishable from a
            // missing barrier when the crash finally arrives.
            self.stats.remembered_drops += 1;
            return;
        };
        self.stats.remembered_owners = self.remembered.count();
    }

    pub fn forget(self: *State, header: *const gc.Header) void {
        _ = self.remembered.remove(@intFromPtr(header));
        if (header.metaConst().flags.young and self.stats.young_count > 0) {
            self.stats.young_count -= 1;
        }
        self.stats.remembered_owners = self.remembered.count();
    }

    /// Everything that survived is old now, so the whole young set clears and
    /// the strong remembered set with it (§8.3: new writes rebuild it after
    /// the mutator resumes).
    /// Survivors become old. With generation in the header the promotion is
    /// the collector clearing each survivor's bit as it walks; this records
    /// the accounting side and resets the remembered set, which is stale once
    /// nothing is young (§8.3).
    /// Drop the young set and the remembered set built from it, without
    /// claiming a collection happened. A major promotes everything too, and
    /// counting that as a minor would corrupt the pause statistics that
    /// separate the two.
    pub fn retireYoungSet(self: *State) void {
        self.remembered.clearRetainingCapacity();
        self.stats.young_count = 0;
        self.stats.remembered_owners = 0;
    }

    /// Minors this workload has run whose yield did not justify their cost.
    ///
    /// A minor's price is almost all fixed: every precise root, a spilled and
    /// conservatively scanned native stack, and a walk of every remembered
    /// owner, none of which shrinks with the young set. It is worth paying only
    /// when most of the young set is dead. The weak generational hypothesis
    /// says it usually is -- but a workload is free to disagree, and splay does
    /// emphatically: it links each freshly allocated node straight into the
    /// live tree, 95%+ of the young set survives, and measured on 2026-08-25
    /// disabling minors entirely made it 21% FASTER while reclaiming more.
    /// earley-boyer loses 3% the same way.
    ///
    /// So the policy stops asserting the hypothesis and measures it instead.
    /// After `low_yield_limit` consecutive minors reclaim less than a tenth of
    /// the young set, minors stop being offered; the next major clears the
    /// count, because a major changes the old generation and with it the
    /// survival rate the next minor would see.
    pub const low_yield_limit: usize = 3;
    const low_yield_reclaim_percent: usize = 10;

    /// How many majors to let pass before probing a suspended minor again.
    /// Doubles on each probe that confirms the workload still keeps its young
    /// objects, so a program that simply does not benefit stops being charged
    /// for the discovery. Capped so a phase change is still noticed.
    const probe_backoff_max: usize = 64;

    pub fn noteMinorYield(self: *State, young_before: usize, reclaimed: usize) void {
        if (young_before == 0) return;
        if (reclaimed * 100 >= young_before * low_yield_reclaim_percent) {
            self.low_yield_streak = 0;
            self.probe_backoff = 1;
            self.probe_countdown = 0;
            return;
        }
        self.low_yield_streak += 1;
        if (self.low_yield_streak >= low_yield_limit) {
            if (self.low_yield_streak == low_yield_limit) self.stats.minor_suspensions += 1;
            self.probe_backoff = @min(self.probe_backoff * 2, probe_backoff_max);
            self.probe_countdown = self.probe_backoff;
        }
    }

    /// A major has run: let the minor try once more.
    ///
    /// Decay by one rather than reset to zero. Zeroing made every major buy a
    /// fresh run of `low_yield_limit` unproductive minors, and on a workload
    /// whose majors are frequent that is most of them -- splay recovered only a
    /// third of what suspending the minor outright was worth. Decaying leaves a
    /// suspended collector one probe per major: enough to notice that the
    /// workload's young mortality has changed, cheap enough that noticing costs
    /// one scan instead of three.
    pub fn decayLowYieldStreak(self: *State) void {
        if (self.low_yield_streak == 0) return;
        if (self.probe_countdown > 0) {
            self.probe_countdown -= 1;
            return;
        }
        self.low_yield_streak -= 1;
    }

    pub fn minorSuspended(self: *const State) bool {
        return self.low_yield_streak >= low_yield_limit;
    }

    pub fn promoteSurvivors(self: *State, survivors: usize) void {
        self.stats.promoted += survivors;
        self.retireYoungSet();
        self.stats.minor_collections += 1;
    }

    pub fn rememberedIterator(self: *const State) std.AutoHashMapUnmanaged(usize, void).KeyIterator {
        return self.remembered.keyIterator();
    }
};

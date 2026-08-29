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
const builtin = @import("builtin");
const gc = @import("gc.zig");

/// Direct field assertions consume the mirrored remembered-owner count only
/// in tests. Production reports derive the count from the owning hash map.
const mutation_stats_enabled = builtin.is_test;

/// The forget-side membership-cache skip (`forgetUnremembered`) rests on I0:
/// for a `gc.traceRememberedCacheEligible` kind, a clear byte-6 bit7 implies
/// absence from `remembered`. Under runtime safety we check I0 at the decision point on
/// every single detach, and we latch the one interval where it is knowingly
/// false (I3: the retirement transaction clears the bits before the map).
/// Both cost nothing in ReleaseFast, where the skip is the whole point.
pub const remembered_skip_audit = std.debug.runtime_safety;

pub const Stats = struct {
    young_count: usize = 0,
    remembered_owners: usize = 0,
    remembered_drops: usize = 0,
    /// Times the minor was suspended for reclaiming too little to be worth its
    /// fixed cost. A workload that keeps its young objects alive is not a
    /// defect, but paying a full root and stack scan to discover that is.
    minor_suspensions: usize = 0,
    minor_collections: usize = 0,
    /// Minor-only outcome. `promoted` below also includes a detailed major's
    /// survivor census, so it cannot price what the minor bought by itself.
    minor_reclaimed: usize = 0,
    minor_promoted: usize = 0,
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
    /// Cumulative minor STW decomposition. Timed only when detailed GC
    /// reports are requested; `pause_ns_total` stays the always-on outer
    /// envelope, so its remainder also exposes collector init/deinit and
    /// instrumentation overhead instead of losing them between phases.
    minor_clear_ns_total: u64 = 0,
    minor_roots_ns_total: u64 = 0,
    minor_conservative_ns_total: u64 = 0,
    minor_remembered_ns_total: u64 = 0,
    minor_trace_ns_total: u64 = 0,
    minor_sweep_ns_total: u64 = 0,
    minor_promote_ns_total: u64 = 0,
    /// Young objects present when each minor started, summed. Divided by
    /// `minor_collections` this is the average young-list size a minor had to
    /// walk -- the scaling figure.
    young_at_start_total: usize = 0,
    young_at_start_max: usize = 0,
    /// Young objects reachable only from conservative stack/register candidates,
    /// not from the precise root graph. Populated only by
    /// `ZJS_GC_VERIFY_MINOR=1`, whose full-trace prepass can separate the two
    /// root populations without changing the production minor's liveness rule.
    conservative_only_young: usize = 0,
    /// Retirement transactions committed and abandoned. An abandon count
    /// that keeps climbing means minors are being starved by a failing
    /// major, which is a policy problem the numbers should surface.
    retirement_commits: usize = 0,
    retirement_abandons: usize = 0,
    /// Times the remembered set actually had entries to drop. Compare with
    /// major count: the difference is the memsets the guard avoided.
    remembered_clears: usize = 0,

    pub fn minorPhaseNsTotal(self: Stats) u64 {
        return self.minor_clear_ns_total +|
            self.minor_roots_ns_total +|
            self.minor_conservative_ns_total +|
            self.minor_remembered_ns_total +|
            self.minor_trace_ns_total +|
            self.minor_sweep_ns_total +|
            self.minor_promote_ns_total;
    }
};

comptime {
    // Registry embeds this structure. Keep its footprint change explicit:
    // The minor outcome and phase totals grow the 64-bit layout from 144B to
    // 216B. The conservative-only probe repurposes the obsolete RC-survival
    // counter, so the release Registry does not grow for this evidence task.
    if (@sizeOf(usize) == 8) std.debug.assert(@sizeOf(Stats) == 216);
}

pub const MinorPauseDistribution = struct {
    samples_total: usize,
    samples_retained: usize,
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    max_ns: u64,
};

/// Where the young generation stands relative to an open major.
///
/// Block-cell retirement is trace-coupled, while list-carrier retirement rides
/// the mandatory finish condemnation walk. Both only become complete at a
/// successful major commit, so between `begin` and that commit the young
/// population is in a state no minor may consume. This makes the window
/// explicit instead of implied.
pub const MajorRetirement = enum {
    /// Quiescent: the sticky equation holds, minors may run.
    clean,
    /// A major is retiring block cells as it traces them. Minors closed.
    tracing,
    /// A major opened the window and did not commit -- aborted, failed to
    /// seed, or declined to sweep an incomplete arena set. Part of the young
    /// population may already have been promoted, so no minor may run until
    /// a major completes and repairs the state.
    needs_major,
};

pub const State = struct {
    major_retirement: MajorRetirement = .clean,
    remembered: std.AutoHashMapUnmanaged(usize, void) = .{},
    low_yield_streak: usize = 0,
    probe_backoff: usize = 1,
    probe_countdown: usize = 0,
    stats: Stats = .{},
    /// Populated only for `--gc-stats`. The shipped path retains the always-on
    /// total/max scalars but never allocates a sample buffer. A diagnostic run
    /// keeps every sample: silently overwriting a bounded ring would turn the
    /// Stage 5 "pause distribution" row into a distribution of an arbitrary
    /// tail window rather than of the run being cited.
    minor_pause_samples: std.ArrayList(u64) = .empty,
    minor_pause_sample_drops: usize = 0,
    /// I3 latch. `Registry.retireGenerationalYoungSet` clears every carrier's
    /// cache bit and only then clears the map, so inside that pair the cache
    /// says "absent" while the map still holds the entry -- exactly the state
    /// `forgetUnremembered` must never observe. Its safety argument is that
    /// the pair is one uninterruptible STW transaction: no mutator, no free,
    /// hence no `forget`. This field turns that comment into a checked
    /// precondition; a future slice boundary dropped between the two halves
    /// trips an assert instead of silently leaking a dangling address.
    retirement_window_open: if (remembered_skip_audit) bool else void =
        if (remembered_skip_audit) false else {},

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.minor_pause_samples.deinit(allocator);
        self.remembered.deinit(allocator);
        self.* = .{};
    }

    pub fn recordMinorPause(self: *State, allocator: std.mem.Allocator, duration_ns: u64, retain_sample: bool) void {
        self.stats.pause_ns_total +|= duration_ns;
        if (duration_ns > self.stats.pause_ns_max) self.stats.pause_ns_max = duration_ns;
        if (!retain_sample) return;
        self.minor_pause_samples.append(allocator, duration_ns) catch {
            self.minor_pause_sample_drops +|= 1;
        };
    }

    pub fn minorPauseDistribution(self: *State) ?MinorPauseDistribution {
        const retained = self.minor_pause_samples.items.len;
        if (retained == 0) return null;
        const window = self.minor_pause_samples.items;
        std.sort.heap(u64, window, {}, std.sort.asc(u64));
        return .{
            .samples_total = retained +| self.minor_pause_sample_drops,
            .samples_retained = retained,
            .p50_ns = window[percentileIndex(retained, 50)],
            .p95_ns = window[percentileIndex(retained, 95)],
            .p99_ns = window[percentileIndex(retained, 99)],
            .max_ns = window[retained - 1],
        };
    }

    fn percentileIndex(len: usize, percentile: usize) usize {
        const rank = (len * percentile + 99) / 100;
        return @min(if (rank == 0) 0 else rank - 1, len - 1);
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
    /// Returns true only when the map owns the entry after this call. A
    /// caller may publish a redundant fast-path cache bit from that fact; an
    /// allocation failure must leave such a bit clear so a later write can
    /// retry instead of silently suppressing the missing owner.
    pub fn rememberOwner(self: *State, allocator: std.mem.Allocator, owner: *gc.Header) bool {
        self.remembered.put(allocator, @intFromPtr(owner), {}) catch {
            // A dropped entry is a silent old-to-young edge: the minor will not
            // re-trace this owner and will condemn the child it just gained.
            // The registry keeps the same counter for the same reason; without
            // one, an allocation failure here is indistinguishable from a
            // missing barrier when the crash finally arrives.
            self.stats.remembered_drops += 1;
            return false;
        };
        if (comptime mutation_stats_enabled) self.stats.remembered_owners = self.remembered.count();
        return true;
    }

    pub fn forget(self: *State, header: *const gc.Header) void {
        if (comptime remembered_skip_audit) std.debug.assert(!self.retirement_window_open);
        _ = self.remembered.remove(@intFromPtr(header));
        self.forgetYoungCensus(header);
        if (comptime mutation_stats_enabled) self.stats.remembered_owners = self.remembered.count();
    }

    /// `forget` for an owner the caller has already proven absent from the
    /// remembered map: an eligible carrier whose byte-6 membership cache bit
    /// is clear (gc.zig I0). Every detach of a carrier that never took the
    /// old-to-young barrier -- the overwhelming majority -- lands here and
    /// skips a Wyhash plus an open-addressing probe, which measured as ~55%
    /// of `removeGcObjectAfter` on splay for a set that peaks at 590 entries.
    ///
    /// The kind precondition was `== .object` while the cache was Object-only.
    /// That was also why the skip never fired: the detach traffic on splay /
    /// raytrace / earley-boyer is `.shape` and `.var_ref` (audit §9.5), block
    /// cells never reaching this path at all. §10 widened the lease to every
    /// `gc.traceRememberedCacheEligible` kind, and this precondition with it.
    ///
    /// `remembered_owners` deliberately is NOT refreshed: nothing was removed,
    /// so the mirrored count is still correct, and refreshing it would put the
    /// `count()` load back on the path the skip exists to empty.
    pub fn forgetUnremembered(self: *State, header: *const gc.Header) void {
        std.debug.assert(gc.traceRememberedCacheEligible(header.metaConst().flags.kind));
        if (comptime remembered_skip_audit) {
            std.debug.assert(!self.retirement_window_open);
            // I0 is the entire licence for skipping the removal. Check it here,
            // per detach, rather than waiting for the collection-boundary
            // auditors to report the dangling address it would leave behind.
            std.debug.assert(!self.remembered.contains(@intFromPtr(header)));
        }
        self.forgetYoungCensus(header);
    }

    /// The half of `forget` that has nothing to do with the remembered map:
    /// the young population census keyed off `flags.young`. Shared so the skip
    /// can drop only the map removal (audit §8.4) instead of returning early.
    inline fn forgetYoungCensus(self: *State, header: *const gc.Header) void {
        if (header.metaConst().flags.young and self.stats.young_count > 0) {
            self.stats.young_count -= 1;
        }
    }

    /// I3 transaction bracket. Opened by the Registry before it walks the map
    /// clearing cache bits, closed by `retireYoungSet` once the map itself is
    /// gone. Debug-only: in ReleaseFast both halves compile to nothing.
    pub fn openRetirementWindow(self: *State) void {
        if (comptime !remembered_skip_audit) return;
        std.debug.assert(!self.retirement_window_open);
        self.retirement_window_open = true;
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
        // Skip the clear when there is nothing to clear. Zig's
        // `clearRetainingCapacity` re-initialises the whole metadata array
        // regardless of count (std/hash_map.zig, `initMetadatas`), so an
        // already-empty map still costs a memset of its high-water capacity
        // -- and this runs at both ends of every major. earley-boyer holds
        // two remembered owners and takes 7,772 majors.
        if (self.remembered.count() != 0) {
            self.remembered.clearRetainingCapacity();
            self.stats.remembered_clears +|= 1;
        }
        self.stats.young_count = 0;
        if (comptime mutation_stats_enabled) self.stats.remembered_owners = 0;
        // Map and cache now agree again (both empty), so I0 holds once more.
        if (comptime remembered_skip_audit) self.retirement_window_open = false;
    }

    /// A major is about to start tracing. Must be called before any root is
    /// shaded, because the first shade may already retire a block cell.
    pub fn beginMajorRetirement(self: *State) void {
        self.major_retirement = .tracing;
    }

    /// The major reached a successful commit: the whole young population has
    /// been retired, by the trace for block cells and by the condemnation
    /// walk for the rest.
    pub fn commitMajorRetirement(self: *State) void {
        self.major_retirement = .clean;
        self.stats.retirement_commits +|= 1;
    }

    /// The major left without committing. Some block cells may already read
    /// old while the structures still describe them as young, so minors stay
    /// closed until a major repairs it.
    pub fn abandonMajorRetirement(self: *State) void {
        if (self.major_retirement == .tracing) {
            self.major_retirement = .needs_major;
            self.stats.retirement_abandons +|= 1;
        }
    }

    pub fn minorsAllowed(self: *const State) bool {
        return self.major_retirement == .clean;
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
        self.stats.minor_reclaimed +|= reclaimed;
        self.stats.minor_promoted +|= young_before -| reclaimed;
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

    pub fn noteMinorPromotion(self: *State, survivors: usize) void {
        self.stats.promoted += survivors;
        self.stats.minor_collections += 1;
    }

    pub fn rememberedIterator(self: *const State) std.AutoHashMapUnmanaged(usize, void).KeyIterator {
        return self.remembered.keyIterator();
    }

    pub fn rememberedOwnerCount(self: *const State) usize {
        return self.remembered.count();
    }
};

//! Pass-B corpse census (measurement only, `-Dzjs_experimental_gc_corpse_census=true`).
//!
//! `drainCycleDeferredFreesBudgeted` costs 0.314 G cycles on fixed-work splay
//! (3.07% of the trace run, ~27.8 cycles per parked entry). The block-drain /
//! hot-reuse design leaves two follow-on stages conditional on evidence this
//! module produces:
//!
//!   * stage 2 -- skip the per-cell allocator free link for a private block and
//!     let `openBlock` rebuild the whole interval table from the alloc bitmap;
//!   * stage 3 -- keep whole blocks of "trivially freeable" corpses out of the
//!     global LIFO entirely and settle them with block-level bitmap arithmetic.
//!
//! Both are priced by the same question: for each parked corpse, what does the
//! PHYSICAL release actually do beyond `clear alloc bit + allocated_count +
//! MemoryAccount debit`? This census answers it by classification, not by
//! guessing from a profile.
//!
//! It is comptime-gated rather than flag-gated on purpose. The quantity being
//! measured is the per-entry work inside the drain; a runtime flag test in that
//! loop would be part of the measurement. With the option off this file
//! contributes no field, no counter and no instruction.

const std = @import("std");
const gc = @import("gc.zig");

pub const enabled = gc.corpse_census_enabled;

/// Longest run length bucket reported individually; everything above lands in
/// the final open bucket.
pub const run_buckets = [_]u32{ 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024 };

/// One parked corpse, described at the moment Pass B reaches it and BEFORE any
/// memory is released. Every field is read from state the drain is about to
/// touch anyway; the census does not keep side tables.
pub const Entry = struct {
    /// Cell in a 64 KiB classed block (versus a standalone/slab allocation).
    block_cell: bool,
    /// `gc.GcKind` as an integer, for the generic prefix breakdown.
    kind: u8,
    /// Pass B keeps the allocation as a resource-stripped weak husk. The cell
    /// stays allocated; neither stage may release it.
    weak_husk: bool,
    /// `takeWeakObjectIdentity` runs: a side-table removal keyed by the object.
    weak_id: bool,
    /// The trace-only fast arm in `Object.freeCycleDeferredStruct`, read from
    /// `Object.passBFastArmEligible` itself rather than restated here: no
    /// `releaseObjectDefinition` call and no inline-payload base fixup.
    fast_class: bool,
    /// Standard (built-in) class id. `releaseObjectDefinition` is a single
    /// compare-and-return for these, and `destructionPlan` is one
    /// `standard_plans[id]` load with no pin state.
    ///
    /// This started as the "what would a widened fast arm be worth" column.
    /// The arm has since been widened to exactly `standard_class and
    /// !inline_payload`, so `block_trivial_std` is now an INDEPENDENT
    /// restatement of `block_trivial`: the two counts must agree, and any
    /// divergence means the predicate and the census have drifted apart.
    standard_class: bool,
    /// Class with an inline payload: the allocation base is BEFORE the Object,
    /// and release goes through `freeAlignedBytes`, never `freeSmallCell`.
    inline_payload: bool,
    /// Trailing property storage. Its `MemoryAccount` debit is
    /// `@sizeOf(Object) + trailing_property_bytes`, NOT the cell size, so a
    /// block-level debit may not simply multiply by `cell_size`.
    trailing_fam: bool,
    /// The block is an interval allocator, so `pushCell` writes the freed cell
    /// onto the `next_free` returned-cell LIFO instead of `free_list`.
    interval_allocator: bool,
    /// The block is `active[class]`: the mutator may allocate from its other
    /// holes between destruction slices, so it must keep a live free
    /// representation. Design §5 forbids the no-link route here.
    allocator_current: bool,
    /// This release takes `allocated_count` to zero, moving the block into the
    /// empty/aged-decommit lifecycle. A per-block action, not a per-cell one.
    becomes_empty: bool,
    /// Cell index inside the block (meaningless when `block_cell` is false).
    cell_index: u32,
    /// Class id, bucketed for the non-fast-arm breakdown.
    class_id: u32,
};

pub const Counters = struct {
    entries_total: u64 = 0,

    // ---- generic (non-block-cell) prefix ----
    generic_entries: u64 = 0,
    generic_by_kind: [16]u64 = @splat(0),

    // ---- block-cell corpses ----
    block_entries: u64 = 0,
    block_weak_husk: u64 = 0,
    block_weak_id: u64 = 0,
    block_fast_class: u64 = 0,
    block_generic_class: u64 = 0,
    block_inline_payload: u64 = 0,
    block_trailing_fam: u64 = 0,
    block_link_interval: u64 = 0,
    block_link_freelist: u64 = 0,
    block_allocator_current: u64 = 0,
    block_becomes_empty: u64 = 0,
    /// Every non-husk block corpse writes exactly one 4-byte poisoned free
    /// link (`pushCell`). This is the stage-2 claimable population.
    block_link_writes: u64 = 0,
    /// Corpses whose release needs nothing but bitmap/count/account work,
    /// measured against the fast-arm predicate the code branches on.
    block_trivial: u64 = 0,
    /// The same, restated independently as "standard class, no inline
    /// payload". Equal to `block_trivial` since the arm was widened; kept as
    /// the cross-check that the predicate covers what it claims to.
    block_trivial_std: u64 = 0,

    // ---- run topology ----
    runs: u64 = 0,
    run_entries: u64 = 0,
    run_len_hist: [run_buckets.len + 1]u64 = @splat(0),
    /// Distinct alloc-bitmap words a run touches. Stage 3 replaces `run_len`
    /// entry visits with this many word read-modify-writes.
    run_words: u64 = 0,
    /// Runs in which every corpse is trivially freeable and the block is not
    /// allocator-current: eligible for whole-block bitmap settlement.
    runs_all_trivial: u64 = 0,
    entries_in_trivial_runs: u64 = 0,
    words_in_trivial_runs: u64 = 0,
    /// The same at block granularity under a standard-class fast arm, which
    /// is the unit stage 3 would actually settle.
    runs_all_trivial_std: u64 = 0,
    entries_in_trivial_std_runs: u64 = 0,
    words_in_trivial_std_runs: u64 = 0,
    /// Runs whose corpses do not share one logical `MemoryAccount` size.
    runs_mixed_fam: u64 = 0,

    // ---- bitmap-word granularity ----
    // A run is often ~1,000 corpses, so a single non-trivial corpse
    // disqualifies a whole block. The 64-cell alloc-bitmap word is the
    // finest granularity at which a bitmap-arithmetic release is still one
    // read-modify-write, so it is the honest unit for stage 3.
    words_all_trivial: u64 = 0,
    entries_in_trivial_words: u64 = 0,
    words_all_trivial_std: u64 = 0,
    entries_in_trivial_std_words: u64 = 0,
    /// Words whose corpses do not share one logical `MemoryAccount` size
    /// (`trailing_fam` is not uniform). A block-level debit of
    /// `n * cell_size` would silently change the RC denominator for these.
    words_mixed_fam: u64 = 0,

    /// Non-fast-arm corpses by class id (open bucket at the end).
    generic_class_hist: [40]u64 = @splat(0),
    /// Runs whose cell indices are not monotone. The bitmap-word transition
    /// count is exact only for monotone runs; a non-monotone run would make
    /// `run_words` an overestimate.
    runs_non_monotone: u64 = 0,
    /// Blocks observed more than once as a separate run (would falsify the
    /// design's "each block occupies one contiguous run" claim at census
    /// granularity; recorded, not asserted).
    runs_resuming_same_block: u64 = 0,

    // ---- stage 3 ----
    /// Corpses `object_gc.trySettleTracerBlockCorpse` released in Pass A, so
    /// they never became a parked entry at all. Stage 3's whole claim is that
    /// this counter absorbs what `block_trivial` used to report; the two are
    /// read together across a base/new census pair.
    pass_a_settled: u64 = 0,
    /// Of those, the trailing-FAM variant. Its `MemoryAccount` debit differs
    /// from the plain one, so a non-zero value here is the proof that the
    /// settlement is charging per corpse rather than per cell size.
    pass_a_settled_fam: u64 = 0,

    // ---- drain invocations ----
    drain_calls: u64 = 0,
    /// Drain calls that stopped on the 4,096 budget rather than emptying.
    drain_calls_budget_stopped: u64 = 0,
};

pub var counters: Counters = .{};

/// Cross-entry run state. Only touched when the census is compiled in.
var run_len: u32 = 0;
var run_words_seen: u32 = 0;
var run_last_word: u32 = 0;
var run_last_index: u32 = 0;
var run_trivial: bool = true;
var run_trivial_std: bool = true;
var run_fam_seen: bool = false;
var run_plain_seen: bool = false;
var run_monotone_broken: bool = false;
var run_prev_block: usize = 0;
var word_len: u32 = 0;
var word_trivial: bool = true;
var word_trivial_std: bool = true;
var word_fam_seen: bool = false;
var word_plain_seen: bool = false;

fn flushWord() void {
    if (word_len == 0) return;
    if (word_trivial) {
        counters.words_all_trivial += 1;
        counters.entries_in_trivial_words += word_len;
    }
    if (word_trivial_std) {
        counters.words_all_trivial_std += 1;
        counters.entries_in_trivial_std_words += word_len;
    }
    if (word_fam_seen and word_plain_seen) counters.words_mixed_fam += 1;
    word_len = 0;
    word_trivial = true;
    word_trivial_std = true;
    word_fam_seen = false;
    word_plain_seen = false;
}

pub inline fn noteDrainCall() void {
    if (comptime !enabled) return;
    counters.drain_calls += 1;
}

pub inline fn noteBudgetStop() void {
    if (comptime !enabled) return;
    counters.drain_calls_budget_stopped += 1;
}

/// Stage 3: one corpse released in Pass A instead of parked.
pub inline fn noteSettled(trailing_fam: bool) void {
    if (comptime !enabled) return;
    counters.pass_a_settled += 1;
    if (trailing_fam) counters.pass_a_settled_fam += 1;
}

pub fn note(e: Entry) void {
    if (comptime !enabled) return;
    counters.entries_total += 1;
    if (!e.block_cell) {
        counters.generic_entries += 1;
        const k: usize = @min(e.kind, counters.generic_by_kind.len - 1);
        counters.generic_by_kind[k] += 1;
        return;
    }

    counters.block_entries += 1;
    if (e.weak_husk) counters.block_weak_husk += 1;
    if (e.weak_id) counters.block_weak_id += 1;
    if (e.fast_class) {
        counters.block_fast_class += 1;
    } else {
        counters.block_generic_class += 1;
        const ci: usize = @min(e.class_id, counters.generic_class_hist.len - 1);
        counters.generic_class_hist[ci] += 1;
    }
    if (e.inline_payload) counters.block_inline_payload += 1;
    if (e.trailing_fam) counters.block_trailing_fam += 1;
    if (e.allocator_current) counters.block_allocator_current += 1;
    if (e.becomes_empty) counters.block_becomes_empty += 1;
    if (!e.weak_husk) {
        counters.block_link_writes += 1;
        if (e.interval_allocator) counters.block_link_interval += 1 else counters.block_link_freelist += 1;
    }

    // "Trivial" = the physical release is exactly {clear alloc bit,
    // allocated_count -= 1, MemoryAccount debit}. Anything that keeps the
    // allocation, removes a side-table entry, consults the class table, or
    // requires a live free representation is not.
    const trivial = !e.weak_husk and !e.weak_id and e.fast_class and
        !e.inline_payload and !e.allocator_current;
    if (trivial) counters.block_trivial += 1;
    const trivial_std = !e.weak_husk and !e.weak_id and e.standard_class and
        !e.inline_payload and !e.allocator_current;
    if (trivial_std) counters.block_trivial_std += 1;

    // Run accounting.
    counters.run_entries += 1;
    const word = e.cell_index / 64;
    if (run_len == 0) {
        run_words_seen = 1;
        run_last_word = word;
        run_last_index = e.cell_index;
        run_trivial = trivial;
        run_trivial_std = trivial_std;
        run_fam_seen = false;
        run_plain_seen = false;
        run_monotone_broken = false;
    } else {
        if (word != run_last_word) {
            flushWord();
            run_words_seen += 1;
            run_last_word = word;
        }
        // Pass A serves a block's doomed bits in ascending index order and the
        // LIFO reverses that, so Pass B should see strictly descending indices.
        if (e.cell_index >= run_last_index) run_monotone_broken = true;
        run_last_index = e.cell_index;
        run_trivial = run_trivial and trivial;
        run_trivial_std = run_trivial_std and trivial_std;
    }
    if (e.trailing_fam) run_fam_seen = true else run_plain_seen = true;
    word_len += 1;
    word_trivial = word_trivial and trivial;
    word_trivial_std = word_trivial_std and trivial_std;
    if (e.trailing_fam) word_fam_seen = true else word_plain_seen = true;
    run_len += 1;
}

/// Called with the block base whose run Pass B has just finished.
pub fn noteRunBoundary(block_base: usize) void {
    if (comptime !enabled) return;
    if (run_len == 0) return;
    flushWord();
    counters.runs += 1;
    counters.run_words += run_words_seen;
    if (run_monotone_broken) counters.runs_non_monotone += 1;
    if (block_base == run_prev_block) counters.runs_resuming_same_block += 1;
    run_prev_block = block_base;

    var bucket: usize = run_buckets.len;
    for (run_buckets, 0..) |limit, i| {
        if (run_len <= limit) {
            bucket = i;
            break;
        }
    }
    counters.run_len_hist[bucket] += 1;

    if (run_trivial) {
        counters.runs_all_trivial += 1;
        counters.entries_in_trivial_runs += run_len;
        counters.words_in_trivial_runs += run_words_seen;
    }
    if (run_trivial_std) {
        counters.runs_all_trivial_std += 1;
        counters.entries_in_trivial_std_runs += run_len;
        counters.words_in_trivial_std_runs += run_words_seen;
    }
    if (run_fam_seen and run_plain_seen) counters.runs_mixed_fam += 1;
    run_len = 0;
    run_words_seen = 0;
    run_monotone_broken = false;
    run_trivial = true;
    run_trivial_std = true;
    run_fam_seen = false;
    run_plain_seen = false;
}

/// A budget may stop halfway through a block run; the run continues in the
/// next slice, so nothing is closed here. Kept as an explicit call so the
/// asymmetry is visible at the call site.
pub inline fn noteSliceEnd() void {
    if (comptime !enabled) return;
}

pub fn report(w: anytype) !void {
    if (comptime !enabled) return;
    const c = &counters;
    try w.print("gc-census: drain_calls {d} budget_stopped {d}\n", .{ c.drain_calls, c.drain_calls_budget_stopped });
    try w.print("gc-census: entries_total {d} block {d} generic {d}\n", .{ c.entries_total, c.block_entries, c.generic_entries });
    try w.print("gc-census: pass_a_settled {d} (fam {d})\n", .{ c.pass_a_settled, c.pass_a_settled_fam });
    for (c.generic_by_kind, 0..) |n, k| {
        if (n == 0) continue;
        try w.print("gc-census: generic_kind[{d}] {d}\n", .{ k, n });
    }
    try w.print("gc-census: block_weak_husk {d} weak_id {d} fast_class {d} generic_class {d}\n", .{
        c.block_weak_husk, c.block_weak_id, c.block_fast_class, c.block_generic_class,
    });
    try w.print("gc-census: block_inline_payload {d} trailing_fam {d}\n", .{
        c.block_inline_payload, c.block_trailing_fam,
    });
    try w.print("gc-census: block_link_writes {d} (interval {d} freelist {d})\n", .{
        c.block_link_writes, c.block_link_interval, c.block_link_freelist,
    });
    try w.print("gc-census: block_allocator_current {d} becomes_empty {d} trivial {d} trivial_std {d}\n", .{
        c.block_allocator_current, c.block_becomes_empty, c.block_trivial, c.block_trivial_std,
    });
    try w.print("gc-census: runs {d} run_entries {d} run_words {d} non_monotone {d} resumed_same_block {d}\n", .{
        c.runs, c.run_entries, c.run_words, c.runs_non_monotone, c.runs_resuming_same_block,
    });
    try w.print("gc-census: runs_all_trivial {d} entries_in_trivial_runs {d} words_in_trivial_runs {d}\n", .{
        c.runs_all_trivial, c.entries_in_trivial_runs, c.words_in_trivial_runs,
    });
    try w.print("gc-census: runs_all_trivial_std {d} entries_in_trivial_std_runs {d} words_in_trivial_std_runs {d} runs_mixed_fam {d}\n", .{
        c.runs_all_trivial_std, c.entries_in_trivial_std_runs, c.words_in_trivial_std_runs, c.runs_mixed_fam,
    });
    try w.print("gc-census: words_all_trivial {d} entries_in_trivial_words {d}\n", .{
        c.words_all_trivial, c.entries_in_trivial_words,
    });
    try w.print("gc-census: words_all_trivial_std {d} entries_in_trivial_std_words {d} words_mixed_fam {d}\n", .{
        c.words_all_trivial_std, c.entries_in_trivial_std_words, c.words_mixed_fam,
    });
    for (c.generic_class_hist, 0..) |n, i| {
        if (n == 0) continue;
        try w.print("gc-census: generic_class[{d}] {d}\n", .{ i, n });
    }
    for (c.run_len_hist, 0..) |n, i| {
        if (n == 0) continue;
        if (i < run_buckets.len) {
            try w.print("gc-census: run_len<={d} {d}\n", .{ run_buckets[i], n });
        } else {
            try w.print("gc-census: run_len>{d} {d}\n", .{ run_buckets[run_buckets.len - 1], n });
        }
    }
}

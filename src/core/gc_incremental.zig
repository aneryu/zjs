//! Incremental-major state and target-shading barrier (§8.4, §7.4).
//!
//! The barrier is incremental-update and shades the *exact new target* of a
//! strong write. That common target-shading arm deliberately reads no owner
//! colour and keeps no owner-rescan bit: a write through an unreachable owner
//! may preserve floating garbage for the cycle, which is the price of not
//! paying for owner state on every store. The two rare owner-requeue arms are
//! different: retracing is necessary only after the owner has already been
//! claimed black, so they verify that prior mark and skip a still-white owner.

const std = @import("std");
const gc = @import("gc.zig");
const registry_lists = @import("gc_registry_lists.zig");

pub const Stats = struct {
    barrier_calls: usize = 0,
    /// Incremental cycles completed, and the marking increments they took.
    cycles_completed: usize = 0,
    /// Total STW of the last completed cycle across all of its pauses.
    last_cycle_stw_ns: u64 = 0,
    /// Cumulative stop-the-world nanoseconds by attributed phase, over the whole
    /// run. The per-cycle total answers §1.3's row; this answers "which
    /// phase owns the stopped time", which is the question a decision about
    /// future parallel marking turns on.
    total_stw_by_kind: [4]u64 = @splat(0),
    max_cycle_stw_ns: u64 = 0,
    /// Same-domain §1.3 envelope. The raw tuple is the one completed cycle
    /// with the largest P/T; retaining one coherent tuple avoids the invalid
    /// alternative of independently maximizing S, T and P across cycles.
    envelope_measured_cycles: usize = 0,
    envelope_skipped_cycles: usize = 0,
    envelope_max_start_bytes: usize = 0,
    envelope_max_threshold_bytes: usize = 0,
    envelope_max_begin_bytes: usize = 0,
    envelope_max_peak_bytes: usize = 0,
    doomed_destroyed_objects: usize = 0,
};

pub fn ratioMillionthsCeil(numerator: usize, denominator: usize) usize {
    if (denominator == 0) return 0;
    const wide_numerator = @as(u128, numerator) * 1_000_000;
    const rounded = (wide_numerator + @as(u128, denominator) - 1) / denominator;
    return @intCast(@min(rounded, std.math.maxInt(usize)));
}

pub const State = struct {
    /// Running STW accumulator for the open cycle; drained into
    /// `stats.last_cycle_stw_ns` at completion.
    cycle_stw_ns: u64 = 0,
    /// Settled live estimate after the last major, in account bytes; the
    /// threshold for the next cycle is priced off it.
    last_settled_live_bytes: usize = 0,
    /// The next cycle consumes the S/T pair established by the preceding
    /// successful major's threshold reset. A manual threshold invalidates it.
    envelope_baseline_valid: bool = false,
    envelope_active: bool = false,
    envelope_next_start_bytes: usize = 0,
    envelope_next_threshold_bytes: usize = 0,
    envelope_cycle_start_bytes: usize = 0,
    envelope_cycle_threshold_bytes: usize = 0,
    envelope_cycle_begin_bytes: usize = 0,
    envelope_cycle_peak_bytes: usize = 0,
    stats: Stats = .{},
};

/// Mark epoch for non-block trace carriers. Epoch 0 is reserved for
/// newborn/unmarked; a major advances this scalar, while minors keep it fixed
/// so sticky survivor marks remain valid. Unlike a global parity flip, a stale
/// nonzero epoch cannot make a newborn (0) read marked.
pub const Marking = struct {
    header_epoch: u16 = 1,
};

pub const Morgue = struct {
    /// Split by kind at condemnation.
    ///
    /// Destruction has to run objects before realms before modules before
    /// bytecode before var_refs before shapes, and it used to get that order
    /// by walking ONE list once per kind: a corpse of the last kind was
    /// stepped over five times before its own pass reached it, and each of
    /// those steps was a list-node dereference and a budget counter tick.
    /// Bucketing at condemnation costs nothing extra -- that pass already
    /// visits every corpse -- and makes destruction visit each exactly once.
    /// Indexed by `@intFromEnum(kind)`.
    by_kind: [gc.gc_kind_count]registry_lists.IntrusiveHeaderList = @splat(.{}),
    /// Sliced-destruction cursor: which kind pass destruction is on. The
    /// lists are stable between slices -- the mutator cannot touch them -- so
    /// a plain cursor resumes exactly where the budget ran out.
    kind_pass: u8 = 0,
    /// Resume point within the current kind pass. Sound to hold across slices
    /// because nothing touches the list between them: collections are gated
    /// and the mutator has no path to a condemned object.
    cursor: ?*gc.Header = null,
    pending: bool = false,
    /// Objects destroyed by the slices of the current morgue, for the
    /// completion poll's CollectionResult.
    destroyed: usize = 0,
    /// Condemned body bytes still charged at the finish boundary. Bitmap-only
    /// cells are debited there already and must not be included again, even
    /// though their physical storage remains pending reclamation.
    /// The growth threshold subtracts this at finish -- pricing the next
    /// cycle off a heap full of corpses was a compounding feedback loop
    /// (measured: an 841 MB peak on a ~50 MB live set).
    bytes: usize = 0,

    /// Finite budget for advancing destruction beyond requested-byte pacing.
    /// Seeded by still-charged condemned bodies, then reconciled with actual
    /// destructor-owned account release. Total issued credit is the larger
    /// of those two quantities, never their sum; each slice spends it once.
    assist_credit_bytes: usize = 0,
    assist_unreconciled_bytes: usize = 0,

    pub fn startAssistCredit(self: *Morgue, estimated_bytes: usize) void {
        self.assist_credit_bytes = estimated_bytes;
        self.assist_unreconciled_bytes = estimated_bytes;
    }

    pub fn recordAssistReclaim(self: *Morgue, before: usize, after: usize) void {
        const reclaimed = before -| after;
        const precredited = @min(reclaimed, self.assist_unreconciled_bytes);
        self.assist_unreconciled_bytes -= precredited;
        // Native payload/backing allocations are not condemned carriers.
        // Their release becomes known here without an extra heap walk.
        self.assist_credit_bytes +|= reclaimed - precredited;
    }

    pub fn consumeAssistDebt(self: *Morgue, requested_bytes: *usize) void {
        const paid = @min(requested_bytes.*, gc.incremental_assist_interval_bytes);
        self.assist_credit_bytes -|= gc.incremental_assist_interval_bytes - paid;
        requested_bytes.* -|= gc.incremental_assist_interval_bytes;
    }

    pub fn clearAssistCredit(self: *Morgue) void {
        self.assist_credit_bytes = 0;
        self.assist_unreconciled_bytes = 0;
    }

    /// Bind the per-kind cyclic sentinels. Must run before any condemnation,
    /// and is idempotent.
    pub fn init(self: *Morgue) void {
        for (&self.by_kind) |*head| head.init();
    }
};

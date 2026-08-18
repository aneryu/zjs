//! Exact block-CFG liveness for the compiler-v2 temporary stream.
//!
//! Bound LabelIds partition the compact byte stream into basic blocks. The
//! production graph stores only block starts, one metadata row per block, a
//! flat CSR edge array, and a packed reachability bitset. Debug and
//! ReleaseSafe additionally run an instruction-granularity oracle to prove
//! that the block/cutoff classification is identical to byte-exact legacy
//! reachability.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core/root.zig");
const bytecode = @import("../bytecode.zig");
const builder = @import("builder.zig");
const labels = @import("labels.zig");

const opcode = bytecode.opcode;
const op = opcode.op;

/// Identity oracles are Debug/ReleaseSafe only; ReleaseFast never references
/// any of this code.
pub const audit_oracles = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

pub const Error = error{
    OutOfMemory,
    InvalidBytecode,
};

/// Sorted bind-index row shared with resolve_variables. `dead_skipped` is
/// resolver bookkeeping; graph construction reads only the identity and the
/// immutable input offset.
pub const BindEntry = struct {
    input_offset: u32,
    label_index: u32,
    dead_skipped: bool = false,
};

pub const OptimizationBoundaryKind = enum {
    make_ref_head,
    make_ref_tail,
    dup_branch_fold,
    insert_tail_fold,
    gosub_empty,
};

/// The ruling's six diff buckets. Every oracle violation is classified into
/// exactly one of these, and every failure message names its bucket before
/// any coordinate. Offsets are the pre-v2 identity and must never be the
/// primary classification key.
pub const DiffBucket = enum {
    boundary_mismatch,
    ownership_mismatch,
    binding_mismatch,
    cfg_mismatch,
    continuation_mismatch,
    source_event_mismatch,

    pub fn name(self: DiffBucket) []const u8 {
        return switch (self) {
            .boundary_mismatch => "BOUNDARY_MISMATCH",
            .ownership_mismatch => "OWNERSHIP_MISMATCH",
            .binding_mismatch => "BINDING_MISMATCH",
            .cfg_mismatch => "CFG_MISMATCH",
            .continuation_mismatch => "CONTINUATION_MISMATCH",
            .source_event_mismatch => "SOURCE_EVENT_MISMATCH",
        };
    }
};

/// Corpus-level oracle report accumulator. Scratch-only: the payload type is
/// comptime-erased to an empty struct in ReleaseFast, so neither the storage
/// nor any of the counting code exists in a release build.
pub const OracleReport = if (audit_oracles) struct {
    // boundary set: every legacy-notion boundary claim resolved against the
    // v2 identity that owns it.
    legacy_boundaries: u64 = 0,
    v2_boundaries: u64 = 0,
    missing_boundaries: u64 = 0,
    extra_boundaries: u64 = 0,
    duplicated_boundaries: u64 = 0,
    // per-category legacy claim totals (the ruling's four boundary
    // categories), reported as provenance for `legacy_boundaries`.
    instruction_claims: u64 = 0,
    control_flow_claims: u64 = 0,
    optimization_claims: u64 = 0,
    debug_claims: u64 = 0,
    // atom-owner ownership events.
    ownership_create: u64 = 0,
    ownership_transfer: u64 = 0,
    ownership_release: u64 = 0,
    ownership_unbalanced: u64 = 0,
    // control totals.
    control_blocks: u64 = 0,
    control_edges: u64 = 0,
    control_continuations: u64 = 0,
    // diff buckets, indexed by @intFromEnum(DiffBucket).
    buckets: [6]u64 = .{0} ** 6,
} else struct {};

pub var oracle_report: OracleReport = .{};

comptime {
    // The ruling requires the counters to not exist in ReleaseFast. This is
    // the standing compile-time proof: the accumulator carries no storage
    // there, so no counting code can be emitted against it either.
    if (!audit_oracles) std.debug.assert(@sizeOf(OracleReport) == 0);
}

/// One resolver-recorded peephole span in INPUT (temporary-stream) coordinates.
/// `replacement_start` is the single offset that owns the emitted replacement;
/// `fold_start .. consumed_end` is the consumed range.
pub const OptimizationBoundary = struct {
    kind: OptimizationBoundaryKind,
    fold_start: u32,
    consumed_end: u32,
    replacement_start: u32,
    /// PRODUCT offset the replacement was written at, captured by the resolver
    /// at the instant of the replacing emission. `labels.unbound` while a fold
    /// is planned but not yet emitted (make_ref_tail between registration and
    /// `emitPendingTailRewrite`). Audit-only: the anchor-split classifier
    /// compares it against the product offset of the label bound at
    /// `replacement_start` to decide class A vs class D.
    replacement_product: u32 = labels.unbound,
};

pub const identity_kinds = [_][]const u8{
    "label",
    "boundary",
    "block",
    "source_event",
    "fold_region",
};

pub const FanoutCensus = struct {
    /// distinct semantic boundaries seen (one per bound input offset)
    semantic_boundaries: u64 = 0,
    /// total label identities bound at those boundaries
    identities: u64 = 0,
    /// boundaries carrying more than one identity
    coalesced_boundaries: u64 = 0,
    /// largest number of identities observed at one semantic boundary
    max_fanout: u64 = 0,
    /// source events sitting on a bound offset but carrying no identity anchor
    unanchored_source_events: u64 = 0,
    /// fold replacement starts carrying no identity anchor
    unanchored_fold_replacements: u64 = 0,
    /// ... of which also claimed by at least one label identity
    contested_fold_replacements: u64 = 0,
    // bytecode.SourceLocSlot / builder.SourceSlot carry no anchor_label, and
    // resolve_labels.relaxJumps shifts source.pc and addr[..] as independent
    // arrays. The minimal fix is an `anchor_label: u32 = labels.unbound` on
    // builder.SourceSlot, set by Builder.addSourceMarker when a label binds at
    // the same code_len, propagated by resolve_variables through
    // attachPendingSourcesAssumeCapacity, then used by relaxJumps to shift an
    // anchored source event from addr[anchor_label] instead of independent pc
    // arithmetic. That API-frozen shell change is intentionally not made here.
    final_source_events: u64 = 0,
    source_events_on_identity: u64 = 0,
    source_events_between_identities: u64 = 0,
    /// Fan-out histogram: identities per semantic boundary. Bucket i counts
    /// boundaries with fan-out i+1; the last bucket is saturating ">= 8".
    fanout_buckets: [8]u64 = .{0} ** 8,
    /// Chain-depth histogram: identity hops per label-operand reference (see
    /// `referenceChainDepth`). Bucket i counts depth i; last bucket saturates.
    /// This population is label references in INPUT coordinates only; the S4
    /// `boundary -> final address` edge is counted separately below so the two
    /// populations never dilute one another's mean.
    chain_depth_buckets: [8]u64 = .{0} ** 8,
    chain_depth_samples: u64 = 0,
    chain_depth_total: u64 = 0,
    max_chain_depth: u64 = 0,
    /// resolve_labels_v2 adds exactly one hop per live product-coordinate
    /// alias group: boundary -> final address. A reference's end-to-end chain
    /// is therefore `chain_depth + 1`, uniformly.
    final_address_hops: u64 = 0,
};

pub var boundary_fanout_census: FanoutCensus = .{};

pub fn fanoutCensusSnapshot() FanoutCensus {
    var census: FanoutCensus = .{
        .semantic_boundaries = @atomicLoad(
            u64,
            &boundary_fanout_census.semantic_boundaries,
            .monotonic,
        ),
        .identities = @atomicLoad(u64, &boundary_fanout_census.identities, .monotonic),
        .coalesced_boundaries = @atomicLoad(
            u64,
            &boundary_fanout_census.coalesced_boundaries,
            .monotonic,
        ),
        .max_fanout = @atomicLoad(u64, &boundary_fanout_census.max_fanout, .monotonic),
        .unanchored_source_events = @atomicLoad(
            u64,
            &boundary_fanout_census.unanchored_source_events,
            .monotonic,
        ),
        .unanchored_fold_replacements = @atomicLoad(
            u64,
            &boundary_fanout_census.unanchored_fold_replacements,
            .monotonic,
        ),
        .contested_fold_replacements = @atomicLoad(
            u64,
            &boundary_fanout_census.contested_fold_replacements,
            .monotonic,
        ),
        .final_source_events = @atomicLoad(
            u64,
            &boundary_fanout_census.final_source_events,
            .monotonic,
        ),
        .source_events_on_identity = @atomicLoad(
            u64,
            &boundary_fanout_census.source_events_on_identity,
            .monotonic,
        ),
        .source_events_between_identities = @atomicLoad(
            u64,
            &boundary_fanout_census.source_events_between_identities,
            .monotonic,
        ),
        .chain_depth_samples = @atomicLoad(
            u64,
            &boundary_fanout_census.chain_depth_samples,
            .monotonic,
        ),
        .chain_depth_total = @atomicLoad(
            u64,
            &boundary_fanout_census.chain_depth_total,
            .monotonic,
        ),
        .max_chain_depth = @atomicLoad(
            u64,
            &boundary_fanout_census.max_chain_depth,
            .monotonic,
        ),
        .final_address_hops = @atomicLoad(
            u64,
            &boundary_fanout_census.final_address_hops,
            .monotonic,
        ),
    };
    for (&census.fanout_buckets, 0..) |*bucket, index| {
        bucket.* = @atomicLoad(
            u64,
            &boundary_fanout_census.fanout_buckets[index],
            .monotonic,
        );
    }
    for (&census.chain_depth_buckets, 0..) |*bucket, index| {
        bucket.* = @atomicLoad(
            u64,
            &boundary_fanout_census.chain_depth_buckets[index],
            .monotonic,
        );
    }
    return census;
}

pub fn resetFanoutCensus() void {
    @atomicStore(u64, &boundary_fanout_census.semantic_boundaries, 0, .monotonic);
    @atomicStore(u64, &boundary_fanout_census.identities, 0, .monotonic);
    @atomicStore(u64, &boundary_fanout_census.coalesced_boundaries, 0, .monotonic);
    @atomicStore(u64, &boundary_fanout_census.max_fanout, 0, .monotonic);
    @atomicStore(u64, &boundary_fanout_census.unanchored_source_events, 0, .monotonic);
    @atomicStore(u64, &boundary_fanout_census.unanchored_fold_replacements, 0, .monotonic);
    @atomicStore(u64, &boundary_fanout_census.contested_fold_replacements, 0, .monotonic);
    @atomicStore(u64, &boundary_fanout_census.final_source_events, 0, .monotonic);
    @atomicStore(u64, &boundary_fanout_census.source_events_on_identity, 0, .monotonic);
    @atomicStore(u64, &boundary_fanout_census.source_events_between_identities, 0, .monotonic);
    for (&boundary_fanout_census.fanout_buckets) |*bucket| {
        @atomicStore(u64, bucket, 0, .monotonic);
    }
    for (&boundary_fanout_census.chain_depth_buckets) |*bucket| {
        @atomicStore(u64, bucket, 0, .monotonic);
    }
    @atomicStore(u64, &boundary_fanout_census.chain_depth_samples, 0, .monotonic);
    @atomicStore(u64, &boundary_fanout_census.chain_depth_total, 0, .monotonic);
    @atomicStore(u64, &boundary_fanout_census.max_chain_depth, 0, .monotonic);
    @atomicStore(u64, &boundary_fanout_census.final_address_hops, 0, .monotonic);
}

/// F3 (anchor-split classification, 2026 campaign report in git history).
///
/// The uniqueness oracle counted the anchoring exposure; it did not say what
/// kind of exposure each contested position is. The ruling's partition:
///   A  one semantic boundary owned by several identities  -> MUST MERGE
///   B  one PC carrying several DISTINCT semantic events   -> allowed
///   C  a source/debug anchor as an independent identity   -> allowed
///   D  the optimization replacement anchor, independent   -> needs a rule
///
/// The class is decided by WHAT COMPETES for the position (a debug marker, a
/// fold replacement, or another control-flow event) plus one falsifiable test
/// applied to every case: do the competing owners of one INPUT position
/// resolve to the same PRODUCT position? A pair that resolves apart is a real
/// split (class A) whatever kind the competitor is; only agreement leaves the
/// case in the allowed classes.
pub const AnchorClass = enum(u8) {
    a,
    b,
    c,
    d,

    pub fn name(self: AnchorClass) []const u8 {
        return switch (self) {
            .a => "A",
            .b => "B",
            .c => "C",
            .d => "D",
        };
    }
};

pub const AnchorCase = enum(u8) {
    /// A: a source event and a label bind at one input offset that resolve to
    /// DIFFERENT product offsets.
    a_source_product_split,
    /// A: a fold replacement and a label bind at one input offset that resolve
    /// to DIFFERENT product offsets.
    a_fold_product_split,
    /// B: one boundary whose label group is referenced under more than one
    /// role (jump target / exception landing / cleanup subroutine / aux).
    b_multi_role_boundary,
    /// B: a boundary that is also the end of a consumed fold region.
    b_boundary_is_fold_region_end,
    /// B: a retained match barrier sharing its PC with a referenced identity.
    b_barrier_with_reference,
    /// B: the ruling's literal example - one PC carrying a line marker, a
    /// label target and a fold replacement at once.
    b_triple_owner_pc,
    /// C: source event and label bind co-resident, same product offset.
    c_source_coresident,
    /// C: the source event survives at a boundary whose whole label group was
    /// retired - the debug anchor OUTLIVES every identity there.
    c_source_outlives_identity,
    /// C: the label survives but the source event was dropped (a trailing
    /// event with no emitted instruction left to carry it).
    c_identity_outlives_source,
    /// C: neither owner survives - the dead boundary retired its labels and
    /// its source events together.
    c_boundary_fully_retired,
    /// D: fold replacement start with no label identity at that offset.
    d_fold_uncontested,
    /// D: fold replacement start contested by a label identity that resolves
    /// to the same product offset.
    d_fold_contested_agree,

    pub fn class(self: AnchorCase) AnchorClass {
        return switch (self) {
            .a_source_product_split, .a_fold_product_split => .a,
            .b_multi_role_boundary,
            .b_boundary_is_fold_region_end,
            .b_barrier_with_reference,
            .b_triple_owner_pc,
            => .b,
            .c_source_coresident,
            .c_source_outlives_identity,
            .c_identity_outlives_source,
            .c_boundary_fully_retired,
            => .c,
            .d_fold_uncontested, .d_fold_contested_agree => .d,
        };
    }

    pub fn name(self: AnchorCase) []const u8 {
        return @tagName(self);
    }
};

pub const anchor_case_count = @typeInfo(AnchorCase).@"enum".fields.len;

/// Corpus accumulator for the classification. Comptime-erased in ReleaseFast
/// exactly like `OracleReport`.
pub const AnchorSplitCensus = if (audit_oracles) struct {
    cases: [anchor_case_count]u64 = .{0} ** anchor_case_count,
    /// fold replacement anchors by OptimizationBoundaryKind
    fold_by_kind: [5]u64 = .{0} ** 5,
    /// ... of which contested by a label identity
    fold_contested_by_kind: [5]u64 = .{0} ** 5,
    /// fold replacements whose product offset was still unrecorded when the
    /// classifier ran (should be zero: every plan is consumed before return)
    fold_product_unknown: u64 = 0,
    /// input source events whose product slot disagreed on line/col - the
    /// falsifiable proof that product source slot i is input source slot i
    source_index_alignment_violations: u64 = 0,
    /// relaxJumps stability, .short layout only
    relax_compactions: u64 = 0,
    relax_window_sources: u64 = 0,
    relax_window_labels: u64 = 0,
    relax_coincidence_before: u64 = 0,
    relax_coincidence_after: u64 = 0,
    relax_coincidence_lost: u64 = 0,
    relax_coincidence_gained: u64 = 0,
} else struct {};

pub var anchor_split_census: AnchorSplitCensus = .{};

comptime {
    if (!audit_oracles) std.debug.assert(@sizeOf(AnchorSplitCensus) == 0);
}

/// One classified position, kept for the corpus report. Exemplars are the
/// ruling's requirement that the classification cite REAL CONSTRUCTS, not just
/// counts: `line`/`col` locate the construct in the compiled source and
/// `label_product` / `other_product` name the competing owners' resolutions.
pub const AnchorExemplar = struct {
    case: AnchorCase,
    /// `@intFromEnum(OptimizationBoundaryKind)` or 0xff when not a fold case
    fold_kind: u8 = 0xff,
    /// opcode at `input_offset` (0xff at the end-of-code boundary)
    op_id: u8 = 0xff,
    /// label identities bound at `input_offset`
    fanout: u32 = 0,
    /// union of BoundaryRole bits observed at references to this boundary
    role_mask: u8 = 0,
    input_offset: u32 = 0,
    label_index: u32 = labels.unbound,
    label_product: u32 = labels.unbound,
    other_product: u32 = labels.unbound,
    line: i32 = 0,
    col: i32 = 0,
};

pub const anchor_exemplar_capacity: usize = 128;
/// Distinct (line, col) sites retained per case.
pub const anchor_exemplars_per_case: u32 = 6;

pub var anchor_exemplars: [anchor_exemplar_capacity]AnchorExemplar = undefined;
pub var anchor_exemplar_len: u32 = 0;

fn anchorAdd(counter: *u64, amount: u64) void {
    if (comptime !audit_oracles) return;
    censusAdd(counter, amount);
}

fn recordAnchorCase(case: AnchorCase) void {
    if (comptime !audit_oracles) return;
    censusAdd(&anchor_split_census.cases[@intFromEnum(case)], 1);
}

/// Retain up to `anchor_exemplars_per_case` DISTINCT source sites per
/// (case, fold kind) - keyed on the fold kind too so one prolific kind cannot
/// crowd the others out of the report. Audit-only and single-threaded by
/// construction (one compile at a time on the compiling thread); no ordering
/// guarantee is needed or offered.
fn recordAnchorExemplar(exemplar: AnchorExemplar) void {
    if (comptime !audit_oracles) return;
    var seen: u32 = 0;
    for (anchor_exemplars[0..anchor_exemplar_len]) |existing| {
        if (existing.case != exemplar.case or existing.fold_kind != exemplar.fold_kind) continue;
        if (existing.line == exemplar.line and existing.col == exemplar.col) return;
        seen += 1;
    }
    if (seen >= anchor_exemplars_per_case) return;
    if (anchor_exemplar_len >= anchor_exemplar_capacity) return;
    anchor_exemplars[anchor_exemplar_len] = exemplar;
    anchor_exemplar_len += 1;
}

pub fn resetAnchorSplitCensus() void {
    if (comptime !audit_oracles) return;
    for (&anchor_split_census.cases) |*counter| @atomicStore(u64, counter, 0, .monotonic);
    for (&anchor_split_census.fold_by_kind) |*counter| @atomicStore(u64, counter, 0, .monotonic);
    for (&anchor_split_census.fold_contested_by_kind) |*counter|
        @atomicStore(u64, counter, 0, .monotonic);
    @atomicStore(u64, &anchor_split_census.fold_product_unknown, 0, .monotonic);
    @atomicStore(u64, &anchor_split_census.source_index_alignment_violations, 0, .monotonic);
    @atomicStore(u64, &anchor_split_census.relax_compactions, 0, .monotonic);
    @atomicStore(u64, &anchor_split_census.relax_window_sources, 0, .monotonic);
    @atomicStore(u64, &anchor_split_census.relax_window_labels, 0, .monotonic);
    @atomicStore(u64, &anchor_split_census.relax_coincidence_before, 0, .monotonic);
    @atomicStore(u64, &anchor_split_census.relax_coincidence_after, 0, .monotonic);
    @atomicStore(u64, &anchor_split_census.relax_coincidence_lost, 0, .monotonic);
    @atomicStore(u64, &anchor_split_census.relax_coincidence_gained, 0, .monotonic);
    anchor_exemplar_len = 0;
}

pub fn anchorSplitSnapshot() AnchorSplitCensus {
    if (comptime !audit_oracles) return .{};
    var census: AnchorSplitCensus = .{
        .fold_product_unknown = @atomicLoad(
            u64,
            &anchor_split_census.fold_product_unknown,
            .monotonic,
        ),
        .source_index_alignment_violations = @atomicLoad(
            u64,
            &anchor_split_census.source_index_alignment_violations,
            .monotonic,
        ),
        .relax_compactions = @atomicLoad(u64, &anchor_split_census.relax_compactions, .monotonic),
        .relax_window_sources = @atomicLoad(
            u64,
            &anchor_split_census.relax_window_sources,
            .monotonic,
        ),
        .relax_window_labels = @atomicLoad(
            u64,
            &anchor_split_census.relax_window_labels,
            .monotonic,
        ),
        .relax_coincidence_before = @atomicLoad(
            u64,
            &anchor_split_census.relax_coincidence_before,
            .monotonic,
        ),
        .relax_coincidence_after = @atomicLoad(
            u64,
            &anchor_split_census.relax_coincidence_after,
            .monotonic,
        ),
        .relax_coincidence_lost = @atomicLoad(
            u64,
            &anchor_split_census.relax_coincidence_lost,
            .monotonic,
        ),
        .relax_coincidence_gained = @atomicLoad(
            u64,
            &anchor_split_census.relax_coincidence_gained,
            .monotonic,
        ),
    };
    for (&census.cases, 0..) |*counter, index| {
        counter.* = @atomicLoad(u64, &anchor_split_census.cases[index], .monotonic);
    }
    for (&census.fold_by_kind, 0..) |*counter, index| {
        counter.* = @atomicLoad(u64, &anchor_split_census.fold_by_kind[index], .monotonic);
    }
    for (&census.fold_contested_by_kind, 0..) |*counter, index| {
        counter.* = @atomicLoad(u64, &anchor_split_census.fold_contested_by_kind[index], .monotonic);
    }
    return census;
}

pub fn anchorClassTotal(census: AnchorSplitCensus, class: AnchorClass) u64 {
    if (comptime !audit_oracles) return 0;
    var total: u64 = 0;
    inline for (@typeInfo(AnchorCase).@"enum".fields) |field| {
        const case: AnchorCase = @enumFromInt(field.value);
        if (case.class() == class) total += census.cases[field.value];
    }
    return total;
}

/// `ZJS-V2-ANCHOR-SPLIT A=<n> B=<n> C=<n> D=<n> cases{...} folds{...}
/// relax{...} integrity{...}` - one line, class A first because it is the only
/// class that changes the model.
pub fn formatAnchorSplit(buffer: []u8, census: AnchorSplitCensus) []const u8 {
    if (comptime !audit_oracles) {
        return "ZJS-V2-ANCHOR-SPLIT unavailable: counters are comptime-erased in this build";
    }
    var writer = std.Io.Writer.fixed(buffer);
    writer.print("ZJS-V2-ANCHOR-SPLIT A={d} B={d} C={d} D={d} cases{{", .{
        anchorClassTotal(census, .a),
        anchorClassTotal(census, .b),
        anchorClassTotal(census, .c),
        anchorClassTotal(census, .d),
    }) catch unreachable;
    inline for (@typeInfo(AnchorCase).@"enum".fields, 0..) |field, index| {
        const case: AnchorCase = @enumFromInt(field.value);
        writer.print("{s}{s}={d}", .{
            if (index == 0) "" else " ",
            case.name(),
            census.cases[field.value],
        }) catch unreachable;
    }
    writer.print("}} folds{{", .{}) catch unreachable;
    inline for (@typeInfo(OptimizationBoundaryKind).@"enum".fields, 0..) |field, index| {
        writer.print("{s}{s}={d}/{d}", .{
            if (index == 0) "" else " ",
            field.name,
            census.fold_contested_by_kind[field.value],
            census.fold_by_kind[field.value],
        }) catch unreachable;
    }
    writer.print(
        "}} relax{{compactions={d} window-sources={d} window-labels={d} coincident={d}->{d} lost={d} gained={d}}} integrity{{fold-product-unknown={d} source-index-violations={d}}}",
        .{
            census.relax_compactions,
            census.relax_window_sources,
            census.relax_window_labels,
            census.relax_coincidence_before,
            census.relax_coincidence_after,
            census.relax_coincidence_lost,
            census.relax_coincidence_gained,
            census.fold_product_unknown,
            census.source_index_alignment_violations,
        },
    ) catch unreachable;
    return writer.buffered();
}

/// One exemplar row: `<class> <case> line=<n> col=<n> op=<name> off=<n>
/// fanout=<n> roles=0x<n> owners{label#<n>@<product>, <other>@<product>}`.
pub fn formatAnchorExemplar(buffer: []u8, exemplar: AnchorExemplar) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    const op_name = if (exemplar.op_id == 0xff)
        "<end-of-code>"
    else
        opcode.nameOfPhase1(exemplar.op_id);
    const other_kind: []const u8 = switch (exemplar.case) {
        .a_fold_product_split, .d_fold_uncontested, .d_fold_contested_agree => "fold_replacement",
        .b_boundary_is_fold_region_end => "fold_region_end",
        .b_multi_role_boundary, .b_barrier_with_reference => "label_group",
        else => "source_event",
    };
    writer.print(
        "ZJS-V2-ANCHOR-EXEMPLAR class={s} case={s} line={d} col={d} op={s} off={d} fanout={d} roles=0x{x:0>2} fold={s} owners{{label#{d}@{d}, {s}@{d}}}",
        .{
            exemplar.case.class().name(),
            exemplar.case.name(),
            exemplar.line,
            exemplar.col,
            op_name,
            exemplar.input_offset,
            exemplar.fanout,
            exemplar.role_mask,
            if (exemplar.fold_kind == 0xff)
                "none"
            else
                @tagName(@as(OptimizationBoundaryKind, @enumFromInt(exemplar.fold_kind))),
            exemplar.label_index,
            exemplar.label_product,
            other_kind,
            exemplar.other_product,
        },
    ) catch unreachable;
    return writer.buffered();
}

/// relaxJumps instrumentation sink (`.short` layout only). `window_sources` /
/// `window_labels` count events that sat STRICTLY INSIDE a compacted jump's
/// removed bytes: the only way the two independently shifted arrays can end up
/// disagreeing, since both use the same `> jump.pos` predicate and delta.
pub fn recordRelaxCompaction(window_sources: u64, window_labels: u64) void {
    if (comptime !audit_oracles) return;
    censusAdd(&anchor_split_census.relax_compactions, 1);
    censusAdd(&anchor_split_census.relax_window_sources, window_sources);
    censusAdd(&anchor_split_census.relax_window_labels, window_labels);
}

pub fn recordRelaxCoincidence(before: u64, after: u64, lost: u64, gained: u64) void {
    if (comptime !audit_oracles) return;
    censusAdd(&anchor_split_census.relax_coincidence_before, before);
    censusAdd(&anchor_split_census.relax_coincidence_after, after);
    censusAdd(&anchor_split_census.relax_coincidence_lost, lost);
    censusAdd(&anchor_split_census.relax_coincidence_gained, gained);
}

pub fn bindLessThan(_: void, lhs: BindEntry, rhs: BindEntry) bool {
    if (lhs.input_offset != rhs.input_offset) return lhs.input_offset < rhs.input_offset;
    return lhs.label_index < rhs.label_index;
}

fn lowerBoundBindOffset(binds: []const BindEntry, input_offset: u32) usize {
    var lo: usize = 0;
    var hi = binds.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (binds[mid].input_offset < input_offset)
            lo = mid + 1
        else
            hi = mid;
    }
    return lo;
}

fn upperBoundBindOffset(binds: []const BindEntry, input_offset: u32) usize {
    var lo: usize = 0;
    var hi = binds.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (binds[mid].input_offset <= input_offset)
            lo = mid + 1
        else
            hi = mid;
    }
    return lo;
}

/// The canonical identity of one semantic boundary: the alias-group
/// representative, i.e. the LOWEST label index bound at the same input offset.
/// `binds` is sorted by (input_offset, label_index), so the representative is
/// the first entry of the offset's contiguous run.
///
/// RULING: `LabelId A != LabelId B` is acceptable when
/// `canonicalBoundaryIdentity(A) == canonicalBoundaryIdentity(B)` (same-
/// subsystem alias coalescing). What must fail is one semantic boundary whose
/// subsystems disagree on the CANONICAL identity — same final address is not a
/// defence, so no comparison in this file may use an address.
///
/// O(binds): the primary sort key is input_offset, so the label's own row can
/// only be found by scanning. Callers that already hold the label slot (every
/// audit walk does) must use `canonicalIdentityAtOffset(binds,
/// slot.bound_offset)` instead — `validateBindIndex` proves the two agree, and
/// the bisection keeps per-reference work logarithmic.
pub fn canonicalBoundaryIdentity(binds: []const BindEntry, label_index: u32) ?u32 {
    // The primary sort key is input_offset, not label_index, so first locate
    // the label's row; the representative lookup itself is the offset bisection
    // shared with canonicalIdentityAtOffset.
    const input_offset = for (binds) |entry| {
        if (entry.label_index == label_index) break entry.input_offset;
    } else return null;
    return canonicalIdentityAtOffset(binds, input_offset);
}

pub fn canonicalIdentityAtOffset(binds: []const BindEntry, input_offset: u32) ?u32 {
    const first = lowerBoundBindOffset(binds, input_offset);
    if (first >= binds.len or binds[first].input_offset != input_offset) return null;
    return binds[first].label_index;
}

pub const TempInstruction = packed struct(u16) {
    size: u8,
    is_temp: bool = false,
    has_atom: bool = false,
    reserved: u6 = 0,
};

fn tempAtomInstructionSize(op_id: u8) ?u8 {
    return switch (op_id) {
        op.scope_get_var_undef,
        op.scope_get_var,
        op.scope_put_var,
        op.scope_delete_var,
        op.scope_get_ref,
        op.scope_put_var_init,
        op.scope_get_var_checkthis,
        op.scope_get_private_field,
        op.scope_get_private_field2,
        op.scope_put_private_field,
        op.scope_in_private_field,
        => 7,
        op.scope_make_ref => 11,
        op.get_field_opt_chain => 5,
        else => null,
    };
}

fn formatHasAtom(format: opcode.Format) bool {
    return switch (format) {
        .atom, .atom_u8, .atom_u16, .atom_label_u8, .atom_label_u16 => true,
        else => false,
    };
}

const TempDecodeKind = enum(u2) {
    final,
    forced_temp,
    atom_candidate,
    invalid,
};

/// Compact QuickJS-style opcode metadata for the mixed Builder stream.  The
/// overlap range needs one extra state beyond QuickJS's phase-1 table because
/// v2 can already contain selected final short opcodes there; an atom-ledger
/// match disambiguates those ids from the temporary scope family.
const TempDecodeInfo = packed struct(u32) {
    fallback_size: u8,
    temp_size: u8,
    fallback_has_atom: bool,
    temp_has_atom: bool,
    kind: TempDecodeKind,
    reserved: u12 = 0,
};

const temp_decode_info: [256]TempDecodeInfo = blk: {
    @setEvalBranchQuota(10_000);
    var table: [256]TempDecodeInfo = undefined;
    for (&table, 0..) |*row, index| {
        const op_id: u8 = @intCast(index);
        row.* = .{
            .fallback_size = opcode.sizeOf(op_id),
            .temp_size = 0,
            .fallback_has_atom = formatHasAtom(opcode.formatOf(op_id)),
            .temp_has_atom = false,
            .kind = .final,
        };
        if (tempAtomInstructionSize(op_id)) |temp_size| {
            row.temp_size = temp_size;
            row.temp_has_atom = true;
            row.kind = .atom_candidate;
        } else switch (op_id) {
            // Labels and source positions are side-table entities in v2.
            op.label, op.line_num => row.kind = .invalid,
            op.enter_scope,
            op.leave_scope,
            op.get_array_el_opt_chain,
            op.set_class_name,
            => {
                row.temp_size = opcode.sizeOfPhase1(op_id);
                row.kind = .forced_temp;
            },
            else => {},
        }
    }
    break :blk table;
};

/// Production compiler-v2 consumes a parser phase-1 Builder, not an arbitrary
/// final bytecode stream.  QuickJS relies on the same phase boundary: ids in
/// the temporary-opcode range name temporary instructions until
/// `resolve_variables` removes them, and short opcodes are introduced only by
/// `resolve_labels`.  Keeping that invariant explicit avoids treating every
/// scope opcode as a possible final short opcode and then rereading its atom
/// operand to disambiguate it.
const Phase1DecodeInfo = packed struct(u16) {
    size: u8,
    has_atom: bool,
    is_temp: bool,
    reserved: u6 = 0,
};

const phase1_decode_info: [256]Phase1DecodeInfo = blk: {
    @setEvalBranchQuota(10_000);
    var table: [256]Phase1DecodeInfo = undefined;
    for (&table, 0..) |*row, index| {
        const op_id: u8 = @intCast(index);
        const final_size = opcode.sizeOf(op_id);
        row.* = .{
            .size = final_size,
            .has_atom = formatHasAtom(opcode.formatOf(op_id)),
            .is_temp = false,
        };
        if (op_id >= op.op_temp_start and op_id < op.op_temp_end) {
            row.* = switch (op_id) {
                // Labels and source positions are side-table entities in v2.
                op.label, op.line_num => .{
                    .size = 0,
                    .has_atom = false,
                    .is_temp = true,
                },
                else => .{
                    .size = opcode.sizeOfPhase1(op_id),
                    .has_atom = formatHasAtom(opcode.formatOfPhase1(op_id)),
                    .is_temp = true,
                },
            };
        }
    }
    break :blk table;
};

fn instructionHasAtom(op_id: u8, is_temp: bool) bool {
    const info = temp_decode_info[op_id];
    return if (is_temp) info.temp_has_atom else info.fallback_has_atom;
}

/// Shared phase-aware decoder for the compact v2 temporary stream. The atom
/// ledger disambiguates temporary atom opcodes from overlapping final short
/// opcodes.
pub fn tempInstruction(
    code: []const u8,
    atoms_ledger: []const core.atom.Atom,
    pc: u32,
    atom_index: u32,
) Error!TempInstruction {
    const pc_index: usize = @intCast(pc);
    if (pc_index >= code.len) return error.InvalidBytecode;
    const op_id = code[pc_index];
    const info = temp_decode_info[op_id];

    if (info.kind == .atom_candidate) {
        const end = std.math.add(usize, pc_index, info.temp_size) catch
            return error.InvalidBytecode;
        if (end <= code.len and atom_index < atoms_ledger.len) {
            const operand = std.mem.readInt(u32, code[pc_index + 1 ..][0..4], .little);
            if (operand == atoms_ledger[atom_index]) {
                return .{
                    .size = info.temp_size,
                    .is_temp = true,
                    .has_atom = info.temp_has_atom,
                };
            }
        }
    }

    const instruction: TempInstruction = switch (info.kind) {
        .invalid => return error.InvalidBytecode,
        .forced_temp => .{
            .size = info.temp_size,
            .is_temp = true,
            .has_atom = info.temp_has_atom,
        },
        .final, .atom_candidate => .{
            .size = info.fallback_size,
            .has_atom = info.fallback_has_atom,
        },
    };
    if (instruction.size == 0) return error.InvalidBytecode;
    const end = std.math.add(usize, pc_index, instruction.size) catch
        return error.InvalidBytecode;
    if (end > code.len) return error.InvalidBytecode;
    return instruction;
}

/// Decode and validate one instruction from the parser-owned phase-1 Builder.
/// Unlike `tempInstruction`, this entry does not accept overlapping final
/// short opcodes in the temporary id range.  The atom comparison both proves
/// that the phase-1 interpretation is valid and authorizes the resolver to
/// consume the matching ledger entry without checking the same operand again.
pub inline fn phase1Instruction(
    code: []const u8,
    atoms_ledger: []const core.atom.Atom,
    pc: u32,
    atom_index: u32,
) Error!TempInstruction {
    const pc_index: usize = @intCast(pc);
    if (pc_index >= code.len) return error.InvalidBytecode;
    const info = phase1_decode_info[code[pc_index]];
    // A zero width is the invalid-opcode sentinel.  `valid` used to encode
    // exactly the same predicate, so checking both spent another branch per
    // instruction without proving anything additional.
    if (info.size == 0 or info.size > code.len - pc_index)
        return error.InvalidBytecode;
    if (info.has_atom) {
        if (info.size < 5 or atom_index >= atoms_ledger.len)
            return error.InvalidBytecode;
        const operand = std.mem.readInt(u32, code[pc_index + 1 ..][0..4], .little);
        if (operand != atoms_ledger[atom_index]) return error.InvalidBytecode;
    }
    return .{
        .size = info.size,
        .is_temp = info.is_temp,
        .has_atom = info.has_atom,
    };
}

pub fn isUnconditionalTerminal(op_id: u8) bool {
    return switch (op_id) {
        op.goto,
        op.tail_call,
        op.tail_call_method,
        op.@"return",
        op.return_undef,
        op.throw,
        op.throw_error,
        op.ret,
        => true,
        else => false,
    };
}

/// Continuation-kind opcodes: the population the CFG's continuation
/// accounting is defined over.
fn isContinuationOp(op_id: u8) bool {
    return switch (op_id) {
        op.@"catch",
        op.gosub,
        op.ret,
        op.nip_catch,
        op.for_await_of_start,
        op.for_await_of_next,
        op.initial_yield,
        op.yield,
        op.yield_star,
        op.async_yield_star,
        op.await,
        => true,
        else => false,
    };
}

fn labelOperandOffset(op_id: u8, instruction: TempInstruction) ?u32 {
    return switch (op_id) {
        op.if_false, op.if_true, op.goto, op.@"catch", op.gosub => 1,
        op.scope_make_ref => if (instruction.is_temp) 5 else null,
        else => switch (if (instruction.is_temp)
            opcode.formatOfPhase1(op_id)
        else
            opcode.formatOf(op_id)) {
            .atom_label_u8, .atom_label_u16 => 5,
            else => null,
        },
    };
}

fn validateAndAdvanceAtom(
    input: *const builder.Builder,
    pc: u32,
    instruction: TempInstruction,
    atom_index: *u32,
) Error!void {
    if (!instruction.has_atom) return;
    if (atom_index.* >= input.atom_len or instruction.size < 5)
        return error.InvalidBytecode;
    const pc_index: usize = @intCast(pc);
    const operand = std.mem.readInt(u32, input.code[pc_index + 1 ..][0..4], .little);
    if (operand != input.atom_operands[atom_index.*]) return error.InvalidBytecode;
    atom_index.* += 1;
}

fn readLabelIndex(
    input: *const builder.Builder,
    pc: u32,
    instruction: TempInstruction,
    operand_offset: u32,
) Error!u32 {
    const operand_end = std.math.add(u32, operand_offset, 4) catch
        return error.InvalidBytecode;
    if (operand_end > instruction.size) return error.InvalidBytecode;
    const operand_pc = std.math.add(u32, pc, operand_offset) catch
        return error.InvalidBytecode;
    const operand_index: usize = @intCast(operand_pc);
    if (operand_index + 4 > input.code_len) return error.InvalidBytecode;
    const label_index = std.mem.readInt(u32, input.code[operand_index..][0..4], .little);
    if (label_index >= input.label_len) return error.InvalidBytecode;
    return label_index;
}

fn labelTargetOffset(input: *const builder.Builder, label_index: u32) Error!u32 {
    if (label_index >= input.label_len) return error.InvalidBytecode;
    const slot = input.label_slots[label_index];
    if (!slot.flags.bound or slot.bound_offset == labels.unbound or
        slot.bound_offset > input.code_len)
    {
        return error.InvalidBytecode;
    }
    return slot.bound_offset;
}

fn isEmptyGosub(input: *const builder.Builder, op_id: u8, target_offset: u32) bool {
    return op_id == op.gosub and
        target_offset < input.code_len and
        input.code[target_offset] == op.ret;
}

pub const Block = struct {
    edge_start: usize = 0,
    edge_end: usize = 0,
    cutoff_offset: u32 = 0,
    has_terminal: bool = false,
};

pub const Graph = struct {
    memory: *core.memory.MemoryAccount,
    block_starts: []u32 = &.{},
    blocks: []Block = &.{},
    edge_storage: []usize = &.{},
    edge_len: usize = 0,
    reachable_words: []usize = &.{},
    /// Set by the mandatory construction walk. Consumers can avoid a second
    /// full decode when no direct-eval instruction exists in the stream.
    has_eval_instruction: bool = false,

    pub fn deinit(self: *Graph) void {
        self.memory.free(u32, self.block_starts);
        self.memory.free(Block, self.blocks);
        self.memory.free(usize, self.edge_storage);
        self.memory.free(usize, self.reachable_words);
        self.block_starts = &.{};
        self.blocks = &.{};
        self.edge_storage = &.{};
        self.edge_len = 0;
        self.reachable_words = &.{};
        self.has_eval_instruction = false;
    }

    pub fn edgesForBlock(self: *const Graph, block_index: usize) []const usize {
        std.debug.assert(block_index < self.blocks.len);
        const block = self.blocks[block_index];
        std.debug.assert(block.edge_start <= block.edge_end);
        std.debug.assert(block.edge_end <= self.edge_len);
        return self.edge_storage[block.edge_start..block.edge_end];
    }

    pub fn isReachable(self: *const Graph, block_index: usize) bool {
        std.debug.assert(block_index < self.blocks.len);
        return bitIsSet(self.reachable_words, block_index);
    }
};

const word_bits = @bitSizeOf(usize);

fn bitWordCount(bit_count: usize) Error!usize {
    const rounded = std.math.add(usize, bit_count, word_bits - 1) catch
        return error.OutOfMemory;
    return rounded / word_bits;
}

fn bitIsSet(words: []const usize, bit_index: usize) bool {
    const shift: std.math.Log2Int(usize) = @intCast(bit_index % word_bits);
    return (words[bit_index / word_bits] & (@as(usize, 1) << shift)) != 0;
}

fn setBit(words: []usize, bit_index: usize) void {
    const shift: std.math.Log2Int(usize) = @intCast(bit_index % word_bits);
    words[bit_index / word_bits] |= @as(usize, 1) << shift;
}

fn findBlockStart(block_starts: []const u32, target_offset: u32) ?usize {
    var lo: usize = 0;
    var hi = block_starts.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (block_starts[mid] < target_offset)
            lo = mid + 1
        else
            hi = mid;
    }
    if (lo >= block_starts.len or block_starts[lo] != target_offset) return null;
    return lo;
}

fn appendEdge(graph: *Graph, target_block: usize) Error!void {
    if (graph.edge_len >= graph.edge_storage.len) return error.InvalidBytecode;
    graph.edge_storage[graph.edge_len] = target_block;
    graph.edge_len += 1;
}

fn validateBindIndex(input: *const builder.Builder, binds: []const BindEntry) Error!void {
    var bound_count: usize = 0;
    for (input.label_slots[0..input.label_len]) |slot| {
        if (slot.flags.bound) bound_count += 1;
    }
    if (bound_count != binds.len) return error.InvalidBytecode;

    var previous: ?BindEntry = null;
    for (binds) |entry| {
        if (entry.label_index >= input.label_len or entry.input_offset > input.code_len)
            return error.InvalidBytecode;
        const slot = input.label_slots[entry.label_index];
        if (!slot.flags.bound or slot.bound_offset != entry.input_offset)
            return error.InvalidBytecode;
        if (previous) |prev| {
            if (entry.input_offset < prev.input_offset or
                (entry.input_offset == prev.input_offset and
                    entry.label_index <= prev.label_index))
            {
                return error.InvalidBytecode;
            }
        }
        previous = entry;
    }
}

fn indexedControlKind(op_id: u8) ?builder.ControlKind {
    if (op_id == op.eval or op_id == op.apply_eval) return .direct_eval;
    if (op_id != op.goto and isUnconditionalTerminal(op_id)) return .terminal;
    return null;
}

/// Debug/ReleaseSafe proof that the parser-maintained sparse index names
/// exactly the non-reloc control events the legacy full decode would find.
/// ReleaseFast can then consume the index without trusting untested metadata.
fn validateControlIndex(input: *const builder.Builder) Error!void {
    var pc: u32 = 0;
    var atom_index: u32 = 0;
    var control_index: u32 = 0;
    while (pc < input.code_len) {
        const instruction = try tempInstruction(
            input.code[0..input.code_len],
            input.atom_operands[0..input.atom_len],
            pc,
            atom_index,
        );
        try validateAndAdvanceAtom(input, pc, instruction, &atom_index);
        if (indexedControlKind(input.code[pc])) |kind| {
            if (control_index >= input.controlCount()) return error.InvalidBytecode;
            const slot = input.controlAt(control_index);
            if (slot.temp_offset != pc or slot.kind != kind)
                return error.InvalidBytecode;
            control_index += 1;
        }
        pc = std.math.add(u32, pc, instruction.size) catch
            return error.InvalidBytecode;
    }
    if (pc != input.code_len or atom_index != input.atom_len or
        control_index != input.controlCount())
    {
        return error.InvalidBytecode;
    }
}

fn relocOpcodeOffset(
    input: *const builder.Builder,
    entry: labels.RelocEntry,
) Error!u32 {
    const delta: u32 = switch (entry.kind) {
        .jump32 => 1,
        .aux32 => 5,
    };
    if (entry.operand_offset < delta or
        @as(u64, entry.operand_offset) + 4 > input.code_len)
    {
        return error.InvalidBytecode;
    }
    return entry.operand_offset - delta;
}

fn indexedRelocOpcodeValid(op_id: u8, kind: labels.RelocKind) bool {
    return switch (kind) {
        .jump32 => op_id == op.if_false or op_id == op.if_true or
            op_id == op.goto or op_id == op.@"catch" or op_id == op.gosub,
        .aux32 => op_id == op.scope_make_ref or switch (opcode.formatOf(op_id)) {
            .atom_label_u8, .atom_label_u16 => true,
            else => false,
        },
    };
}

/// Exact CFG from consumer-proportional side tables: bound labels partition
/// blocks, RelocEntry rows provide explicit edges, and the sparse control
/// index supplies only non-reloc terminals/direct-eval events. Ordinary
/// instructions never need decoding here.
fn buildFromControlIndex(
    memory: *core.memory.MemoryAccount,
    input: *const builder.Builder,
    binds: []const BindEntry,
) Error!Graph {
    var block_count: usize = 1;
    var last_start: u32 = 0;
    for (binds) |entry| {
        if (entry.input_offset != last_start) {
            block_count = std.math.add(usize, block_count, 1) catch
                return error.OutOfMemory;
            last_start = entry.input_offset;
        }
    }
    if (last_start != input.code_len) {
        block_count = std.math.add(usize, block_count, 1) catch
            return error.OutOfMemory;
    }

    var graph: Graph = .{ .memory = memory };
    errdefer graph.deinit();
    graph.block_starts = memory.alloc(u32, block_count) catch
        return error.OutOfMemory;
    graph.blocks = memory.alloc(Block, block_count) catch
        return error.OutOfMemory;

    var start_index: usize = 1;
    graph.block_starts[0] = 0;
    last_start = 0;
    for (binds) |entry| {
        if (entry.input_offset == last_start) continue;
        graph.block_starts[start_index] = entry.input_offset;
        start_index += 1;
        last_start = entry.input_offset;
    }
    if (last_start != input.code_len) {
        graph.block_starts[start_index] = input.code_len;
        start_index += 1;
    }
    if (start_index != block_count or graph.block_starts[block_count - 1] != input.code_len)
        return error.InvalidBytecode;

    const edge_capacity = std.math.add(
        usize,
        @as(usize, input.reloc_len),
        block_count - 1,
    ) catch return error.OutOfMemory;
    if (edge_capacity != 0) {
        graph.edge_storage = memory.alloc(usize, edge_capacity) catch
            return error.OutOfMemory;
    }
    const reachable_word_count = try bitWordCount(block_count);
    graph.reachable_words = memory.alloc(usize, reachable_word_count) catch
        return error.OutOfMemory;
    @memset(graph.reachable_words, 0);

    var reloc_index: u32 = 0;
    var control_index: u32 = 0;
    var previous_reloc_offset: ?u32 = null;
    for (graph.blocks, 0..) |*block, block_index| {
        const block_start = graph.block_starts[block_index];
        const block_end = if (block_index + 1 < block_count)
            graph.block_starts[block_index + 1]
        else
            input.code_len;
        block.* = .{
            .edge_start = graph.edge_len,
            .edge_end = graph.edge_len,
            .cutoff_offset = block_end,
        };

        while (true) {
            const reloc_offset = if (reloc_index < input.reloc_len)
                try relocOpcodeOffset(input, input.relocs[reloc_index])
            else
                std.math.maxInt(u32);
            const control_offset: u32 = if (control_index < input.controlCount())
                input.controlAt(control_index).temp_offset
            else
                std.math.maxInt(u32);
            const event_offset = @min(reloc_offset, control_offset);
            if (event_offset >= block_end) break;
            if (event_offset < block_start or reloc_offset == control_offset)
                return error.InvalidBytecode;

            if (control_offset < reloc_offset) {
                const control = input.controlAt(control_index);
                switch (control.kind) {
                    .direct_eval => graph.has_eval_instruction = true,
                    .terminal => if (!block.has_terminal) {
                        block.has_terminal = true;
                        block.cutoff_offset = control_offset;
                    },
                }
                control_index += 1;
                continue;
            }

            const entry = input.relocs[reloc_index];
            if (previous_reloc_offset) |previous| {
                if (reloc_offset <= previous) return error.InvalidBytecode;
            }
            previous_reloc_offset = reloc_offset;
            const op_id = input.code[reloc_offset];
            if (!indexedRelocOpcodeValid(op_id, entry.kind))
                return error.InvalidBytecode;
            const operand_index: usize = @intCast(entry.operand_offset);
            const label_index = std.mem.readInt(
                u32,
                input.code[operand_index..][0..4],
                .little,
            );
            if (label_index >= input.label_len) return error.InvalidBytecode;
            const target_offset = try labelTargetOffset(input, label_index);
            const target_block = findBlockStart(graph.block_starts, target_offset) orelse
                return error.InvalidBytecode;
            if (!block.has_terminal and !isEmptyGosub(input, op_id, target_offset))
                try appendEdge(&graph, target_block);
            if (!block.has_terminal and op_id == op.goto) {
                block.has_terminal = true;
                block.cutoff_offset = reloc_offset;
            }
            reloc_index += 1;
        }

        if (!block.has_terminal and block_index + 1 < block_count)
            try appendEdge(&graph, block_index + 1);
        block.edge_end = graph.edge_len;
    }
    if (reloc_index != input.reloc_len or control_index != input.controlCount())
        return error.InvalidBytecode;

    const worklist = memory.alloc(usize, block_count) catch
        return error.OutOfMemory;
    defer memory.free(usize, worklist);
    var worklist_len: usize = 1;
    var worklist_index: usize = 0;
    worklist[0] = 0;
    setBit(graph.reachable_words, 0);
    while (worklist_index < worklist_len) : (worklist_index += 1) {
        const block_index = worklist[worklist_index];
        for (graph.edgesForBlock(block_index)) |target_block| {
            if (target_block >= block_count) return error.InvalidBytecode;
            if (bitIsSet(graph.reachable_words, target_block)) continue;
            if (worklist_len >= worklist.len) return error.InvalidBytecode;
            setBit(graph.reachable_words, target_block);
            worklist[worklist_len] = target_block;
            worklist_len += 1;
        }
    }
    return graph;
}

/// Build the exact block CFG once from the immutable Builder product.
pub fn build(
    memory: *core.memory.MemoryAccount,
    input: *const builder.Builder,
    binds: []const BindEntry,
) Error!Graph {
    if (input.code_len > input.code.len or
        input.atom_len > input.atom_operands.len or
        input.label_len > input.label_slots.len or
        input.reloc_len > input.relocs.len)
    {
        return error.InvalidBytecode;
    }
    try validateBindIndex(input, binds);
    if (input.hasControlIndex()) {
        if (comptime audit_oracles) try validateControlIndex(input);
        return buildFromControlIndex(memory, input, binds);
    }

    var block_count: usize = 1;
    var last_start: u32 = 0;
    for (binds) |entry| {
        if (entry.input_offset != last_start) {
            block_count = std.math.add(usize, block_count, 1) catch
                return error.OutOfMemory;
            last_start = entry.input_offset;
        }
    }
    if (last_start != input.code_len) {
        block_count = std.math.add(usize, block_count, 1) catch
            return error.OutOfMemory;
    }

    var graph: Graph = .{ .memory = memory };
    errdefer graph.deinit();

    graph.block_starts = memory.alloc(u32, block_count) catch
        return error.OutOfMemory;
    graph.blocks = memory.alloc(Block, block_count) catch
        return error.OutOfMemory;

    var start_index: usize = 1;
    graph.block_starts[0] = 0;
    last_start = 0;
    for (binds) |entry| {
        if (entry.input_offset == last_start) continue;
        graph.block_starts[start_index] = entry.input_offset;
        start_index += 1;
        last_start = entry.input_offset;
    }
    if (last_start != input.code_len) {
        graph.block_starts[start_index] = input.code_len;
        start_index += 1;
    }
    if (start_index != block_count or graph.block_starts[block_count - 1] != input.code_len)
        return error.InvalidBytecode;

    const fallthrough_capacity = block_count - 1;
    const edge_capacity = std.math.add(
        usize,
        @as(usize, input.reloc_len),
        fallthrough_capacity,
    ) catch return error.OutOfMemory;
    if (edge_capacity != 0) {
        graph.edge_storage = memory.alloc(usize, edge_capacity) catch
            return error.OutOfMemory;
    }

    const reachable_word_count = try bitWordCount(block_count);
    graph.reachable_words = memory.alloc(usize, reachable_word_count) catch
        return error.OutOfMemory;
    @memset(graph.reachable_words, 0);

    var atom_index: u32 = 0;
    var label_reference_count: u32 = 0;
    for (graph.blocks, 0..) |*block, block_index| {
        const block_start = graph.block_starts[block_index];
        const block_end = if (block_index + 1 < block_count)
            graph.block_starts[block_index + 1]
        else
            input.code_len;
        block.* = .{
            .edge_start = graph.edge_len,
            .edge_end = graph.edge_len,
            .cutoff_offset = block_end,
        };

        var pc = block_start;
        while (pc < block_end) {
            const instruction = try tempInstruction(
                input.code[0..input.code_len],
                input.atom_operands[0..input.atom_len],
                pc,
                atom_index,
            );
            const next = std.math.add(u32, pc, instruction.size) catch
                return error.InvalidBytecode;
            if (next > block_end) return error.InvalidBytecode;
            try validateAndAdvanceAtom(input, pc, instruction, &atom_index);

            const op_id = input.code[pc];
            if (op_id == op.eval or op_id == op.apply_eval)
                graph.has_eval_instruction = true;
            if (labelOperandOffset(op_id, instruction)) |operand_offset| {
                if (label_reference_count == std.math.maxInt(u32))
                    return error.InvalidBytecode;
                label_reference_count += 1;
                const label_index = try readLabelIndex(input, pc, instruction, operand_offset);
                const target_offset = try labelTargetOffset(input, label_index);
                const target_block = findBlockStart(graph.block_starts, target_offset) orelse
                    return error.InvalidBytecode;
                std.debug.assert(graph.block_starts[target_block] == target_offset);

                if (!block.has_terminal and !isEmptyGosub(input, op_id, target_offset)) {
                    try appendEdge(&graph, target_block);
                }
            }

            if (!block.has_terminal and isUnconditionalTerminal(op_id)) {
                block.has_terminal = true;
                block.cutoff_offset = pc;
            }
            pc = next;
        }
        if (pc != block_end) return error.InvalidBytecode;
        std.debug.assert(pc == block_end);

        if (!block.has_terminal and block_index + 1 < block_count) {
            try appendEdge(&graph, block_index + 1);
        }
        block.edge_end = graph.edge_len;
    }
    if (atom_index != input.atom_len or label_reference_count != input.reloc_len)
        return error.InvalidBytecode;

    const worklist = memory.alloc(usize, block_count) catch
        return error.OutOfMemory;
    defer memory.free(usize, worklist);
    var worklist_len: usize = 1;
    var worklist_index: usize = 0;
    worklist[0] = 0;
    setBit(graph.reachable_words, 0);
    while (worklist_index < worklist_len) : (worklist_index += 1) {
        const block_index = worklist[worklist_index];
        for (graph.edgesForBlock(block_index)) |target_block| {
            if (target_block >= block_count) return error.InvalidBytecode;
            if (bitIsSet(graph.reachable_words, target_block)) continue;
            if (worklist_len >= worklist.len) return error.InvalidBytecode;
            setBit(graph.reachable_words, target_block);
            worklist[worklist_len] = target_block;
            worklist_len += 1;
        }
    }
    return graph;
}

const AuditInstruction = struct {
    size: u8 = 0,
    is_temp: bool = false,
};

fn enqueueAuditOffset(
    nodes: []const AuditInstruction,
    live_words: []usize,
    worklist: []u32,
    worklist_len: *usize,
    target: u32,
) Error!void {
    const target_index: usize = @intCast(target);
    if (target_index >= nodes.len or
        (target_index + 1 != nodes.len and nodes[target_index].size == 0))
    {
        return error.InvalidBytecode;
    }
    if (bitIsSet(live_words, target_index)) return;
    if (worklist_len.* >= worklist.len) return error.InvalidBytecode;
    setBit(live_words, target_index);
    worklist[worklist_len.*] = target;
    worklist_len.* += 1;
}

/// Debug/ReleaseSafe proof obligation: compare instruction-granularity
/// reachability against block reachability plus each block's first-terminal
/// cutoff. ReleaseFast callers do not reference this routine.
pub fn auditInstructionOwnership(
    memory: *core.memory.MemoryAccount,
    input: *const builder.Builder,
    graph: *const Graph,
) Error!void {
    const node_count = std.math.add(usize, @as(usize, input.code_len), 1) catch
        return error.OutOfMemory;
    const nodes = memory.alloc(AuditInstruction, node_count) catch
        return error.OutOfMemory;
    defer memory.free(AuditInstruction, nodes);
    @memset(nodes, .{});

    var pc: u32 = 0;
    var atom_index: u32 = 0;
    while (pc < input.code_len) {
        const instruction = try tempInstruction(
            input.code[0..input.code_len],
            input.atom_operands[0..input.atom_len],
            pc,
            atom_index,
        );
        nodes[pc] = .{ .size = instruction.size, .is_temp = instruction.is_temp };
        try validateAndAdvanceAtom(input, pc, instruction, &atom_index);
        pc = std.math.add(u32, pc, instruction.size) catch
            return error.InvalidBytecode;
    }
    if (pc != input.code_len or atom_index != input.atom_len)
        return error.InvalidBytecode;

    const live_word_count = try bitWordCount(node_count);
    const live_words = memory.alloc(usize, live_word_count) catch
        return error.OutOfMemory;
    defer memory.free(usize, live_words);
    @memset(live_words, 0);

    const worklist = memory.alloc(u32, node_count) catch
        return error.OutOfMemory;
    defer memory.free(u32, worklist);
    var worklist_len: usize = 0;
    try enqueueAuditOffset(nodes, live_words, worklist, &worklist_len, 0);

    var worklist_index: usize = 0;
    while (worklist_index < worklist_len) : (worklist_index += 1) {
        const current = worklist[worklist_index];
        if (current == input.code_len) continue;
        const node = nodes[current];
        const instruction: TempInstruction = .{
            .size = node.size,
            .is_temp = node.is_temp,
            .has_atom = instructionHasAtom(input.code[current], node.is_temp),
        };
        const next = std.math.add(u32, current, node.size) catch
            return error.InvalidBytecode;
        const op_id = input.code[current];

        if (labelOperandOffset(op_id, instruction)) |operand_offset| {
            const label_index = try readLabelIndex(input, current, instruction, operand_offset);
            const target_offset = try labelTargetOffset(input, label_index);
            if (!isEmptyGosub(input, op_id, target_offset)) {
                try enqueueAuditOffset(nodes, live_words, worklist, &worklist_len, target_offset);
            }
            if (op_id != op.goto) {
                try enqueueAuditOffset(nodes, live_words, worklist, &worklist_len, next);
            }
        } else if (!isUnconditionalTerminal(op_id)) {
            try enqueueAuditOffset(nodes, live_words, worklist, &worklist_len, next);
        }
    }

    var block_index: usize = 0;
    pc = 0;
    while (pc < input.code_len) {
        while (block_index + 1 < graph.block_starts.len and
            graph.block_starts[block_index + 1] <= pc)
        {
            block_index += 1;
        }
        if (block_index >= graph.blocks.len or graph.block_starts[block_index] > pc)
            return error.InvalidBytecode;
        const block = graph.blocks[block_index];
        const instruction_live = bitIsSet(live_words, pc);
        const cfg_live = graph.isReachable(block_index) and
            (!block.has_terminal or pc <= block.cutoff_offset);
        if (instruction_live != cfg_live) {
            recordDiffBucket(.ownership_mismatch);
            std.debug.panic(
                "compiler_v2 oracle violation: bucket=OWNERSHIP_MISMATCH category=cfg_ownership_divergence role=position construct=opcode_0x{x:0>2} key=block={d} identities=[instruction_live={}, cfg_live={}] offset={d}",
                .{ input.code[pc], block_index, instruction_live, cfg_live, pc },
            );
        }
        pc = std.math.add(u32, pc, nodes[pc].size) catch
            return error.InvalidBytecode;
    }
}

const DivergenceOrigin = struct {
    block_index: usize,
    bound_label: ?u32,
    source: ?builder.SourceSlot,
};

fn validateBoundaryAuditInput(
    input: *const builder.Builder,
    graph: *const Graph,
    binds: []const BindEntry,
    product_labels: []const labels.LabelSlot,
) Error!void {
    if (input.code_len > input.code.len or
        input.atom_len > input.atom_operands.len or
        input.label_len > input.label_slots.len or
        input.reloc_len > input.relocs.len or
        input.source_len > input.source_slots.len or
        product_labels.len < input.label_len)
    {
        return error.InvalidBytecode;
    }
    try validateBindIndex(input, binds);

    var previous_source_offset: u32 = 0;
    for (input.source_slots[0..input.source_len], 0..) |source, index| {
        if (index != 0 and source.temp_offset < previous_source_offset)
            return error.InvalidBytecode;
        previous_source_offset = source.temp_offset;
    }

    if (graph.block_starts.len == 0 or
        graph.block_starts.len != graph.blocks.len or
        graph.block_starts[0] != 0 or
        graph.block_starts[graph.block_starts.len - 1] != input.code_len)
    {
        return error.InvalidBytecode;
    }
    for (graph.block_starts, 0..) |block_start, block_index| {
        if (block_start > input.code_len or
            (block_index != 0 and block_start <= graph.block_starts[block_index - 1]))
        {
            return error.InvalidBytecode;
        }
    }
    const reachable_word_count = try bitWordCount(graph.blocks.len);
    if (graph.reachable_words.len < reachable_word_count)
        return error.InvalidBytecode;
}

fn resolveDivergenceOrigin(
    input: *const builder.Builder,
    graph: *const Graph,
    binds: []const BindEntry,
    pc: u32,
) Error!DivergenceOrigin {
    if (pc > input.code_len) return error.InvalidBytecode;

    var block_lo: usize = 0;
    var block_hi = graph.block_starts.len;
    while (block_lo < block_hi) {
        const mid = block_lo + (block_hi - block_lo) / 2;
        if (graph.block_starts[mid] <= pc)
            block_lo = mid + 1
        else
            block_hi = mid;
    }
    if (block_lo == 0) return error.InvalidBytecode;
    const block_index = block_lo - 1;
    if (block_index >= graph.blocks.len) return error.InvalidBytecode;
    const block_start = graph.block_starts[block_index];

    const bind_index = lowerBoundBindOffset(binds, block_start);
    const bound_label = if (bind_index < binds.len and
        binds[bind_index].input_offset == block_start)
        binds[bind_index].label_index
    else
        null;

    const sources = input.source_slots[0..input.source_len];
    var source_lo: usize = 0;
    var source_hi = sources.len;
    while (source_lo < source_hi) {
        const mid = source_lo + (source_hi - source_lo) / 2;
        if (sources[mid].temp_offset <= pc)
            source_lo = mid + 1
        else
            source_hi = mid;
    }
    const source = if (source_lo == 0) null else sources[source_lo - 1];

    return .{
        .block_index = block_index,
        .bound_label = bound_label,
        .source = source,
    };
}

fn formatDivergenceOrigin(buffer: []u8, origin: DivergenceOrigin) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    if (origin.bound_label) |label_index| {
        if (origin.source) |source| {
            writer.print(
                "block={d} label={d} source={d}:{d}",
                .{ origin.block_index, label_index, source.line, source.col },
            ) catch unreachable;
        } else {
            writer.print(
                "block={d} label={d} source=none",
                .{ origin.block_index, label_index },
            ) catch unreachable;
        }
    } else if (origin.source) |source| {
        writer.print(
            "block={d} label=none source={d}:{d}",
            .{ origin.block_index, source.line, source.col },
        ) catch unreachable;
    } else {
        writer.print(
            "block={d} label=none source=none",
            .{origin.block_index},
        ) catch unreachable;
    }
    return writer.buffered();
}

const BoundaryRole = enum {
    position,
    jump_target,
    exception_landing,
    cleanup_subroutine,
    aux_reference,
    source_attribution,
    fold_replacement,
};

const ReportIdentity = struct {
    kind: []const u8,
    index: ?u32,
    offset: u32,
};

fn writeReportIdentity(writer: *std.Io.Writer, identity: ReportIdentity) void {
    if (identity.index) |index| {
        writer.print("{s}#{d}@{d}", .{ identity.kind, index, identity.offset }) catch
            unreachable;
    } else {
        writer.print("{s}@{d}", .{ identity.kind, identity.offset }) catch unreachable;
    }
}

fn panicBoundaryUniquenessViolation(
    bucket: DiffBucket,
    category: []const u8,
    role: BoundaryRole,
    op_id: u8,
    semantic_key: []const u8,
    identities: [2]ReportIdentity,
    origin: DivergenceOrigin,
) noreturn {
    var origin_buffer: [160]u8 = undefined;
    const origin_text = formatDivergenceOrigin(&origin_buffer, origin);

    var message_buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&message_buffer);
    writer.print(
        "compiler_v2 oracle violation: bucket={s} category={s} role={s} construct=opcode_0x{x:0>2} key={s} identities=[",
        .{ bucket.name(), category, @tagName(role), op_id, semantic_key },
    ) catch unreachable;
    writeReportIdentity(&writer, identities[0]);
    writer.print(", ", .{}) catch unreachable;
    writeReportIdentity(&writer, identities[1]);
    writer.print("] {s}", .{origin_text}) catch unreachable;
    recordDiffBucket(bucket);
    std.debug.panic("{s}", .{writer.buffered()});
}

fn boundaryViolation(
    bucket: DiffBucket,
    input: *const builder.Builder,
    graph: *const Graph,
    binds: []const BindEntry,
    category: []const u8,
    role: BoundaryRole,
    construct_offset: u32,
    semantic_key: []const u8,
    identities: [2]ReportIdentity,
) Error!void {
    const origin_offset = @min(construct_offset, input.code_len);
    const origin = try resolveDivergenceOrigin(input, graph, binds, origin_offset);
    const op_id = if (construct_offset < input.code_len)
        input.code[construct_offset]
    else
        0xff;
    panicBoundaryUniquenessViolation(
        bucket,
        category,
        role,
        op_id,
        semantic_key,
        identities,
        origin,
    );
}

const AliasGroupSplit = struct {
    first_label: u32,
    first_offset: u32,
    second_label: u32,
    second_offset: u32,
};

fn aliasGroupSplit(
    group: []const BindEntry,
    product_labels: []const labels.LabelSlot,
) ?AliasGroupSplit {
    var first_survivor: ?BindEntry = null;
    for (group) |entry| {
        if (entry.label_index >= product_labels.len) return null;
        const slot = product_labels[entry.label_index];
        if (!slot.flags.bound) continue;
        if (first_survivor) |first| {
            const first_slot = product_labels[first.label_index];
            if (first_slot.bound_offset != slot.bound_offset) {
                return .{
                    .first_label = first.label_index,
                    .first_offset = first_slot.bound_offset,
                    .second_label = entry.label_index,
                    .second_offset = slot.bound_offset,
                };
            }
        } else {
            first_survivor = entry;
        }
    }
    return null;
}

const DuplicateReplacementOwner = struct {
    first: OptimizationBoundary,
    second: OptimizationBoundary,
};

/// `opt_bounds` must be sorted by replacement_start.
fn duplicateReplacementOwner(
    opt_bounds: []const OptimizationBoundary,
) ?DuplicateReplacementOwner {
    if (opt_bounds.len < 2) return null;
    for (opt_bounds[1..], 1..) |boundary, index| {
        const previous = opt_bounds[index - 1];
        if (previous.replacement_start == boundary.replacement_start) {
            return .{ .first = previous, .second = boundary };
        }
    }
    return null;
}

fn optimizationBoundaryLessThan(
    _: void,
    lhs: OptimizationBoundary,
    rhs: OptimizationBoundary,
) bool {
    if (lhs.replacement_start != rhs.replacement_start)
        return lhs.replacement_start < rhs.replacement_start;
    if (lhs.fold_start != rhs.fold_start) return lhs.fold_start < rhs.fold_start;
    if (lhs.consumed_end != rhs.consumed_end) return lhs.consumed_end < rhs.consumed_end;
    return @intFromEnum(lhs.kind) < @intFromEnum(rhs.kind);
}

const BindInsideFold = struct {
    boundary: OptimizationBoundary,
    bind: BindEntry,
};

fn bindInsideFold(
    binds: []const BindEntry,
    boundary: OptimizationBoundary,
) ?BindInsideFold {
    const bind_index = upperBoundBindOffset(binds, boundary.fold_start);
    if (bind_index < binds.len and binds[bind_index].input_offset < boundary.consumed_end) {
        return .{ .boundary = boundary, .bind = binds[bind_index] };
    }
    return null;
}

const RetiredAliasSplit = struct {
    retired_label: u32,
    surviving_label: u32,
    input_offset: u32,
    surviving_product_offset: u32,
};

/// `input_offset` is the referenced label's own bound offset (see
/// `referenceChainDepth` for why the caller supplies it instead of scanning).
fn referenceToRetiredAlias(
    binds: []const BindEntry,
    product_labels: []const labels.LabelSlot,
    label_index: u32,
    input_offset: u32,
) ?RetiredAliasSplit {
    if (label_index >= product_labels.len or product_labels[label_index].flags.bound)
        return null;

    const first = lowerBoundBindOffset(binds, input_offset);
    var index = first;
    while (index < binds.len and binds[index].input_offset == input_offset) : (index += 1) {
        const sibling = binds[index].label_index;
        if (sibling == label_index or sibling >= product_labels.len) continue;
        const slot = product_labels[sibling];
        if (slot.flags.bound) {
            return .{
                .retired_label = label_index,
                .surviving_label = sibling,
                .input_offset = input_offset,
                .surviving_product_offset = slot.bound_offset,
            };
        }
    }
    return null;
}

fn survivingSibling(
    group: []const BindEntry,
    product_labels: []const labels.LabelSlot,
    label_index: u32,
) ?u32 {
    for (group) |entry| {
        if (entry.label_index != label_index and
            entry.label_index < product_labels.len and
            product_labels[entry.label_index].flags.bound)
        {
            return entry.label_index;
        }
    }
    return null;
}

fn isInstructionStart(starts_words: []const usize, code_len: u32, offset: u32) bool {
    return offset <= code_len and bitIsSet(starts_words, @intCast(offset));
}

fn blockContainingOffset(graph: *const Graph, offset: u32) ?usize {
    var lo: usize = 0;
    var hi = graph.block_starts.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (graph.block_starts[mid] <= offset)
            lo = mid + 1
        else
            hi = mid;
    }
    if (lo == 0) return null;
    const block_index = lo - 1;
    if (block_index >= graph.blocks.len) return null;
    return block_index;
}

fn referencingInstructionIsLive(graph: *const Graph, pc: u32) Error!bool {
    const block_index = blockContainingOffset(graph, pc) orelse
        return error.InvalidBytecode;
    if (graph.block_starts[block_index] > pc) return error.InvalidBytecode;
    const block = graph.blocks[block_index];
    return graph.isReachable(block_index) and
        (!block.has_terminal or pc <= block.cutoff_offset);
}

fn roleForLabelOperand(op_id: u8, instruction: TempInstruction) BoundaryRole {
    return switch (op_id) {
        op.@"catch" => .exception_landing,
        op.gosub => .cleanup_subroutine,
        op.scope_make_ref => if (instruction.is_temp) .aux_reference else .jump_target,
        else => switch (if (instruction.is_temp)
            opcode.formatOfPhase1(op_id)
        else
            opcode.formatOf(op_id)) {
            .atom_label_u8, .atom_label_u16 => .aux_reference,
            else => .jump_target,
        },
    };
}

/// Identity hops a label reference traverses from the operand to the semantic
/// boundary it denotes. The ruling asks for chain depth alongside fan-out:
/// fewer identities is NOT the goal, short chains with one clear owner per hop
/// is. Hops counted here (input coordinates; resolve_labels_v2 adds the final
/// output hop):
///   1 operand -> LabelId
///  +1 LabelId -> alias-group representative   (only when the operand named an
///                                              alias rather than the canonical
///                                              identity)
///  +1 representative -> bound input offset    (the semantic boundary)
///  +1 boundary -> product offset               (only when S3 kept the boundary)
///
/// `input_offset` is the label's own bound offset, which `validateBindIndex`
/// proves equals the offset of its bind row. Taking it from the caller keeps
/// this per-reference sampler O(log binds): scanning `binds` for the label row
/// instead would make the audit walk O(references * binds).
fn referenceChainDepth(
    binds: []const BindEntry,
    product_labels: []const labels.LabelSlot,
    label_index: u32,
    input_offset: u32,
) u32 {
    var depth: u32 = 1;
    const canonical = canonicalIdentityAtOffset(binds, input_offset) orelse return depth;
    if (canonical != label_index) depth += 1;
    depth += 1;

    var bind_index = lowerBoundBindOffset(binds, input_offset);
    while (bind_index < binds.len and
        binds[bind_index].input_offset == input_offset) : (bind_index += 1)
    {
        const sibling = binds[bind_index].label_index;
        if (sibling < product_labels.len and product_labels[sibling].flags.bound) {
            depth += 1;
            break;
        }
    }
    return depth;
}

fn censusAdd(counter: *u64, amount: u64) void {
    _ = @atomicRmw(u64, counter, .Add, amount, .monotonic);
}

fn reportAdd(comptime field: []const u8, amount: u64) void {
    if (comptime !audit_oracles) return;
    censusAdd(&@field(oracle_report, field), amount);
}

pub fn recordDiffBucket(bucket: DiffBucket) void {
    if (comptime !audit_oracles) return;
    censusAdd(&oracle_report.buckets[@intFromEnum(bucket)], 1);
}

pub fn oracleReportSnapshot() OracleReport {
    if (comptime !audit_oracles) return .{};
    var report: OracleReport = .{
        .legacy_boundaries = @atomicLoad(
            u64,
            &oracle_report.legacy_boundaries,
            .monotonic,
        ),
        .v2_boundaries = @atomicLoad(u64, &oracle_report.v2_boundaries, .monotonic),
        .missing_boundaries = @atomicLoad(
            u64,
            &oracle_report.missing_boundaries,
            .monotonic,
        ),
        .extra_boundaries = @atomicLoad(u64, &oracle_report.extra_boundaries, .monotonic),
        .duplicated_boundaries = @atomicLoad(
            u64,
            &oracle_report.duplicated_boundaries,
            .monotonic,
        ),
        .instruction_claims = @atomicLoad(u64, &oracle_report.instruction_claims, .monotonic),
        .control_flow_claims = @atomicLoad(u64, &oracle_report.control_flow_claims, .monotonic),
        .optimization_claims = @atomicLoad(u64, &oracle_report.optimization_claims, .monotonic),
        .debug_claims = @atomicLoad(u64, &oracle_report.debug_claims, .monotonic),
        .ownership_create = @atomicLoad(u64, &oracle_report.ownership_create, .monotonic),
        .ownership_transfer = @atomicLoad(u64, &oracle_report.ownership_transfer, .monotonic),
        .ownership_release = @atomicLoad(u64, &oracle_report.ownership_release, .monotonic),
        .ownership_unbalanced = @atomicLoad(
            u64,
            &oracle_report.ownership_unbalanced,
            .monotonic,
        ),
        .control_blocks = @atomicLoad(u64, &oracle_report.control_blocks, .monotonic),
        .control_edges = @atomicLoad(u64, &oracle_report.control_edges, .monotonic),
        .control_continuations = @atomicLoad(
            u64,
            &oracle_report.control_continuations,
            .monotonic,
        ),
    };
    for (&report.buckets, 0..) |*bucket, index| {
        bucket.* = @atomicLoad(u64, &oracle_report.buckets[index], .monotonic);
    }
    return report;
}

pub fn resetOracleReport() void {
    if (comptime !audit_oracles) return;
    @atomicStore(u64, &oracle_report.legacy_boundaries, 0, .monotonic);
    @atomicStore(u64, &oracle_report.v2_boundaries, 0, .monotonic);
    @atomicStore(u64, &oracle_report.missing_boundaries, 0, .monotonic);
    @atomicStore(u64, &oracle_report.extra_boundaries, 0, .monotonic);
    @atomicStore(u64, &oracle_report.duplicated_boundaries, 0, .monotonic);
    @atomicStore(u64, &oracle_report.instruction_claims, 0, .monotonic);
    @atomicStore(u64, &oracle_report.control_flow_claims, 0, .monotonic);
    @atomicStore(u64, &oracle_report.optimization_claims, 0, .monotonic);
    @atomicStore(u64, &oracle_report.debug_claims, 0, .monotonic);
    @atomicStore(u64, &oracle_report.ownership_create, 0, .monotonic);
    @atomicStore(u64, &oracle_report.ownership_transfer, 0, .monotonic);
    @atomicStore(u64, &oracle_report.ownership_release, 0, .monotonic);
    @atomicStore(u64, &oracle_report.ownership_unbalanced, 0, .monotonic);
    @atomicStore(u64, &oracle_report.control_blocks, 0, .monotonic);
    @atomicStore(u64, &oracle_report.control_edges, 0, .monotonic);
    @atomicStore(u64, &oracle_report.control_continuations, 0, .monotonic);
    for (&oracle_report.buckets) |*bucket| {
        @atomicStore(u64, bucket, 0, .monotonic);
    }
}

const BoundaryClaimCategory = enum(u8) {
    instruction,
    control_flow,
    optimization,
    debug,
};

/// Oracle-report boundary definitions, in INPUT temporary-stream coordinates:
/// `instruction` claims every instruction start plus the `code_len` sentinel;
/// `control_flow` claims every label operand at its target and every
/// unconditional terminal at its own start; `optimization` claims fold_start,
/// replacement_start, and consumed_end for every fold; `debug` claims every
/// SourceSlot.temp_offset. A claim resolves to the canonical bound-label
/// identity at its offset when one exists, otherwise to its instruction-start
/// anchor. `legacy` is the sum of all claims, `v2` is the number of distinct
/// resolved offsets, and `missing` counts claims without either anchor.
/// `extra` counts bind groups absent from the control_flow/optimization/debug
/// union (the all-covering instruction category is deliberately excluded).
/// `duplicated` is summed per category as claims minus distinct offsets, so
/// repeated references to one target intentionally register fan-in.
const BoundaryReportAccounting = if (audit_oracles) struct {
    category_words: [4][]usize,
    any_words: []usize,
    semantic_words: []usize,
    claims: [4]u64 = .{0} ** 4,
    distinct: [4]u64 = .{0} ** 4,
    v2_distinct: u64 = 0,
    missing: u64 = 0,
    ownership_transfer: u64 = 0,
    ownership_release: u64 = 0,
    continuations: u64 = 0,
    block_index: usize = 0,

    fn claim(
        self: *@This(),
        category: BoundaryClaimCategory,
        offset: u32,
        binds: []const BindEntry,
        starts_words: []const usize,
        code_len: u32,
    ) void {
        std.debug.assert(offset <= code_len);
        const category_index = @intFromEnum(category);
        const offset_index: usize = @intCast(offset);
        self.claims[category_index] += 1;
        if (!bitIsSet(self.category_words[category_index], offset_index)) {
            setBit(self.category_words[category_index], offset_index);
            self.distinct[category_index] += 1;
        }
        if (category != .instruction) setBit(self.semantic_words, offset_index);

        const resolved = isInstructionStart(starts_words, code_len, offset) or
            canonicalIdentityAtOffset(binds, offset) != null;
        if (!resolved) {
            self.missing += 1;
            return;
        }
        if (!bitIsSet(self.any_words, offset_index)) {
            setBit(self.any_words, offset_index);
            self.v2_distinct += 1;
        }
    }
} else struct {};

fn censusMax(counter: *u64, value: u64) void {
    _ = @atomicRmw(u64, counter, .Max, value, .monotonic);
}

fn recordFanout(group_len: usize) void {
    std.debug.assert(group_len != 0);
    const fanout: u64 = @intCast(group_len);
    censusAdd(&boundary_fanout_census.semantic_boundaries, 1);
    censusAdd(&boundary_fanout_census.identities, fanout);
    if (group_len > 1) censusAdd(&boundary_fanout_census.coalesced_boundaries, 1);
    censusMax(&boundary_fanout_census.max_fanout, fanout);
    const bucket_index = @min(group_len - 1, boundary_fanout_census.fanout_buckets.len - 1);
    censusAdd(&boundary_fanout_census.fanout_buckets[bucket_index], 1);
}

fn recordChainDepth(depth: u32) void {
    censusAdd(&boundary_fanout_census.chain_depth_samples, 1);
    censusAdd(&boundary_fanout_census.chain_depth_total, depth);
    censusMax(&boundary_fanout_census.max_chain_depth, depth);
    const bucket_index = @min(
        @as(usize, @intCast(depth)),
        boundary_fanout_census.chain_depth_buckets.len - 1,
    );
    censusAdd(&boundary_fanout_census.chain_depth_buckets[bucket_index], 1);
}

pub fn recordFinalSourceCensus(total: u64, on_identity: u64, between_identities: u64) void {
    std.debug.assert(total == on_identity + between_identities);
    censusAdd(&boundary_fanout_census.final_source_events, total);
    censusAdd(&boundary_fanout_census.source_events_on_identity, on_identity);
    censusAdd(&boundary_fanout_census.source_events_between_identities, between_identities);
}

/// Record the one-edge `boundary -> final address` chain once for each live
/// product-coordinate alias group. Deliberately NOT folded into the reference
/// chain-depth histogram: that population is per label reference in input
/// coordinates, and mixing ~1 sample per boundary at depth 1 into it would
/// drag the reported mean down without any chain actually getting shorter.
pub fn recordFinalBoundaryHops(group_count: u64) void {
    if (group_count == 0) return;
    censusAdd(&boundary_fanout_census.final_address_hops, group_count);
}

fn fixedPointHundred(total: u64, count: u64) u64 {
    if (count == 0) return 0;
    const scaled = (@as(u128, total) * 100) / count;
    return @intCast(@min(scaled, std.math.maxInt(u64)));
}

fn histogramP95Index(buckets: [8]u64) ?usize {
    var total: u128 = 0;
    for (buckets) |count| total += count;
    if (total == 0) return null;
    const threshold = (total * 95 + 99) / 100;
    var cumulative: u128 = 0;
    for (buckets, 0..) |count, index| {
        cumulative += count;
        if (cumulative >= threshold) return index;
    }
    return buckets.len - 1;
}

fn writeHistogramP95(
    writer: *std.Io.Writer,
    buckets: [8]u64,
    base_one: bool,
) void {
    const index = histogramP95Index(buckets) orelse {
        writer.print("0", .{}) catch unreachable;
        return;
    };
    if (index == buckets.len - 1) {
        writer.print("8+", .{}) catch unreachable;
    } else {
        const value = index + @intFromBool(base_one);
        writer.print("{d}", .{value}) catch unreachable;
    }
}

/// `identity kinds=<n> instances=<n> fan-out{mean=<a.bb> p95=<n> max=<n>}`
///  `chain{mean=<a.bb> p95=<n> max=<n> +final-hop=<n>} final-source{events=<n>`
///  `on-identity=<n> between-identities=<n>} unanchored{source=<n> fold=<n>`
///  `contested=<n>}`
///
/// `chain` measures label references in INPUT coordinates; `+final-hop` counts
/// the single additional `boundary -> final address` edge resolve_labels_v2
/// adds per live alias group. They are reported separately so neither
/// population skews the other's mean: end-to-end chain per reference is
/// uniformly `chain + 1`.
pub fn formatIdentityHealth(buffer: []u8, census: FanoutCensus) []const u8 {
    const fanout_mean = fixedPointHundred(census.identities, census.semantic_boundaries);
    const chain_mean = fixedPointHundred(census.chain_depth_total, census.chain_depth_samples);

    var writer = std.Io.Writer.fixed(buffer);
    writer.print(
        "identity kinds={d} instances={d} fan-out{{mean={d}.{d:0>2} p95=",
        .{
            identity_kinds.len,
            census.identities,
            fanout_mean / 100,
            fanout_mean % 100,
        },
    ) catch unreachable;
    writeHistogramP95(&writer, census.fanout_buckets, true);
    writer.print(
        " max={d}}} chain{{mean={d}.{d:0>2} p95=",
        .{ census.max_fanout, chain_mean / 100, chain_mean % 100 },
    ) catch unreachable;
    writeHistogramP95(&writer, census.chain_depth_buckets, false);
    writer.print(
        " max={d} +final-hop={d}}} final-source{{events={d} on-identity={d} between-identities={d}}} unanchored{{source={d} fold={d} contested={d}}}",
        .{
            census.max_chain_depth,
            census.final_address_hops,
            census.final_source_events,
            census.source_events_on_identity,
            census.source_events_between_identities,
            census.unanchored_source_events,
            census.unanchored_fold_replacements,
            census.contested_fold_replacements,
        },
    ) catch unreachable;
    return writer.buffered();
}

/// The ruling's report block: Summary first, then Diff buckets. Never prints
/// a bare "PASS", and never keys anything by instruction offset.
pub fn formatOracleReport(buffer: []u8, report: OracleReport) []const u8 {
    if (comptime !audit_oracles) {
        return "ZJS-V2-ORACLE-REPORT unavailable: counters are comptime-erased in this build";
    }

    const atom_balanced = report.ownership_unbalanced == 0 and
        report.ownership_create == report.ownership_transfer + report.ownership_release;
    var writer = std.Io.Writer.fixed(buffer);
    writer.print(
        \\ZJS-V2-ORACLE-REPORT
        \\Summary:
        \\  boundaries: legacy={d} v2={d} missing={d} extra={d} duplicated={d}
        \\  boundary categories: instruction={d} control-flow={d} optimization={d} debug={d}
        \\  ownership events: create={d} transfer={d} release={d}
        \\  atom balanced: {s}
        \\  control totals: blocks={d} edges={d} continuations={d}
        \\Diff buckets:
        \\  {s}={d}
        \\  {s}={d}
        \\  {s}={d}
        \\  {s}={d}
        \\  {s}={d}
        \\  {s}={d}
        \\
    , .{
        report.legacy_boundaries,
        report.v2_boundaries,
        report.missing_boundaries,
        report.extra_boundaries,
        report.duplicated_boundaries,
        report.instruction_claims,
        report.control_flow_claims,
        report.optimization_claims,
        report.debug_claims,
        report.ownership_create,
        report.ownership_transfer,
        report.ownership_release,
        if (atom_balanced) "yes" else "no",
        report.control_blocks,
        report.control_edges,
        report.control_continuations,
        DiffBucket.boundary_mismatch.name(),
        report.buckets[@intFromEnum(DiffBucket.boundary_mismatch)],
        DiffBucket.ownership_mismatch.name(),
        report.buckets[@intFromEnum(DiffBucket.ownership_mismatch)],
        DiffBucket.binding_mismatch.name(),
        report.buckets[@intFromEnum(DiffBucket.binding_mismatch)],
        DiffBucket.cfg_mismatch.name(),
        report.buckets[@intFromEnum(DiffBucket.cfg_mismatch)],
        DiffBucket.continuation_mismatch.name(),
        report.buckets[@intFromEnum(DiffBucket.continuation_mismatch)],
        DiffBucket.source_event_mismatch.name(),
        report.buckets[@intFromEnum(DiffBucket.source_event_mismatch)],
    }) catch unreachable;
    return writer.buffered();
}

/// Product offset a boundary resolves to: the offset of the first SURVIVING
/// identity of the alias group at `input_offset`. `aliasGroupSplit` has
/// already proven every survivor in the group agrees, so the first is the
/// group's answer. Null when the whole group was retired.
fn boundaryProductOffset(
    binds: []const BindEntry,
    product_labels: []const labels.LabelSlot,
    input_offset: u32,
) ?u32 {
    var index = lowerBoundBindOffset(binds, input_offset);
    while (index < binds.len and binds[index].input_offset == input_offset) : (index += 1) {
        const label_index = binds[index].label_index;
        if (label_index >= product_labels.len) continue;
        const slot = product_labels[label_index];
        if (slot.flags.bound) return slot.bound_offset;
    }
    return null;
}

fn boundaryFirstLabel(binds: []const BindEntry, input_offset: u32) u32 {
    const index = lowerBoundBindOffset(binds, input_offset);
    if (index < binds.len and binds[index].input_offset == input_offset)
        return binds[index].label_index;
    return labels.unbound;
}

const SourceSite = struct {
    line: i32 = 0,
    col: i32 = 0,
};

/// Last parser source marker at or before `offset`. Exemplars for boundaries
/// that carry no marker of their own still need a source citation; input
/// source slots are sorted by temp_offset, so this is a bisection.
fn nearestSourceSite(sources: []const builder.SourceSlot, offset: u32) SourceSite {
    var lo: usize = 0;
    var hi = sources.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (sources[mid].temp_offset <= offset) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return .{};
    const slot = sources[lo - 1];
    return .{ .line = slot.line, .col = slot.col };
}

fn opAt(input: *const builder.Builder, offset: u32) u8 {
    return if (offset < input.code_len) input.code[offset] else 0xff;
}

/// F3: classify every contested / unanchored position into the ruling's four
/// classes instead of only counting it. Runs after the reference walk so the
/// per-label role mask is complete.
///
/// The falsifiable arm is the PRODUCT OFFSET COMPARISON. Every competing owner
/// of an input position resolves to a product position: the label group
/// through `product_labels[..].bound_offset`, the source event through the
/// product source slot the resolver attached it to, the fold replacement
/// through the product offset captured at the replacing emission. Owners that
/// resolve apart are a genuine split (class A). Owners that always resolve
/// together are the same position named twice, and the class is then decided
/// by WHAT the competitor is: a debug marker (C), a fold replacement (D), or
/// another control-flow event (B).
fn classifyAnchorSplits(
    input: *const builder.Builder,
    binds: []const BindEntry,
    product_labels: []const labels.LabelSlot,
    product_sources: []const builder.SourceSlot,
    opt_bounds: []const OptimizationBoundary,
    role_masks: []const u8,
) void {
    if (comptime !audit_oracles) return;
    const input_sources = input.source_slots[0..input.source_len];

    // ---- population S: parser source events sitting on a bound offset.
    for (input_sources, 0..) |source, source_index| {
        if (canonicalIdentityAtOffset(binds, source.temp_offset) == null) continue;
        censusAdd(&boundary_fanout_census.unanchored_source_events, 1);

        const attached: ?u32 = if (source_index < product_sources.len) blk: {
            const product = product_sources[source_index];
            // Falsifiable: the resolver appends absorbed events in order, so
            // product slot i must be input slot i. If that ever stops holding
            // the comparison below is meaningless, and this counter says so.
            if (product.line != source.line or product.col != source.col) {
                censusAdd(&anchor_split_census.source_index_alignment_violations, 1);
                break :blk null;
            }
            break :blk product.temp_offset;
        } else null;
        const dropped = source_index >= product_sources.len;
        const label_product = boundaryProductOffset(binds, product_labels, source.temp_offset);
        const label_index = boundaryFirstLabel(binds, source.temp_offset);

        const source_survives = !dropped and attached != null;
        const case: AnchorCase = if (!source_survives and label_product == null)
            .c_boundary_fully_retired
        else if (!source_survives)
            .c_identity_outlives_source
        else if (label_product == null)
            .c_source_outlives_identity
        else if (attached.? == label_product.?)
            .c_source_coresident
        else
            .a_source_product_split;

        recordAnchorCase(case);
        recordAnchorExemplar(.{
            .case = case,
            .op_id = opAt(input, source.temp_offset),
            .fanout = boundaryFanoutAt(binds, source.temp_offset),
            .role_mask = boundaryRoleMask(binds, role_masks, source.temp_offset),
            .input_offset = source.temp_offset,
            .label_index = label_index,
            .label_product = label_product orelse labels.unbound,
            .other_product = attached orelse labels.unbound,
            .line = source.line,
            .col = source.col,
        });
    }

    // ---- population F: fold replacement anchors.
    for (opt_bounds) |boundary| {
        censusAdd(&boundary_fanout_census.unanchored_fold_replacements, 1);
        censusAdd(&anchor_split_census.fold_by_kind[@intFromEnum(boundary.kind)], 1);
        const contested = canonicalIdentityAtOffset(binds, boundary.replacement_start) != null;
        if (contested) {
            censusAdd(&boundary_fanout_census.contested_fold_replacements, 1);
            censusAdd(
                &anchor_split_census.fold_contested_by_kind[@intFromEnum(boundary.kind)],
                1,
            );
        }
        if (boundary.replacement_product == labels.unbound) {
            censusAdd(&anchor_split_census.fold_product_unknown, 1);
        }
        const label_product =
            boundaryProductOffset(binds, product_labels, boundary.replacement_start);
        const case: AnchorCase = if (!contested)
            .d_fold_uncontested
        else if (label_product == null or
            boundary.replacement_product == labels.unbound or
            label_product.? == boundary.replacement_product)
            .d_fold_contested_agree
        else
            .a_fold_product_split;

        recordAnchorCase(case);
        const site = nearestSourceSite(input_sources, boundary.replacement_start);
        recordAnchorExemplar(.{
            .case = case,
            .fold_kind = @intFromEnum(boundary.kind),
            .op_id = opAt(input, boundary.fold_start),
            .fanout = boundaryFanoutAt(binds, boundary.replacement_start),
            .role_mask = boundaryRoleMask(binds, role_masks, boundary.replacement_start),
            .input_offset = boundary.replacement_start,
            .label_index = boundaryFirstLabel(binds, boundary.replacement_start),
            .label_product = label_product orelse labels.unbound,
            .other_product = boundary.replacement_product,
            .line = site.line,
            .col = site.col,
        });
    }

    // ---- population B: one PC, several DISTINCT non-debug semantic events.
    var group_start: usize = 0;
    while (group_start < binds.len) {
        var group_end = group_start + 1;
        while (group_end < binds.len and
            binds[group_end].input_offset == binds[group_start].input_offset) : (group_end += 1)
        {}
        const group = binds[group_start..group_end];
        const input_offset = group[0].input_offset;
        group_start = group_end;

        var role_mask: u8 = 0;
        var barrier = false;
        var referenced = false;
        for (group) |entry| {
            if (entry.label_index >= product_labels.len) continue;
            role_mask |= role_masks[entry.label_index];
            const slot = product_labels[entry.label_index];
            if (slot.flags.match_barrier) barrier = true;
            if (slot.ref_count != 0) referenced = true;
        }
        const distinct_roles = @popCount(role_mask);
        const label_product = boundaryProductOffset(binds, product_labels, input_offset);
        const site = nearestSourceSite(input_sources, input_offset);
        const exemplar: AnchorExemplar = .{
            .case = .b_multi_role_boundary,
            .op_id = opAt(input, input_offset),
            .fanout = @intCast(group.len),
            .role_mask = role_mask,
            .input_offset = input_offset,
            .label_index = group[0].label_index,
            .label_product = label_product orelse labels.unbound,
            .other_product = label_product orelse labels.unbound,
            .line = site.line,
            .col = site.col,
        };

        if (distinct_roles >= 2) {
            recordAnchorCase(.b_multi_role_boundary);
            recordAnchorExemplar(exemplar);
        }
        if (barrier and referenced) {
            recordAnchorCase(.b_barrier_with_reference);
            var barrier_exemplar = exemplar;
            barrier_exemplar.case = .b_barrier_with_reference;
            recordAnchorExemplar(barrier_exemplar);
        }
        for (opt_bounds) |boundary| {
            if (boundary.consumed_end != input_offset) continue;
            recordAnchorCase(.b_boundary_is_fold_region_end);
            var region_exemplar = exemplar;
            region_exemplar.case = .b_boundary_is_fold_region_end;
            region_exemplar.fold_kind = @intFromEnum(boundary.kind);
            region_exemplar.other_product = boundary.replacement_product;
            recordAnchorExemplar(region_exemplar);
            break;
        }

        // The ruling's literal class-B example: a line marker, a fold
        // replacement and a label target on one PC.
        if (!hasSourceEventAt(input_sources, input_offset)) continue;
        for (opt_bounds) |boundary| {
            if (boundary.replacement_start != input_offset) continue;
            recordAnchorCase(.b_triple_owner_pc);
            var triple_exemplar = exemplar;
            triple_exemplar.case = .b_triple_owner_pc;
            triple_exemplar.fold_kind = @intFromEnum(boundary.kind);
            triple_exemplar.other_product = boundary.replacement_product;
            triple_exemplar.line = site.line;
            triple_exemplar.col = site.col;
            recordAnchorExemplar(triple_exemplar);
            break;
        }
    }
}

fn hasSourceEventAt(sources: []const builder.SourceSlot, offset: u32) bool {
    var lo: usize = 0;
    var hi = sources.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (sources[mid].temp_offset < offset) lo = mid + 1 else hi = mid;
    }
    return lo < sources.len and sources[lo].temp_offset == offset;
}

fn boundaryFanoutAt(binds: []const BindEntry, input_offset: u32) u32 {
    var index = lowerBoundBindOffset(binds, input_offset);
    var count: u32 = 0;
    while (index < binds.len and binds[index].input_offset == input_offset) : (index += 1) {
        count += 1;
    }
    return count;
}

fn boundaryRoleMask(
    binds: []const BindEntry,
    role_masks: []const u8,
    input_offset: u32,
) u8 {
    var index = lowerBoundBindOffset(binds, input_offset);
    var mask: u8 = 0;
    while (index < binds.len and binds[index].input_offset == input_offset) : (index += 1) {
        if (binds[index].label_index < role_masks.len) mask |= role_masks[binds[index].label_index];
    }
    return mask;
}

/// Debug/ReleaseSafe input-coordinate proof obligation: one semantic boundary
/// may carry same-offset aliases, but the resolver and every live reference
/// must retain one stable canonical identity for that boundary.
pub fn auditBoundaryUniqueness(
    memory: *core.memory.MemoryAccount,
    input: *const builder.Builder,
    graph: *const Graph,
    binds: []const BindEntry,
    product_labels: []const labels.LabelSlot,
    product_sources: []const builder.SourceSlot,
    opt_bounds: []const OptimizationBoundary,
) Error!void {
    try validateBoundaryAuditInput(input, graph, binds, product_labels);

    const boundary_count = std.math.add(usize, @as(usize, input.code_len), 1) catch
        return error.OutOfMemory;
    const word_count = try bitWordCount(boundary_count);
    const starts_words = memory.alloc(usize, word_count) catch
        return error.OutOfMemory;
    defer memory.free(usize, starts_words);
    @memset(starts_words, 0);

    var pc: u32 = 0;
    var atom_index: u32 = 0;
    while (pc < input.code_len) {
        const instruction = try tempInstruction(
            input.code[0..input.code_len],
            input.atom_operands[0..input.atom_len],
            pc,
            atom_index,
        );
        setBit(starts_words, @intCast(pc));
        try validateAndAdvanceAtom(input, pc, instruction, &atom_index);
        pc = std.math.add(u32, pc, instruction.size) catch
            return error.InvalidBytecode;
    }
    if (pc != input.code_len or atom_index != input.atom_len)
        return error.InvalidBytecode;
    setBit(starts_words, @intCast(input.code_len));

    var group_start: usize = 0;
    while (group_start < binds.len) {
        var group_end = group_start + 1;
        while (group_end < binds.len and
            binds[group_end].input_offset == binds[group_start].input_offset) : (group_end += 1)
        {}
        const group = binds[group_start..group_end];
        const input_offset = group[0].input_offset;
        recordFanout(group.len);

        if (aliasGroupSplit(group, product_labels)) |split| {
            var key_buffer: [256]u8 = undefined;
            var key_writer = std.Io.Writer.fixed(&key_buffer);
            key_writer.print(
                "boundary={d}:alias_group product_offsets={d},{d}",
                .{ input_offset, split.first_offset, split.second_offset },
            ) catch unreachable;
            return boundaryViolation(
                .boundary_mismatch,
                input,
                graph,
                binds,
                "alias_offset_split",
                .position,
                input_offset,
                key_writer.buffered(),
                .{
                    .{ .kind = "label", .index = split.first_label, .offset = split.first_offset },
                    .{ .kind = "label", .index = split.second_label, .offset = split.second_offset },
                },
            );
        }

        const block_index = findBlockStart(graph.block_starts, input_offset) orelse
            return error.InvalidBytecode;
        const reachable = graph.isReachable(block_index);
        for (group) |entry| {
            const slot = product_labels[entry.label_index];
            if (slot.flags.bound) continue;
            const sibling = survivingSibling(group, product_labels, entry.label_index);
            const sibling_index = sibling orelse group[0].label_index;
            if (slot.ref_count != 0 or slot.first_reloc != labels.no_reloc) {
                var key_buffer: [256]u8 = undefined;
                var key_writer = std.Io.Writer.fixed(&key_buffer);
                key_writer.print(
                    "boundary={d}:retired ref_count={d} first_reloc={d}",
                    .{ input_offset, slot.ref_count, slot.first_reloc },
                ) catch unreachable;
                return boundaryViolation(
                    .binding_mismatch,
                    input,
                    graph,
                    binds,
                    "retired_identity_still_referenced",
                    .position,
                    input_offset,
                    key_writer.buffered(),
                    .{
                        .{ .kind = "retired_label", .index = entry.label_index, .offset = input_offset },
                        .{ .kind = "boundary_label", .index = sibling_index, .offset = input_offset },
                    },
                );
            }
            if (reachable and slot.flags.match_barrier) {
                var key_buffer: [192]u8 = undefined;
                var key_writer = std.Io.Writer.fixed(&key_buffer);
                key_writer.print(
                    "boundary={d}:retired_match_barrier reachable=true",
                    .{input_offset},
                ) catch unreachable;
                return boundaryViolation(
                    .binding_mismatch,
                    input,
                    graph,
                    binds,
                    "retired_barrier_in_live_block",
                    .position,
                    input_offset,
                    key_writer.buffered(),
                    .{
                        .{ .kind = "retired_label", .index = entry.label_index, .offset = input_offset },
                        .{ .kind = "boundary_label", .index = sibling_index, .offset = input_offset },
                    },
                );
            }
        }
        group_start = group_end;
    }

    for (binds) |entry| {
        if (!isInstructionStart(starts_words, input.code_len, entry.input_offset)) {
            var key_buffer: [160]u8 = undefined;
            var key_writer = std.Io.Writer.fixed(&key_buffer);
            key_writer.print(
                "label_boundary={d}:instruction_alignment",
                .{entry.input_offset},
            ) catch unreachable;
            return boundaryViolation(
                .boundary_mismatch,
                input,
                graph,
                binds,
                "boundary_not_instruction_start",
                .position,
                entry.input_offset,
                key_writer.buffered(),
                .{
                    .{ .kind = "label", .index = entry.label_index, .offset = entry.input_offset },
                    .{ .kind = "instruction_start", .index = null, .offset = entry.input_offset },
                },
            );
        }
    }
    for (input.source_slots[0..input.source_len], 0..) |source, source_index| {
        if (!isInstructionStart(starts_words, input.code_len, source.temp_offset)) {
            var key_buffer: [160]u8 = undefined;
            var key_writer = std.Io.Writer.fixed(&key_buffer);
            key_writer.print(
                "source_event={d}:instruction_alignment",
                .{source_index},
            ) catch unreachable;
            return boundaryViolation(
                .source_event_mismatch,
                input,
                graph,
                binds,
                "boundary_not_instruction_start",
                .source_attribution,
                source.temp_offset,
                key_writer.buffered(),
                .{
                    .{ .kind = "source_event", .index = @intCast(source_index), .offset = source.temp_offset },
                    .{ .kind = "instruction_start", .index = null, .offset = source.temp_offset },
                },
            );
        }
    }

    for (opt_bounds) |boundary| {
        if (boundary.fold_start > boundary.replacement_start or
            boundary.replacement_start > boundary.consumed_end or
            boundary.consumed_end > input.code_len)
        {
            var key_buffer: [256]u8 = undefined;
            var key_writer = std.Io.Writer.fixed(&key_buffer);
            key_writer.print(
                "fold={s}:{d}..{d}:replacement={d}",
                .{
                    @tagName(boundary.kind),
                    boundary.fold_start,
                    boundary.consumed_end,
                    boundary.replacement_start,
                },
            ) catch unreachable;
            return boundaryViolation(
                .boundary_mismatch,
                input,
                graph,
                binds,
                "invalid_fold_range",
                .fold_replacement,
                boundary.fold_start,
                key_writer.buffered(),
                .{
                    .{
                        .kind = "fold_region",
                        .index = @intCast(@intFromEnum(boundary.kind)),
                        .offset = boundary.fold_start,
                    },
                    .{
                        .kind = "fold_replacement",
                        .index = @intCast(@intFromEnum(boundary.kind)),
                        .offset = boundary.replacement_start,
                    },
                },
            );
        }
        const positions = [_]struct { offset: u32, name: []const u8 }{
            .{ .offset = boundary.fold_start, .name = "fold_start" },
            .{ .offset = boundary.replacement_start, .name = "replacement_start" },
            .{ .offset = boundary.consumed_end, .name = "consumed_end" },
        };
        for (positions) |position| {
            if (!isInstructionStart(starts_words, input.code_len, position.offset)) {
                var key_buffer: [192]u8 = undefined;
                var key_writer = std.Io.Writer.fixed(&key_buffer);
                key_writer.print(
                    "fold={s}:{s}:instruction_alignment",
                    .{ @tagName(boundary.kind), position.name },
                ) catch unreachable;
                return boundaryViolation(
                    .boundary_mismatch,
                    input,
                    graph,
                    binds,
                    "boundary_not_instruction_start",
                    .fold_replacement,
                    boundary.fold_start,
                    key_writer.buffered(),
                    .{
                        .{
                            .kind = "fold_region",
                            .index = @intCast(@intFromEnum(boundary.kind)),
                            .offset = position.offset,
                        },
                        .{ .kind = "instruction_start", .index = null, .offset = position.offset },
                    },
                );
            }
        }
    }

    if (opt_bounds.len != 0) {
        const sorted_bounds = memory.alloc(OptimizationBoundary, opt_bounds.len) catch
            return error.OutOfMemory;
        defer memory.free(OptimizationBoundary, sorted_bounds);
        @memcpy(sorted_bounds, opt_bounds);
        std.mem.sort(OptimizationBoundary, sorted_bounds, {}, optimizationBoundaryLessThan);
        if (duplicateReplacementOwner(sorted_bounds)) |duplicate| {
            var key_buffer: [384]u8 = undefined;
            var key_writer = std.Io.Writer.fixed(&key_buffer);
            key_writer.print(
                "replacement={d}:owners={s}:{d}..{d},{s}:{d}..{d}",
                .{
                    duplicate.first.replacement_start,
                    @tagName(duplicate.first.kind),
                    duplicate.first.fold_start,
                    duplicate.first.consumed_end,
                    @tagName(duplicate.second.kind),
                    duplicate.second.fold_start,
                    duplicate.second.consumed_end,
                },
            ) catch unreachable;
            return boundaryViolation(
                .boundary_mismatch,
                input,
                graph,
                binds,
                "duplicate_replacement_owner",
                .fold_replacement,
                duplicate.first.fold_start,
                key_writer.buffered(),
                .{
                    .{
                        .kind = "fold_region",
                        .index = @intCast(@intFromEnum(duplicate.first.kind)),
                        .offset = duplicate.first.replacement_start,
                    },
                    .{
                        .kind = "fold_region",
                        .index = @intCast(@intFromEnum(duplicate.second.kind)),
                        .offset = duplicate.second.replacement_start,
                    },
                },
            );
        }
    }

    for (opt_bounds) |boundary| {
        if (bindInsideFold(binds, boundary)) |buried| {
            var key_buffer: [256]u8 = undefined;
            var key_writer = std.Io.Writer.fixed(&key_buffer);
            key_writer.print(
                "fold={s}:{d}..{d}:buried_label={d}",
                .{
                    @tagName(boundary.kind),
                    boundary.fold_start,
                    boundary.consumed_end,
                    buried.bind.label_index,
                },
            ) catch unreachable;
            return boundaryViolation(
                .boundary_mismatch,
                input,
                graph,
                binds,
                "bind_inside_fold",
                .fold_replacement,
                boundary.fold_start,
                key_writer.buffered(),
                .{
                    .{
                        .kind = "fold_region",
                        .index = @intCast(@intFromEnum(boundary.kind)),
                        .offset = boundary.replacement_start,
                    },
                    .{
                        .kind = "label",
                        .index = buried.bind.label_index,
                        .offset = buried.bind.input_offset,
                    },
                },
            );
        }
    }

    // builder.SourceSlot carries no anchor_label and OptimizationBoundary
    // carries no replacement_label; the unanchored / contested counters live
    // in classifyAnchorSplits below, which also decides what KIND of exposure
    // each of them is (F3, anchor-split classification, 2026 campaign report in git history).
    const role_masks: []u8 = if (comptime audit_oracles)
        memory.alloc(u8, product_labels.len) catch return error.OutOfMemory
    else
        &.{};
    defer if (comptime audit_oracles) memory.free(u8, role_masks);
    if (comptime audit_oracles) @memset(role_masks, 0);

    const instruction_claimed_words: []usize = if (comptime audit_oracles)
        memory.alloc(usize, word_count) catch return error.OutOfMemory
    else
        &.{};
    defer if (comptime audit_oracles) memory.free(usize, instruction_claimed_words);
    const control_flow_claimed_words: []usize = if (comptime audit_oracles)
        memory.alloc(usize, word_count) catch return error.OutOfMemory
    else
        &.{};
    defer if (comptime audit_oracles) memory.free(usize, control_flow_claimed_words);
    const optimization_claimed_words: []usize = if (comptime audit_oracles)
        memory.alloc(usize, word_count) catch return error.OutOfMemory
    else
        &.{};
    defer if (comptime audit_oracles) memory.free(usize, optimization_claimed_words);
    const debug_claimed_words: []usize = if (comptime audit_oracles)
        memory.alloc(usize, word_count) catch return error.OutOfMemory
    else
        &.{};
    defer if (comptime audit_oracles) memory.free(usize, debug_claimed_words);
    const any_claimed_words: []usize = if (comptime audit_oracles)
        memory.alloc(usize, word_count) catch return error.OutOfMemory
    else
        &.{};
    defer if (comptime audit_oracles) memory.free(usize, any_claimed_words);
    const semantic_claimed_words: []usize = if (comptime audit_oracles)
        memory.alloc(usize, word_count) catch return error.OutOfMemory
    else
        &.{};
    defer if (comptime audit_oracles) memory.free(usize, semantic_claimed_words);

    var accounting: BoundaryReportAccounting = if (comptime audit_oracles) blk: {
        @memset(instruction_claimed_words, 0);
        @memset(control_flow_claimed_words, 0);
        @memset(optimization_claimed_words, 0);
        @memset(debug_claimed_words, 0);
        @memset(any_claimed_words, 0);
        @memset(semantic_claimed_words, 0);
        break :blk .{
            .category_words = .{
                instruction_claimed_words,
                control_flow_claimed_words,
                optimization_claimed_words,
                debug_claimed_words,
            },
            .any_words = any_claimed_words,
            .semantic_words = semantic_claimed_words,
        };
    } else .{};

    pc = 0;
    atom_index = 0;
    var label_reference_count: u32 = 0;
    while (pc < input.code_len) {
        const instruction = try tempInstruction(
            input.code[0..input.code_len],
            input.atom_operands[0..input.atom_len],
            pc,
            atom_index,
        );
        const next = std.math.add(u32, pc, instruction.size) catch
            return error.InvalidBytecode;
        try validateAndAdvanceAtom(input, pc, instruction, &atom_index);

        const op_id = input.code[pc];
        if (comptime audit_oracles) {
            accounting.claim(.instruction, pc, binds, starts_words, input.code_len);
            if (isUnconditionalTerminal(op_id)) {
                accounting.claim(.control_flow, pc, binds, starts_words, input.code_len);
            }
            if (isContinuationOp(op_id)) accounting.continuations += 1;

            while (accounting.block_index + 1 < graph.block_starts.len and
                graph.block_starts[accounting.block_index + 1] <= pc)
            {
                accounting.block_index += 1;
            }
            if (accounting.block_index >= graph.blocks.len or
                graph.block_starts[accounting.block_index] > pc)
            {
                return error.InvalidBytecode;
            }
            if (instruction.has_atom) {
                const block = graph.blocks[accounting.block_index];
                const live = graph.isReachable(accounting.block_index) and
                    (!block.has_terminal or pc <= block.cutoff_offset);
                if (live)
                    accounting.ownership_transfer += 1
                else
                    accounting.ownership_release += 1;
            }
        }
        if (labelOperandOffset(op_id, instruction)) |operand_offset| {
            if (label_reference_count == std.math.maxInt(u32))
                return error.InvalidBytecode;
            label_reference_count += 1;
            const label_index = try readLabelIndex(input, pc, instruction, operand_offset);
            const role = roleForLabelOperand(op_id, instruction);
            if (comptime audit_oracles) {
                if (label_index < role_masks.len) {
                    role_masks[label_index] |= @as(u8, 1) << @intCast(@intFromEnum(role));
                }
            }
            const input_slot = input.label_slots[label_index];
            // validateBindIndex proves label_slots[i].bound_offset is exactly
            // the offset of i's bind row, so every identity lookup below is a
            // bisection on that offset rather than a scan for the row. The
            // walk visits every reference, so a scan here would be quadratic.
            const bound_offset: ?u32 = if (input_slot.flags.bound)
                input_slot.bound_offset
            else
                null;
            recordChainDepth(if (bound_offset) |offset|
                referenceChainDepth(binds, product_labels, label_index, offset)
            else
                1);

            const owner = (if (bound_offset) |offset|
                canonicalIdentityAtOffset(binds, offset)
            else
                null) orelse {
                var key_buffer: [192]u8 = undefined;
                var key_writer = std.Io.Writer.fixed(&key_buffer);
                key_writer.print(
                    "reference_pc={d}:raw_label={d}:no_bound_identity",
                    .{ pc, label_index },
                ) catch unreachable;
                return boundaryViolation(
                    .binding_mismatch,
                    input,
                    graph,
                    binds,
                    "jump_target_identity_unbound",
                    role,
                    pc,
                    key_writer.buffered(),
                    .{
                        .{ .kind = "operand_label", .index = label_index, .offset = pc },
                        .{ .kind = "boundary_label", .index = null, .offset = input_slot.bound_offset },
                    },
                );
            };
            if (comptime audit_oracles) {
                accounting.claim(
                    .control_flow,
                    input_slot.bound_offset,
                    binds,
                    starts_words,
                    input.code_len,
                );
            }

            // Do not compare `owner` with canonicalIdentityAtOffset(binds,
            // input_slot.bound_offset): validateBindIndex proves that both
            // expressions select the same bind run, so that comparison cannot
            // fail for a valid input. SourceSlot and OptimizationBoundary have
            // no independent LabelId yet (R1/R2 count those gaps). The product
            // survivor comparison below is today's falsifiable E4 arm.

            if (referenceToRetiredAlias(
                binds,
                product_labels,
                label_index,
                bound_offset orelse input_slot.bound_offset,
            )) |split| {
                if (try referencingInstructionIsLive(graph, pc)) {
                    var key_buffer: [288]u8 = undefined;
                    var key_writer = std.Io.Writer.fixed(&key_buffer);
                    key_writer.print(
                        "reference_pc={d}:canonical={d}:products={d},{d}",
                        .{
                            pc,
                            owner,
                            product_labels[split.retired_label].bound_offset,
                            split.surviving_product_offset,
                        },
                    ) catch unreachable;
                    return boundaryViolation(
                        .binding_mismatch,
                        input,
                        graph,
                        binds,
                        "reference_to_retired_alias",
                        role,
                        pc,
                        key_writer.buffered(),
                        .{
                            .{
                                .kind = "retired_operand_label",
                                .index = split.retired_label,
                                .offset = split.input_offset,
                            },
                            .{
                                .kind = "surviving_boundary_label",
                                .index = split.surviving_label,
                                .offset = split.input_offset,
                            },
                        },
                    );
                }
            }
        }
        pc = next;
    }
    if (pc != input.code_len or atom_index != input.atom_len or
        label_reference_count != input.reloc_len)
    {
        return error.InvalidBytecode;
    }

    if (comptime audit_oracles) {
        accounting.claim(.instruction, input.code_len, binds, starts_words, input.code_len);
        for (opt_bounds) |boundary| {
            accounting.claim(.optimization, boundary.fold_start, binds, starts_words, input.code_len);
            accounting.claim(
                .optimization,
                boundary.replacement_start,
                binds,
                starts_words,
                input.code_len,
            );
            accounting.claim(.optimization, boundary.consumed_end, binds, starts_words, input.code_len);
        }
        for (input.source_slots[0..input.source_len]) |source| {
            accounting.claim(.debug, source.temp_offset, binds, starts_words, input.code_len);
        }

        var extra_boundaries: u64 = 0;
        var report_group_start: usize = 0;
        while (report_group_start < binds.len) {
            const input_offset = binds[report_group_start].input_offset;
            if (!bitIsSet(accounting.semantic_words, @intCast(input_offset))) {
                extra_boundaries += 1;
            }
            report_group_start += 1;
            while (report_group_start < binds.len and
                binds[report_group_start].input_offset == input_offset)
            {
                report_group_start += 1;
            }
        }

        var legacy_boundaries: u64 = 0;
        var duplicated_boundaries: u64 = 0;
        for (accounting.claims, accounting.distinct) |claims, distinct| {
            legacy_boundaries += claims;
            duplicated_boundaries += claims - distinct;
        }

        reportAdd("legacy_boundaries", legacy_boundaries);
        reportAdd("v2_boundaries", accounting.v2_distinct);
        reportAdd("missing_boundaries", accounting.missing);
        reportAdd("extra_boundaries", extra_boundaries);
        reportAdd("duplicated_boundaries", duplicated_boundaries);
        reportAdd("instruction_claims", accounting.claims[@intFromEnum(BoundaryClaimCategory.instruction)]);
        reportAdd("control_flow_claims", accounting.claims[@intFromEnum(BoundaryClaimCategory.control_flow)]);
        reportAdd("optimization_claims", accounting.claims[@intFromEnum(BoundaryClaimCategory.optimization)]);
        reportAdd("debug_claims", accounting.claims[@intFromEnum(BoundaryClaimCategory.debug)]);

        const ownership_create: u64 = input.atom_len;
        reportAdd("ownership_create", ownership_create);
        reportAdd("ownership_transfer", accounting.ownership_transfer);
        reportAdd("ownership_release", accounting.ownership_release);
        if (accounting.ownership_transfer + accounting.ownership_release != ownership_create) {
            reportAdd("ownership_unbalanced", 1);
        }

        reportAdd("control_blocks", @intCast(graph.blocks.len));
        reportAdd("control_edges", @intCast(graph.edge_len));
        reportAdd("control_continuations", accounting.continuations);
    }

    classifyAnchorSplits(
        input,
        binds,
        product_labels,
        product_sources,
        opt_bounds,
        role_masks,
    );
}

test "compiler_v2.cfg: unreachable self-loop does not retain its block" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var input = builder.Builder.init(&rt.memory, &rt.atoms);
    defer input.deinit();
    const dead = try input.newLabel();
    const merge = try input.newLabel();
    try input.emitJump(op.if_false, merge);
    try input.emitOp(op.return_undef);
    try input.bindLabel(dead);
    try input.emitJump(op.goto, dead);
    try input.bindLabel(merge);
    try input.emitOp(op.return_undef);

    var binds = [_]BindEntry{
        .{ .input_offset = input.label_slots[dead.index()].bound_offset, .label_index = dead.index() },
        .{ .input_offset = input.label_slots[merge.index()].bound_offset, .label_index = merge.index() },
    };
    std.mem.sort(BindEntry, &binds, {}, bindLessThan);

    var graph = try build(&rt.memory, &input, &binds);
    defer graph.deinit();
    try std.testing.expectEqualSlices(u32, &.{ 0, 6, 11, 12 }, graph.block_starts);
    try std.testing.expect(graph.isReachable(0));
    try std.testing.expect(!graph.isReachable(1));
    try std.testing.expect(graph.isReachable(2));
    try std.testing.expect(!graph.isReachable(3));
    try std.testing.expectEqual(@as(u32, 5), graph.blocks[0].cutoff_offset);
    try std.testing.expect(graph.blocks[0].has_terminal);
    try std.testing.expectEqualSlices(usize, &.{2}, graph.edgesForBlock(0));
    try std.testing.expectEqualSlices(usize, &.{1}, graph.edgesForBlock(1));
    try auditInstructionOwnership(&rt.memory, &input, &graph);
}

test "compiler_v2.cfg: alias group coalescing is downstream-indistinguishable" {
    resetFanoutCensus();
    defer resetFanoutCensus();

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var input = builder.Builder.init(&rt.memory, &rt.atoms);
    defer input.deinit();
    const first = try input.newLabel();
    const alias = try input.newLabel();
    try input.emitJump(op.if_false, first);
    try input.emitOp(op.return_undef);
    try input.bindLabel(first);
    try input.bindLabel(alias);
    try input.emitOp(op.return_undef);

    var binds = [_]BindEntry{
        .{
            .input_offset = input.label_slots[first.index()].bound_offset,
            .label_index = first.index(),
        },
        .{
            .input_offset = input.label_slots[alias.index()].bound_offset,
            .label_index = alias.index(),
        },
    };
    std.mem.sort(BindEntry, &binds, {}, bindLessThan);

    var graph = try build(&rt.memory, &input, &binds);
    defer graph.deinit();
    var product_labels = [_]labels.LabelSlot{
        .{ .bound_offset = 11, .flags = .{ .bound = true } },
        .{ .bound_offset = 11, .flags = .{ .bound = true } },
    };
    try auditBoundaryUniqueness(
        &rt.memory,
        &input,
        &graph,
        &binds,
        &product_labels,
        &.{},
        &.{},
    );

    const census = fanoutCensusSnapshot();
    try std.testing.expectEqual(@as(u64, 1), census.semantic_boundaries);
    try std.testing.expectEqual(@as(u64, 2), census.identities);
    try std.testing.expectEqual(@as(u64, 1), census.coalesced_boundaries);
    try std.testing.expectEqual(@as(u64, 2), census.max_fanout);
    try std.testing.expectEqual(@as(u64, 1), census.fanout_buckets[1]);
    try std.testing.expectEqual(@as(u64, 1), census.chain_depth_samples);
    try std.testing.expectEqual(@as(u64, 3), census.chain_depth_total);
    try std.testing.expectEqual(@as(u64, 1), census.chain_depth_buckets[3]);

    var health_buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "identity kinds=5 instances=2 fan-out{mean=2.00 p95=2 max=2} chain{mean=3.00 p95=3 max=3 +final-hop=0} final-source{events=0 on-identity=0 between-identities=0} unanchored{source=0 fold=0 contested=0}",
        formatIdentityHealth(&health_buffer, census),
    );
}

/// Shared fixture for the anchor-split classification tests: one boundary at
/// input offset 6 carrying a bound label and a source marker.
const AnchorSplitFixture = struct {
    rt: *core.JSRuntime,
    input: builder.Builder,
    graph: Graph,
    binds: [1]BindEntry,

    fn init(self: *AnchorSplitFixture) !void {
        self.rt = try core.JSRuntime.create(std.testing.allocator);
        errdefer self.rt.destroy();
        self.input = builder.Builder.init(&self.rt.memory, &self.rt.atoms);
        errdefer self.input.deinit();
        const target = try self.input.newLabel();
        try self.input.emitJump(op.if_false, target);
        try self.input.emitOp(op.return_undef);
        try self.input.bindLabel(target);
        try self.input.addSourceMarker(10, 2);
        try self.input.emitOp(op.return_undef);
        self.binds = .{.{
            .input_offset = self.input.label_slots[target.index()].bound_offset,
            .label_index = target.index(),
        }};
        self.graph = try build(&self.rt.memory, &self.input, &self.binds);
    }

    fn deinit(self: *AnchorSplitFixture) void {
        self.graph.deinit();
        self.input.deinit();
        self.rt.destroy();
    }

    fn boundary(self: *const AnchorSplitFixture) u32 {
        return self.binds[0].input_offset;
    }
};

test "compiler_v2.cfg: class A arm fires when a source event resolves off its boundary" {
    resetFanoutCensus();
    resetAnchorSplitCensus();
    defer resetFanoutCensus();
    defer resetAnchorSplitCensus();
    if (comptime !audit_oracles) return;

    var fixture: AnchorSplitFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var product_labels = [_]labels.LabelSlot{.{ .bound_offset = 4, .flags = .{ .bound = true } }};
    // Same input offset, DIFFERENT product offsets: the split class A exists
    // to name. A=0 on the corpus is only evidence because this fires.
    const split_sources = [_]builder.SourceSlot{
        .{ .temp_offset = 9, .line = 10, .col = 2 },
    };
    try auditBoundaryUniqueness(
        &fixture.rt.memory,
        &fixture.input,
        &fixture.graph,
        &fixture.binds,
        &product_labels,
        &split_sources,
        &.{},
    );
    var census = anchorSplitSnapshot();
    try std.testing.expectEqual(
        @as(u64, 1),
        census.cases[@intFromEnum(AnchorCase.a_source_product_split)],
    );
    try std.testing.expectEqual(@as(u64, 1), anchorClassTotal(census, .a));

    // Negative control: the same fixture with the event on the boundary is C.
    resetAnchorSplitCensus();
    const agreeing_sources = [_]builder.SourceSlot{
        .{ .temp_offset = 4, .line = 10, .col = 2 },
    };
    try auditBoundaryUniqueness(
        &fixture.rt.memory,
        &fixture.input,
        &fixture.graph,
        &fixture.binds,
        &product_labels,
        &agreeing_sources,
        &.{},
    );
    census = anchorSplitSnapshot();
    try std.testing.expectEqual(@as(u64, 0), anchorClassTotal(census, .a));
    try std.testing.expectEqual(
        @as(u64, 1),
        census.cases[@intFromEnum(AnchorCase.c_source_coresident)],
    );
}

test "compiler_v2.cfg: class A arm fires when a fold replacement resolves off its boundary" {
    resetFanoutCensus();
    resetAnchorSplitCensus();
    defer resetFanoutCensus();
    defer resetAnchorSplitCensus();
    if (comptime !audit_oracles) return;

    var fixture: AnchorSplitFixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var product_labels = [_]labels.LabelSlot{.{ .bound_offset = 4, .flags = .{ .bound = true } }};
    const sources = [_]builder.SourceSlot{.{ .temp_offset = 4, .line = 10, .col = 2 }};
    const split_bounds = [_]OptimizationBoundary{.{
        .kind = .dup_branch_fold,
        .fold_start = fixture.boundary(),
        .consumed_end = fixture.input.code_len,
        .replacement_start = fixture.boundary(),
        .replacement_product = 7,
    }};
    try auditBoundaryUniqueness(
        &fixture.rt.memory,
        &fixture.input,
        &fixture.graph,
        &fixture.binds,
        &product_labels,
        &sources,
        &split_bounds,
    );
    var census = anchorSplitSnapshot();
    try std.testing.expectEqual(
        @as(u64, 1),
        census.cases[@intFromEnum(AnchorCase.a_fold_product_split)],
    );
    try std.testing.expectEqual(@as(u64, 1), anchorClassTotal(census, .a));
    try std.testing.expectEqual(@as(u64, 0), census.fold_product_unknown);

    // The same fold agreeing with the boundary is class D, not class A.
    resetAnchorSplitCensus();
    const agreeing_bounds = [_]OptimizationBoundary{.{
        .kind = .dup_branch_fold,
        .fold_start = fixture.boundary(),
        .consumed_end = fixture.input.code_len,
        .replacement_start = fixture.boundary(),
        .replacement_product = 4,
    }};
    try auditBoundaryUniqueness(
        &fixture.rt.memory,
        &fixture.input,
        &fixture.graph,
        &fixture.binds,
        &product_labels,
        &sources,
        &agreeing_bounds,
    );
    census = anchorSplitSnapshot();
    try std.testing.expectEqual(@as(u64, 0), anchorClassTotal(census, .a));
    try std.testing.expectEqual(
        @as(u64, 1),
        census.cases[@intFromEnum(AnchorCase.d_fold_contested_agree)],
    );
    // One PC owning a line marker, a label target and a fold replacement is
    // the ruling's class B example.
    try std.testing.expectEqual(
        @as(u64, 1),
        census.cases[@intFromEnum(AnchorCase.b_triple_owner_pc)],
    );
}

test "compiler_v2.cfg: oracle report counts boundary categories" {
    resetOracleReport();
    defer resetOracleReport();
    if (comptime !audit_oracles) return;

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var input = builder.Builder.init(&rt.memory, &rt.atoms);
    defer input.deinit();
    const target = try input.newLabel();
    try input.emitJump(op.if_false, target);
    try input.emitOp(op.return_undef);
    try input.bindLabel(target);
    try input.addSourceMarker(10, 2);
    try input.emitOp(op.return_undef);

    var binds = [_]BindEntry{.{
        .input_offset = input.label_slots[target.index()].bound_offset,
        .label_index = target.index(),
    }};
    var graph = try build(&rt.memory, &input, &binds);
    defer graph.deinit();
    var product_labels = [_]labels.LabelSlot{.{
        .bound_offset = input.label_slots[target.index()].bound_offset,
        .flags = .{ .bound = true },
    }};
    try auditBoundaryUniqueness(
        &rt.memory,
        &input,
        &graph,
        &binds,
        &product_labels,
        &.{},
        &.{},
    );

    const report = oracleReportSnapshot();
    // Instruction starts are 0, 5, and 6, plus sentinel 7: four claims and
    // four union offsets. Control flow claims target 6 and terminals 5 and 6:
    // three claims over two offsets, hence one duplicate. The source marker
    // contributes one debug claim at 6; there are no optimization claims.
    try std.testing.expectEqual(@as(u64, 8), report.legacy_boundaries);
    try std.testing.expectEqual(@as(u64, 4), report.v2_boundaries);
    try std.testing.expectEqual(@as(u64, 0), report.missing_boundaries);
    try std.testing.expectEqual(@as(u64, 0), report.extra_boundaries);
    try std.testing.expectEqual(@as(u64, 1), report.duplicated_boundaries);
    try std.testing.expectEqual(@as(u64, 4), report.instruction_claims);
    try std.testing.expectEqual(@as(u64, 3), report.control_flow_claims);
    try std.testing.expectEqual(@as(u64, 0), report.optimization_claims);
    try std.testing.expectEqual(@as(u64, 1), report.debug_claims);
}

test "compiler_v2.cfg: oracle report formats summary then diff buckets" {
    resetOracleReport();
    defer resetOracleReport();
    if (comptime !audit_oracles) return;

    const report: OracleReport = .{
        .legacy_boundaries = 101,
        .v2_boundaries = 102,
        .missing_boundaries = 103,
        .extra_boundaries = 104,
        .duplicated_boundaries = 105,
        .instruction_claims = 201,
        .control_flow_claims = 202,
        .optimization_claims = 203,
        .debug_claims = 204,
        .ownership_create = 301,
        .ownership_transfer = 302,
        .ownership_release = 303,
        .ownership_unbalanced = 304,
        .control_blocks = 401,
        .control_edges = 402,
        .control_continuations = 403,
        .buckets = .{ 501, 502, 503, 504, 505, 506 },
    };
    var buffer: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(
        \\ZJS-V2-ORACLE-REPORT
        \\Summary:
        \\  boundaries: legacy=101 v2=102 missing=103 extra=104 duplicated=105
        \\  boundary categories: instruction=201 control-flow=202 optimization=203 debug=204
        \\  ownership events: create=301 transfer=302 release=303
        \\  atom balanced: no
        \\  control totals: blocks=401 edges=402 continuations=403
        \\Diff buckets:
        \\  BOUNDARY_MISMATCH=501
        \\  OWNERSHIP_MISMATCH=502
        \\  BINDING_MISMATCH=503
        \\  CFG_MISMATCH=504
        \\  CONTINUATION_MISMATCH=505
        \\  SOURCE_EVENT_MISMATCH=506
        \\
    , formatOracleReport(&buffer, report));
}

test "compiler_v2.cfg: diff bucket names are the ruling's six" {
    resetOracleReport();
    defer resetOracleReport();

    try std.testing.expectEqualStrings("BOUNDARY_MISMATCH", DiffBucket.boundary_mismatch.name());
    try std.testing.expectEqualStrings("OWNERSHIP_MISMATCH", DiffBucket.ownership_mismatch.name());
    try std.testing.expectEqualStrings("BINDING_MISMATCH", DiffBucket.binding_mismatch.name());
    try std.testing.expectEqualStrings("CFG_MISMATCH", DiffBucket.cfg_mismatch.name());
    try std.testing.expectEqualStrings(
        "CONTINUATION_MISMATCH",
        DiffBucket.continuation_mismatch.name(),
    );
    try std.testing.expectEqualStrings(
        "SOURCE_EVENT_MISMATCH",
        DiffBucket.source_event_mismatch.name(),
    );
}

test "compiler_v2.cfg: split alias identities are rejected" {
    const binds = [_]BindEntry{
        .{ .input_offset = 4, .label_index = 0 },
        .{ .input_offset = 4, .label_index = 1 },
    };
    const product_labels = [_]labels.LabelSlot{
        .{ .bound_offset = 9, .flags = .{ .bound = true } },
        .{ .bound_offset = 10, .flags = .{ .bound = true } },
    };
    const split = aliasGroupSplit(&binds, &product_labels) orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u32, 0), split.first_label);
    try std.testing.expectEqual(@as(u32, 9), split.first_offset);
    try std.testing.expectEqual(@as(u32, 1), split.second_label);
    try std.testing.expectEqual(@as(u32, 10), split.second_offset);
}

test "compiler_v2.cfg: fold spans record one replacement identity each" {
    const unique = [_]OptimizationBoundary{
        .{
            .kind = .make_ref_head,
            .fold_start = 0,
            .consumed_end = 5,
            .replacement_start = 0,
        },
        .{
            .kind = .make_ref_tail,
            .fold_start = 8,
            .consumed_end = 10,
            .replacement_start = 8,
        },
    };
    try std.testing.expect(duplicateReplacementOwner(&unique) == null);

    const duplicate = [_]OptimizationBoundary{
        unique[0],
        .{
            .kind = .gosub_empty,
            .fold_start = 0,
            .consumed_end = 5,
            .replacement_start = 0,
        },
    };
    const owners = duplicateReplacementOwner(&duplicate) orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(OptimizationBoundaryKind.make_ref_head, owners.first.kind);
    try std.testing.expectEqual(OptimizationBoundaryKind.gosub_empty, owners.second.kind);
}

test "compiler_v2.cfg: bind strictly inside a fold is rejected" {
    const binds = [_]BindEntry{
        .{ .input_offset = 0, .label_index = 0 },
        .{ .input_offset = 4, .label_index = 1 },
        .{ .input_offset = 8, .label_index = 2 },
    };
    const enclosing: OptimizationBoundary = .{
        .kind = .dup_branch_fold,
        .fold_start = 0,
        .consumed_end = 8,
        .replacement_start = 0,
    };
    const buried = bindInsideFold(&binds, enclosing) orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u32, 1), buried.bind.label_index);

    const ending_at_bind: OptimizationBoundary = .{
        .kind = .dup_branch_fold,
        .fold_start = 0,
        .consumed_end = 4,
        .replacement_start = 0,
    };
    try std.testing.expect(bindInsideFold(&binds, ending_at_bind) == null);
}

test "compiler_v2.cfg: canonical identity collapses aliases but not boundaries" {
    const binds = [_]BindEntry{
        .{ .input_offset = 3, .label_index = 0 },
        .{ .input_offset = 3, .label_index = 1 },
        .{ .input_offset = 7, .label_index = 2 },
    };
    const later_product = [_]labels.LabelSlot{
        .{ .bound_offset = 19, .flags = .{ .bound = true } },
        .{ .bound_offset = 19, .flags = .{ .bound = true } },
        .{ .bound_offset = 19, .flags = .{ .bound = true } },
    };

    const first = canonicalBoundaryIdentity(&binds, 0).?;
    const alias = canonicalBoundaryIdentity(&binds, 1).?;
    const distinct = canonicalBoundaryIdentity(&binds, 2).?;
    try std.testing.expectEqual(first, alias);
    try std.testing.expect(first != distinct);
    // Same later address is not a defence: input-coordinate canonical
    // identities remain distinct across the two semantic boundaries.
    try std.testing.expectEqual(
        later_product[first].bound_offset,
        later_product[distinct].bound_offset,
    );
}

test "compiler_v2.cfg: a reference naming a retired alias is a split" {
    const binds = [_]BindEntry{
        .{ .input_offset = 6, .label_index = 0 },
        .{ .input_offset = 6, .label_index = 1 },
    };
    const product_labels = [_]labels.LabelSlot{
        .{},
        .{ .bound_offset = 12, .flags = .{ .bound = true } },
    };
    const split = referenceToRetiredAlias(&binds, &product_labels, 0, 6) orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u32, 0), split.retired_label);
    try std.testing.expectEqual(@as(u32, 1), split.surviving_label);
    try std.testing.expectEqual(@as(u32, 6), split.input_offset);
    try std.testing.expect(referenceToRetiredAlias(&binds, &product_labels, 1, 6) == null);
}

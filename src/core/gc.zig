//! Z-GE (Garbage Engine) Core Implementation
//! Governing Layer: third_party/zjs/src/core/gc.zig
//! Following Z-GE Architecture Contract v1.0

const std = @import("std");
pub const representation = @import("gc_representation_constants.zig");
const builtin = @import("builtin");
const build_options = @import("build_options");
const memory = @import("memory.zig");
const bigint = @import("bigint.zig");
const object = @import("object.zig");
const class = @import("class.zig");
const property = @import("property.zig");
const context_mod = @import("context.zig");
const module_mod = @import("module.zig");
const var_ref = @import("var_ref.zig");
const string = @import("string.zig");
const function_bytecode_mod = @import("../bytecode.zig").function_bytecode;
const FunctionBytecode = function_bytecode_mod.FunctionBytecode;
const shape = @import("shape.zig");
const JSValue = @import("value.zig").JSValue;

const KB: usize = 1024;
const MB: usize = 1024 * KB;

/// `-Dzjs_gc=shadow` compiles the non-reclaiming observer in `gc_shadow.zig`.
/// Default `rc` keeps this false so the observer is not imported and the
/// production collector's machine code is unchanged.
pub const shadow_tracer_enabled: bool = std.mem.eql(u8, build_options.zjs_gc, "shadow");

/// `-Dzjs_experimental_gc=trace_stw` compiles the stop-the-world reclaiming tracer
/// (`gc_trace_stw.zig`) over the compatibility heap. Mutually exclusive with
/// `shadow`. Default `rc` stays false so production `.text` is unchanged.
pub const trace_stw_enabled: bool = std.mem.eql(u8, build_options.zjs_gc, "trace_stw");

/// Full-every-2 sticky-major experiment. This is a separate compile-time
/// opt-in underneath the already experimental tracer so the ordinary trace
/// artifact pays no scheduler branch, state field, or changed collection
/// semantics. It must never be inferred from an environment variable alone.
pub const sticky_major_enabled: bool =
    trace_stw_enabled and build_options.zjs_experimental_gc_sticky_major;

/// Pass-B corpse census (`-Dzjs_experimental_gc_corpse_census=true`). It
/// classifies every parked corpse inside `drainCycleDeferredFreesBudgeted`,
/// which is the symbol being priced, so the switch has to be comptime: a
/// runtime flag test would be part of the 27.8 cycles/entry under measurement.
/// Default false in every shipped and every measured artifact.
pub const corpse_census_enabled: bool =
    trace_stw_enabled and build_options.zjs_experimental_gc_corpse_census;
/// Live page-radix address registry for conservative candidate validation.
/// On in tests (so the map can be unit-tested on default `rc` tests) and in
/// shadow/STW builds. Default production `rc` keeps this false so Registry
/// layout and the allocation hot path stay the original body.
pub const address_registry_enabled: bool = shadow_tracer_enabled or trace_stw_enabled or builtin.is_test;

/// Publication-size histogram and measured size-class table (§4.2 / §4.3).
/// Same compile gate as the address registry: tests/shadow/STW only.
pub const space_model_enabled: bool = address_registry_enabled;

/// Logical 64 KiB window sweep state machine and four scheduling quantities
/// (§8.7). Same compile gate.
pub const sweep_model_enabled: bool = address_registry_enabled;

/// Sweep-model observation on the allocation path. Everything the state
/// machine produces is read only by `--gc-stats` and by tests; nothing in the
/// collector or allocator branches on it, and `refreshHeadroom`'s
/// per-publication result is overwritten by `endSweepModelSweep` before the
/// report reads it. So the per-object hash insert is instrumentation and
/// carries an instrument's gate, matching `gc_slot.stats_enabled`.
pub const sweep_model_stats_enabled: bool =
    sweep_model_enabled and (builtin.is_test or shadow_tracer_enabled);

/// 64 KiB block heap. STW only so default `rc` keeps the existing allocator.
pub const block_heap_enabled: bool = trace_stw_enabled;

/// String/rope intervals in the address registry. Shadow/STW only: default
/// `rc` tests keep `stats.live` as the cycle-list census.
/// Shadow only. The reclaiming tracer does not consume string intervals:
/// `gc_conservative.scanWords` discards every `.string`/`.rope` hit,
/// `traceHeader` treats strings as leaves, and `JSValue.cycleMarkHeader` can
/// never yield a string header, so under `trace_stw` every flat string and
/// rope node was paying a `by_header` insert plus a page-bucket append per
/// spanned page on allocation, and a per-page linear scan on free, to produce
/// a fact nothing reads. Strings stay refcount-owned under both collectors, so
/// a native frame holding one holds a count; conservative retention of strings
/// covers nothing (§7.2). Dropping them also shortens exactly the occupant
/// lists the candidate scan walks.
pub const string_registry_enabled: bool = shadow_tracer_enabled;

const BlockHeapMod = @import("gc_block_heap.zig");

const AddressRegistryTable = if (address_registry_enabled)
    @import("gc_address_registry.zig").Table
else
    void;

const SpaceHistogram = if (space_model_enabled)
    @import("gc_space.zig").Histogram
else
    void;

const SweepModel = if (sweep_model_enabled)
    @import("gc_sweep_model.zig").Model
else
    void;

pub const generation_enabled: bool = trace_stw_enabled;

/// Set from the `ZJS_GC_STRESS` environment variable. Collect at every
/// safepoint that has anything young, instead of waiting for the young
/// threshold, and shorten the safepoint cadence itself
/// (`JSContext.pollInterruptSlow`).
///
/// This exists because a missing root or a missing write barrier is only
/// observable when a collection lands inside the exact window the reference is
/// unreachable from the trace. At the production cadence that window is hit by
/// accident, so the same binary passes or fails depending on allocation
/// history, and adding a `print` to find out where moves the collection and the
/// failure disappears. Under stress the window is hit every time.
pub var stress_collect: bool = false;

/// Safepoint cadence under stress, in interpreter ticks. `ZJS_GC_STRESS=1`
/// takes the default; `ZJS_GC_STRESS=<n>` for n > 1 sets it directly, which is
/// how a full test262 sweep stays affordable -- 64 is thorough but roughly two
/// orders of magnitude slower than the production 10_000.
pub var stress_cadence: i32 = 64;

/// `ZJS_GC_STRESS=off` suppresses collection entirely. Diagnostic only: it is
/// how you answer "is this failure caused by a collection landing here at all?"
/// in one run instead of by inference.
pub var stress_disable: bool = false;

/// `ZJS_GC_NO_MINOR=1` runs majors only. Splits "a generational invariant --
/// sticky marks, a missing write barrier, the young suffix" from "a root the
/// trace never sees at all", which a full collection would miss too.
pub var stress_no_minor: bool = false;

/// Diagnostic floor for the major-collection threshold, in bytes
/// (`ZJS_GC_MIN_THRESHOLD`). Raising it far above a workload's total
/// allocation makes the collector effectively never run, which is the only
/// way to separate the two halves of the tracer's price: what the MUTATOR
/// pays merely to be collectable (allocation route, write barrier,
/// generational bookkeeping) from what COLLECTING costs. Never set in any
/// shipped configuration; a run under it is not a correctness
/// configuration either, since nothing is ever reclaimed.
pub var min_major_threshold: usize = 0;

/// Diagnostic override for `small_heap_major_headroom_bytes`
/// (`ZJS_GC_HEADROOM`, bytes; 0 = use the compiled constant). The floor sets
/// the major cadence for every small live set -- raytrace's threshold is set
/// by it on 100% of collections -- so its value has to be swept, not
/// inherited.
pub var headroom_override: usize = 0;

/// Diagnostic override for the tracer's major growth factor, as a percentage
/// of the live bytes (`ZJS_GC_GROWTH_PERCENT`; 0 = use the compiled 200).
///
/// The slab's free-block pool -- and therefore the reuse distance of every
/// recycled slab block -- is about half the allocation headroom this factor
/// buys. That makes it the only knob that moves the alloc side's cache
/// behaviour at all, so it has to be sweepable rather than argued about.
/// Never set in any shipped configuration.
pub var growth_percent_override: usize = 0;

/// `ZJS_MINOR_AUDIT=1`: after the minor picks its condemned set, report any
/// live object still holding an edge into it. Parsed once here rather than
/// read at the check, because the minor path is exactly where a `getenv` per
/// collection is the probe that hides the bug -- regexp performs 794 minors in
/// a two-second script.
pub var minor_audit: bool = false;

/// `ZJS_GC_ARENA_AUDIT=1`: after every collection, check that a slab block
/// reads as a live GC object exactly when it holds one.
///
/// That biconditional is what conservative candidate validation resolves
/// against, and it is maintained by scattered stores in two modules rather
/// than by any one owner -- both stamps that fix it could be deleted with a
/// green suite. A checker is the answer to an invariant with no owner: it does
/// not care which store was forgotten.
pub var arena_audit: bool = false;

/// Expensive whole-heap invariants belong to safety/audit builds only. In the
/// shipped ReleaseFast configuration this folds to the existing, normally
/// false arena-audit flag; no allocation/mark/free hot path calls it.
pub inline fn invariantChecksEnabled() bool {
    if (comptime std.debug.runtime_safety) return true;
    return arena_audit;
}

/// `ZJS_GC_VERIFY_MINOR=1`: check every minor's condemned set against what a
/// full trace would keep. See `gc_trace_stw.computeFullReachable`.
pub var verify_minor: bool = false;

/// `ZJS_GC_VERIFY_STICKY_MAJOR=1`: before an experimental sticky cycle
/// condemns anything, recompute reachability from freshly cleared marks and
/// reject every object that the sticky marks would condemn but the fresh
/// trace reaches. Parsed only in builds that contain the sticky experiment.
pub var verify_sticky_major: bool = false;

/// `ZJS_GC_STICKY_MAJOR=0`: keep the experimental scheduler compiled in but
/// force every self-paced cycle back to full scope. This exists so the arm can
/// be priced against itself in ONE binary: the layout, the branch, and the
/// extra state field are identical on both sides, and the only difference
/// measured is the scope decision. Defaults to on, because in this build the
/// `-Dzjs_experimental_gc_sticky_major` option is already the opt-in.
pub var sticky_major_on: bool = true;

/// `ZJS_GC_VERIFY_MAJOR_ALL=1`: run the same fresh-trace oracle over FULL-scope
/// incremental cycles too. A full scope cannot under-mark by construction, so
/// anything the oracle reports there is its own noise floor -- which is the
/// only way to read the sticky arm's number as a rate rather than a raw count.
pub var verify_major_all: bool = false;

/// `ZJS_GC_STICKY_INJECT_SKIP=N`: deliberately fail to expand the first N
/// remembered owners of a sticky cycle. This is the fault the fresh-trace
/// oracle exists to catch -- an old owner whose young child nothing else
/// reaches -- reproduced in the shipped ReleaseFast arm rather than only in a
/// Debug unit test. Never read unless the sticky experiment is compiled in.
pub var sticky_inject_skip: usize = 0;

/// Read once at `Registry.init`. "0" or empty disables; "1" enables at the
/// default cadence; any other integer enables at that cadence.
fn readStressFromEnv() void {
    if (comptime !trace_stw_enabled) return;
    if (std.c.getenv("ZJS_MINOR_AUDIT")) |raw| {
        const text = std.mem.span(raw);
        minor_audit = text.len != 0 and !std.mem.eql(u8, text, "0");
    }
    if (std.c.getenv("ZJS_GC_ARENA_AUDIT")) |raw| {
        const text = std.mem.span(raw);
        arena_audit = text.len != 0 and !std.mem.eql(u8, text, "0");
    }
    if (std.c.getenv("ZJS_GC_VERIFY_MINOR")) |raw| {
        const text = std.mem.span(raw);
        verify_minor = text.len != 0 and !std.mem.eql(u8, text, "0");
    }
    if (comptime sticky_major_enabled) {
        if (std.c.getenv("ZJS_GC_VERIFY_STICKY_MAJOR")) |raw| {
            const text = std.mem.span(raw);
            verify_sticky_major = text.len != 0 and !std.mem.eql(u8, text, "0");
        }
        if (std.c.getenv("ZJS_GC_STICKY_MAJOR")) |raw| {
            const text = std.mem.span(raw);
            sticky_major_on = text.len != 0 and !std.mem.eql(u8, text, "0");
        }
        if (std.c.getenv("ZJS_GC_VERIFY_MAJOR_ALL")) |raw| {
            const text = std.mem.span(raw);
            verify_major_all = text.len != 0 and !std.mem.eql(u8, text, "0");
        }
        if (std.c.getenv("ZJS_GC_STICKY_INJECT_SKIP")) |raw| {
            sticky_inject_skip = std.fmt.parseInt(usize, std.mem.span(raw), 10) catch 0;
        }
    }
    if (std.c.getenv("ZJS_GC_NO_MINOR")) |raw| {
        const text = std.mem.span(raw);
        stress_no_minor = text.len != 0 and !std.mem.eql(u8, text, "0");
    }
    if (std.c.getenv("ZJS_GC_MIN_THRESHOLD")) |raw| {
        min_major_threshold = std.fmt.parseInt(usize, std.mem.span(raw), 10) catch 0;
    }
    if (std.c.getenv("ZJS_GC_DESTROY_PROBE")) |raw| {
        const text = std.mem.span(raw);
        @import("gc_trace_stw.zig").destroy_probe = text.len != 0 and !std.mem.eql(u8, text, "0");
    }
    if (std.c.getenv("ZJS_GC_HEADROOM")) |raw| {
        headroom_override = std.fmt.parseInt(usize, std.mem.span(raw), 10) catch 0;
    }
    if (std.c.getenv("ZJS_GC_GROWTH_PERCENT")) |raw| {
        const parsed_growth = std.fmt.parseInt(usize, std.mem.span(raw), 10) catch 0;
        growth_percent_override = if (parsed_growth >= 100) parsed_growth else 0;
    }
    const raw = std.c.getenv("ZJS_GC_STRESS") orelse return;
    const text = std.mem.span(raw);
    if (text.len == 0 or std.mem.eql(u8, text, "0")) return;
    if (std.mem.eql(u8, text, "off")) {
        stress_disable = true;
        return;
    }
    stress_collect = true;
    const parsed = std.fmt.parseInt(i32, text, 10) catch return;
    if (parsed > 1) stress_cadence = parsed;
}

/// Candidate validation for torn concurrent reads (§5.4). Compiled wherever a
/// tracer exists, since conservative scanning needs the same checks.
pub const candidate_validation = @import("gc_candidate.zig");

/// Concurrent-major barrier and safepoint handshake (§8.4). Present wherever
/// a tracer is compiled; the marker thread that uses it arrives separately.
pub const concurrent_enabled: bool = trace_stw_enabled;
pub const concurrent = @import("gc_concurrent.zig");
/// Bounded mark queue whose overflow downgrades to rescan rather than
/// dropping work (§8.4).
pub const mark_queue = @import("gc_mark_queue.zig");

/// The census switch lives with the collector; the barrier only reads it.
/// Mutual import with `gc_trace_stw.zig` is fine -- Zig resolves lazily -- and
/// the `rc` build sees a false constant instead of the module.
const gc_trace_stw_reports = if (trace_stw_enabled)
    @import("gc_trace_stw.zig")
else
    struct {
        pub var detailed_reports: bool = false;
    };
/// Marker worker thread (§8.6). Reads published objects and claims mark state;
/// never frees, allocates, or calls embedder code.
pub const marker = @import("gc_marker.zig");
pub const generation = @import("gc_generation.zig");
/// Seqlock snapshot for dynamic layouts, so a marker can read a descriptor
/// beside a mutator that is replacing it (§6.3).
pub const layout_snapshot = @import("gc_snapshot.zig");
const ConcurrentState = if (concurrent_enabled)
    concurrent.State
else
    void;

/// Young objects required before a minor is worth its root scan.
///
/// A minor's cost splits into a per-object part (clear, trace and sweep the
/// young suffix) and a per-invocation part that does not shrink with the young
/// set at all: scan every precise root, spill and scan the native stack
/// conservatively, and force-trace every remembered owner. At 512 objects the
/// second part dominates -- raytrace was paying 104us per minor to reclaim
/// about a thousand objects -- and 40% of the young set was surviving, because
/// a nursery that small is collected again before its occupants have had time
/// to die. Everything that survives is promoted, and only a major can reclaim
/// a promoted object, so an undersized nursery manufactures old garbage.
///
/// For scale: V8's semi-space is 1-8MB and JSC's eden runs to tens of MB. At
/// zjs's p50 object size this is ~1.5MB, which is the low end of that range
/// rather than a match for it; the pause budget is what argues against going
/// further, and that trade is measurable once the block space lands.
pub const minor_young_threshold: usize = 16 * 1024;

/// Bytes the major threshold must leave free above the live set, so that a
/// nursery can actually fill.
///
/// The whole-heap threshold is tested before a minor is offered (§8.5), which
/// means a threshold tighter than one nursery is a threshold the nursery can
/// never reach: every collection becomes a major and the generational filter
/// is dead code. qjs needs no such floor because it has no young generation.
/// Sized from the p95 of the allocation histogram rather than the p50, since
/// the point is to guarantee the room, not to predict it.
///
/// The room is not always enough, and that turns out to be the right outcome
/// rather than a shortfall to tune away. `allocated_bytes` counts strings,
/// shapes and bytecode too, so on a small live set the threshold is still
/// crossed before the nursery fills and every collection becomes a major:
/// raytrace and deltablue run with zero minors. Both are FASTER that way --
/// a whole-heap trace of 600KB costs less than the per-invocation root and
/// conservative-stack scan a minor pays to avoid it.
///
/// An earlier version of this comment claimed the arithmetic reverses on a
/// large live set, and cited splay at 623 minors to 40 majors as the case where
/// minors carry the load. That was wrong in both directions: the ratio is not
/// reproducible, and disabling minors on splay makes it 21% faster. Heap size
/// does not decide whether a minor is worth running -- young mortality does,
/// and only the workload knows that. `gc_generation.noteMinorYield` measures it
/// (see `low_yield_limit`); this constant only decides how much room the young
/// set gets before the question is asked.
/// Time budget for one incremental marking increment at a poll. §1.3's major
/// pause target is 2 ms p99; 1 ms per increment leaves room for the begin and
/// remark slices, which carry fixed whole-heap work until Phase 3.
pub const incremental_mark_budget_ns: u64 = 1_000_000;

/// Floor on the allocation a small live set gets before the next major.
///
/// Named for what it does rather than for how it was first derived. The
/// growth rule alone gives a 0.5 MB live set 0.375 MB of room, which is less
/// than one nursery, so the whole-heap threshold would be crossed before the
/// young set could fill and the minor would never get a chance to answer --
/// that is where `minor_young_threshold * 96` came from. But the constant
/// also sets the MAJOR cadence for every workload whose live set is small,
/// whether or not it runs minors at all, and that is the effect that
/// dominates: raytrace runs zero minors and still takes 3734 majors, one per
/// 1.783 MB allocated, which is this floor and not the growth factor. So the
/// two roles are separated here, and the number is a candidate to be
/// measured rather than a nursery multiple to be inherited.
///
/// It cannot be conditioned on `minorSuspended()`: raytrace never runs a
/// minor at all, so the suspension flag is false for it and the condition
/// would not fire where it is needed. (Adversarial review, codex,
/// 2026-08-27.)
pub const small_heap_major_headroom_bytes: usize =
    if (generation_enabled) minor_young_threshold * 96 else 0;

/// Deprecated spelling kept for the tests and comments that name the nursery
/// role; identical value.
pub const nursery_headroom_bytes: usize = small_heap_major_headroom_bytes;

const GenerationState = if (generation_enabled)
    @import("gc_generation.zig").State
else
    void;

pub const IncrementalMajorScope = enum(u1) {
    full,
    sticky,
};

pub const StickyMajorStats = struct {
    full_cycles: usize = 0,
    sticky_cycles: usize = 0,
    full_forced_by_pressure: usize = 0,
    oracle_checks_sticky: usize = 0,
    /// Oracle runs over FULL-scope cycles. These are the control arm: the same
    /// instrument on a scope that cannot be wrong by construction, so whatever
    /// it reports there is the instrument's own noise floor.
    oracle_checks_full: usize = 0,
    /// A condemned object the fresh trace reached from PRECISE roots. This is
    /// the number that means "sticky killed something live"; it is fail-closed.
    oracle_violations_precise: usize = 0,
    /// A condemned object the fresh trace reached ONLY through a conservative
    /// stack candidate. The oracle runs on a different native frame than the
    /// cycle it audits, so residue can exist in one scan and not the other --
    /// the minor verifier has always reported this class separately for the
    /// same reason. Counted, never fatal, and expected to appear at the same
    /// rate on the full-scope control.
    oracle_violations_conservative: usize = 0,
    /// Settled bytes after a sticky cycle minus settled bytes after the full
    /// that preceded it. At a steady state where live is flat this is the
    /// floating garbage the skipped full would have reclaimed -- the cost side
    /// of the trade. It is an upper bound where live is genuinely growing,
    /// because real new survivors are counted in it too.
    max_sticky_excess_bytes: usize = 0,
    sum_sticky_excess_bytes: usize = 0,
    /// The largest ordinary (sticky-contaminated) threshold ever installed.
    /// Prerequisite #2 is only satisfied if the full-pressure threshold is NOT
    /// a function of this number, so both are printed and can be compared.
    max_ordinary_threshold: usize = 0,
};

const StickyMajorState = struct {
    cycle_scope: IncrementalMajorScope = .full,
    full_baseline_valid: bool = false,
    sticky_rounds_since_full: u1 = 0,
    last_full_settled_bytes: usize = 0,
    full_pressure_threshold: usize = 0,
    stats: StickyMajorStats = .{},
};

/// Max alignment the block heap can serve; `void`-safe for default `rc`.
pub inline fn blockHeapMaxAlign() usize {
    return if (block_heap_enabled) @import("gc_block_heap.zig").cell_alignment else 0;
}

const BlockHeap = if (block_heap_enabled)
    @import("gc_block_heap.zig").Heap
else
    void;

pub const Mode = enum {
    balanced,
    throughput,
    low_rss,
    low_latency,
};

pub const Policy = struct {
    mode: Mode = .balanced,

    large_object_threshold: usize = 8 * KB,

    callback_slice_budget_ns: u64 = 300_000,
    idle_slice_budget_ns: u64 = 2_000_000,
    allocation_slow_path_budget_ns: u64 = 2_000_000,
    native_cleanup_slice_jobs: usize = 8,

    external_weight: usize = 8,
    major_debt_threshold: usize = 64 * MB,
    external_soft_limit: ?usize = null,
    external_hard_limit: ?usize = null,
    rss_soft_limit: ?usize = null,
    rss_hard_limit: ?usize = null,
    cgroup_soft_ratio_per_mille: usize = 0,
    cgroup_hard_ratio_per_mille: usize = 0,

    /// Whether any policy field actually consumes the OS-level memory
    /// snapshot, i.e. whether `Registry.processMemoryRequest` can return
    /// anything but null. Exactly the four fields that function reads, and
    /// deliberately not `external_soft_limit` / `external_hard_limit`: those
    /// are served by the registry's own external-byte counter and need no
    /// `/proc` or cgroup read.
    ///
    /// Gating on the fields rather than on `mode` matters, because a caller may
    /// set an RSS or cgroup limit while staying in `.balanced`; a mode test
    /// would silently disable a pressure policy the embedder asked for.
    pub inline fn needsProcessMemorySnapshot(self: Policy) bool {
        return self.rss_soft_limit != null or
            self.rss_hard_limit != null or
            self.cgroup_soft_ratio_per_mille != 0 or
            self.cgroup_hard_ratio_per_mille != 0;
    }

    pub fn forMode(mode: Mode) Policy {
        var policy = Policy{
            .mode = mode,
        };
        switch (mode) {
            .balanced => {},
            .throughput => {
                policy.callback_slice_budget_ns = 200_000;
                policy.idle_slice_budget_ns = 2_000_000;
                policy.allocation_slow_path_budget_ns = 2_000_000;
                policy.native_cleanup_slice_jobs = 16;
            },
            .low_rss => {
                policy.callback_slice_budget_ns = 300_000;
                policy.idle_slice_budget_ns = 5_000_000;
                policy.external_weight = 12;
                policy.native_cleanup_slice_jobs = 16;
                policy.cgroup_soft_ratio_per_mille = 850;
                policy.cgroup_hard_ratio_per_mille = 950;
            },
            .low_latency => {
                policy.callback_slice_budget_ns = 100_000;
                policy.idle_slice_budget_ns = 1_000_000;
                policy.allocation_slow_path_budget_ns = 500_000;
                policy.native_cleanup_slice_jobs = 4;
            },
        }
        return policy;
    }
};

pub const ExternalMemoryToken = struct {
    registry: ?*Registry = null,
    id: u64 = 0,
    bytes: usize = 0,

    pub fn release(self: *ExternalMemoryToken) void {
        const registry = self.registry orelse return;
        const id = self.id;
        const bytes = self.bytes;
        self.registry = null;
        self.id = 0;
        self.bytes = 0;
        registry.releaseExternalToken(id, bytes);
    }

    pub fn deinit(self: *ExternalMemoryToken) void {
        self.release();
    }
};

/// 6.2 BlockHeader / GcKind definition
/// 3-bit tag packed into the shared kind/flags byte of `Metadata` (qjs
/// `JSMallocBlockHeader.gc_obj_type : 7`, quickjs.c:276, also shares its byte
/// with the mark bit).
///
/// Value order is load-bearing for codegen, mirroring qjs's
/// `JS_GC_OBJ_TYPE_JS_OBJECT == 0` (quickjs.c:423): the hot `kind == .object`
/// guards compile to a single `tst` of the masked byte, and the recurring
/// zero-ref kind sets become contiguous ranges — {object..module} is the
/// enqueue/finalize/remove_cycles set and {object..shape} is the
/// cycle-candidate/deinit set, each a single unsigned compare. string/big_int
/// (plain refcounted payloads, never cycle-tracked) sit at the top.
pub const RefKind = enum(u3) {
    object = 0,
    function_bytecode = 1,
    var_ref = 2,
    realm_context = 3,
    module = 4,
    shape = 5,
    string = 6,
    big_int = 7,
};

/// Stage-0 tracing inventory for every encoded GC reference kind. Adding a
/// RefKind without classifying its carrier is a compile error. This does not
/// claim the composite tracing heap exists; `allocation_ledger` rows are the
/// missing Implementation behind that future Interface.
pub const HeapCensusClass = enum(u8) {
    rc_registry,
    allocation_ledger,
};

pub const StrongEdgeClass = enum(u8) {
    registry_trace,
    string_family,
    leaf,
};

/// Physical prefix carried by a RefKind.  `.metadata` is the shared eight-byte
/// allocator/GC prefix immediately before a 16-byte `BlockHeader`;
/// `.string_rc` is the four-byte refcount-only prefix used by flat strings and
/// ropes, which intentionally has no allocator or lifecycle fields.
pub const PrefixModel = enum(u8) {
    metadata,
    string_rc,
};

/// Legal allocation carriers for a kind.  Only plain objects may enter the
/// collector block heap; every other Metadata kind is slab/standalone, while
/// strings use their dedicated prefixed allocation family.
pub const AllocationCarrier = enum(u8) {
    block_slab_or_standalone,
    slab_or_standalone,
    string_family,
};

/// Meaning of the `Metadata.rc` word for this kind in a tracing build.  The
/// word is still physically present for `trace_removed`, but must remain at
/// its construction value because reachability, not retains, owns liveness.
pub const RefCountSemantics = enum(u8) {
    trace_removed,
    retained,
};

pub const RefKindDescriptor = struct {
    kind: RefKind,
    census: HeapCensusClass,
    strong_edges: StrongEdgeClass,
    cycle_candidate: bool,
};

pub const ref_kind_catalog = [_]RefKindDescriptor{
    .{ .kind = .object, .census = .rc_registry, .strong_edges = .registry_trace, .cycle_candidate = true },
    .{ .kind = .function_bytecode, .census = .rc_registry, .strong_edges = .registry_trace, .cycle_candidate = true },
    .{ .kind = .var_ref, .census = .rc_registry, .strong_edges = .registry_trace, .cycle_candidate = true },
    .{ .kind = .realm_context, .census = .rc_registry, .strong_edges = .registry_trace, .cycle_candidate = true },
    .{ .kind = .module, .census = .rc_registry, .strong_edges = .registry_trace, .cycle_candidate = true },
    .{ .kind = .shape, .census = .rc_registry, .strong_edges = .registry_trace, .cycle_candidate = true },
    // RefKind does not distinguish flat strings from StringRope. Flat strings
    // are leaves; ropes own left/right JSValue edges. Neither is on gc_obj_list.
    .{ .kind = .string, .census = .allocation_ledger, .strong_edges = .string_family, .cycle_candidate = false },
    .{ .kind = .big_int, .census = .allocation_ledger, .strong_edges = .leaf, .cycle_candidate = false },
};

pub inline fn refKindDescriptor(kind: RefKind) *const RefKindDescriptor {
    return &ref_kind_catalog[@intFromEnum(kind)];
}

/// Representation-only contract kept separate from `RefKindDescriptor`.
/// The latter is indexed by existing runtime census code; widening it would
/// change that table's stride in shipped code merely to serve an audit.
pub const RepresentationKindDescriptor = struct {
    kind: RefKind,
    prefix: PrefixModel,
    allocation: AllocationCarrier,
    ref_count: RefCountSemantics,
};

pub const representation_kind_catalog = [_]RepresentationKindDescriptor{
    .{ .kind = .object, .prefix = .metadata, .allocation = .block_slab_or_standalone, .ref_count = .trace_removed },
    .{ .kind = .function_bytecode, .prefix = .metadata, .allocation = .slab_or_standalone, .ref_count = .trace_removed },
    .{ .kind = .var_ref, .prefix = .metadata, .allocation = .slab_or_standalone, .ref_count = .trace_removed },
    .{ .kind = .realm_context, .prefix = .metadata, .allocation = .slab_or_standalone, .ref_count = .retained },
    .{ .kind = .module, .prefix = .metadata, .allocation = .slab_or_standalone, .ref_count = .trace_removed },
    .{ .kind = .shape, .prefix = .metadata, .allocation = .slab_or_standalone, .ref_count = .retained },
    .{ .kind = .string, .prefix = .string_rc, .allocation = .string_family, .ref_count = .retained },
    .{ .kind = .big_int, .prefix = .metadata, .allocation = .slab_or_standalone, .ref_count = .retained },
};

pub inline fn representationKindDescriptor(kind: RefKind) *const RepresentationKindDescriptor {
    return &representation_kind_catalog[@intFromEnum(kind)];
}

comptime {
    const tags = std.meta.tags(RefKind);
    std.debug.assert(@intFromEnum(RefKind.object) == representation.object_kind_tag);
    // Runtime census code indexes this table. Representation audits must not
    // widen its four-byte element or change shipped lookup geometry.
    std.debug.assert(@sizeOf(RefKindDescriptor) == 4);
    std.debug.assert(ref_kind_catalog.len == tags.len);
    std.debug.assert(representation_kind_catalog.len == tags.len);
    for (ref_kind_catalog, 0..) |descriptor, index| {
        std.debug.assert(@intFromEnum(descriptor.kind) == index);
        std.debug.assert(descriptor.cycle_candidate == (descriptor.census == .rc_registry));
    }
    for (representation_kind_catalog, 0..) |descriptor, index| {
        std.debug.assert(@intFromEnum(descriptor.kind) == index);
        std.debug.assert((descriptor.prefix == .string_rc) == (descriptor.kind == .string));
        std.debug.assert((descriptor.allocation == .block_slab_or_standalone) == (descriptor.kind == .object));
        std.debug.assert((descriptor.allocation == .string_family) == (descriptor.kind == .string));
        std.debug.assert((descriptor.ref_count == .trace_removed) == switch (descriptor.kind) {
            .object, .function_bytecode, .var_ref, .module => true,
            else => false,
        });
    }
}

pub const GcKind = RefKind;

pub const gc_kind_count: usize = @typeInfo(GcKind).@"enum".fields.len;

/// Kinds whose lifetime the tracer owns outright under `trace_stw`, so their
/// refcount is not maintained at all -- retain and release are no-ops and the
/// shared lifetime word carries mark/husk state instead.
///
/// `.shape` and `.realm_context` are traced too but keep their counts, for
/// reasons that have nothing to do with liveness. A Shape's `rc == 1` is the
/// exclusive-ownership test that licenses mutating a shape in place instead of
/// splitting it copy-on-write; freezing it would silently license mutating a
/// shared one. A Realm is a host handle with an explicit `JSContext.destroy`
/// API and a teardown-order contract (`context_head == null`) that the runtime
/// asserts. Strings, ropes, symbols and BigInt are not traced at all, so their
/// counts are the only thing keeping them alive.
pub inline fn refCountRemoved(kind: GcKind) bool {
    if (comptime !trace_stw_enabled) return false;
    return switch (kind) {
        .object, .function_bytecode, .var_ref, .module => true,
        else => false,
    };
}
pub const Phase = enum {
    none,
    decref,
    /// Refcounting's cycle collector is running its two-pass teardown.
    remove_cycles,
    /// The tracer is running a destruction slice.
    ///
    /// Distinct from `.remove_cycles` even though the two share most of
    /// their teardown contract, because they do NOT share all of it and a
    /// single value forced every site to serve both. The visible cost was
    /// `Object.destroyFromHeader`'s fast arm, which excludes
    /// `.remove_cycles` for reasons that belong to rc's collector -- so the
    /// tracing build, which frees every object inside such a window, had
    /// never once used its own fast teardown. Measured: destruction costs
    /// the tracer 1.52 s of stopped time on raytrace against rc's 0.50 s for
    /// the same objects, and raytrace's whole gap is 1.6 s.
    tracer_destroy,
    deinit,
    cycle,
};

/// Both teardown windows: resources are freed in one pass and structs in
/// another, so a struct free must be parked either way.
pub inline fn phaseIsTwoPassTeardown(phase: Phase) bool {
    return phase == .remove_cycles or phase == .tracer_destroy;
}

pub const MajorPhase = enum(u8) {
    idle,
    mark_roots,
    sweep,
};

pub const SchedulerPoint = enum(u8) {
    allocation_slow_path,
    callback_boundary,
    idle,
    safepoint,
    urgent,
};

pub const RequestReason = enum(u8) {
    manual,
    allocation_threshold,
    allocation_debt,
    external_memory,
    rss_pressure,
    collection_failed,
};

pub const RequestUrgency = enum(u8) {
    soon,
    urgent,
};

pub const Request = struct {
    pending: bool = false,
    reason: ?RequestReason = null,
    urgency: RequestUrgency = .soon,
};

pub const PressureRequest = struct {
    reason: RequestReason,
    urgency: RequestUrgency,
};

pub const ExternalTokenEntry = struct {
    id: u64 = 0,
    bytes: usize = 0,
};

pub const PinEntry = struct {
    header: *GCObjectHeader,
    count: usize = 0,
};

/// Reserved PinEntry count for a fully initialized but unpublished generator
/// shell. Host pins are positive reference counts and can never reach this
/// value; the discriminator adds no field or padding to the existing ledger.
const construction_pin_count = std.math.maxInt(usize);

pub const SpaceAccount = struct {
    live_bytes: usize = 0,

    // qjs-aligned hot path: mirror rt->malloc_size / rt->malloc_count by
    // tracking only live_bytes (quickjs.c:2160 js_def_malloc bumps a single
    // scalar and delegates all page management to the system allocator).
    fn recordAlloc(self: *SpaceAccount, bytes: usize) void {
        // Plain unsigned add, exactly qjs `s->malloc_size += ...`
        // (quickjs.c:2166). The former checked-add-with-saturation compiled to
        // adds+cset+tst+csinv on the per-object hot path for an overflow that
        // cannot occur (live bytes are bounded by the address space); wrapping
        // `+%=` keeps the codegen a bare ldr/add/str in every build mode. The
        // zero-bytes early-out is dropped for the same reason: adding 0 is a
        // no-op, and qjs has no such guard.
        self.live_bytes +%= bytes;
    }

    fn recordFree(self: *SpaceAccount, bytes: usize) void {
        // Plain wrapping sub, exactly qjs `s->malloc_size -= ...`
        // (quickjs.c:2174 js_def_free): the alloc side records the same exact
        // byte total the free side debits (Debug verifyHeapAccounting walks the
        // object list and proves the balance), so saturation guarded an
        // underflow that cannot occur while costing a subs+csel pair on every
        // GC-object free. The zero-bytes early-out mirrors recordAlloc's
        // removal: subtracting 0 is a no-op.
        std.debug.assert(self.live_bytes >= bytes);
        self.live_bytes -%= bytes;
    }
};

fn ratioPerMille(numerator: usize, denominator: usize) usize {
    if (denominator == 0) return 0;
    const scaled = std.math.mul(usize, numerator, 1000) catch std.math.maxInt(usize);
    return @min(@as(usize, 1000), scaled / denominator);
}

/// Byte 3 of the metadata prefix: the GC kind and the GC lifecycle bits share
/// one byte, mirroring qjs `JSMallocBlockHeader` byte 3 = `gc_obj_type : 7 |
/// mark : 1` (quickjs.c:276). zjs needs four extra cycle/lifecycle bits qjs
/// carries in its wider 4-bit `mark` value ranges and list membership, so the
/// kind is 3 bits and the flags take the remaining five.
pub const BlockFlags = packed struct(u8) {
    /// GC kind tag (qjs `gc_obj_type`). Bits 0-2.
    kind: GcKind = .object,
    mark: bool = false,
    /// Padding: former `in_cycle_list`. Membership is the cyclic list itself
    /// (qjs `list_add_tail` / `list_del`, quickjs.c:6545/6548). Kept so
    /// `finalizing` / `is_pinned` / `cycle_visited` stay at their historical
    /// bit positions — `memory.zig` writes this flags byte by layout.
    /// Was `in_cycle_list`, then padding. Now carries the sticky generation
    /// bit: set on publication, cleared when a collection lets the object
    /// survive. It lives here rather than in a side table because a hash-map
    /// insert on every allocation measured at 28% of throughput -- the object
    /// header is the only place cheap enough for a per-allocation fact.
    ///
    /// The bit position is unchanged, so `memory.zig`'s by-layout write of
    /// this byte still lands where it always did.
    young: bool = false,
    finalizing: bool = false,
    is_pinned: bool = false,
    /// Condemned-garbage flag after gc_scan. qjs derives the same state from
    /// `tmp_obj_list` membership; query sites (`headerIsCycleGarbage`, realm
    /// walk, var_ref release) cannot walk the list, so the bit stays.
    cycle_visited: bool = false,
};

/// Byte 2 of the metadata prefix = the allocator's `block_size_idx` byte (qjs
/// `JSMallocBlockHeader.block_size_idx`, quickjs.c:275), now stamped for GC
/// allocations too, plus two zjs accounting bits in the unused high bits
/// (slab classes only need 5 bits; qjs marks its large blocks via
/// `u.block_idx == FREE_NIL` instead, but zjs stores encoded heap bytes in
/// that u16 for standalone prefixes, so the discriminator lives here).
pub const AllocInfo = packed struct(u8) {
    /// Slab size-class index of the owning block. Valid iff `!standalone`;
    /// free paths read it back instead of re-deriving the class from the byte
    /// size (qjs `__js_free`, quickjs.c:1614-1617).
    block_size_idx: u5 = 0,
    /// Alloc-time large-space classification, stamped by registration
    /// (`addInitializedWithSizeNoFail`) and valid iff `heap_accounted`. The
    /// free path reads it from the alloc_info byte it already loads instead of
    /// re-deriving `bytes >= policy.large_object_threshold` (a policy load +
    /// compare qjs never pays: js_free_rt has no space split at all,
    /// quickjs.c:1613-1617). Stamping also pins the classification to the
    /// space that was actually credited, so a policy-threshold change between
    /// alloc and free can no longer unbalance the two space accounts.
    large: bool = false,
    /// The allocation has been added to the live-byte accounts. Kept separate
    /// from size_class because slab-overlaid metadata reserves that field.
    heap_accounted: bool = false,
    /// The metadata is a dedicated prefix ahead of the object (slab-ineligible
    /// or over-aligned allocation); `size_class` then holds encoded heap bytes.
    /// When false the metadata occupies the small-object slab's allocator
    /// header and `size_class` is the allocator's block index.
    standalone: bool = false,
};

/// The owner's private LIFO mark frontier (see `Registry.mark_stack`).
/// Fixed capacity: a marker must not allocate per object mid-phase. When
/// full, the caller routes the overflow to the shared ring, whose own
/// overflow downgrades to a marked-object rescan -- the same ladder the
/// design already specifies.
pub const MarkStack = struct {
    items: ?[]*GCObjectHeader = null,
    len: usize = 0,

    pub const cap = 65536;

    pub fn ensure(self: *MarkStack) void {
        if (self.items != null) return;
        self.items = Registry.markQueueAllocator().alloc(*GCObjectHeader, cap) catch null;
    }

    pub fn deinitStack(self: *MarkStack) void {
        if (self.items) |slice| Registry.markQueueAllocator().free(slice);
        self.* = .{};
    }

    pub inline fn pop(self: *MarkStack) ?*GCObjectHeader {
        if (self.len == 0) return null;
        self.len -= 1;
        return self.items.?[self.len];
    }

    /// Pop and software-prefetch the next entry. Tracing's dominant cost is
    /// the cache miss on the popped object (JSC keeps the same prefetch in
    /// SlotVisitor::popAndPrefetch and documents it as the top cost of GC
    /// marking); starting the next line's fetch while the current object's
    /// edges are walked hides most of it.
    pub inline fn popPrefetch(self: *MarkStack) ?*GCObjectHeader {
        if (self.len == 0) return null;
        self.len -= 1;
        const items = self.items.?;
        if (self.len != 0) {
            @prefetch(items[self.len - 1], .{ .rw = .read, .locality = 3, .cache = .data });
        }
        return items[self.len];
    }

    /// False when the stack is missing or full; the caller falls back to the
    /// shared ring.
    pub inline fn push(self: *MarkStack, h: *GCObjectHeader) bool {
        const items = self.items orelse return false;
        if (self.len == cap) return false;
        items[self.len] = h;
        self.len += 1;
        return true;
    }
};

/// Tracer-owned lifetime state in the tail of Metadata. Epoch 0 is reserved
/// for newborn/unmarked; the Registry epoch starts at 1. Husk is orthogonal to
/// marking: a weak object can outlive the major that stripped its resources,
/// so its death state must not alias an epoch value.
pub const TraceHeaderFlags = packed struct(u8) {
    husk: bool = false,
    reserved: u7 = 0,
};

/// Offset-6 byte ownership under trace_stw. Object's Shape projection owns the
/// low seven bits; the generational barrier owns the high remembered bit. Keep
/// these masks in gc.zig so header-only barrier code need not import Object.
pub const trace_object_shape_summary_mask: u8 = 0b0111_1111;
pub const trace_remembered_mask: u8 = 0b1000_0000;

/// Kinds whose byte-6 bit7 may carry the remembered-owner membership cache
/// (audit §10). Two exclusions, for two unrelated reasons:
///
///   * `.big_int` keeps a live `i32` in the SAME word (`LifetimeWord.rc`;
///     `resetHeaderLifetimeForPublication` special-cases it). byte 6 is that
///     count's third byte, so setting bit7 would be `rc += 0x800000`.
///   * `.string` has no `Metadata` prefix at all (`PrefixModel.string_rc`, a
///     bare four-byte count), so `header.meta()` does not name its memory.
///
/// What remains is exactly the `gc_obj_list` carrier set -- which is also
/// exactly the set that can reach `remember`/`forgetGenerationalOwner`, since
/// both are entered only through the barrier (Object/VarRef/Module/Realm/Shape
/// owners) and through `removeGcObjectAfter` (list members only). The contiguous
/// enum range makes the gate one unsigned compare, the same price as the
/// `== .object` test it replaces.
pub inline fn traceRememberedCacheEligible(kind: GcKind) bool {
    return @intFromEnum(kind) <= @intFromEnum(GcKind.shape);
}

comptime {
    // The range test above must stay the enumeration of the admitted kinds.
    for (std.meta.tags(GcKind)) |kind| {
        const expected = switch (kind) {
            .object, .function_bytecode, .var_ref, .realm_context, .module, .shape => true,
            .string, .big_int => false,
        };
        std.debug.assert(traceRememberedCacheEligible(kind) == expected);
        // Ineligibility must coincide with "not a gc_obj_list carrier", which
        // is what makes the two exclusions unreachable rather than merely
        // forbidden: `refKindDescriptor(...).cycle_candidate` is the same set.
        std.debug.assert(traceRememberedCacheEligible(kind) == refKindDescriptor(kind).cycle_candidate);
        // Only the admitted kinds have a Metadata prefix to lease a bit from.
        if (traceRememberedCacheEligible(kind))
            std.debug.assert(representationKindDescriptor(kind).prefix == .metadata);
    }
}

pub const TraceHeaderState = extern struct {
    mark_epoch: u16 = 0,
    /// Shared Object byte: low seven bits are the Shape trace projection; bit7
    /// is remembered-set membership. A native byte keeps both hot reads at a
    /// fixed offset. Object owns the summary encoding/mutation audit;
    /// gc_generation owns remembered. Non-Object carriers keep the LOW SEVEN
    /// bits zero -- the Shape projection is Object-only -- but every kind in
    /// `traceRememberedCacheEligible` may carry bit7 (audit §10).
    object_shape_summary: u8 = 0,
    flags: TraceHeaderFlags = .{},
};

/// Physical offset 4 is configuration/kind dependent. Default RC (and shadow)
/// use `rc` for every GC header. trace_stw uses `trace` for registry carriers,
/// while heap BigInt keeps `rc`: it is outside the tracing heap and the generic
/// JSValue retain/free ABI still reaches this exact payload-4 word.
pub const LifetimeWord = extern union {
    rc: i32,
    trace: TraceHeaderState,
};

/// qjs-style block-prefix metadata. The allocator-owned first four bytes keep
/// the JSMallocBlockHeader ABI. The tail is a lifetime union rather than a
/// shared refcount: tracer-owned carriers use a mark epoch + husk state there.
/// For slab-backed objects these 8 bytes ARE the allocator block header;
/// persistent/over-aligned objects keep a standalone prefix.
pub const Metadata = extern struct {
    /// Standalone prefix: encoded heap bytes. Slab overlay: allocator block
    /// index (or free-list link while free). Check alloc_info.standalone before
    /// interpreting this field as a heap size.
    size_class: u16 align(8) = 0,
    alloc_info: AllocInfo = .{},
    flags: BlockFlags = .{},
    lifetime: LifetimeWord = if (trace_stw_enabled)
        .{ .trace = .{} }
    else
        .{ .rc = 1 },
};

/// Size of the metadata prefix that precedes every GC object (objectPtr - 8).
pub const metadata_prefix_size: usize = @sizeOf(Metadata);

comptime {
    // The allocator initializes the prefix by raw byte writes (memory.zig has no
    // gc import); these offsets and bit positions must remain stable.
    std.debug.assert(@sizeOf(Metadata) == representation.metadata_size);
    std.debug.assert(@alignOf(Metadata) == 8);
    std.debug.assert(@offsetOf(Metadata, "size_class") == representation.metadata_size_class_offset);
    std.debug.assert(@offsetOf(Metadata, "alloc_info") == representation.metadata_alloc_info_offset);
    std.debug.assert(@offsetOf(Metadata, "flags") == representation.metadata_flags_offset);
    std.debug.assert(@offsetOf(Metadata, "lifetime") == representation.metadata_rc_offset);
    std.debug.assert(@sizeOf(LifetimeWord) == 4);
    std.debug.assert(@alignOf(LifetimeWord) == 4);
    std.debug.assert(@sizeOf(TraceHeaderState) == 4);
    std.debug.assert(@sizeOf(TraceHeaderFlags) == 1);
    std.debug.assert(@offsetOf(TraceHeaderState, "mark_epoch") == 0);
    std.debug.assert(@offsetOf(TraceHeaderState, "object_shape_summary") == 2);
    std.debug.assert(@offsetOf(TraceHeaderState, "flags") == 3);
    std.debug.assert(trace_object_shape_summary_mask | trace_remembered_mask == std.math.maxInt(u8));
    std.debug.assert(trace_object_shape_summary_mask & trace_remembered_mask == 0);
    std.debug.assert(@as(u8, @bitCast(AllocInfo{ .standalone = true })) == representation.alloc_info_standalone_mask);
    std.debug.assert(@as(u8, @bitCast(AllocInfo{ .heap_accounted = true })) == representation.alloc_info_heap_accounted_mask);
    std.debug.assert(@as(u8, @bitCast(AllocInfo{ .large = true })) == representation.alloc_info_large_mask);
    std.debug.assert(@as(u8, @bitCast(AllocInfo{ .block_size_idx = representation.block_cell_size_class })) == representation.block_cell_alloc_info);
    // Kind occupies the low 3 bits of the shared kind/flags byte; a bare tag
    // byte (all flags clear) equals the enum value, which is what the raw
    // prefix writers in memory.zig and object.zig store.
    std.debug.assert(@as(u8, @bitCast(BlockFlags{ .kind = .big_int })) == @intFromEnum(GcKind.big_int));
    std.debug.assert(@as(u8, @bitCast(BlockFlags{ .kind = .object, .mark = true })) == 1 << 3);
    std.debug.assert(@as(u8, @bitCast(BlockFlags{ .kind = .object, .young = true })) == 1 << 4);
    std.debug.assert(@as(u8, @bitCast(BlockFlags{ .kind = .object, .finalizing = true })) == 1 << 5);
    std.debug.assert(@as(u8, @bitCast(BlockFlags{ .kind = .object, .is_pinned = true })) == 1 << 6);
    std.debug.assert(@as(u8, @bitCast(BlockFlags{ .kind = .object, .cycle_visited = true })) == 1 << 7);
    // The contiguous kind ranges documented on RefKind.
    std.debug.assert(@intFromEnum(GcKind.object) == 0);
    std.debug.assert(@intFromEnum(GcKind.module) == 4 and @intFromEnum(GcKind.shape) == 5);
    std.debug.assert(@intFromEnum(GcKind.string) == 6 and @intFromEnum(GcKind.big_int) == 7);
}

/// In-object GC header = intrusive list links only (qjs `JSGCObjectHeader`,
/// 16 bytes). Lifetime state / kind / flags / optional heap-size live in the
/// Metadata prefix 8 bytes before this header; reach them via `meta()`.
pub const BlockHeader = extern struct {
    prev: ?*BlockHeader = null,
    next: ?*BlockHeader = null,

    comptime {
        std.debug.assert(@sizeOf(BlockHeader) == 16);
        std.debug.assert(@sizeOf(Metadata) == 8);
    }

    pub inline fn meta(self: *BlockHeader) *Metadata {
        return @ptrFromInt(@intFromPtr(self) - metadata_prefix_size);
    }

    pub inline fn metaConst(self: *const BlockHeader) *const Metadata {
        return @ptrFromInt(@intFromPtr(self) - metadata_prefix_size);
    }

    pub inline fn retain(self: *BlockHeader) void {
        if (comptime trace_stw_enabled) {
            if (refCountRemoved(self.metaConst().flags.kind)) return;
        }
        std.debug.assert(headerRefCount(self) > 0);
        incrementHeaderRefCount(self);
    }

    pub fn pinned(self: *const BlockHeader) bool {
        return self.metaConst().flags.is_pinned;
    }

    pub fn setPinned(self: *BlockHeader, value: bool) void {
        self.meta().flags.is_pinned = value;
    }
};

/// Trace-only compact carrier header.
///
/// The compatibility allocator metadata remains immediately before the
/// payload during this physical-layout tranche.  Traced nodes need only one
/// intrusive successor: collector partitioning always knows the owning list,
/// so removal can recover the predecessor from that cold list instead of
/// charging every live object a second pointer.  Ordinary Objects are never
/// on the list (the block bitmap enumerates them), making this word padding for
/// the hot population and shrinking `[Metadata + Object]` from 72 to 64 bytes.
pub const TraceHeader = extern struct {
    next: ?*TraceHeader = null,

    comptime {
        std.debug.assert(@sizeOf(TraceHeader) == 8);
        std.debug.assert(@sizeOf(Metadata) == 8);
    }

    pub inline fn meta(self: *TraceHeader) *Metadata {
        return @ptrFromInt(@intFromPtr(self) - metadata_prefix_size);
    }

    pub inline fn metaConst(self: *const TraceHeader) *const Metadata {
        return @ptrFromInt(@intFromPtr(self) - metadata_prefix_size);
    }

    pub inline fn retain(self: *TraceHeader) void {
        if (refCountRemoved(self.metaConst().flags.kind)) return;
        std.debug.assert(headerRefCount(self) > 0);
        incrementHeaderRefCount(self);
    }

    pub fn pinned(self: *const TraceHeader) bool {
        return self.metaConst().flags.is_pinned;
    }

    pub fn setPinned(self: *TraceHeader, value: bool) void {
        self.meta().flags.is_pinned = value;
    }
};

/// Common QuickJS-style refcount word. Every refcounted JSValue payload points
/// at its body, with this header at the fixed `payload - 4` offset (`__js_rc`
/// in quickjs.h). Strings and heap BigInt always use it. GC carriers use it in
/// RC/shadow builds; trace_stw reinterprets the same physical word as
/// `TraceHeaderState` and gates every raw JSValue retain/release before it.
pub const RefCountHeader = extern struct {
    rc: i32 = 1,

    comptime {
        std.debug.assert(@sizeOf(RefCountHeader) == 4);
    }

    pub inline fn retain(self: *RefCountHeader) void {
        std.debug.assert(self.rc > 0);
        self.rc += 1;
    }
};

/// Compatibility alias for the standalone prefix used by String/StringRope.
pub const StringHeader = RefCountHeader;

/// Byte size of the refcount prefix reserved ahead of every flat `String` and
/// `StringRope` allocation. Equal to `@sizeOf(StringHeader)` (4).
pub const string_rc_prefix_size: usize = @sizeOf(StringHeader);

/// Physical payload displacement of the four-byte lifetime word. It is an RC
/// word only for the kinds/configurations documented on `LifetimeWord`.
pub const ref_count_offset_from_payload: usize = @sizeOf(RefCountHeader);

pub inline fn refCountHeaderFromPayload(payload: *anyopaque) *RefCountHeader {
    const address = @intFromPtr(payload);
    std.debug.assert(address >= ref_count_offset_from_payload);
    return @ptrFromInt(address - ref_count_offset_from_payload);
}

comptime {
    // A GC value stores `BlockHeader *` in its payload. Metadata immediately
    // precedes that header, and its lifetime tail must land at the same
    // payload - 4 address used by strings, symbols, and ropes.
    std.debug.assert(metadata_prefix_size - @offsetOf(Metadata, "lifetime") == ref_count_offset_from_payload);
}

pub const Header = if (trace_stw_enabled) TraceHeader else BlockHeader;
pub const GCObjectHeader = Header;
pub const ObjectHeader = Header;

inline fn prefixRefCount(meta: *Metadata) *i32 {
    return &meta.lifetime.rc;
}

inline fn prefixRefCountConst(meta: *const Metadata) *const i32 {
    return &meta.lifetime.rc;
}

/// The authoritative count for kinds which retain RC semantics in this build.
/// Under trace_stw Shape and Realm moved their real count into existing body
/// padding; BigInt remains in the prefix because JSValue's payload-4 ABI owns
/// it. Calling this for a tracer-owned kind is a contract violation.
pub inline fn headerRefCount(h: *const Header) i32 {
    if (comptime !trace_stw_enabled) return prefixRefCountConst(h.metaConst()).*;
    return switch (h.metaConst().flags.kind) {
        .shape => blk: {
            const value: *const shape.Shape = @alignCast(@fieldParentPtr("header", h));
            break :blk value.ownership.trace_ref_count;
        },
        .realm_context => blk: {
            const value: *const context_mod.JSContext = @alignCast(@fieldParentPtr("header", h));
            break :blk value.traceRefCountPtrConst().*;
        },
        .big_int => prefixRefCountConst(h.metaConst()).*,
        .object, .function_bytecode, .var_ref, .module, .string => unreachable,
    };
}

pub inline fn setHeaderRefCount(h: *Header, value: i32) void {
    std.debug.assert(value >= 0);
    if (comptime !trace_stw_enabled) {
        prefixRefCount(h.meta()).* = value;
        return;
    }
    switch (h.metaConst().flags.kind) {
        .shape => {
            const owner: *shape.Shape = @alignCast(@fieldParentPtr("header", h));
            owner.ownership.trace_ref_count = value;
        },
        .realm_context => {
            const owner: *context_mod.JSContext = @alignCast(@fieldParentPtr("header", h));
            owner.traceRefCountPtr().* = value;
        },
        .big_int => prefixRefCount(h.meta()).* = value,
        .object, .function_bytecode, .var_ref, .module, .string => unreachable,
    }
}

pub inline fn incrementHeaderRefCount(h: *Header) void {
    const old = headerRefCount(h);
    std.debug.assert(old >= 0 and old < std.math.maxInt(i32));
    setHeaderRefCount(h, old + 1);
}

pub inline fn decrementHeaderRefCount(h: *Header) i32 {
    const old = headerRefCount(h);
    std.debug.assert(old > 0);
    const next = old - 1;
    setHeaderRefCount(h, next);
    return next;
}

pub inline fn headerRefCountIsZeroOrHusk(h: *const Header) bool {
    if (comptime trace_stw_enabled) {
        if (h.metaConst().flags.kind == .big_int)
            return prefixRefCountConst(h.metaConst()).* == 0;
        return h.metaConst().lifetime.trace.flags.husk;
    }
    return prefixRefCountConst(h.metaConst()).* == 0;
}

/// True when dropping the last WeakRef may reclaim the resource-stripped
/// object struct. RC distinguishes a finished husk from an in-progress
/// zero-ref teardown with the historical mark bit; trace_stw has an explicit
/// state bit and never routes tracer-owned objects through the zero-ref queue.
pub inline fn headerIsReclaimableWeakHusk(h: *const Header) bool {
    std.debug.assert(h.metaConst().flags.kind == .object);
    if (comptime trace_stw_enabled) return h.metaConst().lifetime.trace.flags.husk;
    return prefixRefCountConst(h.metaConst()).* == 0 and !h.metaConst().flags.mark;
}

pub inline fn setHeaderWeakHusk(h: *Header) void {
    std.debug.assert(h.metaConst().flags.kind == .object);
    if (comptime trace_stw_enabled) {
        std.debug.assert(!h.metaConst().alloc_info.heap_accounted);
        std.debug.assert(h.metaConst().lifetime.trace.flags.reserved == 0);
        // I4 ordering pin. The whole-byte store below also erases the
        // remembered-owner cache bit, so it MUST run after the object has left
        // the remembered map (`unregisterObjectWithBytes` ->
        // `forgetGenerationalOwner`). Hoisting husk marking above that
        // deregistration would leave bit=0/map=1 and make the forget-side skip
        // strand a dangling address -- silently, since nothing else reads the
        // bit on this path. Assert the invariant here instead.
        std.debug.assert(h.metaConst().lifetime.trace.object_shape_summary & trace_remembered_mask == 0);
        // Resource teardown has already released and replaced shape_ref. A
        // husk has no property graph, so do not retain a stale body projection.
        h.meta().lifetime.trace.object_shape_summary = 0;
        h.meta().lifetime.trace.flags.husk = true;
    } else {
        prefixRefCount(h.meta()).* = 0;
    }
}

inline fn resetHeaderLifetimeForPublication(h: *Header) void {
    if (comptime !trace_stw_enabled) {
        prefixRefCount(h.meta()).* = 1;
        return;
    }
    if (h.metaConst().flags.kind == .big_int) {
        prefixRefCount(h.meta()).* = 1;
        return;
    }
    h.meta().lifetime.trace = .{};
    switch (h.metaConst().flags.kind) {
        .shape, .realm_context => setHeaderRefCount(h, 1),
        else => {},
    }
}

inline fn assertInitialHeaderLifetime(h: *const Header) void {
    if (comptime !trace_stw_enabled) {
        std.debug.assert(prefixRefCountConst(h.metaConst()).* == 1);
        return;
    }
    if (h.metaConst().flags.kind == .big_int) {
        std.debug.assert(prefixRefCountConst(h.metaConst()).* == 1);
        return;
    }
    const state = h.metaConst().lifetime.trace;
    std.debug.assert(state.mark_epoch == 0);
    std.debug.assert(!state.flags.husk);
    std.debug.assert(state.flags.reserved == 0);
    // Only the Object-owned low seven bits must be newborn-zero. Bit7 is the
    // remembered-owner lease (audit §10) and a carrier can legitimately hold it
    // BEFORE publication: `module.Registry.prepareFreshTarget` calls
    // `rememberOwnerForBulkWrite` on the record and publishes it on the next
    // line, and an unpublished header reads `flags.young == false`, so the
    // barrier classifies it as old and remembers it. bit=1/map=1 there is
    // consistent, which is all I0 asks; it is simply not "initial".
    if (h.metaConst().flags.kind != .object)
        std.debug.assert(state.object_shape_summary & trace_object_shape_summary_mask == 0);
    switch (h.metaConst().flags.kind) {
        .shape, .realm_context => std.debug.assert(headerRefCount(h) == 1),
        else => {},
    }
}

/// Shape and Realm retain true refcount semantics under trace_stw, so a
/// mutator last-release may unlink them at an arbitrary list position. They
/// store the one backlink compact Header removed in body space made available
/// by that same shrink. Tracer-owned kinds are only detached by collector
/// cursor walks and intentionally carry no backlink.
inline fn storedListPrevious(h: *const Header) ?*Header {
    if (comptime !trace_stw_enabled) return h.prev;
    return switch (h.metaConst().flags.kind) {
        .shape => blk: {
            const owner: *const shape.Shape = @alignCast(@fieldParentPtr("header", h));
            break :blk owner.trace_list_previous.previous();
        },
        .realm_context => blk: {
            const owner: *const context_mod.JSContext = @alignCast(@fieldParentPtr("header", h));
            break :blk owner.traceListPreviousPtrConst().*;
        },
        else => null,
    };
}

inline fn setStoredListPrevious(h: *Header, previous: ?*Header) void {
    if (comptime !trace_stw_enabled) {
        h.prev = previous;
        return;
    }
    switch (h.metaConst().flags.kind) {
        .shape => {
            const owner: *shape.Shape = @alignCast(@fieldParentPtr("header", h));
            owner.trace_list_previous.setPrevious(previous);
        },
        .realm_context => {
            const owner: *context_mod.JSContext = @alignCast(@fieldParentPtr("header", h));
            owner.traceListPreviousPtr().* = previous;
        },
        else => {},
    }
}

/// Intrusive-list authority. RC keeps the QuickJS doubly-linked nodes; trace
/// uses the compact `Header.next` plus this per-list tail. The extra word is
/// paid once per list, never once per object.
pub const IntrusiveHeaderList = struct {
    sentinel: Header = .{},
    /// Empty lists point at their own sentinel. This keeps append/delete in
    /// the same branch-free shape as the old intrusive sentinel: `tail.next`
    /// is always writable, including for the first element.
    tail: ?*Header = null,
};

pub inline fn listInit(head: *IntrusiveHeaderList) void {
    if (comptime trace_stw_enabled) {
        head.sentinel.next = &head.sentinel;
        head.tail = &head.sentinel;
    } else {
        head.sentinel.prev = &head.sentinel;
        head.sentinel.next = &head.sentinel;
        head.tail = &head.sentinel;
    }
}

pub inline fn listEmpty(head: *const IntrusiveHeaderList) bool {
    return head.sentinel.next == @constCast(&head.sentinel);
}

pub inline fn listAddTail(head: *IntrusiveHeaderList, el: *Header) void {
    std.debug.assert(el.next == null);
    if (comptime trace_stw_enabled) {
        const previous = head.tail.?;
        el.next = &head.sentinel;
        previous.next = el;
        head.tail = el;
        setStoredListPrevious(el, previous);
    } else {
        std.debug.assert(el.prev == null);
        const prev = head.sentinel.prev.?;
        el.prev = prev;
        el.next = &head.sentinel;
        prev.next = el;
        head.sentinel.prev = el;
        head.tail = el;
    }
}

/// Append to a collector-private list whose every removal is performed by a
/// forward traversal already carrying the predecessor. Such lists never need
/// Shape/Realm's arbitrary-unlink backlink, so do not pay the kind dispatch
/// that maintains it on the allocation-ordered `gc_obj_list`.
pub inline fn listAddTailTraversalOwned(head: *IntrusiveHeaderList, el: *Header) void {
    if (comptime !trace_stw_enabled) {
        listAddTail(head, el);
        return;
    }
    std.debug.assert(el.next == null);
    const previous = head.tail.?;
    el.next = &head.sentinel;
    previous.next = el;
    head.tail = el;
}

/// Return the predecessor of `el` in `head`. RC reads the in-node backlink;
/// compact trace callers that do not already hold a traversal cursor pay one
/// cold forward scan.
pub inline fn listPrevious(head: *IntrusiveHeaderList, el: *Header) *Header {
    if (comptime trace_stw_enabled) {
        switch (el.metaConst().flags.kind) {
            .shape, .realm_context => {
                const previous = storedListPrevious(el) orelse unreachable;
                std.debug.assert(previous.next == el);
                return previous;
            },
            else => {},
        }
        var previous: *Header = &head.sentinel;
        while (previous.next != el) {
            previous = previous.next.?;
            std.debug.assert(previous != &head.sentinel);
        }
        return previous;
    }
    return el.prev.?;
}

/// Delete `el` when its predecessor is already known by the caller's forward
/// traversal. This is the normal compact-trace sweep primitive: one pointer
/// splice, never a search per corpse.
pub inline fn listDelAfter(head: *IntrusiveHeaderList, previous: *Header, el: *Header) void {
    if (comptime trace_stw_enabled) {
        std.debug.assert(previous.next == el);
        const next = el.next.?;
        previous.next = next;
        if (next != &head.sentinel) setStoredListPrevious(next, previous);
        head.tail = if (head.tail == el) previous else head.tail;
        // Linkage is already authoritatively cleared by `next = null` below.
        // ReleaseFast does not pay a second kind dispatch merely to scrub the
        // Shape/Realm acceleration slot of an object that is either destroyed
        // or immediately re-linked (which overwrites it). Keep the scrub in
        // safety builds so stale-backlink misuse still fails close to origin.
        if (std.debug.runtime_safety) setStoredListPrevious(el, null);
        el.next = null;
    } else {
        std.debug.assert(el.prev == previous);
        const prev = el.prev.?;
        const next = el.next.?;
        prev.next = next;
        next.prev = prev;
        head.tail = if (head.tail == el) prev else head.tail;
        el.prev = null;
        el.next = null;
    }
}

/// Traversal-owned counterpart to `listDelAfter`. The caller promises this is
/// not `gc_obj_list`: no mutator can arbitrarily unlink Shape/Realm nodes from
/// it, so successor backlinks are deliberately absent and need no repair.
pub inline fn listDelAfterTraversalOwned(head: *IntrusiveHeaderList, previous: *Header, el: *Header) void {
    if (comptime !trace_stw_enabled) {
        listDelAfter(head, previous, el);
        return;
    }
    std.debug.assert(previous.next == el);
    previous.next = el.next.?;
    head.tail = if (head.tail == el) previous else head.tail;
    el.next = null;
}

/// qjs `list_del` (list.h:69-78 / remove_gc_object at quickjs.c:6548).
/// Arbitrary compact-trace mutations recover the predecessor once. Sequential
/// collector walks must use `listDelAfter` so a sweep remains O(population).
pub inline fn listDel(head: *IntrusiveHeaderList, el: *Header) void {
    listDelAfter(head, listPrevious(head, el), el);
}

pub inline fn listFirst(head: *const IntrusiveHeaderList) ?*Header {
    const next = head.sentinel.next.?;
    if (next == @constCast(&head.sentinel)) return null;
    return next;
}

pub inline fn listLastAssumeNonEmpty(head: *const IntrusiveHeaderList) *Header {
    std.debug.assert(!listEmpty(head));
    return head.tail.?;
}

pub inline fn listSentinel(head: *const IntrusiveHeaderList) *const Header {
    return &head.sentinel;
}

pub inline fn headerLinked(header: *const Header) bool {
    if (comptime trace_stw_enabled) return header.next != null;
    return header.prev != null;
}

fn verifyCircularHeaderList(
    head: *IntrusiveHeaderList,
    expected_kind: ?GcKind,
    comptime verify_stored_previous: bool,
) InvariantError!usize {
    const sentinel = &head.sentinel;
    if (sentinel.next == null) return error.CorruptGcList;
    if (listEmpty(head)) {
        if (head.tail != sentinel) return error.CorruptGcList;
        if (comptime !trace_stw_enabled) {
            if (sentinel.prev != sentinel) return error.CorruptGcList;
        }
        return 0;
    }

    var tortoise = sentinel.next.?;
    var hare = sentinel.next.?;
    while (hare != sentinel) {
        hare = hare.next orelse return error.CorruptGcList;
        if (hare == sentinel) break;
        hare = hare.next orelse return error.CorruptGcList;
        tortoise = tortoise.next orelse return error.CorruptGcList;
        if (hare != sentinel and tortoise == hare) return error.CorruptGcList;
    }

    var count: usize = 0;
    var previous: *GCObjectHeader = sentinel;
    var current = sentinel.next;
    while (current) |node| {
        if (node == sentinel) break;
        if (expected_kind) |kind| {
            if (node.metaConst().flags.kind != kind) return error.DoomedBucketKindMismatch;
        }
        if (comptime trace_stw_enabled and verify_stored_previous) {
            switch (node.metaConst().flags.kind) {
                .shape, .realm_context => if (storedListPrevious(node) != previous)
                    return error.CorruptGcList,
                else => {},
            }
        }
        const next = node.next orelse return error.CorruptGcList;
        if (comptime !trace_stw_enabled) {
            if (node.prev != previous) return error.CorruptGcList;
            if (next.prev != node) return error.CorruptGcList;
        }
        previous = node;
        current = next;
        count += 1;
    }
    if (previous.next != sentinel or head.tail != previous) return error.CorruptGcList;
    if (comptime !trace_stw_enabled) {
        if (sentinel.prev != previous) return error.CorruptGcList;
    }
    return count;
}

/// Allocation-free temporary intrusive list for cycle partitioning and
/// Pass-B struct deferral. Same `Header.link` words as the Registry lists
/// (qjs reuses `JSGCObjectHeader.link`). Call `init()` in place after the
/// list reaches its stable address — the sentinel is self-referential.
/// See `Registry.cycle_deferred_frees`. Reuses the header's `next` link;
/// `prev` is left alone, and the header is off every other list by the time
/// it gets here (the resource pass detached it).
pub const DeferredFreeStack = struct {
    head: ?*GCObjectHeader = null,
    count: usize = 0,

    pub fn push(self: *DeferredFreeStack, header: *GCObjectHeader) void {
        header.next = self.head;
        self.head = header;
        self.count += 1;
    }

    pub fn pop(self: *DeferredFreeStack) ?*GCObjectHeader {
        const header = self.head orelse return null;
        self.head = header.next;
        header.next = null;
        if (comptime !trace_stw_enabled) header.prev = null;
        self.count -= 1;
        return header;
    }

    /// Pop storage that the caller is about to free. Unlike `pop`, this does
    /// not spend two stores detaching a header whose allocation is dead on
    /// the next instruction. A caller that decides to keep the entry (the
    /// weak-object husk case) must clear both links before returning it to the
    /// heap's observable population.
    pub fn popForFree(self: *DeferredFreeStack) ?*GCObjectHeader {
        const header = self.head orelse return null;
        self.head = header.next;
        self.count -= 1;
        return header;
    }
};

pub const HeaderList = struct {
    list: IntrusiveHeaderList = .{},
    count: usize = 0,

    pub fn init(self: *HeaderList) void {
        listInit(&self.list);
        self.count = 0;
    }

    pub fn append(self: *HeaderList, header: *Header) void {
        std.debug.assert(!headerLinked(header));
        listAddTail(&self.list, header);
        self.count += 1;
    }

    pub fn remove(self: *HeaderList, header: *Header) void {
        listDel(&self.list, header);
        std.debug.assert(self.count != 0);
        self.count -= 1;
    }

    pub fn popFront(self: *HeaderList) ?*Header {
        const header = listFirst(&self.list) orelse return null;
        self.remove(header);
        return header;
    }

    /// Successor of `header` on this list, or null at the sentinel.
    /// Mirrors `list_for_each_safe`'s saved `el1` (qjs:6797).
    pub fn nextAfter(self: *const HeaderList, header: *const Header) ?*Header {
        const next = header.next.?;
        if (next == &self.list.sentinel) return null;
        return next;
    }
};

const large_heap_size_class = std.math.maxInt(u16);

pub const FailureKind = enum(u8) {
    none = 0,
    out_of_memory = 1,
    payload_mark_failed = 2,
};

pub const CollectionError = error{
    OutOfMemory,
    PayloadMarkFailed,
};

pub const CollectionResult = struct {
    freed_objects: usize = 0,
    duration_ns: u64 = 0,
};

pub const InvariantError = error{
    CorruptGcList,
    /// `young_head` no longer names a node on `gc_obj_list` -- a detach path
    /// forgot the young-suffix anchor and the next minor would walk freed
    /// memory (the `unlinkObjectWithBytes` hole, 2026-08-25).
    DanglingYoungHead,
    NegativeRefCount,
    InvalidHeaderState,
    MarkBitLeftSet,
    DuplicateHeapAllocation,
    MissingHeapAllocation,
    HeapLiveBytesMismatch,
    OldLiveBytesMismatch,
    LargeObjectBytesMismatch,
    OldSpaceLiveBytesMismatch,
    LargeSpaceLiveBytesMismatch,
    DuplicateExternalMemoryToken,
    EmptyExternalMemoryToken,
    ExternalTokenBytesMismatch,
    LeakedExternalMemoryToken,
    DuplicatePinEntry,
    EmptyPinEntry,
    PinnedHeaderFlagMismatch,
    PinnedHeaderMissingEntry,
    PinEntryNotLive,
    YoungCountMismatch,
    RememberedCountMismatch,
    RememberedOwnerNotLive,
    RememberedOwnerYoung,
    RememberedCacheWithoutOwner,
    RememberedOwnerMissingCache,
    RetirementStateMismatch,
    RetirementYoungSurvivor,
    DoomedBucketKindMismatch,
    DoomedPendingMismatch,
    DoomedCursorMismatch,
    CorruptDeferredFreeStack,
    DeferredFreeRunInterleaved,
    DeferredBlockCellInvariant,
    DeferredFreeAuditOutOfMemory,
    ConstructionRootStateMismatch,
    RepresentationKindMismatch,
    RepresentationPrefixModelMismatch,
    RepresentationAllocationCarrierMismatch,
    RepresentationPrefixFieldMismatch,
    ObjectShapeSummaryMismatch,
    RepresentationCellIndexMismatch,
    MisalignedPropertyStorage,
    MissingObjectPropertyStorage,
    InvalidTrailingPropertyClass,
    InvalidTrailingPropertyLayout,
    InvalidTrailingPropertyCapacity,
    UndersizedTrailingObjectCell,
    DeferredPayloadRootNotLive,
    DeferredPayloadRootDoomed,
};

/// Publication state selects which prefix fields have meaning.  Keeping this
/// explicit prevents a checker from blessing an unpublished block cell using
/// the weaker rules for a live registry node (or treating a BigInt leaf as if
/// its lifecycle bits were meaningful merely because it has Metadata bytes).
pub const MetadataSemanticState = enum {
    registry_published,
    detached_leaf,
    construction_block_object,
};

/// Validate the semantics of the shared eight-byte prefix without
/// dereferencing the body.  The runtime representation audit calls this for
/// every published GC header; tests also drive the same predicate with a
/// copied prefix so each rule can be corrupted without damaging teardown.
pub fn verifyMetadataSemantics(
    meta: *const Metadata,
    expected_kind: GcKind,
    state: MetadataSemanticState,
) InvariantError!void {
    if (meta.flags.kind != expected_kind) return error.RepresentationKindMismatch;
    const descriptor = representationKindDescriptor(expected_kind);
    if (descriptor.prefix != .metadata) return error.RepresentationPrefixModelMismatch;

    const is_block_cell = meta.alloc_info.block_size_idx == representation.block_cell_size_class;
    switch (descriptor.allocation) {
        .block_slab_or_standalone => {},
        .slab_or_standalone => if (is_block_cell)
            return error.RepresentationAllocationCarrierMismatch,
        .string_family => return error.RepresentationPrefixModelMismatch,
    }
    if (is_block_cell and (meta.alloc_info.standalone or meta.alloc_info.large))
        return error.RepresentationAllocationCarrierMismatch;
    if (meta.alloc_info.standalone) {
        if (meta.alloc_info.block_size_idx != 0)
            return error.RepresentationAllocationCarrierMismatch;
    } else if (!is_block_cell and meta.alloc_info.block_size_idx >= memory.SmallObjectSlab.class_count) {
        return error.RepresentationAllocationCarrierMismatch;
    }
    // `large` is the registry's logical space/accounting class, not a
    // physical-allocation carrier bit. A FunctionBytecode header can be slab
    // backed while its FAM-sized heap footprint crosses the large threshold.
    if (meta.alloc_info.large and !meta.alloc_info.heap_accounted)
        return error.RepresentationPrefixFieldMismatch;

    switch (state) {
        .registry_published => {
            if (!refKindDescriptor(expected_kind).cycle_candidate or !meta.alloc_info.heap_accounted)
                return error.RepresentationPrefixFieldMismatch;
            if (meta.alloc_info.standalone and meta.size_class == 0)
                return error.RepresentationPrefixFieldMismatch;
            if (comptime trace_stw_enabled) {
                const lifetime = meta.lifetime.trace;
                if (lifetime.flags.husk or lifetime.flags.reserved != 0)
                    return error.RepresentationPrefixFieldMismatch;
                // The low seven bits are Object's Shape projection and must
                // stay zero on every other carrier. Bit7 is the remembered
                // cache, which audit §10 leased to every eligible kind: a
                // published `.shape`/`.var_ref` owner legitimately carries it.
                // Ineligible kinds keep the whole byte reserved (they cannot
                // reach `.registry_published` anyway -- neither is a cycle
                // candidate -- so this arm is belt-and-braces).
                if (expected_kind != .object) {
                    const permitted: u8 = if (traceRememberedCacheEligible(expected_kind))
                        trace_remembered_mask
                    else
                        0;
                    if (lifetime.object_shape_summary & ~permitted != 0)
                        return error.RepresentationPrefixFieldMismatch;
                }
            } else {
                if (meta.lifetime.rc < 0) return error.RepresentationPrefixFieldMismatch;
            }
        },
        .detached_leaf => {
            if (refKindDescriptor(expected_kind).cycle_candidate or meta.alloc_info.heap_accounted or meta.alloc_info.large)
                return error.RepresentationPrefixFieldMismatch;
            if (meta.flags.mark or meta.flags.young or meta.flags.finalizing or
                meta.flags.is_pinned or meta.flags.cycle_visited or meta.lifetime.rc <= 0)
            {
                return error.RepresentationPrefixFieldMismatch;
            }
        },
        .construction_block_object => {
            const initial_lifetime = if (comptime trace_stw_enabled)
                meta.lifetime.trace.mark_epoch == 0 and
                    meta.lifetime.trace.object_shape_summary == 0 and
                    !meta.lifetime.trace.flags.husk and
                    meta.lifetime.trace.flags.reserved == 0
            else
                meta.lifetime.rc == 1;
            if (expected_kind != .object or !is_block_cell or
                meta.alloc_info.heap_accounted or meta.alloc_info.standalone or
                meta.alloc_info.large or meta.flags.mark or meta.flags.young or
                meta.flags.finalizing or !meta.flags.is_pinned or
                meta.flags.cycle_visited or !initial_lifetime)
            {
                return error.RepresentationPrefixFieldMismatch;
            }
        },
    }
}

/// 19. GE Stats
/// Retained collection-round durations. Sized so a benchmark-scale run (the
/// V8 suite does ~880 rounds) keeps its whole history rather than a tail.
pub const pause_sample_capacity: usize = 1024;

/// Pause percentiles over the retained window. Absent when no round has
/// completed — an empty distribution is reported as null rather than as zeros,
/// so a caller cannot mistake "never collected" for "collected instantly".
pub const PauseDistribution = struct {
    samples: usize,
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    max_ns: u64,
};

/// Counters the collector actually maintains. Every field here has a write
/// site in `recordSuccess` / `recordFailure` / the zero-ref drain; refcount
/// traffic is deliberately uninstrumented because a counter on that path is
/// not cost-neutral (2026-08-11 ruling), and cycle *count* is absent because
/// the collector reports freed objects, not strongly-connected components.
pub const GeStats = struct {
    zero_ref_drains: usize = 0,

    cycle_gc_count: usize = 0,
    cycle_gc_time_ns: u64 = 0,
    failed_collections: usize = 0,
    last_failure: FailureKind = .none,
    last_collection_time_ns: u64 = 0,

    /// Major-pause durations retained for percentile reporting. An
    /// incremental cycle contributes several slices. The cap bounds memory;
    /// `pause_sample_count` is the lifetime sample count while the ring keeps
    /// only the most recent `pause_sample_capacity` pauses.
    pause_samples: [pause_sample_capacity]u64 = @splat(0),
    pause_sample_cursor: usize = 0,
    pause_sample_count: usize = 0,

    /// All collector entries, including minors. `cycle_gc_count` is completed
    /// majors; the generation stats carry completed minors. The core suite
    /// uses this one as its "did any collection run" oracle.
    collections: usize = 0,
    freed_objects: usize = 0,

    external_bytes: usize = 0,
    external_untracked_bytes: usize = 0,
    peak_external_bytes: usize = 0,
    external_alloc_count: usize = 0,
    external_free_count: usize = 0,
    external_invalid_release_count: usize = 0,
    allocation_debt: usize = 0,
    gc_request_count: usize = 0,
    /// Which rule set each post-collection threshold: the growth factor or
    /// the small-heap floor. Diagnostic.
    threshold_growth_hits: usize = 0,
    threshold_floor_hits: usize = 0,
    last_request_reason: ?RequestReason = null,
};

pub const Stats = struct {
    total_allocated_bytes: usize = 0,
    peak_allocated_bytes: usize = 0,
    heap_live_bytes: usize = 0,
    old_live_bytes: usize = 0,
    large_object_bytes: usize = 0,
    rss_bytes: usize = 0,
    cgroup_limit_bytes: usize = 0,

    old_allocated_bytes: usize = 0,
    old_alloc_count: usize = 0,
    large_allocated_bytes: usize = 0,
    large_alloc_count: usize = 0,

    external_bytes: usize = 0,
    external_untracked_bytes: usize = 0,
    peak_external_bytes: usize = 0,
    external_alloc_count: usize = 0,
    external_free_count: usize = 0,
    external_token_count: usize = 0,
    external_token_bytes: usize = 0,
    external_invalid_release_count: usize = 0,
    allocation_debt: usize = 0,

    /// All collector entries (`collections`) and completed majors
    /// (`major_gc_count`). Generation stats carry completed minors.
    collections: usize = 0,
    major_gc_count: usize = 0,
    major_gc_time_ns: u64 = 0,
    last_collection_time_ns: u64 = 0,
    zero_ref_drains: usize = 0,
    major_phase: MajorPhase = .idle,
    failed_collections: usize = 0,
    last_failure: FailureKind = .none,
    freed_objects: usize = 0,

    pinned_cell_count: usize = 0,
    weak_ref_count: usize = 0,
    finalizer_queue_length: usize = 0,
    pending_finalization_job_count: usize = 0,
    deferred_native_cleanup_count: usize = 0,
    deferred_native_cleanup_run_count: usize = 0,
    deferred_class_payload_finalizer_count: usize = 0,
    deferred_class_payload_finalizer_run_count: usize = 0,

    gc_request_count: usize = 0,
    pending_major: bool = false,
    pending_request_reason: ?RequestReason = null,
    pending_request_urgency: ?RequestUrgency = null,
    last_request_reason: ?RequestReason = null,
};

/// Z-GE Registry
pub const Registry = struct {
    /// K4: `phase` is read by every JSValue release (value.zig
    /// `freeObjectAssumeObject`/`free`, mirroring qjs `__JS_FreeValueRT`'s
    /// `gc_phase` check) — including the per-return function rc-- on the hot
    /// call path. QuickJS keeps `gc_phase` in the JSRuntime head
    /// (quickjs.c:342); zjs auto layout had pushed it to the Registry tail at
    /// rt+18-19KB, costing a `mov #imm` address materialization plus a cold
    /// cache line on every release (M1 dossier K4). `align(64)` pins it to
    /// Registry offset 0 and lifts the Registry field itself into JSRuntime's
    /// highest-alignment (front) bucket, so `rt.gc.phase` is a single
    /// imm-offset ldrb in the runtime's front cache lines.
    phase: Phase align(64) = .none,

    memory: *memory.MemoryAccount,
    policy: Policy = .{},

    // qjs `rt->gc_obj_list` / `rt->tmp_obj_list` / RC zero-ref queue.
    // Each is a cyclic sentinel (list.h). Call `initLists` after the Registry
    // reaches its stable address — sentinels are self-referential.
    gc_obj_list: IntrusiveHeaderList = .{},

    /// First young object in `gc_obj_list`, or null when nothing is young.
    /// See `youngIterator` for why the young set is a suffix.
    young_head: if (generation_enabled) ?*Header else void =
        if (generation_enabled) null else {},
    /// Predecessor of `young_head`. Compact trace nodes have no backlink, so
    /// retaining this one per-runtime cursor lets a minor detach a young list
    /// suffix in O(young) rather than searching from the list head per corpse.
    young_predecessor: if (generation_enabled) ?*Header else void =
        if (generation_enabled) null else {},
    tmp_obj_list: IntrusiveHeaderList = .{},
    zero_ref_list: IntrusiveHeaderList = .{},
    // No live-object counter: qjs add_gc_object/remove_gc_object
    // (quickjs.c:6540/6548) are pure list splices with no count scalar.
    // Diagnostics (`liveCount`) derive the count by walking, like
    // `liveCountKind` always has.
    // Header currently owned by the zero-ref drain. It has been detached from
    // both intrusive lists so its destructor may reuse the links, but remains
    // runtime-owned until the destructor performs final accounting/raw free.
    // `containsHeader` includes this slot so synchronous class finalizers see
    // the same live-object lifetime as qjs `free_object`.
    zero_ref_current: ?*GCObjectHeader = null,
    /// The header the tracing sweep has unlinked and is destroying right now.
    ///
    /// The refcounting path publishes the same fact as `zero_ref_current`, and
    /// `containsHeader` reads it so a synchronous class payload finalizer
    /// asking `JSRuntime.ownsObject` about its own object gets `true` while its
    /// callback runs. The sweep had no such window: it unlinks from
    /// `gc_obj_list` and destroys, so a host finalizer invoked from a
    /// collection was told the engine did not own the object it was being
    /// handed. Nothing else distinguishes the two paths to a host callback.
    sweep_current: ?*GCObjectHeader = null,
    external_tokens: []ExternalTokenEntry = &.{},
    external_tokens_capacity: usize = 0,
    next_external_token_id: u64 = 1,
    pin_entries: []PinEntry = &.{},
    pin_entries_capacity: usize = 0,

    major_phase: MajorPhase = .idle,
    major_reason: ?RequestReason = null,
    major_request: Request = .{},
    old_space: SpaceAccount = .{},
    large_space: SpaceAccount = .{},
    stats: GeStats = .{},

    // Pass-B struct-free deferral for cycle removal (qjs gc_zero_ref_count_list,
    // quickjs.c:6382/6797): during JS_GC_PHASE_REMOVE_CYCLES an object's
    // resources are torn down but its struct memory survives until every sibling
    // in the batch has run, so a sibling finalizer/decref never dereferences a
    // freed struct. The batch driver drains this list after the resource pass.
    /// Structs whose resources are gone and whose storage waits for pass B.
    ///
    /// A singly-linked LIFO, not the doubly-linked `HeaderList` it used to
    /// be. Nothing removes from the middle -- park at one end, drain from
    /// the same end -- and a doubly-linked splice per corpse is five memory
    /// operations where one suffices. The queue carries every destroyed
    /// object: 41 M of them on raytrace, 72 M on earley-boyer, and the drain
    /// measured at 34% of destruction's stopped time.
    ///
    /// Order does not matter here. Pass A already ran every destructor in
    /// the kind order that does matter; pass B only hands storage back.
    cycle_deferred_frees: DeferredFreeStack = .{},
    /// The arena-audit topology proof is invalidated once when a Pass-A
    /// producer sequence opens and remains valid while Pass B only removes a
    /// prefix. Do not invalidate this in `deferCycleStructFree`: that is one
    /// production-path store per corpse for a checker that only runs under
    /// `ZJS_GC_ARENA_AUDIT`.
    deferred_run_topology_verified: if (block_heap_enabled) bool else void =
        if (block_heap_enabled) false else {},
    /// Set only around `JSRuntime.deinit`'s teardown collections. The host has
    /// by contract released every handle and no mutator frame is live, so those
    /// collections are entitled to the precise root scan that
    /// `runObjectCycleRemovalWithValueRoots` already asks for -- production
    /// otherwise forces the conservative pass, and a stale native-stack slot
    /// pointing at a host-released Realm keeps it marked, which breaks the
    /// `context_head == null` teardown invariant once the tracer rather than
    /// refcounting owns object lifetime.
    host_quiescent: bool = false,

    /// Page-radix map of published GC objects. Void in production `rc`.
    /// The slab whose arena lifetimes this registry observes, for recovery.
    arena_slab: if (address_registry_enabled) ?*memory.SmallObjectSlab else void =
        if (address_registry_enabled) null else {},
    address_registry: if (address_registry_enabled) AddressRegistryTable else void =
        if (address_registry_enabled) .{} else {},

    /// Publication-size histogram for Stage 4 class freeze. Void in production `rc`.
    space_histogram: if (space_model_enabled) SpaceHistogram else void =
        if (space_model_enabled) .{} else {},

    /// Logical 64 KiB window sweep machine. Void in production `rc`.
    sweep_model: if (sweep_model_enabled) SweepModel else void =
        if (sweep_model_enabled) .{} else {},

    /// 64 KiB block heap. Void unless `-Dzjs_experimental_gc=trace_stw`.
    // The concurrent mark queue and marker worker are *not* fields here.
    //
    // Embedding them made the OOM canary "binding Realm construction
    // rollback and retry" abort: a partially constructed Registry that is
    // rolled back after an injected allocation failure has to be safe to tear
    // down, and every field added to it widens that obligation. Neither has a
    // production caller yet -- the concurrent major is driven on the owner
    // thread -- so the honest place for them is beside the collector that
    // will own them, allocated when a concurrent cycle starts.
    //
    // This is the same lesson as the 32 KB embedded ring, one level up: what
    // a Registry contains is paid for by every runtime, including the ones
    // that fail halfway through construction.
    concurrent: if (concurrent_enabled) ConcurrentState else void =
        if (concurrent_enabled) .{} else {},
    /// Current mark epoch for non-block trace carriers. Epoch 0 is reserved
    /// for newborn/unmarked; a major advances this scalar, while minors keep
    /// it fixed so sticky survivor marks remain valid. Unlike a global parity
    /// flip, a stale nonzero epoch cannot make a newborn (0) read marked.
    /// Default RC/shadow builds keep the historical `flags.mark` bit instead.
    header_mark_epoch: if (trace_stw_enabled) u16 else void =
        if (trace_stw_enabled) 1 else {},

    /// Condemned by an incremental cycle's finish, awaiting sliced
    /// destruction at later polls.
    ///
    /// Everything here is unreachable (the remark's full trace proved it) and
    /// weak-cleared (processWeak ran first), so the mutator cannot reach it,
    /// cannot re-derive a pointer to it, and cannot observe its destruction
    /// order. What CAN still find it is a conservative scan: a parked corpse
    /// keeps `heap_accounted` until its destructor runs, so a stale stack word
    /// would resolve it and the tracer would walk freed payloads. That is why
    /// minors and new cycles are gated while this list is non-empty -- no
    /// collection, no scan, no resurrection-by-residue.
    /// The morgue, split by kind at condemnation.
    ///
    /// Destruction has to run objects before realms before modules before
    /// bytecode before var_refs before shapes, and it used to get that order
    /// by walking ONE list once per kind: a corpse of the last kind was
    /// stepped over five times before its own pass reached it, and each of
    /// those steps was a list-node dereference and a budget counter tick.
    /// Bucketing at condemnation costs nothing extra -- that pass already
    /// visits every corpse -- and makes destruction visit each exactly once.
    /// Indexed by `@intFromEnum(kind)`.
    doomed_by_kind: [gc_kind_count]IntrusiveHeaderList = @splat(.{}),
    /// Sliced-destruction cursor: which kind pass and where in the list.
    /// The list is stable between slices -- the mutator cannot touch it -- so
    /// a plain cursor resumes exactly where the budget ran out.
    doomed_phase: u8 = 0,
    /// Resume point within the current phase. Sound to hold across slices
    /// because nothing touches the list between them: collections are gated
    /// and the mutator has no path to a condemned object.
    doomed_cursor: ?*GCObjectHeader = null,
    doomed_pending: bool = false,
    /// Objects destroyed by the slices of the current morgue, for the
    /// completion poll's CollectionResult.
    doomed_destroyed: usize = 0,
    /// Heap bytes the morgue holds: already condemned, not yet returned.
    /// The growth threshold subtracts this at finish -- pricing the next
    /// cycle off a heap full of corpses was a compounding feedback loop
    /// (measured: an 841 MB peak on a ~50 MB live set).
    doomed_bytes: usize = 0,

    /// Objects the marking barrier shaded GREY: marked, children still to be
    /// traced. The remark drains it; overflow downgrades to a rescan of every
    /// marked object (`gc_trace_stw.drainBarrierQueue`). Lives on the Registry
    /// rather than in `concurrent.State` so the barrier reaches it without an
    /// import cycle through `gc_mark_queue`.
    concurrent_mark_queue: if (concurrent_enabled) mark_queue.Queue else void =
        if (concurrent_enabled) .{} else {},
    /// The owner's private mark stack: LIFO, plain array operations, no
    /// atomics. The tracing hot loop lives here; the shared ring above
    /// carries only barrier greys and root seeds (and, under parallel
    /// slices, spilled work). It persists across slices -- the mutator
    /// never touches it -- so a budget-exhausted slice parks its frontier
    /// in place instead of paying a drain-back. Fixed capacity, lazily
    /// allocated; on overflow half spills to the ring, whose own overflow
    /// downgrades to rescan. A marker that allocates per-object is a marker
    /// that can fail mid-phase, hence no growable list.
    mark_stack: if (concurrent_enabled) MarkStack else void =
        if (concurrent_enabled) .{} else {},
    generation: if (generation_enabled) GenerationState else void =
        if (generation_enabled) .{} else {},
    sticky_major: if (sticky_major_enabled) StickyMajorState else void =
        if (sticky_major_enabled) .{} else {},
    block_heap: if (block_heap_enabled) BlockHeap else void =
        if (block_heap_enabled) .init(std.heap.page_allocator) else {},

    pub fn init(account: *memory.MemoryAccount, policy: Policy) Registry {
        readStressFromEnv();
        return .{
            .memory = account,
            .policy = policy,
            .old_space = .{},
            .large_space = .{},
            // Off the JS heap deliberately. Backing the block heap with the
            // account allocator means OOM injection reaches it, and a
            // rollback then tears down structures whose allocation never
            // succeeded -- which is what the Realm-construction canary
            // caught. Its memory is not JS-visible, so it does not belong on
            // the injected path in the first place.
            .block_heap = if (comptime block_heap_enabled)
                BlockHeap.init(std.heap.page_allocator)
            else {},
        };
    }

    /// Bind cyclic sentinels after the Registry is in its final location
    /// (qjs `init_list_head` on `JSRuntime` fields). Must run before any
    /// header is published.
    pub fn initLists(self: *Registry) void {
        listInit(&self.gc_obj_list);
        listInit(&self.tmp_obj_list);
        listInit(&self.zero_ref_list);
        for (&self.doomed_by_kind) |*head| listInit(head);
        self.cycle_deferred_frees = .{};
        if (comptime block_heap_enabled) self.deferred_run_topology_verified = false;
    }

    /// Park a resource-stripped GC object's struct for the Pass-B drain. The
    /// header is already unlinked from the GC object list by the resource pass.
    pub fn deferCycleStructFree(self: *Registry, header: *GCObjectHeader) void {
        header.meta().flags.finalizing = true;
        self.cycle_deferred_frees.push(header);
    }

    /// Open one Pass-A producer sequence for the deferred-free stack. Pass A
    /// completes before any Pass-B drain, so one audit-only invalidation covers
    /// every park in the sequence without taxing every dead object.
    pub inline fn beginDeferredFreeProducerSequence(self: *Registry) void {
        if (comptime !block_heap_enabled) return;
        if (arena_audit) self.deferred_run_topology_verified = false;
    }

    pub fn popCycleDeferredFree(self: *Registry) ?*GCObjectHeader {
        return self.cycle_deferred_frees.pop();
    }

    /// Prove the implicit Pass-B block-run representation before its first
    /// consumer slice. A nested destructor park may legally use the same
    /// header stack, but it must not split a block run or insert a generic
    /// header into the block suffix. Finding either shape is the explicit
    /// signal to stop and review the reentrancy before introducing the
    /// per-run-descriptor fallback described by the joint design.
    pub fn verifyDeferredFreeRunTopology(self: *Registry) InvariantError!void {
        if (comptime !block_heap_enabled) return;
        if (!arena_audit or self.deferred_run_topology_verified) return;

        var seen_blocks: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer seen_blocks.deinit(std.heap.page_allocator);
        var saw_block_suffix = false;
        var current_block_base: ?usize = null;
        var cursor = self.cycle_deferred_frees.head;
        while (cursor) |header| : (cursor = header.next) {
            if (!isBlockCellHeader(header)) {
                if (saw_block_suffix) return error.DeferredFreeRunInterleaved;
                continue;
            }
            saw_block_suffix = true;
            if (header.metaConst().flags.kind != .object or
                !header.metaConst().flags.finalizing)
            {
                return error.DeferredBlockCellInvariant;
            }
            const cell_addr = @intFromPtr(header) - metadata_prefix_size;
            const block = self.block_heap.blockOf(@ptrFromInt(cell_addr)) orelse
                return error.DeferredBlockCellInvariant;
            const cell_index = block.cellIndex(cell_addr) orelse
                return error.DeferredBlockCellInvariant;
            if (!block.cellAllocated(cell_index)) return error.DeferredBlockCellInvariant;

            const block_base = @intFromPtr(block);
            if (current_block_base == block_base) continue;
            if (seen_blocks.contains(block_base)) return error.DeferredFreeRunInterleaved;
            seen_blocks.put(std.heap.page_allocator, block_base, {}) catch
                return error.DeferredFreeAuditOutOfMemory;
            current_block_base = block_base;
        }
        self.deferred_run_topology_verified = true;
    }

    pub fn deinit(self: *Registry, rt: anytype) void {
        if (comptime concurrent_enabled) {
            self.abortCycleEnvelope();
            self.invalidateCycleEnvelopeBaseline();
        }
        std.debug.assert(listEmpty(&self.zero_ref_list));
        std.debug.assert(self.zero_ref_current == null);
        self.phase = .deinit;

        // Phase 1: free object resources. Function bytecodes, Shapes, and
        // VarRefs are spliced into holding stacks (reusing their now-unused
        // `next` link).
        // Shapes must outlive objects that own shape_ref. VarRef structs must
        // outlive object properties and bytecode capture arrays that still own
        // cell pointers; release their owned values now, while those values'
        // GC headers are still structurally valid.
        //
        // FunctionBytecode metadata must also outlive every closure object:
        // JSObject stores only the var_refs pointer and derives its allocation
        // length from the FB, exactly as qjs `free_object` does. GC list order
        // is not an ownership order (a prior collection may move nodes), so
        // tearing down an FB as soon as it appears can zero closure_var_count before
        // a later closure frees its capture-pointer allocation. Keep FB
        // resources intact until all Object resource passes have run. Object
        // and FB structs themselves are deferred until Shapes have released
        // their prototype edges, so those later releases never touch freed
        // headers.
        // (qjs avoids the ordering hazard via its mark/decref cycle collector;
        // we keep zjs's explicit teardown but defer these structs.)
        var held_shapes: ?*GCObjectHeader = null;
        var held_var_refs: ?*GCObjectHeader = null;
        var held_function_bytecodes: ?*GCObjectHeader = null;
        while (!listEmpty(&self.gc_obj_list)) {
            // Compact trace has no backlink on tracer-owned kinds. Teardown
            // order is mediated by the holding stacks below, not list order,
            // so consume its head and keep every detach O(1). RC retains qjs's
            // tail walk and its in-node backlinks.
            const h = if (comptime trace_stw_enabled)
                listFirst(&self.gc_obj_list).?
            else
                listLastAssumeNonEmpty(&self.gc_obj_list);
            if (h.meta().flags.kind == .shape) {
                self.removeGcObject(h);
                h.next = held_shapes;
                held_shapes = h;
                continue;
            }
            if (h.meta().flags.kind == .var_ref) {
                self.removeGcObject(h);
                h.meta().flags.finalizing = true;
                var_ref.VarRef.prepareForRuntimeDeinit(rt, h);
                h.next = held_var_refs;
                held_var_refs = h;
                continue;
            }
            self.removeGcObject(h);
            self.recordHeapFreeWithBytes(h, heapByteSizeFromHeader(rt, h));
            h.meta().flags.finalizing = true;
            if (h.meta().flags.kind == .function_bytecode) {
                h.next = held_function_bytecodes;
                held_function_bytecodes = h;
                continue;
            }
            switch (h.meta().flags.kind) {
                .object => object.Object.destroyFromHeader(rt, h),
                .realm_context => context_mod.JSContext.destroyFromHeader(rt, h),
                .module => module_mod.ModuleRecord.destroyFromHeader(rt, h),
                else => unreachable,
            }
            rt.drainDeferredClassPayloadFinalizers();
        }

        // Phase 2: every closure has consumed its FB-owned capture count. FB
        // resources may now release constant-pool object edges; Object structs
        // remain parked in cycle_deferred_frees until after Shape teardown.
        while (held_function_bytecodes) |h| {
            const next = h.next;
            h.next = null;
            function_bytecode_mod.destroyFromHeader(rt, h);
            held_function_bytecodes = next;
        }

        // Phase 3: every cell owner is gone. Their releases were suppressed by
        // the deinit phase/finalizing bit, so reclaim each prepared cell struct
        // exactly once regardless of its residual refcount.
        while (held_var_refs) |h| {
            const next = h.next;
            h.next = null;
            self.recordHeapFreeWithBytes(h, heapByteSizeFromHeader(rt, h));
            var_ref.VarRef.freeCycleDeferredStruct(rt, h);
            held_var_refs = next;
        }

        // Phase 4: every object's resources are gone, but its struct remains
        // valid while held shapes release prototype edges. `destroyShape`
        // self-removes from the GC list (guarded no-op here) and frees property
        // storage + bucket links.
        while (held_shapes) |h| {
            const next = h.next;
            h.next = null;
            rt.shapes.destroyFromHeader(h);
            held_shapes = next;
        }

        // Phase 5: all resource destructors and late Shape releases are done;
        // reclaim the parked Object/FunctionBytecode structs.
        object.Object.drainCycleDeferredFrees(rt);
        rt.shapes.deinit();

        listInit(&self.gc_obj_list);
        listInit(&self.tmp_obj_list);
        listInit(&self.zero_ref_list);

        std.debug.assert(self.cycle_deferred_frees.count == 0);
        if (self.external_tokens_capacity != 0) {
            self.memory.free(ExternalTokenEntry, self.external_tokens.ptr[0..self.external_tokens_capacity]);
        } else if (self.external_tokens.len != 0) {
            self.memory.free(ExternalTokenEntry, self.external_tokens);
        }
        self.external_tokens = &.{};
        self.external_tokens_capacity = 0;
        if (self.pin_entries_capacity != 0) {
            self.memory.free(PinEntry, self.pin_entries.ptr[0..self.pin_entries_capacity]);
        } else if (self.pin_entries.len != 0) {
            self.memory.free(PinEntry, self.pin_entries);
        }
        self.pin_entries = &.{};
        self.pin_entries_capacity = 0;

        if (comptime address_registry_enabled) {
            self.address_registry.deinit(addressRegistryAllocator());
            if (comptime generation_enabled) self.generation.deinit(addressRegistryAllocator());
        }
        if (comptime concurrent_enabled) self.concurrent_mark_queue.deinit(addressRegistryAllocator());
        if (comptime concurrent_enabled) self.mark_stack.deinitStack();
        if (comptime sweep_model_enabled) {
            self.sweep_model.deinit(addressRegistryAllocator());
        }
        if (comptime block_heap_enabled) {
            self.block_heap.deinit();
        }

        self.phase = .none;
    }

    pub fn reportExternalAlloc(self: *Registry, bytes: usize) !ExternalMemoryToken {
        if (bytes == 0) return .{};
        try self.ensureExternalTokenCapacity(self.external_tokens.len + 1);
        const id = self.nextExternalTokenId();
        self.external_tokens.ptr[self.external_tokens.len] = .{
            .id = id,
            .bytes = bytes,
        };
        self.external_tokens = self.external_tokens.ptr[0 .. self.external_tokens.len + 1];
        self.stats.external_bytes = std.math.add(usize, self.stats.external_bytes, bytes) catch std.math.maxInt(usize);
        self.stats.peak_external_bytes = @max(self.stats.peak_external_bytes, self.stats.external_bytes);
        self.stats.external_alloc_count +|= 1;
        const weighted = std.math.mul(usize, bytes, self.policy.external_weight) catch std.math.maxInt(usize);
        self.stats.allocation_debt = std.math.add(usize, self.stats.allocation_debt, weighted) catch std.math.maxInt(usize);
        return .{
            .registry = self,
            .id = id,
            .bytes = bytes,
        };
    }

    /// Logical byte classification for storage already carried by an
    /// accounted GC payload (currently only BufferPayload's inline bytes).
    /// It intentionally creates no token and performs no immediate external
    /// pressure check. Real off-account backing must use
    /// `reportExternalAlloc` so it cannot bypass the major request seam.
    pub fn reportExternalAllocUntracked(self: *Registry, bytes: usize) void {
        if (bytes == 0) return;
        self.stats.external_bytes = std.math.add(usize, self.stats.external_bytes, bytes) catch std.math.maxInt(usize);
        self.stats.external_untracked_bytes = std.math.add(usize, self.stats.external_untracked_bytes, bytes) catch std.math.maxInt(usize);
        self.stats.peak_external_bytes = @max(self.stats.peak_external_bytes, self.stats.external_bytes);
        self.stats.external_alloc_count +|= 1;
        const weighted = std.math.mul(usize, bytes, self.policy.external_weight) catch std.math.maxInt(usize);
        self.stats.allocation_debt = std.math.add(usize, self.stats.allocation_debt, weighted) catch std.math.maxInt(usize);
    }

    /// Legacy raw live-ledger decrement. This does not discharge an
    /// `ExternalMemoryToken`; tracked callers must call `token.release()` so
    /// the registry entry and live bytes move together. No in-tree caller
    /// uses this raw hook.
    pub fn reportExternalFree(self: *Registry, bytes: usize) void {
        if (bytes == 0) return;
        self.stats.external_bytes -|= bytes;
        self.stats.external_free_count +|= 1;
    }

    pub fn reportExternalFreeUntracked(self: *Registry, bytes: usize) void {
        if (bytes == 0) return;
        self.stats.external_bytes -|= bytes;
        self.stats.external_untracked_bytes -|= bytes;
        self.stats.external_free_count +|= 1;
        // Only the live ledger is reversible; see `releaseExternalToken`.
    }

    pub fn releaseExternalToken(self: *Registry, id: u64, bytes: usize) void {
        if (id == 0 or bytes == 0) {
            if (id != 0 or bytes != 0) self.stats.external_invalid_release_count +|= 1;
            return;
        }
        const index = self.externalTokenIndex(id) orelse {
            self.stats.external_invalid_release_count +|= 1;
            return;
        };
        const entry = self.external_tokens[index];
        if (entry.bytes != bytes) {
            self.stats.external_invalid_release_count +|= 1;
            return;
        }
        // `external_bytes` is the live-pressure ledger and is symmetric.
        // `allocation_debt` is deliberately different: it is weighted bytes
        // allocated since the last completed major, so a free does not erase
        // allocation churn that already happened. `resetAllocationDebt`
        // clears that cumulative pacing signal after the major has paid it.
        self.stats.external_bytes -|= entry.bytes;
        self.stats.external_free_count +|= 1;
        if (index + 1 < self.external_tokens.len) {
            std.mem.copyForwards(
                ExternalTokenEntry,
                self.external_tokens[index .. self.external_tokens.len - 1],
                self.external_tokens[index + 1 ..],
            );
        }
        self.external_tokens = self.external_tokens[0 .. self.external_tokens.len - 1];
    }

    pub fn externalMemoryRequestReason(self: Registry) ?RequestReason {
        if (self.policy.external_hard_limit) |limit| {
            if (self.stats.external_bytes >= limit) return .external_memory;
        }
        if (self.stats.allocation_debt >= self.policy.major_debt_threshold) return .allocation_debt;
        if (self.policy.external_soft_limit) |limit| {
            if (self.stats.external_bytes >= limit) return .external_memory;
        }
        return null;
    }

    pub fn externalMemoryRequestUrgency(self: Registry) RequestUrgency {
        if (self.policy.external_hard_limit) |limit| {
            if (self.stats.external_bytes >= limit) return .urgent;
        }
        return .soon;
    }

    pub fn processMemoryRequest(self: Registry, rss_bytes: usize, cgroup_limit_bytes: usize) ?PressureRequest {
        if (self.policy.rss_hard_limit) |limit| {
            if (rss_bytes >= limit) return .{ .reason = .rss_pressure, .urgency = .urgent };
        }
        if (self.policy.cgroup_hard_ratio_per_mille != 0 and cgroup_limit_bytes != 0 and ratioPerMille(rss_bytes, cgroup_limit_bytes) >= self.policy.cgroup_hard_ratio_per_mille) {
            return .{ .reason = .rss_pressure, .urgency = .urgent };
        }
        if (self.policy.rss_soft_limit) |limit| {
            if (rss_bytes >= limit) return .{ .reason = .rss_pressure, .urgency = .soon };
        }
        if (self.policy.cgroup_soft_ratio_per_mille != 0 and cgroup_limit_bytes != 0 and ratioPerMille(rss_bytes, cgroup_limit_bytes) >= self.policy.cgroup_soft_ratio_per_mille) {
            return .{ .reason = .rss_pressure, .urgency = .soon };
        }
        return null;
    }

    pub fn requestGC(self: *Registry, reason: RequestReason, urgency: RequestUrgency) void {
        self.stats.gc_request_count +|= 1;
        self.stats.last_request_reason = reason;
        const slot = &self.major_request;
        if (!slot.pending) {
            slot.* = .{
                .pending = true,
                .reason = reason,
                .urgency = urgency,
            };
            return;
        }
        if (urgency == .urgent and slot.urgency != .urgent) {
            slot.urgency = .urgent;
            slot.reason = reason;
            return;
        }
        // An allocation-threshold request is level-triggered: the live-byte
        // condition may disappear before the next scheduler boundary. Do not
        // let that weak request hide an independently requested same-urgency
        // collection, because the allocation boundary may later discard only
        // the stale threshold request.
        if (slot.reason == .allocation_threshold and reason != .allocation_threshold) {
            slot.reason = reason;
            return;
        }
        if (slot.reason == null) slot.reason = reason;
    }

    pub fn hasPendingRequest(self: Registry) bool {
        return self.major_request.pending;
    }

    pub fn hasPendingMajorRequest(self: Registry) bool {
        return self.major_request.pending;
    }

    pub fn pendingMajorRequest(self: Registry) ?Request {
        return if (self.major_request.pending) self.major_request else null;
    }

    pub fn clearMajorRequest(self: *Registry) ?Request {
        if (!self.major_request.pending) return null;
        const request = self.major_request;
        self.major_request = .{};
        return request;
    }

    pub fn clearStaleAllocationThresholdRequest(self: *Registry) bool {
        const request = self.pendingMajorRequest() orelse return false;
        if (request.reason != .allocation_threshold or request.urgency != .soon) return false;
        self.major_request = .{};
        return true;
    }

    pub fn sliceBudgetNs(self: Registry, point: SchedulerPoint) u64 {
        return switch (point) {
            .allocation_slow_path => self.policy.allocation_slow_path_budget_ns,
            .callback_boundary, .safepoint => self.policy.callback_slice_budget_ns,
            .idle => self.policy.idle_slice_budget_ns,
            .urgent => self.policy.allocation_slow_path_budget_ns,
        };
    }

    pub fn shouldRunMajorAt(self: Registry, point: SchedulerPoint, over_threshold: bool) bool {
        if (comptime trace_stw_enabled) {
            if (stress_disable) return false;
        }
        if (point == .urgent or over_threshold) return true;
        const request = self.pendingMajorRequest() orelse return false;
        return switch (point) {
            .allocation_slow_path, .idle => true,
            .callback_boundary, .safepoint => request.urgency == .urgent,
            .urgent => true,
        };
    }

    pub fn beginMajorCycle(self: *Registry, reason: RequestReason) void {
        if (self.major_phase != .idle) {
            if (self.major_reason == null) self.major_reason = reason;
            return;
        }
        self.major_phase = .mark_roots;
        self.major_reason = reason;
    }

    pub fn setMajorPhase(self: *Registry, phase: MajorPhase) void {
        if (self.major_phase == .idle and phase != .idle) return;
        self.major_phase = phase;
    }

    pub fn activeMajorReason(self: Registry) ?RequestReason {
        return self.major_reason;
    }

    pub fn abortMajorCycle(self: *Registry) void {
        self.major_phase = .idle;
        self.major_reason = null;
    }

    pub fn finishMajorCycle(self: *Registry) void {
        self.major_phase = .idle;
        self.major_reason = null;
    }

    pub fn resetAllocationDebt(self: *Registry) void {
        self.stats.allocation_debt = 0;
    }

    /// Percentiles over the retained round durations, or null if no round has
    /// completed. Sorts a stack copy: this is a diagnostic call, not a hot
    /// path, and sorting in place would reorder the live ring.
    pub fn pauseDistribution(self: *const Registry) ?PauseDistribution {
        const retained = @min(self.stats.pause_sample_count, pause_sample_capacity);
        if (retained == 0) return null;
        var scratch: [pause_sample_capacity]u64 = undefined;
        @memcpy(scratch[0..retained], self.stats.pause_samples[0..retained]);
        const window = scratch[0..retained];
        // Percentiles depend only on value order; equal samples have no
        // identity, so the large stable block-sort implementation buys no
        // observable behavior on this cold diagnostic path.
        std.sort.heap(u64, window, {}, std.sort.asc(u64));
        return .{
            .samples = self.stats.pause_sample_count,
            .p50_ns = window[percentileIndex(retained, 50)],
            .p95_ns = window[percentileIndex(retained, 95)],
            .p99_ns = window[percentileIndex(retained, 99)],
            .max_ns = window[retained - 1],
        };
    }

    /// Nearest-rank index: the smallest sample at or above the percentile.
    fn percentileIndex(len: usize, percentile: usize) usize {
        const rank = (len * percentile + 99) / 100;
        return @min(if (rank == 0) 0 else rank - 1, len - 1);
    }

    pub fn statsSnapshot(self: *const Registry, rt: anytype) Stats {
        const snapshot = self.*;
        // The space accounts are the byte source of truth. Counts are split by
        // walking the already-maintained GC object list; this cold snapshot work
        // keeps scalar count updates off the allocation paths.
        const old_live = snapshot.old_space.live_bytes;
        const large_live = snapshot.large_space.live_bytes;
        const derived_heap_live = old_live +| large_live;
        var derived_old_count: usize = 0;
        var derived_large_count: usize = 0;
        // Walk the live Registry, not the by-value snapshot: nodes' prev/next
        // point at this sentinel, not a copied dummy Header.
        var iterator = self.objectIterator();
        while (iterator.next()) |header| {
            const bytes = heapByteSizeFromHeader(rt, header);
            if (snapshot.isLargeAllocation(bytes)) {
                derived_large_count +|= 1;
            } else {
                derived_old_count +|= 1;
            }
        }
        return .{
            .total_allocated_bytes = derived_heap_live,
            // The account's real high-water, not live again. This field
            // printed `live` for its whole history, which is why the §1.3
            // peak/live rows had no instrument: peak == live == allocated on
            // every panel ever captured. Whole-account rather than heap-only,
            // which errs on the reporting-more side.
            .peak_allocated_bytes = rt.memory.peak_allocated_bytes,
            .heap_live_bytes = derived_heap_live,
            .old_live_bytes = old_live,
            .large_object_bytes = large_live,
            .old_allocated_bytes = old_live,
            .old_alloc_count = derived_old_count,
            .large_allocated_bytes = large_live,
            .large_alloc_count = derived_large_count,
            .external_bytes = snapshot.stats.external_bytes,
            .external_untracked_bytes = snapshot.stats.external_untracked_bytes,
            .peak_external_bytes = snapshot.stats.peak_external_bytes,
            .external_alloc_count = snapshot.stats.external_alloc_count,
            .external_free_count = snapshot.stats.external_free_count,
            .external_token_count = snapshot.external_tokens.len,
            .external_token_bytes = snapshot.externalTokenBytes(),
            .external_invalid_release_count = snapshot.stats.external_invalid_release_count,
            .allocation_debt = snapshot.stats.allocation_debt,
            .collections = snapshot.stats.collections,
            .major_gc_count = snapshot.stats.cycle_gc_count,
            .major_gc_time_ns = snapshot.stats.cycle_gc_time_ns,
            .last_collection_time_ns = snapshot.stats.last_collection_time_ns,
            .zero_ref_drains = snapshot.stats.zero_ref_drains,
            .major_phase = snapshot.major_phase,
            .failed_collections = snapshot.stats.failed_collections,
            .last_failure = snapshot.stats.last_failure,
            .freed_objects = snapshot.stats.freed_objects,
            .pinned_cell_count = snapshot.pin_entries.len,
            .gc_request_count = snapshot.stats.gc_request_count,
            .pending_major = snapshot.major_request.pending,
            .pending_request_reason = if (snapshot.major_request.pending) snapshot.major_request.reason else null,
            .pending_request_urgency = if (snapshot.major_request.pending) snapshot.major_request.urgency else null,
            .last_request_reason = snapshot.stats.last_request_reason,
        };
    }

    pub fn add(self: *Registry, h: *GCObjectHeader) !void {
        try self.addWithSize(h, defaultHeapBytes(h));
    }

    pub fn addWithSize(self: *Registry, h: *GCObjectHeader, bytes: usize) !void {
        resetHeaderLifetimeForPublication(h);
        h.meta().flags = .{ .kind = h.meta().flags.kind };
        h.meta().alloc_info.heap_accounted = false;
        // Registration re-derives and re-stamps the large classification;
        // clearing it here upholds addInitializedWithSizeNoFail's clear-on-entry
        // invariant for re-registered headers.
        h.meta().alloc_info.large = false;
        if (comptime !trace_stw_enabled) h.prev = null;
        h.next = null;
        try self.addInitializedWithSize(h, bytes);
    }

    /// Register a freshly allocated header whose prefix and intrusive links are
    /// already initialized. Typed MemoryAccount allocations plus their owning
    /// constructors provide this invariant, avoiding duplicate hot-path stores.
    pub fn addInitializedWithSize(self: *Registry, h: *GCObjectHeader, bytes: usize) !void {
        self.addInitializedWithSizeNoFail(h, bytes);
    }

    /// No-fail publication primitive for fully prepared GC objects. Registry
    /// publication only updates scalar accounting and intrusive links; every
    /// allocation and owner-producing operation must already have completed.
    pub fn addInitializedWithSizeNoFail(self: *Registry, h: *GCObjectHeader, bytes: usize) void {
        assertInitialHeaderLifetime(h);
        std.debug.assert(!h.meta().flags.mark);
        std.debug.assert(!h.meta().flags.finalizing);
        std.debug.assert(!h.meta().flags.is_pinned);
        std.debug.assert(!h.meta().flags.cycle_visited);
        std.debug.assert(!h.meta().alloc_info.heap_accounted);
        std.debug.assert(!headerLinked(h));

        const is_large = self.isLargeAllocation(bytes);
        // The large bit is clear on entry for every registration: initGcPrefix
        // zeroes it on fresh allocations, and both unaccount sites
        // (recordHeapFreeWithBytes / addWithSize) clear it together with
        // heap_accounted. This keeps the hot RMW below the same single-bit orr
        // it always was; only the cold large arm pays a second byte store.
        std.debug.assert(!h.meta().alloc_info.large);
        // Read the alloc_info byte ONCE, before the heap_accounted store.
        // Every classification this publication still needs from it --
        // standalone prefix, block-cell size class -- is by construction
        // unchanged by setting bit 6 (heap_accounted) or bit 5 (large). The
        // compiler cannot prove that on its own: `old_space.recordAlloc` and
        // `recordLargeSpaceAllocCold` write through `self`, which may alias
        // the header, so every later `alloc_info` read became a reload of the
        // byte just stored. On this host the dependent of that reload carried
        // ~40% of this function's self cycles, and a second reload (after the
        // young-bit store to the adjacent byte) another ~7%.
        const info_at_entry = h.metaConst().alloc_info;
        const is_block_cell = block_cell_blk: {
            if (comptime !block_heap_enabled) break :block_cell_blk false;
            break :block_cell_blk info_at_entry.block_size_idx == representation.block_cell_size_class;
        };
        if (info_at_entry.standalone) h.meta().size_class = encodeHeapBytes(bytes);
        h.meta().alloc_info.heap_accounted = true;
        // qjs add_gc_object writes header bookkeeping once and then
        // list_add_tail's (quickjs.c:6540-6546). No membership flag.
        // GC pacing is owned by MemoryAccount.allocated_bytes. The registry only
        // keeps the selected space's live-byte scalar; all other allocation
        // diagnostics are derived by statsSnapshot. The single cold arm stamps
        // the alloc-time large classification (read back by
        // recordHeapFreeWithBytes) and credits the large space; the hot arm is
        // the policy compare + a fixed-offset old_space bump.
        if (is_large) {
            @branchHint(.unlikely);
            h.meta().alloc_info.large = true;
            self.recordLargeSpaceAllocCold(bytes);
        } else {
            self.old_space.recordAlloc(bytes);
        }

        // Keep this classification out of the large-space accounting live
        // range. In trace builds the publication tail also keeps a far-field
        // Registry base live for block/generation state; carrying `tracked`
        // across the cold allocation call forced every small Object
        // publication to spill one extra callee-saved register.
        const tracked = isCycleCandidate(h);
        // Checkers for the two hoisted classifications above. Everything this
        // function does between the read and here writes `heap_accounted`,
        // `large`, `size_class` or Registry scalars -- none of which may move
        // `standalone` or `block_size_idx`.
        std.debug.assert(info_at_entry.standalone == h.metaConst().alloc_info.standalone);
        std.debug.assert(is_block_cell == isBlockCellHeader(h));
        if (comptime address_registry_enabled) {
            if (tracked and !is_block_cell) self.linkGcObjectTail(h);
            self.registerLiveAddressClassified(h, bytes, tracked, info_at_entry.standalone, is_block_cell);
            self.observeNewPublication(h, bytes);
        } else if (tracked) self.linkGcObjectTail(h);
    }

    /// qjs `add_gc_object` for shapes (quickjs.c:6540): rc/kind already live
    /// in the prefix, then heap_accounted + old_space + list_add_tail.
    /// Shapes stay below `large_object_threshold` (8KiB); skip the large
    /// compare, standalone size_class stamp, and isCycleCandidate test.
    pub fn addInitializedShape(self: *Registry, h: *GCObjectHeader, bytes: usize) void {
        assertInitialHeaderLifetime(h);
        std.debug.assert(!h.meta().alloc_info.heap_accounted);
        std.debug.assert(!headerLinked(h));
        if (h.meta().alloc_info.standalone) {
            self.addInitializedWithSizeNoFail(h, bytes);
            return;
        }
        std.debug.assert(!h.meta().alloc_info.large);
        h.meta().alloc_info.heap_accounted = true;
        self.old_space.recordAlloc(bytes);
        if (comptime address_registry_enabled) {
            self.linkGcObjectTail(h);
            self.registerLiveAddress(h, bytes, true);
            self.observeNewPublication(h, bytes);
        } else self.linkGcObjectTail(h);
    }

    fn defaultHeapBytes(h: *const GCObjectHeader) usize {
        return switch (h.metaConst().flags.kind) {
            // The allocation-layout bit shares Object's existing weak-count
            // word; no property access or tracing path needs to decode the
            // property pointer. Inline class payloads still use the explicit
            // WithBytes APIs, as before.
            .object => blk: {
                const obj: *const object.Object = @alignCast(@fieldParentPtr("header", h));
                break :blk @sizeOf(object.Object) + if (obj.hasTrailingPropertyAllocation())
                    object.Object.trailing_property_bytes
                else
                    0;
            },
            .function_bytecode => blk: {
                const fb: *const FunctionBytecode = @fieldParentPtr("header", h);
                break :blk fb.heapByteSize();
            },
            .var_ref => @sizeOf(var_ref.VarRef),
            .realm_context => @sizeOf(context_mod.JSContext),
            .module => @sizeOf(module_mod.ModuleRecord),
            // A shape's heap footprint includes its inline FAM (hash table +
            // prop[]); recompute from the live capacity fields (qjs get_shape_size).
            .shape => blk: {
                const sh: *const shape.Shape = @alignCast(@fieldParentPtr("header", h));
                break :blk sh.accountedAllocationSize();
            },
            .string, .big_int => 0,
        };
    }

    fn encodeHeapBytes(bytes: usize) u16 {
        return @intCast(@min(bytes, large_heap_size_class));
    }

    fn storedHeapBytes(h: *const GCObjectHeader) ?usize {
        if (!h.metaConst().alloc_info.standalone) return null;
        if (h.metaConst().size_class == 0) return 0;
        if (h.metaConst().size_class == large_heap_size_class) return null;
        return h.metaConst().size_class;
    }

    pub fn heapByteSizeFromHeader(rt: anytype, h: *const GCObjectHeader) usize {
        if (storedHeapBytes(h)) |bytes| return bytes;
        return switch (h.metaConst().flags.kind) {
            .object => blk: {
                const obj: *const object.Object = @alignCast(@fieldParentPtr("header", h));
                break :blk obj.allocationSize(rt);
            },
            .function_bytecode => blk: {
                const fb: *const FunctionBytecode = @fieldParentPtr("header", h);
                break :blk fb.heapByteSize();
            },
            .var_ref => @sizeOf(var_ref.VarRef),
            .realm_context => @sizeOf(context_mod.JSContext),
            .module => @sizeOf(module_mod.ModuleRecord),
            .shape => blk: {
                const sh: *const shape.Shape = @alignCast(@fieldParentPtr("header", h));
                break :blk sh.accountedAllocationSize();
            },
            .string, .big_int => 0,
        };
    }

    fn isLargeAllocation(self: Registry, bytes: usize) bool {
        return bytes != 0 and bytes >= self.policy.large_object_threshold;
    }

    fn isCycleCandidate(h: *const GCObjectHeader) bool {
        return h.metaConst().flags.kind == .object or h.metaConst().flags.kind == .function_bytecode or h.metaConst().flags.kind == .var_ref or h.metaConst().flags.kind == .shape or h.metaConst().flags.kind == .realm_context or h.metaConst().flags.kind == .module;
    }

    fn recordHeapFreeWithBytes(self: *Registry, header: *GCObjectHeader, bytes: usize) void {
        if (!header.meta().alloc_info.heap_accounted or bytes == 0) return;
        // Alloc-time classification stamped by addInitializedWithSizeNoFail:
        // reading it back from the already-loaded alloc_info byte replaces the
        // policy-threshold reload + compare (qjs js_free_rt re-derives nothing,
        // quickjs.c:1613-1617), and guarantees the debit hits the same space
        // account the registration credited.
        const is_large = header.meta().alloc_info.large;
        std.debug.assert(is_large == self.isLargeAllocation(bytes));
        // Live-bytes bookkeeping lives entirely in the space accounts now (see
        // addInitializedWithSize); the free path just decrements live_bytes. Page
        // geometry is derived lazily in refreshPageState, not trimmed here.
        // The cold arm also clears the stamp, restoring the registration
        // clear-on-entry invariant for any later re-registration of the header.
        if (is_large) {
            @branchHint(.unlikely);
            header.meta().alloc_info.large = false;
            self.recordLargeSpaceFreeCold(bytes);
        } else {
            self.old_space.recordFree(bytes);
        }
        header.meta().alloc_info.heap_accounted = false;
        if (header.meta().alloc_info.standalone) header.meta().size_class = 0;
    }

    pub fn pinHeader(self: *Registry, header: *GCObjectHeader) !void {
        if (self.pinEntryIndex(header)) |index| {
            std.debug.assert(self.pin_entries[index].count != construction_pin_count);
            self.pin_entries[index].count +|= 1;
            return;
        }
        try self.ensurePinEntryCapacity(self.pin_entries.len + 1);
        self.pin_entries.ptr[self.pin_entries.len] = .{
            .header = header,
            .count = 1,
        };
        self.pin_entries = self.pin_entries.ptr[0 .. self.pin_entries.len + 1];
        header.setPinned(true);
    }

    pub fn unpinHeader(self: *Registry, header: *GCObjectHeader) void {
        const index = self.pinEntryIndex(header) orelse return;
        std.debug.assert(self.pin_entries[index].count != construction_pin_count);
        if (self.pin_entries[index].count > 1) {
            self.pin_entries[index].count -= 1;
            return;
        }
        if (index + 1 < self.pin_entries.len) {
            std.mem.copyForwards(
                PinEntry,
                self.pin_entries[index .. self.pin_entries.len - 1],
                self.pin_entries[index + 1 ..],
            );
        }
        self.pin_entries = self.pin_entries[0 .. self.pin_entries.len - 1];
        header.setPinned(false);
    }

    // heap_live_bytes / old_live_bytes / large_object_bytes are no longer stored:
    // they are derived from {old,large}_space.live_bytes in statsSnapshot (the
    // space accounts are the single source of truth, cross-checked by the Debug
    // verifyHeapAccounting object-list walk).

    // Keep alloc/free hot paths scalar: QuickJS js_def_malloc updates
    // malloc_count/malloc_size (quickjs.c:2160), add_gc_object only links the
    // object (quickjs.c:6540), and js_trigger_gc gates on one threshold
    // (quickjs.c:1780). Page state is derived by consumers.
    // The large arm is an outlined cold twin: virtually every GC allocation is
    // a small-slab object/shape, and the call boundary is the only reliable way
    // to keep the hot arm a fixed-offset ldr/add/str on old_space.live_bytes —
    // with both arms inline LLVM if-converts the two-way select into a
    // csel-computed store address (a store whose address depends on the policy
    // compare was the top stall of both the registration and destroy paths;
    // @branchHint alone did not defeat the if-conversion).
    noinline fn recordLargeSpaceAllocCold(self: *Registry, bytes: usize) void {
        self.large_space.recordAlloc(bytes);
    }

    noinline fn recordLargeSpaceFreeCold(self: *Registry, bytes: usize) void {
        self.large_space.recordFree(bytes);
    }

    fn externalTokenIndex(self: Registry, id: u64) ?usize {
        for (self.external_tokens, 0..) |entry, index| {
            if (entry.id == id) return index;
        }
        return null;
    }

    fn nextExternalTokenId(self: *Registry) u64 {
        const id = self.next_external_token_id;
        self.next_external_token_id +%= 1;
        if (self.next_external_token_id == 0) self.next_external_token_id = 1;
        return id;
    }

    fn pinEntryIndex(self: Registry, header: *const GCObjectHeader) ?usize {
        for (self.pin_entries, 0..) |entry, index| {
            if (entry.header == header) return index;
        }
        return null;
    }

    pub fn externalTokenBytes(self: Registry) usize {
        var total: usize = 0;
        for (self.external_tokens) |entry| {
            total = std.math.add(usize, total, entry.bytes) catch std.math.maxInt(usize);
        }
        return total;
    }

    pub fn unlinkObjectWithBytes(self: *Registry, h: *GCObjectHeader, bytes: usize) void {
        self.recordHeapFreeWithBytes(h, bytes);
        // Condemnation detached this header before its resource destructor.
        // Let that trace-only structural stamp answer before kind, list, and
        // generation work; rc comptime-erases this arm.
        if (comptime trace_stw_enabled) {
            if (h.meta().flags.cycle_visited) return;
        }
        if (!isCycleCandidate(h)) return;
        // Already unlinked, or condemned on tmp_obj_list / a partition list.
        // qjs remove_gc_object is only called while the node is on gc_obj_list.
        if (!headerLinked(h) or h.meta().flags.cycle_visited) return;
        self.removeGcObject(h);
    }

    /// Account an allocation already detached by `detachCycleCandidate`.
    ///
    /// Trace condemnation removes the object from every live membership
    /// structure before its resource destructor runs. The dominant object
    /// destructor can therefore skip the later generic unlink boundary
    /// entirely; only the byte ledger remains. Keeping this as a separate
    /// contract also prevents a future caller from accidentally treating the
    /// `cycle_visited` stamp as permission to omit accounting.
    pub inline fn recordDetachedHeapFreeWithBytes(self: *Registry, h: *GCObjectHeader, bytes: usize) void {
        if (comptime std.debug.runtime_safety) {
            std.debug.assert(h.metaConst().flags.cycle_visited);
        }
        self.recordHeapFreeWithBytes(h, bytes);
    }

    pub fn unlinkObject(self: *Registry, h: *GCObjectHeader) void {
        const bytes = storedHeapBytes(h) orelse defaultHeapBytes(h);
        self.unlinkObjectWithBytes(h, bytes);
    }

    pub fn retainObject(self: *Registry, h: *GCObjectHeader) void {
        _ = self;
        h.retain();
    }

    pub fn releaseObjectForTest(self: *Registry, h: *GCObjectHeader) bool {
        if (!builtin.is_test) @compileError("test-only helper");
        if (decrementHeaderRefCount(h) == 0) {
            self.unlinkObject(h);
            return true;
        }
        return false;
    }

    fn ensureExternalTokenCapacity(self: *Registry, required: usize) !void {
        if (required <= self.external_tokens_capacity) return;
        var new_capacity = if (self.external_tokens_capacity == 0) @as(usize, 8) else self.external_tokens_capacity * 2;
        while (new_capacity < required) new_capacity *= 2;
        const next = try self.memory.alloc(ExternalTokenEntry, new_capacity);
        errdefer self.memory.free(ExternalTokenEntry, next);
        @memcpy(next[0..self.external_tokens.len], self.external_tokens);
        if (self.external_tokens_capacity != 0) {
            self.memory.free(ExternalTokenEntry, self.external_tokens.ptr[0..self.external_tokens_capacity]);
        } else if (self.external_tokens.len != 0) {
            self.memory.free(ExternalTokenEntry, self.external_tokens);
        }
        self.external_tokens = next[0..self.external_tokens.len];
        self.external_tokens_capacity = new_capacity;
    }

    fn ensurePinEntryCapacity(self: *Registry, required: usize) !void {
        if (required <= self.pin_entries_capacity) return;
        var new_capacity = if (self.pin_entries_capacity == 0) @as(usize, 8) else self.pin_entries_capacity * 2;
        while (new_capacity < required) new_capacity *= 2;
        const next = try self.memory.alloc(PinEntry, new_capacity);
        errdefer self.memory.free(PinEntry, next);
        @memcpy(next[0..self.pin_entries.len], self.pin_entries);
        if (self.pin_entries_capacity != 0) {
            self.memory.free(PinEntry, self.pin_entries.ptr[0..self.pin_entries_capacity]);
        } else if (self.pin_entries.len != 0) {
            self.memory.free(PinEntry, self.pin_entries);
        }
        self.pin_entries = next[0..self.pin_entries.len];
        self.pin_entries_capacity = new_capacity;
    }

    /// Composite iterator over every PUBLISHED GC object.
    ///
    /// Two phases behind one `next()`: the intrusive list (slab and
    /// standalone kinds -- block-served objects no longer link there), then
    /// the block heap's cells, walked bitmap-word first so an empty block
    /// costs four word tests. Producing a cell requires alloc-bit AND
    /// `heap_accounted`, which is exactly the old list membership: husks keep
    /// their cell but lose their accounting, and a cell between
    /// `initGcPrefix` and registration is not yet an object.
    ///
    /// In young mode the block phase walks the young-block list instead of
    /// every superblock, filtering per cell on the `young` header bit --
    /// recycled cells put OLD objects inside young-listed blocks.
    pub const GcObjectIterator = struct {
        cursor: ?*GCObjectHeader,
        sentinel: *const GCObjectHeader,
        heap: if (block_heap_enabled) ?*const BlockHeapMod.Heap else void =
            if (block_heap_enabled) null else {},
        young_only: bool = false,
        /// Dead-scan mode: the block phase yields only allocated-and-unmarked
        /// cells, computed word-at-a-time, so survivors are never touched --
        /// the whole point of bitmap condemnation. List-phase consumers do
        /// their own mark test as before.
        unmarked_only: bool = false,
        sb_index: usize = 0,
        blk_index: usize = 0,
        cell_index: u32 = 0,
        young_block: usize = 0,

        pub fn next(self: *GcObjectIterator) ?*GCObjectHeader {
            if (self.cursor) |current| {
                if (current != self.sentinel) {
                    self.cursor = current.next;
                    return current;
                }
                self.cursor = null;
            }
            if (comptime !block_heap_enabled) return null;
            const heap = self.heap orelse return null;
            if (self.young_only) return self.nextYoungCell(heap);
            return self.nextCell(heap);
        }

        fn nextInBlock(self: *GcObjectIterator, block: *BlockHeapMod.Block, young_filter: bool) ?*GCObjectHeader {
            // Word-skipping: an empty word advances 64 cells on one load. The
            // first cut walked cell by cell with an atomic load each, which
            // priced enumeration at the block's CAPACITY -- slower than the
            // list it replaced.
            const words = block.allocWords();
            const epoch = if (comptime block_heap_enabled) self.heap.?.mark_epoch else 0;
            while (self.cell_index < block.cell_count) {
                const word_index = self.cell_index / 64;
                const shift: u6 = @intCast(self.cell_index % 64);
                const raw = if (self.unmarked_only)
                    block.deadWord(word_index, epoch)
                else
                    words[word_index]; // alloc bitmap is owner-only, see gc_block_heap
                const word = raw >> shift;
                if (word == 0) {
                    self.cell_index = @intCast((word_index + 1) * 64);
                    continue;
                }
                const index = self.cell_index + @ctz(word);
                if (index >= block.cell_count) break;
                self.cell_index = index + 1;
                const header: *GCObjectHeader = @ptrFromInt(block.cellBase(index) + metadata_prefix_size);
                if (!header.metaConst().alloc_info.heap_accounted) continue;
                if (young_filter) {
                    if (!header.metaConst().flags.young) continue;
                    // A condemned cell awaiting its destruction slice still
                    // carries its alloc bit and, until the trace retires it,
                    // its young bit. A minor may run between destruction
                    // slices, and a corpse handed to it would be reclaimed a
                    // second time. Its doomed bit is the discriminator.
                    if (comptime block_heap_enabled) {
                        if (block.isDoomed(index)) continue;
                    }
                }
                return header;
            }
            return null;
        }

        fn nextCell(self: *GcObjectIterator, heap: *const BlockHeapMod.Heap) ?*GCObjectHeader {
            while (self.sb_index < heap.superblocks.items.len) {
                const sb = heap.superblocks.items[self.sb_index];
                if (sb.kind != .classed) {
                    self.sb_index += 1;
                    self.blk_index = 0;
                    continue;
                }
                while (self.blk_index < sb.used_blocks) {
                    const base = @intFromPtr(sb.bytes.ptr) + self.blk_index * BlockHeapMod.block_bytes;
                    const block: *BlockHeapMod.Block = @ptrFromInt(base);
                    if (block.magic != BlockHeapMod.block_magic) {
                        self.blk_index += 1;
                        self.cell_index = 0;
                        continue;
                    }
                    if (self.nextInBlock(block, false)) |header| return header;
                    self.blk_index += 1;
                    self.cell_index = 0;
                }
                self.sb_index += 1;
                self.blk_index = 0;
            }
            return null;
        }

        fn nextYoungCell(self: *GcObjectIterator, heap: *const BlockHeapMod.Heap) ?*GCObjectHeader {
            _ = heap;
            while (self.young_block > 1) {
                const block: *BlockHeapMod.Block = @ptrFromInt(self.young_block);
                if (self.nextInBlock(block, true)) |header| return header;
                self.young_block = block.young_link;
                self.cell_index = 0;
            }
            return null;
        }
    };

    pub fn objectIterator(self: *const Registry) GcObjectIterator {
        return .{
            .cursor = self.gc_obj_list.sentinel.next,
            .sentinel = &self.gc_obj_list.sentinel,
            .heap = if (comptime block_heap_enabled) &self.block_heap else {},
        };
    }

    /// Reserve the existing pin ledger before taking a block cell, so adding
    /// the construction pin after initialization is a no-fail scalar publish.
    pub fn prepareConstructionRoot(self: *Registry) !void {
        if (comptime !trace_stw_enabled) return;
        try self.ensurePinEntryCapacity(self.pin_entries.len + 1);
    }

    /// Protect a fully initialized Object whose shape is intentionally not
    /// installed yet. Only the detached generator constructor has this
    /// lifetime; all other block-cell objects publish immediately.
    pub fn addConstructionRoot(self: *Registry, header: *GCObjectHeader) void {
        if (comptime !trace_stw_enabled) return;
        std.debug.assert(header.metaConst().flags.kind == .object);
        std.debug.assert(!header.metaConst().alloc_info.heap_accounted);
        std.debug.assert(!headerLinked(header));
        std.debug.assert(self.pinEntryIndex(header) == null);
        std.debug.assert(self.pin_entries.len < self.pin_entries_capacity);
        self.pin_entries.ptr[self.pin_entries.len] = .{
            .header = header,
            .count = construction_pin_count,
        };
        self.pin_entries = self.pin_entries.ptr[0 .. self.pin_entries.len + 1];
        header.setPinned(true);
    }

    pub fn removeConstructionRoot(self: *Registry, header: *GCObjectHeader) void {
        if (comptime !trace_stw_enabled) return;
        const index = self.pinEntryIndex(header) orelse unreachable;
        std.debug.assert(self.pin_entries[index].count == construction_pin_count);
        if (index + 1 < self.pin_entries.len) {
            std.mem.copyForwards(
                PinEntry,
                self.pin_entries[index .. self.pin_entries.len - 1],
                self.pin_entries[index + 1 ..],
            );
        }
        self.pin_entries = self.pin_entries[0 .. self.pin_entries.len - 1];
        header.setPinned(false);
    }

    fn isConstructionRoot(self: *const Registry, header: *const GCObjectHeader) bool {
        if (comptime !trace_stw_enabled) return false;
        const index = self.pinEntryIndex(header) orelse return false;
        if (self.pin_entries[index].count != construction_pin_count) return false;
        const meta = header.metaConst();
        if (meta.alloc_info.heap_accounted or
            meta.alloc_info.standalone or
            !isBlockCellHeader(header) or
            meta.flags.kind != .object or
            meta.flags.young or
            meta.flags.finalizing or
            !meta.flags.is_pinned or
            meta.lifetime.trace.mark_epoch != 0 or
            meta.lifetime.trace.object_shape_summary != 0 or
            meta.lifetime.trace.flags.husk or
            meta.lifetime.trace.flags.reserved != 0)
        {
            return false;
        }
        const shell: *const object.Object = @alignCast(@fieldParentPtr("header", header));
        return shell.isDetachedGeneratorShellForGc();
    }

    pub fn pinEntryIsConstructionRoot(self: *const Registry, entry: PinEntry) bool {
        return entry.count == construction_pin_count and self.isConstructionRoot(entry.header);
    }

    /// Cold audit predicate passed into BlockHeap without introducing a module
    /// cycle. The block heap supplies the cell base; the Registry owns the
    /// exact construction-list membership authority.
    pub fn blockCellPublicationAllowance(
        context: *anyopaque,
        cell_addr: usize,
    ) BlockHeapMod.Heap.UnpublishedCellAllowance.Kind {
        if (comptime !trace_stw_enabled) return .none;
        const self: *const Registry = @ptrCast(@alignCast(context));
        const header: *const GCObjectHeader = @ptrFromInt(cell_addr + metadata_prefix_size);
        if (self.isConstructionRoot(header)) return .marked_construction;

        const meta = header.metaConst();
        if (meta.alloc_info.heap_accounted or
            !meta.flags.finalizing or
            !meta.flags.cycle_visited or
            meta.flags.kind != .object or
            !isBlockCellHeader(header))
        {
            return .none;
        }
        var parked = self.cycle_deferred_frees.head;
        while (parked) |candidate| : (parked = candidate.next) {
            if (candidate == header) return .parked_finalizer;
        }
        return .none;
    }

    /// Iterate only the young objects.
    ///
    /// Publication appends at the tail and promotion clears the whole young
    /// set at once, so the young objects are always a contiguous suffix of
    /// the allocation-ordered list. `young_head` names where that suffix
    /// starts, which is what lets a minor cost O(young) instead of O(heap) --
    /// the difference between a nursery collection and a whole-heap walk that
    /// happens to ignore most of what it visits.
    /// Dead-scan iterator: block phase yields only unmarked allocated cells.
    /// The list phase is unchanged -- its consumers test marks themselves.
    pub fn deadCandidateIterator(self: *const Registry) GcObjectIterator {
        var it = self.objectIterator();
        it.unmarked_only = true;
        return it;
    }

    /// Dead block cells only. List condemnation is a separate cursor walk so
    /// compact-header deletion can splice with its known predecessor.
    pub fn deadBlockCandidateIterator(self: *const Registry) GcObjectIterator {
        return .{
            .cursor = null,
            .sentinel = &self.gc_obj_list.sentinel,
            .heap = if (comptime block_heap_enabled) &self.block_heap else {},
            .unmarked_only = true,
        };
    }

    pub fn youngIterator(self: *const Registry) GcObjectIterator {
        return .{
            .cursor = self.young_head,
            .sentinel = &self.gc_obj_list.sentinel,
            .heap = if (comptime block_heap_enabled) &self.block_heap else {},
            .young_only = true,
            .young_block = if (comptime block_heap_enabled)
                (if (self.block_heap.young_blocks) |head| @intFromPtr(head) else 0)
            else
                0,
        };
    }

    /// Young block cells only; the non-block suffix has its own predecessor
    /// cursor and is consumed separately by the minor sweep.
    pub fn youngBlockIterator(self: *const Registry) GcObjectIterator {
        return .{
            .cursor = null,
            .sentinel = &self.gc_obj_list.sentinel,
            .heap = if (comptime block_heap_enabled) &self.block_heap else {},
            .young_only = true,
            .young_block = if (comptime block_heap_enabled)
                (if (self.block_heap.young_blocks) |head| @intFromPtr(head) else 0)
            else
                0,
        };
    }

    /// Non-reclaiming census of the intrusive RC registry. One Adapter for a
    /// future CompositeHeapCensus, not a complete heap census: String/Rope
    /// and BigInt need the allocation-ledger Adapter in `ref_kind_catalog`.
    pub const Census = struct {
        by_kind: [ref_kind_catalog.len]usize = [_]usize{0} ** ref_kind_catalog.len,
        total: usize = 0,

        pub fn count(self: Census, kind: RefKind) usize {
            return self.by_kind[@intFromEnum(kind)];
        }

        pub fn covers(self: Census, kind: RefKind) bool {
            _ = self;
            return refKindDescriptor(kind).census == .rc_registry;
        }

        pub fn completeForAllRefKinds(self: Census) bool {
            _ = self;
            inline for (ref_kind_catalog) |descriptor| {
                if (descriptor.census != .rc_registry) return false;
            }
            return true;
        }
    };

    pub fn census(self: *const Registry) Census {
        var result = Census{};
        var iterator = self.objectIterator();
        while (iterator.next()) |header| {
            result.by_kind[@intFromEnum(header.metaConst().flags.kind)] += 1;
            result.total += 1;
        }
        return result;
    }

    /// Served from the collector's block heap: enumerated by block bitmaps,
    /// never linked on `gc_obj_list`, young-tracked at block granularity.
    pub inline fn isBlockCellHeader(h: *const GCObjectHeader) bool {
        if (comptime !block_heap_enabled) return false;
        // The CLASS FIELD is the marker, not the whole byte: publication sets
        // `heap_accounted` on top of it (0x1F becomes 0x5F), and comparing
        // the full byte made every published block object fail this test --
        // so they linked onto the list AND were enumerated by the block
        // phase, and the bitmap mark split never engaged at all.
        return h.metaConst().alloc_info.block_size_idx == representation.block_cell_size_class;
    }

    /// Cross-module representation audit for Object's direct property pointer
    /// and allocation-layout marker. This is deliberately a whole-heap audit,
    /// never a property-access branch: construction/free, Shape capacity, and
    /// block-cell sizing meet here without taxing the paths they protect.
    pub fn verifyObjectPropertyStorageLayouts(self: *const Registry, rt: anytype) InvariantError!void {
        var iterator = self.objectIterator();
        while (iterator.next()) |header| {
            if (header.metaConst().flags.kind != .object) continue;
            const owner: *const object.Object = @fieldParentPtr("header", header);
            if (@intFromPtr(owner.prop_values) & (@alignOf(property.Entry) - 1) != 0)
                return error.MisalignedPropertyStorage;

            const has_trailing_allocation = owner.hasTrailingPropertyAllocation();
            if (has_trailing_allocation) {
                if (owner.class_id != class.ids.object) return error.InvalidTrailingPropertyClass;
                const definition = rt.classes.recordPtr(owner.class_id) orelse
                    return error.InvalidTrailingPropertyClass;
                if (definition.inline_payload_size != 0)
                    return error.InvalidTrailingPropertyLayout;
                if (owner.propertyStorageIsInline() and
                    (owner.shape_ref.prop_size == 0 or
                        owner.shape_ref.prop_size > object.Object.trailing_property_capacity))
                {
                    return error.InvalidTrailingPropertyCapacity;
                }
            } else if (owner.propertyStorageIsInline()) {
                return error.InvalidTrailingPropertyLayout;
            }
            if (owner.shape_ref.prop_count != 0 and !owner.hasPropertyStorage())
                return error.MissingObjectPropertyStorage;
            if (owner.shape_ref.prop_count > owner.shape_ref.prop_size)
                return error.InvalidTrailingPropertyCapacity;

            if (comptime block_heap_enabled) {
                if (isBlockCellHeader(header)) {
                    const cell = @intFromPtr(header) - metadata_prefix_size;
                    const block = BlockHeapMod.Block.fromCellTrusted(cell);
                    if (block.cell_size < metadata_prefix_size + owner.allocationSize(rt))
                        return error.UndersizedTrailingObjectCell;
                }
            }
        }
    }

    fn appendGcObject(self: *Registry, header: *GCObjectHeader) void {
        std.debug.assert(isCycleCandidate(header));
        std.debug.assert(!headerLinked(header));
        self.stageYoungTailPredecessor();
        listAddTail(&self.gc_obj_list, header);
    }

    /// qjs `list_add_tail` (quickjs.c:6545).
    inline fn linkGcObjectTail(self: *Registry, header: *GCObjectHeader) void {
        self.stageYoungTailPredecessor();
        listAddTail(&self.gc_obj_list, header);
    }

    /// Publication marks a freshly appended carrier young immediately after
    /// linkage. Capture the old tail before that append while it is still O(1).
    inline fn stageYoungTailPredecessor(self: *Registry) void {
        if (comptime !generation_enabled) return;
        if (self.young_head == null) {
            self.young_predecessor = self.gc_obj_list.tail.?;
        }
    }

    pub inline fn resetYoungListSuffix(self: *Registry) void {
        if (comptime !generation_enabled) return;
        self.young_head = null;
        self.young_predecessor = null;
    }

    /// qjs `list_del` / `remove_gc_object` (quickjs.c:6548). Already-unlinked
    /// headers (deinit shape self-remove) are a no-op; a linked node is spliced
    /// with no head/tail null branches.
    fn removeGcObject(self: *Registry, header: *GCObjectHeader) void {
        if (!headerLinked(header)) return;
        const previous = listPrevious(&self.gc_obj_list, header);
        self.removeGcObjectAfter(previous, header);
    }

    /// O(1) list detach for a collector already walking `gc_obj_list`.
    fn removeGcObjectAfter(self: *Registry, previous: *GCObjectHeader, header: *GCObjectHeader) void {
        std.debug.assert(previous.next == header);
        // `unregisterLiveAddress` owns the young-suffix anchor fixup for every
        // detach path; it runs before the `listDel` below so `header.next` is
        // still the successor it needs.
        const removed_predecessor = if (comptime generation_enabled)
            self.young_predecessor == header
        else
            false;
        self.unregisterLiveAddress(header);
        if (comptime generation_enabled) {
            if (removed_predecessor) self.young_predecessor = previous;
            if (self.young_head == null) self.young_predecessor = null;
        }
        listDelAfter(&self.gc_obj_list, previous, header);
    }

    /// Mark accessors, split by population.
    ///
    /// Block cells keep their mark in the BLOCK's bitmap under the heap's
    /// mark epoch: bumping the epoch at a major's begin makes every block's
    /// bitmap stale -- read as unmarked -- in O(1), which is what the single
    /// global parity bit could not soundly do and
    /// what the whole-heap `clearMarks` walk used to cost ~milliseconds per
    /// cycle to do by hand. The epoch never moves between majors, so sticky
    /// marks survive for the minors exactly as before. Everything not in a
    /// block cell uses the fixed `Metadata.lifetime.trace` epoch at payload
    /// minus 4; Shape and Realm keep their ownership counts in their bodies.
    ///
    /// Dispatch cost is one byte read (`alloc_info`, which shares the cell's
    /// first cache line with the header) and a mask; the bitmap word is
    /// shared by 64 neighbours, which is better locality than 64 scattered
    /// header bytes.
    pub inline fn headerMarked(self: *const Registry, h: *const GCObjectHeader) bool {
        if (comptime block_heap_enabled) {
            if (h.metaConst().alloc_info.block_size_idx == representation.block_cell_size_class) {
                const cell = @intFromPtr(h) - metadata_prefix_size;
                const block = BlockHeapMod.Block.fromCellTrusted(cell);
                return block.isMarked(h.metaConst().size_class, self.block_heap.mark_epoch);
            }
        }
        if (comptime trace_stw_enabled) {
            if (std.debug.runtime_safety) std.debug.assert(isCycleCandidate(h));
            return @atomicLoad(u16, &h.metaConst().lifetime.trace.mark_epoch, .monotonic) == self.header_mark_epoch;
        }
        return h.metaConst().flags.mark;
    }

    pub inline fn setHeaderMarked(self: *const Registry, h: *GCObjectHeader) void {
        if (comptime block_heap_enabled) {
            if (h.metaConst().alloc_info.block_size_idx == representation.block_cell_size_class) {
                const cell = @intFromPtr(h) - metadata_prefix_size;
                const block = BlockHeapMod.Block.fromCellTrusted(cell);
                block.setMark(h.metaConst().size_class, self.block_heap.mark_epoch);
                return;
            }
        }
        if (comptime trace_stw_enabled) {
            if (std.debug.runtime_safety) std.debug.assert(isCycleCandidate(h));
            @atomicStore(u16, &h.meta().lifetime.trace.mark_epoch, self.header_mark_epoch, .monotonic);
        } else {
            h.meta().flags.mark = true;
        }
    }

    /// Atomically claim the mark: returns true iff this caller transitioned
    /// the object from unmarked to marked. Parallel tracing uses the claim as
    /// its dedup so each object's edges are walked by exactly one thread --
    /// which also keeps the trace's rare write-backs (accessor sync stores in
    /// `traceChildEdgesFallible`) single-writer. Block cells claim a bitmap
    /// bit; trace header kinds claim the fixed-offset u16 epoch. The separate
    /// state-flags u16 is never part of this atomic operation.
    pub inline fn tryAcquireHeaderMark(self: *const Registry, h: *GCObjectHeader) bool {
        if (comptime block_heap_enabled) {
            if (h.metaConst().alloc_info.block_size_idx == representation.block_cell_size_class) {
                const cell = @intFromPtr(h) - metadata_prefix_size;
                const block = BlockHeapMod.Block.fromCellTrusted(cell);
                return block.tryAcquireMark(h.metaConst().size_class, self.block_heap.mark_epoch);
            }
        }
        if (comptime trace_stw_enabled) {
            if (std.debug.runtime_safety) std.debug.assert(isCycleCandidate(h));
            const epoch_ptr = &h.meta().lifetime.trace.mark_epoch;
            // The only caller is the parallel STW tracer. Its preceding plain
            // marked-load filters the common hit; the Registry epoch cannot
            // change while workers run. One exchange therefore elects exactly
            // one winner without a general CAS retry loop: a racing loser reads
            // back the current epoch written by the winner.
            const epoch = self.header_mark_epoch;
            const old = @atomicRmw(u16, epoch_ptr, .Xchg, epoch, .monotonic);
            return old != epoch;
        }
        const flags_byte: *u8 = @ptrCast(&h.meta().flags);
        const mark_mask: u8 = 1 << @bitOffsetOf(BlockFlags, "mark");
        const old = @atomicRmw(u8, flags_byte, .Or, mark_mask, .monotonic);
        return (old & mark_mask) == 0;
    }

    /// Retire a block cell the tracer has just finished expanding.
    ///
    /// This is trace-coupled retirement: the survivor's header is already in
    /// L1 because `traceHeaderEdges` just read its kind, so clearing the
    /// young bit here is a store to a loaded line, and only SURVIVORS are
    /// touched. The bulk walk it replaces visited the whole young
    /// population -- 125 M headers on earley-boyer, 44 M on raytrace -- to
    /// clear a bit on objects that were about to be condemned anyway.
    ///
    /// Non-block populations are deliberately excluded: the condemnation
    /// walk already retires those survivors, and clearing them here would
    /// break `young_head`'s exact-suffix invariant over `gc_obj_list`.
    pub inline fn retireTracedYoung(self: *Registry, h: *GCObjectHeader) void {
        if (comptime !generation_enabled) return;
        if (self.generation.major_retirement != .tracing) return;
        // A header the tracer reached must be a published, un-condemned
        // object. Reaching anything else means a stale entry survived in the
        // frontier, and this function WRITES, so the consequence is silent
        // memory corruption rather than a wasted trace. Under `free_nil =
        // 0xFFFFFFFF` a free cell's link byte read as the block-cell marker
        // and clearing `young` rewrote the link -- the terminator no longer
        // collides, but the frontier invariant is the real guarantee and it
        // is worth failing loudly on.
        if (std.debug.runtime_safety) {
            std.debug.assert(h.metaConst().alloc_info.heap_accounted);
            std.debug.assert(!h.metaConst().flags.cycle_visited);
        }
        if (comptime block_heap_enabled) {
            if (h.metaConst().alloc_info.block_size_idx == representation.block_cell_size_class) {
                h.meta().flags.young = false;
            }
        }
    }

    pub inline fn setHeaderUnmarked(self: *const Registry, h: *GCObjectHeader) void {
        if (comptime block_heap_enabled) {
            if (h.metaConst().alloc_info.block_size_idx == representation.block_cell_size_class) {
                const cell = @intFromPtr(h) - metadata_prefix_size;
                const block = BlockHeapMod.Block.fromCellTrusted(cell);
                block.clearMark(h.metaConst().size_class, self.block_heap.mark_epoch);
                return;
            }
        }
        if (comptime trace_stw_enabled) {
            if (std.debug.runtime_safety) std.debug.assert(isCycleCandidate(h));
            @atomicStore(u16, &h.meta().lifetime.trace.mark_epoch, 0, .monotonic);
        } else {
            h.meta().flags.mark = false;
        }
    }

    /// O(1) whole-population unmark for the ordinary case. One wrap scrub is
    /// required before reusing epoch 1; 0 always remains newborn/unmarked.
    pub fn advanceHeaderMarkEpoch(self: *Registry) void {
        if (comptime !trace_stw_enabled) return;
        if (self.header_mark_epoch != std.math.maxInt(u16)) {
            self.header_mark_epoch += 1;
            return;
        }

        var cursor = self.gc_obj_list.sentinel.next;
        while (cursor) |header| {
            if (header == &self.gc_obj_list.sentinel) break;
            @atomicStore(u16, &header.meta().lifetime.trace.mark_epoch, 0, .monotonic);
            cursor = header.next;
        }
        self.header_mark_epoch = 1;
    }

    pub fn detachCycleCandidate(self: *Registry, header: *GCObjectHeader) void {
        std.debug.assert(!header.meta().flags.cycle_visited);
        self.removeGcObject(header);
        header.meta().flags.cycle_visited = true;
    }

    /// Sequential-sweep twin of `detachCycleCandidate`; the predecessor must
    /// still name the live-list node immediately before `header`.
    pub fn detachCycleCandidateAfter(self: *Registry, previous: *GCObjectHeader, header: *GCObjectHeader) void {
        std.debug.assert(!header.meta().flags.cycle_visited);
        self.removeGcObjectAfter(previous, header);
        header.meta().flags.cycle_visited = true;
    }

    pub fn restoreCycleCandidate(self: *Registry, header: *GCObjectHeader) void {
        std.debug.assert(header.meta().flags.cycle_visited);
        header.meta().flags.cycle_visited = false;
        self.appendGcObject(header);
        if (comptime address_registry_enabled) {
            const bytes = storedHeapBytes(header) orelse defaultHeapBytes(header);
            self.registerLiveAddress(header, bytes, true);
        }
    }

    /// Shade a target during concurrent marking (§8.4). Marking the object is
    /// what publishes it to the marker; the work queue that would carry it is
    /// the marker thread's business and arrives with it.
    ///
    /// Called only from inside a `CriticalScope`, so final remark cannot stop
    /// the mutator between the heap store and this shading.
    /// Marking-phase write barrier: shade the stored value GREY.
    ///
    /// Grey means marked AND queued for tracing. The first version of this
    /// function only claimed the mark state, which is black-without-having-been-
    /// traced: a pre-existing child whose only path ran through the shaded
    /// object was never discovered and was swept alive. The remark could not
    /// save it -- `shade()` skips already-marked objects, so a marked object
    /// is never re-entered. The hole exists for single-threaded incremental
    /// marking exactly as for a concurrent thread: an object traced in one
    /// increment and mutated in the mutator window is otherwise never
    /// re-examined.
    ///
    /// This is the Dijkstra direction (shade the target), not JSC's
    /// Steele-style owner-append (`Heap::addToRememberedSet` re-queues the
    /// owner). JSC can afford owner-append because `CellState` gives it a
    /// grey state that deduplicates the append: the second barrier on a
    /// remembered owner takes the fast path. Our collector has marked/unmarked
    /// but no distinct grey state, so owner-append would re-push the same hot owner on
    /// every store and flood the ring -- forcing the coarse overflow rescan
    /// every cycle. Shading the target dedups for free: the mark claim itself
    /// is the "already queued" test. The price is more floating garbage (a
    /// stored-then-overwritten value survives the cycle), which is the
    /// documented cost of an insertion barrier (§8.4).
    ///
    /// A failed push is not lost work: the object stays marked and the
    /// queue's overflow flag makes it findable by the remark's rescan of
    /// marked objects.
    /// Choose the scope of the next self-paced incremental cycle. The first
    /// cycle is full, then the experiment permits exactly one sticky cycle;
    /// the following cycle is full even if the ordinary threshold, reset from
    /// the sticky-inflated account, would prefer to wait. A repair transaction
    /// is always full.
    pub fn prepareIncrementalMajorScope(self: *Registry) IncrementalMajorScope {
        if (comptime !sticky_major_enabled) return .full;
        const pressure = self.stickyMajorFullPressureExceeded();
        const must_full = !sticky_major_on or
            !self.sticky_major.full_baseline_valid or
            self.sticky_major.sticky_rounds_since_full != 0 or
            pressure or
            self.generation.major_retirement != .clean;
        self.sticky_major.cycle_scope = if (must_full) .full else .sticky;
        if (must_full and pressure) self.sticky_major.stats.full_forced_by_pressure +|= 1;
        return self.sticky_major.cycle_scope;
    }

    pub inline fn incrementalMajorScope(self: *const Registry) IncrementalMajorScope {
        if (comptime !sticky_major_enabled) return .full;
        return self.sticky_major.cycle_scope;
    }

    /// A second threshold whose baseline changes only after a full trace.
    /// It grants two copies of the first post-full allocation window: one to
    /// reach the sticky cycle, one to reach the mandatory full. Resetting the
    /// ordinary threshold from floating garbage cannot move this cap.
    pub inline fn stickyMajorFullPressureExceeded(self: *const Registry) bool {
        if (comptime !sticky_major_enabled) return false;
        // With the arm off there is no floating garbage to defeat, so the
        // second threshold must not add collections the ordinary schedule
        // would not have run. Off means off, not "off plus a second trigger".
        if (!sticky_major_on) return false;
        return self.sticky_major.full_baseline_valid and
            self.memory.allocated_bytes > self.sticky_major.full_pressure_threshold;
    }

    pub fn noteFullCollectionSettled(
        self: *Registry,
        settled_bytes: usize,
        ordinary_threshold: usize,
        full_sweep_completed: bool,
    ) void {
        if (comptime !sticky_major_enabled) return;
        // Sticky tracing assumes that every old object left behind by the
        // baseline full is marked. An incomplete arena set makes the full
        // collector deliberately retain unmarked objects instead of sweeping
        // them. Such a safe-leak round is not a sticky baseline: an old->old
        // write could revive one of those objects, and the generational
        // remembered set intentionally does not record that edge.
        if (!full_sweep_completed) {
            self.sticky_major.full_baseline_valid = false;
            self.sticky_major.sticky_rounds_since_full = 0;
            self.sticky_major.cycle_scope = .full;
            return;
        }
        const first_window = ordinary_threshold -| settled_bytes;
        const two_windows = std.math.mul(usize, first_window, 2) catch std.math.maxInt(usize);
        self.sticky_major.last_full_settled_bytes = settled_bytes;
        self.sticky_major.full_pressure_threshold =
            std.math.add(usize, settled_bytes, two_windows) catch std.math.maxInt(usize);
        self.sticky_major.full_baseline_valid = true;
        self.sticky_major.sticky_rounds_since_full = 0;
        self.sticky_major.cycle_scope = .full;
        self.sticky_major.stats.full_cycles +|= 1;
    }

    pub fn noteIncrementalCollectionSettled(
        self: *Registry,
        settled_bytes: usize,
        ordinary_threshold: usize,
        full_sweep_completed: bool,
    ) void {
        if (comptime !sticky_major_enabled) return;
        if (!full_sweep_completed) {
            self.sticky_major.full_baseline_valid = false;
            self.sticky_major.sticky_rounds_since_full = 0;
            self.sticky_major.cycle_scope = .full;
            return;
        }
        self.sticky_major.stats.max_ordinary_threshold =
            @max(self.sticky_major.stats.max_ordinary_threshold, ordinary_threshold);
        switch (self.sticky_major.cycle_scope) {
            .full => self.noteFullCollectionSettled(settled_bytes, ordinary_threshold, true),
            .sticky => {
                self.sticky_major.sticky_rounds_since_full = 1;
                self.sticky_major.stats.sticky_cycles +|= 1;
                const excess = settled_bytes -| self.sticky_major.last_full_settled_bytes;
                self.sticky_major.stats.sum_sticky_excess_bytes +|= excess;
                self.sticky_major.stats.max_sticky_excess_bytes =
                    @max(self.sticky_major.stats.max_sticky_excess_bytes, excess);
            },
        }
    }

    pub fn noteStickyMajorOracle(
        self: *Registry,
        scope: IncrementalMajorScope,
        precise: usize,
        conservative_only: usize,
    ) void {
        if (comptime !sticky_major_enabled) return;
        switch (scope) {
            .full => self.sticky_major.stats.oracle_checks_full +|= 1,
            .sticky => self.sticky_major.stats.oracle_checks_sticky +|= 1,
        }
        self.sticky_major.stats.oracle_violations_precise +|= precise;
        self.sticky_major.stats.oracle_violations_conservative +|= conservative_only;
    }

    pub fn stickyMajorStats(self: *const Registry) StickyMajorStats {
        if (comptime !sticky_major_enabled) return .{};
        return self.sticky_major.stats;
    }

    pub fn stickyMajorFullBaseline(self: *const Registry) struct {
        settled_bytes: usize,
        pressure_threshold: usize,
    } {
        if (comptime !sticky_major_enabled) return .{ .settled_bytes = 0, .pressure_threshold = 0 };
        return .{
            .settled_bytes = self.sticky_major.last_full_settled_bytes,
            .pressure_threshold = self.sticky_major.full_pressure_threshold,
        };
    }

    /// Discard an open incremental cycle so a full STW collection can run.
    ///
    /// Explicit collections abort rather than join: an object marked during
    /// the increments that has since died is floating garbage the remark
    /// would honor, and "collect everything" callers -- which is every
    /// determinism-sensitive test -- require full precision. The STW
    /// collector's own `clearMarks` re-derives everything the increments
    /// knew, so nothing is lost but the work already done.
    pub fn abortIncrementalCycle(self: *Registry) void {
        if (comptime !concurrent_enabled) return;
        self.abortCycleEnvelope();
        if (!self.concurrent.markingActive()) return;
        self.concurrent.major_marking_active.store(false, .monotonic);
        self.concurrent_mark_queue.reset();
        self.mark_stack.len = 0;
        // The trace already promoted whatever it reached; the young
        // structures still describe those cells as young. Minors stay closed
        // until a major commits and makes the two agree again.
        self.generation.abandonMajorRetirement();
        self.concurrent.stats.cycles_aborted += 1;
    }

    /// Publish the settled account and the threshold derived from it for the
    /// next automatic incremental cycle. This pair is one policy decision;
    /// keeping it intact is what makes the later S/T/P tuple same-domain.
    pub fn noteCycleEnvelopeBaseline(self: *Registry, start_bytes: usize, threshold_bytes: usize) void {
        if (comptime !concurrent_enabled) return;
        if (!gc_trace_stw_reports.detailed_reports) return;
        std.debug.assert(!self.concurrent.envelope_active);
        if (self.concurrent.envelope_baseline_valid) self.memory.endCyclePeakTracking();
        self.concurrent.envelope_next_start_bytes = start_bytes;
        self.concurrent.envelope_next_threshold_bytes = threshold_bytes;
        self.concurrent.envelope_cycle_peak_bytes = start_bytes;
        self.concurrent.envelope_baseline_valid = threshold_bytes != 0;
        if (self.concurrent.envelope_baseline_valid) {
            self.memory.beginCyclePeakTracking(&self.concurrent.envelope_cycle_peak_bytes);
        }
    }

    /// A caller-supplied threshold has no settled S selected by the growth
    /// policy, so the next cycle must not be presented as §1.3 evidence.
    pub fn invalidateCycleEnvelopeBaseline(self: *Registry) void {
        if (comptime !concurrent_enabled) return;
        if (self.concurrent.envelope_active) {
            self.memory.endCyclePeakTracking();
            self.concurrent.envelope_active = false;
            self.concurrent.stats.envelope_skipped_cycles +|= 1;
        } else if (self.concurrent.envelope_baseline_valid) {
            self.memory.endCyclePeakTracking();
        }
        self.concurrent.envelope_baseline_valid = false;
    }

    /// Consume the preceding reset's S/T pair and begin exact account-peak
    /// tracking before any initial-mark allocation can occur.
    pub fn beginCycleEnvelope(self: *Registry, threshold_bytes: usize) void {
        if (comptime !concurrent_enabled) return;
        if (!gc_trace_stw_reports.detailed_reports) return;
        std.debug.assert(!self.concurrent.envelope_active);
        if (!self.concurrent.envelope_baseline_valid or
            self.concurrent.envelope_next_threshold_bytes != threshold_bytes)
        {
            self.invalidateCycleEnvelopeBaseline();
            self.concurrent.stats.envelope_skipped_cycles +|= 1;
            return;
        }
        self.concurrent.envelope_baseline_valid = false;
        self.concurrent.envelope_cycle_start_bytes = self.concurrent.envelope_next_start_bytes;
        self.concurrent.envelope_cycle_threshold_bytes = threshold_bytes;
        self.concurrent.envelope_cycle_begin_bytes = self.memory.allocated_bytes;
        self.concurrent.envelope_active = true;
    }

    fn abortCycleEnvelope(self: *Registry) void {
        if (comptime !concurrent_enabled) return;
        if (!self.concurrent.envelope_active) return;
        self.memory.endCyclePeakTracking();
        self.concurrent.envelope_active = false;
    }

    fn finishCycleEnvelope(self: *Registry) void {
        if (comptime !concurrent_enabled) return;
        if (!self.concurrent.envelope_active) return;
        self.memory.endCyclePeakTracking();
        self.concurrent.envelope_active = false;

        const start = self.concurrent.envelope_cycle_start_bytes;
        const threshold = self.concurrent.envelope_cycle_threshold_bytes;
        const begin = self.concurrent.envelope_cycle_begin_bytes;
        const peak = self.concurrent.envelope_cycle_peak_bytes;
        std.debug.assert(threshold != 0);
        std.debug.assert(peak >= threshold);
        const stats = &self.concurrent.stats;
        stats.envelope_measured_cycles +|= 1;
        const replaces_max = stats.envelope_max_threshold_bytes == 0 or
            @as(u128, peak) * stats.envelope_max_threshold_bytes >
                @as(u128, stats.envelope_max_peak_bytes) * threshold;
        if (replaces_max) {
            stats.envelope_max_start_bytes = start;
            stats.envelope_max_threshold_bytes = threshold;
            stats.envelope_max_begin_bytes = begin;
            stats.envelope_max_peak_bytes = peak;
        }
    }

    pub inline fn shadeForConcurrentMark(self: *Registry, owner: *GCObjectHeader, target: *GCObjectHeader) void {
        if (comptime !concurrent_enabled) return;
        // The exit split is a --gc-stats structural guardrail, not collector
        // policy. Keep the default tracing build's hot barrier at lane-e's
        // counter-free cost; tests and explicitly requested detailed reports
        // retain lane-f's complete call accounting.
        const report = builtin.is_test or gc_trace_stw_reports.detailed_reports;
        if (report) self.concurrent.stats.barrier_calls += 1;
        if (self.headerMarked(target)) {
            if (report) self.concurrent.stats.barrier_marked_target += 1;
            return;
        }
        // rc-managed targets (shape adoption is the live case: a black object
        // takes a fresh shape) must not enter the queue -- the mutator can
        // free them while queued and the entry dangles. Marking without
        // queuing is the black-without-tracing hole, so instead the OWNER is
        // re-queued: its re-trace reaches the target through `shade`, whose
        // queue mode expands rc-managed kinds synchronously. In the
        // vanishing case where the owner is itself rc-managed, fall back to
        // the queue's overflow contract: mark the target and set the flag, so
        // the remark's marked-object rescan traces its children.
        // An UNPUBLISHED owner's stores are construction, not mutation: the
        // object is queued grey at publication and its trace shades every
        // initial edge, so the barrier owes these writes nothing. Queueing
        // the owner here instead was the corpse factory -- a failed
        // construction's errdefer-destroy left the queue naming a recycled
        // cell.
        if (!owner.meta().alloc_info.heap_accounted) {
            if (report) self.concurrent.stats.barrier_unpublished_owner += 1;
            return;
        }
        // Mirror rule for the target: an unpublished target queues itself
        // grey at publication, and pushing it now would name a cell whose
        // construction can still fail and free it.
        if (!target.meta().alloc_info.heap_accounted) {
            if (report) self.concurrent.stats.barrier_unpublished_target += 1;
            return;
        }
        const kind = target.meta().flags.kind;
        if (kind == .shape or kind == .realm_context) {
            const owner_kind = owner.meta().flags.kind;
            if (owner_kind == .shape or owner_kind == .realm_context) {
                self.setHeaderMarked(target);
                self.concurrent.stats.shaded += 1;
                self.concurrent_mark_queue.overflowed.store(true, .release);
                return;
            }
            if (report) self.concurrent.stats.barrier_requeued_owner += 1;
            _ = self.concurrent_mark_queue.pushSingle(owner);
            return;
        }
        self.setHeaderMarked(target);
        self.concurrent.stats.shaded += 1;
        _ = self.concurrent_mark_queue.pushSingle(target);
    }

    // `markAssist` used to live here: pop a slice of the queue and set mark
    // bits. Under grey-queue semantics that is unsound, not merely useless --
    // an entry's presence in the queue is the ONLY record that its children
    // are still untraced, so popping without tracing loses work. The panel no
    // longer advertises assist or floating-garbage counters that had no
    // production write site.

    /// Whether a minor is worth attempting: enough young objects to be worth
    /// the root scan, and no full collection already in flight. Deliberately
    /// simple — the scheduling policy that replaces it belongs with the
    /// allocation-headroom work, not with the collector mechanism.
    pub inline fn shouldTryMinor(self: *const Registry) bool {
        if (comptime !generation_enabled) return false;
        if (self.phase != .none) return false;
        if (stress_disable or stress_no_minor) return false;
        // Before the stress arm, not after: an open retirement transaction is
        // a correctness condition, and a diagnostic knob must not be able to
        // step past it. (Adversarial review, codex, 2026-08-27.)
        if (!self.generation.minorsAllowed()) return false;
        if (stress_collect) return self.generation.stats.young_count != 0;
        // A minor that keeps coming back empty is a root and stack scan spent
        // to learn that this workload's young objects do not die. Stop asking
        // until a major changes the answer.
        if (self.generation.minorSuspended()) return false;
        // §8.6 Prepare: "close admission of a new minor request". While a
        // major cycle is open every young object is black-published anyway,
        // so a minor would trace roots to reclaim nothing.
        if (comptime concurrent_enabled) {
            if (self.concurrent.markingActive()) return false;
        }
        // Minors run even while sliced destruction is pending. The first
        // version gated them, and the gate was the disease: destruction
        // windows with no minor let the young set grow to the millions
        // (measured 1.7M at minor start on splay), the completion-time
        // account ballooned, and the 1.75x threshold amplified it into a
        // five-fold heap. What made the gate necessary -- a minor's
        // conservative scan resolving a parked corpse -- is handled at the
        // one point every scan funnels through: `shade` refuses
        // `cycle_visited` headers, the bit `detachCycleCandidate` already
        // stamps on everything in the morgue.
        return self.generation.stats.young_count >= minor_young_threshold;
    }

    /// Generational write barrier (§8.3). Lives on the Registry because the
    /// state and its allocator are private here; callers pass owner and child
    /// headers and stay out of the generation representation.
    /// Remember `owner` if it is old, without inspecting what is being stored.
    ///
    /// The value-shaped `generationalBarrier` has to be spelled at every store,
    /// and dense-array appends reach the storage through four different
    /// callers that each write the slot themselves. Guarding the one function
    /// that hands out a fresh dense slot covers all of them, and covers the
    /// fifth one nobody has written yet. Remembering an owner whose stored
    /// value turns out to be old or primitive costs one re-trace of an object
    /// the minor would otherwise skip; missing one frees a live object.
    ///
    /// The marking arm RE-QUEUES THE OWNER. An earlier version said the
    /// concurrent arm was "deliberately absent" because a choke point cannot
    /// shade the exact target -- true, and it did not need to: re-tracing the
    /// owner finds every child the bulk write installed, including the new
    /// one. What "absent" actually meant was that a black array's appends
    /// were invisible to the remark (the remembered set is retired at cycle
    /// begin and consumed only by minors), so anything reachable only through
    /// a mid-cycle dense append was condemned alive. richards, crypto and
    /// raytrace all failed on exactly this the first time destruction slices
    /// widened the mutator windows enough to expose it.
    ///
    /// A hot array appended in a loop re-pushes once per bulk write -- the
    /// mark state cannot dedup an owner that must be re-traced -- so the ring
    /// can overflow. Overflow is the queue's sound downgrade: the remark
    /// rescans every marked object. Worse pause, never a lost object.
    pub inline fn rememberOwnerForBulkWrite(self: *Registry, owner: *GCObjectHeader) void {
        if (comptime !generation_enabled) return;
        if (comptime concurrent_enabled) {
            if (self.concurrent.markingActive()) {
                // Same publication rule as the value barrier: an unpublished
                // owner's edges are covered by its published-grey trace.
                if (owner.meta().alloc_info.heap_accounted) {
                    _ = self.concurrent_mark_queue.pushSingle(owner);
                }
                return;
            }
        }
        if (self.generation.isYoung(owner)) return;
        self.rememberGenerationalOwner(owner);
    }

    /// Target-bearing callers reach the bit only after old-owner/young-target
    /// classification, so the 91% young-owner exit and old-target exit pay
    /// nothing for it; bulk callers likewise classify the owner first. Object
    /// owners use Metadata byte 6 as a membership cache; the hash map remains
    /// authoritative and every non-object owner keeps the existing fallback.
    inline fn rememberGenerationalOwner(self: *Registry, owner: *GCObjectHeader) void {
        if (traceRememberedCacheEligible(owner.metaConst().flags.kind)) {
            const summary = &owner.meta().lifetime.trace.object_shape_summary;
            if (summary.* & trace_remembered_mask != 0) return;
            if (!self.generation.rememberOwner(addressRegistryAllocator(), owner)) return;
            summary.* |= trace_remembered_mask;
            return;
        }
        _ = self.generation.rememberOwner(addressRegistryAllocator(), owner);
    }

    inline fn clearGenerationalRememberedBit(owner: *GCObjectHeader) void {
        if (!traceRememberedCacheEligible(owner.metaConst().flags.kind)) return;
        owner.meta().lifetime.trace.object_shape_summary &= ~trace_remembered_mask;
    }

    inline fn clearGenerationalRememberedBits(self: *Registry) void {
        if (comptime !generation_enabled) return;
        var remembered = self.generation.rememberedIterator();
        while (remembered.next()) |addr| {
            const owner: *GCObjectHeader = @ptrFromInt(addr.*);
            clearGenerationalRememberedBit(owner);
        }
    }

    /// Retire the authoritative map and cache as one transaction. Clearing the
    /// map alone would leave a stale hit that suppresses the next generation's
    /// first owner insertion. The marker masks this orthogonal high bit from
    /// its low-seven-bit Shape summary, so no entry-side whole-map walk is
    /// needed and open incremental slices may use the cache normally.
    pub fn retireGenerationalYoungSet(self: *Registry) void {
        if (comptime !generation_enabled) return;
        // I3: the two halves below are one transaction. Between them the cache
        // reads "absent" while the map is still populated, which is the single
        // interval where `forgetUnremembered`'s premise is false.
        self.generation.openRetirementWindow();
        self.clearGenerationalRememberedBits();
        self.generation.retireYoungSet();
    }

    /// Detach-side counterpart of `rememberGenerationalOwner`.
    ///
    /// Reading the membership bit, removing the map entry and clearing the bit
    /// are ONE step on purpose. The previous shape cleared the bit first and
    /// then removed unconditionally; moving the bit test into `forget` under
    /// that order would have read a zero this function had just written, so
    /// the skip would be unconditional and every remembered entry would rot
    /// into a dangling address (audit §8.1).
    ///
    /// I0 -- for an eligible kind, bit7 clear implies absent from the map --
    /// is what licenses the skip. I1: ineligible owners never set the bit, so
    /// the kind gate is mandatory; it is free, since `flags.kind` shares the
    /// metadata byte `forget` already loads for `flags.young`. I2: the bit is
    /// published only after `rememberOwner` returns true, so an OOM leaves
    /// bit=0/map=0 rather than the one combination that would break I0.
    ///
    /// The gate was `== .object` until audit §10 widened it. `.object` turned
    /// out never to reach here on splay/raytrace/earley-boyer at all -- block
    /// cells are reclaimed by the bitmap sweep, so the detach traffic is the
    /// list carriers, `.shape` and `.var_ref` (§9.5).
    inline fn forgetGenerationalOwner(self: *Registry, header: *GCObjectHeader) void {
        if (traceRememberedCacheEligible(header.metaConst().flags.kind)) {
            const summary = &header.meta().lifetime.trace.object_shape_summary;
            if (summary.* & trace_remembered_mask == 0) {
                self.generation.forgetUnremembered(header);
                return;
            }
            summary.* &= ~trace_remembered_mask;
        }
        self.generation.forget(header);
    }

    /// Deletion mutant for the sticky fresh-trace oracle. A missing owner must
    /// remove both the authoritative entry and its redundant cache bit; leaving
    /// only the bit would manufacture an invalid representation instead of the
    /// missing-barrier state the oracle is meant to reject.
    pub fn forgetGenerationalOwnerForTest(self: *Registry, header: *GCObjectHeader) void {
        if (comptime !builtin.is_test) @compileError("test-only remembered-owner mutation");
        self.forgetGenerationalOwner(header);
    }

    inline fn generationalBarrierDetailed(self: *Registry, owner: *GCObjectHeader, target: *GCObjectHeader) void {
        self.generation.stats.barrier_calls += 1;
        if (self.generation.isYoung(owner)) {
            self.generation.stats.barrier_young_owner += 1;
            return;
        }
        if (!self.generation.isYoung(target)) {
            self.generation.stats.barrier_old_target += 1;
            return;
        }
        self.rememberGenerationalOwner(owner);
    }

    pub inline fn generationalBarrier(self: *Registry, owner: *GCObjectHeader, child: ?*GCObjectHeader) void {
        if (comptime !generation_enabled) return;
        const target = child orelse return;
        // §8.4: while a major is marking, every strong write shades its exact
        // new target instead of taking the generational path. The two are
        // alternatives, not a sequence -- a shaded object is reachable for
        // this cycle, so remembering its owner as well would be redundant.
        if (comptime concurrent_enabled) {
            if (self.concurrent.markingActive()) {
                self.shadeForConcurrentMark(owner, target);
                return;
            }
        }
        // The counter block is diagnostic, not policy, and it was two
        // unconditional RMWs on a path that runs tens of millions of times
        // per benchmark. JSC's barrier fast path carries zero counters
        // (`m_barriersExecuted` lives in the slow path only). Same rule here:
        // pay for numbers when someone asked for them.
        if (gc_trace_stw_reports.detailed_reports) {
            self.generationalBarrierDetailed(owner, target);
            return;
        }
        if (self.generation.isYoung(owner)) return;
        if (!self.generation.isYoung(target)) return;
        self.rememberGenerationalOwner(owner);
    }

    /// JSValue-shaped write barrier. Keep the child raw until an old owner
    /// actually needs its target classified: young owners account for the vast
    /// majority of property writes and a minor scans them regardless.
    ///
    /// Active major marking is the exception. Its insertion barrier shades the
    /// exact target for this cycle, even when the owner is young, so classify
    /// before calling `shadeForConcurrentMark`. Detailed reports likewise keep
    /// the header-shaped barrier's ordering so their edge-only counters remain
    /// comparable with earlier runs.
    pub inline fn generationalBarrierValue(self: *Registry, owner: *GCObjectHeader, child: JSValue) void {
        if (comptime !generation_enabled) return;
        if (comptime concurrent_enabled) {
            if (self.concurrent.markingActive()) {
                const target = child.cycleMarkHeader() orelse return;
                self.shadeForConcurrentMark(owner, target);
                return;
            }
        }
        if (gc_trace_stw_reports.detailed_reports) {
            const target = child.cycleMarkHeader() orelse return;
            self.generationalBarrierDetailed(owner, target);
            return;
        }
        if (self.generation.isYoung(owner)) return;
        const target = child.cycleMarkHeader() orelse return;
        if (!self.generation.isYoung(target)) return;
        self.rememberGenerationalOwner(owner);
    }

    /// The barrier queue's ring shares the registry's allocator for the same
    /// reason the registry uses it: collection-infrastructure allocation must
    /// not recurse into the JS heap account.
    pub inline fn markQueueAllocator() std.mem.Allocator {
        return addressRegistryAllocator();
    }

    inline fn addressRegistryAllocator() std.mem.Allocator {
        // Independent of the JS heap allocator: NoFail publication must not
        // grow a new fallible allocation on the object allocator, and
        // conservative lookup must not recurse into collectBeforeObjectAllocation.
        //
        // Independence is the requirement; going straight to the OS is not.
        // This runs on every publication, and page_allocator turns each
        // hash-map rehash and each page-bucket growth into an mmap/munmap
        // syscall pair -- which profiled at 97% of the tracing build's time.
        // A general-purpose allocator keeps the independence and amortizes
        // the syscalls.
        return std.heap.smp_allocator;
    }

    /// Subscribe the address registry to slab arena lifetime.
    ///
    /// Arenas are `arena_size`-aligned, so a conservative candidate resolves to
    /// its owning block by masking; all the registry needs is to know which
    /// masked bases are real arenas. Installing this is what lets
    /// `registerLiveAddress` stop inserting per published object.
    /// Route fixed-size plain objects to the collector's block heap.
    ///
    /// This is `serves_gc_nodes` becoming true in deed: the cell carries the
    /// same 8-byte metadata prefix the slab overlays, so `Header.meta()` and
    /// every existing consumer see an identical object -- only the memory
    /// under it and the free route differ. Objects first because they are the
    /// overwhelming majority of the heap (space histogram: 18.4M of 18.4M
    /// small allocations) and fixed-size, so the routing predicate is one
    /// comptime tag compare.
    pub fn serveObjectCells(self: *Registry, account: *memory.MemoryAccount) void {
        if (comptime !block_heap_enabled) return;
        // The conservative resolver needs the block geometry before the first
        // cell can appear in a stack slot.
        self.address_registry.block_heap = &self.block_heap;
        // `MemoryAccount` owns the allocation funnel, so give it the concrete
        // heap rather than two runtime function pointers. The trace build can
        // now direct-call and specialize `allocCell`; RC comptime-erases both
        // the field and the branch.
        account.gc_object_cell_heap = &self.block_heap;
    }

    pub fn observeSlabArenas(self: *Registry, slab: *memory.SmallObjectSlab) void {
        if (comptime !address_registry_enabled) return;
        // Kept so a failed arena registration can be recovered by re-walking
        // the slab, instead of leaving that arena invisible for its whole life.
        self.arena_slab = slab;
        // Arenas that already exist. In the current `initWithAccount` order
        // there are none -- `enableSmallObjectSlab` runs afterwards, so this
        // walk visits nothing -- but the observer's correctness must not depend
        // on that ordering, because an arena created before it is installed is
        // invisible to the conservative scanner forever.
        slab.forEachArena(self, struct {
            fn call(ctx: *anyopaque, base: usize) void {
                const registry: *Registry = @ptrCast(@alignCast(ctx));
                registry.address_registry.noteArenaCreated(addressRegistryAllocator(), base);
            }
        }.call);
        slab.arena_observer = .{
            .ctx = self,
            .on_create = struct {
                fn call(ctx: *anyopaque, base: usize) void {
                    const registry: *Registry = @ptrCast(@alignCast(ctx));
                    registry.address_registry.noteArenaCreated(addressRegistryAllocator(), base);
                }
            }.call,
            .on_release = struct {
                fn call(ctx: *anyopaque, base: usize) void {
                    const registry: *Registry = @ptrCast(@alignCast(ctx));
                    registry.address_registry.noteArenaReleased(base);
                }
            }.call,
        };
    }

    inline fn registerLiveAddress(self: *Registry, header: *GCObjectHeader, bytes: usize, tracked: bool) void {
        if (comptime !address_registry_enabled) return;
        if (!tracked) return;
        const info = header.metaConst().alloc_info;
        self.registerLiveAddressClassified(header, bytes, true, info.standalone, isBlockCellHeader(header));
    }

    /// `registerLiveAddress` for callers that already hold the header's
    /// `alloc_info` classification in a register. Publication reads that byte,
    /// then writes it, then would need it again for three separate decisions;
    /// threading the answers through keeps it to one load per publication.
    inline fn registerLiveAddressClassified(
        self: *Registry,
        header: *GCObjectHeader,
        bytes: usize,
        tracked: bool,
        standalone: bool,
        is_block_cell: bool,
    ) void {
        if (comptime !address_registry_enabled) return;
        if (!tracked) return;
        // Slab-backed objects need no entry: their arena is registered, the
        // mask finds it, and the `heap_accounted` bit set just above this call
        // is the same "live GC object" answer the table was storing. Only
        // standalone-prefix allocations -- past the slab's 512-byte class
        // ceiling, or over-aligned -- are unreachable that way.
        if (!standalone) {
            self.markPublishedYoungClassified(header, is_block_cell);
            return;
        }
        self.address_registry.insert(addressRegistryAllocator(), header, bytes) catch {
            self.address_registry.noteFailedInsert();
        };
        self.markPublishedYoungClassified(header, is_block_cell);
    }

    /// Generation shares publication's lifetime: an object is young from the
    /// moment it is published until a collection lets it survive. One bit in a
    /// byte the allocator already writes, rather than a hash-map insert per
    /// allocation.
    inline fn markPublishedYoung(self: *Registry, header: *GCObjectHeader) void {
        if (comptime !generation_enabled) return;
        self.markPublishedYoungClassified(header, isBlockCellHeader(header));
    }

    /// `markPublishedYoung` for callers holding the block-cell answer already.
    /// The young bit lives in flags (byte 3) and the block-cell class in
    /// alloc_info (byte 2) of the same prefix word, so deriving the class after
    /// the young store forced a reload of a byte adjacent to a just-issued
    /// store -- see `addInitializedWithSizeNoFail`'s note.
    inline fn markPublishedYoungClassified(self: *Registry, header: *GCObjectHeader, is_block_cell: bool) void {
        if (comptime !generation_enabled) return;
        // §8.6 concurrent mark: "new objects are black-published AND ALL
        // INITIAL STRONG EDGES ARE SHADED". Both halves, and the second is
        // load-bearing: field initialisation happens BEFORE publication, so
        // the write barrier fires on an owner that is not yet a real object
        // -- and the barrier must skip those (see shadeForConcurrentMark),
        // because queueing an unpublished owner plants a landmine: its
        // errdefer-destroy on a failed construction frees the cell while the
        // queue still names it, and the reused cell is a half-constructed
        // corpse at pop time (found by a test262 core dump, byte for byte).
        // Publication queues the object itself instead -- published-grey --
        // and its one trace covers every construction-time edge at once.
        if (comptime concurrent_enabled) {
            if (self.concurrent.markingActive()) {
                // Published-grey applies to PLAIN OBJECTS ONLY. An object is
                // the one kind a published container can hold before its
                // construction settles, so its initial edges need the push.
                // Every other kind becomes reachable through a store made
                // AFTER its construction completes -- a closure adopting its
                // FunctionBytecode, a frame linking a var_ref -- and that
                // store's barrier greys it at a moment it is fully traceable;
                // until then it stays WHITE, protected by its creator's stack
                // reference, which the remark's conservative rescan honors.
                // The first version pushed every kind here and re-planted
                // both mines this file had just cleared: shapes back in the
                // queue (mutator-freeable), and FunctionBytecode clones
                // popped mid-construction.
                if (header.meta().flags.kind == .object) {
                    self.setHeaderMarked(header);
                    _ = self.concurrent_mark_queue.pushSingle(header);
                }
            }
        }
        header.meta().flags.young = true;
        self.generation.stats.young_count += 1;
        if (comptime block_heap_enabled) {
            // Checker for the hoist: the classification handed in must still
            // be the one the header answers with. Setting `heap_accounted` /
            // `large` / `young` between the read and here must never move the
            // block_size_idx field.
            std.debug.assert(is_block_cell == isBlockCellHeader(header));
            if (is_block_cell) {
                // Block-granular young tracking: the block joins the young
                // list on its first young cell; the suffix anchor below is
                // list-population business only.
                const cell = @intFromPtr(header) - metadata_prefix_size;
                self.block_heap.noteYoungCell(BlockHeapMod.Block.fromCellTrusted(cell));
                return;
            }
        }
        // This object was just appended at the tail, so if no suffix was open
        // it starts here.
        if (self.young_head == null) {
            // Non-block publication captured the old list tail before linking.
            // A missing cursor would turn the next minor into a whole-list
            // predecessor search (or, worse, make it splice the wrong node).
            std.debug.assert(self.young_predecessor != null);
            self.young_head = header;
        }
    }

    inline fn unregisterLiveAddress(self: *Registry, header: *GCObjectHeader) void {
        if (comptime !address_registry_enabled) return;
        // Mirror of `registerLiveAddress`: nothing was inserted for a
        // slab-backed object, and `heap_accounted` is cleared by the free path
        // that brought us here, so the mask stops resolving it on its own.
        if (header.meta().alloc_info.standalone) {
            self.address_registry.remove(addressRegistryAllocator(), header);
        }
        if (comptime generation_enabled) {
            self.forgetGenerationalOwner(header);
            // The young set is a SUFFIX of `gc_obj_list` anchored at
            // `young_head`, so forgetting an object must also move the anchor
            // off it -- otherwise the next minor's `clearYoungMarks` walks a
            // freed header. Both gc_obj_list detach paths funnel through here
            // (`removeGcObject` and `unlinkObjectWithBytes`, the ordinary
            // mutator-side RC free used by shape replacement, var_ref release
            // and the typed frees), and both still have `header.next` valid:
            // the `listDel` follows this call. Freeing the anchor shrinks the
            // suffix to its successor; the suffix never grows here.
            if (self.young_head == header) {
                const next = header.next;
                self.young_head = if (next == &self.gc_obj_list.sentinel) null else next;
            }
        }
    }

    pub fn registerLiveStringRange(
        self: *Registry,
        is_rope: bool,
        base: []const u8,
        identity: usize,
    ) void {
        if (comptime string_registry_enabled) {
            const Kind = @import("gc_address_registry.zig").Kind;
            self.address_registry.insertRange(
                addressRegistryAllocator(),
                if (is_rope) Kind.rope else Kind.string,
                @intFromPtr(base.ptr),
                base.len,
                identity,
            ) catch {
                self.address_registry.noteFailedInsert();
            };
        }
    }

    pub fn unregisterLiveStringRange(self: *Registry, identity: usize) void {
        if (comptime string_registry_enabled) {
            self.address_registry.removePtr(addressRegistryAllocator(), identity);
        }
    }

    /// Histogram and sweep-window observation for a first-time publication.
    /// Restores do not call this (the object was already counted / windowed).
    inline fn observeNewPublication(self: *Registry, header: *GCObjectHeader, bytes: usize) void {
        if (comptime space_model_enabled) {
            if (comptime builtin.is_test or shadow_tracer_enabled) {
                self.space_histogram.record(bytes);
            } else if (gc_trace_stw_reports.detailed_reports) {
                @branchHint(.unlikely);
                self.recordSpacePublicationDetailed(bytes);
            }
        }
        if (comptime sweep_model_stats_enabled) {
            self.sweep_model.noteAllocated(addressRegistryAllocator(), @intFromPtr(header));
            self.sweep_model.refreshHeadroom(
                self.old_space.live_bytes +| self.large_space.live_bytes,
                self.policy.major_debt_threshold,
                self.stats.external_bytes,
            );
        }
    }

    /// `--gc-stats` publication histogram. The CLI enables detailed reports
    /// before creating the runtime; default production must not maintain four
    /// diagnostic counters on every object/shape publication. Outlining keeps
    /// the disabled arm to one flag load and branch instead of retaining the
    /// histogram's classify-and-update body in both publication funnels.
    noinline fn recordSpacePublicationDetailed(self: *Registry, bytes: usize) void {
        self.space_histogram.record(bytes);
    }

    fn appendZeroRef(self: *Registry, header: *GCObjectHeader) void {
        std.debug.assert(headerRefCount(header) == 0);
        std.debug.assert(!headerLinked(header));
        listAddTail(&self.zero_ref_list, header);
    }

    fn popZeroRef(self: *Registry) ?*GCObjectHeader {
        const header = listFirst(&self.zero_ref_list) orelse return null;
        listDel(&self.zero_ref_list, header);
        return header;
    }

    fn drainZeroRefs(self: *Registry, rt: anytype) void {
        if (listEmpty(&self.zero_ref_list)) return;
        self.stats.zero_ref_drains +|= 1;
        while (self.popZeroRef()) |queued| {
            std.debug.assert(headerRefCount(queued) == 0);
            std.debug.assert(self.zero_ref_current == null);
            self.zero_ref_current = queued;
            destroyZeroRefNow(rt, queued);
            self.zero_ref_current = null;
        }
    }

    /// Hold zero-ref GC nodes until a batch traversal is complete. QuickJS
    /// uses the same DECREF phase around its weakref_list walk so payload
    /// finalizers cannot unlink the next weak holder out from under the walk.
    pub fn beginDecrefPhase(self: *Registry) void {
        std.debug.assert(self.phase == .none);
        std.debug.assert(listEmpty(&self.zero_ref_list));
        // .none -> .decref; teardown's .deinit phase cannot overlap this
        // batch (asserted above).
        self.phase = .decref;
    }

    pub fn endDecrefPhase(self: *Registry, rt: anytype) void {
        std.debug.assert(self.phase == .decref);
        // .decref -> .none after the queued batch drains.
        defer self.phase = .none;
        self.drainZeroRefs(rt);
    }

    /// Move a value-bearing GC node to the intrusive zero-ref queue and drain
    /// it at the outermost release boundary. Mirrors QuickJS
    /// `__JS_FreeValueRT` + `free_zero_refcount` without allocating.
    pub fn enqueueZeroRef(self: *Registry, rt: anytype, header: *GCObjectHeader) void {
        std.debug.assert(headerRefCount(header) == 0);
        self.removeGcObject(header);
        // Weak-reference teardown observes this bit while the object is queued,
        // before Object.destroyFromHeader gets its turn to set it again.
        header.meta().flags.mark = true;
        self.appendZeroRef(header);

        if (self.phase != .none) {
            std.debug.assert(self.phase == .decref);
            return;
        }

        // .none -> .decref (guarded above) for the outermost queue drain.
        self.phase = .decref;
        self.endDecrefPhase(rt);
    }

    pub fn recordFailure(self: *Registry, err: CollectionError) void {
        self.stats.failed_collections += 1;
        self.stats.last_failure = switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.PayloadMarkFailed => .payload_mark_failed,
        };
    }

    pub fn recordSuccess(self: *Registry, result: CollectionResult) void {
        self.stats.last_failure = .none;
        self.stats.last_collection_time_ns = result.duration_ns;
        self.stats.cycle_gc_count +|= 1;
        self.stats.cycle_gc_time_ns +|= result.duration_ns;
        self.stats.freed_objects +|= result.freed_objects;
        self.recordPauseSample(result.duration_ns);
    }

    /// One STW slice of an incremental major cycle: begin, an increment, or
    /// the final remark. Each is its own sample in the major ring -- the ring
    /// answers "how long does this collector stop the world at once", and an
    /// incremental cycle stops it many times briefly. The per-cycle total is
    /// accumulated separately for §1.3's cumulative-STW row.
    pub const SliceKind = enum(u2) { begin, increment, destroy, finish };

    pub fn recordMajorSlicePause(self: *Registry, ns: u64, kind: SliceKind) void {
        self.recordPauseSample(ns);
        if (comptime concurrent_enabled) {
            self.concurrent.cycle_stw_ns += ns;
            const slot = &self.concurrent.stats.segment_max_ns[@intFromEnum(kind)];
            if (ns > slot.*) slot.* = ns;
            self.concurrent.stats.total_stw_by_kind[@intFromEnum(kind)] +|= ns;
            self.concurrent.stats.total_segments_by_kind[@intFromEnum(kind)] +|= 1;
        }
    }

    /// Cycle-completion accounting for an incremental major. Mirrors
    /// `recordSuccess` minus the ring push: the slices already recorded
    /// themselves, and pushing the cycle total as one more sample would count
    /// the same nanoseconds twice.
    pub fn recordIncrementalCycleSuccess(self: *Registry, result: CollectionResult) void {
        self.finishCycleEnvelope();
        self.stats.last_failure = .none;
        self.stats.cycle_gc_count +|= 1;
        self.stats.freed_objects +|= result.freed_objects;
        if (comptime concurrent_enabled) {
            const total = self.concurrent.cycle_stw_ns;
            // `result.duration_ns` is intentionally the completion poll's
            // pause for the host-facing call. The stats fields promise major
            // collection time, so they own the whole cycle's accumulated STW.
            self.stats.last_collection_time_ns = total;
            self.stats.cycle_gc_time_ns +|= total;
            self.concurrent.stats.last_cycle_stw_ns = total;
            if (total > self.concurrent.stats.max_cycle_stw_ns) {
                self.concurrent.stats.max_cycle_stw_ns = total;
            }
            self.concurrent.cycle_stw_ns = 0;
        } else {
            self.stats.last_collection_time_ns = result.duration_ns;
            self.stats.cycle_gc_time_ns +|= result.duration_ns;
        }
    }

    /// Credit a MINOR collection without putting its pause in the major ring.
    ///
    /// The two populations differ by more than an order of magnitude -- a minor
    /// is judged on being short, a major on bounding the whole heap -- so
    /// mixing them makes the percentile panel report the wrong thing entirely.
    /// A run doing 90% minors printed a p50 of 758us against a true major
    /// median of 16.45ms, and the target it is checked against
    /// (`docs/tracing-gc-design.md` §1.3) is a major target. The minor's own
    /// distribution lives in `generation.stats`.
    pub fn recordMinorSuccess(self: *Registry, result: CollectionResult) void {
        self.stats.last_failure = .none;
        self.stats.freed_objects +|= result.freed_objects;
    }

    fn recordPauseSample(self: *Registry, duration_ns: u64) void {
        self.stats.pause_samples[self.stats.pause_sample_cursor] = duration_ns;
        self.stats.pause_sample_cursor = (self.stats.pause_sample_cursor + 1) % pause_sample_capacity;
        self.stats.pause_sample_count +|= 1;
    }

    /// Is every live arena resolvable, so that sweeping is sound?
    ///
    /// An arena that failed to register hides every object it holds from the
    /// conservative stack scan, so a sweep performed in that state can free a
    /// live object. Recovery is a re-walk of the slab's arena lists, which
    /// costs one pass over at most a few thousand pointers and only happens
    /// after an allocation failure. If it still cannot record them, the caller
    /// must mark without sweeping: a bounded leak instead of a use-after-free.
    pub fn arenaSetWhole(self: *Registry) bool {
        if (comptime !address_registry_enabled) return true;
        if (!self.address_registry.arenas_incomplete) return true;
        const slab = self.arena_slab orelse return false;
        return self.address_registry.resyncArenas(addressRegistryAllocator(), slab);
    }

    pub fn verifyIntrusiveList(self: *Registry) InvariantError!void {
        try self.verifyAuxiliaryIntrusiveLists();
        _ = try verifyCircularHeaderList(&self.gc_obj_list, null, true);

        var saw_young_head = false;
        const sentinel = &self.gc_obj_list.sentinel;
        var current = sentinel.next;
        var previous: *GCObjectHeader = sentinel;
        while (current) |h| {
            if (h == sentinel) break;
            if (comptime generation_enabled) {
                // The young set is exactly the suffix starting at
                // `young_head`. Checking membership alone is not enough: a
                // stranded anchor whose slab has been recycled points at a
                // live list member again, so "found it" proves nothing. The
                // suffix shape does prove it -- a recycled anchor lands in
                // the wrong place and one of the two halves fails.
                if (self.young_head == h) {
                    if (self.young_predecessor != previous) return error.DanglingYoungHead;
                    saw_young_head = true;
                }
                const is_young = h.metaConst().flags.young;
                if (self.young_head != null) {
                    if (!saw_young_head and is_young) return error.DanglingYoungHead;
                    if (saw_young_head and !is_young) return error.DanglingYoungHead;
                } else if (is_young) return error.DanglingYoungHead;
            }
            if (!isCycleCandidate(h)) return error.CorruptGcList;
            if (comptime trace_stw_enabled) {
                const state = h.metaConst().lifetime.trace;
                if (state.flags.reserved != 0 or state.flags.husk or state.mark_epoch > self.header_mark_epoch)
                    return error.InvalidHeaderState;
                // Every list member is an eligible carrier (the range gate is
                // the cycle-candidate set), so bit7 is legitimately theirs;
                // only the Object-owned low seven bits must be clear here.
                if (h.metaConst().flags.kind != .object and
                    state.object_shape_summary & trace_object_shape_summary_mask != 0)
                    return error.InvalidHeaderState;
                if (!refCountRemoved(h.metaConst().flags.kind) and headerRefCount(h) < 0)
                    return error.NegativeRefCount;
            } else if (headerRefCount(h) < 0) return error.NegativeRefCount;
            // Trial deletion must leave every mark bit clear once a round
            // ends. Sticky generations invert that: a survivor's mark bit is
            // precisely what records "this is old now" between collections
            // (§8.2), so the invariant only applies where marks are transient.
            if (comptime !generation_enabled) {
                if (h.meta().flags.mark and self.phase == .none) return error.MarkBitLeftSet;
            }
            const next = h.next orelse return error.CorruptGcList;
            previous = h;
            current = next;
        }
        // Free-standing check rather than an assert at each detach: the walk
        // above is already paying for the traversal, and a stale anchor is
        // only observable as a crash one collection later.
        if (comptime generation_enabled) {
            if (self.young_head != null and !saw_young_head) return error.DanglingYoungHead;
            if (self.young_head == null and self.young_predecessor != null) return error.DanglingYoungHead;
        }
    }

    fn verifyAuxiliaryIntrusiveLists(self: *Registry) InvariantError!void {
        _ = try verifyCircularHeaderList(&self.tmp_obj_list, null, false);
        _ = try verifyCircularHeaderList(&self.zero_ref_list, null, true);

        var doomed_nodes: usize = 0;
        var cursor_found = self.doomed_cursor == null;
        for (&self.doomed_by_kind, 0..) |*head, kind_index| {
            const kind: GcKind = @enumFromInt(kind_index);
            doomed_nodes += try verifyCircularHeaderList(head, kind, false);
            if (!cursor_found) {
                var node = head.sentinel.next;
                while (node) |candidate| {
                    if (candidate == &head.sentinel) break;
                    if (candidate == self.doomed_cursor.?) cursor_found = true;
                    node = candidate.next;
                }
            }
        }
        if (!cursor_found) return error.DoomedCursorMismatch;

        var deferred_count: usize = 0;
        var slow = self.cycle_deferred_frees.head;
        var fast = self.cycle_deferred_frees.head;
        while (fast) |first| {
            fast = first.next;
            if (fast) |second| fast = second.next;
            if (slow) |node| slow = node.next;
            if (fast != null and fast == slow) return error.CorruptDeferredFreeStack;
        }
        var deferred = self.cycle_deferred_frees.head;
        while (deferred) |node| {
            if (!node.metaConst().flags.finalizing) return error.CorruptDeferredFreeStack;
            deferred_count += 1;
            deferred = node.next;
        }
        if (deferred_count != self.cycle_deferred_frees.count) {
            return error.CorruptDeferredFreeStack;
        }

        const block_doomed = if (comptime block_heap_enabled)
            self.block_heap.doomed_blocks != null
        else
            false;
        if ((doomed_nodes != 0 or block_doomed or self.doomed_cursor != null) and !self.doomed_pending) {
            return error.DoomedPendingMismatch;
        }
    }

    /// Check the reserved pin-ledger entries that protect detached generator
    /// shells. The sentinel must never bless a published, non-block, partially
    /// initialized, or wrong-class header as the BlockHeap publication
    /// exception.
    pub fn verifyConstructionRoots(self: *const Registry) InvariantError!void {
        if (comptime !trace_stw_enabled) return;
        for (self.pin_entries) |entry| {
            if (entry.count != construction_pin_count) continue;
            if (!self.isConstructionRoot(entry.header)) {
                return error.ConstructionRootStateMismatch;
            }
            try verifyMetadataSemantics(entry.header.metaConst(), .object, .construction_block_object);
        }
    }

    fn verifyPublishedHeaderRepresentation(
        self: *const Registry,
        header: *const GCObjectHeader,
        expected_kind: ?GcKind,
    ) InvariantError!void {
        const meta = header.metaConst();
        const kind = expected_kind orelse meta.flags.kind;
        verifyMetadataSemantics(meta, kind, .registry_published) catch |err| {
            std.debug.print(
                "gc: REPRESENTATION HEADER population={s} header=0x{x} kind={s} size_class={d} alloc_info=0x{x:0>2} flags=0x{x:0>2} lifetime=0x{x:0>8} error={s}\n",
                .{
                    if (expected_kind == null) "live" else "doomed",
                    @intFromPtr(header),
                    @tagName(kind),
                    meta.size_class,
                    @as(u8, @bitCast(meta.alloc_info)),
                    @as(u8, @bitCast(meta.flags)),
                    @as(u32, @bitCast(meta.lifetime)),
                    @errorName(err),
                },
            );
            return err;
        };

        if (kind == .object) {
            const owner: *const object.Object = @alignCast(@fieldParentPtr("header", header));
            if (!owner.traceShapeSummaryMatches())
                return error.ObjectShapeSummaryMismatch;
        }
        // bit=1 => map=1, for EVERY carrier that leases the bit (audit §10).
        // Keeping this outside the `.object` arm is the point of the widening:
        // a cache bit no auditor can see is a cache bit with no soundness
        // evidence behind it, and `.shape`/`.var_ref` are where the traffic is.
        if (comptime generation_enabled) {
            if (traceRememberedCacheEligible(kind)) {
                const cached = meta.lifetime.trace.object_shape_summary & trace_remembered_mask != 0;
                if (cached and !self.generation.remembered.contains(@intFromPtr(header)))
                    return error.RememberedCacheWithoutOwner;
            }
        }

        if (comptime block_heap_enabled) {
            const cell_addr = @intFromPtr(header) - metadata_prefix_size;
            const physical_block = self.block_heap.blockOf(@ptrFromInt(cell_addr));
            const stamped_block = meta.alloc_info.block_size_idx == representation.block_cell_size_class;
            if ((physical_block != null) != stamped_block)
                return error.RepresentationAllocationCarrierMismatch;
            if (physical_block) |block| {
                if (kind != .object) return error.RepresentationAllocationCarrierMismatch;
                const actual_index = block.cellIndex(cell_addr) orelse
                    return error.RepresentationCellIndexMismatch;
                if (meta.size_class != actual_index or !block.cellAllocated(actual_index))
                    return error.RepresentationCellIndexMismatch;
            }
        }
    }

    /// Whole-runtime representation audit.  It covers both publication
    /// populations: the ordinary list plus bitmap-enumerated block cells, and
    /// the non-block doomed buckets that have been detached from that list but
    /// whose prefixes remain live until sliced destruction finishes. Call only
    /// at stable boundaries: remembered-map retirement clears each carrier's
    /// cache bit before clearing the map, so the two representations must agree
    /// in both directions whenever this checker runs.
    pub fn verifyRepresentationInvariants(self: *const Registry) InvariantError!void {
        if (comptime !trace_stw_enabled) return;

        var live = self.objectIterator();
        while (live.next()) |header| {
            try self.verifyPublishedHeaderRepresentation(header, null);
        }
        for (&self.doomed_by_kind, 0..) |*head, kind_index| {
            const expected: GcKind = @enumFromInt(kind_index);
            var cursor = head.sentinel.next;
            while (cursor) |header| {
                if (header == &head.sentinel) break;
                try self.verifyPublishedHeaderRepresentation(header, expected);
                cursor = header.next;
            }
        }
        if (comptime generation_enabled) {
            var remembered = self.generation.rememberedIterator();
            while (remembered.next()) |addr| {
                const header: *GCObjectHeader = @ptrFromInt(addr.*);
                if (!self.address_registry.containsHeader(header))
                    return error.RememberedOwnerNotLive;
                // map=1 => bit=1, the other direction. Widened with the cache
                // itself: an eligible resident whose bit is clear is precisely
                // the state that makes `forgetUnremembered` strand a dangling
                // address, so the checker must cover every leasing kind.
                if (traceRememberedCacheEligible(header.metaConst().flags.kind) and
                    header.metaConst().lifetime.trace.object_shape_summary & trace_remembered_mask == 0)
                {
                    return error.RememberedOwnerMissingCache;
                }
            }
        }
    }

    /// Check the sticky-generation census and remembered-owner roots at a
    /// stable collection boundary. A stale remembered address is dereferenced
    /// by the next minor; an under-count silently postpones that minor.
    pub fn verifyGenerationInvariants(self: *Registry) InvariantError!void {
        if (comptime !generation_enabled) return;
        var actual_young: usize = 0;
        var young = self.youngIterator();
        while (young.next()) |_| actual_young += 1;
        if (actual_young != self.generation.stats.young_count) return error.YoungCountMismatch;
        if (self.generation.remembered.count() != self.generation.stats.remembered_owners) {
            return error.RememberedCountMismatch;
        }
        var remembered = self.generation.remembered.keyIterator();
        while (remembered.next()) |addr| {
            const header: *GCObjectHeader = @ptrFromInt(addr.*);
            if (!self.address_registry.containsHeader(header)) return error.RememberedOwnerNotLive;
            if (header.metaConst().flags.young) return error.RememberedOwnerYoung;
        }
    }

    /// A successful major commit must close the trace-coupled retirement
    /// transaction and leave no survivor in the young population.
    pub fn verifyMajorRetirementCommit(self: *Registry) InvariantError!void {
        if (comptime !generation_enabled) return;
        if (self.generation.major_retirement != .clean or
            self.young_head != null or
            self.young_predecessor != null or
            self.generation.stats.young_count != 0 or
            self.generation.remembered.count() != 0 or
            self.generation.stats.remembered_owners != 0)
        {
            return error.RetirementStateMismatch;
        }
        if (comptime block_heap_enabled) {
            if (self.block_heap.young_blocks != null) return error.RetirementStateMismatch;
        }
        var survivors = self.objectIterator();
        while (survivors.next()) |header| {
            if (!header.metaConst().flags.young) continue;
            if (self.headerMarked(header) or header.metaConst().flags.is_pinned) {
                return error.RetirementYoungSurvivor;
            }
        }
    }

    pub fn verifyHeapAccounting(self: *const Registry, rt: anytype) InvariantError!void {
        var heap_live_bytes: usize = 0;
        var old_live_bytes: usize = 0;
        var large_object_bytes: usize = 0;

        var iterator = self.objectIterator();
        while (iterator.next()) |header| {
            if (!header.metaConst().alloc_info.heap_accounted) return error.MissingHeapAllocation;
            if (header.pinned() and self.pinEntryIndex(header) == null) {
                return error.PinnedHeaderMissingEntry;
            }
            const bytes = heapByteSizeFromHeader(rt, header);
            if (bytes == 0) return error.MissingHeapAllocation;
            heap_live_bytes = std.math.add(usize, heap_live_bytes, bytes) catch std.math.maxInt(usize);
            if (self.isLargeAllocation(bytes)) {
                large_object_bytes = std.math.add(usize, large_object_bytes, bytes) catch std.math.maxInt(usize);
            } else {
                old_live_bytes = std.math.add(usize, old_live_bytes, bytes) catch std.math.maxInt(usize);
            }
        }

        for (self.pin_entries, 0..) |entry, index| {
            if (entry.count == 0) return error.EmptyPinEntry;
            if (entry.count == construction_pin_count) {
                if (!self.isConstructionRoot(entry.header)) {
                    return error.ConstructionRootStateMismatch;
                }
            } else if (!self.containsHeader(entry.header)) return error.PinEntryNotLive;
            if (!entry.header.pinned()) return error.PinnedHeaderFlagMismatch;
            for (self.pin_entries[0..index]) |previous| {
                if (previous.header == entry.header) return error.DuplicatePinEntry;
            }
        }

        var external_token_bytes: usize = 0;
        for (self.external_tokens, 0..) |entry, index| {
            if (entry.id == 0 or entry.bytes == 0) return error.EmptyExternalMemoryToken;
            for (self.external_tokens[0..index]) |previous| {
                if (previous.id == entry.id) return error.DuplicateExternalMemoryToken;
            }
            external_token_bytes = std.math.add(usize, external_token_bytes, entry.bytes) catch std.math.maxInt(usize);
        }

        // heap_live / old_live / large_object bytes are derived from the space
        // accounts (the single source of truth since they are no longer mirrored
        // in gc.stats). The object-list walk cross-checks that the space accounts
        // agree with the actual live headers.
        const space_heap_live = self.old_space.live_bytes +| self.large_space.live_bytes;
        if (heap_live_bytes != space_heap_live) return error.HeapLiveBytesMismatch;
        if (old_live_bytes != self.old_space.live_bytes) return error.OldLiveBytesMismatch;
        if (large_object_bytes != self.large_space.live_bytes) return error.LargeObjectBytesMismatch;
        const accounted_external_bytes = std.math.add(usize, external_token_bytes, self.stats.external_untracked_bytes) catch std.math.maxInt(usize);
        if (accounted_external_bytes != self.stats.external_bytes) return error.ExternalTokenBytesMismatch;
        if (old_live_bytes != self.old_space.live_bytes) return error.OldSpaceLiveBytesMismatch;
        if (large_object_bytes != self.large_space.live_bytes) return error.LargeSpaceLiveBytesMismatch;
    }

    pub fn verifyNoExternalTokenLeaks(self: Registry) InvariantError!void {
        if (self.external_tokens.len != 0) return error.LeakedExternalMemoryToken;
        if (self.stats.external_bytes != 0) return error.ExternalTokenBytesMismatch;
        if (self.stats.external_untracked_bytes != 0) return error.ExternalTokenBytesMismatch;
    }

    /// Diagnostic/test-only: derived by walking, exactly like `liveCountKind`.
    /// The hot alloc/free paths keep no live-object counter (qjs
    /// add_gc_object/remove_gc_object are pure list splices).
    pub fn liveCount(self: *const Registry) usize {
        var count: usize = 0;
        var iterator = self.objectIterator();
        while (iterator.next()) |_| count += 1;
        return count;
    }

    pub fn liveCountKind(self: *const Registry, kind: GcKind) usize {
        var count: usize = 0;
        var iterator = self.objectIterator();
        while (iterator.next()) |header| {
            if (header.metaConst().flags.kind == kind) count += 1;
        }
        return count;
    }

    pub fn containsHeader(self: *const Registry, header: *const GCObjectHeader) bool {
        if (self.zero_ref_current == header) return true;
        if (self.sweep_current == header) return true;
        // Condemned-but-not-yet-destroyed nodes are the sweep's analogue of
        // `zero_ref_list`: still owned, resources still intact.
        var condemned = self.tmp_obj_list.sentinel.next;
        while (condemned) |candidate| {
            if (candidate == &self.tmp_obj_list.sentinel) break;
            if (candidate == header) return true;
            condemned = candidate.next;
        }
        var queued = self.zero_ref_list.sentinel.next;
        while (queued) |candidate| {
            if (candidate == &self.zero_ref_list.sentinel) break;
            if (candidate == header) return true;
            queued = candidate.next;
        }
        var iterator = self.objectIterator();
        while (iterator.next()) |candidate| {
            if (candidate == header) return true;
        }
        return false;
    }
};

/// 9.1 统一的非原子 retain/release/dup/free 路径
pub inline fn retain(header: anytype) void {
    header.retain();
}

pub inline fn release(rt: anytype, header: anytype) void {
    comptime {
        @setEvalBranchQuota(10_000);
    }
    if (comptime @TypeOf(header.*) == StringHeader) {
        string.String.releaseFromHeader(rt, header);
        return;
    }
    if (comptime trace_stw_enabled) {
        if (refCountRemoved(header.meta().flags.kind)) return;
    }
    if (decrementHeaderRefCount(header) == 0) destroyZeroRef(rt, header);
}

const ZeroRefKindSet = enum {
    finalizing,
    deinit,
    remove_cycles,
    enqueue,
};

/// Central oracle for the deliberately unequal zero-ref kind sets. The
/// comptime selector preserves each call site's exact checks after inlining.
inline fn zeroRefKindMatches(kind: GcKind, comptime set: ZeroRefKindSet) bool {
    return switch (set) {
        .finalizing, .remove_cycles => kind == .object or kind == .var_ref or kind == .function_bytecode or kind == .realm_context or kind == .module,
        .deinit => kind == .object or kind == .var_ref or kind == .function_bytecode or kind == .shape or kind == .realm_context or kind == .module,
        .enqueue => kind == .object or kind == .function_bytecode or kind == .realm_context or kind == .module,
    };
}

/// Slow path after the caller has already decremented the common RC word to 0.
/// JSValue.free uses this after its QuickJS-style payload-4 fast path; direct
/// GC owners also arrive here through `release` above.
pub noinline fn destroyZeroRef(rt: anytype, header: *Header) align(32) void {
    std.debug.assert(headerRefCount(header) == 0);
    if (header.meta().flags.finalizing and zeroRefKindMatches(header.meta().flags.kind, .finalizing)) return;
    if (rt.gc.phase == .deinit and zeroRefKindMatches(header.meta().flags.kind, .deinit)) return;
    // During cycle removal, a child reaching rc 0 must NOT be freed here: the
    // dedicated batch loop in `destroyRuntimeCyclesWithValueRoots` frees every
    // marked-garbage object exactly once. Freeing it here (a cascade) would
    // double-free it when the batch loop reaches it, and over-release any shape
    // it shares. Pure no-op = qjs `__JS_FreeValueRT`'s `if (gc_phase !=
    // JS_GC_PHASE_REMOVE_CYCLES)` gate (quickjs.c:6476): the object remains
    // owned by the intrusive garbage/staging batch and is reclaimed exactly
    // once by that pass. This makes a reference the mark phase missed harmless
    // (leak at worst) instead of a use-after-free.
    //
    // Kind-set note: qjs gates {OBJECT, FUNCTION_BYTECODE, MODULE} (quickjs.c:6476);
    // zjs also gates realm contexts and VarRefs, and intentionally OMITS shape.
    // A garbage (dead-cycle) shape is freed exactly once by the intrusive shape
    // staging loop in destroyRuntimeCyclesWithValueRoots, and its owners skip
    // releasing it via the `headerIsCycleGarbage` guard (object.zig
    // destroyFromHeader shape-skip);
    // a live/shared shape's eager release here can never reach rc 0 during a cycle
    // round, so shape needs no gate.
    if (phaseIsTwoPassTeardown(rt.gc.phase) and zeroRefKindMatches(header.meta().flags.kind, .remove_cycles)) return;

    // Under the tracing collector the trace owns the lifetime of every kind on
    // `gc_obj_list`: `sweepUnmarked` (gc_trace_stw.zig) condemns all six
    // cycle-candidate kinds on mark + pin alone and tears each one down in a
    // safe order. A second, eager reclamation path keyed on rc is exactly what
    // let a missing root or a missing barrier stay invisible, so during normal
    // execution reaching rc 0 must mean nothing at all. Runtime teardown is
    // excluded: `.deinit` still drains the heap through here for the kinds its
    // own gate above does not claim. Strings, ropes and BigInt are NOT on
    // `gc_obj_list` -- the tracer never sees them -- so they keep refcounting
    // forever, which is why this gate is a kind test and not a blanket return.
    if (comptime trace_stw_enabled) {
        // `.realm_context` is deliberately NOT in this set. A Realm is a host
        // handle with an explicit `JSContext.destroy` API and a teardown-order
        // contract the runtime asserts (`context_head == null` in
        // JSRuntime.deinit): the host promises every Realm is gone before the
        // Runtime is. Handing Realms to the tracer breaks that promise, because
        // production collections always add the conservative stack pass and the
        // host's own now-dead `ctx` local keeps the released Realm marked --
        // observed as the `context_head` assert firing across the staging/sm
        // TypedArray directory. JSC draws the same line: cells are traced, but
        // the API-level JSGlobalContext keeps a retain count.
        const kind = header.meta().flags.kind;
        if (rt.gc.phase != .deinit and Registry.isCycleCandidate(header) and kind != .realm_context) return;
    }

    // qjs free_var_ref (quickjs.c:6164-6183) tears a dead cell down fully
    // synchronously: --ref_count -> JS_FreeValueRT(value) -> remove_gc_object
    // -> js_free_rt. __JS_FreeValueRT's zero-ref queue set is only
    // {OBJECT, FUNCTION_BYTECODE, MODULE} (quickjs.c:6471-6483) — a JSVarRef
    // never touches gc_zero_ref_count_list, so zjs enqueuing it paid a queue
    // splice + drain pop + the full destroyZeroRefNow frame per dead cell.
    // The three phase gates above stay in front, so this tail is reachable only
    // in .none/.decref; remove_cycles keeps its batch loop as the sole cycle
    // release point. Recursion is bounded: a cell's value is never itself a
    // cell (var_ref.zig setVarRefValue terminal-state assert), and an object
    // value released here still goes through the queue exactly like qjs.
    if (header.meta().flags.kind == .var_ref) {
        destroyVarRefNow(rt, header);
        return;
    }

    // QJS queues the GC kinds reachable through JSValue and lets the outermost
    // free drain them. Strings/ropes and BigInt remain immediate; Shape has its
    // own direct release path and can only add object work while a queued node
    // is being destroyed. This removes unbounded Object/FB destructor
    // recursion without adding a fallible allocation to the zero-ref path.
    if (zeroRefKindMatches(header.meta().flags.kind, .enqueue)) {
        rt.gc.enqueueZeroRef(rt, header);
        return;
    }

    destroyZeroRefNow(rt, header);
}

/// Synchronous var_ref teardown, mirroring qjs free_var_ref
/// (quickjs.c:6164-6183): unlink + accounting, then the existing destructor.
/// Never sets the queued-node mark bit — a var_ref has no weak identity
/// (runtime.zig objectFromWeakIdentity resolves objects only) and no
/// containsHeader consumer, so nothing observes the queued state qjs's
/// `js_rc(p)->mark = 1` publishes for objects.
noinline fn destroyVarRefNow(rt: anytype, header: *Header) void {
    std.debug.assert(headerRefCount(header) == 0);
    std.debug.assert(header.meta().flags.kind == .var_ref);
    // Accounting must not drift from the generic path: heapByteSizeFromHeader
    // resolves a var_ref to @sizeOf(VarRef) either via the stamped size_class
    // (addInitializedWithSize stores encodeHeapBytes(@sizeOf(VarRef)), exact
    // as long as it is below the large-class clamp) or the kind switch.
    comptime std.debug.assert(@sizeOf(var_ref.VarRef) < large_heap_size_class);
    rt.gc.unlinkObjectWithBytes(header, comptime @sizeOf(var_ref.VarRef));
    var_ref.VarRef.destroyFromHeader(rt, header);
}

/// Destruct a zero-ref node whose queue link has already been removed. Kept
/// separate from `destroyZeroRef` so releases performed by this teardown append
/// to Registry.zero_ref_* instead of entering another destructor recursively.
///
/// Mirrors qjs free_gc_object (quickjs.c:6394-6412): a frame-free small switch
/// whose hot object arm tail-jumps into free_object. `Object.destroyFromHeader`
/// (via `unregisterObjectWithBytes`) and `Registry.destroyShape` each ALREADY
/// unlink their own header and record the space-account free as the first
/// thing they do — an unlink here would only make that in-destructor unlink a
/// double no-op, yet pay a `heapByteSizeFromHeader` load per free (qjs
/// free_object/free_shape do the gc_obj_list unlink + malloc_size adjustment
/// exactly once inside the teardown, never twice). The cold kinds whose
/// destructors do NOT self-unlink (function_bytecode / realm_context / module)
/// are outlined into noinline wrappers that carry unlink + accounting + the
/// destructor call: inlining the FunctionBytecode dismantle arm
/// (FunctionLayout.init + SIMD copies) here used to cost the hot object arm a
/// 304-byte prologue before its tail jump.
fn destroyZeroRefNow(rt: anytype, header: *Header) void {
    std.debug.assert(headerRefCount(header) == 0);
    switch (header.meta().flags.kind) {
        .string => unreachable,
        .object => object.Object.destroyFromHeader(rt, header),
        .shape => rt.shapes.destroyFromHeader(header),
        .big_int => destroyBigIntZeroRef(rt, header),
        // Unreachable through the queue since var_ref frees synchronously
        // (destroyZeroRef); kept routed for direct callers' completeness.
        .var_ref => destroyVarRefNow(rt, header),
        .function_bytecode => destroyFunctionBytecodeZeroRef(rt, header),
        .realm_context => destroyRealmContextZeroRef(rt, header),
        .module => destroyModuleZeroRef(rt, header),
    }
}

/// Cold zero-ref tails. Private noinline wrappers keep the FunctionBytecode /
/// context / module dismantle bodies (and their frames) out of the hot
/// destroyZeroRefNow switch while leaving each destructor's contract — the
/// runtime-deinit sweep's phase-1 accounting/phase-2 destroy split and the
/// cycle-removal batch's own unlink+destroy pairs — untouched.
noinline fn destroyBigIntZeroRef(rt: anytype, header: *Header) void {
    // BigInt is never queued (destroyZeroRef reaches it directly) and its heap
    // bytes are stamped per allocation, so it keeps the size-from-header unlink.
    rt.gc.unlinkObjectWithBytes(header, Registry.heapByteSizeFromHeader(rt, header));
    bigint.BigInt.destroyFromHeader(rt, header);
}

noinline fn destroyFunctionBytecodeZeroRef(rt: anytype, header: *Header) void {
    const fb: *const FunctionBytecode = @fieldParentPtr("header", header);
    rt.gc.unlinkObjectWithBytes(header, fb.heapByteSize());
    function_bytecode_mod.destroyFromHeader(rt, header);
}

noinline fn destroyRealmContextZeroRef(rt: anytype, header: *Header) void {
    // comptime kind->size: identical to heapByteSizeFromHeader's resolution
    // (stamped size_class roundtrips below the large clamp; the switch arm is
    // @sizeOf either way), with the clamp condition pinned at comptime.
    comptime std.debug.assert(@sizeOf(context_mod.JSContext) < large_heap_size_class);
    rt.gc.unlinkObjectWithBytes(header, comptime @sizeOf(context_mod.JSContext));
    context_mod.JSContext.destroyFromHeader(rt, header);
}

noinline fn destroyModuleZeroRef(rt: anytype, header: *Header) void {
    comptime std.debug.assert(@sizeOf(module_mod.ModuleRecord) < large_heap_size_class);
    rt.gc.unlinkObjectWithBytes(header, comptime @sizeOf(module_mod.ModuleRecord));
    module_mod.ModuleRecord.destroyFromHeader(rt, header);
}

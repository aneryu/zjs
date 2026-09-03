//! Z-GE (Garbage Engine) Core Implementation
//! Governing Layer: third_party/zjs/src/core/gc.zig
//! Following Z-GE Architecture Contract v1.0

const std = @import("std");
pub const representation = @import("gc_representation_constants.zig");
const builtin = @import("builtin");
const build_options = @import("build_options");
const memory = @import("memory.zig");
const carrier = @import("gc_carrier.zig");
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

/// The stop-the-world reclaiming tracer in `gc_trace_stw.zig` is the only
/// collector, so this is a comptime `true`. The name survives because
/// `if (comptime gc.trace_stw_enabled)` gates outside this file still read
/// it (the derived `generation_enabled` / `concurrent_enabled` /
/// `block_heap_enabled` / `address_registry_enabled` constants below are all
/// aliases of it); the dead `else` arms inside gc.zig were removed in TGC S0
/// and the cross-file gates go with S5.
pub const trace_stw_enabled: bool = true;

/// R3 roots diagnosis (`-Dzjs_gc_roots_diag=true`, docs/tracing-gc-s0-spec.md
/// §L4): production links scalar `ValueRootFrame`s, the verify probe records
/// every object only a conservative word kept alive, and the L3 store probe
/// is armed regardless of optimize mode. Off in every shipped artifact.
pub const roots_diag_enabled: bool = build_options.zjs_gc_roots_diag;

/// Live page-radix address registry for conservative candidate validation.
pub const address_registry_enabled: bool = trace_stw_enabled or builtin.is_test;

/// Publication-size histogram and measured size-class table (§4.2 / §4.3).
/// Same compile gate as the address registry.
pub const space_model_enabled: bool = address_registry_enabled;

/// 64 KiB block heap.
pub const block_heap_enabled: bool = trace_stw_enabled;

const BlockHeapMod = @import("gc_block_heap.zig");
const gc_space = @import("gc_space.zig");

const AddressRegistryTable = if (address_registry_enabled)
    @import("gc_address_registry.zig").Table
else
    void;

const SpaceHistogram = if (space_model_enabled)
    @import("gc_space.zig").Histogram
else
    void;

pub const generation_enabled: bool = trace_stw_enabled;
pub const AllocationHandle = carrier.AllocationHandle;
pub const CurrentMembershipKey = carrier.CurrentMembershipKey;
pub const CarrierStateMask = carrier.StateMask;
pub const CarrierLifecycleState = carrier.LifecycleState;
pub const CarrierResolveError = carrier.ResolveError;
pub const block_generation_enabled = carrier.block_generation_enabled;
pub const extent_identity_enabled = carrier.extent_identity_enabled;
pub const lifecycle_state_enabled = carrier.lifecycle_state_enabled;
pub const block_tracking_enabled = carrier.block_tracking_enabled;
pub const extent_tracking_enabled = carrier.extent_tracking_enabled;
pub const ResolvedExact = union(enum) {
    tracing: *Header,
};
pub const ResolvedCurrentMember = union(enum) {
    tracing: *Header,
};

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

/// `ZJS_MINOR_AUDIT=1`: after the minor picks its condemned set, report any
/// live object still holding an edge into it. Parsed once here rather than
/// read at the check, because the minor path is exactly where a `getenv` per
/// collection is the probe that hides the bug -- regexp performs 794 minors in
/// a two-second script.
pub var minor_audit: bool = false;
/// `ZJS_MINOR_AUDIT=fatal`: the audit above panics on its first hit instead
/// of only printing, so a gate that runs the suite under it turns red.
pub var minor_audit_fatal: bool = false;
/// `ZJS_GC_VERIFY_MINOR=fatal`: a PRECISE condemned-but-reachable violation
/// panics. Conservative-only violations stay a report: the verifier's probe
/// runs on a deeper native frame than the minor it checks, so register and
/// stack residue differ between the two scans by construction.
pub var verify_minor_fatal: bool = false;

/// TGC S0 L3: sites of stores that static reading found unbarriered. The
/// probe below counts, per site, the state the generational barrier exists
/// to prevent -- an old, unremembered, published owner gaining a young child.
pub const UnbarrieredStoreSite = enum(u8) {
    set_property_data_overwrite,
    dense_array_in_capacity_append,
    global_lexical_cell_replace,
};
pub var unbarriered_store_hits: [3]usize = .{ 0, 0, 0 };

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

/// `ZJS_GC_VERIFY_MAJOR_ALL=1` (roots-diag builds): re-derive reachability
/// from freshly cleared marks at every incremental finish and reject any
/// object the fresh precise roots reach but the cycle is about to condemn.
pub var verify_major_all: bool = false;

/// `ZJS_GC_M_CUT_INJECT=N`: terminal Object-layout deletion mutants.
/// 1 borrows the still-live scalar word for the parked successor; 2 sends a
/// slots2 Object through its absent resident payload arm; 3 skips removal of
/// its sparse payload entry at destruction; 4 applies the historical uniform-
/// header body offset to Object. Test binaries only.
pub var m_cut_inject: u8 = 0;

pub inline fn mCutInjection(comptime mutation: u8) bool {
    if (comptime !builtin.is_test) return false;
    return m_cut_inject == mutation;
}

/// Read once at `Registry.init`. "0" or empty disables; "1" enables at the
/// default cadence; any other integer enables at that cadence.
fn readStressFromEnv() void {
    if (std.c.getenv("ZJS_MINOR_AUDIT")) |raw| {
        const text = std.mem.span(raw);
        minor_audit = text.len != 0 and !std.mem.eql(u8, text, "0");
        minor_audit_fatal = std.mem.eql(u8, text, "fatal");
    }
    if (std.c.getenv("ZJS_GC_ARENA_AUDIT")) |raw| {
        const text = std.mem.span(raw);
        arena_audit = text.len != 0 and !std.mem.eql(u8, text, "0");
    }
    if (std.c.getenv("ZJS_GC_VERIFY_MINOR")) |raw| {
        const text = std.mem.span(raw);
        verify_minor = text.len != 0 and !std.mem.eql(u8, text, "0");
        verify_minor_fatal = std.mem.eql(u8, text, "fatal");
    }
    if (comptime roots_diag_enabled) {
        if (std.c.getenv("ZJS_GC_VERIFY_MAJOR_ALL")) |raw| {
            const text = std.mem.span(raw);
            verify_major_all = text.len != 0 and !std.mem.eql(u8, text, "0");
        }
    }
    if (comptime builtin.is_test) {
        if (std.c.getenv("ZJS_GC_M_CUT_INJECT")) |raw| {
            m_cut_inject = std.fmt.parseInt(u8, std.mem.span(raw), 10) catch 0;
        }
    }
    const raw = std.c.getenv("ZJS_GC_STRESS") orelse return;
    const text = std.mem.span(raw);
    if (text.len == 0 or std.mem.eql(u8, text, "0")) return;
    stress_collect = true;
    const parsed = std.fmt.parseInt(i32, text, 10) catch return;
    if (parsed > 1) stress_cadence = parsed;
}

/// Concurrent-major barrier and safepoint handshake (§8.4). Present wherever
/// a tracer is compiled; the marker thread that uses it arrives separately.
pub const concurrent_enabled: bool = trace_stw_enabled;
pub const concurrent = @import("gc_concurrent.zig");
/// Unbounded segmented private/shared mark frontier (§8.4).
pub const mark_queue = @import("gc_mark_queue.zig");

/// `detailed_reports` and the stats sinks live with the collector; the
/// barrier only reads them. Mutual import with `gc_trace_stw.zig` is fine --
/// Zig resolves lazily.
const gc_trace_stw_reports = @import("gc_trace_stw.zig");
const conservative_mod = @import("gc_conservative.zig");
pub const generation = @import("gc_generation.zig");
const ConcurrentState = concurrent.State;

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

/// Mutator allocation required before an open incremental major receives its
/// next bounded assist at an object-allocation boundary.
///
/// The time budget bounds ONE slice, but object-heavy JavaScript can cross
/// thousands of allocation boundaries inside one observable operation. Giving
/// every boundary another slice merely concatenates a whole major cycle into
/// that operation (Splay observed ~46 one-millisecond slices in one sample).
/// Pace those assists by allocation debt instead: 512 KiB is below the major
/// headroom floor and still buys enough assists for the collector to finish
/// before the ordinary 2x growth threshold is exhausted. Explicit scheduler,
/// callback, idle, and urgent polls remain unpaced.
pub const incremental_assist_interval_bytes: usize = 512 * 1024;

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

/// Independent byte oracle for tests and explicit ownership-audit builds.
///
/// The public counters are a cold ownership census. An audit cannot use that
/// same census as its expected value: losing the only owner link would hide a
/// still-accounted allocation from both sides. This shadow follows lifecycle
/// publication/free events instead, and is entirely absent from shipped
/// ReleaseFast builds.
pub const heap_accounting_oracle_enabled: bool = carrier.audit_oracle_enabled;

const HeapAccountingOracle = if (heap_accounting_oracle_enabled)
    carrier.HeapAccountingOracle
else
    void;

const BlockHeap = if (block_heap_enabled)
    @import("gc_block_heap.zig").Heap
else
    void;

pub const Policy = struct {
    large_object_threshold: usize = 8 * KB,

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

/// 6.2 GcKind definition
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
/// allocator/GC prefix immediately before the carrier header;
/// `.string_rc` was the four-byte refcount-only prefix used by flat strings and
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
    .{ .kind = .string, .census = if (string_tracer_owned) .rc_registry else .allocation_ledger, .strong_edges = .string_family, .cycle_candidate = string_tracer_owned },
    .{ .kind = .big_int, .census = .rc_registry, .strong_edges = .leaf, .cycle_candidate = true },
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
    .{ .kind = .realm_context, .prefix = .metadata, .allocation = .slab_or_standalone, .ref_count = .trace_removed },
    .{ .kind = .module, .prefix = .metadata, .allocation = .slab_or_standalone, .ref_count = .trace_removed },
    .{ .kind = .shape, .prefix = .metadata, .allocation = .slab_or_standalone, .ref_count = .trace_removed },
    .{ .kind = .string, .prefix = .metadata, .allocation = if (string_tracer_owned) .block_slab_or_standalone else .string_family, .ref_count = if (string_tracer_owned) .trace_removed else .retained },
    .{ .kind = .big_int, .prefix = .metadata, .allocation = .slab_or_standalone, .ref_count = .trace_removed },
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
        // Since S2-a1 every kind carries the eight-byte Metadata prefix; the
        // string family still keeps its count in the prefix's lifetime word.
        std.debug.assert(descriptor.prefix == .metadata);
        std.debug.assert((descriptor.allocation == .block_slab_or_standalone) ==
            (descriptor.kind == .object or (string_tracer_owned and descriptor.kind == .string)));
        std.debug.assert((descriptor.allocation == .string_family) == (descriptor.kind == .string and !string_tracer_owned));
        std.debug.assert((descriptor.ref_count == .trace_removed) == refCountRemoved(descriptor.kind));
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
/// TGC S2 liveness switch for the string family (flat strings, ropes, symbol
/// bodies). false: strings are refcounted raw-slab allocations the tracer
/// never sees (S2-a1 state). true: strings are block cells / extents that the
/// tracer marks and sweeps, and their count is dead. Every S2 change lands
/// behind this constant so both builds gate until the flip (S2 spec §5.0).
pub const string_tracer_owned: bool = false;

pub inline fn refCountRemoved(kind: GcKind) bool {
    return switch (kind) {
        .object, .function_bytecode, .var_ref, .module, .shape, .realm_context, .big_int => true,
        .string => string_tracer_owned,
    };
}

/// O2-B's marking-epoch exemption. Only kinds whose lifetime is owned by the
/// tracer AND whose struct never moves under the mutator may persist as raw
/// pointers in a private or shared mark frontier. Shape is tracer-owned (no
/// refcount) but `relocateShape` frees and re-creates the struct on inline
/// FAM growth, so a queued raw pointer could dangle; it is shaded
/// synchronously instead (`Collector.shade` non-frontier branch). Realm is
/// tracer-owned too and keeps the synchronous route for now (its edges are
/// few; S1-b left the queue admission for a later measurement).
/// Keep this separate from enum ranges: Realm sits between VarRef and Module.
pub inline fn frontierEpochSafe(kind: GcKind) bool {
    return switch (kind) {
        .object, .function_bytecode, .var_ref, .module, .big_int => true,
        .string => string_tracer_owned,
        .realm_context, .shape => false,
    };
}

comptime {
    for (std.meta.tags(GcKind)) |kind| {
        const expected = switch (kind) {
            .object, .function_bytecode, .var_ref, .module, .big_int => true,
            .string => string_tracer_owned,
            .realm_context, .shape => false,
        };
        std.debug.assert(frontierEpochSafe(kind) == expected);
        // A raw frontier pointer requires tracer-owned lifetime; the converse
        // does not hold (Shape relocates). If either catalog changes, O2 must
        // be reopened here.
        if (frontierEpochSafe(kind)) std.debug.assert(refCountRemoved(kind));
    }
}
pub const Phase = enum {
    none,
    /// A batch of zero-ref releases is being held for an outermost drain.
    decref,
    /// The tracer is running a destruction slice. It used to share this role
    /// with refcounting's `.remove_cycles`, and a single value forced every
    /// site to serve both -- visibly so in `Object.destroyFromHeader`, whose
    /// fast arm excluded `.remove_cycles` for reasons belonging to rc's
    /// collector, which meant the tracing build never once used its own fast
    /// teardown. `.remove_cycles` retired with that collector.
    tracer_destroy,
    deinit,
};

/// The teardown window where resources are freed in one pass and structs in
/// another, so a struct free must be parked. There used to be two such
/// windows; the refcounting one is gone, and this predicate survives as the
/// name its call sites read.
pub inline fn phaseIsTwoPassTeardown(phase: Phase) bool {
    return phase == .tracer_destroy;
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
    /// Alloc-time large-space classification, stamped by registration and
    /// valid iff `heap_accounted`. Cold accounting audits compare it with the
    /// live object's current byte size; it is independent of whether the
    /// physical carrier is a slab, block cell, or standalone.
    large: bool = false,
    /// The allocation has been published to the live heap. Kept separate from
    /// size_class because slab-overlaid metadata reserves that field.
    heap_accounted: bool = false,
    /// The metadata is a dedicated prefix ahead of the object (slab-ineligible
    /// or over-aligned allocation); `size_class` then holds encoded heap bytes.
    /// When false the metadata occupies the small-object slab's allocator
    /// header and `size_class` is the allocator's block index.
    standalone: bool = false,
};

pub const MarkStack = mark_queue.MarkStack;

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
    return kind != .string or string_tracer_owned;
}

comptime {
    // The test above must stay the enumeration of the admitted kinds.
    for (std.meta.tags(GcKind)) |kind| {
        const expected = switch (kind) {
            .object, .function_bytecode, .var_ref, .realm_context, .module, .shape, .big_int => true,
            .string => string_tracer_owned,
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

/// Physical offset 4 is kind dependent. Registry carriers use `trace`; heap
/// BigInt keeps `rc`, because it is outside the tracing heap and the generic
/// JSValue retain/free ABI still reaches this exact payload-4 word. `rc` is
/// therefore NOT dead with the refcounting collector gone: `.big_int` is its
/// one remaining user and the union arm exists for it.
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
    lifetime: LifetimeWord = .{ .trace = .{} },
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
    std.debug.assert(@as(u8, @bitCast(BlockFlags{ .kind = .object, .young = true })) == representation.metadata_young_mask);
    std.debug.assert(@as(u8, @bitCast(BlockFlags{ .kind = .object, .finalizing = true })) == 1 << 5);
    std.debug.assert(@as(u8, @bitCast(BlockFlags{ .kind = .object, .is_pinned = true })) == 1 << 6);
    std.debug.assert(@as(u8, @bitCast(BlockFlags{ .kind = .object, .cycle_visited = true })) == 1 << 7);
    // The contiguous kind ranges documented on RefKind.
    std.debug.assert(@intFromEnum(GcKind.object) == 0);
    std.debug.assert(@intFromEnum(GcKind.module) == 4 and @intFromEnum(GcKind.shape) == 5);
    std.debug.assert(@intFromEnum(GcKind.string) == 6 and @intFromEnum(GcKind.big_int) == 7);
}

/// The two owner facts that let a generational write barrier do nothing, as
/// bit positions inside the eight-byte `Metadata` prefix read as one word.
///
///   * `flags.young` (byte 3): a minor traces the whole reachable young set,
///     so an old-to-young edge out of a young owner needs no record.
///   * `lifetime.trace.object_shape_summary` bit7 (byte 6): the remembered-set
///     membership cache of audit §10. Set implies present in the map (the
///     direction `verifyPublishedHeaderRepresentation`'s
///     `RememberedCacheWithoutOwner` enforces at every collection boundary),
///     and a remembered owner is re-traced by the minor in full -- so this
///     edge, whatever its target, is already covered.
///
/// Both live in ONE eight-byte, eight-aligned prefix, which is what makes the
/// JSC-shaped fast path possible: `load` the owner's state word, `and` it with
/// a phase-owned gate, branch. JSC packs generation and colour into one
/// `cellState` byte and compares against `m_barrierThreshold`
/// (AssemblyHelpers.h:1438-1445, Heap.cpp:3382-3386); zjs's two facts are not
/// adjacent bits, so the "threshold" is a mask instead of a magnitude -- the
/// same one ALU op and one branch.
///
/// The constant is produced by a comptime probe rather than hand-computed
/// shifts: that makes it endian-agnostic AND makes a future field move a
/// compile error in `barrierSkipBitsAreExactlyTheTwoFacts` below instead of a
/// silently wrong mask.
pub const barrier_young_bit: u64 = blk: {
    var probe: Metadata = .{};
    probe.flags.young = true;
    break :blk @bitCast(probe);
};

pub const barrier_remembered_bit: u64 = blk: {
    var probe: Metadata = .{};
    probe.lifetime.trace.object_shape_summary = trace_remembered_mask;
    break :blk @bitCast(probe);
};

pub const barrier_skip_bits: u64 = barrier_young_bit | barrier_remembered_bit;

comptime {
    // barrierSkipBitsAreExactlyTheTwoFacts. A bit that MOVES is fine by
    // construction -- the probe follows it -- so what these catch is the rest:
    // a fact that stops being a single bit, the two facts colliding, and any
    // prefix default that would make a brand-new header skip its barriers.
    // (Verified by injection: defaulting `BlockFlags.young` to true trips the
    // second assert, because the remembered probe then carries two bits.)
    std.debug.assert(@popCount(barrier_young_bit) == 1);
    std.debug.assert(@popCount(barrier_remembered_bit) == 1);
    std.debug.assert(barrier_young_bit != barrier_remembered_bit);
    // A zero prefix must read as "the barrier has work to do": an unpublished
    // header is old and unremembered, which is what the pre-fold code
    // classified it as too (audit §10.6).
    std.debug.assert(@as(u64, @bitCast(Metadata{})) & barrier_skip_bits == 0);
}

/// The owner state word of the fast path. One aligned eight-byte load of the
/// prefix the caller is about to write through anyway.
pub inline fn barrierOwnerWord(header: *const Header) u64 {
    return @bitCast(header.metaConst().*);
}

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
    /// Intrusive successor for non-Object tracing kinds. Object headers are
    /// body pointers in terminal layout M, so their first word is the scalar
    /// word and must never be interpreted as linkage.
    next_non_object: ?*TraceHeader = null,

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

    /// Kind-gated successor access for real list members. Sentinel-only list
    /// code uses the storage field directly because sentinels have no Metadata.
    pub inline fn nextNonObject(self: *const TraceHeader) ?*TraceHeader {
        if (comptime std.debug.runtime_safety)
            std.debug.assert(self.metaConst().flags.kind != .object);
        return self.next_non_object;
    }

    pub inline fn setNextNonObject(self: *TraceHeader, next: ?*TraceHeader) void {
        if (comptime std.debug.runtime_safety)
            std.debug.assert(self.metaConst().flags.kind != .object);
        self.next_non_object = next;
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
/// in quickjs.h). Strings and heap BigInt use it. GC carriers reinterpret the
/// same physical word as `TraceHeaderState`, and every raw JSValue
/// retain/release is gated before it.
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

/// Byte size of the prefix reserved ahead of every flat `String` and
/// `StringRope` allocation: a full `Metadata` word (S2-a1). Its `lifetime`
/// tail is the refcount word at payload-4 that `StringHeader` names, so the
/// string family's rc arithmetic is unchanged while the carrier now has the
/// same eight-byte prefix as every GC kind (kind = `.string`, no list link).
pub const string_prefix_size: usize = metadata_prefix_size;

/// Physical payload displacement of the four-byte lifetime word. It is an RC
/// word only for the kinds/configurations documented on `LifetimeWord`.
pub const ref_count_offset_from_payload: usize = @sizeOf(RefCountHeader);

pub inline fn refCountHeaderFromPayload(payload: *anyopaque) *RefCountHeader {
    const address = @intFromPtr(payload);
    std.debug.assert(address >= ref_count_offset_from_payload);
    return @ptrFromInt(address - ref_count_offset_from_payload);
}

comptime {
    // A GC value stores `Header *` in its payload. Metadata immediately
    // precedes that header, and its lifetime tail must land at the same
    // payload - 4 address used by strings, symbols, and ropes.
    std.debug.assert(metadata_prefix_size - @offsetOf(Metadata, "lifetime") == ref_count_offset_from_payload);
}

pub const Header = TraceHeader;
pub const GCObjectHeader = Header;
pub const ObjectHeader = Header;

/// Physical displacement from the unified GC handle to the kind's body. M
/// makes Object's handle equal its body pointer; every other Metadata-backed
/// kind retains the eight-byte TraceHeader word ahead of its body.
pub inline fn bodyOffsetFromHeader(comptime kind: GcKind) usize {
    return switch (kind) {
        .object => 0,
        .function_bytecode, .var_ref, .realm_context, .module, .shape, .string, .big_int => @sizeOf(TraceHeader),
    };
}

/// Typed header-to-body arithmetic. Object's zero displacement is asserted at
/// the only conversion boundary it owns; mutation 4 proves a reintroduced
/// uniform eight-byte offset stops here before a body field is dereferenced.
pub inline fn bodyAddressFromHeader(comptime kind: GcKind, header: *const GCObjectHeader) usize {
    const offset = if (mCutInjection(4) and kind == .object)
        @sizeOf(TraceHeader)
    else
        bodyOffsetFromHeader(kind);
    if (comptime std.debug.runtime_safety) {
        if (kind == .object and offset != 0)
            @panic("gc: M-CUT BODY OFFSET: Object handle must equal body start");
    }
    return @intFromPtr(header) + offset;
}

comptime {
    std.debug.assert(bodyOffsetFromHeader(.object) == 0);
    for (.{ GcKind.function_bytecode, .var_ref, .realm_context, .module, .shape, .string, .big_int }) |kind|
        std.debug.assert(bodyOffsetFromHeader(kind) == 8);
}

/// Parked Object corpses keep their scalar word readable through Pass B, so
/// their temporary successor occupies the already-dead Shape word at body+8.
/// Non-Object corpses retain the ordinary TraceHeader successor.
pub const object_deferred_link_body_offset: usize = 8;

inline fn deferredLinkSlot(header: *GCObjectHeader) *?*GCObjectHeader {
    if (header.metaConst().flags.kind == .object)
        return @ptrFromInt(@intFromPtr(header) + if (mCutInjection(1)) 0 else object_deferred_link_body_offset);
    return &header.next_non_object;
}

pub inline fn deferredNext(header: *const GCObjectHeader) ?*GCObjectHeader {
    return deferredLinkSlot(@constCast(header)).*;
}

/// Deferred successor when the caller has already proven `kind`; skips the
/// per-corpse kind reload of `deferredLinkSlot` on the drain hot loops.
pub inline fn deferredNextForKind(header: *const GCObjectHeader, kind: GcKind) ?*GCObjectHeader {
    if (kind == .object) {
        const slot: *?*GCObjectHeader = @ptrFromInt(@intFromPtr(header) + if (mCutInjection(1)) 0 else object_deferred_link_body_offset);
        return slot.*;
    }
    return header.next_non_object;
}

pub inline fn setDeferredNext(header: *GCObjectHeader, next: ?*GCObjectHeader) void {
    deferredLinkSlot(header).* = next;
}

/// An O2-B frontier entry. Its representation stays one raw address, but the
/// distinct type makes every private/shared enqueue prove the publication,
/// header-agreement, lifetime-kind, and mark-claim preconditions first.
///
/// The constructor is deliberately module-private. Queue code can unwrap an
/// entry it received, but it cannot manufacture one from `*Header`.
pub const FrontierSafeHeader = enum(usize) {
    _,

    inline fn init(raw_header: *Header) FrontierSafeHeader {
        return @enumFromInt(@intFromPtr(raw_header));
    }

    pub inline fn header(self: FrontierSafeHeader) *Header {
        return @ptrFromInt(@intFromEnum(self));
    }
};

comptime {
    std.debug.assert(@sizeOf(FrontierSafeHeader) == @sizeOf(*Header));
    std.debug.assert(@alignOf(FrontierSafeHeader) == @alignOf(*Header));
}

/// The authoritative count for kinds which retain RC semantics in this build.
/// Under trace_stw Shape and Realm moved their real count into existing body
/// padding; BigInt remains in the prefix because JSValue's payload-4 ABI owns
/// it. Calling this for a tracer-owned kind is a contract violation.
pub inline fn headerRefCount(h: *const Header) i32 {
    // No list kind keeps a count any more (S1-c closed the BigInt tail);
    // every caller is behind a `refCountRemoved` gate that is now always true.
    _ = h;
    unreachable;
}

pub inline fn setHeaderRefCount(h: *Header, value: i32) void {
    std.debug.assert(value >= 0);
    _ = h;
    unreachable;
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
    return h.metaConst().lifetime.trace.flags.husk;
}

/// True when dropping the last WeakRef may reclaim the resource-stripped
/// object struct. There is an explicit state bit for it, and tracer-owned
/// objects never go through the zero-ref queue.
pub inline fn headerIsReclaimableWeakHusk(h: *const Header) bool {
    std.debug.assert(h.metaConst().flags.kind == .object);
    return h.metaConst().lifetime.trace.flags.husk;
}

pub inline fn setHeaderWeakHusk(h: *Header) void {
    std.debug.assert(h.metaConst().flags.kind == .object);
    {
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
    }
}

inline fn resetHeaderLifetimeForPublication(h: *Header) void {
    h.meta().lifetime.trace = .{};
}

inline fn assertInitialHeaderLifetime(h: *const Header) void {
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
}

/// Shape and Realm retain true refcount semantics, so a mutator last-release
/// may unlink them at an arbitrary list position. They store the one backlink
/// the compact Header removed, in body space made available by that same
/// shrink. Tracer-owned kinds are only detached by collector cursor walks and
/// intentionally carry no backlink.
inline fn storedListPrevious(h: *const Header) ?*Header {
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

/// Intrusive-list authority: the compact non-Object successor plus this per-list
/// tail. The extra word is paid once per list, never once per object. (The
/// QuickJS doubly-linked node it replaced went with the rc collector.)
pub const IntrusiveHeaderList = struct {
    sentinel: Header = .{},
    /// Empty lists point at their own sentinel. This keeps append/delete in
    /// the same branch-free shape as the old intrusive sentinel: the tail link
    /// is always writable, including for the first element.
    tail: ?*Header = null,
};

pub inline fn listInit(head: *IntrusiveHeaderList) void {
    head.sentinel.next_non_object = &head.sentinel;
    head.tail = &head.sentinel;
}

pub inline fn listEmpty(head: *const IntrusiveHeaderList) bool {
    return head.sentinel.next_non_object == @constCast(&head.sentinel);
}

pub inline fn listAddTail(head: *IntrusiveHeaderList, el: *Header) void {
    std.debug.assert(el.metaConst().flags.kind != .object);
    std.debug.assert(el.next_non_object == null);
    const previous = head.tail.?;
    el.next_non_object = &head.sentinel;
    previous.next_non_object = el;
    head.tail = el;
    setStoredListPrevious(el, previous);
}

/// Append to a collector-private list whose every removal is performed by a
/// forward traversal already carrying the predecessor. Such lists never need
/// Shape/Realm's arbitrary-unlink backlink, so do not pay the kind dispatch
/// that maintains it on the allocation-ordered `gc_obj_list`.
pub inline fn listAddTailTraversalOwned(head: *IntrusiveHeaderList, el: *Header) void {
    std.debug.assert(el.metaConst().flags.kind != .object);
    std.debug.assert(el.next_non_object == null);
    const previous = head.tail.?;
    el.next_non_object = &head.sentinel;
    previous.next_non_object = el;
    head.tail = el;
}

/// Return the predecessor of `el` in `head`. Callers that do not already hold
/// a traversal cursor pay one cold forward scan, except for the two kinds that
/// keep an accelerator backlink in their body.
pub inline fn listPrevious(head: *IntrusiveHeaderList, el: *Header) *Header {
    switch (el.metaConst().flags.kind) {
        .shape, .realm_context => {
            const previous = storedListPrevious(el) orelse unreachable;
            std.debug.assert(previous.next_non_object == el);
            return previous;
        },
        else => {},
    }
    var previous: *Header = &head.sentinel;
    while (previous.next_non_object != el) {
        previous = previous.next_non_object.?;
        std.debug.assert(previous != &head.sentinel);
    }
    return previous;
}

/// Delete `el` when its predecessor is already known by the caller's forward
/// traversal. This is the normal compact-trace sweep primitive: one pointer
/// splice, never a search per corpse.
pub inline fn listDelAfter(head: *IntrusiveHeaderList, previous: *Header, el: *Header) void {
    std.debug.assert(el.metaConst().flags.kind != .object);
    std.debug.assert(previous.next_non_object == el);
    const next = el.next_non_object.?;
    previous.next_non_object = next;
    if (next != &head.sentinel) setStoredListPrevious(next, previous);
    head.tail = if (head.tail == el) previous else head.tail;
    // Linkage is already authoritatively cleared by `next = null` below.
    // ReleaseFast does not pay a second kind dispatch merely to scrub the
    // Shape/Realm acceleration slot of an object that is either destroyed
    // or immediately re-linked (which overwrites it). Keep the scrub in
    // safety builds so stale-backlink misuse still fails close to origin.
    if (std.debug.runtime_safety) setStoredListPrevious(el, null);
    el.next_non_object = null;
}

/// Traversal-owned counterpart to `listDelAfter`. The caller promises this is
/// not `gc_obj_list`: no mutator can arbitrarily unlink Shape/Realm nodes from
/// it, so successor backlinks are deliberately absent and need no repair.
pub inline fn listDelAfterTraversalOwned(head: *IntrusiveHeaderList, previous: *Header, el: *Header) void {
    std.debug.assert(el.metaConst().flags.kind != .object);
    std.debug.assert(previous.next_non_object == el);
    previous.next_non_object = el.next_non_object.?;
    head.tail = if (head.tail == el) previous else head.tail;
    el.next_non_object = null;
}

/// qjs `list_del` (list.h:69-78 / remove_gc_object at quickjs.c:6548).
/// Arbitrary mutations recover the predecessor once. Sequential collector
/// walks must use `listDelAfter` so a sweep remains O(population).
pub inline fn listDel(head: *IntrusiveHeaderList, el: *Header) void {
    listDelAfter(head, listPrevious(head, el), el);
}

pub inline fn listFirst(head: *const IntrusiveHeaderList) ?*Header {
    const next = head.sentinel.next_non_object.?;
    if (next == @constCast(&head.sentinel)) return null;
    return next;
}

pub inline fn headerLinked(header: *const Header) bool {
    return header.nextNonObject() != null;
}

fn verifyCircularHeaderList(
    head: *IntrusiveHeaderList,
    expected_kind: ?GcKind,
    comptime verify_stored_previous: bool,
) InvariantError!usize {
    const sentinel = &head.sentinel;
    if (sentinel.next_non_object == null) return error.CorruptGcList;
    if (listEmpty(head)) {
        if (head.tail != sentinel) return error.CorruptGcList;
        return 0;
    }

    var tortoise = sentinel.next_non_object.?;
    var hare = sentinel.next_non_object.?;
    while (hare != sentinel) {
        hare = hare.nextNonObject() orelse return error.CorruptGcList;
        if (hare == sentinel) break;
        hare = hare.nextNonObject() orelse return error.CorruptGcList;
        tortoise = tortoise.nextNonObject() orelse return error.CorruptGcList;
        if (hare != sentinel and tortoise == hare) return error.CorruptGcList;
    }

    var count: usize = 0;
    var previous: *GCObjectHeader = sentinel;
    var current = sentinel.next_non_object;
    while (current) |node| {
        if (node == sentinel) break;
        if (expected_kind) |kind| {
            if (node.metaConst().flags.kind != kind) return error.DoomedBucketKindMismatch;
        }
        if (comptime verify_stored_previous) {
            switch (node.metaConst().flags.kind) {
                .shape, .realm_context => if (storedListPrevious(node) != previous)
                    return error.CorruptGcList,
                else => {},
            }
        }
        const next = node.nextNonObject() orelse return error.CorruptGcList;
        previous = node;
        current = next;
        count += 1;
    }
    if (previous.next_non_object != sentinel or head.tail != previous) return error.CorruptGcList;
    return count;
}

/// Allocation-free temporary intrusive list for cycle partitioning and
/// Pass-B struct deferral. Non-Object kinds reuse their TraceHeader successor;
/// Object uses the dead Shape word so its scalar word remains readable until
/// the Pass-B weak-husk/class/free decision.
pub const DeferredFreeStack = struct {
    head: ?*GCObjectHeader = null,
    count: usize = 0,

    pub fn push(self: *DeferredFreeStack, header: *GCObjectHeader) void {
        const object_scalar_before: u64 = if (comptime builtin.is_test)
            (if (header.metaConst().flags.kind == .object)
                @as(*const u64, @ptrCast(@alignCast(header))).*
            else
                0)
        else
            0;
        setDeferredNext(header, self.head);
        if (mCutInjection(1) and header.metaConst().flags.kind == .object and
            @as(*const u64, @ptrCast(@alignCast(header))).* != object_scalar_before)
        {
            @panic("gc: M-CUT PARKED LINK: Object scalar word was used as successor");
        }
        self.head = header;
        self.count += 1;
    }

    pub fn pop(self: *DeferredFreeStack) ?*GCObjectHeader {
        const header = self.head orelse return null;
        self.head = deferredNext(header);
        setDeferredNext(header, null);
        self.count -= 1;
        return header;
    }
};

/// Large enough for ordinary Shape/Realm release cascades without making
/// every outermost zero transition reserve a 512-byte frame. Deeper cascades
/// use the scratch allocator arm below and are pinned by the overflow test.
pub const zero_ref_inline_capacity: usize = 8;

/// One-call anti-recursion worklist for Shape/Realm eager-zero teardown.
/// Nodes remain published while queued here, so the canonical header word is
/// never borrowed. Overflow storage is returned before the outermost release
/// completes.
pub const ZeroRefScratch = struct {
    inline_items: [zero_ref_inline_capacity]*GCObjectHeader = undefined,
    inline_len: usize = 0,
    overflow: std.ArrayListUnmanaged(*GCObjectHeader) = .empty,
    read_index: usize = 0,

    fn deinit(self: *ZeroRefScratch) void {
        self.overflow.deinit(std.heap.page_allocator);
        self.* = .{};
    }

    fn append(self: *ZeroRefScratch, header: *GCObjectHeader) void {
        if (self.inline_len < self.inline_items.len) {
            self.inline_items[self.inline_len] = header;
            self.inline_len += 1;
            return;
        }
        self.overflow.append(std.heap.page_allocator, header) catch
            @panic("gc: zero-ref scratch worklist OOM");
    }

    fn next(self: *ZeroRefScratch) ?*GCObjectHeader {
        const total = self.inline_len + self.overflow.items.len;
        if (self.read_index >= total) return null;
        const index = self.read_index;
        self.read_index += 1;
        if (index < self.inline_len) return self.inline_items[index];
        return self.overflow.items[index - self.inline_len];
    }
};


/// Header-external membership authority for published `.object` allocations
/// that are not served by the block heap. Block objects are enumerated by the
/// block allocation bitmap; every other traced kind remains on `gc_obj_list`.
///
/// This intentionally stores only pointers. Object publication reserves one
/// slot before exposing a non-block allocation, so committing membership is a
/// no-fail append and no object/header byte is consumed. Removal is unordered:
/// collection is the only mutator, and none of the consumers assign semantic
/// meaning to allocation order.
const NonBlockObjectAuthority = struct {
    items: std.ArrayListUnmanaged(*GCObjectHeader) = .empty,
    /// Header-external condemnation lanes. Object's body remains entirely
    /// semantic until its destructor strips resources, so neither live scalar
    /// nor Shape words may be borrowed by the major morgue or STW worklist.
    doomed: std.ArrayListUnmanaged(*GCObjectHeader) = .empty,
    temporary: std.ArrayListUnmanaged(*GCObjectHeader) = .empty,

    fn prepare(self: *NonBlockObjectAuthority, allocator: std.mem.Allocator) !void {
        try self.items.ensureUnusedCapacity(allocator, 1);
        const total_population = self.items.items.len + self.doomed.items.len + self.temporary.items.len + 1;
        try self.doomed.ensureTotalCapacity(allocator, total_population);
        try self.temporary.ensureTotalCapacity(allocator, total_population);
    }

    fn publish(self: *NonBlockObjectAuthority, header: *GCObjectHeader) void {
        std.debug.assert(header.metaConst().flags.kind == .object);
        std.debug.assert(!Registry.isBlockCellHeader(header));
        self.items.appendAssumeCapacity(header);
    }

    fn indexOf(self: *const NonBlockObjectAuthority, header: *const GCObjectHeader) ?usize {
        for (self.items.items, 0..) |candidate, index| {
            if (candidate == header) return index;
        }
        return null;
    }

    fn remove(self: *NonBlockObjectAuthority, header: *const GCObjectHeader) bool {
        const index = self.indexOf(header) orelse return false;
        _ = self.items.swapRemove(index);
        return true;
    }

    fn condemn(self: *NonBlockObjectAuthority, header: *GCObjectHeader, temporary: bool) void {
        const index = self.indexOf(header) orelse unreachable;
        _ = self.items.swapRemove(index);
        if (temporary)
            self.temporary.appendAssumeCapacity(header)
        else
            self.doomed.appendAssumeCapacity(header);
    }

    fn popDoomed(self: *NonBlockObjectAuthority) ?*GCObjectHeader {
        return self.doomed.pop();
    }

    fn popTemporary(self: *NonBlockObjectAuthority) ?*GCObjectHeader {
        return self.temporary.pop();
    }

    fn deinit(self: *NonBlockObjectAuthority, allocator: std.mem.Allocator) void {
        std.debug.assert(self.doomed.items.len == 0);
        std.debug.assert(self.temporary.items.len == 0);
        self.items.deinit(allocator);
        self.doomed.deinit(allocator);
        self.temporary.deinit(allocator);
        self.* = .{};
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
        const next = header.nextNonObject().?;
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
    CorruptNonBlockObjectAuthority,
    /// `young_head` no longer names a node on `gc_obj_list` -- a detach path
    /// forgot the young-suffix anchor and the next minor would walk freed
    /// memory (the `unlinkObjectWithBytes` hole, 2026-08-25).
    DanglingYoungHead,
    NegativeRefCount,
    InvalidHeaderState,
    MissingHeapAllocation,
    HeapLiveBytesMismatch,
    OldLiveBytesMismatch,
    LargeObjectBytesMismatch,
    LargeObjectClassificationMismatch,
    CarrierOldNewMismatch,
    CarrierRawOwnedMismatch,
    CarrierGenerationMismatch,
    CarrierByteMismatch,
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
    DanglingSlots2PayloadOwner,
    InvalidSlots2PayloadOwner,
    InvalidSlots2PayloadSlot,
    MissingSlots2PayloadSlot,
    UndersizedTrailingObjectCell,
    ObjectCellSizeClassMismatch,
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
            {
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
            const initial_lifetime = meta.lifetime.trace.mark_epoch == 0 and
                meta.lifetime.trace.object_shape_summary == 0 and
                !meta.lifetime.trace.flags.husk and
                meta.lifetime.trace.flags.reserved == 0;
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

    /// Write-barrier gate: the phase-owned mask the fast path ANDs against the
    /// owner's state word (`barrierOwnerWord`). `barrier_skip_bits` in the
    /// steady state, zero whenever some richer arm must run -- major marking
    /// (exact-target shading) or `--gc-stats` (call accounting). Rewriting one
    /// word at a phase boundary is JSC's `m_barrierThreshold` protocol
    /// (Heap.cpp:3382-3386), and it is what takes both of those global loads
    /// OFF the barrier's hot path.
    ///
    /// Deliberately adjacent to `phase` so it rides the Registry's pinned
    /// front cache line (see K4 above) rather than a cold tail line.
    /// `refreshBarrierGate` is the only writer; `initLists` seeds it.
    barrier_gate: u64 = barrier_skip_bits,

    memory: *memory.MemoryAccount,
    policy: Policy = .{},

    // qjs `rt->gc_obj_list` / `rt->tmp_obj_list`.
    // Published Objects are deliberately absent: block cells use allocation
    // bitmaps, and the rare non-block population uses the authority stored in
    // the address registry's cold state.
    // Each intrusive list is a cyclic sentinel (list.h). Call `initLists` after
    // the Registry reaches its stable address — sentinels are self-referential.
    gc_obj_list: IntrusiveHeaderList = .{},

    /// First young object in `gc_obj_list`, or null when nothing is young.
    /// See `youngIterator` for why the young set is a suffix.
    young_head: ?*Header = null,
    /// Predecessor of `young_head`. Compact trace nodes have no backlink, so
    /// retaining this one per-runtime cursor lets a minor detach a young list
    /// suffix in O(young) rather than searching from the list head per corpse.
    young_predecessor: ?*Header = null,
    tmp_obj_list: IntrusiveHeaderList = .{},
    /// Active outermost Shape/Realm eager-zero worklist. It is transient and
    /// never borrows a published header's canonical `.next` word.
    zero_ref_scratch: ?*ZeroRefScratch = null,
    // No live-object counter: qjs add_gc_object/remove_gc_object
    // (quickjs.c:6540/6548) are pure list splices with no count scalar.
    // Diagnostics (`liveCount`) derive the count by walking, like
    // `liveCountKind` always has.
    /// The header the tracing sweep has unlinked and is destroying right now.
    ///
    /// `containsHeader` reads it so a synchronous class payload finalizer
    /// asking `JSRuntime.ownsObject` about its own object gets `true` while its
    /// callback runs.
    sweep_current: ?*GCObjectHeader = null,
    external_tokens: []ExternalTokenEntry = &.{},
    external_tokens_capacity: usize = 0,
    next_external_token_id: u64 = 1,
    pin_entries: []PinEntry = &.{},
    pin_entries_capacity: usize = 0,

    major_phase: MajorPhase = .idle,
    major_reason: ?RequestReason = null,
    major_request: Request = .{},
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
    deferred_run_topology_verified: bool = false,
    /// Set only around `JSRuntime.deinit`'s teardown collections. The host has
    /// by contract released every handle and no mutator frame is live, so those
    /// collections are entitled to the precise root scan that
    /// `runObjectCycleRemovalWithValueRoots` already asks for -- production
    /// otherwise forces the conservative pass, and a stale native-stack slot
    /// pointing at a host-released Realm keeps it marked, which breaks the
    /// `context_head == null` teardown invariant once the tracer rather than
    /// refcounting owns object lifetime.
    host_quiescent: bool = false,

    /// The slab whose arena lifetimes the address registry observes, for
    /// recovery.
    arena_slab: ?*memory.SmallObjectSlab = null,
    /// Page-radix map of published GC objects.
    address_registry: AddressRegistryTable = .{},

    /// Publication-size histogram for Stage 4 class freeze.
    space_histogram: SpaceHistogram = .{},

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
    concurrent: ConcurrentState = .{},
    /// Current mark epoch for non-block trace carriers. Epoch 0 is reserved
    /// for newborn/unmarked; a major advances this scalar, while minors keep
    /// it fixed so sticky survivor marks remain valid. Unlike a global parity
    /// flip, a stale nonzero epoch cannot make a newborn (0) read marked.
    header_mark_epoch: u16 = 1,

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
    /// traced. Whole 4 KiB segments move between this shared chain and the
    /// private tracer stacks. Lives on the Registry so the barrier reaches it
    /// without an import cycle through `gc_mark_queue`.
    concurrent_mark_queue: mark_queue.Queue = .{},
    /// The owner's segmented private LIFO. It persists across slices; old
    /// whole segments are donated for parallel work while the hot top stays
    /// local. Allocation failure aborts the cycle before sweep.
    mark_stack: MarkStack = .{},
    generation: GenerationState = .{},
    /// Independent byte oracle for tests and ownership-audit builds; void in
    /// shipped builds.
    heap_accounting_oracle: if (heap_accounting_oracle_enabled) HeapAccountingOracle else void =
        if (heap_accounting_oracle_enabled) .{} else {},
    /// 64 KiB block heap.
    block_heap: BlockHeap = .init(std.heap.page_allocator),
    /// R3 conservative-only root census; void outside the diag build so the
    /// shipped Registry layout is untouched.
    roots_diag: if (roots_diag_enabled) conservative_mod.RootsDiagCensus else void =
        if (roots_diag_enabled) .{} else {},

    pub fn init(account: *memory.MemoryAccount, policy: Policy) Registry {
        readStressFromEnv();
        return .{
            .memory = account,
            .policy = policy,
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
        self.refreshBarrierGate();
        listInit(&self.gc_obj_list);
        listInit(&self.tmp_obj_list);
        self.zero_ref_scratch = null;
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
        if (arena_audit) self.deferred_run_topology_verified = false;
    }

    /// Prove the implicit Pass-B block-run representation before its first
    /// consumer slice. A nested destructor park may legally use the same
    /// header stack, but it must not split a block run or insert a generic
    /// header into the block suffix. Finding either shape is the explicit
    /// signal to stop and review the reentrancy before introducing the
    /// per-run-descriptor fallback described by the joint design.
    pub fn verifyDeferredFreeRunTopology(self: *Registry) InvariantError!void {
        if (!arena_audit or self.deferred_run_topology_verified) return;

        var seen_blocks: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer seen_blocks.deinit(std.heap.page_allocator);
        var saw_block_suffix = false;
        var current_block_base: ?usize = null;
        var cursor = self.cycle_deferred_frees.head;
        while (cursor) |header| : (cursor = deferredNext(header)) {
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
            // Close the epoch before any destructor can condemn or raw-free a
            // queued address, then return every private/shared segment.
            self.closeMarkingAndDrainFrontier(.monotonic);
        }
        std.debug.assert(self.zero_ref_scratch == null);
        self.phase = .deinit;

        // Phase 0: unpublished construction-root shells (detached generator
        // shells) are owned only by the pin ledger. Tear them down through the
        // same typed route as `destroyGeneratorShell` -- payload, borrowed
        // holders, raw cell -- while classes, the payload allocator and the
        // block heap are all still alive. `removeConstructionRoot` shifts the
        // ledger, so the index is only advanced past non-construction pins.
        {
            var index: usize = 0;
            while (index < self.pin_entries.len) {
                const entry = self.pin_entries[index];
                if (entry.count != construction_pin_count) {
                    index += 1;
                    continue;
                }
                object.Object.fromHeader(entry.header).destroyGeneratorShell(rt);
            }
        }

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

        // Objects must release their Shape/FB/VarRef edges before those carrier
        // bodies are dismantled below. Block objects should already be gone
        // after JSRuntime's host-quiescent teardown collections; the explicit
        // side authority is nevertheless a complete fallback for every
        // non-block Object still owned at this boundary.
        while (self.nonBlockObjectCount() != 0) {
            const h = self.nonBlockObjectAt(self.nonBlockObjectCount() - 1);
            std.debug.assert(h.metaConst().flags.kind == .object);
            self.removeNonBlockObject(h);
            self.recordHeapFreeWithBytes(h, heapByteSizeFromHeader(rt, h));
            h.meta().flags.finalizing = true;
            object.Object.destroyFromHeader(rt, h);
            rt.drainDeferredClassPayloadFinalizers();
        }
        while (!listEmpty(&self.gc_obj_list)) {
            // Compact headers have no backlink on tracer-owned kinds. Teardown
            // order is mediated by the holding stacks below, not list order,
            // so consume the head and keep every detach O(1).
            const h = listFirst(&self.gc_obj_list).?;
            if (h.meta().flags.kind == .shape) {
                self.removeGcObject(h);
                h.setNextNonObject(held_shapes);
                held_shapes = h;
                continue;
            }
            if (h.meta().flags.kind == .var_ref) {
                self.removeGcObject(h);
                h.meta().flags.finalizing = true;
                var_ref.VarRef.prepareForRuntimeDeinit(rt, h);
                h.setNextNonObject(held_var_refs);
                held_var_refs = h;
                continue;
            }
            self.removeGcObject(h);
            self.recordHeapFreeWithBytes(h, heapByteSizeFromHeader(rt, h));
            h.meta().flags.finalizing = true;
            if (h.meta().flags.kind == .function_bytecode) {
                h.setNextNonObject(held_function_bytecodes);
                held_function_bytecodes = h;
                continue;
            }
            switch (h.meta().flags.kind) {
                .object => object.Object.destroyFromHeader(rt, h),
                .realm_context => context_mod.JSContext.destroyFromHeader(rt, h),
                .module => module_mod.ModuleRecord.destroyFromHeader(rt, h),
                .big_int => bigint.BigInt.destroyFromHeader(rt, h),
                else => unreachable,
            }
            rt.drainDeferredClassPayloadFinalizers();
        }

        // Phase 2: every closure has consumed its FB-owned capture count. FB
        // resources may now release constant-pool object edges; Object structs
        // remain parked in cycle_deferred_frees until after Shape teardown.
        while (held_function_bytecodes) |h| {
            const next = h.nextNonObject();
            h.setNextNonObject(null);
            function_bytecode_mod.destroyFromHeader(rt, h);
            held_function_bytecodes = next;
        }

        // Phase 3: every cell owner is gone. Their releases were suppressed by
        // the deinit phase/finalizing bit, so reclaim each prepared cell struct
        // exactly once regardless of its residual refcount.
        while (held_var_refs) |h| {
            const next = h.nextNonObject();
            h.setNextNonObject(null);
            self.recordHeapFreeWithBytes(h, heapByteSizeFromHeader(rt, h));
            var_ref.VarRef.freeCycleDeferredStruct(rt, h);
            held_var_refs = next;
        }

        // Phase 4: every object's resources are gone, but its struct remains
        // valid while held shapes release prototype edges. `destroyShape`
        // self-removes from the GC list (guarded no-op here) and frees property
        // storage + bucket links.
        while (held_shapes) |h| {
            const next = h.nextNonObject();
            h.setNextNonObject(null);
            rt.shapes.destroyFromHeader(h);
            held_shapes = next;
        }

        // Phase 5: all resource destructors and late Shape releases are done;
        // reclaim the parked Object/FunctionBytecode structs.
        object.Object.drainCycleDeferredFrees(rt);
        rt.shapes.deinit();

        listInit(&self.gc_obj_list);
        listInit(&self.tmp_obj_list);
        self.zero_ref_scratch = null;

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

        // TGC S2: string carriers that survived the host-quiescent teardown
        // collections (atom-table roots) leave through the same unpublish +
        // return path the sweep uses, so the accounting oracle balances.
        if (comptime string_tracer_owned) string.destroyAllStringCarriersForDeinit(rt);

        if (self.nonBlockObjectAuthority()) |authority| {
            authority.deinit(addressRegistryAllocator());
            addressRegistryAllocator().destroy(authority);
            if (comptime block_heap_enabled) {
                self.address_registry.nonblock_objects = null;
            }
        }
        if (comptime address_registry_enabled) {
            self.address_registry.deinit(addressRegistryAllocator());
            if (comptime generation_enabled) self.generation.deinit(addressRegistryAllocator());
        }
        if (comptime concurrent_enabled) self.mark_stack.deinitStack();
        if (comptime concurrent_enabled) self.concurrent_mark_queue.deinit(addressRegistryAllocator());
        if (comptime block_heap_enabled) {
            self.block_heap.deinit();
        }
        if (comptime heap_accounting_oracle_enabled) {
            std.debug.assert(self.heap_accounting_oracle.raw.count() == 0);
            self.heap_accounting_oracle.deinit(std.heap.page_allocator);
        }
        if (comptime carrier.block_tracking_enabled or carrier.extent_tracking_enabled) {
            self.memory.deinitGcCarrier();
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

    pub fn shouldRunMajorAt(self: Registry, point: SchedulerPoint, over_threshold: bool) bool {
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

    pub const HeapSpaceSnapshot = struct {
        heap_live_bytes: usize = 0,
        old_live_bytes: usize = 0,
        large_object_bytes: usize = 0,
        old_count: usize = 0,
        large_count: usize = 0,
    };

    /// Cold logical-space census. Production publication/free keep no byte
    /// ledger: live containers, condemned buckets, and explicit in-finalizer
    /// lifecycle slots are the accounting authority, and each header's real
    /// allocation size is classified against the current immutable policy.
    pub fn deriveHeapSpaceSnapshot(self: *const Registry, rt: anytype) HeapSpaceSnapshot {
        var derived: HeapSpaceSnapshot = .{};
        var iterator = self.heapAccountingIterator();
        while (iterator.next()) |header| {
            const bytes = heapByteSizeFromHeader(rt, header);
            derived.heap_live_bytes +|= bytes;
            if (self.isLargeAllocation(bytes)) {
                derived.large_object_bytes +|= bytes;
                derived.large_count +|= 1;
            } else {
                derived.old_live_bytes +|= bytes;
                derived.old_count +|= 1;
            }
        }
        return derived;
    }

    pub fn statsSnapshot(self: *const Registry, rt: anytype) Stats {
        const snapshot = self.*;
        // Walk the Registry's accounting containers, not the by-value
        // snapshot: nodes' links point at live sentinels, not copied headers.
        const heap = self.deriveHeapSpaceSnapshot(rt);
        return .{
            .total_allocated_bytes = heap.heap_live_bytes,
            // The account's real high-water, not live again. This field
            // printed `live` for its whole history, which is why the §1.3
            // peak/live rows had no instrument: peak == live == allocated on
            // every panel ever captured. Whole-account rather than heap-only,
            // which errs on the reporting-more side.
            .peak_allocated_bytes = rt.memory.peak_allocated_bytes,
            .heap_live_bytes = heap.heap_live_bytes,
            .old_live_bytes = heap.old_live_bytes,
            .large_object_bytes = heap.large_object_bytes,
            .old_allocated_bytes = heap.old_live_bytes,
            .old_alloc_count = heap.old_count,
            .large_allocated_bytes = heap.large_object_bytes,
            .large_alloc_count = heap.large_count,
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
        if (h.metaConst().flags.kind != .object) h.setNextNonObject(null);
        try self.addInitializedWithSize(h, bytes);
    }

    /// Register a freshly allocated header whose prefix and intrusive links are
    /// already initialized. Typed MemoryAccount allocations plus their owning
    /// constructors provide this invariant, avoiding duplicate hot-path stores.
    pub inline fn addInitializedWithSize(self: *Registry, h: *GCObjectHeader, bytes: usize) !void {
        if (h.metaConst().flags.kind == .object and !isBlockCellHeader(h)) {
            try self.prepareNonBlockObjectAuthority();
        }
        self.addInitializedWithSizeNoFail(h, bytes);
    }

    /// Reserve the header-external membership slot before a raw Object
    /// allocation becomes observable. Object allocators call this after they
    /// know the block heap declined; the fallible generic publication API calls
    /// it again as a defensive boundary for test/embedding-created carriers.
    pub fn prepareNonBlockObjectAuthority(self: *Registry) !void {
        const authority = self.nonBlockObjectAuthority() orelse unreachable;
        try authority.prepare(addressRegistryAllocator());
    }

    /// No-fail publication primitive for fully prepared GC objects. Registry
    /// publication only updates scalar accounting and intrusive links; every
    /// allocation and owner-producing operation must already have completed.
    pub fn addInitializedWithSizeNoFail(self: *Registry, h: *GCObjectHeader, bytes: usize) void {
        self.publishInitialized(h, bytes, .fast);
    }

    /// Cold twin of the publication funnel: the SAME body, instantiated with
    /// every cold arm live. The fast instantiation reaches this by tail call
    /// the moment any of the three cold conditions holds, which is what lets
    /// the fast body drop all three calls and become a leaf -- LLVM will not
    /// shrink-wrap a prologue around calls it can see, so the only way to stop
    /// paying five callee-saved pairs on 255M EarleyBoyer publications that
    /// call nothing is to make the hot instantiation call nothing.
    ///
    /// This is a comptime split, not a copy: there is one body, so the two arms
    /// cannot drift. What CAN drift is `publicationNeedsColdArm` -- a cold
    /// condition left out of it would be silently skipped on the fast arm --
    /// so each cold arm asserts its own condition is false when it is compiled
    /// out. Those asserts are the guard's checker.
    noinline fn publishInitializedCold(self: *Registry, h: *GCObjectHeader, bytes: usize) void {
        self.publishInitialized(h, bytes, .cold);
    }

    const PublicationArm = enum { fast, cold };

    /// Runtime half of the fast/cold split. The comptime half (`is_test`
    /// histogram, sweep-model stats) needs no gate: those arms are already
    /// absent from production builds, and `detailed_reports` is reached by a
    /// tail call that costs the frame nothing.
    inline fn publicationNeedsColdArm(self: *const Registry, is_large: bool, standalone: bool) bool {
        if (is_large or standalone) return true;
        if (comptime concurrent_enabled) {
            if (self.concurrent.markingActive()) return true;
        }
        return false;
    }

    inline fn publishInitialized(
        self: *Registry,
        h: *GCObjectHeader,
        bytes: usize,
        comptime arm: PublicationArm,
    ) void {
        assertInitialHeaderLifetime(h);
        std.debug.assert(!h.meta().flags.mark);
        std.debug.assert(!h.meta().flags.finalizing);
        std.debug.assert(!h.meta().flags.is_pinned);
        std.debug.assert(!h.meta().flags.cycle_visited);
        std.debug.assert(!h.meta().alloc_info.heap_accounted);
        // Strings have no TraceHeader link word (the body starts at the
        // handle), so "unlinked" is only meaningful for list carriers.
        if (h.metaConst().flags.kind != .object and !(string_tracer_owned and h.metaConst().flags.kind == .string))
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
        // compiler cannot prove that on its own: Registry writes through
        // `self` may alias the header, so every later `alloc_info` read used to
        // become a reload of the byte just stored. On this host the dependent
        // of that reload carried ~40% of this function's self cycles, and a
        // second reload (after the young-bit store to the adjacent byte)
        // another ~7%.
        const info_at_entry = h.metaConst().alloc_info;
        const is_block_cell = info_at_entry.block_size_idx == representation.block_cell_size_class;
        if (comptime arm == .fast) {
            if (self.publicationNeedsColdArm(is_large, info_at_entry.standalone)) {
                @branchHint(.unlikely);
                self.publishInitializedCold(h, bytes);
                return;
            }
        }
        // Only the cold arm can be standalone; the fast arm asserts it, which
        // is what keeps `publicationNeedsColdArm` honest.
        const standalone = if (comptime arm == .fast) standalone_blk: {
            std.debug.assert(!info_at_entry.standalone);
            break :standalone_blk false;
        } else info_at_entry.standalone;
        if (standalone) h.meta().size_class = encodeHeapBytes(bytes);
        h.meta().alloc_info.heap_accounted = true;
        if (comptime heap_accounting_oracle_enabled) {
            self.heap_accounting_oracle.recordPublish(@intFromPtr(h), bytes, is_large);
        }
        if (comptime carrier.lifecycle_state_enabled) {
            self.memory.carrierPublish(@intFromPtr(h), bytes) catch
                @panic("gc: CARRIER IDENTITY: publication missing carrier record");
        }
        // qjs add_gc_object writes header bookkeeping once and then
        // list_add_tail's (quickjs.c:6540-6546). No membership flag. GC pacing
        // is owned by MemoryAccount.allocated_bytes; logical space bytes and
        // counts are derived by statsSnapshot. Only the cold large arm stamps
        // the alloc-time classification for representation auditing.
        if (comptime arm == .fast) {
            std.debug.assert(!is_large);
        } else if (is_large) {
            @branchHint(.unlikely);
            h.meta().alloc_info.large = true;
        }

        // Keep the tracked-kind classification after the large cold arm. In
        // trace builds the publication tail also keeps a far-field Registry
        // base live for block/generation state; carrying `tracked` across the
        // cold arm forced every small Object publication to spill one extra
        // callee-saved register.
        const tracked = isCycleCandidate(h);
        // Checkers for the two hoisted classifications above. Everything this
        // function does between the read and here writes `heap_accounted`,
        // `large`, `size_class` or Registry scalars -- none of which may move
        // `standalone` or `block_size_idx`.
        std.debug.assert(info_at_entry.standalone == h.metaConst().alloc_info.standalone);
        std.debug.assert(is_block_cell == isBlockCellHeader(h));
        const is_nonblock_object = tracked and !is_block_cell and
            h.metaConst().flags.kind == .object;
        // TGC S2: a string that is neither a block cell nor a non-block
        // Object is an extent (standalone prefix). Strings carry no
        // TraceHeader link word, so `gc_obj_list` cannot hold them; the
        // heap's medium/large extent tables are their enumeration (marked
        // through `extentSetMark`, swept by `Heap.sweepStringExtents`).
        const is_list_carrier = tracked and !is_block_cell and
            !(string_tracer_owned and h.metaConst().flags.kind == .string);
        if (comptime address_registry_enabled) {
            if (is_nonblock_object) {
                self.nonBlockObjectAuthority().?.publish(h);
            } else if (is_list_carrier) {
                self.linkGcObjectTail(h);
            }
            self.registerLiveAddressClassified(h, bytes, tracked, standalone, is_block_cell, arm);
            self.observeNewPublication(h, bytes);
        } else if (is_nonblock_object) {
            self.nonBlockObjectAuthority().?.publish(h);
        } else if (is_list_carrier) self.linkGcObjectTail(h);
    }

    /// qjs `add_gc_object` for shapes (quickjs.c:6540): rc/kind already live
    /// in the prefix, then heap_accounted + list_add_tail.
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
        if (comptime heap_accounting_oracle_enabled) {
            self.heap_accounting_oracle.recordPublish(@intFromPtr(h), bytes, false);
        }
        if (comptime carrier.lifecycle_state_enabled) {
            self.memory.carrierPublish(@intFromPtr(h), bytes) catch
                @panic("gc: CARRIER IDENTITY: publication missing carrier record");
        }
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
            // Symmetric with publication: block cells are charged their
            // physical body capacity (class rounding), standalone their size.
            .object => object.Object.fromHeaderConst(h).bodyBytes(),
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
            .string => if (comptime string_tracer_owned) string.accountedAllocationSizeFromHeader(h) else 0,
            .big_int => blk: {
                const big: *const bigint.BigInt = @alignCast(@fieldParentPtr("header", h));
                break :blk big.accountedAllocationSize();
            },
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
                const obj = object.Object.fromHeaderConst(h);
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
            .string => if (comptime string_tracer_owned) string.accountedAllocationSizeFromHeader(h) else 0,
            .big_int => blk: {
                const big: *const bigint.BigInt = @alignCast(@fieldParentPtr("header", h));
                break :blk big.accountedAllocationSize();
            },
        };
    }

    fn isLargeAllocation(self: Registry, bytes: usize) bool {
        return bytes != 0 and bytes >= self.policy.large_object_threshold;
    }

    fn isCycleCandidate(h: *const GCObjectHeader) bool {
        return h.metaConst().flags.kind == .object or h.metaConst().flags.kind == .function_bytecode or h.metaConst().flags.kind == .var_ref or h.metaConst().flags.kind == .shape or h.metaConst().flags.kind == .realm_context or h.metaConst().flags.kind == .module or h.metaConst().flags.kind == .big_int or
            (string_tracer_owned and h.metaConst().flags.kind == .string);
    }

    fn recordHeapFreeWithBytes(self: *Registry, header: *GCObjectHeader, bytes: usize) void {
        if (!header.meta().alloc_info.heap_accounted or bytes == 0) return;
        self.assertFrontierAllowsReclaimKind(header.metaConst().flags.kind);
        // The cold verifier owns size/classification validation. Production
        // only restores the publication bits; test/audit builds also debit
        // the independent lifecycle oracle compiled above.
        const is_large = self.isLargeAllocation(bytes);
        std.debug.assert(header.meta().alloc_info.large == is_large);
        if (comptime heap_accounting_oracle_enabled) {
            self.heap_accounting_oracle.recordUnpublish(@intFromPtr(header), bytes, is_large);
        }
        header.meta().alloc_info.large = false;
        header.meta().alloc_info.heap_accounted = false;
        if (comptime carrier.lifecycle_state_enabled) {
            self.memory.carrierTransition(@intFromPtr(header), .doomed) catch
                @panic("gc: CARRIER IDENTITY: retirement missing carrier record");
        }
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

    // Production heap_live_bytes / old_live_bytes / large_object_bytes are
    // never stored: statsSnapshot derives them from the accounting census.
    // Test/audit builds separately retain a shadow lifecycle oracle so the
    // verifier can detect a census ownership omission.

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
        // Let that structural stamp answer before kind, list, and generation
        // work.
        if (h.meta().flags.cycle_visited) return;
        if (!isCycleCandidate(h)) return;
        if (h.metaConst().flags.kind == .object) {
            if (!isBlockCellHeader(h)) self.removeNonBlockObject(h);
            return;
        }
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

    /// TGC S2: unpublish an extent string the extent sweep found dead
    /// (`string.sweepStringExtents`). Not `unlinkObjectWithBytes`: that path
    /// reads the intrusive link word, which a string does not have. What a
    /// standalone string publication left behind is the byte ledger, the
    /// address-registry occupant (`insertLiveAddressCold`) and the young
    /// census; undo exactly those, in `unregisterLiveAddress`'s order.
    /// TGC S2: a condemned string BLOCK CELL leaves the registry. Cells are
    /// bitmap-owned (no list link, no occupant-table entry), so this is the
    /// byte debit plus the remembered-owner release -- the string twin of
    /// what `unregisterObjectWithBytes` does for an Object cell.
    pub fn unpublishStringCell(self: *Registry, h: *GCObjectHeader, bytes: usize) void {
        comptime std.debug.assert(string_tracer_owned);
        std.debug.assert(isBlockCellHeader(h));
        self.recordHeapFreeWithBytes(h, bytes);
        if (comptime generation_enabled) self.forgetGenerationalOwner(h);
    }

    pub fn unpublishStringExtent(self: *Registry, h: *GCObjectHeader, bytes: usize) void {
        comptime std.debug.assert(string_tracer_owned);
        std.debug.assert(h.metaConst().flags.kind == .string);
        std.debug.assert(h.metaConst().alloc_info.standalone);
        self.recordHeapFreeWithBytes(h, bytes);
        if (comptime address_registry_enabled) {
            self.address_registry.remove(addressRegistryAllocator(), h);
        }
        if (comptime generation_enabled) self.forgetGenerationalOwner(h);
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
    /// Three phases behind one `next()`: the intrusive non-Object carriers,
    /// the block heap's cells, then the side-authoritative non-block Objects,
    /// walked bitmap-word first so an empty block costs four word tests.
    /// Producing a cell requires alloc-bit AND
    /// `heap_accounted`, which is exactly the old list membership: husks keep
    /// their cell but lose their accounting, and a cell between
    /// `initGcPrefix` and registration is not yet an object.
    ///
    /// In young mode the block phase walks the young-block list instead of
    /// every superblock, filtering per cell on the `young` header bit --
    /// recycled cells put OLD objects inside young-listed blocks.
    ///
    /// NOT enumerated here: TGC S2 extent strings (standalone `.string`
    /// prefixes over the cell ceiling). They have no link word and no cell,
    /// so their only enumeration is the block heap's medium/large extent
    /// tables (`Heap.sweepStringExtents`); census/verify consumers that need
    /// them must walk those tables.
    pub const GcObjectIterator = struct {
        cursor: ?*GCObjectHeader,
        sentinel: *const GCObjectHeader,
        heap: ?*const BlockHeapMod.Heap = null,
        young_only: bool = false,
        /// Dead-scan mode: the block phase yields only allocated-and-unmarked
        /// cells, computed word-at-a-time, so survivors are never touched --
        /// the whole point of bitmap condemnation. List-phase consumers do
        /// their own mark test as before.
        unmarked_only: bool = false,
        /// Include the side-authoritative non-block Object phase. Kept in the
        /// iterator's existing flag tail: the side index reuses `blk_index`
        /// after block enumeration, and Registry is recovered from the stable
        /// list sentinel. This preserves the pre-side iterator size/offsets so
        /// conservative native-stack scanning is not perturbed by bookkeeping.
        side_objects: bool = false,
        sb_index: usize = 0,
        blk_index: usize = 0,
        cell_index: u32 = 0,
        young_block: usize = 0,

        pub fn next(self: *GcObjectIterator) ?*GCObjectHeader {
            if (self.cursor) |current| {
                if (current != self.sentinel) {
                    self.cursor = current.nextNonObject();
                    return current;
                }
                self.cursor = null;
            }
            if (comptime block_heap_enabled) {
                if (self.heap) |heap| {
                    const current = if (self.young_only)
                        self.nextYoungCell(heap)
                    else
                        self.nextCell(heap);
                    if (current) |header| return header;
                    // Retire the phase once. Leaving this pointer live made
                    // every subsequent block-cell `next()` re-check the empty
                    // side authority before it could advance the bitmap.
                    self.heap = null;
                }
            }
            if (self.side_objects) {
                const registry = self.registryFromSentinel();
                // Re-read the authority on every step: a block or payload
                // marker may publish another non-block Object and grow the
                // backing array before or during this final phase.
                while (self.blk_index < registry.nonBlockObjectCount()) {
                    const current = registry.nonBlockObjectAt(self.blk_index);
                    self.blk_index += 1;
                    if (self.young_only and !current.metaConst().flags.young) continue;
                    if (self.unmarked_only and registry.headerMarked(current)) continue;
                    return current;
                }
            }
            return null;
        }

        inline fn registryFromSentinel(self: *const GcObjectIterator) *const Registry {
            const list: *const IntrusiveHeaderList = @fieldParentPtr("sentinel", self.sentinel);
            return @alignCast(@fieldParentPtr("gc_obj_list", list));
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

    /// Logical accounting population: every allocation that still carries
    /// `heap_accounted`, including condemned corpses awaiting destruction.
    ///
    /// This deliberately follows the old ledger's physical-lifetime meaning:
    /// condemnation proves logical death but does not return bytes. Block
    /// corpses remain visible in the alloc bitmap, while delisted standalone
    /// and non-block corpses live in `doomed_by_kind`; current callback slots
    /// cover the interval after a bucket unlink and before the actual debit.
    const HeapAccountingIterator = struct {
        live: GcObjectIterator,
        doomed_by_kind: *const [gc_kind_count]IntrusiveHeaderList,
        doomed_objects: []const *GCObjectHeader,
        temporary_objects: []const *GCObjectHeader,
        doomed_kind_index: usize = 0,
        doomed_cursor: ?*GCObjectHeader = null,
        doomed_object_index: usize = 0,
        temporary_object_index: usize = 0,
        sweep_current: ?*GCObjectHeader,
        current_yielded: bool = false,
        /// TGC S2: string extents sit in the block heap's medium/large
        /// tables, outside every list and bitmap; audits enumerate them here.
        extents: if (block_heap_enabled) BlockHeapMod.Heap.ExtentKeyIterator else void =
            if (block_heap_enabled) undefined else {},

        fn next(self: *HeapAccountingIterator) ?*GCObjectHeader {
            if (self.live.next()) |header| return header;
            if (comptime block_heap_enabled and string_tracer_owned) {
                while (self.extents.next()) |base| {
                    const header: *GCObjectHeader = @ptrFromInt(base + metadata_prefix_size);
                    if (header.metaConst().alloc_info.heap_accounted) return header;
                }
            }
            while (self.doomed_kind_index < gc_kind_count) {
                const bucket = &self.doomed_by_kind[self.doomed_kind_index];
                const current = self.doomed_cursor orelse bucket.sentinel.next_non_object orelse {
                    self.doomed_kind_index += 1;
                    continue;
                };
                if (current == &bucket.sentinel) {
                    self.doomed_kind_index += 1;
                    self.doomed_cursor = null;
                    continue;
                }
                self.doomed_cursor = current.nextNonObject();
                if (!current.metaConst().alloc_info.heap_accounted) continue;
                return current;
            }
            while (self.doomed_object_index < self.doomed_objects.len) {
                const current = self.doomed_objects[self.doomed_object_index];
                self.doomed_object_index += 1;
                if (current.metaConst().alloc_info.heap_accounted) return current;
            }
            while (self.temporary_object_index < self.temporary_objects.len) {
                const current = self.temporary_objects[self.temporary_object_index];
                self.temporary_object_index += 1;
                if (current.metaConst().alloc_info.heap_accounted) return current;
            }
            if (self.current_yielded) return null;
            self.current_yielded = true;
            const current = self.sweep_current orelse return null;
            if (current.metaConst().alloc_info.heap_accounted) return current;
            return null;
        }
    };

    pub fn objectIterator(self: *const Registry) GcObjectIterator {
        return .{
            .cursor = self.gc_obj_list.sentinel.next_non_object,
            .sentinel = &self.gc_obj_list.sentinel,
            .heap = if (comptime block_heap_enabled) &self.block_heap else {},
            .side_objects = true,
        };
    }

    fn heapAccountingIterator(self: *const Registry) HeapAccountingIterator {
        const authority = self.nonBlockObjectAuthority();
        return .{
            .live = self.objectIterator(),
            .doomed_by_kind = &self.doomed_by_kind,
            .doomed_objects = if (authority) |value| value.doomed.items else &.{},
            .temporary_objects = if (authority) |value| value.temporary.items else &.{},
            .sweep_current = self.sweep_current,
            .extents = if (comptime block_heap_enabled) self.block_heap.extentKeys() else {},
        };
    }

    /// Reserve the existing pin ledger before taking a block cell, so adding
    /// the construction pin after initialization is a no-fail scalar publish.
    pub fn prepareConstructionRoot(self: *Registry) !void {
        try self.ensurePinEntryCapacity(self.pin_entries.len + 1);
    }

    /// Protect a fully initialized Object whose shape is intentionally not
    /// installed yet. Only the detached generator constructor has this
    /// lifetime; all other block-cell objects publish immediately.
    pub fn addConstructionRoot(self: *Registry, header: *GCObjectHeader) void {
        std.debug.assert(header.metaConst().flags.kind == .object);
        std.debug.assert(!header.metaConst().alloc_info.heap_accounted);
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
        const shell = object.Object.fromHeaderConst(header);
        return shell.isDetachedGeneratorShellForGc();
    }

    pub fn pinEntryIsConstructionRoot(self: *const Registry, entry: PinEntry) bool {
        return entry.count == construction_pin_count and self.isConstructionRoot(entry.header);
    }

    /// Cold audit predicate passed into BlockHeap without introducing a module
    /// cycle. The block heap supplies the cell base; the Registry owns the
    /// exact construction-list membership authority.
    pub fn blockCellPublicationAllowance(
        context: *const anyopaque,
        cell_addr: usize,
    ) BlockHeapMod.Heap.UnpublishedCellAllowance.Kind {
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
        while (parked) |candidate| : (parked = deferredNext(candidate)) {
            if (candidate == header) return .parked_finalizer;
        }
        return .none;
    }

    /// Heap-accounting runs both outside and after collections. A detached
    /// generator shell is a valid allocated-but-unpublished cell in the first
    /// case; collector publication audit separately requires its mark.
    pub fn blockCellAccountingAllowance(
        context: *const anyopaque,
        cell_addr: usize,
    ) BlockHeapMod.Heap.UnpublishedCellAllowance.Kind {
        const self: *const Registry = @ptrCast(@alignCast(context));
        const header: *const GCObjectHeader = @ptrFromInt(cell_addr + metadata_prefix_size);
        if (self.isConstructionRoot(header)) return .unmarked_construction;
        return blockCellPublicationAllowance(context, cell_addr);
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
            .side_objects = true,
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

    /// Young non-block carriers only. Block cells have their own bitmap-word
    /// clearing path, while the intrusive suffix still needs the ordinary
    /// fixed-header epoch store.
    pub fn youngListIterator(self: *const Registry) GcObjectIterator {
        return .{
            .cursor = self.young_head,
            .sentinel = &self.gc_obj_list.sentinel,
            .heap = if (comptime block_heap_enabled) null else {},
            .young_only = true,
            .side_objects = true,
        };
    }

    pub fn clearYoungBlockMarksStw(self: *Registry) void {
        if (comptime block_heap_enabled) self.block_heap.clearYoungBlockMarksStw();
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
            const owner = object.Object.fromHeaderConst(header);
            const slots2 = owner.hasSlots2Layout();
            const storage = owner.prop_values;
            if (@intFromPtr(storage) & (@alignOf(property.Entry) - 1) != 0)
                return error.MisalignedPropertyStorage;

            const has_trailing_allocation = slots2;
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
            const has_side_payload = rt.slots2_payloads.contains(@constCast(owner));
            if (slots2 and owner.flags.class_payload_kind == .ordinary) {
                if (!has_side_payload) return error.MissingSlots2PayloadSlot;
            } else if (has_side_payload) {
                return error.InvalidSlots2PayloadOwner;
            }
            if (owner.shape_ref.prop_count != 0 and !owner.hasPropertyStorage())
                return error.MissingObjectPropertyStorage;
            if (owner.shape_ref.prop_count > owner.shape_ref.prop_size)
                return error.InvalidTrailingPropertyCapacity;

            if (comptime block_heap_enabled) {
                if (isBlockCellHeader(header)) {
                    const cell = @intFromPtr(header) - metadata_prefix_size;
                    const block = BlockHeapMod.Block.fromCellTrusted(cell);
                    const wanted = metadata_prefix_size + owner.allocationSize(rt);
                    if (block.cell_size < wanted)
                        return error.UndersizedTrailingObjectCell;
                    // obj64 ③: the cell width is now a function of `class_id`,
                    // and alloc and free each compute it independently. A cell
                    // that is merely BIG ENOUGH is not enough: it means the two
                    // sides disagreed, and the free will hand the allocator a
                    // size class the alloc never took. Demand the exact class.
                    const wanted_class = gc_space.classIndexForPayload(wanted) orelse
                        return error.ObjectCellSizeClassMismatch;
                    const actual_class = gc_space.classIndexForPayload(block.cell_size) orelse
                        return error.ObjectCellSizeClassMismatch;
                    if (wanted_class != actual_class)
                        return error.ObjectCellSizeClassMismatch;
                }
            }
        }

        // Validate membership before dereferencing a key. A skipped destroy-
        // side removal leaves raw Object identity in this table after its cell
        // has returned to the allocator; the address registry is the authority
        // that makes that stale key safe to diagnose rather than dereference.
        var payload_iterator = rt.slots2_payloads.iterator();
        while (payload_iterator.next()) |entry| {
            const owner = entry.key_ptr.*;
            const header: *const GCObjectHeader = @ptrCast(owner);
            if (!self.containsHeader(header)) return error.DanglingSlots2PayloadOwner;
            if (!owner.hasSlots2Layout() or owner.class_id != class.ids.object or
                owner.flags.class_payload_kind != .ordinary)
            {
                return error.InvalidSlots2PayloadOwner;
            }
            if (entry.value_ptr.* == null) return error.InvalidSlots2PayloadSlot;
        }
    }

    fn appendGcObject(self: *Registry, header: *GCObjectHeader) void {
        std.debug.assert(isCycleCandidate(header));
        std.debug.assert(header.metaConst().flags.kind != .object);
        std.debug.assert(!headerLinked(header));
        self.stageYoungTailPredecessor();
        listAddTail(&self.gc_obj_list, header);
    }

    /// qjs `list_add_tail` (quickjs.c:6545).
    inline fn linkGcObjectTail(self: *Registry, header: *GCObjectHeader) void {
        std.debug.assert(header.metaConst().flags.kind != .object);
        self.stageYoungTailPredecessor();
        listAddTail(&self.gc_obj_list, header);
    }

    fn unregisterNonBlockObject(self: *Registry, header: *GCObjectHeader) void {
        std.debug.assert(header.metaConst().flags.kind == .object);
        std.debug.assert(!isBlockCellHeader(header));
        if (comptime address_registry_enabled) {
            if (header.metaConst().alloc_info.standalone) {
                self.address_registry.remove(addressRegistryAllocator(), header);
            }
        }
        if (comptime generation_enabled) self.forgetGenerationalOwner(header);
    }

    fn removeNonBlockObject(self: *Registry, header: *GCObjectHeader) void {
        const authority = self.nonBlockObjectAuthority() orelse return;
        if (!authority.remove(header)) return;
        self.unregisterNonBlockObject(header);
    }

    /// Move a live non-block Object into one of the two header-external
    /// condemnation lanes. Publication pre-reserves both lanes for the whole
    /// extant Object population, so the collector-side move cannot allocate.
    pub fn condemnNonBlockObject(self: *Registry, header: *GCObjectHeader, temporary: bool) void {
        self.assertFrontierAllowsReclaimKind(.object);
        std.debug.assert(header.metaConst().flags.kind == .object);
        std.debug.assert(!isBlockCellHeader(header));
        std.debug.assert(!header.metaConst().flags.cycle_visited);
        const authority = self.nonBlockObjectAuthority() orelse unreachable;
        authority.condemn(header, temporary);
        self.unregisterNonBlockObject(header);
        header.meta().flags.cycle_visited = true;
    }

    pub fn doomedNonBlockObjectCount(self: *const Registry) usize {
        const authority = self.nonBlockObjectAuthority() orelse return 0;
        return authority.doomed.items.len;
    }

    pub fn temporaryNonBlockObjectCount(self: *const Registry) usize {
        const authority = self.nonBlockObjectAuthority() orelse return 0;
        return authority.temporary.items.len;
    }

    pub fn popDoomedNonBlockObject(self: *Registry) ?*GCObjectHeader {
        const authority = self.nonBlockObjectAuthority() orelse return null;
        return authority.popDoomed();
    }

    pub fn popTemporaryNonBlockObject(self: *Registry) ?*GCObjectHeader {
        const authority = self.nonBlockObjectAuthority() orelse return null;
        return authority.popTemporary();
    }

    pub fn condemnedNonBlockObjectContains(self: *const Registry, header: *const GCObjectHeader) bool {
        const authority = self.nonBlockObjectAuthority() orelse return false;
        for (authority.doomed.items) |candidate| if (candidate == header) return true;
        for (authority.temporary.items) |candidate| if (candidate == header) return true;
        return false;
    }

    /// Publication marks a freshly appended carrier young immediately after
    /// linkage. Capture the old tail before that append while it is still O(1).
    inline fn stageYoungTailPredecessor(self: *Registry) void {
        if (self.young_head == null) {
            self.young_predecessor = self.gc_obj_list.tail.?;
        }
    }

    pub inline fn resetYoungListSuffix(self: *Registry) void {
        self.young_head = null;
        self.young_predecessor = null;
    }

    /// qjs `list_del` / `remove_gc_object` (quickjs.c:6548). Already-unlinked
    /// headers (deinit shape self-remove) are a no-op; a linked node is spliced
    /// with no head/tail null branches.
    fn removeGcObject(self: *Registry, header: *GCObjectHeader) void {
        std.debug.assert(header.metaConst().flags.kind != .object);
        if (!headerLinked(header)) return;
        const previous = listPrevious(&self.gc_obj_list, header);
        self.removeGcObjectAfter(previous, header);
    }

    /// O(1) list detach for a collector already walking `gc_obj_list`.
    fn removeGcObjectAfter(self: *Registry, previous: *GCObjectHeader, header: *GCObjectHeader) void {
        std.debug.assert(previous.next_non_object == header);
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
    pub inline fn frontierSafeHeaderAfterMarkClaim(
        self: *const Registry,
        header: *GCObjectHeader,
    ) FrontierSafeHeader {
        // O2-B adds no shipped instruction: the wrapper is pointer-sized and
        // all proof checks are compiled only into safety/test binaries.
        if (comptime std.debug.runtime_safety) {
            const meta = header.metaConst();
            if (!frontierEpochSafe(meta.flags.kind))
                @panic("gc: FRONTIER SAFETY: unsafe kind entered frontier");
            if (!meta.alloc_info.heap_accounted or meta.flags.cycle_visited)
                @panic("gc: FRONTIER SAFETY: unpublished header entered frontier");
            // Frontier agreement covers the immutable/shared carrier prefix.
            // The whole representation audit additionally checks Object's
            // mutable Shape projection, but owner requeue legitimately occurs
            // between the shape-slot store and that projection's commit.
            verifyMetadataSemantics(meta, meta.flags.kind, .registry_published) catch
                @panic("gc: FRONTIER SAFETY: carrier/header agreement failed");
            if (!self.headerMarked(header))
                @panic("gc: FRONTIER SAFETY: queue admission preceded mark claim");
        }
        return FrontierSafeHeader.init(header);
    }

    /// Admission for an owner that would be re-traced after a mutator write.
    /// A white owner does not need requeueing: if reachable, its first normal
    /// mark claim will expand the updated edges; if unreachable, preserving
    /// those edges is unnecessary. Only an owner whose earlier claim already
    /// made it black may enter the frontier again.
    ///
    /// This is deliberately a mark CHECK, not a mark execution. The original
    /// exact-target shade keeps its existing `setHeaderMarked(target)` call;
    /// requeue adds no ReleaseFast mark RMW relative to the S1 base.
    pub inline fn frontierSafeHeaderForRequeue(
        self: *const Registry,
        header: *GCObjectHeader,
    ) ?FrontierSafeHeader {
        if (!self.headerMarked(header)) return null;
        return self.frontierSafeHeaderAfterMarkClaim(header);
    }

    fn frontierHasEntriesForSafety(self: *Registry) bool {
        if (self.mark_stack.len != 0 or !self.concurrent_mark_queue.isEmpty()) return true;
        // Helper-private stacks share this pool. An active segment is never
        // empty: the last pop releases it immediately.
        return self.concurrent_mark_queue.segmentPool().stats().active_segments != 0;
    }

    /// Condemnation/raw-free entry guard for O2-B's generation omission. Shape
    /// and Realm are exempt because they never persist in a frontier; all four
    /// admitted kinds must retain their address until marking closes and every
    /// private/shared segment has drained.
    pub fn assertFrontierAllowsReclaimKind(self: *Registry, kind: GcKind) void {
        if (comptime !std.debug.runtime_safety) return;
        if (!frontierEpochSafe(kind)) return;
        if (self.concurrent.markingActive() and self.frontierHasEntriesForSafety())
            @panic("gc: FRONTIER SAFETY: reclaim began with live frontier");
    }

    pub fn assertFrontierDrainedBeforeReclaim(self: *Registry) void {
        if (comptime !std.debug.runtime_safety) return;
        if (self.concurrent.markingActive())
            @panic("gc: FRONTIER SAFETY: reclaim began while marking active");
        if (self.frontierHasEntriesForSafety())
            @panic("gc: FRONTIER SAFETY: reclaim began before frontier drain");
    }

    pub inline fn headerMarked(self: *const Registry, h: *const GCObjectHeader) bool {
        if (comptime block_heap_enabled) {
            if (h.metaConst().alloc_info.block_size_idx == representation.block_cell_size_class) {
                const cell = @intFromPtr(h) - metadata_prefix_size;
                const block = BlockHeapMod.Block.fromCellTrusted(cell);
                return block.isMarked(h.metaConst().size_class, self.block_heap.mark_epoch);
            }
            // TGC S2 extent string (spec §5.7): no bitmap and no TraceHeader
            // epoch either -- the mark lives in the heap's extent table,
            // keyed by the allocation base (body - 8). Cold: only strings
            // over the cell ceiling get here.
            if (comptime string_tracer_owned) {
                if (h.metaConst().flags.kind == .string and h.metaConst().alloc_info.standalone) {
                    @branchHint(.unlikely);
                    return self.block_heap.extentIsMarked(@intFromPtr(h) - metadata_prefix_size, self.block_heap.mark_epoch);
                }
            }
        }
        if (std.debug.runtime_safety) std.debug.assert(isCycleCandidate(h));
        return @atomicLoad(u16, &h.metaConst().lifetime.trace.mark_epoch, .monotonic) == self.header_mark_epoch;
    }

    /// Mark probe for a typed carrier whose representation descriptor excludes
    /// block cells. Shape edges dominate object tracing and are known to use
    /// the fixed header epoch; routing each one through the object-only block
    /// discriminator repeats work for every object sharing the same shape.
    pub inline fn headerMarkedKnownNonBlock(self: *const Registry, h: *const GCObjectHeader) bool {
        std.debug.assert(h.metaConst().alloc_info.block_size_idx != representation.block_cell_size_class);
        return @atomicLoad(u16, &h.metaConst().lifetime.trace.mark_epoch, .monotonic) == self.header_mark_epoch;
    }

    pub inline fn setHeaderMarked(self: *const Registry, h: *GCObjectHeader) void {
        if (comptime block_heap_enabled) {
            if (h.metaConst().alloc_info.block_size_idx == representation.block_cell_size_class) {
                const cell = @intFromPtr(h) - metadata_prefix_size;
                const block = BlockHeapMod.Block.fromCellTrusted(cell);
                block.setMark(h.metaConst().size_class, self.block_heap.mark_epoch);
                return;
            }
            // Extent string: table-held mark, see `headerMarked`.
            if (comptime string_tracer_owned) {
                if (h.metaConst().flags.kind == .string and h.metaConst().alloc_info.standalone) {
                    @branchHint(.unlikely);
                    self.block_heap.extentSetMark(@intFromPtr(h) - metadata_prefix_size, self.block_heap.mark_epoch);
                    return;
                }
            }
        }
        if (std.debug.runtime_safety) std.debug.assert(isCycleCandidate(h));
        @atomicStore(u16, &h.meta().lifetime.trace.mark_epoch, self.header_mark_epoch, .monotonic);
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
        if (std.debug.runtime_safety) std.debug.assert(isCycleCandidate(h));
        @atomicStore(u16, &h.meta().lifetime.trace.mark_epoch, 0, .monotonic);
    }

    /// O(1) whole-population unmark for the ordinary case. One wrap scrub is
    /// required before reusing epoch 1; 0 always remains newborn/unmarked.
    pub fn advanceHeaderMarkEpoch(self: *Registry) void {
        if (self.header_mark_epoch != std.math.maxInt(u16)) {
            self.header_mark_epoch += 1;
            return;
        }

        var cursor = self.gc_obj_list.sentinel.next_non_object;
        while (cursor) |header| {
            if (header == &self.gc_obj_list.sentinel) break;
            @atomicStore(u16, &header.meta().lifetime.trace.mark_epoch, 0, .monotonic);
            cursor = header.nextNonObject();
        }
        if (self.nonBlockObjectAuthority()) |authority| {
            for (authority.items.items) |header| {
                @atomicStore(u16, &header.meta().lifetime.trace.mark_epoch, 0, .monotonic);
            }
        }
        self.header_mark_epoch = 1;
    }

    pub fn detachCycleCandidate(self: *Registry, header: *GCObjectHeader) void {
        self.assertFrontierAllowsReclaimKind(header.metaConst().flags.kind);
        std.debug.assert(!header.meta().flags.cycle_visited);
        if (header.metaConst().flags.kind == .object) {
            if (!isBlockCellHeader(header)) self.removeNonBlockObject(header);
        } else {
            self.removeGcObject(header);
        }
        header.meta().flags.cycle_visited = true;
    }

    /// Detach for a header produced by a block-only iterator. Allocation
    /// bitmap ownership proves there is no intrusive or side membership to
    /// remove, so the production sweep need only stamp the condemnation.
    pub inline fn detachBlockObjectCandidate(self: *Registry, header: *GCObjectHeader) void {
        if (comptime std.debug.runtime_safety) {
            self.assertFrontierAllowsReclaimKind(header.metaConst().flags.kind);
            std.debug.assert(!header.metaConst().flags.cycle_visited);
            const cell_kind = header.metaConst().flags.kind;
            std.debug.assert(cell_kind == .object or (string_tracer_owned and cell_kind == .string));
            std.debug.assert(isBlockCellHeader(header));
        }
        header.meta().flags.cycle_visited = true;
    }

    /// Sequential-sweep twin of `detachCycleCandidate`; the predecessor must
    /// still name the live-list node immediately before `header`.
    pub fn detachCycleCandidateAfter(self: *Registry, previous: *GCObjectHeader, header: *GCObjectHeader) void {
        self.assertFrontierAllowsReclaimKind(header.metaConst().flags.kind);
        std.debug.assert(!header.meta().flags.cycle_visited);
        self.removeGcObjectAfter(previous, header);
        header.meta().flags.cycle_visited = true;
    }

    pub fn restoreCycleCandidate(self: *Registry, header: *GCObjectHeader) void {
        std.debug.assert(header.meta().flags.cycle_visited);
        header.meta().flags.cycle_visited = false;
        if (header.metaConst().flags.kind == .object) {
            if (!isBlockCellHeader(header)) self.nonBlockObjectAuthority().?.publish(header);
        } else {
            self.appendGcObject(header);
        }
        if (comptime address_registry_enabled) {
            const bytes = storedHeapBytes(header) orelse defaultHeapBytes(header);
            self.registerLiveAddress(header, bytes, true);
        }
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
        self.abortCycleEnvelope();
        if (!self.concurrent.markingActive()) return;
        self.closeMarkingAndDrainFrontier(.monotonic);
        // The trace already promoted whatever it reached; the young
        // structures still describe those cells as young. Minors stay closed
        // until a major commits and makes the two agree again.
        self.generation.abandonMajorRetirement();
        self.concurrent.stats.cycles_aborted += 1;
    }

    fn closeMarkingAndDrainFrontier(
        self: *Registry,
        comptime order: std.builtin.AtomicOrder,
    ) void {
        // Ordering is the invariant: no reclamation may see marking active
        // after entries begin disappearing, and teardown may not proceed until
        // every shared/private segment is back in the pool cache.
        if (self.concurrent.markingActive()) self.setMajorMarkingActive(false, order);
        self.mark_stack.reset();
        self.concurrent_mark_queue.reset();
        self.assertFrontierDrainedBeforeReclaim();
    }

    /// Publish the settled account and the threshold derived from it for the
    /// next automatic incremental cycle. This pair is one policy decision;
    /// keeping it intact is what makes the later S/T/P tuple same-domain.
    pub fn noteCycleEnvelopeBaseline(self: *Registry, start_bytes: usize, threshold_bytes: usize) void {
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
        if (!self.concurrent.envelope_active) return;
        self.memory.endCyclePeakTracking();
        self.concurrent.envelope_active = false;
    }

    fn finishCycleEnvelope(self: *Registry) void {
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
        // vanishing case where the owner is itself rc-managed cannot retain a
        // safe queue address. Fail this cycle closed instead of reintroducing
        // a whole-heap recovery scan.
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
                if (kind == .shape) {
                    // Realm -> Shape is a real production edge: a realm fills
                    // its five initial shapes lazily (`ensureInitialShapes`),
                    // possibly while a major is marking and after the realm
                    // went black. A shape's only child is its proto, so shade
                    // it synchronously -- mark the shape, queue the proto --
                    // exactly what `Collector.shade`'s queue mode does for
                    // rc-managed kinds. Failing the cycle here surfaced as a
                    // spurious OutOfMemory in test262 `$262.createRealm()`
                    // tests once the realm barrier existed.
                    self.setHeaderMarked(target);
                    const shape_ref: *shape.Shape = @alignCast(@fieldParentPtr("header", target));
                    if (shape_ref.proto) |proto| {
                        if (@intFromPtr(proto) != 0) {
                            const proto_header = proto.gcHeader();
                            if (!self.headerMarked(proto_header)) {
                                self.setHeaderMarked(proto_header);
                                self.concurrent.stats.shaded += 1;
                                _ = self.concurrent_mark_queue.push(
                                    self.frontierSafeHeaderAfterMarkClaim(proto_header),
                                );
                            }
                        }
                    }
                    return;
                }
                self.concurrent_mark_queue.invalidateBarrier();
                return;
            }
            if (report) self.concurrent.stats.barrier_requeued_owner += 1;
            const frontier_owner = self.frontierSafeHeaderForRequeue(owner) orelse return;
            _ = self.concurrent_mark_queue.push(frontier_owner);
            return;
        }
        self.setHeaderMarked(target);
        self.concurrent.stats.shaded += 1;
        _ = self.concurrent_mark_queue.push(
            self.frontierSafeHeaderAfterMarkClaim(target),
        );
    }

    /// Whether a minor is worth attempting: enough young objects to be worth
    /// the root scan, and no full collection already in flight. Deliberately
    /// simple — the scheduling policy that replaces it belongs with the
    /// allocation-headroom work, not with the collector mechanism.
    pub inline fn shouldTryMinor(self: *const Registry) bool {
        if (self.phase != .none) return false;
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
    /// mark state cannot dedup an owner that must be re-traced -- so the
    /// shared frontier must be unbounded rather than silently dropping work.
    pub inline fn rememberOwnerForBulkWrite(self: *Registry, owner: *GCObjectHeader) void {
        if (self.barrierOwnerSkips(owner)) return;
        self.rememberOwnerForBulkWriteSlow(owner);
    }

    fn rememberOwnerForBulkWriteSlow(self: *Registry, owner: *GCObjectHeader) void {
        @branchHint(.cold);
        if (comptime concurrent_enabled) {
            if (self.concurrent.markingActive()) {
                // Same publication rule as the value barrier: an unpublished
                // owner's edges are covered by its published-grey trace.
                if (owner.meta().alloc_info.heap_accounted) {
                    if (self.frontierSafeHeaderForRequeue(owner)) |frontier_owner|
                        _ = self.concurrent_mark_queue.push(frontier_owner);
                }
                return;
            }
        }
        // The gate proves the owner old and unremembered -- EXCEPT when
        // `detailed_reports` closed the gate for accounting reasons, in which
        // case nothing has been proven and the young test still has to run.
        if (self.generation.isYoung(owner)) return;
        self.rememberGenerationalOwner(owner);
    }

    /// The gate value the current phase demands.
    ///
    /// One definition, two consumers: `refreshBarrierGate` publishes it, and
    /// the fast path's safety check re-derives it to prove the published copy
    /// is not stale. Keeping them the same expression is the point -- a gate
    /// computed one way and checked another checks nothing.
    inline fn expectedBarrierGate(self: *const Registry) u64 {
        if (comptime concurrent_enabled) {
            // Marking wants the exact-target shading arm on every store, so no
            // owner state may buy an exit.
            if (self.concurrent.markingActive()) return 0;
        }
        // `--gc-stats` wants every call counted, including the ones the gate
        // would have retired for free. Closing the gate is how the counter
        // block stays exact without a second global load on the hot path.
        if (gc_trace_stw_reports.detailed_reports) return 0;
        return barrier_skip_bits;
    }

    /// Republish the barrier gate after either of its two inputs changed.
    ///
    /// Marking transitions go through `setMajorMarkingActive`. A
    /// `detailed_reports` flip against a LIVE Registry must call this
    /// explicitly; forgetting to is a panic in every safety build rather than
    /// a silently wrong statistics row, because the fast path re-derives the
    /// expected gate on every barrier (see `barrierOwnerSkips`).
    pub fn refreshBarrierGate(self: *Registry) void {
        self.barrier_gate = self.expectedBarrierGate();
    }

    /// The only writer of the marking phase flag.
    ///
    /// Publishing the flag and republishing the derived gate is ONE
    /// transaction. A bare `major_marking_active.store` would leave the
    /// barrier taking steady-state exits while a major is marking -- i.e.
    /// dropping shades -- so the raw store must not be spelled anywhere else.
    ///
    /// What ENFORCES that is `barrierOwnerSkips`'s C1 assert, not review: a
    /// bare store leaves the gate stale and the next barrier call panics.
    /// Injection-verified at `beginIncrementalCycle`'s publication, which is
    /// the one whose window really contains mutator stores.
    pub fn setMajorMarkingActive(self: *Registry, active: bool, comptime order: std.builtin.AtomicOrder) void {
        self.concurrent.major_marking_active.store(active, order);
        self.refreshBarrierGate();
    }

    /// JSC's two-step barrier fast path (AssemblyHelpers.h:1438-1445): load the
    /// owner's state, test it against the phase-owned gate, done. True means
    /// this store owes the collector nothing.
    ///
    /// The owner word load is the one the pre-fold path already paid for
    /// `isYoung(owner)`; what disappears is the atomic marking load, the
    /// `detailed_reports` load, and -- for an owner already in the remembered
    /// set -- the SECOND object header the old-target classification used to
    /// touch.
    pub inline fn barrierOwnerSkips(self: *const Registry, owner: *const GCObjectHeader) bool {
        if (comptime std.debug.runtime_safety) {
            // C1. A stale gate is the one way this fold can go silently wrong,
            // and it is invisible from the slow path: a gate that wrongly
            // permits a skip never reaches it. So check it here, on every
            // barrier call, in every safety build.
            std.debug.assert(self.barrier_gate == self.expectedBarrierGate());
            // C2. The gate reads byte 6 bit7 as the remembered lease, which is
            // only that for eligible kinds: `.string` has no `Metadata` prefix
            // at all, and `.big_int` aliases the byte onto its live refcount.
            // Audit §10.3 walked every barrier call site and found neither
            // kind; this turns that survey into a machine check.
            std.debug.assert(traceRememberedCacheEligible(owner.metaConst().flags.kind));
        }
        return barrierOwnerWord(owner) & self.barrier_gate != 0;
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

    /// TGC S0 L3 audit probe (`docs/tracing-gc-s0-spec.md` §L3). Placed after
    /// a store that static reading found unbarriered; counts the exact state
    /// the generational barrier exists to prevent: a published, OLD,
    /// UNREMEMBERED owner now holding an edge to a YOUNG child. Only the
    /// authoritative remembered map is consulted, never the cache bit.
    ///
    /// Erased in ReleaseFast (`runtime_safety` is false there) so the shipped
    /// `zjs` carries no symbol; armed in Debug / ReleaseSafe test binaries,
    /// in `zjs-dev`, and in the `-Dzjs_gc_roots_diag` ReleaseFast binary
    /// (which is how Octane runs under the probe at speed); gated at run time
    /// on `ZJS_MINOR_AUDIT`.
    pub inline fn auditUnbarrieredStore(
        self: *Registry,
        owner: *GCObjectHeader,
        child: ?*GCObjectHeader,
        comptime site: UnbarrieredStoreSite,
    ) void {
        if (comptime !(std.debug.runtime_safety or roots_diag_enabled)) return;
        if (!minor_audit) return;
        const target = child orelse return;
        @call(.never_inline, auditUnbarrieredStoreSlow, .{ self, owner, target, site });
    }

    fn auditUnbarrieredStoreSlow(
        self: *Registry,
        owner: *GCObjectHeader,
        target: *GCObjectHeader,
        site: UnbarrieredStoreSite,
    ) void {
        if (!owner.metaConst().alloc_info.heap_accounted) return;
        if (owner.metaConst().flags.young) return;
        if (!target.metaConst().flags.young) return;
        var it = self.generation.rememberedIterator();
        while (it.next()) |addr| {
            if (addr.* == @intFromPtr(owner)) return;
        }
        const slot = &unbarriered_store_hits[@intFromEnum(site)];
        slot.* += 1;
        const owner_class: u32 = if (owner.metaConst().flags.kind == .object)
            object.Object.fromHeader(owner).class_id
        else
            0;
        std.debug.print(
            "UNBARRIERED-STORE site={s} hit={d} owner_kind={s} owner_class={d} child_kind={s}\n",
            .{ @tagName(site), slot.*, @tagName(owner.metaConst().flags.kind), owner_class, @tagName(target.metaConst().flags.kind) },
        );
        if (slot.* == 1) std.debug.dumpCurrentStackTrace(.{});
        if (minor_audit_fatal) @panic("UNBARRIERED-STORE: old unremembered owner gained a young child without a barrier");
    }

    /// Header-shaped write barrier. The whole steady-state decision is
    /// `barrierOwnerSkips`; everything below it is a phase the gate has
    /// already announced by being zero.
    pub inline fn generationalBarrier(self: *Registry, owner: *GCObjectHeader, child: ?*GCObjectHeader) void {
        const target = child orelse return;
        if (self.barrierOwnerSkips(owner)) return;
        self.generationalBarrierSlow(owner, target);
    }

    /// Everything the folded fast path stopped doing inline.
    ///
    /// The exact-target shading arm stays a real arm rather than being folded
    /// into the gate: §8.4's tearing premise is what makes owner-only records
    /// unsound under a real concurrent marker, and JSC's 8-byte atomic escape
    /// hatch does not exist for a 16-byte JSValue. The gate carries the PHASE
    /// decision; the arm carries the semantics.
    fn generationalBarrierSlow(self: *Registry, owner: *GCObjectHeader, target: *GCObjectHeader) void {
        @branchHint(.cold);
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
        // pay for numbers when someone asked for them -- and when they do ask,
        // the gate closes so the count stays complete.
        if (gc_trace_stw_reports.detailed_reports) {
            self.generationalBarrierDetailed(owner, target);
            return;
        }
        // Reached with an open gate only when the owner is old AND not yet
        // remembered, so the owner classification the pre-fold code repeated
        // here is exactly what the gate just did.
        if (!self.generation.isYoung(target)) return;
        self.rememberGenerationalOwner(owner);
    }

    /// JSValue-shaped write barrier. Keep the child raw until the gate says
    /// this store is somebody's business: young owners account for the vast
    /// majority of property writes and a minor scans them regardless.
    ///
    /// Marking and detailed reports both need the target decoded even for a
    /// young owner, and both announce themselves by zeroing the gate -- so the
    /// gate-first shape decodes exactly when the pre-fold three-way ordering
    /// did, and the edge-only counters stay comparable with earlier runs.
    pub inline fn generationalBarrierValue(self: *Registry, owner: *GCObjectHeader, child: JSValue) void {
        if (self.barrierOwnerSkips(owner)) return;
        const target = child.cycleMarkHeader() orelse return;
        self.generationalBarrierSlow(owner, target);
    }

    /// The mark frontier shares the registry's allocator for the same
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
    pub fn serveObjectCells(self: *Registry, account: *memory.MemoryAccount) !void {
        // The conservative resolver needs the block geometry before the first
        // cell can appear in a stack slot.
        self.address_registry.block_heap = &self.block_heap;
        // `MemoryAccount` owns the allocation funnel, so give it the concrete
        // heap rather than two runtime function pointers. The trace build can
        // now direct-call and specialize `allocCell`; RC comptime-erases both
        // the field and the branch.
        account.gc_object_cell_heap = &self.block_heap;
        if (comptime heap_accounting_oracle_enabled) {
            account.gc_heap_oracle = &self.heap_accounting_oracle;
        }
        const authority = try addressRegistryAllocator().create(NonBlockObjectAuthority);
        authority.* = .{};
        self.address_registry.nonblock_objects = authority;
    }

    pub fn observeSlabArenas(self: *Registry, slab: *memory.SmallObjectSlab) void {
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
        if (!tracked) return;
        const info = header.metaConst().alloc_info;
        self.registerLiveAddressClassified(header, bytes, true, info.standalone, isBlockCellHeader(header), .cold);
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
        comptime arm: PublicationArm,
    ) void {
        if (!tracked) return;
        // Slab-backed objects need no entry: their arena is registered, the
        // mask finds it, and the `heap_accounted` bit set just above this call
        // is the same "live GC object" answer the table was storing. Only
        // standalone-prefix allocations -- past the slab's 512-byte class
        // ceiling, or over-aligned -- are unreachable that way.
        if (standalone) {
            @branchHint(.unlikely);
            self.insertLiveAddressCold(header, bytes);
        }
        self.markPublishedYoungClassified(
            header,
            is_block_cell,
            arm,
        );
    }

    /// Outlined so the standalone-prefix arm's call does not have to be
    /// register-allocated inside the publication funnel. Slab and block-cell
    /// publications -- everything EarleyBoyer allocates -- never reach it, and
    /// leaving the `Table.insert` call inline made the funnel keep values live
    /// across it, which is what put five `stp` pairs in a prologue whose hot
    /// path calls nothing at all.
    noinline fn insertLiveAddressCold(self: *Registry, header: *GCObjectHeader, bytes: usize) void {
        self.address_registry.insert(addressRegistryAllocator(), header, bytes) catch {
            self.address_registry.noteFailedInsert();
        };
    }

    /// Generation shares publication's lifetime: an object is young from the
    /// moment it is published until a collection lets it survive. One bit in a
    /// byte the allocator already writes, rather than a hash-map insert per
    /// allocation.
    inline fn markPublishedYoung(self: *Registry, header: *GCObjectHeader) void {
        self.markPublishedYoungClassified(
            header,
            isBlockCellHeader(header),
            .cold,
        );
    }

    /// `markPublishedYoung` for callers holding the block-cell answer already.
    /// The young bit lives in flags (byte 3) and the block-cell class in
    /// alloc_info (byte 2) of the same prefix word, so deriving the class after
    /// the young store forced a reload of a byte adjacent to a just-issued
    /// store -- see `addInitializedWithSizeNoFail`'s note.
    inline fn markPublishedYoungClassified(
        self: *Registry,
        header: *GCObjectHeader,
        is_block_cell: bool,
        comptime arm: PublicationArm,
    ) void {
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
            if (comptime arm == .fast) {
                // `publicationNeedsColdArm` already routed an active marker to
                // the cold twin. This assert is what proves it did -- and it is
                // spelled with an explicit safety gate because `markingActive`
                // is an atomic load that ReleaseFast may not delete even with
                // its result discarded (it left a dead `ldrb wzr` behind).
                if (comptime std.debug.runtime_safety) std.debug.assert(!self.concurrent.markingActive());
            } else if (self.concurrent.markingActive()) {
                @branchHint(.unlikely);
                self.publishGreyCold(header);
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
        // Non-block Objects are not part of the allocation-ordered intrusive
        // suffix. Their side authority is small and filtered on the young bit
        // by `youngListIterator`, so no list anchor belongs to them.
        if (header.metaConst().flags.kind == .object) return;
        // Neither are extent strings: `publishInitialized` never linked them
        // (no link word), so anchoring the young suffix on one would send the
        // next minor's list walk through string bytes.
        if (comptime string_tracer_owned) {
            if (header.metaConst().flags.kind == .string) return;
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

    /// The published-grey arm of `markPublishedYoungClassified`, outlined.
    /// `setHeaderMarked` and `pushSingle` are the publication funnel's other
    /// two calls; concurrent marking is inactive for the overwhelming majority
    /// of publications, so keeping them inline only bought the hot path a
    /// callee-saved prologue it never used.
    noinline fn publishGreyCold(self: *Registry, header: *GCObjectHeader) void {
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
            _ = self.concurrent_mark_queue.push(
                self.frontierSafeHeaderAfterMarkClaim(header),
            );
        }
    }

    inline fn unregisterLiveAddress(self: *Registry, header: *GCObjectHeader) void {
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
                const next = header.nextNonObject();
                self.young_head = if (next == &self.gc_obj_list.sentinel) null else next;
            }
        }
    }

    /// Histogram and sweep-window observation for a first-time publication.
    /// Restores do not call this (the object was already counted / windowed).
    inline fn observeNewPublication(self: *Registry, header: *GCObjectHeader, bytes: usize) void {
        if (comptime space_model_enabled) {
            if (comptime builtin.is_test) {
                if (header.metaConst().flags.kind == .object) {
                    self.space_histogram.recordObject(
                        bytes,
                        object.Object.fromHeaderConst(header).hasSlots2Layout(),
                    );
                } else self.space_histogram.record(bytes);
            } else if (gc_trace_stw_reports.detailed_reports) {
                @branchHint(.unlikely);
                self.recordSpacePublicationDetailed(header, bytes);
            }
        }
    }

    /// `--gc-stats` publication histogram. The CLI enables detailed reports
    /// before creating the runtime; default production must not maintain four
    /// diagnostic counters on every object/shape publication. Outlining keeps
    /// the disabled arm to one flag load and branch instead of retaining the
    /// histogram's classify-and-update body in both publication funnels.
    noinline fn recordSpacePublicationDetailed(self: *Registry, header: *GCObjectHeader, bytes: usize) void {
        if (header.metaConst().flags.kind == .object) {
            self.space_histogram.recordObject(
                bytes,
                object.Object.fromHeaderConst(header).hasSlots2Layout(),
            );
        } else self.space_histogram.record(bytes);
    }

    /// Hold zero-ref GC nodes until a batch traversal is complete. QuickJS
    /// uses the same DECREF phase around its weakref_list walk so payload
    /// finalizers cannot unlink the next weak holder out from under the walk;
    /// the tracer's `processWeak` inherited that discipline verbatim.
    pub fn beginDecrefPhase(self: *Registry, scratch: *ZeroRefScratch) void {
        std.debug.assert(self.phase == .none);
        std.debug.assert(self.zero_ref_scratch == null);
        scratch.* = .{};
        self.zero_ref_scratch = scratch;
        // .none -> .decref; teardown's .deinit phase cannot overlap this
        // batch (asserted above).
        self.phase = .decref;
    }

    pub fn endDecrefPhase(self: *Registry, rt: anytype, scratch: *ZeroRefScratch) void {
        std.debug.assert(self.phase == .decref);
        std.debug.assert(self.zero_ref_scratch == scratch);
        defer {
            self.zero_ref_scratch = null;
            self.phase = .none;
            scratch.deinit();
        }
        // Nothing is admitted to the scratch any more: every list kind is
        // tracer-owned. The phase bracket alone is what processWeak needs.
        std.debug.assert(scratch.next() == null);
        _ = rt;
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

    /// Is every live allocation resolvable, so that sweeping is sound?
    ///
    /// An arena that failed to register hides every object it holds from the
    /// conservative stack scan, so a sweep performed in that state can free a
    /// live object. Recovery is a re-walk of the slab's arena lists, which
    /// costs one pass over at most a few thousand pointers and only happens
    /// after an allocation failure. If it still cannot record them, the caller
    /// must mark without sweeping: a bounded leak instead of a use-after-free.
    pub fn addressSetWhole(self: *Registry, rt: anytype) bool {
        if (self.address_registry.arenasIncomplete()) {
            const slab = self.arena_slab orelse return false;
            if (!self.address_registry.resyncArenas(addressRegistryAllocator(), slab)) return false;
        }
        if (!self.address_registry.occupantsIncomplete()) return true;

        // A failed standalone insert is recoverable because liveness no longer
        // depends on the address index: list carriers and side-authoritative
        // Objects can replay every missing range before sweep. Keep the flag
        // sticky if any retry fails; the caller will mark without reclaiming.
        var live = self.objectIterator();
        while (live.next()) |header| {
            if (!header.metaConst().alloc_info.standalone) continue;
            if (self.address_registry.by_header.contains(@intFromPtr(header))) continue;
            const bytes = heapByteSizeFromHeader(rt, header);
            self.address_registry.insert(addressRegistryAllocator(), header, bytes) catch return false;
        }
        self.address_registry.setOccupantsIncomplete(false);
        return true;
    }

    pub fn verifyIntrusiveList(self: *Registry) InvariantError!void {
        try self.verifyAuxiliaryIntrusiveLists();
        _ = try verifyCircularHeaderList(&self.gc_obj_list, null, true);

        var saw_young_head = false;
        const sentinel = &self.gc_obj_list.sentinel;
        var current = sentinel.next_non_object;
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
            if (!isCycleCandidate(h) or h.metaConst().flags.kind == .object)
                return error.CorruptGcList;
            {
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
            }
            // No "mark bit left set" check here: sticky generations keep a
            // survivor's mark bit between collections as the record of "this
            // is old now" (§8.2), so a set mark outside a collection is normal.
            const next = h.nextNonObject() orelse return error.CorruptGcList;
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

        const nonblock_items = if (self.nonBlockObjectAuthority()) |authority|
            authority.items.items
        else
            &.{};
        for (nonblock_items, 0..) |header, index| {
            const meta = header.metaConst();
            if (meta.flags.kind != .object or isBlockCellHeader(header) or
                !meta.alloc_info.heap_accounted or meta.flags.cycle_visited)
            {
                return error.CorruptNonBlockObjectAuthority;
            }
            for (nonblock_items[0..index]) |previous_object| {
                if (previous_object == header) return error.CorruptNonBlockObjectAuthority;
            }
        }
    }

    fn verifyAuxiliaryIntrusiveLists(self: *Registry) InvariantError!void {
        _ = try verifyCircularHeaderList(&self.tmp_obj_list, null, false);
        var temporary_cursor = self.tmp_obj_list.sentinel.next_non_object;
        while (temporary_cursor) |header| {
            if (header == &self.tmp_obj_list.sentinel) break;
            if (header.metaConst().flags.kind == .object)
                return error.CorruptNonBlockObjectAuthority;
            temporary_cursor = header.nextNonObject();
        }

        var doomed_nodes: usize = 0;
        var cursor_found = self.doomed_cursor == null;
        for (&self.doomed_by_kind, 0..) |*head, kind_index| {
            const kind: GcKind = @enumFromInt(kind_index);
            if (kind == .object and !listEmpty(head))
                return error.CorruptNonBlockObjectAuthority;
            doomed_nodes += try verifyCircularHeaderList(head, kind, false);
            if (!cursor_found) {
                var node = head.sentinel.next_non_object;
                while (node) |candidate| {
                    if (candidate == &head.sentinel) break;
                    if (candidate == self.doomed_cursor.?) cursor_found = true;
                    node = candidate.nextNonObject();
                }
            }
        }
        if (!cursor_found) return error.DoomedCursorMismatch;

        if (self.nonBlockObjectAuthority()) |authority| {
            const live = authority.items.items;
            const doomed = authority.doomed.items;
            const temporary = authority.temporary.items;
            for (doomed, 0..) |header, index| {
                const meta = header.metaConst();
                if (meta.flags.kind != .object or isBlockCellHeader(header) or
                    !meta.alloc_info.heap_accounted or !meta.flags.cycle_visited)
                {
                    return error.CorruptNonBlockObjectAuthority;
                }
                for (live) |candidate| if (candidate == header)
                    return error.CorruptNonBlockObjectAuthority;
                for (doomed[0..index]) |candidate| if (candidate == header)
                    return error.CorruptNonBlockObjectAuthority;
                for (temporary) |candidate| if (candidate == header)
                    return error.CorruptNonBlockObjectAuthority;
            }
            for (temporary, 0..) |header, index| {
                const meta = header.metaConst();
                if (meta.flags.kind != .object or isBlockCellHeader(header) or
                    !meta.alloc_info.heap_accounted or !meta.flags.cycle_visited)
                {
                    return error.CorruptNonBlockObjectAuthority;
                }
                for (live) |candidate| if (candidate == header)
                    return error.CorruptNonBlockObjectAuthority;
                for (temporary[0..index]) |candidate| if (candidate == header)
                    return error.CorruptNonBlockObjectAuthority;
            }
        }

        var deferred_count: usize = 0;
        var slow = self.cycle_deferred_frees.head;
        var fast = self.cycle_deferred_frees.head;
        while (fast) |first| {
            fast = deferredNext(first);
            if (fast) |second| fast = deferredNext(second);
            if (slow) |node| slow = deferredNext(node);
            if (fast != null and fast == slow) return error.CorruptDeferredFreeStack;
        }
        var deferred = self.cycle_deferred_frees.head;
        while (deferred) |node| {
            if (!node.metaConst().flags.finalizing) return error.CorruptDeferredFreeStack;
            deferred_count += 1;
            deferred = deferredNext(node);
        }
        if (deferred_count != self.cycle_deferred_frees.count) {
            return error.CorruptDeferredFreeStack;
        }

        const block_doomed = if (comptime block_heap_enabled)
            self.block_heap.doomed_blocks != null
        else
            false;
        const temporary_objects = self.temporaryNonBlockObjectCount() != 0;
        if ((doomed_nodes != 0 or block_doomed or self.doomed_cursor != null or temporary_objects) and
            !self.doomed_pending and self.phase != .tracer_destroy)
        {
            return error.DoomedPendingMismatch;
        }
    }

    /// Check the reserved pin-ledger entries that protect detached generator
    /// shells. The sentinel must never bless a published, non-block, partially
    /// initialized, or wrong-class header as the BlockHeap publication
    /// exception.
    pub fn verifyConstructionRoots(self: *const Registry) InvariantError!void {
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
            const owner = object.Object.fromHeaderConst(header);
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
                if (kind != .object and !(string_tracer_owned and kind == .string))
                    return error.RepresentationAllocationCarrierMismatch;
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
        var live = self.objectIterator();
        while (live.next()) |header| {
            try self.verifyPublishedHeaderRepresentation(header, null);
        }
        for (&self.doomed_by_kind, 0..) |*head, kind_index| {
            const expected: GcKind = @enumFromInt(kind_index);
            var cursor = head.sentinel.next_non_object;
            while (cursor) |header| {
                if (header == &head.sentinel) break;
                try self.verifyPublishedHeaderRepresentation(header, expected);
                cursor = header.nextNonObject();
            }
        }
        if (self.nonBlockObjectAuthority()) |authority| {
            for (authority.doomed.items) |header| {
                try self.verifyPublishedHeaderRepresentation(header, .object);
            }
            for (authority.temporary.items) |header| {
                try self.verifyPublishedHeaderRepresentation(header, .object);
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
        if (comptime carrier.extent_identity_enabled) {
            self.memory.gc_extent_identity.verify() catch return error.CarrierOldNewMismatch;
        }
        if (comptime carrier.lifecycle_state_enabled) {
            self.memory.gc_extent_lifecycle.verify() catch return error.CarrierOldNewMismatch;
        }
        if (comptime block_heap_enabled and carrier.block_generation_enabled) {
            self.block_heap.verifyGenerationAuthority() catch return error.CarrierOldNewMismatch;
        }
        if (comptime block_heap_enabled and carrier.lifecycle_state_enabled) {
            self.block_heap.verifyLifecycleAuthority() catch return error.CarrierOldNewMismatch;
            self.block_heap.verifyAccountingCellsAllowing(
                representation.block_cell_size_class,
                @as(u3, @intCast(@intFromEnum(GcKind.object))),
                .{
                    .context = @ptrCast(self),
                    .classify = Registry.blockCellAccountingAllowance,
                },
            ) catch return error.MissingHeapAllocation;
        }

        var heap_live_bytes: usize = 0;
        var old_live_bytes: usize = 0;
        var large_object_bytes: usize = 0;

        var iterator = self.heapAccountingIterator();
        while (iterator.next()) |header| {
            if (!header.metaConst().alloc_info.heap_accounted) return error.MissingHeapAllocation;
            if (header.pinned() and self.pinEntryIndex(header) == null) {
                return error.PinnedHeaderMissingEntry;
            }
            const bytes = heapByteSizeFromHeader(rt, header);
            if (bytes == 0) return error.MissingHeapAllocation;
            const is_large = self.isLargeAllocation(bytes);
            if (header.metaConst().alloc_info.large != is_large) {
                return error.LargeObjectClassificationMismatch;
            }
            heap_live_bytes = std.math.add(usize, heap_live_bytes, bytes) catch std.math.maxInt(usize);
            if (is_large) {
                large_object_bytes = std.math.add(usize, large_object_bytes, bytes) catch std.math.maxInt(usize);
            } else {
                old_live_bytes = std.math.add(usize, old_live_bytes, bytes) catch std.math.maxInt(usize);
            }
            if (comptime heap_accounting_oracle_enabled) {
                const raw = self.heap_accounting_oracle.raw.get(@intFromPtr(header)) orelse
                    return error.CarrierRawOwnedMismatch;
                if (!raw.published) return error.CarrierOldNewMismatch;
                if (raw.accounted_bytes != bytes) return error.CarrierByteMismatch;
                if (comptime carrier.authority_audit_enabled) {
                    const handle = self.allocationHandle(header) orelse return error.CarrierOldNewMismatch;
                    const resolved = self.resolveExact(
                        handle,
                        header.metaConst().flags.kind,
                        CarrierStateMask.publishedOnly(),
                    ) catch return error.CarrierOldNewMismatch;
                    if (resolved.tracing != header) return error.CarrierOldNewMismatch;
                    if (raw.generation != handle.generation) return error.CarrierGenerationMismatch;
                }
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

        // The expected value is lifecycle-maintained, not another instance of
        // the ownership iterator above. An accounted header that loses every
        // owner container must therefore leave the walk short and fail here.
        if (comptime heap_accounting_oracle_enabled) {
            const oracle = &self.heap_accounting_oracle;
            if (heap_live_bytes != oracle.heap_live_bytes) return error.HeapLiveBytesMismatch;
            if (old_live_bytes != oracle.old_live_bytes) return error.OldLiveBytesMismatch;
            if (large_object_bytes != oracle.large_object_bytes) return error.LargeObjectBytesMismatch;

            if (comptime carrier.authority_audit_enabled) {
                // independent raw -> new owned authority
                var raw_it = oracle.raw.valueIterator();
                while (raw_it.next()) |raw| {
                    const handle = self.allocationHandle(@ptrFromInt(raw.base)) orelse
                        return error.CarrierRawOwnedMismatch;
                    if (handle.generation != raw.generation) return error.CarrierGenerationMismatch;
                    if (raw.published) {
                        _ = self.resolveExact(
                            handle,
                            null,
                            CarrierStateMask.publishedOnly(),
                        ) catch return error.CarrierOldNewMismatch;
                    }
                }
            }

            // new extent authority -> independent raw
            if (comptime carrier.extent_identity_enabled) {
                var extent_it = self.memory.gc_extent_identity.records.valueIterator();
                while (extent_it.next()) |record| {
                    const raw = oracle.raw.get(record.base) orelse return error.CarrierRawOwnedMismatch;
                    if (raw.generation != record.generation) return error.CarrierGenerationMismatch;
                    if (raw.raw_base != record.raw_base or raw.raw_bytes != record.raw_bytes) {
                        return error.CarrierByteMismatch;
                    }
                }
            }
            if (comptime carrier.lifecycle_state_enabled) {
                var lifecycle_it = self.memory.gc_extent_lifecycle.records.iterator();
                while (lifecycle_it.next()) |entry| {
                    const raw = oracle.raw.get(entry.key_ptr.*) orelse return error.CarrierRawOwnedMismatch;
                    if (raw.published and raw.accounted_bytes != entry.value_ptr.accounted_bytes) {
                        return error.CarrierByteMismatch;
                    }
                }
            }

            const BlockAudit = struct {
                oracle: *const HeapAccountingOracle,
                mismatch: ?InvariantError = null,
                fn visit(raw_context: *anyopaque, handle: AllocationHandle, _: CarrierLifecycleState) void {
                    const audit: *@This() = @ptrCast(@alignCast(raw_context));
                    const raw = audit.oracle.raw.get(handle.base) orelse {
                        audit.mismatch = error.CarrierRawOwnedMismatch;
                        return;
                    };
                    if (raw.generation != handle.generation) audit.mismatch = error.CarrierGenerationMismatch;
                }
            };
            if (comptime carrier.block_generation_enabled and carrier.lifecycle_state_enabled) {
                var block_audit: BlockAudit = .{ .oracle = oracle };
                self.block_heap.forEachOwnedIdentity(metadata_prefix_size, &block_audit, BlockAudit.visit);
                if (block_audit.mismatch) |err| return err;
            }
        }
        const accounted_external_bytes = std.math.add(usize, external_token_bytes, self.stats.external_untracked_bytes) catch std.math.maxInt(usize);
        if (accounted_external_bytes != self.stats.external_bytes) return error.ExternalTokenBytesMismatch;
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

    pub inline fn nonBlockObjectCount(self: *const Registry) usize {
        const authority = self.nonBlockObjectAuthority() orelse return 0;
        return authority.items.items.len;
    }

    pub inline fn nonBlockObjectAt(self: *const Registry, index: usize) *GCObjectHeader {
        return self.nonBlockObjectAuthority().?.items.items[index];
    }

    pub fn nonBlockObjectAuthorityCountForTest(self: *const Registry) usize {
        return self.nonBlockObjectCount();
    }

    pub fn nonBlockObjectAuthorityContainsForTest(
        self: *const Registry,
        header: *const GCObjectHeader,
    ) bool {
        const authority = self.nonBlockObjectAuthority() orelse return false;
        return authority.indexOf(header) != null;
    }

    inline fn nonBlockObjectAuthority(self: *const Registry) ?*NonBlockObjectAuthority {
        const context = self.address_registry.nonblock_objects orelse return null;
        return @ptrCast(@alignCast(context));
    }

    pub fn containsHeader(self: *const Registry, header: *const GCObjectHeader) bool {
        if (self.sweep_current == header) return true;
        if (self.condemnedNonBlockObjectContains(header)) return true;
        // Condemned-but-not-yet-destroyed nodes remain runtime-owned with
        // resources intact.
        var condemned = self.tmp_obj_list.sentinel.next_non_object;
        while (condemned) |candidate| {
            if (candidate == &self.tmp_obj_list.sentinel) break;
            if (candidate == header) return true;
            condemned = candidate.nextNonObject();
        }
        var iterator = self.objectIterator();
        while (iterator.next()) |candidate| {
            if (candidate == header) return true;
        }
        return false;
    }

    /// Resolve only whether this exact address is a member of the current v1
    /// block/address index.  The key intentionally carries neither generation
    /// nor lifecycle state: it promises no ABA or state-mask protection and
    /// may return NotFound while the cold address index is incomplete.
    pub fn resolveCurrentMember(
        self: *const Registry,
        key: CurrentMembershipKey,
        expected_kind: ?GcKind,
    ) CarrierResolveError!ResolvedCurrentMember {
        const header: *GCObjectHeader = @ptrFromInt(key.base);
        if (!self.address_registry.containsHeader(header)) return error.NotFound;
        const kind = header.metaConst().flags.kind;
        if (expected_kind) |expected| if (kind != expected) return error.KindMismatch;
        return .{ .tracing = header };
    }

    /// Mint a generation-bearing handle (audit builds only: the carrier
    /// authorities behind it exist nowhere else).
    pub fn allocationHandle(self: *const Registry, header: *const GCObjectHeader) ?AllocationHandle {
        comptime std.debug.assert(carrier.authority_audit_enabled);
        return self.memory.carrierGenerationHandle(@intFromPtr(header));
    }

    /// Generation/state exact resolution (audit builds only).
    pub fn resolveExact(
        self: *const Registry,
        handle: AllocationHandle,
        expected_kind: ?GcKind,
        allowed_states: CarrierStateMask,
    ) CarrierResolveError!ResolvedExact {
        comptime std.debug.assert(carrier.authority_audit_enabled);
        if (comptime block_heap_enabled) {
            if (self.block_heap.blockOf(@ptrFromInt(handle.base -| metadata_prefix_size)) != null) {
                const resolved = try self.block_heap.resolveExactHandle(
                    handle,
                    metadata_prefix_size,
                    allowed_states,
                    false,
                );
                if (resolved.generation != handle.generation) {
                    @panic("gc: CARRIER IDENTITY: stale generation accepted");
                }
                const header: *GCObjectHeader = @ptrFromInt(handle.base);
                const kind = header.metaConst().flags.kind;
                // Block cells hold Objects, and string bodies once TGC S2 is on.
                if (kind != .object and !(string_tracer_owned and kind == .string)) return error.HeaderMismatch;
                if (expected_kind) |expected| if (kind != expected) return error.KindMismatch;
                if (resolved.state == .published and !header.metaConst().alloc_info.heap_accounted) {
                    return error.HeaderMismatch;
                }
                return .{ .tracing = header };
            }
        }

        const record = try self.memory.gc_extent_identity.resolve(
            handle,
            if (expected_kind) |kind| @intFromEnum(kind) else null,
        );
        const lifecycle = try self.memory.gc_extent_lifecycle.resolve(handle.base, allowed_states);
        const header: *GCObjectHeader = @ptrFromInt(handle.base);
        const kind = header.metaConst().flags.kind;
        if (@intFromEnum(kind) != record.kind) return error.HeaderMismatch;
        if (lifecycle.state == .published and !header.metaConst().alloc_info.heap_accounted) {
            return error.HeaderMismatch;
        }
        return .{ .tracing = header };
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
    if (refCountRemoved(header.meta().flags.kind)) return;
    if (decrementHeaderRefCount(header) == 0) destroyZeroRef(rt, header);
}

/// Slow path after the caller has already decremented the common RC word to 0.
/// JSValue.free uses this after its QuickJS-style payload-4 fast path; direct
/// GC owners also arrive here through `release` above.
pub noinline fn destroyZeroRef(rt: anytype, header: *Header) align(32) void {
    std.debug.assert(headerRefCount(header) == 0);
    const kind = header.metaConst().flags.kind;
    if (rt.gc.phase == .deinit and Registry.isCycleCandidate(header)) return;
    if (header.metaConst().flags.finalizing or header.metaConst().flags.cycle_visited) return;

    // Every list kind is tracer-owned and has no RC transition; only the
    // string family (S2) still reaches a zero-ref destroy, through its own
    // StringHeader path, never through here.
    std.debug.assert(refCountRemoved(kind));
}

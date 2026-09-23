//! Z-GE (Garbage Engine) Core Implementation
//! Governing Layer: third_party/zjs/src/core/gc.zig
//! Following Z-GE Architecture Contract v1.0

const mem_ops = @import("memory.zig");
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
const value_format = @import("value_format.zig");

const KB: usize = 1024;
const MB: usize = 1024 * KB;

const gc_storage = @import("gc_storage.zig");
const heap_budget = @import("heap_budget.zig");
pub const gc_weak = @import("gc_weak.zig");
const BlockHeapMod = @import("gc_block_heap.zig");
const gc_space = @import("gc_space.zig");

const AddressRegistryTable = @import("gc_address_registry.zig").Table;

const SpaceHistogram = @import("gc_space.zig").Histogram;

pub const AllocationHandle = carrier.AllocationHandle;
pub const CurrentMembershipKey = carrier.CurrentMembershipKey;
pub const CarrierStateMask = carrier.StateMask;
pub const carrier_state_masks = carrier.state_masks;
pub const CarrierLifecycleState = carrier.LifecycleState;
pub const CarrierResolveError = carrier.ResolveError;
pub const carrier_audit_enabled = carrier.audit_enabled;
pub const ResolvedExact = union(enum) {
    tracing: *Header,
};
pub const ResolvedCurrentMember = union(enum) {
    tracing: *Header,
};

/// Defect forensics. A missing root or a missing write barrier is only
/// observable when a collection lands inside the exact window the reference is
/// unreachable from the trace. At the production cadence that window is hit by
/// accident, so the same binary passes or fails depending on allocation
/// history, and adding a `print` to find out where moves the collection and the
/// failure disappears. These three widen the window and then check the verdict.
///
/// Read once at `Registry.init` rather than at each check: the minor path is
/// exactly where a `getenv` per collection is the probe that hides the bug --
/// regexp performs 794 minors in a two-second script.
pub const Forensics = struct {
    /// How loud a check is when it fires.
    pub const Level = enum {
        off,
        /// Print and keep going, so a latent site surfaces in the suite
        /// output without turning every unrelated test in the binary red.
        report,
        /// Panic on the first hit, so a gate running the suite turns red.
        fatal,

        pub fn enabled(self: Level) bool {
            return self != .off;
        }
    };

    /// `ZJS_GC_STRESS`: collect at every safepoint that has anything young
    /// instead of waiting for the young threshold, and shorten the safepoint
    /// cadence itself (`JSContext.pollInterruptSlow`) to this many interpreter
    /// ticks. `=1` takes the 64-tick default, which is thorough and roughly
    /// two orders of magnitude slower than the production 10_000; `=<n>` for
    /// n > 1 sets the cadence directly, which is how a full test262 sweep
    /// stays affordable.
    stress_cadence: ?i32 = null,

    /// `ZJS_GC_AUDIT`: report edges that should not exist -- a live object
    /// still holding an edge into the minor's condemned set, an unbarriered
    /// store that left an old unremembered owner holding a young child, or a
    /// holder edge naming an atom entry the sweep already retired.
    ///
    /// Cheap, and correspondingly partial: it asks "does some live object
    /// still name this?", which finds a missing barrier only when the owner
    /// is itself reachable AND the edge is one `traceChildEdges` enumerates.
    audit: Level = .off,

    /// `ZJS_GC_VERIFY`: check what a collection is about to condemn against
    /// what a full trace from freshly cleared marks would keep -- every minor
    /// in `collectMinor`, every incremental finish in `finishIncrementalCycle`.
    ///
    /// This asks the question the collector is really answering, "is this
    /// garbage?", so unlike `audit` it is not blind to references the tracer
    /// does not know about at all. Only PRECISE disagreements are violations:
    /// the verifier's probe runs on a deeper native frame than the collection
    /// it checks, so register and stack residue differ between the two
    /// conservative scans by construction, and a `test-gc-stress` run reports
    /// ~1000 such expected hits against zero precise ones. Conservative-only
    /// hits are therefore counted and never printed.
    verify: Level = .off,

    fn read(name: [*:0]const u8) ?Level {
        const raw = std.c.getenv(name) orelse return null;
        const text = std.mem.span(raw);
        if (text.len == 0 or std.mem.eql(u8, text, "0")) return .off;
        if (std.mem.eql(u8, text, "fatal")) return .fatal;
        return .report;
    }

    fn readFromEnv(self: *Forensics) void {
        if (comptime std.debug.runtime_safety) {
            if (read("ZJS_GC_AUDIT")) |level| self.audit = level;
            if (read("ZJS_GC_VERIFY")) |level| self.verify = level;
        }

        const raw = std.c.getenv("ZJS_GC_STRESS") orelse return;
        const text = std.mem.span(raw);
        if (text.len == 0 or std.mem.eql(u8, text, "0")) return;
        const parsed = value_format.parseAsciiInt(i32, text, 10) catch 1;
        self.stress_cadence = if (parsed > 1) parsed else 64;
    }

    /// Stress is available everywhere: the release binary is what a full
    /// test262 stress sweep runs.
    pub fn stressing(self: Forensics) bool {
        return self.stress_cadence != null;
    }

    /// The two checking arms are safety-build machinery -- each walks the
    /// whole heap per collection and reports through `std.debug.print` -- so
    /// a shipped ReleaseFast binary carries neither the walk nor its
    /// reporting. Reading the fields through these is what erases them.
    pub inline fn auditing(self: Forensics) bool {
        if (comptime !std.debug.runtime_safety) return false;
        return self.audit.enabled();
    }

    pub inline fn auditIsFatal(self: Forensics) bool {
        if (comptime !std.debug.runtime_safety) return false;
        return self.audit == .fatal;
    }

    pub inline fn verifying(self: Forensics) bool {
        if (comptime !std.debug.runtime_safety) return false;
        return self.verify.enabled();
    }

    pub inline fn verifyIsFatal(self: Forensics) bool {
        if (comptime !std.debug.runtime_safety) return false;
        return self.verify == .fatal;
    }
};

pub var forensics: Forensics = .{};

/// Sites of stores that static reading found unbarriered. `auditUnbarrieredStore`
/// counts, per site, the state the generational barrier exists to prevent --
/// an old, unremembered, published owner gaining a young child.
pub const UnbarrieredStoreSite = enum(u8) {
    set_property_data_overwrite,
    dense_array_in_capacity_append,
    global_lexical_cell_replace,
};

/// Whole-heap invariant walks belong to safety builds. No allocation, mark or
/// free hot path calls one, and the shipped ReleaseFast binary carries none.
pub inline fn invariantChecksEnabled() bool {
    return std.debug.runtime_safety;
}

/// Incremental-major barrier state and stats (§8.4). Marking is driven to
/// completion on the owner thread; a future parallel marker would arrive
/// separately.
pub const incremental = @import("gc_incremental.zig");
/// Unbounded segmented private/shared mark frontier (§8.4).
pub const registry_pins = @import("gc_registry_pins.zig");
pub const registry_scheduler = @import("gc_registry_scheduler.zig");
pub const registry_lists = @import("gc_registry_lists.zig");
pub const registry_heap = @import("gc_registry_heap.zig");
pub const registry_diagnostics = @import("gc_registry_diagnostics.zig");

/// `detailed_reports` and the stats sinks live with the collector; the
/// barrier only reads them. Mutual import with `gc_trace_stw.zig` is fine --
/// Zig resolves lazily.
const gc_trace_stw_reports = @import("gc_trace_stw.zig");
const JSRuntime = @import("../runtime.zig").JSRuntime;
pub const generation = @import("gc_generation.zig");
pub const nursery_mod = @import("gc_nursery.zig");

/// Migration switch for the copying young generation. While it is false the
/// nursery is never allocated from and every carrier fork keeps its old
/// shape; the collector's young path is unchanged. Delete it once the
/// bump-allocated young generation is the only one.
pub var nursery_enabled: bool = false;
const IncrementalState = incremental.State;

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

/// TGC S4-f (2): superblocks a minor's hot-block publication slice visits
/// (`Heap.publishCompletedHotBlocksSlice`). Eight 2 MiB superblocks is at most
/// 256 block headers, i.e. a bounded tens-of-microseconds addition to a pause
/// whose measured p50 is already hundreds of microseconds -- and it makes the
/// whole superblock array's coverage period `ceil(superblocks / 8)` minors,
/// which on every workload measured is one to two dozen.
///
/// A whole-heap walk per minor was the alternative and is what this constant
/// exists to refuse: earley-boyer runs 9k-13k minors over ~3.5k populated
/// blocks, so the unbounded form is a 50M-block-visit tax on the one path that
/// must stay short.
pub const minor_hot_publish_superblock_budget: usize = 8;

/// The young set a crossed whole-heap threshold needs before a minor is run
/// ahead of the major (`Registry.shouldTryMinorBeforeMajor`).
///
/// Lower than `minor_young_threshold` because the crossing minor's alternative
/// is a whole-heap trace, not idleness, so it pays for itself at a far smaller
/// young set. pdfjs crosses at ~10k young objects and so never cleared the 16k
/// bar at all.
///
/// Not ZERO, which is where TGC S2-g's first landing put it, and which broke
/// earley-boyer: a crossing arriving just after an ordinary minor found a
/// young set of a few dozen live objects, reclaimed none of them, and three
/// such probes in a row tripped `low_yield_limit`. Suspension then withheld
/// the ORDINARY minors too -- the ones holding the young set down -- so it grew
/// to 10.9M objects, the account to 910MB against a 5.6MB live set, and the 2x
/// threshold rule compounded the rest: maxrss 81MB -> 2.6GB, wall 22.8s ->
/// 26.1s. A degenerate probe must not get a vote in a measurement about
/// whether this workload's young objects die.
///
/// Frozen at 1k on that pair (ReleaseFast, fixed work, CPU19). earley-boyer is
/// at parity with the pre-S2-g scheduler at every value tried; pdfjs pays for
/// a higher floor in majors: 1k -> 24 majors / 4.63s / 145MB, 4k -> 281 / 5.25s
/// / 123MB, 16k (i.e. no separate floor) -> 904 / 6.7s / 111MB.
pub const minor_crossing_young_floor: usize = minor_young_threshold / 16;

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
    minor_young_threshold * 96;

const GenerationState = @import("gc_generation.zig").State;
const PinLedger = registry_pins.Ledger;
const Scheduler = registry_scheduler.Scheduler;
const Lists = registry_lists.Lists;
const Marking = incremental.Marking;
const Morgue = incremental.Morgue;
const ExternalTokens = registry_heap.Tokens;
const NonBlockObjectAuthority = registry_heap.NonBlockObjectAuthority;

/// Independent byte oracle for tests and explicit ownership-audit builds.
///
/// The public counters are a cold ownership census. An audit cannot use that
/// same census as its expected value: losing the only owner link would hide a
/// still-accounted allocation from both sides. This shadow follows lifecycle
/// publication/free events instead, and is entirely absent from shipped
/// ReleaseFast builds.
pub const HeapAccountingOracle = if (carrier_audit_enabled)
    carrier.HeapAccountingOracle
else
    void;

const BlockHeap = @import("gc_block_heap.zig").Heap;

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
/// 4-bit tag packed into the low nibble of the shared kind/flags byte of
/// `Metadata` (qjs `JSMallocBlockHeader.gc_obj_type: 7`, quickjs.c).
/// It was three bits until TGC S4-a, which spent the retired `mark` bit on
/// the fourth: eight values were full, and S4 needs four more kinds.
///
/// Value order is load-bearing for codegen, mirroring qjs's
/// `JS_GC_OBJ_TYPE_JS_OBJECT == 0`: the hot `kind ==.object`
/// guards compile to a single `tst` of the masked byte, and the recurring
/// encoded kind checks stay compact. Values 0..7 are unchanged, so every
/// bare kind tag byte a raw prefix writer stores keeps its old encoding.
pub const RefKind = enum(u4) {
    object = 0,
    function_bytecode = 1,
    var_ref = 2,
    realm_context = 3,
    module = 4,
    shape = 5,
    string = 6,
    big_int = 7,
    /// TGC S4-b: an object's external property-entry buffer as a GC cell.
    /// Declared here so the header encoding, the catalog and the snapshot
    /// are settled in one batch; nothing allocates it until S4-b.
    property_storage = 8,
    /// TGC S4-b: an array/arguments element buffer as a GC cell.
    array_storage = 9,
    /// TGC S4-c: an a-class class payload as a GC cell.
    payload = 10,
    /// TGC S4-a (D-S4-1): rope nodes were discriminated from flat string
    /// bodies by borrowing the prefix `mark` bit (S2). They are a kind of
    /// their own now, which is what freed that bit -- `traceHeaderEdges`
    /// dispatches the two string-family shapes directly instead of
    /// re-reading the prefix inside `traceStringEdges`.
    rope = 11,
    /// TGC S2-i: the extensible tail buffer behind a rope's dependent views
    /// (`string.StringBuffer`). A bare byte carrier: no out-edges, no
    /// destructor, marked only by the `storageCell` edge of every rope node
    /// that reads it. Unlike a flat body or rope node, a buffer is not a
    /// shape that a string JSValue can name; only rope nodes reference it.
    string_buffer = 12,
};

/// Kinds whose carrier may be a collector block cell. Mirrors the catalog's
/// `.block_slab_or_standalone`, spelled as a predicate for the hot cell
/// guards that must not index the catalog.
pub inline fn kindIsBlockCellKind(kind: RefKind) bool {
    return switch (kind) {
        .object, .string, .rope, .string_buffer, .property_storage, .array_storage, .payload => true,
        .function_bytecode, .var_ref, .realm_context, .module, .shape, .big_int => false,
    };
}

/// Carriers whose body starts AT the collector handle behind an eight-byte
/// `Metadata` prefix and therefore own no `TraceHeader` link word: the string
/// family, the S2-i tail buffer and the S4-b storage kinds. Publication may
/// not link them onto `lists.objects`, the young suffix may not anchor on one,
/// and their standalone form is a block-heap EXTENT rather than a slab
/// allocation. Carrier checks use this broader set rather than only the
/// flat body and rope node shapes that a string JSValue can name.
pub inline fn kindIsPrefixCarrier(kind: RefKind) bool {
    return switch (kind) {
        .string, .rope, .string_buffer, .property_storage, .array_storage, .payload => true,
        .object, .function_bytecode, .var_ref, .realm_context, .module, .shape, .big_int => false,
    };
}

/// Storage cells whose life is decided entirely by ONE owner: an object's
/// external property buffer, an array/arguments element buffer, an a-class
/// payload and a rope's tail buffer. They have no independent reachability --
/// no root names them, no second object may hold them -- so they are not an
/// independent young POPULATION either, and counting them towards the minor
/// TRIGGER prices the owner's growth as if it were new garbage.
///
/// S4-b/c/S2-i moved all four into the block heap and regexp's minor count
/// went 641 -> 913 with an unchanged live set: the extra 272 minors were
/// bought entirely by property/array/payload/tail-buffer publications, each of
/// which a minor can only reclaim by tracing its owner anyway.
///
/// They stay in `young_count` (the census `verifyGenerationInvariants` checks
/// and the young list/extent walks enumerate); only
/// `Stats.young_trigger_count` excludes them.
pub inline fn kindIsOwnedStorageCell(kind: RefKind) bool {
    return switch (kind) {
        .property_storage, .array_storage, .payload, .string_buffer => true,
        .string, .rope, .object, .function_bytecode, .var_ref, .realm_context, .module, .shape, .big_int => false,
    };
}

/// Prefix carriers that can exceed the block-cell ceiling and therefore take
/// the extent route (`memory.createExtent`): their mark, their finalizer
/// column and their sweep live in the block heap's extent tables rather than
/// in a block bitmap. Rope nodes are fixed-size and always fit a cell, so
/// they are excluded -- the exclusion is what lets the extent arms stay a
/// single equality test in the hot mark probes.
inline fn kindIsExtentCapable(kind: RefKind) bool {
    return switch (kind) {
        .string, .string_buffer, .property_storage, .array_storage, .payload => true,
        .rope, .object, .function_bytecode, .var_ref, .realm_context, .module, .shape, .big_int => false,
    };
}

/// Legal allocation carriers for a kind.  Only plain objects may enter the
/// collector block heap; every other Metadata kind is slab/standalone, while
/// strings use their dedicated prefixed allocation family.
pub const AllocationCarrier = enum(u8) {
    block_slab_or_standalone,
    slab_or_standalone,
};

pub const RepresentationKindDescriptor = struct {
    kind: RefKind,
    allocation: AllocationCarrier,
};

pub const representation_kind_catalog = [_]RepresentationKindDescriptor{
    .{ .kind = .object, .allocation = .block_slab_or_standalone },
    .{ .kind = .function_bytecode, .allocation = .slab_or_standalone },
    .{ .kind = .var_ref, .allocation = .slab_or_standalone },
    .{ .kind = .realm_context, .allocation = .slab_or_standalone },
    .{ .kind = .module, .allocation = .slab_or_standalone },
    .{ .kind = .shape, .allocation = .slab_or_standalone },
    .{ .kind = .string, .allocation = .block_slab_or_standalone },
    .{ .kind = .big_int, .allocation = .slab_or_standalone },
    .{ .kind = .property_storage, .allocation = .block_slab_or_standalone },
    .{ .kind = .array_storage, .allocation = .block_slab_or_standalone },
    .{ .kind = .payload, .allocation = .block_slab_or_standalone },
    .{ .kind = .rope, .allocation = .block_slab_or_standalone },
    .{ .kind = .string_buffer, .allocation = .block_slab_or_standalone },
};

pub inline fn representationKindDescriptor(kind: RefKind) *const RepresentationKindDescriptor {
    return &representation_kind_catalog[@intFromEnum(kind)];
}

comptime {
    const tags = std.meta.tags(RefKind);
    std.debug.assert(@intFromEnum(RefKind.object) == representation.object_kind_tag);
    std.debug.assert(representation_kind_catalog.len == tags.len);
    for (representation_kind_catalog, 0..) |descriptor, index| {
        std.debug.assert(@intFromEnum(descriptor.kind) == index);
        std.debug.assert((descriptor.allocation == .block_slab_or_standalone) ==
            kindIsBlockCellKind(descriptor.kind));
    }
}

pub const GcKind = RefKind;

pub const gc_kind_count: usize = @typeInfo(GcKind).@"enum".fields.len;

pub const Phase = enum(u8) {
    none,
    /// The tracer is running a destruction slice. It used to share this role
    /// with refcounting's `.remove_cycles`, and a single value forced every
    /// site to serve both -- visibly so in `Object.destroyFromHeader`, whose
    /// fast arm excluded `.remove_cycles` for reasons belonging to rc's
    /// collector, which meant the tracing build never once used its own fast
    /// teardown. `.remove_cycles` retired with that collector.
    tracer_destroy,
    deinit,
};

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

/// A latched major-collection request; absent (null) when none is pending.
pub const Request = struct {
    reason: RequestReason,
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

/// Reserved pin count for a fully initialized but unpublished generator
/// shell. Host pins are positive reference counts and can never reach this
/// value; the discriminator adds no field or padding to the existing ledger.
pub const construction_pin_count = std.math.maxInt(usize);

pub fn ratioPerMille(numerator: usize, denominator: usize) usize {
    if (denominator == 0) return 0;
    const scaled = std.math.mul(usize, numerator, 1000) catch std.math.maxInt(usize);
    return @min(@as(usize, 1000), scaled / denominator);
}

/// Byte 3 of the metadata prefix: the GC kind and the GC lifecycle bits share
/// one byte, mirroring qjs `JSMallocBlockHeader` byte 3 = `gc_obj_type : 7 |
/// mark: 1`. zjs needs cycle/lifecycle bits qjs carries in
/// its wider 4-bit `mark` value ranges and list membership, so the kind is
/// four bits and the flags take the remaining four.
///
/// TGC S4-a: the kind grew from three bits into the retired `mark` bit
/// (bit 3). Every other flag keeps its historical bit position, so the raw
/// prefix writers in `memory.zig`, the free-cell poison and
/// `metadata_young_mask` are all byte-identical to before.
pub const BlockFlags = packed struct(u8) {
    /// GC kind tag (qjs `gc_obj_type`). Bits 0-3.
    kind: GcKind = .object,
    /// Padding: former `in_cycle_list`. Membership is the cyclic list itself
    /// (qjs `list_add_tail` / `list_del`, quickjs.c). Kept so
    /// `finalizing` / the spare bit stay at their historical bit positions
    /// — `memory.zig` writes this flags byte by layout.
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
    /// TGC S4-a/S4-e: this carrier's death owes a destructor call (an external
    /// resource, a weak identity, a cursor, a borrowed holder, an atom
    /// binding). S4-d's sweep visits `doomed & needs_finalizer` only; every
    /// other corpse is reclaimed by clearing its allocation bit without the
    /// header ever being read. Block cells carry the same fact in
    /// `Block.finalizerBits` so the sweep can scan a whole block without
    /// touching a single header.
    ///
    /// S4-a parked it in the lifetime tail because the flags byte had no spare
    /// while `is_pinned` lived here; S4-e retired `is_pinned` (the pin ledger
    /// `pins.entries` was always the authority) and the bit moved into the
    /// vacated position, which is spec 2.1's terminal layout.
    ///
    /// D-S4-4: set-only. Cleared only when the cell itself is released.
    needs_finalizer: bool = false,
    /// TGC S4-h: spare. `cycle_visited` retired into the lifetime word --
    /// condemnation is now the reserved mark epoch `condemned_mark_epoch`
    /// (see `headerCondemned`), which is the same fact in the field that
    /// already answers "is this header marked" and is therefore free.
    ///
    /// The free-cell poison still sets this bit (`free_cell_poison` byte 3 =
    /// 0x86); it is inert there, and what rejects a free cell read as a
    /// header is `heap_accounted == 0` plus the condemnation stamp the cell
    /// carried into the free list.
    reserved: bool = false,
};

/// Byte 2 of the metadata prefix = the allocator's `block_size_idx` byte (qjs
/// `JSMallocBlockHeader.block_size_idx`, quickjs.c), now stamped for GC
/// allocations too, plus two zjs state bits in the unused high bits
/// (slab classes only need 5 bits; qjs marks its large blocks via
/// `u.block_idx == FREE_NIL` instead, but zjs stores encoded heap bytes in
/// that u16 for standalone prefixes, so the discriminator lives here).
pub const AllocInfo = packed struct(u8) {
    /// Slab size-class index of the owning block. Valid iff `!standalone`;
    /// free paths read it back instead of re-deriving the class from the byte
    /// size (qjs `__js_free`, quickjs.c).
    block_size_idx: u5 = 0,
    /// Bump-allocated young cell: no block, no allocation bitmap, no
    /// individual free. It cannot be spelled in `block_size_idx` -- the slab's
    /// 31 classes and the block-cell discriminator fill all 32 values -- so it
    /// takes the byte's one spare bit.
    nursery: bool = false,
    /// The allocation has been published to the live heap. Kept separate from
    /// size_class because slab-overlaid metadata reserves that field.
    heap_accounted: bool = false,
    /// The metadata is a dedicated prefix ahead of the object (slab-ineligible
    /// or over-aligned allocation); `size_class` then holds encoded heap bytes.
    /// When false the metadata occupies the small-object slab's allocator
    /// header and `size_class` is the allocator's block index.
    standalone: bool = false,
};

/// Tracer-owned lifetime state in the tail of Metadata. Epoch 0 is reserved
/// for newborn/unmarked; the Registry epoch starts at 1.
/// TGC S4-e: the lifetime tail's flag byte is empty. `husk` retired with the
/// weak husk and `needs_finalizer` moved into `BlockFlags` when `is_pinned`
/// vacated its bit; the byte stays as reserved padding so `TraceHeaderState`
/// keeps its four-byte extern layout and every "reserved must be zero" header
/// check keeps a field to read.
pub const TraceHeaderFlags = packed struct(u8) {
    reserved: u8 = 0,
};

/// Offset-6 byte ownership under trace_stw. Object's Shape projection owns the
/// low seven bits; the generational barrier owns the high remembered bit. Keep
/// these masks in gc.zig so header-only barrier code need not import Object.
pub const trace_object_shape_summary_mask: u8 = 0b0111_1111;
pub const trace_remembered_mask: u8 = 0b1000_0000;

pub const TraceHeaderState = extern struct {
    mark_epoch: u16 = 0,
    /// Shared Object byte: low seven bits are the Shape trace projection; bit7
    /// is remembered-set membership. A native byte keeps both hot reads at a
    /// fixed offset. Object owns the summary encoding/mutation audit;
    /// gc_generation owns remembered. Non-Object carriers keep the LOW SEVEN
    /// bits zero -- the Shape projection is Object-only -- but every kind may
    /// carry bit7 (audit §10).
    object_shape_summary: u8 = 0,
    flags: TraceHeaderFlags = .{},
};

/// qjs-style block-prefix metadata. The allocator-owned first four bytes keep
/// the JSMallocBlockHeader ABI. The tail stores the mark epoch and the
/// finalizer-debt bit.
/// For slab-backed objects these 8 bytes ARE the allocator block header;
/// persistent/over-aligned objects keep a standalone prefix.
pub const Metadata = extern struct {
    /// Standalone prefix: encoded heap bytes. Slab overlay: allocator block
    /// index (or free-list link while free). Check alloc_info.standalone before
    /// interpreting this field as a heap size.
    size_class: u16 align(8) = 0,
    alloc_info: AllocInfo = .{},
    flags: BlockFlags = .{},
    lifetime: TraceHeaderState = .{},
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
    std.debug.assert(@offsetOf(Metadata, "lifetime") == representation.metadata_lifetime_offset);
    std.debug.assert(@sizeOf(TraceHeaderState) == 4);
    std.debug.assert(@sizeOf(TraceHeaderFlags) == 1);
    std.debug.assert(@offsetOf(TraceHeaderState, "mark_epoch") == 0);
    std.debug.assert(@offsetOf(TraceHeaderState, "object_shape_summary") == 2);
    std.debug.assert(@offsetOf(TraceHeaderState, "flags") == 3);
    std.debug.assert(trace_object_shape_summary_mask | trace_remembered_mask == std.math.maxInt(u8));
    std.debug.assert(trace_object_shape_summary_mask & trace_remembered_mask == 0);
    std.debug.assert(@as(u8, @bitCast(AllocInfo{ .standalone = true })) == representation.alloc_info_standalone_mask);
    std.debug.assert(@as(u8, @bitCast(AllocInfo{ .heap_accounted = true })) == representation.alloc_info_heap_accounted_mask);
    std.debug.assert(@as(u8, @bitCast(AllocInfo{ .block_size_idx = representation.block_cell_size_class })) == representation.block_cell_alloc_info);
    // Kind occupies the low 3 bits of the shared kind/flags byte; a bare tag
    // byte (all flags clear) equals the enum value, which is what the raw
    // prefix writers in memory.zig and object.zig store.
    std.debug.assert(@as(u8, @bitCast(BlockFlags{ .kind = .big_int })) == @intFromEnum(GcKind.big_int));
    std.debug.assert(@as(u8, @bitCast(BlockFlags{ .kind = .rope })) == @intFromEnum(GcKind.rope));
    std.debug.assert(@as(u8, @bitCast(BlockFlags{ .kind = .object, .young = true })) == representation.metadata_young_mask);
    std.debug.assert(@as(u8, @bitCast(BlockFlags{ .kind = .object, .finalizing = true })) == 1 << 5);
    std.debug.assert(@as(u8, @bitCast(BlockFlags{ .kind = .object, .needs_finalizer = true })) == 1 << 6);
    std.debug.assert(@as(u8, @bitCast(BlockFlags{ .kind = .object, .reserved = true })) == 1 << 7);
    // The kind occupies the low nibble; the raw readers mask with it.
    std.debug.assert(@bitSizeOf(GcKind) == 4);
    std.debug.assert(@as(u8, std.math.maxInt(std.meta.Tag(GcKind))) == representation.kind_mask);
    // The contiguous kind ranges documented on RefKind.
    std.debug.assert(@intFromEnum(GcKind.object) == 0);
    std.debug.assert(@intFromEnum(GcKind.module) == 4 and @intFromEnum(GcKind.shape) == 5);
    std.debug.assert(@intFromEnum(GcKind.string) == 6 and @intFromEnum(GcKind.big_int) == 7);
    std.debug.assert(@intFromEnum(GcKind.property_storage) == 8 and @intFromEnum(GcKind.array_storage) == 9);
    std.debug.assert(@intFromEnum(GcKind.payload) == 10 and @intFromEnum(GcKind.rope) == 11);
    std.debug.assert(@intFromEnum(GcKind.rope) == representation.rope_kind_tag);
    std.debug.assert(@intFromEnum(GcKind.string_buffer) == representation.string_buffer_kind_tag);
    std.debug.assert(@intFromEnum(GcKind.property_storage) == representation.property_storage_kind_tag);
    std.debug.assert(@intFromEnum(GcKind.array_storage) == representation.array_storage_kind_tag);
    std.debug.assert(@intFromEnum(GcKind.payload) == representation.payload_kind_tag);
}

/// The two owner facts that let a generational write barrier do nothing, as
/// bit positions inside the eight-byte `Metadata` prefix read as one word.
///
///   * `flags.young` (byte 3): a minor traces the whole reachable young set,
///     so an old-to-young edge out of a young owner needs no record.
///   * `lifetime.object_shape_summary` bit7 (byte 6): the remembered-set
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
    probe.lifetime.object_shape_summary = trace_remembered_mask;
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

    inline fn setNextNonObject(self: *TraceHeader, next: ?*TraceHeader) void {
        if (comptime std.debug.runtime_safety)
            std.debug.assert(self.metaConst().flags.kind != .object);
        self.next_non_object = next;
    }
};

/// Byte size of the prefix reserved ahead of every flat `String` and
/// `StringRope` allocation: a full collector `Metadata` word.
pub const string_prefix_size: usize = metadata_prefix_size;

/// Unified collector handle: a pointer whose `Metadata` lives at `handle - 8`.
/// Physically this is `TraceHeader`. List-carrying kinds store `next_non_object`
/// in that word; Object (layout M) and prefix carriers (string/rope/storage)
/// use the same type for `.meta()` and must not read the link field.
pub const Header = TraceHeader;

/// Physical displacement from the unified GC handle to the kind's body. M
/// makes Object's handle equal its body pointer; every other Metadata-backed
/// kind retains the eight-byte TraceHeader word ahead of its body.
pub inline fn bodyOffsetFromHeader(comptime kind: GcKind) usize {
    return switch (kind) {
        .object => 0,
        .function_bytecode,
        .var_ref,
        .realm_context,
        .module,
        .shape,
        .string,
        .rope,
        .string_buffer,
        .big_int,
        .property_storage,
        .array_storage,
        .payload,
        => @sizeOf(TraceHeader),
    };
}

/// Typed header-to-body arithmetic. Object's zero displacement is asserted at
/// the only conversion boundary it owns, so a reintroduced uniform eight-byte
/// offset stops here before a body field is dereferenced.
pub inline fn bodyAddressFromHeader(comptime kind: GcKind, header: *const Header) usize {
    const offset = bodyOffsetFromHeader(kind);
    if (comptime std.debug.runtime_safety) {
        if (kind == .object and offset != 0)
            @panic("gc: M-CUT BODY OFFSET: Object handle must equal body start");
    }
    return @intFromPtr(header) + offset;
}

comptime {
    std.debug.assert(bodyOffsetFromHeader(.object) == 0);
    for (.{ GcKind.function_bytecode, .var_ref, .realm_context, .module, .shape, .string, .rope, .string_buffer, .big_int, .property_storage, .array_storage, .payload }) |kind|
        std.debug.assert(bodyOffsetFromHeader(kind) == 8);
}

/// TGC S4-e: the Pass-B park is gone, and with it the temporary successor
/// that used the dead Shape word at body+8. The constant survives as the
/// Object head's layout pin: `shape_ref` sits here, and the M-terminal head
/// assertions name this offset rather than an unexplained literal 8.
pub const object_deferred_link_body_offset: usize = 8;

/// TGC S4-a: does this carrier's death owe a destructor call?
/// The header bit is the authority for extents and non-block kinds; block
/// cells carry the same fact in `Block.finalizerBits` so the sweep can scan
/// a whole block without touching a single header.
pub inline fn headerNeedsFinalizer(h: *const Header) bool {
    return h.metaConst().flags.needs_finalizer;
}

/// TGC S4-h: the condemnation stamp.
///
/// A header is condemned when the sweep has removed it from every live
/// membership structure (`lists.objects`, `nonblock_objects.items`, the block
/// allocation bitmap's live meaning) and parked it for its destruction slice.
/// Until S4-h that fact was `BlockFlags.cycle_visited`, the last flag standing
/// between the byte and its terminal layout.
///
/// It is stored as a RESERVED VALUE of the mark epoch rather than as a bit:
///
///   * "condemned" and "marked" are mutually exclusive by construction -- a
///     header is condemned precisely because the remark did not mark it -- so
///     the two facts are one tri-state and belong in one field. Writing the
///     stamp cannot destroy information: the epoch it overwrites is, by the
///     condemnation predicate itself, a stale one.
///   * `advanceHeaderMarkEpoch` never produces this value (it scrubs and wraps
///     one short of it), so `headerMarked` reads false for a condemned header
///     on every kind, which is what all ~20 read sites already assumed.
///   * It costs nothing: `lifetime.mark_epoch` is dead storage for a block
///     cell (the mark authority is the block bitmap) and for an extent (the
///     extent table), which is exactly the population `cycle_visited` cost a
///     byte-wide read-modify-write on.
///   * Every allocation route zeroes the four-byte lifetime word
///     (`initGcPrefix`, `initGcPrefixBlockCell`, `createStringCell`,
///     `createExtent`), so the stamp is cleared by cell reuse the same way the
///     bit was -- and a cell sitting in the free list keeps it, which is a
///     strictly stronger free-cell guard than the poison bit it replaces.
///
/// The alternatives were: a dedicated `condemned_epoch` field (impossible --
/// `Metadata` is eight bytes and full), a parity/odd-sentinel scheme on the
/// mark epoch (needs the stamp to be re-derived per collection, and a corpse
/// whose destruction slice spans a collection would silently lose it), and the
/// per-population authorities the S4-e note proposed: the block doomed bitmap
/// is drained by `takeDoomedCell` and overwritten by the next
/// `snapshotDoomed`, so it is not a stable predicate, and
/// `nonblock_objects.doomed` is an ArrayList whose membership test is O(n).
pub const condemned_mark_epoch: u16 = std.math.maxInt(u16);

/// The relocation stamp, in the same field and for the same reason as
/// `condemned_mark_epoch`: "forwarded", "condemned" and "marked" are mutually
/// exclusive by construction, so they are one tri-state rather than three
/// bits. A minor writes it over a young cell it has just copied out; the
/// forwarding ADDRESS goes in the body's first word, which a copied-out cell
/// no longer needs.
pub const forwarded_mark_epoch: u16 = condemned_mark_epoch - 1;

pub inline fn headerForwarded(h: *const Header) bool {
    return @atomicLoad(u16, &h.metaConst().lifetime.mark_epoch, .monotonic) == forwarded_mark_epoch;
}

/// Where a forwarded cell went. Only valid while `headerForwarded` holds.
pub inline fn forwardingTarget(h: *const Header) *Header {
    return @ptrFromInt(@as(*const usize, @ptrCast(@alignCast(h))).*);
}

/// `body_bytes` is stored alongside the address because the body's first word
/// is where the address goes: once it is written the object can no longer
/// describe its own size, and the page walk that finds the corpses needs a
/// size for every cell, forwarded or not.
pub inline fn setForwarding(h: *Header, target: *Header, body_bytes: usize) void {
    @as(*usize, @ptrCast(@alignCast(h))).* = @intFromPtr(target);
    h.meta().size_class = @intCast(@min(body_bytes, large_heap_size_class));
    @atomicStore(u16, &h.meta().lifetime.mark_epoch, forwarded_mark_epoch, .monotonic);
}

/// The body size of a forwarded cell, read back from the stamp above.
pub inline fn forwardedBodyBytes(h: *const Header) usize {
    return h.metaConst().size_class;
}

/// O(1) condemnation test, valid for every kind: block cell, extent, non-block
/// Object and list carrier alike.
pub inline fn headerCondemned(h: *const Header) bool {
    return @atomicLoad(u16, &h.metaConst().lifetime.mark_epoch, .monotonic) == condemned_mark_epoch;
}

/// The single writer of the stamp, called by the four detach/condemn entry
/// points. Atomic for the same reason `setHeaderMarked` is: a future parallel
/// marker may be loading the same word.
inline fn stampHeaderCondemned(h: *Header) void {
    @atomicStore(u16, &h.meta().lifetime.mark_epoch, condemned_mark_epoch, .monotonic);
}

inline fn assertInitialHeaderLifetime(h: *const Header) void {
    const state = h.metaConst().lifetime;
    std.debug.assert(state.mark_epoch == 0);
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

// The intrusive-list primitives moved to `gc_registry_lists.zig` with the
// Registry cursors that use them; these aliases keep the `gc.listX` spelling
// the collector already had.
pub const IntrusiveHeaderList = registry_lists.IntrusiveHeaderList;
const headerLinked = registry_lists.headerLinked;

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
    /// `young_head` no longer names a node on `lists.objects` -- a detach path
    /// forgot the young-suffix anchor and the next minor would walk freed
    /// memory (the `unlinkObjectWithBytes` hole, 2026-08-25).
    DanglingYoungHead,
    InvalidHeaderState,
    MissingHeapAllocation,
    HeapLiveBytesMismatch,
    OldLiveBytesMismatch,
    LargeObjectBytesMismatch,
    CarrierOldNewMismatch,
    CarrierRawOwnedMismatch,
    CarrierGenerationMismatch,
    CarrierByteMismatch,
    DuplicateExternalMemoryToken,
    EmptyExternalMemoryToken,
    ExternalTokenBytesMismatch,
    EmptyPinEntry,
    PinEntryNotLive,
    YoungCountMismatch,
    RememberedOwnerNotLive,
    RememberedOwnerYoung,
    RememberedCacheWithoutOwner,
    RememberedOwnerMissingCache,
    RetirementStateMismatch,
    RetirementYoungSurvivor,
    DoomedBucketKindMismatch,
    DoomedPendingMismatch,
    DoomedCursorMismatch,
    ConstructionRootStateMismatch,
    RepresentationKindMismatch,
    RepresentationAllocationCarrierMismatch,
    RepresentationPrefixFieldMismatch,
    ObjectShapeSummaryMismatch,
    RepresentationCellIndexMismatch,
    MisalignedPropertyStorage,
    MissingObjectPropertyStorage,
    InvalidTrailingPropertyClass,
    InvalidTrailingPropertyLayout,
    InvalidTrailingPropertyCapacity,
    InvalidSlots2PayloadOwner,
    UndersizedTrailingObjectCell,
    ObjectCellSizeClassMismatch,
    /// TGC S4-b: `prop_values` / `arrayArm().values` must name a published
    /// storage cell of the matching kind. A raw (non-cell) buffer installed
    /// there has no collector prefix, so the sweep would read a neighbouring
    /// allocation's bytes as a header.
    DanglingPropertyStorageCell,
    InvalidPropertyStorageKind,
    DanglingArrayStorageCell,
    InvalidArrayStorageKind,
    DeferredPayloadRootNotLive,
    DeferredPayloadRootDoomed,
};

/// Publication state selects which prefix fields have meaning.  Keeping this
/// explicit prevents a checker from blessing an unpublished block cell using
/// the weaker rules for a live registry node (or treating a BigInt leaf as if
/// its lifecycle bits were meaningful merely because it has Metadata bytes).
pub const MetadataSemanticState = enum {
    registry_published,
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

    // A bump-allocated young cell is its own carrier: class field unused,
    // standalone clear, no block. Checking it against the slab's class domain
    // would read the unused field as class 0.
    if (meta.alloc_info.nursery) {
        if (meta.alloc_info.standalone or
            meta.alloc_info.block_size_idx != 0 or
            expected_kind != .object)
        {
            return error.RepresentationAllocationCarrierMismatch;
        }
        return verifyMetadataLifetime(meta, expected_kind, state);
    }
    const is_block_cell = meta.alloc_info.block_size_idx == representation.block_cell_size_class;
    switch (descriptor.allocation) {
        .block_slab_or_standalone => {},
        .slab_or_standalone => if (is_block_cell)
            return error.RepresentationAllocationCarrierMismatch,
    }
    if (is_block_cell and meta.alloc_info.standalone)
        return error.RepresentationAllocationCarrierMismatch;
    if (meta.alloc_info.standalone) {
        if (meta.alloc_info.block_size_idx != 0)
            return error.RepresentationAllocationCarrierMismatch;
    } else if (!is_block_cell and meta.alloc_info.block_size_idx >= memory.SmallObjectSlab.class_count) {
        return error.RepresentationAllocationCarrierMismatch;
    }
    return verifyMetadataLifetime(meta, expected_kind, state);
}

/// The state half of `verifyMetadataSemantics`: what the lifetime word and the
/// accounting bits must say, independent of which carrier holds the object.
fn verifyMetadataLifetime(
    meta: *const Metadata,
    expected_kind: GcKind,
    state: MetadataSemanticState,
) InvariantError!void {
    const is_block_cell = meta.alloc_info.block_size_idx == representation.block_cell_size_class;
    switch (state) {
        .registry_published => {
            if (!meta.alloc_info.heap_accounted)
                return error.RepresentationPrefixFieldMismatch;
            if (meta.alloc_info.standalone and meta.size_class == 0)
                return error.RepresentationPrefixFieldMismatch;
            {
                const lifetime = meta.lifetime;
                if (lifetime.flags.reserved != 0)
                    return error.RepresentationPrefixFieldMismatch;
                // The low seven bits are Object's Shape projection and must
                // stay zero on every other carrier. Bit7 is the remembered
                // cache, which audit §10 leased to every eligible kind: a
                // published `.shape`/`.var_ref` owner legitimately carries it.
                // Ineligible kinds keep the whole byte reserved (they cannot
                // reach `.registry_published` anyway -- neither is a cycle
                // candidate -- so this arm is belt-and-braces).
                if (expected_kind != .object) {
                    if (lifetime.object_shape_summary & ~trace_remembered_mask != 0)
                        return error.RepresentationPrefixFieldMismatch;
                }
            }
        },
        .construction_block_object => {
            // TGC S4-d: `needs_finalizer` is deliberately NOT in this set. A
            // construction shell can already owe destructor work -- the
            // generator shell stamps itself c-class before it becomes a
            // construction root -- and the bit only ever goes on (D-S4-4),
            // so it carries no information about construction state.
            // Same shared-byte rule as `isConstructionRoot`: only the Shape
            // projection must be pristine. Bit7 is the remembered cache and a
            // shell that took a barrier write carries it legitimately.
            const initial_lifetime = meta.lifetime.mark_epoch == 0 and
                meta.lifetime.object_shape_summary & trace_object_shape_summary_mask == 0 and
                meta.lifetime.flags.reserved == 0;
            if (expected_kind != .object or !is_block_cell or
                meta.alloc_info.heap_accounted or meta.alloc_info.standalone or
                meta.flags.young or
                meta.flags.finalizing or
                meta.flags.reserved or !initial_lifetime)
            {
                return error.RepresentationPrefixFieldMismatch;
            }
        },
    }
}

/// 19. GE Stats
/// Retained collection-round durations. Sized so a benchmark-scale run (the
/// V8 suite does ~880 rounds) keeps its whole history rather than a tail.
pub const pause_sample_capacity: usize = 128;

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

    /// TGC S4-d deletion probe (spec 2.4) and its reverse audit (spec 6).
    ///
    /// `object_destructor_calls` counts every `Object.destroyFromHeader`
    /// entry. `plain_object_destructor_calls` is the bucket this batch exists
    /// to drive to ZERO: `class_id == object`, no class payload, no finalizer
    /// bit -- a plain object the sweep should have reclaimed from the bitmap
    /// without ever touching its header.
    /// `plain_objects_with_finalizer_bit` is the reverse audit: a plain,
    /// payload-free object that nevertheless carries the bit (the sticky-bit
    /// residue allowed by D-S4-4).
    object_destructor_calls: usize = 0,
    plain_object_destructor_calls: usize = 0,
    plain_objects_with_finalizer_bit: usize = 0,
};

pub const Stats = struct {
    /// Account high-water, not a heap census and not RSS.
    peak_allocated_bytes: usize = 0,

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

/// Explicit heap census plus process sample. Ordinary `gcStats` does not
/// fill these; a missing census is not reported as zero.
pub const DetailedStats = struct {
    counters: Stats = .{},
    /// Live traced bytes from one census. Not `allocated_bytes`, not RSS.
    heap_live_bytes: usize = 0,
    old_live_bytes: usize = 0,
    large_object_bytes: usize = 0,
    old_count: usize = 0,
    large_count: usize = 0,
    rss_bytes: usize = 0,
    cgroup_limit_bytes: usize = 0,
};

pub var heap_walks_for_test: if (builtin.is_test) usize else void =
    if (builtin.is_test) 0 else {};

pub fn noteHeapWalk() void {
    if (comptime !builtin.is_test) return;
    heap_walks_for_test += 1;
}

/// Z-GE Registry
/// The two words every write barrier and every JSValue release reads.
///
/// K4: `phase` is read by every JSValue release (value.zig
/// `freeObjectAssumeObject`/`free`, mirroring qjs `__JS_FreeValueRT`'s
/// `gc_phase` check) -- including the per-return function rc-- on the hot
/// call path. QuickJS keeps `gc_phase` in the JSRuntime head
///; zjs auto layout had pushed it to the Registry tail at
/// rt+18-19KB, costing a `mov #imm` address materialization plus a cold
/// cache line on every release (M1 dossier K4).
///
/// `extern` rather than a plain struct because auto layout sorts by
/// alignment and would put the u64 first; the contract these two words are
/// under is *positional*, so the layout has to be declared, not inferred.
/// The Registry field is `align(64)`, which pins the pair at Registry
/// offset 0 and lifts the Registry itself into JSRuntime's
/// highest-alignment (front) bucket, so `rt.gc.hot.phase` is a single
/// imm-offset ldrb in the runtime's front cache lines. `Registry`'s
/// `layout_contract` block below is the compile-time enforcement.
pub const HotWords = extern struct {
    phase: Phase = .none,

    /// Write-barrier gate: the phase-owned mask the fast path ANDs against
    /// the owner's state word (`barrierOwnerWord`). `barrier_skip_bits` in
    /// the steady state, zero whenever some richer arm must run -- major
    /// marking (exact-target shading) or `--gc-stats` (call accounting).
    /// Rewriting one word at a phase boundary is JSC's `m_barrierThreshold`
    /// protocol (Heap.cpp:3382-3386), and it is what takes both of those
    /// global loads OFF the barrier's hot path.
    ///
    /// Deliberately adjacent to `phase` so it rides the Registry's pinned
    /// front cache line rather than a cold tail line.
    /// `refreshBarrierGate` is the only writer; `initLists` seeds it.
    barrier_gate: u64 = barrier_skip_bits,
};

pub const Registry = struct {
    /// Outcome of the most recent collection on THIS runtime: the panel
    /// row, the census time it deducts, and the raw final-remark witness the
    /// deduction test reads. Per runtime, so two runtimes on two threads
    /// cannot contaminate each other's panels (gc_incremental.Stats had the
    /// same bug once).
    last_report: gc_trace_stw_reports.Report = .{},
    last_census_ns: u64 = 0,
    last_finish_remark_raw_ns: u64 = 0,
    /// Unbarriered old->young stores caught by the audit, by store site.
    unbarriered_store_hits: [3]usize = .{ 0, 0, 0 },
    // Field ORDER is load-bearing, not cosmetic. Zig's auto layout keeps
    // declaration order within an alignment class, so the offsets below are
    // exactly this list: the groups the mutator touches on every allocation
    // and every barrier come first, and the two multi-kilobyte diagnostic
    // blobs (`stats`, `space_histogram`) go last so they cannot push a hot
    // group past an addressing-mode boundary. Measured: with the diagnostic
    // blobs in the middle, `block_heap` sat at Registry+4936 and ReleaseFast
    // .text grew 5,260 bytes on address materialization alone.
    hot: HotWords align(64) = .{},

    runtime: *JSRuntime,

    /// The published non-Object carrier list and its cursors.
    /// See `gc_registry_lists.zig`.
    lists: Lists = .{},

    /// 64 KiB block heap.
    block_heap: BlockHeap = .init(std.heap.page_allocator),

    generation: GenerationState = .{},

    // A marker worker is deliberately *not* a field here.
    //
    // Embedding one made the OOM canary "binding Realm construction
    // rollback and retry" abort: a partially constructed Registry that is
    // rolled back after an injected allocation failure has to be safe to tear
    // down, and every field added to it widens that obligation. It has no
    // production caller either -- the incremental major is driven to
    // completion on the owner thread -- so the honest place for a future
    // parallel marker is beside the collector that will own it, allocated
    // when a cycle starts.
    //
    // This is the same lesson as the 32 KB embedded ring, one level up: what
    // a Registry contains is paid for by every runtime, including the ones
    // that fail halfway through construction.
    incremental: IncrementalState = .{},
    /// Mark frontier and mark epoch. See `gc_incremental.zig`.
    marking: Marking = .{},

    /// Page-radix map of published GC objects.
    address_registry: AddressRegistryTable = .{},
    nonblock_objects: ?*NonBlockObjectAuthority = null,
    /// Bump-allocated young generation. Empty unless `nursery_enabled`.
    nursery: nursery_mod.Nursery = .{},
    /// Cell heap, nursery, and audit carrier tables. The account forwards here.
    cell_storage: gc_storage.Owner = .{},
    /// Bumped by every collection that can move or free an object.
    ///
    /// This is the `Effect.may_alloc` discipline made checkable at runtime:
    /// native code that holds a heap pointer across a collection is holding a
    /// stale one, and `Local` compares this counter to decide. A function
    /// that cannot allocate cannot bump it, which is exactly why such a
    /// function may hold bare pointers freely.
    collection_epoch: u64 = 0,
    /// The slab whose arena lifetimes the address registry observes, for
    /// recovery.
    arena_slab: ?*memory.SmallObjectSlab = null,

    /// Host pins and construction roots. See `gc_registry_pins.zig`.
    pins: PinLedger = .{},
    /// Off-account external memory the host holds. See `gc_registry_heap.zig`.
    external: ExternalTokens = .{},

    /// Condemned-but-not-yet-destroyed corpses. See `gc_incremental.zig`.
    morgue: Morgue = .{},

    /// Major-collection pacing and the pending-request latch.
    /// See `gc_registry_scheduler.zig`.
    scheduler: Scheduler = .{},

    /// Independent byte oracle for tests and ownership-audit builds; void in
    /// shipped builds.
    heap_accounting_oracle: if (carrier_audit_enabled) HeapAccountingOracle else void =
        if (carrier_audit_enabled) .{} else {},

    // Cold tail. The verification and statistics surface that reads these
    // lives in `gc_registry_diagnostics.zig`.
    stats: GeStats = .{},
    /// Publication-size histogram for Stage 4 class freeze.
    space_histogram: SpaceHistogram = .{},
    /// Live JS heap charge and its limit. Declared last so it does not shift
    /// the hot prefix. Nursery cells are not charged.
    heap_budget: heap_budget.Budget = .{},

    // The R3 conservative-only root census is deliberately NOT a field here.
    // It lives in `gc_conservative`'s `.bss`: as a Registry field it was part
    // of `JSRuntime`, and changing its size changed the runtime's footprint,
    // the allocator's threshold crossing and therefore how many collections a
    // workload runs -- a diagnosis that moves collection timing measures
    // itself. See `gc_conservative.RootsDiagCensus`.

    /// Backing allocator for the block heap's 2 MiB superblocks, large
    /// extents and side tables.
    ///
    /// Shipped builds take these straight from the OS: the memory is not
    /// JS-visible, so charging it to the account would double-count the
    /// cells the heap then hands out, and the mapping cost has nothing to do
    /// with the JS heap limit.
    ///
    /// The OOM-injection tier must nevertheless route it through
    /// `mem_ops.backing_allocator` -- the *unaccounted* raw allocator
    /// the account itself sits on. Everything the tracing collector moved
    /// into the block heap (S2: the string family; S4-b: property storage
    /// and array element buffers) is otherwise invisible to
    /// `std.testing.checkAllAllocationFailures` and to
    /// `OneShotFailingAllocator`, because `page_allocator` is not the
    /// injector. That silently shrank the OOM tier's reach as the migration
    /// progressed (the export-name-lookahead canary's injectable window
    /// collapsed from
    /// >8 to 6). Going through `backing_allocator` rather than `allocator`
    /// keeps the byte accounting and the memory-limit semantics identical to
    /// the shipped build, so only the injection surface changes. That surface
    /// is the `test-oom` step's alone: keyed off `builtin.is_test` it changed
    /// the allocator topology of the whole unit suite.
    const block_heap_uses_account_backing = memory.oom_injection_enabled;

    // The positional contract `hot` exists to hold. Prose in a doc comment
    // is not a constraint: before S5-d these facts were asserted only by a
    // comment, and the Registry split is exactly the kind of edit that
    // silently breaks them (S5-c measured a candidate field that pushed
    // `barrier_gate` from offset 16 to 2432).
    comptime {
        std.debug.assert(@offsetOf(Registry, "hot") == 0);
        std.debug.assert(@offsetOf(HotWords, "phase") == 0);
        // Both words in the Registry's first cache line, which `align(64)`
        // makes the first line of a 64-byte-aligned region.
        std.debug.assert(@offsetOf(HotWords, "barrier_gate") + @sizeOf(u64) <= 64);
        std.debug.assert(@alignOf(Registry) >= 64);
    }

    /// Infallible by construction: every sub-structure is default-initialized
    /// and the only argument-derived fields are two pointers and the policy
    /// block, so there is no partially-constructed Registry to roll back and
    /// no errdefer to write. The rollback obligation is one level up --
    /// `JSRuntime` construction can fail after this returns -- which is why
    /// each sub-structure's `deinit` is idempotent instead.
    pub fn init(account: *@import("../runtime.zig").JSRuntime, policy: Policy) Registry {
        forensics.readFromEnv();
        return .{
            .runtime = account,
            .scheduler = .{ .policy = policy },
            .block_heap = BlockHeap.init(if (comptime block_heap_uses_account_backing)
                account.allocator
            else
                std.heap.page_allocator),
        };
    }

    /// Bind the groups that hold self-referential state, after the Registry
    /// is in its final location (qjs `init_list_head` on `JSRuntime` fields).
    /// Must run before any header is published; each step is idempotent.
    pub fn initLists(self: *Registry) void {
        self.refreshBarrierGate();
        self.lists.init();
        self.morgue.init();
    }

    pub fn deinit(self: *Registry, rt: *JSRuntime) void {
        self.abortCycleEnvelope();
        self.invalidateCycleEnvelopeBaseline();
        self.hot.phase = .deinit;

        // Phase 0: unpublished construction-root shells (detached generator
        // shells) are owned only by the pin ledger. Tear them down through the
        // same typed route as `destroyGeneratorShell` -- payload, borrowed
        // holders, raw cell -- while classes, the payload allocator and the
        // block heap are all still alive. `removeConstructionRoot` shifts the
        // ledger, so the index is only advanced past non-construction pins.
        while (self.pins.firstConstructionRoot()) |header| {
            object.Object.fromHeader(header).destroyGeneratorShell(rt);
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
        var held_shapes: ?*Header = null;
        var held_var_refs: ?*Header = null;
        var held_function_bytecodes: ?*Header = null;

        // Objects must release their Shape/FB/VarRef edges before those carrier
        // bodies are dismantled below. Block objects should already be gone
        // after JSRuntime's host-quiescent teardown collections; the explicit
        // side authority is nevertheless a complete fallback for every
        // non-block Object still owned at this boundary.
        // Nursery residents. Teardown has no collection to evacuate them, so
        // nothing else will ever reach them: they are in no list, no bitmap
        // and no side authority -- their membership is the page, and the page
        // is about to go back whole. Release their resources here or the
        // carrier ledger ends the run holding their payload cells.
        if (self.nursery.enabled) {
            for (self.nursery.pages.items) |page| {
                var cursor = page.base;
                while (cursor < page.top) {
                    const resident: *Header = @ptrFromInt(cursor + metadata_prefix_size);
                    const forwarded = headerForwarded(resident);
                    const body_bytes = if (forwarded)
                        forwardedBodyBytes(resident)
                    else
                        heapByteSizeFromHeader(rt, resident);
                    if (!forwarded and resident.metaConst().alloc_info.heap_accounted) {
                        self.recordHeapFreeWithBytes(resident, body_bytes);
                        resident.meta().flags.finalizing = true;
                        object.Object.destroyFromHeader(rt, resident);
                        rt.drainDeferredClassPayloadFinalizers();
                    }
                    cursor += std.mem.alignForward(usize, body_bytes + metadata_prefix_size, 8);
                }
            }
        }
        if (self.nonblock_objects) |authority| {
            while (authority.items.items.len != 0) {
                const h = authority.items.items[authority.items.items.len - 1];
                std.debug.assert(h.metaConst().flags.kind == .object);
                self.removeNonBlockObject(h);
                self.recordHeapFreeWithBytes(h, heapByteSizeFromHeader(rt, h));
                h.meta().flags.finalizing = true;
                object.Object.destroyFromHeader(rt, h);
                rt.drainDeferredClassPayloadFinalizers();
            }
        }
        while (!self.lists.objects.isEmpty()) {
            // Compact headers have no backlink on tracer-owned kinds. Teardown
            // order is mediated by the holding stacks below, not list order,
            // so consume the head and keep every detach O(1).
            const h = self.lists.objects.first().?;
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
        // are freed by their own destructors.
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
            var_ref.VarRef.freeStruct(rt, h);
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

        // TGC S4-e spec 2.5: there is no phase 5. Object and FunctionBytecode
        // structs are freed by their own destructors in phases 1 and 2; the
        // holding stacks above are what order teardown, and Shape destruction
        // reads no Object field (`Registry.destroyShape` frees the FAM and
        // unlinks by stored hash).
        rt.shapes.deinit();

        self.lists.init();

        self.external.deinit(self.runtime);
        self.pins.deinit(self.runtime);

        // TGC S2: string carriers that survived the host-quiescent teardown
        // collections (atom-table roots) leave through the same unpublish +
        // return path the sweep uses, so the accounting oracle balances.
        string.destroyAllStringCarriersForDeinit(rt);

        self.destroyNonblockAuthority();
        self.cell_storage.slab.arena_observer = null;
        self.arena_slab = null;
        self.address_registry.deinit(addressRegistryAllocator());
        self.generation.deinit(addressRegistryAllocator());
        self.nursery.deinit(self.nursery.page_allocator);
        self.block_heap.deinit();
        if (comptime carrier_audit_enabled) {
            std.debug.assert(self.heap_accounting_oracle.raw.count() == 0);
            self.heap_accounting_oracle.deinit(std.heap.page_allocator);
        }
        if (comptime carrier.audit_enabled or carrier.audit_enabled) {
            mem_ops.deinitGcCarrier(self.runtime);
        }

        self.hot.phase = .none;
    }

    pub fn reportExternalAlloc(self: *Registry, bytes: usize) !ExternalMemoryToken {
        if (bytes == 0) return .{};
        const id = try self.external.add(self.runtime, bytes);
        self.stats.external_bytes = std.math.add(usize, self.stats.external_bytes, bytes) catch std.math.maxInt(usize);
        self.stats.peak_external_bytes = @max(self.stats.peak_external_bytes, self.stats.external_bytes);
        self.stats.external_alloc_count +|= 1;
        const weighted = std.math.mul(usize, bytes, self.scheduler.policy.external_weight) catch std.math.maxInt(usize);
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
        const weighted = std.math.mul(usize, bytes, self.scheduler.policy.external_weight) catch std.math.maxInt(usize);
        self.stats.allocation_debt = std.math.add(usize, self.stats.allocation_debt, weighted) catch std.math.maxInt(usize);
    }

    pub fn reportExternalFreeUntracked(self: *Registry, bytes: usize) void {
        if (bytes == 0) return;
        self.stats.external_bytes -|= bytes;
        self.stats.external_untracked_bytes -|= bytes;
        self.stats.external_free_count +|= 1;
        // Only the live ledger is reversible; see `releaseExternalToken`.
    }

    fn releaseExternalToken(self: *Registry, id: u64, bytes: usize) void {
        switch (self.external.release(id, bytes)) {
            .malformed, .unknown_id, .byte_mismatch => {
                self.stats.external_invalid_release_count +|= 1;
            },
            // `external_bytes` is the live-pressure ledger and is symmetric.
            // `allocation_debt` is deliberately different: it is weighted
            // bytes allocated since the last completed major, so a free does
            // not erase allocation churn that already happened.
            // `resetAllocationDebt` clears that cumulative pacing signal
            // after the major has paid it.
            .released => |released_bytes| {
                if (released_bytes == 0) return;
                self.stats.external_bytes -|= released_bytes;
                self.stats.external_free_count +|= 1;
            },
        }
    }

    pub fn externalMemoryRequestReason(self: Registry) ?RequestReason {
        if (self.scheduler.policy.external_hard_limit) |limit| {
            if (self.stats.external_bytes >= limit) return .external_memory;
        }
        if (self.stats.allocation_debt >= self.scheduler.policy.major_debt_threshold) return .allocation_debt;
        if (self.scheduler.policy.external_soft_limit) |limit| {
            if (self.stats.external_bytes >= limit) return .external_memory;
        }
        return null;
    }

    pub fn externalMemoryRequestUrgency(self: Registry) RequestUrgency {
        if (self.scheduler.policy.external_hard_limit) |limit| {
            if (self.stats.external_bytes >= limit) return .urgent;
        }
        return .soon;
    }

    pub fn processMemoryRequest(self: Registry, rss_bytes: usize, cgroup_limit_bytes: usize) ?PressureRequest {
        return self.scheduler.processMemoryRequest(rss_bytes, cgroup_limit_bytes);
    }

    /// Count the request, then latch it. The counting half is the statistics
    /// block's; the latch is the scheduler's.
    pub fn requestGC(self: *Registry, reason: RequestReason, urgency: RequestUrgency) void {
        self.stats.gc_request_count +|= 1;
        self.stats.last_request_reason = reason;
        self.scheduler.request(reason, urgency);
    }

    pub fn hasPendingMajorRequest(self: Registry) bool {
        return self.scheduler.hasPendingMajorRequest();
    }

    pub fn resetAllocationDebt(self: *Registry) void {
        self.stats.allocation_debt = 0;
    }

    pub inline fn addInitializedWithSize(self: *Registry, h: *Header, bytes: usize) !void {
        if (h.metaConst().flags.kind == .object and !isBlockCellHeader(h) and !isNurseryHeader(h)) {
            try self.prepareNonBlockObjectAuthority();
        }
        self.addInitializedWithSizeNoFail(h, bytes);
    }

    /// Reserve the header-external membership slot before a raw Object
    /// allocation becomes observable. Object allocators call this after they
    /// know the block heap declined; the fallible generic publication API calls
    /// it again as a defensive boundary for test/embedding-created carriers.
    pub fn prepareNonBlockObjectAuthority(self: *Registry) !void {
        const authority = self.nonblock_objects.?;
        try authority.prepare(addressRegistryAllocator());
    }

    /// No-fail publication primitive for fully prepared GC objects. Registry
    /// publication only updates scalar accounting and intrusive links; every
    /// allocation and owner-producing operation must already have completed.
    pub fn addInitializedWithSizeNoFail(self: *Registry, h: *Header, bytes: usize) void {
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
    noinline fn publishInitializedCold(self: *Registry, h: *Header, bytes: usize) void {
        self.publishInitialized(h, bytes, .cold);
    }

    const PublicationArm = enum { fast, cold };

    /// Runtime half of the fast/cold split. The comptime half (`is_test`
    /// histogram, sweep-model stats) needs no gate: those arms are already
    /// absent from production builds, and `detailed_reports` is reached by a
    /// tail call that costs the frame nothing.
    inline fn publicationNeedsColdArm(is_large: bool, standalone: bool) bool {
        return is_large or standalone;
    }

    inline fn publishInitialized(
        self: *Registry,
        h: *Header,
        bytes: usize,
        comptime arm: PublicationArm,
    ) void {
        assertInitialHeaderLifetime(h);
        std.debug.assert(!h.meta().flags.finalizing);
        std.debug.assert(!headerCondemned(h));
        std.debug.assert(!h.meta().alloc_info.heap_accounted);
        // String-family carriers have no TraceHeader link word (the body
        // starts at the handle), so "unlinked" is only meaningful for list
        // carriers.
        if (h.metaConst().flags.kind != .object and !kindIsPrefixCarrier(h.metaConst().flags.kind))
            std.debug.assert(!headerLinked(h));

        const is_large = self.isLargeAllocation(bytes);
        // Read the alloc_info byte ONCE, before the heap_accounted store.
        // Every classification this publication still needs from it --
        // standalone prefix, block-cell size class -- is by construction
        // unchanged by setting heap_accounted. The compiler cannot prove that
        // on its own: Registry writes through `self` may alias the header, so
        // every later `alloc_info` read used to become a reload of the byte
        // just stored.
        const info_at_entry = h.metaConst().alloc_info;
        const is_block_cell = info_at_entry.block_size_idx == representation.block_cell_size_class;
        if (comptime arm == .fast) {
            if (publicationNeedsColdArm(is_large, info_at_entry.standalone)) {
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
        // A nursery cell has no raw allocation record to pair with: the page
        // was charged, not the cell. Both audits describe the raw-alloc /
        // publish seam, which a bump pointer does not have.
        if (comptime carrier_audit_enabled) {
            if (!h.metaConst().alloc_info.nursery) {
                self.heap_accounting_oracle.recordPublish(@intFromPtr(h), bytes, is_large);
            }
        }
        if (comptime carrier.audit_enabled) {
            if (!h.metaConst().alloc_info.nursery) {
                mem_ops.carrierPublish(self.runtime, @intFromPtr(h), bytes) catch
                    @panic("gc: CARRIER IDENTITY: publication missing carrier record");
            }
        }
        // qjs add_gc_object writes header bookkeeping once and then
        // list_add_tail's. No membership flag. GC pacing
        // is owned by mem_ops.allocated_bytes; logical space bytes and
        // counts are derived by statsSnapshot.
        if (comptime arm == .fast) {
            std.debug.assert(!is_large);
        }

        const tracked = isCycleCandidate(h);
        // Checkers for the two hoisted classifications above. Everything this
        // function does between the read and here writes `heap_accounted`,
        // `size_class` or Registry scalars -- none of which may move
        // `standalone` or `block_size_idx`.
        std.debug.assert(info_at_entry.standalone == h.metaConst().alloc_info.standalone);
        std.debug.assert(is_block_cell == isBlockCellHeader(h));
        // TGC S2-i: the occupant question is "is this an EXTENT carrier",
        // not "is this a string JSValue": `unpublishStringExtent` has taken
        // no `Table.remove` since S2-h1, so any extent kind that took an
        // occupant here would leave a stale entry resolving freed pages.
        const is_extent_carrier = kindIsExtentCapable(h.metaConst().flags.kind);
        // A nursery cell's membership IS its page: no list, no side
        // authority, no allocation bitmap. A minor either copies it out or
        // drops the page, and neither reads a membership structure.
        const is_nursery = isNurseryHeader(h);
        const is_nonblock_object = tracked and !is_block_cell and !is_nursery and
            h.metaConst().flags.kind == .object;
        // TGC S2: a string that is neither a block cell nor a non-block
        // Object is an extent (standalone prefix). Strings carry no
        // TraceHeader link word, so `lists.objects` cannot hold them; the
        // heap's medium/large extent tables are their enumeration (marked
        // through `extentSetMark`, swept by `Heap.sweepExtents`).
        const is_list_carrier = tracked and !is_block_cell and !is_nursery and
            !kindIsPrefixCarrier(h.metaConst().flags.kind);
        {
            if (is_nonblock_object) {
                self.nonblock_objects.?.publish(h);
            } else if (is_list_carrier) {
                self.lists.linkTail(h);
            }
            // TGC S2-h1: an extent string is standalone but takes NO occupant
            // entry. `Heap.extent_pages` already resolves it exactly (and is
            // the authority `forEachTraceCandidateAt` consults first), so the
            // entry was a duplicate answer bought with a hash insert on every
            // >3760-byte string body and a hash remove on every death --
            // `Table.remove +308 / insert +61` of the S2/S3 close-out symbol
            // diff. The range gate those inserts also widened is now merged
            // from `Heap.extent_bounds_lo/hi` in `rebuildScanFilter`.
            self.registerLiveAddressClassified(h, bytes, .{ .tracked = tracked, .needs_occupant = standalone and !is_extent_carrier, .is_block_cell = is_block_cell });
            self.observeNewPublication(h, bytes);
        }
    }

    /// qjs `add_gc_object` for shapes: rc/kind already live
    /// in the prefix, then heap_accounted + list_add_tail.
    /// Shapes stay below `large_object_threshold` (8KiB); skip the large
    /// compare, standalone size_class stamp, and isCycleCandidate test.
    pub fn addInitializedShape(self: *Registry, h: *Header, bytes: usize) void {
        assertInitialHeaderLifetime(h);
        std.debug.assert(!h.meta().alloc_info.heap_accounted);
        std.debug.assert(!headerLinked(h));
        if (h.meta().alloc_info.standalone) {
            self.addInitializedWithSizeNoFail(h, bytes);
            return;
        }
        h.meta().alloc_info.heap_accounted = true;
        if (comptime carrier_audit_enabled) {
            self.heap_accounting_oracle.recordPublish(@intFromPtr(h), bytes, false);
        }
        if (comptime carrier.audit_enabled) {
            mem_ops.carrierPublish(self.runtime, @intFromPtr(h), bytes) catch
                @panic("gc: CARRIER IDENTITY: publication missing carrier record");
        }
        self.lists.linkTail(h);
        const info = h.metaConst().alloc_info;
        self.registerLiveAddressClassified(h, bytes, .{ .tracked = true, .needs_occupant = info.standalone, .is_block_cell = isBlockCellHeader(h) });
        self.observeNewPublication(h, bytes);
    }

    fn encodeHeapBytes(bytes: usize) u16 {
        return @intCast(@min(bytes, large_heap_size_class));
    }

    fn storedHeapBytes(h: *const Header) ?usize {
        if (!h.metaConst().alloc_info.standalone) return null;
        if (h.metaConst().size_class == 0) return 0;
        if (h.metaConst().size_class == large_heap_size_class) return null;
        return h.metaConst().size_class;
    }

    pub fn heapByteSizeFromHeader(rt: *const JSRuntime, h: *const Header) usize {
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
            .string, .rope => string.accountedAllocationSizeFromHeader(h),
            .string_buffer => string.accountedStorageSizeFromHeader(h),
            // TGC S4-b: a storage cell is not self-describing -- its body is
            // the owner's raw array -- so the carrier answers instead. A block
            // cell reports its size class; an extent over the u16 stamp
            // reports the table's `user_bytes` (the stamp itself already
            // returned above through `storedHeapBytes`).
            // TGC S4-c joins `.payload` to the same answer: an a-class class
            // payload (and the slices it owns) is a bare storage cell too.
            .property_storage, .array_storage, .payload => blk: {
                if (isBlockCellHeader(h)) {
                    break :blk storageCellBlockTotalBytes(h) - metadata_prefix_size;
                }
                const base = @intFromPtr(h) - metadata_prefix_size;
                break :blk (rt.gc.block_heap.extentUserBytes(base).?) - metadata_prefix_size;
            },
            .big_int => blk: {
                const big: *const bigint.BigInt = @alignCast(@fieldParentPtr("header", h));
                break :blk big.accountedAllocationSize();
            },
        };
    }

    pub fn isLargeAllocation(self: Registry, bytes: usize) bool {
        return bytes != 0 and bytes >= self.scheduler.policy.large_object_threshold;
    }

    /// Every Metadata kind is tracer-owned, so every published header is a
    /// candidate. Spelled as an exhaustive switch rather than `true` so a new
    /// kind has to state its answer here (the S4 storage kinds did).
    pub fn isCycleCandidate(h: *const Header) bool {
        return switch (h.metaConst().flags.kind) {
            .object,
            .function_bytecode,
            .var_ref,
            .shape,
            .realm_context,
            .module,
            .big_int,
            .string,
            .rope,
            .string_buffer,
            .property_storage,
            .array_storage,
            .payload,
            => true,
        };
    }

    fn recordHeapFreeWithBytes(self: *Registry, header: *Header, bytes: usize) void {
        if (!header.meta().alloc_info.heap_accounted or bytes == 0) return;
        if (!header.metaConst().alloc_info.nursery) self.heap_budget.discharge(bytes);
        // Production restores the publication bit; test/audit builds also
        // debit the independent lifecycle oracle compiled above.
        const is_large = self.isLargeAllocation(bytes);
        // A nursery cell never entered either ledger -- publication skips both
        // because a bump pointer has no raw-alloc/publish seam -- so retiring
        // one must not look for a record that was never written.
        const in_carrier_ledgers = !header.metaConst().alloc_info.nursery;
        if (comptime carrier_audit_enabled) {
            if (in_carrier_ledgers) {
                self.heap_accounting_oracle.recordUnpublish(@intFromPtr(header), bytes, is_large);
            }
        }
        header.meta().alloc_info.heap_accounted = false;
        if (comptime carrier.audit_enabled) {
            if (in_carrier_ledgers) {
                mem_ops.carrierTransition(self.runtime, @intFromPtr(header), .doomed) catch
                    @panic("gc: CARRIER IDENTITY: retirement missing carrier record");
            }
        }
        if (header.meta().alloc_info.standalone) header.meta().size_class = 0;
    }

    // The pin ledger's own API lives on `pins`; these three keep the
    // Registry spelling because the binding layer, the sweep and the tests
    // call them from dozens of sites and the account pointer is the
    // Registry's to supply.

    /// Is `header` pinned? The ledger's membership index, not a header read.
    pub inline fn headerIsPinned(self: *const Registry, header: *const Header) bool {
        return self.pins.contains(header);
    }

    pub fn pinHeader(self: *Registry, header: *Header) !void {
        return self.pins.pin(self.runtime, header);
    }

    pub fn unpinHeader(self: *Registry, header: *Header) void {
        self.pins.unpin(header);
    }

    // Heap live bytes are not stored. `gcDetailedStats` derives them from one
    // census. Ordinary `gcStats` does not. Test/audit builds retain a shadow
    // lifecycle oracle so the verifier can detect a census ownership omission.

    pub fn unlinkObjectWithBytes(self: *Registry, h: *Header, bytes: usize) void {
        self.recordHeapFreeWithBytes(h, bytes);
        // Condemnation detached this header before its resource destructor.
        // Let that structural stamp answer before kind, list, and generation
        // work.
        if (headerCondemned(h)) return;
        if (!isCycleCandidate(h)) return;
        if (h.metaConst().flags.kind == .object) {
            if (!isBlockCellHeader(h) and !isNurseryHeader(h)) self.removeNonBlockObject(h);
            return;
        }
        // Already unlinked, or condemned onto a morgue bucket.
        // qjs remove_gc_object is only called while the node is on gc_obj_list.
        if (!headerLinked(h) or headerCondemned(h)) return;
        self.removeGcObject(h);
    }

    /// Account an allocation already detached by `detachCycleCandidate`.
    ///
    /// Trace condemnation removes the object from every live membership
    /// structure before its resource destructor runs. The dominant object
    /// destructor can therefore skip the later generic unlink boundary
    /// entirely; only the byte ledger remains. Keeping this as a separate
    /// contract also prevents a future caller from accidentally treating the
    /// condemnation stamp as permission to omit accounting.
    pub inline fn recordDetachedHeapFreeWithBytes(self: *Registry, h: *Header, bytes: usize) void {
        if (comptime std.debug.runtime_safety) {
            std.debug.assert(headerCondemned(h));
        }
        self.recordHeapFreeWithBytes(h, bytes);
    }

    /// TGC S4-b spec 2.2: the ONE allocation + publication funnel for a bare
    /// storage cell (property entries, array elements, and in S4-c a-class
    /// payloads). Returns the BODY pointer (`base + 8`); the cell carries no
    /// out-edges and no destructor, so publication is all the collector needs
    /// before an owner's `storageCell` edge can name it.
    ///
    /// The body is left UNINITIALIZED: the caller fills it before any tracer
    /// or mutator can read it. That is sound because a storage cell is a leaf
    /// -- `traceHeaderEdges` returns immediately for these kinds -- and the
    /// window between this call and the owner's install is covered by the
    /// conservative stack scan resolving the caller's local to the cell
    /// itself (S4 spec 5 (4)).
    pub fn createStorageCellPublished(
        self: *Registry,
        kind_tag: u8,
        total_bytes: usize,
    ) ![*]u8 {
        const cell = try mem_ops.createStorageCell(self.runtime, kind_tag, total_bytes);
        const body = cell.base + metadata_prefix_size;
        self.addInitializedWithSizeNoFail(@ptrCast(@alignCast(body)), cell.accounted_bytes);
        return body;
    }

    /// TGC S4-d spec 2.4: retire every condemned cell of `block` that owes no
    /// destructor, after the finalizer subset has been drained and the block
    /// has left the doomed list.
    ///
    /// Production does this with WORD ARITHMETIC and never reads a header. The
    /// only header fact a free block cell owes anyone is `heap_accounted`, and
    /// every production reader of it (`Table.containsHeader`, both
    /// conservative resolvers, `clearYoungMarksStw`) tests the ALLOC BITMAP
    /// first, so a stale byte behind a cleared alloc bit is unobservable. The
    /// bytes were debited in one stroke at condemnation
    /// (`DoomedSnapshot.bitmap_bytes`).
    ///
    /// Two cold cases still walk the cells:
    ///   * audit builds, which own an independent publish/unpublish oracle and
    ///     a carrier lifecycle state machine that must see every retirement;
    ///   * a non-empty remembered map, which is keyed by header ADDRESS -- a
    ///     recycled cell left in it would be re-traced by the next minor.
    ///     Empty is the steady state (earley-boyer holds two entries; a major
    ///     retires the whole map at cycle begin).
    pub fn reclaimDoomedBlock(self: *Registry, block: *BlockHeapMod.Block) usize {
        const audit_walk = comptime carrier_audit_enabled;
        if (audit_walk or self.generation.rememberedCount() != 0) {
            const accounted = block.cell_size - metadata_prefix_size;
            const cells_base = @intFromPtr(block) + block.cells_offset + metadata_prefix_size;
            const cell_size: usize = block.cell_size;
            // TGC S4-g (4): word arithmetic, and one prefetch pass per word.
            //
            // The old shape asked `isDoomed(index)` for every INDEX, which
            // re-derived the bitmap base and re-loaded the same word up to 64
            // times to answer a question a single `@ctz` loop answers once.
            // That was the cheap half. The expensive half is that 77.30% of
            // this function's cycles (4.86% of the whole splay.fixed run) sit
            // on ONE instruction -- the `alloc_info` load of a corpse header,
            // a cold line the destruction slice is the first to touch since
            // the object died. Corpses are dense in the bitmap but the work
            // per corpse is a call (`State.forget`), so the out-of-order
            // window never had more than one of those misses in flight.
            // Issuing the whole word's prefetches first gives the block up to
            // 64 independent misses at once, over at most 64 lines.
            for (block.doomedWords(), 0..) |word_bits, word_index| {
                if (word_bits == 0) continue;
                var probe = word_bits;
                while (probe != 0) {
                    const bit: u6 = @intCast(@ctz(probe));
                    probe &= probe - 1;
                    const index: usize = word_index * 64 + bit;
                    if (index >= block.cell_count) break;
                    @prefetch(@as(*const u8, @ptrFromInt(cells_base + index * cell_size)), .{
                        .rw = .write,
                        .locality = 1,
                        .cache = .data,
                    });
                }
                var bits = word_bits;
                while (bits != 0) {
                    const bit: u6 = @intCast(@ctz(bits));
                    bits &= bits - 1;
                    const index: usize = word_index * 64 + bit;
                    if (index >= block.cell_count) break;
                    const header: *Header = @ptrFromInt(cells_base + index * cell_size);
                    self.unpublishStringCell(header, accounted);
                    if (comptime audit_walk) mem_ops.noteBlockCellBitmapReclaim(self.runtime, header);
                }
            }
        }
        return self.block_heap.reclaimDoomedCells(block);
    }

    /// Sweep-time return of a condemned storage BLOCK CELL. Pure memory: a
    /// storage cell owns no edges, no atom entry and no external resource, so
    /// unlike `string.destroyCellFromHeader` there is no handshake -- only the
    /// registry unpublish and the allocator free. The byte count comes from
    /// the block geometry rather than from the body, because a storage cell is
    /// not self-describing (its body IS the caller's array).
    ///
    /// The extent twin is the storage arm of `string.destroyDeadStringExtent`,
    /// which is handed `user_bytes` by `Heap.sweepExtents`.
    pub fn destroyStorageCell(self: *Registry, h: *Header) void {
        std.debug.assert(isBlockCellHeader(h));
        std.debug.assert(kindIsPrefixCarrier(h.metaConst().flags.kind));
        const total = storageCellBlockTotalBytes(h);
        self.unpublishStringCell(h, BlockHeapMod.accountedBodyBytesForRequest(total, metadata_prefix_size).?);
        mem_ops.destroyStringCell(self.runtime, h, total);
    }

    /// Allocation size (prefix included) of a storage cell served by a block
    /// cell: the size class it was handed, not the request it was born from.
    inline fn storageCellBlockTotalBytes(h: *const Header) usize {
        const cell = @intFromPtr(h) - metadata_prefix_size;
        return BlockHeapMod.Block.fromCellTrusted(cell).cell_size;
    }

    /// TGC S2: a condemned string BLOCK CELL leaves the registry. Cells are
    /// bitmap-owned (no list link, no occupant-table entry), so this is the
    /// byte debit plus the remembered-owner release -- the string twin of
    /// what `unregisterObjectWithBytes` does for an Object cell.
    pub fn unpublishStringCell(self: *Registry, h: *Header, bytes: usize) void {
        std.debug.assert(isBlockCellHeader(h));
        self.recordHeapFreeWithBytes(h, bytes);
        self.forgetGenerationalOwner(h);
    }

    /// TGC S2: unpublish an extent string the extent sweep found dead
    /// (`string.sweepExtents`). Not `unlinkObjectWithBytes`: that path
    /// reads the intrusive link word, which a string does not have. What a
    /// standalone string publication left behind is the byte ledger, the
    /// census; undo exactly those. Since S2-h1 there is no occupant entry to
    /// remove: the heap's `extent_pages` index is the extent's membership,
    /// and `Heap.free` unindexes it as part of returning the mapping.
    pub fn unpublishStringExtent(self: *Registry, h: *Header, bytes: usize) void {
        std.debug.assert(kindIsExtentCapable(h.metaConst().flags.kind));
        std.debug.assert(h.metaConst().alloc_info.standalone);
        self.recordHeapFreeWithBytes(h, bytes);
        self.forgetGenerationalOwner(h);
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
    /// A fourth phase enumerates TGC S2 extent strings (standalone `.string`
    /// prefixes over the cell ceiling). They have no link word, no cell and
    /// no bitmap, so the block heap's medium/large tables are their only
    /// enumeration -- without this phase every whole-heap census and every
    /// whole-heap checker was blind to the string bodies that dominate a
    /// string-heavy heap's bytes.
    ///
    /// Only `.all` gets it. The young selections must not: an extent is in
    /// the young SET but in no young CARRIER, so it has neither a young-block
    /// nor a list-suffix position to be produced from -- its young
    /// enumeration is `Heap.young_extents`
    /// (`Heap.sweepYoungExtents` / `retireYoungExtents`), and
    /// `verifyGenerationInvariants` adds that half to the census by hand.
    /// `.dead_block` must not either: that is a bitmap condemnation walk over
    /// block cells, and an extent is condemned against the mark epoch
    /// instead.
    ///
    /// Consumers see a header that is NOT an Object and NOT a list carrier:
    /// it has no `next_non_object` link and its mark lives in the extent
    /// table, so anything that dereferences past the eight-byte prefix must
    /// dispatch on `flags.kind` first. `Registry.headerMarked` /
    /// `setHeaderMarked` / `heapByteSizeFromHeader` already do.
    pub const GcObjectIterator = struct {
        cursor: ?*Header,
        sentinel: *const Header,
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
        young_block: BlockHeapMod.BlockLink = .unlinked,
        /// Extent phase cursor; null means the selection excludes extents or
        /// the phase is retired. This is the one part of the iterator that is
        /// not a scalar -- two hash-map key iterators -- so it is kept last,
        /// after the fields the earlier phases index.
        extents: ?BlockHeapMod.Heap.ExtentKeyIterator = null,

        pub fn next(self: *GcObjectIterator) ?*Header {
            if (self.cursor) |current| {
                if (current != self.sentinel) {
                    self.cursor = current.nextNonObject();
                    return current;
                }
                self.cursor = null;
            }
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
            if (self.side_objects) {
                const registry = self.registryFromSentinel();
                if (registry.nonblock_objects) |authority| {
                    // Re-read the storage on every step: a block or payload
                    // marker may publish another non-block Object and grow the
                    // backing array before or during this final phase.
                    while (self.blk_index < authority.items.items.len) {
                        const current = authority.items.items[self.blk_index];
                        self.blk_index += 1;
                        if (self.young_only and !current.metaConst().flags.young) continue;
                        if (self.unmarked_only and registry.headerMarked(current)) continue;
                        return current;
                    }
                }
            }
            if (self.extents) |*keys| {
                while (keys.next()) |base| {
                    const header: *Header = @ptrFromInt(base + metadata_prefix_size);
                    // The prefix exists from `createStringExtent`, but the
                    // object does not until publication stamps
                    // `heap_accounted` -- and `unpublishStringExtent`
                    // clears it again before the table entry goes away.
                    if (!header.metaConst().alloc_info.heap_accounted) continue;
                    std.debug.assert(kindIsExtentCapable(header.metaConst().flags.kind));
                    std.debug.assert(header.metaConst().alloc_info.standalone);
                    return header;
                }
                self.extents = null;
            }
            return null;
        }

        inline fn registryFromSentinel(self: *const GcObjectIterator) *const Registry {
            const list: *const IntrusiveHeaderList = @fieldParentPtr("sentinel", self.sentinel);
            const lists: *const Lists = @alignCast(@fieldParentPtr("objects", list));
            return @alignCast(@fieldParentPtr("lists", lists));
        }

        fn nextInBlock(self: *GcObjectIterator, block: *BlockHeapMod.Block, young_filter: bool) ?*Header {
            // Word-skipping: an empty word advances 64 cells on one load. The
            // first cut walked cell by cell with an atomic load each, which
            // priced enumeration at the block's CAPACITY -- slower than the
            // list it replaced.
            const words = block.allocWords();
            const epoch = self.heap.?.mark_epoch;
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
                const header: *Header = @ptrFromInt(block.cellBase(index) + metadata_prefix_size);
                if (!header.metaConst().alloc_info.heap_accounted) continue;
                if (young_filter) {
                    if (!header.metaConst().flags.young) continue;
                    // A condemned cell awaiting its destruction slice still
                    // carries its alloc bit and, until the trace retires it,
                    // its young bit. A minor may run between destruction
                    // slices, and a corpse handed to it would be reclaimed a
                    // second time. Its doomed bit is the discriminator.
                    if (block.isDoomed(index)) continue;
                }
                return header;
            }
            return null;
        }

        fn nextCell(self: *GcObjectIterator, heap: *const BlockHeapMod.Heap) ?*Header {
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

        fn nextYoungCell(self: *GcObjectIterator, heap: *const BlockHeapMod.Heap) ?*Header {
            _ = heap;
            while (self.young_block.next()) |block| {
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
    /// corpses remain visible in the alloc bitmap, while delisted carriers
    /// live in `doomed_by_kind` and non-block Objects in the side authority's
    /// doomed lane; current callback slots cover the interval after a bucket
    /// unlink and before the actual debit.
    const HeapAccountingIterator = struct {
        live: GcObjectIterator,
        doomed_by_kind: *const [gc_kind_count]IntrusiveHeaderList,
        doomed_objects: []const *Header,
        doomed_kind_index: usize = 0,
        doomed_cursor: ?*Header = null,
        doomed_object_index: usize = 0,
        sweep_current: ?*Header,
        current_yielded: bool = false,

        pub fn next(self: *HeapAccountingIterator) ?*Header {
            // TGC S2 string extents arrive from `live`'s extent phase
            // (`objectIterator(.all)`); this iterator adds only the corpses
            // that have already left it.
            if (self.live.next()) |header| return header;
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
            if (self.current_yielded) return null;
            self.current_yielded = true;
            const current = self.sweep_current orelse return null;
            if (current.metaConst().alloc_info.heap_accounted) return current;
            return null;
        }
    };

    pub const ObjectIteration = enum { all, dead_block, young, young_block, young_list };

    pub fn objectIterator(self: *const Registry, comptime selection: ObjectIteration) GcObjectIterator {
        const include_list = selection == .all or selection == .young or selection == .young_list;
        const include_blocks = selection != .young_list;
        const young_only = selection == .young or selection == .young_block or selection == .young_list;
        return .{
            .cursor = if (selection == .all)
                self.lists.objects.sentinel.next_non_object
            else if (include_list)
                self.lists.young_head
            else
                null,
            .sentinel = &self.lists.objects.sentinel,
            .heap = if (include_blocks) &self.block_heap else null,
            .unmarked_only = selection == .dead_block,
            .young_only = young_only,
            .side_objects = selection == .all or selection == .young or selection == .young_list,
            .young_block = if (comptime young_only and include_blocks)
                BlockHeapMod.BlockLink.at(self.block_heap.young_blocks)
            else
                .unlinked,
            .extents = if (selection == .all) self.block_heap.extentKeys() else null,
        };
    }

    pub fn heapAccountingIterator(self: *const Registry) HeapAccountingIterator {
        const authority = self.nonblock_objects;
        return .{
            .live = self.objectIterator(.all),
            .doomed_by_kind = &self.morgue.by_kind,
            .doomed_objects = if (authority) |value| value.doomed.items else &.{},
            .sweep_current = self.lists.sweep_current,
        };
    }

    /// Cold audit predicate passed into BlockHeap without introducing a module
    /// cycle. The block heap supplies the cell base; the Registry owns the
    /// exact construction-list membership authority.
    pub fn blockCellPublicationAllowance(
        context: *const anyopaque,
        cell_addr: usize,
    ) BlockHeapMod.Heap.UnpublishedCellAllowance.Kind {
        const self: *const Registry = @ptrCast(@alignCast(context));
        const header: *const Header = @ptrFromInt(cell_addr + metadata_prefix_size);
        if (self.pins.isConstructionRoot(header)) return .marked_construction;

        const meta = header.metaConst();
        if (meta.alloc_info.heap_accounted or
            !meta.flags.finalizing or
            !headerCondemned(header) or
            meta.flags.kind != .object or
            !isBlockCellHeader(header))
        {
            return .none;
        }
        return .parked_finalizer;
    }

    /// Heap-accounting runs both outside and after collections. A detached
    /// generator shell is a valid allocated-but-unpublished cell in the first
    /// case; collector publication audit separately requires its mark.
    pub fn blockCellAccountingAllowance(
        context: *const anyopaque,
        cell_addr: usize,
    ) BlockHeapMod.Heap.UnpublishedCellAllowance.Kind {
        const self: *const Registry = @ptrCast(@alignCast(context));
        const header: *const Header = @ptrFromInt(cell_addr + metadata_prefix_size);
        if (self.pins.isConstructionRoot(header)) return .unmarked_construction;
        return blockCellPublicationAllowance(context, cell_addr);
    }

    /// Served from the collector's block heap: enumerated by block bitmaps,
    /// never linked on `lists.objects`, young-tracked at block granularity.
    /// A bump-allocated young cell: no block, no allocation bitmap, no
    /// individual free. Its membership IS the nursery page it sits in, and a
    /// minor either copies it out or drops the whole page.
    pub inline fn isNurseryHeader(h: *const Header) bool {
        return h.metaConst().alloc_info.nursery;
    }

    pub inline fn isBlockCellHeader(h: *const Header) bool {
        // The CLASS FIELD is the marker, not the whole byte: publication sets
        // `heap_accounted` on top of it (0x1F becomes 0x5F), and comparing
        // the full byte made every published block object fail this test --
        // so they linked onto the list AND were enumerated by the block
        // phase, and the bitmap mark split never engaged at all.
        return h.metaConst().alloc_info.block_size_idx == representation.block_cell_size_class;
    }

    fn unregisterNonBlockObject(self: *Registry, header: *Header) void {
        std.debug.assert(header.metaConst().flags.kind == .object);
        std.debug.assert(!isBlockCellHeader(header));
        std.debug.assert(!isNurseryHeader(header));
        if (header.metaConst().alloc_info.standalone) {
            self.address_registry.remove(addressRegistryAllocator(), header);
        }
        self.forgetGenerationalOwner(header);
    }

    fn removeNonBlockObject(self: *Registry, header: *Header) void {
        const authority = self.nonblock_objects orelse return;
        if (!authority.remove(header)) return;
        self.unregisterNonBlockObject(header);
    }

    /// Move a live non-block Object into the header-external condemnation
    /// lane. Publication pre-reserves the lane for the whole extant Object
    /// population, so the collector-side move cannot allocate.
    pub fn condemnNonBlockObject(self: *Registry, header: *Header) void {
        std.debug.assert(header.metaConst().flags.kind == .object);
        std.debug.assert(!isBlockCellHeader(header));
        std.debug.assert(!isNurseryHeader(header));
        std.debug.assert(!headerCondemned(header));
        const authority = self.nonblock_objects.?;
        authority.condemn(header);
        self.unregisterNonBlockObject(header);
        stampHeaderCondemned(header);
    }

    /// qjs `list_del` / `remove_gc_object`. Already-unlinked
    /// headers (deinit shape self-remove) are a no-op; a linked node is spliced
    /// with no head/tail null branches.
    fn removeGcObject(self: *Registry, header: *Header) void {
        std.debug.assert(header.metaConst().flags.kind != .object);
        if (!headerLinked(header)) return;
        const previous = self.lists.objects.predecessor(header);
        self.removeGcObjectAfter(previous, header);
    }

    /// O(1) list detach for a collector already walking `lists.objects`.
    fn removeGcObjectAfter(self: *Registry, previous: *Header, header: *Header) void {
        std.debug.assert(previous.next_non_object == header);
        // `unregisterLiveAddress` owns the young-suffix anchor fixup for every
        // detach path; it runs before the `listDel` below so `header.next` is
        // still the successor it needs.
        const removed_predecessor = self.lists.young_predecessor == header;
        self.unregisterLiveAddress(header);
        if (removed_predecessor) self.lists.young_predecessor = previous;
        if (self.lists.young_head == null) self.lists.young_predecessor = null;
        self.lists.objects.delAfter(previous, header);
    }

    pub inline fn headerMarked(self: *const Registry, h: *const Header) bool {
        if (h.metaConst().alloc_info.block_size_idx == representation.block_cell_size_class) {
            const cell = @intFromPtr(h) - metadata_prefix_size;
            const block = BlockHeapMod.Block.fromCellTrusted(cell);
            return block.isMarked(h.metaConst().size_class, self.block_heap.mark_epoch);
        }
        // TGC S2 extent string (spec §5.7): no bitmap and no TraceHeader
        // epoch either -- the mark lives in the heap's extent table,
        // keyed by the allocation base (body - 8). Cold: only strings
        // over the cell ceiling get here. The extent path excludes ropes:
        // `allocRopeNode` asserts at comptime that a
        // rope node always fits a cell, so no rope is ever an extent.
        if (kindIsExtentCapable(h.metaConst().flags.kind) and h.metaConst().alloc_info.standalone) {
            @branchHint(.unlikely);
            const base = @intFromPtr(h) - metadata_prefix_size;
            // An extent-capable standalone prefix that is NOT a live
            // extent means a stale resolution reached a freed mapping;
            // `extentIsMarked` would then read through an absent table
            // entry. This is the assertion that named the S2-i occupant
            // leak (a `.string_buffer` extent took an occupant entry that
            // `unpublishStringExtent` no longer removes).
            std.debug.assert(self.block_heap.containsExtent(base));
            return self.block_heap.extentIsMarked(base, self.block_heap.mark_epoch);
        }
        if (std.debug.runtime_safety) std.debug.assert(isCycleCandidate(h));
        return @atomicLoad(u16, &h.metaConst().lifetime.mark_epoch, .monotonic) == self.marking.header_epoch;
    }

    /// Mark probe for a typed carrier whose representation descriptor excludes
    /// block cells. Shape edges dominate object tracing and are known to use
    /// the fixed header epoch; routing each one through the object-only block
    /// discriminator repeats work for every object sharing the same shape.
    pub inline fn headerMarkedKnownNonBlock(self: *const Registry, h: *const Header) bool {
        std.debug.assert(h.metaConst().alloc_info.block_size_idx != representation.block_cell_size_class);
        return @atomicLoad(u16, &h.metaConst().lifetime.mark_epoch, .monotonic) == self.marking.header_epoch;
    }

    pub inline fn setHeaderMarked(self: *const Registry, h: *Header) void {
        if (h.metaConst().alloc_info.block_size_idx == representation.block_cell_size_class) {
            const cell = @intFromPtr(h) - metadata_prefix_size;
            const block = BlockHeapMod.Block.fromCellTrusted(cell);
            block.setMark(h.metaConst().size_class, self.block_heap.mark_epoch);
            return;
        }
        // Extent string: table-held mark, see `headerMarked`.
        if (kindIsExtentCapable(h.metaConst().flags.kind) and h.metaConst().alloc_info.standalone) {
            @branchHint(.unlikely);
            self.block_heap.extentSetMark(@intFromPtr(h) - metadata_prefix_size, self.block_heap.mark_epoch);
            return;
        }
        if (std.debug.runtime_safety) std.debug.assert(isCycleCandidate(h));
        @atomicStore(u16, &h.meta().lifetime.mark_epoch, self.marking.header_epoch, .monotonic);
    }

    /// TGC S4-a: record that this carrier's death owes a destructor call.
    ///
    /// Writes the fact twice on purpose. The header bit answers a single
    /// carrier (extents, non-block kinds, audits); the block bitmap lets the
    /// S4-d sweep intersect `doomed & finalizer` a word at a time and never
    /// read the header of a corpse that owes nothing. D-S4-4: set-only --
    /// the bit is cleared only when the cell itself is released
    /// (`Heap.freeSmall` / `settleDoomedCellInPassA`).
    pub fn setNeedsFinalizer(self: *Registry, header: *Header) void {
        header.meta().flags.needs_finalizer = true;
        const meta = header.metaConst();
        if (meta.alloc_info.block_size_idx == representation.block_cell_size_class) {
            const cell = @intFromPtr(header) - metadata_prefix_size;
            BlockHeapMod.Block.fromCellTrusted(cell).setFinalizerBit(meta.size_class);
            return;
        }
        // Only a block-heap EXTENT has a table row to stamp. A standalone
        // prefix alone does not prove one: non-block Objects, shapes, modules
        // and the rest come from the slab allocator and keep the header bit
        // alone. Since S4-b/S4-c the storage kinds allocate extents too, which
        // is why the test is `kindIsExtentCapable` and not "is it a string".
        if (meta.alloc_info.standalone and kindIsExtentCapable(meta.flags.kind)) {
            self.block_heap.extentSetNeedsFinalizer(@intFromPtr(header) - metadata_prefix_size);
        }
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
    /// break `young_head`'s exact-suffix invariant over `lists.objects`.
    ///
    /// TGC S4-h (2): minors run the same transaction. A minor's trace reads
    /// the same header line for the same reason, and the walk it replaces --
    /// `collectMinor`'s `objectIterator(.young)` promotion pass -- streamed
    /// the `alloc_info` byte of EVERY allocated cell of every young block.
    pub inline fn retireTracedYoung(self: *Registry, h: *Header) void {
        if (!self.generation.retirementOpen()) return;
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
            std.debug.assert(!headerCondemned(h));
        }
        // A nursery cell's youth ends when its page does. Clearing the bit
        // here would make a surviving husk look old to the page walk.
        if (h.metaConst().alloc_info.nursery) return;
        if (h.metaConst().alloc_info.block_size_idx == representation.block_cell_size_class) {
            h.meta().flags.young = false;
        }
    }

    pub inline fn setHeaderUnmarked(self: *const Registry, h: *Header) void {
        if (h.metaConst().alloc_info.block_size_idx == representation.block_cell_size_class) {
            const cell = @intFromPtr(h) - metadata_prefix_size;
            const block = BlockHeapMod.Block.fromCellTrusted(cell);
            block.clearMark(h.metaConst().size_class, self.block_heap.mark_epoch);
            return;
        }
        if (std.debug.runtime_safety) std.debug.assert(isCycleCandidate(h));
        @atomicStore(u16, &h.meta().lifetime.mark_epoch, 0, .monotonic);
    }

    /// O(1) whole-population unmark for the ordinary case. One wrap scrub is
    /// required before reusing epoch 1; 0 always remains newborn/unmarked.
    pub fn advanceHeaderMarkEpoch(self: *Registry) void {
        // Two short of `condemned_mark_epoch`: neither reserved stamp --
        // condemnation (TGC S4-h) nor forwarding -- may ever be produced as a
        // live mark epoch.
        if (self.marking.header_epoch < forwarded_mark_epoch - 1) {
            self.marking.header_epoch += 1;
            return;
        }

        var cursor = self.lists.objects.sentinel.next_non_object;
        while (cursor) |header| {
            if (header == &self.lists.objects.sentinel) break;
            @atomicStore(u16, &header.meta().lifetime.mark_epoch, 0, .monotonic);
            cursor = header.nextNonObject();
        }
        if (self.nonblock_objects) |authority| {
            for (authority.items.items) |header| {
                @atomicStore(u16, &header.meta().lifetime.mark_epoch, 0, .monotonic);
            }
        }
        self.marking.header_epoch = 1;
    }

    pub fn detachCycleCandidate(self: *Registry, header: *Header) void {
        std.debug.assert(!headerCondemned(header));
        if (header.metaConst().flags.kind == .object) {
            if (!isBlockCellHeader(header) and !isNurseryHeader(header))
                self.removeNonBlockObject(header);
        } else {
            self.removeGcObject(header);
        }
        stampHeaderCondemned(header);
    }

    /// Detach for a header produced by a block-only iterator. Allocation
    /// bitmap ownership proves there is no intrusive or side membership to
    /// remove, so the production sweep need only stamp the condemnation.
    pub inline fn detachBlockObjectCandidate(header: *Header) void {
        if (comptime std.debug.runtime_safety) {
            std.debug.assert(!headerCondemned(header));
            const cell_kind = header.metaConst().flags.kind;
            std.debug.assert(kindIsBlockCellKind(cell_kind));
            std.debug.assert(isBlockCellHeader(header));
        }
        stampHeaderCondemned(header);
    }

    /// Sequential-sweep twin of `detachCycleCandidate`; the predecessor must
    /// still name the live-list node immediately before `header`.
    pub fn detachCycleCandidateAfter(self: *Registry, previous: *Header, header: *Header) void {
        std.debug.assert(!headerCondemned(header));
        self.removeGcObjectAfter(previous, header);
        stampHeaderCondemned(header);
    }

    /// Discard an open incremental cycle so a full STW collection can run.
    /// Discard the pacing envelope a collection was about to be priced
    /// against. Callers reach this when they give up on a cycle before it
    /// starts (allocation failure, teardown).
    pub fn abortCycle(self: *Registry) void {
        self.abortCycleEnvelope();
    }

    /// Publish the settled account and the threshold derived from it for the
    /// next automatic incremental cycle. This pair is one policy decision;
    /// keeping it intact is what makes the later S/T/P tuple same-domain.
    pub fn noteCycleEnvelopeBaseline(self: *Registry, start_bytes: usize, threshold_bytes: usize) void {
        if (!gc_trace_stw_reports.detailed_reports) return;
        std.debug.assert(!self.incremental.envelope_active);
        if (self.incremental.envelope_baseline_valid) self.heap_budget.endCyclePeakTracking();
        self.incremental.envelope_next_start_bytes = start_bytes;
        self.incremental.envelope_next_threshold_bytes = threshold_bytes;
        self.incremental.envelope_cycle_peak_bytes = start_bytes;
        self.incremental.envelope_baseline_valid = threshold_bytes != 0;
        if (self.incremental.envelope_baseline_valid) {
            self.heap_budget.beginCyclePeakTracking(&self.incremental.envelope_cycle_peak_bytes);
        }
    }

    /// A caller-supplied threshold has no settled S selected by the growth
    /// policy, so the next cycle must not be presented as §1.3 evidence.
    pub fn invalidateCycleEnvelopeBaseline(self: *Registry) void {
        if (self.incremental.envelope_active) {
            self.heap_budget.endCyclePeakTracking();
            self.incremental.envelope_active = false;
            self.incremental.stats.envelope_skipped_cycles +|= 1;
        } else if (self.incremental.envelope_baseline_valid) {
            self.heap_budget.endCyclePeakTracking();
        }
        self.incremental.envelope_baseline_valid = false;
    }

    /// Consume the preceding reset's S/T pair and begin exact account-peak
    /// tracking before any initial-mark allocation can occur.
    pub fn beginCycleEnvelope(self: *Registry, threshold_bytes: usize) void {
        if (!gc_trace_stw_reports.detailed_reports) return;
        std.debug.assert(!self.incremental.envelope_active);
        if (!self.incremental.envelope_baseline_valid or
            self.incremental.envelope_next_threshold_bytes != threshold_bytes)
        {
            self.invalidateCycleEnvelopeBaseline();
            self.incremental.stats.envelope_skipped_cycles +|= 1;
            return;
        }
        self.incremental.envelope_baseline_valid = false;
        self.incremental.envelope_cycle_start_bytes = self.incremental.envelope_next_start_bytes;
        self.incremental.envelope_cycle_threshold_bytes = threshold_bytes;
        self.incremental.envelope_cycle_begin_bytes = self.heap_budget.bytes;
        self.incremental.envelope_active = true;
    }

    fn abortCycleEnvelope(self: *Registry) void {
        if (!self.incremental.envelope_active) return;
        self.heap_budget.endCyclePeakTracking();
        self.incremental.envelope_active = false;
    }

    pub fn finishCycleEnvelope(self: *Registry) void {
        if (!self.incremental.envelope_active) return;
        self.heap_budget.endCyclePeakTracking();
        self.incremental.envelope_active = false;

        const start = self.incremental.envelope_cycle_start_bytes;
        const threshold = self.incremental.envelope_cycle_threshold_bytes;
        const begin = self.incremental.envelope_cycle_begin_bytes;
        const peak = self.incremental.envelope_cycle_peak_bytes;
        std.debug.assert(threshold != 0);
        std.debug.assert(peak >= threshold);
        const stats = &self.incremental.stats;
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

    /// Whether a minor is worth attempting: enough young objects to be worth
    /// the root scan, and no full collection already in flight. Deliberately
    /// simple — the scheduling policy that replaces it belongs with the
    /// allocation-headroom work, not with the collector mechanism.
    pub inline fn shouldTryMinor(self: *const Registry) bool {
        if (self.hot.phase != .none) return false;
        // Before the stress arm, not after: an open retirement transaction is
        // a correctness condition, and a diagnostic knob must not be able to
        // step past it. (Adversarial review, codex, 2026-08-27.)
        if (!self.generation.minorsAllowed()) return false;
        // The stress knob deliberately keeps reading the POPULATION, not the
        // trigger census: its contract is "collect whenever anything is
        // young", and a heap holding only owned storage cells is still a heap
        // a stress run must be able to walk.
        if (forensics.stressing()) return self.generation.stats.young_count != 0;
        // A minor that keeps coming back empty is a root and stack scan spent
        // to learn that this workload's young objects do not die. Stop asking
        // until a major changes the answer.
        if (self.generation.minorSuspended()) return false;
        // S4-f (1): the size question is asked of `young_trigger_count`, which
        // excludes the owned storage cells S4-b/c/S2-i moved into the heap. A
        // property buffer that grows 4 -> 8 -> 16 entries publishes three
        // young cells and adds nothing a minor can reclaim on its own; on
        // regexp that inflation alone took the minor count 641 -> 913.
        // Minors run even while sliced destruction is pending. The first
        // version gated them, and the gate was the disease: destruction
        // windows with no minor let the young set grow to the millions
        // (measured 1.7M at minor start on splay), the completion-time
        // account ballooned, and the 1.75x threshold amplified it into a
        // five-fold heap. What made the gate necessary -- a minor's
        // conservative scan resolving a parked corpse -- is handled at the
        // one point every scan funnels through: `shade` refuses condemned
        // headers, the mark-epoch stamp `detachCycleCandidate` already writes
        // on everything in the morgue.
        if (self.nursery.enabled and self.nursery.allocated_bytes >= nursery_mod.collection_trigger_bytes)
            return true;
        return self.generation.stats.young_trigger_count >= minor_young_threshold;
    }

    /// The same minor, asked at a crossed whole-heap threshold, where only the
    /// SIZE question differs. `shouldTryMinor` asks "is the young set big
    /// enough that a root scan pays for itself"; here the alternative is not
    /// "do nothing" but "trace the whole heap", so the bar is
    /// `minor_crossing_young_floor` instead of `minor_young_threshold`.
    ///
    /// The 16k-object bar is what made the S2-g repair a no-op on its first
    /// measurement. pdfjs allocates ~1KB per publication, so ~10 MB of young
    /// garbage -- the amount that crosses a 24 MB threshold over a 13.6 MB
    /// live set -- is only ~10k objects, and every crossing therefore found
    /// `shouldTryMinor` false and went straight to a whole-heap major: 904 of
    /// them.
    ///
    /// Every other guard is retained verbatim, including the suspension (a
    /// minor proven to reclaim nothing must not be prepended to the major) and
    /// the stress-knob ordering.
    pub inline fn shouldTryMinorBeforeMajor(self: *const Registry) bool {
        if (self.hot.phase != .none) return false;
        if (!self.generation.minorsAllowed()) return false;
        if (forensics.stressing()) return self.generation.stats.young_count != 0;
        if (self.nursery.enabled and self.nursery.allocated_bytes >= nursery_mod.collection_trigger_bytes)
            return true;
        if (self.generation.stats.young_trigger_count < minor_crossing_young_floor) return false;
        if (self.generation.minorSuspended()) return false;
        return true;
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
    /// marking arm was "deliberately absent" because a choke point cannot
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
    pub inline fn rememberOwnerForBulkWrite(self: *Registry, owner: *Header) void {
        if (self.barrierOwnerSkips(owner)) return;
        self.rememberOwnerForBulkWriteSlow(owner);
    }

    fn rememberOwnerForBulkWriteSlow(self: *Registry, owner: *Header) void {
        @branchHint(.cold);
        // The gate proves the owner old and unremembered -- EXCEPT when
        // `detailed_reports` closed the gate for accounting reasons, in which
        // case nothing has been proven and the young test still has to run.
        if (owner.metaConst().flags.young) return;
        self.rememberGenerationalOwner(owner);
    }

    /// The gate value the current phase demands.
    ///
    /// One definition, two consumers: `refreshBarrierGate` publishes it, and
    /// the fast path's safety check re-derives it to prove the published copy
    /// is not stale. Keeping them the same expression is the point -- a gate
    /// computed one way and checked another checks nothing.
    inline fn expectedBarrierGate() u64 {
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
        self.hot.barrier_gate = expectedBarrierGate();
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
    pub inline fn barrierOwnerSkips(self: *const Registry, owner: *const Header) bool {
        if (comptime std.debug.runtime_safety) {
            // C1. A stale gate is the one way this fold can go silently wrong,
            // and it is invisible from the slow path: a gate that wrongly
            // permits a skip never reaches it. So check it here, on every
            // barrier call, in every safety build.
            std.debug.assert(self.hot.barrier_gate == expectedBarrierGate());
            // C2. The gate reads byte 6 bit7 as the remembered lease, which is
            // only that for eligible kinds: `.string` has no `Metadata` prefix
            // at all, and `.big_int` aliases the byte onto its live refcount.
            // Audit §10.3 walked every barrier call site and found neither
            // kind; this turns that survey into a machine check.
        }
        return barrierOwnerWord(owner) & self.hot.barrier_gate != 0;
    }

    /// Target-bearing callers reach the bit only after old-owner/young-target
    /// classification, so the 91% young-owner exit and old-target exit pay
    /// nothing for it; bulk callers likewise classify the owner first. Object
    /// owners use Metadata byte 6 as a membership cache; the hash map remains
    /// authoritative and every non-object owner keeps the existing fallback.
    inline fn rememberGenerationalOwner(self: *Registry, owner: *Header) void {
        // A young owner is never remembered: the next minor traces it anyway,
        // and the set keys on the ADDRESS -- which a copying collection
        // changes. Remembering one leaves an entry naming a page that the
        // collection has already handed back, and the minor after that traces
        // whatever now occupies it.
        //
        // The barrier's gate normally makes this unreachable (a young owner
        // buys an exit), but the gate reads a cached bit and this is the
        // authority; the nursery is the first carrier where disagreeing is
        // fatal rather than merely wasteful.
        if (owner.metaConst().flags.young) return;
        const summary = &owner.meta().lifetime.object_shape_summary;
        if (summary.* & trace_remembered_mask != 0) return;
        if (!self.generation.rememberOwner(addressRegistryAllocator(), owner)) return;
        summary.* |= trace_remembered_mask;
    }

    inline fn clearGenerationalRememberedBit(owner: *Header) void {
        owner.meta().lifetime.object_shape_summary &= ~trace_remembered_mask;
    }

    inline fn clearGenerationalRememberedBits(self: *Registry) void {
        var remembered = self.generation.rememberedIterator();
        while (remembered.next()) |addr| {
            const owner: *Header = @ptrFromInt(addr.*);
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
    pub inline fn forgetGenerationalOwner(self: *Registry, header: *Header) void {
        const summary = &header.meta().lifetime.object_shape_summary;
        if (summary.* & trace_remembered_mask == 0) {
            self.generation.forgetUnremembered(header);
            return;
        }
        summary.* &= ~trace_remembered_mask;
        self.generation.forget(header);
    }

    inline fn generationalBarrierDetailed(self: *Registry, owner: *Header, target: *Header) void {
        self.generation.stats.barrier_calls += 1;
        if (owner.metaConst().flags.young) {
            self.generation.stats.barrier_young_owner += 1;
            return;
        }
        if (!target.metaConst().flags.young) {
            self.generation.stats.barrier_old_target += 1;
            return;
        }
        self.rememberGenerationalOwner(owner);
    }

    /// TGC S0 L3 audit probe. Placed after
    /// a store that static reading found unbarriered; counts the exact state
    /// the generational barrier exists to prevent: a published, OLD,
    /// UNREMEMBERED owner now holding an edge to a YOUNG child. Only the
    /// authoritative remembered map is consulted, never the cache bit.
    ///
    /// Erased in ReleaseFast (`runtime_safety` is false there) so the shipped
    /// `zjs` carries no symbol; armed in Debug / ReleaseSafe test binaries,
    /// in Debug `zjs`, and in the `-Dzjs_gc_roots_diag` ReleaseFast binary
    /// (which is how Octane runs under the probe at speed); gated at run time
    /// on `ZJS_MINOR_AUDIT`.
    pub inline fn auditUnbarrieredStore(
        self: *Registry,
        owner: *Header,
        child: ?*Header,
        comptime site: UnbarrieredStoreSite,
    ) void {
        if (comptime !std.debug.runtime_safety) return;
        if (!forensics.auditing()) return;
        const target = child orelse return;
        @call(.never_inline, auditUnbarrieredStoreSlow, .{ self, owner, target, site });
    }

    fn auditUnbarrieredStoreSlow(
        self: *Registry,
        owner: *Header,
        target: *Header,
        site: UnbarrieredStoreSite,
    ) void {
        if (!owner.metaConst().alloc_info.heap_accounted) return;
        if (owner.metaConst().flags.young) return;
        if (!target.metaConst().flags.young) return;
        var it = self.generation.rememberedIterator();
        while (it.next()) |addr| {
            if (addr.* == @intFromPtr(owner)) return;
        }
        const slot = &self.unbarriered_store_hits[@intFromEnum(site)];
        slot.* += 1;
        const owner_class: u32 = if (owner.metaConst().flags.kind == .object)
            object.Object.fromHeader(owner).class_id
        else
            0;
        std.debug.print("UNBARRIERED-STORE site={s} hit={d} owner_kind={s} owner_class={d} child_kind={s}\n", .{
            @tagName(site),
            slot.*,
            @tagName(owner.metaConst().flags.kind),
            owner_class,
            @tagName(target.metaConst().flags.kind),
        });
        if (slot.* == 1) std.debug.dumpCurrentStackTrace(.{});
        if (forensics.auditIsFatal()) @panic("UNBARRIERED-STORE: old unremembered owner gained a young child without a barrier");
    }

    /// Header-shaped write barrier. The whole steady-state decision is
    /// `barrierOwnerSkips`; everything below it is a phase the gate has
    /// already announced by being zero.
    pub inline fn generationalBarrier(self: *Registry, owner: *Header, child: ?*Header) void {
        const target = child orelse return;
        if (self.barrierOwnerSkips(owner)) return;
        self.generationalBarrierSlow(owner, target);
    }

    /// Everything the folded fast path stopped doing inline.
    ///
    /// The exact-target shading arm stays a real arm rather than being folded
    /// into the gate: §8.4's tearing premise is what makes owner-only records
    /// unsound under a real parallel marker, and JSC's 8-byte atomic escape
    /// hatch does not exist for a 16-byte JSValue. The gate carries the PHASE
    /// decision; the arm carries the semantics.
    fn generationalBarrierSlow(self: *Registry, owner: *Header, target: *Header) void {
        @branchHint(.cold);
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
        //
        // An UNPUBLISHED target counts as young. It carries no young bit yet
        // -- publication is what sets one -- so testing the bit alone lets an
        // old owner take a reference to an object that becomes young a moment
        // later, with nothing recording the edge. The next minor then never
        // traces the owner, and the target is either swept or, under a copying
        // young generation, left behind as a stale edge into a reclaimed page.
        const target_info = target.metaConst();
        if (!target_info.flags.young and target_info.alloc_info.heap_accounted) return;
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
    pub inline fn generationalBarrierValue(self: *Registry, owner: *Header, child: JSValue) void {
        if (comptime std.debug.runtime_safety) self.assertStoreIsCurrent(child);
        if (self.barrierOwnerSkips(owner)) return;
        const target = child.cycleMarkHeader() orelse return;
        self.generationalBarrierSlow(owner, target);
    }

    /// A store of a reference that names a page the last collection handed
    /// back. The value came from a native local that outlived the collection,
    /// so this fails at the STORE -- the one place the stack still names the
    /// code that should have rooted it.
    fn assertStoreIsCurrent(self: *const Registry, child: JSValue) void {
        const target = child.cycleMarkHeader() orelse return;
        if (!self.nursery.wasReclaimed(@intFromPtr(target))) return;
        @panic("gc: storing a reference to a reclaimed young page -- the value outlived a collection without a root");
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

    /// Register a young survivor that was just copied into an old-generation
    /// cell.
    ///
    /// Deliberately NOT `publishInitialized`. That path is for an object
    /// coming into existence, and a promoted object is not: it carries the
    /// mark the collection just gave it (so the newborn-lifetime assertion
    /// rejects it), and it is OLD, so setting the young bit and counting it
    /// into the young census -- which is what publication does -- would put
    /// it back in the population the collection is retiring.
    ///
    /// What it shares with publication is the part that is about the CELL
    /// rather than the object: the accounting bit, the carrier ledgers, and
    /// the block heap's live-address bookkeeping.
    pub fn publishPromotedCell(self: *Registry, h: *Header, bytes: usize) void {
        std.debug.assert(isBlockCellHeader(h));
        std.debug.assert(!h.metaConst().alloc_info.heap_accounted);
        std.debug.assert(!headerCondemned(h));
        h.meta().alloc_info.heap_accounted = true;
        const is_large = self.isLargeAllocation(bytes);
        if (comptime carrier_audit_enabled) {
            self.heap_accounting_oracle.recordPublish(@intFromPtr(h), bytes, is_large);
        }
        if (comptime carrier.audit_enabled) {
            mem_ops.carrierPublish(self.runtime, @intFromPtr(h), bytes) catch
                @panic("gc: CARRIER IDENTITY: promotion missing carrier record");
        }
        self.observeNewPublication(h, bytes);
    }

    /// Copy a young cell into the old generation and leave a forwarding
    /// address behind.
    ///
    /// The new cell is a block cell, so the copy is not a straight memcpy of
    /// the whole allocation: the block allocator has already stamped the cell
    /// INDEX into the prefix's first two bytes, and that stamp belongs to the
    /// destination, not the source. Body bytes come over whole; the prefix is
    /// rebuilt from the source's kind and flags with the carrier field set to
    /// the destination's.
    ///
    /// Null means the old generation could not take it. That is not an error:
    /// the caller pins the object instead, which retains its page and leaves
    /// the object old in place.
    pub fn promoteYoungCell(self: *Registry, rt: *JSRuntime, old: *Header) ?*Header {
        std.debug.assert(isNurseryHeader(old));
        std.debug.assert(!headerForwarded(old));
        const body_bytes = heapByteSizeFromHeader(rt, old);
        const request = body_bytes + metadata_prefix_size;
        if (!BlockHeapMod.canAllocCellSize(request)) return null;
        const cell_raw = mem_ops.allocPromotedObjectCell(self.runtime, request) orelse return null;
        const cell = @intFromPtr(cell_raw);
        const moved: *Header = @ptrFromInt(cell + metadata_prefix_size);

        const source_meta = old.metaConst().*;
        @memcpy(
            @as([*]u8, @ptrFromInt(@intFromPtr(moved)))[0..body_bytes],
            @as([*]const u8, @ptrFromInt(@intFromPtr(old)))[0..body_bytes],
        );
        // Carrier field is the destination's; everything else describes the
        // object and comes across unchanged. `heap_accounted` is cleared so
        // the publication below is the one that sets it, exactly as it is for
        // a freshly allocated cell.
        moved.meta().flags = source_meta.flags;
        moved.meta().lifetime = source_meta.lifetime;
        moved.meta().alloc_info = .{ .block_size_idx = representation.block_cell_size_class, .nursery = false };
        moved.meta().flags.young = false;

        object.Object.fromHeader(moved).rebindAfterRelocation(@intFromPtr(old), body_bytes);
        setForwarding(old, moved, body_bytes);
        // Poison what the copy left behind, in safety builds. Without this the
        // husk still holds the object's old field values, so code that kept a
        // bare pointer across the collection keeps WORKING for a while and
        // fails somewhere unrelated -- a corrupt switch value three call
        // frames away. Poisoned, it fails at the use, which is the only place
        // the missing root can be read off a stack trace. The first word is
        // the forwarding address and the metadata prefix is the size, so both
        // stay readable.
        if (comptime std.debug.runtime_safety) {
            const body: [*]u8 = @ptrFromInt(@intFromPtr(old));
            if (body_bytes > @sizeOf(usize)) {
                @memset(body[@sizeOf(usize)..body_bytes], 0xDE);
            }
        }
        return moved;
    }

    /// The nursery's page table shares the address registry's independence
    /// requirement and its reasoning: it grows on the allocation path and may
    /// not recurse into the JS heap allocator.
    inline fn nurseryAllocator() std.mem.Allocator {
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
    /// How many `NonBlockObjectAuthority` objects are currently allocated.
    /// Construction rollback and `Registry.deinit` both go through
    /// `destroyNonblockAuthority`, so a failed `JSRuntime` init must leave
    /// this where it started.
    pub var nonblock_authorities_live_for_test: if (builtin.is_test) usize else void =
        if (builtin.is_test) 0 else {};

    /// When set, the next `serveObjectCells` installs heap pointers and then
    /// returns `error.OutOfMemory` before the authority allocation.
    pub var fail_nonblock_authority_for_test: if (builtin.is_test) bool else void =
        if (builtin.is_test) false else {};

    fn destroyNonblockAuthority(self: *Registry) void {
        const authority = self.nonblock_objects orelse return;
        authority.deinit(addressRegistryAllocator());
        addressRegistryAllocator().destroy(authority);
        self.nonblock_objects = null;
        if (comptime builtin.is_test) nonblock_authorities_live_for_test -= 1;
    }

    /// Drop what `init` / `initLists` / `serveObjectCells` acquired.
    /// No heap walk: shapes, atoms, and classes are not owned here, and a
    /// half-built runtime must not enter `deinit`.
    pub fn rollbackConstruction(self: *Registry) void {
        const account = self.runtime;
        self.destroyNonblockAuthority();
        mem_ops.deinitGcCarrier(account);
        self.cell_storage.slab.arena_observer = null;
        self.arena_slab = null;
        self.address_registry.deinit(addressRegistryAllocator());
        self.generation.deinit(addressRegistryAllocator());
        self.nursery.deinit(self.nursery.page_allocator);
        self.block_heap.deinit();
        self.external.deinit(account);
        self.pins.deinit(account);
        if (comptime carrier_audit_enabled) {
            std.debug.assert(self.heap_accounting_oracle.raw.count() == 0);
            self.heap_accounting_oracle.deinit(std.heap.page_allocator);
        }
    }

    pub fn serveObjectCells(self: *Registry) !void {
        // The conservative resolver needs the block geometry before the first
        // cell can appear in a stack slot.
        self.address_registry.block_heap = &self.block_heap;
        // One cell store, owned here. The account only forwards.
        self.cell_storage.block_heap = &self.block_heap;
        self.nursery.page_allocator = nurseryAllocator();
        self.nursery.enabled = nursery_enabled;
        self.cell_storage.nursery = &self.nursery;
        if (comptime carrier_audit_enabled) {
            self.cell_storage.heap_oracle = &self.heap_accounting_oracle;
        }

        if (comptime builtin.is_test) {
            if (fail_nonblock_authority_for_test) {
                fail_nonblock_authority_for_test = false;
                return error.OutOfMemory;
            }
        }
        const authority = try addressRegistryAllocator().create(NonBlockObjectAuthority);
        authority.* = .{};
        self.nonblock_objects = authority;
        if (comptime builtin.is_test) nonblock_authorities_live_for_test += 1;
    }

    fn noteSlabArenaCreated(ctx: *anyopaque, base: usize) void {
        const registry: *Registry = @ptrCast(@alignCast(ctx));
        registry.address_registry.noteArenaCreated(addressRegistryAllocator(), base);
    }

    fn noteSlabArenaReleased(ctx: *anyopaque, base: usize) void {
        const registry: *Registry = @ptrCast(@alignCast(ctx));
        registry.address_registry.noteArenaReleased(base);
    }

    pub fn observeSlabArenas(self: *Registry, slab: *memory.SmallObjectSlab) void {
        // Kept so a failed arena registration can be recovered by re-walking
        // the slab, instead of leaving that arena invisible for its whole life.
        self.arena_slab = slab;
        // Arenas that already exist. In the current `initInPlace` order
        // there are none -- `enableSmallObjectSlab` runs afterwards, so this
        // walk visits nothing -- but the observer's correctness must not depend
        // on that ordering, because an arena created before it is installed is
        // invisible to the conservative scanner forever.
        slab.forEachArena(self, noteSlabArenaCreated);
        slab.arena_observer = .{
            .ctx = self,
            .on_create = noteSlabArenaCreated,
            .on_release = noteSlabArenaReleased,
        };
    }

    /// Register a live address using classification already held by the caller.
    /// `alloc_info` classification in a register. Publication reads that byte,
    /// then writes it, then would need it again for three separate decisions;
    /// threading the answers through keeps it to one load per publication.
    /// What the address registry must record for a header being published.
    const LiveAddressClass = struct {
        /// False for allocations the registry never needs to find.
        tracked: bool,
        /// Standalone-prefix allocations need an occupant entry; slab-backed
        /// ones are found through their registered arena.
        needs_occupant: bool,
        is_block_cell: bool,
    };

    inline fn registerLiveAddressClassified(
        self: *Registry,
        header: *Header,
        bytes: usize,
        address_class: LiveAddressClass,
    ) void {
        if (!address_class.tracked) return;
        // Slab-backed objects need no entry: their arena is registered, the
        // mask finds it, and the `heap_accounted` bit set just above this call
        // is the same "live GC object" answer the table was storing. Only
        // standalone-prefix allocations -- past the slab's 512-byte class
        // ceiling, or over-aligned -- are unreachable that way.
        if (address_class.needs_occupant) {
            @branchHint(.unlikely);
            self.insertLiveAddressCold(header, bytes);
        }
        self.markPublishedYoungClassified(header, address_class.is_block_cell);
    }

    /// Outlined so the standalone-prefix arm's call does not have to be
    /// register-allocated inside the publication funnel. Slab and block-cell
    /// publications -- everything EarleyBoyer allocates -- never reach it, and
    /// leaving the `Table.insert` call inline made the funnel keep values live
    /// across it, which is what put five `stp` pairs in a prologue whose hot
    /// path calls nothing at all.
    noinline fn insertLiveAddressCold(self: *Registry, header: *Header, bytes: usize) void {
        self.address_registry.insert(addressRegistryAllocator(), header, bytes) catch {
            self.address_registry.noteFailedInsert();
        };
    }

    /// Generation shares publication's lifetime: an object is young from the
    /// moment it is published until a collection lets it survive. One bit in a
    /// byte the allocator already writes, rather than a hash-map insert per
    /// allocation.
    /// Mark a published header young using the block-cell answer already held
    /// by the caller.
    /// The young bit lives in flags (byte 3) and the block-cell class in
    /// alloc_info (byte 2) of the same prefix word, so deriving the class after
    /// the young store forced a reload of a byte adjacent to a just-issued
    /// store -- see `addInitializedWithSizeNoFail`'s note.
    /// Both halves of the young census, in the one place a publication grows
    /// it. `young_count` is the POPULATION (what
    /// `verifyGenerationInvariants` recounts and what the young list plus the
    /// extent tables enumerate); `young_trigger_count` is the SCHEDULING
    /// question, and an owned storage cell is not part of it -- see
    /// `kindIsOwnedStorageCell`.
    inline fn noteYoungPublicationCensus(self: *Registry, header: *const Header) void {
        // A nursery cell is young, but it is not in the population
        // `verifyGenerationInvariants` recounts: no young list, no young
        // block, no extent table holds it. Counting it here would make the
        // census disagree with every structure that enumerates it. The
        // nursery paces its own collection off `allocated_bytes`.
        if (header.metaConst().alloc_info.nursery) return;
        if (comptime std.debug.runtime_safety) self.generation.stats.young_publications +%= 1;
        self.generation.stats.young_count += 1;
        if (!kindIsOwnedStorageCell(header.metaConst().flags.kind)) {
            self.generation.stats.young_trigger_count += 1;
        }
    }

    inline fn markPublishedYoungClassified(
        self: *Registry,
        header: *Header,
        is_block_cell: bool,
    ) void {
        // Extent strings ARE in the generational young set -- a >128 B
        // string body is exactly the kind of short-lived allocation a
        // minor exists to reclaim, and leaving them out made pdfjs hold
        // 343 MB live waiting for a major (spec 7.2 (2)). What they are
        // not in is any young CARRIER: no cell, no block, no list link.
        // Their enumeration is `Heap.young_extents`, appended by the
        // allocator, swept by `Heap.sweepYoungExtents` and retired
        // by `retireYoungExtents`. A non-block-cell string is
        // always an extent (`String.createUninitialized`; ropes always
        // fit a cell).
        if (!is_block_cell and kindIsExtentCapable(header.metaConst().flags.kind)) {
            @branchHint(.unlikely);
            std.debug.assert(header.metaConst().alloc_info.standalone);
            header.meta().flags.young = true;
            self.noteYoungPublicationCensus(header);
            return;
        }
        header.meta().flags.young = true;
        self.noteYoungPublicationCensus(header);
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
        // Non-block Objects are not part of the allocation-ordered intrusive
        // suffix. Their side authority is small and filtered on the young bit
        // by `objectIterator(.young_list)`, so no list anchor belongs to them.
        if (header.metaConst().flags.kind == .object) return;
        // Extent strings never reach here: they returned above, right after
        // their young bit. They have no link word, so anchoring the young
        // suffix on one would send the next minor's list walk through string
        // bytes -- `Heap.young_extents` is their anchor instead. Rope nodes
        // always fit a cell and left through the block arm above.
        std.debug.assert(!kindIsPrefixCarrier(header.metaConst().flags.kind));
        // This object was just appended at the tail, so if no suffix was open
        // it starts here.
        if (self.lists.young_head == null) {
            // Non-block publication captured the old list tail before linking.
            // A missing cursor would turn the next minor into a whole-list
            // predecessor search (or, worse, make it splice the wrong node).
            std.debug.assert(self.lists.young_predecessor != null);
            self.lists.young_head = header;
        }
    }

    inline fn unregisterLiveAddress(self: *Registry, header: *Header) void {
        // Mirror of `registerLiveAddress`: nothing was inserted for a
        // slab-backed object, and `heap_accounted` is cleared by the free path
        // that brought us here, so the mask stops resolving it on its own.
        if (header.meta().alloc_info.standalone) {
            self.address_registry.remove(addressRegistryAllocator(), header);
        }
        self.forgetGenerationalOwner(header);
        // The young set is a SUFFIX of `lists.objects` anchored at
        // `young_head`, so forgetting an object must also move the anchor
        // off it -- otherwise the next minor's `clearYoungMarks` walks a
        // freed header. Both `lists.objects` detach paths funnel through here
        // (`removeGcObject` and `unlinkObjectWithBytes`, the ordinary
        // mutator-side RC free used by shape replacement, var_ref release
        // and the typed frees), and both still have `header.next` valid:
        // the `listDel` follows this call. Freeing the anchor shrinks the
        // suffix to its successor; the suffix never grows here.
        if (self.lists.young_head == header) {
            const next = header.nextNonObject();
            self.lists.young_head = if (next == &self.lists.objects.sentinel) null else next;
        }
    }

    /// Histogram and sweep-window observation for a first-time publication.
    /// Restores do not call this (the object was already counted / windowed).
    inline fn observeNewPublication(self: *Registry, header: *Header, bytes: usize) void {
        if (!isNurseryHeader(header)) self.heap_budget.charge(bytes);
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

    /// `--gc-stats` publication histogram. The CLI enables detailed reports
    /// before creating the runtime; default production must not maintain four
    /// diagnostic counters on every object/shape publication. Outlining keeps
    /// the disabled arm to one flag load and branch instead of retaining the
    /// histogram's classify-and-update body in both publication funnels.
    noinline fn recordSpacePublicationDetailed(self: *Registry, header: *Header, bytes: usize) void {
        if (header.metaConst().flags.kind == .object) {
            self.space_histogram.recordObject(
                bytes,
                object.Object.fromHeaderConst(header).hasSlots2Layout(),
            );
        } else self.space_histogram.record(bytes);
    }

    /// Is every live allocation resolvable, so that sweeping is sound?
    ///
    /// An arena that failed to register hides every object it holds from the
    /// conservative stack scan, so a sweep performed in that state can free a
    /// live object. Recovery is a re-walk of the slab's arena lists, which
    /// costs one pass over at most a few thousand pointers and only happens
    /// after an allocation failure. If it still cannot record them, the caller
    /// must mark without sweeping: a bounded leak instead of a use-after-free.
    pub fn addressSetWhole(self: *Registry, rt: *JSRuntime) bool {
        if (self.address_registry.arenasIncomplete()) {
            const slab = self.arena_slab orelse return false;
            if (!self.address_registry.resyncArenas(addressRegistryAllocator(), slab)) return false;
        }
        if (!self.address_registry.occupantsIncomplete()) return true;

        // A failed standalone insert is recoverable because liveness no longer
        // depends on the address index: list carriers and side-authoritative
        // Objects can replay every missing range before sweep. Keep the flag
        // sticky if any retry fails; the caller will mark without reclaiming.
        var live = self.objectIterator(.all);
        while (live.next()) |header| {
            if (!header.metaConst().alloc_info.standalone) continue;
            // Extents deliberately have no occupant entry (S2-h1). Replaying
            // one here would install a range nothing ever removes -- the
            // death path is `unpublishStringExtent`, which no longer calls
            // `Table.remove` -- and a stale occupant resolves freed memory.
            if (kindIsExtentCapable(header.metaConst().flags.kind)) continue;
            if (self.address_registry.by_header.contains(@intFromPtr(header))) continue;
            const bytes = heapByteSizeFromHeader(rt, header);
            self.address_registry.insert(addressRegistryAllocator(), header, bytes) catch return false;
        }
        self.address_registry.setOccupantsIncomplete(false);
        return true;
    }

    // The verification and statistics surface lives in
    // `gc_registry_diagnostics.zig`; these aliases keep it reachable as
    // `Registry` methods, which is what every call site spells.
    pub const pauseDistribution = registry_diagnostics.pauseDistribution;
    pub const HeapSpaceSnapshot = registry_diagnostics.HeapSpaceSnapshot;
    pub const statsSnapshot = registry_diagnostics.statsSnapshot;
    pub const counterSnapshot = registry_diagnostics.counterSnapshot;
    pub const verifyObjectPropertyStorageLayouts = registry_diagnostics.verifyObjectPropertyStorageLayouts;
    pub const recordFailure = registry_diagnostics.recordFailure;
    pub const recordSuccess = registry_diagnostics.recordSuccess;
    pub const SliceKind = registry_diagnostics.SliceKind;
    pub const recordMajorSlicePause = registry_diagnostics.recordMajorSlicePause;
    pub const recordCycleSuccess = registry_diagnostics.recordCycleSuccess;
    pub const recordMinorSuccess = registry_diagnostics.recordMinorSuccess;
    pub const verifyIntrusiveList = registry_diagnostics.verifyIntrusiveList;
    pub const verifyConstructionRoots = registry_diagnostics.verifyConstructionRoots;
    pub const verifyRepresentationInvariants = registry_diagnostics.verifyRepresentationInvariants;
    pub const verifyGenerationInvariants = registry_diagnostics.verifyGenerationInvariants;
    pub const verifyMajorRetirementCommit = registry_diagnostics.verifyMajorRetirementCommit;
    pub const verifyHeapAccounting = registry_diagnostics.verifyHeapAccounting;
    pub const liveCount = registry_diagnostics.liveCount;
    pub const liveCountKind = registry_diagnostics.liveCountKind;

    pub fn containsHeader(self: *const Registry, header: *const Header) bool {
        if (self.lists.sweep_current == header) return true;
        // A young cell's membership is its page. A pinned one did not move,
        // so its page was retained and that is where the answer lives.
        if (isNurseryHeader(header)) return self.nursery.contains(@intFromPtr(header));
        // A block cell is answered from its block, in O(1). The `.all`
        // iterator's block phase yields exactly the cells whose alloc bit and
        // `heap_accounted` stamp are both set (`nextInBlock`), and no other
        // phase -- the non-block lists, the morgue buckets, the extent table
        // -- can hold a classed-block address, so the bitmap is the whole
        // authority for it. Enumerating the heap to find one cell made this
        // an O(n) walk per query, and the whole-heap audits that ask it once
        // per object (`verifyObjectPropertyStorageLayouts`, every Debug
        // collection) paid O(n^2): 52 s of a 90 s unified test run.
        const addr = @intFromPtr(header);
        if (self.block_heap.blockOf(@ptrFromInt(addr))) |block| {
            const index = block.cellIndexInterior(addr) orelse return false;
            if (!block.cellAllocated(index)) return false;
            if (block.cellBase(index) + metadata_prefix_size != addr) return false;
            return header.metaConst().alloc_info.heap_accounted;
        }
        if (self.nonblock_objects) |authority| {
            for (authority.doomed.items) |candidate| if (candidate == header) return true;
        }
        // Condemned-but-not-yet-destroyed nodes remain runtime-owned with
        // resources intact.
        for (&self.morgue.by_kind) |*bucket| {
            var condemned = bucket.sentinel.next_non_object;
            while (condemned) |candidate| {
                if (candidate == &bucket.sentinel) break;
                if (candidate == header) return true;
                condemned = candidate.nextNonObject();
            }
        }
        var iterator = self.objectIterator(.all);
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
        const header: *Header = @ptrFromInt(key.base);
        if (!self.address_registry.containsHeader(header)) return error.NotFound;
        const kind = header.metaConst().flags.kind;
        if (expected_kind) |expected| if (kind != expected) return error.KindMismatch;
        return .{ .tracing = header };
    }

    /// Mint a generation-bearing handle (audit builds only: the carrier
    /// authorities behind it exist nowhere else).
    pub fn allocationHandle(self: *const Registry, header: *const Header) ?AllocationHandle {
        comptime std.debug.assert(carrier.audit_enabled);
        return mem_ops.carrierGenerationHandle(self.runtime, @intFromPtr(header));
    }

    /// Generation/state exact resolution (audit builds only).
    pub fn resolveExact(
        self: *const Registry,
        handle: AllocationHandle,
        expected_kind: ?GcKind,
        allowed_states: CarrierStateMask,
    ) CarrierResolveError!ResolvedExact {
        comptime std.debug.assert(carrier.audit_enabled);
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
            const header: *Header = @ptrFromInt(handle.base);
            const kind = header.metaConst().flags.kind;
            // Block cells hold Objects, string-family bodies (TGC S2/S4-a)
            // and, from S4-b, storage cells.
            if (!kindIsBlockCellKind(kind)) return error.HeaderMismatch;
            if (expected_kind) |expected| if (kind != expected) return error.KindMismatch;
            if (resolved.state == .published and !header.metaConst().alloc_info.heap_accounted) {
                return error.HeaderMismatch;
            }
            return .{ .tracing = header };
        }

        const record = try self.runtime.gc.cell_storage.extent_identity.resolve(
            handle,
            if (expected_kind) |kind| @intFromEnum(kind) else null,
        );
        const lifecycle = try self.runtime.gc.cell_storage.extent_lifecycle.resolve(handle.base, allowed_states);
        const header: *Header = @ptrFromInt(handle.base);
        const kind = header.metaConst().flags.kind;
        if (@intFromEnum(kind) != record.kind) return error.HeaderMismatch;
        if (lifecycle.state == .published and !header.metaConst().alloc_info.heap_accounted) {
            return error.HeaderMismatch;
        }
        return .{ .tracing = header };
    }
};

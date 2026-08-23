//! Z-GE (Garbage Engine) Core Implementation
//! Governing Layer: third_party/zjs/src/core/gc.zig
//! Following Z-GE Architecture Contract v1.0

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const memory = @import("memory.zig");
const bigint = @import("bigint.zig");
const object = @import("object.zig");
const context_mod = @import("context.zig");
const module_mod = @import("module.zig");
const var_ref = @import("var_ref.zig");
const string = @import("string.zig");
const function_bytecode_mod = @import("../bytecode.zig").function_bytecode;
const FunctionBytecode = function_bytecode_mod.FunctionBytecode;
const shape = @import("shape.zig");

const KB: usize = 1024;
const MB: usize = 1024 * KB;

/// `-Dzjs_gc=shadow` compiles the non-reclaiming observer in `gc_shadow.zig`.
/// Default `rc` keeps this false so the observer is not imported and the
/// production collector's machine code is unchanged.
pub const shadow_tracer_enabled: bool = std.mem.eql(u8, build_options.zjs_gc, "shadow");

/// `-Dzjs_gc=trace_stw` compiles the stop-the-world reclaiming tracer
/// (`gc_trace_stw.zig`) over the compatibility heap. Mutually exclusive with
/// `shadow`. Default `rc` stays false so production `.text` is unchanged.
pub const trace_stw_enabled: bool = std.mem.eql(u8, build_options.zjs_gc, "trace_stw");

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

comptime {
    const tags = std.meta.tags(RefKind);
    std.debug.assert(ref_kind_catalog.len == tags.len);
    for (ref_kind_catalog, 0..) |descriptor, index| {
        std.debug.assert(@intFromEnum(descriptor.kind) == index);
        std.debug.assert(descriptor.cycle_candidate == (descriptor.census == .rc_registry));
    }
}

pub const GcKind = RefKind;
pub const Phase = enum {
    none,
    decref,
    remove_cycles,
    deinit,
    cycle,
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
    _pad_list: bool = false,
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

/// qjs-style block-prefix metadata. Mirrors `JSMallocBlockHeader`
/// (quickjs.c:270-280): {block_idx:u16, block_size_idx:u8, gc_obj_type:7|mark:1,
/// ref_count:i32} live immediately before the object. For slab-backed objects
/// these 8 bytes ARE the allocator block header; persistent/over-aligned
/// objects keep a standalone prefix.
pub const Metadata = extern struct {
    /// Standalone prefix: encoded heap bytes. Slab overlay: allocator block
    /// index (or free-list link while free). Check alloc_info.standalone before
    /// interpreting this field as a heap size.
    size_class: u16 align(8) = 0,
    alloc_info: AllocInfo = .{},
    flags: BlockFlags = .{},
    rc: i32 = 1,
};

/// Size of the metadata prefix that precedes every GC object (objectPtr - 8).
pub const metadata_prefix_size: usize = @sizeOf(Metadata);

comptime {
    // The allocator initializes the prefix by raw byte writes (memory.zig has no
    // gc import); these offsets and bit positions must remain stable.
    std.debug.assert(@offsetOf(Metadata, "alloc_info") == 2);
    std.debug.assert(@offsetOf(Metadata, "flags") == 3);
    std.debug.assert(@offsetOf(Metadata, "rc") == 4);
    std.debug.assert(@as(u8, @bitCast(AllocInfo{ .standalone = true })) == 1 << 7);
    std.debug.assert(@as(u8, @bitCast(AllocInfo{ .heap_accounted = true })) == 1 << 6);
    std.debug.assert(@as(u8, @bitCast(AllocInfo{ .large = true })) == 1 << 5);
    std.debug.assert(@as(u8, @bitCast(AllocInfo{ .block_size_idx = 31 })) == 31);
    // Kind occupies the low 3 bits of the shared kind/flags byte; a bare tag
    // byte (all flags clear) equals the enum value, which is what the raw
    // prefix writers in memory.zig and object.zig store.
    std.debug.assert(@as(u8, @bitCast(BlockFlags{ .kind = .big_int })) == @intFromEnum(GcKind.big_int));
    std.debug.assert(@as(u8, @bitCast(BlockFlags{ .kind = .object, .mark = true })) == 1 << 3);
    std.debug.assert(@as(u8, @bitCast(BlockFlags{ .kind = .object, .cycle_visited = true })) == 1 << 7);
    // The contiguous kind ranges documented on RefKind.
    std.debug.assert(@intFromEnum(GcKind.object) == 0);
    std.debug.assert(@intFromEnum(GcKind.module) == 4 and @intFromEnum(GcKind.shape) == 5);
    std.debug.assert(@intFromEnum(GcKind.string) == 6 and @intFromEnum(GcKind.big_int) == 7);
}

/// In-object GC header = intrusive list links only (qjs `JSGCObjectHeader`,
/// 16 bytes). The refcount / kind / flags / optional heap-size live in Metadata
/// prefix 8 bytes before this header; reach them via `meta()`.
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
        const m = self.meta();
        std.debug.assert(m.rc > 0);
        m.rc += 1;
    }

    pub fn pinned(self: *const BlockHeader) bool {
        return self.metaConst().flags.is_pinned;
    }

    pub fn setPinned(self: *BlockHeader, value: bool) void {
        self.meta().flags.is_pinned = value;
    }
};

/// Common QuickJS-style refcount word. Every refcounted JSValue payload points
/// at its body, with this header at the fixed `payload - 4` offset (`__js_rc`
/// in quickjs.h). Strings allocate it as a standalone prefix; GC objects store
/// the same i32 in the tail of their 8-byte allocator Metadata prefix.
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

/// QuickJS `__js_rc` displacement shared by every refcounted value payload.
pub const ref_count_offset_from_payload: usize = @sizeOf(RefCountHeader);

pub inline fn refCountHeaderFromPayload(payload: *anyopaque) *RefCountHeader {
    const address = @intFromPtr(payload);
    std.debug.assert(address >= ref_count_offset_from_payload);
    return @ptrFromInt(address - ref_count_offset_from_payload);
}

comptime {
    // A GC value stores `BlockHeader *` in its payload. Metadata immediately
    // precedes that header, and its rc tail must land at the same payload - 4
    // address used by strings, symbols, and ropes.
    std.debug.assert(metadata_prefix_size - @offsetOf(Metadata, "rc") == ref_count_offset_from_payload);
}

pub const Header = BlockHeader;
pub const GCObjectHeader = Header;
pub const ObjectHeader = Header;

/// qjs `list.h` cyclic sentinel. `head` is a dummy `Header` — never call `meta()`
/// on it. Linked nodes have non-null prev/next (a neighbor or the sentinel);
/// unlinked nodes have both null (qjs `list_del` fail-safe).
pub inline fn listInit(head: *Header) void {
    head.prev = head;
    head.next = head;
}

pub inline fn listEmpty(head: *const Header) bool {
    return head.next == @constCast(head);
}

pub inline fn listAddTail(head: *Header, el: *Header) void {
    const prev = head.prev.?;
    el.prev = prev;
    el.next = head;
    prev.next = el;
    head.prev = el;
}

/// qjs `list_del` (list.h:69-78 / remove_gc_object at quickjs.c:6548).
/// Caller must pass a linked node. No head/tail null branches.
pub inline fn listDel(el: *Header) void {
    const prev = el.prev.?;
    const next = el.next.?;
    prev.next = next;
    next.prev = prev;
    el.prev = null;
    el.next = null;
}

pub inline fn listFirst(head: *const Header) ?*Header {
    const next = head.next.?;
    if (next == @constCast(head)) return null;
    return next;
}

/// Allocation-free temporary intrusive list for cycle partitioning and
/// Pass-B struct deferral. Same `Header.link` words as the Registry lists
/// (qjs reuses `JSGCObjectHeader.link`). Call `init()` in place after the
/// list reaches its stable address — the sentinel is self-referential.
pub const HeaderList = struct {
    sentinel: Header = .{},
    count: usize = 0,

    pub fn init(self: *HeaderList) void {
        listInit(&self.sentinel);
        self.count = 0;
    }

    pub fn append(self: *HeaderList, header: *Header) void {
        std.debug.assert(header.prev == null and header.next == null);
        listAddTail(&self.sentinel, header);
        self.count += 1;
    }

    pub fn remove(self: *HeaderList, header: *Header) void {
        listDel(header);
        std.debug.assert(self.count != 0);
        self.count -= 1;
    }

    pub fn popFront(self: *HeaderList) ?*Header {
        const header = listFirst(&self.sentinel) orelse return null;
        self.remove(header);
        return header;
    }

    /// Successor of `header` on this list, or null at the sentinel.
    /// Mirrors `list_for_each_safe`'s saved `el1` (qjs:6797).
    pub fn nextAfter(self: *const HeaderList, header: *const Header) ?*Header {
        const next = header.next.?;
        if (next == &self.sentinel) return null;
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
    NegativeRefCount,
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
};

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

    /// Round durations retained for percentile reporting. A collection round
    /// is orders of magnitude more expensive than one array store, so keeping
    /// its duration costs nothing measurable; the cap bounds the memory and
    /// keeps the most recent rounds, which is what pause work asks about.
    /// `pause_sample_count` saturates so a long-lived runtime still reports
    /// how many rounds the retained window represents.
    pause_samples: [pause_sample_capacity]u64 = @splat(0),
    pause_sample_cursor: usize = 0,
    pause_sample_count: usize = 0,

    /// Cycle-collection entry count, bumped by
    /// `object_gc.destroyRuntimeCyclesWithValueRoots`. Distinct from
    /// `cycle_gc_count`, which records completed rounds via `recordSuccess`;
    /// the pair is what tells an aborted round from a finished one, and the
    /// core suite uses this one as its "did a collection run" oracle.
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

    /// Cycle-collection entries (`collections`) and completed rounds
    /// (`major_gc_count`); a gap between them is aborted rounds.
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
    gc_obj_list: Header = .{},
    tmp_obj_list: Header = .{},
    zero_ref_list: Header = .{},
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
    cycle_deferred_frees: HeaderList = .{},

    pub fn init(account: *memory.MemoryAccount, policy: Policy) Registry {
        return .{
            .memory = account,
            .policy = policy,
            .old_space = .{},
            .large_space = .{},
        };
    }

    /// Bind cyclic sentinels after the Registry is in its final location
    /// (qjs `init_list_head` on `JSRuntime` fields). Must run before any
    /// header is published.
    pub fn initLists(self: *Registry) void {
        listInit(&self.gc_obj_list);
        listInit(&self.tmp_obj_list);
        listInit(&self.zero_ref_list);
        self.cycle_deferred_frees.init();
    }

    /// Park a resource-stripped GC object's struct for the Pass-B drain. The
    /// header is already unlinked from the GC object list by the resource pass.
    pub fn deferCycleStructFree(self: *Registry, header: *GCObjectHeader) void {
        header.meta().flags.finalizing = true;
        self.cycle_deferred_frees.append(header);
    }

    pub fn popCycleDeferredFree(self: *Registry) ?*GCObjectHeader {
        return self.cycle_deferred_frees.popFront();
    }

    pub fn deinit(self: *Registry, rt: anytype) void {
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
            const h = self.gc_obj_list.prev.?;
            std.debug.assert(h != &self.gc_obj_list);
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

    pub fn reportExternalAllocUntracked(self: *Registry, bytes: usize) void {
        if (bytes == 0) return;
        self.stats.external_bytes = std.math.add(usize, self.stats.external_bytes, bytes) catch std.math.maxInt(usize);
        self.stats.external_untracked_bytes = std.math.add(usize, self.stats.external_untracked_bytes, bytes) catch std.math.maxInt(usize);
        self.stats.peak_external_bytes = @max(self.stats.peak_external_bytes, self.stats.external_bytes);
        self.stats.external_alloc_count +|= 1;
        const weighted = std.math.mul(usize, bytes, self.policy.external_weight) catch std.math.maxInt(usize);
        self.stats.allocation_debt = std.math.add(usize, self.stats.allocation_debt, weighted) catch std.math.maxInt(usize);
    }

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
        std.mem.sort(u64, window, {}, std.sort.asc(u64));
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
            .peak_allocated_bytes = derived_heap_live,
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
        h.meta().rc = 1;
        h.meta().flags = .{ .kind = h.meta().flags.kind };
        h.meta().alloc_info.heap_accounted = false;
        // Registration re-derives and re-stamps the large classification;
        // clearing it here upholds addInitializedWithSizeNoFail's clear-on-entry
        // invariant for re-registered headers.
        h.meta().alloc_info.large = false;
        h.prev = null;
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
        std.debug.assert(h.meta().rc == 1);
        std.debug.assert(!h.meta().flags.mark);
        std.debug.assert(!h.meta().flags.finalizing);
        std.debug.assert(!h.meta().flags.is_pinned);
        std.debug.assert(!h.meta().flags.cycle_visited);
        std.debug.assert(!h.meta().alloc_info.heap_accounted);
        std.debug.assert(h.prev == null and h.next == null);

        const is_large = self.isLargeAllocation(bytes);
        const tracked = isCycleCandidate(h);
        // The large bit is clear on entry for every registration: initGcPrefix
        // zeroes it on fresh allocations, and both unaccount sites
        // (recordHeapFreeWithBytes / addWithSize) clear it together with
        // heap_accounted. This keeps the hot RMW below the same single-bit orr
        // it always was; only the cold large arm pays a second byte store.
        std.debug.assert(!h.meta().alloc_info.large);
        if (h.meta().alloc_info.standalone) h.meta().size_class = encodeHeapBytes(bytes);
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

        if (tracked) self.linkGcObjectTail(h);
    }

    /// qjs `add_gc_object` for shapes (quickjs.c:6540): rc/kind already live
    /// in the prefix, then heap_accounted + old_space + list_add_tail.
    /// Shapes stay below `large_object_threshold` (8KiB); skip the large
    /// compare, standalone size_class stamp, and isCycleCandidate test.
    pub fn addInitializedShape(self: *Registry, h: *GCObjectHeader, bytes: usize) void {
        std.debug.assert(h.meta().rc == 1);
        std.debug.assert(!h.meta().alloc_info.heap_accounted);
        std.debug.assert(h.prev == null and h.next == null);
        if (h.meta().alloc_info.standalone) {
            self.addInitializedWithSizeNoFail(h, bytes);
            return;
        }
        std.debug.assert(!h.meta().alloc_info.large);
        h.meta().alloc_info.heap_accounted = true;
        self.old_space.recordAlloc(bytes);
        self.linkGcObjectTail(h);
    }

    fn defaultHeapBytes(h: *const GCObjectHeader) usize {
        return switch (h.metaConst().flags.kind) {
            .object => @sizeOf(object.Object),
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
                break :blk sh.allocationSize();
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
                break :blk sh.allocationSize();
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
        if (!isCycleCandidate(h)) return;
        // Already unlinked, or condemned on tmp_obj_list / a partition list.
        // qjs remove_gc_object is only called while the node is on gc_obj_list.
        if (h.prev == null or h.meta().flags.cycle_visited) return;
        listDel(h);
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
        std.debug.assert(h.meta().rc > 0);
        h.meta().rc -= 1;

        if (h.meta().rc == 0) {
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

    pub const GcObjectIterator = struct {
        cursor: ?*GCObjectHeader,
        sentinel: *const GCObjectHeader,

        pub fn next(self: *GcObjectIterator) ?*GCObjectHeader {
            const current = self.cursor orelse return null;
            if (current == self.sentinel) return null;
            self.cursor = current.next;
            return current;
        }
    };

    pub fn objectIterator(self: *const Registry) GcObjectIterator {
        return .{
            .cursor = self.gc_obj_list.next,
            .sentinel = &self.gc_obj_list,
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

    fn appendGcObject(self: *Registry, header: *GCObjectHeader) void {
        std.debug.assert(isCycleCandidate(header));
        std.debug.assert(header.prev == null);
        std.debug.assert(header.next == null);
        listAddTail(&self.gc_obj_list, header);
    }

    /// qjs `list_add_tail` (quickjs.c:6545).
    inline fn linkGcObjectTail(self: *Registry, header: *GCObjectHeader) void {
        listAddTail(&self.gc_obj_list, header);
    }

    /// qjs `list_del` / `remove_gc_object` (quickjs.c:6548). Already-unlinked
    /// headers (deinit shape self-remove) are a no-op; a linked node is spliced
    /// with no head/tail null branches.
    fn removeGcObject(self: *Registry, header: *GCObjectHeader) void {
        _ = self;
        if (header.prev == null) return;
        listDel(header);
    }

    pub fn detachCycleCandidate(self: *Registry, header: *GCObjectHeader) void {
        std.debug.assert(!header.meta().flags.cycle_visited);
        self.removeGcObject(header);
        header.meta().flags.cycle_visited = true;
    }

    pub fn restoreCycleCandidate(self: *Registry, header: *GCObjectHeader) void {
        std.debug.assert(header.meta().flags.cycle_visited);
        header.meta().flags.cycle_visited = false;
        self.appendGcObject(header);
    }

    fn appendZeroRef(self: *Registry, header: *GCObjectHeader) void {
        std.debug.assert(header.meta().rc == 0);
        std.debug.assert(header.prev == null);
        std.debug.assert(header.next == null);
        listAddTail(&self.zero_ref_list, header);
    }

    fn popZeroRef(self: *Registry) ?*GCObjectHeader {
        const header = listFirst(&self.zero_ref_list) orelse return null;
        listDel(header);
        return header;
    }

    fn drainZeroRefs(self: *Registry, rt: anytype) void {
        if (listEmpty(&self.zero_ref_list)) return;
        self.stats.zero_ref_drains +|= 1;
        while (self.popZeroRef()) |queued| {
            std.debug.assert(queued.meta().rc == 0);
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
        std.debug.assert(header.meta().rc == 0);
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
        self.stats.pause_samples[self.stats.pause_sample_cursor] = result.duration_ns;
        self.stats.pause_sample_cursor = (self.stats.pause_sample_cursor + 1) % pause_sample_capacity;
        self.stats.pause_sample_count +|= 1;
    }

    pub fn verifyIntrusiveList(self: *Registry) InvariantError!void {
        if (self.gc_obj_list.next == null or self.gc_obj_list.prev == null)
            return error.CorruptGcList;
        if (listEmpty(&self.gc_obj_list)) {
            if (self.gc_obj_list.prev != &self.gc_obj_list) return error.CorruptGcList;
            return;
        }

        var tortoise: *GCObjectHeader = self.gc_obj_list.next.?;
        var hare: *GCObjectHeader = self.gc_obj_list.next.?;
        while (hare != &self.gc_obj_list) {
            hare = hare.next orelse return error.CorruptGcList;
            if (hare == &self.gc_obj_list) break;
            hare = hare.next orelse return error.CorruptGcList;
            tortoise = tortoise.next orelse return error.CorruptGcList;
            if (hare != &self.gc_obj_list and tortoise == hare) return error.CorruptGcList;
        }

        var previous: *GCObjectHeader = &self.gc_obj_list;
        var current = self.gc_obj_list.next;
        while (current) |h| {
            if (h == &self.gc_obj_list) break;
            if (!isCycleCandidate(h)) return error.CorruptGcList;
            if (h.meta().rc < 0) return error.NegativeRefCount;
            if (h.meta().flags.mark and self.phase == .none) return error.MarkBitLeftSet;
            if (h.prev != previous) return error.CorruptGcList;
            const next = h.next orelse return error.CorruptGcList;
            if (next.prev != h) return error.CorruptGcList;
            previous = h;
            current = next;
        }
        if (previous.next != &self.gc_obj_list) return error.CorruptGcList;
        if (self.gc_obj_list.prev != previous) return error.CorruptGcList;
    }

    pub fn verifyHeapAccounting(self: *const Registry, rt: anytype) InvariantError!void {
        var heap_live_bytes: usize = 0;
        var old_live_bytes: usize = 0;
        var large_object_bytes: usize = 0;

        var iterator = self.objectIterator();
        while (iterator.next()) |header| {
            if (!header.metaConst().alloc_info.heap_accounted) return error.MissingHeapAllocation;
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
        var queued = self.zero_ref_list.next;
        while (queued) |candidate| {
            if (candidate == &self.zero_ref_list) break;
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
    std.debug.assert(header.meta().rc > 0);
    header.meta().rc -= 1;

    if (header.meta().rc == 0) destroyZeroRef(rt, header);
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
    std.debug.assert(header.meta().rc == 0);
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
    if (rt.gc.phase == .remove_cycles and zeroRefKindMatches(header.meta().flags.kind, .remove_cycles)) return;

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
    std.debug.assert(header.meta().rc == 0);
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
    std.debug.assert(header.meta().rc == 0);
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

//! Non-reclaiming shadow tracer (tracing-gc-design.md §13 Stage 1).
//!
//! Observes the current RC heap: enumerate allocated cycle-list objects
//! through `RcRegistryHeapCensus`, mark from the roots the engine can
//! already name, walk `traceChildEdges*` as the sole edge authority, and
//! report allocated-but-not-reachable objects. Never releases memory.
//!
//! Compiled only when `-Dzjs_gc=shadow`. Weak collection entries are not
//! marked (that would promote a weak edge); ephemeron values that stay
//! RC-alive are classified as a known current-collector semantic, not
//! marked and not "fixed".

const std = @import("std");

const context_mod = @import("context.zig");
const conservative = @import("gc_conservative.zig");
const gc = @import("gc.zig");
const module_mod = @import("module.zig");
const object_mod = @import("object.zig");
const object_payloads = @import("object_payloads.zig");
const runtime_mod = @import("runtime.zig");
const shape = @import("shape.zig");
const var_ref_mod = @import("var_ref.zig");
const function_bytecode_mod = @import("../bytecode.zig").function_bytecode;
const FunctionBytecode = function_bytecode_mod.FunctionBytecode;
const JSRuntime = runtime_mod.JSRuntime;
const JSValue = @import("value.zig").JSValue;
const Object = object_mod.Object;

pub const enabled = true;

const ShadowError = runtime_mod.RootTraceError;
const HeaderSet = std.AutoHashMapUnmanaged(usize, void);
const HeaderSetManaged = std.AutoHashMap(usize, void);

pub const KindCounts = struct {
    object: usize = 0,
    function_bytecode: usize = 0,
    var_ref: usize = 0,
    realm_context: usize = 0,
    module: usize = 0,
    shape: usize = 0,
    string: usize = 0,
    big_int: usize = 0,

    pub fn add(self: *KindCounts, kind: gc.RefKind) void {
        switch (kind) {
            .object => self.object += 1,
            .function_bytecode => self.function_bytecode += 1,
            .var_ref => self.var_ref += 1,
            .realm_context => self.realm_context += 1,
            .module => self.module += 1,
            .shape => self.shape += 1,
            .string => self.string += 1,
            .big_int => self.big_int += 1,
        }
    }

    pub fn get(self: KindCounts, kind: gc.RefKind) usize {
        return switch (kind) {
            .object => self.object,
            .function_bytecode => self.function_bytecode,
            .var_ref => self.var_ref,
            .realm_context => self.realm_context,
            .module => self.module,
            .shape => self.shape,
            .string => self.string,
            .big_int => self.big_int,
        };
    }
};

pub const UnexplainedClass = enum {
    pending_finalization,
    pinned,
    declared_external_owner,
    conservative_retention,
    known_current_collector_semantic,
    unexplained,
};

pub const UnexplainedItem = struct {
    header: *gc.Header,
    kind: gc.RefKind,
    class: UnexplainedClass,
};

pub const Report = struct {
    allocated: usize = 0,
    reachable: usize = 0,
    exact_reachable: usize = 0,
    conservative_inclusive: usize = 0,
    allocated_by_kind: KindCounts = .{},
    reachable_by_kind: KindCounts = .{},
    pending_finalization: usize = 0,
    pinned: usize = 0,
    declared_external_owner: usize = 0,
    conservative_retention: usize = 0,
    known_current_collector_semantic: usize = 0,
    unexplained: usize = 0,
    conservative: conservative.Metrics = .{},
    unexplained_by_kind: KindCounts = .{},
    /// Prefix of the allocated-not-reachable list; `unexplainedTotal()` is the
    /// full size. Stored inline so the report outlives the tracer arena.
    sample_buf: [sample_cap]UnexplainedItem = undefined,
    sample_len: usize = 0,

    pub fn sample(self: *const Report) []const UnexplainedItem {
        return self.sample_buf[0..self.sample_len];
    }

    pub fn unexplainedTotal(self: Report) usize {
        return self.pending_finalization +
            self.pinned +
            self.declared_external_owner +
            self.conservative_retention +
            self.known_current_collector_semantic +
            self.unexplained;
    }

    pub fn format(self: Report, writer: anytype) !void {
        try writer.print(
            \\shadow tracer
            \\  allocated: {d}  exact-reachable: {d}  conservative-inclusive: {d}  not-reachable: {d}
            \\  allocated by kind: object={d} fb={d} var_ref={d} realm={d} module={d} shape={d} string={d} big_int={d}
            \\  reachable by kind: object={d} fb={d} var_ref={d} realm={d} module={d} shape={d} string={d} big_int={d}
            \\  conservative scan: supported={s} candidates={d} validated_hits={d} only={d} direct_bytes={d} transitive_bytes={d}
            \\  classified not-reachable:
            \\    pending_finalization: {d}
            \\    pinned: {d}
            \\    declared_external_owner: {d}
            \\    conservative_retention: {d}
            \\    known_current_collector_semantic: {d}
            \\    unexplained: {d}
            \\
        , .{
            self.allocated,
            self.exact_reachable,
            self.conservative_inclusive,
            self.unexplainedTotal(),
            self.allocated_by_kind.object,
            self.allocated_by_kind.function_bytecode,
            self.allocated_by_kind.var_ref,
            self.allocated_by_kind.realm_context,
            self.allocated_by_kind.module,
            self.allocated_by_kind.shape,
            self.allocated_by_kind.string,
            self.allocated_by_kind.big_int,
            self.reachable_by_kind.object,
            self.reachable_by_kind.function_bytecode,
            self.reachable_by_kind.var_ref,
            self.reachable_by_kind.realm_context,
            self.reachable_by_kind.module,
            self.reachable_by_kind.shape,
            self.reachable_by_kind.string,
            self.reachable_by_kind.big_int,
            if (self.conservative.supported) "yes" else "no",
            self.conservative.candidates,
            self.conservative.validated_hits,
            self.conservative.retained_only_conservatively,
            self.conservative.direct_bytes,
            self.conservative.transitive_bytes,
            self.pending_finalization,
            self.pinned,
            self.declared_external_owner,
            self.conservative_retention,
            self.known_current_collector_semantic,
            self.unexplained,
        });
        if (self.sample_len != 0) {
            try writer.print("  sample ({d} of {d}):\n", .{ self.sample_len, self.unexplainedTotal() });
            for (self.sample()) |item| {
                try writer.print("    {s} {s} {*}\n", .{ @tagName(item.class), @tagName(item.kind), item.header });
            }
        }
        if (self.unexplained != 0) {
            try writer.print(
                \\  zero-unexplained still needs:
                \\    - remaining unexplained items (see sample)
                \\    - ephemeron fixed point (classified, not marked)
                \\
            , .{});
        } else {
            try writer.print(
                \\  unexplained is zero; ephemeron values stay classified, not marked
                \\
            , .{});
        }
    }
};

/// Adapter over the current intrusive cycle list. string / big_int are
/// RC-only leaves and never appear here; the eight-kind table still reports
/// them as zero allocated.
pub const RcRegistryHeapCensus = struct {
    pub fn forEach(rt: *JSRuntime, comptime onHeader: fn (*gc.Header) void) void {
        var iterator = rt.gc.objectIterator();
        while (iterator.next()) |header| onHeader(header);
    }
};

pub fn quiesce(rt: *JSRuntime) void {
    _ = rt.runObjectCycleRemoval();
    rt.drainDeferredClassPayloadFinalizers();
    rt.drainDeferredNativeCleanups();
    rt.drainDeferredWeakValueFrees();
}

pub fn run(rt: *JSRuntime) ShadowError!Report {
    var tracer = try Tracer.init(rt);
    defer tracer.deinit();
    try tracer.seedRoots();
    try tracer.drain();
    try tracer.snapshotExact();
    try tracer.seedConservativeRoots();
    try tracer.drain();
    return try tracer.finish();
}

/// Precise-root membership after `seedRoots`+`drain`, before conservative
/// capture. Used to prove a waiter Promise is an exact root, not a stack hit.
pub fn isExactReachable(rt: *JSRuntime, header: *gc.Header) ShadowError!bool {
    var tracer = try Tracer.init(rt);
    defer tracer.deinit();
    try tracer.seedRoots();
    try tracer.drain();
    try tracer.snapshotExact();
    return tracer.exact.get(@intFromPtr(header)) != null;
}

const sample_cap: usize = 64;

const Tracer = struct {
    rt: *JSRuntime,
    arena: std.heap.ArenaAllocator,
    reachable: HeaderSet,
    exact: HeaderSet,
    conservative_direct: HeaderSet,
    work: std.ArrayList(*gc.Header),
    err: ?ShadowError = null,
    conservative: conservative.Metrics = .{},

    fn init(rt: *JSRuntime) std.mem.Allocator.Error!Tracer {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();
        return .{
            .rt = rt,
            .arena = arena,
            .reachable = .empty,
            .exact = .empty,
            .conservative_direct = .empty,
            .work = .empty,
        };
    }

    fn deinit(self: *Tracer) void {
        // Reachable set and worklist live in the arena.
        self.arena.deinit();
    }

    fn allocator(self: *Tracer) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn shade(self: *Tracer, header: *gc.Header) void {
        if (self.err != null) return;
        const addr = @intFromPtr(header);
        // Precise roots should never produce this; keep the observer from
        // chasing a tagged immediate that leaked into a JSValue window.
        if (addr < 4096 or !std.mem.isAligned(addr, @alignOf(gc.Header))) return;
        const gop = self.reachable.getOrPut(self.allocator(), addr) catch |err| {
            self.err = err;
            return;
        };
        if (gop.found_existing) return;
        gop.value_ptr.* = {};
        self.work.append(self.allocator(), header) catch |err| {
            self.err = err;
        };
    }

    fn shadeOptionalObject(self: *Tracer, obj: ?*Object) void {
        const object = obj orelse return;
        if (@intFromPtr(object) == 0) return;
        self.shade(&object.header);
    }

    /// Heap-edge visitor. Signatures match `object_gc.MarkVisitor` (void) so
    /// `JSContext.traceChildEdgesNoFail` can instantiate them. Allocation
    /// failure is stored on `err` and checked after each walk.
    pub fn visitValue(self: *Tracer, val: *JSValue) void {
        if (val.cycleMarkHeader()) |header| self.shade(header);
    }

    pub fn visitObject(self: *Tracer, obj_ptr: *?*Object) void {
        self.shadeOptionalObject(obj_ptr.*);
    }

    pub fn visitShape(self: *Tracer, shape_ref: *shape.Shape) void {
        self.shade(&shape_ref.header);
    }

    pub fn visitRealm(self: *Tracer, ctx_ptr: *?*context_mod.RealmContext) void {
        if (ctx_ptr.*) |ctx| self.shade(&ctx.header);
    }

    pub fn visitModule(self: *Tracer, record: *module_mod.ModuleRecord) void {
        self.shade(&record.header);
    }

    pub fn visitWeakCollectionEntry(self: *Tracer, entry: *object_payloads.WeakCollectionEntry) void {
        // Correct for the current collector and for this observer: marking a
        // weak entry would promote it. Ephemeron values that remain RC-alive
        // are classified after the walk.
        _ = self;
        _ = entry;
    }

    pub fn visitFinalizationCell(self: *Tracer, entry: *object_payloads.FinalizationRegistryCell) void {
        if (entry.keepsHeldValuesAlive()) self.visitValue(&entry.held_value);
    }

    fn seedRoots(self: *Tracer) ShadowError!void {
        var ctx = self.rt.context_head;
        while (ctx) |current| {
            self.shade(&current.header);
            ctx = current.runtime_next;
        }
        ctx = self.rt.constructing_context_head;
        while (ctx) |current| {
            self.shade(&current.header);
            ctx = current.construction_next;
        }
        for (self.rt.gc.pin_entries) |entry| {
            self.shade(entry.header);
        }
        if (self.err) |err| return err;

        const Adaptor = struct {
            tracer: *Tracer,

            fn visitValue(context: *anyopaque, slot: *JSValue) runtime_mod.RootTraceError!void {
                const adaptor: *@This() = @ptrCast(@alignCast(context));
                adaptor.tracer.visitValue(slot);
                if (adaptor.tracer.err) |err| return err;
            }

            fn visitObject(context: *anyopaque, slot: *?*Object) runtime_mod.RootTraceError!void {
                const adaptor: *@This() = @ptrCast(@alignCast(context));
                adaptor.tracer.visitObject(slot);
                if (adaptor.tracer.err) |err| return err;
            }

            fn visitHeader(context: *anyopaque, header: *const gc.Header) runtime_mod.RootTraceError!void {
                const adaptor: *@This() = @ptrCast(@alignCast(context));
                adaptor.tracer.shade(@constCast(header));
                if (adaptor.tracer.err) |err| return err;
            }
        };
        var adaptor = Adaptor{ .tracer = self };
        var visitor = runtime_mod.RootVisitor{
            .context = @ptrCast(&adaptor),
            .visit_value = Adaptor.visitValue,
            .visit_object = Adaptor.visitObject,
            .visit_header = Adaptor.visitHeader,
        };
        // ValueRootFrames plus the exec active-invocation Adapter. Default
        // `rc` comptime-erases both; shadow/tests pass the live lists.
        try self.rt.traceActiveRoots(&visitor);
    }

    fn snapshotExact(self: *Tracer) ShadowError!void {
        var iterator = self.reachable.iterator();
        while (iterator.next()) |entry| {
            try self.exact.put(self.allocator(), entry.key_ptr.*, {});
        }
    }

    fn shadeConservative(context: *anyopaque, header: *gc.Header) void {
        const self: *Tracer = @ptrCast(@alignCast(context));
        const addr = @intFromPtr(header);
        const already_exact = self.exact.get(addr) != null;
        const already_reachable = self.reachable.get(addr) != null;
        self.shade(header);
        if (!already_exact and !already_reachable and self.conservative_direct.get(addr) == null) {
            self.conservative_direct.put(self.allocator(), addr, {}) catch |err| {
                self.err = err;
                return;
            };
            self.conservative.direct_bytes += gc.Registry.heapByteSizeFromHeader(self.rt, header);
        }
    }

    fn seedConservativeRoots(self: *Tracer) ShadowError!void {
        const lookup = try conservative.AddressLookup.build(self.rt, self.allocator());
        conservative.spillRegistersAndScan(
            self.rt,
            lookup,
            &self.conservative,
            shadeConservative,
            @ptrCast(self),
        );
        if (self.err) |err| return err;
    }

    fn drain(self: *Tracer) ShadowError!void {
        while (self.work.pop()) |header| {
            try self.traceHeader(header);
            if (self.err) |err| return err;
        }
    }

    fn traceHeader(self: *Tracer, header: *gc.Header) ShadowError!void {
        switch (header.meta().flags.kind) {
            .object => {
                const obj: *Object = @alignCast(@fieldParentPtr("header", header));
                try obj.traceChildEdgesFallible(self.rt, self);
                if (self.err) |err| return err;
            },
            .function_bytecode => {
                const fb: *FunctionBytecode = @alignCast(@fieldParentPtr("header", header));
                self.visitRealm(&fb.realm.ptr);
                for (fb.cpoolSlice()) |*stored| self.visitValue(stored);
            },
            .var_ref => {
                const ref: *var_ref_mod.VarRef = @alignCast(@fieldParentPtr("header", header));
                // Same as markChildrenCold: open pvalue is a borrowed frame
                // alias and must not be walked as a heap edge.
                self.visitValue(&ref.value);
            },
            .shape => {
                const shape_ref: *shape.Shape = @alignCast(@fieldParentPtr("header", header));
                try shape_ref.traceChildEdgesFallible(self.rt, self);
                if (self.err) |err| return err;
            },
            .realm_context => {
                const ctx: *context_mod.JSContext = @alignCast(@fieldParentPtr("header", header));
                ctx.traceChildEdgesNoFail(self);
                if (self.err) |err| return err;
            },
            .module => {
                const record: *module_mod.ModuleRecord = @alignCast(@fieldParentPtr("header", header));
                try record.traceChildEdgesFallible(self.rt, self);
                if (self.err) |err| return err;
            },
            .string, .big_int => {},
        }
    }

    fn finish(self: *Tracer) ShadowError!Report {
        var report = Report{};
        var ephemeron_values = HeaderSetManaged.init(self.allocator());
        report.exact_reachable = self.exact.count();
        report.conservative = self.conservative;

        var iterator = self.rt.gc.objectIterator();
        while (iterator.next()) |header| {
            report.allocated += 1;
            report.allocated_by_kind.add(header.metaConst().flags.kind);
            const addr = @intFromPtr(header);
            if (self.reachable.get(addr) != null) {
                report.reachable += 1;
                report.reachable_by_kind.add(header.metaConst().flags.kind);
                try collectEphemeronValues(header, &ephemeron_values);
                if (self.exact.get(addr) == null) {
                    report.conservative.retained_only_conservatively += 1;
                    report.conservative.transitive_bytes += gc.Registry.heapByteSizeFromHeader(self.rt, header);
                }
            }
        }
        report.conservative_inclusive = report.reachable;

        iterator = self.rt.gc.objectIterator();
        while (iterator.next()) |header| {
            if (self.reachable.get(@intFromPtr(header)) != null) continue;
            const kind = header.metaConst().flags.kind;
            const classified = classifyNotReachable(header, ephemeron_values);
            switch (classified) {
                .pending_finalization => report.pending_finalization += 1,
                .pinned => report.pinned += 1,
                .declared_external_owner => report.declared_external_owner += 1,
                .conservative_retention => report.conservative_retention += 1,
                .known_current_collector_semantic => report.known_current_collector_semantic += 1,
                .unexplained => report.unexplained += 1,
            }
            report.unexplained_by_kind.add(kind);
            if (report.sample_len < sample_cap) {
                report.sample_buf[report.sample_len] = .{
                    .header = header,
                    .kind = kind,
                    .class = classified,
                };
                report.sample_len += 1;
            }
        }
        return report;
    }
};

fn collectEphemeronValues(header: *gc.Header, into: *HeaderSetManaged) ShadowError!void {
    if (header.metaConst().flags.kind != .object) return;
    const obj: *Object = @alignCast(@fieldParentPtr("header", header));
    const payload = obj.collectionPayloadForCycleGc() orelse return;
    for (payload.weak_entries) |entry| {
        if (entry.value.cycleMarkHeader()) |child| {
            try into.put(@intFromPtr(child), {});
        }
    }
}

fn classifyNotReachable(
    header: *gc.Header,
    ephemeron_values: HeaderSetManaged,
) UnexplainedClass {
    if (header.metaConst().flags.is_pinned) return .pinned;
    if (header.metaConst().flags.finalizing) return .pending_finalization;
    if (ephemeron_values.get(@intFromPtr(header)) != null) {
        return .known_current_collector_semantic;
    }
    return .unexplained;
}

test "shadow tracer module loads" {
    try std.testing.expect(enabled);
}

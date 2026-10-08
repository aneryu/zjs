//! Module-record graph, live-binding cells, linking, and async-evaluation state.
//!
//! A RealmContext module registry owns each `ModuleRecord` and its atoms,
//! namespace/meta/exception values, closure cells, and dependency arrays.
//! Request edges borrow records from that same registry; retained VarRefs and
//! JSValues document the edges that keep bindings/results alive and are traced
//! by core GC. QuickJS source map: `JSModuleDef`. This is
//! realm-core state used by parser/compiler/exec orchestration; it must not
//! import exec or binding.

const std = @import("std");

const atom = @import("atom.zig");
const gc = @import("gc.zig");
const gc_visit = @import("gc_visit.zig");
const module_auto_init = @import("module_auto_init.zig");
const value_mod = @import("value.zig");
const VarRef = @import("var_ref.zig").VarRef;

const atom_default = atom.predefinedId("default", .string).?;
const atom_star = atom.predefinedId("*", .string).?;

/// Cyclic Module Record [[Status]] (§16.2.1.5). `errored` is the spec's
/// `evaluated` with a non-empty [[EvaluationError]] (`eval_exception`).
pub const Status = enum {
    unlinked,
    linking,
    linked,
    evaluating,
    /// Evaluated synchronously up to its async part; waits for itself or a
    /// dependency to finish (§16.2.1.5.3).
    evaluating_async,
    evaluated,
    errored,
};

/// [[AsyncEvaluationOrder]]: unset, an order, or done.
pub const async_order_unset: u64 = 0;
pub const async_order_done: u64 = std.math.maxInt(u64);

pub const SyntheticKind = enum {
    none,
    json,
    text,
    bytes,
};

/// One resolved module request. `module` is a borrowed pointer into the same
/// RealmContext-owned registry as the containing record. Registry membership
/// owns the records' base references, so request edges neither retain nor trace
/// their targets (matching QuickJS `JSReqModuleEntry.module`).
pub const RequestEntry = struct {
    module_name: atom.Atom,
    module: ?*ModuleRecord = null, // gc-slot: weak
};

pub const ImportEntry = struct {
    request_index: u32,
    import_name: atom.Atom,
    local_name: atom.Atom,
    /// Final module-function closure slot, frozen after declaration carriers
    /// have been appended.
    var_idx: u16,
    /// Namespace imports own a MODULE_DECL cell in the importer. Ordinary
    /// imports leave their MODULE_IMPORT slot null until indexed linking.
    is_namespace: bool,
};

/// A local export. The closure-table index is immutable after compilation;
/// linking retains the indexed cell here so the live binding survives module
/// function destruction.
pub const ExportEntry = struct {
    export_name: atom.Atom,
    local_name: atom.Atom,
    var_idx: u16,
    retained_cell: ?value_mod.JSValue = null,
};

pub const IndirectExportEntry = struct {
    request_index: u32,
    export_name: atom.Atom,
    import_name: atom.Atom,
    /// `export * as name from ...` is an indirect namespace export, not a star
    /// export. Resolution returns this entry itself so import linking can create
    /// a fresh importer-owned cell containing the target namespace.
    is_namespace: bool = false,
};

pub const StarExportEntry = struct {
    request_index: u32,
};

pub const ImportAttributeEntry = struct {
    request_index: u32,
    key: atom.Atom,
    value: atom.Atom,
};

pub const ResolvedBinding = struct {
    const Identity = struct {
        module: *ModuleRecord,
        binding_name: atom.Atom,
    };

    pub const Entry = union(enum) {
        local_export: u32,
        namespace_export: u32,
    };

    /// Borrowed stable record identity plus an index into that record's local
    /// or indirect-export table. The result never owns either component.
    module: *ModuleRecord,
    entry: Entry,

    pub fn sameIdentity(lhs: ResolvedBinding, rhs: ResolvedBinding) bool {
        const lhs_identity = lhs.identity();
        const rhs_identity = rhs.identity();
        return lhs_identity.module == rhs_identity.module and
            lhs_identity.binding_name == rhs_identity.binding_name;
    }

    /// Namespace bindings normalize to the requested module namespace rather
    /// than the re-exporting record that happens to carry the indexed locator.
    /// A local export of a namespace import uses the same normalization, so it
    /// compares equal to `export * as name` for the same target.
    fn identity(self: ResolvedBinding) Identity {
        switch (self.entry) {
            .namespace_export => |index| {
                const entry = self.module.indirect_exports[@intCast(index)];
                const request = self.module.requests[@intCast(entry.request_index)];
                std.debug.assert(entry.is_namespace);
                std.debug.assert(request.module != null);
                return .{
                    .module = request.module orelse self.module,
                    .binding_name = atom_star,
                };
            },
            .local_export => |index| {
                const local_name = self.module.exports[@intCast(index)].local_name;
                for (self.module.imports) |entry| {
                    if (!entry.is_namespace or entry.local_name != local_name) continue;
                    const request = self.module.requests[@intCast(entry.request_index)];
                    std.debug.assert(request.module != null);
                    return .{
                        .module = request.module orelse self.module,
                        .binding_name = atom_star,
                    };
                }
                return .{ .module = self.module, .binding_name = local_name };
            },
        }
    }
};

pub const ResolvedExport = union(enum) {
    not_found,
    ambiguous,
    resolved: ResolvedBinding,
};

/// Fully-owned, unpublished module definition. Load/compile code builds this
/// value off-registry, including the initial FunctionBytecode value, before
/// asking the registry for a target. An allocation failure therefore cannot
/// erase or partially rewrite an already-loaded module generation.
///
/// `module_ns` is intentionally absent: a namespace is published only after a
/// fresh record has been completely installed and linked.
/// The six definition arrays shared by `PendingDefinition` and
/// `ModuleRecord`, detached from their owner so they can be released.
const DefinitionArrays = struct {
    requests: []RequestEntry,
    imports: []ImportEntry,
    exports: []ExportEntry,
    indirect_exports: []IndirectExportEntry,
    star_exports: []StarExportEntry,
    import_attributes: []ImportAttributeEntry,

    /// Move the arrays out of `owner`, leaving it empty.
    fn take(owner: anytype) DefinitionArrays {
        defer {
            owner.requests = &.{};
            owner.imports = &.{};
            owner.exports = &.{};
            owner.indirect_exports = &.{};
            owner.star_exports = &.{};
            owner.import_attributes = &.{};
        }
        return .{
            .requests = owner.requests,
            .imports = owner.imports,
            .exports = owner.exports,
            .indirect_exports = owner.indirect_exports,
            .star_exports = owner.star_exports,
            .import_attributes = owner.import_attributes,
        };
    }

    fn free(self: DefinitionArrays, rt: *@import("../runtime.zig").JSRuntime) void {
        for (self.exports) |*entry| {
            if (entry.retained_cell) |cell| {
                std.debug.assert(VarRef.fromValue(cell) != null);
            }
        }
        if (self.requests.len != 0) rt.freeNative(RequestEntry, self.requests);
        if (self.imports.len != 0) rt.freeNative(ImportEntry, self.imports);
        if (self.exports.len != 0) rt.freeNative(ExportEntry, self.exports);
        if (self.indirect_exports.len != 0) rt.freeNative(IndirectExportEntry, self.indirect_exports);
        if (self.star_exports.len != 0) rt.freeNative(StarExportEntry, self.star_exports);
        if (self.import_attributes.len != 0) rt.freeNative(ImportAttributeEntry, self.import_attributes);
    }
};

pub const PendingDefinition = struct {
    runtime: *@import("../runtime.zig").JSRuntime,
    atoms: *atom.AtomTable,
    requests: []RequestEntry = &.{},
    imports: []ImportEntry = &.{},
    exports: []ExportEntry = &.{},
    indirect_exports: []IndirectExportEntry = &.{},
    star_exports: []StarExportEntry = &.{},
    import_attributes: []ImportAttributeEntry = &.{},
    func_obj: value_mod.JSValue = value_mod.JSValue.undefinedValue(),
    synthetic_kind: SyntheticKind = .none,
    has_top_level_await: bool = false,

    pub fn init(account: *@import("../runtime.zig").JSRuntime, atoms: *atom.AtomTable) PendingDefinition {
        return .{ .runtime = account, .atoms = atoms };
    }

    /// Release an unconsumed definition. Every owner is detached first so value
    /// destruction may safely re-enter GC/registry tracing.
    pub fn deinit(self: *PendingDefinition) void {
        const arrays = DefinitionArrays.take(self);
        self.func_obj = value_mod.JSValue.undefinedValue();
        self.synthetic_kind = .none;
        self.has_top_level_await = false;
        arrays.free(self.runtime);
    }

    pub fn addRequest(self: *PendingDefinition, module_name: atom.Atom) !u32 {
        const index = std.math.cast(u32, self.requests.len) orelse return error.ModuleMetadataOverflow;
        const owned_name = self.atoms.noteHolderStore(module_name);
        try append(self.runtime, RequestEntry, &self.requests, .{ .module_name = owned_name });
        return index;
    }

    pub fn addImport(
        self: *PendingDefinition,
        request_index: u32,
        import_name: atom.Atom,
        local_name: atom.Atom,
        var_idx: u16,
        is_namespace: bool,
    ) !void {
        try self.validateRequestIndex(request_index);
        const owned_import_name = self.atoms.noteHolderStore(import_name);
        const owned_local_name = self.atoms.noteHolderStore(local_name);
        try append(self.runtime, ImportEntry, &self.imports, .{
            .request_index = request_index,
            .import_name = owned_import_name,
            .local_name = owned_local_name,
            .var_idx = var_idx,
            .is_namespace = is_namespace,
        });
    }

    pub fn addExport(
        self: *PendingDefinition,
        export_name: atom.Atom,
        local_name: atom.Atom,
        var_idx: u16,
    ) !void {
        if (self.exports.len > std.math.maxInt(u32)) return error.ModuleMetadataOverflow;
        const owned_export_name = self.atoms.noteHolderStore(export_name);
        const owned_local_name = self.atoms.noteHolderStore(local_name);
        try append(self.runtime, ExportEntry, &self.exports, .{
            .export_name = owned_export_name,
            .local_name = owned_local_name,
            .var_idx = var_idx,
        });
    }

    pub fn addIndirectExport(
        self: *PendingDefinition,
        request_index: u32,
        export_name: atom.Atom,
        import_name: atom.Atom,
        is_namespace: bool,
    ) !void {
        try self.validateRequestIndex(request_index);
        if (self.indirect_exports.len > std.math.maxInt(u32)) return error.ModuleMetadataOverflow;
        const owned_export_name = self.atoms.noteHolderStore(export_name);
        const owned_import_name = self.atoms.noteHolderStore(import_name);
        try append(self.runtime, IndirectExportEntry, &self.indirect_exports, .{
            .request_index = request_index,
            .export_name = owned_export_name,
            .import_name = owned_import_name,
            .is_namespace = is_namespace,
        });
    }

    pub fn addStarExport(self: *PendingDefinition, request_index: u32) !void {
        try self.validateRequestIndex(request_index);
        try append(self.runtime, StarExportEntry, &self.star_exports, .{ .request_index = request_index });
    }

    pub fn addImportAttribute(
        self: *PendingDefinition,
        request_index: u32,
        key: atom.Atom,
        value: atom.Atom,
    ) !void {
        try self.validateRequestIndex(request_index);
        const owned_key = self.atoms.noteHolderStore(key);
        const owned_value = self.atoms.noteHolderStore(value);
        try append(self.runtime, ImportAttributeEntry, &self.import_attributes, .{
            .request_index = request_index,
            .key = owned_key,
            .value = owned_value,
        });
    }

    /// Borrow the initial FunctionBytecode/function value. Typed decoding is an
    /// exec-layer concern; core exposes only the JSValue owner.
    pub fn funcObjectValue(self: *const PendingDefinition) value_mod.JSValue {
        return self.func_obj;
    }

    /// Adopt the initial FunctionBytecode owner. Replacing a live owner would
    /// violate the exact take/adopt transition used when it becomes a function
    /// object.
    pub fn adoptFuncObjectValueNoFail(self: *PendingDefinition, next: value_mod.JSValue) void {
        std.debug.assert(self.func_obj.is(.undefined_value));
        std.debug.assert(!next.is(.undefined_value));
        self.func_obj = next;
    }

    pub fn takeFuncObjectValueNoFail(self: *PendingDefinition) value_mod.JSValue {
        const owned = self.func_obj;
        self.func_obj = value_mod.JSValue.undefinedValue();
        return owned;
    }

    fn validateRequestIndex(self: *const PendingDefinition, request_index: u32) !void {
        if (@as(usize, request_index) >= self.requests.len) return error.InvalidModuleRequestIndex;
    }
};

pub const ModuleRecord = struct {
    pub const gc_kind_tag: u8 = @intFromEnum(gc.GcKind.module);

    comptime {
        // The GC finds the record through its embedded header, so the header
        // must remain at payload offset zero.
        std.debug.assert(@offsetOf(@This(), "header") == 0);
        std.debug.assert(@sizeOf(@This()) == 288);
        std.debug.assert(@alignOf(@This()) == 16);
        std.debug.assert(@offsetOf(@This(), "registry_prev") == 16);
        std.debug.assert(@offsetOf(@This(), "registry") == 32);
        std.debug.assert(@offsetOf(@This(), "runtime") == 40);
        std.debug.assert(@offsetOf(@This(), "module_name") == 268);
        std.debug.assert(@offsetOf(@This(), "requests") == 104);
        std.debug.assert(@offsetOf(@This(), "func_obj") == 88);
        std.debug.assert(@offsetOf(@This(), "module_ns") == 200);
        std.debug.assert(@offsetOf(@This(), "status") == 276);
    }

    header: gc.Header align(16) = .{},
    /// Independent, non-owning membership in the realm's loaded-module list.
    /// The GC header links above remain reserved for the collector.
    registry_prev: ?*ModuleRecord = null,
    registry_next: ?*ModuleRecord = null,
    registry: ?*Registry = null,
    runtime: *@import("../runtime.zig").JSRuntime,
    atoms: *atom.AtomTable,
    module_name: atom.Atom,
    definition_installed: bool = false,
    /// True only after every request edge names its canonical record. A module
    /// definition may be published earlier so recursive loading can close
    /// cycles, but linking/evaluation must not observe that provisional state.
    requests_resolved: bool = false,
    status: Status = .unlinked,
    requests: []RequestEntry = &.{},
    imports: []ImportEntry = &.{},
    exports: []ExportEntry = &.{},
    indirect_exports: []IndirectExportEntry = &.{},
    star_exports: []StarExportEntry = &.{},
    import_attributes: []ImportAttributeEntry = &.{},
    /// Owns either the compiled FunctionBytecode value or the resulting module
    /// function object. Core never decodes the active JSValue variant.
    func_obj: value_mod.JSValue = value_mod.JSValue.undefinedValue(),
    /// Published only after complete namespace construction.
    module_ns: value_mod.JSValue = value_mod.JSValue.undefinedValue(),
    /// One stable MODULE_NS AUTOINIT opaque owner per record. Individual
    /// properties re-resolve `(record, property atom)` through this owner; no
    /// per-export owner table is permitted.
    namespace_auto_init_owner: module_auto_init.AutoInitModuleOwner = .{
        .resolve = unresolvedModuleAutoInit,
    },
    import_meta: ?value_mod.JSValue = null,
    import_meta_main: bool = false,
    synthetic_kind: SyntheticKind = .none,
    has_top_level_await: bool = false,
    /// Tarjan fields are transient linking state. `link_stack_prev` is borrowed
    /// and valid only while status is `.linking`.
    link_dfs_index: u32 = 0,
    link_dfs_ancestor_index: u32 = 0,
    link_stack_prev: ?*ModuleRecord = null,
    /// [[EvaluationError]]: a module whose evaluation failed stays `.errored`
    /// and every later import rethrows this value instead of re-running the
    /// body.
    eval_exception: ?value_mod.JSValue = null,
    /// Evaluation state (§16.2.1.5.3). The DFS indices are transient, valid
    /// while the record is on an InnerModuleEvaluation stack.
    eval_dfs_index: u32 = 0,
    eval_dfs_ancestor_index: u32 = 0,
    /// [[CycleRoot]], set when the record's strongly connected component
    /// leaves the evaluation stack. Records of one realm registry outlive
    /// each other's references, so this and `async_parent_modules` are
    /// borrowed.
    cycle_root: ?*ModuleRecord = null,
    async_evaluation_order: u64 = async_order_unset,
    pending_async_dependencies: u32 = 0,
    async_parent_modules: std.ArrayListUnmanaged(*ModuleRecord) = .empty,
    /// [[TopLevelCapability]] exists: an Evaluate() started here.
    has_top_level_capability: bool = false,

    fn prepare(self: *ModuleRecord, account: *@import("../runtime.zig").JSRuntime, atoms: *atom.AtomTable, name: atom.Atom) void {
        self.* = .{
            .runtime = account,
            .atoms = atoms,
            .module_name = atoms.noteHolderStore(name),
        };
    }

    /// Install a complete definition into a fresh, unpublished target. This
    /// operation cannot fail and consumes `pending`. Replacing a published or
    /// previously-installed generation would invalidate MODULE_NS AUTOINIT
    /// opaque pointers, so it is forbidden by construction.
    pub fn replaceDefinitionNoFail(self: *ModuleRecord, pending: *PendingDefinition) void {
        std.debug.assert(self.registry == null);
        std.debug.assert(!self.definition_installed);
        std.debug.assert(!self.requests_resolved);
        std.debug.assert(self.runtime == pending.runtime);
        std.debug.assert(self.atoms == pending.atoms);
        std.debug.assert(self.requests.len == 0);
        std.debug.assert(self.imports.len == 0);
        std.debug.assert(self.exports.len == 0);
        std.debug.assert(self.indirect_exports.len == 0);
        std.debug.assert(self.star_exports.len == 0);
        std.debug.assert(self.import_attributes.len == 0);
        std.debug.assert(self.func_obj.is(.undefined_value));
        std.debug.assert(self.module_ns.is(.undefined_value));
        for (pending.requests) |entry| std.debug.assert(entry.module == null);
        for (pending.exports) |entry| std.debug.assert(entry.retained_cell == null);

        self.requests = pending.requests;
        self.imports = pending.imports;
        self.exports = pending.exports;
        self.indirect_exports = pending.indirect_exports;
        self.star_exports = pending.star_exports;
        self.import_attributes = pending.import_attributes;
        self.func_obj = pending.func_obj;
        self.synthetic_kind = pending.synthetic_kind;
        self.has_top_level_await = pending.has_top_level_await;
        self.definition_installed = true;

        pending.requests = &.{};
        pending.imports = &.{};
        pending.exports = &.{};
        pending.indirect_exports = &.{};
        pending.star_exports = &.{};
        pending.import_attributes = &.{};
        pending.func_obj = value_mod.JSValue.undefinedValue();
        pending.synthetic_kind = .none;
        pending.has_top_level_await = false;
    }

    /// Detach and release the definition during finalization. Loaded records are
    /// never reset in place for a new generation.
    fn clearForDestroy(self: *ModuleRecord) void {
        // Detach every owned payload before releases can re-enter tracing.
        const arrays = DefinitionArrays.take(self);
        self.definition_installed = false;
        self.requests_resolved = false;
        self.status = .unlinked;
        self.func_obj = value_mod.JSValue.undefinedValue();
        self.module_ns = value_mod.JSValue.undefinedValue();
        self.import_meta = null;
        self.import_meta_main = false;
        self.synthetic_kind = .none;
        self.has_top_level_await = false;
        self.resetLinkTransientNoFail();
        self.eval_exception = null;
        self.cycle_root = null;
        self.async_parent_modules.deinit(self.runtime.nativeAllocator());
        self.async_parent_modules = .empty;
        arrays.free(self.runtime);
    }

    /// `rt` is unused: the destroy-by-kind dispatch (`gc.zig`,
    /// `gc_trace_stw.zig`) calls every kind's destructor with the same
    /// (runtime, header) shape, and a module frees through its own
    /// `runtime` (`gc.destroyCell`).
    pub fn destroyFromHeader(rt: anytype, header: *gc.Header) void {
        _ = rt;
        const self: *ModuleRecord = @alignCast(@fieldParentPtr("header", header));
        if (self.registry) |registry| registry.unlink(self);

        self.module_name = atom.null_atom;
        self.clearForDestroy();

        // TGC S4-e spec 2.5: no Pass-B deferral.
        self.runtime.gc.destroyCell(ModuleRecord, self);
    }

    pub inline fn traceChildEdgesFallible(self: *ModuleRecord, rt: anytype, visitor: anytype) !void {
        _ = rt;
        for (self.exports) |*entry| {
            if (entry.retained_cell) |*cell| {
                std.debug.assert(VarRef.fromValue(cell.*) != null);
                try gc_visit.value(visitor, cell);
            }
        }
        try gc_visit.value(visitor, &self.func_obj);
        try gc_visit.value(visitor, &self.module_ns);
        if (self.import_meta) |*value| try gc_visit.value(visitor, value);
        if (self.eval_exception) |*value| try gc_visit.value(visitor, value);

        // TGC S3 §2.2 edge E: the record's own name plus every atom in the
        // six metadata arrays -- exactly the set `clearForDestroy` releases.
        // `star_exports` holds only a request index, so it contributes none.
        try gc_visit.atom(visitor, self.module_name);
        for (self.requests) |entry| try gc_visit.atom(visitor, entry.module_name);
        for (self.imports) |entry| {
            try gc_visit.atom(visitor, entry.import_name);
            try gc_visit.atom(visitor, entry.local_name);
        }
        for (self.exports) |entry| {
            try gc_visit.atom(visitor, entry.export_name);
            try gc_visit.atom(visitor, entry.local_name);
        }
        for (self.indirect_exports) |entry| {
            try gc_visit.atom(visitor, entry.export_name);
            try gc_visit.atom(visitor, entry.import_name);
        }
        for (self.import_attributes) |entry| {
            try gc_visit.atom(visitor, entry.key);
            try gc_visit.atom(visitor, entry.value);
        }
    }

    pub inline fn traceChildEdgesNoFail(self: *ModuleRecord, rt: anytype, visitor: anytype) void {
        self.traceChildEdgesFallible(rt, visitor) catch unreachable;
    }

    /// Take ownership of `value` as the cached evaluation exception
    /// (mirrors qjs js_set_module_evaluated error path setting
    /// `m->eval_exception`, quickjs.c).
    pub fn setEvalException(self: *ModuleRecord, rt: anytype, value: value_mod.JSValue) void {
        self.eval_exception = value;
        rt.gc.generationalBarrier(&self.header, value.cycleMarkHeader());
    }

    pub fn request(self: *ModuleRecord, request_index: u32) ?*RequestEntry {
        if (@as(usize, request_index) >= self.requests.len) return null;
        return &self.requests[@intCast(request_index)];
    }

    pub fn requestsResolved(self: *const ModuleRecord) bool {
        return self.requests_resolved;
    }

    /// Publish request completeness after every borrowed dependency pointer is
    /// installed. Repeating the mark is harmless; changing an edge afterward is
    /// forbidden so linkers may treat this as a stable graph-generation fact.
    pub fn markRequestsResolvedNoFail(self: *ModuleRecord) void {
        std.debug.assert(self.registry != null);
        for (self.requests) |entry| std.debug.assert(entry.module != null);
        self.requests_resolved = true;
    }

    /// Publish the borrowed dependency identity after host resolution. Both
    /// records must belong to this same realm registry.
    pub fn setRequestModuleNoFail(self: *ModuleRecord, request_index: u32, dependency: *ModuleRecord) void {
        const entry = self.request(request_index).?;
        std.debug.assert(self.registry != null);
        std.debug.assert(dependency.registry == self.registry);
        std.debug.assert(!self.requests_resolved);
        std.debug.assert(entry.module == null);
        entry.module = dependency;
    }

    /// Borrow the record's single persistent artifact/function owner.
    pub fn funcObjectValue(self: *const ModuleRecord) value_mod.JSValue {
        return self.func_obj;
    }

    /// Complete a FunctionBytecode -> function-object move after the old owner
    /// was taken. A live slot may never be silently replaced or freed here.
    pub fn adoptFuncObjectValueNoFail(self: *ModuleRecord, rt: anytype, next: value_mod.JSValue) void {
        std.debug.assert(self.func_obj.is(.undefined_value));
        std.debug.assert(!next.is(.undefined_value));
        self.func_obj = next;
        // A ModuleRecord is a traced heap object; installing its function is an
        // owner-to-child store like any other.
        rt.gc.generationalBarrier(&self.header, next.cycleMarkHeader());
    }

    pub fn takeFuncObjectValueNoFail(self: *ModuleRecord) value_mod.JSValue {
        const owned = self.func_obj;
        self.func_obj = value_mod.JSValue.undefinedValue();
        return owned;
    }

    pub fn moduleNamespaceValue(self: *const ModuleRecord) value_mod.JSValue {
        return self.module_ns;
    }

    /// Publish a completely-constructed namespace. The record takes ownership.
    pub fn publishModuleNamespaceNoFail(self: *ModuleRecord, rt: anytype, owned: value_mod.JSValue) void {
        std.debug.assert(self.module_ns.is(.undefined_value));
        std.debug.assert(owned.is(.object));
        self.module_ns = owned;
        rt.gc.generationalBarrier(&self.header, owned.cycleMarkHeader());
    }

    pub fn namespaceAutoInitOwner(self: *const ModuleRecord) *const module_auto_init.AutoInitModuleOwner {
        return &self.namespace_auto_init_owner;
    }

    pub fn setNamespaceAutoInitResolverNoFail(
        self: *ModuleRecord,
        resolve: @FieldType(module_auto_init.AutoInitModuleOwner, "resolve"),
    ) void {
        std.debug.assert(self.module_ns.is(.undefined_value));
        std.debug.assert(self.namespace_auto_init_owner.resolve == unresolvedModuleAutoInit);
        self.namespace_auto_init_owner.resolve = resolve;
    }

    /// Consume one retained VarRef JSValue. The cell has exactly one owner in
    /// this export entry until it is cleared or the record is destroyed.
    pub fn publishRetainedExportCellNoFail(
        self: *ModuleRecord,
        rt: *@import("../runtime.zig").JSRuntime,
        export_index: u32,
        owned_cell: value_mod.JSValue,
    ) void {
        const entry = &self.exports[@intCast(export_index)];
        std.debug.assert(entry.retained_cell == null);
        std.debug.assert(VarRef.fromValue(owned_cell) != null);
        entry.retained_cell = owned_cell;
        // The record may be old; a synthetic module's cell is held only here.
        rt.gc.generationalBarrier(&self.header, owned_cell.cycleMarkHeader());
    }

    /// Borrow a retained local-export cell.
    pub fn retainedExportCellValue(self: *const ModuleRecord, export_index: u32) ?value_mod.JSValue {
        const cell = self.exports[@intCast(export_index)].retained_cell;
        if (cell) |value| std.debug.assert(VarRef.fromValue(value) != null);
        return cell;
    }

    /// Clearing the cell is a plain store under the tracing collector.
    pub fn clearRetainedExportCellNoFail(self: *ModuleRecord, export_index: u32) void {
        const entry = &self.exports[@intCast(export_index)];
        const owned = entry.retained_cell orelse return;
        std.debug.assert(VarRef.fromValue(owned) != null);
        entry.retained_cell = null;
    }

    pub fn resetLinkTransientNoFail(self: *ModuleRecord) void {
        self.link_dfs_index = 0;
        self.link_dfs_ancestor_index = 0;
        self.link_stack_prev = null;
    }
};

pub const Registry = struct {
    runtime: *@import("../runtime.zig").JSRuntime,
    atoms: *atom.AtomTable,
    gc_registry: *gc.Registry,
    head: ?*ModuleRecord = null,
    tail: ?*ModuleRecord = null,
    /// Name -> record, so `find` is not a list walk: module work looks records
    /// up by name at nearly every step. Held on the heap so the registry
    /// keeps its size inside the pinned RealmContext layout.
    names: ?*Names = null,

    const Names = struct {
        map: std.AutoHashMapUnmanaged(atom.Atom, *ModuleRecord) = .empty,
        /// Removals since the last rehash: std hash map removals leave
        /// tombstones and never regrow.
        removals: usize = 0,
    };

    pub const Iterator = struct {
        cursor: ?*ModuleRecord,

        pub fn next(self: *Iterator) ?*ModuleRecord {
            const current = self.cursor orelse return null;
            self.cursor = current.registry_next;
            return current;
        }
    };

    /// An existing result leaves the caller's PendingDefinition untouched. A
    /// fresh result consumed it before the record became observable.
    pub const PreparedTarget = union(enum) {
        existing: *ModuleRecord,
        fresh: *ModuleRecord,

        pub fn record(self: PreparedTarget) *ModuleRecord {
            return switch (self) {
                .existing, .fresh => |target| target,
            };
        }

        pub fn isFresh(self: PreparedTarget) bool {
            return switch (self) {
                .existing => false,
                .fresh => true,
            };
        }
    };

    pub fn init(account: *@import("../runtime.zig").JSRuntime, atoms: *atom.AtomTable, gc_registry: *gc.Registry) Registry {
        return .{
            .runtime = account,
            .atoms = atoms,
            .gc_registry = gc_registry,
        };
    }

    pub fn deinit(self: *Registry) void {
        while (self.head) |record| {
            self.unlink(record);
        }
        std.debug.assert(self.tail == null);
        if (self.names) |names| {
            std.debug.assert(names.map.count() == 0);
            names.map.deinit(self.runtime.nativeAllocator());
            self.runtime.nativeAllocator().destroy(names);
            self.names = null;
        }
    }

    pub fn count(self: *const Registry) usize {
        return if (self.names) |names| names.map.count() else 0;
    }

    pub fn iterator(self: *const Registry) Iterator {
        return .{ .cursor = self.head };
    }

    pub inline fn traceChildEdgesFallible(self: *Registry, visitor: anytype) !void {
        var iter = self.iterator();
        while (iter.next()) |record| try gc_visit.module(visitor, record);
    }

    pub inline fn traceChildEdgesNoFail(self: *Registry, visitor: anytype) void {
        self.traceChildEdgesFallible(visitor) catch unreachable;
    }

    fn link(self: *Registry, record: *ModuleRecord) void {
        std.debug.assert(record.registry == null);
        std.debug.assert(record.registry_prev == null);
        std.debug.assert(record.registry_next == null);

        record.registry = self;
        record.registry_prev = self.tail;
        if (self.tail) |tail| {
            tail.registry_next = record;
        } else {
            self.head = record;
        }
        self.tail = record;
        self.names.?.map.putAssumeCapacityNoClobber(record.module_name, record);
    }

    /// Remove list membership only. The caller decides whether the membership
    /// base-reference has already been consumed by cycle GC or must be released.
    pub fn unlink(self: *Registry, record: *ModuleRecord) void {
        if (record.registry != self) {
            std.debug.assert(record.registry == null);
            return;
        }

        const prev = record.registry_prev;
        const next = record.registry_next;
        if (prev) |previous| {
            previous.registry_next = next;
        } else {
            std.debug.assert(self.head == record);
            self.head = next;
        }
        if (next) |following| {
            following.registry_prev = prev;
        } else {
            std.debug.assert(self.tail == record);
            self.tail = prev;
        }

        record.registry_prev = null;
        record.registry_next = null;
        record.registry = null;
        const names = self.names.?;
        std.debug.assert(names.map.get(record.module_name) == record);
        _ = names.map.remove(record.module_name);
        names.removals += 1;
        if (names.removals * 4 >= names.map.capacity()) {
            names.removals = 0;
            names.map.rehash(std.hash_map.AutoContext(atom.Atom){});
        }
    }

    /// Return the already-published record for `name`, or atomically install a
    /// complete fresh definition. Allocation is the only fallible step. After
    /// it succeeds, definition transfer, GC publication, and list linkage are
    /// all no-fail, so OOM cannot leave a partial record or perturb an existing
    /// generation.
    pub fn prepareFreshTarget(
        self: *Registry,
        name: atom.Atom,
        pending: *PendingDefinition,
    ) !PreparedTarget {
        std.debug.assert(pending.runtime == self.runtime);
        std.debug.assert(pending.atoms == self.atoms);

        if (self.find(name)) |record| {
            std.debug.assert(record.definition_installed);
            return .{ .existing = record };
        }

        const allocator = self.runtime.nativeAllocator();
        const names = self.names orelse blk: {
            const created = try allocator.create(Names);
            created.* = .{};
            self.names = created;
            break :blk created;
        };
        try names.map.ensureUnusedCapacity(allocator, 1);
        const record = try self.runtime.gc.createCell(ModuleRecord);
        record.prepare(self.runtime, self.atoms, name);
        record.replaceDefinitionNoFail(pending);
        // Bulk install of a whole pending definition -- exports, the function
        // object, import attributes. Remember the record once instead of
        // enumerating the fields.
        self.gc_registry.rememberOwnerForBulkWrite(&record.header);
        self.gc_registry.addInitializedWithSizeNoFail(&record.header, @sizeOf(ModuleRecord));
        self.link(record);
        return .{ .fresh = record };
    }

    pub fn find(self: *const Registry, name: atom.Atom) ?*ModuleRecord {
        const names = self.names orelse return null;
        return names.map.get(name);
    }

    /// Pure indexed export resolution. Host loading first fills every borrowed
    /// RequestEntry.module pointer; this routine neither loads dependencies nor
    /// mutates module status, cells, diagnostics, or registry membership.
    pub fn resolveExport(
        self: *Registry,
        record: *ModuleRecord,
        export_name: atom.Atom,
    ) !ResolvedExport {
        if (record.registry != self) return error.ForeignModuleRecord;
        const allocator = self.runtime.nativeAllocator();
        // `resolve_set` keeps every pair the whole call visited, as the spec's
        // resolveSet does, so a diamond of `export *` edges is explored once
        // rather than once per path.
        var resolve_set: std.AutoHashMapUnmanaged(ResolutionVisit, void) = .empty;
        defer resolve_set.deinit(allocator);
        // Re-export chains are user-controlled in depth, so the recursion of
        // ResolveExport (§16.2.1.7.2.2) runs on explicit stacks: a single
        // named re-export continues in place, and each `export *` loop is a
        // StarScan whose children report back through `result`.
        var stars: std.ArrayList(StarScan) = .empty;
        defer stars.deinit(allocator);

        var current = record;
        var name = export_name;
        next: while (true) {
            const terminal: ?ResolvedExport = resolve: {
                if ((try resolve_set.getOrPut(allocator, .{ .module = current, .export_name = name })).found_existing)
                    break :resolve .not_found;

                for (current.exports, 0..) |entry, index| {
                    if (entry.export_name != name) continue;
                    for (current.imports) |import_entry| {
                        if (import_entry.local_name != entry.local_name) continue;
                        if (import_entry.is_namespace) break;
                        current = try requestDependency(current, import_entry.request_index);
                        name = import_entry.import_name;
                        continue :next;
                    }
                    break :resolve .{ .resolved = .{
                        .module = current,
                        .entry = .{ .local_export = @intCast(index) },
                    } };
                }

                for (current.indirect_exports, 0..) |entry, index| {
                    if (entry.export_name != name) continue;
                    const dependency = try requestDependency(current, entry.request_index);
                    if (entry.is_namespace) break :resolve .{ .resolved = .{
                        .module = current,
                        .entry = .{ .namespace_export = @intCast(index) },
                    } };
                    current = dependency;
                    name = entry.import_name;
                    continue :next;
                }

                if (name == atom_default or current.star_exports.len == 0) break :resolve .not_found;
                try stars.append(allocator, .{ .module = current, .export_name = name });
                break :resolve null;
            };
            var result = terminal orelse {
                const scan = &stars.items[stars.items.len - 1];
                current = try requestDependency(scan.module, scan.module.star_exports[0].request_index);
                scan.next_index = 1;
                continue :next;
            };

            while (stars.items.len != 0) {
                const scan = &stars.items[stars.items.len - 1];
                switch (result) {
                    .not_found => {},
                    // Every enclosing level would return it unchanged.
                    .ambiguous => return .ambiguous,
                    .resolved => |binding| if (scan.found) |existing| {
                        if (!existing.sameIdentity(binding)) return .ambiguous;
                    } else {
                        scan.found = binding;
                    },
                }
                if (scan.next_index < scan.module.star_exports.len) {
                    current = try requestDependency(scan.module, scan.module.star_exports[scan.next_index].request_index);
                    name = scan.export_name;
                    scan.next_index += 1;
                    continue :next;
                }
                result = if (scan.found) |binding| .{ .resolved = binding } else .not_found;
                _ = stars.pop();
            }
            return result;
        }
    }
};

/// One pending `export *` loop of ResolveExport.
const StarScan = struct {
    module: *ModuleRecord,
    export_name: atom.Atom,
    next_index: usize = 0,
    found: ?ResolvedBinding = null,
};

const ResolutionVisit = struct {
    /// Both fields are borrowed for the duration of one resolution traversal.
    module: *ModuleRecord,
    export_name: atom.Atom,
};

fn requestDependency(record: *ModuleRecord, request_index: u32) !*ModuleRecord {
    const request = record.request(request_index) orelse return error.InvalidModuleRequestIndex;
    const dependency = request.module orelse return error.ModuleNotFound;
    if (dependency.registry != record.registry) return error.ForeignModuleRecord;
    return dependency;
}

fn unresolvedModuleAutoInit(
    owner: *const module_auto_init.AutoInitModuleOwner,
    realm_header: *gc.Header,
    atom_id: atom.Atom,
) anyerror!module_auto_init.AutoInitMaterialization {
    _ = owner;
    _ = realm_header;
    _ = atom_id;
    return error.InvalidBuiltinRegistry;
}

inline fn append(account: *@import("../runtime.zig").JSRuntime, comptime T: type, slice: *[]T, item: T) !void {
    const old = slice.*;
    const new_count = std.math.add(usize, old.len, 1) catch return error.OutOfMemory;
    const old_ptr: [*]u8 = if (old.len == 0) undefined else @ptrCast(old.ptr);
    const new_buf = try account.reallocNativeElements(
        old_ptr,
        old.len,
        new_count,
        @sizeOf(T),
        comptime std.mem.Alignment.of(T),
    );
    const next: []T = @as([*]T, @ptrCast(@alignCast(new_buf.ptr)))[0..new_count];
    next[old.len] = item;
    slice.* = next;
}

const std = @import("std");

const atom = @import("atom.zig");
const gc = @import("gc.zig");
const memory = @import("memory.zig");
const module_auto_init = @import("module_auto_init.zig");
const value_mod = @import("value.zig");
const VarRef = @import("var_ref.zig").VarRef;

const atom_default = atom.predefinedId("default", .string).?;
const atom_star = atom.predefinedId("*", .string).?;

pub const Status = enum {
    unlinked,
    linking,
    linked,
    evaluating,
    evaluated,
    errored,
};

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
    module: ?*ModuleRecord = null,
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

    pub fn bindingName(self: ResolvedBinding) atom.Atom {
        return switch (self.entry) {
            .local_export => |index| self.module.exports[@intCast(index)].local_name,
            .namespace_export => atom_star,
        };
    }

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
pub const PendingDefinition = struct {
    memory: *memory.MemoryAccount,
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

    pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable) PendingDefinition {
        return .{ .memory = account, .atoms = atoms };
    }

    /// Release an unconsumed definition. Every owner is detached first so value
    /// destruction may safely re-enter GC/registry tracing.
    pub fn deinit(self: *PendingDefinition, rt: anytype) void {
        const requests = self.requests;
        const imports = self.imports;
        const exports = self.exports;
        const indirect_exports = self.indirect_exports;
        const star_exports = self.star_exports;
        const import_attributes = self.import_attributes;
        const func_obj = self.func_obj;

        self.requests = &.{};
        self.imports = &.{};
        self.exports = &.{};
        self.indirect_exports = &.{};
        self.star_exports = &.{};
        self.import_attributes = &.{};
        self.func_obj = value_mod.JSValue.undefinedValue();
        self.synthetic_kind = .none;
        self.has_top_level_await = false;

        for (requests) |entry| self.atoms.free(entry.module_name);
        for (imports) |entry| {
            self.atoms.free(entry.import_name);
            self.atoms.free(entry.local_name);
        }
        for (exports) |*entry| {
            self.atoms.free(entry.export_name);
            self.atoms.free(entry.local_name);
            if (entry.retained_cell) |cell| {
                std.debug.assert(VarRef.fromValue(cell) != null);
                cell.free(rt);
            }
        }
        for (indirect_exports) |entry| {
            self.atoms.free(entry.export_name);
            self.atoms.free(entry.import_name);
        }
        for (import_attributes) |entry| {
            self.atoms.free(entry.key);
            self.atoms.free(entry.value);
        }
        func_obj.free(rt);

        if (requests.len != 0) self.memory.free(RequestEntry, requests);
        if (imports.len != 0) self.memory.free(ImportEntry, imports);
        if (exports.len != 0) self.memory.free(ExportEntry, exports);
        if (indirect_exports.len != 0) self.memory.free(IndirectExportEntry, indirect_exports);
        if (star_exports.len != 0) self.memory.free(StarExportEntry, star_exports);
        if (import_attributes.len != 0) self.memory.free(ImportAttributeEntry, import_attributes);
    }

    pub fn addRequest(self: *PendingDefinition, module_name: atom.Atom) !u32 {
        const index = std.math.cast(u32, self.requests.len) orelse return error.ModuleMetadataOverflow;
        const owned_name = self.atoms.dup(module_name);
        errdefer self.atoms.free(owned_name);
        try append(self.memory, RequestEntry, &self.requests, .{ .module_name = owned_name });
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
        const owned_import_name = self.atoms.dup(import_name);
        errdefer self.atoms.free(owned_import_name);
        const owned_local_name = self.atoms.dup(local_name);
        errdefer self.atoms.free(owned_local_name);
        try append(self.memory, ImportEntry, &self.imports, .{
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
        const owned_export_name = self.atoms.dup(export_name);
        errdefer self.atoms.free(owned_export_name);
        const owned_local_name = self.atoms.dup(local_name);
        errdefer self.atoms.free(owned_local_name);
        try append(self.memory, ExportEntry, &self.exports, .{
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
        const owned_export_name = self.atoms.dup(export_name);
        errdefer self.atoms.free(owned_export_name);
        const owned_import_name = self.atoms.dup(import_name);
        errdefer self.atoms.free(owned_import_name);
        try append(self.memory, IndirectExportEntry, &self.indirect_exports, .{
            .request_index = request_index,
            .export_name = owned_export_name,
            .import_name = owned_import_name,
            .is_namespace = is_namespace,
        });
    }

    pub fn addStarExport(self: *PendingDefinition, request_index: u32) !void {
        try self.validateRequestIndex(request_index);
        try append(self.memory, StarExportEntry, &self.star_exports, .{ .request_index = request_index });
    }

    pub fn addImportAttribute(
        self: *PendingDefinition,
        request_index: u32,
        key: atom.Atom,
        value: atom.Atom,
    ) !void {
        try self.validateRequestIndex(request_index);
        const owned_key = self.atoms.dup(key);
        errdefer self.atoms.free(owned_key);
        const owned_value = self.atoms.dup(value);
        errdefer self.atoms.free(owned_value);
        try append(self.memory, ImportAttributeEntry, &self.import_attributes, .{
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
        std.debug.assert(self.func_obj.isUndefined());
        std.debug.assert(!next.isUndefined());
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
        // MemoryAccount places the common GC metadata immediately before the
        // record, so the embedded header must remain at payload offset zero.
        std.debug.assert(@offsetOf(@This(), "header") == 0);
    }

    header: gc.GCObjectHeader align(16) = .{},
    /// Independent, non-owning membership in the realm's loaded-module list.
    /// The GC header links above remain reserved for the collector.
    registry_prev: ?*ModuleRecord = null,
    registry_next: ?*ModuleRecord = null,
    registry: ?*Registry = null,
    memory: *memory.MemoryAccount,
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
    /// Cached evaluation exception: a module whose evaluation threw stays
    /// `.errored` and every later import rethrows this value instead of
    /// re-running the body (mirrors qjs `JSModuleDef.eval_has_exception` /
    /// `eval_exception`, rethrown by js_inner_module_evaluation
    /// quickjs.c:31442).
    eval_exception: ?value_mod.JSValue = null,

    fn prepare(self: *ModuleRecord, account: *memory.MemoryAccount, atoms: *atom.AtomTable, name: atom.Atom) void {
        self.* = .{
            .memory = account,
            .atoms = atoms,
            .module_name = atoms.dup(name),
        };
    }

    pub fn retain(self: *ModuleRecord) void {
        gc.retain(&self.header);
    }

    pub fn release(self: *ModuleRecord, rt: anytype) void {
        gc.release(rt, &self.header);
    }

    /// Install a complete definition into a fresh, unpublished target. This
    /// operation cannot fail and consumes `pending`. Replacing a published or
    /// previously-installed generation would invalidate MODULE_NS AUTOINIT
    /// opaque pointers, so it is forbidden by construction.
    pub fn replaceDefinitionNoFail(self: *ModuleRecord, pending: *PendingDefinition) void {
        std.debug.assert(self.registry == null);
        std.debug.assert(!self.definition_installed);
        std.debug.assert(!self.requests_resolved);
        std.debug.assert(self.memory == pending.memory);
        std.debug.assert(self.atoms == pending.atoms);
        std.debug.assert(self.requests.len == 0);
        std.debug.assert(self.imports.len == 0);
        std.debug.assert(self.exports.len == 0);
        std.debug.assert(self.indirect_exports.len == 0);
        std.debug.assert(self.star_exports.len == 0);
        std.debug.assert(self.import_attributes.len == 0);
        std.debug.assert(self.func_obj.isUndefined());
        std.debug.assert(self.module_ns.isUndefined());
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
    fn clearForDestroy(self: *ModuleRecord, rt: anytype) void {
        const requests = self.requests;
        const imports = self.imports;
        const exports = self.exports;
        const indirect_exports = self.indirect_exports;
        const star_exports = self.star_exports;
        const import_attributes = self.import_attributes;
        const func_obj = self.func_obj;
        const module_ns = self.module_ns;
        const import_meta = self.import_meta;
        const eval_exception = self.eval_exception;

        // Detach every owned payload before releases can re-enter tracing.
        self.definition_installed = false;
        self.requests_resolved = false;
        self.status = .unlinked;
        self.requests = &.{};
        self.imports = &.{};
        self.exports = &.{};
        self.indirect_exports = &.{};
        self.star_exports = &.{};
        self.import_attributes = &.{};
        self.func_obj = value_mod.JSValue.undefinedValue();
        self.module_ns = value_mod.JSValue.undefinedValue();
        self.import_meta = null;
        self.import_meta_main = false;
        self.synthetic_kind = .none;
        self.has_top_level_await = false;
        self.resetLinkTransientNoFail();
        self.eval_exception = null;

        for (requests) |entry| self.atoms.free(entry.module_name);
        for (imports) |entry| {
            self.atoms.free(entry.import_name);
            self.atoms.free(entry.local_name);
        }
        for (exports) |*entry| {
            self.atoms.free(entry.export_name);
            self.atoms.free(entry.local_name);
            if (entry.retained_cell) |cell| {
                std.debug.assert(VarRef.fromValue(cell) != null);
                cell.free(rt);
            }
        }
        for (indirect_exports) |entry| {
            self.atoms.free(entry.export_name);
            self.atoms.free(entry.import_name);
        }
        for (import_attributes) |entry| {
            self.atoms.free(entry.key);
            self.atoms.free(entry.value);
        }
        func_obj.free(rt);
        module_ns.free(rt);
        if (import_meta) |value| value.free(rt);
        if (eval_exception) |value| value.free(rt);
        if (requests.len != 0) self.memory.free(RequestEntry, requests);
        if (imports.len != 0) self.memory.free(ImportEntry, imports);
        if (exports.len != 0) self.memory.free(ExportEntry, exports);
        if (indirect_exports.len != 0) self.memory.free(IndirectExportEntry, indirect_exports);
        if (star_exports.len != 0) self.memory.free(StarExportEntry, star_exports);
        if (import_attributes.len != 0) self.memory.free(ImportAttributeEntry, import_attributes);
    }

    pub fn destroyFromHeader(rt: anytype, header: *gc.Header) void {
        const self: *ModuleRecord = @alignCast(@fieldParentPtr("header", header));
        if (self.registry) |registry| registry.unlink(self);

        const owned_module_name = self.module_name;
        self.module_name = atom.null_atom;
        self.clearForDestroy(rt);
        self.atoms.free(owned_module_name);

        if (rt.gc.phase == .remove_cycles) {
            rt.gc.deferCycleStructFree(header);
            return;
        }
        self.memory.destroy(ModuleRecord, self);
    }

    pub fn freeCycleDeferredStruct(rt: anytype, header: *gc.Header) void {
        const self: *ModuleRecord = @alignCast(@fieldParentPtr("header", header));
        _ = rt;
        self.memory.destroy(ModuleRecord, self);
    }

    pub inline fn traceChildEdgesFallible(self: *ModuleRecord, rt: anytype, visitor: anytype) !void {
        _ = rt;
        const Helper = struct {
            inline fn callVisitValue(vis: anytype, value: *value_mod.JSValue) !void {
                const VisitorType = @TypeOf(vis);
                const CleanType = comptime if (@typeInfo(VisitorType) == .pointer) @typeInfo(VisitorType).pointer.child else VisitorType;
                if (comptime @hasDecl(CleanType, "visitValue")) {
                    const ReturnType = @typeInfo(@TypeOf(CleanType.visitValue)).@"fn".return_type.?;
                    if (comptime @typeInfo(ReturnType) == .error_union) {
                        try vis.visitValue(value);
                    } else {
                        vis.visitValue(value);
                    }
                }
            }
        };

        for (self.exports) |*entry| {
            if (entry.retained_cell) |*cell| {
                std.debug.assert(VarRef.fromValue(cell.*) != null);
                try Helper.callVisitValue(visitor, cell);
            }
        }
        try Helper.callVisitValue(visitor, &self.func_obj);
        try Helper.callVisitValue(visitor, &self.module_ns);
        if (self.import_meta) |*value| try Helper.callVisitValue(visitor, value);
        if (self.eval_exception) |*value| try Helper.callVisitValue(visitor, value);
    }

    pub inline fn traceChildEdgesNoFail(self: *ModuleRecord, rt: anytype, visitor: anytype) void {
        self.traceChildEdgesFallible(rt, visitor) catch unreachable;
    }

    pub fn setStatus(self: *ModuleRecord, status: Status) void {
        self.status = status;
    }

    /// Take ownership of `value` as the cached evaluation exception
    /// (mirrors qjs js_set_module_evaluated error path setting
    /// `m->eval_exception`, quickjs.c:31279).
    pub fn setEvalException(self: *ModuleRecord, rt: anytype, value: value_mod.JSValue) void {
        if (self.eval_exception) |old| old.free(rt);
        self.eval_exception = value;
    }

    pub fn request(self: *ModuleRecord, request_index: u32) ?*RequestEntry {
        if (@as(usize, request_index) >= self.requests.len) return null;
        return &self.requests[@intCast(request_index)];
    }

    pub fn requestConst(self: *const ModuleRecord, request_index: u32) ?*const RequestEntry {
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
        const entry = self.request(request_index) orelse unreachable;
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
    pub fn adoptFuncObjectValueNoFail(self: *ModuleRecord, next: value_mod.JSValue) void {
        std.debug.assert(self.func_obj.isUndefined());
        std.debug.assert(!next.isUndefined());
        self.func_obj = next;
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
    pub fn publishModuleNamespaceNoFail(self: *ModuleRecord, owned: value_mod.JSValue) void {
        std.debug.assert(self.module_ns.isUndefined());
        std.debug.assert(owned.isObject());
        self.module_ns = owned;
    }

    pub fn namespaceAutoInitOwner(self: *const ModuleRecord) *const module_auto_init.AutoInitModuleOwner {
        return &self.namespace_auto_init_owner;
    }

    pub fn setNamespaceAutoInitResolverNoFail(
        self: *ModuleRecord,
        resolve: @FieldType(module_auto_init.AutoInitModuleOwner, "resolve"),
    ) void {
        std.debug.assert(self.module_ns.isUndefined());
        std.debug.assert(self.namespace_auto_init_owner.resolve == unresolvedModuleAutoInit);
        self.namespace_auto_init_owner.resolve = resolve;
    }

    /// Consume one retained VarRef JSValue. The cell has exactly one owner in
    /// this export entry until it is cleared or the record is destroyed.
    pub fn publishRetainedExportCellNoFail(
        self: *ModuleRecord,
        export_index: u32,
        owned_cell: value_mod.JSValue,
    ) void {
        const entry = &self.exports[@intCast(export_index)];
        std.debug.assert(entry.retained_cell == null);
        std.debug.assert(VarRef.fromValue(owned_cell) != null);
        entry.retained_cell = owned_cell;
    }

    /// Borrow a retained local-export cell.
    pub fn retainedExportCellValue(self: *const ModuleRecord, export_index: u32) ?value_mod.JSValue {
        const cell = self.exports[@intCast(export_index)].retained_cell;
        if (cell) |value| std.debug.assert(VarRef.fromValue(value) != null);
        return cell;
    }

    pub fn clearRetainedExportCellNoFail(self: *ModuleRecord, rt: anytype, export_index: u32) void {
        const entry = &self.exports[@intCast(export_index)];
        const owned = entry.retained_cell orelse return;
        std.debug.assert(VarRef.fromValue(owned) != null);
        entry.retained_cell = null;
        owned.free(rt);
    }

    pub fn resetLinkTransientNoFail(self: *ModuleRecord) void {
        self.link_dfs_index = 0;
        self.link_dfs_ancestor_index = 0;
        self.link_stack_prev = null;
    }
};

pub const Registry = struct {
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,
    gc_registry: *gc.Registry,
    head: ?*ModuleRecord = null,
    tail: ?*ModuleRecord = null,
    count: usize = 0,

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

    pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable, gc_registry: *gc.Registry) Registry {
        return .{
            .memory = account,
            .atoms = atoms,
            .gc_registry = gc_registry,
        };
    }

    pub fn deinit(self: *Registry, rt: anytype) void {
        while (self.head) |record| {
            // Membership borrows the pointer but owns the record's initial
            // reference. Splice first so a zero-ref finalizer cannot unlink it
            // twice, then release that list base-reference.
            self.unlink(record);
            record.release(rt);
        }
        std.debug.assert(self.tail == null);
        std.debug.assert(self.count == 0);
    }

    pub fn iterator(self: *const Registry) Iterator {
        return .{ .cursor = self.head };
    }

    pub inline fn traceChildEdgesFallible(self: *Registry, visitor: anytype) !void {
        const Helper = struct {
            inline fn callVisitModule(vis: anytype, record: *ModuleRecord) !void {
                const VisitorType = @TypeOf(vis);
                const CleanType = comptime if (@typeInfo(VisitorType) == .pointer) @typeInfo(VisitorType).pointer.child else VisitorType;
                if (comptime @hasDecl(CleanType, "visitModule")) {
                    const ReturnType = @typeInfo(@TypeOf(CleanType.visitModule)).@"fn".return_type.?;
                    if (comptime @typeInfo(ReturnType) == .error_union) {
                        try vis.visitModule(record);
                    } else {
                        vis.visitModule(record);
                    }
                }
            }
        };

        var iter = self.iterator();
        while (iter.next()) |record| try Helper.callVisitModule(visitor, record);
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
        self.count += 1;
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
        std.debug.assert(self.count != 0);
        self.count -= 1;
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
        std.debug.assert(pending.memory == self.memory);
        std.debug.assert(pending.atoms == self.atoms);

        if (self.find(name)) |record| {
            std.debug.assert(record.definition_installed);
            return .{ .existing = record };
        }

        const record = try self.memory.create(ModuleRecord);
        record.prepare(self.memory, self.atoms, name);
        record.replaceDefinitionNoFail(pending);
        self.gc_registry.addInitializedWithSizeNoFail(&record.header, @sizeOf(ModuleRecord));
        self.link(record);
        return .{ .fresh = record };
    }

    pub fn find(self: *const Registry, name: atom.Atom) ?*ModuleRecord {
        var iter = self.iterator();
        while (iter.next()) |record| {
            if (record.module_name == name) return record;
        }
        return null;
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
        var visiting = std.ArrayList(ResolutionVisit).empty;
        defer visiting.deinit(self.memory.allocator);
        return self.resolveExportFromRecord(record, export_name, &visiting);
    }

    fn resolveExportFromRecord(
        self: *Registry,
        record: *ModuleRecord,
        export_name: atom.Atom,
        visiting: *std.ArrayList(ResolutionVisit),
    ) !ResolvedExport {
        std.debug.assert(record.registry == self);

        for (visiting.items) |entry| {
            if (entry.module == record and entry.export_name == export_name) return .not_found;
        }
        try visiting.append(self.memory.allocator, .{ .module = record, .export_name = export_name });
        defer _ = visiting.pop().?;

        for (record.exports, 0..) |entry, index| {
            if (entry.export_name == export_name) {
                for (record.imports) |import_entry| {
                    if (import_entry.local_name != entry.local_name) continue;
                    const dependency = try requestDependency(record, import_entry.request_index);
                    if (!import_entry.is_namespace) {
                        return self.resolveExportFromRecord(
                            dependency,
                            import_entry.import_name,
                            visiting,
                        );
                    }
                    break;
                }
                return .{ .resolved = .{
                    .module = record,
                    .entry = .{ .local_export = @intCast(index) },
                } };
            }
        }

        for (record.indirect_exports, 0..) |entry, index| {
            if (entry.export_name != export_name) continue;
            if (entry.is_namespace) {
                _ = try requestDependency(record, entry.request_index);
                return .{ .resolved = .{
                    .module = record,
                    .entry = .{ .namespace_export = @intCast(index) },
                } };
            }
            const dependency = try requestDependency(record, entry.request_index);
            return self.resolveExportFromRecord(dependency, entry.import_name, visiting);
        }

        if (export_name == atom_default) return .not_found;

        var found: ?ResolvedBinding = null;
        for (record.star_exports) |entry| {
            const dependency = try requestDependency(record, entry.request_index);
            const dep_resolution = try self.resolveExportFromRecord(dependency, export_name, visiting);
            switch (dep_resolution) {
                .not_found => {},
                .ambiguous => return .ambiguous,
                .resolved => |binding| {
                    if (found) |existing| {
                        if (!existing.sameIdentity(binding)) return .ambiguous;
                    } else {
                        found = binding;
                    }
                },
            }
        }
        if (found) |binding| return .{ .resolved = binding };
        return .not_found;
    }
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

fn append(account: *memory.MemoryAccount, comptime T: type, slice: *[]T, item: T) !void {
    const next = try account.alloc(T, slice.*.len + 1);
    errdefer account.free(T, next);
    @memcpy(next[0..slice.*.len], slice.*);
    next[slice.*.len] = item;
    const old = slice.*;
    slice.* = next;
    if (old.len != 0) account.free(T, old);
}

const std = @import("std");

const atom = @import("atom.zig");
const gc = @import("gc.zig");
const memory = @import("memory.zig");
const value_mod = @import("value.zig");

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

pub const ImportEntry = struct {
    module_name: atom.Atom,
    import_name: atom.Atom,
    local_name: atom.Atom,
};

pub const ExportEntry = struct {
    export_name: atom.Atom,
    local_name: atom.Atom,
};

pub const IndirectExportEntry = struct {
    module_name: atom.Atom,
    export_name: atom.Atom,
    import_name: atom.Atom,
};

pub const StarExportEntry = struct {
    module_name: atom.Atom,
    export_name: atom.Atom,
};

pub const ImportAttributeEntry = struct {
    module_name: atom.Atom,
    key: atom.Atom,
    value: atom.Atom,
};

pub const ResolvedBinding = struct {
    /// Both Atoms are borrowed. Resolution results never retain a raw
    /// ModuleRecord pointer; callers re-resolve `module_name` in their realm's
    /// registry.
    module_name: atom.Atom,
    local_name: atom.Atom,
};

pub const ResolvedImportEntry = struct {
    /// All three atoms are owned by the persistent entry.
    local_name: atom.Atom,
    module_name: atom.Atom,
    binding_name: atom.Atom,
};

pub const LocalBinding = struct {
    name: atom.Atom,
    initialized: bool = false,
    cell: value_mod.JSValue = value_mod.JSValue.undefinedValue(),
};

pub const ResolvedExport = union(enum) {
    not_found,
    ambiguous,
    resolved: ResolvedBinding,
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
    status: Status = .unlinked,
    requested_modules: []atom.Atom = &.{},
    imports: []ImportEntry = &.{},
    exports: []ExportEntry = &.{},
    indirect_exports: []IndirectExportEntry = &.{},
    star_exports: []StarExportEntry = &.{},
    import_attributes: []ImportAttributeEntry = &.{},
    resolved_imports: []ResolvedImportEntry = &.{},
    local_bindings: []LocalBinding = &.{},
    import_meta: ?value_mod.JSValue = null,
    import_meta_main: bool = false,
    synthetic_kind: SyntheticKind = .none,
    has_top_level_await: bool = false,
    /// The module function's `this === true` entry has executed its guarded
    /// declaration-instantiation branch. Later evaluation invokes the body
    /// branch of compiled bytecode, so cyclic importers and the module body
    /// observe the same installed function identity (QuickJS
    /// js_inner_module_linking calling the module function).
    function_declarations_initialized: bool = false,
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

    /// Reset all mutable module payload while preserving the stable allocation,
    /// GC identity, list membership, and owned module-name Atom.
    fn reset(self: *ModuleRecord, rt: anytype) void {
        const requested_modules = self.requested_modules;
        const imports = self.imports;
        const exports = self.exports;
        const indirect_exports = self.indirect_exports;
        const star_exports = self.star_exports;
        const import_attributes = self.import_attributes;
        const resolved_imports = self.resolved_imports;
        const local_bindings = self.local_bindings;
        const import_meta = self.import_meta;
        const eval_exception = self.eval_exception;

        // Detach every owned payload before releases can re-enter tracing.
        self.status = .unlinked;
        self.requested_modules = &.{};
        self.imports = &.{};
        self.exports = &.{};
        self.indirect_exports = &.{};
        self.star_exports = &.{};
        self.import_attributes = &.{};
        self.resolved_imports = &.{};
        self.local_bindings = &.{};
        self.import_meta = null;
        self.import_meta_main = false;
        self.synthetic_kind = .none;
        self.has_top_level_await = false;
        self.function_declarations_initialized = false;
        self.eval_exception = null;

        for (requested_modules) |requested| self.atoms.free(requested);
        for (imports) |entry| {
            self.atoms.free(entry.module_name);
            self.atoms.free(entry.import_name);
            self.atoms.free(entry.local_name);
        }
        for (exports) |entry| {
            self.atoms.free(entry.export_name);
            self.atoms.free(entry.local_name);
        }
        for (indirect_exports) |entry| {
            self.atoms.free(entry.module_name);
            self.atoms.free(entry.export_name);
            self.atoms.free(entry.import_name);
        }
        for (star_exports) |entry| {
            self.atoms.free(entry.module_name);
            self.atoms.free(entry.export_name);
        }
        for (import_attributes) |entry| {
            self.atoms.free(entry.module_name);
            self.atoms.free(entry.key);
            self.atoms.free(entry.value);
        }
        for (resolved_imports) |entry| {
            self.atoms.free(entry.local_name);
            self.atoms.free(entry.module_name);
            self.atoms.free(entry.binding_name);
        }
        for (local_bindings) |*entry| {
            const cell = entry.cell;
            entry.cell = value_mod.JSValue.undefinedValue();
            self.atoms.free(entry.name);
            cell.free(rt);
        }
        if (import_meta) |value| value.free(rt);
        if (eval_exception) |value| value.free(rt);
        if (requested_modules.len != 0) self.memory.free(atom.Atom, requested_modules);
        if (imports.len != 0) self.memory.free(ImportEntry, imports);
        if (exports.len != 0) self.memory.free(ExportEntry, exports);
        if (indirect_exports.len != 0) self.memory.free(IndirectExportEntry, indirect_exports);
        if (star_exports.len != 0) self.memory.free(StarExportEntry, star_exports);
        if (import_attributes.len != 0) self.memory.free(ImportAttributeEntry, import_attributes);
        if (resolved_imports.len != 0) self.memory.free(ResolvedImportEntry, resolved_imports);
        if (local_bindings.len != 0) self.memory.free(LocalBinding, local_bindings);
    }

    pub fn destroyFromHeader(rt: anytype, header: *gc.Header) void {
        const self: *ModuleRecord = @alignCast(@fieldParentPtr("header", header));
        if (self.registry) |registry| registry.unlink(self);

        const owned_module_name = self.module_name;
        self.module_name = atom.null_atom;
        self.reset(rt);
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

        for (self.local_bindings) |*binding| try Helper.callVisitValue(visitor, &binding.cell);
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

    pub fn addRequestedModule(self: *ModuleRecord, name: atom.Atom) !void {
        const owned_name = self.atoms.dup(name);
        errdefer self.atoms.free(owned_name);
        try append(self.memory, atom.Atom, &self.requested_modules, owned_name);
    }

    pub fn addImport(self: *ModuleRecord, module_name: atom.Atom, import_name: atom.Atom, local_name: atom.Atom) !void {
        const owned_module_name = self.atoms.dup(module_name);
        errdefer self.atoms.free(owned_module_name);
        const owned_import_name = self.atoms.dup(import_name);
        errdefer self.atoms.free(owned_import_name);
        const owned_local_name = self.atoms.dup(local_name);
        errdefer self.atoms.free(owned_local_name);
        try append(self.memory, ImportEntry, &self.imports, .{
            .module_name = owned_module_name,
            .import_name = owned_import_name,
            .local_name = owned_local_name,
        });
    }

    pub fn addExport(self: *ModuleRecord, export_name: atom.Atom, local_name: atom.Atom) !void {
        const owned_export_name = self.atoms.dup(export_name);
        errdefer self.atoms.free(owned_export_name);
        const owned_local_name = self.atoms.dup(local_name);
        errdefer self.atoms.free(owned_local_name);
        try append(self.memory, ExportEntry, &self.exports, .{
            .export_name = owned_export_name,
            .local_name = owned_local_name,
        });
    }

    pub fn addIndirectExport(self: *ModuleRecord, module_name: atom.Atom, export_name: atom.Atom, import_name: atom.Atom) !void {
        const owned_module_name = self.atoms.dup(module_name);
        errdefer self.atoms.free(owned_module_name);
        const owned_export_name = self.atoms.dup(export_name);
        errdefer self.atoms.free(owned_export_name);
        const owned_import_name = self.atoms.dup(import_name);
        errdefer self.atoms.free(owned_import_name);
        try append(self.memory, IndirectExportEntry, &self.indirect_exports, .{
            .module_name = owned_module_name,
            .export_name = owned_export_name,
            .import_name = owned_import_name,
        });
    }

    pub fn addStarExport(self: *ModuleRecord, module_name: atom.Atom, export_name: atom.Atom) !void {
        const owned_module_name = self.atoms.dup(module_name);
        errdefer self.atoms.free(owned_module_name);
        const owned_export_name = self.atoms.dup(export_name);
        errdefer self.atoms.free(owned_export_name);
        try append(self.memory, StarExportEntry, &self.star_exports, .{
            .module_name = owned_module_name,
            .export_name = owned_export_name,
        });
    }

    pub fn addImportAttribute(self: *ModuleRecord, module_name: atom.Atom, key: atom.Atom, value: atom.Atom) !void {
        const owned_module_name = self.atoms.dup(module_name);
        errdefer self.atoms.free(owned_module_name);
        const owned_key = self.atoms.dup(key);
        errdefer self.atoms.free(owned_key);
        const owned_value = self.atoms.dup(value);
        errdefer self.atoms.free(owned_value);
        try append(self.memory, ImportAttributeEntry, &self.import_attributes, .{
            .module_name = owned_module_name,
            .key = owned_key,
            .value = owned_value,
        });
    }

    fn clearResolvedImports(self: *ModuleRecord) void {
        const resolved_imports = self.resolved_imports;
        self.resolved_imports = &.{};
        for (resolved_imports) |entry| {
            self.atoms.free(entry.local_name);
            self.atoms.free(entry.module_name);
            self.atoms.free(entry.binding_name);
        }
        if (resolved_imports.len != 0) self.memory.free(ResolvedImportEntry, resolved_imports);
    }

    fn clearLocalBindings(self: *ModuleRecord, rt: anytype) void {
        const local_bindings = self.local_bindings;
        self.local_bindings = &.{};
        for (local_bindings) |*entry| {
            const cell = entry.cell;
            entry.cell = value_mod.JSValue.undefinedValue();
            self.atoms.free(entry.name);
            cell.free(rt);
        }
        if (local_bindings.len != 0) self.memory.free(LocalBinding, local_bindings);
    }

    fn clearLinkArtifacts(self: *ModuleRecord, rt: anytype) void {
        self.clearResolvedImports();
        self.clearLocalBindings(rt);
        self.function_declarations_initialized = false;
    }

    fn addResolvedImport(self: *ModuleRecord, local_name: atom.Atom, binding: ResolvedBinding) !void {
        const owned_local_name = self.atoms.dup(local_name);
        errdefer self.atoms.free(owned_local_name);
        const owned_module_name = self.atoms.dup(binding.module_name);
        errdefer self.atoms.free(owned_module_name);
        const owned_binding_name = self.atoms.dup(binding.local_name);
        errdefer self.atoms.free(owned_binding_name);
        try append(self.memory, ResolvedImportEntry, &self.resolved_imports, .{
            .local_name = owned_local_name,
            .module_name = owned_module_name,
            .binding_name = owned_binding_name,
        });
    }

    pub fn ensureLocalBinding(self: *ModuleRecord, name: atom.Atom) !void {
        if (self.findLocalBindingIndex(name) != null) return;
        const owned_name = self.atoms.dup(name);
        errdefer self.atoms.free(owned_name);
        try append(self.memory, LocalBinding, &self.local_bindings, .{
            .name = owned_name,
        });
    }

    pub fn markLocalBindingInitialized(self: *ModuleRecord, name: atom.Atom) !void {
        const index = self.findLocalBindingIndex(name) orelse return error.MissingExport;
        self.local_bindings[index].initialized = true;
    }

    pub fn findLocalBindingIndex(self: *const ModuleRecord, name: atom.Atom) ?usize {
        for (self.local_bindings, 0..) |entry, index| {
            if (entry.name == name) return index;
        }
        return null;
    }
};

/// Failed export resolution details captured during linking so callers can
/// build qjs-shaped SyntaxError messages (mirrors
/// js_resolve_export_throw_error quickjs.c:30232, which formats the export
/// and module names at the point of failure).
pub const LinkErrorInfo = struct {
    kind: enum { missing_export, ambiguous_export },
    module_name: atom.Atom,
    export_name: atom.Atom,
};

pub const Registry = struct {
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,
    gc_registry: *gc.Registry,
    head: ?*ModuleRecord = null,
    tail: ?*ModuleRecord = null,
    count: usize = 0,
    link_error: ?LinkErrorInfo = null,

    pub const Iterator = struct {
        cursor: ?*ModuleRecord,

        pub fn next(self: *Iterator) ?*ModuleRecord {
            const current = self.cursor orelse return null;
            self.cursor = current.registry_next;
            return current;
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
        self.clearLinkError();
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

    pub fn clearLinkError(self: *Registry) void {
        const info = self.link_error orelse return;
        self.link_error = null;
        self.atoms.free(info.module_name);
        self.atoms.free(info.export_name);
    }

    fn recordLinkError(self: *Registry, kind: @FieldType(LinkErrorInfo, "kind"), module_name: atom.Atom, export_name: atom.Atom) void {
        self.clearLinkError();
        self.link_error = .{
            .kind = kind,
            .module_name = self.atoms.dup(module_name),
            .export_name = self.atoms.dup(export_name),
        };
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

    pub fn create(self: *Registry, name: atom.Atom) !*ModuleRecord {
        // Allocation is the only fallible step. The record is fully prepared
        // off-list; GC publication and registry linkage are then no-fail, so an
        // OOM cannot perturb the previously published list.
        const record = try self.memory.create(ModuleRecord);
        record.prepare(self.memory, self.atoms, name);
        self.gc_registry.addInitializedWithSizeNoFail(&record.header, @sizeOf(ModuleRecord));
        self.link(record);
        return record;
    }

    pub fn createFresh(self: *Registry, rt: anytype, name: atom.Atom) !*ModuleRecord {
        if (self.find(name)) |record| {
            // Stable identity is observable by non-escaping linking/evaluation
            // work. Keep the allocation, header, list links, registry borrow,
            // and module-name owner; only reset mutable payload.
            record.reset(rt);
            return record;
        }
        return self.create(name);
    }

    pub fn find(self: *const Registry, name: atom.Atom) ?*ModuleRecord {
        var iter = self.iterator();
        while (iter.next()) |record| {
            if (record.module_name == name) return record;
        }
        return null;
    }

    pub fn resolveExport(self: *Registry, module_name: atom.Atom, export_name: atom.Atom) !ResolvedExport {
        if (self.find(module_name) == null) return .not_found;
        var visiting = std.ArrayList(ResolutionVisit).empty;
        defer visiting.deinit(self.memory.allocator);
        return try self.resolveExportByName(module_name, export_name, &visiting);
    }

    fn resolveExportByName(self: *Registry, module_name: atom.Atom, export_name: atom.Atom, visiting: *std.ArrayList(ResolutionVisit)) !ResolvedExport {
        for (visiting.items) |entry| {
            if (entry.module_name == module_name and entry.export_name == export_name) return .not_found;
        }
        try visiting.append(self.memory.allocator, .{ .module_name = module_name, .export_name = export_name });
        defer _ = visiting.pop().?;

        const record = self.find(module_name) orelse return .not_found;
        for (record.exports) |entry| {
            if (entry.export_name == export_name) {
                if (self.resolvedImportBinding(record, entry.local_name)) |binding| return .{ .resolved = binding };
                return .{ .resolved = .{ .module_name = record.module_name, .local_name = entry.local_name } };
            }
        }

        for (record.indirect_exports) |entry| {
            if (entry.export_name != export_name) continue;
            if (self.find(entry.module_name) == null) return .not_found;
            return try self.resolveExportByName(entry.module_name, entry.import_name, visiting);
        }

        var found: ?ResolvedBinding = null;
        for (record.star_exports) |entry| {
            if (entry.export_name != atom_star) {
                if (entry.export_name != export_name) continue;
                const dependency = self.find(entry.module_name) orelse return .not_found;
                return .{ .resolved = .{ .module_name = dependency.module_name, .local_name = atom_star } };
            }
            if (export_name == atom_default) continue;
            if (self.find(entry.module_name) == null) continue;
            const dep_resolution = try self.resolveExportByName(entry.module_name, export_name, visiting);
            switch (dep_resolution) {
                .not_found => {},
                .ambiguous => return .ambiguous,
                .resolved => |binding| {
                    if (found) |existing| {
                        if (existing.module_name != binding.module_name or existing.local_name != binding.local_name) return .ambiguous;
                    } else {
                        found = binding;
                    }
                },
            }
        }
        if (found) |binding| return .{ .resolved = binding };
        return .not_found;
    }

    fn resolvedImportBinding(self: *const Registry, record: *const ModuleRecord, local_name: atom.Atom) ?ResolvedBinding {
        _ = self;
        for (record.resolved_imports) |entry| {
            if (entry.local_name != local_name) continue;
            return .{ .module_name = entry.module_name, .local_name = entry.binding_name };
        }
        return null;
    }

    pub fn linkModule(self: *Registry, rt: anytype, module_name: atom.Atom) !void {
        if (self.find(module_name) == null) return error.ModuleNotFound;
        try self.linkModuleByName(rt, module_name);
    }

    fn linkModuleByName(self: *Registry, rt: anytype, module_name: atom.Atom) !void {
        const record = self.find(module_name) orelse return error.ModuleNotFound;
        switch (record.status) {
            .linked, .evaluating, .evaluated => return,
            .linking => return,
            .errored => return error.ModuleLinkFailed,
            .unlinked => {},
        }

        record.status = .linking;
        record.clearLinkArtifacts(rt);
        errdefer {
            record.clearLinkArtifacts(rt);
            record.status = .errored;
        }

        var requested_index: usize = 0;
        while (requested_index < record.requested_modules.len) : (requested_index += 1) {
            const dep_name = record.requested_modules[requested_index];
            if (self.find(dep_name) == null) return error.ModuleNotFound;
            try self.linkModuleByName(rt, dep_name);
        }

        var import_index: usize = 0;
        while (import_index < record.imports.len) : (import_index += 1) {
            const entry = record.imports[import_index];
            const binding = if (entry.import_name == atom_star) blk: {
                const dependency = self.find(entry.module_name) orelse return error.ModuleNotFound;
                break :blk ResolvedBinding{ .module_name = dependency.module_name, .local_name = atom_star };
            } else try self.expectResolvedExport(entry.module_name, entry.import_name);
            try record.addResolvedImport(entry.local_name, binding);
        }

        var export_index: usize = 0;
        while (export_index < record.exports.len) : (export_index += 1) {
            const entry = record.exports[export_index];
            try record.ensureLocalBinding(entry.local_name);
        }

        var indirect_index: usize = 0;
        while (indirect_index < record.indirect_exports.len) : (indirect_index += 1) {
            const entry = record.indirect_exports[indirect_index];
            _ = try self.expectResolvedExport(entry.module_name, entry.import_name);
        }

        record.status = .linked;
    }

    fn expectResolvedExport(self: *Registry, module_name: atom.Atom, export_name: atom.Atom) !ResolvedBinding {
        const resolution = try self.resolveExport(module_name, export_name);
        return switch (resolution) {
            .resolved => |binding| binding,
            .not_found => {
                self.recordLinkError(.missing_export, module_name, export_name);
                return error.MissingExport;
            },
            .ambiguous => {
                self.recordLinkError(.ambiguous_export, module_name, export_name);
                return error.AmbiguousExport;
            },
        };
    }
};

const ResolutionVisit = struct {
    /// Both atoms are borrowed for the duration of one resolution traversal.
    module_name: atom.Atom,
    export_name: atom.Atom,
};

fn append(account: *memory.MemoryAccount, comptime T: type, slice: *[]T, item: T) !void {
    const next = try account.alloc(T, slice.*.len + 1);
    errdefer account.free(T, next);
    @memcpy(next[0..slice.*.len], slice.*);
    next[slice.*.len] = item;
    const old = slice.*;
    slice.* = next;
    if (old.len != 0) account.free(T, old);
}

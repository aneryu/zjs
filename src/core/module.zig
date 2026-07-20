const std = @import("std");

const atom = @import("atom.zig");
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
    module_index: usize,
    local_name: atom.Atom,
};

pub const ResolvedImportEntry = struct {
    local_name: atom.Atom,
    module_index: usize,
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

    pub fn create(account: *memory.MemoryAccount, atoms: *atom.AtomTable, name: atom.Atom) ModuleRecord {
        return .{
            .memory = account,
            .atoms = atoms,
            .module_name = atoms.dup(name),
        };
    }

    pub fn destroy(self: *ModuleRecord, rt: anytype) void {
        const account = self.memory;
        const atoms = self.atoms;
        const module_name = self.module_name;
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
        self.* = .{
            .memory = account,
            .atoms = atoms,
            .module_name = atom.null_atom,
        };

        atoms.free(module_name);
        for (requested_modules) |requested| atoms.free(requested);
        for (imports) |entry| {
            atoms.free(entry.module_name);
            atoms.free(entry.import_name);
            atoms.free(entry.local_name);
        }
        for (exports) |entry| {
            atoms.free(entry.export_name);
            atoms.free(entry.local_name);
        }
        for (indirect_exports) |entry| {
            atoms.free(entry.module_name);
            atoms.free(entry.export_name);
            atoms.free(entry.import_name);
        }
        for (star_exports) |entry| {
            atoms.free(entry.module_name);
            atoms.free(entry.export_name);
        }
        for (import_attributes) |entry| {
            atoms.free(entry.module_name);
            atoms.free(entry.key);
            atoms.free(entry.value);
        }
        for (resolved_imports) |entry| {
            atoms.free(entry.local_name);
            atoms.free(entry.binding_name);
        }
        for (local_bindings) |*entry| {
            const cell = entry.cell;
            entry.cell = value_mod.JSValue.undefinedValue();
            atoms.free(entry.name);
            cell.free(rt);
        }
        if (import_meta) |value| value.free(rt);
        if (eval_exception) |value| value.free(rt);
        if (requested_modules.len != 0) account.free(atom.Atom, requested_modules);
        if (imports.len != 0) account.free(ImportEntry, imports);
        if (exports.len != 0) account.free(ExportEntry, exports);
        if (indirect_exports.len != 0) account.free(IndirectExportEntry, indirect_exports);
        if (star_exports.len != 0) account.free(StarExportEntry, star_exports);
        if (import_attributes.len != 0) account.free(ImportAttributeEntry, import_attributes);
        if (resolved_imports.len != 0) account.free(ResolvedImportEntry, resolved_imports);
        if (local_bindings.len != 0) account.free(LocalBinding, local_bindings);
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
        const owned_binding_name = self.atoms.dup(binding.local_name);
        errdefer self.atoms.free(owned_binding_name);
        try append(self.memory, ResolvedImportEntry, &self.resolved_imports, .{
            .local_name = owned_local_name,
            .module_index = binding.module_index,
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
    modules: []ModuleRecord = &.{},
    link_error: ?LinkErrorInfo = null,

    pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable) Registry {
        return .{ .memory = account, .atoms = atoms };
    }

    pub fn deinit(self: *Registry, rt: anytype) void {
        self.clearLinkError();
        const modules = self.modules;
        self.modules = &.{};
        for (modules) |*record| record.destroy(rt);
        if (modules.len != 0) self.memory.free(ModuleRecord, modules);
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

    pub fn create(self: *Registry, name: atom.Atom) !*ModuleRecord {
        const old_modules = self.modules;
        const next = try self.memory.alloc(ModuleRecord, self.modules.len + 1);
        errdefer self.memory.free(ModuleRecord, next);
        @memcpy(next[0..old_modules.len], old_modules);
        next[old_modules.len] = ModuleRecord.create(self.memory, self.atoms, name);
        self.modules = next;
        if (old_modules.len != 0) self.memory.free(ModuleRecord, old_modules);
        return &self.modules[self.modules.len - 1];
    }

    pub fn createFresh(self: *Registry, rt: anytype, name: atom.Atom) !*ModuleRecord {
        if (self.findIndex(name)) |index| {
            var old_record = self.modules[index];
            self.modules[index] = ModuleRecord.create(self.memory, self.atoms, name);
            old_record.destroy(rt);
            return &self.modules[index];
        }
        return self.create(name);
    }

    pub fn findIndex(self: Registry, name: atom.Atom) ?usize {
        for (self.modules, 0..) |record, index| {
            if (record.module_name == name) return index;
        }
        return null;
    }

    pub fn find(self: *Registry, name: atom.Atom) ?*ModuleRecord {
        const index = self.findIndex(name) orelse return null;
        return &self.modules[index];
    }

    pub fn resolveExport(self: *Registry, module_name: atom.Atom, export_name: atom.Atom) !ResolvedExport {
        const module_index = self.findIndex(module_name) orelse return .not_found;
        var visiting = std.ArrayList(ResolutionVisit).empty;
        defer visiting.deinit(self.memory.allocator);
        return try self.resolveExportByIndex(module_index, export_name, &visiting);
    }

    fn resolveExportByIndex(self: *Registry, module_index: usize, export_name: atom.Atom, visiting: *std.ArrayList(ResolutionVisit)) !ResolvedExport {
        for (visiting.items) |entry| {
            if (entry.module_index == module_index and entry.export_name == export_name) return .not_found;
        }
        try visiting.append(self.memory.allocator, .{ .module_index = module_index, .export_name = export_name });
        defer _ = visiting.pop().?;

        const record = &self.modules[module_index];
        for (record.exports) |entry| {
            if (entry.export_name == export_name) {
                if (self.resolvedImportBinding(record, entry.local_name)) |binding| return .{ .resolved = binding };
                return .{ .resolved = .{ .module_index = module_index, .local_name = entry.local_name } };
            }
        }

        for (record.indirect_exports) |entry| {
            if (entry.export_name != export_name) continue;
            const dep_index = self.findIndex(entry.module_name) orelse return .not_found;
            return try self.resolveExportByIndex(dep_index, entry.import_name, visiting);
        }

        var found: ?ResolvedBinding = null;
        for (record.star_exports) |entry| {
            if (entry.export_name != atom_star) {
                if (entry.export_name != export_name) continue;
                const dep_index = self.findIndex(entry.module_name) orelse return .not_found;
                return .{ .resolved = .{ .module_index = dep_index, .local_name = atom_star } };
            }
            if (export_name == atom_default) continue;
            const dep_index = self.findIndex(entry.module_name) orelse continue;
            const dep_resolution = try self.resolveExportByIndex(dep_index, export_name, visiting);
            switch (dep_resolution) {
                .not_found => {},
                .ambiguous => return .ambiguous,
                .resolved => |binding| {
                    if (found) |existing| {
                        if (existing.module_index != binding.module_index or existing.local_name != binding.local_name) return .ambiguous;
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
            return .{ .module_index = entry.module_index, .local_name = entry.binding_name };
        }
        return null;
    }

    pub fn linkModule(self: *Registry, rt: anytype, module_name: atom.Atom) !void {
        const module_index = self.findIndex(module_name) orelse return error.ModuleNotFound;
        try self.linkModuleByIndex(rt, module_index);
    }

    fn linkModuleByIndex(self: *Registry, rt: anytype, module_index: usize) !void {
        switch (self.modules[module_index].status) {
            .linked, .evaluating, .evaluated => return,
            .linking => return,
            .errored => return error.ModuleLinkFailed,
            .unlinked => {},
        }

        self.modules[module_index].status = .linking;
        self.modules[module_index].clearLinkArtifacts(rt);
        errdefer {
            self.modules[module_index].clearLinkArtifacts(rt);
            self.modules[module_index].status = .errored;
        }

        var requested_index: usize = 0;
        while (requested_index < self.modules[module_index].requested_modules.len) : (requested_index += 1) {
            const dep_name = self.modules[module_index].requested_modules[requested_index];
            const dep_index = self.findIndex(dep_name) orelse return error.ModuleNotFound;
            try self.linkModuleByIndex(rt, dep_index);
        }

        var import_index: usize = 0;
        while (import_index < self.modules[module_index].imports.len) : (import_index += 1) {
            const entry = self.modules[module_index].imports[import_index];
            const binding = if (entry.import_name == atom_star) blk: {
                const dep_index = self.findIndex(entry.module_name) orelse return error.ModuleNotFound;
                break :blk ResolvedBinding{ .module_index = dep_index, .local_name = atom_star };
            } else try self.expectResolvedExport(entry.module_name, entry.import_name);
            try self.modules[module_index].addResolvedImport(entry.local_name, binding);
        }

        var export_index: usize = 0;
        while (export_index < self.modules[module_index].exports.len) : (export_index += 1) {
            const entry = self.modules[module_index].exports[export_index];
            try self.modules[module_index].ensureLocalBinding(entry.local_name);
        }

        var indirect_index: usize = 0;
        while (indirect_index < self.modules[module_index].indirect_exports.len) : (indirect_index += 1) {
            const entry = self.modules[module_index].indirect_exports[indirect_index];
            _ = try self.expectResolvedExport(entry.module_name, entry.import_name);
        }

        self.modules[module_index].status = .linked;
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
    module_index: usize,
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

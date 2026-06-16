const atom = @import("../core/atom.zig");
const memory = @import("../core/memory.zig");

pub const Request = struct {
    module_name: atom.Atom,
};

pub const Import = struct {
    request_index: u32,
    import_name: atom.Atom,
    local_name: atom.Atom,
};

pub const Export = struct {
    export_name: atom.Atom,
    local_name: atom.Atom,
};

pub const IndirectExport = struct {
    request_index: u32,
    export_name: atom.Atom,
    import_name: atom.Atom,
};

pub const StarExport = struct {
    request_index: u32,
    export_name: atom.Atom,
};

pub const ImportAttribute = struct {
    request_index: u32,
    key: atom.Atom,
    value: atom.Atom,
};

pub const Record = struct {
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,
    requests: []Request = &.{},
    imports: []Import = &.{},
    exports: []Export = &.{},
    indirect_exports: []IndirectExport = &.{},
    star_exports: []StarExport = &.{},
    import_attributes: []ImportAttribute = &.{},
    has_top_level_await: bool = false,

    pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable) Record {
        return .{ .memory = account, .atoms = atoms };
    }

    pub fn deinit(self: *Record) void {
        const requests = self.requests;
        const imports = self.imports;
        const exports = self.exports;
        const indirect_exports = self.indirect_exports;
        const star_exports = self.star_exports;
        const import_attributes = self.import_attributes;
        self.requests = &.{};
        self.imports = &.{};
        self.exports = &.{};
        self.indirect_exports = &.{};
        self.star_exports = &.{};
        self.import_attributes = &.{};
        self.has_top_level_await = false;

        for (requests) |request| self.atoms.free(request.module_name);
        for (imports) |entry| {
            self.atoms.free(entry.import_name);
            self.atoms.free(entry.local_name);
        }
        for (exports) |entry| {
            self.atoms.free(entry.export_name);
            self.atoms.free(entry.local_name);
        }
        for (indirect_exports) |entry| {
            self.atoms.free(entry.export_name);
            self.atoms.free(entry.import_name);
        }
        for (star_exports) |entry| self.atoms.free(entry.export_name);
        for (import_attributes) |entry| {
            self.atoms.free(entry.key);
            self.atoms.free(entry.value);
        }
        if (requests.len != 0) self.memory.free(Request, requests);
        if (imports.len != 0) self.memory.free(Import, imports);
        if (exports.len != 0) self.memory.free(Export, exports);
        if (indirect_exports.len != 0) self.memory.free(IndirectExport, indirect_exports);
        if (star_exports.len != 0) self.memory.free(StarExport, star_exports);
        if (import_attributes.len != 0) self.memory.free(ImportAttribute, import_attributes);
    }

    pub fn addRequest(self: *Record, module_name: atom.Atom) !u32 {
        const index = self.requests.len;
        const owned_module_name = self.atoms.dup(module_name);
        errdefer self.atoms.free(owned_module_name);
        try append(self.memory, Request, &self.requests, .{ .module_name = owned_module_name });
        return @intCast(index);
    }

    pub fn addImport(self: *Record, request_index: u32, import_name: atom.Atom, local_name: atom.Atom) !void {
        const owned_import_name = self.atoms.dup(import_name);
        errdefer self.atoms.free(owned_import_name);
        const owned_local_name = self.atoms.dup(local_name);
        errdefer self.atoms.free(owned_local_name);
        try append(self.memory, Import, &self.imports, .{
            .request_index = request_index,
            .import_name = owned_import_name,
            .local_name = owned_local_name,
        });
    }

    pub fn addExport(self: *Record, export_name: atom.Atom, local_name: atom.Atom) !void {
        const owned_export_name = self.atoms.dup(export_name);
        errdefer self.atoms.free(owned_export_name);
        const owned_local_name = self.atoms.dup(local_name);
        errdefer self.atoms.free(owned_local_name);
        try append(self.memory, Export, &self.exports, .{
            .export_name = owned_export_name,
            .local_name = owned_local_name,
        });
    }

    pub fn addIndirectExport(self: *Record, request_index: u32, export_name: atom.Atom, import_name: atom.Atom) !void {
        const owned_export_name = self.atoms.dup(export_name);
        errdefer self.atoms.free(owned_export_name);
        const owned_import_name = self.atoms.dup(import_name);
        errdefer self.atoms.free(owned_import_name);
        try append(self.memory, IndirectExport, &self.indirect_exports, .{
            .request_index = request_index,
            .export_name = owned_export_name,
            .import_name = owned_import_name,
        });
    }

    pub fn addStarExport(self: *Record, request_index: u32, export_name: atom.Atom) !void {
        const owned_export_name = self.atoms.dup(export_name);
        errdefer self.atoms.free(owned_export_name);
        try append(self.memory, StarExport, &self.star_exports, .{
            .request_index = request_index,
            .export_name = owned_export_name,
        });
    }

    pub fn addImportAttribute(self: *Record, request_index: u32, key: atom.Atom, value: atom.Atom) !void {
        const owned_key = self.atoms.dup(key);
        errdefer self.atoms.free(owned_key);
        const owned_value = self.atoms.dup(value);
        errdefer self.atoms.free(owned_value);
        try append(self.memory, ImportAttribute, &self.import_attributes, .{
            .request_index = request_index,
            .key = owned_key,
            .value = owned_value,
        });
    }
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

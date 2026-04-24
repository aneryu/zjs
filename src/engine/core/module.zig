const atom = @import("atom.zig");
const memory = @import("memory.zig");

pub const Status = enum {
    unlinked,
    linking,
    linked,
    evaluating,
    evaluated,
    errored,
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

pub const ModuleRecord = struct {
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,
    module_name: atom.Atom,
    status: Status = .unlinked,
    requested_modules: []atom.Atom = &.{},
    imports: []ImportEntry = &.{},
    exports: []ExportEntry = &.{},

    pub fn create(account: *memory.MemoryAccount, atoms: *atom.AtomTable, name: atom.Atom) ModuleRecord {
        return .{
            .memory = account,
            .atoms = atoms,
            .module_name = atoms.dup(name),
        };
    }

    pub fn destroy(self: *ModuleRecord) void {
        self.atoms.free(self.module_name);
        for (self.requested_modules) |requested| self.atoms.free(requested);
        for (self.imports) |entry| {
            self.atoms.free(entry.module_name);
            self.atoms.free(entry.import_name);
            self.atoms.free(entry.local_name);
        }
        for (self.exports) |entry| {
            self.atoms.free(entry.export_name);
            self.atoms.free(entry.local_name);
        }
        if (self.requested_modules.len != 0) self.memory.free(atom.Atom, self.requested_modules);
        if (self.imports.len != 0) self.memory.free(ImportEntry, self.imports);
        if (self.exports.len != 0) self.memory.free(ExportEntry, self.exports);
        self.* = .{
            .memory = self.memory,
            .atoms = self.atoms,
            .module_name = atom.null_atom,
        };
    }

    pub fn setStatus(self: *ModuleRecord, status: Status) void {
        self.status = status;
    }

    pub fn addRequestedModule(self: *ModuleRecord, name: atom.Atom) !void {
        try append(self.memory, atom.Atom, &self.requested_modules, self.atoms.dup(name));
    }

    pub fn addImport(self: *ModuleRecord, module_name: atom.Atom, import_name: atom.Atom, local_name: atom.Atom) !void {
        try append(self.memory, ImportEntry, &self.imports, .{
            .module_name = self.atoms.dup(module_name),
            .import_name = self.atoms.dup(import_name),
            .local_name = self.atoms.dup(local_name),
        });
    }

    pub fn addExport(self: *ModuleRecord, export_name: atom.Atom, local_name: atom.Atom) !void {
        try append(self.memory, ExportEntry, &self.exports, .{
            .export_name = self.atoms.dup(export_name),
            .local_name = self.atoms.dup(local_name),
        });
    }
};

pub const Registry = struct {
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,
    modules: []ModuleRecord = &.{},

    pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable) Registry {
        return .{ .memory = account, .atoms = atoms };
    }

    pub fn deinit(self: *Registry) void {
        for (self.modules) |*record| record.destroy();
        if (self.modules.len != 0) self.memory.free(ModuleRecord, self.modules);
        self.modules = &.{};
    }

    pub fn create(self: *Registry, name: atom.Atom) !*ModuleRecord {
        const next = try self.memory.alloc(ModuleRecord, self.modules.len + 1);
        errdefer self.memory.free(ModuleRecord, next);
        @memcpy(next[0..self.modules.len], self.modules);
        next[self.modules.len] = ModuleRecord.create(self.memory, self.atoms, name);
        if (self.modules.len != 0) self.memory.free(ModuleRecord, self.modules);
        self.modules = next;
        return &self.modules[self.modules.len - 1];
    }
};

fn append(account: *memory.MemoryAccount, comptime T: type, slice: *[]T, item: T) !void {
    const next = try account.alloc(T, slice.*.len + 1);
    errdefer account.free(T, next);
    @memcpy(next[0..slice.*.len], slice.*);
    next[slice.*.len] = item;
    if (slice.*.len != 0) account.free(T, slice.*);
    slice.* = next;
}

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

pub const Record = struct {
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,
    requests: []Request = &.{},
    imports: []Import = &.{},
    exports: []Export = &.{},

    pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable) Record {
        return .{ .memory = account, .atoms = atoms };
    }

    pub fn deinit(self: *Record) void {
        for (self.requests) |request| self.atoms.free(request.module_name);
        for (self.imports) |entry| {
            self.atoms.free(entry.import_name);
            self.atoms.free(entry.local_name);
        }
        for (self.exports) |entry| {
            self.atoms.free(entry.export_name);
            self.atoms.free(entry.local_name);
        }
        if (self.requests.len != 0) self.memory.free(Request, self.requests);
        if (self.imports.len != 0) self.memory.free(Import, self.imports);
        if (self.exports.len != 0) self.memory.free(Export, self.exports);
        self.requests = &.{};
        self.imports = &.{};
        self.exports = &.{};
    }

    pub fn addRequest(self: *Record, module_name: atom.Atom) !u32 {
        const index = self.requests.len;
        try append(self.memory, Request, &self.requests, .{ .module_name = self.atoms.dup(module_name) });
        return @intCast(index);
    }

    pub fn addImport(self: *Record, request_index: u32, import_name: atom.Atom, local_name: atom.Atom) !void {
        try append(self.memory, Import, &self.imports, .{
            .request_index = request_index,
            .import_name = self.atoms.dup(import_name),
            .local_name = self.atoms.dup(local_name),
        });
    }

    pub fn addExport(self: *Record, export_name: atom.Atom, local_name: atom.Atom) !void {
        try append(self.memory, Export, &self.exports, .{
            .export_name = self.atoms.dup(export_name),
            .local_name = self.atoms.dup(local_name),
        });
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

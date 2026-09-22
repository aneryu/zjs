const std = @import("std");
const bytecode = @import("../bytecode.zig");
const atom = @import("../core/atom.zig");
const FunctionBytecode = bytecode.FunctionBytecode;
const module = @This();

pub const Request = struct {
    module_name: atom.Atom,
};

pub const Import = struct {
    request_index: u32,
    import_name: atom.Atom,
    local_name: atom.Atom,
    /// Final index into the module root FunctionBytecode closure table.
    var_idx: u16,
    is_namespace: bool,
};

pub const Export = struct {
    export_name: atom.Atom,
    local_name: atom.Atom,
    /// Filled by the module root finalizer after addGlobalVariables has
    /// established the complete closure topology.
    var_idx: u16 = 0,
};

pub const IndirectExport = struct {
    request_index: u32,
    export_name: atom.Atom,
    import_name: atom.Atom,
    is_namespace: bool,
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
    memory: std.mem.Allocator,
    atoms: *atom.AtomTable,
    requests: []Request = &.{},
    imports: []Import = &.{},
    exports: []Export = &.{},
    indirect_exports: []IndirectExport = &.{},
    star_exports: []StarExport = &.{},
    import_attributes: []ImportAttribute = &.{},
    has_top_level_await: bool = false,

    pub fn init(allocator: std.mem.Allocator, atoms: *atom.AtomTable) Record {
        return .{ .memory = allocator, .atoms = atoms };
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

        if (requests.len != 0) self.memory.free(requests);
        if (imports.len != 0) self.memory.free(imports);
        if (exports.len != 0) self.memory.free(exports);
        if (indirect_exports.len != 0) self.memory.free(indirect_exports);
        if (star_exports.len != 0) self.memory.free(star_exports);
        if (import_attributes.len != 0) self.memory.free(import_attributes);
    }

    pub fn addRequest(self: *Record, module_name: atom.Atom) !u32 {
        const index = self.requests.len;
        try append(self.memory, Request, &self.requests, .{ .module_name = module_name });
        return @intCast(index);
    }

    pub fn addImport(
        self: *Record,
        request_index: u32,
        import_name: atom.Atom,
        local_name: atom.Atom,
        var_idx: u16,
        is_namespace: bool,
    ) !void {
        try append(self.memory, Import, &self.imports, .{
            .request_index = request_index,
            .import_name = import_name,
            .local_name = local_name,
            .var_idx = var_idx,
            .is_namespace = is_namespace,
        });
    }

    pub fn addExport(self: *Record, export_name: atom.Atom, local_name: atom.Atom) !void {
        try append(self.memory, Export, &self.exports, .{
            .export_name = export_name,
            .local_name = local_name,
        });
    }

    pub fn addIndirectExport(
        self: *Record,
        request_index: u32,
        export_name: atom.Atom,
        import_name: atom.Atom,
        is_namespace: bool,
    ) !void {
        try append(self.memory, IndirectExport, &self.indirect_exports, .{
            .request_index = request_index,
            .export_name = export_name,
            .import_name = import_name,
            .is_namespace = is_namespace,
        });
    }

    pub fn addStarExport(self: *Record, request_index: u32, export_name: atom.Atom) !void {
        try append(self.memory, StarExport, &self.star_exports, .{
            .request_index = request_index,
            .export_name = export_name,
        });
    }

    pub fn addImportAttribute(self: *Record, request_index: u32, key: atom.Atom, value: atom.Atom) !void {
        try append(self.memory, ImportAttribute, &self.import_attributes, .{
            .request_index = request_index,
            .key = key,
            .value = value,
        });
    }
};

inline fn append(allocator: std.mem.Allocator, comptime T: type, slice: *[]T, item: T) !void {
    const old = slice.*;
    const new_count = std.math.add(usize, old.len, 1) catch return error.OutOfMemory;
    const next = try allocator.alloc(T, new_count);
    if (old.len != 0) {
        @memcpy(next[0..old.len], old);
        allocator.free(old);
    }
    next[old.len] = item;
    slice.* = next;
}

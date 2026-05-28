const std = @import("std");

const bytecode = @import("../bytecode/root.zig");
const builtins = @import("../builtins/root.zig");
const call_mod = @import("call.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const property_ops = @import("property_ops.zig");
const shared_vm = @import("vm/shared.zig");
const frontend = @import("../frontend/root.zig");
const value_ops = @import("value_ops.zig");
const libc = @cImport({
    @cInclude("signal.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/wait.h");
});

const op = bytecode.opcode.op;
const atom_default = core.atom.predefinedId("default", .string).?;
const atom_star = core.atom.predefinedId("*", .string).?;

const ModuleNamespaceError = error{
    OutOfMemory,
    InvalidAtom,
    InvalidBytecode,
    InvalidUtf8,
    ModuleNotFound,
    MissingExport,
    AmbiguousExport,
    NotExtensible,
    IncompatibleDescriptor,
    InvalidLength,
    ReadOnly,
    TypeError,
};

pub fn isLinked(function: bytecode.Bytecode) bool {
    return function.module_record != null;
}

pub fn instantiateParsedRecord(
    runtime: *core.Runtime,
    module_name: core.Atom,
    function: *const bytecode.Bytecode,
) !*core.module.ModuleRecord {
    return instantiateParsedRecordWithReferrer(runtime, module_name, function, null);
}

pub fn instantiateParsedRecordWithReferrer(
    runtime: *core.Runtime,
    module_name: core.Atom,
    function: *const bytecode.Bytecode,
    referrer_path: ?[]const u8,
) !*core.module.ModuleRecord {
    const parsed = function.module_record orelse return error.InvalidBytecode;
    for (parsed.imports) |entry| _ = try requestName(parsed, entry.request_index);
    for (parsed.indirect_exports) |entry| _ = try requestName(parsed, entry.request_index);
    for (parsed.star_exports) |entry| _ = try requestName(parsed, entry.request_index);
    for (parsed.import_attributes) |entry| _ = try requestName(parsed, entry.request_index);

    for (parsed.requests, 0..) |request, request_index| {
        const resolved = try resolvedRequestAtomForParsed(runtime, &parsed, request.module_name, @intCast(request_index), referrer_path);
        defer runtime.atoms.free(resolved);
        if (nativeModuleKindForAtom(runtime, resolved)) |kind| _ = try preloadNativeModule(runtime, kind);
    }

    const record = try runtime.modules.createFresh(runtime, module_name);
    for (parsed.requests, 0..) |request, request_index| {
        const resolved = try resolvedRequestAtomForParsed(runtime, &parsed, request.module_name, @intCast(request_index), referrer_path);
        defer runtime.atoms.free(resolved);
        try record.addRequestedModule(resolved);
    }
    for (parsed.imports) |entry| {
        const request = try requestName(parsed, entry.request_index);
        const resolved = try resolvedRequestAtomForParsed(runtime, &parsed, request.module_name, entry.request_index, referrer_path);
        defer runtime.atoms.free(resolved);
        try record.addImport(resolved, entry.import_name, entry.local_name);
    }
    for (parsed.exports) |entry| try record.addExport(entry.export_name, entry.local_name);
    for (parsed.indirect_exports) |entry| {
        const request = try requestName(parsed, entry.request_index);
        const resolved = try resolvedRequestAtomForParsed(runtime, &parsed, request.module_name, entry.request_index, referrer_path);
        defer runtime.atoms.free(resolved);
        try record.addIndirectExport(resolved, entry.export_name, entry.import_name);
    }
    for (parsed.star_exports) |entry| {
        const request = try requestName(parsed, entry.request_index);
        const resolved = try resolvedRequestAtomForParsed(runtime, &parsed, request.module_name, entry.request_index, referrer_path);
        defer runtime.atoms.free(resolved);
        try record.addStarExport(resolved, entry.export_name);
    }
    for (parsed.import_attributes) |entry| {
        const request = try requestName(parsed, entry.request_index);
        const resolved = try resolvedRequestAtom(runtime, request.module_name, referrer_path);
        defer runtime.atoms.free(resolved);
        try record.addImportAttribute(resolved, entry.key, entry.value);
    }
    record.has_top_level_await = parsed.has_top_level_await;
    return record;
}

pub fn preloadFileModuleGraph(
    io: std.Io,
    allocator: std.mem.Allocator,
    runtime: *core.Runtime,
    root_source: []const u8,
    root_path: []const u8,
    max_source_size: usize,
) !void {
    var seen = std.ArrayList([]const u8).empty;
    defer {
        for (seen.items) |path| allocator.free(path);
        seen.deinit(allocator);
    }
    try preloadFileModuleGraphInner(io, allocator, runtime, root_source, root_path, max_source_size, &seen, null);
}

pub fn preloadFileModuleGraphWithOrder(
    io: std.Io,
    allocator: std.mem.Allocator,
    runtime: *core.Runtime,
    root_source: []const u8,
    root_path: []const u8,
    max_source_size: usize,
    postorder: *std.ArrayList([]const u8),
) !void {
    var seen = std.ArrayList([]const u8).empty;
    defer {
        for (seen.items) |path| allocator.free(path);
        seen.deinit(allocator);
    }
    try preloadFileModuleGraphInner(io, allocator, runtime, root_source, root_path, max_source_size, &seen, postorder);
}

pub fn preloadMissingFileModuleGraphWithOrder(
    io: std.Io,
    allocator: std.mem.Allocator,
    runtime: *core.Runtime,
    root_source: []const u8,
    root_path: []const u8,
    max_source_size: usize,
    postorder: *std.ArrayList([]const u8),
) !void {
    var seen = std.ArrayList([]const u8).empty;
    defer {
        for (seen.items) |path| allocator.free(path);
        seen.deinit(allocator);
    }
    try preloadFileModuleGraphInnerMode(io, allocator, runtime, root_source, root_path, max_source_size, &seen, postorder, true);
}

pub fn resolveModuleSpecifier(allocator: std.mem.Allocator, referrer_path: []const u8, specifier: []const u8) ![]const u8 {
    if (nativeModuleKindForSpecifier(specifier)) |kind| return allocator.dupe(u8, nativeModuleName(kind));
    if (std.fs.path.isAbsolute(specifier)) return std.fs.path.resolve(allocator, &.{specifier});
    if (!(std.mem.startsWith(u8, specifier, "./") or std.mem.startsWith(u8, specifier, "../"))) {
        return error.ModuleNotFound;
    }
    const base = std.fs.path.dirname(referrer_path) orelse ".";
    return std.fs.path.resolve(allocator, &.{ base, specifier });
}

pub fn buildModuleVarRefs(
    ctx: *core.Context,
    module_name: core.Atom,
    function: *const bytecode.Bytecode,
) ![]core.Value {
    if (function.var_ref_names.len == 0) return &.{};
    const record = ctx.runtime.modules.find(module_name) orelse return error.ModuleNotFound;
    for (function.var_ref_names, 0..) |name, idx| {
        if (moduleHasResolvedImport(record, name)) continue;
        const cell = try moduleLocalCell(ctx, record, name, moduleVarRefIsLexical(function, idx), moduleVarRefIsConst(function, idx));
        cell.free(ctx.runtime);
    }
    const refs = try ctx.runtime.memory.alloc(core.Value, function.var_ref_names.len);
    errdefer ctx.runtime.memory.free(core.Value, refs);
    var initialized: usize = 0;
    errdefer {
        for (refs[0..initialized]) |value| value.free(ctx.runtime);
    }

    for (function.var_ref_names, 0..) |name, idx| {
        refs[idx] = if (moduleHasResolvedImport(record, name))
            try moduleImportCell(ctx, record, name)
        else
            try moduleLocalCell(ctx, record, name, moduleVarRefIsLexical(function, idx), moduleVarRefIsConst(function, idx));
        initialized += 1;
    }
    return refs;
}

fn moduleVarRefIsLexical(function: *const bytecode.Bytecode, index: usize) bool {
    if (index >= function.var_ref_is_lexical.len) return false;
    return function.var_ref_is_lexical[index];
}

fn moduleVarRefIsConst(function: *const bytecode.Bytecode, index: usize) bool {
    if (index >= function.var_ref_is_const.len) return false;
    return function.var_ref_is_const[index];
}

pub fn freeModuleVarRefs(runtime: *core.Runtime, refs: []core.Value) void {
    for (refs) |value| value.free(runtime);
    if (refs.len != 0) runtime.memory.free(core.Value, refs);
}

pub fn moduleNamespaceValue(ctx: *core.Context, module_name: core.Atom) !core.Value {
    const record = ctx.runtime.modules.find(module_name) orelse return error.ModuleNotFound;
    const cell = try moduleNamespaceCell(ctx, record);
    defer cell.free(ctx.runtime);
    return moduleBindingCellValue(cell);
}

pub fn initializeModuleFunctionDeclarations(
    ctx: *core.Context,
    global: *core.Object,
    module_name: core.Atom,
    function: *const bytecode.Bytecode,
) !void {
    if (!function.flags.is_module) return;

    const module_var_refs = try buildModuleVarRefs(ctx, module_name, function);
    defer freeModuleVarRefs(ctx.runtime, module_var_refs);

    var frame = frame_mod.Frame.init(function);
    defer frame.deinit(&ctx.runtime.memory, ctx.runtime);
    if (module_var_refs.len != 0) {
        frame.var_refs = try ctx.runtime.memory.alloc(core.Value, module_var_refs.len);
        for (module_var_refs, 0..) |value, idx| frame.var_refs[idx] = value.dup();
    }

    var pc: usize = moduleFunctionDeclarationPrologueEnd(function);
    while (pc < function.code.len) {
        if (function.code[pc] != op.fclosure8) break;
        if (pc + 2 > function.code.len) return error.InvalidBytecode;
        const constant_index = function.code[pc + 1];
        pc += 2;

        if (pc >= function.code.len) return error.InvalidBytecode;
        const ref_idx: usize = switch (function.code[pc]) {
            op.put_var_ref0 => blk: {
                pc += 1;
                break :blk 0;
            },
            op.put_var_ref1 => blk: {
                pc += 1;
                break :blk 1;
            },
            op.put_var_ref2 => blk: {
                pc += 1;
                break :blk 2;
            },
            op.put_var_ref3 => blk: {
                pc += 1;
                break :blk 3;
            },
            op.put_var_ref => blk: {
                if (pc + 3 > function.code.len) return error.InvalidBytecode;
                const idx = std.mem.readInt(u16, function.code[pc + 1 ..][0..2], .little);
                pc += 3;
                break :blk @intCast(idx);
            },
            else => break,
        };
        if (ref_idx >= frame.var_refs.len) return error.InvalidBytecode;

        const value = function.constants.get(constant_index) orelse return error.InvalidBytecode;
        defer value.free(ctx.runtime);
        const function_value = try shared_vm.createBytecodeFunctionObject(ctx, &frame, function, global, value, function.name, op.fclosure8, true, &.{}, &.{}, &.{}, &.{}, &.{});
        shared_vm.setSlotValue(ctx, &frame.var_refs[ref_idx], function_value);
    }
}

fn moduleFunctionDeclarationPrologueEnd(function: *const bytecode.Bytecode) usize {
    if (function.code.len >= 3 and
        function.code[0] == op.push_this and
        function.code[1] == op.if_false8)
    {
        return 3;
    }
    return 0;
}

fn requestName(record: bytecode.module.Record, request_index: u32) !bytecode.module.Request {
    if (request_index >= record.requests.len) return error.InvalidBytecode;
    return record.requests[@intCast(request_index)];
}

fn resolvedRequestAtomForParsed(
    runtime: *core.Runtime,
    parsed: *const bytecode.module.Record,
    request_atom: core.Atom,
    request_index: u32,
    referrer_path: ?[]const u8,
) !core.Atom {
    const resolved = try resolvedRequestAtom(runtime, request_atom, referrer_path);
    errdefer runtime.atoms.free(resolved);
    const kind = syntheticKindForRequestIndex(runtime, parsed, request_index) orelse return resolved;
    if (kind == .none or kind == .native_std or kind == .native_os) return resolved;
    const resolved_name = runtime.atoms.name(resolved) orelse return error.InvalidAtom;
    const tagged_name = try syntheticModuleRegistryName(runtime.memory.allocator, resolved_name, kind);
    defer runtime.memory.allocator.free(tagged_name);
    runtime.atoms.free(resolved);
    return runtime.internAtom(tagged_name);
}

fn moduleImportCell(ctx: *core.Context, record: *const core.module.ModuleRecord, local_name: core.Atom) !core.Value {
    for (record.resolved_imports) |entry| {
        if (entry.local_name != local_name) continue;
        if (entry.module_index >= ctx.runtime.modules.modules.len) return error.ModuleNotFound;
        const dep = &ctx.runtime.modules.modules[entry.module_index];
        const target = if (entry.binding_name == atom_star)
            try moduleNamespaceCell(ctx, dep)
        else if (explicitStarNamespaceTarget(dep, entry.binding_name) != null)
            try moduleExplicitNamespaceExportCell(ctx, dep, entry.binding_name)
        else
            try moduleLocalCell(ctx, dep, entry.binding_name, true, false);
        errdefer target.free(ctx.runtime);
        return createConstVarRefCell(ctx, target);
    }
    return error.MissingExport;
}

fn moduleHasResolvedImport(record: *const core.module.ModuleRecord, local_name: core.Atom) bool {
    for (record.resolved_imports) |entry| {
        if (entry.local_name == local_name) return true;
    }
    return false;
}

fn moduleLocalCell(ctx: *core.Context, record: *core.module.ModuleRecord, name: core.Atom, is_lexical: bool, is_const: bool) !core.Value {
    try record.ensureLocalBinding(name);
    const index = record.findLocalBindingIndex(name) orelse return error.MissingExport;
    if (varRefCellFromValue(record.local_bindings[index].cell) == null) {
        const object = try core.Object.create(ctx.runtime, core.class.ids.object, null);
        errdefer core.Object.destroyFromHeader(ctx.runtime, &object.header);
        try object.initVarRefPayload(ctx.runtime, if (is_lexical) core.Value.uninitialized() else core.Value.undefinedValue());
        object.varRefIsConstSlot().* = is_const;
        record.local_bindings[index].cell = object.value();
    } else if (is_const) {
        const object = varRefCellFromValue(record.local_bindings[index].cell) orelse return error.TypeError;
        object.varRefIsConstSlot().* = true;
    }
    return record.local_bindings[index].cell.dup();
}

fn moduleNamespaceCell(ctx: *core.Context, record: *core.module.ModuleRecord) !core.Value {
    try record.ensureLocalBinding(atom_star);
    const index = record.findLocalBindingIndex(atom_star) orelse return error.MissingExport;
    if (varRefCellFromValue(record.local_bindings[index].cell) == null) {
        const object = try core.Object.create(ctx.runtime, core.class.ids.module_ns, null);
        const namespace = object.value();
        var namespace_owned = true;
        errdefer if (namespace_owned) namespace.free(ctx.runtime);
        record.local_bindings[index].cell = try createVarRefCell(ctx, namespace);
        namespace_owned = false;
        errdefer {
            const old_cell = record.local_bindings[index].cell;
            record.local_bindings[index].cell = core.Value.undefinedValue();
            old_cell.free(ctx.runtime);
        }
        try initializeModuleNamespaceObject(ctx, record, object);
    }
    return record.local_bindings[index].cell.dup();
}

fn createVarRefCell(ctx: *core.Context, value: core.Value) !core.Value {
    return createVarRefCellWithConst(ctx, value, false);
}

fn createConstVarRefCell(ctx: *core.Context, value: core.Value) !core.Value {
    return createVarRefCellWithConst(ctx, value, true);
}

fn createVarRefCellWithConst(ctx: *core.Context, value: core.Value, is_const: bool) !core.Value {
    var rooted_value = value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    const object = try core.Object.create(ctx.runtime, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &object.header);
    try object.initVarRefPayload(ctx.runtime, rooted_value);
    object.varRefIsConstSlot().* = is_const;
    return object.value();
}

test "createVarRefCellWithConst roots direct symbol value while creating cell" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-module-var-ref-cell-symbol");

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const cell_value = try createVarRefCellWithConst(ctx, core.Value.symbol(symbol_atom), true);
    var cell_alive = true;
    defer if (cell_alive) cell_value.free(rt);
    const cell = varRefCellFromValue(cell_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = cell.varRefValueSlot().* orelse return error.TypeError;
    try std.testing.expect(stored.same(core.Value.symbol(symbol_atom)));
    try std.testing.expect(cell.varRefIsConstSlot().*);

    cell_value.free(rt);
    cell_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn createModuleNamespaceObject(ctx: *core.Context, record: *core.module.ModuleRecord) ModuleNamespaceError!core.Value {
    const object = try core.Object.create(ctx.runtime, core.class.ids.module_ns, null);
    errdefer object.value().free(ctx.runtime);
    try initializeModuleNamespaceObject(ctx, record, object);
    return object.value();
}

fn initializeModuleNamespaceObject(ctx: *core.Context, record: *core.module.ModuleRecord, object: *core.Object) ModuleNamespaceError!void {
    var exports = std.ArrayList(core.Atom).empty;
    defer exports.deinit(ctx.runtime.memory.allocator);
    try collectModuleNamespaceExports(ctx, record, &exports);
    std.mem.sort(core.Atom, exports.items, ctx.runtime, atomLessThan);

    var payload_names = std.ArrayList(core.Atom).empty;
    var payload_cells = std.ArrayList(core.Value).empty;
    errdefer {
        for (payload_names.items) |name| ctx.runtime.atoms.free(name);
        payload_names.deinit(ctx.runtime.memory.allocator);
        for (payload_cells.items) |cell| cell.free(ctx.runtime);
        payload_cells.deinit(ctx.runtime.memory.allocator);
    }

    for (exports.items) |export_name| {
        const resolution = try ctx.runtime.modules.resolveExport(record.module_name, export_name);
        if (resolution != .resolved) continue;
        const binding = resolution.resolved;
        if (binding.module_index >= ctx.runtime.modules.modules.len) continue;
        const dep = &ctx.runtime.modules.modules[binding.module_index];
        const cell = if (binding.local_name == atom_star)
            try moduleNamespaceCell(ctx, dep)
        else if (explicitStarNamespaceTarget(dep, binding.local_name) != null)
            try moduleExplicitNamespaceExportCell(ctx, dep, binding.local_name)
        else
            try moduleLocalCell(ctx, dep, binding.local_name, true, false);
        errdefer cell.free(ctx.runtime);
        const value = moduleBindingCellValue(cell);
        defer value.free(ctx.runtime);
        try object.defineOwnProperty(ctx.runtime, export_name, core.Descriptor.data(value, true, true, false));
        const payload_name = ctx.runtime.atoms.dup(export_name);
        var payload_name_owned = true;
        errdefer if (payload_name_owned) ctx.runtime.atoms.free(payload_name);
        try payload_names.append(ctx.runtime.memory.allocator, payload_name);
        payload_name_owned = false;
        try payload_cells.append(ctx.runtime.memory.allocator, cell);
    }
    try defineModuleNamespaceToStringTag(ctx, object);
    const payload = object.moduleNamespacePayload() orelse return error.InvalidBytecode;
    payload.names = try ownedAtomSliceFromList(ctx, &payload_names);
    payload.cells = try ownedValueSliceFromList(ctx, &payload_cells);
    object.extensible = false;
}

fn defineModuleNamespaceToStringTag(ctx: *core.Context, object: *core.Object) !void {
    const tag_atom = core.atom.predefinedId("Symbol.toStringTag", .symbol) orelse return error.InvalidAtom;
    const tag_string = try core.string.String.createUtf8(ctx.runtime, "Module");
    const tag_value = tag_string.value();
    defer tag_value.free(ctx.runtime);
    try object.defineOwnProperty(ctx.runtime, tag_atom, core.Descriptor.data(tag_value, false, false, false));
}

fn ownedAtomSliceFromList(ctx: *core.Context, list: *std.ArrayList(core.Atom)) ![]core.Atom {
    if (list.items.len == 0) return &.{};
    const out = try ctx.runtime.memory.alloc(core.Atom, list.items.len);
    @memcpy(out, list.items);
    list.clearAndFree(ctx.runtime.memory.allocator);
    return out;
}

fn ownedValueSliceFromList(ctx: *core.Context, list: *std.ArrayList(core.Value)) ![]core.Value {
    if (list.items.len == 0) return &.{};
    const out = try ctx.runtime.memory.alloc(core.Value, list.items.len);
    @memcpy(out, list.items);
    list.clearAndFree(ctx.runtime.memory.allocator);
    return out;
}

fn collectModuleNamespaceExports(ctx: *core.Context, record: *core.module.ModuleRecord, exports: *std.ArrayList(core.Atom)) !void {
    for (record.exports) |entry| {
        try appendUniqueExport(ctx, exports, entry.export_name);
    }
    for (record.indirect_exports) |entry| {
        try appendUniqueExport(ctx, exports, entry.export_name);
    }
    for (record.star_exports) |entry| {
        if (entry.export_name != atom_star) {
            try appendUniqueExport(ctx, exports, entry.export_name);
            continue;
        }
        const dep_index = ctx.runtime.modules.findIndex(entry.module_name) orelse continue;
        const dep = &ctx.runtime.modules.modules[dep_index];
        for (dep.exports) |dep_export| {
            if (dep_export.export_name == atom_default) continue;
            const resolution = try ctx.runtime.modules.resolveExport(record.module_name, dep_export.export_name);
            if (resolution == .resolved) try appendUniqueExport(ctx, exports, dep_export.export_name);
        }
        for (dep.indirect_exports) |dep_export| {
            if (dep_export.export_name == atom_default) continue;
            const resolution = try ctx.runtime.modules.resolveExport(record.module_name, dep_export.export_name);
            if (resolution == .resolved) try appendUniqueExport(ctx, exports, dep_export.export_name);
        }
        for (dep.star_exports) |dep_export| {
            if (dep_export.export_name == atom_star or dep_export.export_name == atom_default) continue;
            const resolution = try ctx.runtime.modules.resolveExport(record.module_name, dep_export.export_name);
            if (resolution == .resolved) try appendUniqueExport(ctx, exports, dep_export.export_name);
        }
    }
}

fn appendUniqueExport(ctx: *core.Context, exports: *std.ArrayList(core.Atom), atom_id: core.Atom) !void {
    for (exports.items) |existing| {
        if (existing == atom_id) return;
    }
    try exports.append(ctx.runtime.memory.allocator, atom_id);
}

fn atomLessThan(rt: *core.Runtime, lhs: core.Atom, rhs: core.Atom) bool {
    const lhs_name = rt.atoms.name(lhs) orelse "";
    const rhs_name = rt.atoms.name(rhs) orelse "";
    const order = std.mem.order(u8, lhs_name, rhs_name);
    return switch (order) {
        .lt => true,
        .eq => lhs < rhs,
        .gt => false,
    };
}

fn moduleBindingCellValue(cell_value: core.Value) core.Value {
    return shared_vm.slotValueDup(cell_value);
}

fn moduleExplicitNamespaceExportCell(ctx: *core.Context, record: *core.module.ModuleRecord, export_name: core.Atom) ModuleNamespaceError!core.Value {
    const target_name = explicitStarNamespaceTarget(record, export_name) orelse return moduleLocalCell(ctx, record, export_name, true, false);
    const target_index = ctx.runtime.modules.findIndex(target_name) orelse return error.ModuleNotFound;
    const target = &ctx.runtime.modules.modules[target_index];
    try record.ensureLocalBinding(export_name);
    const index = record.findLocalBindingIndex(export_name) orelse return error.MissingExport;
    if (varRefCellFromValue(record.local_bindings[index].cell) == null) {
        const namespace = try createModuleNamespaceObject(ctx, target);
        errdefer namespace.free(ctx.runtime);
        record.local_bindings[index].cell = try createVarRefCell(ctx, namespace);
    }
    return record.local_bindings[index].cell.dup();
}

fn explicitStarNamespaceTarget(record: *const core.module.ModuleRecord, export_name: core.Atom) ?core.Atom {
    for (record.star_exports) |entry| {
        if (entry.export_name == export_name and entry.export_name != atom_star) return entry.module_name;
    }
    return null;
}

fn varRefCellFromValue(value: core.Value) ?*core.Object {
    const header = value.refHeader() orelse return null;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_payload_kind != .var_ref) return null;
    return object;
}

fn preloadFileModuleGraphInner(
    io: std.Io,
    allocator: std.mem.Allocator,
    runtime: *core.Runtime,
    source_text: []const u8,
    path: []const u8,
    max_source_size: usize,
    seen: *std.ArrayList([]const u8),
    postorder: ?*std.ArrayList([]const u8),
) !void {
    try preloadFileModuleGraphInnerMode(io, allocator, runtime, source_text, path, max_source_size, seen, postorder, false);
}

fn preloadFileModuleGraphInnerMode(
    io: std.Io,
    allocator: std.mem.Allocator,
    runtime: *core.Runtime,
    source_text: []const u8,
    path: []const u8,
    max_source_size: usize,
    seen: *std.ArrayList([]const u8),
    postorder: ?*std.ArrayList([]const u8),
    skip_existing: bool,
) !void {
    for (seen.items) |existing| {
        if (std.mem.eql(u8, existing, path)) return;
    }
    try appendTrackedPath(allocator, seen, path);
    const module_name = try runtime.internAtom(path);
    defer runtime.atoms.free(module_name);
    if (skip_existing and runtime.modules.find(module_name) != null) return;

    var parsed = try frontend.parser.parse(runtime, source_text, .{ .mode = .module, .filename = path });
    defer parsed.deinit();
    if (parsed.syntax_error != null) return error.SyntaxError;

    _ = try instantiateParsedRecordWithReferrer(runtime, module_name, &parsed.function, path);

    const record = parsed.function.module_record orelse return;
    for (record.requests, 0..) |request, request_index| {
        const specifier = runtime.atoms.name(request.module_name) orelse return error.InvalidAtom;
        if (nativeModuleKindForSpecifier(specifier)) |kind| {
            _ = try preloadNativeModule(runtime, kind);
            continue;
        }
        const dep_path_base = try resolveModuleSpecifier(allocator, path, specifier);
        defer allocator.free(dep_path_base);
        const synthetic_kind = syntheticKindForRequestIndex(runtime, &record, @intCast(request_index));
        const dep_path = if (synthetic_kind) |kind|
            try syntheticModuleRegistryName(allocator, dep_path_base, kind)
        else
            try allocator.dupe(u8, dep_path_base);
        defer allocator.free(dep_path);
        if (synthetic_kind) |kind| {
            _ = try preloadSyntheticFileModule(runtime, dep_path, kind);
            continue;
        }
        const dep_source = std.Io.Dir.cwd().readFileAlloc(io, dep_path, allocator, .limited(max_source_size)) catch |err| switch (err) {
            error.FileNotFound => return error.ModuleNotFound,
            else => |e| return e,
        };
        defer allocator.free(dep_source);
        try preloadFileModuleGraphInnerMode(io, allocator, runtime, dep_source, dep_path, max_source_size, seen, postorder, skip_existing);
    }
    if (postorder) |order| {
        try appendTrackedPath(allocator, order, path);
    }
}

fn appendTrackedPath(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8), path: []const u8) !void {
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    try paths.append(allocator, owned_path);
}

fn syntheticKindForRequestIndex(
    runtime: *core.Runtime,
    record: *const bytecode.module.Record,
    request_index: u32,
) ?core.module.SyntheticKind {
    const type_atom = runtime.internAtom("type") catch return null;
    defer runtime.atoms.free(type_atom);
    for (record.import_attributes) |entry| {
        if (entry.request_index != request_index or entry.key != type_atom) continue;
        const value = runtime.atoms.name(entry.value) orelse return null;
        if (std.mem.eql(u8, value, "json")) return .json;
        if (std.mem.eql(u8, value, "text")) return .text;
        if (std.mem.eql(u8, value, "bytes")) return .bytes;
    }
    return null;
}

fn nativeModuleKindForSpecifier(specifier: []const u8) ?core.module.SyntheticKind {
    if (std.mem.eql(u8, specifier, "std") or std.mem.eql(u8, specifier, "qjs:std")) return .native_std;
    if (std.mem.eql(u8, specifier, "os") or std.mem.eql(u8, specifier, "qjs:os")) return .native_os;
    return null;
}

fn nativeModuleKindForAtom(runtime: *core.Runtime, module_name: core.Atom) ?core.module.SyntheticKind {
    const specifier = runtime.atoms.name(module_name) orelse return null;
    return nativeModuleKindForSpecifier(specifier);
}

fn nativeModuleName(kind: core.module.SyntheticKind) []const u8 {
    return switch (kind) {
        .native_std => "std",
        .native_os => "os",
        else => unreachable,
    };
}

fn syntheticModuleKindName(kind: core.module.SyntheticKind) []const u8 {
    return switch (kind) {
        .json => "json",
        .text => "text",
        .bytes => "bytes",
        else => unreachable,
    };
}

fn syntheticModuleRegistryName(allocator: std.mem.Allocator, path: []const u8, kind: core.module.SyntheticKind) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}#type={s}", .{ path, syntheticModuleKindName(kind) });
}

fn syntheticModuleSourcePath(path: []const u8) []const u8 {
    const suffix = std.mem.indexOf(u8, path, "#type=") orelse return path;
    return path[0..suffix];
}

pub fn syntheticModuleFilePath(path: []const u8) []const u8 {
    return syntheticModuleSourcePath(path);
}

pub fn preloadNativeModule(
    runtime: *core.Runtime,
    kind: core.module.SyntheticKind,
) !*core.module.ModuleRecord {
    const module_name = try runtime.internAtom(nativeModuleName(kind));
    defer runtime.atoms.free(module_name);
    if (runtime.modules.find(module_name)) |existing| return existing;
    const record = try runtime.modules.createFresh(runtime, module_name);
    record.synthetic_kind = kind;
    switch (kind) {
        .native_std => try addNativeExports(runtime, record, &.{ "loadFile", "writeFile", "exists", "exit", "getenv", "setenv", "unsetenv", "getenviron", "gc", "evalScript", "loadScript", "open", "fdopen", "tmpfile", "popen", "puts", "printf", "sprintf", "strerror", "urlGet", "SEEK_SET", "SEEK_CUR", "SEEK_END", "Error", "in", "out", "err" }),
        .native_os => try addNativeExports(runtime, record, &.{ "getenv", "getcwd", "chdir", "remove", "rename", "open", "close", "read", "write", "seek", "O_RDONLY", "O_WRONLY", "O_RDWR", "O_APPEND", "O_CREAT", "O_EXCL", "O_TRUNC", "mkdir", "readdir", "stat", "lstat", "realpath", "symlink", "readlink", "utimes", "S_IFMT", "S_IFIFO", "S_IFCHR", "S_IFDIR", "S_IFBLK", "S_IFREG", "S_IFSOCK", "S_IFLNK", "S_ISGID", "S_ISUID", "setTimeout", "clearTimeout", "setInterval", "clearInterval", "exec", "waitpid", "getpid", "pipe", "kill", "dup", "dup2", "WNOHANG", "SIGINT", "SIGABRT", "SIGFPE", "SIGILL", "SIGSEGV", "SIGTERM", "SIGQUIT", "SIGPIPE", "SIGALRM", "SIGUSR1", "SIGUSR2", "SIGCHLD", "SIGCONT", "SIGSTOP", "SIGTSTP", "SIGTTIN", "SIGTTOU", "isatty", "ttyGetWinSize", "ttySetRaw", "setReadHandler", "setWriteHandler", "signal", "cputime", "exePath", "now", "sleepAsync", "platform", "mkdtemp", "mkstemp", "Worker", "poll", "sleep" }),
        else => return error.InvalidBytecode,
    }
    return record;
}

fn addNativeExports(runtime: *core.Runtime, record: *core.module.ModuleRecord, names: []const []const u8) !void {
    for (names) |name| {
        const atom = try runtime.internAtom(name);
        defer runtime.atoms.free(atom);
        try record.addExport(atom, atom);
    }
}

fn preloadSyntheticFileModule(
    runtime: *core.Runtime,
    path: []const u8,
    kind: core.module.SyntheticKind,
) !*core.module.ModuleRecord {
    const module_name = try runtime.internAtom(path);
    defer runtime.atoms.free(module_name);
    if (runtime.modules.find(module_name)) |existing| return existing;
    const record = try runtime.modules.createFresh(runtime, module_name);
    record.synthetic_kind = kind;
    try record.addExport(atom_default, atom_default);
    return record;
}

pub fn initializeSyntheticFileModule(
    ctx: *core.Context,
    global: *core.Object,
    module_name: core.Atom,
    source_text: []const u8,
) !bool {
    const record = ctx.runtime.modules.find(module_name) orelse return false;
    if (record.synthetic_kind == .none) return false;
    switch (record.synthetic_kind) {
        .none => unreachable,
        .native_std => return try initializeNativeStdModule(ctx, record),
        .native_os => return try initializeNativeOsModule(ctx, record),
        .json, .text, .bytes => {},
    }
    if (moduleBindingInitialized(record, atom_default)) {
        return true;
    }

    const value = switch (record.synthetic_kind) {
        .none => unreachable,
        .json => blk: {
            const string = try core.string.String.createUtf8(ctx.runtime, source_text);
            defer string.value().free(ctx.runtime);
            break :blk try builtins.json.parse(ctx.runtime, global, string.value());
        },
        .text => (try core.string.String.createUtf8(ctx.runtime, source_text)).value(),
        .bytes => try syntheticBytesModuleValue(ctx, global, source_text),
        .native_std, .native_os => unreachable,
    };
    errdefer value.free(ctx.runtime);
    try setModuleBinding(ctx, record, atom_default, value);
    return true;
}

fn initializeNativeStdModule(ctx: *core.Context, record: *core.module.ModuleRecord) !bool {
    try initializeNativeModule(ctx, record, &.{ "loadFile", "writeFile", "exists", "exit", "getenv", "setenv", "unsetenv", "getenviron", "gc", "evalScript", "loadScript", "open", "fdopen", "tmpfile", "popen", "puts", "printf", "sprintf", "strerror", "urlGet" });
    try initializeNativeStdIntValue(ctx, record, "SEEK_SET", std.c.SEEK.SET);
    try initializeNativeStdIntValue(ctx, record, "SEEK_CUR", std.c.SEEK.CUR);
    try initializeNativeStdIntValue(ctx, record, "SEEK_END", std.c.SEEK.END);
    try initializeNativeStdErrorValue(ctx, record);
    try initializeNativeStdFileValue(ctx, record, "in", call_mod.stdin, false, true);
    try initializeNativeStdFileValue(ctx, record, "out", call_mod.stdout, false, true);
    try initializeNativeStdFileValue(ctx, record, "err", call_mod.stderr, false, true);
    return true;
}

fn initializeNativeStdIntValue(
    ctx: *core.Context,
    record: *core.module.ModuleRecord,
    name: []const u8,
    value: i32,
) !void {
    const atom = try ctx.runtime.internAtom(name);
    defer ctx.runtime.atoms.free(atom);
    if (moduleBindingInitialized(record, atom)) return;
    try setModuleBinding(ctx, record, atom, core.Value.int32(value));
}

fn initializeNativeStringValue(
    ctx: *core.Context,
    record: *core.module.ModuleRecord,
    name: []const u8,
    value: []const u8,
) !void {
    const atom = try ctx.runtime.internAtom(name);
    defer ctx.runtime.atoms.free(atom);
    if (moduleBindingInitialized(record, atom)) return;
    const string_value = try value_ops.createStringValue(ctx.runtime, value);
    errdefer string_value.free(ctx.runtime);
    try setModuleBinding(ctx, record, atom, string_value);
}

fn builtinPlatformName() []const u8 {
    return switch (@import("builtin").os.tag) {
        .linux => "linux",
        .macos => "darwin",
        .windows => "win32",
        .freebsd => "freebsd",
        .openbsd => "openbsd",
        .netbsd => "netbsd",
        else => "unknown",
    };
}

fn initializeNativeStdErrorValue(ctx: *core.Context, record: *core.module.ModuleRecord) !void {
    const atom = try ctx.runtime.internAtom("Error");
    defer ctx.runtime.atoms.free(atom);
    if (moduleBindingInitialized(record, atom)) return;
    const object = try core.Object.create(ctx.runtime, core.class.ids.object, null);
    errdefer object.value().free(ctx.runtime);

    try defineNativeStdErrorConstant(ctx.runtime, object, "EINVAL", @intFromEnum(std.posix.E.INVAL));
    try defineNativeStdErrorConstant(ctx.runtime, object, "EIO", @intFromEnum(std.posix.E.IO));
    try defineNativeStdErrorConstant(ctx.runtime, object, "EACCES", @intFromEnum(std.posix.E.ACCES));
    try defineNativeStdErrorConstant(ctx.runtime, object, "EEXIST", @intFromEnum(std.posix.E.EXIST));
    try defineNativeStdErrorConstant(ctx.runtime, object, "ENOSPC", @intFromEnum(std.posix.E.NOSPC));
    try defineNativeStdErrorConstant(ctx.runtime, object, "ENOSYS", @intFromEnum(std.posix.E.NOSYS));
    try defineNativeStdErrorConstant(ctx.runtime, object, "EBUSY", @intFromEnum(std.posix.E.BUSY));
    try defineNativeStdErrorConstant(ctx.runtime, object, "ENOENT", @intFromEnum(std.posix.E.NOENT));
    try defineNativeStdErrorConstant(ctx.runtime, object, "EPERM", @intFromEnum(std.posix.E.PERM));
    try defineNativeStdErrorConstant(ctx.runtime, object, "EPIPE", @intFromEnum(std.posix.E.PIPE));
    try defineNativeStdErrorConstant(ctx.runtime, object, "EBADF", @intFromEnum(std.posix.E.BADF));

    try setModuleBinding(ctx, record, atom, object.value());
}

fn defineNativeStdErrorConstant(rt: *core.Runtime, object: *core.Object, name: []const u8, value: i32) !void {
    const atom = try rt.internAtom(name);
    defer rt.atoms.free(atom);
    try object.defineOwnProperty(rt, atom, core.Descriptor.data(core.Value.int32(value), false, false, true));
}

fn initializeNativeStdFileValue(
    ctx: *core.Context,
    record: *core.module.ModuleRecord,
    name: []const u8,
    file: *std.c.FILE,
    is_popen: bool,
    is_stdio: bool,
) !void {
    const atom = try ctx.runtime.internAtom(name);
    defer ctx.runtime.atoms.free(atom);
    if (moduleBindingInitialized(record, atom)) return;
    const value = try call_mod.createStdFileValue(ctx.runtime, ctx.cached_global, file, is_popen, is_stdio);
    errdefer value.free(ctx.runtime);
    try setModuleBinding(ctx, record, atom, value);
}

fn initializeNativeOsModule(ctx: *core.Context, record: *core.module.ModuleRecord) !bool {
    try initializeNativeModule(ctx, record, &.{ "getenv", "getcwd", "chdir", "remove", "rename", "open", "close", "read", "write", "seek", "mkdir", "readdir", "stat", "lstat", "realpath", "symlink", "readlink", "utimes", "setTimeout", "clearTimeout", "setInterval", "clearInterval", "exec", "waitpid", "getpid", "pipe", "kill", "dup", "dup2", "isatty", "ttyGetWinSize", "ttySetRaw", "setReadHandler", "setWriteHandler", "signal", "cputime", "exePath", "now", "sleepAsync", "mkdtemp", "mkstemp", "Worker", "poll", "sleep" });
    try initializeNativeStringValue(ctx, record, "platform", builtinPlatformName());
    try initializeNativeStdIntValue(ctx, record, "O_RDONLY", osFlagValue(.{ .ACCMODE = .RDONLY }));
    try initializeNativeStdIntValue(ctx, record, "O_WRONLY", osFlagValue(.{ .ACCMODE = .WRONLY }));
    try initializeNativeStdIntValue(ctx, record, "O_RDWR", osFlagValue(.{ .ACCMODE = .RDWR }));
    try initializeNativeStdIntValue(ctx, record, "O_APPEND", osFlagValue(.{ .APPEND = true }));
    try initializeNativeStdIntValue(ctx, record, "O_CREAT", osFlagValue(.{ .CREAT = true }));
    try initializeNativeStdIntValue(ctx, record, "O_EXCL", osFlagValue(.{ .EXCL = true }));
    try initializeNativeStdIntValue(ctx, record, "O_TRUNC", osFlagValue(.{ .TRUNC = true }));
    try initializeNativeStdIntValue(ctx, record, "S_IFMT", libc.S_IFMT);
    try initializeNativeStdIntValue(ctx, record, "S_IFIFO", libc.S_IFIFO);
    try initializeNativeStdIntValue(ctx, record, "S_IFCHR", libc.S_IFCHR);
    try initializeNativeStdIntValue(ctx, record, "S_IFDIR", libc.S_IFDIR);
    try initializeNativeStdIntValue(ctx, record, "S_IFBLK", libc.S_IFBLK);
    try initializeNativeStdIntValue(ctx, record, "S_IFREG", libc.S_IFREG);
    try initializeNativeStdIntValue(ctx, record, "S_IFSOCK", libc.S_IFSOCK);
    try initializeNativeStdIntValue(ctx, record, "S_IFLNK", libc.S_IFLNK);
    try initializeNativeStdIntValue(ctx, record, "S_ISGID", libc.S_ISGID);
    try initializeNativeStdIntValue(ctx, record, "S_ISUID", libc.S_ISUID);
    try initializeNativeStdIntValue(ctx, record, "WNOHANG", libc.WNOHANG);
    try initializeNativeStdIntValue(ctx, record, "SIGINT", libc.SIGINT);
    try initializeNativeStdIntValue(ctx, record, "SIGABRT", libc.SIGABRT);
    try initializeNativeStdIntValue(ctx, record, "SIGFPE", libc.SIGFPE);
    try initializeNativeStdIntValue(ctx, record, "SIGILL", libc.SIGILL);
    try initializeNativeStdIntValue(ctx, record, "SIGSEGV", libc.SIGSEGV);
    try initializeNativeStdIntValue(ctx, record, "SIGTERM", libc.SIGTERM);
    try initializeNativeStdIntValue(ctx, record, "SIGQUIT", libc.SIGQUIT);
    try initializeNativeStdIntValue(ctx, record, "SIGPIPE", libc.SIGPIPE);
    try initializeNativeStdIntValue(ctx, record, "SIGALRM", libc.SIGALRM);
    try initializeNativeStdIntValue(ctx, record, "SIGUSR1", libc.SIGUSR1);
    try initializeNativeStdIntValue(ctx, record, "SIGUSR2", libc.SIGUSR2);
    try initializeNativeStdIntValue(ctx, record, "SIGCHLD", libc.SIGCHLD);
    try initializeNativeStdIntValue(ctx, record, "SIGCONT", libc.SIGCONT);
    try initializeNativeStdIntValue(ctx, record, "SIGSTOP", libc.SIGSTOP);
    try initializeNativeStdIntValue(ctx, record, "SIGTSTP", libc.SIGTSTP);
    try initializeNativeStdIntValue(ctx, record, "SIGTTIN", libc.SIGTTIN);
    try initializeNativeStdIntValue(ctx, record, "SIGTTOU", libc.SIGTTOU);
    return true;
}

fn osFlagValue(value: std.c.O) i32 {
    return @intCast(@as(u32, @bitCast(value)));
}

fn initializeNativeModule(ctx: *core.Context, record: *core.module.ModuleRecord, names: []const []const u8) !void {
    for (names) |name| {
        const atom = try ctx.runtime.internAtom(name);
        defer ctx.runtime.atoms.free(atom);
        if (moduleBindingInitialized(record, atom)) continue;
        const value = switch (record.synthetic_kind) {
            .native_std => try call_mod.createStdModuleFunction(ctx.runtime, name),
            .native_os => try call_mod.createOsModuleFunction(ctx.runtime, name),
            else => unreachable,
        };
        errdefer value.free(ctx.runtime);
        try setModuleBinding(ctx, record, atom, value);
    }
}

fn moduleBindingInitialized(record: *const core.module.ModuleRecord, name: core.Atom) bool {
    const index = record.findLocalBindingIndex(name) orelse return false;
    if (varRefCellFromValue(record.local_bindings[index].cell)) |cell| {
        if (cell.varRefValueSlot().*) |stored| return !stored.isUninitialized();
    }
    return false;
}

fn setModuleBinding(ctx: *core.Context, record: *core.module.ModuleRecord, name: core.Atom, value: core.Value) !void {
    try record.ensureLocalBinding(name);
    const index = record.findLocalBindingIndex(name) orelse return error.MissingExport;
    if (varRefCellFromValue(record.local_bindings[index].cell)) |cell| {
        const old_value = cell.varRefValueSlot().*;
        cell.varRefValueSlot().* = value;
        record.local_bindings[index].initialized = true;
        if (old_value) |stored| stored.free(ctx.runtime);
        return;
    }
    record.local_bindings[index].cell = try createVarRefCell(ctx, value);
    record.local_bindings[index].initialized = true;
}

fn syntheticBytesModuleValue(ctx: *core.Context, global: *core.Object, source_text: []const u8) !core.Value {
    const value = try shared_vm.createUint8ArrayFromBytes(ctx.runtime, global, source_text);
    errdefer value.free(ctx.runtime);
    const object = try shared_vm.expectUint8ArrayObject(value);
    const buffer_value = object.typedArrayBuffer() orelse return error.TypeError;
    const buffer = try property_ops.expectObject(buffer_value);
    if (shared_vm.constructorPrototypeFromGlobal(ctx.runtime, global, "ArrayBuffer")) |prototype| {
        try buffer.setPrototype(ctx.runtime, prototype);
    }
    try markImmutableArrayBuffer(ctx.runtime, buffer);
    return value;
}

fn markImmutableArrayBuffer(rt: *core.Runtime, object: *core.Object) !void {
    object.markImmutablePrototype();
    const visible = try rt.internAtom("immutable");
    defer rt.atoms.free(visible);
    try object.defineOwnProperty(rt, visible, core.Descriptor.data(core.Value.boolean(true), false, false, true));
}

fn resolvedRequestAtom(runtime: *core.Runtime, request_atom: core.Atom, referrer_path: ?[]const u8) !core.Atom {
    const referrer = referrer_path orelse return runtime.atoms.dup(request_atom);
    const specifier = runtime.atoms.name(request_atom) orelse return error.InvalidAtom;
    if (nativeModuleKindForSpecifier(specifier)) |kind| return runtime.internAtom(nativeModuleName(kind));
    if (std.fs.path.isAbsolute(specifier)) {
        const resolved = try std.fs.path.resolve(runtime.memory.allocator, &.{specifier});
        defer runtime.memory.allocator.free(resolved);
        return runtime.internAtom(resolved);
    }
    if (!(std.mem.startsWith(u8, specifier, "./") or std.mem.startsWith(u8, specifier, "../"))) {
        return error.ModuleNotFound;
    }
    const base = std.fs.path.dirname(referrer) orelse ".";
    const resolved = try std.fs.path.resolve(runtime.memory.allocator, &.{ base, specifier });
    defer runtime.memory.allocator.free(resolved);
    return runtime.internAtom(resolved);
}

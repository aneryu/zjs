const std = @import("std");

const bytecode = @import("../bytecode/root.zig");
const builtins = @import("../builtins/root.zig");
const call_mod = @import("call.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const property_ops = @import("property_ops.zig");
const shared_vm = @import("shared.zig");
const frontend = @import("../frontend/root.zig");
const value_ops = @import("value_ops.zig");

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

const ValueSliceRoot = struct {
    rt: ?*core.JSRuntime = null,
    slices: [1]core.runtime.ValueRootSlice = undefined,
    frame: core.runtime.ValueRootFrame = .{},

    fn init(self: *ValueSliceRoot, rt: *core.JSRuntime, values: *[]core.JSValue) void {
        self.rt = rt;
        self.slices[0] = .{ .mutable = values };
        self.frame = .{
            .previous = rt.active_value_roots,
            .slices = &self.slices,
        };
        rt.active_value_roots = &self.frame;
    }

    fn deinit(self: *ValueSliceRoot) void {
        const rt = self.rt orelse return;
        rt.active_value_roots = self.frame.previous;
        self.rt = null;
    }
};

pub fn isLinked(function: bytecode.Bytecode) bool {
    return function.module_record != null;
}

pub fn instantiateParsedRecord(
    runtime: *core.JSRuntime,
    module_name: core.Atom,
    function: *const bytecode.Bytecode,
) !*core.module.ModuleRecord {
    return instantiateParsedRecordWithReferrer(runtime, module_name, function, null);
}

pub fn instantiateParsedRecordWithReferrer(
    runtime: *core.JSRuntime,
    module_name: core.Atom,
    function: *const bytecode.Bytecode,
    referrer_path: ?[]const u8,
) !*core.module.ModuleRecord {
    const parsed = function.module_record orelse return error.InvalidBytecode;
    for (parsed.imports) |entry| _ = try requestName(parsed, entry.request_index);
    for (parsed.indirect_exports) |entry| _ = try requestName(parsed, entry.request_index);
    for (parsed.star_exports) |entry| _ = try requestName(parsed, entry.request_index);
    for (parsed.import_attributes) |entry| _ = try requestName(parsed, entry.request_index);

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
    runtime: *core.JSRuntime,
    context: ?*core.JSContext,
    root_source: []const u8,
    root_path: []const u8,
    max_source_size: usize,
) !void {
    var seen = std.ArrayList([]const u8).empty;
    defer {
        for (seen.items) |path| allocator.free(path);
        seen.deinit(allocator);
    }
    try preloadFileModuleGraphInner(io, allocator, runtime, context, root_source, root_path, max_source_size, &seen, null);
}

pub fn preloadFileModuleGraphWithOrder(
    io: std.Io,
    allocator: std.mem.Allocator,
    runtime: *core.JSRuntime,
    context: ?*core.JSContext,
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
    try preloadFileModuleGraphInner(io, allocator, runtime, context, root_source, root_path, max_source_size, &seen, postorder);
}

pub fn preloadMissingFileModuleGraphWithOrder(
    io: std.Io,
    allocator: std.mem.Allocator,
    runtime: *core.JSRuntime,
    context: ?*core.JSContext,
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
    try preloadFileModuleGraphInnerMode(io, allocator, runtime, context, root_source, root_path, max_source_size, &seen, postorder, true);
}

pub fn resolveModuleSpecifier(allocator: std.mem.Allocator, referrer_path: []const u8, specifier: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, specifier, "node:")) return allocator.dupe(u8, specifier);
    if (std.fs.path.isAbsolute(specifier)) return std.fs.path.resolve(allocator, &.{specifier});
    if (!(std.mem.startsWith(u8, specifier, "./") or std.mem.startsWith(u8, specifier, "../"))) {
        return error.ModuleNotFound;
    }
    const base = std.fs.path.dirname(referrer_path) orelse ".";
    return std.fs.path.resolve(allocator, &.{ base, specifier });
}

pub fn buildModuleVarRefs(
    ctx: *core.JSContext,
    module_name: core.Atom,
    function: *const bytecode.Bytecode,
) ![]core.JSValue {
    if (function.var_ref_names.len == 0) return &.{};
    const record = ctx.runtime.modules.find(module_name) orelse return error.ModuleNotFound;
    for (function.var_ref_names, 0..) |name, idx| {
        if (moduleHasResolvedImport(record, name)) continue;
        const cell = try moduleLocalCell(ctx, record, name, moduleVarRefIsLexical(function, idx), moduleVarRefIsConst(function, idx));
        cell.free(ctx.runtime);
    }
    const refs = try ctx.runtime.memory.alloc(core.JSValue, function.var_ref_names.len);
    errdefer ctx.runtime.memory.free(core.JSValue, refs);
    var rooted_refs: []core.JSValue = refs[0..0];
    var refs_root = ValueSliceRoot{};
    refs_root.init(ctx.runtime, &rooted_refs);
    defer refs_root.deinit();
    var initialized: usize = 0;
    errdefer {
        for (refs[0..initialized]) |*value| {
            value.free(ctx.runtime);
            value.* = core.JSValue.undefinedValue();
        }
        rooted_refs = &.{};
    }

    for (function.var_ref_names, 0..) |name, idx| {
        refs[idx] = if (moduleHasResolvedImport(record, name))
            try moduleImportCell(ctx, record, name)
        else
            try moduleLocalCell(ctx, record, name, moduleVarRefIsLexical(function, idx), moduleVarRefIsConst(function, idx));
        initialized += 1;
        rooted_refs = refs[0..initialized];
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

pub fn freeModuleVarRefs(runtime: *core.JSRuntime, refs: []core.JSValue) void {
    for (refs) |value| value.free(runtime);
    if (refs.len != 0) runtime.memory.free(core.JSValue, refs);
}

pub fn moduleNamespaceValue(ctx: *core.JSContext, module_name: core.Atom) !core.JSValue {
    const record = ctx.runtime.modules.find(module_name) orelse return error.ModuleNotFound;
    const cell = try moduleNamespaceCell(ctx, record);
    defer cell.free(ctx.runtime);
    return moduleBindingCellValue(cell);
}

pub fn initializeModuleFunctionDeclarations(
    ctx: *core.JSContext,
    global: *core.Object,
    module_name: core.Atom,
    function: *const bytecode.Bytecode,
) !void {
    if (!function.flags.is_module) return;

    var module_var_refs = try buildModuleVarRefs(ctx, module_name, function);
    defer freeModuleVarRefs(ctx.runtime, module_var_refs);
    var module_var_refs_root = ValueSliceRoot{};
    module_var_refs_root.init(ctx.runtime, &module_var_refs);
    defer module_var_refs_root.deinit();

    var frame = frame_mod.Frame.init(function);
    defer frame.deinit(&ctx.runtime.memory, ctx.runtime);
    var rooted_frame_var_refs: []core.JSValue = &.{};
    var frame_var_refs_root = ValueSliceRoot{};
    frame_var_refs_root.init(ctx.runtime, &rooted_frame_var_refs);
    defer frame_var_refs_root.deinit();
    if (module_var_refs.len != 0) {
        frame.var_refs = try ctx.runtime.memory.alloc(core.JSValue, module_var_refs.len);
        for (module_var_refs, 0..) |value, idx| frame.var_refs[idx] = value.dup();
        rooted_frame_var_refs = frame.var_refs;
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
        try shared_vm.setSlotValue(ctx, &frame.var_refs[ref_idx], function_value);
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
    runtime: *core.JSRuntime,
    parsed: *const bytecode.module.Record,
    request_atom: core.Atom,
    request_index: u32,
    referrer_path: ?[]const u8,
) !core.Atom {
    const resolved = try resolvedRequestAtom(runtime, request_atom, referrer_path);
    errdefer runtime.atoms.free(resolved);
    const kind = syntheticKindForRequestIndex(runtime, parsed, request_index) orelse return resolved;
    if (kind == .none) return resolved;
    const resolved_name = runtime.atoms.name(resolved) orelse return error.InvalidAtom;
    const tagged_name = try syntheticModuleRegistryName(runtime.memory.allocator, resolved_name, kind);
    defer runtime.memory.allocator.free(tagged_name);
    runtime.atoms.free(resolved);
    return runtime.internAtom(tagged_name);
}

fn moduleImportCell(ctx: *core.JSContext, record: *const core.module.ModuleRecord, local_name: core.Atom) !core.JSValue {
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

fn moduleLocalCell(ctx: *core.JSContext, record: *core.module.ModuleRecord, name: core.Atom, is_lexical: bool, is_const: bool) !core.JSValue {
    try record.ensureLocalBinding(name);
    const index = record.findLocalBindingIndex(name) orelse return error.MissingExport;
    if (varRefCellFromValue(record.local_bindings[index].cell) == null) {
        const object = try core.Object.create(ctx.runtime, core.class.ids.object, null);
        errdefer core.Object.destroyFromHeader(ctx.runtime, &object.header);
        try object.initVarRefPayload(ctx.runtime, if (is_lexical) core.JSValue.uninitialized() else core.JSValue.undefinedValue());
        object.varRefIsConstSlot().* = is_const;
        record.local_bindings[index].cell = object.value();
    } else if (is_const) {
        const object = varRefCellFromValue(record.local_bindings[index].cell) orelse return error.TypeError;
        object.varRefIsConstSlot().* = true;
    }
    return record.local_bindings[index].cell.dup();
}

fn moduleNamespaceCell(ctx: *core.JSContext, record: *core.module.ModuleRecord) !core.JSValue {
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
            record.local_bindings[index].cell = core.JSValue.undefinedValue();
            old_cell.free(ctx.runtime);
        }
        try initializeModuleNamespaceObject(ctx, record, object);
    }
    return record.local_bindings[index].cell.dup();
}

fn createVarRefCell(ctx: *core.JSContext, value: core.JSValue) !core.JSValue {
    return createVarRefCellWithConst(ctx, value, false);
}

fn createConstVarRefCell(ctx: *core.JSContext, value: core.JSValue) !core.JSValue {
    return createVarRefCellWithConst(ctx, value, true);
}

fn createVarRefCellWithConst(ctx: *core.JSContext, value: core.JSValue, is_const: bool) !core.JSValue {
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
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-module-var-ref-cell-symbol");

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const cell_value = try createVarRefCellWithConst(ctx, core.JSValue.symbol(symbol_atom), true);
    var cell_alive = true;
    defer if (cell_alive) cell_value.free(rt);
    const cell = varRefCellFromValue(cell_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = cell.varRefValueSlot().* orelse return error.TypeError;
    try std.testing.expect(stored.same(core.JSValue.symbol(symbol_atom)));
    try std.testing.expect(cell.varRefIsConstSlot().*);

    cell_value.free(rt);
    cell_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn createModuleNamespaceObject(ctx: *core.JSContext, record: *core.module.ModuleRecord) ModuleNamespaceError!core.JSValue {
    const object = try core.Object.create(ctx.runtime, core.class.ids.module_ns, null);
    errdefer object.value().free(ctx.runtime);
    try initializeModuleNamespaceObject(ctx, record, object);
    return object.value();
}

fn initializeModuleNamespaceObject(ctx: *core.JSContext, record: *core.module.ModuleRecord, object: *core.Object) ModuleNamespaceError!void {
    var exports = std.ArrayList(core.Atom).empty;
    defer exports.deinit(ctx.runtime.memory.allocator);
    try collectModuleNamespaceExports(ctx, record, &exports);
    std.mem.sort(core.Atom, exports.items, ctx.runtime, atomLessThan);

    var payload_names = std.ArrayList(core.Atom).empty;
    var payload_cells = std.ArrayList(core.JSValue).empty;
    errdefer {
        for (payload_names.items) |name| ctx.runtime.atoms.free(name);
        payload_names.deinit(ctx.runtime.memory.allocator);
        for (payload_cells.items) |cell| cell.free(ctx.runtime);
        payload_cells.deinit(ctx.runtime.memory.allocator);
    }
    var payload_cell_root_slices = [_]core.runtime.ValueRootSlice{
        .{ .mutable = &payload_cells.items },
    };
    const payload_cell_root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .slices = &payload_cell_root_slices,
    };
    ctx.runtime.active_value_roots = &payload_cell_root_frame;
    defer ctx.runtime.active_value_roots = payload_cell_root_frame.previous;

    for (exports.items) |export_name| {
        const resolution = try ctx.runtime.modules.resolveExport(record.module_name, export_name);
        if (resolution != .resolved) continue;
        const binding = resolution.resolved;
        if (binding.module_index >= ctx.runtime.modules.modules.len) continue;
        const dep = &ctx.runtime.modules.modules[binding.module_index];
        var rooted_cell = if (binding.local_name == atom_star)
            try moduleNamespaceCell(ctx, dep)
        else if (explicitStarNamespaceTarget(dep, binding.local_name) != null)
            try moduleExplicitNamespaceExportCell(ctx, dep, binding.local_name)
        else
            try moduleLocalCell(ctx, dep, binding.local_name, true, false);
        var cell_owned = true;
        errdefer if (cell_owned) rooted_cell.free(ctx.runtime);
        var rooted_value = moduleBindingCellValue(rooted_cell);
        defer rooted_value.free(ctx.runtime);
        var loop_root_values = [_]core.runtime.ValueRootValue{
            .{ .value = &rooted_cell },
            .{ .value = &rooted_value },
        };
        const loop_root_frame = core.runtime.ValueRootFrame{
            .previous = ctx.runtime.active_value_roots,
            .values = &loop_root_values,
        };
        ctx.runtime.active_value_roots = &loop_root_frame;
        defer ctx.runtime.active_value_roots = loop_root_frame.previous;

        try object.defineOwnProperty(ctx.runtime, export_name, core.Descriptor.data(rooted_value, true, true, false));
        const payload_name = ctx.runtime.atoms.dup(export_name);
        var payload_name_owned = true;
        errdefer if (payload_name_owned) ctx.runtime.atoms.free(payload_name);
        try payload_names.append(ctx.runtime.memory.allocator, payload_name);
        payload_name_owned = false;
        try payload_cells.append(ctx.runtime.memory.allocator, rooted_cell);
        cell_owned = false;
    }
    try defineModuleNamespaceToStringTag(ctx, object);
    const payload = object.moduleNamespacePayload() orelse return error.InvalidBytecode;
    payload.names = try ownedAtomSliceFromList(ctx, &payload_names);
    try object.setModuleNamespaceCells(ctx.runtime, try ownedValueSliceFromList(ctx, &payload_cells));
    object.extensible = false;
}

fn defineModuleNamespaceToStringTag(ctx: *core.JSContext, object: *core.Object) !void {
    const tag_atom = core.atom.predefinedId("Symbol.toStringTag", .symbol) orelse return error.InvalidAtom;
    const tag_string = try core.string.String.createUtf8(ctx.runtime, "Module");
    const tag_value = tag_string.value();
    defer tag_value.free(ctx.runtime);
    try object.defineOwnProperty(ctx.runtime, tag_atom, core.Descriptor.data(tag_value, false, false, false));
}

fn ownedAtomSliceFromList(ctx: *core.JSContext, list: *std.ArrayList(core.Atom)) ![]core.Atom {
    if (list.items.len == 0) return &.{};
    const out = try ctx.runtime.memory.alloc(core.Atom, list.items.len);
    @memcpy(out, list.items);
    list.clearAndFree(ctx.runtime.memory.allocator);
    return out;
}

fn ownedValueSliceFromList(ctx: *core.JSContext, list: *std.ArrayList(core.JSValue)) ![]core.JSValue {
    if (list.items.len == 0) return &.{};
    var root_slices = [_]core.runtime.ValueRootSlice{
        .{ .mutable = &list.items },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .slices = &root_slices,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    const out = try ctx.runtime.memory.alloc(core.JSValue, list.items.len);
    @memcpy(out, list.items);
    list.clearAndFree(ctx.runtime.memory.allocator);
    return out;
}

test "ownedValueSliceFromList roots source list during runtime allocation" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const first_atom = try rt.atoms.newValueSymbol("gc-module-owned-value-list-source");
    var list = std.ArrayList(core.JSValue).empty;
    defer {
        for (list.items) |value| value.free(rt);
        list.deinit(rt.memory.allocator);
    }
    try list.append(rt.memory.allocator, core.JSValue.symbol(first_atom));

    const Trigger = struct {
        rt: *core.JSRuntime,
        atom_id: u32,
        saw_value: bool = false,
        trace_failed: bool = false,

        fn trigger(context: ?*anyopaque, size: usize) void {
            _ = size;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            var visitor = core.runtime.RootVisitor{
                .context = self,
                .visit_value = @This().visitValue,
                .visit_object = @This().visitObject,
            };
            self.rt.traceActiveRoots(&visitor) catch {
                self.trace_failed = true;
            };
        }

        fn visitValue(context: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (slot.asSymbolAtom()) |atom_id| {
                if (atom_id == self.atom_id) self.saw_value = true;
            }
        }

        fn visitObject(context: *anyopaque, slot: *?*core.Object) core.runtime.RootTraceError!void {
            _ = context;
            _ = slot;
        }
    };

    const saved_trigger_fn = rt.memory.trigger_gc_fn;
    const saved_trigger_ctx = rt.memory.trigger_gc_ctx;
    var trigger = Trigger{
        .rt = rt,
        .atom_id = first_atom,
    };
    rt.memory.trigger_gc_fn = Trigger.trigger;
    rt.memory.trigger_gc_ctx = &trigger;
    defer {
        rt.memory.trigger_gc_fn = saved_trigger_fn;
        rt.memory.trigger_gc_ctx = saved_trigger_ctx;
    }

    const out = try ownedValueSliceFromList(ctx, &list);
    defer {
        for (out) |value| value.free(rt);
        if (out.len != 0) rt.memory.free(core.JSValue, out);
    }

    try std.testing.expect(!trigger.trace_failed);
    try std.testing.expect(trigger.saw_value);
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expect(out[0].same(core.JSValue.symbol(first_atom)));
}

fn collectModuleNamespaceExports(ctx: *core.JSContext, record: *core.module.ModuleRecord, exports: *std.ArrayList(core.Atom)) !void {
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

fn appendUniqueExport(ctx: *core.JSContext, exports: *std.ArrayList(core.Atom), atom_id: core.Atom) !void {
    for (exports.items) |existing| {
        if (existing == atom_id) return;
    }
    try exports.append(ctx.runtime.memory.allocator, atom_id);
}

fn atomLessThan(rt: *core.JSRuntime, lhs: core.Atom, rhs: core.Atom) bool {
    const lhs_name = rt.atoms.name(lhs) orelse "";
    const rhs_name = rt.atoms.name(rhs) orelse "";
    const order = std.mem.order(u8, lhs_name, rhs_name);
    return switch (order) {
        .lt => true,
        .eq => lhs < rhs,
        .gt => false,
    };
}

fn moduleBindingCellValue(cell_value: core.JSValue) core.JSValue {
    return shared_vm.slotValueDup(cell_value);
}

fn moduleExplicitNamespaceExportCell(ctx: *core.JSContext, record: *core.module.ModuleRecord, export_name: core.Atom) ModuleNamespaceError!core.JSValue {
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

fn varRefCellFromValue(value: core.JSValue) ?*core.Object {
    const header = value.refHeader() orelse return null;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_payload_kind != .var_ref) return null;
    return object;
}

fn preloadFileModuleGraphInner(
    io: std.Io,
    allocator: std.mem.Allocator,
    runtime: *core.JSRuntime,
    context: ?*core.JSContext,
    source_text: []const u8,
    path: []const u8,
    max_source_size: usize,
    seen: *std.ArrayList([]const u8),
    postorder: ?*std.ArrayList([]const u8),
) !void {
    try preloadFileModuleGraphInnerMode(io, allocator, runtime, context, source_text, path, max_source_size, seen, postorder, false);
}

fn preloadFileModuleGraphInnerMode(
    io: std.Io,
    allocator: std.mem.Allocator,
    runtime: *core.JSRuntime,
    context: ?*core.JSContext,
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
    if (parsed.syntax_error) |err| {
        if (context) |ctx| {
            const exception_ops = @import("vm_exception_ops.zig");
            const global_object = try ctx.globalObject();
            var msg_buf = std.ArrayList(u8).empty;
            defer msg_buf.deinit(runtime.memory.allocator);
            try msg_buf.print(runtime.memory.allocator, "SYNTAX ERROR in preloadFileModuleGraphInner {s}:{d}:{d} - {s}", .{ path, err.position.line, err.position.column, err.message });
            const error_val = try exception_ops.createNamedError(runtime, global_object, "SyntaxError", msg_buf.items);
            _ = ctx.throwValue(error_val);
        }
        return error.SyntaxError;
    }

    _ = try instantiateParsedRecordWithReferrer(runtime, module_name, &parsed.function, path);

    const record = parsed.function.module_record orelse return;
    for (record.requests, 0..) |request, request_index| {
        const specifier = runtime.atoms.name(request.module_name) orelse return error.InvalidAtom;
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
        try preloadFileModuleGraphInnerMode(io, allocator, runtime, context, dep_source, dep_path, max_source_size, seen, postorder, skip_existing);
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
    runtime: *core.JSRuntime,
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

fn preloadSyntheticFileModule(
    runtime: *core.JSRuntime,
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
    ctx: *core.JSContext,
    global: *core.Object,
    module_name: core.Atom,
    source_text: []const u8,
) !bool {
    const record = ctx.runtime.modules.find(module_name) orelse return false;
    if (record.synthetic_kind == .none) return false;
    switch (record.synthetic_kind) {
        .none => unreachable,
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
    };
    errdefer value.free(ctx.runtime);
    try setModuleBinding(ctx, record, atom_default, value);
    return true;
}

fn moduleBindingInitialized(record: *const core.module.ModuleRecord, name: core.Atom) bool {
    const index = record.findLocalBindingIndex(name) orelse return false;
    if (varRefCellFromValue(record.local_bindings[index].cell)) |cell| {
        if (cell.varRefValueSlot().*) |stored| return !stored.isUninitialized();
    }
    return false;
}

fn setModuleBinding(ctx: *core.JSContext, record: *core.module.ModuleRecord, name: core.Atom, value: core.JSValue) !void {
    try record.ensureLocalBinding(name);
    const index = record.findLocalBindingIndex(name) orelse return error.MissingExport;
    if (varRefCellFromValue(record.local_bindings[index].cell)) |cell| {
        try cell.setVarRefValue(ctx.runtime, value);
        record.local_bindings[index].initialized = true;
        return;
    }
    record.local_bindings[index].cell = try createVarRefCell(ctx, value);
    record.local_bindings[index].initialized = true;
}

fn syntheticBytesModuleValue(ctx: *core.JSContext, global: *core.Object, source_text: []const u8) !core.JSValue {
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

fn markImmutableArrayBuffer(rt: *core.JSRuntime, object: *core.Object) !void {
    object.markImmutablePrototype();
    const visible = try rt.internAtom("immutable");
    defer rt.atoms.free(visible);
    try object.defineOwnProperty(rt, visible, core.Descriptor.data(core.JSValue.boolean(true), false, false, true));
}

fn resolvedRequestAtom(runtime: *core.JSRuntime, request_atom: core.Atom, referrer_path: ?[]const u8) !core.Atom {
    const referrer = referrer_path orelse return runtime.atoms.dup(request_atom);
    const specifier = runtime.atoms.name(request_atom) orelse return error.InvalidAtom;
    if (std.mem.startsWith(u8, specifier, "node:")) return runtime.atoms.dup(request_atom);
    if (std.fs.path.isAbsolute(specifier)) {
        const resolved = try std.fs.path.resolve(runtime.memory.allocator, &.{specifier});
        defer runtime.memory.allocator.free(resolved);
        return runtime.internAtom(resolved);
    }
    if (!(std.mem.startsWith(u8, specifier, "./") or std.mem.startsWith(u8, specifier, "../"))) {
        return runtime.atoms.dup(request_atom);
    }
    const base = std.fs.path.dirname(referrer) orelse ".";
    const resolved = try std.fs.path.resolve(runtime.memory.allocator, &.{ base, specifier });
    defer runtime.memory.allocator.free(resolved);
    return runtime.internAtom(resolved);
}

const std = @import("std");

const bytecode = @import("../bytecode.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const call_runtime = @import("call_runtime.zig");
const core = @import("../core/root.zig");
const module_auto_init = @import("../core/module_auto_init.zig");
const property_ops = @import("property_ops.zig");
const array_ops = @import("array_ops.zig");
const object_ops = @import("object_ops.zig");
const stack_mod = @import("stack.zig");
const parser = @import("../parser.zig");
const value_ops = @import("value_ops.zig");

const atom_default = core.atom.predefinedId("default", .string).?;
const atom_star = core.atom.predefinedId("*", .string).?;

pub const LinkDiagnostic = struct {
    pub const Kind = enum {
        missing_export,
        ambiguous_export,
    };

    /// Null means no export-resolution diagnostic was produced. Atoms are
    /// borrowed from stable module records and remain valid after link failure.
    kind: ?Kind = null,
    module_name: core.Atom = core.atom.null_atom,
    export_name: core.Atom = core.atom.null_atom,
};

const LinkState = struct {
    ctx: *core.JSContext,
    next_dfs_index: u32 = 1,
    stack: ?*core.module.ModuleRecord = null,
    diagnostic: ?*LinkDiagnostic,
};

pub fn isLinked(record: *const core.module.ModuleRecord) bool {
    return switch (record.status) {
        .linked, .evaluating, .evaluated, .errored => true,
        .unlinked, .linking => false,
    };
}

/// Consume one parser ModuleArtifact and install its canonical FunctionBytecode
/// plus indexed metadata as one registry generation.
pub fn installParsedModuleArtifact(
    ctx: *core.JSContext,
    module_name: core.Atom,
    artifact: parser.ModuleArtifact,
    referrer_path: ?[]const u8,
) !*core.module.ModuleRecord {
    var pending = try pendingDefinitionFromArtifact(ctx, artifact, referrer_path, null);
    defer pending.deinit(ctx.runtime);
    return installPendingDefinition(ctx, module_name, &pending);
}

/// Consume an artifact whose request names were already resolved by a host
/// loader. The borrowed slice is duplicated verbatim: no path normalization,
/// import-attribute tagging, or other remapping is performed.
pub fn installResolvedModuleArtifact(
    ctx: *core.JSContext,
    module_name: core.Atom,
    artifact: parser.ModuleArtifact,
    resolved_request_names: []const core.Atom,
) !*core.module.ModuleRecord {
    var pending = try pendingDefinitionFromArtifact(
        ctx,
        artifact,
        null,
        resolved_request_names,
    );
    defer pending.deinit(ctx.runtime);
    return installPendingDefinition(ctx, module_name, &pending);
}

fn installPendingDefinition(
    ctx: *core.JSContext,
    module_name: core.Atom,
    pending: *core.module.PendingDefinition,
) !*core.module.ModuleRecord {
    const prepared = try ctx.modules.prepareFreshTarget(module_name, pending);
    return switch (prepared) {
        .existing => |record| record,
        .fresh => |record| blk: {
            record.setNamespaceAutoInitResolverNoFail(resolveModuleNamespaceAutoInit);
            if (record.requests.len == 0 and !record.requestsResolved()) {
                record.markRequestsResolvedNoFail();
            }
            break :blk record;
        },
    };
}

fn pendingDefinitionFromArtifact(
    ctx: *core.JSContext,
    artifact: parser.ModuleArtifact,
    referrer_path: ?[]const u8,
    resolved_request_names: ?[]const core.Atom,
) !core.module.PendingDefinition {
    const runtime = ctx.runtime;
    var parsed = artifact.record;
    defer parsed.deinit();

    var pending = core.module.PendingDefinition.init(&runtime.memory, &runtime.atoms);
    pending.adoptFuncObjectValueNoFail(core.JSValue.functionBytecode(&artifact.function_bytecode.header));
    errdefer pending.deinit(runtime);

    const function = artifact.function_bytecode;
    if (!function.isModule() or function.realmContext() != ctx) return error.InvalidBytecode;
    const closure_vars = function.closureVar();
    for (parsed.imports) |entry| {
        _ = try requestName(parsed, entry.request_index);
        if (entry.var_idx >= closure_vars.len) return error.InvalidBytecode;
        const closure = closure_vars[entry.var_idx];
        if (closure.var_name != entry.local_name) return error.InvalidBytecode;
        const expected_type: bytecode.function_def.ClosureType = if (entry.is_namespace)
            .module_decl
        else
            .module_import;
        if (closure.closureType() != expected_type) return error.InvalidBytecode;
    }
    for (parsed.exports) |entry| {
        if (entry.var_idx >= closure_vars.len) return error.InvalidBytecode;
        if (closure_vars[entry.var_idx].var_name != entry.local_name) return error.InvalidBytecode;
    }
    for (parsed.indirect_exports) |entry| _ = try requestName(parsed, entry.request_index);
    for (parsed.star_exports) |entry| {
        _ = try requestName(parsed, entry.request_index);
        if (entry.export_name != atom_star) return error.InvalidBytecode;
    }
    for (parsed.import_attributes) |entry| _ = try requestName(parsed, entry.request_index);
    if (resolved_request_names) |names| {
        if (names.len != parsed.requests.len) return error.InvalidBytecode;
    }

    for (parsed.requests, 0..) |request, request_index| {
        const resolved = if (resolved_request_names) |names|
            runtime.atoms.dup(names[request_index])
        else
            try resolvedRequestAtomForParsed(
                runtime,
                &parsed,
                request.module_name,
                @intCast(request_index),
                referrer_path,
            );
        defer runtime.atoms.free(resolved);
        const installed_index = pending.addRequest(resolved) catch |err|
            return pendingMetadataError(err);
        if (installed_index != @as(u32, @intCast(request_index))) return error.InvalidBytecode;
    }
    for (parsed.imports) |entry| {
        pending.addImport(
            entry.request_index,
            entry.import_name,
            entry.local_name,
            entry.var_idx,
            entry.is_namespace,
        ) catch |err| return pendingMetadataError(err);
    }
    for (parsed.exports) |entry| {
        pending.addExport(
            entry.export_name,
            entry.local_name,
            entry.var_idx,
        ) catch |err| return pendingMetadataError(err);
    }
    for (parsed.indirect_exports) |entry| {
        pending.addIndirectExport(
            entry.request_index,
            entry.export_name,
            entry.import_name,
            entry.is_namespace,
        ) catch |err| return pendingMetadataError(err);
    }
    for (parsed.star_exports) |entry| {
        pending.addStarExport(entry.request_index) catch |err|
            return pendingMetadataError(err);
    }
    for (parsed.import_attributes) |entry| {
        pending.addImportAttribute(
            entry.request_index,
            entry.key,
            entry.value,
        ) catch |err| return pendingMetadataError(err);
    }
    pending.has_top_level_await = parsed.has_top_level_await;
    return pending;
}

fn pendingMetadataError(err: anyerror) error{ OutOfMemory, InvalidBytecode } {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidBytecode,
    };
}

pub fn preloadFileModuleGraph(
    io: std.Io,
    allocator: std.mem.Allocator,
    context: *core.JSContext,
    root_source: []const u8,
    root_path: []const u8,
    max_source_size: usize,
) !void {
    var seen = std.ArrayList([]const u8).empty;
    defer {
        for (seen.items) |path| allocator.free(path);
        seen.deinit(allocator);
    }
    try preloadFileModuleGraphInner(
        io,
        allocator,
        context,
        root_source,
        root_path,
        max_source_size,
        &seen,
        null,
    );
}

pub fn preloadFileModuleGraphWithOrder(
    io: std.Io,
    allocator: std.mem.Allocator,
    context: *core.JSContext,
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
    try preloadFileModuleGraphInner(
        io,
        allocator,
        context,
        root_source,
        root_path,
        max_source_size,
        &seen,
        postorder,
    );
}

pub fn preloadMissingFileModuleGraphWithOrder(
    io: std.Io,
    allocator: std.mem.Allocator,
    context: *core.JSContext,
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
    try preloadFileModuleGraphInnerMode(
        io,
        allocator,
        context,
        root_source,
        root_path,
        max_source_size,
        &seen,
        postorder,
        true,
    );
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

/// Borrow the record's canonical module-function value. Linking performs the
/// one-time FunctionBytecode -> function-object ownership transition.
pub fn moduleFunctionValue(record: *const core.module.ModuleRecord) !core.JSValue {
    const value = record.funcObjectValue();
    if (!value.isObject()) return error.InvalidBytecode;
    return value;
}

pub fn moduleFunctionObject(record: *const core.module.ModuleRecord) !*core.Object {
    return object_ops.functionObjectFromValue(try moduleFunctionValue(record)) orelse
        error.InvalidBytecode;
}

pub fn moduleFunctionBytecode(record: *const core.module.ModuleRecord) !*const bytecode.FunctionBytecode {
    const object = try moduleFunctionObject(record);
    const value = object.functionBytecode() orelse return error.InvalidBytecode;
    const function = call_runtime.functionBytecodeFromValue(value) orelse return error.InvalidBytecode;
    if (!function.isModule()) return error.InvalidBytecode;
    return function;
}

fn createModuleDeclarationCell(
    ctx: *core.JSContext,
    closure: bytecode.function_bytecode.BytecodeClosureVar,
) !*core.VarRef {
    const initial_value = if (closure.isLexical())
        core.JSValue.uninitialized()
    else
        core.JSValue.undefinedValue();
    const cell = try core.VarRef.createClosed(ctx.runtime, initial_value);
    cell.is_lexical = closure.isLexical();
    cell.varRefIsConstSlot().* = closure.isConst();
    cell.varRefIsFunctionNameSlot().* = closure.varKind() == .function_name;
    return cell;
}

fn ensureModuleCaptureCells(
    ctx: *core.JSContext,
    object: *core.Object,
    function: *const bytecode.FunctionBytecode,
) !void {
    const closure_vars = function.closureVar();
    if (object.moduleCaptureSlots().len == 0 and closure_vars.len != 0) {
        try object.allocateNullModuleCaptureSlots(ctx.runtime, closure_vars.len);
    }
    const slots = object.moduleCaptureSlots();
    if (slots.len != closure_vars.len) return error.InvalidBytecode;
    for (closure_vars, 0..) |closure, index| {
        switch (closure.closureType()) {
            // The module binding prefix is followed by unresolved ordinary
            // globals discovered while finalizing the module body. They use
            // the same root-global cell waterfall as script/eval roots.
            .global => {
                if (slots[index] != null) continue;
                const global = try @import("zjs_vm.zig").contextGlobal(ctx);
                const cell = try object_ops.createRootGlobalClosureCell(
                    ctx,
                    global,
                    function,
                    closure,
                );
                object.replaceModuleCaptureSlotOwned(
                    ctx.runtime,
                    index,
                    cell,
                ) catch |err| {
                    cell.freeCell(ctx.runtime);
                    return err;
                };
            },
            .module_decl => {
                if (slots[index] != null) continue;
                const cell = try createModuleDeclarationCell(ctx, closure);
                object.replaceModuleCaptureSlotOwned(ctx.runtime, index, cell) catch |err| {
                    cell.freeCell(ctx.runtime);
                    return err;
                };
            },
            .module_import => {
                if (slots[index] != null) return error.InvalidBytecode;
            },
            else => return error.InvalidBytecode,
        }
    }
}

/// Build the canonical module function around the exact FunctionBytecode owner.
/// The record owns the bytecode until the shell exists, then owns the shell
/// before the bytecode and capture cells are attached to it.
fn ensureModuleFunction(
    ctx: *core.JSContext,
    record: *core.module.ModuleRecord,
) !?*core.Object {
    if (record.synthetic_kind != .none) {
        if (!record.funcObjectValue().isUndefined()) return error.InvalidBytecode;
        try ensureSyntheticDefaultCell(ctx, record);
        return null;
    }

    if (object_ops.functionObjectFromValue(record.funcObjectValue())) |object| {
        const function = try moduleFunctionBytecode(record);
        try ensureModuleCaptureCells(ctx, object, function);
        return object;
    }

    const initial_value = record.funcObjectValue();
    if (!initial_value.isFunctionBytecode()) return error.InvalidBytecode;
    const function = call_runtime.functionBytecodeFromValue(initial_value) orelse
        return error.InvalidBytecode;
    if (!function.isModule() or function.realmContext() != ctx) return error.InvalidBytecode;
    const object = try object_ops.createModuleBytecodeFunctionShell(ctx, function);
    var shell_owned = true;
    errdefer if (shell_owned) object.value().free(ctx.runtime);

    const owned_bytecode = record.takeFuncObjectValueNoFail();
    record.adoptFuncObjectValueNoFail(object.value());
    shell_owned = false;
    object.setFunctionBytecodeValue(ctx.runtime, owned_bytecode) catch unreachable;
    try ensureModuleCaptureCells(ctx, object, function);
    return object;
}

pub fn linkModule(
    ctx: *core.JSContext,
    record: *core.module.ModuleRecord,
    diagnostic: ?*LinkDiagnostic,
) !void {
    if (diagnostic) |out| out.* = .{};
    if (record.registry != &ctx.modules) return error.ModuleNotFound;
    if (!record.requestsResolved()) return error.ModuleNotFound;
    if (isLinked(record)) return;
    if (record.status == .linking) return error.ModuleLinkFailed;

    var state = LinkState{
        .ctx = ctx,
        .diagnostic = diagnostic,
    };
    errdefer rollbackActiveLinkStack(&state);
    try linkModuleInner(&state, record);
    std.debug.assert(state.stack == null);
}

pub fn linkModuleByName(
    ctx: *core.JSContext,
    module_name: core.Atom,
    diagnostic: ?*LinkDiagnostic,
) !*core.module.ModuleRecord {
    const record = ctx.modules.find(module_name) orelse return error.ModuleNotFound;
    try linkModule(ctx, record, diagnostic);
    return record;
}

fn linkModuleInner(state: *LinkState, record: *core.module.ModuleRecord) !void {
    if (!record.requestsResolved()) return error.ModuleNotFound;
    if (isLinked(record)) return;
    if (record.status != .unlinked) return error.ModuleLinkFailed;
    if (state.next_dfs_index == 0) return error.InvalidBytecode;

    record.status = .linking;
    record.link_dfs_index = state.next_dfs_index;
    record.link_dfs_ancestor_index = state.next_dfs_index;
    state.next_dfs_index += 1;
    record.link_stack_prev = state.stack;
    state.stack = record;

    _ = try ensureModuleFunction(state.ctx, record);

    for (record.requests) |request| {
        const dependency = request.module orelse return error.ModuleNotFound;
        if (dependency.registry != &state.ctx.modules) return error.ModuleNotFound;
        switch (dependency.status) {
            .unlinked => {
                try linkModuleInner(state, dependency);
                if (dependency.status == .linking) {
                    record.link_dfs_ancestor_index = @min(
                        record.link_dfs_ancestor_index,
                        dependency.link_dfs_ancestor_index,
                    );
                }
            },
            .linking => {
                record.link_dfs_ancestor_index = @min(
                    record.link_dfs_ancestor_index,
                    dependency.link_dfs_index,
                );
            },
            .linked, .evaluating, .evaluated, .errored => {},
        }
    }

    // QuickJS validates every indirect export before wiring even the first
    // import. This preserves the observable missing-indirect-before-bad-import
    // diagnostic order.
    for (record.indirect_exports) |entry| {
        const dependency = try requestDependency(record, entry.request_index);
        if (entry.is_namespace) continue;
        const resolution = try resolveExportChecked(
            state.ctx,
            dependency,
            entry.import_name,
        );
        switch (resolution) {
            .resolved => {},
            .not_found => {
                recordLinkDiagnostic(
                    state,
                    .missing_export,
                    record,
                    entry.export_name,
                );
                return error.MissingExport;
            },
            .ambiguous => {
                recordLinkDiagnostic(
                    state,
                    .ambiguous_export,
                    record,
                    entry.export_name,
                );
                return error.AmbiguousExport;
            },
        }
    }

    try wireModuleImports(state, record);
    try retainLocalExports(state.ctx, record);
    try runModuleDeclarationInstantiation(state.ctx, record);

    if (record.link_dfs_ancestor_index == record.link_dfs_index) {
        while (true) {
            const member = state.stack orelse unreachable;
            state.stack = member.link_stack_prev;
            member.status = .linked;
            member.resetLinkTransientNoFail();
            if (member == record) break;
        }
    }
}

fn requestDependency(
    record: *core.module.ModuleRecord,
    request_index: u32,
) !*core.module.ModuleRecord {
    const request = record.request(request_index) orelse return error.InvalidBytecode;
    const dependency = request.module orelse return error.ModuleNotFound;
    if (dependency.registry != record.registry) return error.ModuleNotFound;
    return dependency;
}

fn resolveExportChecked(
    ctx: *core.JSContext,
    record: *core.module.ModuleRecord,
    export_name: core.Atom,
) !core.module.ResolvedExport {
    return ctx.modules.resolveExport(record, export_name) catch |err| switch (err) {
        error.ForeignModuleRecord,
        error.InvalidModuleRequestIndex,
        => error.InvalidBytecode,
        else => |other| return other,
    };
}

fn expectResolvedExport(
    state: *LinkState,
    module_record: *core.module.ModuleRecord,
    export_name: core.Atom,
) !core.module.ResolvedBinding {
    const resolution = try resolveExportChecked(
        state.ctx,
        module_record,
        export_name,
    );
    return switch (resolution) {
        .resolved => |binding| binding,
        .not_found => {
            recordLinkDiagnostic(state, .missing_export, module_record, export_name);
            return error.MissingExport;
        },
        .ambiguous => {
            recordLinkDiagnostic(state, .ambiguous_export, module_record, export_name);
            return error.AmbiguousExport;
        },
    };
}

fn recordLinkDiagnostic(
    state: *LinkState,
    kind: LinkDiagnostic.Kind,
    module_record: *const core.module.ModuleRecord,
    export_name: core.Atom,
) void {
    const diagnostic = state.diagnostic orelse return;
    if (diagnostic.kind != null) return;
    diagnostic.* = .{
        .kind = kind,
        .module_name = module_record.module_name,
        .export_name = export_name,
    };
}

fn wireModuleImports(state: *LinkState, record: *core.module.ModuleRecord) !void {
    const object = if (record.synthetic_kind == .none)
        try moduleFunctionObject(record)
    else
        return;
    const function = try moduleFunctionBytecode(record);
    const closure_vars = function.closureVar();

    for (record.imports) |entry| {
        if (entry.var_idx >= closure_vars.len) return error.InvalidBytecode;
        const closure = closure_vars[entry.var_idx];
        if (closure.var_name != entry.local_name) return error.InvalidBytecode;
        const dependency = try requestDependency(record, entry.request_index);

        if (entry.is_namespace) {
            if (closure.closureType() != .module_decl) return error.InvalidBytecode;
            const cell = object.moduleCaptureSlots()[entry.var_idx] orelse
                return error.InvalidBytecode;
            const namespace = try moduleNamespaceValueForRecord(state.ctx, dependency);
            cell.setVarRefValue(state.ctx.runtime, namespace);
            continue;
        }

        if (closure.closureType() != .module_import) return error.InvalidBytecode;
        const binding = try expectResolvedExport(state, dependency, entry.import_name);
        const owned_cell = try importBindingCell(state.ctx, binding);
        object.replaceModuleCaptureSlotOwned(
            state.ctx.runtime,
            entry.var_idx,
            owned_cell,
        ) catch |err| {
            owned_cell.freeCell(state.ctx.runtime);
            return err;
        };
    }
}

fn importBindingCell(
    ctx: *core.JSContext,
    binding: core.module.ResolvedBinding,
) !*core.VarRef {
    switch (binding.entry) {
        .local_export => {
            const cell = bindingCell(binding) orelse return error.InvalidBytecode;
            return cell.dupCell();
        },
        .namespace_export => {
            const target = try namespaceBindingTarget(binding);
            const namespace = try moduleNamespaceValueForRecord(ctx, target);
            var namespace_owned = true;
            errdefer if (namespace_owned) namespace.free(ctx.runtime);
            const cell = try core.VarRef.createClosed(ctx.runtime, namespace);
            namespace_owned = false;
            return cell;
        },
    }
}

fn retainLocalExports(
    ctx: *core.JSContext,
    record: *core.module.ModuleRecord,
) !void {
    if (record.synthetic_kind != .none) {
        try ensureSyntheticDefaultCell(ctx, record);
        return;
    }
    const object = try moduleFunctionObject(record);
    const function = try moduleFunctionBytecode(record);
    const closure_vars = function.closureVar();
    const slots = object.moduleCaptureSlots();
    for (record.exports, 0..) |entry, index| {
        if (entry.var_idx >= closure_vars.len or entry.var_idx >= slots.len)
            return error.InvalidBytecode;
        if (closure_vars[entry.var_idx].var_name != entry.local_name)
            return error.InvalidBytecode;
        if (record.retainedExportCellValue(@intCast(index)) != null) continue;
        const cell = slots[entry.var_idx] orelse return error.InvalidBytecode;
        record.publishRetainedExportCellNoFail(
            @intCast(index),
            cell.valueRef().dup(),
        );
    }
}

fn rollbackActiveLinkStack(state: *LinkState) void {
    while (state.stack) |record| {
        state.stack = record.link_stack_prev;
        rollbackRecordLinkArtifacts(state.ctx, record);
        record.status = .unlinked;
        record.resetLinkTransientNoFail();
    }
}

fn rollbackRecordLinkArtifacts(
    ctx: *core.JSContext,
    record: *core.module.ModuleRecord,
) void {
    for (record.exports, 0..) |_, index| {
        record.clearRetainedExportCellNoFail(ctx.runtime, @intCast(index));
    }
    if (record.synthetic_kind != .none) return;

    const object = moduleFunctionObject(record) catch return;
    const function = moduleFunctionBytecode(record) catch return;
    const slots = object.moduleCaptureSlots();
    for (function.closureVar(), 0..) |closure, index| {
        if (index >= slots.len) continue;
        switch (closure.closureType()) {
            .module_import => object.clearModuleImportCaptureSlot(
                ctx.runtime,
                index,
            ) catch unreachable,
            .module_decl => if (slots[index]) |cell| {
                const initial_value = if (closure.isLexical())
                    core.JSValue.uninitialized()
                else
                    core.JSValue.undefinedValue();
                cell.setVarRefValue(ctx.runtime, initial_value);
            },
            else => {},
        }
    }
}

pub fn runModuleDeclarationInstantiation(
    ctx: *core.JSContext,
    record: *core.module.ModuleRecord,
) !void {
    if (!record.requestsResolved()) return error.ModuleNotFound;
    if (record.synthetic_kind != .none) return;
    const object = try moduleFunctionObject(record);
    const function = try moduleFunctionBytecode(record);
    try object.sealModuleCaptures();
    const global = try @import("zjs_vm.zig").contextGlobal(ctx);
    var stack = stack_mod.Stack.init(&ctx.runtime.memory, ctx.stackLimit());
    defer stack.deinit(ctx.runtime);
    try stack.reserveAdditional(function.stack_size);
    const result = try @import("zjs_vm.zig").runWithCallEnv(.{
        .ctx = ctx,
        .stack = &stack,
        .function = function,
        .initial_this_value = core.JSValue.boolean(true),
        .var_refs = object.functionCaptures(),
        .global = global,
        .current_function_value = record.funcObjectValue(),
        .global_declarations_prevalidated = true,
    });
    result.free(ctx.runtime);
}

pub fn runModuleEvaluationStep(
    ctx: *core.JSContext,
    record: *core.module.ModuleRecord,
    output: ?*std.Io.Writer,
    module_state: *core.Object,
    resume_value: ?core.JSValue,
) !core.JSValue {
    if (!record.requestsResolved()) return error.ModuleNotFound;
    const object = try moduleFunctionObject(record);
    const function = try moduleFunctionBytecode(record);
    try object.sealModuleCaptures();
    const global = try @import("zjs_vm.zig").contextGlobal(ctx);
    var stack = stack_mod.Stack.init(&ctx.runtime.memory, ctx.stackLimit());
    defer stack.deinit(ctx.runtime);
    // A resumed TLA continuation already owns its parked stack backing.
    // runWithArgsState installs (and grows, if needed) that backing directly;
    // preallocating an empty replacement here would be overwritten by the
    // ownership transfer and leak one buffer per resume.
    if (!module_state.generatorExecutionState().has_frame) {
        try stack.reserveAdditional(function.stack_size);
    }
    const finalize_completion = !module_state.generatorStackUsesCombinedStorage();
    defer if (finalize_completion)
        module_state.finalizeGeneratorExecutionCompletion(ctx.runtime);
    return @import("zjs_vm.zig").runWithCallEnv(.{
        .ctx = ctx,
        .stack = &stack,
        .function = function,
        .var_refs = object.functionCaptures(),
        .output = output,
        .global = global,
        .generator_state = module_state,
        .resume_value = resume_value,
        .current_function_value = record.funcObjectValue(),
        .global_declarations_prevalidated = true,
        .suspend_on_module_await = true,
    });
}

pub fn moduleNamespaceValue(
    ctx: *core.JSContext,
    module_name: core.Atom,
) !core.JSValue {
    const record = ctx.modules.find(module_name) orelse return error.ModuleNotFound;
    return moduleNamespaceValueForRecord(ctx, record);
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

fn bindingCell(binding: core.module.ResolvedBinding) ?*core.VarRef {
    const export_index = switch (binding.entry) {
        .local_export => |index| index,
        .namespace_export => return null,
    };
    if (binding.module.retainedExportCellValue(export_index)) |retained| {
        return core.VarRef.fromValue(retained);
    }
    if (binding.module.synthetic_kind != .none) return null;
    const export_entry = binding.module.exports[@intCast(export_index)];
    const object = moduleFunctionObject(binding.module) catch return null;
    const slots = object.moduleCaptureSlots();
    if (export_entry.var_idx >= slots.len) return null;
    return slots[export_entry.var_idx];
}

fn namespaceBindingTarget(
    binding: core.module.ResolvedBinding,
) !*core.module.ModuleRecord {
    const indirect_index = switch (binding.entry) {
        .namespace_export => |index| index,
        .local_export => return error.InvalidBytecode,
    };
    const entry = binding.module.indirect_exports[@intCast(indirect_index)];
    if (!entry.is_namespace) return error.InvalidBytecode;
    return requestDependency(binding.module, entry.request_index);
}

fn moduleNamespaceValueForRecord(
    ctx: *core.JSContext,
    record: *core.module.ModuleRecord,
) !core.JSValue {
    if (record.registry != &ctx.modules) return error.ModuleNotFound;
    if (!record.requestsResolved()) return error.ModuleNotFound;
    const cached = record.moduleNamespaceValue();
    if (!cached.isUndefined()) return cached.dup();

    const object = try core.Object.create(ctx.runtime, core.class.ids.module_ns, null);
    var object_owned = true;
    errdefer if (object_owned) object.value().free(ctx.runtime);
    try initializeCanonicalModuleNamespace(ctx, record, object);
    record.publishModuleNamespaceNoFail(object.value());
    object_owned = false;
    return record.moduleNamespaceValue().dup();
}

fn initializeCanonicalModuleNamespace(
    ctx: *core.JSContext,
    record: *core.module.ModuleRecord,
    object: *core.Object,
) !void {
    var exports = std.ArrayList(core.Atom).empty;
    defer exports.deinit(ctx.runtime.memory.allocator);
    var visited = std.ArrayList(*core.module.ModuleRecord).empty;
    defer visited.deinit(ctx.runtime.memory.allocator);
    try collectCanonicalModuleNamespaceExports(
        ctx,
        record,
        true,
        &visited,
        &exports,
    );
    std.mem.sort(core.Atom, exports.items, ctx.runtime, atomLessThan);

    for (exports.items) |export_name| {
        const resolution = try resolveExportChecked(ctx, record, export_name);
        const binding = switch (resolution) {
            .not_found, .ambiguous => continue,
            .resolved => |resolved| resolved,
        };
        switch (binding.entry) {
            .local_export => {
                if (bindingCell(binding)) |cell| {
                    try object.defineModuleVarRefProperty(
                        ctx.runtime,
                        export_name,
                        cell.dupCell(),
                    );
                } else {
                    try object.defineModuleAutoInitProperty(
                        ctx.runtime,
                        export_name,
                        ctx,
                        record.namespaceAutoInitOwner(),
                    );
                }
            },
            .namespace_export => try object.defineModuleAutoInitProperty(
                ctx.runtime,
                export_name,
                ctx,
                record.namespaceAutoInitOwner(),
            ),
        }
    }
    try defineCanonicalModuleNamespaceToStringTag(ctx, object);
    object.preventExtensions();
}

fn defineCanonicalModuleNamespaceToStringTag(
    ctx: *core.JSContext,
    object: *core.Object,
) !void {
    const tag_atom = core.atom.predefinedId("Symbol.toStringTag", .symbol) orelse
        return error.InvalidAtom;
    const tag_string = try core.string.String.createUtf8(ctx.runtime, "Module");
    const tag_value = tag_string.value();
    defer tag_value.free(ctx.runtime);
    try object.defineOwnProperty(
        ctx.runtime,
        tag_atom,
        core.Descriptor.data(tag_value, false, false, false),
    );
}

fn collectCanonicalModuleNamespaceExports(
    ctx: *core.JSContext,
    record: *core.module.ModuleRecord,
    include_default: bool,
    visited: *std.ArrayList(*core.module.ModuleRecord),
    exports: *std.ArrayList(core.Atom),
) !void {
    for (visited.items) |seen| {
        if (seen == record) return;
    }
    try visited.append(ctx.runtime.memory.allocator, record);

    for (record.exports) |entry| {
        if (!include_default and entry.export_name == atom_default) continue;
        try appendUniqueExport(ctx, exports, entry.export_name);
    }
    for (record.indirect_exports) |entry| {
        if (!include_default and entry.export_name == atom_default) continue;
        try appendUniqueExport(ctx, exports, entry.export_name);
    }
    for (record.star_exports) |entry| {
        try collectCanonicalModuleNamespaceExports(
            ctx,
            try requestDependency(record, entry.request_index),
            false,
            visited,
            exports,
        );
    }
}

fn resolveModuleNamespaceAutoInit(
    owner: *const module_auto_init.AutoInitModuleOwner,
    realm_header: *core.gc.Header,
    atom_id: core.Atom,
) anyerror!module_auto_init.AutoInitMaterialization {
    const record: *core.module.ModuleRecord = @alignCast(@constCast(
        @fieldParentPtr("namespace_auto_init_owner", owner),
    ));
    const realm: *core.JSContext = @alignCast(@fieldParentPtr("header", realm_header));
    if (record.registry != &realm.modules) return error.InvalidBuiltinRegistry;
    const resolution = try resolveExportChecked(realm, record, atom_id);
    const binding = switch (resolution) {
        .not_found => return error.MissingExport,
        .ambiguous => return error.AmbiguousExport,
        .resolved => |resolved| resolved,
    };
    return switch (binding.entry) {
        .local_export => .{
            .var_ref = bindingCell(binding) orelse
                return error.InvalidBuiltinRegistry,
        },
        .namespace_export => .{
            .value = try moduleNamespaceValueForRecord(
                realm,
                try namespaceBindingTarget(binding),
            ),
        },
    };
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

fn preloadFileModuleGraphInner(
    io: std.Io,
    allocator: std.mem.Allocator,
    context: *core.JSContext,
    source_text: []const u8,
    path: []const u8,
    max_source_size: usize,
    seen: *std.ArrayList([]const u8),
    postorder: ?*std.ArrayList([]const u8),
) !void {
    try preloadFileModuleGraphInnerMode(
        io,
        allocator,
        context,
        source_text,
        path,
        max_source_size,
        seen,
        postorder,
        false,
    );
}

fn preloadFileModuleGraphInnerMode(
    io: std.Io,
    allocator: std.mem.Allocator,
    context: *core.JSContext,
    source_text: []const u8,
    path: []const u8,
    max_source_size: usize,
    seen: *std.ArrayList([]const u8),
    postorder: ?*std.ArrayList([]const u8),
    skip_existing: bool,
) !void {
    const runtime = context.runtime;
    for (seen.items) |existing| {
        if (std.mem.eql(u8, existing, path)) return;
    }
    try appendTrackedPath(allocator, seen, path);
    const module_name = try runtime.internAtom(path);
    defer runtime.atoms.free(module_name);

    const existing_record = context.modules.find(module_name);
    if (existing_record) |existing| {
        if (existing.requestsResolved()) return;
    }
    const record = existing_record orelse blk: {
        var parsed = try parser.compile(
            .{ .realm = context },
            source_text,
            .{ .mode = .module, .filename = path },
        );
        defer parsed.deinit();
        if (parsed.syntax_error) |err| {
            const exception_ops = @import("vm_exception_ops.zig");
            const global_object = try @import("zjs_vm.zig").contextGlobal(context);
            var msg_buf = std.ArrayList(u8).empty;
            defer msg_buf.deinit(runtime.memory.allocator);
            try msg_buf.print(
                runtime.memory.allocator,
                "SYNTAX ERROR in {s}:{d}:{d} - {s}",
                .{ path, err.position.line, err.position.column, err.message },
            );
            const error_val = try exception_ops.createNamedError(
                context,
                global_object,
                "SyntaxError",
                msg_buf.items,
            );
            _ = context.throwValue(error_val);
            return error.SyntaxError;
        }
        const artifact = parsed.takeModuleArtifact() orelse
            return error.InvalidBytecode;
        const installed = try installParsedModuleArtifact(
            context,
            module_name,
            artifact,
            path,
        );
        break :blk installed;
    };
    for (record.requests, 0..) |*request, request_index| {
        const dependency_name = runtime.atoms.name(request.module_name) orelse
            return error.InvalidAtom;
        if (syntheticKindFromRegistryName(dependency_name)) |kind| {
            const dependency = try preloadSyntheticFileModuleTracked(
                context,
                dependency_name,
                kind,
            );
            if (request.module == null) {
                record.setRequestModuleNoFail(@intCast(request_index), dependency);
            } else if (request.module != dependency) {
                return error.ModuleNotFound;
            }
            continue;
        }

        const existing_dependency = request.module orelse
            context.modules.find(request.module_name);
        if (existing_dependency == null or
            !existing_dependency.?.requestsResolved())
        {
            const dependency_source = std.Io.Dir.cwd().readFileAlloc(
                io,
                dependency_name,
                allocator,
                .limited(max_source_size),
            ) catch |err| switch (err) {
                error.FileNotFound => {
                    try throwCouldNotLoadModule(context, dependency_name);
                    return error.ModuleNotFound;
                },
                else => |load_error| return load_error,
            };
            defer allocator.free(dependency_source);
            try preloadFileModuleGraphInnerMode(
                io,
                allocator,
                context,
                dependency_source,
                dependency_name,
                max_source_size,
                seen,
                postorder,
                skip_existing,
            );
        }
        const dependency = context.modules.find(request.module_name) orelse
            return error.ModuleNotFound;
        if (request.module == null) {
            record.setRequestModuleNoFail(@intCast(request_index), dependency);
        } else if (request.module != dependency) {
            return error.ModuleNotFound;
        }
    }
    if (!record.requestsResolved()) record.markRequestsResolvedNoFail();
    if (postorder) |order| {
        try appendTrackedPath(allocator, order, path);
    }
}

/// Throw the qjs module-loader failure as a catchable JS exception:
/// `ReferenceError: could not load module filename '<name>'` (mirrors
/// js_module_loader quickjs-libc.c:699).
pub fn throwCouldNotLoadModule(ctx: *core.JSContext, filename: []const u8) !void {
    const exception_ops = @import("vm_exception_ops.zig");
    const global_object = try @import("zjs_vm.zig").contextGlobal(ctx);
    var msg_buf = std.ArrayList(u8).empty;
    defer msg_buf.deinit(ctx.runtime.memory.allocator);
    try msg_buf.print(ctx.runtime.memory.allocator, "could not load module filename '{s}'", .{filename});
    const error_val = try exception_ops.createNamedError(ctx, global_object, "ReferenceError", msg_buf.items);
    _ = ctx.throwValue(error_val);
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
    // No `type` attribute: a `.json` specifier still loads as a JSON module,
    // mirroring qjs js_module_loader's extension check
    // (`has_suffix(module_name, ".json") || res > 0`, quickjs-libc.c:704).
    if (request_index < record.requests.len) {
        if (runtime.atoms.name(record.requests[@intCast(request_index)].module_name)) |specifier| {
            if (std.mem.endsWith(u8, specifier, ".json")) return .json;
        }
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

fn syntheticKindFromRegistryName(path: []const u8) ?core.module.SyntheticKind {
    const marker = std.mem.lastIndexOf(u8, path, "#type=") orelse return null;
    const kind_name = path[marker + "#type=".len ..];
    if (std.mem.eql(u8, kind_name, "json")) return .json;
    if (std.mem.eql(u8, kind_name, "text")) return .text;
    if (std.mem.eql(u8, kind_name, "bytes")) return .bytes;
    return null;
}

pub fn syntheticModuleRegistryName(allocator: std.mem.Allocator, path: []const u8, kind: core.module.SyntheticKind) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}#type={s}", .{ path, syntheticModuleKindName(kind) });
}

fn syntheticModuleSourcePath(path: []const u8) []const u8 {
    const suffix = std.mem.indexOf(u8, path, "#type=") orelse return path;
    return path[0..suffix];
}

pub fn syntheticModuleFilePath(path: []const u8) []const u8 {
    return syntheticModuleSourcePath(path);
}

pub fn preloadSyntheticFileModule(
    ctx: *core.JSContext,
    path: []const u8,
    kind: core.module.SyntheticKind,
) !void {
    _ = try preloadSyntheticFileModuleTracked(ctx, path, kind);
}

fn preloadSyntheticFileModuleTracked(
    ctx: *core.JSContext,
    path: []const u8,
    kind: core.module.SyntheticKind,
) !*core.module.ModuleRecord {
    const runtime = ctx.runtime;
    const module_name = try runtime.internAtom(path);
    defer runtime.atoms.free(module_name);
    if (ctx.modules.find(module_name)) |existing| {
        if (existing.synthetic_kind != kind) return error.InvalidBytecode;
        if (!existing.requestsResolved()) existing.markRequestsResolvedNoFail();
        return existing;
    }

    var pending = core.module.PendingDefinition.init(
        &runtime.memory,
        &runtime.atoms,
    );
    defer pending.deinit(runtime);
    pending.synthetic_kind = kind;
    pending.addExport(atom_default, atom_default, 0) catch |err|
        return pendingMetadataError(err);
    const record = try installPendingDefinition(ctx, module_name, &pending);
    if (!record.requestsResolved()) record.markRequestsResolvedNoFail();
    return record;
}

fn ensureSyntheticDefaultCell(
    ctx: *core.JSContext,
    record: *core.module.ModuleRecord,
) !void {
    if (record.synthetic_kind == .none) return error.InvalidBytecode;
    const export_index = syntheticDefaultExportIndex(record) orelse
        return error.InvalidBytecode;
    if (record.retainedExportCellValue(export_index) != null) return;
    const cell = try core.VarRef.createClosed(
        ctx.runtime,
        core.JSValue.uninitialized(),
    );
    cell.is_lexical = true;
    record.publishRetainedExportCellNoFail(export_index, cell.valueRef());
}

fn syntheticDefaultExportIndex(
    record: *const core.module.ModuleRecord,
) ?u32 {
    for (record.exports, 0..) |entry, index| {
        if (entry.export_name == atom_default and
            entry.local_name == atom_default)
        {
            return std.math.cast(u32, index);
        }
    }
    return null;
}

pub fn initializeSyntheticFileModule(
    ctx: *core.JSContext,
    global: *core.Object,
    module_name: core.Atom,
    source_text: []const u8,
) !bool {
    const record = ctx.modules.find(module_name) orelse return false;
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
            // Route JSON-module parsing through the internal record table
            // (JSON.parse, no reviver) so exec carries no compile-time JSON
            // knowledge. The input is a freshly built string, so the method's
            // ToString coercion is an identity step and no VM caller frame is
            // needed. The json domain is always installed, so the table never
            // misses here.
            const json_parse_ref = core.function.NativeBuiltinRef{
                .domain = .json,
                .id = @intFromEnum(core.host_function.builtin_method_ids.json.StaticMethod.parse),
            };
            break :blk (try builtin_dispatch.callInternalRecord(
                ctx,
                null,
                global,
                &.{},
                null,
                core.JSValue.undefinedValue(),
                json_parse_ref,
                &.{string.value()},
                null,
                null,
            )) orelse return error.SyntaxError;
        },
        .text => (try core.string.String.createUtf8(ctx.runtime, source_text)).value(),
        .bytes => try syntheticBytesModuleValue(ctx, global, source_text),
    };
    errdefer value.free(ctx.runtime);
    try setModuleBinding(ctx, record, atom_default, value);
    return true;
}

fn moduleBindingInitialized(record: *const core.module.ModuleRecord, name: core.Atom) bool {
    for (record.exports, 0..) |entry, index| {
        if (entry.local_name != name) continue;
        const retained = record.retainedExportCellValue(@intCast(index)) orelse
            return false;
        const cell = core.VarRef.fromValue(retained) orelse return false;
        return !cell.varRefValue().isUninitialized();
    }
    return false;
}

fn setModuleBinding(ctx: *core.JSContext, record: *core.module.ModuleRecord, name: core.Atom, value: core.JSValue) !void {
    try ensureSyntheticDefaultCell(ctx, record);
    for (record.exports, 0..) |entry, index| {
        if (entry.local_name != name) continue;
        const retained = record.retainedExportCellValue(@intCast(index)) orelse
            return error.InvalidBytecode;
        const cell = core.VarRef.fromValue(retained) orelse
            return error.InvalidBytecode;
        cell.setVarRefValue(ctx.runtime, value);
        return;
    }
    return error.MissingExport;
}

fn syntheticBytesModuleValue(ctx: *core.JSContext, global: *core.Object, source_text: []const u8) !core.JSValue {
    const value = try array_ops.createUint8ArrayFromBytes(ctx.runtime, global, source_text);
    errdefer value.free(ctx.runtime);
    const object = try array_ops.expectUint8ArrayObject(value);
    const buffer_value = object.typedArrayBuffer() orelse return error.TypeError;
    const buffer = try property_ops.expectObject(buffer_value);
    if (object_ops.constructorPrototypeFromGlobal(ctx.runtime, global, "ArrayBuffer")) |prototype| {
        try buffer.setPrototype(ctx.runtime, prototype);
    }
    try markImmutableArrayBuffer(ctx.runtime, buffer);
    return value;
}

fn markImmutableArrayBuffer(rt: *core.JSRuntime, object: *core.Object) !void {
    try core.object.markArrayBufferImmutable(rt, object);
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

// import.meta.url synthesis (moved from the VM call runtime).

/// Mirrors qjs `js_module_set_import_meta` (quickjs-libc.c:548): a module
/// name containing a scheme separator (`:`) is used verbatim; anything else
/// becomes `file://` + realpath(name), so import.meta.url is an absolute
/// file:// URL even when the engine was invoked with a relative path.
pub fn importMetaUrlValue(rt: *core.JSRuntime, record: *core.module.ModuleRecord) !core.JSValue {
    const name = rt.atoms.name(record.module_name) orelse "";
    if (std.mem.indexOfScalar(u8, name, ':') != null) {
        return value_ops.createStringValue(rt, name);
    }
    // Synthetic registry names carry a `#type=` suffix that is not part of
    // the on-disk path; the URL uses the file path portion.
    const file_path = syntheticModuleFilePath(name);
    const path_z = rt.memory.allocator.dupeZ(u8, file_path) catch return error.OutOfMemory;
    defer rt.memory.allocator.free(path_z);
    var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.c.realpath(path_z, &resolved_buf)) |resolved| {
        const resolved_path = std.mem.span(@as([*:0]u8, @ptrCast(resolved)));
        const url = try std.fmt.allocPrint(rt.memory.allocator, "file://{s}", .{resolved_path});
        defer rt.memory.allocator.free(url);
        return value_ops.createStringValue(rt, url);
    }
    // realpath failure (e.g. "<eval>" pseudo-names): keep the pre-realpath
    // behavior — absolute names still get the file:// scheme, other names are
    // returned verbatim.
    if (std.mem.startsWith(u8, file_path, "/")) {
        const url = try std.fmt.allocPrint(rt.memory.allocator, "file://{s}", .{file_path});
        defer rt.memory.allocator.free(url);
        return value_ops.createStringValue(rt, url);
    }
    return value_ops.createStringValue(rt, name);
}

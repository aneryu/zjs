//! Static module installation, linking, namespaces, and evaluation.
//!
//! Parser artifacts are consumed into `PendingDefinition`; installation moves
//! owned bytecode and duplicates request atoms or binding cells retained by a
//! module record. Link diagnostics borrow atoms from those stable records.
//! Asynchronous host loading and dynamic-import jobs live in this file
//! alongside the registry and graph-link state. The corresponding QuickJS
//! resolver/linker/evaluator spans quickjs.c and quickjs.c.

const std = @import("std");

const bytecode = @import("../bytecode.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const call_runtime = @import("call_runtime.zig");
const core = @import("../core/root.zig");
const array_list_erased = @import("../core/array_list_erased.zig");
const sort_erased = @import("../core/sort_erased.zig");
const exception_ops = @import("exception_ops.zig");
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
    defer pending.deinit();
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
    defer pending.deinit();
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

    var pending = core.module.PendingDefinition.init(runtime, runtime.atoms);
    pending.adoptFuncObjectValueNoFail(core.JSValue.functionBytecode(&artifact.function_bytecode.header));
    errdefer pending.deinit();

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
            names[request_index]
        else
            try resolvedRequestAtomForParsed(
                ctx,
                &parsed,
                request.module_name,
                @intCast(request_index),
                referrer_path,
            );
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

fn resolveModuleSource(context: *core.JSContext, allocator: std.mem.Allocator, referrer: ?[]const u8, specifier: []const u8, mode: core.context.ModuleSourceLoader.Resolution) ![]u8 {
    const loader = context.module_source_loader orelse return error.ModuleNotFound;
    return loader.resolve(loader.ptr, allocator, referrer, specifier, mode);
}

fn readModuleSource(context: *core.JSContext, io: std.Io, allocator: std.mem.Allocator, path: []const u8, limit: usize) std.Io.Dir.ReadFileAllocError![]u8 {
    const loader = context.module_source_loader orelse return error.FileNotFound;
    return loader.read(loader.ptr, io, allocator, path, limit);
}

/// Borrow the record's canonical module-function value. Linking performs the
/// one-time FunctionBytecode -> function-object ownership transition.
pub fn moduleFunctionValue(record: *const core.module.ModuleRecord) !core.JSValue {
    const value = record.funcObjectValue();
    if (!value.is(.object)) return error.InvalidBytecode;
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
                    index,
                    cell,
                ) catch |err| {
                    return err;
                };
            },
            .module_decl => {
                if (slots[index] != null) continue;
                const cell = try createModuleDeclarationCell(ctx, closure);
                object.replaceModuleCaptureSlotOwned(index, cell) catch |err| {
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
        if (!record.funcObjectValue().is(.undefined_value)) return error.InvalidBytecode;
        try ensureSyntheticDefaultCell(ctx, record);
        return null;
    }

    if (object_ops.functionObjectFromValue(record.funcObjectValue())) |object| {
        const function = try moduleFunctionBytecode(record);
        try ensureModuleCaptureCells(ctx, object, function);
        return object;
    }

    const initial_value = record.funcObjectValue();
    if (!initial_value.is(.function_bytecode)) return error.InvalidBytecode;
    const function = call_runtime.functionBytecodeFromValue(initial_value) orelse
        return error.InvalidBytecode;
    if (!function.isModule() or function.realmContext() != ctx) return error.InvalidBytecode;
    const object = try object_ops.createModuleBytecodeFunctionShell(ctx, function);

    const owned_bytecode = record.takeFuncObjectValueNoFail();
    record.adoptFuncObjectValueNoFail(ctx.runtime, object.value());
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
            const member = state.stack.?;
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
            entry.var_idx,
            owned_cell,
        ) catch |err| {
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
            return cell;
        },
        .namespace_export => {
            const target = try namespaceBindingTarget(binding);
            const namespace = try moduleNamespaceValueForRecord(ctx, target);
            const cell = try core.VarRef.createClosed(ctx.runtime, namespace);
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
            cell.valueRef(),
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
        record.clearRetainedExportCellNoFail(@intCast(index));
    }
    if (record.synthetic_kind != .none) return;

    const object = moduleFunctionObject(record) catch return;
    const function = moduleFunctionBytecode(record) catch return;
    const slots = object.moduleCaptureSlots();
    for (function.closureVar(), 0..) |closure, index| {
        if (index >= slots.len) continue;
        switch (closure.closureType()) {
            .module_import => object.clearModuleImportCaptureSlot(
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
    var stack = stack_mod.Stack.init(ctx.runtime, ctx.stackLimit());
    defer stack.deinit(ctx.runtime);
    try stack.reserveAdditional(function.stack_size);
    _ = try @import("zjs_vm.zig").runWithCallEnv(.{
        .ctx = ctx,
        .stack = &stack,
        .function = function,
        .initial_this_value = core.JSValue.boolean(true),
        .var_refs = object.functionCaptures(),
        .global = global,
        .current_function_value = record.funcObjectValue(),
    });
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
    var stack = stack_mod.Stack.init(ctx.runtime, ctx.stackLimit());
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
    ctx: *core.JSContext,
    parsed: *const bytecode.module.Record,
    request_atom: core.Atom,
    request_index: u32,
    referrer_path: ?[]const u8,
) !core.Atom {
    const runtime = ctx.runtime;
    const resolved = try resolvedRequestAtom(ctx, request_atom, referrer_path);
    // TGC S3 §4 class B: the resolved specifier is a bare id held across the
    // tagged-name formatting allocation below.
    var resolved_roots = core.runtime.rootAtoms(.{&resolved});
    resolved_roots.activate(runtime);
    defer resolved_roots.deactivate(runtime);
    const kind = syntheticKindForRequestIndex(ctx, parsed, request_index) orelse return resolved;
    if (kind == .none) return resolved;
    const resolved_name = runtime.atoms.name(resolved) orelse return error.InvalidAtom;
    const tagged_name = try syntheticModuleRegistryName(runtime.nativeAllocator(), resolved_name, kind);
    defer runtime.nativeAllocator().free(tagged_name);
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
    if (!cached.is(.undefined_value)) return cached;

    const object = try core.Object.create(ctx.runtime, core.class.ids.module_ns, null);
    try initializeCanonicalModuleNamespace(ctx, record, object);
    record.publishModuleNamespaceNoFail(ctx.runtime, object.value());
    return record.moduleNamespaceValue();
}

fn initializeCanonicalModuleNamespace(
    ctx: *core.JSContext,
    record: *core.module.ModuleRecord,
    object: *core.Object,
) !void {
    var exports = std.ArrayList(core.Atom).empty;
    defer exports.deinit(ctx.runtime.nativeAllocator());
    var visited = std.ArrayList(*core.module.ModuleRecord).empty;
    defer visited.deinit(ctx.runtime.nativeAllocator());
    try collectCanonicalModuleNamespaceExports(
        ctx,
        record,
        true,
        &visited,
        &exports,
    );
    sort_erased.heap(core.Atom, exports.items, ctx.runtime, atomLessThan);

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
                        cell,
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
    try object.defineOwnProperty(
        ctx.runtime,
        tag_atom,
        core.Descriptor.data(tag_value, .none),
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
    try visited.append(ctx.runtime.nativeAllocator(), record);

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
    try exports.append(ctx.runtime.nativeAllocator(), atom_id);
}

fn atomLessThan(rt: *core.JSRuntime, lhs: core.Atom, rhs: core.Atom) bool {
    const lhs_name = rt.atoms.name(lhs) orelse "";
    const rhs_name = rt.atoms.name(rhs) orelse "";
    const order = std.mem.order(u8, lhs_name, rhs_name);
    return switch (order) {
        .lt => true,
        .eq => lhs.raw() < rhs.raw(),
        .gt => false,
    };
}

/// Skipping already-preloaded modules is not a caller-selectable mode: the
/// `seen` list plus the "record with resolved requests returns early" check
/// below give every entry point the same behaviour.
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
    const runtime = context.runtime;
    for (seen.items) |existing| {
        if (std.mem.eql(u8, existing, path)) return;
    }
    try appendTrackedPath(allocator, seen, path);
    const module_name = try runtime.internAtom(path);
    // TGC S3 §4 class B: held across compilation of the module source.
    var module_name_roots = core.runtime.rootAtoms(.{&module_name});
    module_name_roots.activate(runtime);
    defer module_name_roots.deactivate(runtime);

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
            const global_object = try @import("zjs_vm.zig").contextGlobal(context);
            var msg_buf = std.ArrayList(u8).empty;
            defer msg_buf.deinit(runtime.nativeAllocator());
            try msg_buf.print(
                runtime.nativeAllocator(),
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
            const dependency_source = readModuleSource(context, io, allocator, dependency_name, max_source_size) catch |err| switch (err) {
                error.FileNotFound => {
                    try throwCouldNotLoadModule(context, dependency_name);
                    return error.JSException;
                },
                else => |load_error| {
                    const global = context.global orelse
                        try @import("zjs_vm.zig").contextGlobal(context);
                    _ = try exception_ops.throwHostError(context, global, load_error);
                    unreachable;
                },
            };
            defer allocator.free(dependency_source);
            try preloadFileModuleGraphInner(
                io,
                allocator,
                context,
                dependency_source,
                dependency_name,
                max_source_size,
                seen,
                postorder,
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
    const global_object = try @import("zjs_vm.zig").contextGlobal(ctx);
    var msg_buf = std.ArrayList(u8).empty;
    defer msg_buf.deinit(ctx.runtime.nativeAllocator());
    try msg_buf.print(ctx.runtime.nativeAllocator(), "could not load module filename '{s}'", .{filename});
    const error_val = try exception_ops.createNamedError(ctx, global_object, "ReferenceError", msg_buf.items);
    _ = ctx.throwValue(error_val);
}

fn appendTrackedPath(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8), path: []const u8) !void {
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    try array_list_erased.append(paths, allocator, owned_path);
}

fn syntheticKindForRequestIndex(
    ctx: *core.JSContext,
    record: *const bytecode.module.Record,
    request_index: u32,
) ?core.module.SyntheticKind {
    const loader = ctx.module_source_loader orelse return null;
    if (request_index >= record.requests.len) return null;
    const specifier = ctx.runtime.atoms.name(record.requests[request_index].module_name) orelse return null;
    var attribute: ?[]const u8 = null;
    for (record.import_attributes) |entry| {
        if (entry.request_index == request_index and entry.key == core.atom.ids.type_) {
            attribute = ctx.runtime.atoms.name(entry.value);
            break;
        }
    }
    return loader.syntheticKind(loader.ptr, specifier, attribute);
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
    const suffix = std.mem.lastIndexOf(u8, path, "#type=") orelse return path;
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
    // TGC S3 §4 class B: held across the synthetic record build.
    var module_name_roots = core.runtime.rootAtoms(.{&module_name});
    module_name_roots.activate(runtime);
    defer module_name_roots.deactivate(runtime);
    if (ctx.modules.find(module_name)) |existing| {
        if (existing.synthetic_kind != kind) return error.InvalidBytecode;
        if (!existing.requestsResolved()) existing.markRequestsResolvedNoFail();
        return existing;
    }

    var pending = core.module.PendingDefinition.init(
        runtime,
        runtime.atoms,
    );
    defer pending.deinit();
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
    try setModuleBinding(ctx, record, atom_default, value);
    return true;
}

fn moduleBindingInitialized(record: *const core.module.ModuleRecord, name: core.Atom) bool {
    for (record.exports, 0..) |entry, index| {
        if (entry.local_name != name) continue;
        const retained = record.retainedExportCellValue(@intCast(index)) orelse
            return false;
        const cell = core.VarRef.fromValue(retained) orelse return false;
        return !cell.varRefValue().is(.uninitialized);
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
    const object = try array_ops.expectUint8ArrayObject(value);
    const buffer_value = object.typedArrayBuffer() orelse return error.TypeError;
    const buffer = try property_ops.expectObject(buffer_value);
    if (ctx.classPrototypeObject(core.class.ids.array_buffer)) |prototype| {
        try buffer.setPrototype(ctx.runtime, prototype);
    }
    try markImmutableArrayBuffer(ctx.runtime, buffer);
    return value;
}

fn markImmutableArrayBuffer(rt: *core.JSRuntime, object: *core.Object) !void {
    try core.object.markArrayBufferImmutable(rt, object);
}

fn resolvedRequestAtom(ctx: *core.JSContext, request_atom: core.Atom, referrer_path: ?[]const u8) !core.Atom {
    const referrer = referrer_path orelse return request_atom;
    const loader = ctx.module_source_loader orelse return request_atom;
    const runtime = ctx.runtime;
    const specifier = runtime.atoms.name(request_atom) orelse return error.InvalidAtom;
    const resolved = try loader.resolve(loader.ptr, runtime.nativeAllocator(), referrer, specifier, .static_import);
    defer runtime.nativeAllocator().free(resolved);
    return runtime.internAtom(resolved);
}

/// Metadata contents come from host policy; the engine owns object identity.
pub fn importMetaUrlValue(ctx: *core.JSContext, record: *core.module.ModuleRecord) !core.JSValue {
    const loader = ctx.module_source_loader orelse return core.JSValue.undefinedValue();
    const rt = ctx.runtime;
    const name = rt.atoms.name(record.module_name) orelse "";
    const url = try loader.metadataUrl(loader.ptr, rt.nativeAllocator(), name);
    defer rt.nativeAllocator().free(url);
    return value_ops.createStringValue(rt, url);
}

// ----- merged from module_graph.zig -----
// Host-integrated module loading, dynamic import jobs, and graph evaluation.
//
// `HostHooks.LoadedModule.owned` decides whether the loader or this module
// owns returned source/path storage. Dynamic-import state owns its private
// continuation/waiter lists, while queued continuations duplicate retained
// JSValues and hold a `RealmRef` until completion. Parser artifacts, the
// static module registry, and the asynchronous graph lifecycle share this
// file. The protocol follows `js_dynamic_import` and its job at quickjs.c,
// plus module evaluation at quickjs.c.
const atomics_ops = @import("atomics_ops.zig");
const jobs_mod = core.jobs;
const exec = @import("root.zig");
const frame_mod = @import("frame.zig");
pub const HostHooks = struct {
    ptr: *anyopaque,
    resolveModule: *const fn (*anyopaque, []const u8, ?[]const u8, std.mem.Allocator) anyerror!ResolvedModule,
    loadModule: *const fn (*anyopaque, ResolvedModule, std.mem.Allocator) anyerror!LoadedModule,

    pub const ModuleKind = enum { esm, commonjs, json, wasm, builtin };

    pub const ResolvedModule = struct {
        specifier: []const u8,
        path: []const u8,
        kind: ModuleKind,
    };

    pub const LoadedModule = struct {
        source: []const u8,
        path: []const u8,
        kind: ModuleKind,
        owned: bool = false,
    };
};
pub const ModuleEvalStep = union(enum) {
    completed: core.JSValue,
    suspended: struct {
        continuation: core.JSValue,
        awaited: core.JSValue,
    },
};
const ContinuationRoots = struct {
    runtime: *core.JSRuntime,
    list: *std.ArrayList(ModuleContinuation),
    registered: bool = false,

    fn traceRoots(context: *anyopaque, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
        const self: *ContinuationRoots = @ptrCast(@alignCast(context));
        for (self.list.items) |*entry| {
            if (entry.realm.borrow()) |ctx| try visitor.constHeader(&ctx.header);
            try visitor.value(&entry.continuation);
            try visitor.value(&entry.awaited);
        }
    }

    fn provider(self: *ContinuationRoots) core.runtime.RootProvider {
        return .{ .context = @ptrCast(self), .trace = traceRoots };
    }

    inline fn activate(self: *ContinuationRoots) !void {
        if (comptime !core.runtime.value_root_frames_enabled) return;
        try self.runtime.registerRootProvider(self.provider());
        self.registered = true;
    }

    fn deactivate(self: *ContinuationRoots) void {
        if (comptime !core.runtime.value_root_frames_enabled) return;
        if (!self.registered) return;
        self.runtime.unregisterRootProvider(self.provider());
        self.registered = false;
    }
};
const WaiterRoots = struct {
    runtime: *core.JSRuntime,
    list: *std.ArrayList(ModuleEvaluationWaiter),
    registered: bool = false,

    fn traceRoots(context: *anyopaque, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
        const self: *WaiterRoots = @ptrCast(@alignCast(context));
        for (self.list.items) |*entry| {
            if (entry.realm.borrow()) |ctx| try visitor.constHeader(&ctx.header);
            try visitor.value(&entry.resolve);
            try visitor.value(&entry.reject);
        }
    }

    fn provider(self: *WaiterRoots) core.runtime.RootProvider {
        return .{ .context = @ptrCast(self), .trace = traceRoots };
    }

    inline fn activate(self: *WaiterRoots) !void {
        if (comptime !core.runtime.value_root_frames_enabled) return;
        try self.runtime.registerRootProvider(self.provider());
        self.registered = true;
    }

    fn deactivate(self: *WaiterRoots) void {
        if (comptime !core.runtime.value_root_frames_enabled) return;
        if (!self.registered) return;
        self.runtime.unregisterRootProvider(self.provider());
        self.registered = false;
    }
};
pub const ModuleContinuation = struct {
    realm: core.RealmRef,
    path: []const u8,
    continuation: core.JSValue,
    awaited: core.JSValue,
    keep_result: bool,
    completed: bool = false,
    /// Terminal payload remains owned here until every exposed evaluation
    /// waiter has been settled successfully.
    settle_waiters: bool = false,
    completion_rejected: bool = false,
    deferred_start: bool = false,
    awaited_normalized: bool = false,
    ready: bool = false,

    fn replaceAwaited(self: *ModuleContinuation, _: *core.JSRuntime, replacement: core.JSValue) void {
        self.awaited = replacement;
    }
};
const ModuleEvaluationWaiter = struct {
    realm: core.RealmRef,
    path: []const u8,
    resolve: core.JSValue,
    reject: core.JSValue,

    fn deinit(self: *ModuleEvaluationWaiter, _: *core.JSRuntime, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.realm.deinit();
    }
};
pub const ImportLoaderType = enum { none, json, text };
fn importLoaderTypeFromAttributes(ctx: *core.JSContext, attributes: core.JSValue) ImportLoaderType {
    if (!attributes.is(.object)) return .none;
    const type_atom = core.atom.ids.type_;
    const object = core.value_semantics.objectFromValue(attributes) orelse return .none;
    const type_value = object.getOwnDataPropertyValue(type_atom) orelse return .none;
    if (!type_value.isString()) return .none;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(ctx.runtime.nativeAllocator());
    exec.value_ops.appendRawString(ctx.runtime, &buf, type_value) catch return .none;
    if (std.mem.eql(u8, buf.items, "json")) return .json;
    if (std.mem.eql(u8, buf.items, "text")) return .text;
    return .none;
}

pub const DynamicImportState = struct {
    runtime: *core.JSRuntime,
    output: ?*std.Io.Writer,
    io: std.Io,
    allocator: std.mem.Allocator,
    max_source_size: usize,
    continuations: ?*std.ArrayList(ModuleContinuation) = null,
    waiters: ?*std.ArrayList(ModuleEvaluationWaiter) = null,
    owned_continuations: std.ArrayList(ModuleContinuation) = .empty,
    owned_waiters: std.ArrayList(ModuleEvaluationWaiter) = .empty,
    /// Root scopes over whichever lists this state schedules through, held for
    /// the state's whole lifetime rather than only while jobs drain. A module
    /// that suspends on top-level await parks its continuation during
    /// evaluation, long before anything calls `runJobs`, and a collection in
    /// that window has no other way to see the generator object the
    /// continuation names.
    continuation_roots: ContinuationRoots = undefined,
    waiter_roots: WaiterRoots = undefined,
    roots_active: bool = false,
    /// Load-relevant import attribute (`type`) for the job currently being
    /// dispatched, set by dynamicImportJobCall before invoking the callback
    /// (jobs run one at a time on this thread, so a single slot suffices —
    /// mirrors qjs threading `attributes` through js_dynamic_import_job to
    /// js_module_loader, quickjs.c / quickjs-libc.c:703).
    pending_import_type: ImportLoaderType = .none,

    fn continuationList(self: *DynamicImportState) *std.ArrayList(ModuleContinuation) {
        return self.continuations orelse &self.owned_continuations;
    }

    fn waiterList(self: *DynamicImportState) *std.ArrayList(ModuleEvaluationWaiter) {
        return self.waiters orelse &self.owned_waiters;
    }

    /// Drain Promise/finalization/host jobs and module TLA resumptions through
    /// one QuickJS-style FIFO. Script-mode dynamic imports use the state-owned
    /// lists because they do not have an enclosing static module evaluator.
    pub fn runJobs(self: *DynamicImportState, facade_context: *core.JSContext) !void {
        try self.runtime.requireOwnerThread();
        std.debug.assert(facade_context.runtime == self.runtime);
        const checkpoint = &self.runtime.microtasks;
        if (checkpoint.reporting) return error.MicrotaskReentry;
        if (checkpoint.running or checkpoint.scope_depth != 0) return;
        checkpoint.running = true;
        defer checkpoint.running = false;
        try drainModuleJobLoop(
            self.runtime,
            facade_context,
            self.output,
            self.allocator,
            self.continuationList(),
        );
        self.runtime.clearWeakRefKeptAlive();
    }

    /// Announce the scheduling lists to the tracer. Called from
    /// `installDynamicImport`, which every construction site already goes
    /// through, and undone by `deinit`. External lists use these providers as
    /// their sole root owner while the loader scope is active.
    fn activateRoots(self: *DynamicImportState) !void {
        if (comptime !core.runtime.value_root_frames_enabled) return;
        if (self.roots_active) return;
        self.continuation_roots = .{ .runtime = self.runtime, .list = self.continuationList() };
        try self.continuation_roots.activate();
        errdefer self.continuation_roots.deactivate();
        self.waiter_roots = .{ .runtime = self.runtime, .list = self.waiterList() };
        try self.waiter_roots.activate();
        self.roots_active = true;
    }

    fn deactivateRoots(self: *DynamicImportState) void {
        if (comptime !core.runtime.value_root_frames_enabled) return;
        if (!self.roots_active) return;
        self.waiter_roots.deactivate();
        self.continuation_roots.deactivate();
        self.roots_active = false;
    }

    /// Release only state-owned scheduling data. Static module graph runners
    /// pass external lists whose lifetime they continue to manage themselves.
    pub fn deinit(self: *DynamicImportState) void {
        self.deactivateRoots();
        freeModuleContinuations(self.runtime, self.allocator, &self.owned_continuations);
        freeModuleEvaluationWaiters(self.runtime, self.allocator, &self.owned_waiters);
    }

    fn load(
        userdata: ?*anyopaque,
        ctx: *core.JSContext,
        output: ?*std.Io.Writer,
        global: *core.Object,
        referrer_path: []const u8,
        specifier: []const u8,
    ) core.context.DynamicImportError!core.JSValue {
        _ = global;
        const state: *DynamicImportState = @ptrCast(@alignCast(userdata orelse return error.ModuleNotFound));
        std.debug.assert(ctx.runtime == state.runtime);
        return evalDynamicImportModule(
            state,
            ctx,
            output,
            referrer_path,
            specifier,
            state.pending_import_type,
        ) catch |err| {
            // Any pending JS exception must reach the import() promise as-is
            // (js_dynamic_import_job quickjs.c: exception → reject).
            if (ctx.hasException()) return error.JSException;
            return err;
        };
    }
};
fn activeDynamicImportState(context: *core.JSContext) ?*DynamicImportState {
    const loader = context.runtime.getDynamicImportLoader();
    if (loader.callback != DynamicImportState.load) return null;
    const userdata = loader.userdata orelse return null;
    return @ptrCast(@alignCast(userdata));
}

fn createModuleEvaluationWaiter(
    state: *DynamicImportState,
    context: *core.JSContext,
    global: *core.Object,
    path: []const u8,
) !core.JSValue {
    std.debug.assert(context.runtime == state.runtime);
    const waiters = state.waiterList();
    const rt = state.runtime;
    const capability = try exec.promise_ops.internalPromiseCapability(
        context,
        global,
        exec.promise_ops.promisePrototypeFromGlobal(rt, global),
    );
    var promise = capability.promise;
    var resolve = capability.resolve;
    var reject = capability.reject;
    var root_frame = core.runtime.rootValues(.{ &promise, &resolve, &reject });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const owned_path = try state.allocator.dupe(u8, path);
    errdefer state.allocator.free(owned_path);
    var realm = core.RealmRef.retain(context);
    errdefer realm.deinit();
    try waiters.append(state.allocator, .{
        .realm = realm,
        .path = owned_path,
        .resolve = resolve,
        .reject = reject,
    });
    return promise;
}

fn settleModuleEvaluationWaiters(
    context: *core.JSContext,
    output: ?*std.Io.Writer,
    path: []const u8,
    rejected: bool,
    reason: ?core.JSValue,
) !void {
    const state = activeDynamicImportState(context) orelse return;
    const waiters = state.waiterList();
    const global = try exec.zjs_vm.contextGlobal(context);
    var namespace = core.JSValue.undefinedValue();
    if (!rejected) {
        const module_name = try state.runtime.internAtom(path);
        // TGC S3 §4 class B: bare module-name id held across module work.
        var module_name_roots = core.runtime.rootAtoms(.{&module_name});
        module_name_roots.activate(state.runtime);
        defer module_name_roots.deactivate(state.runtime);
        namespace = try exec.module.moduleNamespaceValue(context, module_name);
    }

    var index: usize = 0;
    while (index < waiters.items.len) {
        const waiter_context = waiters.items[index].realm.borrow().?;
        if (waiter_context != context or !std.mem.eql(u8, waiters.items[index].path, path)) {
            index += 1;
            continue;
        }
        const waiter = waiters.items[index];
        const callback = if (rejected) waiter.reject else waiter.resolve;
        const payload = if (rejected) reason orelse core.JSValue.undefinedValue() else namespace;
        _ = try exec.call_runtime.callValueOrBytecodeRoot(
            context,
            output,
            global,
            core.JSValue.undefinedValue(),
            callback,
            &.{payload},
            null,
            null,
        );
        var settled_waiter = waiters.orderedRemove(index);
        settled_waiter.deinit(state.runtime, state.allocator);
    }
}

fn takeRecordedModuleEvaluationRejection(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    path: []const u8,
) !?core.JSValue {
    const module_name = try runtime.internAtom(path);
    // TGC S3 §4 class B: bare module-name id held across module work.
    var module_name_roots = core.runtime.rootAtoms(.{&module_name});
    module_name_roots.activate(runtime);
    defer module_name_roots.deactivate(runtime);
    const record = context.modules.find(module_name) orelse return null;
    if (record.status != .errored) return null;
    if (context.hasException()) return context.takeException();
    if (record.eval_exception) |reason| return reason;
    return null;
}

fn moduleDependencyRejection(
    context: *core.JSContext,
    path: []const u8,
) !?core.JSValue {
    const runtime = context.runtime;
    const module_name = try runtime.internAtom(path);
    // TGC S3 §4 class B: bare module-name id held across module work.
    var module_name_roots = core.runtime.rootAtoms(.{&module_name});
    module_name_roots.activate(runtime);
    defer module_name_roots.deactivate(runtime);
    const record = context.modules.find(module_name) orelse return null;
    var visited = std.ArrayList(core.Atom).empty;
    defer visited.deinit(runtime.nativeAllocator());
    // TGC S3 §4 class B: `visited` is a native []Atom grown while walking.
    var visited_roots = core.runtime.rootAtomList(&visited.items);
    visited_roots.activate(runtime);
    defer visited_roots.deactivate(runtime);
    try visited.append(runtime.nativeAllocator(), module_name);
    return recordDependencyRejection(context, record, &visited);
}

fn recordDependencyRejection(
    context: *core.JSContext,
    record: *const core.module.ModuleRecord,
    visited: *std.ArrayList(core.Atom),
) !?core.JSValue {
    const runtime = context.runtime;
    for (record.requests) |request| {
        const dependency = request.module orelse continue;
        if (dependency.status == .errored) {
            if (dependency.eval_exception) |reason| return reason;
        }
        var already_visited = false;
        for (visited.items) |seen| {
            if (seen == request.module_name) {
                already_visited = true;
                break;
            }
        }
        if (already_visited) continue;
        try visited.append(runtime.nativeAllocator(), request.module_name);
        if (try recordDependencyRejection(context, dependency, visited)) |reason| return reason;
    }
    return null;
}

fn recordModuleEvaluationRejection(
    context: *core.JSContext,
    path: []const u8,
    reason: core.JSValue,
) !void {
    const runtime = context.runtime;
    const module_name = try runtime.internAtom(path);
    // TGC S3 §4 class B: bare module-name id held across module work.
    var module_name_roots = core.runtime.rootAtoms(.{&module_name});
    module_name_roots.activate(runtime);
    defer module_name_roots.deactivate(runtime);
    const record = context.modules.find(module_name) orelse return error.ModuleNotFound;
    record.status = .errored;
    if (record.eval_exception == null) record.setEvalException(runtime, reason);
}

pub fn createModuleAwaitReactionPromise(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    awaited: core.JSValue,
) !core.JSValue {
    const promise_constructor = try exec.promise_ops.promiseDefaultConstructor(context, global);
    var awaited_promise = try exec.promise_ops.promiseStaticCall(
        context,
        output,
        global,
        promise_constructor,
        &.{awaited},
        .resolve,
        null,
        null,
    );
    var reaction_promise = core.JSValue.undefinedValue();
    var resolve = core.JSValue.undefinedValue();
    var reject = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{ &awaited_promise, &reaction_promise, &resolve, &reject });
    root_frame.activate(runtime);
    defer root_frame.deactivate(runtime);

    const capability = try exec.promise_ops.internalPromiseCapability(
        context,
        global,
        exec.promise_ops.promisePrototypeFromGlobal(runtime, global),
    );
    reaction_promise = capability.promise;
    resolve = capability.resolve;
    reject = capability.reject;
    try exec.promise_ops.performPromiseThen(
        context,
        output,
        global,
        awaited_promise,
        resolve,
        reject,
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
    );
    return reaction_promise;
}

pub const DynamicImportHostState = struct {
    runtime: *core.JSRuntime,
    output: ?*std.Io.Writer,
    host_hooks: HostHooks,
    allocator: std.mem.Allocator,

    fn load(
        userdata: ?*anyopaque,
        ctx: *core.JSContext,
        output: ?*std.Io.Writer,
        global: *core.Object,
        referrer_path: []const u8,
        specifier: []const u8,
    ) core.context.DynamicImportError!core.JSValue {
        _ = global;
        const state: *DynamicImportHostState = @ptrCast(@alignCast(userdata orelse return error.ModuleNotFound));
        std.debug.assert(ctx.runtime == state.runtime);
        return evalDynamicImportModuleWithHostHooks(
            ctx.runtime,
            ctx,
            output orelse state.output,
            state.host_hooks,
            referrer_path,
            specifier,
            state.allocator,
        ) catch |err| {
            // Any pending JS exception must reach the import() promise as-is
            // (js_dynamic_import_job quickjs.c: exception → reject).
            if (ctx.hasException()) return error.JSException;
            return dynamicImportHostError(err);
        };
    }
};
pub fn evaluateImportCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    prototype: ?*core.Object,
    referrer_path: []const u8,
    specifier: core.JSValue,
    options: core.JSValue,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
) exec.exceptions.HostError!core.JSValue {
    // quickjs.c — `if (!JS_IsUndefined(options))`.
    var attributes = core.JSValue.undefinedValue();
    if (!options.is(.undefined_value)) {
        // quickjs.c — options must be an object.
        if (!options.is(.object)) {
            return rejectedImportTypeError(ctx, global, prototype, "options must be an object");
        }
        const with_atom = core.atom.ids.with;
        // quickjs.c — `attributes_obj = JS_GetProperty(options, "with")`.
        const attributes_obj = exec.object_ops.getValueProperty(ctx, output, global, options, with_atom, function, frame) catch |err|
            return rejectedImportRuntimeError(ctx, global, prototype, err);
        // quickjs.c — `if (!JS_IsUndefined(attributes_obj))`.
        if (!attributes_obj.is(.undefined_value)) {
            // quickjs.c — options.with must be an object.
            if (!attributes_obj.is(.object)) {
                return rejectedImportTypeError(ctx, global, prototype, "options.with must be an object");
            }
            attributes = buildImportAttributes(ctx, output, global, attributes_obj, function, frame) catch |err|
                return rejectedImportRuntimeError(ctx, global, prototype, err);
        }
    }

    return enqueueDynamicImportJobWithAttributes(ctx, global, prototype, referrer_path, specifier, attributes);
}

/// Mirror of qjs js_dynamic_import's attributes loop:
/// create a null-prototype attributes object; enumerate the source's own
/// enumerable string keys (JS_GetOwnPropertyNamesInternal with
/// JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY); Get each value; reject with a
/// TypeError if any value is not a String; otherwise copy
/// it onto the attributes object (JS_PROP_C_W_E). Returns the built
/// attributes object; the caller owns it. A thrown Get (or the proxy ownKeys
/// trap) propagates as a runtime error so the caller can reject.
fn buildImportAttributes(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    attributes_obj: core.JSValue,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
) exec.exceptions.HostError!core.JSValue {
    const rt = ctx.runtime;
    const source = try exec.property_ops.expectObject(attributes_obj);

    // quickjs.c — `attributes = JS_NewObjectProto(ctx, JS_NULL)`.
    const attributes_object = try core.Object.create(rt, core.class.ids.object, null);
    const attributes = attributes_object.value();

    // quickjs.c — JS_GetOwnPropertyNamesInternal(STRING_MASK|ENUM_ONLY).
    // The proxy ownKeys trap runs here; a throwing trap propagates (mirrors
    // IfAbruptRejectPromise on the keys list).
    const keys = try exec.object_ops.objectRestOwnKeys(ctx, output, global, source);
    defer core.Object.freeKeys(rt, keys);

    for (keys) |key| {
        // JS_GPN_STRING_MASK: only string keys (Symbols excluded).
        if (rt.atoms.kind(key) != .string) continue;
        // JS_GPN_ENUM_ONLY: only enumerable own properties.
        const desc = (try exec.object_ops.proxyAwareOwnPropertyDescriptor(ctx, output, global, source, key, function, frame)) orelse continue;
        const enumerable = desc.enumerable orelse false;
        if (!enumerable) continue;

        // quickjs.c — `val = JS_GetProperty(attributes_obj, key)`.
        const val = try exec.object_ops.getValueProperty(ctx, output, global, attributes_obj, key, function, frame);
        // quickjs.c — module attribute values must be strings.
        if (!val.isString()) {
            return exec.exception_ops.throwTypeErrorMessage(ctx, global, "module attribute values must be strings");
        }
        // quickjs.c — `JS_DefinePropertyValue(attributes, key, val, C_W_E)`.
        // Object.defineOwnProperty duplicates descriptor values; keep and
        // release the Get result instead of pretending ownership moved.
        try attributes_object.defineOwnProperty(rt, key, core.Descriptor.data(val, .all));
    }

    return attributes;
}

/// Reject the import() capability with a freshly-built TypeError (mirrors
/// js_dynamic_import's `exception:` label after JS_ThrowTypeError,
/// quickjs.c). Returns the pending-then-rejected promise value.
fn rejectedImportTypeError(
    ctx: *core.JSContext,
    global: *core.Object,
    prototype: ?*core.Object,
    message: []const u8,
) exec.exceptions.HostError!core.JSValue {
    const error_value = try exec.exception_ops.createNamedError(ctx, global, "TypeError", message);
    return core.promise.rejectedWithPrototype(ctx, error_value, prototype);
}

/// Reject the import() capability with the current pending JS exception (or a
/// mapped runtime error), mirroring js_dynamic_import's `exception:` label
/// (JS_GetException → JS_Call(reject), quickjs.c).
fn rejectedImportRuntimeError(
    ctx: *core.JSContext,
    global: *core.Object,
    prototype: ?*core.Object,
    err: exec.exceptions.HostError,
) exec.exceptions.HostError!core.JSValue {
    if (err == error.OutOfMemory or err == error.ProcessExit or err == error.StackOverflow) return err;
    return exec.exception_ops.rejectedPromiseForRuntimeError(ctx, global, err, prototype);
}

/// Mirror of qjs js_dynamic_import's job-enqueue tail: build
/// a promise capability, retain [resolve, reject, basename, specifier,
/// attributes] in a typed FIFO payload, and enqueue it on the runtime job queue
/// (JS_EnqueueJob quickjs.c — "cannot run JS_LoadModuleInternal
/// synchronously because it would cause an unexpected recursion in
/// js_evaluate_module()"). The returned pending promise is the value of the
/// import() expression; the module loads and evaluates only when the job
/// runs. Takes ownership of `attributes` (JS_UNDEFINED or a null-prototype
/// object of string values).
pub fn enqueueDynamicImportJob(
    ctx: *core.JSContext,
    global: *core.Object,
    prototype: ?*core.Object,
    referrer_path: []const u8,
    specifier: core.JSValue,
) !core.JSValue {
    return enqueueDynamicImportJobWithAttributes(ctx, global, prototype, referrer_path, specifier, core.JSValue.undefinedValue());
}

fn enqueueDynamicImportJobWithAttributes(
    ctx: *core.JSContext,
    global: *core.Object,
    prototype: ?*core.Object,
    referrer_path: []const u8,
    specifier: core.JSValue,
    attributes: core.JSValue,
) exec.exceptions.HostError!core.JSValue {
    const rt = ctx.runtime;
    var promise_value = core.JSValue.undefinedValue();
    var resolve_value = core.JSValue.undefinedValue();
    var reject_value = core.JSValue.undefinedValue();
    var specifier_value = specifier;
    var attributes_value = attributes;
    var basename_value = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{
        &promise_value,
        &resolve_value,
        &reject_value,
        &specifier_value,
        &attributes_value,
        &basename_value,
    });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const capability = try exec.promise_ops.internalPromiseCapability(ctx, global, prototype);
    promise_value = capability.promise;
    resolve_value = capability.resolve;
    reject_value = capability.reject;

    basename_value = try exec.value_ops.createStringValue(rt, referrer_path);

    try rt.job_queue.enqueueDynamicImport(
        ctx,
        dynamicImportJobRun,
        resolve_value,
        reject_value,
        basename_value,
        specifier_value,
        attributes_value,
    );
    return promise_value;
}

/// Mirror of qjs js_dynamic_import_job: run the module
/// loader and settle the import() capability — any failure (including a
/// pending JS exception) rejects the promise instead of aborting evaluation.
fn dynamicImportJobRun(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    payload: *const jobs_mod.DynamicImportPayload,
) core.errors.RuntimeError!core.JSValue {
    const rt = ctx.runtime;
    const global = ctx.global orelse return error.TypeError;
    const resolve_value = payload.resolve;
    const reject_value = payload.reject;
    const basename_value = payload.basename;
    const specifier_value = payload.specifier;
    const attributes_value = payload.attributes;

    var basename_bytes = std.ArrayList(u8).empty;
    defer basename_bytes.deinit(rt.nativeAllocator());
    try exec.value_ops.appendRawString(rt, &basename_bytes, basename_value);
    var specifier_bytes = std.ArrayList(u8).empty;
    defer specifier_bytes.deinit(rt.nativeAllocator());
    try exec.value_ops.appendRawString(rt, &specifier_bytes, specifier_value);

    // Thread the load-relevant `type` attribute to the file loader through the
    // installed DynamicImportState (mirrors qjs passing `attributes` into
    // js_dynamic_import_job → js_module_loader, quickjs.c /
    // quickjs-libc.c:703). Host-hook loaders resolve their own module kind and
    // ignore this. Jobs run one at a time on this thread, so restoring the
    // previous value keeps re-entrant graph drains correct.
    const import_type = importLoaderTypeFromAttributes(ctx, attributes_value);
    var restore_import_type: ?struct { state: *DynamicImportState, prev: ImportLoaderType } = null;
    const loader = rt.getDynamicImportLoader();
    if (loader.callback == DynamicImportState.load) {
        if (loader.userdata) |userdata| {
            const state: *DynamicImportState = @ptrCast(@alignCast(userdata));
            restore_import_type = .{ .state = state, .prev = state.pending_import_type };
            state.pending_import_type = import_type;
        }
    }
    defer if (restore_import_type) |r| {
        r.state.pending_import_type = r.prev;
    };

    const load_result: (core.context.DynamicImportError || error{OperationUnsupported})!core.JSValue = blk: {
        const callback = loader.callback orelse break :blk error.OperationUnsupported;
        break :blk callback(loader.userdata, ctx, output, global, basename_bytes.items, specifier_bytes.items);
    };

    if (load_result) |namespace| {
        if (namespace.is(.object)) {
            const object = try exec.property_ops.expectObject(namespace);
            if (object.class_id == core.class.ids.promise) {
                // A TLA module returns its shared evaluation promise. Chain the
                // import() capability instead of resolving it with the promise
                // object itself (ContinueDynamicImport → PerformPromiseThen).
                try exec.promise_ops.performPromiseThen(
                    ctx,
                    output,
                    global,
                    namespace,
                    resolve_value,
                    reject_value,
                    core.JSValue.undefinedValue(),
                    core.JSValue.undefinedValue(),
                );
                return core.JSValue.undefinedValue();
            }
        }
        _ = try exec.call_runtime.callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), resolve_value, &.{namespace}, null, null);
    } else |err| {
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ProcessExit => return error.ProcessExit,
            error.StackOverflow => return error.StackOverflow,
            else => {},
        }
        const reason = try dynamicImportRejectionValue(ctx, global, err, specifier_bytes.items);
        _ = try exec.call_runtime.callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), reject_value, &.{reason}, null, null);
    }
    return core.JSValue.undefinedValue();
}

/// Rejection reason for a failed dynamic import: the pending JS exception
/// verbatim when one exists (js_dynamic_import_job quickjs.c
/// JS_GetException → reject), otherwise the loader's ReferenceError shape
/// (js_module_loader quickjs-libc.c:699) or a generic mapped error.
fn dynamicImportRejectionValue(
    ctx: *core.JSContext,
    global: *core.Object,
    err: anyerror,
    specifier: []const u8,
) !core.JSValue {
    if (ctx.hasException()) return ctx.takeException();
    switch (err) {
        error.OperationUnsupported => return exec.exception_ops.createNamedError(ctx, global, "TypeError", "dynamic import is not supported"),
        error.ModuleNotFound, error.FileNotFound => {
            var msg_buf = std.ArrayList(u8).empty;
            defer msg_buf.deinit(ctx.runtime.nativeAllocator());
            try msg_buf.print(ctx.runtime.nativeAllocator(), "could not load module filename '{s}'", .{specifier});
            return exec.exception_ops.createNamedError(ctx, global, "ReferenceError", msg_buf.items);
        },
        else => {
            if (exec.exception_ops.runtimeErrorInfo(err)) |info| {
                return exec.exception_ops.createSentinelError(ctx, global, err, info);
            }
            return exec.exception_ops.createNamedError(ctx, global, "Error", @errorName(err));
        },
    }
}

/// Install the file-loader dynamic import callback on the state's Runtime.
/// The state must outlive every job drain that may run an import job (the
/// CLI keeps one alive for the whole process; the module-graph runners
/// install a scoped one and drain before restoring).
/// Pairs the installed loader with the state's root registration so the two
/// cannot get out of step. They did: activation used to happen in
/// `installDynamicImport` and deactivation only in `DynamicImportState.deinit`,
/// which the static graph evaluator never calls -- its lists are owned by the
/// caller -- so the provider outlived the stack frame holding the state and
/// the next collection walked a poisoned pointer.
pub const DynamicImportScope = struct {
    loader: core.runtime.DynamicImportLoaderScope,
    rooted_state: ?*DynamicImportState = null,

    pub fn deinit(self: *DynamicImportScope) void {
        self.loader.deinit();
        if (self.rooted_state) |state| state.deactivateRoots();
    }
};

/// Module execution owns dynamic-import loader installation. Keep the Runtime
/// callback slot as a low-level mechanism; production module loaders enter
/// through this helper so loader restoration and any required GC roots share
/// one scope type.
fn installDynamicImportCallback(
    runtime: *core.JSRuntime,
    callback: core.context.DynamicImportCallback,
    userdata: ?*anyopaque,
    rooted_state: ?*DynamicImportState,
) DynamicImportScope {
    return .{
        .rooted_state = rooted_state,
        .loader = runtime.installDynamicImportLoader(.{ .callback = callback, .userdata = userdata }),
    };
}

pub fn installDynamicImport(state: *DynamicImportState) !DynamicImportScope {
    try state.activateRoots();
    return installDynamicImportCallback(state.runtime, DynamicImportState.load, state, state);
}

pub fn installDynamicImportHost(state: *DynamicImportHostState) DynamicImportScope {
    return installDynamicImportCallback(state.runtime, DynamicImportHostState.load, state, null);
}

fn runJobs(runtime: *core.JSRuntime, context: *core.JSContext, output: ?*std.Io.Writer) !void {
    _ = runtime;
    const global_object = try @import("zjs_vm.zig").contextGlobal(context);
    try @import("zjs_vm.zig").drainPendingPromiseJobs(context, output, global_object);
}

pub fn evalFileModuleGraphWithOutput(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    source_text: []const u8,
    output: *std.Io.Writer,
    filename: []const u8,
    io: std.Io,
    allocator: std.mem.Allocator,
    max_source_size: usize,
) !core.JSValue {
    // Arm the native recursion guard at this outermost ES-module entry (analogue
    // of eval()'s JS_UpdateStackTop refresh) so module parse/exec on this thread
    // measures against a precise base. The construction-time baseline already
    // covers it; this tightens it for the running thread (test262 workers run on
    // a different C stack than where the runtime was constructed).
    if (context.runtime.call_depth == 0) runtime.updateNativeStackTop();
    const normalized_filename = try resolveModuleSource(context, allocator, null, filename, .entry);
    defer allocator.free(normalized_filename);

    var module_postorder = std.ArrayList([]const u8).empty;
    defer {
        for (module_postorder.items) |path| allocator.free(path);
        module_postorder.deinit(allocator);
    }
    try exec.module.preloadFileModuleGraphWithOrder(io, allocator, context, source_text, normalized_filename, max_source_size, &module_postorder);
    const root_module_name = try runtime.internAtom(normalized_filename);
    // TGC S3 §4 class B: bare module-name id held across module work.
    var root_module_name_roots = core.runtime.rootAtoms(.{&root_module_name});
    root_module_name_roots.activate(runtime);
    defer root_module_name_roots.deactivate(runtime);
    const root_record = context.modules.find(root_module_name) orelse return error.ModuleNotFound;
    root_record.import_meta_main = true;
    try initializeSyntheticFileModules(runtime, context, io, allocator, max_source_size);
    var link_diagnostic: exec.module.LinkDiagnostic = .{};
    exec.module.linkModule(context, root_record, &link_diagnostic) catch |err| {
        try throwModuleLinkError(runtime, context, normalized_filename, err, &link_diagnostic);
        return moduleResolutionError(err);
    };
    try rebuildPendingModuleEvalPostorder(
        context,
        allocator,
        root_module_name,
        &module_postorder,
    );
    var continuations = std.ArrayList(ModuleContinuation).empty;
    defer freeModuleContinuations(runtime, allocator, &continuations);
    var module_waiters = std.ArrayList(ModuleEvaluationWaiter).empty;
    defer freeModuleEvaluationWaiters(runtime, allocator, &module_waiters);
    var dynamic_import_state = DynamicImportState{
        .runtime = runtime,
        .output = output,
        .io = io,
        .allocator = allocator,
        .max_source_size = max_source_size,
        .continuations = &continuations,
        .waiters = &module_waiters,
    };
    var dynamic_import_scope = try installDynamicImport(&dynamic_import_state);
    defer dynamic_import_scope.deinit();
    for (module_postorder.items) |path| {
        if (std.mem.eql(u8, path, normalized_filename)) continue;
        if (!try preloadedModuleNeedsEvaluation(context, path)) continue;
        if (try hasActiveAsyncDependency(context, &continuations, path)) {
            try enqueueDeferredModuleStart(context, allocator, &continuations, path, false);
            continue;
        }
        const dep_step = try startPreloadedFileModuleStep(runtime, context, output, path);
        try appendModuleEvalStepRetainingOnError(context, allocator, &continuations, dep_step, path, false);
        if (context.hasUnhandledRejection() or context.hasException()) return error.UnhandledPromiseRejection;
    }
    var result = core.JSValue.undefinedValue();
    if (try preloadedModuleNeedsEvaluation(context, normalized_filename)) {
        if (try hasActiveAsyncDependency(context, &continuations, normalized_filename)) {
            try enqueueDeferredModuleStart(context, allocator, &continuations, normalized_filename, true);
        } else {
            const root_step = try startPreloadedFileModuleStep(runtime, context, output, normalized_filename);
            try appendModuleEvalStepRetainingOnError(context, allocator, &continuations, root_step, normalized_filename, true);
        }
        result = try drainModuleContinuations(runtime, context, output, allocator, &continuations);
    }
    // Dynamic-import jobs may add TLA continuations to the shared scheduler.
    // Alternate one queued reaction with one ready module resume until both
    // queues quiesce while the loader state is still alive.
    try drainModuleJobLoop(runtime, context, output, allocator, &continuations);
    return result;
}

/// Status gate shared by the postorder evaluation loops: modules already
/// evaluated (e.g. by a dynamic import job that ran between steps) or
/// currently evaluating are never re-run (mirrors js_inner_module_evaluation
/// quickjs.c).
fn preloadedModuleNeedsEvaluation(context: *core.JSContext, path: []const u8) !bool {
    const runtime = context.runtime;
    const module_name = try runtime.internAtom(path);
    // TGC S3 §4 class B: bare module-name id held across module work.
    var module_name_roots = core.runtime.rootAtoms(.{&module_name});
    module_name_roots.activate(runtime);
    defer module_name_roots.deactivate(runtime);
    const record = context.modules.find(module_name) orelse return true;
    return moduleNeedsEvaluation(record);
}

pub fn evalFileModuleGraphWithHostHooks(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    source_text: []const u8,
    output: *std.Io.Writer,
    filename: []const u8,
    host_hooks: HostHooks,
    allocator: std.mem.Allocator,
) !core.JSValue {
    std.debug.assert(context.runtime == runtime);
    var module_postorder = std.ArrayList([]const u8).empty;
    defer {
        for (module_postorder.items) |path| allocator.free(path);
        module_postorder.deinit(allocator);
    }
    try preloadFileModuleGraphWithHostHooks(allocator, runtime, context, host_hooks, source_text, filename, &module_postorder);

    const root_module_name = try runtime.internAtom(filename);
    // TGC S3 §4 class B: bare module-name id held across module work.
    var root_module_name_roots = core.runtime.rootAtoms(.{&root_module_name});
    root_module_name_roots.activate(runtime);
    defer root_module_name_roots.deactivate(runtime);
    const root_record = context.modules.find(root_module_name) orelse return error.ModuleNotFound;
    root_record.import_meta_main = true;
    var link_diagnostic: exec.module.LinkDiagnostic = .{};
    exec.module.linkModule(context, root_record, &link_diagnostic) catch |err| {
        try throwModuleLinkError(runtime, context, filename, err, &link_diagnostic);
        return moduleResolutionError(err);
    };
    try rebuildPendingModuleEvalPostorder(
        context,
        allocator,
        root_module_name,
        &module_postorder,
    );

    var dynamic_import_state = DynamicImportHostState{
        .runtime = runtime,
        .output = output,
        .host_hooks = host_hooks,
        .allocator = allocator,
    };
    var dynamic_import_scope = installDynamicImportHost(&dynamic_import_state);
    defer dynamic_import_scope.deinit();

    var continuations = std.ArrayList(ModuleContinuation).empty;
    defer freeModuleContinuations(runtime, allocator, &continuations);
    var continuation_roots = ContinuationRoots{ .runtime = runtime, .list = &continuations };
    try continuation_roots.activate();
    defer continuation_roots.deactivate();

    for (module_postorder.items) |path| {
        if (std.mem.eql(u8, path, filename)) continue;
        if (!try preloadedModuleNeedsEvaluation(context, path)) continue;

        if (try hasActiveAsyncDependency(context, &continuations, path)) {
            try enqueueDeferredModuleStart(context, allocator, &continuations, path, false);
            continue;
        }
        const dep_step = try startPreloadedFileModuleStep(runtime, context, output, path);
        try appendModuleEvalStepRetainingOnError(context, allocator, &continuations, dep_step, path, false);
        if (context.hasUnhandledRejection() or context.hasException()) return error.UnhandledPromiseRejection;
    }

    var result = core.JSValue.undefinedValue();
    if (try preloadedModuleNeedsEvaluation(context, filename)) {
        if (try hasActiveAsyncDependency(context, &continuations, filename)) {
            try enqueueDeferredModuleStart(context, allocator, &continuations, filename, true);
        } else {
            const root_step = try startPreloadedFileModuleStep(runtime, context, output, filename);
            try appendModuleEvalStepRetainingOnError(context, allocator, &continuations, root_step, filename, true);
        }
        result = try drainModuleContinuations(runtime, context, output, allocator, &continuations);
    }
    // Drain jobs enqueued by a synchronously-completing root (dynamic-import
    // jobs in particular) while this runner's dynamic-import state is still
    // installed and alive.
    try runJobs(runtime, context, output);
    return result;
}

fn initializeSyntheticFileModules(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    io: std.Io,
    allocator: std.mem.Allocator,
    max_source_size: usize,
) !void {
    const global_object = try exec.zjs_vm.contextGlobal(context);
    var modules = context.modules.iterator();
    while (modules.next()) |record| {
        if (record.synthetic_kind == .none) continue;
        const path = runtime.atoms.name(record.module_name) orelse return error.InvalidAtom;
        const source_path = exec.module.syntheticModuleFilePath(path);
        const module_source = readModuleSource(context, io, allocator, source_path, max_source_size) catch |err| switch (err) {
            error.FileNotFound => {
                try exec.module.throwCouldNotLoadModule(context, source_path);
                return error.JSException;
            },
            else => |load_error| {
                _ = try exec.exception_ops.throwHostError(
                    context,
                    global_object,
                    load_error,
                );
                unreachable;
            },
        };
        defer allocator.free(module_source);
        _ = try exec.module.initializeSyntheticFileModule(context, global_object, record.module_name, module_source);
    }
}

fn evalPreloadedFileModuleStep(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    output: ?*std.Io.Writer,
    filename: []const u8,
    continuation_value: ?core.JSValue,
    resume_value: ?core.JSValue,
) !ModuleEvalStep {
    var input_continuation = continuation_value;

    const module_name = try runtime.internAtom(filename);
    // TGC S3 §4 class B: bare module-name id held across module work.
    var module_name_roots = core.runtime.rootAtoms(.{&module_name});
    module_name_roots.activate(runtime);
    defer module_name_roots.deactivate(runtime);
    const record = context.modules.find(module_name) orelse return error.ModuleNotFound;
    if (record.synthetic_kind != .none) {
        // Synthetic records publish their retained default cell during
        // preload/initialization and have no bytecode function to run.
        if (input_continuation != null or resume_value != null)
            return error.InvalidBytecode;
        if (record.status != .linked) return error.ModuleLinkFailed;
        record.status = .evaluated;
        return .{ .completed = core.JSValue.undefinedValue() };
    }
    record.status = .evaluating;
    errdefer {
        if (record.status == .evaluating) {
            // Cache the evaluation exception on the record so later imports
            // rethrow it instead of re-running the body (mirrors qjs setting
            // m->eval_exception, quickjs.c).
            record.status = .errored;
            if (context.hasException()) {
                record.setEvalException(runtime, context.runtime.current_exception);
            }
        }
    }

    const owned_continuation = if (input_continuation) |value| blk: {
        input_continuation = null;
        break :blk value;
    } else blk: {
        const object = try core.Object.create(runtime, core.class.ids.generator, null);
        break :blk object.value();
    };
    const continuation = try exec.property_ops.expectObject(owned_continuation);
    const result = exec.module.runModuleEvaluationStep(
        context,
        record,
        output,
        continuation,
        resume_value,
    ) catch |err| return moduleResolutionError(err);
    if (continuation.generatorJustYielded() and !continuation.generatorDone()) {
        return .{ .suspended = .{
            .continuation = owned_continuation,
            .awaited = result,
        } };
    }
    record.status = .evaluated;
    return .{ .completed = result };
}

/// Start a module body only after every already-terminal dependency failure has
/// been copied onto this record. Postorder construction deliberately skips
/// records that no longer need evaluation, so the status gate alone cannot
/// distinguish an evaluated dependency from an errored one.
fn startPreloadedFileModuleStep(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    output: ?*std.Io.Writer,
    filename: []const u8,
) !ModuleEvalStep {
    if (try moduleDependencyRejection(context, filename)) |reason| {
        try recordModuleEvaluationRejection(context, filename, reason);
        _ = context.throwValue(reason);
        return error.JSException;
    }
    return evalPreloadedFileModuleStep(runtime, context, output, filename, null, null);
}

/// Append a freshly-produced evaluation step, transferring its JSValue
/// owners only after every fallible allocation succeeds. On error the caller
/// still owns `step`; drainOneModuleContinuation uses that guarantee to move a
/// post-resume step back into the removed FIFO slot instead of replaying or
/// losing the generator.
fn appendModuleEvalStepRetainingOnError(
    context: *core.JSContext,
    allocator: std.mem.Allocator,
    continuations: *std.ArrayList(ModuleContinuation),
    step: ModuleEvalStep,
    filename: []const u8,
    keep_result: bool,
) !void {
    switch (step) {
        .completed => |value| {
            if (keep_result) {
                const path_copy = try allocator.dupe(u8, filename);
                errdefer allocator.free(path_copy);
                var realm = core.RealmRef.retain(context);
                errdefer realm.deinit();
                const continuation = ModuleContinuation{
                    .realm = realm,
                    .path = path_copy,
                    .continuation = core.JSValue.undefinedValue(),
                    .awaited = value,
                    .keep_result = true,
                    .completed = true,
                };
                try array_list_erased.append(continuations, allocator, continuation);
            } else {}
        },
        .suspended => |suspended| {
            const path_copy = try allocator.dupe(u8, filename);
            errdefer allocator.free(path_copy);
            var realm = core.RealmRef.retain(context);
            errdefer realm.deinit();
            const continuation = ModuleContinuation{
                .realm = realm,
                .path = path_copy,
                .continuation = suspended.continuation,
                .awaited = suspended.awaited,
                .keep_result = keep_result,
            };
            try array_list_erased.append(continuations, allocator, continuation);
        },
    }
}

fn enqueueDeferredModuleStart(
    context: *core.JSContext,
    allocator: std.mem.Allocator,
    continuations: *std.ArrayList(ModuleContinuation),
    filename: []const u8,
    keep_result: bool,
) !void {
    const runtime = context.runtime;
    const module_name = try runtime.internAtom(filename);
    // TGC S3 §4 class B: bare module-name id held across module work.
    var module_name_roots = core.runtime.rootAtoms(.{&module_name});
    module_name_roots.activate(runtime);
    defer module_name_roots.deactivate(runtime);
    const module_record = context.modules.find(module_name) orelse return error.ModuleNotFound;
    const path_copy = try allocator.dupe(u8, filename);
    errdefer allocator.free(path_copy);
    var realm = core.RealmRef.retain(context);
    errdefer realm.deinit();
    const continuation = ModuleContinuation{
        .realm = realm,
        .path = path_copy,
        .continuation = core.JSValue.undefinedValue(),
        .awaited = core.JSValue.undefinedValue(),
        .keep_result = keep_result,
        .deferred_start = true,
    };
    try array_list_erased.append(continuations, allocator, continuation);
    module_record.status = .evaluating;
}

fn drainModuleContinuations(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    output: ?*std.Io.Writer,
    allocator: std.mem.Allocator,
    continuations: *std.ArrayList(ModuleContinuation),
) !core.JSValue {
    var kept_result: core.JSValue = core.JSValue.undefinedValue();
    var has_kept_result = false;
    while (continuations.items.len != 0) {
        switch (try drainOneScheduledModuleWork(runtime, output, allocator, continuations)) {
            .stalled => if (!try drainOneModuleHostEvent(context, output)) {
                _ = try exec.exception_ops.throwModuleHostStall(
                    context,
                    try exec.zjs_vm.contextGlobal(context),
                );
                unreachable;
            },
            .progressed => {},
            .value => |value| {
                kept_result = value;
                has_kept_result = true;
            },
        }
    }
    if (has_kept_result) return kept_result;
    return core.JSValue.undefinedValue();
}

fn drainModuleContinuationsForDependencies(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    output: ?*std.Io.Writer,
    allocator: std.mem.Allocator,
    continuations: *std.ArrayList(ModuleContinuation),
    filename: []const u8,
) !void {
    while (try hasActiveAsyncDependency(context, continuations, filename)) {
        switch (try drainOneScheduledModuleWork(runtime, output, allocator, continuations)) {
            .stalled => if (!try drainOneModuleHostEvent(context, output)) {
                _ = try exec.exception_ops.throwModuleHostStall(
                    context,
                    try exec.zjs_vm.contextGlobal(context),
                );
                unreachable;
            },
            .progressed => {},
            .value => {},
        }
    }
    if (try moduleDependencyRejection(context, filename)) |reason| {
        try recordModuleEvaluationRejection(context, filename, reason);
        _ = context.throwValue(reason);
        return error.JSException;
    }
}

fn drainModuleJobLoop(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    output: ?*std.Io.Writer,
    allocator: std.mem.Allocator,
    continuations: *std.ArrayList(ModuleContinuation),
) !void {
    while (true) {
        try jobs_mod.checkTermination(runtime);
        if (continuations.items.len != 0) {
            switch (try drainOneScheduledModuleWork(runtime, output, allocator, continuations)) {
                .stalled => {},
                .progressed => continue,
                .value => continue,
            }
        }

        if (try drainOneModuleQueuedOrHostJob(runtime, context, output)) continue;
        if (!runtime.microtasks.running) runtime.clearWeakRefKeptAlive();
        return;
    }
}

fn drainOneModuleQueuedOrHostJob(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    output: ?*std.Io.Writer,
) !bool {
    // This is a host/module scheduler boundary, not a microtask primitive.
    // Publish expired Atomics completions before timers can keep rescheduling.
    try exec.atomics_ops.processExpiredAtomicsWaiters(context);
    if (try runOneModuleMicrotask(runtime, output) != .empty) return true;
    return drainOneModuleHostEvent(context, output);
}

fn runOneModuleMicrotask(runtime: *core.JSRuntime, output: ?*std.Io.Writer) !jobs_mod.RunOneStatus {
    const previous_output = runtime.microtasks.output;
    runtime.microtasks.output = output;
    defer runtime.microtasks.output = previous_output;
    return jobs_mod.runCheckpointStep(runtime);
}

fn drainOneModuleHostEvent(context: *core.JSContext, output: ?*std.Io.Writer) !bool {
    const global = try exec.zjs_vm.contextGlobal(context);
    if (try exec.call_runtime.pollHostScheduler(context, output, global)) return true;
    return exec.atomics_ops.runNextAtomicsHostCompletion(context, false);
}

const ModuleDrainResult = union(enum) {
    stalled,
    progressed,
    value: core.JSValue,
};
fn prepareModuleContinuationAwait(
    runtime: *core.JSRuntime,
    output: ?*std.Io.Writer,
    continuations: *const std.ArrayList(ModuleContinuation),
    continuation: *ModuleContinuation,
) !void {
    const context = continuation.realm.borrow().?;
    std.debug.assert(context.runtime == runtime);
    if (continuation.completed or continuation.ready) return;
    if (continuation.deferred_start) {
        if (!try hasActiveAsyncDependency(context, continuations, continuation.path)) {
            // GatherAvailableAncestors executes newly-unblocked synchronous
            // parents in the current fulfillment job, before the next queued
            // Promise reaction.
            continuation.ready = true;
        }
        return;
    }
    const global_object = try exec.zjs_vm.contextGlobal(context);
    if (!continuation.awaited_normalized) {
        const reaction_promise = try createModuleAwaitReactionPromise(runtime, context, output, global_object, continuation.awaited);
        continuation.replaceAwaited(runtime, reaction_promise);
        continuation.awaited_normalized = true;
    }

    const promise = try exec.property_ops.expectObject(continuation.awaited);
    if (promise.class_id != core.class.ids.promise) return error.TypeError;
    if (promise.promiseResult() == null) return;
    if (promise.promiseIsRejected()) core.promise.markHandled(context, promise);
    // The internal reaction promise settles while its Promise reaction job is
    // running. Resume before the next queued job, exactly as QuickJS executes
    // the async-module continuation inside that reaction.
    continuation.ready = true;
}

fn nextReadyModuleContinuation(continuations: *const std.ArrayList(ModuleContinuation)) ?usize {
    for (continuations.items, 0..) |continuation, index| {
        if (continuation.completed) return index;
        if (continuation.ready) return index;
    }
    return null;
}

fn drainOneScheduledModuleWork(
    runtime: *core.JSRuntime,
    output: ?*std.Io.Writer,
    allocator: std.mem.Allocator,
    continuations: *std.ArrayList(ModuleContinuation),
) !ModuleDrainResult {
    try jobs_mod.checkTermination(runtime);
    // TLA resumptions alternate with the unified sequence one item at a time,
    // exactly like QuickJS promise-reaction jobs.
    for (continuations.items) |*continuation| {
        try prepareModuleContinuationAwait(runtime, output, continuations, continuation);
    }

    // `nextReadyModuleContinuation` already accepts both the completed and the
    // merely-ready continuation; both are drained the same way.
    if (nextReadyModuleContinuation(continuations)) |index| {
        if (try drainOneModuleContinuation(runtime, output, allocator, continuations, index)) |value| {
            return .{ .value = value };
        }
        return .progressed;
    }

    if (try runOneModuleMicrotask(runtime, output) != .empty) return .progressed;
    return .stalled;
}

/// Reuse a removed continuation's path allocation for a step that must remain
/// retryable. The list still has capacity for the removed element, so
/// reinsertion at the original index cannot fail and preserves FIFO order.
/// If symbol-root registration ever becomes fallible again, the node is
/// already owned by the list before that error escapes.
fn reinsertRemovedModuleStep(
    _: *core.JSRuntime,
    continuations: *std.ArrayList(ModuleContinuation),
    index: usize,
    current: ModuleContinuation,
    step: ModuleEvalStep,
    completion_rejected: bool,
) !void {
    var replacement = current;
    replacement.completed = switch (step) {
        .completed => true,
        .suspended => false,
    };
    replacement.settle_waiters = replacement.completed;
    replacement.completion_rejected = completion_rejected;
    replacement.deferred_start = false;
    replacement.awaited_normalized = false;
    replacement.ready = false;
    switch (step) {
        .completed => |value| {
            replacement.continuation = core.JSValue.undefinedValue();
            replacement.awaited = value;
        },
        .suspended => |suspended| {
            replacement.continuation = suspended.continuation;
            replacement.awaited = suspended.awaited;
        },
    }

    continuations.insertAssumeCapacity(index, replacement);
}

/// Transfer a step produced after a continuation was removed. A suspended step
/// normally gets a fresh path copy. If that late scheduling work fails,
/// ownership moves into the old allocation and the node is restored in place
/// before the error escapes. Completed steps always become terminal nodes so
/// dynamic-import waiters can be settled transactionally on retry.
fn retainRemovedModuleStep(
    runtime: *core.JSRuntime,
    allocator: std.mem.Allocator,
    continuations: *std.ArrayList(ModuleContinuation),
    index: usize,
    current: ModuleContinuation,
    step: ModuleEvalStep,
    completion_rejected: bool,
) !void {
    switch (step) {
        .completed => return reinsertRemovedModuleStep(
            runtime,
            continuations,
            index,
            current,
            step,
            completion_rejected,
        ),
        .suspended => {},
    }

    appendModuleEvalStepRetainingOnError(
        current.realm.borrow().?,
        allocator,
        continuations,
        step,
        current.path,
        current.keep_result,
    ) catch |err| {
        reinsertRemovedModuleStep(
            runtime,
            continuations,
            index,
            current,
            step,
            completion_rejected,
        ) catch |reinsert_err| return reinsert_err;
        return err;
    };

    // appendModuleEvalStepRetainingOnError transferred `step` to the tail.
    // Move that node back to the removed slot without allocating, then release
    // the superseded path and settled await owners.
    var superseded = current;
    allocator.free(superseded.path);
    superseded.realm.deinit();
    const appended = continuations.orderedRemove(continuations.items.len - 1);
    continuations.insertAssumeCapacity(index, appended);
}

fn drainOneModuleContinuation(
    runtime: *core.JSRuntime,
    output: ?*std.Io.Writer,
    allocator: std.mem.Allocator,
    continuations: *std.ArrayList(ModuleContinuation),
    index: usize,
) !?core.JSValue {
    var current = continuations.orderedRemove(index);
    // Taking the entry out of the list takes it out of `ContinuationRoots`'
    // view: from here until it is reinserted or consumed, its continuation and
    // awaited promise live only in this frame. The resumed evaluation enters
    // `runWithCallEnv`'s interrupt/GC poll before publishing ActiveInvocation,
    // so scalar stack capture cannot be replaced by the list provider alone.
    // Publish the pair as one native window; production trace intentionally
    // erases scalar ValueRootScopes.
    var current_root_values = [_]core.JSValue{ current.continuation, current.awaited };
    var current_root_slices = [_]core.runtime.ValueRootSlice{.{ .borrowed = &current_root_values }};
    var current_root_frame = core.runtime.ValueRootFrame{ .slices = &current_root_slices };
    current_root_frame.activate(runtime);
    defer current_root_frame.deactivate(runtime);
    var restore_current = true;
    // On errors, restore list ownership before the root window is unlinked.
    errdefer if (restore_current) continuations.insertAssumeCapacity(index, current);
    const context = current.realm.borrow().?;
    std.debug.assert(context.runtime == runtime);

    if (current.completed) {
        if (current.settle_waiters) {
            try settleModuleEvaluationWaiters(
                context,
                output,
                current.path,
                current.completion_rejected,
                if (current.completion_rejected) current.awaited else null,
            );
            current.settle_waiters = false;
        }
        restore_current = false;
        allocator.free(current.path);
        if (current.completion_rejected) {
            if (current.keep_result) {
                const reason = current.awaited;
                _ = context.throwValue(reason);
                current.realm.deinit();
                return error.JSException;
            }
            current.realm.deinit();
            return null;
        }
        if (current.keep_result) {
            current.realm.deinit();
            return current.awaited;
        }
        current.realm.deinit();
        return null;
    }

    if (current.deferred_start) {
        const step = startPreloadedFileModuleStep(runtime, context, output, current.path) catch |err| {
            if (err == error.OutOfMemory or err == error.ProcessExit) return err;
            if (try takeRecordedModuleEvaluationRejection(runtime, context, current.path)) |reason| {
                restore_current = false;
                try retainRemovedModuleStep(
                    runtime,
                    allocator,
                    continuations,
                    index,
                    current,
                    .{ .completed = reason },
                    true,
                );
                return null;
            }
            return err;
        };
        restore_current = false;
        try retainRemovedModuleStep(runtime, allocator, continuations, index, current, step, false);
        return null;
    }

    const awaited_promise = current.awaited;
    const continuation = current.continuation;
    const promise = try exec.property_ops.expectObject(awaited_promise);
    if (promise.class_id != core.class.ids.promise) return error.TypeError;
    const resume_value = if (promise.promiseResult()) |stored| stored else {
        _ = try exec.exception_ops.throwModuleHostStall(
            context,
            try exec.zjs_vm.contextGlobal(context),
        );
        unreachable;
    };
    const continuation_object = try exec.property_ops.expectObject(continuation);
    exec.call_runtime.setGeneratorResumeCompletion(continuation_object, if (promise.promiseIsRejected()) .throw else .next);
    const step = evalPreloadedFileModuleStep(
        runtime,
        context,
        output,
        current.path,
        continuation,
        resume_value,
    ) catch |err| {
        if (err == error.OutOfMemory or err == error.ProcessExit) return err;
        if (try takeRecordedModuleEvaluationRejection(runtime, context, current.path)) |reason| {
            restore_current = false;
            try retainRemovedModuleStep(
                runtime,
                allocator,
                continuations,
                index,
                current,
                .{ .completed = reason },
                true,
            );
            return null;
        }
        return err;
    };

    restore_current = false;
    try retainRemovedModuleStep(runtime, allocator, continuations, index, current, step, false);
    if (context.hasUnhandledRejection() or context.hasException()) return error.UnhandledPromiseRejection;
    return null;
}

fn hasActiveAsyncDependency(
    context: *core.JSContext,
    continuations: *const std.ArrayList(ModuleContinuation),
    filename: []const u8,
) !bool {
    const runtime = context.runtime;
    const module_name = try runtime.internAtom(filename);
    // TGC S3 §4 class B: bare module-name id held across module work.
    var module_name_roots = core.runtime.rootAtoms(.{&module_name});
    module_name_roots.activate(runtime);
    defer module_name_roots.deactivate(runtime);
    const record = context.modules.find(module_name) orelse return false;
    var visited = std.ArrayList(core.Atom).empty;
    defer visited.deinit(runtime.nativeAllocator());
    // TGC S3 §4 class B: `visited` is a native []Atom grown while walking.
    var visited_roots = core.runtime.rootAtomList(&visited.items);
    visited_roots.activate(runtime);
    defer visited_roots.deactivate(runtime);
    return recordHasActiveAsyncDependency(context, continuations, record, filename, &visited);
}

fn recordHasActiveAsyncDependency(
    context: *core.JSContext,
    continuations: *const std.ArrayList(ModuleContinuation),
    record: *const core.module.ModuleRecord,
    ignored_path: []const u8,
    visited: *std.ArrayList(core.Atom),
) !bool {
    const runtime = context.runtime;
    for (visited.items) |seen| {
        if (seen == record.module_name) return false;
    }
    try visited.append(runtime.nativeAllocator(), record.module_name);
    for (record.requests) |request| {
        const request_name = runtime.atoms.name(request.module_name) orelse continue;
        for (continuations.items) |continuation| {
            if (continuation.realm.borrow() != context) continue;
            if (std.mem.eql(u8, continuation.path, ignored_path)) continue;
            if (!continuation.completed and std.mem.eql(u8, continuation.path, request_name)) return true;
        }
        const requested_record = request.module orelse continue;
        if (try recordHasActiveAsyncDependency(context, continuations, requested_record, ignored_path, visited)) return true;
    }
    return false;
}

fn freeModuleContinuations(
    _: *core.JSRuntime,
    allocator: std.mem.Allocator,
    continuations: *std.ArrayList(ModuleContinuation),
) void {
    for (continuations.items) |*item| {
        allocator.free(item.path);
        item.realm.deinit();
    }
    continuations.deinit(allocator);
}

fn freeModuleEvaluationWaiters(
    runtime: *core.JSRuntime,
    allocator: std.mem.Allocator,
    waiters: *std.ArrayList(ModuleEvaluationWaiter),
) void {
    for (waiters.items) |*waiter| waiter.deinit(runtime, allocator);
    waiters.deinit(allocator);
}

pub fn moduleResolutionError(err: anytype) (@TypeOf(err) || error{SyntaxError}) {
    return switch (err) {
        error.MissingExport, error.AmbiguousExport => error.SyntaxError,
        else => err,
    };
}

fn evalDynamicImportModule(
    state: *DynamicImportState,
    context: *core.JSContext,
    output: ?*std.Io.Writer,
    referrer_path: []const u8,
    specifier: []const u8,
    import_type: ImportLoaderType,
) !core.JSValue {
    const runtime = state.runtime;
    std.debug.assert(context.runtime == runtime);
    const io = state.io;
    const allocator = state.allocator;
    const max_source_size = state.max_source_size;
    if (referrer_path.len == 0) {
        try exec.module.throwCouldNotLoadModule(context, specifier);
        return error.JSException;
    }
    // An unresolvable specifier rejects the import() promise with the
    // loader's ReferenceError (mirrors js_module_loader quickjs-libc.c:699)
    // instead of aborting the evaluation with a host error.
    const target_path_base = resolveModuleSource(context, allocator, referrer_path, specifier, .dynamic_import) catch |err| switch (err) {
        error.ModuleNotFound => {
            try exec.module.throwCouldNotLoadModule(context, specifier);
            return error.JSException;
        },
        else => |e| return e,
    };
    defer allocator.free(target_path_base);

    // A `.json` target — or one tagged `with { type: 'json' }` — loads as a
    // JSON module. Attribute `type: 'text'` selects the corresponding
    // synthetic text module even when the file suffix is `.json`; otherwise
    // unknown/absent types retain ordinary ESM loading. The registry name is
    // shared with attribute-tagged static imports so both forms resolve to
    // one module record.
    const source_loader = context.module_source_loader orelse return error.ModuleNotFound;
    const synthetic_kind = source_loader.syntheticKind(source_loader.ptr, target_path_base, switch (import_type) {
        .none => null,
        .json => "json",
        .text => "text",
    });
    const is_synthetic = synthetic_kind != null;
    const target_path = if (synthetic_kind) |kind|
        try exec.module.syntheticModuleRegistryName(allocator, target_path_base, kind)
    else
        try allocator.dupe(u8, target_path_base);
    defer allocator.free(target_path);

    const module_name = try runtime.internAtom(target_path);
    // TGC S3 §4 class B: bare module-name id held across module work.
    var module_name_roots = core.runtime.rootAtoms(.{&module_name});
    module_name_roots.activate(runtime);
    defer module_name_roots.deactivate(runtime);

    var preload_postorder = std.ArrayList([]const u8).empty;
    defer {
        for (preload_postorder.items) |item| allocator.free(item);
        preload_postorder.deinit(allocator);
    }
    if (context.modules.find(module_name) == null) {
        if (!is_synthetic) {
            const source = readModuleSource(context, io, allocator, target_path, max_source_size) catch |err| switch (err) {
                error.FileNotFound => {
                    try exec.module.throwCouldNotLoadModule(context, target_path);
                    return error.JSException;
                },
                else => |load_error| {
                    if (load_error == error.OutOfMemory) return error.OutOfMemory;
                    const global = try exec.zjs_vm.contextGlobal(context);
                    const reason = try exec.exception_ops.hostErrorValue(context, global, load_error);
                    _ = context.throwValue(reason);
                    return error.JSException;
                },
            };
            defer allocator.free(source);
            // skip-existing preload: records already in the registry keep
            // their live bindings and status (re-instantiating them would
            // reset already-evaluated modules).
            try exec.module.preloadMissingFileModuleGraphWithOrder(io, allocator, context, source, target_path, max_source_size, &preload_postorder);
        } else {
            try exec.module.preloadSyntheticFileModule(context, target_path, synthetic_kind.?);
        }
    }

    // Evaluate-once via the module status machine (mirrors
    // js_inner_module_evaluation quickjs.c): an errored module
    // rethrows its cached exception (before relinking — linking artifacts of
    // an errored record must stay untouched); evaluating/evaluated modules
    // never re-run their body.
    if (context.modules.find(module_name)) |record| {
        if (record.status == .errored) return throwCachedModuleEvalException(runtime, context, record);
        if (record.status == .evaluated) return exec.module.moduleNamespaceValue(context, module_name);
        if (record.status == .evaluating) {
            const global = try exec.zjs_vm.contextGlobal(context);
            return createModuleEvaluationWaiter(state, context, global, target_path);
        }
    } else return error.ModuleNotFound;

    // Synthetic records have no bytecode function. Publish their indexed
    // default cell before linking so ordinary import wiring sees the same
    // retained export-cell authority as source modules.
    if (is_synthetic) {
        const source_path = exec.module.syntheticModuleFilePath(target_path);
        const module_source = readModuleSource(context, io, allocator, source_path, max_source_size) catch |err| switch (err) {
            error.FileNotFound => {
                try exec.module.throwCouldNotLoadModule(context, target_path_base);
                return error.JSException;
            },
            else => |load_error| {
                if (load_error == error.OutOfMemory) return error.OutOfMemory;
                const global = try exec.zjs_vm.contextGlobal(context);
                const reason = try exec.exception_ops.hostErrorValue(context, global, load_error);
                _ = context.throwValue(reason);
                return error.JSException;
            },
        };
        defer allocator.free(module_source);
        const global_object = try exec.zjs_vm.contextGlobal(context);
        _ = try exec.module.initializeSyntheticFileModule(context, global_object, module_name, module_source);
    } else {
        try initializeSyntheticFileModules(runtime, context, io, allocator, max_source_size);
    }

    const target_record = context.modules.find(module_name) orelse return error.ModuleNotFound;
    var link_diagnostic: exec.module.LinkDiagnostic = .{};
    exec.module.linkModule(context, target_record, &link_diagnostic) catch |err| {
        try throwModuleLinkError(runtime, context, target_path_base, err, &link_diagnostic);
        return error.JSException;
    };

    var postorder = std.ArrayList([]const u8).empty;
    defer {
        for (postorder.items) |path| allocator.free(path);
        postorder.deinit(allocator);
    }
    var seen = std.ArrayList(core.Atom).empty;
    defer seen.deinit(allocator);
    try appendPendingModuleEvalPostorder(context, allocator, module_name, &seen, &postorder);

    const continuations = state.continuationList();

    for (postorder.items) |path| {
        const module_atom = try runtime.internAtom(path);
        // TGC S3 §4 class B: bare module-name id held across module work.
        var module_atom_roots = core.runtime.rootAtoms(.{&module_atom});
        module_atom_roots.activate(runtime);
        defer module_atom_roots.deactivate(runtime);
        const record = context.modules.find(module_atom) orelse return error.ModuleNotFound;
        if (record.synthetic_kind != .none) {
            // Synthetic file-module records carry no code; their default
            // binding was initialized before linking.
            record.status = .evaluated;
            continue;
        }
        if (!moduleNeedsEvaluation(record)) continue;

        if (try hasActiveAsyncDependency(context, continuations, path)) {
            try enqueueDeferredModuleStart(context, allocator, continuations, path, false);
            continue;
        }
        const step = try startPreloadedFileModuleStep(runtime, context, output, path);
        try appendModuleEvalStepRetainingOnError(context, allocator, continuations, step, path, false);
        if (context.hasException()) return error.JSException;
    }

    if (context.modules.find(module_name)) |record| {
        if (record.status == .errored) return throwCachedModuleEvalException(runtime, context, record);
        if (record.status != .evaluated) {
            const global = try exec.zjs_vm.contextGlobal(context);
            return createModuleEvaluationWaiter(state, context, global, target_path);
        }
    }
    return exec.module.moduleNamespaceValue(context, module_name);
}

/// Rethrow a module's cached evaluation exception (mirrors
/// js_inner_module_evaluation quickjs.c: `JS_DupValue(ctx,
/// m->eval_exception)` for an evaluated module with eval_has_exception).
fn throwCachedModuleEvalException(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    record: *core.module.ModuleRecord,
) error{JSException} {
    _ = runtime;
    if (record.eval_exception) |exception| {
        _ = context.throwValue(exception);
    }
    return error.JSException;
}
pub fn throwModuleLinkError(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    filename: []const u8,
    err: anyerror,
    diagnostic: ?*const exec.module.LinkDiagnostic,
) !void {
    const global_object = try exec.zjs_vm.contextGlobal(context);
    var msg_buf = std.ArrayList(u8).empty;
    defer msg_buf.deinit(runtime.nativeAllocator());
    var formatted_diagnostic = false;
    if (diagnostic) |info| if (info.kind) |kind| {
        const export_name = runtime.atoms.name(info.export_name) orelse "";
        const in_module = runtime.atoms.name(info.module_name) orelse "";
        switch (kind) {
            .missing_export => try msg_buf.print(runtime.nativeAllocator(), "Could not find export '{s}' in module '{s}'", .{ export_name, in_module }),
            .ambiguous_export => try msg_buf.print(runtime.nativeAllocator(), "export '{s}' in module '{s}' is ambiguous", .{ export_name, in_module }),
        }
        formatted_diagnostic = true;
    };
    if (!formatted_diagnostic) {
        try msg_buf.print(runtime.nativeAllocator(), "could not link module '{s}': {s}", .{ filename, @errorName(err) });
    }
    const error_val = try exception_ops.createNamedError(context, global_object, "SyntaxError", msg_buf.items);
    _ = context.throwValue(error_val);
}

fn evalDynamicImportModuleWithHostHooks(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    output: ?*std.Io.Writer,
    host_hooks: HostHooks,
    referrer_path: []const u8,
    specifier: []const u8,
    allocator: std.mem.Allocator,
) !core.JSValue {
    if (referrer_path.len == 0) return error.ModuleNotFound;

    const resolved = try host_hooks.resolveModule(host_hooks.ptr, specifier, referrer_path, allocator);
    defer allocator.free(resolved.specifier);
    defer allocator.free(resolved.path);

    const resolved_atom = try runtime.internAtom(resolved.path);
    // TGC S3 §4 class B: bare module-name id held across module work.
    var resolved_atom_roots = core.runtime.rootAtoms(.{&resolved_atom});
    resolved_atom_roots.activate(runtime);
    defer resolved_atom_roots.deactivate(runtime);

    const needs_preload = if (context.modules.find(resolved_atom)) |record|
        !record.requestsResolved()
    else
        true;
    if (needs_preload) {
        const loaded = try host_hooks.loadModule(host_hooks.ptr, resolved, allocator);
        defer if (loaded.owned) allocator.free(loaded.source);
        defer allocator.free(loaded.path);

        var module_source_allocated = false;
        const module_source = try wrapSourceByKind(allocator, loaded.kind, loaded.source, resolved.path, &module_source_allocated);
        defer if (module_source_allocated) allocator.free(module_source);

        var preload_postorder = std.ArrayList([]const u8).empty;
        defer {
            for (preload_postorder.items) |path| allocator.free(path);
            preload_postorder.deinit(allocator);
        }
        try preloadFileModuleGraphWithHostHooks(allocator, runtime, context, host_hooks, module_source, resolved.path, &preload_postorder);
    }

    const resolved_record = context.modules.find(resolved_atom) orelse return error.ModuleNotFound;
    var link_diagnostic: exec.module.LinkDiagnostic = .{};
    exec.module.linkModule(context, resolved_record, &link_diagnostic) catch |err| {
        try throwModuleLinkError(runtime, context, resolved.path, err, &link_diagnostic);
        return moduleResolutionError(err);
    };

    var postorder = std.ArrayList([]const u8).empty;
    defer {
        for (postorder.items) |path| allocator.free(path);
        postorder.deinit(allocator);
    }
    var seen = std.ArrayList(core.Atom).empty;
    defer seen.deinit(allocator);
    try appendPendingModuleEvalPostorder(context, allocator, resolved_atom, &seen, &postorder);

    var continuations = std.ArrayList(ModuleContinuation).empty;
    defer freeModuleContinuations(runtime, allocator, &continuations);
    var continuation_roots = ContinuationRoots{ .runtime = runtime, .list = &continuations };
    try continuation_roots.activate();
    defer continuation_roots.deactivate();

    for (postorder.items) |path| {
        const module_atom = try runtime.internAtom(path);
        // TGC S3 §4 class B: bare module-name id held across module work.
        var module_atom_roots = core.runtime.rootAtoms(.{&module_atom});
        module_atom_roots.activate(runtime);
        defer module_atom_roots.deactivate(runtime);
        const record = context.modules.find(module_atom) orelse return error.ModuleNotFound;
        if (!moduleNeedsEvaluation(record)) continue;

        try drainModuleContinuationsForDependencies(runtime, context, output, allocator, &continuations, path);

        const step = try startPreloadedFileModuleStep(runtime, context, output, path);
        try appendModuleEvalStepRetainingOnError(context, allocator, &continuations, step, path, false);
        if (context.hasUnhandledRejection() or context.hasException()) return error.UnhandledPromiseRejection;
    }

    _ = try drainModuleContinuations(runtime, context, output, allocator, &continuations);
    return exec.module.moduleNamespaceValue(context, resolved_atom);
}

fn moduleNeedsEvaluation(record: *const core.module.ModuleRecord) bool {
    return switch (record.status) {
        .unlinked, .linked => true,
        .linking, .evaluating, .evaluated, .errored => false,
    };
}

fn dynamicImportHostError(err: anyerror) core.context.DynamicImportError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.AccessDenied => error.AccessDenied,
        error.PermissionDenied => error.PermissionDenied,
        error.ProcessExit => error.ProcessExit,
        error.SyntaxError => error.SyntaxError,
        error.ReferenceError => error.ReferenceError,
        error.TypeError => error.TypeError,
        error.UnhandledPromiseRejection => error.UnhandledPromiseRejection,
        error.ModuleNotFound, error.FileNotFound, error.Unsupported, error.UnsupportedBarePackage, error.PackageSubpathNotFound => error.ModuleNotFound,
        else => error.Unexpected,
    };
}

fn appendPendingModuleEvalPostorder(
    context: *core.JSContext,
    allocator: std.mem.Allocator,
    module_name: core.Atom,
    seen: *std.ArrayList(core.Atom),
    postorder: *std.ArrayList([]const u8),
) !void {
    const runtime = context.runtime;
    for (seen.items) |existing| {
        if (existing == module_name) return;
    }
    try seen.append(allocator, module_name);

    const record = context.modules.find(module_name) orelse return error.ModuleNotFound;
    for (record.requests) |request| {
        try appendPendingModuleEvalPostorder(context, allocator, request.module_name, seen, postorder);
    }

    const refreshed = context.modules.find(module_name) orelse return error.ModuleNotFound;
    if (!moduleNeedsEvaluation(refreshed)) return;

    const path = runtime.atoms.name(module_name) orelse return error.InvalidAtom;
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    try array_list_erased.append(postorder, allocator, owned_path);
}

fn rebuildPendingModuleEvalPostorder(
    context: *core.JSContext,
    allocator: std.mem.Allocator,
    root_module_name: core.Atom,
    postorder: *std.ArrayList([]const u8),
) !void {
    for (postorder.items) |path| allocator.free(path);
    postorder.clearRetainingCapacity();

    var seen = std.ArrayList(core.Atom).empty;
    defer seen.deinit(allocator);
    try appendPendingModuleEvalPostorder(
        context,
        allocator,
        root_module_name,
        &seen,
        postorder,
    );
}

/// Skipping already-loaded modules is not a caller-selectable mode: it falls
/// out of the "record with resolved requests returns early" check in
/// `preloadFileModuleGraphWithHostHooksInner`, so every entry point behaves the
/// same way.
fn preloadFileModuleGraphWithHostHooks(
    allocator: std.mem.Allocator,
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    host_hooks: HostHooks,
    root_source: []const u8,
    root_path: []const u8,
    postorder: *std.ArrayList([]const u8),
) !void {
    var seen = std.ArrayList([]const u8).empty;
    defer {
        for (seen.items) |path| allocator.free(path);
        seen.deinit(allocator);
    }
    try preloadFileModuleGraphWithHostHooksInner(
        allocator,
        runtime,
        context,
        host_hooks,
        root_source,
        root_path,
        &seen,
        postorder,
    );
}

fn trackedPathContains(paths: *const std.ArrayList([]const u8), path: []const u8) bool {
    for (paths.items) |existing| {
        if (std.mem.eql(u8, existing, path)) return true;
    }
    return false;
}

fn validateHostResolvedRecord(
    context: *core.JSContext,
    record: *core.module.ModuleRecord,
    module_name: core.Atom,
    resolved_atoms: []const core.Atom,
) !void {
    if (record.registry != &context.modules) return error.ForeignModuleRecord;
    if (record.module_name != module_name) return error.InvalidBytecode;
    if (record.requests.len != resolved_atoms.len) return error.InvalidBytecode;
    for (record.requests, resolved_atoms) |request, resolved_atom| {
        if (request.module_name != resolved_atom) return error.InvalidBytecode;
    }
}

fn validateHostRequestDependency(
    context: *core.JSContext,
    record: *core.module.ModuleRecord,
    request_index: usize,
) !void {
    const request = &record.requests[request_index];
    const dependency = request.module orelse return error.ModuleNotFound;
    if (dependency.registry != &context.modules) return error.ForeignModuleRecord;
    if (dependency.module_name != request.module_name) return error.InvalidBytecode;
    const canonical = context.modules.find(request.module_name) orelse
        return error.ModuleNotFound;
    if (canonical != dependency) return error.ForeignModuleRecord;
}

fn preloadFileModuleGraphWithHostHooksInner(
    allocator: std.mem.Allocator,
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    host_hooks: HostHooks,
    source_text: []const u8,
    path: []const u8,
    seen: *std.ArrayList([]const u8),
    postorder: *std.ArrayList([]const u8),
) !void {
    if (trackedPathContains(seen, path)) return;
    const owned_path = try allocator.dupe(u8, path);
    var seen_owns_path = false;
    errdefer if (!seen_owns_path) allocator.free(owned_path);
    try array_list_erased.append(seen, allocator, owned_path);
    seen_owns_path = true;

    const module_name = try runtime.internAtom(path);
    // TGC S3 §4 class B: bare module-name id held across module work.
    var module_name_roots = core.runtime.rootAtoms(.{&module_name});
    module_name_roots.activate(runtime);
    defer module_name_roots.deactivate(runtime);
    // Successfully completed records are load-once. An incomplete record is a
    // stable, recoverable publication from an earlier failed/re-entrant load:
    // compile the current source again only to validate its resolved request
    // shape, then preserve and complete the record's existing request edges.
    if (context.modules.find(module_name)) |existing| {
        if (existing.requestsResolved()) return;
    }

    var parsed = try parser.compile(.{ .realm = context }, source_text, .{ .mode = .module, .filename = path });
    defer parsed.deinit();
    if (parsed.syntax_error) |err| {
        const global_object = try exec.zjs_vm.contextGlobal(context);
        var msg_buf = std.ArrayList(u8).empty;
        defer msg_buf.deinit(runtime.nativeAllocator());
        try msg_buf.print(runtime.nativeAllocator(), "SYNTAX ERROR in {s}:{d}:{d} - {s}", .{ path, err.position.line, err.position.column, err.message });
        const error_val = try exception_ops.createNamedError(context, global_object, "SyntaxError", msg_buf.items);
        _ = context.throwValue(error_val);
        return error.SyntaxError;
    }

    const artifact_view = parsed.moduleArtifact() orelse return error.InvalidBytecode;
    const request_count = artifact_view.record.requests.len;
    const resolved_modules: []HostHooks.ResolvedModule = if (request_count == 0)
        &.{}
    else
        try allocator.alloc(HostHooks.ResolvedModule, request_count);
    var resolved_count: usize = 0;
    defer {
        for (resolved_modules[0..resolved_count]) |resolved| {
            allocator.free(resolved.specifier);
            allocator.free(resolved.path);
        }
        if (resolved_modules.len != 0) allocator.free(resolved_modules);
    }
    const resolved_atoms: []core.Atom = if (request_count == 0)
        &.{}
    else
        try allocator.alloc(core.Atom, request_count);
    var resolved_atom_count: usize = 0;
    defer {
        if (resolved_atoms.len != 0) allocator.free(resolved_atoms);
    }
    // TGC S3 §4 class B: a native []Atom filled by a re-entrant host hook.
    // Root only the written prefix; the tail is still `undefined`.
    var rooted_resolved_atoms: []core.Atom = resolved_atoms[0..0];
    var resolved_atom_roots = core.runtime.rootAtomList(&rooted_resolved_atoms);
    resolved_atom_roots.activate(runtime);
    defer resolved_atom_roots.deactivate(runtime);

    for (artifact_view.record.requests, 0..) |request, index| {
        const specifier = runtime.atoms.name(request.module_name) orelse return error.InvalidAtom;
        resolved_modules[index] = try host_hooks.resolveModule(host_hooks.ptr, specifier, path, allocator);
        resolved_count += 1;
        resolved_atoms[index] = try runtime.internAtom(resolved_modules[index].path);
        resolved_atom_count += 1;
        rooted_resolved_atoms = resolved_atoms[0..resolved_atom_count];
    }

    // Resolution hooks may re-enter the same Realm and publish or even finish
    // this exact record. Whichever record is canonical after resolution wins;
    // the newly parsed artifact remains disposable unless no record exists.
    const record = context.modules.find(module_name) orelse blk: {
        const artifact = parsed.takeModuleArtifact() orelse
            return error.InvalidBytecode;
        break :blk try exec.module.installResolvedModuleArtifact(
            context,
            module_name,
            artifact,
            resolved_atoms,
        );
    };
    try validateHostResolvedRecord(
        context,
        record,
        module_name,
        resolved_atoms,
    );
    if (record.requestsResolved()) return;

    for (resolved_modules, 0..) |resolved, request_index| {
        const request = &record.requests[request_index];
        if (request.module != null) {
            try validateHostRequestDependency(context, record, request_index);
        }

        const existing_dependency: ?*core.module.ModuleRecord = if (request.module) |dependency|
            dependency
        else
            context.modules.find(request.module_name);
        if ((existing_dependency == null or
            !existing_dependency.?.requestsResolved()) and
            !trackedPathContains(seen, resolved.path))
        {
            const loaded = try host_hooks.loadModule(
                host_hooks.ptr,
                resolved,
                allocator,
            );
            defer if (loaded.owned) allocator.free(loaded.source);
            defer allocator.free(loaded.path);

            var module_source_allocated = false;
            const module_source = try wrapSourceByKind(
                allocator,
                loaded.kind,
                loaded.source,
                resolved.path,
                &module_source_allocated,
            );
            defer if (module_source_allocated) allocator.free(module_source);

            try preloadFileModuleGraphWithHostHooksInner(
                allocator,
                runtime,
                context,
                host_hooks,
                module_source,
                resolved.path,
                seen,
                postorder,
            );
        }

        // A load/resolve callback can re-enter and fill this same edge. Re-read
        // it before the no-fail publication transition and accept only the
        // canonical record for the resolved name.
        if (request.module == null) {
            const dependency = context.modules.find(request.module_name) orelse
                return error.ModuleNotFound;
            record.setRequestModuleNoFail(@intCast(request_index), dependency);
        }
        try validateHostRequestDependency(context, record, request_index);
    }

    // Re-entrant completion may already have marked this record while a host
    // callback above was active. The API is idempotent, and the guard avoids
    // treating a valid second observation as a new transition.
    if (!record.requestsResolved()) record.markRequestsResolvedNoFail();

    const order_path = try allocator.dupe(u8, path);
    errdefer allocator.free(order_path);
    try array_list_erased.append(postorder, allocator, order_path);
}

fn wrapSourceByKind(
    allocator: std.mem.Allocator,
    kind: HostHooks.ModuleKind,
    source: []const u8,
    path: []const u8,
    allocated: *bool,
) ![]const u8 {
    switch (kind) {
        .esm, .builtin => {
            allocated.* = false;
            return source;
        },
        .json => {
            allocated.* = true;
            return try std.fmt.allocPrint(allocator, "export default {s};", .{source});
        },
        .commonjs => {
            const dirname = std.fs.path.dirname(path) orelse ".";
            allocated.* = true;
            return try std.fmt.allocPrint(allocator,
                \\var exports = {{}}, module = {{ exports: exports }};
                \\(function(exports, require, module, __filename, __dirname) {{
                \\{s}
                \\}})(exports, undefined, module, "{s}", "{s}");
                \\export default module.exports;
            , .{ source, path, dirname });
        },
        .wasm => {
            var bytes_list = std.ArrayList(u8).empty;
            errdefer bytes_list.deinit(allocator);
            try bytes_list.appendSlice(allocator, "const bytes = new Uint8Array([");
            for (source, 0..) |b, i| {
                if (i > 0) try bytes_list.appendSlice(allocator, ",");
                var buf: [16]u8 = undefined;
                const slice = std.fmt.bufPrint(&buf, "{d}", .{b}) catch unreachable;
                try bytes_list.appendSlice(allocator, slice);
            }
            try bytes_list.appendSlice(allocator, "]);\nconst module = new WebAssembly.Module(bytes);\nconst instance = new WebAssembly.Instance(module);\nexport default instance.exports;\n");
            allocated.* = true;
            return try bytes_list.toOwnedSlice(allocator);
        },
    }
}

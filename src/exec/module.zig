//! Static module installation, linking, namespaces, and evaluation.
//!
//! Parser artifacts are consumed into `PendingDefinition`; installation moves
//! owned bytecode and duplicates request atoms or binding cells retained by a
//! module record. Link diagnostics borrow atoms from those stable records.
//! Host loading is synchronous. Dynamic-import jobs and top-level await
//! scheduling live in this file alongside the registry and graph-link state,
//! mirroring the QuickJS module resolver, linker and evaluator.

const std = @import("std");

const bytecode = @import("../bytecode.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const call_runtime = @import("call_runtime.zig");
const core = @import("../core/root.zig");
const sort_erased = @import("../core/sort_erased.zig");
const exception_ops = @import("exception_ops.zig");
const module_auto_init = @import("../core/module_auto_init.zig");
const property_ops = @import("property_ops.zig");
const array_ops = @import("array_ops.zig");
const uint8array_codec = @import("uint8array_codec.zig");
const object_ops = @import("object_ops.zig");
const stack_mod = @import("stack.zig");
const parser = @import("../parser.zig");
const value_ops = @import("value_ops.zig");

const atom_default = core.atom.predefinedId("default", .string).?;

const LinkDiagnostic = struct {
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
        .linked, .evaluating, .evaluating_async, .evaluated, .errored => true,
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
    // The pending definition parks resolved request names and copied
    // import/export names in native arrays no tracer sees until the record
    // is published; the record's own allocation can run a major. Every
    // `PendingDefinition.add*` notes its ids in the ambient compile scope.
    var atom_scope = core.atom.CompileAtomScope.init(ctx.runtime.atoms, ctx.runtime);
    defer atom_scope.deinit();
    try atom_scope.activate();
    var pending = try pendingDefinitionFromArtifact(ctx, artifact, referrer_path);
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

    for (parsed.requests, 0..) |request, request_index| {
        const resolved = try resolvedRequestAtomForParsed(
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
        if (entry.var_idx >= closure_vars.len) return error.InvalidBytecode;
        const closure = closure_vars[entry.var_idx];
        if (closure.var_name != entry.local_name) return error.InvalidBytecode;
        const expected_type: bytecode.function_def.ClosureType = if (entry.is_namespace)
            .module_decl
        else
            .module_import;
        if (closure.closureType() != expected_type) return error.InvalidBytecode;
        pending.addImport(
            entry.request_index,
            entry.import_name,
            entry.local_name,
            entry.var_idx,
            entry.is_namespace,
        ) catch |err| return pendingMetadataError(err);
    }
    for (parsed.exports) |entry| {
        if (entry.var_idx >= closure_vars.len) return error.InvalidBytecode;
        if (closure_vars[entry.var_idx].var_name != entry.local_name) return error.InvalidBytecode;
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

fn preloadFileModuleGraph(
    env: ModuleEnv,
    context: *core.JSContext,
    root_source: []const u8,
    root_path: []const u8,
) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var keys = seen.keyIterator();
        while (keys.next()) |path| env.allocator.free(path.*);
        seen.deinit(env.allocator);
    }
    try preloadFileModuleGraphInner(env, context, root_source, root_path, &seen);
}

fn resolveModuleSource(context: *core.JSContext, allocator: std.mem.Allocator, referrer: ?[]const u8, specifier: []const u8, mode: core.context.ModuleSourceLoader.Resolution) ![]u8 {
    const loader = context.module_source_loader orelse return error.ModuleNotFound;
    const resolved = try loader.resolve(loader.ptr, allocator, referrer, specifier, mode);
    // No file has a NUL in its name; one would also forge a synthetic tag.
    if (std.mem.indexOfScalar(u8, resolved, 0) != null) {
        allocator.free(resolved);
        return error.ModuleNotFound;
    }
    return resolved;
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

/// A module declaration's value before its declaration runs: in its TDZ for
/// `let`/`const`/`class`, `undefined` for `var` and functions.
fn moduleDeclarationInitialValue(closure: bytecode.function_bytecode.BytecodeClosureVar) core.JSValue {
    return if (closure.isLexical()) core.JSValue.uninitialized() else core.JSValue.undefinedValue();
}

fn createModuleDeclarationCell(
    ctx: *core.JSContext,
    closure: bytecode.function_bytecode.BytecodeClosureVar,
) !*core.VarRef {
    const cell = try core.VarRef.createClosed(ctx.runtime, moduleDeclarationInitialValue(closure));
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
                try object.replaceModuleCaptureSlotOwned(ctx.runtime, index, cell);
            },
            .module_decl => {
                if (slots[index] != null) continue;
                const cell = try createModuleDeclarationCell(ctx, closure);
                try object.replaceModuleCaptureSlotOwned(ctx.runtime, index, cell);
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
    // `owned_bytecode` is the function_bytecode value checked above, the only
    // input `setFunctionBytecodeValue` rejects.
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

/// InnerModuleLinking with an explicit stack, so a long import chain costs
/// heap, not native stack.
fn linkModuleInner(state: *LinkState, root: *core.module.ModuleRecord) !void {
    const allocator = state.ctx.runtime.nativeAllocator();
    const Frame = struct { record: *core.module.ModuleRecord, next_request: usize = 0 };
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(allocator);
    if (!try enterLinkModule(state, root)) return;
    try frames.append(allocator, .{ .record = root });
    while (frames.items.len != 0) {
        const frame = &frames.items[frames.items.len - 1];
        const record = frame.record;
        if (frame.next_request < record.requests.len) {
            const dependency = record.requests[frame.next_request].module orelse return error.ModuleNotFound;
            frame.next_request += 1;
            if (dependency.registry != &state.ctx.modules) return error.ModuleNotFound;
            switch (dependency.status) {
                .unlinked => if (try enterLinkModule(state, dependency)) {
                    try frames.append(allocator, .{ .record = dependency });
                },
                .linking => record.link_dfs_ancestor_index = @min(
                    record.link_dfs_ancestor_index,
                    dependency.link_dfs_index,
                ),
                .linked, .evaluating, .evaluating_async, .evaluated, .errored => {},
            }
            continue;
        }
        try finishLinkModule(state, record);
        _ = frames.pop();
        if (frames.items.len != 0 and record.status == .linking) {
            const parent = frames.items[frames.items.len - 1].record;
            parent.link_dfs_ancestor_index = @min(
                parent.link_dfs_ancestor_index,
                record.link_dfs_ancestor_index,
            );
        }
    }
}

/// Push `record` onto the link stack. False when it is already linked.
fn enterLinkModule(state: *LinkState, record: *core.module.ModuleRecord) !bool {
    if (!record.requestsResolved()) return error.ModuleNotFound;
    if (isLinked(record)) return false;
    if (record.status != .unlinked) return error.ModuleLinkFailed;
    if (state.next_dfs_index == 0) return error.InvalidBytecode;

    record.status = .linking;
    record.link_dfs_index = state.next_dfs_index;
    record.link_dfs_ancestor_index = state.next_dfs_index;
    state.next_dfs_index += 1;
    record.link_stack_prev = state.stack;
    state.stack = record;

    _ = try ensureModuleFunction(state.ctx, record);
    return true;
}

/// Link `record` after its dependencies, and pop its component once it is
/// the component's root.
fn finishLinkModule(state: *LinkState, record: *core.module.ModuleRecord) !void {
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
    if (record.synthetic_kind != .none) return;
    const object = try moduleFunctionObject(record);
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
        try object.replaceModuleCaptureSlotOwned(state.ctx.runtime, entry.var_idx, owned_cell);
    }
}

fn importBindingCell(
    ctx: *core.JSContext,
    binding: core.module.ResolvedBinding,
) !*core.VarRef {
    switch (binding.entry) {
        .local_export => {
            if (bindingCell(binding)) |cell| return cell;
            // The exporting module links later in this DFS: a cycle reached it
            // through a re-export before its own turn. Its declaration cells
            // are created on demand, and it adopts them when it links, so the
            // importer binds the same cell (CreateImportBinding is indirect).
            _ = try ensureModuleFunction(ctx, binding.module);
            return bindingCell(binding) orelse error.InvalidBytecode;
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
            ctx.runtime,
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
            // A non-empty capture table implies a bytecode function, and the
            // index is in range: the two cases the clear rejects.
            .module_import => object.clearModuleImportCaptureSlot(index) catch unreachable,
            .module_decl => if (slots[index]) |cell| {
                cell.setVarRefValue(ctx.runtime, moduleDeclarationInitialValue(closure));
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
    try collectCanonicalModuleNamespaceExports(ctx, record, &exports);
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

/// GetExportedNames (§16.2.1.7.2.1) over `export *` edges, with an explicit
/// worklist because star chains are user-controlled in depth. `exports` is
/// unordered and duplicate-free; the caller sorts it.
fn collectCanonicalModuleNamespaceExports(
    ctx: *core.JSContext,
    root: *core.module.ModuleRecord,
    exports: *std.ArrayList(core.Atom),
) !void {
    const allocator = ctx.runtime.nativeAllocator();
    var seen_names: std.AutoHashMapUnmanaged(core.Atom, void) = .empty;
    defer seen_names.deinit(allocator);
    var visited: std.AutoHashMapUnmanaged(*core.module.ModuleRecord, void) = .empty;
    defer visited.deinit(allocator);
    var pending: std.ArrayList(*core.module.ModuleRecord) = .empty;
    defer pending.deinit(allocator);
    try pending.append(allocator, root);

    while (pending.pop()) |record| {
        if ((try visited.getOrPut(allocator, record)).found_existing) continue;
        // Only the requested module contributes its `default`.
        const include_default = record == root;
        for (record.exports) |entry| {
            if (!include_default and entry.export_name == atom_default) continue;
            try appendExportName(allocator, &seen_names, exports, entry.export_name);
        }
        for (record.indirect_exports) |entry| {
            if (!include_default and entry.export_name == atom_default) continue;
            try appendExportName(allocator, &seen_names, exports, entry.export_name);
        }
        for (record.star_exports) |entry| {
            try pending.append(allocator, try requestDependency(record, entry.request_index));
        }
    }
}

fn appendExportName(
    allocator: std.mem.Allocator,
    seen_names: *std.AutoHashMapUnmanaged(core.Atom, void),
    exports: *std.ArrayList(core.Atom),
    name: core.Atom,
) !void {
    if ((try seen_names.getOrPut(allocator, name)).found_existing) return;
    try exports.append(allocator, name);
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

/// Module namespace [[Exports]] order: the export names as strings, compared
/// by UTF-16 code units (so "10" precedes "2", and a surrogate pair precedes
/// U+FFFF).
fn atomLessThan(rt: *core.JSRuntime, lhs: core.Atom, rhs: core.Atom) bool {
    var lhs_digits: [10]u8 = undefined;
    var rhs_digits: [10]u8 = undefined;
    const lhs_name = exportNameBytes(rt, lhs, &lhs_digits);
    const rhs_name = exportNameBytes(rt, rhs, &rhs_digits);
    const order = array_ops.orderWtf8ByCodeUnits(lhs_name, rhs_name);
    return switch (order) {
        .lt => true,
        .eq => lhs.raw() < rhs.raw(),
        .gt => false,
    };
}

fn exportNameBytes(rt: *core.JSRuntime, atom_id: core.Atom, digits: *[10]u8) []const u8 {
    if (atom_id.isTaggedInt()) return std.fmt.bufPrint(digits, "{d}", .{atom_id.toUInt32()}) catch unreachable;
    return rt.atoms.name(atom_id) orelse "";
}

/// Load the graph below `path` depth-first with an explicit stack, so a long
/// import chain costs heap, not native stack. Dependencies are visited in
/// request order.
///
/// Skipping already-preloaded modules is not a caller-selectable mode: the
/// `seen` set plus the "record with resolved requests is done" check give
/// every entry point the same behaviour.
fn preloadFileModuleGraphInner(
    env: ModuleEnv,
    context: *core.JSContext,
    source_text: []const u8,
    path: []const u8,
    seen: *std.StringHashMapUnmanaged(void),
) !void {
    const allocator = env.allocator;
    const runtime = context.runtime;
    const Frame = struct { record: *core.module.ModuleRecord, next_request: usize = 0 };
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(allocator);

    const root = (try preloadModuleRecord(context, allocator, source_text, path, seen)) orelse return;
    try frames.append(allocator, .{ .record = root });
    while (frames.items.len != 0) {
        const frame = &frames.items[frames.items.len - 1];
        const record = frame.record;
        if (frame.next_request == record.requests.len) {
            if (!record.requestsResolved()) record.markRequestsResolvedNoFail();
            _ = frames.pop();
            continue;
        }
        const request_index = frame.next_request;
        frame.next_request += 1;
        const request = &record.requests[request_index];
        const dependency_name = runtime.atoms.name(request.module_name) orelse
            return error.InvalidAtom;
        if (syntheticKindFromRegistryName(dependency_name)) |kind| {
            const dependency = try preloadSyntheticFileModuleTracked(
                context,
                dependency_name,
                kind,
            );
            try bindRequestModule(record, request_index, dependency);
            continue;
        }

        const existing_dependency = request.module orelse
            context.modules.find(request.module_name);
        var loaded: ?*core.module.ModuleRecord = null;
        if ((existing_dependency == null or !existing_dependency.?.requestsResolved()) and
            !seen.contains(dependency_name))
        {
            const dependency_source = try readModuleSourceOrThrow(context, env, dependency_name, dependency_name);
            defer allocator.free(dependency_source);
            loaded = try preloadModuleRecord(context, allocator, dependency_source, dependency_name, seen);
        }
        const dependency = context.modules.find(request.module_name) orelse
            return error.ModuleNotFound;
        try bindRequestModule(record, request_index, dependency);
        // `frame` may move once another frame is pushed.
        if (loaded) |child| try frames.append(allocator, .{ .record = child });
    }
}

/// Mark `path` seen and compile it unless the registry already holds its
/// record. Null when there is nothing left to walk: the path was seen, or its
/// record already resolved its requests.
fn preloadModuleRecord(
    context: *core.JSContext,
    allocator: std.mem.Allocator,
    source_text: []const u8,
    path: []const u8,
    seen: *std.StringHashMapUnmanaged(void),
) !?*core.module.ModuleRecord {
    const runtime = context.runtime;
    const seen_entry = try seen.getOrPut(allocator, path);
    if (seen_entry.found_existing) return null;
    seen_entry.key_ptr.* = allocator.dupe(u8, path) catch |err| {
        seen.removeByPtr(seen_entry.key_ptr);
        return err;
    };
    const module_name = try runtime.internAtom(path);
    // TGC S3 §4 class B: held across compilation of the module source.
    var module_name_roots = core.runtime.rootAtoms(.{&module_name});
    module_name_roots.activate(runtime);
    defer module_name_roots.deactivate(runtime);

    if (context.modules.find(module_name)) |existing| {
        if (existing.requestsResolved()) return null;
        return existing;
    }
    // Realm intrinsics must exist before parse-time constants take them.
    _ = try @import("zjs_vm.zig").contextGlobal(context);
    // Roots the parsed record's names from the compile until the install
    // has copied them into the module record.
    var record_atoms = core.atom.CompileAtomScope.init(runtime.atoms, runtime);
    defer record_atoms.deinit();
    try record_atoms.activate();
    var parsed = try parser.compile(
        .{ .realm = context },
        source_text,
        .{ .mode = .module, .filename = path },
    );
    defer parsed.deinit();
    if (parsed.syntax_error) |err| {
        // The script compile-error surface: the bare diagnostic, with
        // fileName/lineNumber/columnNumber and an `at file:line:col`
        // stack line.
        const global_object = try @import("zjs_vm.zig").contextGlobal(context);
        _ = try exception_ops.throwParseSyntaxError(context, global_object, path, err.position.line, err.position.column, err.message);
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
    return installed;
}

/// Read a module's source. Allocation failure propagates, a missing file is
/// the QuickJS ReferenceError naming `display_name`, and any other host I/O
/// failure is thrown as its mapped host error.
fn readModuleSourceOrThrow(context: *core.JSContext, env: ModuleEnv, path: []const u8, display_name: []const u8) ![]u8 {
    return readModuleSource(context, env.io, env.allocator, path, env.max_source_size) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => {
            try throwCouldNotLoadModule(context, display_name);
            return error.JSException;
        },
        else => |load_error| {
            const global = try @import("zjs_vm.zig").contextGlobal(context);
            // Engine sentinels keep their own error; a host I/O failure
            // (`IsDir`, `AccessDenied`, ...) names the module it hit.
            const reason = if (exception_ops.runtimeErrorInfo(load_error) != null)
                try exception_ops.hostErrorValue(context, global, load_error)
            else blk: {
                var msg_buf = std.ArrayList(u8).empty;
                defer msg_buf.deinit(context.runtime.nativeAllocator());
                try msg_buf.print(context.runtime.nativeAllocator(), "could not load module '{s}': {s}", .{ display_name, @errorName(load_error) });
                break :blk try exception_ops.createNamedError(context, global, "Error", msg_buf.items);
            };
            _ = context.throwValue(reason);
            return error.JSException;
        },
    };
}

/// Resolve a specifier, or throw the loader's ReferenceError when it cannot
/// be resolved. The caller frees the returned path.
fn resolveModuleSourceOrThrow(
    context: *core.JSContext,
    allocator: std.mem.Allocator,
    referrer: ?[]const u8,
    specifier: []const u8,
    mode: core.context.ModuleSourceLoader.Resolution,
) ![]u8 {
    return resolveModuleSource(context, allocator, referrer, specifier, mode) catch |err| switch (err) {
        error.ModuleNotFound => {
            try throwCouldNotLoadModule(context, specifier);
            return error.JSException;
        },
        else => |e| return e,
    };
}

/// Throw the qjs module-loader failure as a catchable JS exception:
/// `ReferenceError: could not load module filename '<name>'` (mirrors
/// js_module_loader in quickjs-libc).
pub fn throwCouldNotLoadModule(ctx: *core.JSContext, filename: []const u8) !void {
    const global_object = try @import("zjs_vm.zig").contextGlobal(ctx);
    _ = ctx.throwValue(try couldNotLoadModuleError(ctx, global_object, filename));
}

fn couldNotLoadModuleError(ctx: *core.JSContext, global: *core.Object, filename: []const u8) !core.JSValue {
    var msg_buf = std.ArrayList(u8).empty;
    defer msg_buf.deinit(ctx.runtime.nativeAllocator());
    try msg_buf.print(ctx.runtime.nativeAllocator(), "could not load module filename '{s}'", .{filename});
    return exception_ops.createNamedError(ctx, global, "ReferenceError", msg_buf.items);
}

/// Bind request `request_index` to `dependency`, or check that an earlier
/// load bound it to the same record.
fn bindRequestModule(record: *core.module.ModuleRecord, request_index: usize, dependency: *core.module.ModuleRecord) !void {
    const request = record.requests[request_index];
    if (request.module == null) {
        record.setRequestModuleNoFail(@intCast(request_index), dependency);
    } else if (request.module != dependency) {
        return error.ModuleNotFound;
    }
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

/// Separates a synthetic module's file path from its kind in the registry
/// name. A file path cannot contain NUL, and resolution rejects one that
/// does, so no real path reads as tagged.
const synthetic_kind_marker = "\x00type=";

fn syntheticKindFromRegistryName(path: []const u8) ?core.module.SyntheticKind {
    const marker = std.mem.lastIndexOf(u8, path, synthetic_kind_marker) orelse return null;
    return core.module.SyntheticKind.fromName(path[marker + synthetic_kind_marker.len ..]);
}

pub fn syntheticModuleRegistryName(allocator: std.mem.Allocator, path: []const u8, kind: core.module.SyntheticKind) ![]u8 {
    const kind_name = kind.name() orelse unreachable;
    return std.fmt.allocPrint(allocator, "{s}" ++ synthetic_kind_marker ++ "{s}", .{ path, kind_name });
}

pub fn syntheticModuleFilePath(path: []const u8) []const u8 {
    const suffix = std.mem.lastIndexOf(u8, path, synthetic_kind_marker) orelse return path;
    return path[0..suffix];
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
    record.publishRetainedExportCellNoFail(ctx.runtime, export_index, cell.valueRef());
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
    if (moduleBindingInitialized(record, atom_default)) {
        return true;
    }

    // UTF-8 decode (WHATWG Encoding, used by JSON and text modules) drops a
    // leading byte order mark; bytes modules keep every byte.
    const utf8_bom = "\xEF\xBB\xBF";
    const without_bom = if (std.mem.startsWith(u8, source_text, utf8_bom)) source_text[utf8_bom.len..] else source_text;
    // The decode replaces ill-formed sequences with U+FFFD (maximal subparts).
    const replaced: ?[]u8 = if (record.synthetic_kind != .bytes and !std.unicode.utf8ValidateSlice(without_bom))
        try std.fmt.allocPrint(ctx.runtime.nativeAllocator(), "{f}", .{std.unicode.fmtUtf8(without_bom)})
    else
        null;
    defer if (replaced) |bytes| ctx.runtime.nativeAllocator().free(bytes);
    const decoded_text = replaced orelse without_bom;
    const value = switch (record.synthetic_kind) {
        .none => unreachable,
        .json => blk: {
            const string = try core.string.String.createUtf8(ctx.runtime, decoded_text);
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
        .text => (try core.string.String.createUtf8(ctx.runtime, decoded_text)).value(),
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
    const value = try uint8array_codec.createUint8ArrayFromBytes(ctx.runtime, global, source_text);
    const object = try uint8array_codec.expectUint8ArrayObject(value);
    const buffer_value = object.typedArrayBuffer() orelse return error.TypeError;
    const buffer = try property_ops.expectObject(buffer_value);
    if (ctx.classPrototypeObject(core.class.ids.array_buffer)) |prototype| {
        try buffer.setPrototype(ctx.runtime, prototype);
    }
    return value;
}

fn resolvedRequestAtom(ctx: *core.JSContext, request_atom: core.Atom, referrer_path: ?[]const u8) !core.Atom {
    const referrer = referrer_path orelse return request_atom;
    if (ctx.module_source_loader == null) return request_atom;
    const runtime = ctx.runtime;
    const specifier = runtime.atoms.name(request_atom) orelse return error.InvalidAtom;
    const resolved = try resolveModuleSourceOrThrow(ctx, runtime.nativeAllocator(), referrer, specifier, .static_import);
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

// ----- Module loading, dynamic import and graph evaluation -----
// Host-integrated module loading, dynamic import jobs, and graph evaluation.
//
// Sources come from the Context's injected `ModuleSourceLoader`; every slice
// it returns is owned by the caller. Dynamic-import state owns its private
// continuation/waiter lists, while queued continuations duplicate retained
// JSValues and hold a `RealmRef` until completion. Parser artifacts, the
// static module registry, and the asynchronous graph lifecycle share this
// file. import() runs as a job; module evaluation follows ECMA-262
// §16.2.1.5.3 (see "Module evaluation" below).
const jobs_mod = core.jobs;
const exec = @import("root.zig");
const frame_mod = @import("frame.zig");
const ModuleEvalStep = union(enum) {
    completed: core.JSValue,
    suspended: struct {
        continuation: core.JSValue,
        awaited: core.JSValue,
    },
};
/// Module work waiting on a promise reaction.
pub const ModuleContinuation = struct {
    realm: core.RealmRef,
    /// Records of a realm's registry live as long as the realm, which
    /// `realm` keeps alive.
    record: *core.module.ModuleRecord,
    kind: Kind,
    /// `body`: the suspended module body.
    continuation: core.JSValue = core.JSValue.undefinedValue(),
    /// The promise whose settlement this work consumes: Await's
    /// PromiseResolve of the awaited value for `body`, the body's completion
    /// for `settle`.
    awaited: core.JSValue,
    /// Settles with no value once `awaited`'s reaction job has run; the
    /// value is read from `awaited`, so a thenable is not adopted twice.
    reaction: core.JSValue = core.JSValue.undefinedValue(),
    ready: bool = false,

    pub const Kind = enum {
        /// A module body suspended on top-level await.
        body,
        /// A finished async module body. AsyncModuleExecutionFulfilled or
        /// Rejected runs in the reaction to its completion (§16.2.1.5.3.4-5).
        settle,
    };
};

/// An import() of a module whose evaluation is still in progress.
const ModuleEvaluationWaiter = struct {
    realm: core.RealmRef,
    /// The cycle root whose [[TopLevelCapability]] settles this waiter.
    root: *core.module.ModuleRecord,
    /// The imported module; its namespace fulfils the import.
    target: *core.module.ModuleRecord,
    /// The import() promise's own capability.
    resolve: core.JSValue,
    reject: core.JSValue,
};

fn importLoaderTypeFromAttributes(ctx: *core.JSContext, attributes: core.JSValue) !core.module.SyntheticKind {
    if (!attributes.is(.object)) return .none;
    const type_atom = core.atom.ids.type_;
    const object = core.value_semantics.objectFromValue(attributes) orelse return .none;
    const type_value = object.getOwnDataPropertyValue(type_atom) orelse return .none;
    if (!type_value.isString()) return .none;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(ctx.runtime.nativeAllocator());
    try exec.value_ops.appendRawString(ctx.runtime, &buf, type_value);
    return core.module.SyntheticKind.fromName(buf.items) orelse .none;
}

/// Host I/O, the allocator that owns loaded module bytes, and the read limit.
pub const ModuleEnv = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    max_source_size: usize,
};

pub const DynamicImportState = struct {
    runtime: *core.JSRuntime,
    output: ?*std.Io.Writer,
    env: ModuleEnv,
    /// Parked TLA bodies and async completions, and the import() promises
    /// waiting on an evaluation. Both are rooted by this state for its whole
    /// lifetime rather than only while jobs drain: a module that suspends on
    /// top-level await parks its continuation during evaluation, long before
    /// anything calls `runJobs`, and a collection in that window has no other
    /// way to see the generator object the continuation names.
    continuations: std.ArrayList(ModuleContinuation) = .empty,
    waiters: std.ArrayList(ModuleEvaluationWaiter) = .empty,
    roots_registered: bool = false,
    /// Load-relevant import attribute (`type`) for the job currently being
    /// dispatched, set by dynamicImportJobRun before invoking the callback
    /// (jobs run one at a time on this thread, so a single slot suffices —
    /// mirrors qjs threading `attributes` through js_dynamic_import_job to
    /// js_module_loader, quickjs.c / quickjs-libc.c:703).
    pending_import_type: core.module.SyntheticKind = .none,
    /// The capability of the import() promise whose job is loading, set
    /// alongside `pending_import_type`. An import whose module is still
    /// evaluating keeps it in a waiter and sets `import_deferred`, so the
    /// job leaves the promise alone.
    pending_import_capability: ?struct { resolve: core.JSValue, reject: core.JSValue } = null,
    import_deferred: bool = false,

    /// Previous load-slot values for one dynamic-import job. `exit` restores
    /// them so a re-entrant graph drain sees the outer job's attribute.
    const JobScope = struct {
        state: *DynamicImportState,
        prev: core.module.SyntheticKind,
        prev_capability: @FieldType(DynamicImportState, "pending_import_capability"),
        prev_deferred: bool,

        fn exit(self: JobScope) void {
            self.state.pending_import_type = self.prev;
            self.state.pending_import_capability = self.prev_capability;
            self.state.import_deferred = self.prev_deferred;
        }
    };

    /// Jobs run one at a time on this thread, so restoring the previous
    /// value keeps re-entrant graph drains correct. Host-hook loaders resolve
    /// their own module kind and ignore this slot.
    fn enterJob(self: *DynamicImportState, import_type: core.module.SyntheticKind, resolve: core.JSValue, reject: core.JSValue) JobScope {
        const scope = JobScope{
            .state = self,
            .prev = self.pending_import_type,
            .prev_capability = self.pending_import_capability,
            .prev_deferred = self.import_deferred,
        };
        self.pending_import_type = import_type;
        self.pending_import_capability = .{ .resolve = resolve, .reject = reject };
        self.import_deferred = false;
        return scope;
    }

    /// Drain Promise/finalization/host jobs, interleaved with module work
    /// (TLA resumptions, async completions) as each becomes ready.
    /// Script-mode dynamic imports use the state-owned lists because they do
    /// not have an enclosing static module evaluator.
    pub fn runJobs(self: *DynamicImportState, facade_context: *core.JSContext) !void {
        try self.runtime.requireOwnerThread();
        std.debug.assert(facade_context.runtime == self.runtime);
        const drain = (try self.runtime.microtasks.beginDrain()) orelse return;
        defer drain.leave();
        try drainModuleJobLoop(self, facade_context, self.output);
        drain.complete(self.runtime.nativeAllocator());
    }

    /// Announce the scheduling lists to the tracer. Called from
    /// `installDynamicImport`, which every construction site already goes
    /// through, and undone by `deinit`.
    fn activateRoots(self: *DynamicImportState) !void {
        if (self.roots_registered) return;
        try self.runtime.registerRootProvider(self.rootProvider());
        self.roots_registered = true;
    }

    fn rootProvider(self: *DynamicImportState) core.runtime.RootProvider {
        return .{ .context = @ptrCast(self), .trace = traceRoots };
    }

    fn traceRoots(context: *anyopaque, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
        const self: *DynamicImportState = @ptrCast(@alignCast(context));
        for (self.continuations.items) |*entry| {
            if (entry.realm.borrow()) |ctx| try visitor.constHeader(&ctx.header);
            try visitor.value(&entry.continuation);
            try visitor.value(&entry.awaited);
            try visitor.value(&entry.reaction);
        }
        for (self.waiters.items) |*entry| {
            if (entry.realm.borrow()) |ctx| try visitor.constHeader(&ctx.header);
            try visitor.value(&entry.resolve);
            try visitor.value(&entry.reject);
        }
    }

    fn deactivateRoots(self: *DynamicImportState) void {
        if (!self.roots_registered) return;
        self.runtime.unregisterRootProvider(self.rootProvider());
        self.roots_registered = false;
    }

    pub fn deinit(self: *DynamicImportState) void {
        self.deactivateRoots();
        for (self.continuations.items) |*item| item.realm.deinit();
        self.continuations.deinit(self.env.allocator);
        for (self.waiters.items) |*waiter| waiter.realm.deinit();
        self.waiters.deinit(self.env.allocator);
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
pub fn createModuleAwaitReactionPromise(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    awaited: core.JSValue,
) !core.JSValue {
    const promise_constructor = try exec.promise_ops.promiseDefaultConstructor(context, global);
    var awaited_promise = exec.promise_ops.promiseResolveStaticCall(
        context,
        output,
        global,
        promise_constructor,
        &.{awaited},
        null,
        null,
    ) catch |err| blk: {
        // Await step 2 (`? PromiseResolve`) throws into the module body.
        if (!exec.exception_ops.isCatchableError(context, err)) return err;
        const reason = try exec.exception_ops.promiseErrorValue(context, global, err);
        break :blk try core.promise.rejectedWithPrototype(context, reason, exec.promise_ops.promisePrototypeFromGlobal(runtime, global));
    };
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
        awaited_promise,
        resolve,
        reject,
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
    );
    return reaction_promise;
}

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
    // A Proxy ownKeys result lives only in this native list across the
    // traps and allocations below; keep its atoms alive.
    var keys_roots = core.runtime.rootAtomList(&keys);
    keys_roots.activate(rt);
    defer keys_roots.deactivate(rt);
    var unsupported: ?core.Atom = null;

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
        if (unsupported == null and key != core.atom.ids.type_) unsupported = key;
    }

    // AllImportAttributesSupported runs after every value passed the String
    // check, so a non-string value's TypeError wins over this SyntaxError.
    if (unsupported) |key| {
        const key_name = rt.atoms.name(key) orelse "";
        var message_buffer: [128]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buffer, "import attribute '{s}' is not supported", .{key_name}) catch
            "import attribute is not supported";
        return exec.exception_ops.throwSyntaxErrorMessage(ctx, global, message);
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
/// runs.
pub fn enqueueDynamicImportJob(
    ctx: *core.JSContext,
    global: *core.Object,
    prototype: ?*core.Object,
    referrer_path: []const u8,
    specifier: core.JSValue,
) !core.JSValue {
    return enqueueDynamicImportJobWithAttributes(ctx, global, prototype, referrer_path, specifier, core.JSValue.undefinedValue());
}

/// Takes ownership of `attributes` (JS_UNDEFINED or a null-prototype object
/// of string values).
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
    // quickjs-libc.c:703).
    const import_type = try importLoaderTypeFromAttributes(ctx, attributes_value);
    var job_scope: ?DynamicImportState.JobScope = null;
    const loader = rt.dynamic_import_loader;
    if (loader.callback == DynamicImportState.load) {
        if (loader.userdata) |userdata| {
            const state: *DynamicImportState = @ptrCast(@alignCast(userdata));
            job_scope = state.enterJob(import_type, resolve_value, reject_value);
        }
    }
    defer if (job_scope) |scope| scope.exit();

    const load_result: (core.context.DynamicImportError || error{OperationUnsupported})!core.JSValue = blk: {
        const callback = loader.callback orelse break :blk error.OperationUnsupported;
        break :blk callback(loader.userdata, ctx, output, global, basename_bytes.items, specifier_bytes.items);
    };

    if (load_result) |namespace| {
        // A waiter now owns the capability (the module is still evaluating).
        if (job_scope) |scope| if (scope.state.import_deferred) return core.JSValue.undefinedValue();
        if (namespace.is(.object)) {
            const object = try exec.property_ops.expectObject(namespace);
            if (object.class_id == core.class.ids.promise) {
                // A TLA module returns its shared evaluation promise. Chain the
                // import() capability instead of resolving it with the promise
                // object itself (ContinueDynamicImport → PerformPromiseThen).
                try exec.promise_ops.performPromiseThen(
                    ctx,
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
        error.ModuleNotFound, error.FileNotFound => return couldNotLoadModuleError(ctx, global, specifier),
        else => {
            if (exec.exception_ops.runtimeErrorInfo(err)) |info| {
                return exec.exception_ops.createSentinelError(ctx, global, err, info);
            }
            return exec.exception_ops.createNamedError(ctx, global, "Error", @errorName(err));
        },
    }
}

/// The installed loader paired with the state's root registration, so the
/// two cannot get out of step (deactivation once lived apart from activation,
/// and the root provider outlived the frame holding the state).
pub const DynamicImportScope = struct {
    loader: core.runtime.DynamicImportLoaderScope,
    rooted_state: *DynamicImportState,

    pub fn deinit(self: *DynamicImportScope) void {
        self.loader.deinit();
        self.rooted_state.deactivateRoots();
    }
};

/// Install the file-loader dynamic import callback on the state's Runtime.
/// The state must outlive every job drain that may run an import job (the
/// CLI keeps one alive for the whole process; the module-graph runners
/// install a scoped one and drain before restoring).
pub fn installDynamicImport(state: *DynamicImportState) !DynamicImportScope {
    try state.activateRoots();
    return .{
        .rooted_state = state,
        .loader = state.runtime.installDynamicImportLoader(.{ .callback = DynamicImportState.load, .userdata = state }),
    };
}

/// Evaluate `source_text` as entry module `filename` together with its static
/// graph. Every dependency is resolved and read through the Context's
/// `ModuleSourceLoader`; module continuations and dynamic imports are drained
/// before returning.
pub fn evalModuleGraph(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    source_text: []const u8,
    output: *std.Io.Writer,
    filename: []const u8,
    env: ModuleEnv,
) !core.JSValue {
    const allocator = env.allocator;
    // Arm the native recursion guard at this outermost ES-module entry (analogue
    // of eval()'s JS_UpdateStackTop refresh) so module parse/exec on this thread
    // measures against a precise base. The construction-time baseline already
    // covers it; this tightens it for the running thread (test262 workers run on
    // a different C stack than where the runtime was constructed).
    if (context.runtime.stack.call_depth == 0) runtime.stack.captureNativeTop();
    const normalized_filename = try resolveModuleSourceOrThrow(context, allocator, null, filename, .entry);
    defer allocator.free(normalized_filename);

    try preloadFileModuleGraph(env, context, source_text, normalized_filename);
    const root_module_name = try runtime.internAtom(normalized_filename);
    // TGC S3 §4 class B: bare module-name id held across module work.
    var root_module_name_roots = core.runtime.rootAtoms(.{&root_module_name});
    root_module_name_roots.activate(runtime);
    defer root_module_name_roots.deactivate(runtime);
    const root_record = context.modules.find(root_module_name) orelse return error.ModuleNotFound;
    root_record.import_meta_main = true;
    try initializeUnlinkedSyntheticDependencies(context, env, root_record);
    try linkModuleOrThrow(runtime, context, root_record, normalized_filename);
    var dynamic_import_state = DynamicImportState{
        .runtime = runtime,
        .output = output,
        .env = env,
    };
    defer dynamic_import_state.deinit();
    var dynamic_import_scope = try installDynamicImport(&dynamic_import_state);
    defer dynamic_import_scope.deinit();
    switch (try evaluateModule(&dynamic_import_state, context, output, root_record)) {
        .fulfilled => {},
        .rejected => |reason| {
            _ = context.throwValue(reason);
            return error.JSException;
        },
        .pending => |cycle_root| {
            while (cycle_root.status == .evaluating_async) {
                switch (try drainOneScheduledModuleWork(&dynamic_import_state, output)) {
                    .progressed => {},
                    .stalled => if (!try drainOneModuleHostEvent(context, output)) {
                        _ = try exec.exception_ops.throwModuleHostStall(context, try exec.zjs_vm.contextGlobal(context));
                        unreachable;
                    },
                }
            }
            if (cycle_root.status == .errored) {
                _ = context.throwValue(cycle_root.eval_exception orelse core.JSValue.undefinedValue());
                return error.JSException;
            }
        },
    }
    // Dynamic-import jobs may add TLA continuations to the shared scheduler.
    // Alternate one queued reaction with one ready module resume until both
    // queues quiesce while the loader state is still alive.
    try drainModuleJobLoop(&dynamic_import_state, context, output);
    return core.JSValue.undefinedValue();
}

/// Initialize the synthetic dependencies of every not-yet-linked record
/// reachable from `root`, in request order. A dependency's own synthetics
/// are initialized before the importer's, so the first missing file is the
/// one the postorder walk used to report. A linked record's dependencies
/// already are initialized.
fn initializeUnlinkedSyntheticDependencies(
    context: *core.JSContext,
    env: ModuleEnv,
    root: *core.module.ModuleRecord,
) !void {
    const runtime = context.runtime;
    const native = runtime.nativeAllocator();
    const global_object = try exec.zjs_vm.contextGlobal(context);
    var visited: std.AutoHashMapUnmanaged(*core.module.ModuleRecord, void) = .empty;
    defer visited.deinit(native);
    const Frame = struct { record: *core.module.ModuleRecord, next_request: usize = 0 };
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(native);
    try frames.append(native, .{ .record = root });
    while (frames.items.len != 0) {
        const frame = &frames.items[frames.items.len - 1];
        if (frame.next_request == 0) {
            if ((try visited.getOrPut(native, frame.record)).found_existing) {
                _ = frames.pop();
                continue;
            }
        }
        const requests = frame.record.requests;
        if (frame.next_request == requests.len) {
            for (requests) |request| {
                const record = request.module orelse continue;
                if (record.synthetic_kind == .none or moduleBindingInitialized(record, atom_default)) continue;
                const record_path = runtime.atoms.name(record.module_name) orelse return error.InvalidAtom;
                const source_path = syntheticModuleFilePath(record_path);
                const module_source = try readModuleSourceOrThrow(context, env, source_path, source_path);
                defer env.allocator.free(module_source);
                _ = try initializeSyntheticFileModule(context, global_object, record.module_name, module_source);
            }
            _ = frames.pop();
            continue;
        }
        const dependency = requests[frame.next_request].module orelse {
            frame.next_request += 1;
            continue;
        };
        frame.next_request += 1;
        if (dependency.synthetic_kind != .none or dependency.status != .unlinked) continue;
        if (visited.contains(dependency)) continue;
        try frames.append(native, .{ .record = dependency });
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

// ===== Module evaluation (ECMA-262 §16.2.1.5.3) =====
//
// Evaluate / InnerModuleEvaluation / ExecuteAsyncModule and the async
// completion handlers follow the specification. A module body runs as a
// generator step that suspends on top-level await; the scheduler below
// resumes it when the awaited value's reaction has run, and runs the async
// completion handlers when the body's completion reaction has.

const ModuleRecord = core.module.ModuleRecord;

/// IncrementModuleAsyncEvaluationCount: one monotonic order for every
/// runtime; only the relative order within a graph matters.
var module_async_evaluation_count = std.atomic.Value(u64).init(core.module.async_order_unset + 1);

fn nextAsyncEvaluationOrder() u64 {
    return module_async_evaluation_count.fetchAdd(1, .monotonic);
}

fn hasPendingAsyncOrder(record: *const ModuleRecord) bool {
    return record.async_evaluation_order != core.module.async_order_unset and
        record.async_evaluation_order != core.module.async_order_done;
}

const EvaluationOutcome = union(enum) {
    fulfilled,
    rejected: core.JSValue,
    /// Settles when this cycle root's top-level capability does.
    pending: *ModuleRecord,
};

/// Evaluate() (§16.2.1.5.3.1) for a linked record: the outcome of its cycle
/// root's top-level capability, which may still be pending.
fn evaluateModule(
    state: *DynamicImportState,
    context: *core.JSContext,
    output: ?*std.Io.Writer,
    record: *ModuleRecord,
) !EvaluationOutcome {
    var module = record;
    switch (module.status) {
        .evaluating_async, .evaluated, .errored => module = module.cycle_root orelse module,
        else => {},
    }
    if (module.has_top_level_capability) return topLevelOutcome(module);
    module.has_top_level_capability = true;

    var stack: std.ArrayList(*ModuleRecord) = .empty;
    defer stack.deinit(state.env.allocator);
    innerModuleEvaluation(state, context, output, module, &stack) catch |err| {
        // Step 9 runs whatever failed, so no record is left `.evaluating`
        // for a later Evaluate to wait on forever. A failure that must reach
        // the host (allocation failure, termination) still propagates after
        // it, with its exception left pending.
        const out_of_memory = err == error.OutOfMemory or context.exceptionIsOutOfMemory();
        const fatal = out_of_memory or context.exceptionIsUncatchable();
        var rooted_reason = if (fatal)
            (if (context.hasException()) context.runtime.exception.value else core.JSValue.undefinedValue())
        else
            try takeModuleError(context, err);
        var roots = core.runtime.rootValues(.{&rooted_reason});
        roots.activate(context.runtime);
        defer roots.deactivate(context.runtime);
        for (stack.items) |member| {
            member.status = .errored;
            member.setEvalException(context.runtime, rooted_reason);
        }
        // A record evaluated from inside another evaluation (an import job
        // run while its body was on the stack) can have a waiting import.
        for (stack.items) |member| {
            if (member.has_top_level_capability and member != module) try settleTopLevelCapability(state, member, rooted_reason);
        }
        // A root that never entered the stack keeps no capability.
        if (module.status == .linked) module.has_top_level_capability = false;
        if (out_of_memory) return error.OutOfMemory;
        if (fatal) return err;
        return .{ .rejected = rooted_reason };
    };
    if (module.status == .evaluated) return .fulfilled;
    return .{ .pending = module };
}

fn topLevelOutcome(root: *ModuleRecord) EvaluationOutcome {
    return switch (root.status) {
        .errored => .{ .rejected = root.eval_exception orelse core.JSValue.undefinedValue() },
        .evaluated => .fulfilled,
        else => .{ .pending = root },
    };
}

/// The thrown value of a failed module evaluation step, taken from the
/// context. An out-of-memory error thrown into the script is a value like any
/// other; a failure with nothing thrown, or an uncatchable one
/// (termination), propagates.
fn takeModuleError(context: *core.JSContext, err: anytype) !core.JSValue {
    if (context.exceptionIsUncatchable()) return err;
    if (context.hasException()) return context.takeException();
    if (exec.exception_ops.runtimeErrorInfo(err) == null) return err;
    const global = try exec.zjs_vm.contextGlobal(context);
    return exec.exception_ops.promiseErrorValue(context, global, @errorCast(err));
}

/// InnerModuleEvaluation (§16.2.1.5.3.2) with an explicit DFS stack. A
/// thrown error leaves the visited records on `stack` for Evaluate.
fn innerModuleEvaluation(
    state: *DynamicImportState,
    context: *core.JSContext,
    output: ?*std.Io.Writer,
    root: *ModuleRecord,
    stack: *std.ArrayList(*ModuleRecord),
) !void {
    const Frame = struct { record: *ModuleRecord, next_request: usize = 0 };
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(state.env.allocator);
    var index: u32 = 0;
    if (!try enterModuleEvaluation(state, context, root, &index, stack)) return;
    try frames.append(state.env.allocator, .{ .record = root });
    while (frames.items.len != 0) {
        const frame = &frames.items[frames.items.len - 1];
        const module = frame.record;
        if (frame.next_request < module.requests.len) {
            const required = module.requests[frame.next_request].module orelse return error.ModuleNotFound;
            frame.next_request += 1;
            if (try enterModuleEvaluation(state, context, required, &index, stack)) {
                try frames.append(state.env.allocator, .{ .record = required });
                continue;
            }
            try noteEvaluatedDependency(context, module, required);
            continue;
        }
        try finishModuleEvaluation(state, context, output, module, stack);
        _ = frames.pop();
        if (frames.items.len != 0) try noteEvaluatedDependency(context, frames.items[frames.items.len - 1].record, module);
    }
}

/// Steps 2-10: push a linked record onto the stack. False when it is
/// already evaluated or being evaluated; an evaluation error is thrown.
fn enterModuleEvaluation(
    state: *DynamicImportState,
    context: *core.JSContext,
    module: *ModuleRecord,
    index: *u32,
    stack: *std.ArrayList(*ModuleRecord),
) !bool {
    switch (module.status) {
        .evaluating, .evaluating_async, .evaluated => return false,
        .errored => {
            _ = context.throwValue(module.eval_exception orelse core.JSValue.undefinedValue());
            return error.JSException;
        },
        .linked => {},
        .unlinked, .linking => return error.ModuleLinkFailed,
    }
    try stack.ensureUnusedCapacity(state.env.allocator, 1);
    module.status = .evaluating;
    module.eval_dfs_index = index.*;
    module.eval_dfs_ancestor_index = index.*;
    module.pending_async_dependencies = 0;
    index.* += 1;
    stack.appendAssumeCapacity(module);
    return true;
}

/// Step 11.c: account for one evaluated (or in-progress) requested module.
fn noteEvaluatedDependency(
    context: *core.JSContext,
    module: *ModuleRecord,
    required_module: *ModuleRecord,
) !void {
    var required = required_module;
    if (required.status == .evaluating) {
        module.eval_dfs_ancestor_index = @min(module.eval_dfs_ancestor_index, required.eval_dfs_ancestor_index);
    } else {
        required = required.cycle_root orelse required;
        if (required.status == .errored) {
            _ = context.throwValue(required.eval_exception orelse core.JSValue.undefinedValue());
            return error.JSException;
        }
    }
    if (hasPendingAsyncOrder(required)) {
        try required.async_parent_modules.append(context.runtime.nativeAllocator(), module);
        module.pending_async_dependencies += 1;
    }
}

/// Steps 12-16: execute the module (or schedule it), then pop its strongly
/// connected component once it is the component's root.
fn finishModuleEvaluation(
    state: *DynamicImportState,
    context: *core.JSContext,
    output: ?*std.Io.Writer,
    module: *ModuleRecord,
    stack: *std.ArrayList(*ModuleRecord),
) !void {
    if (module.pending_async_dependencies > 0 or module.has_top_level_await) {
        module.async_evaluation_order = nextAsyncEvaluationOrder();
        if (module.pending_async_dependencies == 0) try executeAsyncModule(state, context, output, module);
    } else {
        try executeModuleSync(context, output, module);
    }
    if (module.eval_dfs_ancestor_index != module.eval_dfs_index) return;
    while (stack.pop()) |member| {
        member.status = if (member.async_evaluation_order == core.module.async_order_unset) .evaluated else .evaluating_async;
        member.cycle_root = module;
        if (member.status == .evaluated and member.has_top_level_capability) try settleTopLevelCapability(state, member, null);
        if (member == module) break;
    }
}

/// Run a module body from its start, or resume it with the settled value of
/// the promise it awaits.
fn stepModuleBody(
    context: *core.JSContext,
    output: ?*std.Io.Writer,
    record: *ModuleRecord,
    continuation_value: ?core.JSValue,
    resume_value: ?core.JSValue,
) !ModuleEvalStep {
    const owned_continuation = continuation_value orelse (try core.Object.create(context.runtime, core.class.ids.generator, null)).value();
    const continuation = try exec.property_ops.expectObject(owned_continuation);
    const result = runModuleEvaluationStep(context, record, output, continuation, resume_value) catch |err|
        return moduleResolutionError(err);
    if (continuation.generatorJustYielded() and !continuation.generatorDone()) {
        return .{ .suspended = .{ .continuation = owned_continuation, .awaited = result } };
    }
    return .{ .completed = result };
}

/// ExecuteModule for a module without top-level await. Synthetic modules
/// were initialized when they loaded.
fn executeModuleSync(context: *core.JSContext, output: ?*std.Io.Writer, module: *ModuleRecord) !void {
    if (module.synthetic_kind != .none) return;
    switch (try stepModuleBody(context, output, module, null, null)) {
        .completed => {},
        .suspended => return error.InvalidBytecode,
    }
}

/// ExecuteAsyncModule (§16.2.1.5.3.3): run the body up to its first await;
/// its completion is handled in a later reaction.
fn executeAsyncModule(
    state: *DynamicImportState,
    context: *core.JSContext,
    output: ?*std.Io.Writer,
    module: *ModuleRecord,
) !void {
    const step = stepModuleBody(context, output, module, null, null) catch |err| {
        const reason = try takeModuleError(context, err);
        return scheduleModuleSettle(state, context, module, reason);
    };
    try scheduleModuleStep(state, context, output, module, step);
}

fn scheduleModuleStep(
    state: *DynamicImportState,
    context: *core.JSContext,
    output: ?*std.Io.Writer,
    module: *ModuleRecord,
    step: ModuleEvalStep,
) !void {
    switch (step) {
        .completed => try scheduleModuleSettle(state, context, module, null),
        .suspended => |suspended| {
            var continuation = suspended.continuation;
            var roots = core.runtime.rootValues(.{&continuation});
            roots.activate(context.runtime);
            defer roots.deactivate(context.runtime);
            const global = try exec.zjs_vm.contextGlobal(context);
            const awaited = try awaitPromise(context, output, global, suspended.awaited);
            try appendModuleContinuation(state, context, .{
                .realm = undefined,
                .record = module,
                .kind = .body,
                .continuation = continuation,
                .awaited = awaited,
            });
        },
    }
}

/// Await step 2: `? PromiseResolve(%Promise%, value)`; an abrupt result
/// throws into the body, so it becomes a rejected promise here.
fn awaitPromise(context: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue) !core.JSValue {
    const promise_constructor = try exec.promise_ops.promiseDefaultConstructor(context, global);
    return exec.promise_ops.promiseResolveStaticCall(context, output, global, promise_constructor, &.{value}, null, null) catch |err| {
        if (!exec.exception_ops.isCatchableError(context, err)) return err;
        const reason = try exec.exception_ops.promiseErrorValue(context, global, err);
        return core.promise.rejectedWithPrototype(context, reason, exec.promise_ops.promisePrototypeFromGlobal(context.runtime, global));
    };
}

/// The body finished (`reason == null`) or threw: the async completion
/// handler runs in the reaction to that completion (ExecuteAsyncModule
/// performs PerformPromiseThen on its internal capability).
fn scheduleModuleSettle(
    state: *DynamicImportState,
    context: *core.JSContext,
    module: *ModuleRecord,
    reason: ?core.JSValue,
) !void {
    const global = try exec.zjs_vm.contextGlobal(context);
    const prototype = exec.promise_ops.promisePrototypeFromGlobal(context.runtime, global);
    const completion = if (reason) |value|
        try core.promise.rejectedWithPrototype(context, value, prototype)
    else
        try core.promise.fulfilledWithPrototype(context, core.JSValue.undefinedValue(), prototype);
    try appendModuleContinuation(state, context, .{
        .realm = undefined,
        .record = module,
        .kind = .settle,
        .awaited = completion,
    });
}

/// Queue `entry`, attaching the reaction to its promise now, as Await and
/// PerformPromiseThen do. The reaction's handlers are %Function.prototype%,
/// which returns undefined: its settlement marks the reaction job's turn.
fn appendModuleContinuation(
    state: *DynamicImportState,
    context: *core.JSContext,
    entry: ModuleContinuation,
) !void {
    const rt = context.runtime;
    const global = try exec.zjs_vm.contextGlobal(context);
    var queued = entry;
    var roots = core.runtime.rootValues(.{ &queued.awaited, &queued.continuation, &queued.reaction });
    roots.activate(rt);
    defer roots.deactivate(rt);
    try state.continuations.ensureUnusedCapacity(state.env.allocator, 1);
    const capability = try exec.promise_ops.internalPromiseCapability(context, global, exec.promise_ops.promisePrototypeFromGlobal(rt, global));
    queued.reaction = capability.promise;
    var resolve = capability.resolve;
    var reject = capability.reject;
    var capability_roots = core.runtime.rootValues(.{ &resolve, &reject });
    capability_roots.activate(rt);
    defer capability_roots.deactivate(rt);
    const noop = (global.cachedFunctionProto(rt) orelse return error.InvalidBuiltinRegistry).value();
    try exec.promise_ops.performPromiseThen(context, queued.awaited, noop, noop, resolve, reject);
    queued.realm = core.RealmRef.retain(context);
    state.continuations.appendAssumeCapacity(queued);
}

/// AsyncModuleExecutionFulfilled (§16.2.1.5.3.4).
fn asyncModuleExecutionFulfilled(
    state: *DynamicImportState,
    context: *core.JSContext,
    output: ?*std.Io.Writer,
    module: *ModuleRecord,
) !void {
    if (module.status == .errored) return;
    std.debug.assert(module.status == .evaluating_async);
    module.async_evaluation_order = core.module.async_order_done;
    module.status = .evaluated;
    if (module.has_top_level_capability) try settleTopLevelCapability(state, module, null);

    if (module.async_parent_modules.items.len == 0) return;
    var exec_list: std.ArrayList(*ModuleRecord) = .empty;
    defer exec_list.deinit(state.env.allocator);
    try gatherAvailableAncestors(state.env.allocator, module, &exec_list);
    std.mem.sort(*ModuleRecord, exec_list.items, {}, struct {
        fn lessThan(_: void, lhs: *ModuleRecord, rhs: *ModuleRecord) bool {
            return lhs.async_evaluation_order < rhs.async_evaluation_order;
        }
    }.lessThan);
    for (exec_list.items) |ready| {
        if (ready.status == .errored) continue;
        if (ready.has_top_level_await) {
            try executeAsyncModule(state, context, output, ready);
            continue;
        }
        executeModuleSync(context, output, ready) catch |err| {
            const reason = try takeModuleError(context, err);
            try asyncModuleExecutionRejected(state, ready, reason);
            continue;
        };
        ready.async_evaluation_order = core.module.async_order_done;
        ready.status = .evaluated;
        if (ready.has_top_level_capability) try settleTopLevelCapability(state, ready, null);
    }
}

/// GatherAvailableAncestors (§16.2.1.5.3.6), iteratively.
fn gatherAvailableAncestors(
    allocator: std.mem.Allocator,
    module: *ModuleRecord,
    exec_list: *std.ArrayList(*ModuleRecord),
) !void {
    var pending: std.ArrayList(*ModuleRecord) = .empty;
    defer pending.deinit(allocator);
    try pending.append(allocator, module);
    while (pending.pop()) |finished| {
        for (finished.async_parent_modules.items) |parent| {
            if (std.mem.indexOfScalar(*ModuleRecord, exec_list.items, parent) != null) continue;
            if ((parent.cycle_root orelse parent).status == .errored) continue;
            std.debug.assert(parent.pending_async_dependencies > 0);
            parent.pending_async_dependencies -= 1;
            if (parent.pending_async_dependencies != 0) continue;
            try exec_list.append(allocator, parent);
            if (!parent.has_top_level_await) try pending.append(allocator, parent);
        }
    }
}

/// AsyncModuleExecutionRejected (§16.2.1.5.3.5): a module's own capability
/// is rejected before its parents are, leaf to root.
fn asyncModuleExecutionRejected(
    state: *DynamicImportState,
    module: *ModuleRecord,
    reason: core.JSValue,
) !void {
    var rooted_reason = reason;
    var roots = core.runtime.rootValues(.{&rooted_reason});
    roots.activate(state.runtime);
    defer roots.deactivate(state.runtime);
    const Frame = struct { record: *ModuleRecord, next_parent: usize = 0 };
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(state.env.allocator);
    if (!try rejectAsyncModule(state, module, rooted_reason)) return;
    try frames.append(state.env.allocator, .{ .record = module });
    while (frames.items.len != 0) {
        const frame = &frames.items[frames.items.len - 1];
        if (frame.next_parent == frame.record.async_parent_modules.items.len) {
            _ = frames.pop();
            continue;
        }
        const parent = frame.record.async_parent_modules.items[frame.next_parent];
        frame.next_parent += 1;
        if (try rejectAsyncModule(state, parent, rooted_reason)) try frames.append(state.env.allocator, .{ .record = parent });
    }
}

/// Steps 1-9 for one module: record the error and reject its capability.
/// False when it had already failed.
fn rejectAsyncModule(state: *DynamicImportState, module: *ModuleRecord, reason: core.JSValue) !bool {
    if (!markModuleRejected(state.runtime, module, reason)) return false;
    if (module.has_top_level_capability) try settleTopLevelCapability(state, module, reason);
    return true;
}

fn markModuleRejected(rt: *core.JSRuntime, module: *ModuleRecord, reason: core.JSValue) bool {
    if (module.status == .errored) return false;
    std.debug.assert(module.status == .evaluating_async);
    module.status = .errored;
    module.setEvalException(rt, reason);
    module.async_evaluation_order = core.module.async_order_done;
    return true;
}

/// Settle the imports waiting on `root`: ContinueDynamicImport's reaction
/// to the evaluation promise calls the import capability one job later,
/// with `target`'s namespace (`reason == null`) or the reason.
fn settleTopLevelCapability(
    state: *DynamicImportState,
    root: *ModuleRecord,
    reason: ?core.JSValue,
) !void {
    const waiters = &state.waiters;
    var index: usize = 0;
    while (index < waiters.items.len) {
        if (waiters.items[index].root != root) {
            index += 1;
            continue;
        }
        var waiter = waiters.orderedRemove(index);
        defer waiter.realm.deinit();
        const context = waiter.realm.borrow().?;
        const global = try exec.zjs_vm.contextGlobal(context);
        var settled = core.JSValue.undefinedValue();
        var roots = core.runtime.rootValues(.{ &waiter.resolve, &waiter.reject, &settled });
        roots.activate(state.runtime);
        defer roots.deactivate(state.runtime);
        const prototype = exec.promise_ops.promisePrototypeFromGlobal(state.runtime, global);
        settled = if (reason) |value|
            try core.promise.rejectedWithPrototype(context, value, prototype)
        else
            try core.promise.fulfilledWithPrototype(context, try moduleNamespaceValue(context, waiter.target.module_name), prototype);
        try exec.promise_ops.performPromiseThen(context, settled, waiter.resolve, waiter.reject, core.JSValue.undefinedValue(), core.JSValue.undefinedValue());
    }
}

/// Settle the import() capability `resolve`/`reject` with `root`'s
/// top-level capability and `target`'s namespace.
fn addModuleEvaluationWaiter(
    state: *DynamicImportState,
    context: *core.JSContext,
    root: *ModuleRecord,
    target: *ModuleRecord,
    resolve: core.JSValue,
    reject: core.JSValue,
) !void {
    try state.waiters.ensureUnusedCapacity(state.env.allocator, 1);
    state.waiters.appendAssumeCapacity(.{
        .realm = core.RealmRef.retain(context),
        .root = root,
        .target = target,
        .resolve = resolve,
        .reject = reject,
    });
}

// ----- scheduler -----

const ModuleDrainResult = enum { stalled, progressed };

/// Run one ready module continuation, or else one queued job.
fn drainOneScheduledModuleWork(state: *DynamicImportState, output: ?*std.Io.Writer) !ModuleDrainResult {
    try jobs_mod.checkTermination(state.runtime);
    if (try settleHostEvaluatedWaiter(state)) return .progressed;
    const list = &state.continuations;
    for (list.items) |*entry| markModuleContinuationReady(entry);
    for (list.items, 0..) |entry, index| {
        if (!entry.ready) continue;
        try runModuleContinuation(state, output, index);
        return .progressed;
    }
    if (try runOneModuleMicrotask(state.runtime, output) != .empty) return .progressed;
    return .stalled;
}

/// Settle the waiters of one root that finished outside this scheduler. A
/// root settled here settles its waiters at once, so a waiter on a finished
/// root is one whose root was evaluated by a context `eval` (with its own TLA
/// loop) while an import() waited on it.
fn settleHostEvaluatedWaiter(state: *DynamicImportState) !bool {
    for (state.waiters.items) |waiter| {
        const root = waiter.root;
        switch (root.status) {
            .evaluated => try settleTopLevelCapability(state, root, null),
            .errored => try settleTopLevelCapability(state, root, root.eval_exception orelse core.JSValue.undefinedValue()),
            else => continue,
        }
        return true;
    }
    return false;
}

/// A continuation is ready once its reaction promise settled: the reaction
/// job has run, and the work runs before the next queued job.
fn markModuleContinuationReady(entry: *ModuleContinuation) void {
    if (entry.ready) return;
    const reaction = core.value_semantics.objectFromValue(entry.reaction) orelse return;
    if (reaction.promiseResult() == null) return;
    entry.ready = true;
}

fn runModuleContinuation(state: *DynamicImportState, output: ?*std.Io.Writer, index: usize) !void {
    var entry = state.continuations.orderedRemove(index);
    defer entry.realm.deinit();
    // Out of the list the pair is rooted only by this frame.
    var values = [_]core.JSValue{ entry.continuation, entry.awaited, entry.reaction };
    const slices = [_]core.runtime.ValueRootSlice{.{ .borrowed = &values }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(state.runtime);
    defer roots.deactivate(state.runtime);
    const context = entry.realm.borrow().?;
    const promise = try exec.property_ops.expectObject(entry.awaited);
    const settled = promise.promiseResult() orelse return error.InvalidBytecode;
    const rejected = promise.promiseIsRejected();
    switch (entry.kind) {
        .body => {
            const continuation = try exec.property_ops.expectObject(entry.continuation);
            exec.call_runtime.setGeneratorResumeCompletion(continuation, if (rejected) .throw else .next);
            const step = stepModuleBody(context, output, entry.record, entry.continuation, settled) catch |err| {
                const reason = try takeModuleError(context, err);
                return scheduleModuleSettle(state, context, entry.record, reason);
            };
            try scheduleModuleStep(state, context, output, entry.record, step);
        },
        .settle => if (rejected)
            try asyncModuleExecutionRejected(state, entry.record, settled)
        else
            try asyncModuleExecutionFulfilled(state, context, output, entry.record),
    }
}

/// Alternate module continuations with queued and host jobs until both
/// are idle.
fn drainModuleJobLoop(state: *DynamicImportState, context: *core.JSContext, output: ?*std.Io.Writer) !void {
    const runtime = state.runtime;
    while (true) {
        try jobs_mod.checkTermination(runtime);
        if (state.continuations.items.len != 0 or state.waiters.items.len != 0) {
            switch (try drainOneScheduledModuleWork(state, output)) {
                .stalled => {},
                .progressed => continue,
            }
        }
        if (try drainOneModuleQueuedOrHostJob(runtime, context, output)) continue;
        runtime.microtasks.endStandaloneJob(runtime.nativeAllocator());
        return;
    }
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
    import_type: core.module.SyntheticKind,
) !core.JSValue {
    const runtime = state.runtime;
    std.debug.assert(context.runtime == runtime);
    const env = state.env;
    const allocator = env.allocator;
    if (referrer_path.len == 0) {
        try throwCouldNotLoadModule(context, specifier);
        return error.JSException;
    }
    // An unresolvable specifier rejects the import() promise with the
    // loader's ReferenceError (mirrors js_module_loader quickjs-libc.c:699)
    // instead of aborting the evaluation with a host error.
    const target_path_base = try resolveModuleSourceOrThrow(context, allocator, referrer_path, specifier, .dynamic_import);
    defer allocator.free(target_path_base);

    // A `.json` target — or one tagged `with { type: 'json' }` — loads as a
    // JSON module. Attribute `type: 'text'` / `'bytes'` selects the matching
    // synthetic module even when the file suffix is `.json`; otherwise
    // unknown/absent types retain ordinary ESM loading. The registry name is
    // shared with attribute-tagged static imports so both forms resolve to
    // one module record.
    const source_loader = context.module_source_loader orelse return error.ModuleNotFound;
    const synthetic_kind = source_loader.syntheticKind(source_loader.ptr, target_path_base, import_type.name());
    const is_synthetic = synthetic_kind != null;
    const target_path = if (synthetic_kind) |kind|
        try syntheticModuleRegistryName(allocator, target_path_base, kind)
    else
        try allocator.dupe(u8, target_path_base);
    defer allocator.free(target_path);

    const module_name = try runtime.internAtom(target_path);
    // TGC S3 §4 class B: bare module-name id held across module work.
    var module_name_roots = core.runtime.rootAtoms(.{&module_name});
    module_name_roots.activate(runtime);
    defer module_name_roots.deactivate(runtime);

    // A record whose graph failed to load earlier still has unresolved
    // requests: load it again so the same failure (or, if the missing file
    // appeared, success) repeats instead of a link-time internal error.
    // Already-resolved records keep their live bindings and status.
    const existing_record = context.modules.find(module_name);
    if (existing_record == null or !existing_record.?.requestsResolved()) {
        if (!is_synthetic) {
            const source = try readModuleSourceOrThrow(context, env, target_path, target_path);
            defer allocator.free(source);
            try preloadFileModuleGraph(env, context, source, target_path);
        } else {
            _ = try preloadSyntheticFileModuleTracked(context, target_path, synthetic_kind.?);
        }
    }

    const target_record = context.modules.find(module_name) orelse return error.ModuleNotFound;
    if (target_record.status == .unlinked) {
        // Synthetic records have no bytecode function. Publish their indexed
        // default cell before linking so ordinary import wiring sees the same
        // retained export-cell authority as source modules.
        if (is_synthetic) {
            const source_path = syntheticModuleFilePath(target_path);
            const module_source = try readModuleSourceOrThrow(context, env, source_path, target_path_base);
            defer allocator.free(module_source);
            const global_object = try exec.zjs_vm.contextGlobal(context);
            _ = try initializeSyntheticFileModule(context, global_object, module_name, module_source);
        } else {
            try initializeUnlinkedSyntheticDependencies(context, env, target_record);
        }
        try linkModuleOrThrow(runtime, context, target_record, target_path_base);
    }

    // ContinueDynamicImport: the import settles in a reaction to the
    // evaluation of the module's cycle root and fulfils with the module's
    // own namespace. A settled promise is chained by the import job, which
    // adds that reaction; a pending evaluation settles its waiter directly
    // and the chain adds it there.
    const global = try exec.zjs_vm.contextGlobal(context);
    const promise_prototype = exec.promise_ops.promisePrototypeFromGlobal(runtime, global);
    switch (try evaluateModule(state, context, output, target_record)) {
        .fulfilled => return core.promise.fulfilledWithPrototype(context, try moduleNamespaceValue(context, module_name), promise_prototype),
        .rejected => |reason| return core.promise.rejectedWithPrototype(context, reason, promise_prototype),
        .pending => |cycle_root| {
            const capability = state.pending_import_capability orelse return error.InvalidBytecode;
            try addModuleEvaluationWaiter(state, context, cycle_root, target_record, capability.resolve, capability.reject);
            state.import_deferred = true;
            return core.JSValue.undefinedValue();
        },
    }
}

pub fn linkModuleOrThrow(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    record: *core.module.ModuleRecord,
    filename: []const u8,
) !void {
    var diagnostic: LinkDiagnostic = .{};
    linkModule(context, record, &diagnostic) catch |err| {
        try throwModuleLinkError(runtime, context, filename, err, &diagnostic);
        return moduleResolutionError(err);
    };
}

fn throwModuleLinkError(
    runtime: *core.JSRuntime,
    context: *core.JSContext,
    filename: []const u8,
    err: anyerror,
    diagnostic: ?*const LinkDiagnostic,
) !void {
    const global_object = try exec.zjs_vm.contextGlobal(context);
    switch (err) {
        // Engine failures keep their own error class (and the OOM tag the
        // embedder seam reads); they are not malformed module graphs.
        error.OutOfMemory, error.StackOverflow, error.Interrupted => {
            _ = builtin_dispatch.nativeFromHostError(context, global_object, err);
            return;
        },
        else => {},
    }
    var msg_buf = std.ArrayList(u8).empty;
    defer msg_buf.deinit(runtime.nativeAllocator());
    var formatted_diagnostic = false;
    if (diagnostic) |info| if (info.kind) |kind| {
        const export_name = runtime.atoms.name(info.export_name) orelse "";
        const in_module = syntheticModuleFilePath(runtime.atoms.name(info.module_name) orelse "");
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

const std = @import("std");

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const parser = @import("../parser.zig");
const call = @import("call.zig");
const call_runtime = @import("call_runtime.zig");
const error_stack_ops = @import("error_stack_ops.zig");
const exception_ops = @import("vm_exception_ops.zig");
const module_exec = @import("module.zig");
const module_graph = @import("module_graph.zig");
const object_ops = @import("object_ops.zig");
const promise_ops = @import("promise_ops.zig");
const property_ops = @import("property_ops.zig");
const string_ops = @import("string_ops.zig");
const stack_mod = @import("stack.zig");
const zjs_vm = @import("zjs_vm.zig");

pub fn evalScriptSource(ctx: *core.JSContext, source_text: []const u8, options: core.context.ScriptEvalOptions) !core.JSValue {
    const global = options.realm_global orelse try zjs_vm.contextGlobal(ctx);
    return call.qjsEvalGlobalScriptSource(ctx, options.output, global, source_text, options.filename);
}

pub fn evalScriptValue(ctx: *core.JSContext, source_value: core.JSValue, options: core.context.ScriptEvalOptions) !core.JSValue {
    if (!source_value.isString()) return error.TypeError;
    var source = std.ArrayList(u8).empty;
    defer source.deinit(ctx.runtime.memory.allocator);
    try string_ops.appendSourceStringUtf8(ctx.runtime, &source, source_value);
    return evalScriptSource(ctx, source.items, options);
}

pub fn eval(ctx: *core.JSContext, source_text: []const u8, options: core.context.ContextEvalOptions) !core.JSValue {
    const rt = ctx.runtime;
    // Refresh the native C-stack recursion base at the outermost JS entry only
    // (QuickJS JS_UpdateStackTop): a nested direct `eval()` runs while bytecode
    // is executing (call_depth > 0) and must keep measuring against the true
    // outermost base. Doing it here — on the thread that will run the parser and
    // interpreter — makes the guard correct even when the runtime was
    // constructed on a different thread's stack (test262 worker threads).
    if (ctx.runtime.call_depth == 0) rt.updateNativeStackTop();
    var module_name_buf: [64]u8 = undefined;
    const module_name: core.Atom = if (options.mode == .module) blk: {
        const module_name_bytes = if (std.mem.eql(u8, options.filename, "<eval>"))
            try std.fmt.bufPrint(&module_name_buf, "<eval>#{d}", .{ctx.modules.count})
        else
            options.filename;
        break :blk try rt.internAtom(module_name_bytes);
    } else core.atom.null_atom;
    defer if (module_name != core.atom.null_atom) rt.atoms.free(module_name);

    const parse_start = monotonicNanos();
    var compiled = try parser.compile(.{
        .realm = ctx,
        .policy = .{ .runtime_strict = options.runtime_strict },
    }, source_text, .{
        .mode = parserMode(options.mode),
        .filename = options.filename,
        .script_or_module = if (module_name != core.atom.null_atom) module_name else null,
        .source_kind = parserSourceKind(options.source_kind),
        .strict = options.parse_strict,
        .return_completion = options.mode == .script and options.return_completion,
    });
    if (options.timing) |timing| timing.parse_ns += elapsedNanosSince(parse_start);
    defer compiled.deinit();
    if (compiled.syntax_error) |*err| {
        const global = try zjs_vm.contextGlobal(ctx);
        // Compile-error surface: message is the bare parse diagnostic and the
        // error carries own fileName/lineNumber/columnNumber plus the leading
        // `at file:line:col` stack line (qjs JS_ThrowSyntaxError +
        // build_backtrace filename branch, quickjs.c:7553-7570).
        const parse_filename = rt.atoms.name(err.filename) orelse options.filename;
        return error_stack_ops.throwParseSyntaxError(ctx, global, parse_filename, err.position.line, err.position.column, err.message);
    }
    var module_record: ?*core.module.ModuleRecord = null;
    var should_evaluate_module = false;
    var function: ?*const bytecode.FunctionBytecode = null;
    if (options.mode == .module) {
        const artifact = compiled.takeModuleArtifact() orelse return error.InvalidBytecode;
        const referrer_path: ?[]const u8 = if (std.mem.eql(u8, options.filename, "<eval>")) null else options.filename;
        const record = try module_exec.installParsedModuleArtifact(
            ctx,
            module_name,
            artifact,
            referrer_path,
        );
        record.import_meta_main = true;
        module_record = record;
        switch (record.status) {
            .unlinked => {
                var diagnostic: module_exec.LinkDiagnostic = .{};
                module_exec.linkModule(ctx, record, &diagnostic) catch |err| {
                    try module_graph.throwModuleLinkError(rt, ctx, options.filename, err, &diagnostic);
                    return moduleResolutionError(err);
                };
                if (record.status != .linked) return error.InvalidBytecode;
                should_evaluate_module = true;
            },
            .linked => should_evaluate_module = true,
            .evaluating, .evaluated => {},
            .errored => {
                const exception = record.eval_exception orelse return error.InvalidBytecode;
                _ = ctx.throwValue(exception.dup());
                return error.JSException;
            },
            .linking => return error.ModuleLinkFailed,
        }
        if (should_evaluate_module) {
            function = try module_exec.moduleFunctionBytecode(record);
        }
    } else {
        function = compiled.functionBytecode() orelse return error.InvalidBytecode;
    }

    // Ordinary script/direct/indirect roots are real function objects, just as
    // JS_EvalFunctionInternal first calls js_closure. Move the Result's sole FB
    // owner into that object. Module roots were moved as one artifact into their
    // record above and linkModule published the persistent function/captures.
    var root_function_value = core.JSValue.undefinedValue();
    defer root_function_value.free(rt);
    var root_function_object: ?*core.Object = null;
    if (module_record == null) {
        const root_function = function orelse return error.InvalidBytecode;
        const root_realm = root_function.realmContext() orelse return error.InvalidBuiltinRegistry;
        if (root_realm != ctx) return error.InvalidBytecode;
        const root_global = try zjs_vm.contextGlobal(root_realm);
        const owned_function = compiled.takeFunctionBytecodeValue() orelse return error.InvalidBytecode;
        root_function_value = try object_ops.createRootBytecodeFunctionObject(
            ctx,
            root_global,
            owned_function,
            .root_global,
        );
        root_function_object = object_ops.objectFromValue(root_function_value) orelse return error.InvalidBytecode;
    }
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &root_function_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const result = if (module_record) |record| blk: {
        if (!should_evaluate_module) break :blk core.JSValue.undefinedValue();
        // Track the record through the evaluation status machine (mirrors
        // js_evaluate_module quickjs.c: EVALUATING → EVALUATED, with the
        // thrown value cached as eval_exception on failure) so a later
        // dynamic import of the same module never re-runs its body.
        std.debug.assert(record.status == .linked);
        record.status = .evaluating;
        errdefer if (record.status == .evaluating) {
            record.status = .errored;
            if (ctx.hasException()) record.setEvalException(rt, ctx.runtime.current_exception.dup());
        };
        const value = try runEvalModule(ctx, record, options.output, options.timing);
        if (record.status == .evaluating) record.status = .evaluated;
        break :blk value;
    } else blk: {
        const root_function = function orelse return error.InvalidBytecode;
        const vm_start = monotonicNanos();
        var stack = stack_mod.Stack.init(&rt.memory, ctx.stackLimit());
        defer stack.deinit(rt);
        try stack.reserveAdditional(root_function.stack_size);
        const value = if (root_function_object) |root_object| v: {
            const is_eval_code = options.mode == .eval_direct or options.mode == .eval_indirect;
            const initial_this = if (root_function.runtimeStrictMode()) core.JSValue.undefinedValue() else root_object.bytecodeFunctionRealmGlobalPtr().?.value();
            break :v try zjs_vm.runWithCallEnv(.{
                .ctx = ctx,
                .stack = &stack,
                .function = root_function,
                .initial_this_value = initial_this,
                .var_refs = root_object.functionCaptures(),
                .output = options.output,
                .global = root_object.bytecodeFunctionRealmGlobalPtr() orelse return error.InvalidBuiltinRegistry,
                .break_var_ref_cycles_on_exit = true,
                .strict_unresolved_get_var = root_function.isStrictMode(),
                .current_function_value = root_function_value,
                .eval_global_var_bindings = options.mode == .eval_indirect,
                .direct_eval_vars_reach_global = options.mode == .script or
                    (options.mode == .eval_indirect and !root_function.isStrictMode()),
                .is_eval_code = is_eval_code,
                .global_declarations_prevalidated = true,
            });
        } else return error.InvalidBytecode;
        if (options.timing) |timing| timing.vm_run_ns += elapsedNanosSince(vm_start);
        break :blk value;
    };
    // The completion value is owned here while the post-run steps below can
    // still fail (e.g. OOM while draining promise jobs); release it on every
    // error exit (found by test-oom injection).
    errdefer result.free(rt);

    const global_object = try zjs_vm.contextGlobal(ctx);
    const jobs_start = monotonicNanos();
    try zjs_vm.drainPendingPromiseJobs(ctx, options.output, global_object);
    if (options.timing) |timing| timing.promise_jobs_ns += elapsedNanosSince(jobs_start);

    if (options.mode == .script and options.discard_script_result) {
        result.free(rt);
        return core.JSValue.undefinedValue();
    }
    return result;
}

fn runEvalModule(
    ctx: *core.JSContext,
    record: *core.module.ModuleRecord,
    output: ?*std.Io.Writer,
    timing: ?*core.context.ContextEvalTiming,
) !core.JSValue {
    const rt = ctx.runtime;
    var module_state_value = (try core.Object.create(rt, core.class.ids.generator, null)).value();
    defer module_state_value.free(rt);
    const module_state = try property_ops.expectObject(module_state_value);
    var resume_value: ?core.JSValue = null;
    var resume_value_symbol_rooted = false;
    defer if (resume_value) |value| {
        if (resume_value_symbol_rooted) rt.unregisterExternalValueSymbolRoot(value);
        value.free(rt);
    };

    while (true) {
        const vm_start = monotonicNanos();
        const result = module_exec.runModuleEvaluationStep(
            ctx,
            record,
            output,
            module_state,
            resume_value,
        ) catch |err| return moduleResolutionError(err);
        if (timing) |item| item.vm_run_ns += elapsedNanosSince(vm_start);
        if (resume_value) |value| {
            if (resume_value_symbol_rooted) {
                rt.unregisterExternalValueSymbolRoot(value);
                resume_value_symbol_rooted = false;
            }
            value.free(rt);
            resume_value = null;
        }

        if (module_state.generatorJustYielded() and !module_state.generatorDone()) {
            const await_resume = try waitForModuleAwaitReaction(
                ctx,
                output,
                result,
                timing,
            );
            resume_value = await_resume.value;
            resume_value_symbol_rooted = try rt.registerExternalValueSymbolRoot(
                await_resume.value,
            );
            try call_runtime.setGeneratorResumeCompletionType(
                rt,
                module_state,
                if (await_resume.rejected) 2 else 0,
            );
            continue;
        }

        return result;
    }
}

const ModuleAwaitResume = struct {
    value: core.JSValue,
    rejected: bool,
};

/// Consume one raw OP_await result and resume only when this await's reaction
/// has reached its FIFO position. Jobs after that reaction stay queued until
/// the module has run to its next suspension or completion.
fn waitForModuleAwaitReaction(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    awaited: core.JSValue,
    timing: ?*core.context.ContextEvalTiming,
) !ModuleAwaitResume {
    const rt = ctx.runtime;
    defer awaited.free(rt);
    const global = try zjs_vm.contextGlobal(ctx);
    const reaction_value = try module_graph.createModuleAwaitReactionPromise(
        rt,
        ctx,
        output,
        global,
        awaited,
    );
    defer reaction_value.free(rt);
    const reaction = try property_ops.expectObject(reaction_value);
    if (reaction.class_id != core.class.ids.promise) return error.TypeError;

    while (reaction.promiseResult() == null) {
        const progressed = progress: {
            const jobs_start = monotonicNanos();
            defer if (timing) |item| {
                item.promise_jobs_ns += elapsedNanosSince(jobs_start);
            };
            switch (try promise_ops.drainOnePendingJob(ctx, output, global)) {
                .success => break :progress true,
                .exception => return error.JSException,
                .empty => break :progress try runOneModuleAwaitHostEvent(
                    ctx,
                    output,
                    global,
                ),
            }
        };
        if (!progressed) return error.OperationUnsupported;
    }

    const rejected = reaction.promiseIsRejected();
    if (rejected) core.promise.markHandled(ctx, reaction);
    const settled = reaction.promiseResult() orelse return error.OperationUnsupported;
    return .{
        .value = settled.dup(),
        .rejected = rejected,
    };
}

fn runOneModuleAwaitHostEvent(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
) !bool {
    if (try call.runNextOsSignalHandler(ctx, output, global)) return true;
    if (try call_runtime.runNextOsRwHandler(ctx, output, global)) return true;
    if (try call_runtime.runNextOsTimer(ctx, output, global)) return true;
    return call_runtime.runNextAtomicsHostCompletion(ctx, false);
}

fn moduleResolutionError(err: anytype) (@TypeOf(err) || error{SyntaxError}) {
    return switch (err) {
        error.MissingExport, error.AmbiguousExport => error.SyntaxError,
        else => err,
    };
}

fn parserMode(mode: core.context.EvalMode) parser.Mode {
    return switch (mode) {
        .script => .script,
        .module => .module,
        .eval_direct => .eval_direct,
        .eval_indirect => .eval_indirect,
    };
}

fn parserSourceKind(kind: core.context.EvalSourceKind) parser.SourceKind {
    return switch (kind) {
        .auto => .auto,
        .javascript => .javascript,
        .typescript => .typescript,
    };
}

fn elapsedNanosSince(start: u64) u64 {
    const end = monotonicNanos();
    return if (end > start) end - start else 0;
}

fn monotonicNanos() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// Eval compile wrappers (moved from the dissolved exec/eval.zig).

pub fn compileDirect(realm: *core.RealmContext, source: []const u8) !parser.Result {
    return parser.compile(.{ .realm = realm }, source, .{ .mode = .eval_direct, .filename = "<eval>" });
}

pub fn compileIndirect(realm: *core.RealmContext, source: []const u8) !parser.Result {
    return parser.compile(.{ .realm = realm }, source, .{ .mode = .eval_indirect, .filename = "<eval>" });
}

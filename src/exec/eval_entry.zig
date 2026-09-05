//! Public script/module evaluation entry and its realm-bound execution setup.
//!
//! Compiled roots and temporary module names are owned locally; the returned
//! completion is owned by the caller. This is the exec-side analogue of
//! QuickJS `JS_EvalInternal`, including outermost stack-base refresh and job
//! draining, while parser/compiler policy stays in their own modules.

const std = @import("std");
const atomics_ops = @import("atomics_ops.zig");

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const parser = @import("../parser.zig");
const platform_clock = @import("../platform_clock.zig");
const call = @import("call.zig");
const call_runtime = @import("call_runtime.zig");
const error_stack_ops = @import("error_stack_ops.zig");
const exception_ops = @import("exception_ops.zig");
const module_mod = @import("module.zig");
const module_graph = @import("module_graph.zig");
const object_ops = @import("object_ops.zig");
const promise_ops = @import("promise_ops.zig");
const property_ops = @import("property_ops.zig");
const string_ops = @import("string_ops.zig");
const stack_mod = @import("stack.zig");
const zjs_vm = @import("zjs_vm.zig");

pub fn evalScriptSource(ctx: *core.JSContext, source_text: []const u8, options: core.context.ScriptEvalOptions) !core.JSValue {
    const global = options.realm_global orelse try zjs_vm.contextGlobal(ctx);
    return call.evalGlobalScriptSource(ctx, options.output, global, source_text, options.filename);
}

pub fn evalScriptValue(ctx: *core.JSContext, source_value: core.JSValue, options: core.context.ScriptEvalOptions) !core.JSValue {
    if (!source_value.isString()) return error.TypeError;
    var source = std.ArrayList(u8).empty;
    defer source.deinit(ctx.runtime.memory.allocator);
    try string_ops.appendSourceStringUtf8(ctx.runtime, &source, source_value);
    return evalScriptSource(ctx, source.items, options);
}

/// Intern the module name, if this is a module at all.
///
/// `noinline` for the frame, not for the code: the `<eval>#N` fallback inlines
/// `std.fmt.bufPrint`, which puts a 64-byte buffer AND an `std.Io.Writer`
/// (whose `buffer.ptr` slot R1-a fingerprinted at `fp-272`) in whatever frame
/// it lands in. That frame must not be the one the interpreter runs under.
noinline fn resolveModuleName(ctx: *core.JSContext, options: core.context.ContextEvalOptions) !core.Atom {
    if (options.mode != .module) return core.atom.null_atom;
    var module_name_buf: [64]u8 = undefined;
    const module_name_bytes = if (std.mem.eql(u8, options.filename, "<eval>"))
        std.fmt.bufPrint(&module_name_buf, "<eval>#{d}", .{ctx.modules.count}) catch unreachable
    else
        options.filename;
    return ctx.runtime.internAtom(module_name_bytes);
}

/// Everything `eval` needs from the compile phase, and nothing that phase
/// allocated on the stack to produce it.
const PreparedRoot = struct {
    module_record: ?*core.module.ModuleRecord = null,
    should_evaluate_module: bool = false,
    function: ?*const bytecode.FunctionBytecode = null,
    /// Owned by the caller from the moment this returns; `eval` roots it
    /// before it can allocate again.
    root_function_value: core.JSValue = core.JSValue.undefinedValue(),
    root_function_object: ?*core.Object = null,
    /// Start of the "first execute" timing window, which opens after
    /// compilation and therefore has to be taken inside this helper.
    first_execute_start: u64 = 0,
};

/// Compile, install and link, then publish the root function object.
///
/// The parse result is released HERE rather than at the end of `eval`. That is
/// sound because both ownership transfers below empty it: `takeFunctionBytecodeValue`
/// moves the sole FunctionBytecode reference into the closure object and
/// `takeModuleArtifact` moves the module artifact into its record, each leaving
/// `artifact = .none`, so the `deinit` that used to outlive the VM run had
/// nothing left to free by then anyway. Keeping it here is what lets the whole
/// phase -- parse result, link diagnostic, syntax-error surface and their
/// inlined `Io.Writer`s -- live and die below `eval`'s frame.
noinline fn prepareRootFunction(
    ctx: *core.JSContext,
    source_text: []const u8,
    options: core.context.ContextEvalOptions,
    module_name: core.Atom,
) !PreparedRoot {
    const rt = ctx.runtime;
    var prepared: PreparedRoot = .{};

    var compile_timing: bytecode.CompileTiming = .{};
    const compile_start = platform_clock.monotonicNanos();
    var compiled = try parser.compile(.{
        .realm = ctx,
        .policy = .{ .runtime_strict = options.runtime_strict },
        .timing = if (options.timing != null) &compile_timing else null,
    }, source_text, .{
        .mode = parserMode(options.mode),
        .filename = options.filename,
        .script_or_module = if (module_name != core.atom.null_atom) module_name else null,
        .source_kind = parserSourceKind(options.source_kind),
        .strict = options.parse_strict,
        // QuickJS `js_parse_program` always materializes the hidden `<ret>`
        // completion slot for scripts (quickjs.c:37095-37121). Whether an
        // embedding caller wants that value is a host-result policy, not a
        // different parser/CFG mode; apply that policy after execution below.
        .return_completion = options.mode == .script,
    });
    if (options.timing) |timing| {
        const compile_ns = platform_clock.elapsedNanosSince(compile_start);
        timing.parse_ns += compile_ns;
        timing.compile_ns += compile_ns;
        timing.compile_frontend_ns += compile_timing.frontend_ns;
        timing.compile_finalize_ns += compile_timing.finalize_ns;
    }
    // See the doc comment: safe to release before the VM runs.
    defer compiled.deinit();
    if (compiled.syntax_error) |*err| {
        const global = try zjs_vm.contextGlobal(ctx);
        // Compile-error surface: message is the bare parse diagnostic and the
        // error carries own fileName/lineNumber/columnNumber plus the leading
        // `at file:line:col` stack line (qjs JS_ThrowSyntaxError +
        // build_backtrace filename branch, quickjs.c:7553-7570).
        const parse_filename = rt.atoms.name(err.filename) orelse options.filename;
        // Always an error return; the `!JSValue` signature is for the other
        // call sites.
        _ = try error_stack_ops.throwParseSyntaxError(ctx, global, parse_filename, err.position.line, err.position.column, err.message);
        return error.SyntaxError;
    }
    prepared.first_execute_start = if (options.mode != .module and options.timing != null)
        platform_clock.monotonicNanos()
    else
        0;
    if (options.mode == .module) {
        const artifact = compiled.takeModuleArtifact() orelse return error.InvalidBytecode;
        const referrer_path: ?[]const u8 = if (std.mem.eql(u8, options.filename, "<eval>")) null else options.filename;
        const record = try module_mod.installParsedModuleArtifact(
            ctx,
            module_name,
            artifact,
            referrer_path,
        );
        record.import_meta_main = true;
        prepared.module_record = record;
        switch (record.status) {
            .unlinked => {
                var diagnostic: module_mod.LinkDiagnostic = .{};
                module_mod.linkModule(ctx, record, &diagnostic) catch |err| {
                    try module_graph.throwModuleLinkError(rt, ctx, options.filename, err, &diagnostic);
                    return module_graph.moduleResolutionError(err);
                };
                if (record.status != .linked) return error.InvalidBytecode;
                prepared.should_evaluate_module = true;
            },
            .linked => prepared.should_evaluate_module = true,
            .evaluating, .evaluated => {},
            .errored => {
                const exception = record.eval_exception orelse return error.InvalidBytecode;
                _ = ctx.throwValue(exception);
                return error.JSException;
            },
            .linking => return error.ModuleLinkFailed,
        }
        if (prepared.should_evaluate_module) {
            prepared.function = try module_mod.moduleFunctionBytecode(record);
        }
    } else {
        prepared.function = compiled.functionBytecode() orelse return error.InvalidBytecode;
    }

    // Ordinary script/direct/indirect roots are real function objects, just as
    // JS_EvalFunctionInternal first calls js_closure. Move the Result's sole FB
    // owner into that object. Module roots were moved as one artifact into their
    // record above and linkModule published the persistent function/captures.
    const root_function_publish_start = if (prepared.module_record == null and options.timing != null) platform_clock.monotonicNanos() else 0;
    if (prepared.module_record == null) {
        const root_function = prepared.function orelse return error.InvalidBytecode;
        const root_realm = root_function.realmContext() orelse return error.InvalidBuiltinRegistry;
        if (root_realm != ctx) return error.InvalidBytecode;
        const root_global = try zjs_vm.contextGlobal(root_realm);
        const owned_function = compiled.takeFunctionBytecodeValue() orelse return error.InvalidBytecode;
        prepared.root_function_value = try object_ops.createRootBytecodeFunctionObject(
            ctx,
            root_global,
            owned_function,
            .root_global,
        );
        prepared.root_function_object = object_ops.objectFromValue(prepared.root_function_value) orelse return error.InvalidBytecode;
        if (options.timing) |timing| {
            timing.root_function_publish_ns += platform_clock.elapsedNanosSince(root_function_publish_start);
        }
    }

    return prepared;
}

pub fn eval(ctx: *core.JSContext, source_text: []const u8, options: core.context.ContextEvalOptions) !core.JSValue {
    const rt = ctx.runtime;
    // Refresh the native C-stack recursion base at the outermost JS entry only
    // (QuickJS JS_UpdateStackTop): a nested direct `eval()` runs while bytecode
    // is executing (call_depth > 0) and must keep measuring against the true
    // outermost base. Doing it here — on the thread that will run the parser and
    // interpreter — makes the guard correct even when the runtime was
    // constructed on a different thread's stack (test262 worker threads).
    if (ctx.runtime.hot.call_depth == 0) rt.updateNativeStackTop();
    const outermost = ctx.runtime.hot.call_depth == 0;
    defer if (outermost) rt.clearWeakRefKeptAlive();
    // R1-b: the compile and diagnostic phase runs in ITS OWN native frames.
    //
    // R3 ranked this function's frame first in the whole engine (158,240
    // conservative-only hits over the R1-a corpus) and R1-a proved none of
    // them were roots: they were dead words in `eval`'s 2,176-byte frame, in
    // slots the compile phase had built and the VM phase never rewrites, still
    // resolving to cells the collector had recycled underneath them. A root
    // cannot fix that shape -- only getting the slots out of the frame that is
    // live while the VM runs can, and a `noinline` callee costs nothing at
    // runtime because the phase runs once per script either way.
    const module_name = try resolveModuleName(ctx, options);
    // TGC S3 §4 class B: bare id held across compilation and evaluation of
    // the whole module body.
    var module_name_roots = core.runtime.rootAtoms(.{&module_name});
    module_name_roots.activate(rt);
    defer module_name_roots.deactivate(rt);

    const prepared = try prepareRootFunction(ctx, source_text, options, module_name);
    const first_execute_start = prepared.first_execute_start;
    const module_record = prepared.module_record;
    const should_evaluate_module = prepared.should_evaluate_module;
    const function = prepared.function;
    var root_function_value = prepared.root_function_value;
    const root_function_object = prepared.root_function_object;

    var root_frame = core.runtime.rootValues(.{&root_function_value});
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);
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
            if (ctx.hasException()) record.setEvalException(rt, ctx.runtime.current_exception);
        };
        const value = try runEvalModule(ctx, record, options.output, options.timing);
        if (record.status == .evaluating) record.status = .evaluated;
        break :blk value;
    } else blk: {
        const root_function = function orelse return error.InvalidBytecode;
        const vm_start = platform_clock.monotonicNanos();
        var stack = stack_mod.Stack.init(&rt.memory, ctx.stackLimit());
        defer stack.deinit(rt);
        try stack.reserveAdditional(root_function.stack_size);
        const value = if (root_function_object) |root_object| v: {
            const is_eval_code = options.mode == .eval_direct or options.mode == .eval_indirect;
            const realm_global = root_object.bytecodeFunctionRealmGlobalPtr() orelse return error.InvalidBuiltinRegistry;
            const initial_this = if (root_function.runtimeStrictMode()) core.JSValue.undefinedValue() else realm_global.value();
            const captures = root_object.functionCaptures();
            // TGC R1: the call environment below is a native struct built in
            // THIS frame and read for the whole script. Its members -- the
            // root function object and the bytecode it runs, the realm global
            // that is also the sloppy `this`, and the closure cells -- have no
            // other owner while the VM runs, so a precise-only root set has to
            // name them here. `.slices` rather than a scalar `rootValues`, for
            // the reason the completion value below gives: a container frame
            // is honoured by the production container-only policy, a scalar
            // one is not.
            //
            // Measured: this does NOT move the R3 census share attributed to
            // this call site (158,240 -> 158,214 over the R1-a test262 corpus).
            // That share is not the call env at all -- it is stale words in
            // eval's own 2 KiB frame, in slots the compile/diagnostic phase
            // used and the VM phase never rewrites (an `Io.Writer` buffer slot
            // and a dead JSValue slot, both re-resolving to recycled cells).
            // Residue needs scrubbing or a smaller frame, not a root.
            var env_values = [_]core.JSValue{ root_function_value, initial_this, realm_global.value() };
            var env_slices = [_]core.runtime.ValueRootSlice{
                .{ .borrowed = &env_values },
                .{ .borrowed_cells = captures },
            };
            var env_headers = [_]core.runtime.HeaderRootValue{.{ .header = @constCast(&root_function.header) }};
            var env_roots = core.runtime.ValueRootFrame{ .slices = &env_slices, .headers = &env_headers };
            env_roots.activate(rt);
            defer env_roots.deactivate(rt);
            break :v try zjs_vm.runWithCallEnv(.{
                .ctx = ctx,
                .stack = &stack,
                .function = root_function,
                .initial_this_value = initial_this,
                .var_refs = captures,
                .output = options.output,
                .global = realm_global,
                .strict_unresolved_get_var = root_function.isStrictMode(),
                .current_function_value = root_function_value,
                .eval_global_var_bindings = options.mode == .eval_indirect,
                .direct_eval_vars_reach_global = options.mode == .script or
                    (options.mode == .eval_indirect and !root_function.isStrictMode()),
                .is_eval_code = is_eval_code,
                .global_declarations_prevalidated = true,
            });
        } else return error.InvalidBytecode;
        if (options.timing) |timing| timing.vm_run_ns += platform_clock.elapsedNanosSince(vm_start);
        break :blk value;
    };
    if (module_record == null) {
        if (options.timing) |timing| {
            timing.first_execute_ns += platform_clock.elapsedNanosSince(first_execute_start);
        }
    }
    return drainAndFinish(ctx, options, result);
}

/// Root the completion, drain the microtask queue, apply the host result
/// policy.
///
/// `noinline` for the same reason as `prepareRootFunction`: this phase's root
/// frame, its slice array and its one-element value array are dead while the
/// interpreter runs, and LLVM aliases the compile phase's leftovers onto
/// exactly those slots. Their being in the frame that is live across the whole
/// script is what turned them into the engine's largest block of
/// conservative-only hits.
noinline fn drainAndFinish(
    ctx: *core.JSContext,
    options: core.context.ContextEvalOptions,
    result: core.JSValue,
) !core.JSValue {
    const rt = ctx.runtime;
    // The completion value is owned here while the post-run steps below can
    // still fail (e.g. OOM while draining promise jobs); release it on every
    // error exit (found by test-oom injection).

    // The VM invocation has been torn down, but the owned completion remains
    // live across context/global lookup and the post-run Job drain. Publish
    // that one native handoff value as a window: scalar ValueRootScopes are
    // intentionally erased in production tracing builds, while `.slices` is
    // the exact-root contract for native storage that crosses a safepoint.
    var completion_values = [_]core.JSValue{result};
    var completion_slices = [_]core.runtime.ValueRootSlice{.{ .borrowed = &completion_values }};
    var completion_roots = core.runtime.ValueRootFrame{ .slices = &completion_slices };
    completion_roots.activate(rt);
    defer completion_roots.deactivate(rt);

    const global_object = try zjs_vm.contextGlobal(ctx);
    const jobs_start = platform_clock.monotonicNanos();
    try zjs_vm.drainPendingPromiseJobs(ctx, options.output, global_object);
    if (options.timing) |timing| timing.promise_jobs_ns += platform_clock.elapsedNanosSince(jobs_start);

    if (options.mode == .script and
        (options.discard_script_result or !options.return_completion))
    {
        completion_values[0] = core.JSValue.undefinedValue();
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
    const module_state_value = (try core.Object.create(rt, core.class.ids.generator, null)).value();
    const module_state = try property_ops.expectObject(module_state_value);
    var resume_value: ?core.JSValue = null;

    while (true) {
        const vm_start = platform_clock.monotonicNanos();
        const result = module_mod.runModuleEvaluationStep(
            ctx,
            record,
            output,
            module_state,
            resume_value,
        ) catch |err| return module_graph.moduleResolutionError(err);
        if (timing) |item| item.vm_run_ns += platform_clock.elapsedNanosSince(vm_start);
        if (resume_value) |_| {
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
    const global = try zjs_vm.contextGlobal(ctx);
    const reaction_value = try module_graph.createModuleAwaitReactionPromise(
        rt,
        ctx,
        output,
        global,
        awaited,
    );
    const reaction = try property_ops.expectObject(reaction_value);
    if (reaction.class_id != core.class.ids.promise) return error.TypeError;

    while (reaction.promiseResult() == null) {
        const progressed = progress: {
            const jobs_start = platform_clock.monotonicNanos();
            defer if (timing) |item| {
                item.promise_jobs_ns += platform_clock.elapsedNanosSince(jobs_start);
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
        if (!progressed) {
            _ = try exception_ops.throwModuleHostStall(ctx, global);
            unreachable;
        }
    }

    const rejected = reaction.promiseIsRejected();
    if (rejected) core.promise.markHandled(ctx, reaction);
    const settled = reaction.promiseResult() orelse {
        _ = try exception_ops.throwModuleHostStall(ctx, global);
        unreachable;
    };
    return .{
        .value = settled,
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
    return atomics_ops.runNextAtomicsHostCompletion(ctx, false);
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

// Eval compile wrappers (moved from the dissolved exec/eval.zig).

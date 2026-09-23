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
const error_stack_ops = @import("exception_ops.zig");
const exception_ops = @import("exception_ops.zig");
const module_mod = @import("module.zig");
const module_graph = @import("module.zig");
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
    defer source.deinit(ctx.runtime.nativeAllocator());
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
        .strict = options.parse_strict,
        // QuickJS `js_parse_program` always materializes the hidden `<ret>`
        // completion slot for scripts. Whether an
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
        // build_backtrace filename branch, quickjs.c).
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
    if (ctx.runtime.call_depth == 0) rt.updateNativeStackTop();
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
        var stack = stack_mod.Stack.init(rt, ctx.stackLimit());
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
            // Measured: rooting these does not shrink what the conservative
            // scan keeps alive here. That residue is not the call env at all
            // -- it is stale words in eval's own 2 KiB frame, in slots the
            // compile phase used and the VM phase never rewrites (an
            // `Io.Writer` buffer slot and a dead JSValue slot, both
            // re-resolving to recycled cells).
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

    const jobs_start = platform_clock.monotonicNanos();
    const previous_output = rt.microtasks.output;
    rt.microtasks.output = options.output;
    defer rt.microtasks.output = previous_output;
    try rt.runAutomaticMicrotasks();
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
            call_runtime.setGeneratorResumeCompletion(module_state, if (await_resume.rejected) .throw else .next);
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
    if (try call_runtime.pollHostScheduler(ctx, output, global)) return true;
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

// Eval compile wrappers (moved from the dissolved exec/eval.zig).

// ----- merged from eval_ops.zig -----
// Direct/indirect eval execution, compiler seed construction and indexed cell setup.
const frame_mod = @import("frame.zig");
const inline_calls = @import("inline_calls.zig");
const op = bytecode.opcode.op;
const runWithCallEnv = zjs_vm.runWithCallEnv;
const array_ops = @import("array_ops.zig");
const HostError = @import("exception_ops.zig").HostError;
const InlineCallRequest = call_runtime.InlineCallRequest;
const ValueSliceRoot = array_ops.ValueSliceRoot;
const appendSourceStringUtf8 = string_ops.appendSourceStringUtf8;
const argsFromArray = array_ops.argsFromArray;
const atomIdOrNameEql = call_runtime.atomIdOrNameEql;
const callValueOrBytecodeRoot = call_runtime.callValueOrBytecodeRoot;
const freeArgs = call_runtime.freeArgs;
const functionBytecodeFromValue = call_runtime.functionBytecodeFromValue;
const handleCatchableRuntimeError = call_runtime.handleCatchableRuntimeError;
const normalizeEvalRuntimeError = exception_ops.normalizeEvalRuntimeError;
const objectFromValue = object_ops.objectFromValue;
fn appendEvalClosureSeed(
    rt: *core.JSRuntime,
    seeds: *std.ArrayList(parser.EvalClosureSeed),
    atom_id: core.Atom,
    closure_type: bytecode.function_bytecode.ClosureType,
    var_idx: u16,
    is_lexical: bool,
    is_const: bool,
    var_kind: bytecode.function_bytecode.VarKind,
) !void {
    if (atom_id == core.atom.null_atom) return;
    // qjs add_closure_variables copies every visible scoped binding, argument,
    // unscoped local, and inherited closure row in order. Same-name bindings
    // are distinct identities; lookup-first-match supplies shadowing later.
    try seeds.append(rt.nativeAllocator(), .{
        .var_name = atom_id,
        .closure_type = closure_type,
        .var_idx = var_idx,
        .is_lexical = is_lexical,
        .is_const = is_const,
        .var_kind = var_kind,
    });
}

fn directEvalVarIsInParameterScope(vd: bytecode.function_bytecode.BytecodeVarDef) bool {
    return vd.var_name == core.atom.ids.home_object or
        vd.var_name == core.atom.ids.this_active_func or
        vd.var_name == core.atom.ids.new_target or
        vd.var_name == core.atom.ids.this_ or
        vd.var_name == core.atom.ids.arg_var_object or
        vd.varKind() == .function_name;
}

const DirectEvalClosureSeed = struct {
    values: []parser.EvalClosureSeed = &.{},
    is_arg_scope: bool = false,
};
fn createDirectEvalClosureSeed(
    rt: *core.JSRuntime,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    eval_scope_head: i32,
) !DirectEvalClosureSeed {
    const function = caller_function orelse return .{};
    const frame = caller_frame orelse return .{};

    var seeds = std.ArrayList(parser.EvalClosureSeed).empty;
    errdefer seeds.deinit(rt.nativeAllocator());

    const local_count = @min(function.varDefs().len, frame.locals.len);
    const locals = function.varDefs()[0..local_count];

    // qjs add_closure_variables starts at the adjusted operand, follows the
    // finalized scope_next chain, and adds only rows carrying has_scope.
    var chain_index = eval_scope_head;
    var visited: usize = 0;
    while (chain_index >= 0) {
        if (@as(usize, @intCast(chain_index)) >= locals.len or visited >= locals.len) {
            return error.InvalidBytecode;
        }
        visited += 1;
        const local_index: usize = @intCast(chain_index);
        const vd = locals[local_index];
        if (vd.hasScope()) {
            try appendEvalClosureSeed(rt, &seeds, vd.var_name, .local, @intCast(local_index), vd.isLexical(), vd.isConst(), vd.varKind());
        }
        chain_index = vd.scope_next;
    }
    if (chain_index != -1 and chain_index != bytecode.function_bytecode.arg_scope_end) return error.InvalidBytecode;
    const is_arg_scope = chain_index == bytecode.function_bytecode.arg_scope_end;

    if (!is_arg_scope) {
        const arg_count = @min(function.argVarDefs().len, frame.args.len);
        for (function.argVarDefs()[0..arg_count], 0..) |arg, arg_index| {
            try appendEvalClosureSeed(rt, &seeds, arg.var_name, .arg, @intCast(arg_index), false, false, .normal);
        }
        for (locals, 0..) |vd, local_index| {
            if (vd.hasScope() or vd.var_name == core.atom.ids.ret) continue;
            try appendEvalClosureSeed(rt, &seeds, vd.var_name, .local, @intCast(local_index), vd.isLexical(), vd.isConst(), vd.varKind());
        }
    } else {
        // Argument-scope eval sees only QuickJS's pseudo parameter bindings;
        // ordinary arguments and body locals belong to the later body scope.
        for (locals, 0..) |vd, local_index| {
            if (vd.hasScope() or !directEvalVarIsInParameterScope(vd)) continue;
            try appendEvalClosureSeed(rt, &seeds, vd.var_name, .local, @intCast(local_index), vd.isLexical(), vd.isConst(), vd.varKind());
        }
    }

    for (function.closureVar(), 0..) |cv, idx| {
        switch (cv.closureType()) {
            // qjs add_closure_variables omits every global family entry from
            // a direct-eval seed; the eval unit resolves those names against
            // its own global environment. Module declarations/imports remain
            // ordinary live cells and are intentionally forwarded.
            .global, .global_ref, .global_decl => continue,
            // QuickJS forwards these rows by finalized table identity. The
            // final JSClosureVar has no source-depth field; the eval compiler
            // receives an opaque REF seed and threads any nested consumers by
            // table order and var_idx.
            .local, .arg, .ref, .module_decl, .module_import => {},
        }
        try appendEvalClosureSeed(rt, &seeds, cv.var_name, .ref, @intCast(idx), cv.isLexical(), cv.isConst(), cv.varKind());
    }

    if (seeds.items.len == 0) {
        seeds.deinit(rt.nativeAllocator());
        return .{ .is_arg_scope = is_arg_scope };
    }
    const owned = try rt.nativeAllocator().alloc(parser.EvalClosureSeed, seeds.items.len);
    @memcpy(owned, seeds.items);
    seeds.deinit(rt.nativeAllocator());
    return .{ .values = owned, .is_arg_scope = is_arg_scope };
}

/// The direct-eval frame's view of an outer var_ref slot. Normally the slot
/// cell itself (rc++). For a read-only closure var whose shared cell
/// carries no const flag — a module import slot directly aliases the
/// EXPORTING module's live cell (qjs js_inner_module_linking form,
/// quickjs.c) and must not have importer-side const-ness stamped
/// Direct eval shares the exact outer cell. Read-only semantics belong to the
/// eval bytecode's ClosureVar descriptor (checked by execPutVarRef), not to a
/// wrapper cell that would give one binding two runtime identities.
fn directEvalOuterVarRefView(
    ctx: *core.JSContext,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    idx: usize,
) !*core.VarRef {
    _ = ctx;
    if (idx >= function.closureVar().len or idx >= frame.var_refs.len) return error.InvalidBytecode;
    return frame.var_refs[idx];
}

fn ownedCellFromValue(_: *core.JSRuntime, owned: core.JSValue) !*core.VarRef {
    return core.VarRef.fromValue(owned) orelse {
        return error.InvalidBytecode;
    };
}

fn directEvalSeedFrameVarRef(
    ctx: *core.JSContext,
    global: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    eval_global_var_bindings: bool,
    cv: bytecode.function_bytecode.BytecodeClosureVar,
) !*core.VarRef {
    const outer_function = caller_function orelse return error.InvalidBytecode;
    const outer_frame = caller_frame orelse return error.InvalidBytecode;
    return switch (cv.closureType()) {
        .local => blk: {
            const local_idx: usize = cv.var_idx;
            const outer_vardefs = outer_function.varDefs();
            if (local_idx >= outer_vardefs.len or local_idx >= outer_frame.locals.len) return error.InvalidBytecode;
            const vd = outer_vardefs[local_idx];
            if (eval_global_var_bindings and
                !vd.hasScope() and
                call_runtime.globalLexicalHasForGlobal(ctx, global, vd.var_name) and
                directEvalVisibleLocalNameCount(ctx.runtime, outer_vardefs[0..@min(outer_vardefs.len, outer_frame.locals.len)], vd.var_name) == 1)
            {
                break :blk try ownedCellFromValue(
                    ctx.runtime,
                    try call_runtime.selectOrdinaryGlobalClosureCell(ctx, global, vd.var_name),
                );
            }
            break :blk try outer_frame.captureLocal(ctx.runtime, local_idx);
        },
        .arg => blk: {
            const arg_idx: usize = cv.var_idx;
            if (arg_idx >= outer_frame.args.len) return error.InvalidBytecode;
            break :blk try outer_frame.captureArg(ctx.runtime, arg_idx);
        },
        .ref => blk: {
            if (cv.var_idx >= outer_function.varRefNamesLen() or cv.var_idx >= outer_frame.var_refs.len) return error.InvalidBytecode;
            break :blk try directEvalOuterVarRefView(ctx, outer_function, outer_frame, cv.var_idx);
        },
        // Direct-eval seed construction lowers outer module rows to `.ref` and
        // omits global rows entirely. Seeing either family here means the final
        // closure table no longer matches the seed topology.
        .global_ref, .global_decl, .global, .module_decl, .module_import => error.InvalidBytecode,
    };
}

const DirectEvalClosureResolverContext = struct {
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    eval_global_var_bindings: bool,
};
fn resolveDirectEvalClosureCell(
    opaque_context: ?*anyopaque,
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.FunctionBytecode,
    index: usize,
    cv: bytecode.function_bytecode.BytecodeClosureVar,
) HostError!*core.VarRef {
    const resolver: *DirectEvalClosureResolverContext = @ptrCast(@alignCast(opaque_context orelse return error.InvalidBytecode));
    switch (cv.closureType()) {
        .global, .global_ref, .global_decl => return object_ops.createRootGlobalClosureCell(ctx, global, function, cv),
        .local, .arg, .ref, .module_decl, .module_import => {},
    }
    _ = index;
    return directEvalSeedFrameVarRef(
        ctx,
        global,
        resolver.caller_function,
        resolver.caller_frame,
        resolver.eval_global_var_bindings,
        cv,
    );
}

pub const ExecEvalResult = union(enum) {
    done,
    continue_loop,
    /// A direct-eval call whose callee is not %eval% sitting in tail
    /// position: an ordinary call eligible for tail-call frame reuse.
    tail_inline: InlineCallRequest,
};
pub fn execDirectEval(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    argc: u16,
    output: ?*std.Io.Writer,
    global: *core.Object,
    eval_scope_head: i32,
    caller_eval_global_var_bindings: bool,
    allow_tail_inline: bool,
) !ExecEvalResult {
    // `return eval(...)` lowers to `eval ; return`. When the callee is not
    // %eval%, the call is an ordinary one (12.3.4.1 step 9 evaluates it
    // with the tailCall flag); request frame reuse like op.tail_call.
    if (allow_tail_inline and frame.pc < function.byteCode().len and function.byteCode()[frame.pc] == op.@"return") {
        const total = @as(usize, argc) + 1;
        if (stack.len() >= total) {
            const region_base = stack.len() - total;
            const func_borrowed = stack.values[region_base];
            if (!isContextIntrinsicEval(ctx, func_borrowed)) {
                // `eval(...)` is a plain call: no receiver, `this` is undefined.
                if (inline_calls.resolveInlineTarget(global, core.JSValue.undefinedValue(), func_borrowed)) |target| {
                    return .{ .tail_inline = .{ .target = target, .region_base = region_base, .argc = argc } };
                }
            }
        }
    }

    var args: []core.JSValue = &.{};
    if (argc != 0) args = try ctx.runtime.nativeAllocator().alloc(core.JSValue, argc);
    defer if (args.len != 0) ctx.runtime.nativeAllocator().free(args);

    var remaining: usize = argc;
    while (remaining > 0) {
        remaining -= 1;
        args[remaining] = try stack.pop();
    }

    var func = try stack.pop();
    var rooted_args = args;
    var root_values = [_]*core.JSValue{
        &func,
    };
    var root_slices = [_]core.runtime.ValueRootSlice{
        .{ .mutable = &rooted_args },
    };
    var root_frame = core.runtime.ValueRootFrame{
        .values = &root_values,
        .slices = &root_slices,
    };
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    const result = if (isContextIntrinsicEval(ctx, func))
        directEval(ctx, output, global, rooted_args, function, frame, eval_scope_head, caller_eval_global_var_bindings) catch |err| {
            const eval_err = normalizeEvalRuntimeError(err);
            if (try handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, eval_err)) {
                return .continue_loop;
            }
            return eval_err;
        }
    else
        call_runtime.callValueOrBytecodeRootPreRootedInternal(ctx, output, global, core.JSValue.undefinedValue(), func, rooted_args, function, frame) catch |err| {
            if (try handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) {
                return .continue_loop;
            }
            return err;
        };
    try stack.push(result);
    return .done;
}

pub fn isContextIntrinsicEval(ctx: *core.JSContext, func: core.JSValue) bool {
    return func.is(.object) and func.same(ctx.eval_function);
}

pub fn execApplyEval(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    output: ?*std.Io.Writer,
    global: *core.Object,
    eval_scope_head: i32,
    caller_eval_global_var_bindings: bool,
) !ExecEvalResult {
    var arg_array = try stack.pop();
    var func = try stack.pop();
    var value_roots = [_]*core.JSValue{
        &arg_array,
        &func,
    };
    var value_root_frame = core.runtime.ValueRootFrame{
        .values = &value_roots,
    };
    value_root_frame.activate(ctx.runtime);
    defer value_root_frame.deactivate(ctx.runtime);

    var args = try argsFromArray(ctx.runtime, arg_array);
    defer freeArgs(ctx.runtime, args);
    var args_root = ValueSliceRoot{};
    args_root.init(ctx.runtime, &args);
    defer args_root.deinit();
    const result = if (isContextIntrinsicEval(ctx, func))
        directEval(ctx, output, global, args, function, frame, eval_scope_head, caller_eval_global_var_bindings) catch |err| {
            const eval_err = normalizeEvalRuntimeError(err);
            if (try handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, eval_err)) {
                return .continue_loop;
            }
            return eval_err;
        }
    else
        callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), func, args, function, frame) catch |err| {
            if (try handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) {
                return .continue_loop;
            }
            return err;
        };
    try stack.push(result);
    return .done;
}

pub fn directEval(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    eval_scope_head: i32,
    caller_eval_global_var_bindings: bool,
) !core.JSValue {
    if (args.len == 0) return core.JSValue.undefinedValue();
    if (!args[0].isString()) return args[0];
    var source = std.ArrayList(u8).empty;
    defer source.deinit(ctx.runtime.nativeAllocator());
    try appendSourceStringUtf8(ctx.runtime, &source, args[0]);
    const caller_strict = if (caller_function) |outer_function| outer_function.isStrictMode() else false;
    const caller_entry = if (caller_function) |outer_function|
        outer_function.entryContract()
    else
        bytecode.EntryContract{
            .arguments_allowed = true,
        };
    // Whether a sloppy eval declaration reaches the global variable
    // environment is an invocation fact. It belongs to the executing root
    // frame (and is false for every nested ordinary function), not to every
    // finalized FunctionBytecode compiled beneath that root.
    const requested_eval_global_var_bindings = caller_eval_global_var_bindings;
    const eval_allows_new_target = caller_entry.new_target_allowed;
    const eval_allows_super_call = caller_entry.super_call_allowed;
    const eval_allows_super_property = caller_entry.super_allowed;
    const eval_arguments_allowed = caller_entry.arguments_allowed;
    const eval_seed = try createDirectEvalClosureSeed(ctx.runtime, caller_function, caller_frame, eval_scope_head);
    defer if (eval_seed.values.len != 0) ctx.runtime.nativeAllocator().free(eval_seed.values);
    const eval_script_or_module = if (caller_function) |outer_function|
        outer_function.scriptOrModule()
    else
        null;
    var compiled = try parser.compile(.{ .realm = ctx }, source.items, .{
        .mode = .eval_direct,
        .filename = "<eval>",
        .script_or_module = eval_script_or_module,
        .strict = caller_strict,
        .eval_global_var_bindings = requested_eval_global_var_bindings,
        .eval_in_parameter_initializer = eval_seed.is_arg_scope,
        .eval_allows_new_target = eval_allows_new_target,
        .eval_allows_super_call = eval_allows_super_call,
        .eval_allows_super_property = eval_allows_super_property,
        .eval_arguments_allowed = eval_arguments_allowed,
        .eval_closure_seed = eval_seed.values,
    });
    defer compiled.deinit();
    if (compiled.syntax_error) |*parse_error| {
        // qjs parse errors throw with the compile-error surface: own
        // fileName/lineNumber/columnNumber and a leading `at file:line:col`
        // stack line (build_backtrace filename branch, quickjs.c).
        const parse_filename = ctx.runtime.atoms.name(parse_error.filename) orelse "<eval>";
        return error_stack_ops.throwParseSyntaxError(ctx, global, parse_filename, parse_error.position.line, parse_error.position.column, parse_error.message);
    }
    const compiled_function = compiled.functionBytecode() orelse return error.InvalidBytecode;
    const eval_strict = compiled_function.isStrictMode();
    const eval_global_var_bindings = requested_eval_global_var_bindings and !eval_strict;
    const eval_this = try directEvalThisValue(ctx, global, caller_function, caller_frame);
    const eval_new_target = if (eval_allows_new_target)
        directEvalNewTargetValue(caller_function, caller_frame)
    else
        core.JSValue.undefinedValue();
    var resolver_context = DirectEvalClosureResolverContext{
        .caller_function = caller_function,
        .caller_frame = caller_frame,
        .eval_global_var_bindings = eval_global_var_bindings,
    };
    const owned_function = compiled.takeFunctionBytecodeValue() orelse return error.InvalidBytecode;
    var eval_function_value = try object_ops.createRootBytecodeFunctionObject(
        ctx,
        global,
        owned_function,
        .{ .custom = .{ .context = @ptrCast(&resolver_context), .resolve = resolveDirectEvalClosureCell } },
    );
    var root_values = [_]*core.JSValue{
        &eval_function_value,
    };
    var root_frame = core.runtime.ValueRootFrame{
        .values = &root_values,
    };
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    const eval_function_object = objectFromValue(eval_function_value) orelse return error.InvalidBytecode;
    const function_value = eval_function_object.functionBytecode() orelse return error.InvalidBytecode;
    const function = functionBytecodeFromValue(function_value) orelse return error.InvalidBytecode;
    var nested_stack = stack_mod.Stack.init(ctx.runtime, ctx.runtime.stackSize());
    defer nested_stack.deinit(ctx.runtime);
    const result = try runWithCallEnv(.{
        .ctx = ctx,
        .stack = &nested_stack,
        .function = function,
        .initial_this_value = eval_this,
        .var_refs = eval_function_object.functionCaptures(),
        .output = output,
        .global = global,
        .strict_unresolved_get_var = eval_strict,
        .current_function_value = eval_function_value,
        .new_target_value = eval_new_target,
        .eval_global_var_bindings = eval_global_var_bindings,
        .direct_eval_vars_reach_global = eval_global_var_bindings,
        .is_eval_code = true,
    });
    return result;
}

pub fn directEvalThisValue(
    ctx: *core.JSContext,
    global: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const outer_frame = caller_frame orelse return core.JSValue.undefinedValue();
    if (capturedSpecialValue(caller_function, outer_frame, core.atom.ids.this_)) |value| return value;
    if (caller_function) |function| {
        if (function.isDerivedClassConstructor()) {
            const local_count = @min(function.varDefs().len, outer_frame.locals.len);
            for (function.varDefs()[0..local_count], 0..) |vd, idx| {
                if (vd.var_name == core.atom.ids.this_) return outer_frame.locals[idx];
            }
            return error.InvalidBytecode;
        }
    }
    return object_ops.materializeFrameThisBinding(ctx, global, outer_frame);
}

fn capturedSpecialValue(
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: *frame_mod.Frame,
    name: core.Atom,
) ?core.JSValue {
    const function = caller_function orelse return null;
    for (function.closureVar(), 0..) |capture, index| {
        if (capture.var_name == name and index < caller_frame.var_refs.len) {
            return caller_frame.var_refs[index].varRefValue();
        }
    }
    return null;
}

fn directEvalNewTargetValue(
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) core.JSValue {
    const frame = caller_frame orelse return core.JSValue.undefinedValue();
    return capturedSpecialValue(caller_function, frame, core.atom.ids.new_target) orelse frame.newTargetValue();
}

pub fn directEvalVisibleLocalNameCount(rt: *core.JSRuntime, vardefs: []const bytecode.function_bytecode.BytecodeVarDef, atom_id: core.Atom) usize {
    var count: usize = 0;
    for (vardefs) |vd| {
        if (atomIdOrNameEql(rt, vd.var_name, atom_id)) count += 1;
    }
    return count;
}

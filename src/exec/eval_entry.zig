const std = @import("std");

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const parser = @import("../parser.zig");
const call = @import("call.zig");
const error_stack_ops = @import("error_stack_ops.zig");
const exception_ops = @import("vm_exception_ops.zig");
const module_exec = @import("module.zig");
const module_graph = @import("module_graph.zig");
const object_ops = @import("object_ops.zig");
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
    const legacy_module = compiled.legacyModuleConst();
    var module_adapter: bytecode.LegacyExecutionAdapter = undefined;
    const function: *const bytecode.FunctionBytecode = compiled.functionBytecode() orelse if (legacy_module) |module_function|
        module_adapter.init(module_function)
    else
        return error.InvalidBytecode;

    var has_module_record = false;
    if (options.mode == .module and legacy_module != null and legacy_module.?.module_record != null) {
        const module_function = legacy_module.?;
        has_module_record = true;
        const referrer_path: ?[]const u8 = if (std.mem.eql(u8, options.filename, "<eval>")) null else options.filename;
        try module_exec.instantiateParsedRecordWithReferrer(ctx, module_name, module_function, referrer_path);
        if (ctx.modules.find(module_name)) |record| record.import_meta_main = true;
        ctx.modules.linkModule(rt, module_name) catch |err| {
            try module_graph.throwModuleLinkError(rt, ctx, options.filename, err);
            return moduleResolutionError(err);
        };
        // js_inner_module_linking invokes the module function once with
        // `this === true` after import/export cells are linked. The compiler's
        // entry guard performs declaration instantiation and returns before
        // the body. Keep the in-memory eval entry on the same mechanism as the
        // file-module graph instead of relying on evaluation-time fallbacks.
        try module_graph.initializeModuleFunctionDeclarations(rt, ctx, module_name, module_function);
    }

    var module_var_refs: []*core.VarRef = &.{};
    if (has_module_record) {
        module_var_refs = try module_exec.buildModuleVarRefs(ctx, module_name, legacy_module.?);
    }
    defer module_exec.freeModuleVarRefs(rt, module_var_refs);

    // Ordinary script/direct/indirect roots are real function objects, just as
    // JS_EvalFunctionInternal first calls js_closure. Move the Result's sole FB
    // owner into that object; the explicitly legacy module path remains on its
    // W1e state machine.
    var root_function_value = core.JSValue.undefinedValue();
    defer root_function_value.free(rt);
    var root_function_object: ?*core.Object = null;
    if (compiled.functionBytecode() != null) {
        const root_realm = function.realmContext() orelse return error.InvalidBuiltinRegistry;
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

    const result = if (has_module_record) blk: {
        // Track the record through the evaluation status machine (mirrors
        // js_evaluate_module quickjs.c: EVALUATING → EVALUATED, with the
        // thrown value cached as eval_exception on failure) so a later
        // dynamic import of the same module never re-runs its body.
        if (ctx.modules.find(module_name)) |record| record.status = .evaluating;
        errdefer if (ctx.modules.find(module_name)) |record| {
            if (record.status == .evaluating) {
                record.status = .errored;
                if (ctx.hasException()) record.setEvalException(rt, ctx.runtime.current_exception.dup());
            }
        };
        const value = try runEvalModuleWithVarRefs(ctx, function, options.output, module_var_refs, options.timing);
        if (ctx.modules.find(module_name)) |record| {
            if (record.status == .evaluating) record.status = .evaluated;
        }
        break :blk value;
    } else blk: {
        const vm_start = monotonicNanos();
        var stack = stack_mod.Stack.init(&rt.memory, ctx.stackLimit());
        defer stack.deinit(rt);
        try stack.reserveAdditional(function.stack_size);
        const value = if (root_function_object) |root_object| v: {
            const is_eval_code = options.mode == .eval_direct or options.mode == .eval_indirect;
            const initial_this = if (function.runtimeStrictMode()) core.JSValue.undefinedValue() else root_object.bytecodeFunctionRealmGlobalPtr().?.value();
            break :v try zjs_vm.runWithCallEnv(.{
                .ctx = ctx,
                .stack = &stack,
                .function = function,
                .initial_this_value = initial_this,
                .var_refs = root_object.functionCaptures(),
                .output = options.output,
                .global = root_object.bytecodeFunctionRealmGlobalPtr() orelse return error.InvalidBuiltinRegistry,
                .break_var_ref_cycles_on_exit = true,
                .strict_unresolved_get_var = function.isStrictMode(),
                .current_function_value = root_function_value,
                .eval_global_var_bindings = options.mode == .eval_indirect,
                .direct_eval_vars_reach_global = options.mode == .script or
                    (options.mode == .eval_indirect and !function.isStrictMode()),
                .is_eval_code = is_eval_code,
                .global_declarations_prevalidated = true,
            });
        } else switch (options.mode) {
            .module => try zjs_vm.runWithOutput(ctx, &stack, function, options.output),
            .script, .eval_direct, .eval_indirect => return error.InvalidBytecode,
        };
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

fn runEvalModuleWithVarRefs(
    ctx: *core.JSContext,
    function: *const bytecode.FunctionBytecode,
    output: ?*std.Io.Writer,
    module_var_refs: []const *core.VarRef,
    timing: ?*core.context.ContextEvalTiming,
) !core.JSValue {
    const rt = ctx.runtime;
    var continuation_value = (try core.Object.create(rt, core.class.ids.generator, null)).value();
    defer continuation_value.free(rt);
    const continuation = try property_ops.expectObject(continuation_value);
    var resume_value: ?core.JSValue = null;
    var resume_value_symbol_rooted = false;
    defer if (resume_value) |value| {
        if (resume_value_symbol_rooted) rt.unregisterExternalValueSymbolRoot(value);
        value.free(rt);
    };

    while (true) {
        var stack = stack_mod.Stack.init(&rt.memory, ctx.stackLimit());
        defer stack.deinit(rt);
        const vm_start = monotonicNanos();
        const result = zjs_vm.runModuleWithOutputAndVarRefsState(
            ctx,
            &stack,
            function,
            output,
            module_var_refs,
            continuation,
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

        if (continuation.generatorJustYielded() and !continuation.generatorDone()) {
            resume_value = result;
            resume_value_symbol_rooted = try rt.registerExternalValueSymbolRoot(result);
            const global_object = try zjs_vm.contextGlobal(ctx);
            const jobs_start = monotonicNanos();
            try zjs_vm.drainPendingPromiseJobs(ctx, output, global_object);
            if (timing) |item| item.promise_jobs_ns += elapsedNanosSince(jobs_start);
            continue;
        }

        return result;
    }
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

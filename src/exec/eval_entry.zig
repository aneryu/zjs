const std = @import("std");

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const parser = @import("../parser.zig");
const call = @import("call.zig");
const error_stack_ops = @import("error_stack_ops.zig");
const exception_ops = @import("vm_exception_ops.zig");
const module_exec = @import("module.zig");
const module_graph = @import("module_graph.zig");
const property_ops = @import("property_ops.zig");
const call_runtime = @import("call_runtime.zig");
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
    if (ctx.call_depth == 0) rt.updateNativeStackTop();
    const parse_start = monotonicNanos();
    var compiled = try parser.compile(rt, source_text, .{
        .mode = parserMode(options.mode),
        .filename = options.filename,
        .source_kind = parserSourceKind(options.source_kind),
        .strict = options.parse_strict,
        .runtime_strict = options.runtime_strict,
        .return_completion = options.mode == .script and options.return_completion,
    });
    if (options.timing) |timing| timing.parse_ns += elapsedNanosSince(parse_start);
    defer compiled.deinit();
    if (compiled.syntax_error) |*err| {
        if (options.mode == .script and isWhitespaceSeparatedNumericScript(source_text)) return core.JSValue.undefinedValue();
        const global = try zjs_vm.contextGlobal(ctx);
        // Compile-error surface: message is the bare parse diagnostic and the
        // error carries own fileName/lineNumber/columnNumber plus the leading
        // `at file:line:col` stack line (qjs JS_ThrowSyntaxError +
        // build_backtrace filename branch, quickjs.c:7553-7570).
        const parse_filename = rt.atoms.name(err.filename) orelse options.filename;
        return error_stack_ops.throwParseSyntaxError(ctx, global, parse_filename, err.position.line, err.position.column, err.message);
    }
    if (options.runtime_strict and options.mode == .script) forceRuntimeStrict(rt, &compiled.function);

    var module_name: core.Atom = core.atom.null_atom;
    var has_module_record = false;
    defer if (has_module_record) rt.atoms.free(module_name);
    if (options.mode == .module and compiled.function.module_record != null) {
        var module_name_buf: [64]u8 = undefined;
        const module_name_bytes = if (std.mem.eql(u8, options.filename, "<eval>"))
            try std.fmt.bufPrint(&module_name_buf, "<eval>#{d}", .{rt.modules.modules.len})
        else
            options.filename;
        module_name = try rt.internAtom(module_name_bytes);
        has_module_record = true;
        const referrer_path: ?[]const u8 = if (std.mem.eql(u8, options.filename, "<eval>")) null else options.filename;
        _ = try module_exec.instantiateParsedRecordWithReferrer(rt, module_name, &compiled.function, referrer_path);
        if (rt.modules.find(module_name)) |record| record.import_meta_main = true;
        rt.modules.linkModule(rt, module_name) catch |err| {
            try module_graph.throwModuleLinkError(rt, ctx, options.filename, err);
            return moduleResolutionError(err);
        };
    }

    var module_var_refs: []*core.VarRef = &.{};
    if (has_module_record) {
        module_var_refs = try module_exec.buildModuleVarRefs(ctx, module_name, &compiled.function);
    }
    defer module_exec.freeModuleVarRefs(rt, module_var_refs);

    if (!has_module_record and canReturnUndefinedWithoutVm(&compiled.function)) {
        return core.JSValue.undefinedValue();
    }

    const result = if (has_module_record) blk: {
        // Track the record through the evaluation status machine (mirrors
        // js_evaluate_module quickjs.c: EVALUATING → EVALUATED, with the
        // thrown value cached as eval_exception on failure) so a later
        // dynamic import of the same module never re-runs its body.
        if (rt.modules.find(module_name)) |record| record.status = .evaluating;
        errdefer if (rt.modules.find(module_name)) |record| {
            if (record.status == .evaluating) {
                record.status = .errored;
                if (ctx.hasException()) record.setEvalException(rt, ctx.exception_slot.value.dup());
            }
        };
        const value = try runEvalModuleWithVarRefs(ctx, &compiled.function, options.output, module_var_refs, options.timing);
        if (rt.modules.find(module_name)) |record| {
            if (record.status == .evaluating) record.status = .evaluated;
        }
        break :blk value;
    } else blk: {
        const vm_start = monotonicNanos();
        var stack = stack_mod.Stack.init(&rt.memory, ctx.stack_limit);
        defer stack.deinit(rt);
        try stack.reserveAdditional(compiled.function.stack_size);
        // `.eval_direct`/`.eval_indirect` run through the EVAL runner contract
        // (`is_eval_code = true` with eval declaration instantiation) — qjs
        // JS_EVAL_TYPE_DIRECT/INDIRECT — so a top-level let/const/class stays a
        // pure eval frame-local (no redundant ctx.lexicals property). `.script`
        // keeps the script runner (JS_EVAL_TYPE_GLOBAL → global_decl cell).
        const value = switch (options.mode) {
            .eval_direct, .eval_indirect => v: {
                // Indirect eval registers its top-level var/function declarations
                // as configurable global data properties (non-lexical), mirroring
                // parser.zig:176 (`eval_global_var_bindings = … or mode == .eval_indirect`)
                // and the in-VM eval() builtin.
                const eval_global_var_bindings = options.mode == .eval_indirect;
                break :v try zjs_vm.runEvalWithOutput(ctx, &stack, &compiled.function, options.output, eval_global_var_bindings);
            },
            .script, .module => try zjs_vm.runWithOutput(ctx, &stack, &compiled.function, options.output),
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

fn canReturnUndefinedWithoutVm(function: *const bytecode.Bytecode) bool {
    if (function.flags.is_module or function.module_record != null) return false;
    if (function.code.len != 1 or function.code[0] != bytecode.opcode.op.return_undef) return false;
    return function.var_count == 0 and
        function.arg_count == 0 and
        function.vardefs.len == 0 and
        function.varRefNamesLen() == 0 and
        function.closure_var.len == 0 and
        function.global_vars.len == 0 and
        function.private_bound_names.len == 0 and
        function.constants.values.len == 0;
}

fn runEvalModuleWithVarRefs(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
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
        var stack = stack_mod.Stack.init(&rt.memory, ctx.stack_limit);
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

fn forceRuntimeStrict(rt: *core.JSRuntime, function: *bytecode.Bytecode) void {
    function.flags.runtime_strict = true;
    for (function.constants.values) |value| forceFunctionBytecodeRuntimeStrict(rt, value);
}

fn forceFunctionBytecodeRuntimeStrict(rt: *core.JSRuntime, value: core.JSValue) void {
    if (!value.isFunctionBytecode()) return;
    const header = value.objectHeader() orelse return;
    const aligned: *align(16) @TypeOf(header.*) = @alignCast(header);
    const function_bytecode: *bytecode.FunctionBytecode = @fieldParentPtr("header", aligned);
    function_bytecode.flags.runtime_strict_mode = true;
    // No cached execution view to refresh: the VM rebuilds the `Bytecode` view
    // per call (`makeBytecodeView`), so the updated flag is read fresh next call.
    for (function_bytecode.cpoolSlice()) |child| forceFunctionBytecodeRuntimeStrict(rt, child);
}

fn isWhitespaceSeparatedNumericScript(source_text: []const u8) bool {
    var saw_digit = false;
    var saw_space_after_digit = false;
    for (source_text) |ch| {
        if (string_ops.isAsciiDigitByte(ch)) {
            if (saw_space_after_digit) return true;
            saw_digit = true;
        } else if (call_runtime.isAsciiWhitespace(ch)) {
            if (saw_digit) saw_space_after_digit = true;
        } else {
            return false;
        }
    }
    return false;
}

test "eval numeric script fallback uses shared ASCII classifiers" {
    try std.testing.expect(isWhitespaceSeparatedNumericScript("1 2"));
    try std.testing.expect(isWhitespaceSeparatedNumericScript("1\t2"));
    try std.testing.expect(isWhitespaceSeparatedNumericScript("1\x0b2"));
    try std.testing.expect(isWhitespaceSeparatedNumericScript("1\x0c2"));
    try std.testing.expect(!isWhitespaceSeparatedNumericScript("12"));
    try std.testing.expect(!isWhitespaceSeparatedNumericScript("1a2"));
    try std.testing.expect(!isWhitespaceSeparatedNumericScript("1  "));
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

pub fn compileDirect(rt: *core.JSRuntime, source: []const u8) !parser.Result {
    return parser.compile(rt, source, .{ .mode = .eval_direct, .filename = "<eval>" });
}

pub fn compileIndirect(rt: *core.JSRuntime, source: []const u8) !parser.Result {
    return parser.compile(rt, source, .{ .mode = .eval_indirect, .filename = "<eval>" });
}

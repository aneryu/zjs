const std = @import("std");

const bytecode = @import("../bytecode/root.zig");
const core = @import("../core/root.zig");
const parser = @import("../frontend/parser.zig");
const call = @import("call.zig");
const exception_ops = @import("vm_exception_ops.zig");
const module_exec = @import("module.zig");
const property_ops = @import("property_ops.zig");
const shared = @import("shared.zig");
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
    try shared.appendSourceStringUtf8(ctx.runtime, &source, source_value);
    return evalScriptSource(ctx, source.items, options);
}

pub fn eval(ctx: *core.JSContext, source_text: []const u8, options: core.context.ContextEvalOptions) !core.JSValue {
    const rt = ctx.runtime;
    const parse_start = monotonicNanos();
    var compiled = try parser.parse(rt, source_text, .{
        .mode = parserMode(options.mode),
        .filename = options.filename,
        .source_kind = parserSourceKind(options.source_kind),
        .strict = options.parse_strict,
        .return_completion = options.mode == .script and options.return_completion,
    });
    if (options.timing) |timing| timing.parse_ns += elapsedNanosSince(parse_start);
    defer compiled.deinit();
    if (compiled.syntax_error) |err| {
        if (options.mode == .script and isWhitespaceSeparatedNumericScript(source_text)) return core.JSValue.undefinedValue();
        const global = try zjs_vm.contextGlobal(ctx);
        var msg_buf = std.ArrayList(u8).empty;
        defer msg_buf.deinit(rt.memory.allocator);
        try msg_buf.print(rt.memory.allocator, "SYNTAX ERROR in {s}:{d}:{d} - {s}", .{ options.filename, err.position.line, err.position.column, err.message });
        const error_val = try exception_ops.createNamedError(rt, global, "SyntaxError", msg_buf.items);
        _ = ctx.throwValue(error_val);
        return error.SyntaxError;
    }
    if (options.runtime_strict and options.mode == .script) forceRuntimeStrict(&compiled.function);

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
            const global = try zjs_vm.contextGlobal(ctx);
            var msg_buf = std.ArrayList(u8).empty;
            defer msg_buf.deinit(rt.memory.allocator);
            try msg_buf.print(rt.memory.allocator, "LINK ERROR for module {s}: {s}", .{ options.filename, @errorName(err) });
            const error_val = try exception_ops.createNamedError(rt, global, "SyntaxError", msg_buf.items);
            _ = ctx.throwValue(error_val);
            return moduleResolutionError(err);
        };
    }

    var module_var_refs: []core.JSValue = &.{};
    if (has_module_record) {
        module_var_refs = try module_exec.buildModuleVarRefs(ctx, module_name, &compiled.function);
    }
    defer module_exec.freeModuleVarRefs(rt, module_var_refs);

    const result = if (has_module_record)
        try runEvalModuleWithVarRefs(ctx, &compiled.function, options.output, module_var_refs, options.timing)
    else blk: {
        const vm_start = monotonicNanos();
        var stack = stack_mod.Stack.init(&rt.memory, ctx.stack_limit);
        defer stack.deinit(rt);
        try stack.reserveAdditional(compiled.function.stack_size);
        const value = try zjs_vm.runWithOutput(ctx, &stack, &compiled.function, options.output);
        if (options.timing) |timing| timing.vm_run_ns += elapsedNanosSince(vm_start);
        break :blk value;
    };

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
    function: *const bytecode.Bytecode,
    output: ?*std.Io.Writer,
    module_var_refs: []const core.JSValue,
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

fn forceRuntimeStrict(function: *bytecode.Bytecode) void {
    function.flags.runtime_strict = true;
    for (function.constants.values) |value| forceFunctionBytecodeRuntimeStrict(value);
}

fn forceFunctionBytecodeRuntimeStrict(value: core.JSValue) void {
    if (!value.isFunctionBytecode()) return;
    const header = value.objectHeader() orelse return;
    const function_bytecode: *bytecode.FunctionBytecode = @fieldParentPtr("header", header);
    function_bytecode.runtime_strict_mode = true;
    for (function_bytecode.cpool) |child| forceFunctionBytecodeRuntimeStrict(child);
}

fn isWhitespaceSeparatedNumericScript(source_text: []const u8) bool {
    var saw_digit = false;
    var saw_space_after_digit = false;
    for (source_text) |ch| {
        if (std.ascii.isDigit(ch)) {
            if (saw_space_after_digit) return true;
            saw_digit = true;
        } else if (std.ascii.isWhitespace(ch)) {
            if (saw_digit) saw_space_after_digit = true;
        } else {
            return false;
        }
    }
    return false;
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

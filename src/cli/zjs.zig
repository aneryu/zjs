//! CLI boundary for script/module evaluation, host loading, job draining, and exception/rejection reporting.
//! Source buffers live through evaluation; `--leak-check` selects explicit event-loop, context, and runtime teardown.
const std = @import("std");
const cli_process = @import("cli_process.zig");
const engine = @import("zjs");
const simple_token = engine.simple_token;
const platform_clock = engine.platform_clock;
/// Message-only panics in ReleaseFast, full traces everywhere else.
/// See `panic_policy.zig` for why the shipped binary drops the symbolizer.
pub const panic = @import("panic_policy.zig").policy;

// QCP-1: this root is shared by `zjs` (ReleaseFast), `zjs-profile`
// (ReleaseFast) and `zjs-dev` (Debug), so it proves the effective
// configuration of the shipped binary itself at compile time, each reporting
// its own optimize mode (src/config_signature.zig). `--print-config-signature`
// below is the runtime half of the same statement.
comptime {
    engine.config_signature.attest("zjs CLI");
}

const public_api = engine.public_api;
const zjs = public_api;
const runtime_layer = public_api.runtime;

const Runtime = struct {
    runtime: *zjs.JSRuntime,
    context: *zjs.JSContext,
    event_loop: runtime_layer.EventLoop,

    pub fn deinit(self: *Runtime) void {
        self.event_loop.deinit();
        self.context.destroy();
        self.runtime.destroy();
    }
};

const max_source_size = 64 * 1024 * 1024;
const max_include_paths = 16;

pub const CliError = error{
    Usage,
};

pub const Command = union(enum) {
    eval: EvalCommand,
    file: FileCommand,
};

pub const RuntimeOptions = struct {
    memory_limit: ?usize = null,
    stack_size: ?usize = null,
    can_block: bool = false,
    dump_memory: bool = false,
    trace_memory: bool = false,
    profile_opcodes: bool = false,
    gc_stats: bool = false,
    perf_json: bool = false,
    leak_check: bool = false,
    include_paths: [max_include_paths][]const u8 = @splat(""),
    include_count: usize = 0,
    /// Shadow-only. Void in default `rc` so this struct's layout is unchanged.
    gc_shadow_check: if (engine.core.gc.shadow_tracer_enabled) bool else void =
        if (engine.core.gc.shadow_tracer_enabled) false else {},

    fn addInclude(self: *RuntimeOptions, path: []const u8) !void {
        if (self.include_count == self.include_paths.len) return error.TooManyIncludes;
        self.include_paths[self.include_count] = path;
        self.include_count += 1;
    }

    fn includes(self: *const RuntimeOptions) []const []const u8 {
        return self.include_paths[0..self.include_count];
    }
};

pub const EvalCommand = struct {
    source: []const u8,
    options: RuntimeOptions = .{},
};

pub const FileCommand = struct {
    path: []const u8,
    script_args: []const []const u8,
    mode: zjs.context.EvalMode = .script,
    options: RuntimeOptions = .{},
};

pub fn parseArgs(args: []const []const u8) CliError!Command {
    var rest = args;
    var options = RuntimeOptions{};
    while (rest.len != 0) {
        if (std.mem.eql(u8, rest[0], "--can-block")) {
            options.can_block = true;
            rest = rest[1..];
            continue;
        }
        if (std.mem.eql(u8, rest[0], "-d") or std.mem.eql(u8, rest[0], "--dump")) {
            options.dump_memory = true;
            rest = rest[1..];
            continue;
        }
        if (std.mem.eql(u8, rest[0], "-T") or std.mem.eql(u8, rest[0], "--trace")) {
            options.trace_memory = true;
            rest = rest[1..];
            continue;
        }
        if (std.mem.eql(u8, rest[0], "--gc-stats")) {
            options.gc_stats = true;
            // The panel's census costs six whole-heap walks per major, so the
            // collector only performs them when someone is going to read them.
            engine.core.gc_trace_stw.detailed_reports = true;
            rest = rest[1..];
            continue;
        }
        if (comptime engine.core.gc.shadow_tracer_enabled) {
            if (std.mem.eql(u8, rest[0], "--gc-shadow-check")) {
                options.gc_shadow_check = true;
                rest = rest[1..];
                continue;
            }
        }
        if (std.mem.eql(u8, rest[0], "--profile-opcodes")) {
            options.profile_opcodes = true;
            rest = rest[1..];
            continue;
        }
        if (std.mem.eql(u8, rest[0], "--perf-json")) {
            options.perf_json = true;
            rest = rest[1..];
            continue;
        }
        if (std.mem.eql(u8, rest[0], "--leak-check")) {
            options.leak_check = true;
            rest = rest[1..];
            continue;
        }
        if (std.mem.eql(u8, rest[0], "--memory-limit")) {
            if (rest.len < 2) return error.Usage;
            options.memory_limit = parseLimitKBytes(rest[1]) catch return error.Usage;
            rest = rest[2..];
            continue;
        }
        if (std.mem.eql(u8, rest[0], "--stack-size")) {
            if (rest.len < 2) return error.Usage;
            options.stack_size = parseLimitKBytes(rest[1]) catch return error.Usage;
            rest = rest[2..];
            continue;
        }
        if (std.mem.eql(u8, rest[0], "-I") or std.mem.eql(u8, rest[0], "--include")) {
            if (rest.len < 2) return error.Usage;
            options.addInclude(rest[1]) catch return error.Usage;
            rest = rest[2..];
            continue;
        }
        break;
    }
    if (rest.len == 0) {
        return error.Usage;
    }
    if (std.mem.eql(u8, rest[0], "-h") or std.mem.eql(u8, rest[0], "--help")) return error.Usage;
    if (std.mem.eql(u8, rest[0], "-e")) {
        if (options.can_block or rest.len != 2) return error.Usage;
        return .{ .eval = .{ .source = rest[1], .options = options } };
    }
    if (std.mem.eql(u8, rest[0], "-m")) {
        if (rest.len < 2) return error.Usage;
        return .{ .file = .{ .path = rest[1], .script_args = rest[1..], .mode = .module, .options = options } };
    }
    if (rest[0].len != 0 and rest[0][0] != '-') {
        return .{ .file = .{ .path = rest[0], .script_args = rest[0..], .options = options } };
    }
    return error.Usage;
}

fn runFileModule(
    ctx: *zjs.JSContext,
    source_text: []const u8,
    output: *std.Io.Writer,
    path: []const u8,
    io: std.Io,
    allocator: std.mem.Allocator,
    max_size: usize,
) !zjs.JSValue {
    return try runtime_layer.evalFileModuleGraphWithOutput(ctx, source_text, output, path, io, allocator, max_size);
}

pub fn main(init: std.process.Init) !void {
    const total_start = platform_clock.monotonicNanos();
    setupHostDispatchStatsExitDump(init.environ_map);
    setupV2OracleReportExitDump(init.environ_map);
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try cli_process.argsToSlice(arena, init.minimal.args);

    // QCP-1 configuration signature. Answered before any engine construction
    // so it is readable from every configuration, including instrumented
    // tiers, and so `zig build config-signature-check` can compare the
    // shipped binary's own answer against what the build graph requested.
    if (args.len >= 2 and std.mem.eql(u8, args[1], config_signature_flag)) {
        try printConfigSignature(io);
        return;
    }

    const command = parseArgs(args[1..]) catch {
        try printUsage(io);
        std.process.exit(2);
    };

    var read_source_ns: u64 = 0;
    const source_text = switch (command) {
        .eval => |eval| eval.source,
        .file => |file| source: {
            const read_start = platform_clock.monotonicNanos();
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, file.path, allocator, .limited(max_source_size)) catch |err| {
                try cli_process.printError(io, "zjs: unable to read {s}: {s}\n", .{ file.path, @errorName(err) });
                std.process.exit(1);
            };
            read_source_ns = platform_clock.elapsedNanosSince(read_start);
            break :source bytes;
        },
    };
    defer if (command == .file) allocator.free(source_text);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    var opcode_profile = zjs.OpcodeProfile{};
    var eval_timing = zjs.context.EvalTiming{};
    var include_ns: u64 = 0;
    var setup_ns: u64 = 0;
    var eval_ns: u64 = 0;
    var jobs_ns: u64 = 0;
    const runtime_start = platform_clock.monotonicNanos();
    const rt = zjs.JSRuntime.createWithOptions(allocator, .{
        .trace_writer = if (commandRuntimeOptions(command).trace_memory) &stdout_writer.interface else null,
        .memory_limit = commandRuntimeOptions(command).memory_limit,
        .gc_threshold = zjs.default_gc_threshold,
        .stack_size = commandRuntimeOptions(command).stack_size orelse zjs.default_stack_size,
    }) catch |err| {
        try cli_process.printError(io, "zjs: engine init failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    errdefer rt.destroy();
    const ctx = zjs.JSContext.create(rt) catch |err| {
        try cli_process.printError(io, "zjs: context init failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    errdefer ctx.destroy();
    var runtime = Runtime{
        .runtime = rt,
        .context = ctx,
        .event_loop = runtime_layer.EventLoop.init(ctx, .{ .output = &stdout_writer.interface }),
    };
    runtime.event_loop.install();
    errdefer runtime.event_loop.deinit();

    const runtime_create_ns = platform_clock.elapsedNanosSince(runtime_start);
    const setup_start = platform_clock.monotonicNanos();
    applyRuntimeOptions(&runtime, commandRuntimeOptions(command));
    runtime.context.setTrackUnhandledRejections(commandTracksUnhandledRejections(command));
    const runtime_options = commandRuntimeOptions(command);
    if (runtime_options.profile_opcodes) {
        if (!zjs.opcode_profile_build_enabled) {
            try cli_process.printError(io, "zjs: --profile-opcodes requires a profiling build; run 'zig build zjs-profile' or rebuild with -Dzjs_enable_opcode_profile=true (refusing to emit an all-zero profile)\n", .{});
            std.process.exit(2);
        }
        runtime.runtime.setOpcodeProfile(&opcode_profile);
    } else if (runtime_options.perf_json) {
        _ = zjs.activateOpcodeProfile(&opcode_profile);
    }
    zjs.host.defineScriptArgs(runtime.context, commandScriptArgs(command)) catch |err| {
        try cli_process.printError(io, "zjs: scriptArgs setup failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    runtime.context.setPreserveUncaughtException(true);
    // Install the file-loader dynamic import for every mode, mirroring qjs
    // installing js_module_loader unconditionally (qjs.c JS_SetModuleLoaderFunc):
    // import() works from scripts and -e, not only under -m. The state lives
    // for the whole process, so import jobs drained after evaluation (event
    // loop turns) still resolve.
    var dynamic_import_state = engine.exec.module_graph.DynamicImportState{
        .runtime = runtime.context.runtimePtr(),
        .output = &stdout_writer.interface,
        .io = io,
        .allocator = allocator,
        .max_source_size = max_source_size,
    };
    var dynamic_import_scope = try engine.exec.module_graph.installDynamicImport(&dynamic_import_state);
    defer dynamic_import_scope.deinit();
    setup_ns = platform_clock.elapsedNanosSince(setup_start);
    // NB: we intentionally do NOT `defer runtime.deinit()` on the happy path.
    // `JSRuntime.destroy` asserts that the runtime has no outstanding
    // allocations, which catches refcounting bugs in `zig build test` where
    // the engine is used in-process. As a short-lived CLI process, zjs
    // returns from `main` and the OS reclaims memory a few microseconds
    // later; calling `deinit` here only exposes latent leaks to the
    // test262 runner, where the 2s panic+backtrace path caused many
    // otherwise-passing tests to be misreported as timeouts. The historical
    // validation note is preserved in the convergence docs' git history.
    const include_start = platform_clock.monotonicNanos();
    runIncludeFiles(&runtime, commandRuntimeOptions(command), &stdout_writer.interface, io, allocator) catch |err| {
        try exitIfRequested(&runtime, &stdout_writer.interface, err);
        if (runtime.context.hasException()) {
            try stdout_writer.interface.flush();
            try printEvaluationError(io, &runtime, err);
            std.process.exit(1);
        }
        try printEvaluationError(io, &runtime, err);
        std.process.exit(1);
    };
    include_ns = platform_clock.elapsedNanosSince(include_start);
    const eval_start = platform_clock.monotonicNanos();
    const value = switch (command) {
        .eval => runtime.context.eval(source_text, .{
            .mode = .script,
            .filename = "<eval>",
            .output = &stdout_writer.interface,
            .parse_strict = false,
            .runtime_strict = false,
            .discard_script_result = true,
            .timing = &eval_timing,
        }),
        .file => |file| if (detectFileMode(file.path, source_text, file.mode) == .module)
            runFileModule(runtime.context, source_text, &stdout_writer.interface, file.path, io, allocator, max_source_size)
        else
            runtime.context.eval(source_text, .{
                .mode = .script,
                .filename = file.path,
                .output = &stdout_writer.interface,
                .parse_strict = false,
                .runtime_strict = false,
                .discard_script_result = true,
                .timing = &eval_timing,
            }),
    } catch |err| {
        try exitIfRequested(&runtime, &stdout_writer.interface, err);
        if (runtime.context.hasException()) {
            try stdout_writer.interface.flush();
            try printEvaluationError(io, &runtime, err);
            if (comptime engine.core.gc.shadow_tracer_enabled) {
                exitAfterOptionalShadowCheck(&stdout_writer.interface, runtime.runtime, runtime_options, 1);
            }
            std.process.exit(1);
        }
        if (err == error.TypeError) {
            try stdout_writer.interface.flush();
            try printTypeErrorNotFunction(io, command);
            if (comptime engine.core.gc.shadow_tracer_enabled) {
                exitAfterOptionalShadowCheck(&stdout_writer.interface, runtime.runtime, runtime_options, 1);
            }
            std.process.exit(1);
        }
        try printEvaluationError(io, &runtime, err);
        if (comptime engine.core.gc.shadow_tracer_enabled) {
            exitAfterOptionalShadowCheck(&stdout_writer.interface, runtime.runtime, runtime_options, 1);
        }
        std.process.exit(1);
    };
    eval_ns = platform_clock.elapsedNanosSince(eval_start);
    try stdout_writer.interface.flush();

    if (value.isException()) {
        try cli_process.printError(io, "zjs: uncaught exception\n", .{});
        if (comptime engine.core.gc.shadow_tracer_enabled) {
            exitAfterOptionalShadowCheck(&stdout_writer.interface, runtime.runtime, runtime_options, 1);
        }
        std.process.exit(1);
    }

    const jobs_start = platform_clock.monotonicNanos();
    try dynamic_import_state.runJobs(runtime.context.core);
    // Post-eval jobs (module-mode microtasks in particular) print into the
    // buffered stdout writer; flush before any exit path so their output is
    // not dropped (qjs.c main: js_std_loop writes unbuffered per job).
    try stdout_writer.interface.flush();
    jobs_ns = platform_clock.elapsedNanosSince(jobs_start);
    if (runtime.context.hasUnhandledRejection() or runtime.context.hasException()) {
        // Mirrors qjs js_std_promise_rejection_check (quickjs-libc.c:4276-4290):
        // every still-unhandled rejection is reported, in rejection order,
        // before the process exits with 1. One shared stderr writer: fresh
        // per-report writers restart at position 0 on regular files.
        var stderr_buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
        const stderr = &stderr_writer.interface;
        while (true) {
            const exception = takePendingRejectionOrException(&runtime);
            try printUnhandledRejectionTo(stderr, &runtime, exception);
            exception.free(runtime.runtime);
            if (!runtime.context.hasUnhandledRejection()) break;
        }
        if (comptime engine.core.gc.shadow_tracer_enabled) {
            exitAfterOptionalShadowCheck(&stdout_writer.interface, runtime.runtime, runtime_options, 1);
        }
        std.process.exit(1);
    }

    if (commandRuntimeOptions(command).dump_memory) {
        try dumpMemoryUsage(&stdout_writer.interface, &runtime);
        try stdout_writer.interface.flush();
    }
    // The CLI does not tear the runtime down on the happy path, so the slab
    // never gets to report from its own `deinit`. The `comptime` guard is
    // load-bearing: an unguarded call to an empty function still moved the
    // refcounting build's `.text`, which is the one thing this measurement
    // instrument must not do.
    if (comptime engine.core.memory.slab_locality_audit) engine.core.memory.slabLocalityReport();
    if (commandRuntimeOptions(command).profile_opcodes) {
        opcode_profile.flushPendingDispatch();
        try dumpOpcodeProfile(&stdout_writer.interface, runtime.runtime.opcode_profile.?);
        try stdout_writer.interface.flush();
    }
    if (commandRuntimeOptions(command).gc_stats) {
        try dumpGcStats(&stdout_writer.interface, runtime.runtime.gcStats(), &runtime.runtime.gc);
        try dumpGcPauses(&stdout_writer.interface, runtime.runtime.gcPauseDistribution());
        if (comptime engine.core.gc.space_model_enabled) {
            try dumpGcSpaceStats(&stdout_writer.interface, &runtime.runtime.gc);
        }
        if (comptime engine.core.gc.block_heap_enabled) {
            try dumpGcBlockHeapStats(&stdout_writer.interface, &runtime.runtime.gc);
            try dumpGcParallelStats(&stdout_writer.interface, runtime.runtime);
            try dumpGcMarkFootprint(&stdout_writer.interface, runtime.runtime);
            try dumpGcPhaseTotals(&stdout_writer.interface, &runtime.runtime.gc);
        }
        if (comptime engine.core.gc.generation_enabled) {
            try dumpGcGenerationStats(&stdout_writer.interface, &runtime.runtime.gc);
        }
        if (comptime engine.core.gc.trace_stw_enabled) {
            try stdout_writer.interface.print("gc: terminal doomed_pending {s}\n", .{
                if (runtime.runtime.gc.doomed_pending) "true" else "false",
            });
        }
        if (comptime engine.core.gc.corpse_census_enabled) {
            try engine.core.gc_corpse_census.report(&stdout_writer.interface);
        }
        try stdout_writer.interface.flush();
    }
    if (comptime engine.core.gc.shadow_tracer_enabled) {
        if (commandRuntimeOptions(command).gc_shadow_check) {
            try runGcShadowCheck(&stdout_writer.interface, runtime.runtime);
        }
    }
    if (commandRuntimeOptions(command).perf_json) {
        opcode_profile.flushPendingDispatch();
        const active_profile: ?*const zjs.OpcodeProfile =
            if (commandRuntimeOptions(command).profile_opcodes) &opcode_profile else null;
        try dumpPerfJson(io, command, &runtime, active_profile, .{
            .total_ns = platform_clock.elapsedNanosSince(total_start),
            .read_source_ns = read_source_ns,
            .runtime_create_ns = runtime_create_ns,
            .setup_ns = setup_ns,
            .include_ns = include_ns,
            .eval_ns = eval_ns,
            .jobs_ns = jobs_ns,
            .zjs = eval_timing,
        });
    }

    // Explicit exit skips the remaining defers (source_text free, etc.) on the default path.
    // However, if leak checking is explicitly requested, we deinit the runtime
    // and return normally so all defers (including those for source_text and options) execute,
    // allowing the GeneralPurposeAllocator to perform full validation.
    engine.printSmallInlineProbe();
    if (runtime_options.leak_check) {
        // Restore the loader hook while the runtime it points at is still
        // alive. The trailing `defer dynamic_import_scope.deinit()` would
        // otherwise run after `runtime.deinit()` and touch a destroyed
        // runtime; `restore` is idempotent, so calling it here is safe and
        // the defer becomes a no-op.
        dynamic_import_scope.deinit();
        dynamic_import_state.deinit();
        runtime.deinit();
        return;
    }
    std.process.exit(0);
}

fn printUsage(io: std.Io) !void {
    if (comptime engine.core.gc.shadow_tracer_enabled) {
        try cli_process.printError(io, "usage: zjs [-d] [-T] [--profile-opcodes] [--gc-stats] [--gc-shadow-check] [--perf-json] [--leak-check] [--memory-limit n] [--stack-size n] [-I file] -e <script>\n       zjs [-d] [-T] [--profile-opcodes] [--gc-stats] [--gc-shadow-check] [--perf-json] [--leak-check] [--memory-limit n] [--stack-size n] [-I file] [-m] <file.js>\n       zjs " ++ config_signature_flag ++ "\n", .{});
        return;
    }
    try cli_process.printError(io, "usage: zjs [-d] [-T] [--profile-opcodes] [--gc-stats] [--perf-json] [--leak-check] [--memory-limit n] [--stack-size n] [-I file] -e <script>\n       zjs [-d] [-T] [--profile-opcodes] [--gc-stats] [--perf-json] [--leak-check] [--memory-limit n] [--stack-size n] [-I file] [-m] <file.js>\n       zjs " ++ config_signature_flag ++ "\n", .{});
}

fn runGcShadowCheck(out: *std.Io.Writer, rt: *zjs.JSRuntime) !void {
    if (comptime !engine.core.gc.shadow_tracer_enabled) return;
    engine.core.gc_shadow.quiesce(rt);
    const report = engine.core.gc_shadow.run(rt) catch |err| {
        try out.print("zjs: gc-shadow-check failed: {s}\n", .{@errorName(err)});
        try out.flush();
        std.process.exit(1);
    };
    try report.format(out);
    if (comptime engine.core.gc.shadow_tracer_enabled) {
        try engine.core.gc_write_audit.format(out);
    }
    try out.flush();
    if (report.unexplained != 0) std.process.exit(1);
}

fn exitAfterOptionalShadowCheck(
    out: *std.Io.Writer,
    rt: *zjs.JSRuntime,
    options: RuntimeOptions,
    exit_code: u8,
) noreturn {
    if (comptime engine.core.gc.shadow_tracer_enabled) {
        if (options.gc_shadow_check) {
            runGcShadowCheck(out, rt) catch std.process.exit(1);
        }
    }
    std.process.exit(exit_code);
}

/// Standalone query flag: it takes no script and constructs no runtime, so it
/// deliberately never reaches `parseArgs`.
const config_signature_flag = "--print-config-signature";

fn printConfigSignature(io: std.Io) !void {
    var stdout_buf: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}\n", .{engine.config_signature.signature});
    try stdout.flush();
}

fn commandRuntimeOptions(command: Command) RuntimeOptions {
    return switch (command) {
        .eval => |eval| eval.options,
        .file => |file| file.options,
    };
}

fn commandTracksUnhandledRejections(command: Command) bool {
    return switch (command) {
        .eval, .file => true,
    };
}

fn commandScriptArgs(command: Command) []const []const u8 {
    return switch (command) {
        .eval => &.{},
        .file => |file| file.script_args,
    };
}

fn applyRuntimeOptions(runtime: *Runtime, options: RuntimeOptions) void {
    runtime.runtime.setCanBlock(options.can_block);
    if (options.memory_limit) |limit| runtime.runtime.setMemoryLimit(limit);
    if (options.stack_size) |size| {
        runtime.runtime.setStackSize(size);
        runtime.context.setStackLimit(size);
    }
}

fn exitIfRequested(runtime: *Runtime, output: *std.Io.Writer, err: anyerror) !void {
    if (err != error.ProcessExit) return;
    const code = runtime.event_loop.exitCode() orelse return;
    try output.flush();
    std.process.exit(code);
}

fn runIncludeFiles(runtime: *Runtime, options: RuntimeOptions, output: *std.Io.Writer, io: std.Io, allocator: std.mem.Allocator) !void {
    for (options.includes()) |path| {
        const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_source_size));
        defer allocator.free(source);
        const mode = detectFileMode(path, source, .script);
        const result = if (mode == .module)
            try runFileModule(runtime.context, source, output, path, io, allocator, max_source_size)
        else
            try runtime.context.eval(source, .{
                .mode = .script,
                .filename = path,
                .output = output,
                .parse_strict = false,
                .runtime_strict = false,
                .discard_script_result = true,
            });
        result.free(runtime.runtime);
    }
}

fn parseLimitKBytes(text: []const u8) !usize {
    if (text.len == 0) return error.InvalidCharacter;
    const kbytes = try std.fmt.parseInt(usize, text, 10);
    return std.math.mul(usize, kbytes, 1024) catch error.Overflow;
}

fn detectFileMode(path: []const u8, source: []const u8, explicit_mode: zjs.context.EvalMode) zjs.context.EvalMode {
    if (explicit_mode == .module) return .module;
    if (std.mem.endsWith(u8, path, ".mjs")) return .module;
    return if (sourceLooksLikeModule(source)) .module else .script;
}

/// Mirrors qjs `JS_DetectModule` (quickjs.c:23792): after the shebang, only
/// the FIRST token decides — `import` not followed by `(` or `.`, or a
/// leading `export`. A late `export`/`import` no longer promotes the file to
/// module mode (it is a SyntaxError in script mode, as in qjs), and
/// `import.meta` / `import(...)` never promote.
fn sourceLooksLikeModule(source: []const u8) bool {
    var pos: usize = 0;
    skipShebang(source, &pos);
    switch (simple_token.next(source, &pos, false)) {
        .import_keyword => {
            const tok = simple_token.next(source, &pos, false);
            return tok != .dot and tok != .left_paren;
        },
        .export_keyword => return true,
        else => return false,
    }
}

/// Mirrors qjs `skip_shebang` (quickjs.c:23761).
fn skipShebang(source: []const u8, pos: *usize) void {
    if (source.len >= 2 and source[0] == '#' and source[1] == '!') {
        var index: usize = 2;
        while (index < source.len and source[index] != '\n' and source[index] != '\r') index += 1;
        pos.* = index;
    }
}

fn dumpMemoryUsage(output: *std.Io.Writer, runtime: *Runtime) !void {
    const memory = runtime.runtime.memoryUsage();

    try output.print("\nZJS memory usage\n", .{});
    try output.print("  memory limit: ", .{});
    if (memory.memory_limit) |limit| {
        try output.print("{d}\n", .{limit});
    } else {
        try output.print("0\n", .{});
    }
    try output.print("\nNAME                    COUNT     SIZE\n", .{});
    try output.print("{s:<22} {d:>5} {d:>8}\n", .{ "memory allocated", memory.allocation_count, memory.allocated_bytes });
    try output.print("{s:<22} {d:>5} {d:>8}\n", .{ "atoms", memory.atom_count, memory.atom_bytes });
    try output.print("{s:<22} {d:>5} {d:>8}\n", .{ "objects", memory.object_count, memory.object_bytes });
    try output.print("{s:<22} {d:>5} {d:>8}\n", .{ "shapes", memory.shape_count, memory.shape_bytes });
    try output.print("{s:<22} {d:>5} {d:>8}\n", .{ "modules", memory.module_count, memory.module_bytes });
    try output.print("{s:<22} {d:>5} {d:>8}\n", .{ "classes", memory.registered_class_count, memory.class_bytes });
}

const PerfJsonTimings = struct {
    total_ns: u64,
    read_source_ns: u64,
    runtime_create_ns: u64,
    setup_ns: u64,
    include_ns: u64,
    eval_ns: u64,
    jobs_ns: u64,
    zjs: zjs.context.EvalTiming,
};

fn dumpPerfJson(io: std.Io, command: Command, runtime: *Runtime, perf_profile: ?*const zjs.OpcodeProfile, timings: PerfJsonTimings) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    const memory = runtime.runtime.memoryUsage();

    try stderr.print("{{\n  \"file\": ", .{});
    try writeJsonString(stderr, commandPerfFile(command));
    try stderr.print(",\n", .{});
    try stderr.print("  \"total_ns\": {d},\n", .{timings.total_ns});
    try stderr.print("  \"read_source_ns\": {d},\n", .{timings.read_source_ns});
    try stderr.print("  \"runtime_create_ns\": {d},\n", .{timings.runtime_create_ns});
    try stderr.print("  \"setup_ns\": {d},\n", .{timings.setup_ns});
    try stderr.print("  \"include_ns\": {d},\n", .{timings.include_ns});
    try stderr.print("  \"eval_ns\": {d},\n", .{timings.eval_ns});
    try stderr.print("  \"parse_ns\": {d},\n", .{timings.zjs.parse_ns});
    try stderr.print("  \"finalize_ns\": null,\n", .{});
    try stderr.print("  \"parse_ns_includes_finalize\": true,\n", .{});
    try stderr.print("  \"vm_run_ns\": {d},\n", .{timings.zjs.vm_run_ns});
    try stderr.print("  \"promise_jobs_ns\": {d},\n", .{timings.zjs.promise_jobs_ns});
    try stderr.print("  \"jobs_ns\": {d},\n", .{timings.jobs_ns});
    try stderr.print("  \"memory\": {{\n", .{});
    try stderr.print("    \"allocated_bytes\": {d},\n", .{memory.allocated_bytes});
    try stderr.print("    \"allocation_count\": {d},\n", .{memory.allocation_count});
    try stderr.print("    \"allocated_bytes_peak\": {d},\n", .{memory.peak_allocated_bytes});
    try stderr.print("    \"allocation_count_peak\": {d},\n", .{memory.peak_allocation_count});
    try stderr.print("    \"alloc_calls\": {d},\n", .{memory.alloc_calls});
    try stderr.print("    \"free_calls\": {d},\n", .{memory.free_calls});
    try stderr.print("    \"create_calls\": {d},\n", .{memory.create_calls});
    try stderr.print("    \"destroy_calls\": {d}\n", .{memory.destroy_calls});
    try stderr.print("  }}", .{});
    try stderr.print(",\n  \"opcode_profile_enabled\": {}", .{perf_profile != null});
    if (perf_profile) |profile| {
        try stderr.print(",\n", .{});
        try dumpPerfJsonOpcodeProfile(stderr, profile);
        try stderr.print(",\n", .{});
        try dumpPerfJsonIc(stderr, profile);
    }
    try stderr.print("\n}}\n", .{});
    try stderr.flush();
}

fn dumpPerfJsonOpcodeProfile(output: *std.Io.Writer, profile: *const zjs.OpcodeProfile) !void {
    ensureOpcodeProfileNames();

    var rows: [zjs.OpcodeProfile.opcode_count]OpcodeProfileRow = undefined;
    var row_count: usize = 0;
    for (profile.count, 0..) |count, opcode| {
        if (count == 0) continue;
        rows[row_count] = .{
            .opcode = @intCast(opcode),
            .count = count,
            .nanos = profile.nanos[opcode],
        };
        row_count += 1;
    }
    std.sort.heap(OpcodeProfileRow, rows[0..row_count], {}, opcodeProfileRowLessThan);

    try output.print("  \"opcode_profile\": {{\n", .{});
    try output.print("    \"opcodes_executed\": {d},\n", .{profile.totalOpcodeCount()});
    if (comptime zjs.opcode_profile_build_enabled) {
        try output.writeAll("    \"measured_ns\": \"not instrumented\",\n");
    } else {
        try output.print("    \"measured_ns\": {d},\n", .{profile.totalOpcodeNanos()});
    }
    if (comptime zjs.opcode_profile_build_enabled) {
        try output.writeAll("    \"value_dups\": \"not instrumented\",\n");
    } else {
        try output.print("    \"value_dups\": {d},\n", .{profile.value_dup_count});
    }
    try output.print("    \"value_frees\": {d},\n", .{profile.value_free_count});
    try output.print("    \"prop_lookups\": {d},\n", .{profile.prop_lookup_count});
    if (comptime zjs.opcode_profile_build_enabled) {
        try output.writeAll("    \"global_lookups\": \"not instrumented\",\n");
    } else {
        try output.print("    \"global_lookups\": {d},\n", .{profile.global_lookup_count});
    }
    if (comptime zjs.opcode_profile_build_enabled) {
        try output.writeAll("    \"allocations\": \"not instrumented\",\n");
        try output.writeAll("    \"call_frames\": \"not instrumented\",\n");
    } else {
        try output.print("    \"allocations\": {d},\n", .{profile.alloc_count});
        try output.print("    \"call_frames\": {d},\n", .{profile.call_frame_count});
    }
    try output.writeAll("    \"opcodes\": [");
    for (rows[0..row_count], 0..) |row, index| {
        if (index != 0) try output.writeByte(',');
        const name = zjs.OpcodeProfile.opcodeName(row.opcode);
        const display_name = if (name.len == 0) "<invalid>" else name;
        const avg = if (row.count == 0) 0 else row.nanos / row.count;
        try output.print("\n      {{\"opcode\": {d}, \"name\": ", .{row.opcode});
        try writeJsonString(output, display_name);
        if (comptime zjs.opcode_profile_build_enabled) {
            try output.print(", \"count\": {d}, \"nanos\": \"not instrumented\", \"avg_ns\": \"not instrumented\", \"slow\": \"not instrumented\"}}", .{row.count});
        } else {
            try output.print(", \"count\": {d}, \"nanos\": {d}, \"avg_ns\": {d}, \"slow\": {d}}}", .{ row.count, row.nanos, avg, profile.slow_count[row.opcode] });
        }
    }
    if (row_count != 0) try output.writeByte('\n');
    try output.writeAll("    ]\n  }");
}

fn dumpPerfJsonIc(output: *std.Io.Writer, profile: *const zjs.OpcodeProfile) !void {
    if (comptime zjs.opcode_profile_build_enabled) {
        try output.print("  \"ic\": {{\n", .{});
        try output.writeAll("    \"hit\": \"not instrumented\",\n");
        try output.writeAll("    \"miss\": \"not instrumented\",\n");
        try output.writeAll("    \"invalidate\": \"not instrumented\",\n");
        try output.writeAll("    \"promote_poly\": \"not instrumented\",\n");
        try output.writeAll("    \"promote_mega\": \"not instrumented\"\n");
        try output.print("  }},\n", .{});
        try output.writeAll("  \"ic_hit\": \"not instrumented\",\n");
        try output.writeAll("  \"ic_miss\": \"not instrumented\",\n");
        try output.writeAll("  \"ic_invalidate\": \"not instrumented\",\n");
        try output.writeAll("  \"ic_promote_poly\": \"not instrumented\",\n");
        try output.writeAll("  \"ic_promote_mega\": \"not instrumented\"");
        return;
    }
    try output.print("  \"ic\": {{\n", .{});
    try output.print("    \"hit\": {d},\n", .{profile.totalIcHit()});
    try output.print("    \"miss\": {d},\n", .{profile.totalIcMiss()});
    try output.print("    \"invalidate\": {d},\n", .{profile.totalIcInvalidate()});
    try output.print("    \"promote_poly\": {d},\n", .{profile.totalIcPromotePoly()});
    try output.print("    \"promote_mega\": {d}\n", .{profile.totalIcPromoteMega()});
    try output.print("  }},\n", .{});
    try output.writeAll("  \"ic_hit\": ");
    try writeJsonU64Array(output, &profile.ic_hit);
    try output.writeAll(",\n  \"ic_miss\": ");
    try writeJsonU64Array(output, &profile.ic_miss);
    try output.writeAll(",\n  \"ic_invalidate\": ");
    try writeJsonU64Array(output, &profile.ic_invalidate);
    try output.writeAll(",\n  \"ic_promote_poly\": ");
    try writeJsonU64Array(output, &profile.ic_promote_poly);
    try output.writeAll(",\n  \"ic_promote_mega\": ");
    try writeJsonU64Array(output, &profile.ic_promote_mega);
}

fn writeJsonU64Array(output: *std.Io.Writer, values: *const [zjs.OpcodeProfile.opcode_count]u64) !void {
    try output.writeByte('[');
    for (values.*, 0..) |value, index| {
        if (index != 0) try output.writeByte(',');
        try output.print("{d}", .{value});
    }
    try output.writeByte(']');
}

fn commandPerfFile(command: Command) []const u8 {
    return switch (command) {
        .eval => "<eval>",
        .file => |file| file.path,
    };
}

fn writeJsonString(output: *std.Io.Writer, bytes: []const u8) !void {
    try output.writeByte('"');
    for (bytes) |byte| {
        switch (byte) {
            '"' => try output.writeAll("\\\""),
            '\\' => try output.writeAll("\\\\"),
            '\n' => try output.writeAll("\\n"),
            '\r' => try output.writeAll("\\r"),
            '\t' => try output.writeAll("\\t"),
            else => {
                if (byte < 0x20) {
                    try output.print("\\u{x:0>4}", .{byte});
                } else {
                    try output.writeByte(byte);
                }
            },
        }
    }
    try output.writeByte('"');
}

const OpcodeProfileRow = struct {
    opcode: u8,
    count: u64,
    nanos: u64,
};

/// Post-run GC counters. Every line here has a maintained write site in the
/// collector; fields the engine does not instrument are simply absent rather
/// than printed as zero.
fn dumpGcSpaceStats(writer: *std.Io.Writer, registry: *const engine.core.gc.Registry) !void {
    if (comptime engine.core.gc.space_model_enabled) {
        const space = engine.core.gc_space;
        const hist = registry.space_histogram;
        const p50 = hist.percentilePayloadBelowLarge(50);
        const p95 = hist.percentilePayloadBelowLarge(95);
        const p99 = hist.percentilePayloadBelowLarge(99);
        try writer.print(
            "gc: allocation histogram publications {d}, payload bytes {d}, p50-below-large {d}, p95-below-large {d}, p99-below-large {d}, max-small {d}, covered-by-small {d}/{d} below-large, large {d}\n",
            .{
                hist.total,
                hist.bytes_total,
                p50,
                p95,
                p99,
                space.max_small_payload,
                hist.coveredByMaxSmall(),
                hist.belowLarge(),
                hist.large,
            },
        );
    }
}

/// Generational counters. `remembered without young` is the one to watch: it
/// counts owners a minor re-traced that turned out to hold no young child, so
/// a large share means the write barrier is firing more than it needs to.
fn dumpGcGenerationStats(writer: *std.Io.Writer, registry: *engine.core.gc.Registry) !void {
    const st = registry.generation.stats;
    try writer.print("gc: generation current young {d}, remembered owners {d}\n", .{
        st.young_count,
        registry.generation.rememberedOwnerCount(),
    });
    try writer.print("gc: minor collections {d}, reclaimed {d}, promoted-by-minor {d}, promoted-all {d}, remembered without young {d}, remembered drops {d}, suspensions {d}\n", .{
        st.minor_collections,
        st.minor_reclaimed,
        st.minor_promoted,
        st.promoted,
        st.remembered_without_young,
        st.remembered_drops,
        st.minor_suspensions,
    });
    try writer.print("gc: major retirement commits {d}, abandons {d}, current state {s}\n", .{
        st.retirement_commits,
        st.retirement_abandons,
        @tagName(registry.generation.major_retirement),
    });
    try writer.print("gc: generational barrier calls {d}, exit young-owner {d}, exit old-target {d}, remembered-owner {d}\n", .{
        st.barrier_calls,
        st.barrier_young_owner,
        st.barrier_old_target,
        st.barrier_calls -| st.barrier_young_owner -| st.barrier_old_target,
    });
    const mean_pause = if (st.minor_collections == 0) 0 else st.pause_ns_total / st.minor_collections;
    const mean_young = if (st.minor_collections == 0) 0 else st.young_at_start_total / st.minor_collections;
    try writer.print("gc: minor stw total {d} ns, mean {d} ns, max {d} ns\n", .{ st.pause_ns_total, mean_pause, st.pause_ns_max });
    if (registry.generation.minorPauseDistribution()) |d| {
        try writer.print("gc: minor pause p50 {d} ns, p95 {d} ns, p99 {d} ns, max {d} ns over {d} retained of {d} samples\n", .{
            d.p50_ns,
            d.p95_ns,
            d.p99_ns,
            d.max_ns,
            d.samples_retained,
            d.samples_total,
        });
    } else {
        try writer.print("gc: minor pause distribution unavailable, sample drops {d}\n", .{registry.generation.minor_pause_sample_drops});
    }
    try writer.print(
        "gc: minor phase totals clear {d}, roots {d}, conservative {d}, remembered {d}, trace {d}, sweep+destroy {d}, promote {d}, other {d} ns\n",
        .{
            st.minor_clear_ns_total,
            st.minor_roots_ns_total,
            st.minor_conservative_ns_total,
            st.minor_remembered_ns_total,
            st.minor_trace_ns_total,
            st.minor_sweep_ns_total,
            st.minor_promote_ns_total,
            st.pause_ns_total -| st.minorPhaseNsTotal(),
        },
    );
    try writer.print("gc: minor young-at-start mean {d}, max {d}\n", .{
        mean_young,
        st.young_at_start_max,
    });
    if (engine.core.gc.verify_minor) {
        try writer.print("gc: conservative-only young {d} over {d} verified minors\n", .{
            st.conservative_only_young,
            st.minor_collections,
        });
    } else {
        try writer.print("gc: conservative-only young unavailable (set ZJS_GC_VERIFY_MINOR=1)\n", .{});
    }
    if (comptime engine.core.gc.concurrent_enabled) {
        const cs = registry.concurrent.stats;
        try writer.print(
            "gc: exact-target marking barrier calls {d}, exit marked-target {d}, exit unpublished-owner {d}, exit unpublished-target {d}, requeued-owner {d}, shaded-target {d}\n",
            .{
                cs.barrier_calls,
                cs.barrier_marked_target,
                cs.barrier_unpublished_owner,
                cs.barrier_unpublished_target,
                cs.barrier_requeued_owner,
                cs.shaded,
            },
        );
        try writer.print("gc: incremental doomed condemned headers {d}, destroyed counted objects {d}, parked entries drained {d}, parked-drain slices {d}\n", .{
            cs.doomed_condemned_headers,
            cs.doomed_destroyed_objects,
            cs.doomed_parked_entries_drained,
            cs.doomed_parked_drain_slices,
        });
        try writer.print(
            "gc: incremental major cycles completed {d}, aborted {d}, forced {d}, mark steps {d}, cycle STW last {d} ns max {d} ns\n",
            .{ cs.cycles_completed, cs.cycles_aborted, cs.forced_finishes, cs.increments, cs.last_cycle_stw_ns, cs.max_cycle_stw_ns },
        );
        if (comptime engine.core.gc.sticky_major_enabled) {
            const sticky = registry.stickyMajorStats();
            const baseline = registry.stickyMajorFullBaseline();
            try writer.print(
                "gc: sticky-major experiment arm {s}, full {d}, sticky {d}, pressure-forced full {d}, last-full settled {d}, full-pressure threshold {d}, oracle checks sticky {d} full {d}, violations precise {d} conservative-only {d}, inject-skip {d}\n",
                .{
                    if (engine.core.gc.sticky_major_on) "on" else "off",
                    sticky.full_cycles,
                    sticky.sticky_cycles,
                    sticky.full_forced_by_pressure,
                    baseline.settled_bytes,
                    baseline.pressure_threshold,
                    sticky.oracle_checks_sticky,
                    sticky.oracle_checks_full,
                    sticky.oracle_violations_precise,
                    sticky.oracle_violations_conservative,
                    engine.core.gc.sticky_inject_skip,
                },
            );
            try writer.print(
                "gc: sticky-major floating garbage max {d} bytes, sum {d} bytes over {d} sticky cycles, max ordinary threshold {d}\n",
                .{
                    sticky.max_sticky_excess_bytes,
                    sticky.sum_sticky_excess_bytes,
                    sticky.sticky_cycles,
                    sticky.max_ordinary_threshold,
                },
            );
        }
        try writer.print(
            "gc: cycle envelope measured {d}, skipped {d}, max-P/T S {d}, T {d}, B {d}, P {d}, B/T-x1000000 {d}, P/T-x1000000 {d}, P/S-x1000000 {d}, forced {d}\n",
            .{
                cs.envelope_measured_cycles,
                cs.envelope_skipped_cycles,
                cs.envelope_max_start_bytes,
                cs.envelope_max_threshold_bytes,
                cs.envelope_max_begin_bytes,
                cs.envelope_max_peak_bytes,
                engine.core.gc.concurrent.envelopeBeginOverThresholdMillionths(cs),
                engine.core.gc.concurrent.envelopePeakOverThresholdMillionths(cs),
                engine.core.gc.concurrent.envelopePeakOverStartMillionths(cs),
                cs.forced_finishes,
            },
        );
        try writer.print(
            "gc: incremental STW phase-segment max ns begin {d}, increment {d}, destroy {d}, finish {d}\n",
            .{ cs.segment_max_ns[0], cs.segment_max_ns[1], cs.segment_max_ns[2], cs.segment_max_ns[3] },
        );
        if (engine.core.gc_trace_stw.destroy_probe) {
            try writer.print(
                "gc: destroy probe destructor {d} ns, parked-drain {d} ns, condemned headers {d}\n",
                .{
                    engine.core.gc_trace_stw.destroy_probe_dtor_ns,
                    engine.core.gc_trace_stw.destroy_probe_drain_ns,
                    engine.core.gc_trace_stw.destroy_probe_corpses,
                },
            );
        }
        try writer.print(
            "gc: incremental STW phase totals begin {d} ns/{d} segments, increment {d} ns/{d} segments, destroy {d} ns/{d} segments, finish {d} ns/{d} segments\n",
            .{
                cs.total_stw_by_kind[0], cs.total_segments_by_kind[0],
                cs.total_stw_by_kind[1], cs.total_segments_by_kind[1],
                cs.total_stw_by_kind[2], cs.total_segments_by_kind[2],
                cs.total_stw_by_kind[3], cs.total_segments_by_kind[3],
            },
        );
    }
}

fn dumpGcBlockHeapStats(writer: *std.Io.Writer, registry: *const engine.core.gc.Registry) !void {
    if (comptime engine.core.gc.block_heap_enabled) {
        const st = registry.block_heap.stats;
        try writer.print(
            "gc: block heap committed {d} live {d} committed/live-x1000 {d} superblocks {d} large maps {d}\n",
            .{
                st.committed_bytes,
                registry.block_heap.liveBytes(),
                registry.block_heap.committedLiveMilli(),
                st.superblocks,
                st.large_maps,
            },
        );
        const census = registry.block_heap.census();
        try writer.print(
            "gc: block heap topology classed superblocks {d}, medium superblocks {d}, initialized blocks {d}, reserved-uninitialized blocks {d}, nonempty blocks {d}, partially-full blocks {d}, empty-free blocks {d}, empty-active blocks {d}, decommitted-empty blocks {d}, wholly-empty superblocks {d}, hot-reuse blocks {d}, interval-active blocks {d}\n",
            .{
                census.classed_superblocks,
                census.medium_superblocks,
                census.initialized_blocks,
                census.reserved_uninitialized_blocks,
                census.nonempty_blocks,
                census.partially_full_blocks,
                census.empty_free_blocks,
                census.empty_active_blocks,
                census.decommitted_empty_blocks,
                census.wholly_empty_superblocks,
                census.hot_reuse_blocks,
                census.interval_active_blocks,
            },
        );
        try writer.print(
            "gc: block heap cell capacity live {d}, nonempty capacity {d}, empty capacity {d}, within-nonempty-unused {d}\n",
            .{
                census.live_cell_bytes,
                census.nonempty_cell_capacity_bytes,
                census.empty_cell_capacity_bytes,
                census.nonempty_cell_capacity_bytes -| census.live_cell_bytes,
            },
        );
        for (engine.core.gc_space.classes, 0..) |cell_size, class_idx| {
            const class = census.classes[class_idx];
            if (class.initialized_blocks == 0) continue;
            try writer.print(
                "gc: block heap class {d} bytes initialized {d}, nonempty {d}, empty-free {d}, empty-active {d}, live-cells {d}, capacity-cells {d}\n",
                .{
                    cell_size,
                    class.initialized_blocks,
                    class.nonempty_blocks,
                    class.empty_free_blocks,
                    class.empty_active_blocks,
                    class.live_cells,
                    class.cell_capacity,
                },
            );
        }
        try writer.print(
            "gc: block heap deferred block runs {d}, hot reuse published {d}, reopened {d}, pass-A settled cells {d}\n",
            .{ st.deferred_block_runs_completed, st.hot_blocks_published, st.hot_blocks_reopened, st.passa_settled_cells },
        );
        try writer.print(
            "gc: major threshold resets growth {d}, small-heap-floor {d}\n",
            .{ registry.stats.threshold_growth_hits, registry.stats.threshold_floor_hits },
        );
        try writer.print(
            "gc: block heap page returns cumulative decommitted {d}, recommitted {d}\n",
            .{ st.decommitted_bytes, st.recommitted_bytes },
        );
        try writer.print(
            "gc: block heap decommit checks {d}, released blocks cumulative {d}, current bytes {d}, max batch bytes {d}\n",
            .{
                st.decommit_checks,
                st.decommitted_bytes / (engine.core.gc_block_heap.block_bytes - engine.core.gc_block_heap.page_bytes),
                st.currentDecommittedBytes(),
                st.decommit_max_batch_bytes,
            },
        );
        try writer.print(
            "gc: process heap trim attempts {d}, successes {d}\n",
            .{ st.malloc_trim_attempts, st.malloc_trim_successes },
        );
    }
}

fn dumpGcPhaseTotals(writer: *std.Io.Writer, registry: *const engine.core.gc.Registry) !void {
    if (comptime engine.core.gc.trace_stw_enabled) {
        const ph = registry.concurrent.stats;
        try writer.print(
            "gc: incremental subphase ns totals begin-clear {d}, begin-precise-seed {d}, begin-conservative-seed {d}, begin-retire {d}, finish-remark-total {d}, finish-conservative-seed-subset {d}, finish-weak {d}, finish-condemn {d}\n",
            .{
                ph.phase_begin_clear_ns,
                ph.phase_begin_precise_seed_ns,
                ph.phase_begin_conservative_seed_ns,
                ph.phase_begin_retire_ns,
                ph.phase_finish_remark_ns,
                ph.phase_finish_conservative_seed_ns,
                ph.phase_finish_weak_ns,
                ph.phase_finish_condemn_ns,
            },
        );
        try writer.print(
            "gc: incremental subphase work totals retired non-block headers {d}, retired young blocks {d}, retired remembered sets {d}, clearMarks non-block headers {d}\n",
            .{ ph.phase_retired_nonblock_headers, ph.phase_retired_young_blocks, ph.phase_retired_remembered_sets, ph.phase_cleared_nonblock_headers },
        );
    }
}

fn dumpGcParallelStats(writer: *std.Io.Writer, rt: *const engine.core.JSRuntime) !void {
    if (comptime engine.core.gc.trace_stw_enabled) {
        const ps = rt.gc_mark_pool.stats;
        if (ps.parallel_slices == 0 and rt.gc_mark_pool.count == 0) return;
        try writer.print(
            "gc: parallel mark claims workers {d}, slices {d}, owner successful {d}, helpers successful {d}\n",
            .{ rt.gc_mark_pool.count, ps.parallel_slices, ps.owner_marked, ps.worker_marked },
        );
    }
}

fn dumpGcMarkFootprint(writer: *std.Io.Writer, rt: *const engine.core.JSRuntime) !void {
    if (comptime engine.core.gc.trace_stw_enabled) {
        const fp = rt.gc_mark_pool.footprint;
        try writer.print(
            "gc: marked-set census majors {d}, headers {d}, block headers {d}, refcount-removed headers {d}\n",
            .{ fp.major_censuses, fp.marked_headers, fp.block_headers, fp.refcount_removed_headers },
        );
        try writer.print(
            "gc: marked-set kinds object {d}, function-bytecode {d}, var-ref {d}, realm-context {d}, module {d}, shape {d}\n",
            .{
                fp.by_kind[@intFromEnum(engine.core.gc.GcKind.object)],
                fp.by_kind[@intFromEnum(engine.core.gc.GcKind.function_bytecode)],
                fp.by_kind[@intFromEnum(engine.core.gc.GcKind.var_ref)],
                fp.by_kind[@intFromEnum(engine.core.gc.GcKind.realm_context)],
                fp.by_kind[@intFromEnum(engine.core.gc.GcKind.module)],
                fp.by_kind[@intFromEnum(engine.core.gc.GcKind.shape)],
            },
        );
        try writer.print(
            "gc: marked-set trace classes ordinary-object {d}, fast-array {d}, bytecode-function {d}, exotic-object {d}, non-object {d}\n",
            .{
                fp.by_trace_class[@intFromEnum(engine.core.gc_trace_stw.MarkTraceClass.ordinary_object)],
                fp.by_trace_class[@intFromEnum(engine.core.gc_trace_stw.MarkTraceClass.fast_array)],
                fp.by_trace_class[@intFromEnum(engine.core.gc_trace_stw.MarkTraceClass.bytecode_function)],
                fp.by_trace_class[@intFromEnum(engine.core.gc_trace_stw.MarkTraceClass.exotic_object)],
                fp.by_trace_class[@intFromEnum(engine.core.gc_trace_stw.MarkTraceClass.non_object)],
            },
        );
        inline for (std.meta.tags(engine.core.gc_trace_stw.MarkStorageComponent)) |component| {
            const aggregate = fp.storage[@intFromEnum(component)];
            try writer.print(
                "gc: mark storage {s} allocation-touches {d}, allocated-bytes {d}, touched-cache-lines {d}\n",
                .{ @tagName(component), aggregate.allocation_touches, aggregate.allocated_bytes, aggregate.touched_cache_lines },
            );
        }
        inline for (std.meta.tags(engine.core.gc_trace_stw.MarkTraceClass)) |trace_class| {
            const aggregate = fp.storage_by_trace_class[@intFromEnum(trace_class)];
            try writer.print(
                "gc: mark trace class storage {s} allocation-touches {d}, allocated-bytes {d}, touched-cache-lines {d}\n",
                .{ @tagName(trace_class), aggregate.allocation_touches, aggregate.allocated_bytes, aggregate.touched_cache_lines },
            );
        }
        inline for (engine.core.gc_trace_stw.MarkFootprint.inline_limits, 0..) |limit, index| {
            const plain_external = fp.inline_eligible_objects[index] -
                fp.inline_direct_objects[index] -
                fp.inline_tail_grown_external_objects[index];
            try writer.print(
                "gc: inline property upper slots {d}, eligible-objects {d}, direct-inline {d}, tail-grown-external {d}, plain-external {d}, external-allocated-bytes {d}, external-touched-cache-lines {d}\n",
                .{ limit, fp.inline_eligible_objects[index], fp.inline_direct_objects[index], fp.inline_tail_grown_external_objects[index], plain_external, fp.inline_property_bytes[index], fp.inline_property_cache_lines[index] },
            );
            const ordinary_plain_external = fp.inline_ordinary_eligible_objects[index] -
                fp.inline_ordinary_direct_objects[index] -
                fp.inline_ordinary_tail_grown_external_objects[index];
            try writer.print(
                "gc: inline ordinary property upper slots {d}, eligible-objects {d}, direct-inline {d}, tail-grown-external {d}, plain-external {d}, external-allocated-bytes {d}, external-touched-cache-lines {d}\n",
                .{ limit, fp.inline_ordinary_eligible_objects[index], fp.inline_ordinary_direct_objects[index], fp.inline_ordinary_tail_grown_external_objects[index], ordinary_plain_external, fp.inline_ordinary_property_bytes[index], fp.inline_ordinary_property_cache_lines[index] },
            );
        }
    }
}

fn dumpGcStats(writer: *std.Io.Writer, stats: zjs.GCStats, registry: *const engine.core.gc.Registry) !void {
    const minors = if (comptime engine.core.gc.generation_enabled)
        registry.generation.stats.minor_collections
    else
        0;
    try writer.print("gc: collection entries total {d}, major completed {d}, minor completed {d}, failed {d}\n", .{
        stats.collections,
        stats.major_gc_count,
        minors,
        stats.failed_collections,
    });
    try writer.print("gc: collector counted objects freed {d} (excludes bytecode), zero-ref drains {d}\n", .{
        stats.freed_objects,
        stats.zero_ref_drains,
    });
    try writer.print("gc: heap live {d} bytes, account peak {d} bytes\n", .{
        stats.heap_live_bytes,
        stats.peak_allocated_bytes,
    });
    // External is a separate reporting dimension, even where an ordinary
    // ArrayBuffer's engine-owned backing also overlaps the whole
    // MemoryAccount. The weighted debt is a pacing counter, not current live
    // bytes; printing both prevents either from being mistaken for the other.
    try writer.print(
        "gc: external bytes current {d}, peak {d}, token bytes {d} in {d} tokens, untracked bytes {d}, allocations {d}, frees {d}, invalid releases {d}, weighted debt {d}\n",
        .{
            stats.external_bytes,
            stats.peak_external_bytes,
            stats.external_token_bytes,
            stats.external_token_count,
            stats.external_untracked_bytes,
            stats.external_alloc_count,
            stats.external_free_count,
            stats.external_invalid_release_count,
            stats.allocation_debt,
        },
    );
    try writer.print("gc: weak refs current {d}, finalizer queue current {d}\n", .{
        stats.weak_ref_count,
        stats.finalizer_queue_length,
    });
}

/// Pause percentiles, or an explicit "no pauses" line. Never print zeros for
/// an empty distribution: a run that never stopped must not read like a run
/// that stopped instantly.
///
/// MAJOR collections only. Minors keep their own line below, because the two
/// populations are more than an order of magnitude apart and mixing them made
/// this p50 report a minor while claiming to report the whole-heap pause the
/// design target is written against.
fn dumpGcPauses(writer: *std.Io.Writer, distribution: ?zjs.GCPauseDistribution) !void {
    const d = distribution orelse {
        try writer.print("gc: major pauses none\n", .{});
        return;
    };
    const retained = @min(d.samples, engine.core.gc.pause_sample_capacity);
    try writer.print("gc: major pause p50 {d} ns, p95 {d} ns, p99 {d} ns, max {d} ns, retained {d} of {d} pauses\n", .{
        d.p50_ns,
        d.p95_ns,
        d.p99_ns,
        d.max_ns,
        retained,
        d.samples,
    });
}

fn dumpOpcodeProfile(output: *std.Io.Writer, profile: *const zjs.OpcodeProfile) !void {
    ensureOpcodeProfileNames();

    var rows: [zjs.OpcodeProfile.opcode_count]OpcodeProfileRow = undefined;
    var row_count: usize = 0;
    for (profile.count, 0..) |count, opcode| {
        if (count == 0) continue;
        rows[row_count] = .{
            .opcode = @intCast(opcode),
            .count = count,
            .nanos = profile.nanos[opcode],
        };
        row_count += 1;
    }

    std.sort.heap(OpcodeProfileRow, rows[0..row_count], {}, opcodeProfileRowLessThan);

    try output.print("\nZJS opcode profile\n", .{});
    try output.print("  opcodes executed: {d}\n", .{profile.totalOpcodeCount()});
    if (comptime zjs.opcode_profile_build_enabled) {
        try output.print("  measured ns:      not instrumented\n", .{});
    } else {
        try output.print("  measured ns:      {d}\n", .{profile.totalOpcodeNanos()});
    }
    if (comptime zjs.opcode_profile_build_enabled) {
        try output.print("  value dups:       not instrumented\n", .{});
    } else {
        try output.print("  value dups:       {d}\n", .{profile.value_dup_count});
    }
    try output.print("  value frees:      {d}\n", .{profile.value_free_count});
    try output.print("  prop lookups:     {d}\n", .{profile.prop_lookup_count});
    if (comptime zjs.opcode_profile_build_enabled) {
        try output.print("  global lookups:   not instrumented\n", .{});
    } else {
        try output.print("  global lookups:   {d}\n", .{profile.global_lookup_count});
    }
    if (comptime zjs.opcode_profile_build_enabled) {
        try output.print("  allocations:      not instrumented\n", .{});
        try output.print("  call frames:      not instrumented\n", .{});
        try output.print("  ic hits:          not instrumented\n", .{});
        try output.print("  ic misses:        not instrumented\n", .{});
        try output.print("  ic invalidations: not instrumented\n", .{});
        try output.print("  ic promote poly:  not instrumented\n", .{});
        try output.print("  ic promote mega:  not instrumented\n", .{});
        try output.print("\nOPCODE                 COUNT          TOTAL_NS           AVG_NS             SLOW\n", .{});
    } else {
        try output.print("  allocations:      {d}\n", .{profile.alloc_count});
        try output.print("  call frames:      {d}\n", .{profile.call_frame_count});
        try output.print("  ic hits:          {d}\n", .{profile.totalIcHit()});
        try output.print("  ic misses:        {d}\n", .{profile.totalIcMiss()});
        try output.print("  ic invalidations: {d}\n", .{profile.totalIcInvalidate()});
        try output.print("  ic promote poly:  {d}\n", .{profile.totalIcPromotePoly()});
        try output.print("  ic promote mega:  {d}\n", .{profile.totalIcPromoteMega()});
        try output.print("\nOPCODE                 COUNT      TOTAL_NS       AVG_NS       SLOW\n", .{});
    }

    // The default 40-row cap keeps the profile readable. `ZJS_PROFILE_ALL=1`
    // prints every executed opcode, which is what an opcode-space census
    // needs: the cold tail is exactly the part the cap hides.
    const print_all = if (std.c.getenv("ZJS_PROFILE_ALL")) |raw| blk: {
        const v = std.mem.span(raw);
        break :blk v.len != 0 and v[0] == '1';
    } else false;
    const limit = if (print_all) row_count else @min(row_count, 40);
    for (rows[0..limit]) |row| {
        const name = zjs.OpcodeProfile.opcodeName(row.opcode);
        const display_name = if (name.len == 0) "<invalid>" else name;
        const avg = if (row.count == 0) 0 else row.nanos / row.count;
        if (comptime zjs.opcode_profile_build_enabled) {
            try output.print("{s:<20} {d:>9} {s:>18} {s:>16} {s:>16}\n", .{ display_name, row.count, "not instrumented", "not instrumented", "not instrumented" });
        } else {
            try output.print("{s:<20} {d:>9} {d:>13} {d:>12} {d:>10}\n", .{ display_name, row.count, row.nanos, avg, profile.slow_count[row.opcode] });
        }
    }

    try dumpHostDispatchStats(output);
}

const host_dispatch_stats = engine.exec.host_dispatch_stats;

/// Per-site hit table for the legacy string-name dispatch branches in
/// `call.zig`. Only available (and only printed) when built with
/// `-Dzjs_enable_opcode_profile=true`.
fn dumpHostDispatchStats(output: *std.Io.Writer) !void {
    if (comptime !host_dispatch_stats.enabled) return;
    const counts = host_dispatch_stats.snapshot();
    var order: [host_dispatch_stats.site_count]u16 = undefined;
    for (&order, 0..) |*slot, index| slot.* = @intCast(index);
    std.sort.heap(u16, &order, @as([]const u64, &counts), struct {
        fn lessThan(c: []const u64, lhs: u16, rhs: u16) bool {
            if (c[lhs] != c[rhs]) return c[lhs] > c[rhs];
            return lhs < rhs;
        }
    }.lessThan);
    var zero_count: usize = 0;
    try output.print("\nHOST DISPATCH SITE                                                HITS\n", .{});
    for (order) |index| {
        if (counts[index] == 0) {
            zero_count += 1;
            continue;
        }
        try output.print("{s:<60} {d:>9}\n", .{ host_dispatch_stats.tagName(index), counts[index] });
    }
    try output.print("dispatch sites with zero hits: {d}/{d}\n", .{ zero_count, host_dispatch_stats.site_count });
}

extern "c" fn atexit(callback: *const fn () callconv(.c) void) c_int;

var host_dispatch_stats_path_buf: [512:0]u8 = undefined;
var host_dispatch_stats_path_len: usize = 0;

/// When built with `-Dzjs_enable_opcode_profile=true` and
/// `ZJS_HOST_DISPATCH_STATS_FILE` is set, append per-site dispatch hit counts
/// to that file when the process exits (the explicit `std.process.exit` calls
/// skip defers, so this uses libc `atexit`).
fn setupHostDispatchStatsExitDump(environ_map: *std.process.Environ.Map) void {
    if (comptime !host_dispatch_stats.enabled) return;
    const path = environ_map.get("ZJS_HOST_DISPATCH_STATS_FILE") orelse return;
    if (path.len == 0 or path.len >= host_dispatch_stats_path_buf.len) return;
    @memcpy(host_dispatch_stats_path_buf[0..path.len], path);
    host_dispatch_stats_path_buf[path.len] = 0;
    host_dispatch_stats_path_len = path.len;
    _ = atexit(writeHostDispatchStatsAtExit);
}

fn writeHostDispatchStatsAtExit() callconv(.c) void {
    if (comptime !host_dispatch_stats.enabled) return;
    if (host_dispatch_stats_path_len == 0) return;
    host_dispatch_stats.appendToFile(&host_dispatch_stats_path_buf);
}

fn setupV2OracleReportExitDump(environ_map: *std.process.Environ.Map) void {
    if (comptime !engine.compiler.oracle_report_enabled) return;
    const flag = environ_map.get("ZJS_V2_ORACLE_REPORT") orelse return;
    if (flag.len == 0 or std.mem.eql(u8, flag, "0")) return;
    _ = atexit(writeV2OracleReportAtExit);
}

fn writeV2OracleReportAtExit() callconv(.c) void {
    if (comptime !engine.compiler.oracle_report_enabled) return;
    var buffer: [1024]u8 = undefined;
    const text = engine.compiler.formatOracleReport(&buffer);
    if (text.len == 0) return;
    std.debug.print("{s}\n", .{text});
}

fn opcodeProfileRowLessThan(_: void, lhs: OpcodeProfileRow, rhs: OpcodeProfileRow) bool {
    if (lhs.nanos != rhs.nanos) return lhs.nanos > rhs.nanos;
    if (lhs.count != rhs.count) return lhs.count > rhs.count;
    return lhs.opcode < rhs.opcode;
}

fn ensureOpcodeProfileNames() void {
    const previous = zjs.activateOpcodeProfile(null);
    _ = zjs.activateOpcodeProfile(previous);
}

fn takePendingRejectionOrException(runtime: *Runtime) zjs.JSValue {
    return runtime.context.takePendingException();
}

fn printEvaluationError(io: std.Io, runtime: *Runtime, err: anyerror) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    if (runtime.context.hasException() or runtime.context.hasUnhandledRejection()) {
        const thrown = runtime.context.takePendingException();
        defer thrown.free(runtime.runtime);
        if (try printExceptionValue(stderr, runtime, thrown)) return;
    }
    try stderr.print("zjs: evaluation failed: ", .{});
    try stderr.print("{s}\n", .{@errorName(err)});
    try stderr.flush();
}

fn printExceptionValue(stderr: *std.Io.Writer, runtime: *Runtime, value: zjs.JSValue) !bool {
    const rt = runtime.runtime;
    if (!value.isObject()) return false;

    const header = try runtime.context.formatException(value, rt.memory.allocator);
    defer rt.memory.allocator.free(header);
    if (header.len == 0) {
        try stderr.print("Error\n", .{});
    } else {
        try stderr.print("{s}\n", .{header});
    }

    const stack = runtime.context.formatExceptionStack(value, rt.memory.allocator) catch |err| blk: {
        if (runtime.context.hasException()) {
            runtime.context.clearException();
            break :blk null;
        }
        return err;
    };
    defer if (stack) |bytes| rt.memory.allocator.free(bytes);
    if (stack) |bytes| {
        if (bytes.len != 0) {
            try stderr.writeAll(bytes);
            if (bytes[bytes.len - 1] != '\n') try stderr.print("\n", .{});
        }
    }
    try stderr.flush();
    return true;
}

/// Reports one rejection into a caller-owned stderr writer. Reporting loops
/// must reuse ONE writer: each fresh File.stderr().writer() starts at its own
/// position 0, so successive reports would overwrite each other when stderr
/// is redirected to a regular file.
fn printUnhandledRejectionTo(stderr: *std.Io.Writer, runtime: *Runtime, value: zjs.JSValue) !void {
    try stderr.print("Possibly unhandled promise rejection: ", .{});
    if (value.asInt32()) |int_value| {
        try stderr.print("{d}", .{int_value});
    } else if (value.asBool()) |bool_value| {
        try stderr.print("{s}", .{if (bool_value) "true" else "false"});
    } else if (value.isUndefined()) {
        try stderr.print("undefined", .{});
    } else if (value.isNull()) {
        try stderr.print("null", .{});
    } else if (value.isString()) {
        try stderr.print("[object String]", .{});
    } else if (value.isObject()) {
        if (try printExceptionValue(stderr, runtime, value)) return;
    } else {
        try stderr.print("[object Object]", .{});
    }
    try stderr.print("\n", .{});
    try stderr.flush();
}

fn printTypeErrorNotFunction(io: std.Io, command: Command) !void {
    const path = switch (command) {
        .file => |file| file.path,
        .eval => "<eval>",
    };
    try cli_process.printError(io, "TypeError: not a function\n    at <anonymous> ({s}:7:20)\n\n", .{path});
}

test "zjs args accept eval source" {
    const command = try parseArgs(&.{ "-e", "1" });
    try std.testing.expectEqualStrings("1", command.eval.source);
}

test "zjs args accept one file" {
    const command = try parseArgs(&.{"input.js"});
    try std.testing.expectEqualStrings("input.js", command.file.path);
}

test "zjs args accept file script arguments" {
    const command = try parseArgs(&.{ "input.js", "empty_loop" });
    try std.testing.expectEqualStrings("input.js", command.file.path);
    try std.testing.expectEqual(@as(usize, 2), command.file.script_args.len);
    try std.testing.expectEqualStrings("input.js", command.file.script_args[0]);
    try std.testing.expectEqualStrings("empty_loop", command.file.script_args[1]);
}

test "zjs args accept runtime limits" {
    const command = try parseArgs(&.{ "--memory-limit", "7", "--stack-size", "9", "input.js" });
    try std.testing.expectEqual(@as(?usize, 7 * 1024), command.file.options.memory_limit);
    try std.testing.expectEqual(@as(?usize, 9 * 1024), command.file.options.stack_size);

    try std.testing.expectError(error.Usage, parseArgs(&.{ "--stack-size", "11" }));
}

test "zjs args accept include preload files" {
    const command = try parseArgs(&.{ "-I", "prelude.js", "--include", "setup.mjs", "input.js" });
    try std.testing.expectEqual(@as(usize, 2), command.file.options.include_count);
    try std.testing.expectEqualStrings("prelude.js", command.file.options.includes()[0]);
    try std.testing.expectEqualStrings("setup.mjs", command.file.options.includes()[1]);
}

test "zjs args accept gc-shadow-check only in shadow builds" {
    if (comptime engine.core.gc.shadow_tracer_enabled) {
        const command = try parseArgs(&.{ "--gc-shadow-check", "-e", "1" });
        try std.testing.expect(command == .eval);
        try std.testing.expect(command.eval.options.gc_shadow_check);
    } else {
        try std.testing.expectError(error.Usage, parseArgs(&.{ "--gc-shadow-check", "-e", "1" }));
    }
}

test "zjs args accept memory dump flag" {
    const command = try parseArgs(&.{ "-d", "input.js" });
    try std.testing.expect(command == .file);
    try std.testing.expect(command.file.options.dump_memory);
}

test "zjs args accept memory trace flag" {
    const command = try parseArgs(&.{ "-T", "input.js" });
    try std.testing.expect(command == .file);
    try std.testing.expect(command.file.options.trace_memory);
}

test "zjs args accept opcode profile flag" {
    const command = try parseArgs(&.{ "--profile-opcodes", "input.js" });
    try std.testing.expect(command == .file);
    try std.testing.expect(command.file.options.profile_opcodes);

    const eval_command = try parseArgs(&.{ "--profile-opcodes", "-e", "1" });
    try std.testing.expect(eval_command == .eval);
    try std.testing.expect(eval_command.eval.options.profile_opcodes);
}

test "zjs args accept perf json flag for eval and files only" {
    const command = try parseArgs(&.{ "--perf-json", "input.js" });
    try std.testing.expect(command == .file);
    try std.testing.expect(command.file.options.perf_json);

    const eval_command = try parseArgs(&.{ "--perf-json", "-e", "1" });
    try std.testing.expect(eval_command == .eval);
    try std.testing.expect(eval_command.eval.options.perf_json);

    try std.testing.expectError(error.Usage, parseArgs(&.{"--perf-json"}));
}

test "zjs perf json opcode profile includes counters and rows" {
    var profile = zjs.OpcodeProfile{};
    profile.recordOpcode(engine.bytecode.opcode.op.get_var, 17);
    profile.recordOpcode(engine.bytecode.opcode.op.push_i16, 5);
    profile.recordValueDup();
    profile.recordValueFree();
    profile.recordGlobalLookup();

    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try dumpPerfJsonOpcodeProfile(&writer, &profile);
    const json = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, json, "\"opcode_profile\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"opcodes_executed\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"value_frees\": 1") != null);
    if (comptime zjs.opcode_profile_build_enabled) {
        try std.testing.expect(std.mem.indexOf(u8, json, "\"value_dups\": \"not instrumented\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"global_lookups\": \"not instrumented\"") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, json, "\"value_dups\": 1") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"global_lookups\": 1") != null);
    }
    if (comptime zjs.opcode_profile_build_enabled) {
        try std.testing.expect(std.mem.indexOf(u8, json, "\"measured_ns\": \"not instrumented\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"allocations\": \"not instrumented\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"call_frames\": \"not instrumented\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"nanos\": \"not instrumented\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"avg_ns\": \"not instrumented\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"slow\": \"not instrumented\"") != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"get_var\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"push_i16\"") != null);

    if (comptime zjs.opcode_profile_build_enabled) {
        var ic_buffer: [1024]u8 = undefined;
        var ic_writer = std.Io.Writer.fixed(&ic_buffer);
        try dumpPerfJsonIc(&ic_writer, &profile);
        const ic_json = ic_writer.buffered();
        try std.testing.expect(std.mem.indexOf(u8, ic_json, "\"hit\": \"not instrumented\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, ic_json, "\"ic_hit\": \"not instrumented\"") != null);
    }
}

test "zjs args accept module file" {
    const command = try parseArgs(&.{ "-m", "input.mjs" });
    try std.testing.expectEqualStrings("input.mjs", command.file.path);
    try std.testing.expectEqual(zjs.context.EvalMode.module, command.file.mode);
}

test "zjs args accept module file script arguments" {
    const command = try parseArgs(&.{ "-m", "input.mjs", "arg" });
    try std.testing.expectEqualStrings("input.mjs", command.file.path);
    try std.testing.expectEqual(zjs.context.EvalMode.module, command.file.mode);
    try std.testing.expectEqual(@as(usize, 2), command.file.script_args.len);
    try std.testing.expectEqualStrings("input.mjs", command.file.script_args[0]);
    try std.testing.expectEqualStrings("arg", command.file.script_args[1]);
}

test "zjs detects module mode from extension and first token (qjs JS_DetectModule)" {
    try std.testing.expectEqual(zjs.context.EvalMode.module, detectFileMode("input.mjs", "console.log(1)", .script));
    try std.testing.expectEqual(zjs.context.EvalMode.module, detectFileMode("input.js", "import value from './dep.mjs';\nconsole.log(value)", .script));
    try std.testing.expectEqual(zjs.context.EvalMode.module, detectFileMode("input.js", "export const value = 1;", .script));
    try std.testing.expectEqual(zjs.context.EvalMode.module, detectFileMode("input.js", "/* leading */ // comment\nimport 'x';", .script));
    try std.testing.expectEqual(zjs.context.EvalMode.module, detectFileMode("input.js", "#!/usr/bin/env zjs\nimport value from './dep.mjs';", .script));
    try std.testing.expectEqual(zjs.context.EvalMode.module, detectFileMode("input.js", "\xC2\xA0import 'x';", .script));
    try std.testing.expectEqual(zjs.context.EvalMode.module, detectFileMode("input.js", "// \xCF\x80\xE2\x80\xA8export const x = 1;", .script));
    try std.testing.expectEqual(zjs.context.EvalMode.module, detectFileMode("input.js", "// \xCF\x80\xE2\x80\xA9import 'x';", .script));
    // Only the first token decides (qjs JS_DetectModule quickjs.c:23792):
    // `import.meta` / `import(...)` never promote, and a late export/import
    // is a script-mode SyntaxError rather than a silent module promotion.
    try std.testing.expectEqual(zjs.context.EvalMode.script, detectFileMode("input.js", "console.log(import.meta.url)", .script));
    try std.testing.expectEqual(zjs.context.EvalMode.script, detectFileMode("input.js", "import('./dep.mjs')", .script));
    try std.testing.expectEqual(zjs.context.EvalMode.script, detectFileMode("input.js", "import\n('./dep.mjs')", .script));
    try std.testing.expectEqual(zjs.context.EvalMode.script, detectFileMode("input.js", "import.meta.url", .script));
    try std.testing.expectEqual(zjs.context.EvalMode.script, detectFileMode("input.js", "const s = 'import x from y';\nimport('./dep.mjs')", .script));
    try std.testing.expectEqual(zjs.context.EvalMode.script, detectFileMode("input.js", "console.log(1);\nexport const late = 1;", .script));
    try std.testing.expectEqual(zjs.context.EvalMode.script, detectFileMode("input.js", "// export const x = 1\nconsole.log('ok')", .script));
    try std.testing.expectEqual(zjs.context.EvalMode.script, detectFileMode("input.js", "importx.meta", .script));
    try std.testing.expectEqual(zjs.context.EvalMode.script, detectFileMode("input.js", "import\xCF\x80.meta", .script));
    try std.testing.expectEqual(zjs.context.EvalMode.script, detectFileMode("input.js", "exports.value = 1;", .script));
}

test "zjs module specifier resolver uses referrer directory" {
    const resolved = try runtime_layer.resolveModuleSpecifier(std.testing.allocator, "tests/fixtures/main.mjs", "./dep.mjs");
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings("tests/fixtures/dep.mjs", resolved);
    try std.testing.expectError(error.ModuleNotFound, runtime_layer.resolveModuleSpecifier(std.testing.allocator, "main.mjs", "bare"));
}

test "zjs args reject missing source" {
    try std.testing.expectError(error.Usage, parseArgs(&.{"-e"}));
    try std.testing.expectError(error.Usage, parseArgs(&.{"-m"}));
    try std.testing.expectError(error.Usage, parseArgs(&.{ "-i", "extra" }));
}

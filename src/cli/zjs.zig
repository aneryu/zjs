//! CLI boundary for script/module evaluation, host loading, job draining, and exception/rejection reporting.
//! Source buffers live through evaluation; `--leak-check` selects explicit event-loop, context, and runtime teardown.
const std = @import("std");
const cli_process = @import("cli_process.zig");
const engine = @import("zjs");
const sort_erased = engine.sort_erased;
const simple_token = engine.simple_token;
const platform_clock = engine.platform_clock;
/// Message-only panics in ReleaseFast, full traces everywhere else.
/// See `panic_policy.zig` for why the shipped binary drops the symbolizer.
pub const panic = @import("panic_policy.zig").policy;

// QCP-1: this root is shared by `zjs` (ReleaseFast), `zjs-profile`
// (ReleaseFast), `zjs-dev` (Debug), and `zjs-size` (-Doptimize), so it proves the effective
// configuration of the shipped binary itself at compile time, each reporting
// its own optimize mode (src/config_signature.zig). `--print-config-signature`
// below is the runtime half of the same statement.
comptime {
    engine.config_signature.attest("zjs CLI");
    if (!std.mem.eql(u8, @tagName(@import("builtin").mode), engine.config_signature.optimize)) {
        @compileError("zjs CLI optimize mode differs from its engine");
    }
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
    gc_gate_settle: bool = false,
    gc_block_census: bool = false,
    perf_json: bool = false,
    leak_check: bool = false,
    include_paths: [max_include_paths][]const u8 = @splat(""),
    include_count: usize = 0,

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
            // The panel's census costs whole-heap walks per major, so the
            // collector only performs them when someone is going to read them.
            // The marked-set/storage census is NOT among them: it is the one
            // walk large enough to move the scores this panel is used to
            // judge, so it has its own flag below.
            engine.core.gc_trace_stw.detailed_reports = true;
            rest = rest[1..];
            continue;
        }
        if (std.mem.eql(u8, rest[0], "--gc-gate-settle")) {
            // Gate-only contract: retain the natural endpoint, then complete
            // any irreversible destruction transaction before publishing the
            // stats the checker treats as settled. This implies --gc-stats so
            // callers cannot accidentally request a silent settlement.
            options.gc_stats = true;
            options.gc_gate_settle = true;
            engine.core.gc_trace_stw.detailed_reports = true;
            rest = rest[1..];
            continue;
        }
        if (std.mem.eql(u8, rest[0], "--gc-block-census")) {
            // TGC S4-f (2). A pure exit-time walk of the block table: nothing
            // on a collector or allocator path consults it, so unlike
            // `--gc-mark-footprint` it does not move the numbers it prints.
            options.gc_stats = true;
            options.gc_block_census = true;
            engine.core.gc_trace_stw.detailed_reports = true;
            rest = rest[1..];
            continue;
        }
        if (std.mem.eql(u8, rest[0], "--gc-mark-footprint")) {
            // Opt in to the marked-set/storage census and print the panel that
            // reads it. Measured cost on splay: Splay -9.8%, SplayLatency
            // -23.7% against the same binary. That is a study tool, not a
            // ruler -- do not take pause or score numbers from a run with it.
            options.gc_stats = true;
            engine.core.gc_trace_stw.detailed_reports = true;
            engine.core.gc_trace_stw.mark_footprint_census = true;
            rest = rest[1..];
            continue;
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
                try cli_process.printErrorJoin(io, &.{ "zjs: unable to read ", file.path, ": ", @errorName(err), "\n" });
                std.process.exit(1);
            };
            read_source_ns = platform_clock.elapsedNanosSince(read_start);
            break :source bytes;
        },
    };
    defer if (command == .file) allocator.free(source_text);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    var opcode_profile: zjs.OpcodeProfile = undefined;
    initOpcodeProfile(&opcode_profile);
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
        try cli_process.printErrorJoin(io, &.{ "zjs: engine init failed: ", @errorName(err), "\n" });
        std.process.exit(1);
    };
    errdefer rt.destroy();
    const ctx = zjs.JSContext.create(rt) catch |err| {
        try cli_process.printErrorJoin(io, &.{ "zjs: context init failed: ", @errorName(err), "\n" });
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
            try cli_process.printError(io, "zjs: --profile-opcodes requires a profiling build; run 'zig build zjs-profile' or rebuild with -Dzjs_enable_opcode_profile=true (refusing to emit an all-zero profile)\n");
            std.process.exit(2);
        }
        runtime.runtime.setOpcodeProfile(&opcode_profile);
    } else if (runtime_options.perf_json) {
        _ = zjs.activateOpcodeProfile(&opcode_profile);
    }
    zjs.host.defineScriptArgs(runtime.context, commandScriptArgs(command)) catch |err| {
        try cli_process.printErrorJoin(io, &.{ "zjs: scriptArgs setup failed: ", @errorName(err), "\n" });
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
            std.process.exit(1);
        }
        if (err == error.TypeError) {
            try stdout_writer.interface.flush();
            try printTypeErrorNotFunction(io, command);
            std.process.exit(1);
        }
        try printEvaluationError(io, &runtime, err);
        std.process.exit(1);
    };
    eval_ns = platform_clock.elapsedNanosSince(eval_start);
    try stdout_writer.interface.flush();

    if (value.isException()) {
        try cli_process.printError(io, "zjs: uncaught exception\n");
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
            if (!runtime.context.hasUnhandledRejection()) break;
        }
        std.process.exit(1);
    }

    if (commandRuntimeOptions(command).dump_memory) {
        try dumpMemoryUsage(&stdout_writer.interface, &runtime);
        try stdout_writer.interface.flush();
    }
    if (zjs.opcode_profile_build_enabled and commandRuntimeOptions(command).profile_opcodes) {
        opcode_profile.flushPendingDispatch();
        try dumpOpcodeProfile(&stdout_writer.interface, runtime.runtime.opcode_profile.?);
        try stdout_writer.interface.flush();
    }
    if (commandRuntimeOptions(command).gc_stats) {
        if (commandRuntimeOptions(command).gc_gate_settle) {
            try dumpGcDoomedState(&stdout_writer.interface, "endpoint", runtime.runtime);
            engine.core.runtime.settlePendingDestructionForGateStats(runtime.runtime);
        }
        try dumpGcStats(&stdout_writer.interface, runtime.runtime.gcStats(), &runtime.runtime.gc);
        try dumpAtomAuditStats(&stdout_writer.interface, runtime.runtime);
        try dumpGcPauses(&stdout_writer.interface, runtime.runtime.gcPauseDistribution());
        try dumpGcSpaceStats(&stdout_writer.interface, &runtime.runtime.gc);
        try dumpGcBlockHeapStats(&stdout_writer.interface, &runtime.runtime.gc);
        if (commandRuntimeOptions(command).gc_block_census) {
            try dumpGcBlockCensus(&stdout_writer.interface, &runtime.runtime.gc);
        }
        try dumpGcMarkFootprint(&stdout_writer.interface, runtime.runtime);
        try dumpGcPhaseTotals(&stdout_writer.interface, &runtime.runtime.gc);
        try dumpGcGenerationStats(&stdout_writer.interface, &runtime.runtime.gc);
        if (comptime engine.core.gc.roots_diag_enabled) {
            try engine.core.gc_conservative.reportGlobal(&stdout_writer.interface);
        }
        try dumpGcDoomedState(
            &stdout_writer.interface,
            if (commandRuntimeOptions(command).gc_gate_settle) "settled" else "endpoint",
            runtime.runtime,
        );
        try stdout_writer.interface.flush();
    }
    if (commandRuntimeOptions(command).perf_json) {
        opcode_profile.flushPendingDispatch();
        const active_profile: ?*const zjs.OpcodeProfile =
            if (zjs.opcode_profile_build_enabled and commandRuntimeOptions(command).profile_opcodes) &opcode_profile else null;
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
    try cli_process.printError(io, "usage: zjs [-d] [-T] [--profile-opcodes] [--gc-stats] [--gc-gate-settle] [--gc-mark-footprint] [--gc-block-census] [--perf-json] [--leak-check] [--memory-limit n] [--stack-size n] [-I file] -e <script>\n       zjs [-d] [-T] [--profile-opcodes] [--gc-stats] [--gc-gate-settle] [--gc-mark-footprint] [--gc-block-census] [--perf-json] [--leak-check] [--memory-limit n] [--stack-size n] [-I file] [-m] <file.js>\n       zjs " ++ config_signature_flag ++ "\n");
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
        _ = if (mode == .module)
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
    }
}

fn parseLimitKBytes(text: []const u8) !usize {
    if (text.len == 0) return error.InvalidCharacter;
    const kbytes = try engine.core.value_format.parseAsciiInt(usize, text, 10);
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
    try dumpMemorySnapshot(output, runtime.runtime.memoryUsage());
}

fn dumpMemorySnapshot(output: *std.Io.Writer, memory: zjs.RuntimeMemoryUsage) !void {
    try output.print("\nZJS memory usage\n", .{});
    try output.print("  memory limit: ", .{});
    if (memory.memory_limit) |limit| {
        try output.print("{d}\n", .{limit});
    } else {
        try output.print("0\n", .{});
    }
    try output.print("\nNAME                    COUNT     SIZE\n", .{});
    for ([_]struct { []const u8, usize, usize }{
        .{ "memory allocated", memory.allocation_count, memory.allocated_bytes },
        .{ "atoms", memory.atom_count, memory.atom_bytes },
        .{ "objects", memory.object_count, memory.object_bytes },
        .{ "shapes", memory.shape_count, memory.shape_bytes },
        .{ "modules", memory.module_count, memory.module_bytes },
        .{ "classes", memory.registered_class_count, memory.class_bytes },
    }) |row| {
        var name_buf: [32]u8 = undefined;
        var count_buf: [32]u8 = undefined;
        var size_buf: [32]u8 = undefined;
        try output.writeAll(spacePad(row[0], 22, false, &name_buf));
        try output.writeAll(" ");
        try output.writeAll(decPad(@as(u64, row[1]), 5, &count_buf));
        try output.writeAll(" ");
        try output.writeAll(decPad(@as(u64, row[2]), 8, &size_buf));
        try output.writeAll("\n");
    }
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
    try dumpPerfJsonMetrics(stderr, memory, timings);
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

fn dumpPerfJsonMetrics(stderr: *std.Io.Writer, memory: zjs.RuntimeMemoryUsage, timings: PerfJsonTimings) !void {
    try writeCounterLine(stderr, &.{
        .{ "  \"total_ns\": ", timings.total_ns },
        .{ ",\n  \"read_source_ns\": ", timings.read_source_ns },
        .{ ",\n  \"runtime_create_ns\": ", timings.runtime_create_ns },
        .{ ",\n  \"setup_ns\": ", timings.setup_ns },
        .{ ",\n  \"include_ns\": ", timings.include_ns },
        .{ ",\n  \"eval_ns\": ", timings.eval_ns },
        .{ ",\n  \"parse_ns\": ", timings.zjs.parse_ns },
        .{ ",\n  \"finalize_ns\": null,\n  \"parse_ns_includes_finalize\": true,\n  \"vm_run_ns\": ", timings.zjs.vm_run_ns },
        .{ ",\n  \"promise_jobs_ns\": ", timings.zjs.promise_jobs_ns },
        .{ ",\n  \"jobs_ns\": ", timings.jobs_ns },
        .{ ",\n  \"memory\": {\n    \"allocated_bytes\": ", memory.allocated_bytes },
        .{ ",\n    \"allocation_count\": ", memory.allocation_count },
        .{ ",\n    \"allocated_bytes_peak\": ", memory.peak_allocated_bytes },
        .{ ",\n    \"allocation_count_peak\": ", memory.peak_allocation_count },
        .{ ",\n    \"alloc_calls\": ", memory.alloc_calls },
        .{ ",\n    \"free_calls\": ", memory.free_calls },
        .{ ",\n    \"create_calls\": ", memory.create_calls },
        .{ ",\n    \"destroy_calls\": ", memory.destroy_calls },
    }, "\n  }");
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
    sort_erased.heap(OpcodeProfileRow, rows[0..row_count], {}, opcodeProfileRowLessThan);

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
    const space = engine.core.gc_space;
    const hist = registry.space_histogram;
    const p50 = hist.percentilePayloadBelowLarge(50);
    const p95 = hist.percentilePayloadBelowLarge(95);
    const p99 = hist.percentilePayloadBelowLarge(99);
    try writeCounterLine(writer, &.{
        .{ "gc: allocation histogram publications ", hist.total },
        .{ ", payload bytes ", hist.bytes_total },
        .{ ", p50-below-large ", p50 },
        .{ ", p95-below-large ", p95 },
        .{ ", p99-below-large ", p99 },
        .{ ", max-small ", space.max_small_payload },
        .{ ", covered-by-small ", hist.coveredByMaxSmall() },
        .{ "/", hist.belowLarge() },
        .{ " below-large, large ", hist.large },
    }, "\n");
}

/// TGC S4-f (2): per-size-class block occupancy. `blocks` is what
/// `committed_bytes` is actually made of (a superblock's `used_blocks` never
/// falls, so it is the peak count of distinct opened blocks); the four
/// occupancy buckets say whether that peak is live data, thinly-populated
/// fragmentation, or blocks nothing has reclaimed.
fn dumpGcBlockCensus(writer: *std.Io.Writer, registry: *const engine.core.gc.Registry) !void {
    const census = registry.block_heap.censusBlocks();
    try writeCounterLine(writer, &.{
        .{ "gc: block census classed superblocks ", census.classed_superblocks },
        .{ ", other ", census.other_superblocks },
        .{ ", uninitialized slots ", census.uninitialized_blocks },
    }, "\n");
    try writer.writeAll(
        "gc: block census columns cell_bytes blocks cells allocated occ_x1000 empty lt10 lt50 ge50 young decommitted active hot free\n",
    );
    var total: engine.core.gc_block_heap.BlockCensusRow = .{};
    for (census.rows) |row| {
        total.blocks += row.blocks;
        total.cells += row.cells;
        total.allocated += row.allocated;
        total.empty += row.empty;
        total.lt10 += row.lt10;
        total.lt50 += row.lt50;
        total.ge50 += row.ge50;
        total.young += row.young;
        total.decommitted += row.decommitted;
        total.active += row.active;
        total.hot_listed += row.hot_listed;
        total.free_listed += row.free_listed;
        if (row.blocks == 0) continue;
        try writeCounterLine(writer, &.{
            .{ "gc: block census row ", row.cell_bytes },
            .{ " ", row.blocks },
            .{ " ", row.cells },
            .{ " ", row.allocated },
            .{ " ", if (row.cells == 0) @as(u64, 0) else row.allocated * 1000 / row.cells },
            .{ " ", row.empty },
            .{ " ", row.lt10 },
            .{ " ", row.lt50 },
            .{ " ", row.ge50 },
            .{ " ", row.young },
            .{ " ", row.decommitted },
            .{ " ", row.active },
            .{ " ", row.hot_listed },
            .{ " ", row.free_listed },
        }, "\n");
    }
    try writeCounterLine(writer, &.{
        .{ "gc: block census total 0 ", total.blocks },
        .{ " ", total.cells },
        .{ " ", total.allocated },
        .{ " ", if (total.cells == 0) @as(u64, 0) else total.allocated * 1000 / total.cells },
        .{ " ", total.empty },
        .{ " ", total.lt10 },
        .{ " ", total.lt50 },
        .{ " ", total.ge50 },
        .{ " ", total.young },
        .{ " ", total.decommitted },
        .{ " ", total.active },
        .{ " ", total.hot_listed },
        .{ " ", total.free_listed },
    }, "\n");
}

// Share integer formatting across cold diagnostic rows while keeping each
// label, value, and suffix explicit at the call site.
noinline fn writeCounterLine(writer: *std.Io.Writer, parts: []const struct { []const u8, u64 }, suffix: []const u8) !void {
    for (parts) |part| try writer.print("{s}{d}", .{ part[0], part[1] });
    try writer.writeAll(suffix);
}

/// Zig `{s:<width}` / `{s:>width}`: width is a floor. Longer text is unchanged.
noinline fn spacePad(text: []const u8, width: u8, right_align: bool, buf: *[32]u8) []const u8 {
    std.debug.assert(width >= 1 and width <= buf.len);
    if (text.len >= width) return text;
    const pad = @as(usize, width) - text.len;
    if (right_align) {
        @memset(buf[0..pad], ' ');
        @memcpy(buf[pad..][0..text.len], text);
    } else {
        @memcpy(buf[0..text.len], text);
        @memset(buf[text.len..][0..pad], ' ');
    }
    return buf[0..@as(usize, width)];
}

/// Zig `{d:>width}`: decimal digits, then right-align. Width is a floor.
noinline fn decPad(value: u64, width: u8, buf: *[32]u8) []const u8 {
    std.debug.assert(width >= 1 and width <= buf.len);
    var rest = value;
    var i: usize = buf.len;
    while (true) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(rest % 10));
        rest /= 10;
        if (rest == 0) break;
    }
    const raw_len = buf.len - i;
    if (raw_len >= width) return buf[i..];
    const pad = @as(usize, width) - raw_len;
    const start = i - pad;
    @memset(buf[start..i], ' ');
    return buf[start..];
}

/// Generational counters. `remembered without young` is the one to watch: it
/// counts owners a minor re-traced that turned out to hold no young child, so
/// a large share means the write barrier is firing more than it needs to.
fn dumpGcGenerationStats(writer: *std.Io.Writer, registry: *engine.core.gc.Registry) !void {
    const st = registry.generation.stats;
    // Row shape frozen: tools/perf/gc_stats_snapshot.py parses it. The S4-f
    // trigger census gets its own row below rather than a field here.
    try writeCounterLine(writer, &.{
        .{ "gc: generation current young ", st.young_count },
        .{ ", remembered owners ", registry.generation.remembered.count() },
    }, "\n");
    try writeCounterLine(writer, &.{
        .{ "gc: generation current young-trigger ", st.young_trigger_count },
    }, " (excludes owner-decided storage cells)\n");
    try writeCounterLine(writer, &.{
        .{ "gc: minor collections ", st.minor_collections },
        .{ ", reclaimed ", st.minor_reclaimed },
        .{ ", promoted-by-minor ", st.minor_promoted },
        .{ ", promoted-all ", st.promoted },
        .{ ", remembered without young ", st.remembered_without_young },
        .{ ", remembered drops ", st.remembered_drops },
        .{ ", suspensions ", st.minor_suspensions },
    }, "\n");
    try writeCounterLine(writer, &.{
        .{ "gc: major retirement commits ", st.retirement_commits },
        .{ ", abandons ", st.retirement_abandons },
    }, "");
    try writer.writeAll(", current state ");
    try writer.writeAll(@tagName(registry.generation.major_retirement));
    try writer.writeAll("\n");
    try writeCounterLine(writer, &.{
        .{ "gc: generational barrier calls ", st.barrier_calls },
        .{ ", exit young-owner ", st.barrier_young_owner },
        .{ ", exit old-target ", st.barrier_old_target },
        .{ ", remembered-owner ", st.barrier_calls -| st.barrier_young_owner -| st.barrier_old_target },
    }, "\n");
    const mean_pause = if (st.minor_collections == 0) 0 else st.pause_ns_total / st.minor_collections;
    const mean_young = if (st.minor_collections == 0) 0 else st.young_at_start_total / st.minor_collections;
    try writeCounterLine(writer, &.{
        .{ "gc: minor stw total ", st.pause_ns_total },
        .{ " ns, mean ", mean_pause },
        .{ " ns, max ", st.pause_ns_max },
    }, " ns\n");
    if (registry.generation.minorPauseDistribution()) |d| {
        try writeCounterLine(writer, &.{
            .{ "gc: minor pause p50 ", d.p50_ns },
            .{ " ns, p95 ", d.p95_ns },
            .{ " ns, p99 ", d.p99_ns },
            .{ " ns, max ", d.max_ns },
            .{ " ns over ", d.samples_retained },
            .{ " retained of ", d.samples_total },
        }, " samples\n");
    } else {
        try writeCounterLine(writer, &.{
            .{ "gc: minor pause distribution unavailable, sample drops ", registry.generation.minor_pause_sample_drops },
        }, "\n");
    }
    try writeCounterLine(writer, &.{
        .{ "gc: minor phase totals clear ", st.minor_clear_ns_total },
        .{ ", roots ", st.minor_roots_ns_total },
        .{ ", conservative ", st.minor_conservative_ns_total },
        .{ ", remembered ", st.minor_remembered_ns_total },
        .{ ", trace ", st.minor_trace_ns_total },
        .{ ", sweep+destroy ", st.minor_sweep_ns_total },
        .{ ", promote ", st.minor_promote_ns_total },
        .{ ", other ", st.pause_ns_total -| st.minorPhaseNsTotal() },
    }, " ns\n");
    try writeCounterLine(writer, &.{
        .{ "gc: minor young-at-start mean ", mean_young },
        .{ ", max ", st.young_at_start_max },
    }, "\n");
    if (engine.core.gc.verify_minor) {
        try writeCounterLine(writer, &.{
            .{ "gc: conservative-only young ", st.conservative_only_young },
            .{ " over ", st.minor_collections },
        }, " verified minors\n");
    } else {
        try writer.writeAll("gc: conservative-only young unavailable (set ZJS_GC_VERIFY_MINOR=1)\n");
    }
    const cs = registry.incremental.stats;
    try writeCounterLine(writer, &.{
        .{ "gc: exact-target marking barrier calls ", cs.barrier_calls },
        .{ ", exit marked-target ", cs.barrier_marked_target },
        .{ ", exit unpublished-owner ", cs.barrier_unpublished_owner },
        .{ ", exit unpublished-target ", cs.barrier_unpublished_target },
        .{ ", requeued-owner ", cs.barrier_requeued_owner },
        .{ ", shaded-target ", cs.shaded },
    }, "\n");
    try writeCounterLine(writer, &.{
        .{ "gc: incremental doomed condemned headers ", cs.doomed_condemned_headers },
        .{ ", destroyed counted objects ", cs.doomed_destroyed_objects },
        .{ ", parked entries drained ", cs.doomed_parked_entries_drained },
        .{ ", parked-drain slices ", cs.doomed_parked_drain_slices },
    }, "\n");
    try writeCounterLine(writer, &.{
        .{ "gc: incremental major cycles completed ", cs.cycles_completed },
        .{ ", aborted ", cs.cycles_aborted },
        .{ ", forced ", cs.forced_finishes },
        .{ ", mark steps ", cs.increments },
        .{ ", cycle STW last ", cs.last_cycle_stw_ns },
        .{ " ns max ", cs.max_cycle_stw_ns },
    }, " ns\n");
    try writeCounterLine(writer, &.{
        .{ "gc: cycle envelope measured ", cs.envelope_measured_cycles },
        .{ ", skipped ", cs.envelope_skipped_cycles },
        .{ ", max-P/T S ", cs.envelope_max_start_bytes },
        .{ ", T ", cs.envelope_max_threshold_bytes },
        .{ ", B ", cs.envelope_max_begin_bytes },
        .{ ", P ", cs.envelope_max_peak_bytes },
        .{ ", B/T-x1000000 ", engine.core.gc.incremental.ratioMillionthsCeil(cs.envelope_max_begin_bytes, cs.envelope_max_threshold_bytes) },
        .{ ", P/T-x1000000 ", engine.core.gc.incremental.ratioMillionthsCeil(cs.envelope_max_peak_bytes, cs.envelope_max_threshold_bytes) },
        .{ ", P/S-x1000000 ", engine.core.gc.incremental.ratioMillionthsCeil(cs.envelope_max_peak_bytes, cs.envelope_max_start_bytes) },
        .{ ", forced ", cs.forced_finishes },
    }, "\n");
    try writeCounterLine(writer, &.{
        .{ "gc: incremental STW phase-segment max ns begin ", cs.segment_max_ns[0] },
        .{ ", increment ", cs.segment_max_ns[1] },
        .{ ", destroy ", cs.segment_max_ns[2] },
        .{ ", finish ", cs.segment_max_ns[3] },
    }, "\n");
    try writeCounterLine(writer, &.{
        .{ "gc: incremental STW phase totals begin ", cs.total_stw_by_kind[0] },
        .{ " ns/", cs.total_segments_by_kind[0] },
        .{ " segments, increment ", cs.total_stw_by_kind[1] },
        .{ " ns/", cs.total_segments_by_kind[1] },
        .{ " segments, destroy ", cs.total_stw_by_kind[2] },
        .{ " ns/", cs.total_segments_by_kind[2] },
        .{ " segments, finish ", cs.total_stw_by_kind[3] },
        .{ " ns/", cs.total_segments_by_kind[3] },
    }, " segments\n");
}

fn dumpGcBlockHeapStats(writer: *std.Io.Writer, registry: *const engine.core.gc.Registry) !void {
    const st = registry.block_heap.stats;
    try writeCounterLine(writer, &.{
        .{ "gc: block heap committed ", st.committed_bytes },
        .{ " live ", registry.block_heap.liveBytes() },
        .{ " committed/live-x1000 ", registry.block_heap.committedLiveMilli() },
        .{ " superblocks ", st.superblocks },
        .{ " large maps ", st.large_maps },
    }, "\n");
    try writeCounterLine(writer, &.{
        .{ "gc: block heap deferred block runs ", st.deferred_block_runs_completed },
        .{ ", hot reuse published ", st.hot_blocks_published },
        .{ ", reopened ", st.hot_blocks_reopened },
        .{ ", bitmap reclaimed cells ", st.bitmap_reclaimed_cells },
    }, "\n");
    try writeCounterLine(writer, &.{
        .{ "gc: block heap hot publish rejects empty ", st.hot_publish_rejected_empty },
        .{ ", capacity ", st.hot_publish_rejected_capacity },
        .{ ", active ", st.hot_publish_rejected_active },
        .{ ", doomed ", st.hot_publish_rejected_doomed },
        .{ ", young ", st.hot_publish_rejected_young },
        .{ ", listed ", st.hot_publish_rejected_listed },
        .{ ", decommitted ", st.hot_publish_rejected_decommitted },
        .{ ", cached-k ", st.hot_publish_rejected_cached_k },
        .{ ", k-rejected reopens ", st.hot_blocks_k_rejected },
    }, "\n");
    try writeCounterLine(writer, &.{
        .{ "gc: major threshold resets growth ", registry.stats.threshold_growth_hits },
        .{ ", small-heap-floor ", registry.stats.threshold_floor_hits },
    }, "\n");
    // TGC S4-d spec 2.4 deletion probe. The middle number is the one that
    // has to read 0 on every workload: a plain, payload-free, unstamped
    // object that still reached a destructor. The third is the sticky-bit
    // residue D-S4-4 permits (an object that stopped owing work keeps its
    // bit and so keeps paying one no-op visit).
    try writeCounterLine(writer, &.{
        .{ "gc: object destructor calls ", registry.stats.object_destructor_calls },
        .{ ", plain-object calls ", registry.stats.plain_object_destructor_calls },
        .{ ", plain objects carrying the finalizer bit ", registry.stats.plain_objects_with_finalizer_bit },
    }, "\n");
    try writeCounterLine(writer, &.{
        .{ "gc: block heap page returns cumulative decommitted ", st.decommitted_bytes },
        .{ ", recommitted ", st.recommitted_bytes },
    }, "\n");
    try writeCounterLine(writer, &.{
        .{ "gc: block heap medium superblocks returned ", st.medium_superblocks_released },
        .{ ", bytes ", st.medium_superblock_bytes_released },
    }, "\n");
    try writeCounterLine(writer, &.{
        .{ "gc: block heap decommit checks ", st.decommit_checks },
        .{ ", released blocks cumulative ", st.decommitted_bytes / @max(engine.core.gc_block_heap.decommit_bytes, 1) },
        .{ ", current bytes ", st.currentDecommittedBytes() },
        .{ ", max batch bytes ", st.decommit_max_batch_bytes },
    }, "\n");
    try writeCounterLine(writer, &.{
        .{ "gc: process heap trim attempts ", st.malloc_trim_attempts },
        .{ ", successes ", st.malloc_trim_successes },
    }, "\n");
}

fn dumpGcPhaseTotals(writer: *std.Io.Writer, registry: *const engine.core.gc.Registry) !void {
    const ph = registry.incremental.stats;
    // Row format is parsed by tools/perf/gc_stats_snapshot.py (Stage 0); the
    // two finish-side timers added by TGC S0 go on the reconciliation row
    // below so this row keeps its eight fields.
    try writeCounterLine(writer, &.{
        .{ "gc: incremental subphase ns totals begin-clear ", ph.phase_begin_clear_ns },
        .{ ", begin-precise-seed ", ph.phase_begin_precise_seed_ns },
        .{ ", begin-conservative-seed ", ph.phase_begin_conservative_seed_ns },
        .{ ", begin-retire ", ph.phase_begin_retire_ns },
        .{ ", finish-remark-total ", ph.phase_finish_remark_ns },
        .{ ", finish-conservative-seed-subset ", ph.phase_finish_conservative_seed_ns },
        .{ ", finish-weak ", ph.phase_finish_weak_ns },
        .{ ", finish-condemn ", ph.phase_finish_condemn_ns },
    }, "\n");
    // Reconciliation against the STW rows above: both are cumulative over
    // the run, so the residuals are what the subphase timers do not cover
    // (the `nowNanos` reads around each pause, and for begin the frontier
    // seeding between clear and retire).
    const begin_total = ph.total_stw_by_kind[@intFromEnum(engine.core.gc.Registry.SliceKind.begin)];
    const finish_total = ph.total_stw_by_kind[@intFromEnum(engine.core.gc.Registry.SliceKind.finish)];
    const begin_sum = ph.phase_begin_clear_ns +| ph.phase_begin_precise_seed_ns +| ph.phase_begin_conservative_seed_ns +| ph.phase_begin_retire_ns;
    const finish_sum = ph.phase_finish_init_ns +| ph.phase_finish_remark_ns +| ph.phase_finish_weak_ns +| ph.phase_finish_condemn_ns +| ph.phase_finish_tail_ns;
    try writeCounterLine(writer, &.{
        .{ "gc: incremental subphase reconciliation finish-init ", ph.phase_finish_init_ns },
        .{ ", finish-tail ", ph.phase_finish_tail_ns },
        .{ "; begin STW ", begin_total },
        .{ " - subphases ", begin_sum },
        .{ " = other ", begin_total -| begin_sum },
        .{ " ns; finish STW ", finish_total },
        .{ " - subphases ", finish_sum },
        .{ " = other ", finish_total -| finish_sum },
    }, " ns\n");
    try writeCounterLine(writer, &.{
        .{ "gc: incremental subphase work totals retired non-block headers ", ph.phase_retired_nonblock_headers },
        .{ ", retired young blocks ", ph.phase_retired_young_blocks },
        .{ ", retired remembered sets ", ph.phase_retired_remembered_sets },
        .{ ", clearMarks non-block headers ", ph.phase_cleared_nonblock_headers },
    }, "\n");
}

fn dumpGcMarkFootprint(writer: *std.Io.Writer, rt: *const engine.core.JSRuntime) !void {
    const fp = rt.gc_mark_footprint;
    // An all-zero panel reads like "nothing was marked", which is a wrong
    // answer rather than a missing one. Say which it is.
    if (!engine.core.gc_trace_stw.mark_footprint_census) {
        try writer.writeAll(
            "gc: marked-set census not run (pass --gc-mark-footprint; it costs a whole-heap walk inside every final remark)\n",
        );
        return;
    }
    try writeCounterLine(writer, &.{
        .{ "gc: marked-set census majors ", fp.major_censuses },
        .{ ", headers ", fp.marked_headers },
        .{ ", block headers ", fp.block_headers },
    }, "\n");
    // `string` folds the rope kind in (`MarkFootprint.noteMarkedHeader`):
    // the two are one family to every consumer of this panel.
    try writeCounterLine(writer, &.{
        .{ "gc: marked-set kinds object ", fp.by_kind[@intFromEnum(engine.core.gc.GcKind.object)] },
        .{ ", function-bytecode ", fp.by_kind[@intFromEnum(engine.core.gc.GcKind.function_bytecode)] },
        .{ ", var-ref ", fp.by_kind[@intFromEnum(engine.core.gc.GcKind.var_ref)] },
        .{ ", realm-context ", fp.by_kind[@intFromEnum(engine.core.gc.GcKind.realm_context)] },
        .{ ", module ", fp.by_kind[@intFromEnum(engine.core.gc.GcKind.module)] },
        .{ ", shape ", fp.by_kind[@intFromEnum(engine.core.gc.GcKind.shape)] },
        .{ ", big-int ", fp.by_kind[@intFromEnum(engine.core.gc.GcKind.big_int)] },
        .{ ", string ", fp.by_kind[@intFromEnum(engine.core.gc.GcKind.string)] },
        .{ ", storage ", fp.by_kind[@intFromEnum(engine.core.gc.GcKind.property_storage)] +
            fp.by_kind[@intFromEnum(engine.core.gc.GcKind.array_storage)] +
            fp.by_kind[@intFromEnum(engine.core.gc.GcKind.payload)] },
    }, "\n");
    try writeCounterLine(writer, &.{
        .{ "gc: marked-set trace classes ordinary-object ", fp.by_trace_class[@intFromEnum(engine.core.gc_trace_stw.MarkTraceClass.ordinary_object)] },
        .{ ", fast-array ", fp.by_trace_class[@intFromEnum(engine.core.gc_trace_stw.MarkTraceClass.fast_array)] },
        .{ ", bytecode-function ", fp.by_trace_class[@intFromEnum(engine.core.gc_trace_stw.MarkTraceClass.bytecode_function)] },
        .{ ", exotic-object ", fp.by_trace_class[@intFromEnum(engine.core.gc_trace_stw.MarkTraceClass.exotic_object)] },
        .{ ", non-object ", fp.by_trace_class[@intFromEnum(engine.core.gc_trace_stw.MarkTraceClass.non_object)] },
    }, "\n");
    for (std.meta.tags(engine.core.gc_trace_stw.MarkStorageComponent)) |component| {
        const aggregate = fp.storage[@intFromEnum(component)];
        try writer.writeAll("gc: mark storage ");
        try writer.writeAll(@tagName(component));
        try writeCounterLine(writer, &.{
            .{ " allocation-touches ", aggregate.allocation_touches },
            .{ ", allocated-bytes ", aggregate.allocated_bytes },
            .{ ", touched-cache-lines ", aggregate.touched_cache_lines },
        }, "\n");
    }
    for (std.meta.tags(engine.core.gc_trace_stw.MarkTraceClass)) |trace_class| {
        const aggregate = fp.storage_by_trace_class[@intFromEnum(trace_class)];
        try writer.writeAll("gc: mark trace class storage ");
        try writer.writeAll(@tagName(trace_class));
        try writeCounterLine(writer, &.{
            .{ " allocation-touches ", aggregate.allocation_touches },
            .{ ", allocated-bytes ", aggregate.allocated_bytes },
            .{ ", touched-cache-lines ", aggregate.touched_cache_lines },
        }, "\n");
    }
    for (engine.core.gc_trace_stw.MarkFootprint.inline_limits, 0..) |limit, index| {
        const plain_external = fp.inline_eligible_objects[index] -
            fp.inline_direct_objects[index] -
            fp.inline_tail_grown_external_objects[index];
        try writeCounterLine(writer, &.{
            .{ "gc: inline property upper slots ", limit },
            .{ ", eligible-objects ", fp.inline_eligible_objects[index] },
            .{ ", direct-inline ", fp.inline_direct_objects[index] },
            .{ ", tail-grown-external ", fp.inline_tail_grown_external_objects[index] },
            .{ ", plain-external ", plain_external },
            .{ ", external-allocated-bytes ", fp.inline_property_bytes[index] },
            .{ ", external-touched-cache-lines ", fp.inline_property_cache_lines[index] },
        }, "\n");
        const ordinary_plain_external = fp.inline_ordinary_eligible_objects[index] -
            fp.inline_ordinary_direct_objects[index] -
            fp.inline_ordinary_tail_grown_external_objects[index];
        try writeCounterLine(writer, &.{
            .{ "gc: inline ordinary property upper slots ", limit },
            .{ ", eligible-objects ", fp.inline_ordinary_eligible_objects[index] },
            .{ ", direct-inline ", fp.inline_ordinary_direct_objects[index] },
            .{ ", tail-grown-external ", fp.inline_ordinary_tail_grown_external_objects[index] },
            .{ ", plain-external ", ordinary_plain_external },
            .{ ", external-allocated-bytes ", fp.inline_ordinary_property_bytes[index] },
            .{ ", external-touched-cache-lines ", fp.inline_ordinary_property_cache_lines[index] },
        }, "\n");
    }
}

fn dumpGcStats(writer: *std.Io.Writer, stats: zjs.GCStats, registry: *const engine.core.gc.Registry) !void {
    const minors = registry.generation.stats.minor_collections;
    try writeCounterLine(writer, &.{
        .{ "gc: collection entries total ", stats.collections },
        .{ ", major completed ", stats.major_gc_count },
        .{ ", minor completed ", minors },
        .{ ", failed ", stats.failed_collections },
    }, "\n");
    try writeCounterLine(writer, &.{
        .{ "gc: collector counted objects freed ", stats.freed_objects },
    }, " (excludes bytecode)\n");
    try writeCounterLine(writer, &.{
        .{ "gc: heap live ", stats.heap_live_bytes },
        .{ " bytes, account peak ", stats.peak_allocated_bytes },
    }, " bytes\n");
    // External is a separate reporting dimension, even where an ordinary
    // ArrayBuffer's engine-owned backing also overlaps the whole
    // MemoryAccount. The weighted debt is a pacing counter, not current live
    // bytes; printing both prevents either from being mistaken for the other.
    try writeCounterLine(writer, &.{
        .{ "gc: external bytes current ", stats.external_bytes },
        .{ ", peak ", stats.peak_external_bytes },
        .{ ", token bytes ", stats.external_token_bytes },
        .{ " in ", stats.external_token_count },
        .{ " tokens, untracked bytes ", stats.external_untracked_bytes },
        .{ ", allocations ", stats.external_alloc_count },
        .{ ", frees ", stats.external_free_count },
        .{ ", invalid releases ", stats.external_invalid_release_count },
        .{ ", weighted debt ", stats.allocation_debt },
    }, "\n");
    try writeCounterLine(writer, &.{
        .{ "gc: weak refs current ", stats.weak_ref_count },
        .{ ", finalizer queue current ", stats.finalizer_queue_length },
    }, "\n");
}

/// TGC S3 §2.6 audit. `stale-edge` counts holder edges that named an entry the
/// sweep had already retired -- it must be 0. `shell-edge` is the
/// informational mirror (an edge reaching a WeakRef'd shell, which is legal).
/// `entries` is the dynamic atom table's slot count, so the two are readable
/// as a rate.
fn dumpAtomAuditStats(writer: *std.Io.Writer, rt: *const zjs.JSRuntime) !void {
    try writeCounterLine(writer, &.{
        .{ "gc: atom audit stale-edge ", rt.atoms.atom_audit_stale_edge },
        .{ ", shell-edge ", rt.atoms.atom_audit_shell_edge },
        .{ ", entries ", rt.atoms.entries.len },
    }, "\n");
}

fn dumpGcDoomedState(writer: *std.Io.Writer, layer: []const u8, rt: *const zjs.JSRuntime) !void {
    try writeDoomedStateLine(writer, layer, engine.core.gc_trace_stw.doomedStateSnapshot(rt));
}

fn writeDoomedStateLine(
    writer: *std.Io.Writer,
    layer: []const u8,
    state: engine.core.gc_trace_stw.DoomedStateSnapshot,
) !void {
    try writer.writeAll("gc: ");
    try writer.writeAll(layer);
    try writer.writeAll(" doomed_pending ");
    try writer.writeAll(if (state.pending) "true" else "false");
    try writeCounterLine(writer, &.{
        .{ ", doomed_buckets ", state.nonempty_buckets },
        .{ ", doomed_headers ", state.bucket_headers },
    }, "");
    try writer.writeAll(", doomed_cursor ");
    try writer.writeAll(if (state.cursor_present) "true" else "false");
    try writeCounterLine(writer, &.{
        .{ ", doomed_blocks ", state.doomed_blocks },
        .{ ", deferred_finalizers ", state.deferred_finalizers },
    }, "");
    try writer.writeAll(", active_finalizer ");
    try writer.writeAll(if (state.active_finalizer) "true" else "false");
    try writer.writeAll("\n");
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
        try writer.writeAll("gc: major pauses none\n");
        return;
    };
    const retained = @min(d.samples, engine.core.gc.pause_sample_capacity);
    try writeCounterLine(writer, &.{
        .{ "gc: major pause p50 ", d.p50_ns },
        .{ " ns, p95 ", d.p95_ns },
        .{ " ns, p99 ", d.p99_ns },
        .{ " ns, max ", d.max_ns },
        .{ " ns, retained ", retained },
        .{ " of ", d.samples },
    }, " pauses\n");
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

    sort_erased.heap(OpcodeProfileRow, rows[0..row_count], {}, opcodeProfileRowLessThan);

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
            var name_buf: [32]u8 = undefined;
            var count_buf: [32]u8 = undefined;
            var total_buf: [32]u8 = undefined;
            var avg_buf: [32]u8 = undefined;
            var slow_buf: [32]u8 = undefined;
            try output.writeAll(spacePad(display_name, 20, false, &name_buf));
            try output.writeAll(" ");
            try output.writeAll(decPad(row.count, 9, &count_buf));
            try output.writeAll(" ");
            try output.writeAll(spacePad("not instrumented", 18, true, &total_buf));
            try output.writeAll(" ");
            try output.writeAll(spacePad("not instrumented", 16, true, &avg_buf));
            try output.writeAll(" ");
            try output.writeAll(spacePad("not instrumented", 16, true, &slow_buf));
            try output.writeAll("\n");
        } else {
            var name_buf: [32]u8 = undefined;
            var count_buf: [32]u8 = undefined;
            var total_buf: [32]u8 = undefined;
            var avg_buf: [32]u8 = undefined;
            var slow_buf: [32]u8 = undefined;
            try output.writeAll(spacePad(display_name, 20, false, &name_buf));
            try output.writeAll(" ");
            try output.writeAll(decPad(row.count, 9, &count_buf));
            try output.writeAll(" ");
            try output.writeAll(decPad(row.nanos, 13, &total_buf));
            try output.writeAll(" ");
            try output.writeAll(decPad(avg, 12, &avg_buf));
            try output.writeAll(" ");
            try output.writeAll(decPad(profile.slow_count[row.opcode], 10, &slow_buf));
            try output.writeAll("\n");
        }
    }

    // D12: the carrier's residents, one row per sub, named from the
    // declaration. Aggregating them into the one `using` row above is
    // exactly what 11.5 clause 3 forbids -- the cold plane's population
    // is the fact a reclaim decision needs.
    var sub_total: u64 = 0;
    for (profile.ext0_sub_count) |c| sub_total +|= c;
    if (sub_total != 0) {
        try output.print("\nUSING SUB               COUNT\n", .{});
        for (profile.ext0_sub_count, 0..) |c, sub| {
            if (c == 0) continue;
            const resident = engine.bytecode.opcode.logical.subForm(@intCast(sub));
            const name = if (resident) |form| @tagName(form) else "<range>";
            var name_buf: [32]u8 = undefined;
            var count_buf: [32]u8 = undefined;
            var sub_buf: [32]u8 = undefined;
            try output.writeAll(spacePad(name, 20, false, &name_buf));
            try output.writeAll(" ");
            try output.writeAll(decPad(c, 9, &count_buf));
            try output.writeAll("  (sub ");
            try output.writeAll(decPad(@as(u64, sub), 1, &sub_buf));
            try output.writeAll(")\n");
        }
    }

    // D12's family rollup: a GENERATED aggregation view over the form
    // counts, never a substitute for per-form rows.
    var family_counts = std.enums.EnumArray(engine.bytecode.opcode.logical.SemanticFamily, u64).initFill(0);
    for (profile.count, 0..) |c, id| {
        if (c == 0 or id >= engine.bytecode.opcode.op.op_count) continue;
        if (engine.bytecode.opcode.physical.stateOf(@intCast(id)) != .claimed) continue;
        const form: engine.bytecode.opcode.logical.LogicalOpcode = @enumFromInt(id);
        family_counts.getPtr(engine.bytecode.opcode.logical.familyOf(form)).* +|= c;
    }
    try output.print("\nFAMILY (rollup)         COUNT\n", .{});
    var fam_it = family_counts.iterator();
    while (fam_it.next()) |entry| {
        if (entry.value.* == 0) continue;
        var name_buf: [32]u8 = undefined;
        var count_buf: [32]u8 = undefined;
        try output.writeAll(spacePad(@tagName(entry.key), 20, false, &name_buf));
        try output.writeAll(" ");
        try output.writeAll(decPad(entry.value.*, 9, &count_buf));
        try output.writeAll("\n");
    }
}

extern "c" fn atexit(callback: *const fn () callconv(.c) void) c_int;

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
    try cli_process.printErrorJoin(io, &.{ "TypeError: not a function\n    at <anonymous> (", path, ":7:20)\n\n" });
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

test "zjs args reject the retired gc-shadow-check flag" {
    // The shadow observer went with the rc collector (2026-08-29); the flag it
    // gated must now be an error rather than a silently ignored word.
    try std.testing.expectError(error.Usage, parseArgs(&.{ "--gc-shadow-check", "-e", "1" }));
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

test "zjs args gate settlement implies GC stats" {
    const command = try parseArgs(&.{ "--gc-gate-settle", "input.js" });
    try std.testing.expect(command.file.options.gc_gate_settle);
    try std.testing.expect(command.file.options.gc_stats);
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

test "zjs mark footprint serialization preserves populated rows and missing census" {
    // Only the census field is read by this serializer; no collector is run.
    var rt: engine.core.JSRuntime = undefined;
    rt.gc_mark_footprint = .{ .major_censuses = 2, .marked_headers = 3, .block_headers = 4 };
    const fp = &rt.gc_mark_footprint;
    fp.by_kind[@intFromEnum(engine.core.gc.GcKind.object)] = 1;
    fp.by_kind[@intFromEnum(engine.core.gc.GcKind.function_bytecode)] = 2;
    fp.by_kind[@intFromEnum(engine.core.gc.GcKind.var_ref)] = 3;
    fp.by_kind[@intFromEnum(engine.core.gc.GcKind.realm_context)] = 4;
    fp.by_kind[@intFromEnum(engine.core.gc.GcKind.module)] = 5;
    fp.by_kind[@intFromEnum(engine.core.gc.GcKind.shape)] = 6;
    fp.by_kind[@intFromEnum(engine.core.gc.GcKind.big_int)] = 7;
    fp.by_kind[@intFromEnum(engine.core.gc.GcKind.string)] = 8;
    fp.by_kind[@intFromEnum(engine.core.gc.GcKind.property_storage)] = 9;
    fp.by_kind[@intFromEnum(engine.core.gc.GcKind.array_storage)] = 10;
    fp.by_kind[@intFromEnum(engine.core.gc.GcKind.payload)] = 11;
    for (&fp.storage, 0..) |*row, i| row.* = .{ .allocation_touches = i + 1, .allocated_bytes = i + 11, .touched_cache_lines = i + 21 };
    for (&fp.storage_by_trace_class, 0..) |*row, i| row.* = .{ .allocation_touches = i + 31, .allocated_bytes = i + 41, .touched_cache_lines = i + 51 };
    for (0..fp.inline_eligible_objects.len) |i| {
        fp.inline_eligible_objects[i] = i + 10;
        fp.inline_direct_objects[i] = 2;
        fp.inline_tail_grown_external_objects[i] = 3;
        fp.inline_property_bytes[i] = i + 100;
        fp.inline_property_cache_lines[i] = i + 20;
        fp.inline_ordinary_eligible_objects[i] = i + 8;
        fp.inline_ordinary_direct_objects[i] = 1;
        fp.inline_ordinary_tail_grown_external_objects[i] = 2;
        fp.inline_ordinary_property_bytes[i] = i + 80;
        fp.inline_ordinary_property_cache_lines[i] = i + 15;
    }
    const old_census = engine.core.gc_trace_stw.mark_footprint_census;
    defer engine.core.gc_trace_stw.mark_footprint_census = old_census;
    engine.core.gc_trace_stw.mark_footprint_census = true;
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try dumpGcMarkFootprint(&writer, &rt);
    const expected =
        \\gc: marked-set census majors 2, headers 3, block headers 4
        \\gc: marked-set kinds object 1, function-bytecode 2, var-ref 3, realm-context 4, module 5, shape 6, big-int 7, string 8, storage 30
        \\gc: marked-set trace classes ordinary-object 0, fast-array 0, bytecode-function 0, exotic-object 0, non-object 0
        \\gc: mark storage base allocation-touches 1, allocated-bytes 11, touched-cache-lines 21
        \\gc: mark storage shape allocation-touches 2, allocated-bytes 12, touched-cache-lines 22
        \\gc: mark storage property_slots allocation-touches 3, allocated-bytes 13, touched-cache-lines 23
        \\gc: mark storage dense_elements allocation-touches 4, allocated-bytes 14, touched-cache-lines 24
        \\gc: mark storage trace_payload allocation-touches 5, allocated-bytes 15, touched-cache-lines 25
        \\gc: mark storage payload_backing allocation-touches 6, allocated-bytes 16, touched-cache-lines 26
        \\gc: mark trace class storage ordinary_object allocation-touches 31, allocated-bytes 41, touched-cache-lines 51
        \\gc: mark trace class storage fast_array allocation-touches 32, allocated-bytes 42, touched-cache-lines 52
        \\gc: mark trace class storage bytecode_function allocation-touches 33, allocated-bytes 43, touched-cache-lines 53
        \\gc: mark trace class storage exotic_object allocation-touches 34, allocated-bytes 44, touched-cache-lines 54
        \\gc: mark trace class storage non_object allocation-touches 35, allocated-bytes 45, touched-cache-lines 55
        \\gc: inline property upper slots 1, eligible-objects 10, direct-inline 2, tail-grown-external 3, plain-external 5, external-allocated-bytes 100, external-touched-cache-lines 20
        \\gc: inline ordinary property upper slots 1, eligible-objects 8, direct-inline 1, tail-grown-external 2, plain-external 5, external-allocated-bytes 80, external-touched-cache-lines 15
        \\gc: inline property upper slots 2, eligible-objects 11, direct-inline 2, tail-grown-external 3, plain-external 6, external-allocated-bytes 101, external-touched-cache-lines 21
        \\gc: inline ordinary property upper slots 2, eligible-objects 9, direct-inline 1, tail-grown-external 2, plain-external 6, external-allocated-bytes 81, external-touched-cache-lines 16
        \\gc: inline property upper slots 4, eligible-objects 12, direct-inline 2, tail-grown-external 3, plain-external 7, external-allocated-bytes 102, external-touched-cache-lines 22
        \\gc: inline ordinary property upper slots 4, eligible-objects 10, direct-inline 1, tail-grown-external 2, plain-external 7, external-allocated-bytes 82, external-touched-cache-lines 17
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.buffered());
    engine.core.gc_trace_stw.mark_footprint_census = false;
    writer = std.Io.Writer.fixed(&buffer);
    try dumpGcMarkFootprint(&writer, &rt);
    try std.testing.expectEqualStrings("gc: marked-set census not run (pass --gc-mark-footprint; it costs a whole-heap walk inside every final remark)\n", writer.buffered());
    engine.core.gc_trace_stw.mark_footprint_census = true;
    var small: [1]u8 = undefined;
    writer = std.Io.Writer.fixed(&small);
    try std.testing.expectError(error.WriteFailed, dumpGcMarkFootprint(&writer, &rt));
}

test "zjs generation diagnostic lines preserve populated snapshot" {
    var memory = engine.core.memory.MemoryAccount.init(std.testing.allocator);
    var registry: engine.core.gc.Registry = .{ .memory = &memory };
    inline for (@typeInfo(@TypeOf(registry.generation.stats)).@"struct".fields, 0..) |field, i| {
        if (@typeInfo(field.type) == .int) @field(registry.generation.stats, field.name) = @intCast(i + 11);
    }
    inline for (@typeInfo(@TypeOf(registry.incremental.stats)).@"struct".fields, 0..) |field, i| {
        if (@typeInfo(field.type) == .int) @field(registry.incremental.stats, field.name) = @intCast(i + 101);
    }
    var samples = [_]u64{ 7, 2, 5 };
    registry.generation.minor_pause_samples = .{ .items = &samples, .capacity = samples.len };
    const old_verify = engine.core.gc.verify_minor;
    defer engine.core.gc.verify_minor = old_verify;
    engine.core.gc.verify_minor = false;
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try dumpGcGenerationStats(&writer, &registry);
    const expected =
        \\gc: generation current young 12, remembered owners 0
        \\gc: generation current young-trigger 13 (excludes owner-decided storage cells)
        \\gc: minor collections 16, reclaimed 17, promoted-by-minor 18, promoted-all 19, remembered without young 20, remembered drops 14, suspensions 15
        \\gc: major retirement commits 36, abandons 37, current state clean
        \\gc: generational barrier calls 21, exit young-owner 22, exit old-target 23, remembered-owner 0
        \\gc: minor stw total 24 ns, mean 1 ns, max 25 ns
        \\gc: minor pause p50 5 ns, p95 7 ns, p99 7 ns, max 7 ns over 3 retained of 3 samples
        \\gc: minor phase totals clear 26, roots 27, conservative 28, remembered 29, trace 30, sweep+destroy 31, promote 32, other 0 ns
        \\gc: minor young-at-start mean 2, max 34
        \\gc: conservative-only young unavailable (set ZJS_GC_VERIFY_MINOR=1)
        \\gc: exact-target marking barrier calls 102, exit marked-target 103, exit unpublished-owner 104, exit unpublished-target 105, requeued-owner 106, shaded-target 101
        \\gc: incremental doomed condemned headers 121, destroyed counted objects 122, parked entries drained 123, parked-drain slices 124
        \\gc: incremental major cycles completed 107, aborted 108, forced 114, mark steps 109, cycle STW last 110 ns max 113 ns
        \\gc: cycle envelope measured 115, skipped 116, max-P/T S 117, T 118, B 119, P 120, B/T-x1000000 1008475, P/T-x1000000 1016950, P/S-x1000000 1025642, forced 114
        \\gc: incremental STW phase-segment max ns begin 0, increment 0, destroy 0, finish 0
        \\gc: incremental STW phase totals begin 0 ns/0 segments, increment 0 ns/0 segments, destroy 0 ns/0 segments, finish 0 ns/0 segments
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "zjs doomed state line preserves mixed bools and counters" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeDoomedStateLine(&writer, "endpoint", .{
        .pending = true,
        .nonempty_buckets = 2,
        .bucket_headers = 7,
        .cursor_present = false,
        .doomed_blocks = 11,
        .deferred_finalizers = 13,
        .active_finalizer = true,
    });
    try std.testing.expectEqualStrings(
        "gc: endpoint doomed_pending true, doomed_buckets 2, doomed_headers 7, doomed_cursor false, doomed_blocks 11, deferred_finalizers 13, active_finalizer true\n",
        writer.buffered(),
    );
    writer = std.Io.Writer.fixed(&buffer);
    try writeDoomedStateLine(&writer, "settled", .{
        .pending = false,
        .nonempty_buckets = 0,
        .bucket_headers = 0,
        .cursor_present = true,
        .doomed_blocks = 0,
        .deferred_finalizers = 0,
        .active_finalizer = false,
    });
    try std.testing.expectEqualStrings(
        "gc: settled doomed_pending false, doomed_buckets 0, doomed_headers 0, doomed_cursor true, doomed_blocks 0, deferred_finalizers 0, active_finalizer false\n",
        writer.buffered(),
    );
    writer = std.Io.Writer.fixed(buffer[0..8]);
    try std.testing.expectError(error.WriteFailed, writeDoomedStateLine(&writer, "endpoint", .{
        .pending = true,
        .nonempty_buckets = 1,
        .bucket_headers = 1,
        .cursor_present = true,
        .doomed_blocks = 1,
        .deferred_finalizers = 1,
        .active_finalizer = true,
    }));
}

test "zjs column pad matches std fmt min-width" {
    const dec_cases = .{
        .{ 0, 1, "{d:>1}" },
        .{ 0, 5, "{d:>5}" },
        .{ 3, 5, "{d:>5}" },
        .{ 123456, 5, "{d:>5}" },
        .{ 0, 8, "{d:>8}" },
        .{ 999999999, 8, "{d:>8}" },
        .{ 1, 9, "{d:>9}" },
        .{ 12345678901, 9, "{d:>9}" },
        .{ 0, 13, "{d:>13}" },
        .{ 1, 12, "{d:>12}" },
        .{ 1, 10, "{d:>10}" },
        .{ std.math.maxInt(u64), 8, "{d:>8}" },
    };
    inline for (dec_cases) |case| {
        var expected_buf: [32]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buf, case[2], .{@as(u64, case[0])});
        var actual_buf: [32]u8 = undefined;
        try std.testing.expectEqualStrings(expected, decPad(case[0], case[1], &actual_buf));
    }

    const space_cases = .{
        .{ "atoms", 22, false, "{s:<22}" },
        .{ "memory allocated", 22, false, "{s:<22}" },
        .{ "this-name-is-longer-than-22-chars", 22, false, "{s:<22}" },
        .{ "get_var", 20, false, "{s:<20}" },
        .{ "not instrumented", 18, true, "{s:>18}" },
        .{ "not instrumented", 16, true, "{s:>16}" },
        .{ "overflow-string-value", 16, true, "{s:>16}" },
    };
    inline for (space_cases) |case| {
        var expected_buf: [64]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buf, case[3], .{case[0]});
        var actual_buf: [32]u8 = undefined;
        try std.testing.expectEqualStrings(expected, spacePad(case[0], case[1], case[2], &actual_buf));
    }
}

test "zjs opcode profile table preserves min-width columns" {
    var profile: zjs.OpcodeProfile = undefined;
    initOpcodeProfile(&profile);
    const get_var = engine.bytecode.opcode.op.get_var;
    const push_i16 = engine.bytecode.opcode.op.push_i16;
    profile.recordOpcode(get_var, 17);
    profile.recordOpcode(push_i16, 5);
    profile.slow_count[get_var] = 12345678901;
    profile.ext0_sub_count[3] = 7;

    var buf: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try dumpOpcodeProfile(&writer, &profile);
    const text = writer.buffered();

    const get_var_name = zjs.OpcodeProfile.opcodeName(get_var);
    const push_name = zjs.OpcodeProfile.opcodeName(push_i16);
    var row_buf: [128]u8 = undefined;
    if (comptime zjs.opcode_profile_build_enabled) {
        const row = try std.fmt.bufPrint(&row_buf, "{s:<20} {d:>9} {s:>18} {s:>16} {s:>16}\n", .{
            get_var_name,
            @as(u64, 1),
            "not instrumented",
            "not instrumented",
            "not instrumented",
        });
        try std.testing.expect(std.mem.indexOf(u8, text, row) != null);
    } else {
        const get_var_row = try std.fmt.bufPrint(&row_buf, "{s:<20} {d:>9} {d:>13} {d:>12} {d:>10}\n", .{
            get_var_name,
            @as(u64, 1),
            @as(u64, 17),
            @as(u64, 17),
            profile.slow_count[get_var],
        });
        try std.testing.expect(std.mem.indexOf(u8, text, get_var_row) != null);
        const push_row = try std.fmt.bufPrint(&row_buf, "{s:<20} {d:>9} {d:>13} {d:>12} {d:>10}\n", .{
            push_name,
            @as(u64, 1),
            @as(u64, 5),
            @as(u64, 5),
            @as(u64, 0),
        });
        try std.testing.expect(std.mem.indexOf(u8, text, push_row) != null);
    }

    const resident = engine.bytecode.opcode.logical.subForm(3);
    const sub_name = if (resident) |form| @tagName(form) else "<range>";
    const sub_row = try std.fmt.bufPrint(&row_buf, "{s:<20} {d:>9}  (sub {d})\n", .{
        sub_name,
        @as(u64, 7),
        @as(u64, 3),
    });
    try std.testing.expect(std.mem.indexOf(u8, text, sub_row) != null);
}

test "zjs counter line handles full unsigned range and writer errors" {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeCounterLine(&writer, &.{ .{ "zero ", 0 }, .{ ", max ", std.math.maxInt(u64) } }, " bytes\n");
    try std.testing.expectEqualStrings("zero 0, max 18446744073709551615 bytes\n", writer.buffered());
    // Fail after the first field, then at the trailing suffix.
    for ([_]usize{ 8, 32 }) |capacity| {
        writer = std.Io.Writer.fixed(buffer[0..capacity]);
        try std.testing.expectError(error.WriteFailed, writeCounterLine(&writer, &.{ .{ "zero ", 0 }, .{ ", max ", std.math.maxInt(u64) } }, " bytes\n"));
    }
}

test "zjs registry diagnostic panels preserve populated snapshot" {
    var memory = engine.core.memory.MemoryAccount.init(std.testing.allocator);
    var registry: engine.core.gc.Registry = .{ .memory = &memory };
    inline for (@typeInfo(@TypeOf(registry.stats)).@"struct".fields, 0..) |field, i| {
        if (@typeInfo(field.type) == .int) @field(registry.stats, field.name) = @intCast(i + 11);
    }
    inline for (@typeInfo(@TypeOf(registry.block_heap.stats)).@"struct".fields, 0..) |field, i| {
        if (@typeInfo(field.type) == .int) @field(registry.block_heap.stats, field.name) = @intCast(i + 101);
    }
    inline for (@typeInfo(@TypeOf(registry.incremental.stats)).@"struct".fields, 0..) |field, i| {
        if (@typeInfo(field.type) == .int) @field(registry.incremental.stats, field.name) = @intCast(i + 201);
    }
    registry.incremental.stats.total_stw_by_kind = .{ 10000, 20000, 30000, 40000 };
    registry.space_histogram.record(32);
    registry.space_histogram.record(128);
    registry.space_histogram.record(70000);
    var buffer: [16384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try dumpGcSpaceStats(&writer, &registry);
    try dumpGcBlockCensus(&writer, &registry);
    try dumpGcBlockHeapStats(&writer, &registry);
    try dumpGcPhaseTotals(&writer, &registry);
    var stats: zjs.GCStats = .{};
    inline for (@typeInfo(zjs.GCStats).@"struct".fields, 0..) |field, i| {
        if (@typeInfo(field.type) == .int) @field(stats, field.name) = @intCast(i + 301);
    }
    try dumpGcStats(&writer, stats, &registry);
    try dumpGcPauses(&writer, null);
    try dumpGcPauses(&writer, .{ .samples = 3, .p50_ns = 2, .p95_ns = 3, .p99_ns = 5, .max_ns = 7 });
    const expected =
        \\gc: allocation histogram publications 3, payload bytes 70160, p50-below-large 32, p95-below-large 128, p99-below-large 128, max-small 3760, covered-by-small 2/2 below-large, large 1
        \\gc: block census classed superblocks 0, other 0, uninitialized slots 0
        \\gc: block census columns cell_bytes blocks cells allocated occ_x1000 empty lt10 lt50 ge50 young decommitted active hot free
        \\gc: block census total 0 0 0 0 0 0 0 0 0 0 0 0 0 0
        \\gc: block heap committed 101 live 0 committed/live-x1000 0 superblocks 103 large maps 104
        \\gc: block heap deferred block runs 115, hot reuse published 116, reopened 117, bitmap reclaimed cells 127
        \\gc: block heap hot publish rejects empty 118, capacity 119, active 120, doomed 121, young 122, listed 123, decommitted 124, cached-k 125, k-rejected reopens 126
        \\gc: major threshold resets growth 29, small-heap-floor 30
        \\gc: object destructor calls 32, plain-object calls 33, plain objects carrying the finalizer bit 34
        \\gc: block heap page returns cumulative decommitted 109, recommitted 110
        \\gc: block heap medium superblocks returned 128, bytes 129
        \\gc: block heap decommit checks 111, released blocks cumulative 0, current bytes 0, max batch bytes 112
        \\gc: process heap trim attempts 113, successes 114
        \\gc: incremental subphase ns totals begin-clear 226, begin-precise-seed 227, begin-conservative-seed 228, begin-retire 229, finish-remark-total 230, finish-conservative-seed-subset 231, finish-weak 232, finish-condemn 233
        \\gc: incremental subphase reconciliation finish-init 234, finish-tail 235; begin STW 10000 - subphases 910 = other 9090 ns; finish STW 40000 - subphases 1164 = other 38836 ns
        \\gc: incremental subphase work totals retired non-block headers 236, retired young blocks 237, retired remembered sets 238, clearMarks non-block headers 239
        \\gc: collection entries total 321, major completed 322, minor completed 0, failed 326
        \\gc: collector counted objects freed 328 (excludes bytecode)
        \\gc: heap live 303 bytes, account peak 302 bytes
        \\gc: external bytes current 312, peak 314, token bytes 318 in 317 tokens, untracked bytes 313, allocations 315, frees 316, invalid releases 319, weighted debt 320
        \\gc: weak refs current 330, finalizer queue current 331
        \\gc: major pauses none
        \\gc: major pause p50 2 ns, p95 3 ns, p99 5 ns, max 7 ns, retained 3 of 3 pauses
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "zjs perf JSON metrics preserve populated fields" {
    const timings: PerfJsonTimings = .{
        .total_ns = 1,
        .read_source_ns = 2,
        .runtime_create_ns = 3,
        .setup_ns = 4,
        .include_ns = 5,
        .eval_ns = 6,
        .jobs_ns = 10,
        .zjs = .{ .parse_ns = 7, .vm_run_ns = 8, .promise_jobs_ns = 9 },
    };
    var memory = std.mem.zeroes(zjs.RuntimeMemoryUsage);
    memory.allocated_bytes = 11;
    memory.allocation_count = 12;
    memory.peak_allocated_bytes = 13;
    memory.peak_allocation_count = 14;
    memory.alloc_calls = 15;
    memory.free_calls = 16;
    memory.create_calls = 17;
    memory.destroy_calls = 18;
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try dumpPerfJsonMetrics(&writer, memory, timings);
    const expected =
        \\  "total_ns": 1,
        \\  "read_source_ns": 2,
        \\  "runtime_create_ns": 3,
        \\  "setup_ns": 4,
        \\  "include_ns": 5,
        \\  "eval_ns": 6,
        \\  "parse_ns": 7,
        \\  "finalize_ns": null,
        \\  "parse_ns_includes_finalize": true,
        \\  "vm_run_ns": 8,
        \\  "promise_jobs_ns": 9,
        \\  "jobs_ns": 10,
        \\  "memory": {
        \\    "allocated_bytes": 11,
        \\    "allocation_count": 12,
        \\    "allocated_bytes_peak": 13,
        \\    "allocation_count_peak": 14,
        \\    "alloc_calls": 15,
        \\    "free_calls": 16,
        \\    "create_calls": 17,
        \\    "destroy_calls": 18
        \\  }
    ;
    try std.testing.expectEqualStrings(expected, writer.buffered());
    writer = std.Io.Writer.fixed(buf[0..17]);
    try std.testing.expectError(error.WriteFailed, dumpPerfJsonMetrics(&writer, memory, timings));
}

test "zjs memory table preserves widths and populated fields" {
    var memory = std.mem.zeroes(zjs.RuntimeMemoryUsage);
    memory.allocation_count = 123456;
    memory.allocated_bytes = 999999999;
    memory.atom_count = 3;
    memory.atom_bytes = 4;
    memory.object_count = 5;
    memory.object_bytes = 6;
    memory.shape_count = 7;
    memory.shape_bytes = 8;
    memory.module_count = 9;
    memory.module_bytes = 10;
    memory.registered_class_count = 11;
    memory.class_bytes = 12;
    const rows =
        \\memory allocated       123456 999999999
        \\atoms                      3        4
        \\objects                    5        6
        \\shapes                     7        8
        \\modules                    9       10
        \\classes                   11       12
        \\
    ;
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try dumpMemorySnapshot(&writer, memory);
    try std.testing.expectEqualStrings("\nZJS memory usage\n  memory limit: 0\n\nNAME                    COUNT     SIZE\n" ++ rows, writer.buffered());
    memory.memory_limit = 101;
    writer = std.Io.Writer.fixed(&buf);
    try dumpMemorySnapshot(&writer, memory);
    try std.testing.expectEqualStrings("\nZJS memory usage\n  memory limit: 101\n\nNAME                    COUNT     SIZE\n" ++ rows, writer.buffered());
    writer = std.Io.Writer.fixed(buf[0..1]);
    try std.testing.expectError(error.WriteFailed, dumpMemorySnapshot(&writer, memory));
}

// Materialize the declared defaults without a 18 KiB .rodata copy of
// `OpcodeProfile{}`. Every field is zero except `pending_op`, whose type
// default is the pending-dispatch sentinel.
fn initOpcodeProfile(profile: *zjs.OpcodeProfile) void {
    profile.* = std.mem.zeroes(zjs.OpcodeProfile);
    profile.pending_op = zjs.OpcodeProfile.no_pending_op;
}

test "opcode profile initialization preserves every default field" {
    var profile: zjs.OpcodeProfile = undefined;
    initOpcodeProfile(&profile);
    try std.testing.expectEqualDeep(zjs.OpcodeProfile{}, profile);
}

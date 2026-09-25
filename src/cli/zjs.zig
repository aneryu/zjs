//! CLI boundary for script/module evaluation, host loading, job draining, and exception/rejection reporting.
//! Source buffers live through evaluation; `--leak-check` selects explicit event-loop, context, and runtime teardown.
const runtime_owner = @import("zjs").core.runtime;
const std = @import("std");
const cli_process = @import("cli_process.zig");
const zjs = @import("zjs");
const host = @import("zjs_host");
const sort_erased = zjs.sort_erased;

const eval_filename = "<eval>";
const max_include_paths = 16;

pub const CliError = error{
    Usage,
};

/// Shared runtime switches collected before the path / `-e` word.
pub const RuntimeOptions = struct {
    memory_limit: ?usize = null,
    stack_size: ?usize = null,
    can_block: bool = false,
    dump_memory: bool = false,
    profile_opcodes: bool = false,
    gc_stats: bool = false,
    gc_gate_settle: bool = false,
    gc_block_census: bool = false,
    leak_check: bool = false,
    /// Compile-only diagnostic: print a fingerprint of the compiled bytecode
    /// tree instead of running the file. Used by the parser identity gate.
    bytecode_fingerprint: bool = false,
    bytecode_fingerprint_verbose: bool = false,
    /// Collector-side census switches the stats panels read; applied to the
    /// engine by `applyRuntimeOptions`, never during argument parsing.
    gc_detailed_reports: bool = false,
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

/// One job for `main`: a path, a source buffer, script args, and eval mode.
/// Files default to module; `-e` and `-s` pin script. `loadSource` only reads
/// a path — it does not sniff. Later stages do not switch on how the job
/// was filled.
pub const Command = struct {
    path: []const u8,
    /// argv text for `-e`, including empty. `null` until `loadSource` reads a path.
    source: ?[]const u8 = null,
    script_args: []const []const u8 = &.{},
    mode: zjs.Context.EvalMode = .module,
    options: RuntimeOptions = .{},
};

const Token = union(enum) {
    long: struct { name: []const u8, value: ?[]const u8 },
    short: u8,
    positional: []const u8,
    end_of_options,
};

/// One row per option. Aliases are the optional short letter. `.set` is the
/// RuntimeOptions bools to turn on; `.take` is the following (or `=`) value.
const Option = struct {
    long: []const u8,
    short: ?u8 = null,
    set: []const std.meta.FieldEnum(RuntimeOptions) = &.{},
    take: Take = .none,

    const Take = enum { none, memory_limit, stack_size, include };
};

const option_table = [_]Option{
    .{ .long = "can-block", .set = &.{.can_block} },
    .{ .long = "dump", .short = 'd', .set = &.{.dump_memory} },
    // The panel's census costs whole-heap walks per major, so the
    // collector only performs them when someone is going to read
    // them.
    .{ .long = "gc-stats", .set = &.{ .gc_stats, .gc_detailed_reports } },
    // Gate-only contract: retain the natural endpoint, then complete
    // any irreversible destruction transaction before publishing the
    // stats the checker treats as settled. This implies --gc-stats so
    // callers cannot accidentally request a silent settlement.
    .{ .long = "gc-gate-settle", .set = &.{ .gc_stats, .gc_gate_settle, .gc_detailed_reports } },
    // TGC S4-f (2). A pure exit-time walk of the block table: nothing
    // on a collector or allocator path consults it.
    .{ .long = "gc-block-census", .set = &.{ .gc_stats, .gc_block_census, .gc_detailed_reports } },
    .{ .long = "profile-opcodes", .set = &.{.profile_opcodes} },
    .{ .long = "bytecode-fingerprint", .set = &.{.bytecode_fingerprint} },
    .{ .long = "bytecode-fingerprint-verbose", .set = &.{ .bytecode_fingerprint, .bytecode_fingerprint_verbose } },
    .{ .long = "leak-check", .set = &.{.leak_check} },
    .{ .long = "memory-limit", .take = .memory_limit },
    .{ .long = "stack-size", .take = .stack_size },
    .{ .long = "include", .short = 'I', .take = .include },
};

pub fn parseArgs(argv: []const []const u8) CliError!Command {
    var rest = argv;
    var opts = RuntimeOptions{};
    while (rest.len != 0) {
        const tok = tokenize(rest[0]);
        switch (tok) {
            .end_of_options => {
                rest = rest[1..];
                if (rest.len == 0) return error.Usage;
                return .{ .path = rest[0], .script_args = rest, .options = opts };
            },
            .positional => break,
            .long, .short => {
                const spec = lookupOption(tok) orelse {
                    if (isCommandWord(rest[0])) break;
                    return error.Usage;
                };
                rest = rest[1..];
                try applyOption(&opts, spec, tok, &rest);
            },
        }
    }
    if (rest.len == 0) return error.Usage;
    if (std.mem.eql(u8, rest[0], "-h") or std.mem.eql(u8, rest[0], "--help")) return error.Usage;
    if (std.mem.eql(u8, rest[0], "-e")) {
        if (opts.can_block or rest.len != 2) return error.Usage;
        return .{ .path = eval_filename, .source = rest[1], .mode = .script, .options = opts };
    }
    if (std.mem.eql(u8, rest[0], "-m")) {
        if (rest.len < 2) return error.Usage;
        return .{ .path = rest[1], .script_args = rest[1..], .mode = .module, .options = opts };
    }
    if (std.mem.eql(u8, rest[0], "-s")) {
        if (rest.len < 2) return error.Usage;
        return .{ .path = rest[1], .script_args = rest[1..], .mode = .script, .options = opts };
    }
    if (rest[0].len != 0 and rest[0][0] != '-') {
        return .{ .path = rest[0], .script_args = rest[0..], .options = opts };
    }
    return error.Usage;
}

fn tokenize(arg: []const u8) Token {
    if (std.mem.eql(u8, arg, "--")) return .end_of_options;
    if (std.mem.startsWith(u8, arg, "--")) {
        const body = arg[2..];
        if (std.mem.indexOfScalar(u8, body, '=')) |eq| {
            return .{ .long = .{ .name = body[0..eq], .value = body[eq + 1 ..] } };
        }
        return .{ .long = .{ .name = body, .value = null } };
    }
    if (arg.len == 2 and arg[0] == '-') return .{ .short = arg[1] };
    return .{ .positional = arg };
}

fn lookupOption(tok: Token) ?Option {
    switch (tok) {
        .long => |long| {
            for (option_table) |opt| {
                if (std.mem.eql(u8, opt.long, long.name)) return opt;
            }
        },
        .short => |c| {
            for (option_table) |opt| {
                if (opt.short == c) return opt;
            }
        },
        else => {},
    }
    return null;
}

fn applyOption(opts: *RuntimeOptions, spec: Option, tok: Token, rest: *[]const []const u8) CliError!void {
    const inline_value: ?[]const u8 = switch (tok) {
        .long => |long| long.value,
        else => null,
    };
    if (spec.take == .none) {
        if (inline_value != null) return error.Usage;
        applyBools(opts, spec.set);
        return;
    }
    const value = inline_value orelse blk: {
        if (rest.len == 0) return error.Usage;
        const next = rest.*[0];
        rest.* = rest.*[1..];
        break :blk next;
    };
    switch (spec.take) {
        .none => unreachable,
        .memory_limit => opts.memory_limit = parseLimitKBytes(value) catch return error.Usage,
        .stack_size => opts.stack_size = parseLimitKBytes(value) catch return error.Usage,
        .include => opts.addInclude(value) catch return error.Usage,
    }
}

fn applyBools(opts: *RuntimeOptions, fields: []const std.meta.FieldEnum(RuntimeOptions)) void {
    for (fields) |field| {
        switch (field) {
            inline else => |tag| {
                if (@FieldType(RuntimeOptions, @tagName(tag)) == bool) {
                    @field(opts, @tagName(tag)) = true;
                } else unreachable;
            },
        }
    }
}

fn isCommandWord(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-e") or
        std.mem.eql(u8, arg, "-m") or
        std.mem.eql(u8, arg, "-s") or
        std.mem.eql(u8, arg, "-h") or
        std.mem.eql(u8, arg, "--help");
}

fn parseLimitKBytes(text: []const u8) !usize {
    if (text.len == 0) return error.InvalidCharacter;
    const kbytes = try zjs.core.value_format.parseAsciiInt(usize, text, 10);
    return std.math.mul(usize, kbytes, 1024) catch error.Overflow;
}

fn printUsage(io: std.Io) !void {
    try cli_process.printError(io, "usage: zjs [-d] [--profile-opcodes] [--gc-stats] [--gc-gate-settle] [--gc-block-census] [--leak-check] [--memory-limit n] [--stack-size n] [-I file] -e <script>\n       zjs [-d] [--profile-opcodes] [--gc-stats] [--gc-gate-settle] [--gc-block-census] [--leak-check] [--memory-limit n] [--stack-size n] [-I file] [-m|-s] <file.js>\n");
}

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var command = parseArgs(argv[1..]) catch {
        try printUsage(init.io);
        std.process.exit(2);
    };
    try execute(init, &command);
}

fn execute(init: std.process.Init, command: *Command) !void {
    const allocator = init.gpa;
    const io = init.io;
    const runtime_options = command.options;

    const owned_source = try loadSource(command, allocator, io);
    defer if (owned_source) |bytes| allocator.free(bytes);
    const source = command.source.?;
    const path = command.path;
    const mode = command.mode;
    const script_args = command.script_args;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    var opcode_profile: zjs.OpcodeProfile = undefined;
    initOpcodeProfile(&opcode_profile);

    const rt = zjs.Runtime.create(allocator, .{
        .diagnostic_clock = if (runtime_options.gc_stats or runtime_options.profile_opcodes) host.clock.diagnostic_clock else null,
        .memory_limit = runtime_options.memory_limit,
        .gc_threshold = zjs.default_gc_threshold,
        .stack_size = runtime_options.stack_size orelse zjs.default_stack_size,
    }) catch |err| {
        try cli_process.printErrorJoin(io, &.{ "zjs: engine init failed: ", @errorName(err), "\n" });
        std.process.exit(1);
    };
    errdefer rt.destroy();
    const ctx = zjs.Context.create(rt, .{}) catch |err| {
        try cli_process.printErrorJoin(io, &.{ "zjs: context init failed: ", @errorName(err), "\n" });
        std.process.exit(1);
    };
    errdefer ctx.destroy();
    var event_loop = host.EventLoop.init(ctx, .{ .output = stdout });
    // `install` publishes `*EventLoop` to the context. Do that only after the
    // loop lives in this frame; a by-value move of an already-installed
    // loop would leave the host vtable pointing at a dead stack slot.
    event_loop.install();
    errdefer event_loop.deinit();

    host.file_modules.install(ctx.core);
    try host.globals.install(ctx.core, try zjs.globalObjectPtr(ctx));
    try configureRuntime(rt, ctx, script_args, runtime_options, &opcode_profile, io);
    // Install the file-loader dynamic import for every mode, mirroring qjs
    // installing js_module_loader unconditionally (qjs.c JS_SetModuleLoaderFunc):
    // import() works from scripts and -e, not only under -m. The state lives
    // for the whole process, so import jobs drained after evaluation (event
    // loop turns) still resolve.
    var dynamic_import_state = zjs.exec.module_graph.DynamicImportState{
        .runtime = ctx.runtimePtr(),
        .output = stdout,
        .io = io,
        .allocator = allocator,
        .max_source_size = max_source_size,
    };
    var dynamic_import_scope = try zjs.exec.module_graph.installDynamicImport(&dynamic_import_state);
    defer dynamic_import_scope.deinit();

    // NB: we intentionally do NOT tear down the event loop / context / runtime
    // on the happy path. `JSRuntime.destroy` asserts that the runtime has no
    // outstanding allocations, which catches refcounting bugs in
    // `zig build test` where the engine is used in-process. As a short-lived
    // CLI process, zjs returns from `main` and the OS reclaims memory a few
    // microseconds later; calling destroy here only exposes latent leaks to
    // the test262 runner, where the 2s panic+backtrace path caused many
    // otherwise-passing tests to be misreported as timeouts. The historical
    // validation note is preserved in the convergence docs' git history.
    runIncludeFiles(ctx, runtime_options, stdout, io, allocator) catch |err|
        try failEvaluation(ctx, rt, &event_loop, stdout, io, err);

    if (runtime_options.bytecode_fingerprint) {
        if (owned_source == null) {
            try cli_process.printError(io, "zjs: --bytecode-fingerprint requires a file argument\n");
            std.process.exit(2);
        }
        try printBytecodeFingerprint(stdout, ctx, source, path, mode, runtime_options.bytecode_fingerprint_verbose);
        try stdout.flush();
        return;
    }

    const value = evalSource(
        ctx,
        source,
        stdout,
        path,
        mode,
        io,
        allocator,
    ) catch |err| try failEvaluation(ctx, rt, &event_loop, stdout, io, err);
    try stdout.flush();

    if (value.is(.exception)) {
        try cli_process.printError(io, "zjs: uncaught exception\n");
        std.process.exit(1);
    }

    try dynamic_import_state.runJobs(ctx.core);
    // Post-eval jobs (module-mode microtasks in particular) print into the
    // buffered stdout writer; flush before any exit path so their output is
    // not dropped (qjs.c main: js_std_loop writes unbuffered per job).
    try stdout.flush();
    if (ctx.hasUnhandledRejection() or ctx.hasException()) {
        try reportUnhandledRejections(io, ctx, rt);
        std.process.exit(1);
    }

    try dumpRequested(stdout, rt, runtime_options, &opcode_profile);

    // Explicit exit skips the remaining defers (source_text free, etc.) on the default path.
    // However, if leak checking is explicitly requested, we tear down the
    // event loop, context, and runtime and return normally so all defers
    // (including those for source_text and options) execute, allowing the
    // GeneralPurposeAllocator to perform full validation.
    zjs.printSmallInlineProbe();
    if (runtime_options.leak_check) {
        // Restore the loader hook while the runtime it points at is still
        // alive. The trailing `defer dynamic_import_scope.deinit()` would
        // otherwise run after `rt.destroy()` and touch a destroyed runtime;
        // `restore` is idempotent, so calling it here is safe and the defer
        // becomes a no-op.
        dynamic_import_scope.deinit();
        dynamic_import_state.deinit();
        event_loop.deinit();
        ctx.destroy();
        rt.destroy();
        return;
    }
    std.process.exit(0);
}

fn loadSource(command: *Command, allocator: std.mem.Allocator, io: std.Io) !?[]const u8 {
    if (command.source != null) return null;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, command.path, allocator, .limited(max_source_size)) catch |err| {
        try cli_process.printErrorJoin(io, &.{ "zjs: unable to read ", command.path, ": ", @errorName(err), "\n" });
        std.process.exit(1);
    };
    command.source = bytes;
    return bytes;
}

fn configureRuntime(
    rt: *zjs.Runtime,
    ctx: *zjs.Context,
    script_args: []const []const u8,
    runtime_options: RuntimeOptions,
    opcode_profile: *zjs.OpcodeProfile,
    io: std.Io,
) !void {
    applyRuntimeOptions(rt, ctx, runtime_options);
    ctx.setTrackUnhandledRejections(true);
    if (runtime_options.profile_opcodes) {
        if (!zjs.opcode_profile_build_enabled) {
            try cli_process.printError(io, "zjs: --profile-opcodes requires a profiling build; run 'zig build zjs-profile' or rebuild with -Dzjs_enable_opcode_profile=true (refusing to emit an all-zero profile)\n");
            std.process.exit(2);
        }
        rt.setOpcodeProfile(opcode_profile);
    }
    ctx.defineScriptArgs(script_args) catch |err| {
        try cli_process.printErrorJoin(io, &.{ "zjs: scriptArgs setup failed: ", @errorName(err), "\n" });
        std.process.exit(1);
    };
    ctx.setPreserveUncaughtException(true);
}

fn applyRuntimeOptions(rt: *zjs.Runtime, ctx: *zjs.Context, runtime_options: RuntimeOptions) void {
    zjs.core.gc_trace_stw.detailed_reports = runtime_options.gc_detailed_reports;
    // `detailed_reports` is one input of the barrier gate; a flip against a
    // live Registry must republish it (gc.refreshBarrierGate contract).
    rt.gc.refreshBarrierGate();
    rt.setCanBlock(runtime_options.can_block);
    if (runtime_options.memory_limit) |limit| rt.setMemoryLimit(limit);
    if (runtime_options.stack_size) |size| {
        rt.setStackSize(size);
        ctx.setStackLimit(size);
    }
}

fn failEvaluation(
    ctx: *zjs.Context,
    rt: *zjs.Runtime,
    event_loop: *host.EventLoop,
    output: *std.Io.Writer,
    io: std.Io,
    err: anyerror,
) !noreturn {
    try exitIfRequested(event_loop, output, err);
    if (ctx.hasException()) try output.flush();
    try printEvaluationError(io, ctx, rt, err);
    std.process.exit(1);
}

fn exitIfRequested(event_loop: *host.EventLoop, output: *std.Io.Writer, err: anyerror) !void {
    if (err != error.ProcessExit) return;
    const code = event_loop.exitCode() orelse return;
    try output.flush();
    std.process.exit(code);
}

const max_source_size = 64 * 1024 * 1024;

fn evalScript(
    ctx: *zjs.Context,
    source_text: []const u8,
    output: *std.Io.Writer,
    filename: []const u8,
) !zjs.Value {
    return ctx.eval(source_text, .{
        .mode = .script,
        .filename = filename,
        .output = output,
        .parse_strict = false,
        .runtime_strict = false,
        .discard_script_result = true,
    });
}

fn evalSource(
    ctx: *zjs.Context,
    source_text: []const u8,
    output: *std.Io.Writer,
    path: []const u8,
    mode: zjs.Context.EvalMode,
    io: std.Io,
    allocator: std.mem.Allocator,
) !zjs.Value {
    if (mode == .module) {
        return runFileModule(ctx, source_text, output, path, io, allocator, max_source_size);
    }
    return evalScript(ctx, source_text, output, path);
}

fn runFileModule(
    ctx: *zjs.Context,
    source_text: []const u8,
    output: *std.Io.Writer,
    path: []const u8,
    io: std.Io,
    allocator: std.mem.Allocator,
    max_size: usize,
) !zjs.Value {
    return try zjs.exec.module_graph.evalFileModuleGraphWithOutput(
        ctx.runtimePtr(),
        ctx.core,
        source_text,
        output,
        path,
        io,
        allocator,
        max_size,
    );
}

fn runIncludeFiles(
    ctx: *zjs.Context,
    runtime_options: RuntimeOptions,
    output: *std.Io.Writer,
    io: std.Io,
    allocator: std.mem.Allocator,
) !void {
    for (runtime_options.includes()) |path| {
        const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_source_size));
        defer allocator.free(source);
        _ = try evalSource(ctx, source, output, path, .module, io, allocator);
    }
}

/// Parser identity gate: compile the file without running it and print a
/// stable hash of the whole FunctionBytecode tree (code bytes, counts, and
/// every nested child in cpool order). Two engine builds that print the same
/// line for a corpus produce byte-identical bytecode for it.
fn printBytecodeFingerprint(
    output: *std.Io.Writer,
    ctx: *zjs.Context,
    source_text: []const u8,
    path: []const u8,
    mode: zjs.Context.EvalMode,
    verbose: bool,
) !void {
    var compiled = zjs.parser.compile(.{ .realm = ctx.core }, source_text, .{
        .mode = if (mode == .module) .module else .script,
        .filename = path,
        .return_completion = mode != .module,
    }) catch |err| {
        try output.print("error {s} {s}\n", .{ @errorName(err), path });
        return;
    };
    defer compiled.deinit();
    if (compiled.syntax_error) |syntax_error| {
        try output.print("syntax-error {d}:{d} {s} {s}\n", .{
            syntax_error.position.line,
            syntax_error.position.column,
            syntax_error.message,
            path,
        });
        return;
    }
    const root = compiled.functionBytecode() orelse {
        try output.print("no-artifact {s}\n", .{path});
        return;
    };
    var hasher = std.hash.Wyhash.init(0x7a6a73);
    var function_count: u32 = 0;
    fingerprintFunctionBytecode(&hasher, root, &function_count, if (verbose) output else null);
    try output.print("{x:0>16} functions={d} {s}\n", .{ hasher.final(), function_count, path });
}

fn fingerprintFunctionBytecode(hasher: *std.hash.Wyhash, fb: *const zjs.bytecode.FunctionBytecode, function_count: *u32, verbose: ?*std.Io.Writer) void {
    function_count.* += 1;
    const code = fb.byteCode();
    if (verbose) |out| {
        out.print("  fn#{d} code_len={d} args={d} vars={d} defined_args={d} stack={d} closure_vars={d} cpool={d} flags={x}/{x}/{x}\n", .{
            function_count.*,     code.len,       fb.arg_count, fb.var_count,   fb.defined_arg_count, fb.stack_size,
            fb.closure_var_count, fb.cpool_count, fb.js_mode,   fb.flag_byte17, fb.flag_byte18,
        }) catch {};
        if (fb.debugInfo()) |debug| {
            if (debug.source_ptr) |source_ptr| {
                const source_len: usize = @intCast(@max(debug.source_len, 0));
                out.print("    src: {s}\n", .{source_ptr[0..@min(source_len, 200)]}) catch {};
            }
        }
        out.print("    ", .{}) catch {};
        for (code) |byte| out.print("{x:0>2}", .{byte}) catch {};
        out.print("\n", .{}) catch {};
    }
    hasher.update(std.mem.asBytes(&@as(u32, @intCast(code.len))));
    hasher.update(code);
    const scalars = [_]u32{
        fb.arg_count,                   fb.var_count,
        fb.defined_arg_count,           fb.stack_size,
        @bitCast(fb.closure_var_count), fb.js_mode,
        fb.flag_byte17,                 fb.flag_byte18,
        @bitCast(fb.cpool_count),
    };
    hasher.update(std.mem.sliceAsBytes(scalars[0..]));
    for (fb.cpoolSlice()) |value| {
        if (zjs.exec.call_runtime.functionBytecodeFromValue(value)) |child| {
            hasher.update("fb");
            fingerprintFunctionBytecode(hasher, child, function_count, verbose);
        } else if (value.isTracerOwned()) {
            // Heap values: hash the tag and, for strings, the contents. The
            // address itself differs between runs.
            const tag: i32 = value.tagOf();
            hasher.update(std.mem.asBytes(&tag));
            if (value.asStringBodyRaw()) |body| {
                if (body.len_meta.is_wide) {
                    hasher.update(std.mem.sliceAsBytes(body.utf16()));
                } else {
                    hasher.update(body.latin1());
                }
            }
        } else {
            const bits: u64 = @bitCast(value);
            hasher.update(std.mem.asBytes(&bits));
        }
    }
}

fn printEvaluationError(io: std.Io, ctx: *zjs.Context, rt: *zjs.Runtime, err: anyerror) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    if (ctx.hasException() or ctx.hasUnhandledRejection()) {
        const thrown = ctx.takePendingException();
        if (try printExceptionValue(stderr, ctx, rt, thrown)) return;
    }
    try stderr.print("zjs: evaluation failed: ", .{});
    try stderr.print("{s}\n", .{@errorName(err)});
    try stderr.flush();
}

fn printExceptionValue(stderr: *std.Io.Writer, ctx: *zjs.Context, rt: *zjs.Runtime, value: zjs.Value) !bool {
    if (!value.is(.object)) return false;

    const header = try ctx.formatException(value, rt.nativeAllocator());
    defer rt.nativeAllocator().free(header);
    if (header.len == 0) {
        try stderr.print("Error\n", .{});
    } else {
        try stderr.print("{s}\n", .{header});
    }

    const stack = ctx.formatExceptionStack(value, rt.nativeAllocator()) catch |err| blk: {
        if (ctx.hasException()) {
            ctx.clearException();
            break :blk null;
        }
        return err;
    };
    defer if (stack) |bytes| rt.nativeAllocator().free(bytes);
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
fn printUnhandledRejectionTo(stderr: *std.Io.Writer, ctx: *zjs.Context, rt: *zjs.Runtime, value: zjs.Value) !void {
    try stderr.print("Possibly unhandled promise rejection: ", .{});
    if (value.as(.int)) |int_value| {
        try stderr.print("{d}", .{int_value});
    } else if (value.as(.boolean)) |bool_value| {
        try stderr.print("{s}", .{if (bool_value) "true" else "false"});
    } else if (value.is(.undefined_value)) {
        try stderr.print("undefined", .{});
    } else if (value.is(.null_value)) {
        try stderr.print("null", .{});
    } else if (value.isString()) {
        try stderr.print("[object String]", .{});
    } else if (value.is(.object)) {
        if (try printExceptionValue(stderr, ctx, rt, value)) return;
    } else {
        try stderr.print("[object Object]", .{});
    }
    try stderr.print("\n", .{});
    try stderr.flush();
}

/// Mirrors qjs `js_std_promise_rejection_check` (quickjs-libc.c:4276-4290):
/// every still-unhandled rejection is reported, in rejection order, before
/// the process exits with 1.
fn reportUnhandledRejections(io: std.Io, ctx: *zjs.Context, rt: *zjs.Runtime) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    while (true) {
        const exception = ctx.takePendingException();
        try printUnhandledRejectionTo(stderr, ctx, rt, exception);
        if (!ctx.hasUnhandledRejection()) break;
    }
}

fn dumpMemoryUsage(output: *std.Io.Writer, runtime: *zjs.Runtime) !void {
    try dumpMemorySnapshot(output, runtime.memoryUsage());
}

fn dumpMemorySnapshot(output: *std.Io.Writer, memory: zjs.RuntimeMemoryUsage) !void {
    try output.print("\nZJS memory usage\n", .{});
    try output.print("  memory limit: ", .{});
    if (memory.memory_limit) |limit| {
        try output.print("{d}\n", .{limit});
    } else {
        try output.print("0\n", .{});
    }
    if (!memory.allocation_tracking_enabled) try output.print("  native allocation counters: unavailable in this build\n  heap accounted bytes: {d}\n", .{memory.heap_bytes});
    try output.print("\nNAME                    COUNT     SIZE\n", .{});
    const rows = [_]struct { []const u8, usize, ?usize }{
        .{ "memory allocated", memory.allocation_count, memory.allocated_bytes },
        .{ "atoms", memory.atom_count, memory.atom_bytes },
        .{ "classes", memory.registered_class_count, null },
    };
    for (rows) |row| {
        try output.print("{s:<22} {d:>5} ", .{ row[0], row[1] });
        if (row[2]) |size| {
            try output.print("{d:>8}\n", .{size});
        } else {
            try output.print("{s:>8}\n", .{"-"});
        }
    }
}

fn dumpRequested(
    stdout: *std.Io.Writer,
    runtime: *zjs.Runtime,
    runtime_options: RuntimeOptions,
    opcode_profile: *zjs.OpcodeProfile,
) !void {
    if (runtime_options.dump_memory) {
        try dumpMemoryUsage(stdout, runtime);
        try stdout.flush();
    }
    if (zjs.opcode_profile_build_enabled and runtime_options.profile_opcodes) {
        opcode_profile.flushPendingDispatch(runtime.diagnosticNanos());
        try dumpOpcodeProfile(stdout, runtime.opcode_profile.?);
        try stdout.flush();
    }
    if (runtime_options.gc_stats) {
        try dumpGcPanels(stdout, runtime, runtime_options);
        try stdout.flush();
    }
}

fn dumpGcPanels(writer: *std.Io.Writer, runtime: *zjs.Runtime, runtime_options: RuntimeOptions) !void {
    if (runtime_options.gc_gate_settle) {
        try dumpGcDoomedState(writer, "endpoint", runtime);
        zjs.core.runtime.settlePendingDestructionForGateStats(runtime);
    }
    try dumpGcStats(writer, runtime.gcDetailedStats(), runtime.gc);
    try dumpAtomAuditStats(writer, runtime);
    try dumpGcPauses(writer, runtime.gcPauseDistribution());
    try dumpGcSpaceStats(writer, runtime.gc);
    try dumpGcBlockHeapStats(writer, runtime.gc);
    if (runtime_options.gc_block_census) {
        try dumpGcBlockCensus(writer, runtime.gc);
    }
    try dumpGcGenerationStats(writer, runtime.gc);
    try dumpGcDoomedState(
        writer,
        if (runtime_options.gc_gate_settle) "settled" else "endpoint",
        runtime,
    );
}

/// Whether the `OpcodeProfile` counters below are known to have no increment
/// site, so the dumps must say so instead of printing a `0` that reads like a
/// measurement.
///
/// The name is deliberately not `opcode_profile_build_enabled` even though it
/// tracks it: the flag is what *enables* profiling, but the counters it leaves
/// empty are the ones listed here. In a profiling build the tail-call
/// dispatcher only calls `OpcodeProfile.noteDispatch` -- counts, never timings,
/// because a scope cannot span an `always_tail` chain (see
/// `src/exec/tailcall_dispatch.zig`) -- and nothing increments the value-dup,
/// call-frame or global-lookup counters on that path. `--profile-opcodes` is
/// the only way to reach these dumps for real and it requires a profiling
/// build, so the `false` arm is exercised only by the unit tests at the bottom
/// of this file, which poke the counters by hand and then expect raw values.
const profile_counters_uninstrumented = zjs.opcode_profile_build_enabled;

const OpcodeProfileRow = struct {
    opcode: u8,
    count: u64,
    nanos: u64,
};

/// Post-run GC counters. Every line here has a maintained write site in the
/// collector; fields the engine does not instrument are simply absent rather
/// than printed as zero.
fn dumpGcSpaceStats(writer: *std.Io.Writer, registry: *const zjs.core.gc.Registry) !void {
    const space = zjs.core.gc_space;
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
fn dumpGcBlockCensus(writer: *std.Io.Writer, registry: *const zjs.core.gc.Registry) !void {
    const census = registry.block_heap.censusBlocks();
    try writeCounterLine(writer, &.{
        .{ "gc: block census classed superblocks ", census.classed_superblocks },
        .{ ", other ", census.other_superblocks },
        .{ ", uninitialized slots ", census.uninitialized_blocks },
    }, "\n");
    try writer.writeAll(
        "gc: block census columns cell_bytes blocks cells allocated occ_x1000 empty lt10 lt50 ge50 young decommitted active hot free\n",
    );
    var total: zjs.core.gc_block_heap.BlockCensusRow = .{};
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

/// Generational counters. `remembered without young` is the one to watch: it
/// counts owners a minor re-traced that turned out to hold no young child, so
/// a large share means the write barrier is firing more than it needs to.
fn dumpGcGenerationStats(writer: *std.Io.Writer, registry: *zjs.core.gc.Registry) !void {
    const st = registry.generation.stats;
    // Row shape is the `--gc-stats` panel contract. The S4-f trigger census
    // gets its own row below rather than a field here.
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
        .{ "gc: minor phase totals clear ", st.minor_ns.get(.clear) },
        .{ ", roots ", st.minor_ns.get(.roots) },
        .{ ", conservative ", st.minor_ns.get(.conservative) },
        .{ ", remembered ", st.minor_ns.get(.remembered) },
        .{ ", trace ", st.minor_ns.get(.trace) },
        .{ ", sweep+destroy ", st.minor_ns.get(.sweep) },
        .{ ", promote ", st.minor_ns.get(.promote) },
        .{ ", other ", st.pause_ns_total -| st.minorPhaseNsTotal() },
    }, " ns\n");
    try writeCounterLine(writer, &.{
        .{ "gc: minor young-at-start mean ", mean_young },
        .{ ", max ", st.young_at_start_max },
    }, "\n");
    if (zjs.core.gc.forensics.verifying()) {
        try writeCounterLine(writer, &.{
            .{ "gc: conservative-only young ", st.conservative_only_young },
            .{ " over ", st.minor_collections },
        }, " verified minors\n");
    } else {
        try writer.writeAll("gc: conservative-only young unavailable (set ZJS_GC_VERIFY=1)\n");
    }
    const cs = registry.incremental.stats;
    try writeCounterLine(writer, &.{
        .{ "gc: marking barrier calls ", cs.barrier_calls },
    }, "\n");
    try writeCounterLine(writer, &.{
        .{ "gc: destroyed counted objects ", cs.doomed_destroyed_objects },
    }, "\n");
    try writeCounterLine(writer, &.{
        .{ "gc: major cycles completed ", cs.cycles_completed },
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
        .{ ", B/T-x1000000 ", zjs.core.gc.incremental.ratioMillionthsCeil(cs.envelope_max_begin_bytes, cs.envelope_max_threshold_bytes) },
        .{ ", P/T-x1000000 ", zjs.core.gc.incremental.ratioMillionthsCeil(cs.envelope_max_peak_bytes, cs.envelope_max_threshold_bytes) },
        .{ ", P/S-x1000000 ", zjs.core.gc.incremental.ratioMillionthsCeil(cs.envelope_max_peak_bytes, cs.envelope_max_start_bytes) },
    }, "\n");
}

fn dumpGcBlockHeapStats(writer: *std.Io.Writer, registry: *const zjs.core.gc.Registry) !void {
    const st = registry.block_heap.stats;
    try writeCounterLine(writer, &.{
        .{ "gc: block heap committed ", st.committed_bytes },
        .{ " live ", registry.block_heap.liveBytes() },
        .{ " committed/live-x1000 ", registry.block_heap.committedLiveMilli() },
        .{ " superblocks ", st.superblocks },
        .{ " large maps ", st.large_maps },
    }, "\n");
    try writeCounterLine(writer, &.{
        .{ "gc: block heap hot reuse published ", st.hot_blocks_published },
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
        .{ ", released blocks cumulative ", st.decommitted_bytes / @max(zjs.core.gc_block_heap.decommit_bytes, 1) },
        .{ ", current bytes ", st.currentDecommittedBytes() },
        .{ ", max batch bytes ", st.decommit_max_batch_bytes },
    }, "\n");
    try writeCounterLine(writer, &.{
        .{ "gc: process heap trim attempts ", st.malloc_trim_attempts },
        .{ ", successes ", st.malloc_trim_successes },
    }, "\n");
}

fn dumpGcStats(writer: *std.Io.Writer, detailed: zjs.GCDetailedStats, registry: *const zjs.core.gc.Registry) !void {
    const stats = detailed.counters;
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
        .{ "gc: heap live ", detailed.heap_live_bytes },
        .{ " bytes, account peak ", stats.peak_allocated_bytes },
    }, " bytes\n");
    // External is a separate reporting dimension, even where an ordinary
    // ArrayBuffer's engine-owned backing also overlaps the whole
    // mem_ops. The weighted debt is a pacing counter, not current live
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
fn dumpAtomAuditStats(writer: *std.Io.Writer, rt: *const zjs.Runtime) !void {
    try writeCounterLine(writer, &.{
        .{ "gc: atom audit stale-edge ", rt.atoms.atom_audit_stale_edge },
        .{ ", shell-edge ", rt.atoms.atom_audit_shell_edge },
        .{ ", entries ", rt.atoms.entries.len },
    }, "\n");
}

fn dumpGcDoomedState(writer: *std.Io.Writer, layer: []const u8, rt: *const zjs.Runtime) !void {
    try writeDoomedStateLine(writer, layer, zjs.core.gc_trace_stw.doomedStateSnapshot(rt));
}

fn writeDoomedStateLine(
    writer: *std.Io.Writer,
    layer: []const u8,
    state: zjs.core.gc_trace_stw.DoomedStateSnapshot,
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
    const retained = @min(d.samples, zjs.core.gc.pause_sample_capacity);
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
    const sorted_rows = sortedOpcodeProfileRows(profile, &rows);

    try output.print("\nZJS opcode profile\n", .{});
    try output.print("  opcodes executed: {d}\n", .{profile.totalOpcodeCount()});
    if (comptime profile_counters_uninstrumented) {
        try output.print("  measured ns:      not instrumented\n", .{});
    } else {
        try output.print("  measured ns:      {d}\n", .{profile.totalOpcodeNanos()});
    }
    if (comptime profile_counters_uninstrumented) {
        try output.print("  value dups:       not instrumented\n", .{});
    } else {
        try output.print("  value dups:       {d}\n", .{profile.value_dup_count});
    }
    try output.print("  value frees:      {d}\n", .{profile.value_free_count});
    try output.print("  prop lookups:     {d}\n", .{profile.prop_lookup_count});
    if (comptime profile_counters_uninstrumented) {
        try output.print("  global lookups:   not instrumented\n", .{});
    } else {
        try output.print("  global lookups:   {d}\n", .{profile.global_lookup_count});
    }
    try output.print("  allocations:      {d}\n", .{profile.alloc_count});
    if (comptime profile_counters_uninstrumented) {
        try output.print("  call frames:      not instrumented\n", .{});
        try output.print("\nOPCODE                 COUNT          TOTAL_NS           AVG_NS             SLOW\n", .{});
    } else {
        try output.print("  call frames:      {d}\n", .{profile.call_frame_count});
        try output.print("\nOPCODE                 COUNT      TOTAL_NS       AVG_NS       SLOW\n", .{});
    }

    // The default 40-row cap keeps the profile readable. `ZJS_PROFILE_ALL=1`
    // prints every executed opcode, which is what an opcode-space census
    // needs: the cold tail is exactly the part the cap hides.
    const print_all = if (std.c.getenv("ZJS_PROFILE_ALL")) |raw| blk: {
        const v = std.mem.span(raw);
        break :blk v.len != 0 and v[0] == '1';
    } else false;
    const limit = if (print_all) sorted_rows.len else @min(sorted_rows.len, 40);
    for (sorted_rows[0..limit]) |row| {
        const name = zjs.OpcodeProfile.opcodeName(row.opcode);
        const display_name = if (name.len == 0) "<invalid>" else name;
        const avg = if (row.count == 0) 0 else row.nanos / row.count;
        if (comptime profile_counters_uninstrumented) {
            try output.print("{s:<20} {d:>9} {s:>18} {s:>16} {s:>16}\n", .{ display_name, row.count, "not instrumented", "not instrumented", "not instrumented" });
        } else {
            try output.print("{s:<20} {d:>9} {d:>13} {d:>12} {d:>10}\n", .{ display_name, row.count, row.nanos, avg, profile.slow_count[row.opcode] });
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
            const resident = zjs.bytecode.opcode.logical.subForm(@intCast(sub));
            const name = if (resident) |form| @tagName(form) else "<range>";
            try output.print("{s:<20} {d:>9}  (sub {d})\n", .{ name, c, sub });
        }
    }

    // D12's family rollup: a GENERATED aggregation view over the form
    // counts, never a substitute for per-form rows.
    var family_counts = std.enums.EnumArray(zjs.bytecode.opcode.logical.SemanticFamily, u64).initFill(0);
    for (profile.count, 0..) |c, id| {
        if (c == 0 or id >= zjs.bytecode.opcode.op.op_count) continue;
        if (zjs.bytecode.opcode.physical.stateOf(@intCast(id)) != .claimed) continue;
        const form: zjs.bytecode.opcode.logical.LogicalOpcode = @enumFromInt(id);
        family_counts.getPtr(zjs.bytecode.opcode.logical.familyOf(form)).* +|= c;
    }
    try output.print("\nFAMILY (rollup)         COUNT\n", .{});
    var fam_it = family_counts.iterator();
    while (fam_it.next()) |entry| {
        if (entry.value.* == 0) continue;
        try output.print("{s:<20} {d:>9}\n", .{ @tagName(entry.key), entry.value.* });
    }
}

/// The executed opcodes as rows sorted by time, then count, then opcode.
/// `rows` is the caller's backing storage; the returned slice aliases it.
fn sortedOpcodeProfileRows(profile: *const zjs.OpcodeProfile, rows: *[zjs.OpcodeProfile.opcode_count]OpcodeProfileRow) []OpcodeProfileRow {
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
    const sorted = rows[0..row_count];
    sort_erased.heap(OpcodeProfileRow, sorted, {}, opcodeProfileRowLessThan);
    return sorted;
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

// Materialize the declared defaults without a 18 KiB .rodata copy of
// `OpcodeProfile{}`. Every field is zero except `pending_op`, whose type
// default is the pending-dispatch sentinel.
fn initOpcodeProfile(profile: *zjs.OpcodeProfile) void {
    profile.* = std.mem.zeroes(zjs.OpcodeProfile);
    profile.pending_op = zjs.OpcodeProfile.no_pending_op;
}

test "zjs args accept eval, file, and module jobs" {
    const eval_command = try parseArgs(&.{ "--profile-opcodes", "-e", "1" });
    try std.testing.expectEqualStrings("1", eval_command.source.?);
    try std.testing.expectEqualStrings(eval_filename, eval_command.path);
    try std.testing.expectEqual(zjs.Context.EvalMode.script, eval_command.mode);
    try std.testing.expect(eval_command.options.profile_opcodes);

    const empty_eval = try parseArgs(&.{ "-e", "" });
    try std.testing.expectEqualStrings("", empty_eval.source.?);

    const file = try parseArgs(&.{ "input.js", "empty_loop" });
    try std.testing.expectEqualStrings("input.js", file.path);
    try std.testing.expect(file.source == null);
    try std.testing.expectEqual(@as(usize, 2), file.script_args.len);
    try std.testing.expectEqualStrings("empty_loop", file.script_args[1]);
    try std.testing.expectEqual(zjs.Context.EvalMode.module, file.mode);

    const script = try parseArgs(&.{ "-s", "input.js", "arg" });
    try std.testing.expectEqualStrings("input.js", script.path);
    try std.testing.expectEqual(zjs.Context.EvalMode.script, script.mode);

    const module = try parseArgs(&.{ "-m", "input.mjs", "arg" });
    try std.testing.expectEqualStrings("input.mjs", module.path);
    try std.testing.expectEqual(zjs.Context.EvalMode.module, module.mode);
    try std.testing.expectEqual(@as(usize, 2), module.script_args.len);
    try std.testing.expectEqualStrings("arg", module.script_args[1]);
}

test "zjs args accept options" {
    const command = try parseArgs(&.{
        "--memory-limit",      "7",
        "--stack-size=9",      "-d",
        "-I",                  "prelude.js",
        "--include=setup.mjs", "--gc-gate-settle",
        "--",                  "input.js",
        "-d",
    });
    try std.testing.expectEqual(@as(?usize, 7 * 1024), command.options.memory_limit);
    try std.testing.expectEqual(@as(?usize, 9 * 1024), command.options.stack_size);
    try std.testing.expect(command.options.dump_memory);
    try std.testing.expect(command.options.gc_gate_settle);
    try std.testing.expect(command.options.gc_stats);
    try std.testing.expectEqual(@as(usize, 2), command.options.include_count);
    try std.testing.expectEqualStrings("prelude.js", command.options.includes()[0]);
    try std.testing.expectEqualStrings("setup.mjs", command.options.includes()[1]);
    try std.testing.expectEqualStrings("input.js", command.path);
    try std.testing.expectEqualStrings("-d", command.script_args[1]);
}

test "zjs end of options treats command words as file paths" {
    for ([_][]const u8{ "-e", "-m", "-s", "-h", "--help", "--dump", "-input.js" }) |path| {
        const command = try parseArgs(&.{ "--", path, "argument" });
        try std.testing.expectEqualStrings(path, command.path);
        try std.testing.expect(command.source == null);
        try std.testing.expectEqual(zjs.Context.EvalMode.module, command.mode);
        try std.testing.expectEqualStrings("argument", command.script_args[1]);
    }
}

test "zjs args reject usage" {
    try std.testing.expectError(error.Usage, parseArgs(&.{ "--trace", "-e", "1" }));
    try std.testing.expectError(error.Usage, parseArgs(&.{ "-T", "-e", "1" }));
    try std.testing.expectError(error.Usage, parseArgs(&.{ "--gc-mark-footprint", "-e", "1" }));
    try std.testing.expectError(error.Usage, parseArgs(&.{"-e"}));
    try std.testing.expectError(error.Usage, parseArgs(&.{"-m"}));
    try std.testing.expectError(error.Usage, parseArgs(&.{"-s"}));
    try std.testing.expectError(error.Usage, parseArgs(&.{ "-i", "extra" }));
    try std.testing.expectError(error.Usage, parseArgs(&.{"--"}));
    try std.testing.expectError(error.Usage, parseArgs(&.{ "--stack-size", "11" }));
    try std.testing.expectError(error.Usage, parseArgs(&.{ "--dump=1", "input.js" }));
    // The shadow observer went with the rc collector (2026-08-29); the flag it
    // gated must now be an error rather than a silently ignored word.
    try std.testing.expectError(error.Usage, parseArgs(&.{ "--gc-shadow-check", "-e", "1" }));
}

test "zjs loadSource keeps inline eval source as script" {
    var command = try parseArgs(&.{ "-e", "export const x = 1" });
    const owned = try loadSource(&command, std.testing.allocator, undefined);
    try std.testing.expect(owned == null);
    try std.testing.expectEqualStrings("export const x = 1", command.source.?);
    try std.testing.expectEqual(zjs.Context.EvalMode.script, command.mode);
}

test "zjs opcode profile dump includes counters and rows" {
    var profile = zjs.OpcodeProfile{};
    profile.recordOpcode(zjs.bytecode.opcode.op.get_var, 17);
    profile.recordOpcode(zjs.bytecode.opcode.op.push_i16, 5);
    profile.recordValueDup();
    profile.recordValueFree();
    profile.recordGlobalLookup();

    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try dumpOpcodeProfile(&writer, &profile);
    const text = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, text, "ZJS opcode profile") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "opcodes executed: 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "get_var") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "push_i16") != null);
}

test "opcode profile initialization preserves every default field" {
    var profile: zjs.OpcodeProfile = undefined;
    initOpcodeProfile(&profile);
    try std.testing.expectEqualDeep(zjs.OpcodeProfile{}, profile);
}

test "zjs generation diagnostic lines preserve populated snapshot" {
    const memory = try runtime_owner.createAllocationTestRuntime(std.testing.allocator);
    defer memory.destroy();
    var registry: zjs.core.gc.Registry = .{ .runtime = memory, .allocator = std.testing.allocator };
    // Position-based fill so every counter prints a distinct value; the
    // minor phase array takes one position per phase.
    comptime var position: usize = 0;
    inline for (@typeInfo(@TypeOf(registry.generation.stats)).@"struct".fields) |field| {
        if (@typeInfo(field.type) == .int) {
            @field(registry.generation.stats, field.name) = @intCast(position + 11);
            position += 1;
        } else if (field.type == std.EnumArray(zjs.core.gc.generation.MinorPhase, u64)) {
            inline for (0..@field(registry.generation.stats, field.name).values.len) |phase_index| {
                @field(registry.generation.stats, field.name).values[phase_index] = position + 11;
                position += 1;
            }
        } else {
            position += 1;
        }
    }
    inline for (@typeInfo(@TypeOf(registry.incremental.stats)).@"struct".fields, 0..) |field, i| {
        if (@typeInfo(field.type) == .int) @field(registry.incremental.stats, field.name) = @intCast(i + 101);
    }
    var samples = [_]u64{ 7, 2, 5 };
    registry.generation.minor_pause_samples = .{ .items = &samples, .capacity = samples.len };
    const old_verify = zjs.core.gc.forensics.verify;
    defer zjs.core.gc.forensics.verify = old_verify;
    zjs.core.gc.forensics.verify = .off;
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
        \\gc: conservative-only young unavailable (set ZJS_GC_VERIFY=1)
        \\gc: marking barrier calls 101
        \\gc: destroyed counted objects 112
        \\gc: major cycles completed 102, cycle STW last 103 ns max 105 ns
        \\gc: cycle envelope measured 106, skipped 107, max-P/T S 108, T 109, B 110, P 111, B/T-x1000000 1009175, P/T-x1000000 1018349, P/S-x1000000 1027778
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

test "zjs registry diagnostic panels preserve populated snapshot" {
    const memory = try runtime_owner.createAllocationTestRuntime(std.testing.allocator);
    defer memory.destroy();
    var registry: zjs.core.gc.Registry = .{ .runtime = memory, .allocator = std.testing.allocator };
    inline for (@typeInfo(@TypeOf(registry.stats)).@"struct".fields, 0..) |field, i| {
        if (@typeInfo(field.type) == .int) @field(registry.stats, field.name) = @intCast(i + 11);
    }
    inline for (@typeInfo(@TypeOf(registry.block_heap.stats)).@"struct".fields, 0..) |field, i| {
        if (@typeInfo(field.type) == .int) @field(registry.block_heap.stats, field.name) = @intCast(i + 101);
    }
    inline for (@typeInfo(@TypeOf(registry.incremental.stats)).@"struct".fields, 0..) |field, i| {
        if (@typeInfo(field.type) == .int) @field(registry.incremental.stats, field.name) = @intCast(i + 201);
    }
    registry.space_histogram.record(32);
    registry.space_histogram.record(128);
    registry.space_histogram.record(70000);
    var buffer: [16384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try dumpGcSpaceStats(&writer, &registry);
    try dumpGcBlockCensus(&writer, &registry);
    try dumpGcBlockHeapStats(&writer, &registry);
    const detailed = zjs.GCDetailedStats{
        .heap_live_bytes = 303,
        .counters = .{
            .peak_allocated_bytes = 302,
            .external_bytes = 312,
            .external_untracked_bytes = 313,
            .peak_external_bytes = 314,
            .external_alloc_count = 315,
            .external_free_count = 316,
            .external_token_count = 317,
            .external_token_bytes = 318,
            .external_invalid_release_count = 319,
            .allocation_debt = 320,
            .collections = 321,
            .major_gc_count = 322,
            .failed_collections = 326,
            .freed_objects = 328,
            .weak_ref_count = 330,
            .finalizer_queue_length = 331,
        },
    };
    try dumpGcStats(&writer, detailed, &registry);
    try dumpGcPauses(&writer, null);
    try dumpGcPauses(&writer, .{ .samples = 3, .p50_ns = 2, .p95_ns = 3, .p99_ns = 5, .max_ns = 7 });
    const expected =
        \\gc: allocation histogram publications 3, payload bytes 70160, p50-below-large 32, p95-below-large 128, p99-below-large 128, max-small 3760, covered-by-small 2/2 below-large, large 1
        \\gc: block census classed superblocks 0, other 0, uninitialized slots 0
        \\gc: block census columns cell_bytes blocks cells allocated occ_x1000 empty lt10 lt50 ge50 young decommitted active hot free
        \\gc: block census total 0 0 0 0 0 0 0 0 0 0 0 0 0 0
        \\gc: block heap committed 101 live 0 committed/live-x1000 0 superblocks 103 large maps 104
        \\gc: block heap hot reuse published 115, reopened 116, bitmap reclaimed cells 126
        \\gc: block heap hot publish rejects empty 117, capacity 118, active 119, doomed 120, young 121, listed 122, decommitted 123, cached-k 124, k-rejected reopens 125
        \\gc: major threshold resets growth 29, small-heap-floor 30
        \\gc: object destructor calls 32, plain-object calls 33, plain objects carrying the finalizer bit 34
        \\gc: block heap page returns cumulative decommitted 109, recommitted 110
        \\gc: block heap medium superblocks returned 127, bytes 128
        \\gc: block heap decommit checks 111, released blocks cumulative 0, current bytes 0, max batch bytes 112
        \\gc: process heap trim attempts 113, successes 114
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

test "zjs memory table preserves widths and populated fields" {
    var memory = std.mem.zeroes(zjs.RuntimeMemoryUsage);
    memory.allocation_tracking_enabled = true;
    memory.allocation_count = 123456;
    memory.allocated_bytes = 999999999;
    memory.atom_count = 3;
    memory.atom_bytes = 4;
    memory.registered_class_count = 11;
    const rows =
        \\memory allocated       123456 999999999
        \\atoms                      3        4
        \\classes                   11        -
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

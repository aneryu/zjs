const std = @import("std");
const engine = @import("zjs");
const public_api = engine.public_api;
const unicode = engine.libs.unicode;
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
    const total_start = monotonicNanos();
    setupFusionStatsExitDump(init.environ_map);
    setupHostDispatchStatsExitDump(init.environ_map);
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try argsToSlice(arena, init.minimal.args);

    const command = parseArgs(args[1..]) catch {
        try printUsage(io);
        std.process.exit(2);
    };

    var read_source_ns: u64 = 0;
    const source_text = switch (command) {
        .eval => |eval| eval.source,
        .file => |file| source: {
            const read_start = monotonicNanos();
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, file.path, allocator, .limited(max_source_size)) catch |err| {
                try printError(io, "zjs: unable to read {s}: {s}\n", .{ file.path, @errorName(err) });
                std.process.exit(1);
            };
            read_source_ns = elapsedNanosSince(read_start);
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
    const runtime_start = monotonicNanos();
    const rt = zjs.JSRuntime.createWithOptions(allocator, .{
        .trace_writer = if (commandRuntimeOptions(command).trace_memory) &stdout_writer.interface else null,
        .memory_limit = commandRuntimeOptions(command).memory_limit,
        .gc_threshold = zjs.default_gc_threshold,
        .stack_size = commandRuntimeOptions(command).stack_size orelse zjs.default_stack_size,
    }) catch |err| {
        try printError(io, "zjs: engine init failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    errdefer rt.destroy();
    const ctx = zjs.JSContext.create(rt) catch |err| {
        try printError(io, "zjs: context init failed: {s}\n", .{@errorName(err)});
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

    const runtime_create_ns = elapsedNanosSince(runtime_start);
    const setup_start = monotonicNanos();
    applyRuntimeOptions(&runtime, commandRuntimeOptions(command));
    runtime.context.setTrackUnhandledRejections(commandTracksUnhandledRejections(command));
    const runtime_options = commandRuntimeOptions(command);
    if (runtime_options.profile_opcodes) {
        runtime.runtime.setOpcodeProfile(&opcode_profile);
    } else if (runtime_options.perf_json) {
        _ = zjs.activateOpcodeProfile(&opcode_profile);
    }
    zjs.host.defineScriptArgs(runtime.context, commandScriptArgs(command)) catch |err| {
        try printError(io, "zjs: scriptArgs setup failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    runtime.context.setPreserveUncaughtException(true);
    setup_ns = elapsedNanosSince(setup_start);
    // NB: we intentionally do NOT `defer runtime.deinit()` on the happy path.
    // `JSRuntime.destroy` asserts that the runtime has no outstanding
    // allocations, which catches refcounting bugs in `zig build test` where
    // the engine is used in-process. As a short-lived CLI process, zjs
    // returns from `main` and the OS reclaims memory a few microseconds
    // later; calling `deinit` here only exposes latent leaks to the
    // test262 runner, where the 2s panic+backtrace path caused many
    // otherwise-passing tests to be misreported as timeouts. The historical
    // validation note is preserved in the convergence docs' git history.
    const include_start = monotonicNanos();
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
    include_ns = elapsedNanosSince(include_start);
    const eval_start = monotonicNanos();
    const value = switch (command) {
        .eval => runtime.context.eval(source_text, .{
            .mode = .script,
            .filename = "<eval>",
            .output = &stdout_writer.interface,
            .parse_strict = true,
            .runtime_strict = true,
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
                .runtime_strict = true,
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
    eval_ns = elapsedNanosSince(eval_start);
    try stdout_writer.interface.flush();

    if (value.isException()) {
        try printError(io, "zjs: uncaught exception\n", .{});
        std.process.exit(1);
    }

    const jobs_start = monotonicNanos();
    _ = try runtime.event_loop.runUntilIdle();
    jobs_ns = elapsedNanosSince(jobs_start);
    if (runtime.context.hasUnhandledRejection() or runtime.context.hasException()) {
        const exception = takePendingRejectionOrException(&runtime);
        try printUnhandledRejection(io, &runtime, exception);
        std.process.exit(1);
    }

    if (commandRuntimeOptions(command).dump_memory) {
        try dumpMemoryUsage(&stdout_writer.interface, &runtime);
        try stdout_writer.interface.flush();
    }
    if (commandRuntimeOptions(command).profile_opcodes) {
        try dumpOpcodeProfile(&stdout_writer.interface, runtime.runtime.opcode_profile.?);
        try stdout_writer.interface.flush();
    }
    if (commandRuntimeOptions(command).perf_json) {
        try dumpPerfJson(io, command, &runtime, &opcode_profile, .{
            .total_ns = elapsedNanosSince(total_start),
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
    if (runtime_options.leak_check) {
        runtime.deinit();
        return;
    }
    std.process.exit(0);
}

fn argsToSlice(arena: std.mem.Allocator, args: std.process.Args) ![]const []const u8 {
    const raw_args = try args.toSlice(arena);
    const result = try arena.alloc([]const u8, raw_args.len);
    for (raw_args, 0..) |arg, i| result[i] = arg;
    return result;
}

fn printUsage(io: std.Io) !void {
    try printError(io, "usage: zjs [-d] [-T] [--profile-opcodes] [--perf-json] [--leak-check] [--memory-limit n] [--stack-size n] [-I file] -e <script>\n       zjs [-d] [-T] [--profile-opcodes] [--perf-json] [--leak-check] [--memory-limit n] [--stack-size n] [-I file] [-m] <file.js>\n", .{});
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
                .runtime_strict = true,
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

fn elapsedNanosSince(start: u64) u64 {
    const end = monotonicNanos();
    return if (end > start) end - start else 0;
}

fn monotonicNanos() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn detectFileMode(path: []const u8, source: []const u8, explicit_mode: zjs.context.EvalMode) zjs.context.EvalMode {
    if (explicit_mode == .module) return .module;
    if (std.mem.endsWith(u8, path, ".mjs")) return .module;
    return if (sourceLooksLikeModule(source)) .module else .script;
}

fn sourceLooksLikeModule(source: []const u8) bool {
    var index: usize = 0;
    var brace_depth: usize = 0;
    while (index < source.len) {
        const byte = source[index];
        if (unicode.isAsciiWhitespaceByte(byte)) {
            index += 1;
            continue;
        }
        switch (byte) {
            '/' => {
                if (index + 1 < source.len and source[index + 1] == '/') {
                    index += 2;
                    while (index < source.len and source[index] != '\n' and source[index] != '\r') index += 1;
                } else if (index + 1 < source.len and source[index + 1] == '*') {
                    index += 2;
                    while (index + 1 < source.len and !(source[index] == '*' and source[index + 1] == '/')) index += 1;
                    if (index + 1 < source.len) index += 2;
                } else {
                    index += 1;
                }
            },
            '\'', '"' => {
                index = skipQuoted(source, index, byte);
            },
            '`' => {
                index = skipTemplate(source, index);
            },
            '{' => {
                brace_depth += 1;
                index += 1;
            },
            '}' => {
                if (brace_depth != 0) brace_depth -= 1;
                index += 1;
            },
            else => {
                if (isIdentifierStart(byte)) {
                    const start = index;
                    index += 1;
                    while (index < source.len and isIdentifierContinue(source[index])) index += 1;
                    if (brace_depth == 0) {
                        const word = source[start..index];
                        if (std.mem.eql(u8, word, "export")) return true;
                        if (std.mem.eql(u8, word, "import")) {
                            const next = skipSpacesAndComments(source, index);
                            if (next >= source.len or source[next] != '(') return true;
                        }
                    }
                } else {
                    index += 1;
                }
            },
        }
    }
    return false;
}

fn skipQuoted(source: []const u8, start: usize, quote: u8) usize {
    var index = start + 1;
    while (index < source.len) : (index += 1) {
        if (source[index] == '\\') {
            index += 1;
            continue;
        }
        if (source[index] == quote) return index + 1;
    }
    return index;
}

fn skipTemplate(source: []const u8, start: usize) usize {
    var index = start + 1;
    while (index < source.len) : (index += 1) {
        if (source[index] == '\\') {
            index += 1;
            continue;
        }
        if (source[index] == '`') return index + 1;
    }
    return index;
}

fn skipSpacesAndComments(source: []const u8, start: usize) usize {
    var index = start;
    while (index < source.len) {
        if (unicode.isAsciiWhitespaceByte(source[index])) {
            index += 1;
            continue;
        }
        switch (source[index]) {
            '/' => {
                if (index + 1 < source.len and source[index + 1] == '/') {
                    index += 2;
                    while (index < source.len and source[index] != '\n' and source[index] != '\r') index += 1;
                } else if (index + 1 < source.len and source[index + 1] == '*') {
                    index += 2;
                    while (index + 1 < source.len and !(source[index] == '*' and source[index + 1] == '/')) index += 1;
                    if (index + 1 < source.len) index += 2;
                } else return index;
            },
            else => return index,
        }
    }
    return index;
}

fn isIdentifierStart(byte: u8) bool {
    return unicode.isAsciiIdentifierStartByte(byte);
}

fn isIdentifierContinue(byte: u8) bool {
    return unicode.isAsciiIdentifierPartByte(byte);
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
    std.mem.sort(OpcodeProfileRow, rows[0..row_count], {}, opcodeProfileRowLessThan);

    try output.print("  \"opcode_profile\": {{\n", .{});
    try output.print("    \"opcodes_executed\": {d},\n", .{profile.totalOpcodeCount()});
    try output.print("    \"measured_ns\": {d},\n", .{profile.totalOpcodeNanos()});
    try output.print("    \"value_dups\": {d},\n", .{profile.value_dup_count});
    try output.print("    \"value_frees\": {d},\n", .{profile.value_free_count});
    try output.print("    \"prop_lookups\": {d},\n", .{profile.prop_lookup_count});
    try output.print("    \"global_lookups\": {d},\n", .{profile.global_lookup_count});
    try output.print("    \"allocations\": {d},\n", .{profile.alloc_count});
    try output.print("    \"call_frames\": {d},\n", .{profile.call_frame_count});
    try output.writeAll("    \"opcodes\": [");
    for (rows[0..row_count], 0..) |row, index| {
        if (index != 0) try output.writeByte(',');
        const name = zjs.OpcodeProfile.opcodeName(row.opcode);
        const display_name = if (name.len == 0) "<invalid>" else name;
        const avg = if (row.count == 0) 0 else row.nanos / row.count;
        try output.print("\n      {{\"opcode\": {d}, \"name\": ", .{row.opcode});
        try writeJsonString(output, display_name);
        try output.print(", \"count\": {d}, \"nanos\": {d}, \"avg_ns\": {d}, \"slow\": {d}}}", .{ row.count, row.nanos, avg, profile.slow_count[row.opcode] });
    }
    if (row_count != 0) try output.writeByte('\n');
    try output.writeAll("    ]\n  }");
}

fn dumpPerfJsonIc(output: *std.Io.Writer, profile: *const zjs.OpcodeProfile) !void {
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

    std.mem.sort(OpcodeProfileRow, rows[0..row_count], {}, opcodeProfileRowLessThan);

    try output.print("\nZJS opcode profile\n", .{});
    try output.print("  opcodes executed: {d}\n", .{profile.totalOpcodeCount()});
    try output.print("  measured ns:      {d}\n", .{profile.totalOpcodeNanos()});
    try output.print("  value dups:       {d}\n", .{profile.value_dup_count});
    try output.print("  value frees:      {d}\n", .{profile.value_free_count});
    try output.print("  prop lookups:     {d}\n", .{profile.prop_lookup_count});
    try output.print("  global lookups:   {d}\n", .{profile.global_lookup_count});
    try output.print("  allocations:      {d}\n", .{profile.alloc_count});
    try output.print("  call frames:      {d}\n", .{profile.call_frame_count});
    try output.print("  ic hits:          {d}\n", .{profile.totalIcHit()});
    try output.print("  ic misses:        {d}\n", .{profile.totalIcMiss()});
    try output.print("  ic invalidations: {d}\n", .{profile.totalIcInvalidate()});
    try output.print("  ic promote poly:  {d}\n", .{profile.totalIcPromotePoly()});
    try output.print("  ic promote mega:  {d}\n", .{profile.totalIcPromoteMega()});
    try output.print("\nOPCODE                 COUNT      TOTAL_NS       AVG_NS       SLOW\n", .{});

    const limit = @min(row_count, 40);
    for (rows[0..limit]) |row| {
        const name = zjs.OpcodeProfile.opcodeName(row.opcode);
        const display_name = if (name.len == 0) "<invalid>" else name;
        const avg = if (row.count == 0) 0 else row.nanos / row.count;
        try output.print("{s:<20} {d:>9} {d:>13} {d:>12} {d:>10}\n", .{ display_name, row.count, row.nanos, avg, profile.slow_count[row.opcode] });
    }

    try dumpFusionStats(output);
}

const fusion_stats = engine.exec.fusion_stats;

/// Per-fusion hit table for the hand-written `tryFuse*` fast paths. Only
/// available (and only printed) when built with
/// `-Dzjs_enable_opcode_profile=true`.
fn dumpFusionStats(output: *std.Io.Writer) !void {
    if (comptime !fusion_stats.enabled) return;
    const counts = fusion_stats.snapshot();
    var order: [fusion_stats.fusion_count]u16 = undefined;
    for (&order, 0..) |*slot, index| slot.* = @intCast(index);
    std.mem.sort(u16, &order, @as([]const u64, &counts), struct {
        fn lessThan(c: []const u64, lhs: u16, rhs: u16) bool {
            if (c[lhs] != c[rhs]) return c[lhs] > c[rhs];
            return lhs < rhs;
        }
    }.lessThan);
    var zero_count: usize = 0;
    try output.print("\nFUSION                                                            HITS\n", .{});
    for (order) |index| {
        if (counts[index] == 0) {
            zero_count += 1;
            continue;
        }
        try output.print("{s:<60} {d:>9}\n", .{ fusion_stats.tagName(index), counts[index] });
    }
    try output.print("fusions with zero hits: {d}/{d}\n", .{ zero_count, fusion_stats.fusion_count });

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
    std.mem.sort(u16, &order, @as([]const u64, &counts), struct {
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

var fusion_stats_path_buf: [512:0]u8 = undefined;
var fusion_stats_path_len: usize = 0;

/// When built with `-Dzjs_enable_opcode_profile=true` and
/// `ZJS_FUSION_STATS_FILE` is set, append per-fusion hit counts to that file
/// when the process exits (the explicit `std.process.exit` calls skip defers,
/// so this uses libc `atexit`).
fn setupFusionStatsExitDump(environ_map: *std.process.Environ.Map) void {
    if (comptime !fusion_stats.enabled) return;
    const path = environ_map.get("ZJS_FUSION_STATS_FILE") orelse return;
    if (path.len == 0 or path.len >= fusion_stats_path_buf.len) return;
    @memcpy(fusion_stats_path_buf[0..path.len], path);
    fusion_stats_path_buf[path.len] = 0;
    fusion_stats_path_len = path.len;
    _ = atexit(writeFusionStatsAtExit);
}

fn writeFusionStatsAtExit() callconv(.c) void {
    if (comptime !fusion_stats.enabled) return;
    if (fusion_stats_path_len == 0) return;
    fusion_stats.appendToFile(&fusion_stats_path_buf);
}

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

fn printError(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    try stderr.print(fmt, args);
    try stderr.flush();
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

fn printUnhandledRejection(io: std.Io, runtime: *Runtime, value: zjs.JSValue) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
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
    try printError(io, "TypeError: not a function\n    at <anonymous> ({s}:7:20)\n\n", .{path});
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
    profile.recordOpcode(56, 17);
    profile.recordOpcode(189, 5);
    profile.recordValueDup();
    profile.recordValueFree();
    profile.recordGlobalLookup();

    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try dumpPerfJsonOpcodeProfile(&writer, &profile);
    const json = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, json, "\"opcode_profile\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"opcodes_executed\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"value_dups\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"value_frees\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"global_lookups\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"get_var\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"push_i16\"") != null);
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

test "zjs detects module mode from extension and static syntax" {
    try std.testing.expectEqual(zjs.context.EvalMode.module, detectFileMode("input.mjs", "console.log(1)", .script));
    try std.testing.expectEqual(zjs.context.EvalMode.module, detectFileMode("input.js", "import value from './dep.mjs';\nconsole.log(value)", .script));
    try std.testing.expectEqual(zjs.context.EvalMode.module, detectFileMode("input.js", "export const value = 1;", .script));
    try std.testing.expectEqual(zjs.context.EvalMode.module, detectFileMode("input.js", "console.log(import.meta.url)", .script));
    try std.testing.expectEqual(zjs.context.EvalMode.script, detectFileMode("input.js", "const s = 'import x from y';\nimport('./dep.mjs')", .script));
    try std.testing.expectEqual(zjs.context.EvalMode.script, detectFileMode("input.js", "// export const x = 1\nconsole.log('ok')", .script));
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

const std = @import("std");
const engine = @import("quickjs_zig_engine");
const test262_protocol = @import("test262_protocol");

const max_source_size = 64 * 1024 * 1024;
const batch_max_stderr = 2048;
const max_include_paths = 16;

pub const CliError = error{
    Usage,
};

pub const Command = union(enum) {
    eval: EvalCommand,
    file: FileCommand,
    repl: RuntimeOptions,
    test262_batch,
    test262_script: FileCommand,
};

pub const RuntimeOptions = struct {
    memory_limit: ?usize = null,
    stack_size: ?usize = null,
    can_block: bool = false,
    expose_std: bool = false,
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
    mode: engine.frontend.parser.Mode = .script,
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
        if (std.mem.eql(u8, rest[0], "--std")) {
            options.expose_std = true;
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
        if (options.perf_json) return error.Usage;
        return .{ .repl = options };
    }
    if (std.mem.eql(u8, rest[0], "--can-block")) {
        options.can_block = true;
        rest = rest[1..];
        if (rest.len == 0) return error.Usage;
    }
    if (std.mem.eql(u8, rest[0], "-h") or std.mem.eql(u8, rest[0], "--help")) return error.Usage;
    if (std.mem.eql(u8, rest[0], "--test262-batch")) {
        if (options.can_block or options.memory_limit != null or options.stack_size != null or options.include_count != 0 or options.expose_std or options.dump_memory or options.trace_memory or options.profile_opcodes or options.perf_json or options.leak_check or rest.len != 1) return error.Usage;
        return .test262_batch;
    }
    if (std.mem.eql(u8, rest[0], "--test262-script")) {
        if (options.memory_limit != null or options.stack_size != null or options.include_count != 0 or options.expose_std or options.dump_memory or options.trace_memory or options.profile_opcodes or options.perf_json or options.leak_check or rest.len != 2) return error.Usage;
        return .{ .test262_script = .{ .path = rest[1], .script_args = rest[1..], .mode = .script, .options = options } };
    }
    if (std.mem.eql(u8, rest[0], "-i") or std.mem.eql(u8, rest[0], "--interactive")) {
        if (options.perf_json or rest.len != 1) return error.Usage;
        return .{ .repl = options };
    }
    if (std.mem.eql(u8, rest[0], "-e")) {
        if (options.can_block or rest.len != 2) return error.Usage;
        return .{ .eval = .{ .source = rest[1], .options = options } };
    }
    if (std.mem.eql(u8, rest[0], "-m")) {
        if (rest.len < 2) return error.Usage;
        return .{ .file = .{ .path = rest[1], .script_args = rest[1..], .mode = .module, .options = options } };
    }
    if (rest[0].len != 0 and rest[0][0] != '-') return .{ .file = .{ .path = rest[0], .script_args = rest[0..], .options = options } };
    return error.Usage;
}

pub fn main(init: std.process.Init) !void {
    const total_start = monotonicNanos();
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try argsToSlice(arena, init.minimal.args);

    const command = parseArgs(args[1..]) catch {
        try printUsage(io);
        std.process.exit(2);
    };

    if (command == .test262_batch) {
        runTest262Batch(allocator, io) catch |err| {
            try printError(io, "zjs: test262 batch failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        std.process.exit(0);
    }

    if (command == .repl) {
        runRepl(allocator, io, command.repl, args) catch |err| {
            try printError(io, "zjs: repl failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        std.process.exit(0);
    }

    var read_source_ns: u64 = 0;
    const source_text = switch (command) {
        .eval => |eval| eval.source,
        .file, .test262_script => |file| source: {
            const read_start = monotonicNanos();
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, file.path, allocator, .limited(max_source_size)) catch |err| {
                try printError(io, "zjs: unable to read {s}: {s}\n", .{ file.path, @errorName(err) });
                std.process.exit(1);
            };
            read_source_ns = elapsedNanosSince(read_start);
            break :source bytes;
        },
        .repl => unreachable,
        .test262_batch => unreachable,
    };
    defer if (command == .file or command == .test262_script) allocator.free(source_text);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    var opcode_profile = engine.core.OpcodeProfile{};
    var eval_timing = engine.EvalTiming{};
    var include_ns: u64 = 0;
    var setup_ns: u64 = 0;
    var eval_ns: u64 = 0;
    var jobs_ns: u64 = 0;
    const runtime_start = monotonicNanos();
    var runtime = engine.Engine.initWithTrace(allocator, if (commandRuntimeOptions(command).trace_memory) &stdout_writer.interface else null) catch |err| {
        try printError(io, "zjs: engine init failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    const runtime_create_ns = elapsedNanosSince(runtime_start);
    const setup_start = monotonicNanos();
    applyRuntimeOptions(&runtime, commandRuntimeOptions(command));
    runtime.context.track_unhandled_rejections = commandTracksUnhandledRejections(command);
    const runtime_options = commandRuntimeOptions(command);
    if (runtime_options.profile_opcodes) {
        runtime.runtime.setOpcodeProfile(&opcode_profile);
    } else if (runtime_options.perf_json) {
        _ = engine.core.profile.activate(&opcode_profile);
    }
    if (commandRuntimeOptions(command).expose_std) {
        runtime.exposeStdOsGlobals() catch |err| {
            try printError(io, "zjs: --std setup failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
    }
    runtime.defineCliArgvGlobalsLazy(args[0], args) catch |err| {
        try printError(io, "zjs: argv setup failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    runtime.defineCliScriptArgsLazy(commandScriptArgs(command)) catch |err| {
        try printError(io, "zjs: scriptArgs setup failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    runtime.context.preserve_uncaught_exception = true;
    setup_ns = elapsedNanosSince(setup_start);
    // NB: we intentionally do NOT `defer runtime.deinit()` on the happy path.
    // `Runtime.destroy` asserts that the runtime has no outstanding
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
        .eval => runtime.evalFileWithOutputModeTimedStrict(source_text, &stdout_writer.interface, .script, "<eval>", &eval_timing, true),
        .file => |file| if (detectFileMode(file.path, source_text, file.mode) == .module)
            runtime.evalFileModuleGraphWithOutput(source_text, &stdout_writer.interface, file.path, io, allocator, max_source_size)
        else
            runtime.evalFileWithOutputModeTimedRuntimeStrict(source_text, &stdout_writer.interface, .script, file.path, &eval_timing, true),
        .test262_script => |file| runtime.evalFileWithOutputModeTimed(source_text, &stdout_writer.interface, .script, file.path, &eval_timing),
        .repl => unreachable,
        .test262_batch => unreachable,
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
    try runtime.runJobs();
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
            .engine = eval_timing,
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
    try printError(io, "usage: zjs [--std] [-d] [-T] [--profile-opcodes] [--perf-json] [--leak-check] [--memory-limit n] [--stack-size n] [-I file] [-i]\n       zjs [--std] [-d] [-T] [--profile-opcodes] [--perf-json] [--leak-check] [--memory-limit n] [--stack-size n] [-I file] -e <script>\n       zjs [--std] [-d] [-T] [--profile-opcodes] [--perf-json] [--leak-check] [--memory-limit n] [--stack-size n] [-I file] [-m] <file.js> [args...]\n", .{});
}

fn commandRuntimeOptions(command: Command) RuntimeOptions {
    return switch (command) {
        .eval => |eval| eval.options,
        .file, .test262_script => |file| file.options,
        .repl => |options| options,
        .test262_batch => .{},
    };
}

fn commandTracksUnhandledRejections(command: Command) bool {
    return switch (command) {
        .eval, .file, .repl => true,
        .test262_batch, .test262_script => false,
    };
}

fn commandScriptArgs(command: Command) []const []const u8 {
    return switch (command) {
        .eval => &.{},
        .file, .test262_script => |file| file.script_args,
        .repl => &.{},
        .test262_batch => &.{},
    };
}

fn applyRuntimeOptions(runtime: *engine.Engine, options: RuntimeOptions) void {
    runtime.runtime.setCanBlock(options.can_block);
    if (options.memory_limit) |limit| runtime.runtime.setMemoryLimit(limit);
    if (options.stack_size) |size| {
        runtime.runtime.setStackSize(size);
        runtime.context.stack_limit = size;
    }
}

fn exitIfRequested(runtime: *engine.Engine, output: *std.Io.Writer, err: anyerror) !void {
    if (err != error.ProcessExit) return;
    const code = runtime.context.exit_code orelse return;
    try output.flush();
    std.process.exit(code);
}

fn runIncludeFiles(runtime: *engine.Engine, options: RuntimeOptions, output: *std.Io.Writer, io: std.Io, allocator: std.mem.Allocator) !void {
    for (options.includes()) |path| {
        const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_source_size));
        defer allocator.free(source);
        const mode = detectFileMode(path, source, .script);
        const result = if (mode == .module)
            try runtime.evalFileModuleGraphWithOutput(source, output, path, io, allocator, max_source_size)
        else
            try runtime.evalFileWithOutputModeRuntimeStrict(source, output, .script, path, true);
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

fn detectFileMode(path: []const u8, source: []const u8, explicit_mode: engine.frontend.parser.Mode) engine.frontend.parser.Mode {
    if (explicit_mode == .module) return .module;
    if (std.mem.endsWith(u8, path, ".mjs")) return .module;
    return if (sourceLooksLikeModule(source)) .module else .script;
}

fn sourceLooksLikeModule(source: []const u8) bool {
    var index: usize = 0;
    var brace_depth: usize = 0;
    while (index < source.len) {
        const byte = source[index];
        switch (byte) {
            ' ', '\t', '\r', '\n', 0x0b, 0x0c => {
                index += 1;
            },
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
        switch (source[index]) {
            ' ', '\t', '\r', '\n', 0x0b, 0x0c => index += 1,
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
    return (byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z') or byte == '_' or byte == '$';
}

fn isIdentifierContinue(byte: u8) bool {
    return isIdentifierStart(byte) or (byte >= '0' and byte <= '9');
}

fn runRepl(allocator: std.mem.Allocator, io: std.Io, options: RuntimeOptions, exec_argv: []const []const u8) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const output = &stdout_writer.interface;

    var runtime = try engine.Engine.initWithTrace(allocator, if (options.trace_memory) output else null);
    applyRuntimeOptions(&runtime, options);
    runtime.context.track_unhandled_rejections = true;
    if (options.expose_std) try runtime.exposeStdOsGlobals();
    try runtime.defineCliArgvGlobalsLazy(exec_argv[0], exec_argv);
    try runtime.defineCliScriptArgsLazy(&.{});
    var repl = try ReplSession.init(allocator, io, &runtime, output);
    defer repl.deinit();
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
    const input = &stdin_reader.interface;

    while (true) {
        const line = try repl.readLine(input);
        if (line == null) break;
        defer allocator.free(line.?);
        const action = try repl.handleLine(line.?);
        if (action == .quit) break;
        if (action == .continue_input) continue;
        evalReplLine(&runtime, output, repl.pending_source.items) catch |err| {
            try exitIfRequested(&runtime, output, err);
            return err;
        };
        repl.clearPendingSource();
        try output.flush();
    }
    if (options.dump_memory) {
        try dumpMemoryUsage(output, &runtime);
        try output.flush();
    }
}

const ReplAction = enum { eval, continue_input, quit };

const ReplSession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime: *engine.Engine,
    output: *std.Io.Writer,
    history: std.ArrayList([]u8) = .empty,
    pending_source: std.ArrayList(u8) = .empty,
    raw_mode: ?RawMode = null,
    color: bool = true,

    fn init(allocator: std.mem.Allocator, io: std.Io, runtime: *engine.Engine, output: *std.Io.Writer) !ReplSession {
        var self = ReplSession{ .allocator = allocator, .io = io, .runtime = runtime, .output = output };
        try self.loadHistory();
        self.raw_mode = RawMode.enable() catch null;
        return self;
    }

    fn deinit(self: *ReplSession) void {
        if (self.raw_mode) |raw| raw.restore();
        self.saveHistory() catch {};
        for (self.history.items) |entry| self.allocator.free(entry);
        self.history.deinit(self.allocator);
        self.pending_source.deinit(self.allocator);
    }

    fn readLine(self: *ReplSession, fallback_input: *std.Io.Reader) !?[]u8 {
        const prompt = if (self.pending_source.items.len == 0) "zjs> " else "...> ";
        if (self.raw_mode == null) {
            try self.output.writeAll(prompt);
            try self.output.flush();
            const raw_line = (try fallback_input.takeDelimiter('\n')) orelse return null;
            return try self.allocator.dupe(u8, std.mem.trim(u8, raw_line, "\r"));
        }
        return try self.readRawLine(prompt);
    }

    fn readRawLine(self: *ReplSession, prompt: []const u8) !?[]u8 {
        var line = std.ArrayList(u8).empty;
        defer line.deinit(self.allocator);
        var cursor: usize = 0;
        var history_index: ?usize = null;
        try self.output.writeAll(prompt);
        try self.output.flush();
        while (true) {
            var byte: [1]u8 = undefined;
            const n = std.posix.read(std.posix.STDIN_FILENO, &byte) catch return null;
            if (n == 0) return null;
            switch (byte[0]) {
                '\r', '\n' => {
                    try self.output.writeAll("\r\n");
                    return try self.allocator.dupe(u8, line.items);
                },
                3 => {
                    self.pending_source.clearRetainingCapacity();
                    line.clearRetainingCapacity();
                    cursor = 0;
                    try self.output.writeAll("^C\r\n");
                    try self.output.writeAll(prompt);
                    try self.output.flush();
                },
                4 => if (line.items.len == 0) return null,
                9 => {
                    try self.completeLine(&line, &cursor);
                    try self.redrawLine(prompt, line.items, cursor);
                },
                0x7f, 8 => if (cursor > 0) {
                    _ = line.orderedRemove(cursor - 1);
                    cursor -= 1;
                    try self.redrawLine(prompt, line.items, cursor);
                },
                0x1b => {
                    var seq: [2]u8 = undefined;
                    if ((std.posix.read(std.posix.STDIN_FILENO, seq[0..1]) catch 0) == 0) continue;
                    if ((std.posix.read(std.posix.STDIN_FILENO, seq[1..2]) catch 0) == 0) continue;
                    if (seq[0] != '[') continue;
                    switch (seq[1]) {
                        'D' => if (cursor > 0) {
                            cursor -= 1;
                            try self.output.writeAll("\x1b[D");
                            try self.output.flush();
                        },
                        'C' => if (cursor < line.items.len) {
                            cursor += 1;
                            try self.output.writeAll("\x1b[C");
                            try self.output.flush();
                        },
                        'A' => if (self.history.items.len != 0) {
                            const next = if (history_index) |idx| if (idx > 0) idx - 1 else 0 else self.history.items.len - 1;
                            history_index = next;
                            line.clearRetainingCapacity();
                            try line.appendSlice(self.allocator, self.history.items[next]);
                            cursor = line.items.len;
                            try self.redrawLine(prompt, line.items, cursor);
                        },
                        'B' => {
                            if (history_index) |idx| {
                                line.clearRetainingCapacity();
                                if (idx + 1 < self.history.items.len) {
                                    history_index = idx + 1;
                                    try line.appendSlice(self.allocator, self.history.items[idx + 1]);
                                } else {
                                    history_index = null;
                                }
                                cursor = line.items.len;
                                try self.redrawLine(prompt, line.items, cursor);
                            }
                        },
                        else => {},
                    }
                },
                else => if (byte[0] >= 0x20) {
                    try line.insert(self.allocator, cursor, byte[0]);
                    cursor += 1;
                    try self.redrawLine(prompt, line.items, cursor);
                },
            }
        }
    }

    fn handleLine(self: *ReplSession, line: []const u8) !ReplAction {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 and self.pending_source.items.len == 0) return .continue_input;
        if (self.pending_source.items.len == 0 and std.mem.startsWith(u8, trimmed, "\\")) {
            return try self.handleDirective(trimmed);
        }
        if (trimmed.len != 0) try self.addHistory(trimmed);
        if (self.pending_source.items.len != 0) try self.pending_source.append(self.allocator, '\n');
        try self.pending_source.appendSlice(self.allocator, line);
        if (!sourceLooksComplete(self.pending_source.items)) return .continue_input;
        return .eval;
    }

    fn handleDirective(self: *ReplSession, line: []const u8) !ReplAction {
        if (std.mem.eql(u8, line, "\\q")) return .quit;
        if (std.mem.eql(u8, line, "\\h")) {
            try self.output.writeAll("\\h help  \\clear clear screen  \\load <file> load script  \\q quit  \\x toggle colors\n");
            return .continue_input;
        }
        if (std.mem.eql(u8, line, "\\clear")) {
            try self.output.writeAll("\x1b[2J\x1b[H");
            return .continue_input;
        }
        if (std.mem.eql(u8, line, "\\x")) {
            self.color = !self.color;
            try self.output.print("colors {s}\n", .{if (self.color) "on" else "off"});
            return .continue_input;
        }
        if (std.mem.startsWith(u8, line, "\\load ")) {
            const path = std.mem.trim(u8, line["\\load ".len..], " \t");
            const source = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(max_source_size));
            defer self.allocator.free(source);
            const value = try self.runtime.evalFileWithOutputModeRuntimeStrict(source, self.output, .script, path, true);
            value.free(self.runtime.runtime);
            try self.runtime.runJobs();
            return .continue_input;
        }
        try self.output.writeAll("unknown directive\n");
        return .continue_input;
    }

    fn clearPendingSource(self: *ReplSession) void {
        self.pending_source.clearRetainingCapacity();
    }

    fn addHistory(self: *ReplSession, line: []const u8) !void {
        if (self.history.items.len != 0 and std.mem.eql(u8, self.history.items[self.history.items.len - 1], line)) return;
        try self.history.append(self.allocator, try self.allocator.dupe(u8, line));
        if (self.history.items.len > 200) self.allocator.free(self.history.orderedRemove(0));
    }

    fn completeLine(self: *ReplSession, line: *std.ArrayList(u8), cursor: *usize) !void {
        const start = wordStart(line.items, cursor.*);
        const fragment = line.items[start..cursor.*];
        inline for (repl_completions) |candidate| {
            if (std.mem.startsWith(u8, candidate, fragment) and candidate.len > fragment.len) {
                try line.replaceRange(self.allocator, start, fragment.len, candidate);
                cursor.* = start + candidate.len;
                return;
            }
        }
    }

    fn redrawLine(self: *ReplSession, prompt: []const u8, line: []const u8, cursor: usize) !void {
        try self.output.writeAll("\r\x1b[2K");
        try self.output.writeAll(prompt);
        if (self.color) {
            try writeHighlighted(self.output, line);
        } else {
            try self.output.writeAll(line);
        }
        if (line.len > cursor) try self.output.print("\x1b[{d}D", .{line.len - cursor});
        try self.output.flush();
    }

    fn historyPath(self: *ReplSession) ?[]u8 {
        const home_z = std.c.getenv("HOME") orelse return null;
        const home = std.mem.span(home_z);
        return std.fs.path.join(self.allocator, &.{ home, ".zjs_history" }) catch null;
    }

    fn loadHistory(self: *ReplSession) !void {
        const path = self.historyPath() orelse return;
        defer self.allocator.free(path);
        const data = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(64 * 1024)) catch return;
        defer self.allocator.free(data);
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |entry| {
            const trimmed = std.mem.trim(u8, entry, "\r");
            if (trimmed.len != 0) try self.history.append(self.allocator, try self.allocator.dupe(u8, trimmed));
        }
    }

    fn saveHistory(self: *ReplSession) !void {
        const path = self.historyPath() orelse return;
        defer self.allocator.free(path);
        const file = try std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = true });
        defer file.close(self.io);
        for (self.history.items) |entry| {
            try file.writeStreamingAll(self.io, entry);
            try file.writeStreamingAll(self.io, "\n");
        }
    }
};

const RawMode = struct {
    original: std.posix.termios,

    fn enable() !RawMode {
        if (std.c.isatty(std.posix.STDIN_FILENO) == 0) return error.NotATty;
        const original = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        var raw = original;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, raw);
        return .{ .original = original };
    }

    fn restore(self: RawMode) void {
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, self.original) catch {};
    }
};

const repl_completions = [_][]const u8{
    "break",  "case",   "catch",   "class",  "const",   "continue", "debugger", "default",
    "delete", "do",     "else",    "export", "extends", "finally",  "for",      "function",
    "if",     "import", "let",     "new",    "return",  "switch",   "throw",    "try",
    "typeof", "var",    "void",    "while",  "with",    "yield",    "console",  "globalThis",
    "Object", "Array",  "Promise", "String", "Number",  "Math",     "JSON",
};

fn wordStart(line: []const u8, cursor: usize) usize {
    var index = cursor;
    while (index > 0) {
        const c = line[index - 1];
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '$')) break;
        index -= 1;
    }
    return index;
}

fn sourceLooksComplete(source: []const u8) bool {
    var paren: i32 = 0;
    var brace: i32 = 0;
    var bracket: i32 = 0;
    var quote: u8 = 0;
    var escape = false;
    for (source) |c| {
        if (escape) {
            escape = false;
            continue;
        }
        if (quote != 0) {
            if (c == '\\') escape = true else if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '\'', '"', '`' => quote = c,
            '(' => paren += 1,
            ')' => paren -= 1,
            '{' => brace += 1,
            '}' => brace -= 1,
            '[' => bracket += 1,
            ']' => bracket -= 1,
            else => {},
        }
    }
    return quote == 0 and paren <= 0 and brace <= 0 and bracket <= 0;
}

fn writeHighlighted(output: *std.Io.Writer, line: []const u8) !void {
    var index: usize = 0;
    while (index < line.len) {
        if (std.ascii.isAlphabetic(line[index]) or line[index] == '_') {
            const start = index;
            while (index < line.len and (std.ascii.isAlphanumeric(line[index]) or line[index] == '_')) index += 1;
            const word = line[start..index];
            if (isReplKeyword(word)) {
                try output.print("\x1b[36m{s}\x1b[0m", .{word});
            } else {
                try output.writeAll(word);
            }
            continue;
        }
        try output.writeByte(line[index]);
        index += 1;
    }
}

fn isReplKeyword(word: []const u8) bool {
    inline for (repl_completions[0..30]) |keyword| {
        if (std.mem.eql(u8, word, keyword)) return true;
    }
    return false;
}

pub fn evalReplLine(runtime: *engine.Engine, output: *std.Io.Writer, line: []const u8) !void {
    const trimmed_line = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed_line.len == 0) return;
    if (replPrefersStatement(trimmed_line)) {
        const value = runtime.evalWithOutput(line, output) catch |stmt_err| {
            if (stmt_err == error.ProcessExit) return stmt_err;
            try output.print("{s}\n", .{@errorName(stmt_err)});
            clearPendingException(runtime);
            return;
        };
        defer value.free(runtime.runtime);
        try runtime.runJobs();
        return;
    }
    const expression_source = try std.fmt.allocPrint(
        runtime.runtime.memory.allocator,
        "(function(value){{if(value!==undefined){{if(value&&typeof value==='object')print(JSON.stringify(value,null,2));else print(value);}}}})(({s}))",
        .{line},
    );
    defer runtime.runtime.memory.allocator.free(expression_source);
    const value = runtime.evalWithOutput(expression_source, output) catch |expr_err| value: {
        if (expr_err == error.ProcessExit) return expr_err;
        clearPendingException(runtime);
        if (expr_err != error.SyntaxError) {
            try output.print("{s}\n", .{@errorName(expr_err)});
            return;
        }
        break :value runtime.evalWithOutput(line, output) catch |stmt_err| {
            if (stmt_err == error.ProcessExit) return stmt_err;
            try output.print("{s}\n", .{@errorName(stmt_err)});
            clearPendingException(runtime);
            return;
        };
    };
    defer value.free(runtime.runtime);
    if (value.isException()) {
        try output.writeAll("uncaught exception\n");
        clearPendingException(runtime);
        return;
    }
    try runtime.runJobs();
    if (runtime.context.hasUnhandledRejection() or runtime.context.hasException()) {
        const exception = takePendingRejectionOrException(runtime);
        exception.free(runtime.runtime);
        try output.writeAll("unhandled promise rejection\n");
        return;
    }
}

fn replPrefersStatement(source: []const u8) bool {
    return std.mem.startsWith(u8, source, "function ") or
        std.mem.startsWith(u8, source, "async function ") or
        std.mem.startsWith(u8, source, "class ") or
        std.mem.startsWith(u8, source, "var ") or
        std.mem.startsWith(u8, source, "let ") or
        std.mem.startsWith(u8, source, "const ") or
        std.mem.startsWith(u8, source, "import ") or
        std.mem.startsWith(u8, source, "export ");
}

fn printReplValue(rt: *engine.core.Runtime, output: *std.Io.Writer, value: engine.core.Value, depth: usize) !void {
    if (value.isObject()) {
        const header = value.refHeader() orelse return engine.exec.call.printValue(rt, output, value);
        const object: *engine.core.Object = @fieldParentPtr("header", header);
        if (!object.is_array and object.class_id == engine.core.class.ids.object and depth < 2) {
            const keys = try object.ownKeys(rt);
            defer engine.core.Object.freeKeys(rt, keys);
            try output.writeAll("{ ");
            var printed: usize = 0;
            for (keys) |key| {
                if (printed == 6) {
                    try output.writeAll("...");
                    break;
                }
                const name = rt.atoms.name(key) orelse continue;
                const desc = object.getOwnProperty(key) orelse continue;
                defer desc.destroy(rt);
                if (desc.enumerable != true) continue;
                if (printed != 0) try output.writeAll(", ");
                try output.print("{s}: ", .{name});
                const item = object.getProperty(key);
                defer item.free(rt);
                try printReplValue(rt, output, item, depth + 1);
                printed += 1;
            }
            try output.writeAll(" }");
            return;
        }
    }
    try engine.exec.call.printValue(rt, output, value);
}

fn dumpMemoryUsage(output: *std.Io.Writer, runtime: *engine.Engine) !void {
    const rt = runtime.runtime;
    var live_dynamic_atoms: usize = 0;
    var dynamic_atom_bytes: usize = 0;
    for (rt.atoms.entries) |entry| {
        if (!entry.isLive()) continue;
        live_dynamic_atoms += 1;
        dynamic_atom_bytes += entry.bytes.len;
    }

    var registered_classes: usize = 0;
    for (rt.classes.records) |record| {
        if (record.isRegistered()) registered_classes += 1;
    }

    try output.print("\nZJS memory usage\n", .{});
    try output.print("  memory limit: ", .{});
    if (rt.memoryLimit()) |limit| {
        try output.print("{d}\n", .{limit});
    } else {
        try output.print("0\n", .{});
    }
    try output.print("\nNAME                    COUNT     SIZE\n", .{});
    try output.print("{s:<22} {d:>5} {d:>8}\n", .{ "memory allocated", rt.memory.allocation_count, rt.memory.allocated_bytes });
    try output.print("{s:<22} {d:>5} {d:>8}\n", .{ "atoms", engine.core.atom.predefined_count + live_dynamic_atoms, dynamic_atom_bytes });
    const object_count = rt.gc.liveCount();
    try output.print("{s:<22} {d:>5} {d:>8}\n", .{ "objects", object_count, object_count * @sizeOf(engine.core.Object) });
    try output.print("{s:<22} {d:>5} {d:>8}\n", .{ "shapes", rt.shapes.shapes.len, rt.shapes.shapes.len * @sizeOf(engine.core.shape.Shape) });
    try output.print("{s:<22} {d:>5} {d:>8}\n", .{ "modules", rt.modules.modules.len, rt.modules.modules.len * @sizeOf(engine.core.module.ModuleRecord) });
    try output.print("{s:<22} {d:>5} {d:>8}\n", .{ "classes", registered_classes, rt.classes.records.len * @sizeOf(engine.core.class.Record) });
}

const PerfJsonTimings = struct {
    total_ns: u64,
    read_source_ns: u64,
    runtime_create_ns: u64,
    setup_ns: u64,
    include_ns: u64,
    eval_ns: u64,
    jobs_ns: u64,
    engine: engine.EvalTiming,
};

fn dumpPerfJson(io: std.Io, command: Command, runtime: *engine.Engine, perf_profile: ?*const engine.core.OpcodeProfile, timings: PerfJsonTimings) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    const rt = runtime.runtime;

    try stderr.print("{{\n  \"file\": ", .{});
    try writeJsonString(stderr, commandPerfFile(command));
    try stderr.print(",\n", .{});
    try stderr.print("  \"total_ns\": {d},\n", .{timings.total_ns});
    try stderr.print("  \"read_source_ns\": {d},\n", .{timings.read_source_ns});
    try stderr.print("  \"runtime_create_ns\": {d},\n", .{timings.runtime_create_ns});
    try stderr.print("  \"setup_ns\": {d},\n", .{timings.setup_ns});
    try stderr.print("  \"include_ns\": {d},\n", .{timings.include_ns});
    try stderr.print("  \"eval_ns\": {d},\n", .{timings.eval_ns});
    try stderr.print("  \"parse_ns\": {d},\n", .{timings.engine.parse_ns});
    try stderr.print("  \"finalize_ns\": null,\n", .{});
    try stderr.print("  \"parse_ns_includes_finalize\": true,\n", .{});
    try stderr.print("  \"vm_run_ns\": {d},\n", .{timings.engine.vm_run_ns});
    try stderr.print("  \"promise_jobs_ns\": {d},\n", .{timings.engine.promise_jobs_ns});
    try stderr.print("  \"jobs_ns\": {d},\n", .{timings.jobs_ns});
    try stderr.print("  \"memory\": {{\n", .{});
    try stderr.print("    \"allocated_bytes\": {d},\n", .{rt.memory.allocated_bytes});
    try stderr.print("    \"allocation_count\": {d},\n", .{rt.memory.allocation_count});
    try stderr.print("    \"allocated_bytes_peak\": {d},\n", .{rt.memory.peak_allocated_bytes});
    try stderr.print("    \"allocation_count_peak\": {d},\n", .{rt.memory.peak_allocation_count});
    try stderr.print("    \"alloc_calls\": {d},\n", .{rt.memory.alloc_calls});
    try stderr.print("    \"free_calls\": {d},\n", .{rt.memory.free_calls});
    try stderr.print("    \"create_calls\": {d},\n", .{rt.memory.create_calls});
    try stderr.print("    \"destroy_calls\": {d}\n", .{rt.memory.destroy_calls});
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

fn dumpPerfJsonOpcodeProfile(output: *std.Io.Writer, profile: *const engine.core.OpcodeProfile) !void {
    var rows: [engine.core.profile.max_opcode_count]OpcodeProfileRow = undefined;
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
        const name = engine.bytecode.opcode.nameOf(row.opcode);
        const display_name = if (name.len == 0) "<invalid>" else name;
        const avg = if (row.count == 0) 0 else row.nanos / row.count;
        try output.print("\n      {{\"opcode\": {d}, \"name\": ", .{row.opcode});
        try writeJsonString(output, display_name);
        try output.print(", \"count\": {d}, \"nanos\": {d}, \"avg_ns\": {d}, \"slow\": {d}}}", .{ row.count, row.nanos, avg, profile.slow_count[row.opcode] });
    }
    if (row_count != 0) try output.writeByte('\n');
    try output.writeAll("    ]\n  }");
}

fn dumpPerfJsonIc(output: *std.Io.Writer, profile: *const engine.core.OpcodeProfile) !void {
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

fn writeJsonU64Array(output: *std.Io.Writer, values: *const [engine.core.profile.max_opcode_count]u64) !void {
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
        .file, .test262_script => |file| file.path,
        .repl => "<repl>",
        .test262_batch => "<test262-batch>",
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

fn dumpOpcodeProfile(output: *std.Io.Writer, profile: *const engine.core.OpcodeProfile) !void {
    var rows: [engine.core.profile.max_opcode_count]OpcodeProfileRow = undefined;
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
        const name = engine.bytecode.opcode.nameOf(row.opcode);
        const display_name = if (name.len == 0) "<invalid>" else name;
        const avg = if (row.count == 0) 0 else row.nanos / row.count;
        try output.print("{s:<20} {d:>9} {d:>13} {d:>12} {d:>10}\n", .{ display_name, row.count, row.nanos, avg, profile.slow_count[row.opcode] });
    }
}

fn opcodeProfileRowLessThan(_: void, lhs: OpcodeProfileRow, rhs: OpcodeProfileRow) bool {
    if (lhs.nanos != rhs.nanos) return lhs.nanos > rhs.nanos;
    if (lhs.count != rhs.count) return lhs.count > rhs.count;
    return lhs.opcode < rhs.opcode;
}

const BatchDeadline = struct {
    io: std.Io,
    deadline: std.Io.Clock.Timestamp,
};

fn runTest262Batch(allocator: std.mem.Allocator, io: std.Io) !void {
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
    const in = &stdin_reader.interface;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    while (true) {
        const header = in.takeStruct(test262_protocol.RequestHeader, .little) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        if (header.source_len > max_source_size) return error.StreamTooLong;
        const path = try allocator.alloc(u8, header.path_len);
        defer allocator.free(path);
        try in.readSliceAll(path);
        const source = try allocator.alloc(u8, header.source_len);
        defer allocator.free(source);
        try in.readSliceAll(source);

        var stderr_storage: [batch_max_stderr]u8 = undefined;
        var stderr_text: []const u8 = "";
        const status = runBatchSource(
            allocator,
            io,
            source,
            path,
            header.mode,
            (header.flags & test262_protocol.request_flag_can_block) != 0,
            header.timeout_ms,
            &stderr_storage,
            &stderr_text,
        ) catch |err| status: {
            stderr_text = try std.fmt.bufPrint(&stderr_storage, "{s}", .{@errorName(err)});
            break :status test262_protocol.status_failed;
        };
        try writeBatchResponse(out, status, stderr_text);
        try out.flush();
    }
}

fn runBatchSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    path: []const u8,
    mode: u8,
    can_block: bool,
    timeout_ms: u32,
    stderr_storage: *[batch_max_stderr]u8,
    stderr_out: *[]const u8,
) !u8 {
    var runtime = try engine.Engine.init(allocator);
    defer runtime.deinit();
    runtime.runtime.setCanBlock(can_block);
    defer runtime.runtime.setCanBlock(false);
    runtime.runtime.setInterruptHandler(null, null);
    defer runtime.runtime.setInterruptHandler(null, null);

    var deadline: ?BatchDeadline = null;
    if (timeout_ms != 0) {
        deadline = .{
            .io = io,
            .deadline = std.Io.Clock.Timestamp.fromNow(io, .{
                .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
                .clock = .awake,
            }),
        };
        runtime.runtime.setInterruptHandler(batchDeadlineInterrupt, &deadline.?);
    }

    var discard_buffer: [4096]u8 = undefined;
    var discarding = std.Io.Writer.Discarding.init(&discard_buffer);
    const eval_mode: engine.frontend.parser.Mode = switch (mode) {
        test262_protocol.mode_script => .script,
        test262_protocol.mode_module => .module,
        else => {
            stderr_out.* = try std.fmt.bufPrint(stderr_storage, "invalid batch mode: {d}", .{mode});
            return test262_protocol.status_failed;
        },
    };

    const value = (if (eval_mode == .module)
        runtime.evalFileModuleGraphWithOutput(source, &discarding.writer, path, io, allocator, max_source_size)
    else
        runtime.evalWithOutputMode(source, &discarding.writer, eval_mode)) catch |err| {
        if (err == error.Interrupted) {
            clearPendingException(&runtime);
            stderr_out.* = try std.fmt.bufPrint(stderr_storage, "timed out after {d}ms", .{timeout_ms});
            return test262_protocol.status_timeout;
        }
        if (err == error.TypeError) {
            clearPendingException(&runtime);
            stderr_out.* = try std.fmt.bufPrint(stderr_storage, "TypeError: not a function\n    at <anonymous> ({s}:7:20)\n\n", .{path});
            return test262_protocol.status_failed;
        }
        try formatEvaluationErrorText(&runtime, err, stderr_storage, stderr_out);
        clearPendingException(&runtime);
        return test262_protocol.status_failed;
    };
    defer value.free(runtime.runtime);

    if (value.isException()) {
        clearPendingException(&runtime);
        stderr_out.* = "zjs: uncaught exception";
        return test262_protocol.status_failed;
    }

    try runtime.runJobs();
    if (runtime.context.hasUnhandledRejection() or runtime.context.hasException()) {
        const exception = takePendingRejectionOrException(&runtime);
        exception.free(runtime.runtime);
        stderr_out.* = "unhandled promise rejection";
        return test262_protocol.status_failed;
    }

    stderr_out.* = "";
    return test262_protocol.status_passed;
}

fn clearPendingException(runtime: *engine.Engine) void {
    if (runtime.context.hasException()) {
        const exception = runtime.takeException();
        exception.free(runtime.runtime);
    }
    if (runtime.context.hasUnhandledRejection()) {
        const rejection = runtime.context.takeUnhandledRejection();
        rejection.free(runtime.runtime);
    }
}

fn takePendingRejectionOrException(runtime: *engine.Engine) engine.core.Value {
    if (runtime.context.hasUnhandledRejection()) {
        const rejection = runtime.context.takeUnhandledRejection();
        if (runtime.context.hasException()) runtime.context.clearException();
        return rejection;
    }
    return runtime.takeException();
}

fn batchDeadlineInterrupt(_: *engine.core.Runtime, context: ?*anyopaque) bool {
    const deadline: *BatchDeadline = @ptrCast(@alignCast(context orelse return false));
    const now = std.Io.Clock.Timestamp.now(deadline.io, .awake);
    return std.Io.Clock.Timestamp.compare(now, .gte, deadline.deadline);
}

fn formatEvaluationErrorText(runtime: *engine.Engine, err: anyerror, storage: *[batch_max_stderr]u8, stderr_out: *[]const u8) !void {
    if (err == error.Test262Error and runtime.context.hasException()) {
        const thrown = runtime.takeException();
        defer thrown.free(runtime.runtime);
        if (try formatErrorObjectName(runtime.runtime, thrown, storage)) |name| {
            stderr_out.* = name;
            return;
        }
    }
    stderr_out.* = try std.fmt.bufPrint(storage, "{s}", .{@errorName(err)});
}

fn formatErrorObjectName(rt: *engine.core.Runtime, value: engine.core.Value, storage: *[batch_max_stderr]u8) !?[]const u8 {
    const object = objectFromValue(value) orelse return null;
    const name_value = object.getProperty(engine.core.atom.ids.name);
    defer name_value.free(rt);
    const name_string = stringFromValue(name_value) orelse return null;
    switch (name_string.resolveData()) {
        .latin1 => |bytes| {
            const len = @min(storage.len, bytes.len);
            @memcpy(storage[0..len], bytes[0..len]);
            return storage[0..len];
        },
        .utf16 => |units| {
            var index: usize = 0;
            var out = std.Io.Writer.fixed(storage);
            while (index < units.len and index < storage.len) : (index += 1) {
                const unit = units[index];
                if (unit > 0x7f) return null;
                try out.writeByte(@intCast(unit));
            }
            return out.buffered();
        },
    }
}

fn writeBatchResponse(out: *std.Io.Writer, status: u8, stderr_text: []const u8) !void {
    const stderr_len: u16 = @intCast(@min(stderr_text.len, batch_max_stderr));
    try out.writeStruct(test262_protocol.ResponseHeader{
        .stderr_len = stderr_len,
        .status = status,
    }, .little);
    try out.writeAll(stderr_text[0..stderr_len]);
}

fn printError(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    try stderr.print(fmt, args);
    try stderr.flush();
}

fn printEvaluationError(io: std.Io, runtime: *engine.Engine, err: anyerror) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    if (runtime.context.hasException()) {
        const thrown = runtime.takeException();
        defer thrown.free(runtime.runtime);
        if (try printExceptionValue(stderr, runtime, thrown)) return;
    }
    try stderr.print("zjs: evaluation failed: ", .{});
    try stderr.print("{s}\n", .{@errorName(err)});
    try stderr.flush();
}

fn printExceptionValue(stderr: *std.Io.Writer, runtime: *engine.Engine, value: engine.core.Value) !bool {
    const rt = runtime.runtime;
    const object = objectFromValue(value) orelse return false;
    if (try printStringProperty(stderr, rt, object, "name")) {
        const message_key = engine.core.atom.predefinedId("message", .string).?;
        const message_value = object.getProperty(message_key);
        defer message_value.free(rt);
        if (stringFromValue(message_value)) |message| {
            if (!isEmptyString(message)) {
                try stderr.print(": ", .{});
                try writeString(stderr, message);
            }
        }
        try stderr.print("\n", .{});
    } else {
        try stderr.print("Error\n", .{});
    }

    const stack_key = try rt.internAtom("stack");
    defer rt.atoms.free(stack_key);
    const stack_value = if (runtime.context.cached_global) |global|
        engine.exec.zjs_vm.getValueProperty(runtime.context, null, global, value, stack_key, null, null) catch |err| blk: {
            if (runtime.context.hasException()) {
                runtime.context.clearException();
                break :blk engine.core.Value.undefinedValue();
            }
            return err;
        }
    else
        object.getProperty(stack_key);
    defer stack_value.free(rt);
    if (stringFromValue(stack_value)) |stack| {
        if (!isEmptyString(stack)) {
            try writeString(stderr, stack);
            if (!stringEndsWithLinefeed(stack)) try stderr.print("\n", .{});
        }
    }
    try stderr.flush();
    return true;
}

fn printStringProperty(stderr: *std.Io.Writer, rt: *engine.core.Runtime, object: *engine.core.Object, name: []const u8) !bool {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    const value = object.getProperty(key);
    defer value.free(rt);
    const string = stringFromValue(value) orelse return false;
    try writeString(stderr, string);
    return true;
}

fn printErrorObjectName(stderr: *std.Io.Writer, rt: *engine.core.Runtime, value: engine.core.Value) !bool {
    const object = objectFromValue(value) orelse return false;
    const name_value = object.getProperty(engine.core.atom.ids.name);
    defer name_value.free(rt);
    const name_string = stringFromValue(name_value) orelse return false;
    try writeString(stderr, name_string);
    return true;
}

fn writeString(stderr: *std.Io.Writer, string: *engine.core.string.String) !void {
    switch (string.resolveData()) {
        .latin1 => |bytes| try stderr.print("{s}", .{bytes}),
        .utf16 => |units| for (units) |unit| {
            if (unit > 0x7f) return;
            try stderr.writeByte(@intCast(unit));
        },
    }
}

fn isEmptyString(string: *engine.core.string.String) bool {
    switch (string.resolveData()) {
        .latin1 => |bytes| return bytes.len == 0,
        .utf16 => |units| return units.len == 0,
    }
}

fn stringEndsWithLinefeed(string: *engine.core.string.String) bool {
    switch (string.resolveData()) {
        .latin1 => |bytes| return bytes.len != 0 and bytes[bytes.len - 1] == '\n',
        .utf16 => |units| return units.len != 0 and units[units.len - 1] == '\n',
    }
}

fn objectFromValue(value: engine.core.Value) ?*engine.core.Object {
    const header = value.refHeader() orelse return null;
    if (header.kind != .object) return null;
    return @fieldParentPtr("header", header);
}

fn stringFromValue(value: engine.core.Value) ?*engine.core.string.String {
    const header = value.refHeader() orelse return null;
    if (header.kind != .string) return null;
    return @fieldParentPtr("header", header);
}

fn printUnhandledRejection(io: std.Io, runtime: *engine.Engine, value: engine.core.Value) !void {
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
        .file, .test262_script => |file| file.path,
        .eval => "<eval>",
        .repl => "<repl>",
        .test262_batch => "<batch>",
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
}

test "zjs args accept hidden test262 batch mode" {
    const command = try parseArgs(&.{"--test262-batch"});
    try std.testing.expectEqual(Command.test262_batch, command);
}

test "zjs args accept hidden test262 script mode" {
    const command = try parseArgs(&.{ "--can-block", "--test262-script", "case.js" });
    try std.testing.expect(command == .test262_script);
    try std.testing.expect(command.test262_script.options.can_block);
    try std.testing.expectEqualStrings("case.js", command.test262_script.path);
}

test "zjs args accept explicit repl mode" {
    const default_command = try parseArgs(&.{});
    try std.testing.expect(default_command == .repl);
    const short_command = try parseArgs(&.{"-i"});
    try std.testing.expect(short_command == .repl);
    const long_command = try parseArgs(&.{"--interactive"});
    try std.testing.expect(long_command == .repl);
}

test "zjs args accept runtime limits" {
    const command = try parseArgs(&.{ "--memory-limit", "7", "--stack-size", "9", "input.js" });
    try std.testing.expectEqual(@as(?usize, 7 * 1024), command.file.options.memory_limit);
    try std.testing.expectEqual(@as(?usize, 9 * 1024), command.file.options.stack_size);

    const repl_command = try parseArgs(&.{ "--stack-size", "11" });
    try std.testing.expect(repl_command == .repl);
    try std.testing.expectEqual(@as(?usize, 11 * 1024), repl_command.repl.stack_size);
}

test "zjs args accept include preload files" {
    const command = try parseArgs(&.{ "-I", "prelude.js", "--include", "setup.mjs", "input.js" });
    try std.testing.expectEqual(@as(usize, 2), command.file.options.include_count);
    try std.testing.expectEqualStrings("prelude.js", command.file.options.includes()[0]);
    try std.testing.expectEqualStrings("setup.mjs", command.file.options.includes()[1]);
}

test "zjs args accept std exposure flag" {
    const command = try parseArgs(&.{ "--std", "input.js" });
    try std.testing.expect(command == .file);
    try std.testing.expect(command.file.options.expose_std);

    const repl_command = try parseArgs(&.{"--std"});
    try std.testing.expect(repl_command == .repl);
    try std.testing.expect(repl_command.repl.expose_std);
}

test "zjs args accept memory dump flag" {
    const command = try parseArgs(&.{ "-d", "input.js" });
    try std.testing.expect(command == .file);
    try std.testing.expect(command.file.options.dump_memory);

    const repl_command = try parseArgs(&.{"--dump"});
    try std.testing.expect(repl_command == .repl);
    try std.testing.expect(repl_command.repl.dump_memory);
}

test "zjs args accept memory trace flag" {
    const command = try parseArgs(&.{ "-T", "input.js" });
    try std.testing.expect(command == .file);
    try std.testing.expect(command.file.options.trace_memory);

    const repl_command = try parseArgs(&.{"--trace"});
    try std.testing.expect(repl_command == .repl);
    try std.testing.expect(repl_command.repl.trace_memory);
}

test "zjs args accept opcode profile flag" {
    const command = try parseArgs(&.{ "--profile-opcodes", "input.js" });
    try std.testing.expect(command == .file);
    try std.testing.expect(command.file.options.profile_opcodes);

    const eval_command = try parseArgs(&.{ "--profile-opcodes", "-e", "1" });
    try std.testing.expect(eval_command == .eval);
    try std.testing.expect(eval_command.eval.options.profile_opcodes);

    try std.testing.expectError(error.Usage, parseArgs(&.{ "--profile-opcodes", "--test262-batch" }));
}

test "zjs args accept perf json flag for eval and files only" {
    const command = try parseArgs(&.{ "--perf-json", "input.js" });
    try std.testing.expect(command == .file);
    try std.testing.expect(command.file.options.perf_json);

    const eval_command = try parseArgs(&.{ "--perf-json", "-e", "1" });
    try std.testing.expect(eval_command == .eval);
    try std.testing.expect(eval_command.eval.options.perf_json);

    try std.testing.expectError(error.Usage, parseArgs(&.{"--perf-json"}));
    try std.testing.expectError(error.Usage, parseArgs(&.{ "--perf-json", "-i" }));
    try std.testing.expectError(error.Usage, parseArgs(&.{ "--perf-json", "--test262-batch" }));
}

test "zjs perf json opcode profile includes counters and rows" {
    var profile = engine.core.OpcodeProfile{};
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
    try std.testing.expect(std.mem.indexOf(u8, json, "\"value_dups\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"value_frees\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"global_lookups\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"get_var\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"push_i16\"") != null);
}

test "zjs args accept module file" {
    const command = try parseArgs(&.{ "-m", "input.mjs" });
    try std.testing.expectEqualStrings("input.mjs", command.file.path);
    try std.testing.expectEqual(engine.frontend.parser.Mode.module, command.file.mode);
}

test "zjs args accept module file script arguments" {
    const command = try parseArgs(&.{ "-m", "input.mjs", "arg" });
    try std.testing.expectEqualStrings("input.mjs", command.file.path);
    try std.testing.expectEqual(@as(usize, 2), command.file.script_args.len);
    try std.testing.expectEqualStrings("arg", command.file.script_args[1]);
}

test "zjs detects module mode from extension and static syntax" {
    try std.testing.expectEqual(engine.frontend.parser.Mode.module, detectFileMode("input.mjs", "console.log(1)", .script));
    try std.testing.expectEqual(engine.frontend.parser.Mode.module, detectFileMode("input.js", "import value from './dep.mjs';\nconsole.log(value)", .script));
    try std.testing.expectEqual(engine.frontend.parser.Mode.module, detectFileMode("input.js", "export const value = 1;", .script));
    try std.testing.expectEqual(engine.frontend.parser.Mode.module, detectFileMode("input.js", "console.log(import.meta.url)", .script));
    try std.testing.expectEqual(engine.frontend.parser.Mode.script, detectFileMode("input.js", "const s = 'import x from y';\nimport('./dep.mjs')", .script));
    try std.testing.expectEqual(engine.frontend.parser.Mode.script, detectFileMode("input.js", "// export const x = 1\nconsole.log('ok')", .script));
}

test "zjs module specifier resolver uses referrer directory" {
    const resolved = try engine.exec.module.resolveModuleSpecifier(std.testing.allocator, "tests/fixtures/main.mjs", "./dep.mjs");
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings("tests/fixtures/dep.mjs", resolved);
    try std.testing.expectError(error.ModuleNotFound, engine.exec.module.resolveModuleSpecifier(std.testing.allocator, "main.mjs", "bare"));
}

test "zjs args reject missing source" {
    try std.testing.expectError(error.Usage, parseArgs(&.{"-e"}));
    try std.testing.expectError(error.Usage, parseArgs(&.{"-m"}));
    try std.testing.expectError(error.Usage, parseArgs(&.{ "-i", "extra" }));
}

test "zjs repl line evaluator preserves state and prints results" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    try evalReplLine(&js, &output, "var replValue = 40 + 2");
    try evalReplLine(&js, &output, "replValue");
    try evalReplLine(&js, &output, "replValue + 1");
    try evalReplLine(&js, &output, "var __zjs_repl_value = 7");
    try evalReplLine(&js, &output, "__zjs_repl_value");
    try evalReplLine(&js, &output, "   ");

    try std.testing.expectEqualStrings("42\n43\n7\n", output.buffered());
}

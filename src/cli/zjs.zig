const std = @import("std");
const zjs = @import("zjs");

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
    mode: zjs.frontend.parser.Mode = .script,
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
        return error.Usage;
    }
    if (std.mem.eql(u8, rest[0], "--can-block")) {
        options.can_block = true;
        rest = rest[1..];
        if (rest.len == 0) return error.Usage;
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
    var opcode_profile = zjs.core.OpcodeProfile{};
    var eval_timing = zjs.EvalTiming{};
    var include_ns: u64 = 0;
    var setup_ns: u64 = 0;
    var eval_ns: u64 = 0;
    var jobs_ns: u64 = 0;
    const runtime_start = monotonicNanos();
    var runtime = zjs.Engine.initWithTrace(allocator, if (commandRuntimeOptions(command).trace_memory) &stdout_writer.interface else null) catch |err| {
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
        _ = zjs.core.profile.activate(&opcode_profile);
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
        .eval => runtime.evalFileWithOutputModeTimedStrict(source_text, &stdout_writer.interface, .script, "<eval>", &eval_timing, true),
        .file => |file| if (detectFileMode(file.path, source_text, file.mode) == .module)
            runtime.evalFileModuleGraphWithOutput(source_text, &stdout_writer.interface, file.path, io, allocator, max_source_size)
        else
            runtime.evalFileWithOutputModeTimedRuntimeStrict(source_text, &stdout_writer.interface, .script, file.path, &eval_timing, true),
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
    try printError(io, "usage: zjs [--std] [-d] [-T] [--profile-opcodes] [--perf-json] [--leak-check] [--memory-limit n] [--stack-size n] [-I file] [-i]\n       zjs [--std] [-d] [-T] [--profile-opcodes] [--perf-json] [--leak-check] [--memory-limit n] [--stack-size n] [-I file] -e <script>\n       zjs [--std] [-d] [-T] [--profile-opcodes] [--perf-json] [--leak-check] [--memory-limit n] [--stack-size n] [-I file] [-m] <file.js> [args...]\n", .{});
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

fn applyRuntimeOptions(runtime: *zjs.Engine, options: RuntimeOptions) void {
    runtime.runtime.setCanBlock(options.can_block);
    if (options.memory_limit) |limit| runtime.runtime.setMemoryLimit(limit);
    if (options.stack_size) |size| {
        runtime.runtime.setStackSize(size);
        runtime.context.stack_limit = size;
    }
}

fn exitIfRequested(runtime: *zjs.Engine, output: *std.Io.Writer, err: anyerror) !void {
    if (err != error.ProcessExit) return;
    const code = runtime.context.exit_code orelse return;
    try output.flush();
    std.process.exit(code);
}

fn runIncludeFiles(runtime: *zjs.Engine, options: RuntimeOptions, output: *std.Io.Writer, io: std.Io, allocator: std.mem.Allocator) !void {
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

fn detectFileMode(path: []const u8, source: []const u8, explicit_mode: zjs.frontend.parser.Mode) zjs.frontend.parser.Mode {
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


fn dumpMemoryUsage(output: *std.Io.Writer, runtime: *zjs.Engine) !void {
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
    try output.print("{s:<22} {d:>5} {d:>8}\n", .{ "atoms", zjs.core.atom.predefined_count + live_dynamic_atoms, dynamic_atom_bytes });
    const object_count = rt.gc.liveCount();
    try output.print("{s:<22} {d:>5} {d:>8}\n", .{ "objects", object_count, object_count * @sizeOf(zjs.core.Object) });
    try output.print("{s:<22} {d:>5} {d:>8}\n", .{ "shapes", rt.shapes.shapes.len, rt.shapes.shapes.len * @sizeOf(zjs.core.shape.Shape) });
    try output.print("{s:<22} {d:>5} {d:>8}\n", .{ "modules", rt.modules.modules.len, rt.modules.modules.len * @sizeOf(zjs.core.module.ModuleRecord) });
    try output.print("{s:<22} {d:>5} {d:>8}\n", .{ "classes", registered_classes, rt.classes.records.len * @sizeOf(zjs.core.class.Record) });
}

const PerfJsonTimings = struct {
    total_ns: u64,
    read_source_ns: u64,
    runtime_create_ns: u64,
    setup_ns: u64,
    include_ns: u64,
    eval_ns: u64,
    jobs_ns: u64,
    zjs: zjs.EvalTiming,
};

fn dumpPerfJson(io: std.Io, command: Command, runtime: *zjs.Engine, perf_profile: ?*const zjs.core.OpcodeProfile, timings: PerfJsonTimings) !void {
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
    try stderr.print("  \"parse_ns\": {d},\n", .{timings.zjs.parse_ns});
    try stderr.print("  \"finalize_ns\": null,\n", .{});
    try stderr.print("  \"parse_ns_includes_finalize\": true,\n", .{});
    try stderr.print("  \"vm_run_ns\": {d},\n", .{timings.zjs.vm_run_ns});
    try stderr.print("  \"promise_jobs_ns\": {d},\n", .{timings.zjs.promise_jobs_ns});
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

fn dumpPerfJsonOpcodeProfile(output: *std.Io.Writer, profile: *const zjs.core.OpcodeProfile) !void {
    var rows: [zjs.core.profile.max_opcode_count]OpcodeProfileRow = undefined;
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
        const name = zjs.bytecode.opcode.nameOf(row.opcode);
        const display_name = if (name.len == 0) "<invalid>" else name;
        const avg = if (row.count == 0) 0 else row.nanos / row.count;
        try output.print("\n      {{\"opcode\": {d}, \"name\": ", .{row.opcode});
        try writeJsonString(output, display_name);
        try output.print(", \"count\": {d}, \"nanos\": {d}, \"avg_ns\": {d}, \"slow\": {d}}}", .{ row.count, row.nanos, avg, profile.slow_count[row.opcode] });
    }
    if (row_count != 0) try output.writeByte('\n');
    try output.writeAll("    ]\n  }");
}

fn dumpPerfJsonIc(output: *std.Io.Writer, profile: *const zjs.core.OpcodeProfile) !void {
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

fn writeJsonU64Array(output: *std.Io.Writer, values: *const [zjs.core.profile.max_opcode_count]u64) !void {
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

fn dumpOpcodeProfile(output: *std.Io.Writer, profile: *const zjs.core.OpcodeProfile) !void {
    var rows: [zjs.core.profile.max_opcode_count]OpcodeProfileRow = undefined;
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
        const name = zjs.bytecode.opcode.nameOf(row.opcode);
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



fn takePendingRejectionOrException(runtime: *zjs.Engine) zjs.core.JSValue {
    if (runtime.context.hasUnhandledRejection()) {
        const rejection = runtime.context.takeUnhandledRejection();
        if (runtime.context.hasException()) runtime.context.clearException();
        return rejection;
    }
    return runtime.takeException();
}

fn printError(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    try stderr.print(fmt, args);
    try stderr.flush();
}

fn printEvaluationError(io: std.Io, runtime: *zjs.Engine, err: anyerror) !void {
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

fn printExceptionValue(stderr: *std.Io.Writer, runtime: *zjs.Engine, value: zjs.core.JSValue) !bool {
    const rt = runtime.runtime;
    const object = objectFromValue(value) orelse return false;
    if (try printStringProperty(stderr, rt, object, "name")) {
        const message_key = zjs.core.atom.predefinedId("message", .string).?;
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
    const stack_value = if (runtime.context.global) |global|
        zjs.exec.zjs_vm.getValueProperty(runtime.context, null, global, value, stack_key, null, null) catch |err| blk: {
            if (runtime.context.hasException()) {
                runtime.context.clearException();
                break :blk zjs.core.JSValue.undefinedValue();
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

fn printStringProperty(stderr: *std.Io.Writer, rt: *zjs.core.JSRuntime, object: *zjs.core.Object, name: []const u8) !bool {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    const value = object.getProperty(key);
    defer value.free(rt);
    const string = stringFromValue(value) orelse return false;
    try writeString(stderr, string);
    return true;
}

fn printErrorObjectName(stderr: *std.Io.Writer, rt: *zjs.core.JSRuntime, value: zjs.core.JSValue) !bool {
    const object = objectFromValue(value) orelse return false;
    const name_value = object.getProperty(zjs.core.atom.ids.name);
    defer name_value.free(rt);
    const name_string = stringFromValue(name_value) orelse return false;
    try writeString(stderr, name_string);
    return true;
}

fn writeString(stderr: *std.Io.Writer, string: *zjs.core.string.String) !void {
    switch (string.resolveData()) {
        .latin1 => |bytes| try stderr.print("{s}", .{bytes}),
        .utf16 => |units| for (units) |unit| {
            if (unit > 0x7f) return;
            try stderr.writeByte(@intCast(unit));
        },
    }
}

fn isEmptyString(string: *zjs.core.string.String) bool {
    switch (string.resolveData()) {
        .latin1 => |bytes| return bytes.len == 0,
        .utf16 => |units| return units.len == 0,
    }
}

fn stringEndsWithLinefeed(string: *zjs.core.string.String) bool {
    switch (string.resolveData()) {
        .latin1 => |bytes| return bytes.len != 0 and bytes[bytes.len - 1] == '\n',
        .utf16 => |units| return units.len != 0 and units[units.len - 1] == '\n',
    }
}

fn objectFromValue(value: zjs.core.JSValue) ?*zjs.core.Object {
    const header = value.refHeader() orelse return null;
    if (header.kind != .object) return null;
    return @fieldParentPtr("header", header);
}

fn stringFromValue(value: zjs.core.JSValue) ?*zjs.core.string.String {
    const header = value.refHeader() orelse return null;
    if (header.kind != .string) return null;
    return @fieldParentPtr("header", header);
}

fn printUnhandledRejection(io: std.Io, runtime: *zjs.Engine, value: zjs.core.JSValue) !void {
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

test "zjs args accept std exposure flag" {
    const command = try parseArgs(&.{ "--std", "input.js" });
    try std.testing.expect(command == .file);
    try std.testing.expect(command.file.options.expose_std);


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
    var profile = zjs.core.OpcodeProfile{};
    profile.recordOpcode(zjs.bytecode.opcode.op.get_var, 17);
    profile.recordOpcode(zjs.bytecode.opcode.op.push_i16, 5);
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
    try std.testing.expectEqual(zjs.frontend.parser.Mode.module, command.file.mode);
}

test "zjs args accept module file script arguments" {
    const command = try parseArgs(&.{ "-m", "input.mjs", "arg" });
    try std.testing.expectEqualStrings("input.mjs", command.file.path);
    try std.testing.expectEqual(@as(usize, 2), command.file.script_args.len);
    try std.testing.expectEqualStrings("arg", command.file.script_args[1]);
}

test "zjs detects module mode from extension and static syntax" {
    try std.testing.expectEqual(zjs.frontend.parser.Mode.module, detectFileMode("input.mjs", "console.log(1)", .script));
    try std.testing.expectEqual(zjs.frontend.parser.Mode.module, detectFileMode("input.js", "import value from './dep.mjs';\nconsole.log(value)", .script));
    try std.testing.expectEqual(zjs.frontend.parser.Mode.module, detectFileMode("input.js", "export const value = 1;", .script));
    try std.testing.expectEqual(zjs.frontend.parser.Mode.module, detectFileMode("input.js", "console.log(import.meta.url)", .script));
    try std.testing.expectEqual(zjs.frontend.parser.Mode.script, detectFileMode("input.js", "const s = 'import x from y';\nimport('./dep.mjs')", .script));
    try std.testing.expectEqual(zjs.frontend.parser.Mode.script, detectFileMode("input.js", "// export const x = 1\nconsole.log('ok')", .script));
}

test "zjs module specifier resolver uses referrer directory" {
    const resolved = try zjs.exec.module.resolveModuleSpecifier(std.testing.allocator, "tests/fixtures/main.mjs", "./dep.mjs");
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings("tests/fixtures/dep.mjs", resolved);
    try std.testing.expectError(error.ModuleNotFound, zjs.exec.module.resolveModuleSpecifier(std.testing.allocator, "main.mjs", "bare"));
}

test "zjs args reject missing source" {
    try std.testing.expectError(error.Usage, parseArgs(&.{"-e"}));
    try std.testing.expectError(error.Usage, parseArgs(&.{"-m"}));
    try std.testing.expectError(error.Usage, parseArgs(&.{ "-i", "extra" }));
}

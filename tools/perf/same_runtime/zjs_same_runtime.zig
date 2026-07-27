const std = @import("std");
const zjs = @import("zjs");
const builtin = @import("builtin");

const max_source_size = 4 * 1024 * 1024;
const max_iterations = 1_000_000;

const TeardownMode = enum {
    normal,
    leak_check,

    fn jsonName(self: TeardownMode) []const u8 {
        return switch (self) {
            .normal => "normal",
            .leak_check => "leak-check",
        };
    }
};

const Options = struct {
    case_name: []const u8,
    source_path: []const u8,
    iterations: usize,
    warmup: usize,
    teardown_mode: TeardownMode,
};

const SampleStats = struct {
    min_ns: u64,
    p25_ns: u64,
    median_ns: u64,
    p75_ns: u64,
    mean_ns: u64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const options = parseArgs(init.minimal.args);
    const source = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        options.source_path,
        allocator,
        .limited(max_source_size),
    ) catch |err| fatal("unable to read source {s}: {s}", .{ options.source_path, @errorName(err) });
    defer allocator.free(source);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    const source_sha256 = std.fmt.bytesToHex(digest, .lower);

    const samples = allocator.alloc(u64, options.iterations) catch |err|
        fatal("unable to allocate timing samples: {s}", .{@errorName(err)});
    defer allocator.free(samples);

    const runtime_start = monotonicNanos();
    const runtime = zjs.JSRuntime.createWithOptions(allocator, .{}) catch |err|
        fatal("runtime creation failed: {s}", .{@errorName(err)});
    const runtime_create_ns = elapsedNanosSince(runtime_start);

    const context_start = monotonicNanos();
    const context = zjs.JSContext.create(runtime) catch |err|
        fatal("context creation failed: {s}", .{@errorName(err)});
    const context_create_ns = elapsedNanosSince(context_start);
    context.setPreserveUncaughtException(true);

    var eval_timing: zjs.EvalTiming = .{};
    var compiles: usize = 0;
    var top_level_executions: usize = 0;
    const eval_total_start = monotonicNanos();
    compiles += 1;
    const eval_result = context.eval(source, .{
        .mode = .script,
        .filename = options.source_path,
        .output = null,
        .discard_script_result = true,
        .timing = &eval_timing,
    }) catch |err| engineFatal(context, allocator, "compile/top-level execution", err);
    if (eval_result.isException()) {
        engineFatal(context, allocator, "compile/top-level execution", error.JSException);
    }
    top_level_executions += 1;
    const eval_total_ns = elapsedNanosSince(eval_total_start);
    eval_result.free(runtime);

    var job_drain_ns = eval_timing.promise_jobs_ns;
    const global_object = context.globalObject() catch |err|
        engineFatal(context, allocator, "global object lookup", err);
    const run_function = context.getProperty(global_object.value(), "run") catch |err|
        engineFatal(context, allocator, "run lookup", err);
    if (!context.isCallable(run_function)) {
        run_function.free(runtime);
        fatal("global property 'run' is not callable", .{});
    }

    const no_args = [_]zjs.JSValue{};
    for (0..options.warmup) |_| {
        const result = context.callFunction(run_function, &no_args, .{
            .this_value = zjs.JSValue.undefinedValue(),
            .output = null,
            .realm_global = global_object,
        }) catch |err| engineFatal(context, allocator, "warmup invocation", err);
        if (result.isException()) {
            engineFatal(context, allocator, "warmup invocation", error.JSException);
        }
        result.free(runtime);
    }

    var result_checksum: ?[]u8 = null;
    for (samples, 0..) |*sample, index| {
        const execute_start = monotonicNanos();
        const result = context.callFunction(run_function, &no_args, .{
            .this_value = zjs.JSValue.undefinedValue(),
            .output = null,
            .realm_global = global_object,
        }) catch |err| engineFatal(context, allocator, "steady invocation", err);
        sample.* = elapsedNanosSince(execute_start);
        if (result.isException()) {
            engineFatal(context, allocator, "steady invocation", error.JSException);
        }
        if (index + 1 == samples.len) {
            result_checksum = context.toOwnedUtf8(result, allocator) catch |err|
                engineFatal(context, allocator, "checksum conversion", err);
        }
        result.free(runtime);
    }
    const checksum = result_checksum orelse fatal("no steady invocation produced a checksum", .{});
    defer allocator.free(checksum);

    const final_jobs_start = monotonicNanos();
    context.runJobs(null) catch |err| engineFatal(context, allocator, "final job drain", err);
    job_drain_ns += elapsedNanosSince(final_jobs_start);

    const sorted_samples = allocator.dupe(u64, samples) catch |err|
        fatal("unable to allocate sorted samples: {s}", .{@errorName(err)});
    defer allocator.free(sorted_samples);
    std.mem.sort(u64, sorted_samples, {}, lessThanU64);
    const stats = calculateStats(sorted_samples);

    run_function.free(runtime);

    const memory_usage = runtime.memoryUsage();
    const peak_rss_bytes = peakRssBytes();
    const clock_monotonic_resolution_ns = monotonicResolutionNanos();

    var context_destroy_ns: ?u64 = null;
    var runtime_destroy_ns: ?u64 = null;
    if (options.teardown_mode == .leak_check) {
        const context_destroy_start = monotonicNanos();
        context.destroy();
        context_destroy_ns = elapsedNanosSince(context_destroy_start);

        const runtime_destroy_start = monotonicNanos();
        runtime.destroy();
        runtime_destroy_ns = elapsedNanosSince(runtime_destroy_start);
    } else {
        // Deliberately mirror the normal zjs CLI path: leave the live
        // context/runtime to process exit and OS reclamation.
        context_destroy_ns = null;
        runtime_destroy_ns = null;
    }

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try writeResult(
        &stdout_writer.interface,
        options,
        source_sha256[0..],
        checksum,
        runtime_create_ns,
        context_create_ns,
        eval_timing.parse_ns,
        eval_timing.vm_run_ns,
        eval_total_ns,
        job_drain_ns,
        context_destroy_ns,
        runtime_destroy_ns,
        compiles,
        top_level_executions,
        memory_usage,
        peak_rss_bytes,
        clock_monotonic_resolution_ns,
        samples,
        stats,
    );
    try stdout_writer.interface.flush();

    if (options.teardown_mode == .normal) {
        std.process.exit(0);
    }
}

fn parseArgs(minimal_args: std.process.Args) Options {
    var args = std.process.Args.Iterator.init(minimal_args);
    defer args.deinit();
    _ = args.next();

    var case_name: ?[]const u8 = null;
    var source_path: ?[]const u8 = null;
    var iterations: usize = 200;
    var warmup: usize = 20;
    var teardown_mode: TeardownMode = .normal;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--case")) {
            case_name = args.next() orelse fatal("--case requires a value", .{});
        } else if (std.mem.eql(u8, arg, "--source")) {
            source_path = args.next() orelse fatal("--source requires a value", .{});
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            const value = args.next() orelse fatal("--iterations requires a value", .{});
            iterations = parseCount(value, "--iterations", false);
        } else if (std.mem.eql(u8, arg, "--warmup")) {
            const value = args.next() orelse fatal("--warmup requires a value", .{});
            warmup = parseCount(value, "--warmup", true);
        } else if (std.mem.eql(u8, arg, "--teardown")) {
            const value = args.next() orelse fatal("--teardown requires a value", .{});
            teardown_mode = if (std.mem.eql(u8, value, "normal"))
                .normal
            else if (std.mem.eql(u8, value, "leak-check"))
                .leak_check
            else
                fatal("--teardown must be normal or leak-check", .{});
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            usage();
            std.process.exit(0);
        } else {
            fatal("unknown argument: {s}", .{arg});
        }
    }

    return .{
        .case_name = case_name orelse fatal("--case is required", .{}),
        .source_path = source_path orelse fatal("--source is required", .{}),
        .iterations = iterations,
        .warmup = warmup,
        .teardown_mode = teardown_mode,
    };
}

fn parseCount(text: []const u8, label: []const u8, allow_zero: bool) usize {
    const value = std.fmt.parseInt(usize, text, 10) catch
        fatal("{s} must be an integer", .{label});
    if ((!allow_zero and value == 0) or value > max_iterations) {
        fatal("{s} must be {s} and at most {d}", .{
            label,
            if (allow_zero) "non-negative" else "positive",
            max_iterations,
        });
    }
    return value;
}

fn usage() void {
    std.debug.print(
        "usage: zjs-same-runtime --case NAME --source FILE [--iterations N] [--warmup N] [--teardown normal|leak-check]\n",
        .{},
    );
}

fn engineFatal(
    context: *zjs.JSContext,
    allocator: std.mem.Allocator,
    stage: []const u8,
    err: anyerror,
) noreturn {
    if (context.hasException()) {
        const exception = context.takeException();
        if (context.toOwnedUtf8(exception, allocator)) |message| {
            std.debug.print("error: {s} failed: {s} ({s})\n", .{ stage, message, @errorName(err) });
            allocator.free(message);
        } else |_| {
            std.debug.print("error: {s} failed with exception ({s})\n", .{ stage, @errorName(err) });
        }
        exception.free(context.runtimePtr());
    } else {
        std.debug.print("error: {s} failed: {s}\n", .{ stage, @errorName(err) });
    }
    std.process.exit(1);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ format ++ "\n", args);
    std.process.exit(2);
}

fn lessThanU64(_: void, lhs: u64, rhs: u64) bool {
    return lhs < rhs;
}

fn calculateStats(sorted: []const u64) SampleStats {
    var sum: u128 = 0;
    for (sorted) |sample| sum += sample;
    const midpoint = sorted.len / 2;
    const median = if (sorted.len % 2 == 1)
        sorted[midpoint]
    else
        @as(u64, @intCast((@as(u128, sorted[midpoint - 1]) + sorted[midpoint]) / 2));
    return .{
        .min_ns = sorted[0],
        .p25_ns = interpolatedQuartile(sorted, 1),
        .median_ns = median,
        .p75_ns = interpolatedQuartile(sorted, 3),
        .mean_ns = @intCast(sum / sorted.len),
    };
}

fn interpolatedQuartile(sorted: []const u64, numerator: u128) u64 {
    const scaled = @as(u128, sorted.len - 1) * numerator;
    const lower: usize = @intCast(scaled / 4);
    const remainder = scaled % 4;
    if (remainder == 0) return sorted[lower];
    const weighted =
        @as(u128, sorted[lower]) * (4 - remainder) +
        @as(u128, sorted[lower + 1]) * remainder;
    return @intCast(weighted / 4);
}

fn writeResult(
    output: *std.Io.Writer,
    options: Options,
    source_sha256: []const u8,
    checksum: []const u8,
    runtime_create_ns: u64,
    context_create_ns: u64,
    compile_ns: u64,
    first_execute_ns: u64,
    eval_total_ns: u64,
    job_drain_ns: u64,
    context_destroy_ns: ?u64,
    runtime_destroy_ns: ?u64,
    compiles: usize,
    top_level_executions: usize,
    memory_usage: zjs.RuntimeMemoryUsage,
    peak_rss_bytes: ?u64,
    clock_monotonic_resolution_ns: ?u64,
    samples: []const u64,
    stats: SampleStats,
) !void {
    try output.writeAll("{\n  \"engine\": \"zjs\",\n  \"layer\": \"same-runtime\",\n  \"case\": ");
    try writeJsonString(output, options.case_name);
    try output.writeAll(",\n  \"source_sha256\": ");
    try writeJsonString(output, source_sha256);
    try output.print(
        ",\n  \"compiles\": {d},\n  \"top_level_executions\": {d},\n  \"build\": {{\n    \"mode\": ",
        .{ compiles, top_level_executions },
    );
    try writeJsonString(output, @tagName(builtin.mode));
    try output.print(
        ",\n    \"optimize_mode_enum\": {d}\n  }},\n" ++
            "  \"jsvalue_representation\": {{\n" ++
            "    \"size_bytes\": {d},\n" ++
            "    \"nan_boxing\": {s},\n" ++
            "    \"description\": ",
        .{
            @intFromEnum(builtin.mode),
            @sizeOf(zjs.JSValue),
            if (@sizeOf(zjs.JSValue) == 8) "true" else "false",
        },
    );
    try writeJsonString(
        output,
        if (@sizeOf(zjs.JSValue) == 8) "8-byte NaN-boxed" else "16-byte payload-plus-tag",
    );
    try output.writeAll("\n  },\n  \"clock_monotonic_resolution_ns\": ");
    try writeOptionalU64(output, clock_monotonic_resolution_ns);
    try output.writeAll(",\n  \"teardown_mode\": ");
    try writeJsonString(output, options.teardown_mode.jsonName());
    try output.print(
        ",\n  \"iterations\": {d},\n  \"warmup\": {d},\n  \"result_checksum\": ",
        .{ options.iterations, options.warmup },
    );
    try writeJsonString(output, checksum);
    try output.writeAll(
        ",\n  \"globals_install_note\": \"JSContext.create installs standard globals during context creation; the public API has no separate install step.\",\n" ++
            "  \"phase_definitions\": {\n" ++
            "    \"runtime_create_ns\": \"Create one engine runtime.\",\n" ++
            "    \"context_create_ns\": \"Create one context; includes standard globals when the engine cannot expose them separately.\",\n" ++
            "    \"globals_install_ns\": \"Install standard globals separately when the engine API exposes that boundary; otherwise null.\",\n" ++
            "    \"compile_ns\": \"Internal parse timing only; not cross-engine comparable because zjs excludes contextGlobal and root bytecode function creation.\",\n" ++
            "    \"first_execute_ns\": \"Internal VM-run timing only; not cross-engine comparable because zjs excludes contextGlobal and root bytecode function creation.\",\n" ++
            "    \"eval_total_ns\": \"Outer wall-clock time around the complete context.eval call, including compile, root bytecode function creation, and first top-level execution.\",\n" ++
            "    \"steady_execute\": \"After warmup, each sample times one call to the retained run function; the source is never recompiled.\",\n" ++
            "    \"job_drain_ns\": \"Sum of pending-job drain time immediately after top-level execution and after all run invocations.\",\n" ++
            "    \"context_destroy_ns\": \"Destroy the context only in leak-check mode; null in normal mode.\",\n" ++
            "    \"runtime_destroy_ns\": \"Destroy the runtime only in leak-check mode; null in normal mode.\"\n" ++
            "  },\n" ++
            "  \"phases\": {\n",
    );
    try output.print(
        "    \"runtime_create_ns\": {d},\n" ++
            "    \"context_create_ns\": {d},\n" ++
            "    \"globals_install_ns\": null,\n" ++
            "    \"compile_ns\": {d},\n" ++
            "    \"first_execute_ns\": {d},\n" ++
            "    \"eval_total_ns\": {d},\n" ++
            "    \"job_drain_ns\": {d},\n" ++
            "    \"context_destroy_ns\": ",
        .{ runtime_create_ns, context_create_ns, compile_ns, first_execute_ns, eval_total_ns, job_drain_ns },
    );
    try writeOptionalU64(output, context_destroy_ns);
    try output.writeAll(",\n    \"runtime_destroy_ns\": ");
    try writeOptionalU64(output, runtime_destroy_ns);
    try output.writeAll("\n  },\n  \"steady_execute\": {\n    \"samples_ns\": [");
    for (samples, 0..) |sample, index| {
        if (index != 0) try output.writeAll(", ");
        try output.print("{d}", .{sample});
    }
    try output.print(
        "],\n" ++
            "    \"min_ns\": {d},\n" ++
            "    \"p25_ns\": {d},\n" ++
            "    \"median_ns\": {d},\n" ++
            "    \"p75_ns\": {d},\n" ++
            "    \"mean_ns\": {d}\n" ++
            "  }},\n" ++
            "  \"resources\": {{\n" ++
            "    \"allocation_count\": ",
        .{ stats.min_ns, stats.p25_ns, stats.median_ns, stats.p75_ns, stats.mean_ns },
    );
    if (builtin.mode == .Debug) {
        try output.print("{d}", .{memory_usage.allocation_count});
    } else {
        try output.writeAll("null");
    }
    try output.print(
        ",\n" ++
            "    \"allocation_count_observed\": {d},\n" ++
            "    \"allocation_count_reason\": ",
        .{memory_usage.allocation_count},
    );
    if (builtin.mode == .Debug) {
        try output.writeAll("null");
    } else {
        try writeJsonString(output, "zjs MemoryAccount diagnostic allocation counters are disabled outside Debug builds");
    }
    try output.print(
        ",\n" ++
            "    \"allocated_bytes\": {d},\n" ++
            "    \"peak_allocated_bytes\": ",
        .{memory_usage.allocated_bytes},
    );
    if (builtin.mode == .Debug) {
        try output.print("{d}", .{memory_usage.peak_allocated_bytes});
    } else {
        try output.writeAll("null");
    }
    try output.writeAll(
        ",\n" ++
            "    \"alloc_calls\": ",
    );
    if (builtin.mode == .Debug) {
        try output.print("{d}", .{memory_usage.alloc_calls});
    } else {
        try output.writeAll("null");
    }
    try output.writeAll(",\n    \"free_calls\": ");
    if (builtin.mode == .Debug) {
        try output.print("{d}", .{memory_usage.free_calls});
    } else {
        try output.writeAll("null");
    }
    try output.writeAll(
        ",\n" ++
            "    \"allocation_source\": \"JSRuntime.memoryUsage()\",\n" ++
            "    \"peak_rss_bytes\": ",
    );
    try writeOptionalU64(output, peak_rss_bytes);
    try output.writeAll(
        ",\n    \"peak_rss_source\": \"getrusage(RUSAGE_SELF).ru_maxrss (Linux KiB)\"\n" ++
            "  }\n" ++
            "}\n",
    );
}

fn writeOptionalU64(output: *std.Io.Writer, value: ?u64) !void {
    if (value) |number| {
        try output.print("{d}", .{number});
    } else {
        try output.writeAll("null");
    }
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

fn elapsedNanosSince(start: u64) u64 {
    const end = monotonicNanos();
    return if (end > start) end - start else 0;
}

fn monotonicNanos() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn monotonicResolutionNanos() ?u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_getres(.MONOTONIC, &ts) != 0) return null;
    if (ts.sec < 0 or ts.nsec < 0) return null;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn peakRssBytes() ?u64 {
    const resource_usage = std.posix.getrusage(std.posix.rusage.SELF);
    if (resource_usage.maxrss < 0) return null;
    const value_kib: u64 = @intCast(resource_usage.maxrss);
    if (value_kib > std.math.maxInt(u64) / 1024) return null;
    return value_kib * 1024;
}

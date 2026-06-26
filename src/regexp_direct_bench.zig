const std = @import("std");
const regexp = @import("libs/regexp.zig");

const max_cases_file_size = 128 * 1024 * 1024;

const Config = struct {
    compile_iterations: usize = 100,
    exec_iterations: usize = 1_000,
    warmup: usize = 20,
    include_zig_api_phases: bool = false,
};

const InputData = union(enum) {
    latin1: []u8,
    utf16: []u16,

    fn deinit(self: InputData, allocator: std.mem.Allocator) void {
        switch (self) {
            .latin1 => |bytes| allocator.free(bytes),
            .utf16 => |units| allocator.free(units),
        }
    }

    fn asRegexpInput(self: InputData) regexp.engine.Input {
        return switch (self) {
            .latin1 => |bytes| .{ .latin1 = bytes },
            .utf16 => |units| .{ .utf16 = units },
        };
    }
};

const Case = struct {
    name: []u8,
    flags: []u8,
    pattern: []u8,
    input: InputData,

    fn deinit(self: *Case, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.flags);
        allocator.free(self.pattern);
        self.input.deinit(allocator);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    defer args.deinit();
    _ = args.next();

    const cases_path = args.next() orelse return error.InvalidArgs;
    const config = Config{
        .compile_iterations = if (args.next()) |arg| try std.fmt.parseUnsigned(usize, arg, 10) else 100,
        .exec_iterations = if (args.next()) |arg| try std.fmt.parseUnsigned(usize, arg, 10) else 1_000,
        .warmup = if (args.next()) |arg| try std.fmt.parseUnsigned(usize, arg, 10) else 20,
        .include_zig_api_phases = if (args.next()) |arg| try parseBoolArg(arg) else false,
    };
    if (args.next() != null) return error.InvalidArgs;

    const cases = try loadCases(allocator, init.io, cases_path);
    defer {
        for (cases) |*case| case.deinit(allocator);
        allocator.free(cases);
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll("engine,case,phase,iterations,nanoseconds,matches\n");
    for (cases) |case| {
        try runCase(allocator, stdout, case, config);
    }
    try stdout.flush();
}

fn runCase(allocator: std.mem.Allocator, out: *std.Io.Writer, case: Case, config: Config) !void {
    try runCompilePhase(allocator, out, case, config);
    try runExecSlotsPhase(allocator, out, case, config, "exec");
    if (config.include_zig_api_phases) {
        try runExecApiPhase(allocator, out, case, config);
        try runExecIntoPhase(allocator, out, case, config);
        try runTestPhase(allocator, out, case, config);
    }
}

fn runCompilePhase(allocator: std.mem.Allocator, out: *std.Io.Writer, case: Case, config: Config) !void {
    const warmup_iterations = @min(config.warmup, config.compile_iterations);
    var warmup: usize = 0;
    while (warmup < warmup_iterations) : (warmup += 1) {
        const bytecode = try regexp.engine.compile(allocator, case.pattern, case.flags);
        allocator.free(bytecode);
    }

    const start = monotonicNanos();
    var i: usize = 0;
    while (i < config.compile_iterations) : (i += 1) {
        const bytecode = try regexp.engine.compile(allocator, case.pattern, case.flags);
        allocator.free(bytecode);
    }
    const elapsed = elapsedNanosSince(start);

    try out.print("zjs-regexp-facade,{s},compile,{d},{d},0\n", .{ case.name, config.compile_iterations, elapsed });
}

fn runExecApiPhase(allocator: std.mem.Allocator, out: *std.Io.Writer, case: Case, config: Config) !void {
    const bytecode = try regexp.engine.compile(allocator, case.pattern, case.flags);
    defer allocator.free(bytecode);
    const input = case.input.asRegexpInput();

    var warmup: usize = 0;
    while (warmup < config.warmup) : (warmup += 1) {
        const status = try regexp.engine.exec(allocator, bytecode, input, 0);
        _ = status;
    }

    const start = monotonicNanos();
    var matches: usize = 0;
    var i: usize = 0;
    while (i < config.exec_iterations) : (i += 1) {
        const status = try regexp.engine.exec(allocator, bytecode, input, 0);
        if (status.result == .match) matches += 1;
    }
    const elapsed = elapsedNanosSince(start);

    try out.print("zjs-regexp-facade,{s},exec_api,{d},{d},{d}\n", .{ case.name, config.exec_iterations, elapsed, matches });
}

fn runExecIntoPhase(allocator: std.mem.Allocator, out: *std.Io.Writer, case: Case, config: Config) !void {
    const bytecode = try regexp.engine.compile(allocator, case.pattern, case.flags);
    defer allocator.free(bytecode);
    const input = case.input.asRegexpInput();

    var match: regexp.engine.Match = undefined;
    var warmup: usize = 0;
    while (warmup < config.warmup) : (warmup += 1) {
        _ = try regexp.engine.execIntoMatch(allocator, bytecode, input, 0, &match);
    }

    const start = monotonicNanos();
    var matches: usize = 0;
    var i: usize = 0;
    while (i < config.exec_iterations) : (i += 1) {
        if (try regexp.engine.execIntoMatch(allocator, bytecode, input, 0, &match) == .match) matches += 1;
    }
    const elapsed = elapsedNanosSince(start);

    try out.print("zjs-regexp-facade,{s},exec_into,{d},{d},{d}\n", .{ case.name, config.exec_iterations, elapsed, matches });
}

fn runExecSlotsPhase(allocator: std.mem.Allocator, out: *std.Io.Writer, case: Case, config: Config, phase_name: []const u8) !void {
    const bytecode = try regexp.engine.compile(allocator, case.pattern, case.flags);
    defer allocator.free(bytecode);
    const input = case.input.asRegexpInput();
    const alloc_count = regexp.engine.allocCount(bytecode);
    var inline_capture_slots: [regexp.engine.small_exec_slots]usize = undefined;
    var heap_capture_slots: []usize = &.{};
    defer if (heap_capture_slots.len != 0) allocator.free(heap_capture_slots);
    const capture_slots = if (alloc_count <= inline_capture_slots.len)
        inline_capture_slots[0..alloc_count]
    else capture: {
        heap_capture_slots = try allocator.alloc(usize, alloc_count);
        break :capture heap_capture_slots;
    };

    var warmup: usize = 0;
    while (warmup < config.warmup) : (warmup += 1) {
        _ = try regexp.engine.execCaptureSlotsSliceTrustedWithOptions(allocator, bytecode, input, 0, .{}, capture_slots);
    }

    const start = monotonicNanos();
    var matches: usize = 0;
    var i: usize = 0;
    while (i < config.exec_iterations) : (i += 1) {
        if (try regexp.engine.execCaptureSlotsSliceTrustedWithOptions(allocator, bytecode, input, 0, .{}, capture_slots) == .match) matches += 1;
    }
    const elapsed = elapsedNanosSince(start);

    try out.print("zjs-regexp-facade,{s},{s},{d},{d},{d}\n", .{ case.name, phase_name, config.exec_iterations, elapsed, matches });
}

fn runTestPhase(allocator: std.mem.Allocator, out: *std.Io.Writer, case: Case, config: Config) !void {
    const bytecode = try regexp.engine.compile(allocator, case.pattern, case.flags);
    defer allocator.free(bytecode);
    const input = case.input.asRegexpInput();

    var warmup: usize = 0;
    while (warmup < config.warmup) : (warmup += 1) {
        _ = try regexp.engine.testMatch(allocator, bytecode, input, 0);
    }

    const start = monotonicNanos();
    var matches: usize = 0;
    var i: usize = 0;
    while (i < config.exec_iterations) : (i += 1) {
        if (try regexp.engine.testMatch(allocator, bytecode, input, 0)) matches += 1;
    }
    const elapsed = elapsedNanosSince(start);

    try out.print("zjs-regexp-facade,{s},test,{d},{d},{d}\n", .{ case.name, config.exec_iterations, elapsed, matches });
}

fn loadCases(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]Case {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_cases_file_size));
    defer allocator.free(bytes);

    var cases = std.ArrayList(Case).empty;
    errdefer {
        for (cases.items) |*case| case.deinit(allocator);
        cases.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw_line| {
        line_no += 1;
        const line = std.mem.trim(u8, raw_line, "\r");
        if (line.len == 0 or line[0] == '#') continue;

        var case = parseCaseLine(allocator, line) catch |err| {
            std.debug.print("invalid regexp direct case at {s}:{d}: {s}\n", .{ path, line_no, @errorName(err) });
            return err;
        };
        errdefer case.deinit(allocator);
        try cases.append(allocator, case);
    }

    return cases.toOwnedSlice(allocator);
}

fn parseCaseLine(allocator: std.mem.Allocator, line: []const u8) !Case {
    var fields: [5][]const u8 = undefined;
    try splitTabs(line, &fields);

    const name = try allocator.dupe(u8, fields[0]);
    errdefer allocator.free(name);
    const flags = try allocator.dupe(u8, fields[1]);
    errdefer allocator.free(flags);
    const pattern = try decodeHexBytes(allocator, fields[2]);
    errdefer allocator.free(pattern);
    const input = try decodeInput(allocator, fields[3], fields[4]);
    errdefer input.deinit(allocator);

    return .{
        .name = name,
        .flags = flags,
        .pattern = pattern,
        .input = input,
    };
}

fn splitTabs(line: []const u8, fields: *[5][]const u8) !void {
    var start: usize = 0;
    var count: usize = 0;
    for (line, 0..) |byte, index| {
        if (byte != '\t') continue;
        if (count >= fields.len) return error.InvalidCaseFile;
        fields[count] = line[start..index];
        count += 1;
        start = index + 1;
    }
    if (count >= fields.len) return error.InvalidCaseFile;
    fields[count] = line[start..];
    count += 1;
    if (count != fields.len) return error.InvalidCaseFile;
}

fn decodeInput(allocator: std.mem.Allocator, kind: []const u8, hex: []const u8) !InputData {
    if (std.mem.eql(u8, kind, "latin1")) {
        return .{ .latin1 = try decodeHexBytes(allocator, hex) };
    }
    if (std.mem.eql(u8, kind, "utf16le")) {
        return .{ .utf16 = try decodeHexUtf16Le(allocator, hex) };
    }
    return error.InvalidCaseFile;
}

fn decodeHexBytes(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    if ((hex.len & 1) != 0) return error.InvalidCaseFile;
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const hi = try hexNibble(hex[i * 2]);
        const lo = try hexNibble(hex[i * 2 + 1]);
        out[i] = (hi << 4) | lo;
    }
    return out;
}

fn decodeHexUtf16Le(allocator: std.mem.Allocator, hex: []const u8) ![]u16 {
    if ((hex.len % 4) != 0) return error.InvalidCaseFile;
    const out = try allocator.alloc(u16, hex.len / 4);
    errdefer allocator.free(out);
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const lo_hi = try hexNibble(hex[i * 4]);
        const lo_lo = try hexNibble(hex[i * 4 + 1]);
        const hi_hi = try hexNibble(hex[i * 4 + 2]);
        const hi_lo = try hexNibble(hex[i * 4 + 3]);
        const lo_byte: u16 = (@as(u16, lo_hi) << 4) | lo_lo;
        const hi_byte: u16 = (@as(u16, hi_hi) << 4) | hi_lo;
        out[i] = lo_byte | (hi_byte << 8);
    }
    return out;
}

fn hexNibble(byte: u8) !u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => error.InvalidCaseFile,
    };
}

fn parseBoolArg(arg: []const u8) !bool {
    if (std.mem.eql(u8, arg, "1") or std.mem.eql(u8, arg, "true")) return true;
    if (std.mem.eql(u8, arg, "0") or std.mem.eql(u8, arg, "false")) return false;
    return error.InvalidArgs;
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

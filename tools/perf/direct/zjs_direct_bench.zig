const std = @import("std");
// Dossier variant identity. The A/B/C attribution candidates differ only by
// this comptime option, and every artifact must be able to say which one
// produced its numbers. It is read here rather than exposed through the zjs
// CLI on purpose: adding a code path to the CLI perturbs the very binary the
// process layer measures (21 symbols changed instruction counts in the
// rejected --build-info approach), whereas the harness writes it once, outside
// any timed window.
const dossier_build_options = @import("dossier_options");
const dossier_variant = dossier_build_options.zjs_dossier_simple_ctor;
const dossier_bypass = !std.mem.eql(u8, dossier_variant, "c");
const dossier_memo = std.mem.eql(u8, dossier_variant, "a");

const builtin = @import("builtin");
const zjs = @import("zjs");

const core = zjs.core;
const bigint = zjs.libs.bigint;
const number_format = zjs.libs.number_format;
const regexp = zjs.libs.regexp;

const hash_offset: u64 = 0xcbf29ce484222325;
const hash_prime: u64 = 0x100000001b3;
const allocation_count_enabled = builtin.is_test or builtin.mode == .Debug;
const allocation_count_unavailable_reason =
    "zjs MemoryAccount.allocation_count is compiled out unless builtin.is_test or Debug (src/core/memory.zig:5); ReleaseFast harness cannot count allocations";

const MemoryObservation = struct {
    allocation_count_before: usize,
    allocation_count_after: usize,
    allocated_bytes_before: usize,
    allocated_bytes_after: usize,
};

const BenchResult = struct {
    category: []const u8,
    case_name: []const u8,
    iterations: usize,
    warmup: usize,
    ns_total: u64,
    checksum: u64,
    fidelity: []const u8,
    entry: []const u8,
    comparable: bool,
    checksum_comparable: bool,
    caliber_note: []const u8,
    memory: ?MemoryObservation,
    allocations_reason: ?[]const u8,
};

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    defer args.deinit();
    _ = args.next();

    const case_name = args.next() orelse return usage();
    const iterations = try parsePositive(args.next() orelse return usage());
    const warmup = try parseNonNegative(args.next() orelse return usage());
    if (args.next() != null) return usage();

    const result = if (std.mem.eql(u8, case_name, "dtoa/mixed-free"))
        runDtoa(iterations, warmup)
    else if (std.mem.eql(u8, case_name, "regexp/exec-latin1"))
        try runRegexp(init.gpa, iterations, warmup)
    else if (std.mem.eql(u8, case_name, "property_lookup/own-data"))
        try runPropertyLookup(init.gpa, iterations, warmup)
    else if (std.mem.eql(u8, case_name, "typed_array/int32-get"))
        try runTypedArray(init.gpa, iterations, warmup)
    else if (std.mem.eql(u8, case_name, "bigint/mul-multilimb"))
        try runBigInt(init.gpa, iterations, warmup)
    else
        return usage();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try emitResult(stdout, result, readPeakRssKb(init.io));
    try stdout.flush();
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        "usage: zjs-direct-bench <category/case> <iterations> <warmup>\n",
        .{},
    );
    return error.InvalidArguments;
}

fn parsePositive(text: []const u8) !usize {
    const value = try std.fmt.parseUnsigned(usize, text, 10);
    if (value == 0) return error.InvalidArguments;
    return value;
}

fn parseNonNegative(text: []const u8) !usize {
    return std.fmt.parseUnsigned(usize, text, 10);
}

fn emitResult(out: *std.Io.Writer, result: BenchResult, peak_rss_kb: ?u64) !void {
    const ns_per_op = @as(f64, @floatFromInt(result.ns_total)) /
        @as(f64, @floatFromInt(result.iterations));
    try out.print(
        "{{\"category\":\"{s}\",\"case\":\"{s}\",\"engine\":\"zjs\",\"dossier_variant\":\"" ++ dossier_variant ++ "\",\"iterations\":{d},\"warmup\":{d},\"ns_total\":{d},\"ns_per_op\":{d:.6},\"checksum\":\"{x:0>16}\",\"fidelity\":\"{s}\",\"entry\":\"{s}\",\"comparable\":{},\"checksum_comparable\":{},\"caliber_note\":\"{s}\"",
        .{
            result.category,
            result.case_name,
            result.iterations,
            result.warmup,
            result.ns_total,
            ns_per_op,
            result.checksum,
            result.fidelity,
            result.entry,
            result.comparable,
            result.checksum_comparable,
            result.caliber_note,
        },
    );
    if (result.memory) |memory| {
        if (comptime allocation_count_enabled) {
            try out.print(
                ",\"allocation_count_before\":{d},\"allocation_count_after\":{d},\"allocation_count_reason\":null",
                .{
                    memory.allocation_count_before,
                    memory.allocation_count_after,
                },
            );
        } else {
            try out.print(
                ",\"allocation_count_before\":null,\"allocation_count_after\":null,\"allocation_count_reason\":\"{s}\"",
                .{allocation_count_unavailable_reason},
            );
        }
        try out.print(
            ",\"allocated_bytes_before\":{d},\"allocated_bytes_after\":{d},\"allocations_reason\":null",
            .{
                memory.allocated_bytes_before,
                memory.allocated_bytes_after,
            },
        );
    } else {
        try out.print(
            ",\"allocation_count_before\":null,\"allocation_count_after\":null,\"allocated_bytes_before\":null,\"allocated_bytes_after\":null,\"allocations_reason\":\"{s}\"",
            .{result.allocations_reason orelse "runtime allocation counters unavailable"},
        );
    }
    if (peak_rss_kb) |rss| {
        try out.print(",\"peak_rss_kb\":{d},\"peak_rss_reason\":null", .{rss});
    } else {
        try out.writeAll(
            ",\"peak_rss_kb\":null,\"peak_rss_reason\":\"unable to read /proc/self/status VmHWM\"",
        );
    }
    try out.print(
        ",\"jsvalue_size_bytes\":{d}}}\n",
        .{@sizeOf(core.JSValue)},
    );
}

fn readPeakRssKb(io: std.Io) ?u64 {
    const file = std.Io.Dir.cwd().openFile(io, "/proc/self/status", .{}) catch return null;
    defer file.close(io);
    var buffer: [16 * 1024]u8 = undefined;
    const len = file.readPositionalAll(io, &buffer, 0) catch return null;
    var lines = std.mem.splitScalar(u8, buffer[0..len], '\n');
    while (lines.next()) |line| {
        const prefix = "VmHWM:";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const rest = std.mem.trim(u8, line[prefix.len..], " \t");
        const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        return std.fmt.parseUnsigned(u64, rest[0..end], 10) catch null;
    }
    return null;
}

fn runDtoa(iterations: usize, warmup: usize) BenchResult {
    const warmup_checksum = dtoaLoop(warmup, hash_offset);
    const start = monotonicNanos();
    const checksum = dtoaLoop(iterations, warmup_checksum);
    const elapsed = elapsedNanosSince(start);
    return .{
        .category = "dtoa",
        .case_name = "mixed-free",
        .iterations = iterations,
        .warmup = warmup,
        .ns_total = elapsed,
        .checksum = checksum,
        .fidelity = "true-direct",
        .entry = "libs/number_format.formatDtoa",
        .comparable = true,
        .checksum_comparable = true,
        .caliber_note = "radix-10 free format; stack buffer and dtoa temp state are inside each kernel call",
        .memory = null,
        .allocations_reason = "no zjs JSRuntime exists for the dtoa kernel",
    };
}

fn dtoaLoop(iterations: usize, initial_checksum: u64) u64 {
    const values = [_]f64{
        0.0,
        -0.0,
        1.0,
        12.5,
        1.0 / 3.0,
        1.2345678901234567,
        1.0e-7,
        1.0e21,
        -9.87654321012345e-120,
    };
    var checksum = initial_checksum;
    var buffer: [128]u8 = undefined;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const index: usize = @intCast(
            (checksum ^ @as(u64, @intCast(i))) % @as(u64, values.len),
        );
        const text = number_format.formatDtoa(
            &buffer,
            values[index],
            0,
            number_format.JS_DTOA_FORMAT_FREE | number_format.JS_DTOA_EXP_AUTO,
        );
        checksum = mixBytes(checksum, text);
        checksum = mixByte(checksum, 0xff);
    }
    return checksum;
}

fn runRegexp(allocator: std.mem.Allocator, iterations: usize, warmup: usize) !BenchResult {
    const pattern = "^(?:foo|bar)+[0-9]{2}$";
    const input_bytes = "foobarfoo42";
    const bytecode = try regexp.compile(allocator, pattern, "");
    defer allocator.free(bytecode);

    const alloc_count = regexp.allocCount(bytecode);
    if (alloc_count > regexp.small_exec_slots) return error.RegexpCaptureSlotsTooLarge;
    var capture_storage: [regexp.small_exec_slots]usize = undefined;
    const capture_slots = capture_storage[0..alloc_count];
    const capture_count = regexp.captureCount(bytecode);

    const warmup_checksum = try regexpLoop(
        allocator,
        bytecode,
        .{ .latin1 = input_bytes },
        capture_slots,
        capture_count,
        warmup,
        hash_offset,
    );
    const start = monotonicNanos();
    const checksum = try regexpLoop(
        allocator,
        bytecode,
        .{ .latin1 = input_bytes },
        capture_slots,
        capture_count,
        iterations,
        warmup_checksum,
    );
    const elapsed = elapsedNanosSince(start);
    return .{
        .category = "regexp",
        .case_name = "exec-latin1",
        .iterations = iterations,
        .warmup = warmup,
        .ns_total = elapsed,
        .checksum = checksum,
        .fidelity = "true-direct",
        .entry = "libs/regexp.execCaptureSlotsSliceTrustedWithOptions",
        .comparable = true,
        .checksum_comparable = true,
        .caliber_note = "compile and capture-slot allocation excluded; timed region executes compiled latin1 regexp",
        .memory = null,
        .allocations_reason = "regexp kernel uses the caller allocator without a JSRuntime memoryUsage counter",
    };
}

fn regexpLoop(
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    input: regexp.Input,
    capture_slots: []usize,
    capture_count: usize,
    iterations: usize,
    initial_checksum: u64,
) !u64 {
    var checksum = initial_checksum;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const result = try regexp.execCaptureSlotsSliceTrustedWithOptions(
            allocator,
            bytecode,
            input,
            0,
            .{},
            capture_slots,
        );
        checksum = mixU64(checksum, if (result == .match) 1 else 0);
        if (result == .match) {
            for (capture_slots[0 .. capture_count * 2]) |slot| {
                checksum = mixU64(checksum, slot);
            }
        }
    }
    return checksum;
}

fn runPropertyLookup(allocator: std.mem.Allocator, iterations: usize, warmup: usize) !BenchResult {
    const rt = try core.JSRuntime.create(allocator);
    defer rt.destroy();
    const object = try core.Object.create(rt, core.class.ids.object, null);
    defer object.value().free(rt);

    const names = [_][]const u8{ "p0", "p1", "p2", "p3" };
    const values = [_]i32{ 11, 23, 37, 53 };
    var atoms: [names.len]core.Atom = undefined;
    for (names, 0..) |name, index| {
        atoms[index] = try rt.internAtom(name);
    }
    defer for (atoms) |atom_id| rt.atoms.free(atom_id);
    for (atoms, values) |atom_id, value| {
        try object.defineOwnProperty(
            rt,
            atom_id,
            core.Descriptor.data(core.JSValue.int32(value), true, true, true),
        );
    }

    const warmup_checksum = try propertyLookupLoop(rt, object, &atoms, warmup, hash_offset);
    const memory_before = rt.memoryUsage();
    const start = monotonicNanos();
    const checksum = try propertyLookupLoop(rt, object, &atoms, iterations, warmup_checksum);
    const elapsed = elapsedNanosSince(start);
    const memory_after = rt.memoryUsage();
    return .{
        .category = "property_lookup",
        .case_name = "own-data",
        .iterations = iterations,
        .warmup = warmup,
        .ns_total = elapsed,
        .checksum = checksum,
        .fidelity = "true-direct",
        .entry = "core.Object.getProperty",
        .comparable = true,
        .checksum_comparable = true,
        .caliber_note = "runtime object atom and properties built before timing; returned JSValue dup and free are timed",
        .memory = .{
            .allocation_count_before = memory_before.allocation_count,
            .allocation_count_after = memory_after.allocation_count,
            .allocated_bytes_before = memory_before.allocated_bytes,
            .allocated_bytes_after = memory_after.allocated_bytes,
        },
        .allocations_reason = null,
    };
}

fn propertyLookupLoop(
    rt: *core.JSRuntime,
    object: *core.Object,
    atoms: *const [4]core.Atom,
    iterations: usize,
    initial_checksum: u64,
) !u64 {
    var checksum = initial_checksum;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const index: usize = @intCast(
            (checksum ^ @as(u64, @intCast(i))) & 3,
        );
        const value = try object.getProperty(atoms[index]);
        const int_value = value.asInt32() orelse {
            value.free(rt);
            return error.UnexpectedPropertyValue;
        };
        checksum = mixU64(checksum, @as(u32, @bitCast(int_value)));
        value.free(rt);
    }
    return checksum;
}

fn runTypedArray(allocator: std.mem.Allocator, iterations: usize, warmup: usize) !BenchResult {
    const rt = try core.JSRuntime.create(allocator);
    defer rt.destroy();

    const buffer_value = try core.typed_array.createArrayBuffer(rt, 1024 * 4, null);
    defer buffer_value.free(rt);
    const buffer: *core.Object = @fieldParentPtr(
        "header",
        buffer_value.refHeader() orelse return error.ExpectedArrayBufferObject,
    );
    const view_value = try core.typed_array.typedArrayConstructFullBuffer(
        rt,
        4,
        6,
        buffer_value,
        buffer,
        null,
    );
    defer view_value.free(rt);
    const view: *core.Object = @fieldParentPtr(
        "header",
        view_value.refHeader() orelse return error.ExpectedTypedArrayObject,
    );
    const backing = buffer.byteStorage();
    var index: u32 = 0;
    while (index < 1024) : (index += 1) {
        const value: u32 = index * 3 + 7;
        const offset: usize = @as(usize, index) * 4;
        backing[offset] = @truncate(value);
        backing[offset + 1] = @truncate(value >> 8);
        backing[offset + 2] = @truncate(value >> 16);
        backing[offset + 3] = @truncate(value >> 24);
    }

    const warmup_checksum = try typedArrayLoop(rt, view, warmup, hash_offset);
    const memory_before = rt.memoryUsage();
    const start = monotonicNanos();
    const checksum = try typedArrayLoop(rt, view, iterations, warmup_checksum);
    const elapsed = elapsedNanosSince(start);
    const memory_after = rt.memoryUsage();
    return .{
        .category = "typed_array",
        .case_name = "int32-get",
        .iterations = iterations,
        .warmup = warmup,
        .ns_total = elapsed,
        .checksum = checksum,
        .fidelity = "true-direct",
        .entry = "core.typed_array.typedArrayGetIndex",
        .comparable = false,
        .checksum_comparable = true,
        .caliber_note = "direct Int32Array kernel read; QJS side uses exported property API so no headline ratio",
        .memory = .{
            .allocation_count_before = memory_before.allocation_count,
            .allocation_count_after = memory_after.allocation_count,
            .allocated_bytes_before = memory_before.allocated_bytes,
            .allocated_bytes_after = memory_after.allocated_bytes,
        },
        .allocations_reason = null,
    };
}

fn typedArrayLoop(
    rt: *core.JSRuntime,
    view: *core.Object,
    iterations: usize,
    initial_checksum: u64,
) !u64 {
    var checksum = initial_checksum;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const index: u32 = @intCast(
            (checksum ^ @as(u64, @intCast(i))) & 1023,
        );
        const value = try core.typed_array.typedArrayGetIndex(rt, view, index);
        const int_value = value.asInt32() orelse {
            value.free(rt);
            return error.UnexpectedTypedArrayValue;
        };
        checksum = mixU64(checksum, @as(u32, @bitCast(int_value)));
        value.free(rt);
    }
    return checksum;
}

fn runBigInt(allocator: std.mem.Allocator, iterations: usize, warmup: usize) !BenchResult {
    var lhs = try bigint.parseBase10Alloc(
        allocator,
        "123456789012345678901234567890123456789",
    );
    defer lhs.deinit();
    var rhs = try bigint.parseBase10Alloc(
        allocator,
        "98765432109876543210987654321",
    );
    defer rhs.deinit();

    const warmup_checksum = try bigIntLoop(allocator, lhs, rhs, warmup, hash_offset);
    const start = monotonicNanos();
    const checksum = try bigIntLoop(allocator, lhs, rhs, iterations, warmup_checksum);
    const elapsed = elapsedNanosSince(start);
    return .{
        .category = "bigint",
        .case_name = "mul-multilimb",
        .iterations = iterations,
        .warmup = warmup,
        .ns_total = elapsed,
        .checksum = checksum,
        .fidelity = "true-direct",
        .entry = "libs/bigint.mulAlloc",
        .comparable = true,
        .checksum_comparable = true,
        .caliber_note = "operands parsed before timing; direct result allocation multiplication low-limb consume and deinit are timed",
        .memory = null,
        .allocations_reason = "BigInt kernel uses the caller allocator without a JSRuntime memoryUsage counter",
    };
}

fn bigIntLoop(
    allocator: std.mem.Allocator,
    lhs: bigint.BigInt,
    rhs: bigint.BigInt,
    iterations: usize,
    initial_checksum: u64,
) !u64 {
    var checksum = initial_checksum;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var product = if (((checksum ^ @as(u64, @intCast(i))) & 1) == 0)
            try bigint.mulAlloc(allocator, lhs, rhs)
        else
            try bigint.mulAlloc(allocator, rhs, lhs);
        const low_limb = if (product.limbs.len == 0) 0 else product.limbs[0];
        checksum = mixU64(checksum, low_limb);
        product.deinit();
    }
    return checksum;
}

fn mixBytes(initial: u64, bytes: []const u8) u64 {
    var checksum = initial;
    for (bytes) |byte| checksum = mixByte(checksum, byte);
    return checksum;
}

fn mixU64(initial: u64, value: u64) u64 {
    var checksum = initial;
    var remaining = value;
    var byte_index: usize = 0;
    while (byte_index < 8) : (byte_index += 1) {
        checksum = mixByte(checksum, @truncate(remaining));
        remaining >>= 8;
    }
    return checksum;
}

fn mixByte(checksum: u64, byte: u8) u64 {
    return (checksum ^ byte) *% hash_prime;
}

fn elapsedNanosSince(start: u64) u64 {
    const end = monotonicNanos();
    return if (end > start) end - start else 0;
}

fn monotonicNanos() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(ts.nsec));
}

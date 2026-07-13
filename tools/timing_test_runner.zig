const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const runner_threaded_io: Io = Io.Threaded.global_single_threaded.io();

pub fn main(init: std.process.Init.Minimal) !void {
    const test_fns = builtin.test_functions;
    var args = std.process.Args.Iterator.init(init.args);
    defer args.deinit();
    _ = args.skip();
    var filter: ?[]const u8 = null;
    var start_index: usize = 0;
    var end_index: usize = test_fns.len;
    var fail_fast = false;
    var list_only = false;
    var require_tests = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--list")) {
            list_only = true;
        } else if (std.mem.eql(u8, arg, "--require-tests")) {
            require_tests = true;
        } else if (std.mem.eql(u8, arg, "--fail-fast")) {
            fail_fast = true;
        } else if (std.mem.eql(u8, arg, "--range")) {
            const range_arg = args.next() orelse return error.InvalidArgs;
            const range = try parseRange(range_arg, test_fns.len);
            start_index = range.start;
            end_index = range.end;
        } else if (filter == null) {
            filter = arg;
        } else {
            return error.InvalidArgs;
        }
    }

    if (list_only) {
        for (test_fns, 0..) |test_fn, index| {
            std.debug.print("{}: {s}\n", .{ index, test_fn.name });
        }
        return;
    }

    std.debug.print("Running {} tests with timing", .{test_fns.len});
    if (filter) |pattern| std.debug.print(" matching \"{s}\"", .{pattern});
    if (start_index != 0 or end_index != test_fns.len) std.debug.print(" in range {}..{}", .{ start_index, end_index });
    std.debug.print("...\n", .{});

    const allocator = std.heap.page_allocator;

    const Entry = struct {
        name: []const u8,
        duration_ns: u64,
    };

    var timings = std.ArrayList(Entry).empty;
    defer timings.deinit(allocator);

    var ok_count: usize = 0;
    var fail_count: usize = 0;
    var skip_count: usize = 0;
    var filtered_count: usize = 0;

    for (test_fns, 0..) |test_fn, test_index| {
        if (test_index < start_index or test_index >= end_index) {
            filtered_count += 1;
            continue;
        }
        if (filter) |pattern| {
            if (std.mem.indexOf(u8, test_fn.name, pattern) == null) {
                filtered_count += 1;
                continue;
            }
        }

        // Setup testing environment
        std.testing.allocator_instance = .{};
        std.testing.io_instance = .init(std.testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        std.testing.environ = init.environ;
        std.testing.log_level = .warn;

        const start = Io.Clock.awake.now(runner_threaded_io);
        const res = test_fn.func();
        const end = Io.Clock.awake.now(runner_threaded_io);

        const duration = @as(u64, @intCast(start.durationTo(end).toNanoseconds()));

        if (res) |_| {
            ok_count += 1;
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip_count += 1;
            },
            else => {
                fail_count += 1;
                std.debug.print("FAIL: {s} ({s})\n", .{ test_fn.name, @errorName(err) });
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpErrorReturnTrace(trace);
                }
                if (fail_fast) break;
            },
        }

        std.testing.io_instance.deinit();
        _ = std.testing.allocator_instance.deinit();

        try timings.append(allocator, .{
            .name = test_fn.name,
            .duration_ns = duration,
        });
    }

    // Sort timings in descending order of duration
    const sort_helper = struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return a.duration_ns > b.duration_ns;
        }
    };
    std.sort.block(Entry, timings.items, {}, sort_helper.lessThan);

    std.debug.print("\nTop 20 Slowest Test Cases:\n", .{});
    for (timings.items[0..@min(20, timings.items.len)], 0..) |entry, i| {
        const ms = @as(f64, @floatFromInt(entry.duration_ns)) / 1_000_000.0;
        std.debug.print("{d:2}. {s}: {d:.3} ms\n", .{ i + 1, entry.name, ms });
    }

    std.debug.print("\nSummary: {} passed; {} skipped; {} failed; {} filtered.\n", .{ ok_count, skip_count, fail_count, filtered_count });
    if (require_tests and ok_count + skip_count + fail_count == 0) {
        std.debug.print("FAIL: test selection matched no tests.\n", .{});
        std.process.exit(1);
    }
    if (fail_count > 0) {
        std.process.exit(1);
    }
}

const TestRange = struct {
    start: usize,
    end: usize,
};

fn parseRange(arg: []const u8, max_len: usize) !TestRange {
    const delimiter = std.mem.indexOfScalar(u8, arg, ':') orelse return error.InvalidArgs;
    const start = try std.fmt.parseUnsigned(usize, arg[0..delimiter], 10);
    const end = try std.fmt.parseUnsigned(usize, arg[delimiter + 1 ..], 10);
    if (start > end or end > max_len) return error.InvalidArgs;
    return .{ .start = start, .end = end };
}

const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const runner_threaded_io: Io = Io.Threaded.global_single_threaded.io();

pub fn main(init: std.process.Init.Minimal) !void {
    const test_fns = builtin.test_functions;
    
    std.debug.print("Running {} tests with timing...\n", .{test_fns.len});
    
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
    
    for (test_fns) |test_fn| {
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
                std.debug.print("FAIL: {s} ({s})\n", .{test_fn.name, @errorName(err)});
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpErrorReturnTrace(trace);
                }
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
        std.debug.print("{d:2}. {s}: {d:.3} ms\n", .{i + 1, entry.name, ms});
    }
    
    std.debug.print("\nSummary: {} passed; {} skipped; {} failed.\n", .{ok_count, skip_count, fail_count});
    if (fail_count > 0) {
        std.process.exit(1);
    }
}

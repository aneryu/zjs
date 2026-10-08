//! Test runner for the full unified suite in the gates.
//!
//! Zig's default runner executes one binary's tests on one thread, which made
//! the ~2,200-test suite the longest step of checkpoint-gate. The build graph
//! instead runs this runner as several processes, each taking the tests whose
//! index is congruent to its shard: `ZJS_TEST_SHARD=k/n` (0 <= k < n; unset
//! runs everything). Per test it matches the default runner: a fresh
//! `std.testing` allocator (leaks fail), `SkipZigTest`, and error-level logs
//! fail the run. `ZJS_TEST_SLOWEST=N` prints the N slowest tests of the shard.

const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;

pub const std_options: std.Options = .{
    .logFn = log,
};

var log_err_count: usize = 0;
const clock_io: std.Io = std.Io.Threaded.global_single_threaded.io();

const Shard = struct { index: usize, count: usize };

fn parseShard(raw: ?[*:0]const u8) Shard {
    const text = std.mem.span(raw orelse return .{ .index = 0, .count = 1 });
    const slash = std.mem.indexOfScalar(u8, text, '/') orelse
        std.debug.panic("ZJS_TEST_SHARD must be k/n, got '{s}'", .{text});
    const index = std.fmt.parseUnsigned(usize, text[0..slash], 10) catch
        std.debug.panic("ZJS_TEST_SHARD must be k/n, got '{s}'", .{text});
    const count = std.fmt.parseUnsigned(usize, text[slash + 1 ..], 10) catch
        std.debug.panic("ZJS_TEST_SHARD must be k/n, got '{s}'", .{text});
    if (count == 0 or index >= count) std.debug.panic("ZJS_TEST_SHARD must be k/n with k < n, got '{s}'", .{text});
    return .{ .index = index, .count = count };
}

const Timing = struct { ns: u64, index: usize };

pub fn main(init: std.process.Init.Minimal) void {
    const test_fns = builtin.test_functions;
    const shard = parseShard(std.c.getenv("ZJS_TEST_SHARD"));
    const slowest_wanted: usize = if (std.c.getenv("ZJS_TEST_SLOWEST")) |raw|
        std.fmt.parseUnsigned(usize, std.mem.span(raw), 10) catch 0
    else
        0;
    var slowest: [32]Timing = @splat(.{ .ns = 0, .index = 0 });
    const slowest_len = @min(slowest_wanted, slowest.len);

    var ok_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;
    var leak_count: usize = 0;
    var index = shard.index;
    while (index < test_fns.len) : (index += shard.count) {
        const test_fn = test_fns[index];
        testing.allocator_instance = .{};
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        testing.log_level = .warn;
        testing.environ = init.environ;

        const started = std.Io.Clock.awake.now(clock_io);
        if (test_fn.func()) |_| {
            ok_count += 1;
        } else |err| switch (err) {
            error.SkipZigTest => skip_count += 1,
            else => {
                fail_count += 1;
                std.debug.print("FAIL ({t}): {s}\n", .{ err, test_fn.name });
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            },
        }
        const elapsed = started.durationTo(std.Io.Clock.awake.now(clock_io)).nanoseconds;
        recordTiming(slowest[0..slowest_len], .{ .ns = @intCast(@max(elapsed, 0)), .index = index });

        testing.io_instance.deinit();
        if (testing.allocator_instance.deinit() == .leak) {
            leak_count += 1;
            std.debug.print("LEAK: {s}\n", .{test_fn.name});
        }
    }

    for (slowest[0..slowest_len]) |timing| {
        if (timing.ns == 0) break;
        std.debug.print("slow: {d} ms {s}\n", .{ timing.ns / std.time.ns_per_ms, test_fns[timing.index].name });
    }
    const failed = fail_count != 0 or leak_count != 0 or log_err_count != 0;
    // A passing shard stays silent: the build summary already names it.
    if (failed or slowest_len != 0) {
        std.debug.print("shard {d}/{d}: {d} passed; {d} skipped; {d} failed; {d} leaked; {d} error logs.\n", .{
            shard.index, shard.count, ok_count, skip_count, fail_count, leak_count, log_err_count,
        });
    }
    if (failed) std.process.exit(1);
}

fn recordTiming(slowest: []Timing, timing: Timing) void {
    if (slowest.len == 0 or timing.ns <= slowest[slowest.len - 1].ns) return;
    var i = slowest.len - 1;
    while (i > 0 and slowest[i - 1].ns < timing.ns) : (i -= 1) slowest[i] = slowest[i - 1];
    slowest[i] = timing;
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) log_err_count +|= 1;
    if (@intFromEnum(message_level) <= @intFromEnum(testing.log_level)) {
        std.debug.print("[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n", args);
    }
}

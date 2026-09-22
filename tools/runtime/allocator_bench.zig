//! Reproducible Runtime allocator comparison. Engine GC backing is unchanged.
const std = @import("std");
const zjs = @import("zjs");

const Result = struct { peak_rss: usize = 0, checksum: i64 = 0, failure: ?anyerror = null };
const Work = struct { allocator: std.mem.Allocator, rounds: usize, recreate: bool, result: *Result };
const script =
    \\(() => {
    \\  const values = [];
    \\  for (let i = 0; i < 2000; ++i) values.push({ index: i, text: "item_" + i });
    \\  return values.reduce((sum, item) => sum + item.index, 0);
    \\})()
;
fn sample(result: *Result) void {
    const rss = zjs.core.runtime.process_memory.currentRssBytes() orelse 0;
    result.peak_rss = @max(result.peak_rss, rss);
}
fn run(work: Work) !void {
    const cycles = if (work.recreate) work.rounds else 1;
    for (0..cycles) |_| {
        const rt = try zjs.Runtime.create(.{ .allocator = work.allocator });
        defer rt.destroy();
        const ctx = try zjs.Context.create(rt, .{});
        defer ctx.destroy();
        const repeats = if (work.recreate) 1 else work.rounds;
        for (0..repeats) |_| {
            const value = try ctx.eval(script, .{});
            const answer = value.as(.int) orelse return error.BadResult;
            if (answer != 1999000) return error.BadResult;
            work.result.checksum += answer;
            sample(work.result);
        }
    }
}
fn worker(work: Work) void {
    run(work) catch |err| {
        work.result.failure = err;
    };
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) return error.ExpectedAllocatorScenarioRounds;
    const allocator = if (std.mem.eql(u8, args[1], "c")) std.heap.c_allocator else if (std.mem.eql(u8, args[1], "smp")) std.heap.smp_allocator else return error.BadAllocator;
    const rounds = try std.fmt.parseInt(usize, args[3], 10);
    const parallel = std.mem.eql(u8, args[2], "parallel");
    const recreate = std.mem.eql(u8, args[2], "recreate");
    if (!parallel and !recreate and !std.mem.eql(u8, args[2], "persistent")) return error.BadScenario;
    const before = zjs.core.runtime.process_memory.currentRssBytes() orelse 0;
    const start = std.Io.Clock.Timestamp.now(init.io, .awake).raw.toNanoseconds();
    var results: [4]Result = @splat(.{});
    const count: usize = if (parallel) 4 else 1;
    if (parallel) {
        var threads: [4]std.Thread = undefined;
        var started: usize = 0;
        defer for (threads[0..started]) |thread| thread.join();
        for (&threads, &results) |*thread, *result| {
            thread.* = try std.Thread.spawn(.{}, worker, .{Work{ .allocator = allocator, .rounds = rounds, .recreate = false, .result = result }});
            started += 1;
        }
    } else {
        try run(.{ .allocator = allocator, .rounds = rounds, .recreate = recreate, .result = &results[0] });
    }
    const elapsed = std.Io.Clock.Timestamp.now(init.io, .awake).raw.toNanoseconds() - start;
    const after = zjs.core.runtime.process_memory.currentRssBytes() orelse 0;
    var peak: usize = before;
    var checksum: i64 = 0;
    for (results[0..count]) |result| {
        if (result.failure) |err| return err;
        peak = @max(peak, result.peak_rss);
        checksum += result.checksum;
    }
    std.debug.print("{s},{s},{d},{d},{d},{d},{d},{d}\n", .{ args[1], args[2], rounds, elapsed, before, peak, after, checksum });
}

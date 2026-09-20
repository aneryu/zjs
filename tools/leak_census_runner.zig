//! Test runner used only by `zig build test-leak-census`.
//!
//! Daily `zig build test` uses Zig's default runner. The census needs two
//! in-process passes over the same shared Realm (pass 0 warms lazy state;
//! pass 1 rejects unaccounted retained growth), which the default runner
//! cannot do.

const builtin = @import("builtin");
const std = @import("std");

pub export var zjs_test_runner_current_name_ptr: [*]const u8 = undefined;
pub export var zjs_test_runner_current_name_len: usize = 0;
pub export var zjs_test_runner_current_pass: usize = 0;

pub fn main(init: std.process.Init.Minimal) !void {
    const test_fns = builtin.test_functions;
    const repeat_count: usize = 2;

    zjs_test_runner_current_name_ptr = "".ptr;
    zjs_test_runner_current_name_len = 0;
    zjs_test_runner_current_pass = 0;

    std.debug.print("Running {} tests for {} leak-census passes...\n", .{ test_fns.len, repeat_count });
    std.debug.print("leak-census: pass test count_delta bytes_delta module_count module_delta count bytes\n", .{});

    var ok_count: usize = 0;
    var fail_count: usize = 0;
    var skip_count: usize = 0;

    const invocation_count = std.math.mul(usize, repeat_count, test_fns.len) catch return error.Overflow;
    for (0..invocation_count) |invocation_index| {
        const pass = invocation_index / test_fns.len;
        const test_fn = test_fns[invocation_index % test_fns.len];

        zjs_test_runner_current_name_ptr = test_fn.name.ptr;
        zjs_test_runner_current_name_len = test_fn.name.len;
        zjs_test_runner_current_pass = pass;

        std.testing.allocator_instance = .{};
        std.testing.io_instance = .init(std.testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        std.testing.environ = init.environ;
        std.testing.log_level = .warn;

        const res = test_fn.func();

        var outcome: enum { passed, skipped, failed } = .passed;
        if (res) |_| {
            ok_count += 1;
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip_count += 1;
                outcome = .skipped;
            },
            else => {
                fail_count += 1;
                outcome = .failed;
                std.debug.print("FAIL: {s} ({s})\n", .{ test_fn.name, @errorName(err) });
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpErrorReturnTrace(trace);
                }
            },
        }

        std.testing.io_instance.deinit();
        if (std.testing.allocator_instance.deinit() == .leak) {
            std.debug.print("LEAK: {s}\n", .{test_fn.name});
            switch (outcome) {
                .failed => {},
                .passed => {
                    ok_count -= 1;
                    fail_count += 1;
                },
                .skipped => {
                    skip_count -= 1;
                    fail_count += 1;
                },
            }
        }
    }

    std.debug.print("\nSummary: {} passed; {} skipped; {} failed.\n", .{ ok_count, skip_count, fail_count });
    if (ok_count == 0) {
        std.debug.print("FAIL: leak-census selection matched no tests.\n", .{});
        std.process.exit(1);
    }
    if (fail_count > 0) {
        std.process.exit(1);
    }
}

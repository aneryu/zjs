//! Test runner (explicitly deferred placeholder).
//!
//! See docs/roadmap.md (M7).

pub const TestRunnerError = error{
    TestRunnerNotImplemented,
};

pub fn runAll() TestRunnerError!void {
    return error.TestRunnerNotImplemented;
}

test "test runner is explicit placeholder" {
    const std = @import("std");
    try std.testing.expectError(error.TestRunnerNotImplemented, runAll());
}

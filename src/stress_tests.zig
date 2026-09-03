//! Focused test root for the long-running stress tier (src/tests/stress.zig).
const std = @import("std");
const stress_tests = @import("tests/stress.zig");
// QCP-1: this artifact proves its OWN effective configuration at compile
// time. Like the unified suite -- and unlike the Debug-pinned scoped
// targets -- it follows -Doptimize, so the ReleaseSafe phase-close run
// (`zig build test test-stress -Doptimize=ReleaseSafe`) covers the stress
// tier too.
comptime {
    @import("zjs").config_signature.attest("test-stress");
}

test {
    std.testing.refAllDecls(stress_tests);
}

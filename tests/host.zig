//! Explicit collection of bundled host regression tests in the unified root.
const host = @import("zjs_host");

test "runtime.EventLoop drains queued JS callbacks" {
    try host.testing.event_loop.case0();
}

test "runtime.EventLoop removes timers without allocation" {
    try host.testing.event_loop.case1();
}

test "runtime.EventLoop removes rw handlers without allocation" {
    try host.testing.event_loop.case2();
}

test "runtime.EventLoop removes signal handlers without allocation" {
    try host.testing.event_loop.case3();
}

test "runtime.EventLoop keeps host-held unique symbol atoms until release" {
    try host.testing.event_loop.case4();
}

test "runtime.root tracer visits EventLoop host roots" {
    try host.testing.event_loop.case5();
}

test "runtime.EventLoop roots one-shot function bytecode timer callback after dequeue" {
    try host.testing.event_loop.case6();
}

test "runtime.namespace does not expose internals or kernel primitives" {
    try host.testing.event_loop.case7();
}

test "host lazy factories keep distinct identities and retry failed materialization" {
    try host.testing.output.case0();
}

test "file loader rejects bare dynamic specifiers and owns resolved paths" {
    try host.testing.file_modules.case0();
}

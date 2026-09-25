//! Diagnostic scope for borrowed heap views. This is not a root or a pin:
//! callers must finish borrowing before any operation that can collect.
const builtin = @import("builtin");
const JSRuntime = @import("../runtime.zig").JSRuntime;

pub const checks_enabled = builtin.mode == .Debug or builtin.is_test;

/// Activate at the final stack address; active scopes must not be copied.
/// Native allocation remains allowed. Collection requests panic at entry,
/// including requests that would otherwise decide there is no work to do.
pub const NoGcScope = struct {
    state: if (checks_enabled) struct {
        runtime: ?*JSRuntime = null,
        previous: ?*NoGcScope = null,
    } else void = if (checks_enabled) .{} else {},

    pub fn activate(self: *NoGcScope, rt: *JSRuntime) void {
        if (comptime checks_enabled) {
            rt.assertOwnerThread();
            if (self.state.runtime != null) @panic("no-GC scope already active");
            self.state = .{ .runtime = rt, .previous = rt.active_no_gc_scope };
            rt.active_no_gc_scope = self;
        }
    }

    pub fn deactivate(self: *NoGcScope) void {
        if (comptime checks_enabled) {
            const rt = self.state.runtime orelse return;
            rt.assertOwnerThread();
            if (rt.active_no_gc_scope != self) @panic("no-GC scopes must deactivate in LIFO order at their original address");
            rt.active_no_gc_scope = self.state.previous;
            self.state = .{};
        }
    }
};

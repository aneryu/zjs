//! The current thread's native stack bounds, for the conservative scanner
//! (`high`) and the native stack budget (`low`). Stacks grow down.

const std = @import("std");
const builtin = @import("builtin");

pub const Bounds = struct {
    /// Lowest usable address (the stack's end, before any guard page).
    low: usize,
    /// Highest address (the stack's base).
    high: usize,
};

const linux_pthread = builtin.os.tag == .linux;
const darwin_pthread = builtin.os.tag.isDarwin();
const windows_stack = builtin.os.tag == .windows;

const linux_stack = if (linux_pthread) struct {
    extern "c" fn pthread_getattr_np(thread: std.c.pthread_t, attr: *std.c.pthread_attr_t) c_int;
    extern "c" fn pthread_attr_getstack(
        attr: *const std.c.pthread_attr_t,
        stackaddr: *?*anyopaque,
        stacksize: *usize,
    ) c_int;

    fn query() ?Bounds {
        var attr: std.c.pthread_attr_t = undefined;
        if (pthread_getattr_np(std.c.pthread_self(), &attr) != 0) return null;
        defer _ = std.c.pthread_attr_destroy(&attr);
        var stackaddr: ?*anyopaque = null;
        var stacksize: usize = 0;
        if (pthread_attr_getstack(&attr, &stackaddr, &stacksize) != 0) return null;
        const low = @intFromPtr(stackaddr orelse return null);
        return .{ .low = low, .high = low + stacksize };
    }
} else struct {
    fn query() ?Bounds {
        return null;
    }
};

const darwin_stack = if (darwin_pthread) struct {
    extern "c" fn pthread_get_stackaddr_np(thread: std.c.pthread_t) ?*anyopaque;
    extern "c" fn pthread_get_stacksize_np(thread: std.c.pthread_t) usize;

    fn query() ?Bounds {
        // Darwin returns the highest address of a downward-growing stack.
        const high = @intFromPtr(pthread_get_stackaddr_np(std.c.pthread_self()) orelse return null);
        const size = pthread_get_stacksize_np(std.c.pthread_self());
        if (size == 0 or size > high) return null;
        return .{ .low = high - size, .high = high };
    }
} else struct {
    fn query() ?Bounds {
        return null;
    }
};

const windows_limits = if (windows_stack) struct {
    extern "kernel32" fn GetCurrentThreadStackLimits(
        low: *usize,
        high: *usize,
    ) callconv(.winapi) void;

    fn query() ?Bounds {
        var low: usize = 0;
        var high: usize = 0;
        GetCurrentThreadStackLimits(&low, &high);
        return if (high == 0) null else .{ .low = low, .high = high };
    }
} else struct {
    fn query() ?Bounds {
        return null;
    }
};

/// Cached per thread, because the answer cannot change for a live thread and
/// the question is expensive to ask.
///
/// glibc's `pthread_getattr_np` resolves the INITIAL thread's bounds by
/// opening and parsing `/proc/self/maps`; for other threads it is cheap, but
/// the collector runs on whichever thread owns the runtime and that is
/// usually the initial one. Every conservative scan asked, and there are two
/// per major plus one per minor: earley-boyer's 7,772 majors and 2,803
/// minors make ~18,300 calls, each of them a file open, read and parse.
/// A thread's stack is fixed once it is running, so one call per thread is
/// enough. (Found in adversarial review, codex, 2026-08-27.)
threadlocal var cached: Bounds = .{ .low = 0, .high = 0 };
threadlocal var cached_valid: bool = false;

/// The current thread's stack bounds, or null where the platform cannot say.
pub fn bounds() ?Bounds {
    if (!cached_valid) {
        cached_valid = true;
        const queried = if (comptime linux_pthread)
            linux_stack.query()
        else if (comptime darwin_pthread)
            darwin_stack.query()
        else if (comptime windows_stack)
            windows_limits.query()
        else
            null;
        cached = queried orelse .{ .low = 0, .high = 0 };
    }
    return if (cached.high == 0) null else cached;
}

test "the current thread's stack contains this frame" {
    const b = bounds() orelse return;
    const sp = @frameAddress();
    try std.testing.expect(b.low < sp and sp < b.high);
}

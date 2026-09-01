//! Conservative native-root scanner (design §7.2). Written for the Stage 1
//! shadow observer and inherited by the reclaiming tracer, which is now its
//! only caller.
//!
//! Implemented ABIs: AArch64 Linux/macOS (AAPCS64 + Darwin), x86_64 SysV
//! (Linux/macOS), and x86_64 Windows. Remaining ABIs are an explicit
//! unimplemented branch and fail at compile time.
//!
//! Candidates are never dereferenced. A machine word is a root only if the
//! live address registry maps it to a published allocation (header, metadata
//! prefix, interior, or one-past-end). `AddressLookup.build` remains a
//! census-snapshot oracle for tests.

const std = @import("std");
const builtin = @import("builtin");

const gc = @import("gc.zig");
const AddressRegistry = @import("gc_address_registry.zig");
const runtime_mod = @import("runtime.zig");
const JSRuntime = runtime_mod.JSRuntime;

pub const target_supported = switch (builtin.cpu.arch) {
    .aarch64 => switch (builtin.os.tag) {
        .linux, .macos => true,
        else => false,
    },
    .x86_64 => switch (builtin.os.tag) {
        .linux, .macos, .windows => true,
        else => false,
    },
    else => false,
};

comptime {
    // A reclaiming tracer that cannot scan the native stack will free objects
    // whose only reference is a machine word. Degrading to precise-only on an
    // unimplemented ABI is not a lighter configuration, it is an unsound one,
    // and it used to happen silently: `spillRegistersAndScan` set
    // `metrics.supported = false` and returned, so no gate went red. Refuse at
    // build time instead. The shadow tracer is exempt because it never
    // reclaims -- there a missing root is a census discrepancy, which is
    // exactly what the shadow build exists to report.
    if (!target_supported) {
        @compileError("the tracing collector needs a conservative stack scanner for this target; " ++
            "see `missing_abis` below. Reclaiming without one frees natively-held objects.");
    }
}

pub const missing_abis = [_][]const u8{
    "aarch64-windows",
};

pub const Metrics = struct {
    supported: bool = target_supported,
    candidates: usize = 0,
    validated_hits: usize = 0,
    retained_only_conservatively: usize = 0,
    direct_bytes: usize = 0,
    transitive_bytes: usize = 0,
};

const Range = struct {
    lo: usize,
    hi: usize,
    header: *gc.Header,

    fn lessThan(_: void, a: Range, b: Range) bool {
        return a.lo < b.lo;
    }
};

pub const AddressLookup = struct {
    ranges: []Range,

    /// Census snapshot used as a test oracle against the live page-radix
    /// registry. Collection no longer builds this on the mark path.
    pub fn build(rt: *JSRuntime, allocator: std.mem.Allocator) std.mem.Allocator.Error!AddressLookup {
        var list: std.ArrayList(Range) = .empty;
        var iterator = rt.gc.objectIterator();
        while (iterator.next()) |header| {
            const header_addr = @intFromPtr(header);
            const size = gc.Registry.heapByteSizeFromHeader(rt, header);
            const lo = header_addr - gc.metadata_prefix_size;
            // Exclusive end includes one-past-end of the object body.
            const hi = header_addr + size + 1;
            try list.append(allocator, .{ .lo = lo, .hi = hi, .header = header });
        }
        const ranges = list.items;
        std.mem.sort(Range, ranges, {}, Range.lessThan);
        return .{ .ranges = ranges };
    }

    pub fn resolve(self: AddressLookup, addr: usize) ?*gc.Header {
        if (addr < 4096) return null;
        const ranges = self.ranges;
        if (ranges.len == 0) return null;
        var lo: usize = 0;
        var hi: usize = ranges.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (ranges[mid].lo <= addr) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo == 0) return null;
        const range = ranges[lo - 1];
        if (addr < range.hi) return range.header;
        return null;
    }
};

const SpillImage = switch (builtin.cpu.arch) {
    .aarch64 => extern struct {
        gpr: [31]u64 align(16) = undefined,
        _pad_x30: u64 = undefined,
        simd: [64]u64 = undefined,

        comptime {
            std.debug.assert(@offsetOf(@This(), "simd") == 256);
            std.debug.assert(@sizeOf(@This()) == 768);
        }
    },
    .x86_64 => extern struct {
        /// rax, rbx, rcx, rdx, rsi, rdi, rbp, r8-r15. Slot 7 is unused padding
        /// so XMM spills start at offset 128.
        gpr: [16]u64 align(16) = undefined,
        xmm: [32]u64 = undefined,

        comptime {
            std.debug.assert(@offsetOf(@This(), "xmm") == 128);
            std.debug.assert(@sizeOf(@This()) == 384);
        }
    },
    else => void,
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

    fn stackHigh() ?usize {
        var attr: std.c.pthread_attr_t = undefined;
        if (pthread_getattr_np(std.c.pthread_self(), &attr) != 0) return null;
        defer _ = std.c.pthread_attr_destroy(&attr);
        var stackaddr: ?*anyopaque = null;
        var stacksize: usize = 0;
        if (pthread_attr_getstack(&attr, &stackaddr, &stacksize) != 0) return null;
        const base = @intFromPtr(stackaddr orelse return null);
        return base + stacksize;
    }
} else struct {
    fn stackHigh() ?usize {
        return null;
    }
};

const darwin_stack = if (darwin_pthread) struct {
    extern "c" fn pthread_get_stackaddr_np(thread: std.c.pthread_t) ?*anyopaque;

    fn stackHigh() ?usize {
        // Darwin returns the highest address of a downward-growing stack.
        const addr = pthread_get_stackaddr_np(std.c.pthread_self()) orelse return null;
        return @intFromPtr(addr);
    }
} else struct {
    fn stackHigh() ?usize {
        return null;
    }
};

const windows_limits = if (windows_stack) struct {
    extern "kernel32" fn GetCurrentThreadStackLimits(
        low: *usize,
        high: *usize,
    ) callconv(.winapi) void;

    fn stackHigh() ?usize {
        var low: usize = 0;
        var high: usize = 0;
        GetCurrentThreadStackLimits(&low, &high);
        return if (high == 0) null else high;
    }
} else struct {
    fn stackHigh() ?usize {
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
threadlocal var cached_stack_high: usize = 0;
threadlocal var cached_stack_high_valid: bool = false;

fn threadStackHigh() ?usize {
    if (cached_stack_high_valid) {
        return if (cached_stack_high == 0) null else cached_stack_high;
    }
    cached_stack_high_valid = true;
    const high = if (comptime linux_pthread)
        linux_stack.stackHigh()
    else if (comptime darwin_pthread)
        darwin_stack.stackHigh()
    else if (comptime windows_stack)
        windows_limits.stackHigh()
    else
        null;
    cached_stack_high = high orelse 0;
    return high;
}

fn scanHigh(rt: *const JSRuntime, sp: usize) usize {
    if (threadStackHigh()) |high| {
        if (high > sp) return high;
    }
    const top = rt.hot.native_stack_top;
    if (top > sp) return top;
    return sp;
}

fn dumpRegisters(image: *SpillImage) usize {
    if (comptime builtin.cpu.arch == .aarch64) {
        return asm volatile (
            \\stp x0, x1, [%[p], #0]
            \\stp x2, x3, [%[p], #16]
            \\stp x4, x5, [%[p], #32]
            \\stp x6, x7, [%[p], #48]
            \\stp x8, x9, [%[p], #64]
            \\stp x10, x11, [%[p], #80]
            \\stp x12, x13, [%[p], #96]
            \\stp x14, x15, [%[p], #112]
            \\stp x16, x17, [%[p], #128]
            \\stp x18, x19, [%[p], #144]
            \\stp x20, x21, [%[p], #160]
            \\stp x22, x23, [%[p], #176]
            \\stp x24, x25, [%[p], #192]
            \\stp x26, x27, [%[p], #208]
            \\stp x28, x29, [%[p], #224]
            \\str x30, [%[p], #240]
            \\stp q0, q1, [%[p], #256]
            \\stp q2, q3, [%[p], #288]
            \\stp q4, q5, [%[p], #320]
            \\stp q6, q7, [%[p], #352]
            \\stp q8, q9, [%[p], #384]
            \\stp q10, q11, [%[p], #416]
            \\stp q12, q13, [%[p], #448]
            \\stp q14, q15, [%[p], #480]
            \\stp q16, q17, [%[p], #512]
            \\stp q18, q19, [%[p], #544]
            \\stp q20, q21, [%[p], #576]
            \\stp q22, q23, [%[p], #608]
            \\stp q24, q25, [%[p], #640]
            \\stp q26, q27, [%[p], #672]
            \\stp q28, q29, [%[p], #704]
            \\stp q30, q31, [%[p], #736]
            \\mov %[sp], sp
            : [sp] "=r" (-> usize),
            : [p] "r" (image),
            : .{ .memory = true });
    } else if (comptime builtin.cpu.arch == .x86_64) {
        return asm volatile (
            \\movq %%rax, 0(%[p])
            \\movq %%rbx, 8(%[p])
            \\movq %%rcx, 16(%[p])
            \\movq %%rdx, 24(%[p])
            \\movq %%rsi, 32(%[p])
            \\movq %%rdi, 40(%[p])
            \\movq %%rbp, 48(%[p])
            \\movq %%r8, 56(%[p])
            \\movq %%r9, 64(%[p])
            \\movq %%r10, 72(%[p])
            \\movq %%r11, 80(%[p])
            \\movq %%r12, 88(%[p])
            \\movq %%r13, 96(%[p])
            \\movq %%r14, 104(%[p])
            \\movq %%r15, 112(%[p])
            \\movdqu %%xmm0, 128(%[p])
            \\movdqu %%xmm1, 144(%[p])
            \\movdqu %%xmm2, 160(%[p])
            \\movdqu %%xmm3, 176(%[p])
            \\movdqu %%xmm4, 192(%[p])
            \\movdqu %%xmm5, 208(%[p])
            \\movdqu %%xmm6, 224(%[p])
            \\movdqu %%xmm7, 240(%[p])
            \\movdqu %%xmm8, 256(%[p])
            \\movdqu %%xmm9, 272(%[p])
            \\movdqu %%xmm10, 288(%[p])
            \\movdqu %%xmm11, 304(%[p])
            \\movdqu %%xmm12, 320(%[p])
            \\movdqu %%xmm13, 336(%[p])
            \\movdqu %%xmm14, 352(%[p])
            \\movdqu %%xmm15, 368(%[p])
            \\movq %%rsp, %[sp]
            : [sp] "=r" (-> usize),
            : [p] "r" (image),
            : .{ .memory = true });
    } else {
        unreachable;
    }
}

fn scanWords(
    rt: *JSRuntime,
    lo: usize,
    hi: usize,
    scan_filter: AddressRegistry.ScanFilter,
    metrics: *Metrics,
    shade: *const fn (*anyopaque, *gc.Header) void,
    shade_ctx: *anyopaque,
) void {
    var addr = std.mem.alignForward(usize, lo, @sizeOf(usize));
    // Account the fixed word range once. Keeping both counters in the loop
    // forced two diagnostic read-modify-writes for every native-stack word --
    // once to this scan's Metrics and once inside `forEachGcObjectAt` to the
    // registry's cumulative Stats. The callback may alias arbitrary runtime
    // state, so the compiler cannot safely hoist those writes on its own.
    const candidates = if (hi > addr) (hi - addr) / @sizeOf(usize) else 0;
    metrics.candidates += candidates;
    rt.gc.address_registry.stats.lookup_calls += candidates;
    var validated_hits: usize = 0;
    while (addr + @sizeOf(usize) <= hi) : (addr += @sizeOf(usize)) {
        const word = @as(*const usize, @ptrFromInt(addr)).*;
        // Shade every gc object the word lands inside, not just one. A word
        // sitting where object A's one-past-end meets object B's metadata
        // prefix is a live reference to whichever of the two the native code
        // meant, and the registry cannot tell; shading both is the only safe
        // reading. String and rope hits are still discarded -- they are
        // refcount-owned and the tracer does not sweep them.
        const hits = rt.gc.address_registry.forEachGcObjectAt(word, scan_filter, shade_ctx, shade);
        if (hits != 0) validated_hits += 1;
    }
    metrics.validated_hits += validated_hits;
    rt.gc.address_registry.stats.lookup_hits += validated_hits;
}

pub fn spillRegistersAndScan(
    rt: *JSRuntime,
    metrics: *Metrics,
    shade: *const fn (*anyopaque, *gc.Header) void,
    shade_ctx: *anyopaque,
) void {
    if (comptime !target_supported) {
        metrics.supported = false;
        return;
    }
    comptime std.debug.assert(gc.address_registry_enabled);
    // The filter must be current before any word is dismissed by it; arenas
    // and standalone allocations may have appeared since the last scan.
    // Keep both TinyBloom filters and the monotone bounds in locals across
    // the word loop. This is JSC's `genericAddSpan` trick: the shade callback
    // may alias runtime state, but a stop-the-world span cannot mutate these
    // snapshots, so the compiler may keep them in registers.
    const scan_filter = rt.gc.address_registry.rebuildScanFilter();
    var image: SpillImage = undefined;
    const sp = dumpRegisters(&image);
    std.mem.doNotOptimizeAway(&image);
    const high = scanHigh(rt, sp);
    scanWords(rt, sp, high, scan_filter, metrics, shade, shade_ctx);
}

test "conservative scanner is enabled on this ABI" {
    try std.testing.expect(target_supported);
}

test "spillRegistersAndScan covers a non-empty stack range" {
    const rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    var metrics: Metrics = .{};
    const shade = struct {
        fn f(_: *anyopaque, _: *gc.Header) void {}
    }.f;
    var ctx: u8 = 0;
    spillRegistersAndScan(rt, &metrics, shade, &ctx);
    try std.testing.expect(metrics.supported);
    try std.testing.expect(metrics.candidates > 0);
}

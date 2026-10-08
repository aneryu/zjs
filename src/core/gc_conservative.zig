//! Conservative native-root scanner (design §7.2): the net under every Zig
//! local that holds a heap reference across an allocation while production
//! links only container/window `ValueRootFrame`s (R1 of the completion plan
//! retires it to a verification arm).
//!
//! Implemented ABIs: AArch64 Linux/macOS (AAPCS64 + Darwin), x86_64 SysV
//! (Linux/macOS), and x86_64 Windows. Remaining ABIs are an explicit
//! unimplemented branch and fail at compile time.
//!
//! Candidates are never dereferenced. A machine word is a root only if the
//! live address registry maps it to a published allocation (header, metadata
//! prefix, interior, or one-past-end).

const std = @import("std");
const builtin = @import("builtin");

const gc = @import("gc.zig");
const AddressRegistry = @import("gc_address_registry.zig");
const thread_stack = @import("thread_stack.zig");
const runtime_mod = @import("../runtime.zig");
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
    // whose only reference is a machine word. Refuse unsupported builds rather
    // than silently degrading to an unsound precise-only scan.
    if (!target_supported) {
        @compileError("the tracing collector needs a conservative stack scanner for this target; " ++
            "supported targets are aarch64-linux/macos and x86_64-linux/macos/windows");
    }
}

pub const Metrics = struct {
    candidates: usize = 0,
};

pub const SpillImage = switch (builtin.cpu.arch) {
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
        /// rax, rbx, rcx, rdx, rsi, rdi, rbp, r8-r15 in `dumpRegisters` order
        /// (offsets 0..112). Slot 15 (offset 120) is unused padding so XMM
        /// spills start at offset 128.
        gpr: [16]u64 align(16) = undefined,
        xmm: [32]u64 = undefined,

        comptime {
            std.debug.assert(@offsetOf(@This(), "xmm") == 128);
            std.debug.assert(@sizeOf(@This()) == 384);
        }
    },
    else => void,
};

fn scanHigh(rt: *const JSRuntime, sp: usize) usize {
    if (thread_stack.bounds()) |stack| {
        if (stack.high > sp) return stack.high;
    }
    const top = rt.stack.native_top;
    if (top > sp) return top;
    return sp;
}

pub fn dumpRegisters(image: *SpillImage) usize {
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
    const nursery_enabled = rt.gc.nursery.enabled and rt.gc.nursery.pages.items.len != 0;
    var addr = std.mem.alignForward(usize, lo, @sizeOf(usize));
    // Account the fixed word range once rather than updating the metric for
    // every native-stack word.
    const candidates = if (hi > addr) (hi - addr) / @sizeOf(usize) else 0;
    metrics.candidates += candidates;
    while (addr + @sizeOf(usize) <= hi) : (addr += @sizeOf(usize)) {
        const word = @as(*const usize, @ptrFromInt(addr)).*;
        // Shade every gc object the word lands inside, not just one. A word
        // sitting where object A's one-past-end meets object B's metadata
        // prefix is a live reference to whichever of the two the native code
        // meant, and the registry cannot tell; shading both is the only safe
        // reading. Which kinds a hit is offered for is entirely `scan_filter`
        // plus the `shade` callback's business: this loop forwards every
        // candidate and never filters by kind itself.
        _ = rt.gc.address_registry.forEachTraceCandidateAt(word, scan_filter, shade_ctx, shade);
        if (nursery_enabled) forEachNurseryCandidateAt(rt, word, shade_ctx, shade);
        // NaN-boxed JSValues store pointers in the low 48 bits with a prefix
        // 0xFFF1..0xFFFF (`0xFFF0 + dense Kind index` in value.zig). Keep the
        // constants here so this leaf does not import the value module. The
        // 0xFFF0_xxxx hole above -Inf is not a boxed encoding; scanning it
        // only creates false conservative roots.
        const nanbox_first_boxed: usize = 0xFFF1_0000_0000_0000;
        const nanbox_payload_mask: usize = (@as(usize, 1) << 48) - 1;
        if (word >= nanbox_first_boxed) {
            const unboxed = word & nanbox_payload_mask;
            if (unboxed != 0 and unboxed != word) {
                _ = rt.gc.address_registry.forEachTraceCandidateAt(unboxed, scan_filter, shade_ctx, shade);
                if (nursery_enabled) forEachNurseryCandidateAt(rt, unboxed, shade_ctx, shade);
            }
        }
    }
}

/// Nursery pages come from their own allocator, so the address registry
/// cannot resolve them. A bump page stores objects back to back, each behind
/// its metadata prefix, so walk the page to the object(s) the word lands in.
/// One-past-end counts, exactly as in the registry arms: a native pointer
/// past object A is a reference to A.
fn forEachNurseryCandidateAt(
    rt: *JSRuntime,
    addr: usize,
    shade_ctx: *anyopaque,
    shade: *const fn (*anyopaque, *gc.Header) void,
) void {
    const nursery = &rt.gc.nursery;
    const page = nursery.pageOf(addr) orelse nursery.pageOf(addr -% 1) orelse return;
    var cursor = page.base;
    while (cursor < page.top and cursor <= addr) {
        const header: *gc.Header = @ptrFromInt(cursor + gc.metadata_prefix_size);
        const forwarded = gc.headerForwarded(header);
        const body_bytes = if (forwarded)
            gc.forwardedBodyBytes(header)
        else
            gc.Registry.heapByteSizeFromHeader(rt, header);
        const end = cursor + gc.metadata_prefix_size + body_bytes;
        // A husk is not an object. The pre-evacuation pass retains every page
        // a native word names, so a named object is never forwarded. Like the
        // registry arms, offer only published cells: an unpublished one is a
        // tombstoned corpse or an object between allocation and publication,
        // and the nursery constructors (plain, slots2, array) collect and
        // allocate storage before the cell, so no collection sees the latter.
        if (addr <= end and !forwarded and header.metaConst().alloc_info.heap_accounted) shade(shade_ctx, header);
        cursor += std.mem.alignForward(usize, gc.metadata_prefix_size + body_bytes, 8);
    }
}

pub fn spillRegistersAndScan(
    rt: *JSRuntime,
    metrics: *Metrics,
    shade: *const fn (*anyopaque, *gc.Header) void,
    shade_ctx: *anyopaque,
) void {
    if (comptime !target_supported) unreachable;
    // The filter must be current before any word is dismissed by it; arenas
    // and standalone allocations may have appeared since the last scan.
    // Keep both TinyBloom filters and the monotone bounds in locals across
    // the word loop. This is JSC's `genericAddSpan` trick: the shade callback
    // may alias runtime state, but a stop-the-world span cannot mutate these
    // snapshots, so the compiler may keep them in registers.
    const scan_filter = rt.gc.address_registry.rebuildScanFilter();
    if (gc.invariantChecksEnabled()) {
        rt.gc.address_registry.verifyScanFilter(scan_filter) catch |err| {
            std.debug.print("gc: SCAN FILTER AUDIT: {s}\n", .{@errorName(err)});
            @panic("conservative scan filter invariant violated");
        };
    }
    var image: SpillImage = undefined;
    const sp = dumpRegisters(&image);
    std.mem.doNotOptimizeAway(&image);
    const high = scanHigh(rt, sp);
    scanWords(rt, sp, high, scan_filter, metrics, shade, shade_ctx);
}

test "spillRegistersAndScan covers a non-empty stack range" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var metrics: Metrics = .{};
    const shade = struct {
        fn f(_: *anyopaque, _: *gc.Header) void {}
    }.f;
    var ctx: u8 = 0;
    spillRegistersAndScan(rt, &metrics, shade, &ctx);
    try std.testing.expect(metrics.candidates > 0);
}

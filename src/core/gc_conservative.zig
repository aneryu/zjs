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
const runtime_mod = @import("runtime.zig");
const object_mod = @import("object.zig");
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
    // Account the fixed word range once rather than updating the metric for
    // every native-stack word.
    const candidates = if (hi > addr) (hi - addr) / @sizeOf(usize) else 0;
    metrics.candidates += candidates;
    while (addr + @sizeOf(usize) <= hi) : (addr += @sizeOf(usize)) {
        const word = @as(*const usize, @ptrFromInt(addr)).*;
        if (comptime gc.roots_diag_enabled) {
            diag_word.addr = addr;
            diag_word.word = word;
        }
        // Shade every gc object the word lands inside, not just one. A word
        // sitting where object A's one-past-end meets object B's metadata
        // prefix is a live reference to whichever of the two the native code
        // meant, and the registry cannot tell; shading both is the only safe
        // reading. String and rope hits are still discarded -- they are
        // refcount-owned and the tracer does not sweep them.
        _ = rt.gc.address_registry.forEachTraceCandidateAt(word, scan_filter, shade_ctx, shade);
    }
}

pub fn spillRegistersAndScan(
    rt: *JSRuntime,
    metrics: *Metrics,
    shade: *const fn (*anyopaque, *gc.Header) void,
    shade_ctx: *anyopaque,
) void {
    if (comptime !target_supported) unreachable;
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
    if (comptime gc.roots_diag_enabled) {
        diag_word.sp = sp;
        diag_word.image_lo = @intFromPtr(&image);
        diag_word.image_hi = @intFromPtr(&image) + @sizeOf(SpillImage);
    }
    scanWords(rt, sp, high, scan_filter, metrics, shade, shade_ctx);
}

// ===== R3 roots diagnosis (`-Dzjs_gc_roots_diag=true`) =====
//
// Question: in a production binary, which objects does the conservative
// scan alone keep alive, and which native word did it? The probe in
// `gc_trace_stw.computeFullReachable` finishes the precise trace first, so a
// header that is unmarked when the conservative callback reaches it and
// marked after is a DIRECT conservative-only root; everything the drain then
// reaches through it is TRANSITIVE. The scan loop publishes the word it is
// resolving; the census keys each direct hit by (interpreter function,
// header kind, object class, word source, pointer shape).

/// The stack word the scan loop is currently resolving, plus the frame
/// geometry needed to classify it. Written only in the diag build.
pub const DiagWord = struct {
    addr: usize = 0,
    word: usize = 0,
    sp: usize = 0,
    image_lo: usize = 0,
    image_hi: usize = 0,
};
threadlocal var diag_word: DiagWord = .{};

pub inline fn diagCurrentWord() DiagWord {
    return diag_word;
}

/// Number of machine words in the register spill image.
pub const diag_register_words = if (target_supported) @sizeOf(SpillImage) / @sizeOf(usize) else 0;

pub fn diagRegisterName(index: usize, buf: []u8) []const u8 {
    if (comptime builtin.cpu.arch == .aarch64) {
        if (index < 31) return std.fmt.bufPrint(buf, "x{d}", .{index}) catch "?";
        if (index == 31) return "pad";
        const q = (index - 32) / 2;
        return std.fmt.bufPrint(buf, "q{d}.{s}", .{ q, if ((index - 32) % 2 == 0) "lo" else "hi" }) catch "?";
    } else if (comptime builtin.cpu.arch == .x86_64) {
        const names = [_][]const u8{ "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "pad", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15" };
        if (index < names.len) return names[index];
        const x = (index - 16) / 2;
        return std.fmt.bufPrint(buf, "xmm{d}.{s}", .{ x, if ((index - 16) % 2 == 0) "lo" else "hi" }) catch "?";
    }
    return "?";
}

pub const RootsDiagCensus = struct {
    pub const Source = enum(u3) { register, stack_lt_1k, stack_lt_4k, stack_lt_16k, stack_lt_64k, stack_ge_64k };
    pub const PtrKind = enum(u2) { exact, prefix, interior };

    pub const Key = packed struct(u64) {
        function_atom: u32,
        class_id: u16,
        kind: u4,
        source: u3,
        ptr_kind: u2,
        young: u1,
        native: u1,
        _pad: u5 = 0,
    };

    const Slot = struct {
        key: Key = @bitCast(@as(u64, 0)),
        count: usize = 0,
        used: bool = false,
    };
    const slots_len = 1024;

    slots: [slots_len]Slot = @splat(.{}),
    /// `computeFullReachable` runs with the conservative arm on.
    probes: usize = 0,
    /// Headers a conservative word marked that the precise trace had not.
    direct: usize = 0,
    direct_young: usize = 0,
    /// Conservative-only headers reached through a direct hit, not by a word
    /// of their own.
    transitive: usize = 0,
    /// Distinct keys the fixed table could not hold (never silently dropped:
    /// printed with the census).
    dropped_keys: usize = 0,
    by_source: [6]usize = @splat(0),
    by_ptr_kind: [3]usize = @splat(0),
    by_kind: [gc.gc_kind_count]usize = @splat(0),
    by_register: [if (diag_register_words == 0) 1 else diag_register_words]usize = @splat(0),

    fn hashKey(key: Key) usize {
        const bits: u64 = @bitCast(key);
        return @intCast((bits *% 0x9E37_79B9_7F4A_7C15) >> (64 - 10));
    }

    fn currentFunction(rt: *const JSRuntime) struct { atom: u32, native: bool } {
        if (rt.hot.current_backtrace_frame) |frame| {
            if (frame.resolver(frame.data, 0)) |snapshot| {
                return .{ .atom = snapshot.function_name, .native = snapshot.is_native };
            }
        }
        return .{ .atom = 0, .native = false };
    }

    /// Record one direct conservative-only root. `header` was unmarked before
    /// the shade and is marked now; `w` is the word that named it.
    pub fn noteDirect(self: *RootsDiagCensus, rt: *const JSRuntime, header: *const gc.Header, w: DiagWord) void {
        self.direct += 1;
        const meta = header.metaConst();
        if (meta.flags.young) self.direct_young += 1;
        const header_addr = @intFromPtr(header);
        const ptr_kind: PtrKind = if (w.word == header_addr)
            .exact
        else if (w.word == header_addr - gc.metadata_prefix_size)
            .prefix
        else
            .interior;
        var source: Source = undefined;
        if (w.addr >= w.image_lo and w.addr < w.image_hi) {
            source = .register;
            const index = (w.addr - w.image_lo) / @sizeOf(usize);
            if (index < self.by_register.len) self.by_register[index] += 1;
        } else {
            const depth = w.addr -| w.sp;
            source = if (depth < 1024)
                .stack_lt_1k
            else if (depth < 4096)
                .stack_lt_4k
            else if (depth < 16384)
                .stack_lt_16k
            else if (depth < 65536)
                .stack_lt_64k
            else
                .stack_ge_64k;
        }
        self.by_source[@intFromEnum(source)] += 1;
        self.by_ptr_kind[@intFromEnum(ptr_kind)] += 1;
        self.by_kind[@intFromEnum(meta.flags.kind)] += 1;
        const function = currentFunction(rt);
        const class_id: u16 = if (meta.flags.kind == .object)
            @intCast(object_mod.Object.fromHeaderConst(header).class_id)
        else
            0;
        const key: Key = .{
            .function_atom = function.atom,
            .class_id = class_id,
            .kind = @intCast(@intFromEnum(meta.flags.kind)),
            .source = @intFromEnum(source),
            .ptr_kind = @intFromEnum(ptr_kind),
            .young = @intFromBool(meta.flags.young),
            .native = @intFromBool(function.native),
        };
        var index = hashKey(key);
        var probed: usize = 0;
        while (probed < slots_len) : (probed += 1) {
            const slot = &self.slots[index];
            if (!slot.used) {
                slot.* = .{ .key = key, .count = 1, .used = true };
                return;
            }
            if (@as(u64, @bitCast(slot.key)) == @as(u64, @bitCast(key))) {
                slot.count += 1;
                return;
            }
            index = (index + 1) % slots_len;
        }
        self.dropped_keys += 1;
    }

    /// Close one probe: `conservative_only` is the number of headers the
    /// probe's conservative arm marked in total, `direct` how many of those
    /// were hit by a word of their own.
    pub fn noteProbe(self: *RootsDiagCensus, conservative_only: usize, direct: usize) void {
        self.probes += 1;
        self.transitive += conservative_only -| direct;
    }

    pub fn report(self: *const RootsDiagCensus, writer: *std.Io.Writer, rt: *const JSRuntime) !void {
        try writer.print(
            "gc: conservative-only census probes {d}, direct {d} (young {d}), transitive {d}, dropped keys {d}\n",
            .{ self.probes, self.direct, self.direct_young, self.transitive, self.dropped_keys },
        );
        try writer.print(
            "gc: conservative-only by source registers {d}, stack<1K {d}, <4K {d}, <16K {d}, <64K {d}, >=64K {d}; by pointer exact {d}, prefix {d}, interior {d}\n",
            .{
                self.by_source[0],   self.by_source[1],   self.by_source[2],   self.by_source[3], self.by_source[4], self.by_source[5],
                self.by_ptr_kind[0], self.by_ptr_kind[1], self.by_ptr_kind[2],
            },
        );
        try writer.print("gc: conservative-only by kind", .{});
        for (self.by_kind, 0..) |count, kind_index| {
            const kind: gc.GcKind = @enumFromInt(kind_index);
            try writer.print(" {s} {d}", .{ @tagName(kind), count });
        }
        try writer.print("\n", .{});
        try writer.print("gc: conservative-only registers", .{});
        var any_register = false;
        for (self.by_register, 0..) |count, index| {
            if (count == 0) continue;
            any_register = true;
            var name_buf: [16]u8 = undefined;
            try writer.print(" {s} {d}", .{ diagRegisterName(index, &name_buf), count });
        }
        if (!any_register) try writer.print(" none", .{});
        try writer.print("\n", .{});

        var ranked: [slots_len]Slot = undefined;
        var used: usize = 0;
        for (self.slots) |slot| {
            if (!slot.used) continue;
            ranked[used] = slot;
            used += 1;
        }
        std.mem.sort(Slot, ranked[0..used], {}, struct {
            fn moreHits(_: void, a: Slot, b: Slot) bool {
                return a.count > b.count;
            }
        }.moreHits);
        const shown = @min(used, 20);
        try writer.print("gc: conservative-only top {d} of {d} keys (function, kind/class, source, pointer, young, native)\n", .{ shown, used });
        for (ranked[0..shown], 1..) |slot, rank| {
            const key = slot.key;
            const kind: gc.GcKind = @enumFromInt(key.kind);
            const source: Source = @enumFromInt(key.source);
            const ptr_kind: PtrKind = @enumFromInt(key.ptr_kind);
            const function_name: []const u8 = if (key.function_atom == 0)
                "<no frame>"
            else
                rt.atoms.name(key.function_atom) orelse "<anonymous>";
            try writer.print(
                "gc: conservative-only #{d} {d} fn={s} kind={s} class={d} src={s} ptr={s} young={d} native={d}\n",
                .{ rank, slot.count, function_name, @tagName(kind), key.class_id, @tagName(source), @tagName(ptr_kind), key.young, key.native },
            );
        }
    }
};

test "spillRegistersAndScan covers a non-empty stack range" {
    const rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    var metrics: Metrics = .{};
    const shade = struct {
        fn f(_: *anyopaque, _: *gc.Header) void {}
    }.f;
    var ctx: u8 = 0;
    spillRegistersAndScan(rt, &metrics, shade, &ctx);
    try std.testing.expect(metrics.candidates > 0);
}

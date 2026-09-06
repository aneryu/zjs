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
        diag_word.high = high;
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
    high: usize = 0,
    image_lo: usize = 0,
    image_hi: usize = 0,
};
threadlocal var diag_word: DiagWord = .{};

pub inline fn diagCurrentWord() DiagWord {
    return diag_word;
}

// --- native frame map -------------------------------------------------------
//
// R3 asks WHICH engine function's locals the conservative arm is rescuing, and
// the answer is a property of the native frame the word sits in, not of the JS
// frame the interpreter happens to be running. Both AArch64 AAPCS64 and x86_64
// SysV keep the same two words at the frame base: `[fp] = caller fp`,
// `[fp + 8] = return address into the caller`. Walking that chain gives an
// ascending table of frame tops; the frame that OWNS the slot at `addr` is the
// first one whose top is at or above it, and the function that owns that frame
// is the one containing the return address saved by the frame below it. Debug
// and ReleaseSafe keep frame pointers; if the chain breaks the entry is simply
// absent and the word is attributed to `unknown`.
//
// The walk is LAZY and runs from the classification callback, never from
// `spillRegistersAndScan`. That placement is load-bearing, not stylistic: the
// scan range is `[sp, native stack high)` where `sp` is the scanner's own stack
// pointer, so ANY local or call the diagnosis adds to `spillRegistersAndScan`
// lowers `sp` and makes the collector scan words it would not otherwise have
// seen -- residue that pins objects the production collector would free. Every
// frame from `scanWords` down sits below `sp` and is therefore outside the
// scanned range by construction, so doing the work there is free of that
// hazard. The chain cannot change mid-scan (the mutator is stopped), so one
// walk per scan is exact; `diag_word.sp` doubles as the cache key.

pub const diag_max_frames = 256;

const DiagFrame = struct {
    /// Frame base (`fp`). Locals of this frame live below it.
    top: usize = 0,
    /// Return address inside the function that owns this frame; 0 where the
    /// chain ran out.
    pc: usize = 0,
};

threadlocal var diag_frames: [diag_max_frames]DiagFrame = @splat(.{});
threadlocal var diag_frame_count: usize = 0;
threadlocal var diag_frames_truncated: bool = false;
/// `diag_word.sp` of the scan `diag_frames` was built for; 0 = no table.
threadlocal var diag_frames_for_sp: usize = 0;

fn diagCaptureFrames(w: DiagWord) void {
    diag_frame_count = 0;
    diag_frames_truncated = false;
    diag_frames_for_sp = w.sp;
    var fp = @frameAddress();
    var count: usize = 0;
    while (count < diag_max_frames) {
        if (!std.mem.isAligned(fp, @sizeOf(usize))) break;
        if (fp + 2 * @sizeOf(usize) > w.high) break;
        const next_fp = @as(*const usize, @ptrFromInt(fp)).*;
        const return_address = @as(*const usize, @ptrFromInt(fp + @sizeOf(usize))).*;
        // A frame chain is strictly ascending and stays inside the stack.
        if (next_fp <= fp or next_fp >= w.high) break;
        if (return_address < 4096) break;
        diag_frames[count] = .{ .top = next_fp, .pc = return_address };
        count += 1;
        fp = next_fp;
    }
    diag_frames_truncated = count == diag_max_frames;
    diag_frame_count = count;
}

/// Return addresses inside the engine function whose frame owns `addr` and
/// inside its caller, or 0 where the chain gave no answer.
///
/// The caller is worth a second slot because AAPCS64 (and SysV) make a
/// prologue save its CALLER's callee-saved registers into its OWN frame: a
/// `*Object` the mutator was holding in x19 across a call is found in the
/// frame of whatever the mutator called, so the owner frame alone reads as
/// "pollGC" for a word the mutator owns. The pair separates the two.
fn diagOwnerPcs(w: DiagWord) struct { owner: usize, caller: usize, frame_base: usize } {
    if (diag_frames_for_sp != w.sp or w.high == 0) diagCaptureFrames(w);
    const frames = diag_frames[0..diag_frame_count];
    // Ascending tops: the owner is the first frame whose base is at or above
    // the slot.
    var lo: usize = 0;
    var hi: usize = frames.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (frames[mid].top >= w.addr) hi = mid else lo = mid + 1;
    }
    if (lo >= frames.len) return .{ .owner = 0, .caller = 0, .frame_base = 0 };
    // `frame_base` is what R1-b added: the owner frame's `fp`. A hit is only
    // actionable once you know WHERE in the frame the word sat -- a prologue
    // save slot (`fp - 16*k`) is the caller's register, a deep slot the
    // compiler reused is residue, and neither of those is a missing root.
    return .{
        .owner = frames[lo].pc,
        .caller = if (lo + 1 < frames.len) frames[lo + 1].pc else 0,
        .frame_base = frames[lo].top,
    };
}

/// Number of machine words in the register spill image.
pub const diag_register_words = if (target_supported) @sizeOf(SpillImage) / @sizeOf(usize) else 0;

fn diagRegisterName(index: usize, buf: []u8) []const u8 {
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

/// Process-wide conservative-only attribution.
///
/// NOT a `JSRuntime` field, and that is a correctness constraint rather than a
/// convenience. The census used to live in `gc.Registry`; growing it grew
/// `JSRuntime` by 112 KiB, which moved the allocator's threshold crossing and
/// bought the 500-pair young-cycle test one extra implicit minor before the
/// one it measures (2 minors -> 3, the measured minor reclaiming 328 instead of
/// 2003 while the cumulative total held at ~2000). A diagnosis that changes
/// when a collection runs is measuring itself. In `.bss` it costs the runtime
/// nothing in every build, so it cannot move collection timing again.
///
/// Being process-wide also fixes the reporting hole it was working around:
/// `run-test262` builds one runtime per test across several worker threads, so
/// a per-runtime table could never aggregate a sweep, and a JS atom is only
/// meaningful inside the runtime that minted it. Function names are therefore
/// interned as bytes at note time, and the table outlives every runtime.
/// One (owner frame pc, frame slot) site, tracked across every scan in the
/// process.
///
/// The residue signature R1-a had to find by hand -- the same slot resolving
/// to the same header collection after collection, in a frame phase that no
/// longer writes it -- is exactly what this table measures. A live local
/// changes what it points at as the mutator runs; a dead slot does not.
const StabilityEntry = struct {
    used: bool = false,
    pc: usize = 0,
    pc_index: u12 = 0,
    slot_bucket: u16 = 0,
    /// `run-test262` runs one runtime per worker thread on identical native
    /// frames, so (pc, slot) alone names EIGHT different slots whose contents
    /// have nothing to do with each other. Without this field the "same header
    /// as last time" test is destroyed by interleaving: the 2026-09-05 corpus
    /// read the known `eval` residue at 10% stability. Sites are per thread;
    /// the report merges them back per slot.
    thread_id: u32 = 0,
    /// Header the previous hit at this site resolved to.
    last_header: usize = 0,
    hits: usize = 0,
    /// Hits whose header equalled `last_header` at the time.
    stable_hits: usize = 0,
    exact_hits: usize = 0,
    prefix_hits: usize = 0,
    /// Bitmask over `gc.GcKind` of everything this slot ever resolved to.
    ///
    /// The second residue signature, and the sharper one: a Zig local has a
    /// static type, so a real root slot resolves to ONE kind forever. A dead
    /// slot holding a recycled address resolves to whatever cell now occupies
    /// it -- a function object on one collection, property storage on the
    /// next. Kind churn is the fingerprint of an address that means nothing.
    kinds: u16 = 0,
    /// Most recent offset bucket, for reporting.
    offset_bucket: u8 = 0,

    fn kindCount(self: StabilityEntry) usize {
        return @popCount(self.kinds);
    }
};

/// Dense per-thread id for the site table; 0 means "not yet assigned".
var diag_thread_counter: std.atomic.Value(u32) = .init(0);
threadlocal var diag_thread_id: u32 = 0;

fn diagThreadId() u32 {
    if (diag_thread_id == 0) diag_thread_id = diag_thread_counter.fetchAdd(1, .monotonic) +| 1;
    return diag_thread_id;
}

pub const RootsDiagCensus = struct {
    /// Where the machine word that named the object lived.
    ///
    /// `register` is the spill image; everything else is a native stack slot
    /// bucketed by how deep below the collector's own `sp` it sits, which
    /// separates "a local of the function that triggered the GC" from "residue
    /// far up the interpreter's call chain".
    ///
    /// There is deliberately no arm for `Stack.pendingCallRegion()`: that
    /// window lives in the heap-backed operand arena, so it is outside
    /// `[sp, stack high)` by construction and cannot be a word source. The
    /// 2026-09-05 sweep instrumented it anyway and measured 0 hits in
    /// 525,217 -- the probe was then removed rather than left costing the
    /// interpreter two thread-local stores per call-region publish.
    pub const Source = enum(u4) {
        register,
        stack_lt_1k,
        stack_lt_4k,
        stack_lt_16k,
        stack_lt_64k,
        stack_ge_64k,
        unknown,
    };
    pub const source_count = @typeInfo(Source).@"enum".fields.len;
    pub const PtrKind = enum(u2) { exact, prefix, interior };

    /// Interned return addresses of the frame-owning engine functions, and
    /// interned JS function names. 12 bits of key space each; `index_unknown`
    /// is the reserved escape for "no answer" and for table overflow.
    pub const pc_table_len = 1024;
    pub const name_table_len = 512;
    pub const name_max = 48;
    pub const index_unknown: u12 = 0xFFF;

    /// R1-b column 1: `word - header`, bucketed.
    ///
    /// `exact`/`prefix`/`interior` alone cannot separate a missing root from
    /// junk: an interior word at a fixed distance is what a live *field*
    /// pointer looks like, and so is a dead slot the compiler recycled. The
    /// distance itself is the discriminator, so it goes in the key.
    ///
    /// Encoding: 0 = exact (`word == header`), 1 = the metadata prefix
    /// (`header - 8`), 2 + n/8 for an interior word n bytes past the header
    /// (saturating at `>= 256`), 255 for anything else below the header.
    pub const offset_exact: u8 = 0;
    pub const offset_prefix: u8 = 1;
    pub const offset_interior_base: u8 = 2;
    pub const offset_interior_max: u8 = offset_interior_base + 32;
    pub const offset_below: u8 = 255;

    fn offsetBucket(word: usize, header_addr: usize) u8 {
        if (word == header_addr) return offset_exact;
        if (word == header_addr - gc.metadata_prefix_size) return offset_prefix;
        if (word < header_addr) return offset_below;
        const delta = (word - header_addr) / @sizeOf(usize);
        return @min(offset_interior_base + @as(u8, @intCast(@min(delta, 32))), offset_interior_max);
    }

    fn offsetBucketName(bucket: u8, buf: []u8) []const u8 {
        return switch (bucket) {
            offset_exact => "+0",
            offset_prefix => "-8",
            offset_below => "<hdr",
            offset_interior_max => ">=256",
            else => std.fmt.bufPrint(buf, "+{d}", .{@as(usize, bucket - offset_interior_base) * 8}) catch "?",
        };
    }

    /// R1-b column 2: `frame_base - word_address` in 8-byte units, i.e. how
    /// deep in the owner frame the slot sat. `slot_unknown` covers register
    /// and below-`sp` hits, which have no owner frame.
    pub const slot_unknown: u16 = 0xFFFF;

    /// AAPCS64/SysV prologues save the CALLER's callee-saved registers into
    /// the callee's own frame, immediately below the frame record, in pairs.
    /// A hit in that band is "someone else's register", not a local of the
    /// frame it is attributed to. Ten AArch64 GPR pairs (x19-x28) plus the
    /// d8-d15 band fit in 160 bytes; the constant is deliberately generous,
    /// because over-calling `likely_spill` only shortens the R1 worklist with
    /// frames the caller has to own anyway.
    pub const callee_saved_span: usize = 160;

    /// Three-way reading of one (frame, slot) site.
    pub const Verdict = enum {
        /// Same slot, same header, scan after scan, and not a header-exact
        /// word: a dead stack slot the compiler recycled. Rooting cannot fix
        /// it; only scrubbing or a smaller frame can.
        likely_residue,
        /// A header-exact (or metadata-prefix) word inside the prologue save
        /// band: the caller's register, spilled by the callee. The owner of
        /// the reference is the caller, so the frame it is billed to is the
        /// wrong place to look.
        likely_spill,
        /// Everything else: a word that behaves like a real reference held in
        /// a real local. This is the R1 worklist.
        candidate_root,
    };
    pub const verdict_count = @typeInfo(Verdict).@"enum".fields.len;

    pub const Key = packed struct(u128) {
        /// Index into `names`, or `index_unknown`.
        name_index: u12,
        class_id: u16,
        /// Index into `pcs` for the frame that owns the slot.
        pc_index: u12,
        /// Index into `pcs` for that frame's caller.
        caller_pc_index: u12,
        kind: u4,
        source: u4,
        ptr_kind: u2,
        young: u1,
        native: u1,
        offset_bucket: u8,
        slot_bucket: u16,
        // Stability is NOT part of the key: it is a property of the site over
        // time, so folding it in would split one site's row in two. It rides
        // alongside as `Slot.stable_count`.
        _pad: u40 = 0,
    };

    const Slot = struct {
        key: Key = @bitCast(@as(u128, 0)),
        count: usize = 0,
        stable_count: usize = 0,
        used: bool = false,
    };
    // Sized for headroom, not for footprint: the census is `.bss`, so a wider
    // table costs the runtime nothing. 4096 saturated (`dropped keys 329`) on
    // one test262 directory once the scan range was corrected.
    const slots_len = 16384;
    /// `.bss`, like the rest of the census, so a wide table is free. It lives
    /// OUTSIDE the census struct because `diagCensusSnapshot` copies the
    /// census by value for tests, and a megabyte of site table on a test
    /// thread's stack is not worth the tidiness.
    pub const stability_len = 65536;

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
    /// Distinct owner pcs / function names the intern tables could not hold.
    dropped_pcs: usize = 0,
    dropped_names: usize = 0,
    /// Scans whose frame walk hit the frame cap (attribution may be short).
    truncated_walks: usize = 0,
    by_source: [source_count]usize = @splat(0),
    by_ptr_kind: [3]usize = @splat(0),
    by_kind: [gc.gc_kind_count]usize = @splat(0),
    by_register: [if (diag_register_words == 0) 1 else diag_register_words]usize = @splat(0),
    /// Owner-pc intern table and its hit counts, kept independently of `slots`
    /// so the frame ranking survives key-table saturation.
    pcs: [pc_table_len]usize = @splat(0),
    pc_counts: [pc_table_len]usize = @splat(0),
    pc_stable_counts: [pc_table_len]usize = @splat(0),
    pc_used: usize = 0,
    /// Hits with no owner frame (register spill image, or below the scanner's
    /// own `sp`); they have no slot geometry and stay out of the verdict.
    unlocated: usize = 0,
    /// Distinct (frame, slot) sites the stability table could not hold.
    dropped_sites: usize = 0,
    names: [name_table_len][name_max]u8 = @splat(@splat(0)),
    name_lens: [name_table_len]u8 = @splat(0),
    names_used: usize = 0,

    /// One classified direct hit.
    const Record = struct {
        key: Key,
        source: Source,
        ptr_kind: PtrKind,
        kind: gc.GcKind,
        young: bool,
        register_index: ?usize,
        owner_pc: usize,
        caller_pc: usize,
        function_name: []const u8,
        truncated: bool,
        offset_bucket: u8,
        slot_bucket: u16,
        header_addr: usize,
    };

    fn hashKey(key: Key) usize {
        const bits: u128 = @bitCast(key);
        const folded: u64 = @truncate(bits ^ (bits >> 64));
        return @intCast((folded *% 0x9E37_79B9_7F4A_7C15) >> (64 - 12));
    }

    fn currentFunction(rt: *const JSRuntime) struct { name: []const u8, native: bool } {
        if (rt.hot.current_backtrace_frame) |frame| {
            if (frame.resolver(frame.data, 0)) |snapshot| {
                if (snapshot.function_name != 0) {
                    const name = rt.atoms.name(snapshot.function_name) orelse "<anonymous>";
                    return .{ .name = name, .native = snapshot.is_native };
                }
                return .{ .name = "<anonymous>", .native = snapshot.is_native };
            }
        }
        return .{ .name = "", .native = false };
    }

    fn internName(self: *RootsDiagCensus, name: []const u8) u12 {
        if (name.len == 0) return index_unknown;
        const text = name[0..@min(name.len, name_max)];
        var index: usize = 0;
        while (index < self.names_used) : (index += 1) {
            if (std.mem.eql(u8, self.names[index][0..self.name_lens[index]], text)) return @intCast(index);
        }
        if (self.names_used == name_table_len) {
            self.dropped_names += 1;
            return index_unknown;
        }
        @memcpy(self.names[self.names_used][0..text.len], text);
        self.name_lens[self.names_used] = @intCast(text.len);
        self.names_used += 1;
        return @intCast(self.names_used - 1);
    }

    fn internPcSilent(self: *RootsDiagCensus, pc: usize) u12 {
        if (pc == 0) return index_unknown;
        var index: usize = 0;
        while (index < self.pc_used) : (index += 1) {
            if (self.pcs[index] == pc) return @intCast(index);
        }
        if (self.pc_used == pc_table_len) {
            self.dropped_pcs += 1;
            return index_unknown;
        }
        self.pcs[self.pc_used] = pc;
        self.pc_counts[self.pc_used] = 0;
        self.pc_used += 1;
        return @intCast(self.pc_used - 1);
    }

    fn internPc(self: *RootsDiagCensus, pc: usize) u12 {
        const index = self.internPcSilent(pc);
        if (index != index_unknown) self.pc_counts[index] += 1;
        return index;
    }

    fn classify(rt: *const JSRuntime, header: *const gc.Header, w: DiagWord) Record {
        const meta = header.metaConst();
        const header_addr = @intFromPtr(header);
        const ptr_kind: PtrKind = if (w.word == header_addr)
            .exact
        else if (w.word == header_addr - gc.metadata_prefix_size)
            .prefix
        else
            .interior;
        const offset_bucket = offsetBucket(w.word, header_addr);
        var slot_bucket: u16 = slot_unknown;
        var source: Source = undefined;
        var register_index: ?usize = null;
        var owner_pc: usize = 0;
        var caller_pc: usize = 0;
        if (w.addr >= w.image_lo and w.addr < w.image_hi) {
            source = .register;
            register_index = (w.addr - w.image_lo) / @sizeOf(usize);
        } else if (w.addr < w.sp) {
            source = .unknown;
        } else {
            const owners = diagOwnerPcs(w);
            owner_pc = owners.owner;
            caller_pc = owners.caller;
            if (owners.frame_base >= w.addr) {
                slot_bucket = @intCast(@min((owners.frame_base - w.addr) / @sizeOf(usize), slot_unknown - 1));
            }
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
        const function = currentFunction(rt);
        const class_id: u16 = if (meta.flags.kind == .object)
            @intCast(object_mod.Object.fromHeaderConst(header).class_id)
        else
            0;
        return .{
            .key = .{
                .name_index = index_unknown,
                .class_id = class_id,
                .pc_index = index_unknown,
                .caller_pc_index = index_unknown,
                .kind = @intCast(@intFromEnum(meta.flags.kind)),
                .source = @intFromEnum(source),
                .ptr_kind = @intFromEnum(ptr_kind),
                .young = @intFromBool(meta.flags.young),
                .native = @intFromBool(function.native),
                .offset_bucket = offset_bucket,
                .slot_bucket = slot_bucket,
            },
            .source = source,
            .ptr_kind = ptr_kind,
            .kind = meta.flags.kind,
            .young = meta.flags.young,
            .register_index = register_index,
            .owner_pc = owner_pc,
            .caller_pc = caller_pc,
            .function_name = function.name,
            .truncated = diag_frames_truncated,
            .offset_bucket = offset_bucket,
            .slot_bucket = slot_bucket,
            .header_addr = header_addr,
        };
    }

    /// Fold one hit into the (frame, slot) stability table and report whether
    /// the site resolved to the same header as last time.
    fn noteSite(self: *RootsDiagCensus, record: Record, pc_index: u12) bool {
        if (record.owner_pc == 0 or record.slot_bucket == slot_unknown) {
            self.unlocated += 1;
            return false;
        }
        const thread_id = diagThreadId();
        const kind_bit = @as(u16, 1) << @intCast(record.key.kind);
        var index: usize = @intCast((record.owner_pc ^
            (@as(usize, record.slot_bucket) *% 0x9E37_79B9) ^
            (@as(usize, thread_id) *% 0x85EB_CA6B)) % stability_len);
        var probed: usize = 0;
        while (probed < stability_len) : (probed += 1) {
            const entry = &diag_sites[index];
            if (!entry.used) {
                entry.* = .{
                    .used = true,
                    .pc = record.owner_pc,
                    .pc_index = pc_index,
                    .slot_bucket = record.slot_bucket,
                    .thread_id = thread_id,
                    .last_header = record.header_addr,
                    .hits = 1,
                    .stable_hits = 0,
                    .exact_hits = @intFromBool(record.ptr_kind == .exact),
                    .prefix_hits = @intFromBool(record.ptr_kind == .prefix),
                    .kinds = kind_bit,
                    .offset_bucket = record.offset_bucket,
                };
                return false;
            }
            if (entry.pc == record.owner_pc and
                entry.slot_bucket == record.slot_bucket and
                entry.thread_id == thread_id)
            {
                const stable = entry.last_header == record.header_addr;
                entry.hits += 1;
                if (stable) entry.stable_hits += 1;
                if (record.ptr_kind == .exact) entry.exact_hits += 1;
                if (record.ptr_kind == .prefix) entry.prefix_hits += 1;
                entry.kinds |= kind_bit;
                entry.last_header = record.header_addr;
                entry.offset_bucket = record.offset_bucket;
                return stable;
            }
            index = (index + 1) % stability_len;
        }
        self.dropped_sites += 1;
        return false;
    }

    /// Distinct kinds above which a slot cannot be a typed Zig local.
    ///
    /// Two is not enough on its own: `?*Object` versus a payload cell, or a
    /// rope versus a string, are both one source-level type. Three separate
    /// GC kinds through one stack slot is not a type, it is an address.
    pub const kind_churn_floor: usize = 3;

    fn entryVerdict(entry: StabilityEntry) Verdict {
        // Signature 1: same slot, same header, collection after collection --
        // the slot is not being written at all.
        //
        // Gated on non-exactness: a header-exact word is the one shape residue
        // essentially never takes, and an exact word that keeps naming the same
        // header is the signature of a long-lived REAL root, which must stay on
        // the worklist.
        //
        // The first hit at a site can never be stable, so a rate can only clear
        // 90% honestly once the site has been seen a few times.
        const non_exact = entry.hits - entry.exact_hits;
        if (non_exact * 2 > entry.hits) {
            if (entry.hits >= 4 and entry.stable_hits * 10 > entry.hits * 9) return .likely_residue;
        }
        // Signature 2: the slot resolves to a different KIND of cell over time.
        // This is the one that catches residue whose word is rewritten each
        // script (the `eval` compile-phase slots), where header stability is
        // diluted to nothing by construction.
        //
        // Deliberately OUTSIDE the non-exact gate (R1-d). A real root slot is a
        // typed Zig local, so its static type pins the kind no matter how the
        // word was formed; kind drift and pointer exactness are independent
        // facts. Under the old gate an exact-and-churning slot -- `stringCall`
        // fp-488, 1103 hits, 79% stable, five kinds -- could never be called
        // anything but `candidate`, so the R1 worklist carried dead slots that
        // no root can fix.
        if (entry.kindCount() >= kind_churn_floor) return .likely_residue;
        const exactish = entry.exact_hits + entry.prefix_hits;
        if (exactish * 2 > entry.hits and @as(usize, entry.slot_bucket) * @sizeOf(usize) <= callee_saved_span) {
            return .likely_spill;
        }
        return .candidate_root;
    }

    fn apply(self: *RootsDiagCensus, record: Record) void {
        self.direct += 1;
        if (record.young) self.direct_young += 1;
        if (record.truncated) self.truncated_walks += 1;
        if (record.register_index) |index| {
            if (index < self.by_register.len) self.by_register[index] += 1;
        }
        self.by_source[@intFromEnum(record.source)] += 1;
        self.by_ptr_kind[@intFromEnum(record.ptr_kind)] += 1;
        self.by_kind[@intFromEnum(record.kind)] += 1;
        var key = record.key;
        key.name_index = self.internName(record.function_name);
        const pc_index = self.internPc(record.owner_pc);
        key.pc_index = pc_index;
        // Interned without a hit count: the frame ranking counts owners only,
        // so a caller does not double-count.
        key.caller_pc_index = self.internPcSilent(record.caller_pc);
        const stable = self.noteSite(record, pc_index);
        if (stable and pc_index != index_unknown) self.pc_stable_counts[pc_index] += 1;
        var index = hashKey(key);
        var probed: usize = 0;
        while (probed < slots_len) : (probed += 1) {
            const slot = &self.slots[index];
            if (!slot.used) {
                slot.* = .{ .key = key, .count = 1, .stable_count = @intFromBool(stable), .used = true };
                return;
            }
            if (@as(u128, @bitCast(slot.key)) == @as(u128, @bitCast(key))) {
                slot.count += 1;
                if (stable) slot.stable_count += 1;
                return;
            }
            index = (index + 1) % slots_len;
        }
        self.dropped_keys += 1;
    }

    fn nameAt(self: *const RootsDiagCensus, index: u12) []const u8 {
        if (index == index_unknown or index >= self.names_used) return "<no frame>";
        return self.names[index][0..self.name_lens[index]];
    }

    fn percent(part: usize, whole: usize) usize {
        if (whole == 0) return 0;
        return part * 100 / whole;
    }

    fn slotName(bucket: u16, buf: []u8) []const u8 {
        if (bucket == slot_unknown) return "n/a";
        return std.fmt.bufPrint(buf, "fp-{d}", .{@as(usize, bucket) * @sizeOf(usize)}) catch "?";
    }

    /// Sum the per-thread entries for one (frame, slot) back into a single
    /// site. `last_header` is meaningless once merged and is left at zero.
    fn mergeSite(pc: usize, slot_bucket: u16) StabilityEntry {
        var merged: StabilityEntry = .{ .used = true, .pc = pc, .slot_bucket = slot_bucket };
        for (diag_sites) |entry| {
            if (!entry.used or entry.pc != pc or entry.slot_bucket != slot_bucket) continue;
            merged.hits += entry.hits;
            merged.stable_hits += entry.stable_hits;
            merged.exact_hits += entry.exact_hits;
            merged.prefix_hits += entry.prefix_hits;
            merged.kinds |= entry.kinds;
            merged.offset_bucket = entry.offset_bucket;
            merged.pc_index = entry.pc_index;
        }
        return merged;
    }

    /// Distinct slots (not per-thread entries) the scan hit in this frame.
    fn siteCountFor(pc: usize) usize {
        var count: usize = 0;
        for (diag_sites, 0..) |entry, index| {
            if (!entry.used or entry.pc != pc) continue;
            var duplicate = false;
            for (diag_sites[0..index]) |earlier| {
                if (earlier.used and earlier.pc == pc and earlier.slot_bucket == entry.slot_bucket) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) count += 1;
        }
        return count;
    }

    /// The R1-b payload for a frame: which slots in it the scan keeps hitting,
    /// how sticky each one is, and the verdict that follows.
    fn writeTopSites(writer: *std.Io.Writer, pc: usize, limit: usize) !void {
        // Successive maxima over MERGED slots: the table is `.bss` and cannot
        // be reordered, `limit` is 3, and per-thread entries for one slot must
        // read as one line.
        var printed: [8]u16 = @splat(slot_unknown);
        var shown: usize = 0;
        while (shown < limit and shown < printed.len) : (shown += 1) {
            var best: ?StabilityEntry = null;
            for (diag_sites) |entry| {
                if (!entry.used or entry.pc != pc) continue;
                if (std.mem.indexOfScalar(u16, printed[0..shown], entry.slot_bucket) != null) continue;
                const merged = mergeSite(pc, entry.slot_bucket);
                if (best) |current| {
                    if (merged.hits <= current.hits) continue;
                }
                best = merged;
            }
            const entry = best orelse return;
            printed[shown] = entry.slot_bucket;
            var offset_buf: [16]u8 = undefined;
            var slot_buf: [24]u8 = undefined;
            try writer.print("      site slot={s} off={s} hits={d} stable={d}% exact={d} prefix={d} kinds={d} verdict={s}\n", .{
                slotName(entry.slot_bucket, &slot_buf),
                offsetBucketName(entry.offset_bucket, &offset_buf),
                entry.hits,
                percent(entry.stable_hits, entry.hits),
                entry.exact_hits,
                entry.prefix_hits,
                entry.kindCount(),
                @tagName(entryVerdict(entry)),
            });
        }
    }

    /// Per owner frame, split its hits three ways. This is the table R1 reads:
    /// only the `candidate_root` column can be answered with a root.
    fn reportVerdicts(self: *const RootsDiagCensus, writer: *std.Io.Writer) !void {
        // Classified per THREAD entry rather than per merged slot: merging
        // inside this loop would be quadratic in the site table, and each
        // thread's entry already carries thousands of hits. The per-slot lines
        // in the frame table above are merged and can therefore differ from
        // the sum here when one slot's threads disagree.
        var totals: [pc_table_len][verdict_count]usize = @splat(@splat(0));
        var overall: [verdict_count]usize = @splat(0);
        for (diag_sites) |entry| {
            if (!entry.used) continue;
            const verdict = entryVerdict(entry);
            overall[@intFromEnum(verdict)] += entry.hits;
            if (entry.pc_index == index_unknown or entry.pc_index >= self.pc_used) continue;
            totals[entry.pc_index][@intFromEnum(verdict)] += entry.hits;
        }
        const located = overall[0] + overall[1] + overall[2];
        try writer.print(
            "gc: ===== R1-b verdict: located {d} (residue {d} = {d}%, spill {d} = {d}%, candidate {d} = {d}%), unlocated {d} =====\n",
            .{
                located,
                overall[@intFromEnum(Verdict.likely_residue)],
                percent(overall[@intFromEnum(Verdict.likely_residue)], located),
                overall[@intFromEnum(Verdict.likely_spill)],
                percent(overall[@intFromEnum(Verdict.likely_spill)], located),
                overall[@intFromEnum(Verdict.candidate_root)],
                percent(overall[@intFromEnum(Verdict.candidate_root)], located),
                self.unlocated,
            },
        );
        var order: [pc_table_len]usize = undefined;
        var used: usize = 0;
        while (used < self.pc_used) : (used += 1) order[used] = used;
        const Sorter = struct {
            fn frameTotal(row: [verdict_count]usize) usize {
                return row[0] + row[1] + row[2];
            }
            fn more(all: *const [pc_table_len][verdict_count]usize, a: usize, b: usize) bool {
                return frameTotal(all[a]) > frameTotal(all[b]);
            }
        };
        std.mem.sort(usize, order[0..used], &totals, Sorter.more);
        const shown = @min(used, 30);
        try writer.print("gc: R1-b verdict top {d} owner frames (residue / spill / candidate)\n", .{shown});
        for (order[0..shown], 1..) |index, rank| {
            const row = totals[index];
            const total = Sorter.frameTotal(row);
            if (total == 0) break;
            const dominant: Verdict = blk: {
                var best: Verdict = .candidate_root;
                var best_count: usize = 0;
                inline for (0..verdict_count) |v| {
                    if (row[v] > best_count) {
                        best_count = row[v];
                        best = @enumFromInt(v);
                    }
                }
                break :blk best;
            };
            try writer.print("gc: R1-b verdict #{d} {d} residue={d} spill={d} candidate={d} => {s} pc=0x{x}\n", .{
                rank,
                total,
                row[@intFromEnum(Verdict.likely_residue)],
                row[@intFromEnum(Verdict.likely_spill)],
                row[@intFromEnum(Verdict.candidate_root)],
                @tagName(dominant),
                self.pcs[index],
            });
            try writeOwnerPc(writer, self.pcs[index]);
        }
    }

    fn writeOwnerPc(writer: *std.Io.Writer, pc: usize) !void {
        if (pc == 0) {
            try writer.print("        <no frame>\n", .{});
            return;
        }
        var addresses = [_]usize{pc};
        const trace: std.debug.StackTrace = .{
            .return_addresses = addresses[0..],
            .skipped = .none,
        };
        std.debug.writeStackTrace(&trace, .{ .writer = writer, .mode = .no_color }) catch {
            try writer.print("        0x{x}\n", .{pc});
        };
    }

    pub fn report(self: *const RootsDiagCensus, writer: *std.Io.Writer) !void {
        try writer.print(
            "gc: conservative-only census probes {d}, direct {d} (young {d}), transitive {d}, dropped keys {d}, dropped pcs {d}, dropped names {d}, dropped sites {d}, truncated walks {d}, unlocated {d}\n",
            .{ self.probes, self.direct, self.direct_young, self.transitive, self.dropped_keys, self.dropped_pcs, self.dropped_names, self.dropped_sites, self.truncated_walks, self.unlocated },
        );
        try writer.print("gc: conservative-only by source", .{});
        for (self.by_source, 0..) |count, source_index| {
            const source: Source = @enumFromInt(source_index);
            try writer.print(" {s} {d}", .{ @tagName(source), count });
        }
        try writer.print("; by pointer exact {d}, prefix {d}, interior {d}\n", .{
            self.by_ptr_kind[0], self.by_ptr_kind[1], self.by_ptr_kind[2],
        });
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

        // Owner-frame ranking: which engine function's native frame held the
        // rescuing word. This is the R1 worklist -- each line is a Zig local
        // that production would have to root precisely.
        {
            var order: [pc_table_len]usize = undefined;
            var used: usize = 0;
            while (used < self.pc_used) : (used += 1) order[used] = used;
            const counts = &self.pc_counts;
            std.mem.sort(usize, order[0..used], counts, struct {
                fn moreHits(c: *const [pc_table_len]usize, a: usize, b: usize) bool {
                    return c[a] > c[b];
                }
            }.moreHits);
            const shown = @min(used, 30);
            try writer.print("gc: conservative-only top {d} of {d} owner frames\n", .{ shown, used });
            for (order[0..shown], 1..) |index, rank| {
                try writer.print("gc: conservative-only frame #{d} {d} stable={d}% sites={d} pc=0x{x}\n", .{
                    rank,
                    self.pc_counts[index],
                    percent(self.pc_stable_counts[index], self.pc_counts[index]),
                    siteCountFor(self.pcs[index]),
                    self.pcs[index],
                });
                try writeTopSites(writer, self.pcs[index], 3);
                try writeOwnerPc(writer, self.pcs[index]);
            }
        }

        try self.reportVerdicts(writer);

        // Indices, not copies: `Slot` grew past 32 bytes in R1-b and a
        // by-value ranking array would put 640 KiB on the reporting thread's
        // stack.
        var ranked: [slots_len]u32 = undefined;
        var used: usize = 0;
        for (self.slots, 0..) |slot, slot_index| {
            if (!slot.used) continue;
            ranked[used] = @intCast(slot_index);
            used += 1;
        }
        std.mem.sort(u32, ranked[0..used], &self.slots, struct {
            fn moreHits(all: *const [slots_len]Slot, a: u32, b: u32) bool {
                return all[a].count > all[b].count;
            }
        }.moreHits);
        const shown = @min(used, 30);
        try writer.print("gc: conservative-only top {d} of {d} keys (function, kind/class, source, pointer, offset, slot, stability, young, native, frame)\n", .{ shown, used });
        for (ranked[0..shown], 1..) |slot_index, rank| {
            const slot = self.slots[slot_index];
            const key = slot.key;
            const kind: gc.GcKind = @enumFromInt(key.kind);
            const source: Source = @enumFromInt(key.source);
            const ptr_kind: PtrKind = @enumFromInt(key.ptr_kind);
            const owner_pc: usize = if (key.pc_index == index_unknown) 0 else self.pcs[key.pc_index];
            const caller_pc: usize = if (key.caller_pc_index == index_unknown) 0 else self.pcs[key.caller_pc_index];
            var offset_buf: [16]u8 = undefined;
            var slot_buf: [24]u8 = undefined;
            try writer.print(
                "gc: conservative-only #{d} {d} fn={s} kind={s} class={d} src={s} ptr={s} off={s} slot={s} stable={d}% young={d} native={d} pc=0x{x} caller=0x{x}\n",
                .{
                    rank,                                 slot.count,
                    self.nameAt(key.name_index),          @tagName(kind),
                    key.class_id,                         @tagName(source),
                    @tagName(ptr_kind),                   offsetBucketName(key.offset_bucket, &offset_buf),
                    slotName(key.slot_bucket, &slot_buf), percent(slot.stable_count, slot.count),
                    key.young,                            key.native,
                    owner_pc,                             caller_pc,
                },
            );
            if (owner_pc != 0) try writeOwnerPc(writer, owner_pc);
            if (caller_pc != 0) {
                try writer.print("    caller:\n", .{});
                try writeOwnerPc(writer, caller_pc);
            }
        }
    }
};

var global: RootsDiagCensus = .{};
/// See `RootsDiagCensus.stability_len`.
var diag_sites: [RootsDiagCensus.stability_len]StabilityEntry = @splat(.{});

/// Diagnostic-only spinlock. `std.Io.Mutex` needs an `Io` to unlock and the
/// census is updated from the middle of a stop-the-world scan, which has none;
/// contention is one worker thread per test262 collection, so a test-and-set
/// is enough.
const GlobalLock = struct {
    held: std.atomic.Value(bool) = .init(false),

    fn lock(self: *GlobalLock) void {
        while (self.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *GlobalLock) void {
        self.held.store(false, .release);
    }
};
var global_mutex: GlobalLock = .{};

/// Direct hits this thread has recorded. `computeFullReachable` needs the
/// delta for one probe, and the shared counter is not a per-probe quantity
/// once test262 runs a runtime per worker thread.
threadlocal var thread_direct: usize = 0;

pub inline fn diagThreadDirect() usize {
    return if (comptime gc.roots_diag_enabled) thread_direct else 0;
}

/// Record one direct conservative-only root. `header` was unmarked before the
/// shade and is marked now; `w` is the word that named it.
pub fn noteDirect(rt: *const JSRuntime, header: *const gc.Header, w: DiagWord) void {
    if (comptime !gc.roots_diag_enabled) return;
    const record = RootsDiagCensus.classify(rt, header, w);
    thread_direct += 1;
    global_mutex.lock();
    defer global_mutex.unlock();
    global.apply(record);
}

/// Close one probe: `conservative_only` is the number of headers the probe's
/// conservative arm marked in total, `direct` how many of those were hit by a
/// word of their own.
pub fn noteProbe(conservative_only: usize, direct: usize) void {
    if (comptime !gc.roots_diag_enabled) return;
    global_mutex.lock();
    defer global_mutex.unlock();
    global.probes += 1;
    global.transitive += conservative_only -| direct;
}

/// Print the process-wide census. Safe to call after every runtime is gone.
pub fn reportGlobal(writer: *std.Io.Writer) !void {
    if (comptime !gc.roots_diag_enabled) return;
    global_mutex.lock();
    defer global_mutex.unlock();
    try writer.print("gc: ===== R3 process-wide conservative-only attribution =====\n", .{});
    try global.report(writer);
}

/// Verdict for the (frame, slot) site that last resolved to `header_addr`,
/// or null if no site did.
///
/// For tests: each one allocates its own object, so the header address is a
/// unique handle into the process-wide site table without needing a delta.
fn diagVerdictForHeader(header_addr: usize) ?RootsDiagCensus.Verdict {
    if (comptime !gc.roots_diag_enabled) return null;
    global_mutex.lock();
    defer global_mutex.unlock();
    var best: ?StabilityEntry = null;
    for (diag_sites) |entry| {
        if (!entry.used or entry.last_header != header_addr) continue;
        if (best) |current| {
            if (entry.hits <= current.hits) continue;
        }
        best = entry;
    }
    const entry = best orelse return null;
    return RootsDiagCensus.entryVerdict(entry);
}

/// Snapshot for tests, which must not race the shared table.
fn diagCensusSnapshot() RootsDiagCensus {
    global_mutex.lock();
    defer global_mutex.unlock();
    return global;
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
    try std.testing.expect(metrics.candidates > 0);
}

test "R3 census names the native frame that rescued an unrooted stack JSValue" {
    // The census only exists in the diagnosis build, and so does the frame
    // pointer the walk needs; `zig build test -Dzjs_gc_roots_diag=true` is the
    // configuration this asserts.
    if (comptime !gc.roots_diag_enabled) return error.SkipZigTest;

    const rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const object = try object_mod.Object.create(rt, @import("class.zig").ids.object, null);
    const target: *gc.Header = object.gcHeader();

    // The dependency R1 has to retire: a heap reference whose only holder is a
    // Zig local. Taking the address forces it into a real stack slot instead of
    // a callee-saved register, so the expected source is the native stack and
    // not the spill image.
    var slot: [1]usize = .{@intFromPtr(target)};
    std.mem.doNotOptimizeAway(&slot);

    // The census is process-wide, so the assertions are deltas against a
    // snapshot rather than absolutes.
    const before = diagCensusSnapshot();

    const Probe = struct {
        rt: *JSRuntime,
        target: *gc.Header,

        fn shade(context: *anyopaque, header: *gc.Header) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (header != self.target) return;
            noteDirect(self.rt, header, diagCurrentWord());
        }
    };
    var probe: Probe = .{ .rt = rt, .target = target };
    var metrics: Metrics = .{};
    spillRegistersAndScan(rt, &metrics, Probe.shade, &probe);
    std.mem.doNotOptimizeAway(&slot);

    const after = diagCensusSnapshot();
    try std.testing.expect(metrics.candidates > 0);
    try std.testing.expect(after.direct > before.direct);

    var stack_hits: usize = 0;
    for ([_]RootsDiagCensus.Source{
        .stack_lt_1k, .stack_lt_4k, .stack_lt_16k, .stack_lt_64k, .stack_ge_64k,
    }) |source| {
        const index = @intFromEnum(source);
        stack_hits += after.by_source[index] - before.by_source[index];
    }
    try std.testing.expect(stack_hits > 0);
    // The word was named by the slot's own address, so the hit is exact rather
    // than an interior or metadata-prefix alias.
    const exact = @intFromEnum(RootsDiagCensus.PtrKind.exact);
    try std.testing.expect(after.by_ptr_kind[exact] > before.by_ptr_kind[exact]);
    // And the frame walk produced an owner, which is the whole point: R1 needs
    // the engine function, not just "somewhere on the stack".
    try std.testing.expect(after.pc_used > 0);

    var found_stack_key = false;
    for (after.slots) |census_slot| {
        if (!census_slot.used) continue;
        const source: RootsDiagCensus.Source = @enumFromInt(census_slot.key.source);
        switch (source) {
            .stack_lt_1k, .stack_lt_4k, .stack_lt_16k, .stack_lt_64k, .stack_ge_64k => {
                if (census_slot.key.pc_index != RootsDiagCensus.index_unknown) found_stack_key = true;
            },
            else => {},
        }
    }
    try std.testing.expect(found_stack_key);
}

/// Run `count` scans from a frame that keeps `slot` alive, recording ONLY the
/// hit whose word came out of `slot` itself.
///
/// `noinline` and the loop are both load-bearing: the site table keys on the
/// return address plus the slot's distance from `fp`, and both have to be
/// identical across iterations for a stability rate to mean anything. The
/// address filter is what makes the assertion about one site rather than about
/// whichever copy of the pointer the compiler left lying around.
noinline fn diagRescanFixedSlot(rt: *JSRuntime, slot: *[1]usize, count: usize) void {
    const Probe = struct {
        rt: *JSRuntime,
        slot: usize,

        fn shade(context: *anyopaque, header: *gc.Header) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            const w = diagCurrentWord();
            if (w.addr != self.slot) return;
            noteDirect(self.rt, header, w);
        }
    };
    var probe: Probe = .{ .rt = rt, .slot = @intFromPtr(slot) };
    var round: usize = 0;
    while (round < count) : (round += 1) {
        var metrics: Metrics = .{};
        std.mem.doNotOptimizeAway(slot);
        spillRegistersAndScan(rt, &metrics, Probe.shade, &probe);
        std.mem.doNotOptimizeAway(slot);
    }
}

test "R1-b verdict calls a stale interior slot residue" {
    if (comptime !gc.roots_diag_enabled) return error.SkipZigTest;

    const rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const object = try object_mod.Object.create(rt, @import("class.zig").ids.object, null);
    const target: *gc.Header = object.gcHeader();

    // The R1-a signature, reproduced deliberately: one stack slot holding an
    // INTERIOR word into a heap cell, never rewritten between scans. No root
    // can fix this shape, so the census has to say so rather than carry it on
    // the R1 worklist as a missing root.
    //
    // This is signature 1 specifically: the word is interior (so the non-exact
    // gate opens) and the header never changes. One kind throughout, so the
    // kind-churn arm stays silent and the verdict below is the stability arm's
    // alone.
    var stale: [1]usize = .{@intFromPtr(target) + @sizeOf(usize)};
    diagRescanFixedSlot(rt, &stale, 16);
    std.mem.doNotOptimizeAway(&stale);

    try std.testing.expectEqual(
        @as(?RootsDiagCensus.Verdict, .likely_residue),
        diagVerdictForHeader(@intFromPtr(target)),
    );
}

test "R1-b verdict calls a bare exact pointer in a deep slot a candidate root" {
    if (comptime !gc.roots_diag_enabled) return error.SkipZigTest;

    const rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    // A fresh object per test: the header address is the handle the verdict
    // lookup keys on, so two tests must not share one.
    const first = try object_mod.Object.create(rt, @import("class.zig").ids.object, null);
    const second = try object_mod.Object.create(rt, @import("class.zig").ids.object, null);

    // Deep enough in the frame that the slot cannot be read as the prologue's
    // callee-saved save band, chosen against the real `fp` rather than trusting
    // the compiler to order locals.
    var cells: [64]usize = @splat(0);
    const frame_base = @frameAddress();
    var index: usize = 0;
    while (index < cells.len) : (index += 1) {
        if (frame_base -| @intFromPtr(&cells[index]) > RootsDiagCensus.callee_saved_span) break;
    }
    if (index == cells.len) return error.SkipZigTest;
    const slot: *[1]usize = @ptrCast(&cells[index]);

    // A real unrooted local: header-exact, and naming a different object in
    // the second half of the run. Changing what it points at is precisely what
    // a live local does and dead residue does not.
    //
    // Both halves name an `object`, so the site sees exactly one kind. That is
    // what keeps this a candidate now that the kind-churn arm runs outside the
    // non-exact gate: a typed local's kind does not drift, and neither does
    // this one.
    slot[0] = @intFromPtr(first.gcHeader());
    diagRescanFixedSlot(rt, slot, 3);
    slot[0] = @intFromPtr(second.gcHeader());
    diagRescanFixedSlot(rt, slot, 3);
    std.mem.doNotOptimizeAway(&cells);

    try std.testing.expectEqual(
        @as(?RootsDiagCensus.Verdict, .candidate_root),
        diagVerdictForHeader(@intFromPtr(second.gcHeader())),
    );
}

test "R1-b verdict calls an exact slot with drifting kinds residue" {
    if (comptime !gc.roots_diag_enabled) return error.SkipZigTest;

    const rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    // Three DIFFERENT kinds through one header-exact slot. Exactness and kind
    // drift are independent facts: a typed Zig local is exact AND single-kind,
    // so drift alone convicts the slot even when every word was a clean header
    // pointer. This is the R1-c `stringCall` fp-488 shape (exact, 79% stable,
    // five kinds) that the pre-R1-d rule could only ever call a candidate.
    const object = try object_mod.Object.create(rt, @import("class.zig").ids.object, null);
    const shape_ref = try rt.shapes.create(null);
    rt.shapes.publish(shape_ref);
    const cell = try @import("var_ref.zig").VarRef.createClosed(rt, @import("value.zig").JSValue.undefinedValue());

    var cells: [64]usize = @splat(0);
    const frame_base = @frameAddress();
    var index: usize = 0;
    while (index < cells.len) : (index += 1) {
        if (frame_base -| @intFromPtr(&cells[index]) > RootsDiagCensus.callee_saved_span) break;
    }
    if (index == cells.len) return error.SkipZigTest;
    const slot: *[1]usize = @ptrCast(&cells[index]);

    slot[0] = @intFromPtr(&shape_ref.header);
    diagRescanFixedSlot(rt, slot, 3);
    slot[0] = @intFromPtr(&cell.header);
    diagRescanFixedSlot(rt, slot, 3);
    slot[0] = @intFromPtr(object.gcHeader());
    diagRescanFixedSlot(rt, slot, 3);
    std.mem.doNotOptimizeAway(&cells);

    try std.testing.expectEqual(
        @as(?RootsDiagCensus.Verdict, .likely_residue),
        diagVerdictForHeader(@intFromPtr(object.gcHeader())),
    );
}

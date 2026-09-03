//! obj64 stride ablation (engine-external).
//!
//! Isolates the *line/stride* axis of the 96B → 80B → 64B object-cell ladder
//! without compiling the engine. Each cell is a packed `[metadata word][next]`
//! pair, matching the two loads `shadeExact` makes on a header before it
//! follows a child. Three visit orders:
//!
//! * `seq`   — packed 0..n-1. Models a linear dense scan (the shape the
//!             dense-array knife died on: adjacent-line prefetch covers it).
//! * `chase` — a random linked list through the same packed cells. Models
//!             the mark frontier (S0's "engine-faithful" arm).
//! * `shuf`  — shuffled indices into packed cells. Intermediate: random
//!             order, but the index array is extra traffic.
//!
//! Prefetch is one header ahead, the same depth the slab-reuse knife used.
//!
//! Kill line (from the S0 booking, ARM Cortex-X925): if the prefetch arm of
//! 64 vs 96 (or 64 vs 80) is <1.5% cycles AND <8% refill, the line axis is
//! dead. Booking runs bind `armv8_pmuv3_1/{instructions,cycles,l2d_cache_refill}`
//! through sysfs (not generic `PERF_COUNT_HW_*`) and fail closed if `--cpu`
//! cannot be applied or the named PMU does not own that CPU. On x86, wall
//! time is directional only.
//!
//!     zig build obj64-stride-ablation -Doptimize=ReleaseFast
//!     taskset -c 17 zig-out/bin/obj64-stride-ablation --cpu 17 --pmu armv8_pmuv3_1 \
//!         --cells 1048576 --repeats 8 --json obj64-stride.json
//!
//! Equal-work: every arm visits each cell once and XORs the same immutable
//! payload word, so the checksum is independent of visit order.

const std = @import("std");
const builtin = @import("builtin");

const cache_line: usize = 64;
const strides = [_]usize{ 64, 80, 96 };

const Order = enum { seq, chase, shuf };

const Arm = struct {
    stride: usize,
    order: Order,
    prefetch: bool,
};

const Sample = struct {
    ns: u64,
    checksum: u64,
    instructions: ?u64 = null,
    cycles: ?u64 = null,
    refill: ?u64 = null,
};

const default_booking_pmu = "armv8_pmuv3_1";

const PmuOpenError = error{
    PmuRequiresPinnedCpu,
    PmuNotFound,
    PmuCpuMismatch,
    PmuEventRejected,
    PmuPathTooLong,
};

const linux_perf = if (builtin.os.tag == .linux) LinuxPerf else struct {
    pmu_name: []const u8 = "none",
    refill_event: []const u8 = "none",
    bound: bool = false,
    pub fn open(_: OpenSpec) PmuOpenError!@This() {
        return .{};
    }
    pub fn close(_: *@This()) void {}
    pub fn enable(_: *@This()) void {}
    pub fn disable(_: *@This()) void {}
    pub fn read(_: *@This()) Counters {
        return .{};
    }
    pub const Counters = struct {
        instructions: ?u64 = null,
        cycles: ?u64 = null,
        refill: ?u64 = null,
    };
    pub const OpenSpec = LinuxPerf.OpenSpec;
};

const LinuxPerf = struct {
    ins_fd: i32 = -1,
    cyc_fd: i32 = -1,
    refill_fd: i32 = -1,
    pmu_name: []const u8 = "none",
    refill_event: []const u8 = "none",
    bound: bool = false,

    const Counters = struct {
        instructions: ?u64 = null,
        cycles: ?u64 = null,
        refill: ?u64 = null,
    };

    pub const OpenSpec = struct {
        pmu: []const u8,
        cpu: ?usize,
        require: bool,
    };

    fn openTyped(type_id: u32, config: u64, cpu: i32, group_fd: i32) i32 {
        var attr = std.os.linux.perf_event_attr{
            .type = @enumFromInt(type_id),
            .size = @sizeOf(std.os.linux.perf_event_attr),
            .config = config,
            .flags = .{
                .disabled = true,
                .inherit = true,
                .exclude_kernel = true,
                .exclude_hv = true,
            },
        };
        const rc = std.os.linux.perf_event_open(&attr, 0, cpu, group_fd, 0);
        const fd: isize = @bitCast(rc);
        if (fd < 0) return -1;
        return @intCast(fd);
    }

    fn closeFds(ins_fd: i32, cyc_fd: i32, refill_fd: i32) void {
        if (ins_fd >= 0) _ = std.os.linux.close(ins_fd);
        if (cyc_fd >= 0) _ = std.os.linux.close(cyc_fd);
        if (refill_fd >= 0) _ = std.os.linux.close(refill_fd);
    }

    fn cpuArg(cpu: ?usize) PmuOpenError!i32 {
        const n = cpu orelse return -1;
        return std.math.cast(i32, n) orelse error.PmuCpuMismatch;
    }

    fn openNamed(pmu: []const u8, cpu: i32) PmuOpenError!LinuxPerf {
        const type_id = (readSysfsU32(pmu, "type") catch return error.PmuNotFound) orelse return error.PmuNotFound;
        const ins = (readSysfsEvent(pmu, "instructions") catch return error.PmuNotFound) orelse return error.PmuNotFound;
        const cyc = (readSysfsEvent(pmu, "cycles") catch return error.PmuNotFound) orelse return error.PmuNotFound;
        const refill = (readSysfsEvent(pmu, "l2d_cache_refill") catch return error.PmuNotFound) orelse return error.PmuNotFound;
        // Group the three counters so RESET/ENABLE/DISABLE around each timed
        // arm is one ioctl on the leader. cpu>=0 counts only that CPU.
        const ins_fd = openTyped(type_id, ins, cpu, -1);
        const cyc_fd = openTyped(type_id, cyc, cpu, if (ins_fd >= 0) ins_fd else -1);
        const refill_fd = openTyped(type_id, refill, cpu, if (ins_fd >= 0) ins_fd else -1);
        if (ins_fd < 0 or cyc_fd < 0 or refill_fd < 0) {
            closeFds(ins_fd, cyc_fd, refill_fd);
            return error.PmuEventRejected;
        }
        return .{
            .ins_fd = ins_fd,
            .cyc_fd = cyc_fd,
            .refill_fd = refill_fd,
            .pmu_name = pmu,
            .refill_event = "l2d_cache_refill",
            .bound = true,
        };
    }

    fn openGenericHw(cpu: i32) LinuxPerf {
        return .{
            .ins_fd = openTyped(@intFromEnum(std.os.linux.PERF.TYPE.HARDWARE), @intFromEnum(std.os.linux.PERF.COUNT.HW.INSTRUCTIONS), cpu, -1),
            .cyc_fd = openTyped(@intFromEnum(std.os.linux.PERF.TYPE.HARDWARE), @intFromEnum(std.os.linux.PERF.COUNT.HW.CPU_CYCLES), cpu, -1),
            .refill_fd = openTyped(@intFromEnum(std.os.linux.PERF.TYPE.HARDWARE), @intFromEnum(std.os.linux.PERF.COUNT.HW.CACHE_MISSES), cpu, -1),
            .pmu_name = "generic-hw",
            .refill_event = "PERF_COUNT_HW_CACHE_MISSES",
            .bound = false,
        };
    }

    pub fn open(spec: OpenSpec) PmuOpenError!LinuxPerf {
        const cpu = try cpuArg(spec.cpu);
        const want_named = spec.require or switch (builtin.cpu.arch) {
            .aarch64, .aarch64_be => true,
            else => false,
        };
        if (want_named) {
            const pinned = spec.cpu orelse {
                if (spec.require) return error.PmuRequiresPinnedCpu;
                return .{ .pmu_name = "unbound", .refill_event = "none", .bound = false };
            };
            if (assertPmuOwnsCpu(spec.pmu, pinned)) |_| {
                return openNamed(spec.pmu, cpu) catch |err| {
                    if (spec.require) return err;
                    return .{ .pmu_name = spec.pmu, .refill_event = "none", .bound = false };
                };
            } else |err| {
                if (spec.require) return err;
                return .{ .pmu_name = spec.pmu, .refill_event = "none", .bound = false };
            }
        }
        var generic = openGenericHw(cpu);
        generic.bound = generic.ins_fd >= 0 and generic.cyc_fd >= 0 and generic.refill_fd >= 0;
        return generic;
    }

    pub fn close(self: *LinuxPerf) void {
        closeFds(self.ins_fd, self.cyc_fd, self.refill_fd);
        self.* = .{};
    }

    fn ioctl(fd: i32, request: u32, arg: usize) void {
        if (fd < 0) return;
        _ = std.os.linux.ioctl(fd, request, arg);
    }

    pub fn enable(self: *LinuxPerf) void {
        if (self.bound) {
            ioctl(self.ins_fd, std.os.linux.PERF.EVENT_IOC.RESET, std.os.linux.PERF.IOC_FLAG_GROUP);
            ioctl(self.ins_fd, std.os.linux.PERF.EVENT_IOC.ENABLE, std.os.linux.PERF.IOC_FLAG_GROUP);
            return;
        }
        inline for (.{ self.ins_fd, self.cyc_fd, self.refill_fd }) |fd| {
            ioctl(fd, std.os.linux.PERF.EVENT_IOC.RESET, 0);
            ioctl(fd, std.os.linux.PERF.EVENT_IOC.ENABLE, 0);
        }
    }

    pub fn disable(self: *LinuxPerf) void {
        if (self.bound) {
            ioctl(self.ins_fd, std.os.linux.PERF.EVENT_IOC.DISABLE, std.os.linux.PERF.IOC_FLAG_GROUP);
            return;
        }
        inline for (.{ self.ins_fd, self.cyc_fd, self.refill_fd }) |fd| {
            ioctl(fd, std.os.linux.PERF.EVENT_IOC.DISABLE, 0);
        }
    }

    fn readFd(fd: i32) ?u64 {
        if (fd < 0) return null;
        var value: u64 = 0;
        const n = std.posix.read(fd, std.mem.asBytes(&value)) catch return null;
        if (n != 8) return null;
        return value;
    }

    pub fn read(self: *LinuxPerf) Counters {
        return .{
            .instructions = readFd(self.ins_fd),
            .cycles = readFd(self.cyc_fd),
            .refill = readFd(self.refill_fd),
        };
    }
};

fn splitmix64(state: *u64) u64 {
    state.* +%= 0x9e3779b97f4a7c15;
    var z = state.*;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

fn cpuSetBitCapacity() usize {
    return @sizeOf(std.os.linux.cpu_set_t) * 8;
}

fn cpuInSet(set: std.os.linux.cpu_set_t, cpu: usize) bool {
    if (cpu >= cpuSetBitCapacity()) return false;
    const bits = @bitSizeOf(usize);
    return set[cpu / bits] & (@as(usize, 1) << @intCast(cpu % bits)) != 0;
}

fn countCpus(set: std.os.linux.cpu_set_t) usize {
    var n: usize = 0;
    for (set) |word| n += @popCount(word);
    return n;
}

const AffinityError = error{ CpuOutOfRange, AffinityFailed, AffinityNotExclusive, AffinityUnsupported };

fn pinCpu(cpu: usize) AffinityError!void {
    if (builtin.os.tag != .linux) return error.AffinityUnsupported;
    if (cpu >= cpuSetBitCapacity()) return error.CpuOutOfRange;
    var set = std.mem.zeroes(std.os.linux.cpu_set_t);
    const bits = @bitSizeOf(usize);
    set[cpu / bits] |= @as(usize, 1) << @intCast(cpu % bits);
    const rc = std.os.linux.syscall3(
        .sched_setaffinity,
        0,
        @sizeOf(std.os.linux.cpu_set_t),
        @intFromPtr(&set),
    );
    if (@as(isize, @bitCast(rc)) < 0) return error.AffinityFailed;
    const got = try currentAffinity();
    if (!cpuInSet(got, cpu) or countCpus(got) != 1) return error.AffinityNotExclusive;
}

fn readSysfs(path: []const u8, buf: []u8) error{PmuPathTooLong}!?[]const u8 {
    var zpath: [256]u8 = undefined;
    if (path.len + 1 > zpath.len) return error.PmuPathTooLong;
    @memcpy(zpath[0..path.len], path);
    zpath[path.len] = 0;
    const rc = std.os.linux.open(zpath[0..path.len :0], .{ .CLOEXEC = true }, 0);
    const fd: i32 = @intCast(@as(isize, @bitCast(rc)));
    if (fd < 0) return null;
    defer _ = std.os.linux.close(fd);
    const n = std.posix.read(fd, buf) catch return null;
    return std.mem.trim(u8, buf[0..n], " \t\r\n");
}

fn sysfsDevicePath(buf: []u8, pmu: []const u8, leaf: []const u8) error{PmuPathTooLong}![]u8 {
    return std.fmt.bufPrint(buf, "/sys/bus/event_source/devices/{s}/{s}", .{ pmu, leaf }) catch error.PmuPathTooLong;
}

fn readSysfsU32(pmu: []const u8, leaf: []const u8) error{PmuPathTooLong}!?u32 {
    var path_buf: [256]u8 = undefined;
    var data_buf: [64]u8 = undefined;
    const path = try sysfsDevicePath(&path_buf, pmu, leaf);
    const text = (try readSysfs(path, &data_buf)) orelse return null;
    return std.fmt.parseInt(u32, text, 0) catch null;
}

fn readSysfsEvent(pmu: []const u8, event: []const u8) error{PmuPathTooLong}!?u64 {
    var path_buf: [256]u8 = undefined;
    var leaf_buf: [64]u8 = undefined;
    var data_buf: [128]u8 = undefined;
    const leaf = std.fmt.bufPrint(&leaf_buf, "events/{s}", .{event}) catch return error.PmuPathTooLong;
    const path = try sysfsDevicePath(&path_buf, pmu, leaf);
    const text = (try readSysfs(path, &data_buf)) orelse return null;
    return parseEventConfig(text);
}

fn assertPmuOwnsCpu(pmu: []const u8, cpu: usize) PmuOpenError!void {
    var path_buf: [256]u8 = undefined;
    var data_buf: [256]u8 = undefined;
    const path = sysfsDevicePath(&path_buf, pmu, "cpus") catch return error.PmuPathTooLong;
    const text = (readSysfs(path, &data_buf) catch return error.PmuPathTooLong) orelse return error.PmuNotFound;
    if (!cpuListContains(text, cpu)) return error.PmuCpuMismatch;
}

fn cpuListContains(text: []const u8, cpu: usize) bool {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, text, " \t\r\n"), ',');
    while (it.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t");
        if (part.len == 0) continue;
        if (std.mem.indexOfScalar(u8, part, '-')) |dash| {
            const lo = std.fmt.parseInt(usize, part[0..dash], 10) catch continue;
            const hi = std.fmt.parseInt(usize, part[dash + 1 ..], 10) catch continue;
            if (cpu >= lo and cpu <= hi) return true;
        } else {
            const v = std.fmt.parseInt(usize, part, 10) catch continue;
            if (v == cpu) return true;
        }
    }
    return false;
}

fn parseEventConfig(text: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |tok_raw| {
        const tok = std.mem.trim(u8, tok_raw, " \t");
        inline for (.{ "event=", "config=" }) |prefix| {
            if (std.mem.startsWith(u8, tok, prefix)) {
                return std.fmt.parseInt(u64, tok[prefix.len..], 0) catch null;
            }
        }
    }
    return std.fmt.parseInt(u64, trimmed, 0) catch null;
}

fn currentAffinity() AffinityError!std.os.linux.cpu_set_t {
    var got = std.mem.zeroes(std.os.linux.cpu_set_t);
    const rc = std.os.linux.sched_getaffinity(0, @sizeOf(std.os.linux.cpu_set_t), &got);
    if (@as(isize, @bitCast(rc)) < 0) return error.AffinityFailed;
    return got;
}

fn firstCpuOutside(set: std.os.linux.cpu_set_t) ?usize {
    var cpu: usize = 0;
    while (cpu < cpuSetBitCapacity()) : (cpu += 1) {
        if (!cpuInSet(set, cpu)) return cpu;
    }
    return null;
}

fn cellAt(base: [*]u8, stride: usize, index: usize) [*]u8 {
    return base + index * stride;
}

fn initSlab(base: [*]u8, stride: usize, n: usize, seed: u64, order: Order) void {
    var rng = seed;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const p = cellAt(base, stride, i);
        const payload: u64 = @as(u64, @intCast(i)) *% 0x9e3779b97f4a7c15 ^ seed;
        std.mem.writeInt(u64, p[0..8], payload | 1, .little); // odd: never a pointer
        std.mem.writeInt(usize, p[8..8 + @sizeOf(usize)], 0, .little);
    }
    if (order == .chase) {
        // Random cyclic linked list. Each cell is visited exactly once.
        var perm = std.heap.page_allocator.alloc(u32, n) catch @panic("perm");
        defer std.heap.page_allocator.free(perm);
        i = 0;
        while (i < n) : (i += 1) perm[i] = @intCast(i);
        i = n;
        while (i > 1) {
            i -= 1;
            const j: usize = @intCast(splitmix64(&rng) % (i + 1));
            const tmp = perm[i];
            perm[i] = perm[j];
            perm[j] = tmp;
        }
        i = 0;
        while (i < n) : (i += 1) {
            const from = perm[i];
            const to = perm[(i + 1) % n];
            const p = cellAt(base, stride, from);
            std.mem.writeInt(usize, p[8..8 + @sizeOf(usize)], @intFromPtr(cellAt(base, stride, to)), .little);
        }
    }
}

fn expectedChecksum(n: usize, seed: u64) u64 {
    var sum: u64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const payload: u64 = @as(u64, @intCast(i)) *% 0x9e3779b97f4a7c15 ^ seed;
        sum ^= payload | 1;
    }
    return sum;
}

fn walk(
    base: [*]u8,
    stride: usize,
    n: usize,
    order: Order,
    do_prefetch: bool,
    indices: []const u32,
) u64 {
    var sum: u64 = 0;
    switch (order) {
        .seq => {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (do_prefetch) {
                    const next = cellAt(base, stride, if (i + 1 < n) i + 1 else 0);
                    @prefetch(next, .{ .rw = .read, .locality = 3, .cache = .data });
                }
                const p = cellAt(base, stride, i);
                const word = @as(*const volatile u64, @ptrCast(@alignCast(p))).*;
                sum ^= word;
            }
        },
        .shuf => {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (do_prefetch) {
                    const next_i = indices[if (i + 1 < n) i + 1 else 0];
                    @prefetch(cellAt(base, stride, next_i), .{ .rw = .read, .locality = 3, .cache = .data });
                }
                const p = cellAt(base, stride, indices[i]);
                const word = @as(*const volatile u64, @ptrCast(@alignCast(p))).*;
                sum ^= word;
            }
        },
        .chase => {
            var p: [*]u8 = base;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const word = @as(*const volatile u64, @ptrCast(@alignCast(p))).*;
                const next_addr = @as(*const volatile usize, @ptrCast(@alignCast(p + 8))).*;
                if (do_prefetch) {
                    @prefetch(@as([*]u8, @ptrFromInt(next_addr)), .{ .rw = .read, .locality = 3, .cache = .data });
                }
                sum ^= word;
                p = @ptrFromInt(next_addr);
            }
        },
    }
    return sum;
}

fn medianU64(values: []u64) u64 {
    std.sort.heap(u64, values, {}, std.sort.asc(u64));
    return values[values.len / 2];
}

fn parseArgs(args: []const []const u8) struct {
    cells: usize,
    repeats: usize,
    cpu: ?usize,
    seed: u64,
    json_path: ?[]const u8,
    pmu: []const u8,
    require_pmu: ?bool,
} {
    var cells: usize = 1 << 20;
    var repeats: usize = 7;
    var cpu: ?usize = null;
    var seed: u64 = 0x6a09e667f3bcc909;
    var json_path: ?[]const u8 = null;
    var pmu: []const u8 = default_booking_pmu;
    var require_pmu: ?bool = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--cells") and i + 1 < args.len) {
            i += 1;
            cells = std.fmt.parseInt(usize, args[i], 10) catch cells;
        } else if (std.mem.eql(u8, a, "--repeats") and i + 1 < args.len) {
            i += 1;
            repeats = std.fmt.parseInt(usize, args[i], 10) catch repeats;
        } else if (std.mem.eql(u8, a, "--cpu") and i + 1 < args.len) {
            i += 1;
            cpu = std.fmt.parseInt(usize, args[i], 10) catch cpu;
        } else if (std.mem.eql(u8, a, "--seed") and i + 1 < args.len) {
            i += 1;
            seed = std.fmt.parseInt(u64, args[i], 0) catch seed;
        } else if (std.mem.eql(u8, a, "--json") and i + 1 < args.len) {
            i += 1;
            json_path = args[i];
        } else if (std.mem.eql(u8, a, "--pmu") and i + 1 < args.len) {
            i += 1;
            pmu = args[i];
        } else if (std.mem.eql(u8, a, "--require-pmu")) {
            require_pmu = true;
        } else if (std.mem.eql(u8, a, "--no-require-pmu")) {
            require_pmu = false;
        } else if (std.mem.eql(u8, a, "--quick")) {
            cells = 1 << 12;
            repeats = 3;
        }
    }
    return .{ .cells = cells, .repeats = repeats, .cpu = cpu, .seed = seed, .json_path = json_path, .pmu = pmu, .require_pmu = require_pmu };
}

fn armName(arm: Arm, buf: *[32]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}-{s}-{s}", .{
        arm.stride,
        @tagName(arm.order),
        if (arm.prefetch) "pf" else "np",
    }) catch buf;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var arg_list: std.ArrayList([]const u8) = .empty;
    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    while (arg_it.next()) |a| try arg_list.append(arena, a);
    const cfg = parseArgs(arg_list.items);
    if (cfg.cpu) |cpu| {
        pinCpu(cpu) catch |err| {
            std.debug.print("obj64-stride-ablation: --cpu {d} failed ({s}); not timing an unpinned run\n", .{
                cpu, @errorName(err),
            });
            return err;
        };
    }
    const require_pmu = cfg.require_pmu orelse switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => true,
        else => false,
    };

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_writer.interface;

    var cpu_buf: [16]u8 = undefined;
    const cpu_text: []const u8 = if (cfg.cpu) |c|
        std.fmt.bufPrint(&cpu_buf, "{d}", .{c}) catch "?"
    else
        "inherit";

    var perf = linux_perf.open(.{
        .pmu = cfg.pmu,
        .cpu = cfg.cpu,
        .require = require_pmu,
    }) catch |err| {
        std.debug.print("obj64-stride-ablation: PMU bind failed ({s}) pmu={s} cpu={s} require={}\n", .{
            @errorName(err), cfg.pmu, cpu_text, require_pmu,
        });
        return err;
    };
    defer perf.close();

    try out.print(
        "obj64 stride ablation  cells={d} repeats={d} cpu={s} seed=0x{x} host={s}-{s} cpu_model={s} pmu={s} refill={s} pmu_bound={}\n",
        .{
            cfg.cells,
            cfg.repeats,
            cpu_text,
            cfg.seed,
            @tagName(builtin.cpu.arch),
            @tagName(builtin.os.tag),
            builtin.cpu.model.name,
            perf.pmu_name,
            perf.refill_event,
            perf.bound,
        },
    );

    const n = cfg.cells;
    const want = expectedChecksum(n, cfg.seed);

    var indices: []u32 = &.{};
    {
        indices = try arena.alloc(u32, n);
        var i: usize = 0;
        while (i < n) : (i += 1) indices[i] = @intCast(i);
        var rng = cfg.seed ^ 0x243f6a8885a308d3;
        i = n;
        while (i > 1) {
            i -= 1;
            const j: usize = @intCast(splitmix64(&rng) % (i + 1));
            const tmp = indices[i];
            indices[i] = indices[j];
            indices[j] = tmp;
        }
    }

    const orders = [_]Order{ .seq, .chase, .shuf };
    const prefetch_arms = [_]bool{ false, true };
    const arm_count = strides.len * orders.len * prefetch_arms.len;

    var arms = try arena.alloc(Arm, arm_count);
    {
        var k: usize = 0;
        for (strides) |stride| {
            for (orders) |order| {
                for (prefetch_arms) |pf| {
                    arms[k] = .{ .stride = stride, .order = order, .prefetch = pf };
                    k += 1;
                }
            }
        }
    }

    const slabs = try arena.alloc([]u8, strides.len);
    for (strides, 0..) |stride, si| {
        const bytes = stride * n + cache_line;
        const raw = try std.heap.page_allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(cache_line), bytes);
        slabs[si] = raw;
        @memset(raw, 0);
        initSlab(raw.ptr, stride, n, cfg.seed, .chase);
        // seq/shuf ignore the next pointer; chase uses it. One init with chase
        // links covers all three orders.
    }

    var samples = try arena.alloc([]Sample, arm_count);
    for (samples) |*row| row.* = try arena.alloc(Sample, cfg.repeats);

    // Warm the slabs once so the first timed sample is not a cold-mapped page.
    for (arms) |arm| {
        const slab = slabs[strideIndex(arm.stride)].ptr;
        _ = walk(slab, arm.stride, n, arm.order, arm.prefetch, indices);
    }

    var round: usize = 0;
    while (round < cfg.repeats) : (round += 1) {
        // ABBA-ish: reverse arm order every other round.
        var ai: usize = 0;
        while (ai < arm_count) : (ai += 1) {
            const idx = if (round % 2 == 0) ai else arm_count - 1 - ai;
            const arm = arms[idx];
            const slab = slabs[strideIndex(arm.stride)].ptr;
            std.mem.doNotOptimizeAway(slab);

            perf.enable();
            const t0 = std.Io.Clock.Timestamp.now(io, .awake).raw.toNanoseconds();
            const checksum = walk(slab, arm.stride, n, arm.order, arm.prefetch, indices);
            const t1 = std.Io.Clock.Timestamp.now(io, .awake).raw.toNanoseconds();
            const ns: u64 = if (t1 > t0) @intCast(t1 - t0) else 0;
            perf.disable();
            std.mem.doNotOptimizeAway(checksum);
            if (checksum != want) {
                std.debug.panic("checksum mismatch arm stride={d} order={s} pf={}\n", .{
                    arm.stride, @tagName(arm.order), arm.prefetch,
                });
            }
            const counters = perf.read();
            samples[idx][round] = .{
                .ns = ns,
                .checksum = checksum,
                .instructions = counters.instructions,
                .cycles = counters.cycles,
                .refill = counters.refill,
            };
        }
    }

    try out.print(
        "{s:<16} {s:>10} {s:>10} {s:>10} {s:>10} {s:>12} {s:>12} {s:>12}\n",
        .{ "arm", "ns_med", "ns/cell", "vs80", "vs96", "insn_med", "cyc_med", "refill_med" },
    );

    var med_ns: [strides.len * orders.len * prefetch_arms.len]u64 = undefined;
    var med_insn: [strides.len * orders.len * prefetch_arms.len]?u64 = undefined;
    var med_cyc: [strides.len * orders.len * prefetch_arms.len]?u64 = undefined;
    var med_miss: [strides.len * orders.len * prefetch_arms.len]?u64 = undefined;

    for (arms, 0..) |_, ai| {
        var ns_buf = try arena.alloc(u64, cfg.repeats);
        var insn_buf = try arena.alloc(u64, cfg.repeats);
        var cyc_buf = try arena.alloc(u64, cfg.repeats);
        var miss_buf = try arena.alloc(u64, cfg.repeats);
        var insn_n: usize = 0;
        var cyc_n: usize = 0;
        var miss_n: usize = 0;
        for (samples[ai], 0..) |s, si| {
            ns_buf[si] = s.ns;
            if (s.instructions) |v| {
                insn_buf[insn_n] = v;
                insn_n += 1;
            }
            if (s.cycles) |v| {
                cyc_buf[cyc_n] = v;
                cyc_n += 1;
            }
            if (s.refill) |v| {
                miss_buf[miss_n] = v;
                miss_n += 1;
            }
        }
        med_ns[ai] = medianU64(ns_buf);
        med_insn[ai] = if (insn_n == cfg.repeats) medianU64(insn_buf[0..insn_n]) else null;
        med_cyc[ai] = if (cyc_n == cfg.repeats) medianU64(cyc_buf[0..cyc_n]) else null;
        med_miss[ai] = if (miss_n == cfg.repeats) medianU64(miss_buf[0..miss_n]) else null;
    }

    // vs80 / vs96 are vs the same order+prefetch at those strides.
    for (arms, 0..) |arm, ai| {
        const vs80 = ratioVs(arms, med_ns[0..], ai, 80);
        const vs96 = ratioVs(arms, med_ns[0..], ai, 96);
        var name_buf: [32]u8 = undefined;
        const name = armName(arm, &name_buf);
        const per = @as(f64, @floatFromInt(med_ns[ai])) / @as(f64, @floatFromInt(n));
        try out.print("{s:<16} {d:>10} {d:>10.3} {d:>10.4} {d:>10.4}", .{ name, med_ns[ai], per, vs80, vs96 });
        if (med_insn[ai]) |v| try out.print(" {d:>12}", .{v}) else try out.print(" {s:>12}", .{"-"});
        if (med_cyc[ai]) |v| try out.print(" {d:>12}", .{v}) else try out.print(" {s:>12}", .{"-"});
        if (med_miss[ai]) |v| try out.print(" {d:>12}", .{v}) else try out.print(" {s:>12}", .{"-"});
        try out.print("\n", .{});
    }

    try out.print("\nchecksum ok ({d} arms × {d} repeats, xor=0x{x})\n", .{ arm_count, cfg.repeats, want });
    try out.flush();

    if (cfg.json_path) |path| {
        var json_buf: std.ArrayList(u8) = .empty;
        const cpu_json: []const u8 = if (cfg.cpu != null) cpu_text else "null";
        try json_buf.print(arena, "{{\n  \"host_arch\": \"{s}\",\n  \"host_os\": \"{s}\",\n  \"host_cpu\": \"{s}\",\n  \"cpu\": {s},\n  \"pmu\": \"{s}\",\n  \"refill_event\": \"{s}\",\n  \"pmu_bound\": {},\n  \"require_pmu\": {},\n  \"cells\": {d},\n  \"repeats\": {d},\n  \"seed\": {d},\n  \"arms\": [\n", .{
            @tagName(builtin.cpu.arch), @tagName(builtin.os.tag), builtin.cpu.model.name, cpu_json, perf.pmu_name, perf.refill_event, perf.bound, require_pmu, n, cfg.repeats, cfg.seed,
        });
        for (arms, 0..) |arm, ai| {
            const vs80 = ratioVs(arms, med_ns[0..], ai, 80);
            const vs96 = ratioVs(arms, med_ns[0..], ai, 96);
            try json_buf.print(
                arena,
                "    {{\"stride\": {d}, \"order\": \"{s}\", \"prefetch\": {}, \"ns_med\": {d}, \"vs80\": {d:.6}, \"vs96\": {d:.6}",
                .{ arm.stride, @tagName(arm.order), arm.prefetch, med_ns[ai], vs80, vs96 },
            );
            if (med_insn[ai]) |v| try json_buf.print(arena, ", \"insn_med\": {d}", .{v});
            if (med_cyc[ai]) |v| try json_buf.print(arena, ", \"cycles_med\": {d}", .{v});
            if (med_miss[ai]) |v| try json_buf.print(arena, ", \"refill_med\": {d}", .{v});
            try json_buf.print(arena, "}}{s}\n", .{if (ai + 1 == arm_count) "" else ","});
        }
        try json_buf.print(arena, "  ]\n}}\n", .{});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json_buf.items });
    }

    for (slabs) |slab| std.heap.page_allocator.free(slab);
}

fn strideIndex(stride: usize) usize {
    for (strides, 0..) |s, i| if (s == stride) return i;
    return 0;
}

fn findArm(arms: []const Arm, stride: usize, order: Order, prefetch: bool) ?usize {
    for (arms, 0..) |a, i| {
        if (a.stride == stride and a.order == order and a.prefetch == prefetch) return i;
    }
    return null;
}

fn ratioVs(arms: []const Arm, med_ns: []const u64, ai: usize, ref_stride: usize) f64 {
    const arm = arms[ai];
    const ref = findArm(arms, ref_stride, arm.order, arm.prefetch) orelse ai;
    if (med_ns[ref] == 0) return 0;
    return @as(f64, @floatFromInt(med_ns[ai])) / @as(f64, @floatFromInt(med_ns[ref]));
}

test "all visit orders xor the same payload" {
    const n: usize = 256;
    const seed: u64 = 1;
    var indices = try std.testing.allocator.alloc(u32, n);
    defer std.testing.allocator.free(indices);
    var i: usize = 0;
    while (i < n) : (i += 1) indices[i] = @intCast(i);
    var rng: u64 = seed;
    i = n;
    while (i > 1) {
        i -= 1;
        const j: usize = @intCast(splitmix64(&rng) % (i + 1));
        const tmp = indices[i];
        indices[i] = indices[j];
        indices[j] = tmp;
    }
    const want = expectedChecksum(n, seed);
    for (strides) |stride| {
        const bytes = stride * n + cache_line;
        const raw = try std.testing.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(cache_line), bytes);
        defer std.testing.allocator.free(raw);
        @memset(raw, 0);
        initSlab(raw.ptr, stride, n, seed, .chase);
        try std.testing.expectEqual(want, walk(raw.ptr, stride, n, .seq, false, indices));
        try std.testing.expectEqual(want, walk(raw.ptr, stride, n, .seq, true, indices));
        try std.testing.expectEqual(want, walk(raw.ptr, stride, n, .shuf, false, indices));
        try std.testing.expectEqual(want, walk(raw.ptr, stride, n, .shuf, true, indices));
        try std.testing.expectEqual(want, walk(raw.ptr, stride, n, .chase, false, indices));
        try std.testing.expectEqual(want, walk(raw.ptr, stride, n, .chase, true, indices));
    }
}

test "cpu list parser covers the booking big-core set" {
    try std.testing.expect(cpuListContains("5-9,15-19", 17));
    try std.testing.expect(cpuListContains("5-9,15-19", 5));
    try std.testing.expect(!cpuListContains("5-9,15-19", 0));
    try std.testing.expect(cpuListContains("0-3", 2));
    try std.testing.expect(!cpuListContains("0-3", 4));
    try std.testing.expect(cpuListContains("17", 17));
    try std.testing.expect(!cpuListContains("17", 18));
}

test "sysfs event= lines parse" {
    try std.testing.expectEqual(@as(u64, 0x08), parseEventConfig("event=0x08").?);
    try std.testing.expectEqual(@as(u64, 0x17), parseEventConfig("event=0x17\n").?);
    try std.testing.expectEqual(@as(u64, 0x11), parseEventConfig("event=0x11,inv=1").?);
    try std.testing.expectEqual(@as(u64, 0x08), parseEventConfig("config=0x08").?);
}

test "affinity rejects a CPU outside cpu_set_t" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try std.testing.expectError(error.CpuOutOfRange, pinCpu(cpuSetBitCapacity()));
}

test "affinity rejects a CPU the kernel will not pin" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const before = try currentAffinity();
    const cpu = firstCpuOutside(before) orelse return error.SkipZigTest;
    try std.testing.expectError(error.AffinityFailed, pinCpu(cpu));
    const after = try currentAffinity();
    try std.testing.expectEqual(countCpus(before), countCpus(after));
    var i: usize = 0;
    while (i < cpuSetBitCapacity()) : (i += 1) {
        try std.testing.expectEqual(cpuInSet(before, i), cpuInSet(after, i));
    }
}

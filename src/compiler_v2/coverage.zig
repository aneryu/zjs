//! QCP-1 L3: emission coverage accounting and the v2 migration gate.

const std = @import("std");
const builtin = @import("builtin");

pub const enabled: bool = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

pub const LegacyConstruct = enum(u8) {
    none = 0,
    ts_enum,
    ts_namespace,
    ts_namespace_class_export,
    using_declaration_in_for_of,
};

pub const Reachability = enum {
    ecmascript,
    typescript,
    dead,
};

pub const AllowlistEntry = struct {
    construct: LegacyConstruct,
    reason: []const u8,
    exit_milestone: []const u8,
    reachable_from: Reachability,
};

pub const legacy_allowlist = [_]AllowlistEntry{
    .{
        .construct = .ts_enum,
        .reason = "parseEnumDeclaration still emits enum initialization and member mappings through legacy funnels",
        .exit_milestone = "QCP-1 L4 construct migration",
        .reachable_from = .typescript,
    },
    .{
        .construct = .ts_namespace,
        .reason = "parseNamespaceDeclarationWithIdent still emits namespace initialization and exports through legacy funnels",
        .exit_milestone = "QCP-1 L4 construct migration",
        .reachable_from = .typescript,
    },
    .{
        .construct = .ts_namespace_class_export,
        .reason = "parseClass still emits a namespace-exported class re-export through the legacy put_field funnel",
        .exit_milestone = "QCP-1 L4 construct migration",
        .reachable_from = .typescript,
    },
    .{
        .construct = .using_declaration_in_for_of,
        .reason = "parseForInOf still stores the using iteration value through the legacy put_loc funnel",
        .exit_milestone = "QCP-1 L4 construct migration",
        .reachable_from = .ecmascript,
    },
};

comptime {
    for (legacy_allowlist) |entry| {
        if (entry.construct == .none) {
            @compileError("compiler-v2 legacy emission allowlist must not contain .none");
        }
    }
    for (@typeInfo(LegacyConstruct).@"enum".fields) |field| {
        const construct: LegacyConstruct = @enumFromInt(field.value);
        if (construct == .none) continue;
        var matches: usize = 0;
        for (legacy_allowlist) |entry| {
            matches += @intFromBool(entry.construct == construct);
        }
        if (matches != 1) {
            @compileError("compiler-v2 legacy emission construct must have exactly one allowlist entry: " ++ field.name);
        }
    }
}

pub fn isAllowlisted(construct: LegacyConstruct) bool {
    for (legacy_allowlist) |entry| {
        if (entry.construct == construct) return true;
    }
    return false;
}

const legacy_construct_count = @typeInfo(LegacyConstruct).@"enum".fields.len;

/// Debug/ReleaseSafe-only accumulator. The payload is an empty struct in
/// ReleaseFast/ReleaseSmall, matching compiler_v2.cfg's oracle counters.
pub const Counters = if (enabled) struct {
    v2_construct_emitted: u64 = 0,
    legacy_construct_emitted: u64 = 0,
    legacy_in_v2_scope: u64 = 0,
    legacy_in_v2_unallowed: u64 = 0,
    per_construct: [legacy_construct_count]u64 = .{0} ** legacy_construct_count,
} else struct {};

var counters: Counters = .{};

const site_address_capacity = 24;
const max_violation_sites = 256;

const Site = struct {
    addresses: [site_address_capacity]usize,
    address_len: u8,
    construct: LegacyConstruct,
    hits: u64,
};

const ViolationState = if (enabled) struct {
    lock_state: std.atomic.Value(bool) = .init(false),
    sites: std.AutoHashMapUnmanaged(u64, Site) = .empty,
    sites_dropped: u64 = 0,
} else struct {};

var violations: ViolationState = .{};
var collect_mode_cache: if (enabled) u8 else void = if (enabled) 0 else {};

comptime {
    if (!enabled) {
        std.debug.assert(@sizeOf(Counters) == 0);
        std.debug.assert(@sizeOf(ViolationState) == 0);
        std.debug.assert(@sizeOf(@TypeOf(collect_mode_cache)) == 0);
    }
}

inline fn add(counter: *u64) void {
    if (comptime !enabled) return;
    _ = @atomicRmw(u64, counter, .Add, 1, .monotonic);
}

pub fn noteV2Emission() void {
    if (comptime !enabled) return;
    add(&counters.v2_construct_emitted);
}

pub fn noteLegacyEmission(
    in_v2_scope: bool,
    construct: LegacyConstruct,
    count_bytes_event: bool,
) void {
    if (comptime !enabled) return;

    // Only the two byte-append funnels count an emission event. The outer
    // source/append wrappers call here with false so they can still enforce
    // the gate without double-counting the byte event routed beneath them.
    if (count_bytes_event) {
        add(&counters.legacy_construct_emitted);
        if (in_v2_scope) {
            add(&counters.legacy_in_v2_scope);
            add(&counters.per_construct[@intFromEnum(construct)]);
        }
    }

    if (!in_v2_scope or isAllowlisted(construct)) return;
    // THE GATE. Counted for every violating funnel call, including the
    // non-counting wrappers: a construct can reach the legacy stream through
    // `emitSourcePosAndLoc` (source slot, no bytes), `truncateCode` or
    // `publishParserLabelTarget` alone, and a gate that only counted byte
    // events would read zero while those holes were open. This is a violation
    // count, deliberately not an instruction count — the only value that ever
    // passes is 0.
    add(&counters.legacy_in_v2_unallowed);

    var address_buffer: [site_address_capacity]usize = undefined;
    const trace = std.debug.captureCurrentStackTrace(.{}, &address_buffer);
    recordViolation(trace.return_addresses, construct);

    if (collectMode()) return;

    std.debug.print(
        "QCP-1 L3 gate violation stack (construct={s}):\n",
        .{@tagName(construct)},
    );
    std.debug.dumpStackTrace(&trace);
    var message_buffer: [160]u8 = undefined;
    const message = std.fmt.bufPrint(
        &message_buffer,
        "QCP-1 L3 gate: ungated legacy emission during a v2 parse (construct={s})",
        .{@tagName(construct)},
    ) catch "QCP-1 L3 gate: ungated legacy emission during a v2 parse";
    @panic(message);
}

pub fn snapshot() Counters {
    if (comptime !enabled) return .{};
    var result: Counters = .{
        .v2_construct_emitted = @atomicLoad(
            u64,
            &counters.v2_construct_emitted,
            .monotonic,
        ),
        .legacy_construct_emitted = @atomicLoad(
            u64,
            &counters.legacy_construct_emitted,
            .monotonic,
        ),
        .legacy_in_v2_scope = @atomicLoad(
            u64,
            &counters.legacy_in_v2_scope,
            .monotonic,
        ),
        .legacy_in_v2_unallowed = @atomicLoad(
            u64,
            &counters.legacy_in_v2_unallowed,
            .monotonic,
        ),
    };
    for (&result.per_construct, 0..) |*value, index| {
        value.* = @atomicLoad(u64, &counters.per_construct[index], .monotonic);
    }
    return result;
}

pub fn reset() void {
    if (comptime !enabled) return;
    @atomicStore(u64, &counters.v2_construct_emitted, 0, .monotonic);
    @atomicStore(u64, &counters.legacy_construct_emitted, 0, .monotonic);
    @atomicStore(u64, &counters.legacy_in_v2_scope, 0, .monotonic);
    @atomicStore(u64, &counters.legacy_in_v2_unallowed, 0, .monotonic);
    for (&counters.per_construct) |*value| {
        @atomicStore(u64, value, 0, .monotonic);
    }

    lockViolations();
    defer unlockViolations();
    violations.sites.clearRetainingCapacity();
    @atomicStore(u64, &violations.sites_dropped, 0, .monotonic);
}

pub fn collectMode() bool {
    if (comptime !enabled) return false;
    const cached = @atomicLoad(u8, &collect_mode_cache, .monotonic);
    if (cached != 0) return cached == 2;
    const detected: u8 = if (std.c.getenv("ZJS_V2_EMISSION_COLLECT") != null) 2 else 1;
    @atomicStore(u8, &collect_mode_cache, detected, .monotonic);
    return detected == 2;
}

pub fn violationSiteCount() usize {
    if (comptime !enabled) return 0;
    lockViolations();
    defer unlockViolations();
    return violations.sites.count();
}

pub fn writeReport(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (comptime !enabled) return;
    const totals = snapshot();
    const dropped = @atomicLoad(u64, &violations.sites_dropped, .monotonic);
    try writer.print(
        "QCP-1 L3 emission coverage: v2_construct_emitted={d} legacy_construct_emitted={d} legacy_in_v2_scope={d} legacy_in_v2_unallowed={d} sites_dropped={d}\n",
        .{
            totals.v2_construct_emitted,
            totals.legacy_construct_emitted,
            totals.legacy_in_v2_scope,
            totals.legacy_in_v2_unallowed,
            dropped,
        },
    );
    try writer.writeAll("construct\tin_v2_scope\tallowlisted\texit_milestone\treachability\n");
    inline for (@typeInfo(LegacyConstruct).@"enum".fields) |field| {
        const construct: LegacyConstruct = @enumFromInt(field.value);
        if (allowlistEntry(construct)) |entry| {
            try writer.print(
                "{s}\t{d}\tyes\t{s}\t{s}\n",
                .{
                    field.name,
                    totals.per_construct[@intFromEnum(construct)],
                    entry.exit_milestone,
                    @tagName(entry.reachable_from),
                },
            );
        } else {
            try writer.print(
                "{s}\t{d}\tno\t-\t-\n",
                .{ field.name, totals.per_construct[@intFromEnum(construct)] },
            );
        }
    }

    lockViolations();
    defer unlockViolations();
    var iterator = violations.sites.iterator();
    while (iterator.next()) |entry| {
        const site = entry.value_ptr;
        try writer.print(
            "violation_site construct={s} hits={d}\n",
            .{ @tagName(site.construct), site.hits },
        );
        const addresses = site.addresses[0..site.address_len];
        const trace: std.debug.StackTrace = .{
            .return_addresses = addresses,
            .skipped = if (site.address_len == site_address_capacity) .unknown else .none,
        };
        writer.print(
            "{f}",
            .{std.debug.FormatStackTrace{ .stack_trace = trace }},
        ) catch |format_err| {
            writeRawStackTrace(writer, addresses) catch return format_err;
        };
    }
}

pub fn dumpReport() void {
    if (comptime !enabled) return;
    var output: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer output.deinit();
    writeReport(&output.writer) catch return;
    std.debug.print("{s}", .{output.written()});
}

fn allowlistEntry(construct: LegacyConstruct) ?AllowlistEntry {
    for (legacy_allowlist) |entry| {
        if (entry.construct == construct) return entry;
    }
    return null;
}

fn lockViolations() void {
    if (comptime !enabled) return;
    while (violations.lock_state.swap(true, .acquire)) std.atomic.spinLoopHint();
}

fn unlockViolations() void {
    if (comptime !enabled) return;
    violations.lock_state.store(false, .release);
}

fn recordViolation(addresses: []const usize, construct: LegacyConstruct) void {
    if (comptime !enabled) return;
    const hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(addresses));

    lockViolations();
    defer unlockViolations();
    if (violations.sites.getPtr(hash)) |site| {
        site.hits +|= 1;
        return;
    }
    if (violations.sites.count() >= max_violation_sites) {
        add(&violations.sites_dropped);
        return;
    }

    var site: Site = .{
        .addresses = undefined,
        .address_len = @intCast(addresses.len),
        .construct = construct,
        .hits = 1,
    };
    @memcpy(site.addresses[0..addresses.len], addresses);
    violations.sites.put(std.heap.page_allocator, hash, site) catch {
        add(&violations.sites_dropped);
    };
}

fn writeRawStackTrace(writer: *std.Io.Writer, addresses: []const usize) std.Io.Writer.Error!void {
    if (comptime !enabled) return;
    try writer.writeAll("raw stack trace:\n");
    for (addresses) |address| try writer.print("  0x{x}\n", .{address});
}

const std = @import("std");

pub const max_opcode_count = 256;

pub const OpcodeProfile = struct {
    pub const opcode_count = max_opcode_count;

    count: [max_opcode_count]u64 = @splat(0),
    nanos: [max_opcode_count]u64 = @splat(0),
    slow_count: [max_opcode_count]u64 = @splat(0),
    ic_hit: [max_opcode_count]u64 = @splat(0),
    ic_miss: [max_opcode_count]u64 = @splat(0),
    ic_invalidate: [max_opcode_count]u64 = @splat(0),
    ic_promote_poly: [max_opcode_count]u64 = @splat(0),
    ic_promote_mega: [max_opcode_count]u64 = @splat(0),
    value_dup_count: u64 = 0,
    value_free_count: u64 = 0,
    prop_lookup_count: u64 = 0,
    global_lookup_count: u64 = 0,
    alloc_count: u64 = 0,
    call_frame_count: u64 = 0,

    pub fn recordOpcode(self: *OpcodeProfile, opcode: u8, elapsed_nanos: u64) void {
        self.count[opcode] +|= 1;
        self.nanos[opcode] +|= elapsed_nanos;
    }

    pub fn recordAlloc(self: *OpcodeProfile) void {
        self.alloc_count +|= 1;
    }

    pub fn recordValueDup(self: *OpcodeProfile) void {
        self.value_dup_count +|= 1;
    }

    pub fn recordValueFree(self: *OpcodeProfile) void {
        self.value_free_count +|= 1;
    }

    pub fn recordPropLookup(self: *OpcodeProfile, is_global: bool) void {
        self.prop_lookup_count +|= 1;
        if (is_global) self.global_lookup_count +|= 1;
    }

    pub fn recordGlobalLookup(self: *OpcodeProfile) void {
        self.global_lookup_count +|= 1;
    }

    pub fn recordSlowPath(self: *OpcodeProfile, opcode: ?u8) void {
        if (opcode) |op| self.slow_count[op] +|= 1;
    }

    pub fn recordCallFrame(self: *OpcodeProfile) void {
        self.call_frame_count +|= 1;
    }

    pub fn opcodeName(opcode: u8) []const u8 {
        return @import("../bytecode/opcode.zig").nameOf(opcode);
    }

    pub fn recordIcHit(self: *OpcodeProfile, opcode: ?u8) void {
        incrementOpcodeCounter(&self.ic_hit, opcode);
    }

    pub fn recordIcMiss(self: *OpcodeProfile, opcode: ?u8) void {
        incrementOpcodeCounter(&self.ic_miss, opcode);
    }

    pub fn recordIcInvalidate(self: *OpcodeProfile, opcode: ?u8) void {
        incrementOpcodeCounter(&self.ic_invalidate, opcode);
    }

    pub fn recordIcPromotePoly(self: *OpcodeProfile, opcode: ?u8) void {
        incrementOpcodeCounter(&self.ic_promote_poly, opcode);
    }

    pub fn recordIcPromoteMega(self: *OpcodeProfile, opcode: ?u8) void {
        incrementOpcodeCounter(&self.ic_promote_mega, opcode);
    }

    pub fn totalOpcodeCount(self: OpcodeProfile) u64 {
        var total: u64 = 0;
        for (self.count) |value| total +|= value;
        return total;
    }

    pub fn totalOpcodeNanos(self: OpcodeProfile) u64 {
        var total: u64 = 0;
        for (self.nanos) |value| total +|= value;
        return total;
    }

    pub fn totalIcHit(self: OpcodeProfile) u64 {
        return totalCounter(self.ic_hit);
    }

    pub fn totalIcMiss(self: OpcodeProfile) u64 {
        return totalCounter(self.ic_miss);
    }

    pub fn totalIcInvalidate(self: OpcodeProfile) u64 {
        return totalCounter(self.ic_invalidate);
    }

    pub fn totalIcPromotePoly(self: OpcodeProfile) u64 {
        return totalCounter(self.ic_promote_poly);
    }

    pub fn totalIcPromoteMega(self: OpcodeProfile) u64 {
        return totalCounter(self.ic_promote_mega);
    }
};

fn incrementOpcodeCounter(counter: *[max_opcode_count]u64, opcode: ?u8) void {
    if (opcode) |op| counter[op] +|= 1;
}

fn totalCounter(counter: [max_opcode_count]u64) u64 {
    var total: u64 = 0;
    for (counter) |value| total +|= value;
    return total;
}

threadlocal var active_profile: ?*OpcodeProfile = null;
threadlocal var active_opcode: ?u8 = null;

pub const ActiveState = struct {
    profile: ?*OpcodeProfile,
    opcode: ?u8,
};

pub fn activate(profile: ?*OpcodeProfile) ?*OpcodeProfile {
    const previous = active_profile;
    active_profile = profile;
    return previous;
}

pub fn enterOpcode(opcode: u8) ActiveState {
    const previous = ActiveState{
        .profile = active_profile,
        .opcode = active_opcode,
    };
    active_opcode = opcode;
    return previous;
}

pub fn restoreOpcode(state: ActiveState) void {
    active_profile = state.profile;
    active_opcode = state.opcode;
}

pub fn active() ?*OpcodeProfile {
    return active_profile;
}

pub fn activeOpcode() ?u8 {
    return active_opcode;
}

pub fn recordValueDup() void {
    if (active_profile) |profile| profile.recordValueDup();
}

pub fn recordPropLookup(is_global: bool) void {
    if (active_profile) |profile| profile.recordPropLookup(is_global);
}

pub fn recordGlobalLookup() void {
    if (active_profile) |profile| profile.recordGlobalLookup();
}

pub fn recordSlowPath() void {
    if (active_profile) |profile| profile.recordSlowPath(active_opcode);
}

pub fn nowNanos() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

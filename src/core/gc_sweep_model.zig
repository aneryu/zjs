//! Mutator-only lazy-sweep plan (tracing-gc-design.md §8.7).
//!
//! This round stands up the block state machine and the four scheduling
//! quantities. It does not allocate 64 KiB blocks: a "window" is a 64 KiB
//! address group over the live address registry, used only for observation.
//! Sweep remains fully synchronous in STW; after a collection, sweep debt is
//! zero. Default production `rc` does not import this file.

const std = @import("std");

pub const window_shift: u6 = 16;
pub const window_bytes: usize = 1 << window_shift;

pub const SweepState = enum(u8) {
    fresh,
    active,
    needs_sweep,
    sweeping,
    swept,
};

pub const Debt = struct {
    mark_debt: usize = 0,
    sweep_debt: usize = 0,
    soft_headroom: usize = 0,
    hard_headroom: usize = 0,
};

pub const Model = struct {
    windows: std.AutoHashMapUnmanaged(usize, SweepState) = .empty,
    fresh: usize = 0,
    active: usize = 0,
    needs_sweep: usize = 0,
    sweeping: usize = 0,
    swept: usize = 0,
    trans_fresh_to_active: usize = 0,
    trans_active_to_needs_sweep: usize = 0,
    trans_needs_sweep_to_sweeping: usize = 0,
    trans_sweeping_to_swept: usize = 0,
    trans_swept_to_active: usize = 0,
    debt: Debt = .{},
    last_mark_debt: usize = 0,
    last_sweep_debt: usize = 0,

    pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        self.windows.deinit(allocator);
        self.* = .{};
    }

    pub fn noteAllocated(self: *Model, allocator: std.mem.Allocator, header_addr: usize) void {
        const id = header_addr >> window_shift;
        const gop = self.windows.getOrPut(allocator, id) catch return;
        if (!gop.found_existing) {
            gop.value_ptr.* = .fresh;
            self.fresh += 1;
            self.transition(gop.value_ptr, .active);
            return;
        }
        if (gop.value_ptr.* == .swept) {
            self.transition(gop.value_ptr, .active);
        }
    }

    pub fn beginMark(self: *Model, allocated_bytes: usize) void {
        self.debt.mark_debt = allocated_bytes;
        self.last_mark_debt = allocated_bytes;
    }

    pub fn endMark(self: *Model, unmarked_bytes: usize) void {
        self.debt.mark_debt = 0;
        self.debt.sweep_debt = unmarked_bytes;
        self.last_sweep_debt = unmarked_bytes;
        var iterator = self.windows.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.* == .active) self.transition(entry.value_ptr, .needs_sweep);
        }
    }

    pub fn beginSweep(self: *Model) void {
        var iterator = self.windows.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.* == .needs_sweep) self.transition(entry.value_ptr, .sweeping);
        }
    }

    pub fn endSweep(self: *Model) void {
        var iterator = self.windows.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.* == .sweeping) {
                self.transition(entry.value_ptr, .swept);
                self.transition(entry.value_ptr, .active);
            }
        }
        self.debt.sweep_debt = 0;
    }

    pub fn refreshHeadroom(self: *Model, allocated_bytes: usize, threshold: usize, external_bytes: usize) void {
        self.debt.soft_headroom = saturatingSub(threshold, allocated_bytes);
        self.debt.hard_headroom = self.debt.soft_headroom +| self.debt.sweep_debt +| external_bytes;
    }

    fn transition(self: *Model, slot: *SweepState, next: SweepState) void {
        const prev = slot.*;
        switch (prev) {
            .fresh => self.fresh -= 1,
            .active => self.active -= 1,
            .needs_sweep => self.needs_sweep -= 1,
            .sweeping => self.sweeping -= 1,
            .swept => self.swept -= 1,
        }
        switch (next) {
            .fresh => self.fresh += 1,
            .active => self.active += 1,
            .needs_sweep => self.needs_sweep += 1,
            .sweeping => self.sweeping += 1,
            .swept => self.swept += 1,
        }
        if (prev == .fresh and next == .active) self.trans_fresh_to_active += 1;
        if (prev == .active and next == .needs_sweep) self.trans_active_to_needs_sweep += 1;
        if (prev == .needs_sweep and next == .sweeping) self.trans_needs_sweep_to_sweeping += 1;
        if (prev == .sweeping and next == .swept) self.trans_sweeping_to_swept += 1;
        if (prev == .swept and next == .active) self.trans_swept_to_active += 1;
        slot.* = next;
    }
};

fn saturatingSub(a: usize, b: usize) usize {
    return if (a > b) a - b else 0;
}

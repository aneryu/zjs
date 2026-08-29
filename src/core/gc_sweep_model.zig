//! Mutator-only lazy-sweep plan (tracing-gc-design.md §8.7).
//!
//! This is the logical-window observation model, not the physical BlockHeap
//! authority. A "window" is a 64 KiB address group over the live address
//! registry; ReleaseFast tracing does not populate the map, and physical lazy
//! destruction is driven by doomed bitmaps/lists plus `doomed_pending`.
//! Keeping that boundary explicit prevents test-only transitions here from
//! being cited as proof that the §8.7 block machine is complete. Default
//! production `rc` does not import this file.

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

comptime {
    std.debug.assert(@typeInfo(SweepState).@"enum".fields.len == 5);
}

pub const Debt = struct {
    mark_debt: usize = 0,
    sweep_debt: usize = 0,
    soft_headroom: usize = 0,
    hard_headroom: usize = 0,
};

pub const VerifyError = error{
    IllegalTransition,
    StateCountMismatch,
    TransitionBalanceMismatch,
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
    invalid_transitions: usize = 0,
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

    /// Audit the whole machine, not one hand-picked edge. State population is
    /// recounted from the authoritative window map, then the five cumulative
    /// edge counters must satisfy flow conservation at every node. This catches
    /// both an illegal transition attempt and a direct state/counter write that
    /// bypassed `transition`.
    pub fn verify(self: *const Model) VerifyError!void {
        if (self.invalid_transitions != 0) return error.IllegalTransition;

        var observed: [@typeInfo(SweepState).@"enum".fields.len]usize = @splat(0);
        var iterator = self.windows.valueIterator();
        while (iterator.next()) |state| observed[@intFromEnum(state.*)] += 1;
        const recorded = [_]usize{ self.fresh, self.active, self.needs_sweep, self.sweeping, self.swept };
        if (!std.mem.eql(usize, &observed, &recorded)) return error.StateCountMismatch;

        // A window is inserted as fresh and immediately takes the only edge
        // out of fresh, so the number of created windows is exactly f->a.
        if (self.fresh != 0) return error.TransitionBalanceMismatch;
        const active_in = std.math.add(
            usize,
            self.trans_fresh_to_active,
            self.trans_swept_to_active,
        ) catch return error.TransitionBalanceMismatch;
        if (self.trans_active_to_needs_sweep > active_in or
            self.active != active_in - self.trans_active_to_needs_sweep)
        {
            return error.TransitionBalanceMismatch;
        }
        if (self.trans_needs_sweep_to_sweeping > self.trans_active_to_needs_sweep or
            self.needs_sweep != self.trans_active_to_needs_sweep - self.trans_needs_sweep_to_sweeping)
        {
            return error.TransitionBalanceMismatch;
        }
        if (self.trans_sweeping_to_swept > self.trans_needs_sweep_to_sweeping or
            self.sweeping != self.trans_needs_sweep_to_sweeping - self.trans_sweeping_to_swept)
        {
            return error.TransitionBalanceMismatch;
        }
        if (self.trans_swept_to_active > self.trans_sweeping_to_swept or
            self.swept != self.trans_sweeping_to_swept - self.trans_swept_to_active)
        {
            return error.TransitionBalanceMismatch;
        }
    }

    fn transition(self: *Model, slot: *SweepState, next: SweepState) void {
        const prev = slot.*;
        if (!isLegalTransition(prev, next)) {
            self.invalid_transitions +|= 1;
            return;
        }
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

pub fn isLegalTransition(prev: SweepState, next: SweepState) bool {
    return switch (prev) {
        .fresh => next == .active,
        .active => next == .needs_sweep,
        .needs_sweep => next == .sweeping,
        .sweeping => next == .swept,
        .swept => next == .active,
    };
}

fn saturatingSub(a: usize, b: usize) usize {
    return if (a > b) a - b else 0;
}

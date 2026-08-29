//! Marker worker: the second thread of the concurrent major (§8.6).
//!
//! The worker only ever *reads* published objects and *sets* mark bits. It
//! never frees, never allocates, and never calls embedder code -- those are
//! all owner-thread responsibilities, and the design says so explicitly
//! because a marker that can call out is a marker that can reenter the
//! runtime it is scanning.
//!
//! Its relationship with the mutator is entirely through two things already
//! built: the bounded queue, whose overflow downgrades to rescan rather than
//! dropping work, and the shading barrier, which publishes writes the marker
//! would otherwise miss.

const std = @import("std");
const gc = @import("gc.zig");

pub const Stats = struct {
    started: usize = 0,
    finished: usize = 0,
    marked: usize = 0,
    idle_spins: usize = 0,
};

pub const Worker = struct {
    thread: ?std.Thread = null,
    /// Owner sets this to ask the worker to finish its current batch and exit.
    /// Release/acquire because the worker must observe every mark the owner
    /// published before the request.
    stop: std.atomic.Value(bool) = .init(false),
    running: std.atomic.Value(bool) = .init(false),
    stats: Stats = .{},

    /// Start marking. The queue must already be seeded and
    /// `major_marking_active` published, so the worker cannot observe a
    /// half-initialised phase.
    pub fn start(self: *Worker, registry: *gc.Registry, queue: *gc.mark_queue.Queue) !void {
        std.debug.assert(self.thread == null);
        self.stop.store(false, .release);
        self.running.store(true, .release);
        self.stats.started += 1;
        self.thread = try std.Thread.spawn(.{}, run, .{ self, registry, queue });
    }

    /// Ask the worker to stop and wait for it. Called from the owner thread at
    /// the start of final remark, so that everything the worker marked is
    /// visible before roots are rescanned.
    pub fn join(self: *Worker) void {
        const thread = self.thread orelse return;
        self.stop.store(true, .release);
        thread.join();
        self.thread = null;
        self.stats.finished += 1;
    }

    fn run(self: *Worker, registry: *gc.Registry, queue: *gc.mark_queue.Queue) void {
        defer self.running.store(false, .release);
        while (!self.stop.load(.acquire)) {
            const header = queue.pop() orelse {
                self.stats.idle_spins += 1;
                std.Thread.yield() catch {};
                continue;
            };
            // Marking is the whole job: the owner thread walks children during
            // remark. Splitting edge enumeration across threads would need the
            // snapshot protocol (§6.3), which is a later tranche. The mark
            // accessors dispatch to the block bitmap for cell-served objects;
            // writing the raw header bit here left them unmarked in the
            // authority the collector actually reads.
            if (!registry.headerMarked(header)) {
                registry.setHeaderMarked(header);
                self.stats.marked += 1;
            }
        }
    }
};

//! Parallel STW slice marking (throughput-triangle ruling, option B).
//!
//! Marking is the tracer's dominant tax -- fixed-work splay spends ~63% of
//! its wall clock inside mark slices -- and every slice runs with the
//! mutator stopped. That stop is what makes parallelism cheap to reason
//! about: inside a slice the object graph is frozen, so worker threads only
//! ever *read* object fields and *claim* mark bits (atomically). No snapshot
//! protocol, no barrier interplay beyond what already exists.
//!
//! Topology: the owner plus up to `max_workers` helpers, each with a private
//! LIFO mark stack (depth-first, cache-hot), sharing the Vyukov MPMC ring
//! for seed distribution and spill. Dedup is `tryAcquireHeaderMark`: the
//! claim's winner alone walks the object's edges, which also keeps the
//! trace's rare write-backs (accessor sync stores) single-writer.
//!
//! Termination inside a slice is two-flag: the owner raises `stop` when the
//! budget runs out (workers spill their stacks to the ring and become hot
//! standbys -- the frontier survives to the next slice), or the frontier
//! genuinely dries up (`busy` count reaches zero with the ring empty; only
//! then can no new work appear, because every producer is a tracer and every
//! tracer is idle). The first parallel slice of a cycle uses the condvar;
//! later slices advance an atomic generation so hot standbys never park and
//! immediately wake again. They return to the condvar when the cycle closes.
//!
//! The pool is lazy on two axes: threads spawn on the first slice whose
//! frontier is worth sharing (a test-corpus runtime that builds thousands of
//! small heaps never spawns), and the worker count comes from the CPU
//! affinity mask at spawn time -- a single-core pin gets zero workers and
//! the exact single-threaded collector it had before.

const std = @import("std");
const builtin = @import("builtin");
const gc = @import("gc.zig");
const runtime_mod = @import("runtime.zig");
const stw = @import("gc_trace_stw.zig");

const JSRuntime = runtime_mod.JSRuntime;
const JSValue = @import("value.zig").JSValue;
const Object = @import("object.zig").Object;
const context_mod = @import("context.zig");
const module_mod = @import("module.zig");
const shape_mod = @import("shape.zig");
const object_payloads = @import("object_payloads.zig");
const profile = @import("profile.zig");

pub const max_workers = 3;

/// Instantaneous-frontier trigger. Depth-first tracing keeps the visible
/// frontier small (a few hundred) even over a million-object graph, so this
/// alone almost never fires; the real trigger is `slice_in_cycle` -- any
/// cycle that needs a second slice has more than a budget's worth of work,
/// which is plenty to share. Both mirror JSC's approach of not trusting the
/// instantaneous stack size (SlotVisitor::donateKnownParallel).
pub const parallel_threshold = 4096;

/// Objects traced between donation checks, and the local-stack size below
/// which donating is not worth the ring traffic. JSC rebalances every
/// Options::minimumNumberOfScansBetweenRebalance() scans on the same
/// reasoning: donation must be rare relative to tracing.
pub const donate_interval = 64;
pub const donate_min_stack = 64;

/// Donate the older half of a local stack to the shared ring and wake any
/// spinning lane. The bottom of a LIFO trace stack holds the earliest
/// discovered -- widest -- subtrees, which is exactly what an idle worker
/// should be handed; the hot top stays local. A full ring stops the
/// donation mid-way; nothing is lost, the remainder is compacted back.
fn donateHalf(local: *gc.MarkStack, queue: *gc.mark_queue.Queue) void {
    const items = local.items orelse return;
    const n = local.len / 2;
    var moved: usize = 0;
    while (moved < n) : (moved += 1) {
        if (!queue.push(items[moved])) break;
    }
    if (moved == 0) return;
    const remaining = local.len - moved;
    std.mem.copyForwards(*gc.Header, items[0..remaining], items[moved..local.len]);
    local.len = remaining;
}

pub const Stats = struct {
    parallel_slices: usize = 0,
    worker_marked: usize = 0,
    owner_marked: usize = 0,
    spawn_failures: usize = 0,
};

pub const Pool = struct {
    threads: [max_workers]?std.Thread = @splat(null),
    count: usize = 0,
    spawned: bool = false,
    /// Owner-only: at least one parallel slice has started in this cycle, so
    /// helpers are waiting on the atomic generation rather than the condvar.
    /// Fits in the padding before `wake_mutex`; `Pool` does not grow.
    cycle_hot: bool = false,

    /// The condvar releases workers into the first parallel slice of a cycle;
    /// the atomic generation releases the already-hot workers into later
    /// slices. POSIX uses raw pthread primitives: zig 0.16 moved std's
    /// Mutex/Condition behind an Io instance the collector's interior has no
    /// business threading through, and the process links libc already. Windows
    /// has no pthreads; `WaitOnAddress` / `WakeByAddressAll` on `job_gen` are
    /// the same generation protocol without a mutex.
    wake_mutex: if (builtin.os.tag == .windows) void else std.c.pthread_mutex_t =
        if (builtin.os.tag == .windows) {} else std.c.PTHREAD_MUTEX_INITIALIZER,
    wake_cond: if (builtin.os.tag == .windows) void else std.c.pthread_cond_t =
        if (builtin.os.tag == .windows) {} else std.c.PTHREAD_COND_INITIALIZER,
    job_gen: std.atomic.Value(u32) = .init(0),
    /// Budget exhausted: spill local stacks and park.
    stop: std.atomic.Value(bool) = .init(false),
    /// Workers currently inside a slice (between wake and park).
    active: std.atomic.Value(u32) = .init(0),
    /// Tracers currently holding work (owner included). Zero with an empty
    /// ring means the frontier is exhausted.
    busy: std.atomic.Value(u32) = .init(0),
    shutdown_flag: std.atomic.Value(bool) = .init(false),

    rt: ?*JSRuntime = null,
    /// Slices this marking cycle has already taken; reset at cycle begin.
    /// The second slice onward goes parallel: needing a second slice proves
    /// the frontier holds more than a budget of work.
    slice_in_cycle: usize = 0,
    worker_stacks: [max_workers]gc.MarkStack = @splat(.{}),
    worker_marked: [max_workers]usize = @splat(0),
    stats: Stats = .{},
    /// Whole-run, `--gc-stats`-only final-mark census. It lives beside the
    /// trace pool so RC builds carry no storage and single-CPU runs retain the
    /// same reporting authority even though no helper thread is spawned.
    footprint: stw.MarkFootprint = .{},

    /// Spawn workers once, sized by the affinity mask. Zero workers (single
    /// CPU, spawn failure, or a corpus of tiny heaps) means every slice
    /// stays on the exact single-threaded path.
    pub fn ensureSpawned(self: *Pool, rt: *JSRuntime) void {
        if (self.spawned) return;
        self.spawned = true;
        self.rt = rt;
        const cpus = std.Thread.getCpuCount() catch 1;
        if (cpus < 2) return;
        const want = @min(max_workers, cpus - 1);
        var i: usize = 0;
        while (i < want) : (i += 1) {
            self.worker_stacks[i].ensure();
            if (self.worker_stacks[i].items == null) break;
            self.threads[i] = std.Thread.spawn(.{}, workerMain, .{ self, i }) catch {
                self.stats.spawn_failures += 1;
                break;
            };
            self.count += 1;
        }
    }

    pub fn shutdown(self: *Pool) void {
        if (self.count == 0) {
            for (&self.worker_stacks) |*stack| stack.deinitStack();
            return;
        }
        self.shutdown_flag.store(true, .release);
        self.bumpAndBroadcast();
        for (&self.threads) |*slot| {
            if (slot.*) |thread| thread.join();
            slot.* = null;
        }
        self.count = 0;
        for (&self.worker_stacks) |*stack| stack.deinitStack();
    }

    pub fn available(self: *const Pool) bool {
        return self.count > 0;
    }

    fn waitForGeneration(self: *Pool, seen: u32) void {
        if (comptime builtin.os.tag == .windows) {
            var expected = seen;
            while (self.job_gen.load(.acquire) == expected) {
                _ = std.os.windows.ntdll.RtlWaitOnAddress(
                    @ptrCast(&self.job_gen),
                    @ptrCast(&expected),
                    @sizeOf(u32),
                    null,
                );
            }
        } else {
            _ = std.c.pthread_mutex_lock(&self.wake_mutex);
            while (self.job_gen.load(.acquire) == seen) {
                _ = std.c.pthread_cond_wait(&self.wake_cond, &self.wake_mutex);
            }
            _ = std.c.pthread_mutex_unlock(&self.wake_mutex);
        }
    }

    fn bumpAndBroadcast(self: *Pool) void {
        if (comptime builtin.os.tag == .windows) {
            _ = self.job_gen.fetchAdd(1, .release);
            std.os.windows.ntdll.RtlWakeAddressAll(@ptrCast(&self.job_gen));
        } else {
            _ = std.c.pthread_mutex_lock(&self.wake_mutex);
            _ = self.job_gen.fetchAdd(1, .release);
            _ = std.c.pthread_mutex_unlock(&self.wake_mutex);
            _ = std.c.pthread_cond_broadcast(&self.wake_cond);
        }
    }

    fn workerMain(self: *Pool, index: usize) void {
        var seen: u32 = 0;
        while (true) {
            self.waitForGeneration(seen);
            seen = self.job_gen.load(.monotonic);
            if (self.shutdown_flag.load(.acquire)) return;
            cycle: while (true) {
                _ = self.active.fetchAdd(1, .acquire);
                self.drainAsWorker(index);
                _ = self.active.fetchSub(1, .release);

                // The object graph is mutable between slices, so this loop
                // must never call `drainAsWorker` until the owner publishes a
                // new generation. Spinning keeps the lane scheduled during a
                // multi-slice cycle; a closed/aborted cycle sends it back to
                // the condvar instead of burning CPU through the mutator's
                // inter-cycle work.
                while (true) {
                    if (self.shutdown_flag.load(.acquire)) return;
                    if (!self.rt.?.gc.concurrent.markingActive()) break :cycle;
                    const generation = self.job_gen.load(.acquire);
                    if (generation != seen) {
                        seen = generation;
                        break;
                    }
                    std.atomic.spinLoopHint();
                }
            }
        }
    }

    fn drainAsWorker(self: *Pool, index: usize) void {
        const rt = self.rt.?;
        const queue = &rt.gc.concurrent_mark_queue;
        const local = &self.worker_stacks[index];
        var tracer = Tracer{ .rt = rt, .local = local, .queue = queue };

        _ = self.busy.fetchAdd(1, .acq_rel);
        var counted_busy = true;
        var since_donate: usize = 0;
        outer: while (!self.stop.load(.monotonic)) {
            const header = local.popPrefetch() orelse queue.pop() orelse {
                _ = self.busy.fetchSub(1, .release);
                counted_busy = false;
                while (true) {
                    if (self.stop.load(.monotonic)) break :outer;
                    if (queue.len() != 0) {
                        _ = self.busy.fetchAdd(1, .acq_rel);
                        counted_busy = true;
                        continue :outer;
                    }
                    if (self.busy.load(.acquire) == 0) break :outer;
                    std.atomic.spinLoopHint();
                }
            };
            tracer.traceOne(header);
            since_donate += 1;
            if (since_donate == donate_interval) {
                since_donate = 0;
                if (queue.len() == 0 and local.len >= donate_min_stack) donateHalf(local, queue);
            }
        }
        if (counted_busy) _ = self.busy.fetchSub(1, .release);
        // Park protocol: whatever remains locally goes back to the ring so
        // the frontier is never trapped in a sleeping thread. A full ring
        // downgrades to rescan via the ring's own overflow flag.
        while (local.pop()) |h| _ = queue.push(h);
        self.worker_marked[index] +%= tracer.marked;
    }
};

/// The parallel slice's per-thread visitor. Same shading semantics as the
/// single-threaded `Collector` in queue mode, with the atomic claim as the
/// dedup and no error paths: in queue mode nothing on the trace allocates.
pub const Tracer = struct {
    rt: *JSRuntime,
    local: *gc.MarkStack,
    queue: *gc.mark_queue.Queue,
    marked: usize = 0,

    pub fn traceOne(self: *Tracer, header: *gc.Header) void {
        stw.traceHeaderEdges(self.rt, self, header) catch unreachable;
        // Trace-coupled retirement, same contract as the serial collector's.
        // Safe from a worker lane: the bit lives in the header byte, only
        // the lane that won the mark claim gets here for a given object, and
        // the mutator is stopped for the whole slice.
        self.rt.gc.retireTracedYoung(header);
    }

    /// Parallel visitors receive only typed, precise edges. Conservative
    /// candidates are validated on the owner before they can seed this pool.
    fn shadeExact(self: *Tracer, header: *gc.Header) void {
        // Cheap plain-load filter first: most edges point at already-marked
        // objects, and a fetch-or on every edge is measurably worse than a
        // load + branch. The claim below stays the authority.
        if (self.rt.gc.headerMarked(header)) return;
        if (!header.meta().alloc_info.heap_accounted) return;
        if (header.meta().flags.cycle_visited) return;
        if (!self.rt.gc.tryAcquireHeaderMark(header)) return;
        self.marked += 1;
        const kind = header.meta().flags.kind;
        if (kind == .shape or kind == .realm_context) {
            // rc-managed kinds never enter any queue (the mutator can free
            // them between slices and the entry would dangle); the claim
            // above already dedups the recursion.
            self.traceOne(header);
            return;
        }
        if (!self.local.push(header)) _ = self.queue.push(header);
    }

    pub fn visitValue(self: *Tracer, val: *JSValue) void {
        if (val.cycleMarkHeader()) |header| self.shadeExact(header);
    }

    pub fn visitObject(self: *Tracer, obj_ptr: *?*Object) void {
        const object = obj_ptr.* orelse return;
        self.shadeExact(&object.header);
    }

    pub fn visitShape(self: *Tracer, shape_ref: *shape_mod.Shape) void {
        self.shadeExact(&shape_ref.header);
    }

    pub fn visitRealm(self: *Tracer, ctx_ptr: *?*context_mod.RealmContext) void {
        if (ctx_ptr.*) |ctx| self.shadeExact(&ctx.header);
    }

    pub fn visitModule(self: *Tracer, record: *module_mod.ModuleRecord) void {
        self.shadeExact(&record.header);
    }

    /// Strong mark must not promote a weak edge (ephemeron fixed point owns
    /// those, on the owner thread at finish).
    pub fn visitWeakCollectionEntry(self: *Tracer, entry: *object_payloads.WeakCollectionEntry) void {
        _ = self;
        _ = entry;
    }

    pub fn visitFinalizationCell(self: *Tracer, entry: *object_payloads.FinalizationRegistryCell) void {
        if (entry.keepsHeldValuesAlive()) self.visitValue(&entry.held_value);
    }
};

/// One parallel mark slice. The owner participates as a tracer lane; helpers
/// use the condvar only for the cycle's first parallel slice and an atomic
/// generation for later slices. Every slice still ends with all helpers
/// quiescent before the mutator resumes. Returns true when the frontier is
/// exhausted (ready for final remark).
pub fn parallelMarkStep(rt: *JSRuntime, pool: *Pool, budget_ns: u64) bool {
    const queue = &rt.gc.concurrent_mark_queue;
    const owner_stack = &rt.gc.mark_stack;

    // Feed the ring so helpers have something to start on: move a batch of
    // the owner's parked frontier over. MPMC pushes cost a CAS each, so the
    // batch is bounded; helpers refill it themselves by spilling as their
    // local stacks overflow.
    var fed: usize = 0;
    while (fed < 8192 and owner_stack.len > 0) : (fed += 1) {
        const h = owner_stack.pop() orelse break;
        if (!queue.push(h)) {
            // Ring full: keep it local, the owner will trace it.
            _ = owner_stack.push(h);
            break;
        }
    }

    pool.stop.store(false, .monotonic);
    if (pool.cycle_hot) {
        _ = pool.job_gen.fetchAdd(1, .release);
    } else {
        pool.cycle_hot = true;
        pool.bumpAndBroadcast();
    }

    var tracer = Tracer{ .rt = rt, .local = owner_stack, .queue = queue };
    const started = profile.nowNanos();
    var since_clock: usize = 0;
    _ = pool.busy.fetchAdd(1, .acq_rel);
    var owner_busy = true;
    outer: while (true) {
        const header = owner_stack.popPrefetch() orelse queue.pop() orelse {
            _ = pool.busy.fetchSub(1, .release);
            owner_busy = false;
            while (true) {
                if (queue.len() != 0) {
                    _ = pool.busy.fetchAdd(1, .acq_rel);
                    owner_busy = true;
                    continue :outer;
                }
                if (pool.busy.load(.acquire) == 0) break :outer;
                if (profile.nowNanos() -| started >= budget_ns) break :outer;
                std.atomic.spinLoopHint();
            }
        };
        tracer.traceOne(header);
        since_clock += 1;
        if (since_clock == 64) {
            since_clock = 0;
            if (profile.nowNanos() -| started >= budget_ns) break;
            if (queue.len() == 0 and owner_stack.len >= donate_min_stack) donateHalf(owner_stack, queue);
        }
    }
    if (owner_busy) _ = pool.busy.fetchSub(1, .release);

    // Stop helpers and wait for them to park (they spill their stacks back
    // to the ring on the way out).
    pool.stop.store(true, .release);
    while (pool.active.load(.acquire) != 0) std.atomic.spinLoopHint();

    var marked: usize = 0;
    for (&pool.worker_marked) |*w| {
        marked += w.*;
        w.* = 0;
    }
    pool.stats.worker_marked += marked;
    pool.stats.owner_marked += tracer.marked;
    pool.stats.parallel_slices += 1;

    return owner_stack.len == 0 and queue.len() == 0;
}

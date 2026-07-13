//! Atomics engine primitives that live in `exec` because the Atomics wait
//! mechanism is part of the VM core, not a client builtin (QuickJS keeps
//! `js_atomics_wait` in the engine; see quickjs.c:61234 and the roadmap's
//! "Atomics 等待机制留 exec" decision). The slow-path dispatcher
//! (`call_runtime.qjsAtomicsCallForNativeRecord`) switches on this
//! `StaticMethod` selector, and the wait/notify state machine lives beside it
//! in `call_runtime.zig`. The install-time name->id mapping (`methodId`) lives
//! in `exec/atomics_ops.zig`, so the registry binds the namespace without a
//! builtins -> exec detour.

const std = @import("std");

pub const StaticMethod = enum(u32) {
    add = 1,
    @"and" = 2,
    compare_exchange = 3,
    exchange = 4,
    is_lock_free = 5,
    load = 6,
    notify = 7,
    @"or" = 8,
    pause = 9,
    store = 10,
    sub = 11,
    wait = 12,
    wait_async = 13,
    xor = 14,
};

pub fn isLockFree(size: usize) bool {
    return size == 1 or size == 2 or size == 4 or size == 8;
}

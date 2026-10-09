//! Engine integration tests pulled into the unified suite.
//!
//! Unit tests stay next to the implementation. This file only pulls
//! multi-module system tests: public API, runtime/GC, and VM/eval.
//! Zig 0.16 names these `tests.public_api.`, `tests.core.`, `tests.exec.`.
pub const public_api = @import("public_api.zig");
pub const core = @import("core.zig");
pub const exec = @import("exec.zig");

test {
    _ = public_api;
    _ = core;
    _ = core.value_boundary;
    _ = core.roots_nursery;
    _ = core.atoms_s3;
    _ = core.storage_s4;
    _ = core.gc_stress;
    _ = core.oom_cap;
    _ = core.embedding_api;
    _ = core.heap_limit;
    _ = core.interrupts;
    _ = core.runtime_lifecycle;
    _ = core.microtasks;
    _ = core.value_root_buffer;
    _ = core.regressions;
    _ = exec;
    // A `pub const` import does not collect that file's tests. Reference
    // each area from this existing test so the suite does not grow one.
    _ = exec.string_boundary;
    _ = exec.interrupts_spread;
    _ = exec.native_dispatch;
    _ = exec.runtime_tails_jobs;
    _ = exec.calls_generators_classes;
    _ = exec.realms_modules;
    _ = exec.vm_branches_inlining;
    _ = exec.gc_rooting;
    _ = exec.typescript;
    _ = exec.builtins;
    _ = exec.regressions;
}

//! Integration-test harness for `tests/core.zig` and `tests/exec.zig`.
//!
//! This is not an engine package. Unit tests next to `src/` must not
//! import it; they only need `runObjectCycleRemoval` (see the local
//! `reclaimNow` helpers in `src/parser/tests.zig` and
//! `src/bytecode/tests.zig`).
//!
//! | File | Owns |
//! |---|---|
//! | `harness/gc.zig` | precise reclaim, weak collections, incremental GC drain |
//! | `harness/expect.zig` | string / set assertions |
//! | `harness/fixture.zig` | hand-written bytecode and parse-then-run |
//! | `harness/test_engine.zig` | one-off TestEngine, host probes, scratch dirs |
//! | `harness/shared.zig` | process-level shared engine and leak gate |

pub const gc = @import("harness/gc.zig");
pub const expect = @import("harness/expect.zig");
pub const fixture = @import("harness/fixture.zig");
pub const test_engine = @import("harness/test_engine.zig");
pub const shared = @import("harness/shared.zig");

pub const reclaimNow = gc.reclaimNow;
pub const objectFromValue = gc.objectFromValue;
pub const appendWeakCollectionEntry = gc.appendWeakCollectionEntry;
pub const appendWeakCollectionEntryForValue = gc.appendWeakCollectionEntryForValue;
pub const finishGcCycles = gc.finishGcCycles;

pub const expectActiveSetStrings = expect.expectActiveSetStrings;
pub const expectStringValueBytes = expect.expectStringValueBytes;

pub const Fixture = fixture.Fixture;
pub const FixtureSpec = fixture.FixtureSpec;
pub const makeFixture = fixture.makeFixture;
pub const runFixture = fixture.runFixture;
pub const createTailOpcodeFixture = fixture.createTailOpcodeFixture;
pub const vm_helpers = fixture.vm_helpers;

pub const evalTypeScriptChecked = test_engine.evalTypeScriptChecked;
pub const registerStandardGlobalsBare = test_engine.registerStandardGlobalsBare;
pub const installHostGlobalsBare = test_engine.installHostGlobalsBare;
pub const countJob = test_engine.countJob;
pub const countJobArgs = test_engine.countJobArgs;
pub const TestEngine = test_engine.TestEngine;
pub const LegacyProbeState = test_engine.LegacyProbeState;
pub const scratchDirForProcess = test_engine.scratchDirForProcess;

pub const expectPrints = shared.expectPrints;
pub const sharedTestEngine = shared.sharedTestEngine;
pub const deinitSharedTestEngine = shared.deinitSharedTestEngine;
pub const endSharedTest = shared.endSharedTest;

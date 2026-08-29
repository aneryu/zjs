# Tracing GC Default, And The Retirement Of The RC Rollback

Status: 2026-08-29. Two things happened on this date, in this order.

1. **Stage 7 promotion executed** (`7fc2c9e9` adopt, `6e5d7a69` flip): the
   tracing collector became the production default on `main`. The gate basis:
   gc_heavy_six fixed-work geomean 1.0419 against the frozen rc baseline
   (margin 1.05 met), splay major pause p99 ~1 ms against rc's 42.4 ms,
   dual-variant unit suites green, trace-build test262 0/49778.
   `docs/splay-account-2026-08-28.md` holds the full ledger.
2. **The rc collector was retired outright** (branch `gc/rm-rc`). The rollback
   story moved from a build flag to git history plus the frozen binaries. See
   `docs/rc-retirement-2026-08-29.md` for what was deleted, what was kept, and
   the anchor evidence.

This document is what remains of the rollback contract: the parts that are
still true when the second implementation no longer exists.

## Build Contract

```sh
# The only build. There is one collector.
zig build zjs
```

`-Dzjs_gc` survives as a selector with exactly one legal value, `trace_stw`, so
that a caller who passes a retired one gets a migration message rather than
"unknown option":

```
$ zig build zjs -Dzjs_gc=rc
error: -Dzjs_gc=rc is no longer available: rc collector removed 2026-08-29;
use a frozen binary or checkout before 6e5d7a69
```

`-Dzjs_experimental_gc=trace_stw|off` survives as an accepted-but-redundant
compat alias, because gate scripts and release automation still pass it.
`-Dzjs_gc=shadow` is rejected by the same message: the Stage 1 shadow observer
enumerated the rc heap and had nothing left to observe.

`build_options.zjs_gc` remains the resolved implementation selector inside the
engine, and `gc.trace_stw_enabled` remains a public comptime `true`. Roughly
270 `if (comptime gc.trace_stw_enabled)` gates read it; keeping the name meant
none of them had to move when the `else` arms were deleted.

The `zjs-config-v2` configuration signature describes the shipped
compiler/value/build-safety configuration and does **not** encode the
collector. With one collector left that is no longer a gap, but release
manifests should still record the resolved GC option values: they are how a
future reader tells a post-retirement artifact from a pre-retirement one.

## Rolling Back To The RC Collector

The rollback is still an artifact replacement plus a process restart. It is not
an in-process heap conversion, and it never was. What changed is where the rc
artifact comes from.

1. Stop promotion of the current artifact and retain its binary, manifest,
   logs, crash data, and workload inputs for diagnosis.
2. Obtain an rc binary. In order of preference:
   * a frozen release artifact whose recorded SHA-256 you can verify;
   * the frozen binaries in `/home/aneryu/zjs-frozen/` and the public tag
     `frozen/gc-tracing-2026-08-26` (`62061f94`);
   * a build from a checkout **before `6e5d7a69`**, with
     `zig build zjs -Dzjs_gc=rc -Dzjs_experimental_gc=off`. That revision still
     contains both collectors; no revision after it does.
3. Run the release gates from `docs/release-checklist.md` against whatever you
   built, at the revision you built it from. Do not run today's gates against
   an old binary and do not claim a newly built binary is byte-identical to a
   previously released one without comparing hashes.
4. Strip/sign/package by the normal release procedure. The manifest must record
   the source revision, `zjs_gc=rc`, `zjs_experimental_gc=off`, and the hash of
   the bytes actually published.
5. Replace the artifact in the affected channel and restart every affected
   process. Drain or terminate the tracing processes; never attach an rc
   runtime to their live heap, handles, plugin payloads, or pending GC work.
6. Verify with rc smoke/correctness probes and reset the GC telemetry baseline.

The trade this retirement made, stated plainly: a collector-only rollback used
to be a one-flag rebuild at the current revision; it is now a rebuild at an old
revision, which carries every other change made since. That is the cost of not
maintaining a second lifetime semantics in every module that touches object
lifetime, and the owner accepted it on 2026-08-29.

## State And Compatibility Boundary

Unchanged by the retirement -- these are properties of "restart into a
different collector", not of how the rc binary is produced.

| State or promise | After an RC rollback |
|---|---|
| Live JavaScript heap, local/persistent/weak handles, native pointers into it | Invalid when the tracing process exits. Recreate the runtime and reconstruct state through application-level inputs. |
| Pending jobs, timers, promises, weak cleanup, deferred finalizers, incremental/retirement work | Not transferable. Durable work must be replayed by the embedding application; collector queues and statistics start empty. |
| GC statistics, pause rings, allocation/retirement counters | Start a new series labelled RC. Do not splice tracing and RC samples into one continuous baseline. |
| Current runtime-plugin ABI | Reload is permitted only if the normal descriptor checks pass. The ABI pins `JSValue` layout and features, not a live heap or GC-header layout; process-local plugin payload state does not survive restart. |
| Application data outside the engine heap | Unchanged by the collector rollback, subject to the application's own compatibility contract. |
| Resumable heap/engine snapshot | No such production format is promised, so there is no heap image to convert. Any future format must be versioned, and a pre-retirement binary must reject it unless an explicit converter exists. |

The points that a source rollback alone cannot undo are external compatibility
promises. Publishing a tracing-only heap/checkpoint format, promising GC header
or object-layout details through a plugin ABI, or allowing plugins to require a
tracing-only feature creates persisted data or third-party binaries that an rc
build may not understand. Before any such release, add a format/ABI version, a
reject path, and either a tested down-converter or an explicit statement that
the data/plugin becomes unusable after rollback.

## Stage 7 Preflight (Historical)

The preflight table that used to close this document recorded a **NO-GO** as of
2026-08-28: §1.2's full correctness matrix had not been rerun on one clean
candidate, §1.3's peak/live envelope was at 4.63x against a 1.8 limit, and the
`gc_heavy_six` geomean stood at 1.112 against a 1.05 margin. All three closed
before the Stage 7 flip on 2026-08-29 (geomean 1.0419; the pause and envelope
evidence is in `docs/splay-account-2026-08-28.md`). The table is not reproduced
here because it is no longer a checklist anyone can act on -- it was a gate on
a decision that has been taken. `7fc2c9e9`'s message and the splay account are
the record.

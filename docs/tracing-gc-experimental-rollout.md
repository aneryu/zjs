# Tracing GC Default And RC Rollback

Status: 2026-08-29. **Stage 7 promotion executed**: the tracing collector is
the production default on `main`. The gate basis: gc_heavy_six fixed-work
geomean 1.0419 vs the frozen rc baseline (margin 1.05 met), splay major pause
p99 ~1ms vs rc 42.4ms, dual-variant unit suites green, trace-build test262
0/49778 (docs/splay-account-2026-08-28.md holds the full ledger). This
document keeps the rollback contract that Stage 7 required.

## Build Contract

```sh
# Production/default: stop-the-world tracing collector.
zig build zjs

# Rollback: refcounting collector. The explicit two-option form pins both
# halves of the decision for release automation.
zig build zjs -Dzjs_gc=rc -Dzjs_experimental_gc=off
```

`-Dzjs_experimental_gc=trace_stw` remains accepted as a compat alias from the
experimental phase (now redundant with the default), so existing gate scripts
keep working. `-Dzjs_gc=shadow` remains the non-reclaiming observer and cannot
be combined with the reclaiming tracer.

This is a compile-time collector selection, not a runtime flag. One process
cannot change an existing heap from tracing to RC or back. The internal
`build_options.zjs_gc` value remains the resolved implementation selector so
all existing `comptime` collector branches are erased in the RC artifact.

Experimental artifacts must use a separate channel/name and a release manifest
that records at least source revision, target triple, exact two GC option
values, normal configuration signature, and artifact SHA-256. The current
`zjs-config-v2` signature describes the shipped compiler/value/build-safety
configuration but does **not** encode the collector; it is therefore not, by
itself, proof that an artifact is RC. Release automation must fail closed when
the manifest lacks the GC fields.

## Build/Release Rollback To RC

Rollback is an artifact replacement plus process restart. It is not an
in-process heap conversion.

1. Stop promotion of the experimental artifact and retain its binary, manifest,
   logs, crash data, and workload inputs for diagnosis. Select the current
   source revision if the incident is collector-only; select the last known-good
   RC release revision if other changes are implicated.
2. Build RC explicitly with
   `zig build zjs -Dzjs_gc=rc -Dzjs_experimental_gc=off`. Do not reuse an
   experimental binary or only change its filename.
3. Run the normal RC release gates from `docs/release-checklist.md`, including
   `engine-production-gate`, the ReleaseSafe run, and
   `config-signature-check`, always with `-Dzjs_gc=rc` and
   `-Dzjs_experimental_gc=off`. For an exact previously released RC artifact,
   verify its recorded SHA-256 instead of claiming a newly built binary is
   byte-identical without evidence.
4. Strip/sign/package the RC binary by the normal release procedure. Its
   manifest must say `zjs_gc=rc`, `zjs_experimental_gc=off`, and contain the
   hash of the bytes actually published.
5. Replace the experimental artifact in the affected channel and restart every
   affected process. Drain or terminate old tracing processes; never attach an
   RC runtime to their live heap, handles, plugin payloads, or pending GC work.
6. Verify the restarted service with RC smoke/correctness probes and reset the
   GC telemetry baseline. Close the incident only after no experimental
   artifact remains addressable from the production channel.

The rollback does not require deleting tracing code or reverting its commits.
The release switch is the boundary: keeping both implementations buildable is
what makes a collector-only rollback small and auditable.

## State And Compatibility Boundary

| State or promise | After RC rollback |
|---|---|
| Live JavaScript heap, local/persistent/weak handles, native pointers into it | Invalid when the tracing process exits. Recreate the runtime and reconstruct state through application-level inputs. |
| Pending jobs, timers, promises, weak cleanup, deferred finalizers, incremental/retirement work | Not transferable. Durable work must be replayed by the embedding application; collector queues and statistics start empty. |
| GC statistics, pause rings, allocation/retirement counters | Start a new series labelled RC. Do not splice tracing and RC samples into one continuous baseline. |
| Current runtime-plugin ABI | Reload is permitted only if the normal descriptor checks pass. The ABI pins `JSValue` layout and features, not a live heap or GC-header layout; process-local plugin payload state does not survive restart. |
| Application data outside the engine heap | Unchanged by the collector rollback, subject to the application's own compatibility contract. |
| Resumable heap/engine snapshot | No such production format is currently promised, so there is no current heap image to convert. Any future experimental format must be versioned and RC must reject it unless an explicit converter exists. |

The points that source rollback alone cannot undo are external compatibility
promises. Publishing a tracing-only heap/checkpoint format, promising GC header
or object-layout details through a plugin ABI, or allowing plugins to require a
tracing-only feature creates persisted data or third-party binaries that RC may
not understand. Before any such release, add a format/ABI version, an RC-side
reject path, and either a tested down-converter or an explicit statement that
the data/plugin becomes unusable after rollback. Do not call an experimental
layout stable merely to make rollback look complete.

## Stage 7 Production-Default Preflight

An unchecked row blocks the default switch. Evidence must belong to one clean
release-candidate revision; historical results are useful diagnostics but are
not carried forward as a candidate sign-off.

| Done | Stage 7 requirement | Current status (2026-08-28) | What closes it |
|---|---|---|---|
| [ ] | All correctness gates in `tracing-gc-design.md` §1.2 | **Not signed for a current release candidate.** Historical tracing test262/OOM/stress results and current unit/macro/fixed-work smoke are green, including the representation invariant negative tests, but the full §1.2 matrix has not been rerun on one clean post-lane candidate. | Run and archive the entire §1.2/§14 matrix on the exact candidate, including deletion probes, shadow agreement, full test262, failure injection, concurrency, plugin/host, and ReleaseFast stress. |
| [ ] | Declared pause and memory envelopes in §1.3 | **Failed.** lane-f A2 (`gc/lane-f@806080e8`, snapshot engine `c9ae9853`) records fixed-work splay `account peak = 251,999,130` and `live = 54,427,792`, or **4.63×**, above the 1.8 peak/live limit. Its block heap is `232,783,872 / 67,949,680 = 3.426×`, also above the 1.3 committed/live limit. | Produce contract-complete pause and memory evidence for the declared corpus/heap range with every bound satisfied, or obtain an explicit design-owner change to §1.3. |
| [ ] | No regression under the current measurement contract | **Failed.** The adjudicated `gc_heavy_six` fixed-work trace/RC geomean is **1.112** against the **1.05** margin (raytrace 1.070, earley-boyer 1.064, splay 1.624). | A clean-revision, contract-valid measurement at or below the governing margin, with provenance and balanced samples. |
| [x] | Build/release-level rollback plan | **Ready.** The experimental-only selector and the RC artifact/restart procedure are defined above; the legacy peer-looking tracing selector fails closed. | Revalidate the commands and release-manifest fields on the eventual candidate. |

Verdict: **Stage 7 production-default work is NO-GO.** The experimental switch
and rollback preparation may remain landed because they do not change the
shipped RC default and do not waive any unchecked row.

# STATUS

This page is the single authoritative status source for `zjs`.
README carries condensed copies of the headline tables; when they disagree,
this page and the documents it names win.

## Roadmap governance

Current roadmap: `docs/roadmap.md` **v2.0** (registry
`docs/roadmap/work-items.yaml`), approval status: **approved execution
baseline** (all §0.3 hard conditions met 2026-08-26; owner ratified the
yardstick ruling and the main required-checks ruleset the same day).
v2.0 (2026-09-06) records a fact, not a design: the tracing collector is
the only collector in the tree. Owner ruled 2026-09-03 to finish the
tracing GC and adapt the object model completely; TGC S0–S5 landed on
main 2026-09-04→05 (`e972c4b5` → `f005aee7`), refcounting left the
object model, and the `gc/tracing` branch and the dual-session split are
retired. The G2-GC-MERGE statistical protocol was superseded by that
ruling and never run (no verdict); the merge basis was the Stage 0
fixed-work screen against the frozen rc baseline plus four green gates
(`docs/tracing-gc-completion-account.md`). Still owed after the merge:
VM-CONTRACT-GC (the representation contract is v2, exported from the
branch before S1–S5) and the conservative-root residue
R1.
BASE-G0 (measurement freeze) completed 2026-08-26: the official QuickJS
yardstick is the GCC-16 build recorded in
`reports/evidence/BASE-G0/manifest.json`, the tracing-GC candidate is
pinned by the public tag `frozen/gc-tracing-2026-08-26`, and all official
measurements are governed by `policies/` (preregistered) with evidence
registered under `reports/evidence/`. Main branch protection:
`main-no-force-push` (no force-push/deletion, no bypass) +
`main-required-checks` (roadmap-lint, linux-arm64, linux-x86_64;
repository-admin bypass keeps the owner's direct-push workflow).

## test262

Checked report date: 2026-09-06 (merge-gate run on `ca537eca`; the numbers
are unchanged since 2026-08-22 and `COMPATIBILITY.md` carries the same
numbers; the same result holds under `ZJS_GC_STRESS=1` since the S5
closeout).

- 49,778 prepared / 44,584 pass / 0 checked-in known failures / 0 unexpected failures / 5,194 feature skips
- Configuration = repository `test262.conf` + submodule pin `4249661388e5d3f92a85186213da140a6481490f`

See `COMPATIBILITY.md` and `test262.conf` for the active validation boundary.
Configured skip classes include Intl, Temporal, ShadowRealm, decorators,
source-phase imports, and PTC.

## Performance

The authoritative score source is `docs/perf/bench-v8-status.md`; this page
does not maintain its own copy of the numbers. Since 2026-08-25 the vendored
suite (`tools/perf/bench_v8/`) is Octane 2.0 (V8 suite version 9). The
current five-engine snapshot (2026-09-06, 17 results, zlib scored, zjs
`10966b12` with the tracing collector) reads zjs/qjs composite **0.9666**
against the GCC 16.0.1 reference build: 11 of 17 results at or above
QuickJS; the gap is Splay 0.62 / SplayLatency 0.69 (the structural
marking account closed in `docs/tracing-gc-completion-account.md` §6b),
then EarleyBoyer 0.85 and PdfJS 0.89. **Owner ruling 2026-09-06: the
performance line is closed; Octane vs QuickJS is a regression gate at
≥ 0.95 from here.** Routine snapshots run zjs + QuickJS only; the other
three engines are re-run only when the suite contract changes. Per the 2026-08-25 reference-drift adjudication,
every published record must carry the reference binary's fingerprint
(hash + compiler); ratios are not comparable across suite versions or
reference binaries. The official yardstick was ruled 2026-08-26 (BASE-G0,
owner-ratified): the GCC-16 reference build pinned in
`reports/evidence/BASE-G0/manifest.json`.

The external-checkout zoo runner was retired 2026-08-29: the vendored
bench-v8 suite covers the same Octane corpus, and fixed-work attribution
moved to `tools/perf/bench_v8/run_fixed_pmu.py`. The last zoo baseline
(geomean 1.0304, v7 suite / GCC-13 reference) was removed from the active
tree with the 2026-08-25 stale-doc cleanup; recover it from git history.
The superseded version-7 headline records (2026-08-19 composite 1.0464)
were removed the same way.

This is a maintainer single-machine measurement; there is no independent
reproduction yet.

- Machine: ARM Cortex-X925 (3.9 GHz big cores, pinned), Linux 6.17.
- QuickJS reference pin: commit `04be246`, upstream Makefile default release
  build. Two reference binaries exist for this same commit (GCC 13.3.0 and
  GCC 16.0.1, aarch64), and the compiler difference alone moves the composite
  by ~6.6%; record the binary fingerprint with every measurement (see
  `docs/perf/bench-v8-status.md`).
- Campaign ledgers and attribution reports were moved out of the active tree;
  recover them from git history at `90eb9385^` (`reports/perf/qjs-align/` —
  the directory was deleted in the release commit itself, so the `v0.1.0`
  tag does not contain it). Raw sample files were deleted during campaign
  close; re-measurement must re-run the measurement contract.

Measurement contract: `tools/compare/measurement_contract.js` with
`tools/compare/measurement_policy.json`; the prose incident register
(16 clauses) is preserved in git history at
`90eb9385^:reports/perf/qjs-align/measurement-contracts.md`.

## Gates

The dated cells below are snapshots from the runs they name, not continuous
results. The most recent evidence is 2026-09-06 on `ca537eca` (the first
push of the tracing-collector main; see the two 2026-09-06 rows).

Wall-clock as of 2026-09-06 (build pool on the big cores, see `mise.toml`):
`zig build check` 7 s, `zig build test` 21 s, `mise run checkpoint-gate`
26 s, `mise run batch-gate` (= `zig build merge-gate`) 91 s, full test262 9.8 s standalone.

| Gate | What it covers | This lane |
|------|----------------|-----------|
| `mise run batch-gate` (= `zig build merge-gate`) | one build graph: unified Debug suite (16 shards), stress tier, gc-stress, Debug CLI smoke, architecture lints, full test262, fixed-work smoke (ordinary + arena-audit runs per workload) | 2026-09-06, `ca537eca` (main): PASS, 91 s. test262 `0/49778 errors, passed 44584`. Re-run the same day on `ef24c0bb` (Q21 fix + the two diagnostics commits): PASS, 70/70 steps, test262 unchanged. |
| nightly tiers, run locally | `zig build test -Doptimize=ReleaseSafe`, `test-oom`, `test-leak-census`, `test-stress`, `zig build test -Dzjs_ownership_audit=true` | 2026-09-06, `ca537eca` (main, local): all five PASS — ReleaseSafe full suite 24/24 steps, test-oom 22 passed / 0 failed, leak-census 1570 passed / 0 failed, test-stress 9/9 steps, ownership-audit 24/24 steps. |
| `zig build engine-production-gate --summary all` | unified Debug suite, ReleaseFast CLI smoke, architecture lints (including compiler-stage `nm`), OOM-cap, full test262 | 2026-08-17, branch `lane/prod-v0.1.0`: PASS. 35/35 steps succeeded. unified-tests: 2266 passed / 1 skipped / 0 failed. test262-check: `0/49775 errors, passed 44581`. Historical row also named `architecture-check` and `config-drift-gate`; those steps are gone. |
| `zig build test -Doptimize=ReleaseSafe --summary all` | optimized-loop safety | 2026-08-17, branch `lane/prod-v0.1.0`: PASS. 9/9 steps succeeded. 2266 passed / 1 skipped / 0 failed. |
| `zig build test-oom --summary all` | corpus × allocation-failure injection plus same-runtime recovery canaries | instrumentation tier; runs nightly. 2026-08-19: PASS, 21 passed / 0 failed — after fixing two pre-existing defects this target had been silently failing on (it had not been run in a long time). |
| `zig build test -Dzjs_ownership_audit=true --summary all` | borrowed-atom use-after-free audit (see `docs/borrowed_atom_audit.md`) | instrumentation tier; runs nightly. 2026-08-19: PASS, 2275 passed / 0 failed. |
| `mise run checkpoint-gate` | unified Debug suite, Debug CLI smoke, source-side architecture | handoff gate; does not compile ReleaseFast `zjs` |
| `zig build test262-check --summary all` | full test262, zero-failure | runs on every PR (linux-arm64) |

Nightly note (2026-09-06): the GitHub `Nightly` workflow was red for
eleven consecutive nights (2026-08-26 → 2026-09-05; last green
2026-08-25). Every run built the stale `origin/main` (`6b9458ef`,
2026-09-01, and older): `engine-production-gate` passed 35/35 there, the
failing step was `zig build test -Doptimize=ReleaseSafe` on
`tests.oom_cap` "exhausted-heap OOM delivery to JS catch allocates
nothing", and fail-fast meant the OOM / leak-census / stress /
ownership-audit tiers did not run in CI for that period. The failure does
not reproduce on `ca537eca` (the row above); main was pushed 2026-09-06
and the next nightly is the confirmation.

Gate note (2026-08-20): `mise run checkpoint-gate` now also runs the
public-API surface snapshot. It previously fired only on the production gate,
and four commits landed past a stale `JSValue` pin before anyone noticed.

## Known defects

Recorded rather than fixed, with the reproduction that found them. Entries
that have since been fixed keep their attribution trail here until the next
release notes absorb them.

### Fixed 2026-09-06: Q21 — dense-array element cell traced only while `fast_array`

`Object.traceChildEdges` visited the `.array_storage` cell behind the array
arm only while `flags.fast_array` was set (or the owner was a mapped
arguments object). The flag is the dense-mode semantics bit; in the current
tree every clear goes through `freeArrayElementBufferAfterMove` (capacity
→ 0), so no production path reached the dangling state, but a transition
that left the buffer attached would have dropped the collector's only edge
to the cell. The edge is now derived from the arm itself
(`Object.denseArmNamesStorageCell`: class ∈ {array, mapped_arguments,
arguments without a class payload} and `capacity != 0`), shared by the
trace, the footprint recorder and the property-storage audit. The first
attempt's SIGSEGV on pdfjs was an `arguments` object whose arm word is a
class-payload pointer; the payload-kind term is the guard. Deletion probe:
"Q21: the element cell is kept alive by the arm, not by flags.fast_array"
(`src/tests/core.zig`), red on the old guard. Gates: unified suite and
gc-stress green; fixed-work PMU screen vs the pre-change binary
insn 0.9976–1.0003 on raytrace / splay / earley-boyer / deltablue / pdfjs (neutral). Priced entry: `docs/backlog.md` Q21 (closed).

### Closed 2026-09-06: Q22 — storage-cell corpse possibly debited twice

Not a defect. The per-corpse walk in `Registry.reclaimDoomedBlock`
(`unpublishStringCell → recordHeapFreeWithBytes`) clears the header's
accounting bit and feeds the test-build oracle and carrier lifecycle; it
never touches the `MemoryAccount` byte ledger. That ledger is debited once
per condemnation by `debitBlockBytes` with a snapshot that already excludes
finalizer-owing corpses, which are debited by their own destructor. An
invariant test now guards it: "Q22: a bitmap-reclaimed storage cell leaves
the byte ledger exactly once" (`src/tests/core.zig`), red when a second
debit is injected into the per-corpse path. Code-level trail:
`docs/backlog.md` Q22 (closed).

### Fixed 2026-08-22: frame teardown read its bytecode after releasing it

A returning frame decides whether to close open var refs by reading
`frame.function.openVarRefCount()`. All three simple-teardown arms in
`src/exec/inline_calls.zig` performed that read *after*
`frame.current_function.free(rt)`. When the frame's function object holds the
last reference to its `FunctionBytecode` — a dynamic `Function(...)` call is
the shape reachable from JavaScript — that release destroyed the bytecode the
next line reads.

Attribution (the earlier entry's generator diagnosis is retracted; the freed
object was the dynamic function's ordinary `anonymous` bytecode,
`isGenerator=false`, atom 815):

  * The historical abort is reproducible on `47cf81ef` by restoring the
    "collection constructors iterate their array argument" test to
    `sharedTestEngine()` and running `zig build test-builtins`. Allocation
    history, not generators, is what made it fault there.
  * Making `openVarRefCount` `noinline` in that checkout named the reader:
    `inline_calls.deinitOrdinarySimpleResources`, not any compile-time scan.
  * On the current tree the read still hit freed memory — it simply no longer
    faulted, because the allocation stayed mapped. A destroy witness compared
    against `frame.function` fired on
    `Function("var a = 2; var g = function () { return a; }; return g();")()`
    before the fix and is silent after it.

The fix moves the var-ref close above the `this_value` / `current_function`
releases in all three arms, which is also the order the adjacent QuickJS
reference comment describes. Regression test: "a dynamic function outlives its
teardown when its object held the last bytecode reference"
(`src/tests/exec.zig`). Gates: full suite 2332 passed / 1 skipped / 0 failed,
test262 `0/49778 errors, passed 44584` (delta 0), rule-2 bench-v8 A/B composite
0.9994 and 1.0004 across two samplings (RayTrace's first-run −1.88% converged
to −0.92%, i.e. dispersion, not a regression).

### Constraint 2026-08-23: extra `JSContext.destroy` undercounts live realm edges

`JSRuntime.deinit` asserts `context_head == null`, so every `JSContext` must
be destroyed before its runtime. The shared engine
(`src/tests/helpers.zig` `sharedTestEngine`) now does that at process exit:
restore the baseline, drop the snapshot's extra retains, destroy only the
host-owned main context, then `JSRuntime.destroy`. Leftover
`$262.createRealm()` cycles are collected there; the ~400 shared tests now
enter both the `context_head` and `allocation_count` asserts.

The historical abort when wiring that teardown was:

```
src/core/object_gc.zig  gcDecrefChildInline: assert(p.meta().rc > 0)
  <- visitRealm
  <- markUnusualPropertyCold <- markPropertyDataSlots
     (or markChildrenCold for C_FUNCTION / realm-record / bytecode edges)
```

That stack is not a missing sweep on the documented destroy path. Property-slot
realm pointers are `AutoInitSlot.realm_and_id` (`RealmAndAutoInitId.retain` =
`gc.retain` of the `JSContext` header; `visitRealm` during cycle mark;
`deinit` on slot destroy). `RealmValueSlot` is the per-context intrinsic
cache, not this edge. Sibling `visitRealm` owners (C_FUNCTION native
`RealmRef`, `FunctionBytecode.realm`, `$262.createRealm()` record payloads)
use the same RC.

`JSContext.destroy` is one `gc.release` of the host ref, matching QuickJS
`JS_FreeContext`. A slot that retained B therefore keeps B alive after the
host destroy; cycle GC's trial decref/restore matches the retain. JavaScript
has no realm-destroy.

Constructive reachability (embedding API, no shared engine):

  * Two `JSContext.create` realms, A's object holds B via an auto_init slot
    (`Object.defineFunctionPrototypeAutoInit`) or via a stolen
    `Array.prototype`: one `B.destroy()` leaves B live (`rc` is the remaining
    auto_init / native / bytecode retains). Cycle GC does not trip. Dropping
    the holder then collecting frees B.
  * Newest-first and oldest-first host destroy of those two contexts, then
    `JSRuntime.destroy`, both tear down. The earlier "order does not help"
    observation was from the extra-destroy recipe below, not from this path.
  * `$262.createRealm()` / `JSContext.createRealm` transfers the child's
    create ref onto the realm-record `RealmRef`. The public owner is that
    JSValue (free it), not a second `JSContext.destroy`. Leftovers on the
    parent global collect when the parent and runtime go down, without
    destroying the child context.

The abort is an extra `gc.release`: looking up the child with
`contextForGlobal` (or walking `context_head`) and calling
`JSContext.destroy` while auto_init / native / bytecode edges still point at
it. That undercounts remaining `visitRealm` edges by one, so cycle mark hits
`rc == 0` on a later slot. The same shape is `destroy()` twice on a
`JSContext.create` realm. It is not a shape the documented embedding API
produces, and it is not reachable from JS.

Shared-tier teardown is armed on that recipe (atexit from the first
`sharedTestEngine()`). Walking leftover children and `destroy()`ing them is
the undercount and is not the gate.

Debug/ReleaseSafe `JSContext.destroy` / `tryDestroy` and `RealmRef.takeOwned`
consume the host API release exactly once (`host_api_release_consumed`). A
second host `destroy` on a still-allocated realm panics at the call instead
of later in cycle mark. `RealmRef.retain`/`deinit` remains the extra-host-ref
pair and does not consume that flag. The field is present in ReleaseFast for
layout identity; the assert is `std.debug.assert`.

Host-ref ownership is documented in `docs/public-api-contract.md`.

Regression tests: "auto_init slot to another realm retains it across
`JSContext.destroy` and cycle GC" (`src/tests/core.zig`); embedding
cross-realm `Array.prototype` keep-alive, newest-first / oldest-first
teardown, and createRealm leftover without child `JSContext.destroy`
(`src/tests/embedding_examples.zig`).

## Reproduction Commands

```sh
zig build zjs --summary all
zig build test --summary all
zig build engine-production-gate --summary all
zig build test262-check --summary all
```

Direct test262 runner (after `zig build run-test262 --summary all`):

```sh
./zig-out/bin/run-test262 -t 8 -c test262.conf -d test262/test 0 100000
```

## CI

[![CI](https://github.com/aneryu/zjs/actions/workflows/ci.yml/badge.svg)](https://github.com/aneryu/zjs/actions/workflows/ci.yml)

All lanes (Linux arm64, Linux x86-64, macOS, Windows) are required; none is
marked advisory (`continue-on-error`) in `.github/workflows/ci.yml`.

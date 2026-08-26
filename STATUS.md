# STATUS

This page is the single authoritative status source for `zjs`.
README carries condensed copies of the headline tables; when they disagree,
this page and the documents it names win.

## test262

Checked report date: 2026-08-22 (full-suite run recorded under Known defects
below; `COMPATIBILITY.md` carries the same numbers).

- 49,778 prepared / 44,584 pass / 0 checked-in known failures / 0 unexpected failures / 5,194 feature skips
- Configuration = repository `test262.conf` + submodule pin `4249661388e5d3f92a85186213da140a6481490f`

See `COMPATIBILITY.md` and `test262.conf` for the active validation boundary.
Configured skip classes include Intl, Temporal, ShadowRealm, decorators,
source-phase imports, and PTC.

## Performance

The authoritative score source is `docs/perf/bench-v8-status.md`; this page
does not maintain its own copy of the numbers. Since 2026-08-25 the vendored
suite (`tools/perf/bench_v8/`) is Octane 2.0 (V8 suite version 9); the
current five-engine snapshot there reads zjs/qjs composite 0.9611 against a
GCC 16.0.1 reference build. Per the 2026-08-25 reference-drift adjudication,
every published record must carry the reference binary's fingerprint
(hash + compiler); ratios are not comparable across suite versions or
reference binaries, and which build is the official yardstick is an open
owner decision.

The 15-benchmark zoo suite stays as a standalone-file attribution
instrument (usage: `tools/perf/zoo/README.md`). Its last baseline (geomean
1.0304, v7 suite / GCC-13 reference) was removed from the active tree with
the 2026-08-25 stale-doc cleanup; recover it from git history. The
superseded version-7 headline records (2026-08-19 composite 1.0464) were
removed the same way.

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
results. The most recent full-suite evidence is 2026-08-22: full suite 2332
passed / 1 skipped / 0 failed, test262 `0/49778 errors, passed 44584` (see
the frame-teardown entry under Known defects).

| Gate | What it covers | This lane |
|------|----------------|-----------|
| `zig build engine-production-gate --summary all` | unified Debug suite, ReleaseFast CLI smoke, architecture lints (including compiler-stage `nm`), OOM-cap, full test262 | 2026-08-17, branch `lane/prod-v0.1.0`: PASS. 35/35 steps succeeded. unified-tests: 2266 passed / 1 skipped / 0 failed. test262-check: `0/49775 errors, passed 44581`. Historical row also named `architecture-check` and `config-drift-gate`; those steps are gone. |
| `zig build test -Doptimize=ReleaseSafe --summary all` | optimized-loop safety | 2026-08-17, branch `lane/prod-v0.1.0`: PASS. 9/9 steps succeeded. 2266 passed / 1 skipped / 0 failed. |
| `zig build test-oom --summary all` | corpus × allocation-failure injection plus same-runtime recovery canaries | instrumentation tier; runs nightly. 2026-08-19: PASS, 21 passed / 0 failed — after fixing two pre-existing defects this target had been silently failing on (it had not been run in a long time). |
| `zig build test -Dzjs_ownership_audit=true --summary all` | borrowed-atom use-after-free audit (see `docs/borrowed_atom_audit.md`) | instrumentation tier; runs nightly. 2026-08-19: PASS, 2275 passed / 0 failed. |
| `mise run checkpoint-gate` | unified Debug suite, Debug CLI smoke, source-side architecture | handoff gate; does not compile ReleaseFast `zjs` |
| `zig build test262-check --summary all` | full test262, zero-failure | runs on every PR (linux-arm64) |

Gate note (2026-08-20): `mise run checkpoint-gate` now also runs the
public-API surface snapshot. It previously fired only on the production gate,
and four commits landed past a stale `JSValue` pin before anyone noticed.

## Known defects

Recorded rather than fixed, with the reproduction that found them. Entries
that have since been fixed keep their attribution trail here until the next
release notes absorb them.

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

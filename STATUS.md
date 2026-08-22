# STATUS

This page is the single authoritative status source for `zjs`.
README keeps only a pointer here.

## test262

Checked report date: 2026-08-05 (source: `COMPATIBILITY.md`).

- 49,778 prepared / 44,584 pass / 0 checked-in known failures / 0 unexpected failures / 5,194 feature skips
- Configuration = repository `test262.conf` + submodule pin `4249661388e5d3f92a85186213da140a6481490f`

See `COMPATIBILITY.md` and `test262.conf` for the active validation boundary.
Configured skip classes include Intl, Temporal, ShadowRealm, decorators,
source-phase imports, and PTC.

## Performance

The authoritative score source is `docs/perf/bench-v8-status.md` (the V8
benchmark suite v7 — the suite upstream QuickJS publishes with, vendored in
`tools/perf/bench_v8/`); this page does not maintain its own copy of the
numbers.

Current headline (2026-08-19, `main@da875a7d`, serial pinned 8-sample
ABBA protocol): composite Score ratio **1.0464** (zjs 2706 / qjs 2586),
7/8 benchmarks at or above 1.0. The remaining laggard is EarleyBoyer
(0.879). The 15-benchmark zoo suite stays as an internal diagnostic
(`docs/perf/zoo-status.md`, last baseline geomean 1.0304).

This is a maintainer single-machine measurement; there is no independent
reproduction yet.

- Machine: ARM Cortex-X925 (3.9 GHz big cores, pinned), Linux 6.17.
- QuickJS reference pin: commit `04be246`, upstream Makefile default release
  build (GCC 13.3.0, aarch64).
- Campaign ledgers and attribution reports were moved out of the active tree;
  recover them from tag `v0.1.0` (`reports/perf/qjs-align/`) or git history.
  Raw sample files were deleted during campaign close; re-measurement must
  re-run the measurement contract.

Measurement contract: `tools/compare/measurement_contract.js` with
`tools/compare/measurement_policy.json`; the prose incident register
(16 clauses) is preserved at tag `v0.1.0` under
`reports/perf/qjs-align/measurement-contracts.md`.

## Gates

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

### Destroying a realm can decref an already-dead JSContext

`JSRuntime.deinit` asserts `context_head == null`, so every `JSContext` must
be destroyed before its runtime. The test suite's process-lifetime shared
engine (`src/tests/helpers.zig` `sharedTestEngine`) never is — which also
means ~400 tests sit outside that assert entirely, and outside the
`allocation_count` one beside it.

Wiring a teardown for it (destroy the extra realms `$262.createRealm()` left
behind, then the engine) trips a deeper assert:

```
src/core/object.zig:7624  gcDecrefChildInline: assert(p.meta().rc > 0)
  <- src/core/object.zig:7693  visitRealm: self.mark_func(self.rt, &ctx.header)
  <- markUnusualPropertyCold <- markPropertyDataSlots
```

An object in one realm holds a realm reference to a `JSContext` that has
already been destroyed: destroying a context does not clear or decref the
realm references other realms' property slots hold into it. Destruction order
does not help — newest-first and oldest-first fail identically.

Scope not established: reachable from the embedding API (`JSContext.destroy`
is public) but not demonstrated there, and not reachable from JS, which has no
realm-destroy. Two separable pieces of work: the engine-side realm-reference
teardown, and then arming the shared tier's leak gate on top of it.

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

x86-64 and macOS lanes start as advisory; they become required once green.

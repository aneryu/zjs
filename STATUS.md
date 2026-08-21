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

Recorded rather than fixed, with the reproduction that found them.

### A generator bound to a `const` on the shared test engine outlives its bytecode

Minimal reproduction — add this test to any file that uses the shared engine,
then run the whole target:

```zig
const js = helpers.sharedTestEngine();
defer helpers.endSharedTest();
_ = try js.evalWithOutput(
    \\const gen = function* () { yield 1; };
    \\print(JSON.stringify([...gen()]));
, &stream);
```

The test itself passes. A LATER test in the same run then dies:

```
Segmentation fault
  src/bytecode.zig:2134  openVarRefCount: return self.var_ref_count;
  <- tailcall_dispatch.runDispatchLoop <- zjs_vm.runTC
```

Narrowed by substitution, one variable at a time:

  * a plain function returning an iterator object in place of the generator —
    passes. It is specific to generator bytecode.
  * `new Set(iterable)` in place of the spread — same crash, so the collection
    constructors are not involved; any drain of the generator does it.
  * the same script through the CLI on a fresh runtime — no crash. It needs
    `endSharedTest`, which frees the lexical environment (`ctx.lexicals = null`
    then `env.value().free(rt)`) that the `const` binding lived in.

So something still references the generator's `FunctionBytecode` after that
environment is freed, and the next test's dispatch loop reads it. Pre-existing:
reproduced on an unmodified engine with `git stash`. The suite has not been
hitting it because its generator tests either use dedicated engines or
`function*` declarations rather than a `const` binding on the shared engine.

Related: the shared tier is also outside the allocator leak check and outside
`JSRuntime.deinit`'s asserts — see the realm-teardown entry below.

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

# STATUS

This page is the single authoritative status source for `zjs`.
README keeps only a pointer here.

## test262

Checked report date: 2026-08-05 (source: `COMPATIBILITY.md`).

- 49,775 prepared / 44,581 pass / 0 checked-in known failures / 0 unexpected failures / 5,194 feature skips
- Configuration = repository `test262.conf` + submodule pin `4249661388e5d3f92a85186213da140a6481490f`

See `COMPATIBILITY.md` and `test262.conf` for the active validation boundary.
Configured skip classes include Intl, Temporal, ShadowRealm, decorators,
source-phase imports, and PTC.

## Performance

The authoritative score source is `docs/perf/zoo-status.md`; this page does
not maintain its own copy of the zoo numbers.

Current headline (zoo-status 2026-08-19 clean-field close, `main@0c32a71c`,
official 8-sample parallel-cluster protocol): geomean **1.0304**, 11/15
benchmarks at or above 1.0. The remaining laggards are listed in zoo-status
(pdfjs / earley-boyer / box2d / typescript).

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
| `zig build test-oom --summary all` | corpus × allocation-failure injection plus same-runtime recovery canaries | phase-close tier; not re-run in this packaging lane |
| `zig build test-altrepr --summary all` | nan-boxing representation guard | **Known pre-existing failure** (reproduced on main 2026-08-18, unrelated to the maintainability campaign): `tests.exec.test.Engine direct eval shares top-level lexical cells across nested closures` SIGABRTs under nan_boxed (`bytecode.openVarRefCount` / `tailcall_dispatch.run`). Tracked for an independent fix. |
| `mise run checkpoint-gate` | unified Debug suite, Debug CLI smoke, source-side architecture | handoff gate; does not compile ReleaseFast `zjs` |
| `zig build perf-self-check --summary all` | ZJS self-baseline | run by the maintainer on the measurement machine at release time |

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

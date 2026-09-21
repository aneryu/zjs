# Testing Graph

How compile roots and validation steps fit together. The executable build
graph in `build/` is the authority; this document describes the conventions
that graph encodes.

## Compile-root chain

One engine root:

| Root | Role |
|---|---|
| `src/root.zig` | Engine module imported as `zjs`. Embedder names plus layer re-exports for CLI and in-tree tests. |
| `test_root.zig` | Unified engine Zig-test root. Re-exports `src/root.zig` so one module can see `src/` unit tests and `tests/` integration tests. |
| `src/cli/tests.zig` | CLI test root. Pulls colocated tests in `zjs.zig` / `run_test262.zig`; `@import("zjs")` is `src/root.zig`. |

The production `zjs` / `run-test262` artifacts compile against
`src/root.zig`. The engine `test` binary uses `test_root.zig` as its
`root_source_file` and `@import("zjs")` is that module (it re-exports
`src/root.zig`).
CLI tests are a separate compile so engine files never import that tree.
`test-embedding` compiles the same `src/root.zig` module as `zjs`.

Zig unit tests live next to the code they exercise: colocated `test`
blocks plus package `tests.zig` files. `test_root.zig` file-imports
those package suites and `tests/engine.zig` (public API, runtime/GC,
VM/eval) when `build_options.zjs_unified_test_suite` is set.
`test-embedding` / `test-oom` leave that flag off, so those files are
not analyzed. Parser and bytecode package roots also comptime-import
their `tests.zig` for the same flag.

## Remaining test roots

The engine suite (`test_root.zig`) is the only engine-bearing compile for
package Zig unit tests and `tests/` integration tests. Focused work uses `test-fast -- '<substring>'`
(compile-time `--test-filter` on that root). Do not add a second compile
root per engine subsystem. Host families (CLI, embedding, OOM)
are separate compiles, the same shape as `test-embedding`.
The CLI root file-imports `run_test262_host.zig` so its four colocated
host tests are collected; importing it only as a dependency module does
not collect those tests.

Two more artifacts compile a different test file against the same engine:

- `test-embedding` / `check-embedding`: `src/root.zig` as `zjs`, tests in
  `tests/embedding_examples.zig`. Does not attest.
- `test-oom`: `tests/oom.zig` over `src/root.zig` with the injectable
  allocator topology.

### Independent options (rule C)

Every engine-bearing module gets its own `addOptions` object when the
generated file would otherwise be shared as two module roots. One `zig build`
is one `-Doptimize`; do not pin a second mode inside the graph.

### `tests/harness.zig`

Integration-test harness (`helpers.*` names), not an engine package.
`tests/core.zig` and `tests/exec.zig` import it. The work lives under
`tests/harness/`:

| File | Owns |
|---|---|
| `gc.zig` | precise reclaim, weak collections, incremental GC drain |
| `expect.zig` | string / set assertions |
| `fixture.zig` | hand-written bytecode and parse-then-run |
| `test_engine.zig` | one-off `TestEngine`, host probes, scratch dirs |
| `shared.zig` | process-level shared engine and leak gate |

Package unit tests (`src/parser/tests.zig`, `src/bytecode/tests.zig`)
only reclaim with a local `runObjectCycleRemoval` helper. They do not
import this package. The engine module does not export it.

## Attest matrix

| Artifact | How it attests | Notes |
|---|---|---|
| `zjs` / `zjs-profile` / `zjs-size` | `src/cli/zjs.zig` | Follow `-Doptimize` |
| `run-test262` | `src/cli/run_test262.zig` | Follow `-Doptimize` |
| engine `test` | `test_root.zig` plus `src/cli/tests.zig` | Follows `-Doptimize`; two processes; optional `-Dgate-run-cpus` pin on the engine run |
| `test-fast -- <substring>` | engine root, compile-time `--test-filter` | Missing, empty, or unmatched selection fails. Keeps DWARF. Engine suite only. |
| `test-embedding` | public `src/root.zig` | |
| `test-oom` | `tests/oom.zig` attests `"oom-tests"` | |
| `test-leak-census` | same root, `tools/leak_census_runner.zig` | Compile-time filter `tests.exec.`; two in-process passes |

## Filter naming

Area selection is a compile-time `--test-filter` on the unified root.
Zig ORs multiple filters.

| Target | How it selects |
|---|---|
| `test-fast -- '<substring>'` | `--test-filter <substring>` plus `zjs.pull_test_modules` on the engine root. Integration prefixes are `tests.public_api.`, `tests.core.`, `tests.exec.` |
| `test` | engine suite plus CLI tests |
| `test-gc-stress` | engine suite under GC diagnostic env |
| `test-leak-census` | `--test-filter tests.exec.`; runner repeats twice with `ZJS_LEAK_CENSUS=1` |
| `test-embedding` / `check-embedding` | public-root compile of `tests/embedding_examples.zig`; no name filter |

`test-embedding` uses an independent `zjs` module rooted at
`src/root.zig` (same `-Doptimize` as the rest of the graph) and hangs on
`engine-production-gate`. checkpoint-gate takes the sema-only twin
`check-embedding` so it does not pay a second engine compile + link.

## Step naming

| Suffix | Meaning | Examples |
|---|---|---|
| `-gate` | Aggregate validation gate | `quick-gate`, `checkpoint-gate`, `engine-production-gate` |
| `-check` | Single check | `test262-check` |
| (none) | Build or run | `zjs`, `test`, `smoke`, `test-fast` |

`check` (no suffix, no prefix) is the one exception, and it is deliberate:
it is the name the Zig ecosystem and editor tooling already look for.

## `zig build check`: the compile-error half of the edit loop

`check` compiles the engine and CLI test roots and stops after semantic analysis.
Nothing consumes its binary, so the build system passes `-fno-emit-bin`:
no LLVM module, no machine code, no link, no test executed.

It exists because a little over half of a Debug test compile on this tree is
codegen plus the link of a 245 MB object file, and that half is pure waste
when the answer is "your edit does not compile": 55 s instead of 113 s, and
instead of 176 s once the 63 s test run it never reaches is counted. It also
peaks at 1.4 GB instead of 8.25 GB, which is what decides whether several
agents can build on one machine at once.

What `check` still proves: every comptime assertion the tree owns.
The opcode declaration ledger and the FNABI `@cImport` round-trip are
semantic analysis, so they all fire.

What it does not prove: anything a machine-code backend decides
(`@call(.always_tail)` lowering, the `.space` tombstones) and any behaviour
whatsoever. **`check` is not a gate and no gate depends on it.**
`zig build test` remains the checkpoint dependency.

## Optional Run-step pinning

The graph's Run steps -- unified tests, gc-stress, test262 -- are
unpinned by default. Linux-only
`taskset` pinning is opt-in: `-Dgate-run-cpus`, else `ZJS_GATE_RUN_CPUS`,
else `ZJS_BUILD_CPUS`. An empty string leaves them on whatever `zig build`
got.

Two build-runner facts decide the shape of a gate (2026-09-06):

- The runner's worker pool is `cpu_count - 1` threads and a step dispatched
  past it runs inline on the main thread, which is still dispatching the
  initial steps. Gates therefore go through mise, which passes `-j32`.
- A Run step with inherited stdio holds the runner's stderr lock for its
  whole duration. test262 runs in `.check` mode
  (`expectStdOutMatch` on their summary line; a red run prints the whole
  log) so it does not serialise other steps.

The edit loop: `zig build check` (~7 s, sema only) rejects a non-compiling
edit. `zig build test` then runs the engine suite and the CLI tests.
LLVM Debug codegen + link is the compile floor.

## What CI runs

The build graph is the same everywhere; CI only decides which steps a machine
runs unprompted.

| Workflow | Primary job | Steps it runs |
|---|---|---|
| `ci.yml` (push to `main`, pull requests) | `linux-arm64` | ReleaseFast `zjs`, Debug `checkpoint-gate`, ReleaseFast `test262-check` |
| `nightly.yml` (scheduled) | `linux-arm64` | `engine-production-gate -Doptimize=ReleaseFast`, `test -Doptimize=ReleaseSafe`, `test-oom`, `test-leak-census`, and `test -Dzjs_ownership_audit=true` |

`test262-check` is a zero-failure gate — any failed or newly-fixed case fails
the step — which makes it the sharpest semantic-regression signal available. It
runs on the primary development platform only: results are
architecture-independent, so a second copy would buy noise.

The nightly instrumentation tiers used to depend on a developer remembering to
run them when they touched the matching subsystem. A machine runs them now, and
a `notify-failure` job opens (or comments on) one long-lived GitHub issue when
any nightly job fails.

`-Dzjs_force_gc` is not on either list. It is a diagnostic instrument, in the
same tier as a host `perf stat` session: run it when a GC-shaped question needs it, not
as a gate.

Performance steps never run in CI; the measurement contract forbids publishing
performance numbers from shared runners.

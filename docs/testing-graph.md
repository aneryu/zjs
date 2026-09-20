# Testing Graph

How compile roots and validation steps fit together. The executable build
graph in `build/` is the authority; this document describes the conventions
that graph encodes.

## Compile-root chain

Two roots:

| Root | Role |
|---|---|
| `src/root.zig` | Public embedder facade. |
| `src/internal_root.zig` | Engine + CLI surface. Adds core `Object`, `Descriptor`, `Atom`. Also the unified Zig test root. |

The production `zjs` / `run-test262` artifacts compile against
`internal_root`. The unified `test` step uses the same file as its
`root_source_file`; `@import("zjs")` in that binary is `internal_root`
itself. `test-embedding` is the one artifact that compiles the public
`src/root.zig` module as `zjs`.

Zig unit tests live next to the code they exercise: each package root
comptime-imports `tests.zig` when `build_options.zjs_unified_test_suite`
is set (the unified `test` module), plus colocated `test` blocks and
`src/compiler/tests.zig`. `test-embedding` / `test-oom` leave that flag
off, so those package test files are not analyzed.

## Remaining test roots

The unified suite (`src/internal_root.zig`) is the only engine-bearing
compile for Zig unit tests. Focused work uses `test-fast -- '<substring>'`
(compile-time `--test-filter` on that root). Do not add a second compile
root per subsystem.

Two artifacts still compile a different root:

- `test-embedding` / `check-embedding`: public `src/root.zig` as `zjs`,
  tests in `tests/embedding_examples.zig`. Does not attest.
- `test-oom`: `tests/oom.zig` over `internal_root` with the injectable
  allocator topology.

### Independent options (rule C)

Every engine-bearing module gets its own `addOptions` object when the
generated file would otherwise be shared as two module roots. One `zig build`
is one `-Doptimize`; do not pin a second mode inside the graph.

### `src/testing.zig`

Shared harness (`helpers.*` names). Relative engine imports so package
`tests.zig` files can use it. In-tree tests may import it; they share that
one module.

## Attest matrix

| Artifact | How it attests | Notes |
|---|---|---|
| `zjs` / `zjs-profile` / `zjs-size` | `src/cli/zjs.zig` | Follow `-Doptimize` |
| `run-test262` | `src/cli/run_test262.zig` | Follow `-Doptimize` |
| unified `test` | `src/internal_root.zig` | Follows `-Doptimize`; Zig default runner, one process; optional `-Dgate-run-cpus` pin |
| `test-fast -- <substring>` | same root, compile-time `--test-filter` | Missing, empty, or unmatched selection fails. Keeps DWARF. |
| `test-embedding` | public `src/root.zig` | |
| `test-oom` | `tests/oom.zig` attests `"oom-tests"` | |
| `test-leak-census` | same root, `tools/leak_census_runner.zig` | Compile-time filter `exec.tests.`; two in-process passes |

## Filter naming

Area selection is a compile-time `--test-filter` on the unified root.
Zig ORs multiple filters.

| Target | How it selects |
|---|---|
| `test-fast -- '<substring>'` | `--test-filter <substring>` plus `zjs.pull_test_modules` |
| `test-stress` | `--test-filter stress.` and `ZJS_RUN_STRESS=1` |
| `test` / `test-gc-stress` | full suite; `src/stress.zig` cases `SkipZigTest` unless `ZJS_RUN_STRESS=1` |
| `test-leak-census` | `--test-filter exec.tests.`; runner repeats twice with `ZJS_LEAK_CENSUS=1` |
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

`check` compiles the unified test root and stops after semantic analysis.
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

The graph's Run steps -- unified tests, gc-stress, the stress tier,
test262 -- are unpinned by default. Linux-only
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
edit. `zig build test` then runs the unified suite in one process with
Zig's default runner. LLVM Debug codegen + link is the compile floor.

## What CI runs

The build graph is the same everywhere; CI only decides which steps a machine
runs unprompted.

| Workflow | Primary job | Steps it runs |
|---|---|---|
| `ci.yml` (push to `main`, pull requests) | `linux-arm64` | ReleaseFast `zjs`, Debug `checkpoint-gate` / `test-stress`, ReleaseFast `test262-check` |
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
same tier as `perf-benchmark`: run it when a GC-shaped question needs it, not
as a gate.

Performance steps never run in CI; the measurement contract forbids publishing
performance numbers from shared runners.

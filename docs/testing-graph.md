# Testing Graph

How compile roots and validation steps fit together. The executable build
graph in `build/` is the authority; this document describes the conventions
that graph encodes.

## Compile-root chain

Three roots, each a superset of the one above it:

| Root | Role |
|---|---|
| `src/root.zig` | Public embedder facade. |
| `src/internal_root.zig` | Engine + CLI surface. Adds core `Object`, `Descriptor`, `Atom`. |
| `src/all_tests.zig` | Unified suite. Re-exports every `internal_root` name and overlays public-surface mirrors. |

`all_tests` asserts at runtime that every public declaration on
`internal_root` is reachable on `all_tests` and identical, except for an
explicit exception table. The only exception today is `Object`: the public
type is an opaque facade, the internal type has `create`.

The production `zjs` / `run-test262` artifacts compile against
`internal_root`. The unified `test` step compiles against `all_tests`.
`test-embedding` is the one artifact that compiles the public `src/root.zig`
module as `zjs`.

## Remaining test roots

The unified suite (`src/all_tests.zig`) is the only engine-bearing compile
for Zig unit tests. Focused work uses `test-fast -- '<substring>'` on that
binary. Do not add a second compile root per subsystem.

Two artifacts still compile a different root:

- `test-embedding` / `check-embedding`: public `src/root.zig` as `zjs`,
  tests in `src/tests/embedding_examples.zig`. Does not attest.
- `test-oom`: `src/tests/oom.zig` over `internal_root` with the injectable
  allocator topology.

### Independent options (rule C)

Every engine-bearing module gets its own `addOptions` object when the
generated file would otherwise be shared as two module roots. One `zig build`
is one `-Doptimize`; do not pin a second mode inside the graph.

### `helpers.zig` (rule D)

`src/tests/helpers.zig` `@import("zjs")` internally. `compiler/tests.zig`
and in-tree runtime tests must never import it: they are pulled into
`all_tests` by `refAllDecls` and would then exist in two modules.

## Attest matrix

| Artifact | How it attests | Notes |
|---|---|---|
| `zjs` / `zjs-profile` / `zjs-size` | `src/cli/zjs.zig` | Follow `-Doptimize` |
| `run-test262` | `src/cli/run_test262.zig` | Follow `-Doptimize` |
| unified `test` | `src/all_tests.zig` | Follows `-Doptimize`; one compile, `-Dtest-shards` (default 16) parallel `--shard i/N` run processes with captured stderr; optional `-Dgate-run-cpus` pin |
| `test-fast -- <substring>` | same unified binary | One runtime-filtered process; missing, empty, unmatched, or list-only selection fails. Changing the substring does not change the compile artifact. |
| `test-embedding` | public `src/root.zig` | |
| `test-oom` | `src/tests/oom.zig` attests `"oom-tests"` | |
| `test-leak-census` | same unified binary | Runtime `--repeat 2 --leak-census` plus `--filter tests.exec.` / `tests.builtins.` |

## Filter naming

Area selection is a runtime filter on the unified binary. Multiple
`--filter` arguments are OR-matched.

| Target | How it selects |
|---|---|
| `test-fast -- '<substring>'` | `--filter <substring>` |
| `test-stress` | `--only-prefix tests.stress.` |
| `test` / `test-gc-stress` shards | `--skip-prefix tests.stress.` |
| `test-leak-census` | `--filter tests.exec.` `--filter tests.builtins.` plus `--repeat 2 --leak-census` |
| `test-embedding` / `check-embedding` | public-root compile of `src/tests/embedding_examples.zig`; no name filter |

`test-embedding` uses an independent `zjs` module rooted at
`src/root.zig` (same `-Doptimize` as the rest of the graph) and hangs on
`engine-production-gate`; checkpoint-gate takes its sema-only twin
`check-embedding` because the same test bodies, runtime pins included,
already run in the unified suite.

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

The graph's Run steps -- the unified shards, gc-stress, the stress tier,
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
  log) and the shards capture stderr, so none of them serialise.

The edit loop: `zig build check` (~7 s, sema only) rejects a non-compiling
edit; an incremental `zig build test` after an engine edit is ~11 s (cold
~21 s: the difference is sema; the LLVM Debug codegen + link is the floor
either way).

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

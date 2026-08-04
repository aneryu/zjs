# `tools/final-switch/` — the compiler-switch orchestration

Gate A (the QCP-1 compiler switch to V2 + `.short`) was run from scratch shell
scripts in a job temp directory. They worked, and then they would have been
thrown away. This directory is that orchestration promoted to a maintained set,
with the defects that were found the hard way fixed in the committed version
rather than carried forward as folklore.

| script | lane | needs both compilers? |
| --- | --- | --- |
| `preflight.sh` | host + toolchain checks, shared helpers, the standing rules (sourced by all others) | no |
| `selftest.sh` | **fault-inject every standing rule** — `zig build final-switch-selftest` | no |
| `build_artifacts.sh` | two cold builds per side, manifest with sha256 + signature | yes (`--no-legacy` after deletion) |
| `correctness_default.sh` | correctness on **true production defaults** | no |
| `correctness_variants.sh` | altrepr, OOM, force-GC, ownership-audit, ReleaseSafe, `.plain` | no |
| `migration_gates.sh` | dual comparator (Zig corpus + full test262), L3 emission | **yes — delete with the legacy path** |
| `performance.sh` | zoo × 4 + codeload micro × 4, then the join | yes |
| `join_results.py` | arbitrate: all four pairings, gates, noise floors | no |
| `l3_workload.js` / `.ts` | real source for the L3 emission collect | no |

Suggested order on a single host, never overlapping:

```bash
tools/final-switch/selftest.sh        # seconds; run it first, every time
tools/final-switch/preflight.sh
tools/final-switch/build_artifacts.sh
tools/final-switch/correctness_default.sh
tools/final-switch/correctness_variants.sh
tools/final-switch/migration_gates.sh
tools/final-switch/performance.sh     # quiet host: nothing else may run
```

`performance.sh` must run **alone**. The correctness lanes may not overlap it,
not even pinned to other cores.

## The five standing rules

Each of these is a **regression test, not a style preference**: each one names a
process defect that produced a wrong or vacuous result on a real Gate A run.
Each is enforced by machine, and `selftest.sh` reintroduces each defect on every
run and requires the rule to catch it — a rule that has only ever been observed
passing is a comment.

| rule | enforced by | proven by |
| --- | --- | --- |
| **A · AFFINITY** — the orchestrator SETS `taskset -c $FS_CPU` and verifies the pin INDEPENDENTLY; a runner's self-report is corroborated, never trusted alone | `fs_pinned()`, `fs_verify_affinity()`, `join_results.py` | `selftest.sh` A1–A8 |
| **B · TS PROBES** — a TypeScript probe routes through `parseAndCompileV2TestProgram()`, never `zjs -e '<ts source>'` | ban scan over `tools/` + `docs/`; a named test in `src/compiler_v2/tests.zig` | `selftest.sh` B1–B4 |
| **C · L3 COLLECT** — `v2_construct_emitted > 0` is asserted BEFORE `legacy_in_v2_unallowed == 0` is believed | `fs_l3_verdict()`, called by `migration_gates.sh` | `selftest.sh` C1–C5 |
| **D · CORPUS SKIPS** — the actual skipped set is compared against an EXPLICIT per-case allowlist, by identity, both ways. No proportional tolerance in any form | `expectCoverageSkipSetMatches()` in `src/compiler_v2/tests.zig` | `selftest.sh` D1–D4 + a Zig self-test |
| **E · STRICT SHELL** — scripts are shellcheck-clean and ABORT LOUDLY rather than silently emitting nothing | `fs_strict()` / `fs_finish()` + the abort banner | `selftest.sh` E1–E6 |

```bash
zig build final-switch-selftest       # or: tools/final-switch/selftest.sh
```

### A · The zoo runner attests affinity; it does not set it

`tools/perf/zoo/run_zoo_compare.py` verifies `os.sched_getaffinity(0) == {--cpu}`
and refuses otherwise — the caller must supply `taskset -c 19`. The first Gate A
performance attempt omitted it and the runner refused all three invocations
(`rc=2`). That was fail-closed behaviour working correctly, but only because
the runner happened to check; the orchestrator should never have been able to
request an unpinned measurement at all. So:

* `fs_pinned()` in `preflight.sh` is the only sanctioned way to invoke an
  affinity-attesting runner, and it always supplies `taskset -c $FS_CPU`.
  `selftest.sh` A1 refuses any other script in this directory that spells
  `taskset`, and A2 refuses any invocation of an affinity-attesting runner —
  the list is *derived* by grepping `tools/perf` for `sched_getaffinity`, so a
  new attesting runner is covered the day it lands — that is not `fs_pinned`;
* `fs_pinned()` then **verifies the pin from inside the pinned process tree**,
  reading `/proc/self/status` immediately before `exec`ing the runner. That is
  a different process and a different mechanism from the runner's own
  `os.sched_getaffinity`, so agreement between the two is corroboration rather
  than one source attesting itself twice. Observations are appended to
  `$FS_AFFINITY_ATTEST`;
* `fs_preflight_measure()` proves the pin takes effect *before* a long run
  starts, instead of discovering it at the end;
* `performance.sh` reports `rc=2` as a hard failure and additionally fails when
  a run leaves no artifact, so a refusal cannot become a silent hole;
* `join_results.py` **requires** the orchestrator's ledger, refuses any artifact
  whose `effectiveAffinity != [cpu]`, refuses a runner self-report the ledger
  does not corroborate, and refuses to join a **missing** artifact at all — a
  run that did not happen must never be averaged in as a smaller sample.

### B · A TypeScript probe cannot be `zjs -e`

The CLI's `-e` path has no TypeScript handling: there is no filename for the
source-kind autodetect to work from, and no flag to force it. So

```
$ zjs -e '<ts source>'
SyntaxError: UnexpectedToken
```

for **every** construct — `enum`, `interface`, `namespace`, a plain type
annotation, all of them — which is indistinguishable from an engine failure and
reads as a finding. A TypeScript probe must instead route through
`parseAndCompileV2TestProgram()` with `.source_kind = .typescript`, which is what
the coverage corpus and the named RULE B test in `src/compiler_v2/tests.zig` do.
The `.ts` **file** route works too (the engine strips by path), which is why
`l3_workload.ts` is a file.

`selftest.sh` bans the `-e` formulation statically over `tools/` and `docs/`
(a plain recursive grep, not `git grep`: an untracked scratch script is exactly
where this gets written), and grounds the ban dynamically — B2 requires the
`-e` form to still report `SyntaxError`, and B4 requires the same construct to
compile when the source kind is known, so the failure is demonstrably a property
of the probe and not of the construct.

### C · The L3 emission collect must run over a real workload

The first attempt invoked the binary with `--print-config-signature`, which
compiles nothing. It reported

```
QCP-1 L3 emission coverage: v2_construct_emitted=0 legacy_construct_emitted=0 \
  legacy_in_v2_scope=0 legacy_in_v2_unallowed=0 sites_dropped=0
```

— a vacuous zero that reads exactly like a pass. `legacy_in_v2_unallowed == 0`
is a claim about constructs that were emitted; over zero emitted constructs it
is not a weak pass, it is not a measurement. `migration_gates.sh` runs the
collector over `l3_workload.js` and `l3_workload.ts` and **asserts
`v2_construct_emitted > 0` before believing `legacy_in_v2_unallowed == 0`**; an
emitted count of zero is reported as `VACUOUS`, not as a pass. The assertion is
`fs_l3_verdict()` in `preflight.sh` — one implementation, shared by the gate and
by `selftest.sh`, which feeds it the **verbatim** historical vacuous line on
every run and requires the verdict `VACUOUS`.

### D · The corpus skip set is an allowlist, not a tolerance

`src/compiler_v2/tests.zig` asserted `skipped * 2 <= cases.len` — up to **half**
the coverage corpus could stop covering anything while the test stayed green.
A proportional tolerance is not acceptable in any form, so there is now an
explicit per-case allowlist compared **by identity, in both directions**:

* a snippet that fails to compile and is not allowlisted fails the test, naming
  the index and the source;
* an allowlisted snippet that starts compiling also fails, as a stale entry;
* `.expect_skip = true` requires a `.skip_reason`, enforced at `comptime`.

Exactly one entry is allowlisted: a bare `new.target;` at top level, which is
genuinely invalid JavaScript in that position and so could never reach emission.
It is kept **in** the corpus rather than deleted, precisely so that the expected
skip set is stated by identity and a NEW skip anywhere else fails. The valid
in-function form is the snippet directly above it.

`selftest.sh` D1 refuses a proportional tolerance reappearing, D2 requires the
comparison to be both defined and called, D3 requires exactly one allowlisted
entry inside the corpus array and requires it to be `new.target;`, and D4
requires the Zig self-test that fault-injects the comparison itself to still
exist.

### E · A script must fail loudly, never silently

A `set -u` unbound-variable bug killed two separate Gate A measurement scripts.
Both times the script stopped mid-way, printed one line of bash diagnostic among
hundreds of lines of build output, and produced **no verdict** — which reads
like a run still in progress, not like a run that died.

* every script enters strict mode through `fs_strict()`, which installs an
  `EXIT` trap, and leaves through `fs_finish()`, which is the only sanctioned
  exit. Any other exit path prints an unmissable `ABORTED <script> rc=N` banner
  and forces a non-zero status;
* the scripts are **shellcheck-clean** at `-x -S style`. `selftest.sh` E6 runs
  shellcheck when it is available and fails on any finding; with
  `FS_REQUIRE_SHELLCHECK=1` its absence is itself a failure. E1–E5 are the
  guaranteed floor beneath it: `bash -n` on every script, the strict-mode and
  `fs_finish` wiring, and a **live fault injection** that runs a script with a
  genuine unbound variable and requires a loud abort — plus the two
  no-false-positive directions, that a completed run prints no banner and that a
  failing *gate* (`fs_finish 1`) is a verdict rather than an abort;
* `flock` is not reentrant across processes, so a nested acquisition hangs with
  no output at all — the same silent-death shape. `FS_LOCK_ALREADY_HELD=1`
  declares that the caller holds the host lock; it is recorded in the provenance
  block, and E2 refuses any script other than `selftest.sh` that sets it.

## Also fixed here: a variant gate must prove it ran the variant

**With the build, not a grep.**
`correctness_default.sh` refuses to accept `-Dzjs_compiler` / `-Dzjs_v2_layout`
in any of its own gate lines, because the predecessor gate was green about a
configuration it had never run: every line carried an explicit flag, so the
default build was never the thing tested. The mirror-image risk is a variant
gate that silently ran the *default*.

Grepping the runtime configuration signature out of the gate's stdout was
tried first and is **not sound**: the scoped test steps (`test-core`,
`test-parser`, …) print no runtime signature at all, so "no signature seen" is
indistinguishable from "wrong signature" and the check fails gates that are in
fact correct. `correctness_variants.sh` therefore passes `-Dzjs_expect_config`
with the full expected signature, which makes every engine-bearing artifact in
the build graph assert its own effective configuration **at compile time**:

```
error: zjs configuration drift: ... artifact: test-compiler-v2
       expected: ...,force_gc=off,...   actual: ...,force_gc=on,...
       differing fields: force_gc: expected off, actual on
```

The script opens with a self-check that runs one deliberately-wrong expectation
and **requires it to fail**, so each run proves the assertion has teeth instead
of assuming it. `test-altrepr` and `test-oom` are the two exceptions: they
reconfigure themselves internally, so their effective configuration is not the
one the invocation requests and a top-level expectation would assert the wrong
thing. They are covered by the attestation their nested builds carry.

## The two-tier measurement rule

From `docs/qcp1_switch_decision.md` §0.1.5. One kind of measurement was doing
two different jobs; they are now separated and must be labelled.

**INTERMEDIATE — not a switch gate.** Cheap, fast, run per cut: code-load alone,
insn/score, cyc/score, compiler scratch measurements. Every report at this tier
must carry the literal words *"INTERMEDIATE — not a switch gate"*. It exists to
steer work between decisions. It may not conclude one. A number obtained by
flipping a constant in a scratch binary is INTERMEDIATE by construction, however
carefully it was measured.

**FINAL SWITCH.** Run on **candidate true production defaults** — the actual
shipping configuration, no explicit flags — and must report all of: full-suite
geomean over all 15 zoo throughput benchmarks; per-benchmark paired ratio;
code-load; insn/score; cyc/score; artifact size; and the full correctness
matrix. `performance.sh` + `join_results.py` are the FINAL SWITCH tier; the
codeload micro inside `performance.sh` is an attribution instrument and is
INTERMEDIATE on its own.

The gate in force (§0.1.2), all three jointly:

1. code-load, v2 / corrected-legacy **≥ 1.2359×**;
2. full-zoo geomean **not regressed** versus the same corrected legacy;
3. **no** non-code-load benchmark negative beyond noise.

`join_results.py` evaluates all three against the **worst** of the four
pairings, and prints every pairing. Reporting only the favourable one is the
specific failure the four-pairing protocol exists to prevent.

## Gate A manifest

The reference run these scripts reproduce.

| field | value |
| --- | --- |
| source commit | `04922a47` (`04922a471eaf940b1a3964e2572efffdc7727a06`) |
| zig | `0.16.0` |
| pinned qjs (sha256) | `b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d` |
| host | pinned to **core 19**, exclusive lock `/tmp/zjs-host-heavy.lock` |
| candidate signature | `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off` |
| legacy signature | same with `compiler=legacy` |

Gate A results on true production defaults:

| measurement | value |
| --- | --- |
| test262 (defaults) | `0/49775 errors, passed 44541, known 25` |
| full-zoo geomean vs corrected legacy | **1.0164×** (four pairings: 1.0150, 1.0189, 1.0140, 1.0178) |
| code-load vs corrected legacy | **1.2517×** (1.2544, 1.2488, 1.2546, 1.2490) — gate ≥ 1.2359× |
| candidate runtime noise floor (b1/b2) | geomean 1.0010, max per-bench deviation 2.18% |
| legacy build-layout lottery (a1/a2) | geomean 1.0038, max per-bench deviation 2.05% |

The per-benchmark floor in `join_results.py` is `0.975`, chosen against those
measured noise floors: a tighter floor would flag the build-layout lottery as a
regression.

## Known open item: `force-gc-unified` fails on BOTH backends

`correctness_variants.sh` returns non-zero at `04922a47` because
`zig build test -Dzjs_force_gc=true` fails two tests:

```
FAIL: tests.exec.test.Engine eval exit leaves closed var-ref cycles for explicit collection
      expected 1133, found 1217
FAIL: tests.exec.test.ordinary script entry points do not run full-heap cycle collection on exit
      expected 1, found 1291
```

Both assert *counts of collections that did not happen*, which force-GC — where
every allocation is a collection point — necessarily violates. The identical
pair fails under `-Dzjs_compiler=legacy` too (`expected 1121, found 1184` /
`expected 1, found 1241`), so this is **pre-existing and backend-independent**,
not a switch regression. The script does not special-case it: a failing gate
reports as failing. Either the two tests need a force-GC-aware expectation or
the gate needs to exclude them explicitly — silently tolerating it would put a
50%-tolerance-shaped hole back into the matrix.

## CLOSED: the dual test262 divergence

The full dual-comparator test262 run — deliberately deferred to the last moment
both compilers coexisted — did **not** match the single-backend runs at
`04922a47`:

| run | result at `04922a47` |
| --- | --- |
| `zig build test262-gate` (defaults, v2) | `0/49775 errors, passed 44541, known 25` |
| `zig build test262-gate -Dzjs_compiler=legacy` | `0/49775 errors, passed 44541, known 25` |
| `zig build test262-gate -Dzjs_compiler=dual` | **`5/49775 errors, passed 44536, known 25`** |

All five were `DualCompileMismatch`, all at comparator tier 1.5 (CFG), field
`block_count`, with v2 emitting one block more than legacy. Minimal reproducer:

```js
switch (0) { default: if (false) ; else ; }   // legacy=1 block, v2=2 blocks
```

**Root-caused and fixed in `a9c13b0a`** — v2 materialised a switch-dispatch
bridge block that legacy never had. Since that commit the full dual run is
`0/49775 errors, passed 44541, known 25` with zero mismatch lines at any
comparator tier, matching both single-backend runs exactly. Kept here because
the *sequence* is the lesson: the widest corpus either backend ever sees found
a divergence that no hand-written dual corpus reached, and it was found only
because the dual run was scheduled while both backends still existed.

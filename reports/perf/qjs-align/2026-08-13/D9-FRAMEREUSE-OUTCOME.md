# D9-FRAMEREUSE outcome — NO-GO, pricing prototype withdrawn

## Decision

Do not delete the frame-reuse subsystem in this round. The pricing-only
comptime prototype is fully withdrawn; no source or test change remains.

The decisive causal Zoo result is candidate/base throughput geomean
`0.9971 / 0.9984 / 0.9973` for pad `0 / 3 / 7`. All three lineages regress.
The median effect is `-0.2724%`, the worst is `-0.2901%`, and the lineage spread
is `0.1327 pp`; `|effect| / spread = 2.05`. It therefore fails both required
conditions: the median is not favorable and the worst pad is not non-regressing.

More importantly for attribution, a normal resolved `op_call2` pays **zero**
reads or writes of `tail_request`, `tail_is_reuse`, `tail_chain`, or
`TailChainBudget`, and zero `loadCurrentLevel` calls between handler entry and
the callee's first opcode. Its full exact-args-leaf return also avoids the
generic tail-chain check. Production disassembly agrees. Removing reuse cannot
own the ordinary-call residual measured here: after the prototype, the task's
`12.46 cyc` residual is still `12.48 cyc/call` by the same decomposition.

## Scope and provenance

- Baseline source: `e31af460d94c5c368a243f37afbf15d4cefed392`, copied with
  read-only `git archive` into `/tmp/d9-framereuse-base-src.IrDvAW`.
- QuickJS reference source/binary: `/home/aneryu/quickjs`, commit `04be2460`;
  binary SHA-256
  `b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d`.
- Zoo: `a17d4e0aabe52719fab1074f4b566d16d08a563c`, clean.
- All zjs timing binaries reported
  `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`.
- CPU 7 only; effective affinity `[7]`; parallelism 1; no `flock`. Builds and
  measurements were serial. Samples are 8 per side, even and ABBA-balanced.
- Counter builds were used only for frequency. All costs below come from
  counter-free production binaries.

The matched Zoo lineage binaries and SHA-256 values are:

| pad | frozen base | pricing candidate |
|---:|---|---|
| 0 | `5f92f6fa040f6c9afc1b79fa6243413361588762aaf5729817006d962c9c4077` | `4b7cc9c2045f6b4b73710a7329a9f62aa3123123408fb4dac4a8c72799eb886d` |
| 3 | `a058837d93d4ddf65544f4b2c15d14c852c85c88046a56dfaceb39dc9dc1f2e6` | `07de4b1d094502ce1d61c6fa0e8a715664354a3682e3afe4e57eb2983e207f78` |
| 7 | `e80276b1b609132073c600ba51b6fab8001c20d77b32dbcb9d4a3dd174442ca3` | `250e3c25756e0dc99fa6608291021a6c2dd603a1cffa0a610245ef09fd1a3aff` |

## Q1 — ordinary-call charge, proved at the exits

### QuickJS versus zjs

QuickJS puts `JSStackFrame sf_s` and the hot frame locals in the
`JS_CallInternal` C activation (`quickjs.c:17746-17759`), checks the planned
stack size and performs one `alloca` (`quickjs.c:17834-17870`). Both ordinary
and tail opcodes call a nested `JS_CallInternal`; a successful tail opcode then
jumps directly to the caller's shared `done:` cleanup
(`quickjs.c:18182-18201`, `18220-18238`, `20699-20710`). There is no physical
frame-reuse record.

zjs has the following additional state:

- `Vm.tail_request` and `Vm.tail_is_reuse` at
  `src/exec/tailcall_dispatch.zig:167-170`;
- `Entry.teardown.tail_chain` at `src/exec/inline_calls.zig:350-356`;
- the 16-byte `TailChainBudget` dead-slot/padding overlay at
  `src/exec/inline_calls.zig:479-507`;
- `Machine.loadCurrentLevel` at `src/exec/inline_calls.zig:1218-1237`;
- replacement, inherited-budget write, and physical Entry overwrite at
  `src/exec/inline_calls.zig:4192-4288`;
- driver selection at `src/exec/tailcall_dispatch.zig:5298-5342` and the
  outlined chain teardown at `src/exec/inline_calls.zig:4294-4357`.

### Counter design and exact counts

The temporary profiling build had twelve exit counters. `op_call2` entry opened
a window; the selected callee's first opcode closed it. Global counters also
proved the complete positive lifecycle. The build was not timed and all source
instrumentation was removed before production builds.

For 100,000 iterations of the ordinary `add(1, 2)` shape:

```text
event order:
 call2_enter, callee_first_opcode,
 tail_request_write, tail_request_read,
 tail_is_reuse_write_false, tail_is_reuse_write_true, tail_is_reuse_read,
 tail_chain_read, tail_chain_write,
 tail_budget_read, tail_budget_write, load_current_level

all:          {100000,100000,0,0,0,0,0,0,0,0,0,1}
call2 window: {100000,100000,0,0,0,0,0,0,0,0,0,0}
flat control: {0,0,0,0,0,0,0,0,0,0,0,1}
```

Thus, per normal resolved `op_call2`, from entry through first callee opcode:

| state | reads | writes | unconditional charge | actual-reuse charge |
|---|---:|---:|---:|---:|
| `tail_request` | 0 | 0 | 0 | 1 read + 1 write |
| `tail_is_reuse` | 0 | 0 | 0 | 1 read + 1 true write |
| `tail_chain` | 0 | 0 | 0 | 1 true write; true read at final chain pop |
| `TailChainBudget` | 0 | 0 | 0 | 1 read + 1 write |
| `loadCurrentLevel` | 0 | — | 0 | 1 call |

The actual-reuse column is detected by 10,000 shadowed-direct-eval reuses:

```text
all: {10000,10000,10000,10000,0,10000,10000,20000,10000,10000,10000,10001}
```

After subtracting the one root `loadCurrentLevel`, this is exactly one
`loadCurrentLevel` per reuse. The two `tail_chain` reads per iteration are one
false read on the surrounding general wrapper pop and one true read on the
final reused-chain pop; only the latter consumes the budget.

There are two narrower non-reuse taxes, neither present in the measured hot
ordinary call:

1. The cold `execCall(...).inline_call` fallback writes
   `tail_is_reuse=false` once. The base `op_call2` disassembly contains
   `strb wzr,[x19,#220]`; the candidate is exactly 4 bytes smaller there.
2. `popFrameMode` tests `tail_chain` once for general/abrupt frames. Ordinary
   and exact-args-leaf returns branch through `popOrdinaryFrame` or their leaf
   epilogue first (`tailcall_dispatch.zig:1087-1094`, `1148-1252`), so the hot
   ordinary return does not pay it.

A partial original-workload Zoo profile completed Box2D, CodeLoad, Crypto,
DeltaBlue, EarleyBoyer and GBemu before being deliberately interrupted. All six
had zero request/reuse/budget events and zero `tail_chain` writes, although
general teardown produced false `tail_chain` reads. This is evidence only for
those six completed benchmarks, not a claim about the other nine.

Production AArch64 disassembly independently confirms the counter result. The
base and candidate hot `op_call2` entry-to-dispatch sequences are equivalent;
neither contains reuse-state traffic or `loadCurrentLevel`. In the base driver,
the actual reuse leg starts with `ldrb w8,[sp,#332]` / `tbz`; the candidate
immediately enters fresh `pushFrame`, and its outlined
`popTailChainFrameMode` symbol is absent. See
`D9-FRAMEREUSE-disassembly.txt` and `D9-FRAMEREUSE-counter-evidence.txt`.

## Q2 — price of removing reuse

The pricing prototype kept every `Vm` and `Entry` field and therefore retained
data layout. A comptime false erased:

- the six `tail_is_reuse` stores and the driver test/replacement leg;
- `tailCallReuse`'s inlined execution body;
- `popTailChainFrameMode` and native-boundary budget reads.

All `.tail` requests fell through to the existing fresh `pushCall` leg. This is
not a shippable semantic implementation: a successful raw `OP_tail_call` needs
the QuickJS `goto done` equivalent after the callee returns, whereas this probe
does not install a faithful two-frame tail-return completion. The prototype did
pass the existing `test-exec` suite (416/416), including recursive tail-budget
tests, but that does not cover the missing successful raw-tail completion. It
was used only for pricing and was then removed.

### Per-call PMU

The exact ordinary-call differential used production binaries, 8 ABBA samples,
CPU 7, explicit `armv8_pmuv3_1` events with 100% counting, and the formula
`(A_direct_call-empty)/30M - (ctrl-empty)/200M`.

| metric per call | base | candidate | paired candidate-base median (MAD) | QuickJS | candidate-QuickJS |
|---|---:|---:|---:|---:|---:|
| cycles | 59.3526 | 59.1720 | -0.2445 (0.1796) | 40.8758 | +18.2961 |
| instructions | 348.1454 | 348.1442 | +0.000064 (0.002255) | 290.0991 | +58.0452 |
| ops | 337.4497 | 338.0034 | +0.5464 (0.0237) | 279.8205 | +58.1828 |
| stall slots | 256.0352 | 253.6208 | -3.0161 (1.6501) | 128.8888 | +124.7320 |

The paired cycle result is only `1.36 × MAD`; instructions are zero within
noise and retired ops move in the wrong direction. This is a layout/codegen
move, not proof that ordinary calls executed less reuse bookkeeping.

Using the task's decomposition of `0.1 cyc` per extra retired op:

```text
fresh base residual      = 18.4767 - 57.6291 * 0.1 = 12.7138 cyc/call
pricing-candidate residual = 18.2961 - 58.1828 * 0.1 = 12.4779 cyc/call
```

So the stated `12.46 cyc` remains `12.48 cyc/call`—effectively all of it. Frame
reuse is not the owner of that ordinary-call residual.

A deliberately non-leaf call shape also had zero reuse counters. Its prototype
delta was `+0.9959 instructions/call` but `-1.3994 cycles/call` (MAD `0.4965`),
with `-96.58` backend slots and `+87.24` frontend slots. That contradiction is
additional evidence of code-placement sensitivity, not a second mechanism win.

## Q3 — can it be deleted faithfully?

Yes in principle, but not by deleting the fields and using the pricing probe.
A faithful implementation must do all of the following together:

1. Push and retain a physical Entry for every tail caller, so observable stack
   frames match QuickJS's nested `JS_CallInternal` calls.
2. Mark the callee with a tail-return completion. On successful return, clean
   the callee, then immediately clean and unlink the intact caller without
   dispatching bytes after terminal `OP_tail_call`; on throw/setup failure, the
   intact caller's catch/unwind boundary must remain authoritative.
3. Charge `call_depth` and `active_bytecode_stack_bytes` at each fresh entry and
   release them one frame at a time. Removing physical reuse removes the need
   for `TailChainBudget`, but it does **not** permit replacing the established
   per-frame budget with an arena pointer/ladder; that would move stack-overflow
   and unwind boundaries.
4. Preserve constructor completion exactly. In particular, constructor frames
   must not set `teardown.simple`: commit `0e81cc01` records the ReleaseSafe
   abort caused by deriving a live operand window from an empty locals slice.
   The current driver already refuses replacement over constructor completion;
   a faithful fresh-frame path must keep that ownership distinction.

The current `pushCall` leg already performs per-entry stack accounting and
leaves the caller present for setup-error handling, so the architecture can
support this. The missing part is the successful two-frame tail-return fusion,
not another fast path. The registered faithful IMPL-TAILCALL experiment built
that shape and measured EarleyBoyer cycles `+1.6761%` and TypeScript
`+1.4659%`; those are prior-session context, not numbers subtracted from this
D9 A/B. Given D9's negative Zoo result, reimplementing it here has no landing
case.

## Q4 — causal Zoo A/B adjudication

Each cell is candidate/base score; higher is better. Each pad is a separately
frozen matched pair with 8 samples per engine and alternating first position.

| benchmark | pad 0 | pad 3 | pad 7 | three-pad median | worst pad |
|---|---:|---:|---:|---:|---:|
| Box2D | 0.9977 | 0.9999 | 1.0004 | 0.9999 | 0.9977 |
| CodeLoad | 1.0002 | 0.9981 | 0.9967 | 0.9981 | 0.9967 |
| Crypto | 0.9976 | 0.9923 | 0.9967 | 0.9967 | 0.9923 |
| DeltaBlue | 0.9996 | 1.0020 | 0.9972 | 0.9996 | 0.9972 |
| EarleyBoyer | 0.9904 | 0.9914 | 0.9940 | 0.9914 | 0.9904 |
| GBemu | 1.0005 | 1.0041 | 0.9991 | 1.0005 | 0.9991 |
| Mandreel | 0.9975 | 0.9948 | 0.9902 | 0.9948 | 0.9902 |
| Navier-Stokes | 0.9909 | 0.9894 | 0.9856 | 0.9894 | 0.9856 |
| PdfJS | 0.9934 | 0.9944 | 0.9934 | 0.9934 | 0.9934 |
| RayTrace | 0.9932 | 0.9965 | 0.9946 | 0.9946 | 0.9932 |
| RegExp | 1.0241 | 1.0349 | 1.0423 | 1.0349 | 1.0241 |
| Richards | 1.0007 | 0.9990 | 0.9960 | 0.9990 | 0.9960 |
| Splay | 0.9994 | 1.0000 | 0.9973 | 0.9994 | 0.9973 |
| TypeScript | 0.9986 | 1.0015 | 0.9961 | 0.9986 | 0.9961 |
| Zlib | 0.9735 | 0.9789 | 0.9808 | 0.9789 | 0.9735 |
| **throughput geomean** | **0.9971** | **0.9984** | **0.9973** | **0.9973** | **0.9971** |

RegExp's 2.4–4.2% gain cannot rescue the candidate. No dynamic reuse count is
claimed for RegExp because the partial scan did not reach it; the six completed
scan benchmarks had no reuse events, and the candidate globally changes
handler placement.
Thirteen of fifteen pad-7 medians are below one. The headline regression is
stable enough to distinguish from its own pad spread (`2.05×`) and points in
the wrong direction.

### Fixed-work mechanism evidence, not the verdict

Pad-0 production binaries were also run with identical deterministic work,
iteration divisor 16 and 8 paired ABBA samples. Ratios are candidate/base;
lower is better.

| benchmark | instructions | cycles | wall | IPC |
|---|---:|---:|---:|---:|
| EarleyBoyer | 1.000863 | 1.005261 | 1.001859 | 0.995516 |
| TypeScript | 1.000533 | 1.001510 | 1.001304 | 0.998924 |
| Zlib | 1.000019 | 1.019079 | 1.018335 | 0.980561 |

The prototype did not reduce retired work on any of the three. This supports
the exit-counter conclusion; it is not used in place of the Zoo verdict.

## Q5 — go / no-go

**NO-GO.** The mechanism is QuickJS-absent, but the premise that ordinary calls
pay it is false for the measured hot path. Actual physical reuse pays the full
request/reuse/budget/cache-refresh protocol; normal resolved calls do not.
Erasing the mechanism leaves the ordinary-call residual essentially unchanged
and regresses causal Zoo in every pad lineage. The pricing prototype is
withdrawn, and no exception to the anti-goal is requested.

This is a useful negative result: it removes frame reuse from the ownership set
for the `12.46 cyc` ordinary-call gap and pushes that residual back toward the
remaining architectural call protocol / port-pressure explanation.

## Rejected candidates and gates

| candidate | decisive numbers | result |
|---|---|---|
| D9 comptime erase, retain layout, fresh push for every `.tail` | Zoo geomean `0.9971 / 0.9984 / 0.9973`; exact-call instructions `+0.000064/call`; residual `12.48 cyc/call` | rejected and withdrawn |
| Same prototype on non-leaf call shape | `+0.9959 insn/call`, `-1.3994 cyc/call`, large frontend/backend slot exchange | rejected as layout-sensitive, not mechanism evidence |
| Faithful caller-retention/tail-return fusion (registered IMPL-TAILCALL precedent) | EB cycles `+1.6761%`, TS `+1.4659%` | not retried; prior no-go confirmed by D9 Zoo direction |

The withdrawn pricing prototype itself passed `test-exec`:

```text
Summary: 416 passed; 0 skipped; 0 failed; 0 filtered.
Build Summary: 4/4 steps succeeded
test-exec success
```

After source reversion, the required baseline gates produced:

`zig build test-exec --seed 0 --summary all`

```text
Summary: 416 passed; 0 skipped; 0 failed; 0 filtered.
Build Summary: 4/4 steps succeeded
test-exec success
```

`zig build test-bytecode --seed 0 --summary all`

```text
Summary: 69 passed; 0 skipped; 0 failed; 0 filtered.
Build Summary: 4/4 steps succeeded
test-bytecode success
```

`bash tools/perf/lint_anti_goals.sh`

```text
(no output; exit 0)
```

`git diff --check`

```text
(no output; exit 0)
```

`zig build test -Doptimize=ReleaseSafe --seed 0 --summary all` compiled the
ReleaseSafe artifact and ran 2165 tests, then failed only at the two fixtures
missing from this worktree's empty `test262/` directory. Per task instruction,
no test262 file/configuration was added or altered:

```text
FAIL: cli.run_test262.test.embedded Debug runner executes a representative test262 harness within its native stack budget (FileNotFound)
FAIL: cli.run_test262.test.test262 typed array iterator staging source parses after installing globals (FileNotFound)
zjs config signature: zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseSafe,force_gc=off,ownership_audit=off
compiler_v2.coverage corpus compiled=44/45 allowlisted_skips=1
Summary: 2162 passed; 1 skipped; 2 failed; 0 filtered.
Build Summary: 7/9 steps succeeded (1 failed)
```

## Artifacts

- `D9-FRAMEREUSE-zoo-pad{0,3,7}-causal-ab.json`: raw causal Zoo runs.
- `D9-FRAMEREUSE-zoo-lineage-summary.json`: per-benchmark median/worst/spread.
- `D9-FRAMEREUSE-lineage-binaries.json`: SHA and config attestations.
- `D9-FRAMEREUSE-call-pmu.json`: exact ordinary-call PMU and QuickJS residual.
- `D9-FRAMEREUSE-generic-call-pmu.json`: non-leaf layout-sensitivity probe.
- `D9-FRAMEREUSE-fixed-pmu.json`: fixed-work mechanism evidence.
- `D9-FRAMEREUSE-counter-evidence.txt`: counter vectors and partial Zoo scan.
- `D9-FRAMEREUSE-disassembly.txt`: production base/candidate instruction evidence.
- `D9-FRAMEREUSE-gates.txt`: verbatim gate summaries and ReleaseSafe failure text.
- `D9-FRAMEREUSE-run-call-pmu.py` and `D9-FRAMEREUSE-summarize-zoo.py`:
  reproducible local measurement/summarization scripts.

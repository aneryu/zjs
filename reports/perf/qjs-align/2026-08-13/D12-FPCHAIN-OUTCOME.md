# D12-FPCHAIN outcome: NO-GO

> **STATUS: CLOSED — NO-GO; all tested mechanism candidates falsified; no
> transferable benchmark classification established.**
>
> ⚠️ **`pad7` is INVALID / EXCLUDED due to CPU contention.** During that window a
> second task was mistakenly pinned to the same CPU 5. It must not enter any
> median, range, or cross-pad stability conclusion. It was deliberately **not**
> re-measured: cand1 is already rejected on three grounds independent of pad7 —
> the worst *valid* pad fails the gate, the target benchmark regresses on every
> pad, and the mechanism's priced exposure does not match the Zoo response.
>
> ⚠️ The host line originally read `Cortex-A725`. That was a transcription error;
> CPU 5 and CPU 19 share MIDR `0x410fd851`, both cap at 3900 MHz, and both belong
> to `armv8_pmuv3_1` (which covers 5-9,15-19; the A725 cluster is 0-4,10-14 at
> 2808 MHz). The measurements are on the intended big core and are comparable
> with the CPU 19 baselines.
>
> **Key negative conclusion.** The observed Zoo split between apparent
> latency-sensitive regressions and throughput-oriented gains is not causally
> explained by the priced floating-point dependency-chain mechanism; exposure
> magnitude fails to predict even the direction of benchmark movement.
> (navier-stokes: highest priced exposure 109.16M yet regresses ~0.24%;
> box2d: only 23.62M priced yet improves ~1.57%; crypto/zlib/richards carry
> essentially no exposure.) The cand1 Zoo grouping therefore may **not** be used
> as diagnostic evidence for floating-point dependency chains, operand pre-load,
> or stack forwarding.
>
> **Falsified candidates retained for the record:**
> full operand pre-load — NO-GO; tag-before-payload — no mechanism gain
> (21.0193 → 21.0255 cycles/update); NaN boxing — amplifies the serialisation
> penalty (2.986 → 9.998 cycles/update); "the C ABI boundary prevents holding
> values in registers across handlers" — falsified, the compiler already
> eliminates that boundary.
>
> No follow-up autopsy and no further machine or analysis time are authorised.

Date: 2026-08-13

CPU: 5, Cortex-X925, `taskset -c 5`, one process at a time, no `flock`

Baseline: `e31af460d94`, production signature
`zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`

## Verdict

The dependency-chain deficit is real and reproducible, but neither tested
QuickJS-faithful source transformation is acceptable:

1. Loading complete operands at handler entry removes about 1.9% of the
   dependency microbenchmark's instructions, but makes its serial critical path
   **0.742 cycles/update slower**. Its full 7-lineage causal Zoo result has a
   beneficial median (**+0.408 pp**) but a regressing worst lineage
   (**-0.080 pp**) and makes navier-stokes worse in six of seven lineages
   (median **-0.241 pp**). It fails the stated rule.
2. Publishing the tag before the FP-dependent payload is present in the emitted
   assembly, but changes the serial cost from 21.0193 to 21.0255 cycles/update.
   It has no mechanism-level benefit and therefore does not advance to Zoo.

No production source was changed. The honest outcome is that the observed
approximately 4.5-cycle zjs/qjs serialisation gap is a backend critical-path
property, but the obvious QuickJS-shaped source changes do not shorten it on
this compiler/CPU. The remaining interpreter stack edge is not safely removable
without a non-QuickJS bypass or a wider dispatcher redesign.

## Q1 — The emitted dependency chain

### Representation and source mechanism

This measurement is for the production **16-byte payload+64-bit-tag**
representation. zjs implements the generic float arm at
`src/exec/tailcall_dispatch.zig:2381-2413`; add/mul read operands through
`numberValue` and write `sp[-2]` at line 2404. QuickJS copies both complete
operands at `quickjs.c:19699-19700` and `quickjs.c:19834-19835`, classifies the
float arm at `quickjs.c:19710-19725` / `19853-19868`, and writes `sp[-2]` at
`19727-19728` / `19870-19873`.

QuickJS is not using an 8-byte representation here: `quickjs.h:218-232` defines
the same 16-byte payload followed by an `int64_t tag`; its float accessor is the
payload field at `quickjs.h:236-241`.

### `op_add`, float/float hot path, instruction by instruction

Addresses are from frozen binaries, not source inference. `S0` is the result
slot that the following dependent opcode consumes.

| Stage | zjs `op_add` | qjs `OP_add` | Dependency |
|---|---|---|---|
| Load operand tags | `117bbc0 ldur x10,[x1,#-24]`; `117bbc8 ldur x9,[x1,#-8]` | `23958 ldp x2,x5,[x19,#-32]`; `2395c ldp x0,x4,[x19,#-16]` | qjs loads payload+tag together; zjs loads tags first |
| Classify | `117bbcc orr`; `117bbd0 cbz`; float branch through `117bc2c cmp x10,#8` and `117bc70 cmp x9,#8` | `23968 orr`; `2396c cbnz`; `2a30c cmp w5,#8`; `2b0e0 cmp w4,#8` | tag values control whether FP execution is reached |
| Load/extract payload | `117bc28 ldur x11,[x1,#-32]`; `117bc68 fmov d0,x11`; `117bc6c ldr x10,[x8]`; `117bc78 fmov d1,x10` | payloads already in `x2/x0`; `2b0dc fmov d1,x2`; `2a7f8 fmov d0,x0` | payload load to `fmov` is a true data dependency |
| Calculate | `117bc7c fadd d0,d0,d1` | `2a7fc fadd d0,d0,d1` | true FP data dependency |
| Publish result | `117bc80 stur d0,[x1,#-32]` (S0 payload); `mov tag`; `117bc88 stur x9,[x1,#-24]` | independent `mov x8`; `mov tag`; tag store; table-base/SP arithmetic; `2a818 stur d0,[x19,#-16]` (S0 payload) | FP result to payload store is true; tag work is independent of FP result |
| Dispatch | opcode load, table address/load, `117bca0 br x4` | opcode load, table load, `2a82c br x0` | control dependency only |
| Next dependent opcode | next handler repeats tag classification, then loads S0 payload | next `ldp` reads S0 payload+tag | S0 store to same-address load, then load to FP op, is the cross-handler true dependency |

The duplicated qjs `ldp` pair at `23960/23964` feeds other add branches; it is
not another dependent stack round trip. Full dumps are
`D12-FPCHAIN-zjs-op-add-disasm.txt` and
`D12-FPCHAIN-qjs-op-add-disasm.txt`.

### `op_mul`, float/float hot path

| Stage | zjs `op_mul` | qjs `OP_mul` | Dependency |
|---|---|---|---|
| Load values | tags: `117b9c0/117b9c8`; late payloads: `117b9d4/117b9e8` | `2383c ldp x2,x3,[x19,#-32]`; `23840 ldp x1,x0,[x19,#-16]` | same split versus complete-load difference |
| Classify/extract | `orr/cbz`, two tag comparisons, `117ba34/117ba44 fmov` | `23844 orr`; `29a3c cmp`; `2ab54` arm; `29a54 fmov` | tag is a control dependency; payload is a data dependency |
| Calculate | `117ba48 fmul d0,d0,d1` | `29a58 fmul d0,d0,d1` | true FP dependency |
| Publish | `117ba4c stur d0,[x1,#-32]`, then tag store | `sub sp`; `mov tag`; `29a34 stur d0,[x19,#-32]`; common tag store `23874` | payload store carries the result; surrounding integer work does not |
| Dispatch/consume | `117ba58-117ba6c`, then next tag/payload loads | `23878-23894`, then next `ldp` | dispatch is control; same-address store/load is the cross-op data edge |

Full dumps are `D12-FPCHAIN-zjs-op-mul-disasm.txt` and
`D12-FPCHAIN-qjs-op-mul-disasm.txt`.

Thus the unavoidable result chain in both engines is:

```text
previous fadd/fmul
  -> payload store S0
  -> next handler same-address payload load
  -> fmov/extract
  -> current fadd/fmul
```

The tag store/load/classification is a parallel **control** chain that gates the
current FP instruction. Opcode lookup is another control chain. Neither is the
FP payload's data chain, although either can determine total latency if it
finishes later.

## Q2 — Why the approximately 4.5-cycle gap exists

### Positive control and reproduction

The counter method first had to detect a known chain. Eight ABBA samples on CPU
5 reproduce the supplied phenomenon after subtracting the empty loop and
dividing by 80,000,000 `s=s*a+b` updates:

| Case | qjs cycles/update | zjs cycles/update | zjs-qjs |
|---|---:|---:|---:|
| four serial chains (`dep`) | 20.2409 | 21.0320 | +0.7911 |
| four independent chains (`indep`) | 17.3542 | 13.4813 | -3.8729 |
| serialisation penalty, `dep-indep` | **+2.8868** | **+7.5508** | **+4.6640** |

The positive control therefore detects the known latency difference. In `dep`,
zjs/qjs backend-stall ratio is 1.359, while backend-memory is 0.996; this is a
non-memory backend dependency, not an LLC/L1 miss effect. Raw data:
`D12-FPCHAIN-baseline-micro-pmu.json`.

The nested control performs the same 80M mul/add updates while reducing local
writeback from 80M to 20M. It still reverses the engines: net qjs 19.7156 versus
zjs 21.6847 cycles/update, with zjs-qjs +1.969 cycles and only +0.0018
backend-memory cycles/update. Therefore local-variable writeback is not the
primary mechanism; the arithmetic stack edge remains. Raw data:
`D12-FPCHAIN-nested-micro-pmu.json`.

### Preregistered hypotheses

| Hypothesis | Assembly/counter result | Judgment |
|---|---|---|
| 16-byte value round-trips through the interpreter stack and store forwarding is wider/misaligned | The round trip is real in both engines. On the tagged zjs path, an aligned 8-byte `stur d0` is consumed by an 8-byte `ldur/ldr` from the exact payload field; tag is a separate aligned 8-byte store/load. There is no partial-width or overlapping access. Backend-memory stays flat in the positive control. | **Round trip confirmed; width/alignment-forwarding-failure variant disproved.** It is a true latency edge but not uniquely zjs. |
| zjs separately reads tag and payload while qjs `JS_VALUE_GET_FLOAT64` is one load | Assembly confirms zjs tag-first/late-payload and qjs entry `ldp`. Candidate 1 forces complete operand loads once at entry; emitted assembly does so and removes 1.888% of `dep` instructions, yet adds 0.742 net cycles/update. | **Static difference confirmed; causal explanation/leverage disproved.** |
| `callconv(.c)` helper boundary spills values | There is no native call at the source helper boundary. LLVM tail-folds `opBinaryFloat` into the same handler; no `bl`, prologue, or helper frame appears between classification and FP operation. | **Disproved.** |
| zjs stores the dependent payload immediately after `fadd/fmul`, while qjs schedules independent tag/SP/table-base work first | Candidate 2 emits tag store before payload store (`fadd; mov tag; stur tag; stur payload`). Serial net cost is 21.0255 versus baseline 21.0193 cycles/update; backend cost also rises. | **One-instruction scheduling form tested and disproved as a useful source lever.** |
| The alternative 8-byte representation removes the stack-chain cost | See Q3: NaN boxing makes the serial penalty much larger. | **Strongly disproved on this CPU/compiler.** |

What remains established is narrower than a speculative single-instruction
story: zjs's extra latency is the non-memory backend cost of the FP-result →
stack publication → dependent FP-consumer chain plus its surrounding handler
schedule. The experiments do **not** justify calling it a forwarding failure,
tag-load problem, or ABI call boundary. No source-level transformation tested
here shortens that emitted critical path.

## Q3 — Is each component reducible?

| Component | Reducibility decision |
|---|---|
| `code_ptr -> opcode -> handler` | **Irreducible in this task**, matching D7 and qjs computed goto. It is a control chain, not the FP payload chain. |
| FP result -> interpreter stack payload store -> next payload load | **Semantically required by both current interpreters.** Removing it would require a register-caching dispatcher/bytecode redesign, not a local QuickJS-aligned change. A per-op/opcode-combination bypass would violate the anti-goal. |
| Separate tag chain | **Locally alterable but not profitably reducible.** Complete-load candidate 1 reduced instructions and lost latency/Zoo robustness. |
| Source `callconv(.c)` boundary | **Already compiled away** for this path; nothing to remove. |
| Store scheduling around FP result | **Locally alterable but measured neutral/negative** in candidate 2. |
| Representation | **Selectable only as the mandated alternate, not a production tuning knob; it is much worse here.** |

### `-Dzjs_nan_boxing=true` contrast

The production `layout=short` NaN-box build at `e31af460` cannot link on this
AArch64 checkout: four linker assertions report `get_arg* handler size drifted`.
For a representation-only diagnosis, both tagged and NaN-boxed binaries were
therefore rebuilt from the same baseline with `layout=plain` and only the
AArch64 handler-island linker script disabled. This is not a Zoo/acceptance
comparison.

Eight ABBA samples give:

| Representation (`layout=plain`) | dep net cyc/update | indep net cyc/update | serial penalty |
|---|---:|---:|---:|
| 16-byte tagged | 18.2831 | 15.2975 | **2.9856** |
| 8-byte NaN box | 30.7055 | 20.7075 | **9.9980** |

NaN boxing executes only two 8-byte operand loads and one 8-byte result store,
but the emitted xor/shift/prefix checks and post-FP NaN canonicalisation lengthen
the chain. It is not a solution; on this build it adds about 7.01 cycles/update
of serialisation penalty. Raw data and assembly:
`D12-FPCHAIN-repr-micro-pmu.json`,
`D12-FPCHAIN-zjs-nanbox-op-{add,mul}-disasm.txt`.

## Q4 — Absolute pricing by benchmark

The calibrated control contains 80M `s=s*a+b` updates, hence 160M arithmetic
result edges. Its zjs/qjs serialisation-penalty difference is 4.664
cycles/update, or a deliberately simple **2.332 cycles/detected result edge**
gross price.

A profiling-only exit counter records a float-fast opcode and records a chain
only when its lhs or rhs slot address **and exact two-word result bits** match the
preceding float-fast result. The counter was validated before use:

| Positive-control corpus | float-fast ops | detected edges |
|---|---:|---:|
| `dep` | 160,000,000 | 159,999,999 |
| `indep` | 160,000,003 | 80,000,002 |
| nested dependency | 160,000,000 | 159,999,999 |

It detects every intended edge in `dep`/nested and detects the deliberately
missing cross-chain edges in `indep`. The following fixed-work counts are thus
macro-path evidence, not an assumption that the microbenchmark unit price is
universally exact.

| Benchmark, d16 | z/q insn | z/q cycles | zjs-qjs median cycles | float-fast ops | detected edges | gross chain contribution |
|---|---:|---:|---:|---:|---:|---:|
| navier-stokes | 0.96446 | 1.04193 | +68.36M | 62,364,030 | 46,811,577 | **109.16M cyc** |
| box2d | 1.02238 | 1.08255 | +101.81M | 20,205,559 | 10,128,461 | **23.62M cyc** |
| crypto | 0.80629 | 0.96384 | -194.58M | 32,069 | 10,631 | **0.0248M cyc** |
| zlib | 0.95950 | 1.08933 | +1,383.92M | 6 | 0 | **0** |
| richards | 1.17559 | 1.10336 | +446.73M | 6 | 0 | **0** |

All fixed-work rows are fresh CPU-5, 8-sample ABBA results from
`D12-FPCHAIN-five-fixed-pmu-d16-n8.json`; fixed sources have the exact runner
transformation, and navier's hash is
`8f6cf45ecae6672fcee1e70a54f77b47a6a9e95532fc825909131d66e435b6fa`.

This is a **gross** attribution. Navier's 109.16M estimate exceeding its fresh
68.36M net deficit means other zjs mechanisms save roughly 40.8M cycles in the
same workload; it does not mean the counter is a net causal model. Relative to
the supplied CPU-19 +92.3M deficit, the gross estimate is about 118%. Box2d has
a material but minority gross contribution (~23% of its fresh net deficit).
Crypto's edge count is negligible and zjs wins overall; zlib/richards have zero
detected FP-chain contribution, so their gaps must be elsewhere. This rejects a
cross-benchmark claim that FPCHAIN explains all five scores.

## Q5 — Candidates and causal Zoo decision

### Candidate 1: complete operand loads at handler entry

The candidate follows qjs `quickjs.c:19699-19700,19834-19835`: copy each
complete operand once at entry and consume locals in the inline float arm. The
emitted entry changes from two tag loads followed by late payload loads to one
payload load plus an `ldp` payload/tag pair and the remaining tag load. There is
still no native helper call.

Mechanism ABBA result:

| Metric | `dep`, candidate/base | `indep`, candidate/base |
|---|---:|---:|
| instructions | **0.98112** | **0.98291** |
| raw cycles | 1.03009 | 0.97421 |
| loop-subtracted cycles/update | 21.7649 vs 21.0233 (**+0.742**) | 13.685 vs 14.142 |

Because it changed the mechanism and might still affect lifecycle/Zoo behavior,
it was taken through the required causal Zoo: candidate zjs versus frozen
`e31af460` zjs, pads `0,1,3,7,15,31,63`, 8 samples per side per benchmark,
serial alternating ABBA, CPU 5, 120/120 valid ordered runs in every lineage.
Cells are `100*ln(candidate_score/baseline_score)` percentage points; positive
is beneficial.

| benchmark | p0 | p1 | p3 | p7 | p15 | p31 | p63 | median |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| box2d | +1.560 | +0.475 | +1.323 | +2.409 | +1.746 | +1.325 | +1.125 | +1.325 |
| code-load | +0.598 | -0.067 | +0.310 | +0.648 | +0.696 | +0.695 | +0.425 | +0.598 |
| crypto | -0.065 | -0.153 | -0.740 | -0.262 | -0.174 | -0.499 | -0.304 | -0.262 |
| deltablue | +0.040 | -0.040 | +0.241 | +0.121 | -0.161 | -0.322 | +0.080 | +0.040 |
| earley | -0.256 | -0.370 | -0.526 | -0.385 | -0.486 | -0.370 | -0.570 | -0.385 |
| gbemu | +1.094 | +0.274 | +0.956 | +1.320 | +1.320 | +1.093 | +1.273 | +1.094 |
| mandreel | -0.165 | -0.357 | -0.275 | -0.110 | -0.688 | -0.549 | -0.384 | -0.357 |
| navier-stokes | **-0.241** | **-0.508** | **-0.554** | **-0.193** | **-0.097** | **-0.386** | **+0.048** | **-0.241** |
| pdfjs | +0.483 | +0.143 | +0.515 | +0.425 | +0.477 | +0.705 | +0.566 | +0.483 |
| raytrace | -0.155 | -0.252 | -0.329 | -0.058 | -0.291 | -0.058 | +0.291 | -0.155 |
| regexp | +0.613 | +0.336 | +1.522 | +1.360 | +1.984 | +2.088 | +2.260 | +1.522 |
| richards | +0.203 | +0.068 | -0.068 | +0.101 | 0.000 | -0.068 | -0.203 | 0.000 |
| splay | +0.722 | +0.792 | +0.546 | +0.738 | +0.540 | +0.205 | +0.385 | +0.546 |
| typescript | +0.395 | -0.194 | -0.031 | -0.036 | +0.158 | +0.023 | -0.140 | -0.031 |
| zlib | +1.299 | -1.341 | +0.811 | +0.812 | +1.360 | +1.114 | +1.413 | +1.114 |
| **geomean** | **+0.408** | **-0.080** | **+0.247** | **+0.459** | **+0.426** | **+0.333** | **+0.418** | **+0.408** |

Geomean lineage range is 0.539 pp; MAD is 0.0511 pp and robust sigma
`1.4826*MAD` is 0.0757 pp. Effect/range is **0.76**, effect/robust-sigma is
**5.39**, and effect/MDE is **1.47**. Despite clearing the median and MDE legs,
the worst pad is negative. It therefore fails
“median beneficial AND worst pad non-regressing AND effect > MDE.” More
importantly, it misses the requested benchmark directly. Decision:
**INCONCLUSIVE/NO-GO, do not land**.

Raw causal artifacts are `D12-FPCHAIN-cand1-zoo-pad{0,1,3,7,15,31,63}-n8.json`
(**`pad7` excluded as invalid, see the status note at the top**)
and matching `.log` files. Frozen baseline and candidate hashes are embedded in
each JSON.

### Candidate 2: tag-before-payload publication

The candidate follows the ordering visible around qjs
`quickjs.c:19727-19728,19870-19878`. Its disassembly proves the intended change:

```text
baseline: fadd/fmul -> stur payload -> mov tag -> stur tag
candidate: fadd/fmul -> mov tag -> stur tag -> stur payload
```

Eight ABBA samples show no serial benefit:

| Metric | baseline | candidate | delta/ratio |
|---|---:|---:|---:|
| `dep` instructions | 8,467,430,506 | 8,467,471,453 | 1.000005x |
| `dep` raw cycles | 1,969,099,910 | 1,969,111,219 | 1.000006x |
| net cycles/update | 21.01931 | 21.02548 | **+0.00616** |
| net backend-stall/update | 7.00328 | 7.04533 | **+0.04205** |

It fails the mechanism precondition, so there is no “go” to price with a
multi-hour Zoo. Decision: **REJECT before Zoo**. Raw data:
`D12-FPCHAIN-cand2-micro-pmu.json`.

Candidate source patches are retained only as rejected evidence in
`D12-FPCHAIN-cand1.patch` and `D12-FPCHAIN-cand2.patch`; every changed source
site contains its `qjs:<line>` annotation. Neither patch was applied to the
worktree.

## Gates

These gates ran against the unchanged production source on CPU 5. Original
output is retained in the named `D12-FPCHAIN-gate-*.log` files.

```text
$ zig build test-exec --seed 0 --summary all
Summary: 417 passed; 0 skipped; 0 failed; 0 filtered.
Build Summary: 4/4 steps succeeded
```

```text
$ zig build test-bytecode --seed 0 --summary all
Summary: 69 passed; 0 skipped; 0 failed; 0 filtered.
Build Summary: 4/4 steps succeeded
```

```text
$ bash tools/perf/lint_anti_goals.sh
(no stdout; exit 0)
```

```text
$ git diff --check
git diff --check: PASS
```

The required ReleaseSafe gate is honestly **not green** in this worktree:

```text
$ zig build test -Doptimize=ReleaseSafe --seed 0 --summary all
FAIL: cli.run_test262.test.embedded Debug runner executes a representative test262 harness within its native stack budget (FileNotFound)
FAIL: cli.run_test262.test.test262 typed array iterator staging source parses after installing globals (FileNotFound)
Summary: 2163 passed; 1 skipped; 2 failed; 0 filtered.
Build Summary: 7/9 steps succeeded (1 failed)
```

Both failures are the declared missing-test262-corpus condition of this
worktree, not failures in arithmetic code. No corpus, config, ledger, or test was
changed or skipped. Per task contract, canonical test262/ReleaseSafe resolution
belongs to the driver on main. Since no candidate is being landed, there is no
claim that a new source change passed the final gate.

## Artifact index

- Baseline/controls: `D12-FPCHAIN-baseline-micro-pmu.json`,
  `D12-FPCHAIN-nested-micro-pmu.json`, `D12-FPCHAIN-dep-nested.js`.
- Tagged/NaN-box contrast: `D12-FPCHAIN-repr-micro-pmu.json` and the four
  tagged/NaN-box add/mul disassembly files.
- Candidate 1: patch, add/mul disassembly, micro PMU JSON, seven Zoo JSON/log
  pairs.
- Candidate 2: patch, add/mul disassembly, micro PMU JSON.
- Exit counts: `D12-FPCHAIN-counter-control-{dep,indep,nested}.json` and
  `D12-FPCHAIN-counter-{navier-stokes,box2d,crypto,zlib,richards}-fixed-d16.json`.
- Fixed work: five generated d16 scripts and
  `D12-FPCHAIN-five-fixed-pmu-d16-n8.json`.
- Reproducer: `D12-FPCHAIN-run-micro.py`.
- Gates: `D12-FPCHAIN-gate-{test-exec,test-bytecode,release-safe,anti-goals,diff-check}.log`.

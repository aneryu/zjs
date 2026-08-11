# 2026-08-11 outcome — per-opcode audit, six knives, two landed

## Headline

`dec6961d` → `e9ab2cf5`: zoo causal geomean **1.0110**, 15 of 17 scores up,
one neutral, one regression (RegExp, adjudicated below and accepted).

Absolute vs QuickJS `04be2460`, measured rather than projected:
**geomean 0.8946** (17 scores, 8 samples, CPU 5).
The previous archived absolute run was `07ab9b24` at 0.8324 — four months and
three tranches stale. Everything between was chain-projected from causal A/Bs,
which compounds each step's layout component; the projection read 0.8810 and the
campaign plan read 0.8849, so the projection was low by ~1.1pp.

**Do not attribute 0.8324 → 0.8946 to today's knives.** Back-solving the causal
factor gives `0.8946 / 1.0110 = 0.8849` as the pre-integration absolute, which is
exactly what the campaign plan carried. Today's two knives are worth **+1.1%**.

## What landed (`e9ab2cf5`)

| knife | mechanism | measured |
|---|---|---|
| cold-boundary | fast arms stop publishing pc/sp/`Stack.top_ptr` into a cold shell and reloading through `coldNext`; hot arms route to resident handlers. Population is `special_object` 39.956M + complex `if_false8` 46.522M, not the `neg` path the diagnosis predicted. QuickJS keeps CASE and its slow label in one `JS_CallInternal` activation (qjs:19148, qjs:18469). | rt-fixed insn **−1.575%**, cyc **−2.775%**, four cold-build combinations, 16 paired samples, all winning; ≈57 instructions per removed entry |
| deinit-gate | releases stop reading the GC-phase mirror before decrementing; the gate moves onto the zero-refcount leg, mirroring `__JS_FreeValueRT` (qjs:2664, qjs:6431), so the ~99.9% of releases that do not free stop paying | rt-fixed insn −1.036%..−1.092%, cyc **−0.811%..−1.220%**; splay insn −0.875%..−0.893%, cyc −0.031%..−0.262% (near neutral) |

Gates: `test-exec` 414/414, `test-bytecode` 69/69, ReleaseSafe unified
2161 passed / 1 skipped / 0 failed, `test262-gate` **0/49775 errors, 44581 passed**
— bit-identical to the pre-integration baseline.

## Accepted regression: RegExp −2.78%

Adjudicated with the new layout-lineage runner (three pads, both sides built at
each pad, each lineage its own paired A/B):

| pad | instructions | cycles | IPC | branch-misses |
|---:|---:|---:|---:|---:|
| 0 | −0.410% | +3.418% | −3.77% | +3.85% |
| 3 | −0.381% | +2.576% | −2.96% | +0.19% |
| 7 | −0.411% | +3.457% | −3.60% | +3.95% |

Verdict **SEMANTIC** for both metrics (instructions spread 0.030pp, cycles spread
0.881pp, all lineages agreeing in sign). This is a real mechanism effect, not the
placement lottery.

Mechanism: the cold-boundary knife replaces `cold_table[pc[0]]` indirect calls
with `residentTailHandler` ones, changing the indirect-branch target
distribution. RegExp barely executes those cold legs, so its indirect jumps were
highly predictable before; the resident routing adds target entropy. Fewer
instructions (−0.41%) lose to more mispredicts (+3.9%).

Accepted because: the causal geomean is +1.1% with 15 of 17 up, RegExp's absolute
score remains **1.1270** (far ahead of QuickJS), and the regression is now
explained rather than unexplained. A narrower variant that keeps `if_false8`
resident while leaving `special_object` on the cold path was not attempted; that
is the obvious follow-up if RegExp becomes a target.

⚠️ A single-shot reading of this same comparison had reported branch-misses
**−1.52%**, which would have exonerated branch prediction. The lineage run showed
+3.85% and +3.95% on two of three pads. Single-shot stall/miss readings are not
adjudicative.

## Method correction: clause 4 was not controlling layout

Every knife measured today used "two cold builds per side" as its layout control.
That clause samples compiler non-determinism, which is nearly absent here because
Zig is deterministic for a fixed source — the pairs are frequently byte-identical.
It proves the noise floor; it does not move code.

`-Dzjs_dossier_layout_pad` (src/dossier_pad.zig) does move code, was already
wired into engine options and imported by `internal_root`, and nothing drove it.
`tools/perf/layout_lineage/run_lineage.py` now does.

Consequence for today's other results: T2b (state-base mirror, cycles +1.458%,
`stall_frontend` +11.918% against `stall_backend` −6.962%) and T7 (`add_property`,
EarleyBoyer cycles +0.128%..+0.364% with I-cache miss flipping sign between the
two candidate builds) were both concluded on the ineffective control. Their
verdicts are provisional until re-run through lineages.

## Not landed

| knife | measured | disposition |
|---|---|---|
| stack-top publish | cyc −0.328%, four combinations consistent | 6 conflict hunks against the landed pair; redo on `e9ab2cf5` rather than hand-merging three-way intent |
| `is_exotic` predecomputed bit | insn **−1.207%..−1.259%** stable, cycles −1.049%..+0.085% inconsistent | mechanism confirmed (first-round "just delete the classification" cost +0.53% because nothing preserved the ordinary-node bypass); cycles unrealised |
| `add_property` mirror | micro 5.72–7.13 cyc/property saved of 23.6 predicted; RT/TS improve, EarleyBoyer regresses | provisional — never lineage-tested |
| state-base mirror | cyc +1.41%..+1.46% across two rounds | provisional negative |
| teardown budget/ladder | insn −0.038%..+0.071%, cyc −0.148%..+0.171% | negative; "collapse four counters into one arena pointer" is not faithfully implementable under segmented arena, heap fallback and tail reuse — it would move the stack-overflow and unwind boundaries |

## Diagnosis artifacts

- `zoo-full-vs-qjs-e9ab2cf5.json` — the absolute baseline all future ordering should divide by
- `regexp-layout-lineage.json` — the adjudication above
- EarleyBoyer census (in-session): opcode totals **zjs 300.7M vs qjs 341.5M**, zjs
  11.93% *lower*, the entire gap being `constructSimpleFieldConstructor`'s bypass
  (`sc_Pair` 4.704M constructions × 9 opcodes). It does 12% less work and still
  scores 0.6450. The `apply` suspicion is dead for this workload: qjs reports
  `function_apply=0`, `build_arg_list=0`, `call_method=2209`, with a positive
  control proving the counters detect.
- Constructor stage split (20M `new Node(1,2)`, bypass removed so both engines run
  the same nine opcodes): qjs 286.70 vs zjs 417.60 cyc/new — handler shell +63.42,
  two property writes +47.22, admission +43.70, teardown +30.60, `this` creation
  +14.57. **Frame construction itself is a zjs win** (11.38 vs 29.50 cyc of
  increment), matching the independently measured call-setup advantage.

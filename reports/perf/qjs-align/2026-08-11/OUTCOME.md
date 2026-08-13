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

---

# Second tranche: EarleyBoyer knives (`4fa7c0b3`)

## Absolute baseline moved 0.8946 → 0.8958 (+0.14%)

Causal A/B read **1.0034**; the absolute run read **+0.14%**. The gap is RegExp,
which reads −2.20% causally and **−4.05%** absolutely.

| benchmark | e9ab2cf5 | 4fa7c0b3 | |
|---|---:|---:|---|
| EarleyBoyer | 0.6450 | **0.6629** | +2.78% |
| MandreelLatency | 0.9443 | 0.9609 | +1.76% |
| zlib | 0.9016 | 0.9113 | +1.07% |
| PdfJS | 0.7397 | 0.7457 | +0.80% |
| Richards | 0.9003 | 0.9070 | +0.75% |
| RayTrace | 0.7548 | 0.7587 | +0.52% |
| Box2D | 0.9015 | 0.8955 | −0.66% |
| **RegExp** | 1.1270 | **1.0814** | **−4.05%** |

EarleyBoyer's +2.78% matches the causal +2.89%. The knives are:
`is_null` resident handler (100% hit rate, 13.4 → 0.85 cyc, 15x),
`instanceof` dead pre-filter removal (7,928,421 nominal, **0** measured hits),
and `OP_dup` (−7.33 insn / −5.32 cyc per event).

## ⚠️ A layout verdict does not undo the layout

RegExp was adjudicated **LAYOUT** by the lineage runner, and that verdict is
correct — but the three pads read:

| pad | cycles (cand/base) | |
|---:|---:|---|
| 0 | **+0.721%** | candidate slower |
| 3 | −2.871% | candidate faster |
| 7 | −2.183% | candidate faster |

**pad 0 is the default build — the binary that actually ships.** It is the one
lineage out of three where RegExp loses; under the other two placements the
candidate is ~2% *faster*. So "this is placement, not mechanism" is true and
also does not help: the shipped artifact really did draw the bad ticket, and
−4.05% of a 1.127 score is a real 4% of throughput on that benchmark.

The correct reading of a LAYOUT verdict is **"a different placement removes
it"**, not "it is not happening". Nothing in this campaign acted on that
distinction, and the absolute baseline is where it showed up: causal +0.34%
against absolute +0.14%.

This is the first concrete instance of the placement lottery costing real score
rather than merely confusing a measurement. It does not justify hand-tuning
linker placement as a strategy (that remains an acceptance constraint, not a
lever), but it does mean a LAYOUT verdict should be recorded with the shipped
pad's own number, not just the median.

## Day total

```
dec6961d   0.8849 (back-solved)
e9ab2cf5   0.8946   T1 cold-boundary + T5 deinit-gate     causal 1.0110
4fa7c0b3   0.8958   is_null + instanceof + dup            causal 1.0034
                    net +1.23%, gap to parity 11.6%
```

Four gate rounds, `0/49775 errors / 44581 passed` every time, bit-identical to
the campaign start.

## Yield

14 codex tasks produced 5 landed knives, 3 deep attributions, and 1 tool.
Seven candidate knives were implemented; **four produced no reproducible cycle
win**. Five of the eight adjudications required the lineage runner to avoid a
wrong conclusion, including one that reversed a verdict this campaign had
already issued (T7's `add_property`, concluded "not worth landing" on the
ineffective two-cold-builds control, later re-adjudicated LAYOUT).

The durable output of the day is the attribution work and the tool, not the
implementation throughput.

## Native boundary: investigated, largely closed

`instanceof` is 23.1% of EarleyBoyer's excess cycles at 3.44x unit cost, and the
native call boundary was the leading suspect. A full design study priced it:

```
direct boundary   zjs 59.5 vs qjs 32.7 cyc/call   1.82x, excess 26.8
  entry/admission  +11.58    native frame +4.85    realm +3.93
  return +3.14     params +2.17    actual body +1.24 (near parity)
env_publish        0        ← T3's exec_direct ABI already removed it entirely
```

Forcing the same body back through the environment fallback costs **+51–52
instructions / +25.1–26.9 cycles per call**, confirming T3's win is real and
must not be double-counted. Three proposals were produced; the best has a
conservative window of **3–4 cyc/call**, the second **2.2 cyc/call**.

Each of `NativeCallEnvironment`'s nine fields was justified individually. Two
are architectural necessities rather than overhead: `output: *std.Io.Writer`
(zjs's host writer is not part of QuickJS's `JSContext` ABI) and the
`caller_function`/`caller_frame` pair (zjs has no single C activation spanning
all handlers, so the caller's Frame/Vm must be reified).

The study also corrected a misuse of the attribution number: EarleyBoyer's
84.54 cyc/event cannot be carried across to this host and concurrency
condition. Measured J-shape excess is ~60–61 cyc, of which the boundary explains
**26.8**; roughly **34 cyc remain outside the boundary** and are unlocated.

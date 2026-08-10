# RayTrace attribution — where the 0.565 score ratio comes from

Status: **attribution only**. No production source was changed. The measured
binary carried the working-tree `caller`/`arguments` atom-id gate edits
(`src/core/atom.zig`, `src/exec/call_runtime.zig`, `src/exec/object_ops.zig`,
`src/exec/property_ic.zig`); those touch neither RayTrace's hot route nor any
conclusion below.

Pinned references: QuickJS `04be2460`, javascript-zoo `a17d4e0a`, CPU 19
(Cortex-X925), explicit PMU `armv8_pmuv3_1`, exclusive host lock throughout.

## Headline

| measurement | value |
|---|---|
| Octane score (8 samples, ABBA) | zjs 1920.5 / qjs 3397.0 = **0.565** |
| fixed-work instructions | **1.7351x** |
| fixed-work cycles | **1.7674x** |
| fixed-work IPC | **0.9804** |
| bytecode operations executed | **1.0013x** |

Two facts frame everything else. IPC is at parity, so RayTrace is not stalled
on memory or branches — the gap is retired instruction *count*. And the two
engines execute the same bytecode to within 0.13%, so the count gap is not
extra work either. **The whole of RayTrace's gap is per-operation unit cost.**

The only structural opcode difference is that QuickJS emits `tail_call_method`
64,934 times (per 50M operations) where zjs emits `call_method` + `return`;
87 of 103 opcodes have identical counts and the rest differ by single digits.

## Method

- **Opcode census.** A QuickJS copy with a counter on the dispatch macro, and
  `zjs-profile --profile-opcodes`, both on the same deterministic source.
- **Per-opcode cycles for QuickJS.** QuickJS ships `OPCODE_ASM_LABEL`, which
  emits a global symbol at every opcode handler. That build measured −0.20%
  instructions and +0.49% cycles against stock, so it is a faithful proxy.
  `perf`'s own symbol resolution merges the overlapping `JS_CallInternal` and
  `label_OP_*` symbols inconsistently, so sample IPs were mapped to labels
  directly from `nm` instead of trusting `perf report`.
- **Bucketing.** `tools/perf/zoo/raytrace_bucket_attrib.py` puts every profiled
  symbol of both engines into one mechanism bucket, then scales bucket shares
  by each run's measured total cycles.
- **Independent pricing.** `tools/perf/callshapes` cases, control-subtracted,
  8 ABBA samples, used to confirm or refute each bucket-level claim.

Known method error: 4.28% of QuickJS's cycles land on `label_OP_*` regions
whose opcode never executes (1.819G of it on `OP_goto`, whose sibling
`goto8`/`goto16` tails GCC merged into that block). Every such case stays
inside the bucket it belongs to, so no bucket conclusion depends on it.

## Mechanism buckets (full work: qjs 51.31G cycles, zjs 90.29G, excess 38.98G)

| bucket | qjs G | zjs G | Δ G | z/q | % of excess |
|---|---:|---:|---:|---:|---:|
| call machinery (JS + native) | 8.05 | 22.21 | +14.17 | **2.76** | **36.3%** |
| property read | 13.19 | 19.96 | +6.78 | 1.51 | 17.4% |
| property write | 5.57 | 11.62 | +6.05 | 2.09 | 15.5% |
| arguments / apply | 2.27 | 8.06 | +5.79 | **3.56** | 14.9% |
| object teardown / refcount | 4.49 | 7.67 | +3.18 | 1.71 | 8.2% |
| locals / stack ops | 4.52 | 6.18 | +1.66 | 1.37 | 4.3% |
| arith / control ops | 4.12 | 5.61 | +1.49 | 1.36 | 3.8% |
| **object create + allocator** | **8.74** | **8.80** | **+0.06** | **1.01** | **0.2%** |

Count-normalised, using the event counts below:

| mechanism | qjs | zjs | per |
|---|---:|---:|---|
| call machinery | 45.9 | 126.7 cyc | call (JS frame or native) |
| property read | 22.3 | 33.8 cyc | field read |
| property write | 39.4 | 82.2 cyc | field write |
| arguments materialisation | 39.0 | 109.4 cyc | arguments object |
| apply forwarding | 17.7 | 92.2 cyc | apply |
| object create + allocator | 109.3 | 110.1 cyc | object |
| object teardown / refcount | 56.1 | 95.9 cyc | object |

`locals/stack` at 1.37x and `arith/control` at 1.36x reproduce the campaign's
generic 1.378x engine baseline independently. Everything above that line is
the actual finding; nothing is below it.

## Two results that refute natural priors

**Allocation is not RayTrace's problem.** Object creation plus the allocator
together are 1.01x — 110.1 versus 109.3 cycles per object across 79.9M
objects. zjs's allocator alone is *faster* than QuickJS's (0.77x); creation is
correspondingly more expensive, and the two net out. For a benchmark that
allocates two objects per constructor call, this closes the most obvious
hypothesis.

**Prototype shadowing is free.** RayTrace declares defaults on every prototype
(`Vector.prototype = {x:0, y:0, z:0}`) and then assigns the same names in
`initialize`, so almost every store shadows an inherited writable data
property. Pricing that directly (`L4p` − `L4`, both on the generic route) gives
**−5.2 cycles for zjs and −10.6 for QuickJS**: neither engine pays. The
`defineNewOwnDataPropertyForSimpleSetKnownNoOwn` prototype loop that mirrors
`JS_SetPropertyInternal`'s `break`-and-`add_property` is doing its job.

## What the gap actually is

`Class.create()` makes every RayTrace class a constructor of the form
`function () { this.initialize.apply(this, arguments); }`. Case `G` in the
call-shape suite is exactly that shape:

    G excess = 760.0 cycles/construct  x  39,956,520 constructs
             = 30.37G cycles = 78% of the measured 38.98G gap

Independently priced components of that 760 cycles:

| component | case | excess cyc |
|---|---|---:|
| generic construct route, empty body | `L0` | +160.3 |
| materialise mapped `arguments` | `E0` | +75.0 |
| `apply(arguments)` forwarding, net of `E0` | `D` − `E0` | +199.5 |
| prototype method lookup + inner call | `I` | +18.5 |
| two field stores on the generic route | from `L4` | ~+168 |
| composition / remainder | | ~+139 |

The remaining 22% of the gap is ordinary method calls (`I`, +18.5 cyc each over
roughly 55M non-constructor `call_method`s), teardown, and arithmetic; own
property reads and overwrites are a small credit (`H1` 0.82x, `H2` 0.89x).

## The construct fast path hides all of this from microbenchmarks

`constructSimpleFieldConstructor` recognises the `this.f = arg` bytecode
pattern and builds the instance without a frame at all. Its effect is large and
it is easy to measure it by accident:

| case | zjs cyc | qjs cyc | ratio |
|---|---:|---:|---:|
| `L3` `new Three(1,2,3)`, default prototype | 416.9 | 412.9 | **1.01** |
| `L4` same work, pattern disqualified | 828.3 | 415.7 | **1.99** |
| `L0` `new Empty()` | 316.6 | 156.2 | **2.03** |
| `G` RayTrace constructor | 1479.2 | 719.2 | **2.06** |

The fast path is worth 411.5 cycles per construct to zjs and 2.8 to QuickJS. A
differential profile of `L3` against `L3p` shows why the ratio moves so far:
in `L3`, `op_put_field`, `setValuePropertyWithThrow`, `setupInlineEntry`,
`pushConstructorCall`, `op_return_undef` and `FrameSlab.carve` all record
**zero** cycles. The whole frame and store path is skipped.

**RayTrace never takes this path** — its constructors call a prototype method
through `apply`, which is not the simple-field pattern. Any "constructors are
at parity" reading drawn from `F` (1.09x) or `L3` (1.01x) is an artifact of a
zjs-only fast path that the benchmark cannot reach. The representative numbers
are `L0`/`L4`/`G` at 2.0–2.1x.

## Event counts (QuickJS instrumentation, full work)

| event | count | note |
|---|---:|---|
| JS call frames | 128,956,245 | zjs `call_frames` counter agrees |
| native calls | 46,343,880 | **86% of them are `Function.prototype.apply`** |
| objects created | 79,938,000 | 2.00 per construct: instance + `arguments` |
| mapped `arguments` objects | 39,956,520 | one per construct |
| `build_arg_list` / `js_function_apply` | 39,956,520 each | one per construct |
| var refs created | 96,433,320 | 2.41 per `arguments` object |
| new own properties | 117,069,000 | 82.8% of all field writes |
| `JS_GetPropertyInternal` entries | 79,930,860 | 13.9% of field reads miss the inline path |

## Open, in priority order

1. **Call machinery, +80.8 cycles per call, 36.3% of the gap.** zjs spreads
   across `setupInlineEntry`, `pushExactSimpleFrame`, `pushConstructorCall`,
   `popConstructorReturn`, `deinitGeneralResources`, `runSyncInlineRouteMovedArgs`,
   `FrameSlab.carve`, `VmStackArena.carve` and `runTC` what QuickJS does in one
   `JS_CallInternal` prologue (8.46% of its total cycles) plus the `done:`
   epilogue. This is the documented explicit Frame/Stack state model, now with
   a RayTrace-specific price attached.
2. **Native call dispatch.** RayTrace makes 46.3M native calls, 40M of which
   are `apply`. Bucketed generously, zjs spends 4.22G there against QuickJS's
   0.50G in `js_call_c_function`. JS→JS entry has been optimised repeatedly;
   the native boundary has not.
3. **Property read at 1.51x is not reproduced by any read microbenchmark.**
   `H1` 0.82x, `M1` (prototype data) 0.84x, `M2` (four-deep chain) 0.87x, `M3`
   (two shapes at one site) 0.86x — zjs leads all of them, yet the bucket is
   1.51x with 7.5G in out-of-line helpers (`vm_property_field.field`,
   `getValueProperty`, `findProperty`, the `coldStd` read arm) against
   QuickJS's 1.37G in `JS_GetPropertyInternal`. Whatever drives RayTrace's
   reads out of line is unidentified and is the largest genuinely open
   question in this report.
4. **`arguments`/`apply` at 3.56x** remains the highest-ratio bucket, already
   the subject of the landed apply/arguments work.

## Artifacts

- `raytrace-fixed-pmu.json` — six-sample fixed-work PMU comparison.
- `raytrace-opcode-census-d1.json` — both engines' full-work opcode counts.
- `qjs-raytrace-opcode-event-counts.json` — QuickJS mechanism event counts.
- `raytrace-mechanism-buckets.json` — per-symbol cycles for both engines.
- `raytrace-callshapes.csv` — raw call-shape samples including the new cases.
- `tools/perf/zoo/raytrace_bucket_attrib.py` — the bucketing tool.
- `tools/perf/callshapes/cases/{L0,L3,L3p,L4,L4p,M1,M2,M3}*.js` — new cases.

# Zoo alignment outcome — mapped arguments and constant-pool dispatch

Status: **two QuickJS-alignment cuts implemented and validated; all 15 Zoo
benchmarks audited with fixed-work PMU; not committed or merged**.

Implementation base: `9bc0fb3ac07bf2066b44e7d795a7766d1b0f31ad`.
Branch/worktree: `perf/zoo-align-20260809` / `/home/aneryu/zjs-zoo-align-20260809`.

The production configuration throughout the performance campaign was:

```text
zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off
```

## Outcome

Two removable zjs-only mechanisms survived semantic and causal performance
checks:

1. mapped `arguments` construction allocated and filled a redundant root
   mirror beside the object-owned `VarRef` table;
2. `push_const` and `push_const8` published the VM and entered a noinline cold
   helper, while QuickJS performs the retained constant-pool load directly in
   its interpreter loop.

Both cuts remove work that QuickJS does not perform. Neither adds an opcode
fusion, object specialization, or other zjs-only fast path.

### Mapped-arguments root mirror

The useful cut was in mapped `arguments` materialization. zjs allocated a
second `[]*VarRef` solely to mirror the pointers already owned by the arguments
object, then pushed that mirror as a `CellSliceRoot`. The current collector
ignores the passed root chain in both `JSRuntime.pollGC` and
`Object.destroyRuntimeCyclesWithValueRoots`, so the mirror neither owned a
reference nor changed reachability. QuickJS's `js_build_mapped_arguments`
allocates only the object's `JSVarRef **tab`.

The candidate removes the mirror allocation, its per-element copies, and the
root push/pop. It retains the object's pointer table, every `captureArg` /
closed-var-ref ownership transition, partial-construction cleanup, and mapped
arguments semantics. This is an allocation-topology alignment with QuickJS,
not a zjs-only fast path.

Matched compiler-state microbenchmarks show the intended cohort and only that
cohort moving:

| call shape | instructions candidate/base, state X | state Y | cycles X | cycles Y |
|---|---:|---:|---:|---:|
| control loop | 1.00000 | 1.00000 | 0.99790 | 1.00436 |
| direct call | 1.00000 | 1.00000 | 0.99932 | 1.00133 |
| `apply` with a prebuilt array | 1.00000 | 1.00000 | 0.99985 | 1.00264 |
| `apply(arguments)` | **0.96435** | **0.96436** | **0.94740** | **0.93767** |
| zero-argument `arguments` | **0.98700** | **0.98698** | 0.99118 | 0.98971 |
| `arguments.length` | **0.95025** | **0.95025** | **0.91452** | **0.91426** |
| `arguments[0]` | **0.95388** | **0.95389** | **0.91748** | **0.92010** |
| four-argument `arguments` | **0.96124** | **0.96126** | **0.92837** | **0.92581** |
| simple constructor | 1.00107 | 1.00000 | 1.00083 | 1.00020 |
| RayTrace constructor composite | **0.98177** | **0.98180** | **0.97669** | **0.97485** |

The instruction reductions reproduce almost digit-for-digit in both Zig build
states. Direct calls, prebuilt-array `apply`, and a simple constructor are flat,
which rejects a generic code-layout explanation for the arguments cohort.

## Fresh Zoo baseline and mechanism map

The starting comparison was remeasured rather than copied from the prior
campaign. Four samples per engine, balanced leading position, exclusive host
lock, CPU 19. The schema-1 artifact stored the upper middle observation as its
`median`; this table reaggregates its raw samples with the corrected schema-2
definition, which averages the middle pair:

| benchmark | current HEAD / QuickJS score |
|---|---:|
| raytrace | 0.5523 |
| earley-boyer | 0.5986 |
| pdfjs | 0.7062 |
| typescript | 0.7286 |
| crypto | 0.7344 |
| splay | 0.7521 |
| box2d | 0.7715 |
| navier-stokes | 0.8262 |
| mandreel | 0.8293 |
| deltablue | 0.8349 |
| zlib | 0.8434 |
| gbemu | 0.8477 |
| richards | 0.8795 |
| code-load | 1.0863 |
| regexp | 1.1130 |
| **throughput geomean** | **0.79416** |

The ordinary Octane protocol runs for approximately one second, so a faster
engine performs more work. Raw whole-process PMU counters from that protocol
cannot attribute instruction or cycle gaps. `run_zoo_fixed_pmu.py` was added to
make temporary deterministic-work copies and collect explicit PMU events.

The final combined candidate's fixed-work result (four paired samples,
iteration divisor 16, CPU 19, `armv8_pmuv3_1`) was:

| benchmark | instructions zjs/qjs | cycles zjs/qjs | IPC zjs/qjs | wall zjs/qjs |
|---|---:|---:|---:|---:|
| box2d | 1.2252 | 1.2679 | 0.9666 | 1.2608 |
| code-load | 0.8358 | 0.8756 | 0.9544 | 0.8900 |
| crypto | 1.1368 | 1.3604 | 0.8349 | 1.3586 |
| deltablue | 1.4186 | 1.2248 | 1.1588 | 1.2241 |
| earley-boyer | 1.4749 | 1.6589 | 0.8893 | 1.6562 |
| gbemu | 1.1705 | 1.2186 | 0.9624 | 1.2103 |
| mandreel | 1.1343 | 1.1778 | 0.9620 | 1.1779 |
| navier-stokes | 1.1360 | 1.2024 | 0.9450 | 1.2076 |
| pdfjs | 1.1303 | 1.3063 | 0.8669 | 1.2997 |
| raytrace | 1.7479 | 1.7832 | 0.9793 | 1.7749 |
| regexp | 0.7789 | 0.8919 | 0.8734 | 0.8933 |
| richards | 1.2593 | 1.1379 | 1.1068 | 1.1383 |
| splay | 1.3898 | 1.3719 | 1.0129 | 1.3542 |
| typescript | 1.3224 | 1.1921 | 1.1097 | 1.1933 |
| zlib | 1.0745 | 1.1728 | 0.9170 | 1.1726 |

An unscaled two-sample RayTrace cross-check gave 1.7704 instructions and
1.8390 cycles, while divisor 16 gave the same mechanism and direction. The
scaled matrix is therefore useful for ranking, while the unscaled check guards
against changing the workload's dominant path.

This separates the current Zoo picture by mechanism:

1. **Already ahead in instructions:** CodeLoad and RegExp.
2. **Call/frame and field-dispatch structural cluster:** DeltaBlue, Richards,
   TypeScript, and Splay. Operation pricing and profiles bound these to the
   already-audited same-Machine call/frame model and distributed object
   lifecycle work.
3. **Arguments/apply overlay:** RayTrace and Earley-Boyer rise above that
   baseline; the call-shape matrix independently prices
   `apply(arguments)`/arguments access at 1.6–1.8x QuickJS.
4. **Nearer instruction parity, often IPC-bound:** Crypto, GBEMU, Mandreel,
   Navier-Stokes, PDF.js, and zlib retire 1.07–1.17x QuickJS's instructions;
   Crypto/PDF.js/zlib have materially larger cycle ratios.
5. **Box2D is mixed opcode cost:** property reads and floating arithmetic are
   prominent, but a profile exposed one concrete zjs-only constant-pool cold
   route. Removing it accounts for a small, exactly predicted part of Box2D;
   it does not close the benchmark's remaining 1.225x instruction ratio.

The root-mirror removal addresses one measured arguments component. It does not
erase the generic baseline or claim that the whole arguments/apply cluster is
closed.

## QuickJS and zjs ownership evidence

- QuickJS `quickjs.c:16215` (`js_build_mapped_arguments`) allocates one
  `JSVarRef **tab`, fills it with retained/open or closed var refs, and installs
  that table directly in the object.
- QuickJS `quickjs.c:16154`/`:16226` takes `ctx->array_proto_values` directly;
  there is no second root mirror.
- zjs `src/exec/object_ops.zig:createArgumentsObject` already stores the same
  cells in `Object.argumentsVarRefsMut()`. The removed storage copied pointers
  only; it never acquired another ref.
- zjs `src/core/runtime.zig:pollGC` and
  `src/core/object.zig:destroyRuntimeCyclesWithValueRoots` currently discard
  the `roots` parameter. Thus `CellSliceRoot` could not affect a collection in
  the current implementation.
- OOM injection and force-GC arguments tests cover failure during partial
  materialization and confirm the object-owned table still releases its
  initialized entries correctly.

The compile-time mapped/unmapped selection remains deliberately unchanged.
QuickJS chooses it while emitting `OP_special_object`; zjs must still reapply
effective strictness at runtime because its compile policy can make a
sloppy-parsed function runtime-strict. Removing that gate would be a semantic
shortcut, not alignment.

## Zig build-state control

The first source A/B looked excellent but was rejected: baseline normalized
signature `73e487c9...` and candidate `15e659c3...` were different compiler
states, with thousands of symbol bodies changing.

Four cold builds then isolated local cache, global cache, install prefix, and
`TMPDIR`:

| block | role | binary SHA-256 | normalized signature |
|---|---|---|---|
| X | baseline `b0` | `09be3010c038...` | `73e487c97d9e...` |
| Y | baseline `b2` | `f050e47f2587...` | `7d5aa1aff2c6...` |
| X | candidate `c0` | `336a5641be76...` | `7fa15ee81e75...` |
| Y | candidate `c1` | `bbbca5dcad31...` | `15e659c38261...` |

Within the baseline, X/Y changed 200 symbol sizes; within the candidate, X/Y
changed 201. The like-state source pairs changed only two symbol sizes
(`attachFunctionCaptures` and `specialObject`), whereas both crossed pairs
changed 202. This gives an unambiguous size-state pairing. Source-induced
layout movement changes many relative branch encodings, so the repository's
exact-body state classifier intentionally does not issue a cross-variant
`matched` verdict here. The result is therefore reported as two separate
state blocks, and acceptance requires direction and cohort selection to agree
in both. They do.

The durable comparison artifacts are `state-baseline-xy.json`,
`state-candidate-xy.json`, `state-pair-x.json`, `state-pair-y.json`, and the two
`state-cross-*.json` controls in this directory.

## Macro acceptance

State X ran the full 15-benchmark candidate/baseline matrix. Ratios are
candidate/baseline, higher is better. As above, these values are recomputed
from the schema-1 artifact's raw samples with the schema-2 median definition:

| benchmark | state X |
|---|---:|
| raytrace | **1.0220** |
| earley-boyer | **1.0064** |
| code-load | 1.0021 |
| typescript | 1.0020 |
| richards | 1.0010 |
| zlib | 1.0009 |
| gbemu | 1.0017 |
| mandreel | 1.0018 |
| deltablue | 1.0008 |
| splay | 0.9995 |
| crypto | 0.9994 |
| box2d | 1.0014 |
| navier-stokes | 0.9955 |
| pdfjs | 0.9960 |
| regexp | 0.9899 |
| **geomean** | **1.00134** |

State Y repeated the mechanism-bearing and most suspicious cases:

| benchmark | state Y |
|---|---:|
| raytrace | **1.0202** |
| pdfjs | 1.0055 |
| earley-boyer | 1.0017 |
| code-load | 1.0015 |
| typescript | 1.0016 |
| splay | 1.0005 |
| regexp | 0.9989 |
| **seven-case geomean** | **1.00423** |

RayTrace is the stable macro win. The apparent state-X PDF.js and RegExp
losses do not reproduce in state Y, so they are not attributed to the change.
Earley-Boyer is directionally positive but small enough to remain
noise-sensitive at the macro-score level.

Finally, a direct combined-candidate/QuickJS full Zoo run (not a multiplication
of two ratios) produced:

| benchmark | candidate / QuickJS |
|---|---:|
| raytrace | 0.5620 |
| earley-boyer | 0.5960 |
| pdfjs | 0.7034 |
| typescript | 0.7263 |
| crypto | 0.7363 |
| splay | 0.7507 |
| box2d | 0.7782 |
| mandreel | 0.8322 |
| navier-stokes | 0.8393 |
| deltablue | 0.8351 |
| gbemu | 0.8469 |
| zlib | 0.8497 |
| richards | 0.8766 |
| regexp | 1.0718 |
| code-load | 1.0806 |
| **throughput geomean** | **0.79390** |

With the same corrected aggregation, the current-HEAD raw samples give 0.79416
and the intermediate mapped-arguments-only samples give 0.79479. The final
independent run's 0.79390 is not a causal regression or win claim: cross-session
per-case deltas are dominated by macro-score spread. The matched-state and
fixed-work candidate/base matrices provide causal evidence. RayTrace's
mapped-arguments gain reproduces at +2.0–2.2% in both state blocks even though
its independent direct-score medians move within the benchmark's run-to-run
spread.

## Generic residual closeout

The fixed-work Splay/TypeScript residual was followed through rather than left
as an unspecified next campaign. The profiling build used the same production
configuration signature, with profiling counters enabled only for attribution;
all performance ratios still come from the frozen ReleaseFast production
binaries.

### TypeScript: fields are not the owner; ordinary calls are structural

The deterministic divisor-16 TypeScript run executed 307,813,820 opcodes,
including 53,583,551 `get_field`, 15,767,034 `get_field2`, 13,597,510
`put_field`, 13,117,437 `call_method`, and 10,772,841 pushed call frames.
The production binary retired 1.32285x QuickJS's instructions but only 1.18989x
its cycles.

Fresh control-subtracted operation pricing rejects the most visually prominent
flat-profile symbols as the generic owner:

| operation | instructions qjs → zjs | ratio | cycles qjs → zjs | ratio |
|---|---:|---:|---:|---:|
| loop/control iteration | 102.060 → 91.066 | **0.8923** | 18.552 → 15.321 | **0.8258** |
| own-property read | 119.103 → 125.104 | 1.0504 | 20.513 → 19.286 | **0.9402** |
| own-property write | 82.058 → 83.059 | 1.0122 | 10.879 → 10.600 | **0.9743** |
| direct exact leaf call | 290.171 → 346.219 | **1.1932** | 40.980 → 57.620 | **1.4061** |
| method call | 351.230 → 427.281 | **1.2165** | 56.691 → 74.983 | **1.3227** |
| prototype method call | 488.480 → 687.557 | **1.4075** | 110.542 → 134.090 | **1.2130** |

The method-specific increment (`method - direct`) is only about 20 extra zjs
instructions over QuickJS; most of the call gap already exists in the direct
same-Machine bytecode→bytecode frame/return path. That is not a new open
candidate. P3-08 through P5-01 already tested wrapper inlining, return
bookkeeping, completion classification, extended-tail outlining, frame layout,
and a native continuation boundary. The useful return cuts landed; outlining
was neutral/regressive; native continuation made `fib_rec` 24.8% worse. The
remaining direct-call delta is the documented explicit Frame/Stack state-model
constant, not evidence for reopening the rejected native-return ABI.

### Splay: same collector frequency and same cost distribution

The deterministic Splay run executed 38,573,726 opcodes, 1,210,095 call frames,
and 14,381,520 value frees. Two independent cycle profiles produced the
following grouped shares:

| group | QuickJS run 1 / 2 | zjs run 1 / 2 |
|---|---:|---:|
| RC/cycle trace and object teardown | 38.71% / 38.78% | 38.95% / 39.46% |
| small allocator | 9.50% / 9.32% | 9.06% / 8.58% |
| object/property publication | 8.18% / 8.08% | 9.20% / 9.94% |

Production-symbol entry counters on the same fixed source recorded exactly
**16** `JS_RunGC` calls in QuickJS and **16**
`destroyRuntimeCyclesWithValueRoots` calls in zjs. Thus Splay is not paying for
extra collection rounds. P7-00 separately proved that empty-arena churn and the
slab policy are shared with QuickJS, so allocator retention is also closed.

A focused 10,000,000-iteration `{a,b}` case, paired with an identical arithmetic
control and output-matched at `100000000000000`, priced the remaining two-field
object work at 1.2283x instructions and 1.1192x cycles. It is real, but it is a
distributed combination of creation, two property publications, two reads,
RC release, and the shared periodic cycle walk. The profile has no zjs-only
stage or excess event count to remove. Turning that aggregate into a new
object-literal specialization would be a QuickJS-absent fast path, not an
alignment fix.

### Box2D follow-up: constant-pool pushes were still cold

The full 15-benchmark pass added Box2D, DeltaBlue, and Richards opcode and
cycle profiles. DeltaBlue and Richards landed on the closed call/frame plus
field-dispatch mechanism. Box2D was different: arithmetic handlers were
visible, but a controlled floating-point matrix showed that every operation
case also added one `push_const8`. The profile made that confound explicit:
the fixed Box2D source executed 145,006,585 opcodes, including 148,739
`push_const8` operations. The selected integer counters, fixed-source hashes,
and two-run flat-profile shares are retained in
`zoo-residual-profile-supplement.json` rather than left only in `/tmp`.

Pinned QuickJS handles both constant opcodes directly:

```c
CASE(OP_push_const):
    *sp++ = JS_DupValue(ctx, b->cpool[get_u32(pc)]);
    pc += 4;
    BREAK;
CASE(OP_push_const8):
    *sp++ = JS_DupValue(ctx, b->cpool[*pc++]);
    BREAK;
```

zjs instead mapped both opcodes to `coldStd`, published `pc`/`sp`, and called
the noinline `vm_value.pushConst*` helper. The second production cut adds
register-resident handlers that duplicate the constant, advance `sp` and `pc`,
and tail-dispatch. An out-of-range synthetic operand or an armed generator/eval
stop boundary still enters the unchanged publishing cold path.

The X-state micro A/B used one frozen baseline binary and two independent
candidate builds whose normalized symbol identities were identical
(`8a0c8c75fe4d...`). The two candidate SHA-256 values were
`b8cff1113f5f...` and `cc7119bf9b31...`; both reported the production
configuration signature. Relative to frozen X baseline `c0`, no shared symbol
changed size and the candidate added only the two intended handler symbols;
the Y baseline differs in 151 shared symbol sizes. Fresh baseline rebuilds
reproducibly landed in Zig's Y state, so this cut does not claim two independent
X-state baseline builds. That limitation is recorded instead of mixing X and Y
binaries.

| case | instructions candidate/base | cycles candidate/base |
|---|---:|---:|
| repeated `push_const8` | **0.68703** | **0.56246** |
| loop without constant-pool push | 1.00002 | 1.00858 |
| floating add plus `push_const8` | **0.85646** | **0.79319** |
| floating subtract plus `push_const8` | **0.84802** | **0.73185** |
| floating multiply plus `push_const8` | **0.84802** | **0.73367** |

The isolated case removes about 57 retired instructions per constant push.
Multiplying that by Box2D's 148,739 hits predicts 8.48 million removed
instructions, or 0.128% of the baseline run. The observed fixed-work Box2D
change was 0.99875 candidate/base, a 0.125% reduction. That count agreement,
plus the instruction-flat control, ties the real-work movement to the intended
opcode route rather than general code layout.

The full 15-benchmark candidate/base fixed-work run found no material
instruction regression and had a 0.99905 unweighted geomean. The largest
reductions were Navier-Stokes 0.9937, RegExp 0.9972, Splay 0.9983, Box2D
0.9987, and PDF.js 0.9991. Seven more cases were 0.99945–0.99998. Richards
was 1.0000001, DeltaBlue 1.0000385, and Crypto 1.0000399: at most +0.004%,
not literal zeros hidden by four-decimal rounding. Cycles were noisier, but
their full-matrix geomean was 0.99669, and the final direct candidate/QuickJS
fixed-work run reproduced every residual cluster in the table above.

### Stop decision

The second pass closes the phrase “generic 1.32–1.39x baseline” into explicit
mechanism boundaries:

- TypeScript's property read/write legs are at or ahead of QuickJS in cycles;
  its visible remaining call cost is the already-audited Frame/Stack model.
- Splay runs the same number of cycle collections, with nearly identical GC and
  allocator profile shares; its residual is spread over shared object-state
  operations rather than one extra mechanism.
- The mapped-arguments root mirror is the only newly identified removable
  allocation with a product-level win.
- The constant-pool cold route is a second QuickJS mismatch with exact
  micro-to-Box2D instruction accounting and a 0.99905 full-Zoo instruction
  geomean; three near-zero cases move upward by at most 0.004%. Its product
  effect is deliberately described as small.

No third production cut is justified by the evidence. A future reopening
requires either a new flat/current QuickJS mismatch with a separately priced
stage, or a deliberate structure-level Frame/Object representation project;
neither may be disguised as another local fast path.

## Rejected or non-attribution artifacts

- `zoo-current-pmu.json` measured PMU counters under Octane's ordinary
  one-second throughput protocol. The engines performed different work, so it
  must not be used for instruction attribution. It motivated the fixed-work
  runner and is retained only as a rejected diagnostic.
- `mapped-arguments-root-ab.json` compared independently built binaries in
  different Zig compiler states. Its attractive numbers are invalid as a
  source-treatment estimate.
- Historical `zjs-zoo-compare` schema-1 artifacts selected the upper middle
  observation while labeling it `median`. Their stored summaries are not used
  against schema 2; the report's historical numbers are reaggregated from the
  retained raw samples by averaging the middle pair.
- The first `checkpoint-check` invocation failed because this new worktree had
  not initialized `test262/`: 15 smoke files and two unified-test fixtures were
  `FileNotFound`, and the runner aborted during thread cleanup. After checking
  out the pinned submodule commit `42496613...`, the complete gate was rerun and
  passed. The failed run is environmental evidence, not a green gate.

## Validation

| gate | result |
|---|---|
| `zig build test-exec --seed 0 --summary all` | 409 passed |
| `zig build test-bytecode --seed 0 --summary all` | 69 passed |
| `mise run quick-check` | 2 passed / 1 skipped |
| force-GC filtered mapped-arguments tests | 7 passed |
| force-GC filtered arguments tests | 20 passed |
| full force-GC `test-exec` diagnostic | 407 passed, 2 expected-count assertions incompatible with force-on-allocation; not counted as a green gate |
| `zig build test-oom --seed 0 --summary all` | 21 passed |
| `mise run checkpoint-check` after submodule init | 34/34 steps; unified 2151 passed / 1 skipped; test262 smoke 15/15 |
| `run-test262 -d test262/test/language/arguments-object` | 263/263 |
| `zig build test262-gate --seed 0 --summary all` | 0/49,775 errors; 44,581 executed passed |
| `zig build test -Doptimize=ReleaseSafe --seed 0 --summary all` | 2151 passed / 1 skipped / 0 failed |
| `python3 -m unittest discover -s tools/perf/verify -p 'test_*.py'` | 66 passed |

## Residual boundary and reopen conditions

The mapped-arguments cut removes 3.6–5.0% of the instructions in
arguments-heavy microbenchmarks and about 1.8% in the RayTrace constructor
composite. The constant-pool cut removes 31.3% of instructions in its isolated
opcode case, but its lower product frequency makes the full-Zoo effect much
smaller. The final direct Zoo geomean is 0.79390; RayTrace remains 0.5620 of
QuickJS in that independent run.

The remaining arguments costs (template/prototype lookup, generic object
construction, runtime strictness reconciliation, and apply forwarding) are
distributed; no evidence from this campaign justifies a new QuickJS-absent
fast path or removal of the runtime strictness gate. The generic Splay and
TypeScript residuals are now bounded above rather than left unattributed; see
the closeout section and `zoo-generic-residual-audit.json`.

## Primary artifacts

- `zoo-current-head.json`: fresh current-HEAD / pinned-QuickJS full Zoo raw
  samples (schema 1; reaggregated in this report with the schema-2 median).
- `zoo-current-fixed-pmu.json`: fixed-work mechanism matrix.
- `zoo-current-callshapes.json`: current call-shape pricing against QuickJS.
- `zoo-candidate-fixed-pmu-all.json`: mapped-arguments candidate / QuickJS
  fixed-work PMU across all 15 benchmarks.
- `mapped-arguments-root-matched-state-ab.json`: four-binary two-state PMU A/B.
- `zoo-matched-state-x-ab.json`: full candidate/baseline macro A/B.
- `zoo-matched-state-y-key-ab.json`: second-state key-case macro A/B.
- `zoo-candidate-vs-qjs-state-x.json`: intermediate mapped-arguments-only
  candidate/QuickJS full Zoo raw samples (schema 1; reaggregated here).
- `zoo-push-const-hot-route-pmu.json`: constant-push micro and control PMU A/B.
- `zoo-push-const-hot-route-fixed-pmu-all-ab.json`: combined candidate versus
  mapped-arguments-only candidate across all 15 fixed-work benchmarks.
- `zoo-push-const-candidate-vs-qjs.json`: final combined candidate / QuickJS
  full Zoo throughput run using the corrected schema-2 median.
- `zoo-final-fixed-pmu-all.json`: final combined candidate / QuickJS fixed-work
  PMU across all 15 benchmarks.
- `zoo-generic-operation-pricing.json`: property/method operation pricing.
- `zoo-method-vs-direct-pricing.json`: direct-call versus method-call split.
- `zoo-generic-residual-audit.json`: Splay/TypeScript opcode, profile, GC-count,
  object-control, and closed-mechanism evidence.
- `zoo-residual-profile-supplement.json`: durable Box2D/DeltaBlue/Richards
  opcode counts, fixed-source hashes, flat-profile shares, and float-confound
  opcode deltas.
- `cases/splay-object2*.js`: output-matched object-lifecycle case and arithmetic
  control used by the residual audit.
- `cases/push-const8.js` and `cases/float-*.js`: constant-pool isolation,
  float-operation confound, and instruction-flat control cases.

Pinned reference identities:

- QuickJS commit `04be246001599f5995fa2f2d8c91a0f198d3f34c`, binary SHA-256
  `b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d`.
- javascript-zoo commit `a17d4e0aabe52719fab1074f4b566d16d08a563c`.
- Linux `6.17.0-1014-nvidia`, CPU 19 (Cortex-X925), explicit PMU
  `armv8_pmuv3_1` for counter runs.

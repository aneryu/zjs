# Campaign outcome — four knives landed, zoo geomean 0.7474 → 0.7931

Start: `b15ae407` (attribution baseline) / `fedf852a` (implementation base).
End: `5409bd0d`. `PLAN.md` holds the original design; this file records what
actually happened, including the parts that failed.

## Landed

| commit | mechanism | pricing |
|---|---|---|
| `fca56118` | `Array.prototype.splice` dense fast-array arm (qjs:43040) | 1175.9 → 2.98 insn per shifted element (394x) |
| `de612c76` | flat string equality in the eq family (qjs:20321) | ~1.0M cold-handler exits per pdfjs run removed |
| `949bd75f` | rope linearization at the index-read boundary (qjs:13597) | 289k charCodeAt calls stop re-descending the tree |
| `72f498e4` | dense in-range element write inlined (qjs:19552) | 151.1 → 121.1 insn/write |
| `5409bd0d` | `op_put_array_el` prologue-free hot arm (qjs:19552) | 121.1 → 107.1 insn/write; handler 271 → 60 insn |

zoo, 4 samples, pinned CPU 19, exclusive host lock:

| benchmark | before | after |
|---|---|---|
| pdfjs | 0.464 | **0.706** |
| navier-stokes | 0.713 | **0.820** |
| richards | 0.799 | **0.878** |
| deltablue | 0.795 | 0.834 |
| zlib | 0.830 | 0.858 |
| mandreel | 0.815 | 0.840 |
| box2d | 0.744 | 0.771 |
| splay | 0.745 | 0.755 |
| typescript | 0.716 | 0.729 |
| earley-boyer | 0.578 | 0.598 |
| raytrace | 0.517 | 0.545 |
| gbemu | 0.849 | 0.855 |
| code-load | 1.084 | 1.080 |
| regexp | 1.121 | 1.097 |
| **geomean** | **0.7474** | **0.7931** |

Gates on every knife: test262 0/49775, force-GC build, OOM 21/21, Debug build,
test-core/exec/builtins/parser/bytecode/runtime, architecture-check, smoke, and
a per-knife semantics fixture diffed against qjs.

## Operation pricing table (post-landing)

`tools/perf/callshapes`, 8 samples, ABBA, pinned. Ratio is zjs/qjs cycles per
operation, startup- and control-subtracted.

| shape | cyc ratio | note |
|---|---|---|
| `ctrl` empty loop | 0.83 | zjs ahead |
| H1 `o.x` | 0.89 | zjs ahead |
| H2 `o.x = v` | 0.90 | zjs ahead |
| K1 `array.length` | 0.96 | zjs ahead |
| K2 `plainobj.length` | 1.06 | |
| F `new Pair(1,2)` | 1.09 | |
| A2 `s += f(1,2)` | 1.15 | |
| I `o.method()` | 1.16 | |
| B `o.f(1,2)` | 1.20 | |
| A `f(1,2)` | 1.23 | |
| E0 arguments (0 args) | 1.41 | pure materialization shell |
| C `f.apply(o,[1,2])` | 1.47 | |
| C2 `f.apply(o,args)` | 1.55 | |
| E1 `arguments.length` | 1.63 | |
| D `f.apply(o,arguments)` | 1.75 | |
| E2 `arguments[0]` | 1.77 | |
| E4 arguments (4 args) | 1.79 | |
| J `instanceof` | 1.80 | |
| **G RayTrace ctor** | **2.14** | composite of E+D+F+I |

Property read/write and `.length` now BEAT qjs. Every remaining shape above
1.4x is in the arguments/apply cluster, and `G` is their composite.

Other operations priced this campaign (control-subtracted microbenchmarks):

| operation | zjs | qjs | ratio |
|---|---|---|---|
| own-property read (monomorphic hit) | 54.0 | 52.0 | 1.04x |
| dense array element read | 67.1 | 59.3 | 1.13x |
| object construction `new Pair(a,b)` | 2075.8 | 1727.6 | 1.20x |
| dense in-range element write | 107.1 | 64.0 | **1.67x** |
| `instanceof` (hit) | 813.4 | 469.2 | 1.73x |

## What failed, and why it matters

Three attempts were killed by measurement after looking correct on paper.

**instanceof shell comptime split — +6.4% regression, reverted.**
`inOrInstanceof` carried both `in` and `instanceof` in one 1218-instruction body
with a runtime `opc` test and a 304-byte frame. Making `opc` comptime split it
into 916 + 327 instructions as intended — and instanceof got *slower*
(813.4 → 865.5 insn/op) because its specialization's frame grew to 384 bytes.
LLVM allocated worse for the dedicated function than for the shared one.

**`specialObject` split — no effect, reverted.**
One body served six `OP_special_object` subtypes (1669 instructions) where qjs
has independent switch arms. Moving the five rare subtypes out halved it to 829
static instructions and changed the dynamic count by 0.5% (E0 1691 → 1682).
The moved code never executed on the hot path.

**Static size is not dynamic cost, and function-boundary changes are not
directionally safe.** The two knives that worked were *subtractive* (remove a
call, remove a frame); both that failed were *additive* (create a function,
split a body). This is the same lesson as the existing "热臂绝不共享" rule but
with the opposite sign: sharing is not automatically bad — what costs is code
the hot path actually executes, or a frame it actually pays.

## Refuted attributions (do not re-litigate)

Each of these looked like a real divergence from the profile or the source and
was killed by counting:

- **shape transition cache.** zjs's `findHashedShapeProperty` requires
  `prop_size == property_capacity` where qjs (quickjs.c:9211-9218) accepts a
  mismatch and reallocs. Looked like a systematic cache-miss bug. Measured miss
  counts: zjs 263,817 vs qjs 263,775 (0.02% apart). The extra term costs nothing
  in practice.
- **instanceof at 16x.** The profile shows zjs's three instanceof functions at
  312.0 Mcyc against qjs's `JS_OrdinaryIsInstanceOf` at 19.5 Mcyc. But
  `JS_IsInstanceOf` (quickjs.c:8139) reads `Symbol.hasInstance` on every call and
  that read lands in `JS_GetPropertyInternal`, not in the function being
  compared. Microbenchmark: 1.73x.
- **object construction at 4.51x.** Same trap; qjs's construction cost is inlined
  into `JS_CallInternal`. Microbenchmark: 1.20x.
- **`op_get_field` as boyer's bottleneck.** It is zjs's largest boyer symbol
  (347.9 Mcyc) but own-property reads price at 1.04x — boyer simply reads a lot.
- **float-specific dense write cost.** int and float write price identically
  (151.1 insn both), so the gap was never in value boxing.

Rule: **qjs is a monolithic interpreter, so "zjs's out-of-line function vs qjs's
function" systematically overstates.** Only a control-subtracted microbenchmark
is comparable. This trap fired three times in one campaign.

## Operation counts match qjs exactly

Wherever it was checked, zjs performs the same number of operations as qjs; the
gaps are per-operation cost, never complexity or count:

| operation | zjs | qjs |
|---|---|---|
| property adds (raytrace) | 391,423 | 391,374 |
| shape-cache misses (raytrace) | 263,817 | 263,775 |
| shape clones (raytrace) | 8,756 | 8,692 |
| arguments materializations (raytrace) | 133,190 | 133,190 |
| apply forwards (raytrace) | 133,190 | 133,190 |
| instanceof (boyer) | 491,887 | 491,887 |
| object constructions (boyer) | 258,564 | 258,564 |

## Remaining picture

**pdfjs was the only benchmark with a structural single point** (a builtin
missing its fast arm entirely). raytrace and earley-boyer were both fully
attributed and neither has one:

- raytrace: three paths at 1.5–4.3x, all with matching operation counts. `gap =
  1.841x = insn 1.767x × IPC 1.042x` — almost pure instruction count, no
  outlining-induced stall signature.
- boyer: `instanceof` is 41.5% of its instruction gap, but only because it is
  25.8% of all instructions at 1.73x. Root cause is generic native-call dispatch
  (2.41x), i.e. knife D, which pdfjs pricing already deferred as having no
  single faithful cut. The one large win available — caching `Symbol.hasInstance`
  identity to skip the native call — is something **qjs does not do**, so it is
  not faithful alignment.

The arguments/apply cluster is the only remaining group above 1.4x. E0, the
pure materialization shell with zero arguments, is already 1.59x insn (625
insn/op behind `js_build_mapped_arguments`'s 157-instruction body), and the
excess is spread across: a runtime mapped/strict re-decision that qjs settles at
emit time (quickjs.c:34864), template + iterator lookups, the generic
`createFromShape` path, and a `CellSliceRoot` push/pop that runs even at zero
arguments. No single owner.

Known but unpriced: mapped arguments materialization does **two** heap
allocations to qjs's one (the extra `argument_root_storage` is a GC-rooting
mirror). Whether it can go depends on zjs GC reachability semantics for an
object held only by a Zig local mid-loop — not decidable by reading.

## Second sweep: six consecutive misses, and what they establish

After the knives landed, a further sweep looked for more single points. It
found none. Recording it so the same six doors are not reopened.

**splay (0.755) — diffuse.** `cycles 1.311x = insn 1.378x × IPC 0.952`; zjs's
IPC is *better*. GC marking is 423.7 vs 384.4 Mcyc = 1.10x, i.e. near parity
despite `traceChildren` being zjs's top two symbols at 25.85% combined.

**typescript (0.729) — diffuse.** `cycles 1.355x = insn 1.378x × IPC 0.984`.
The profile is all base opcodes; the largest, `op_get_field` at 19.19%, prices
at 1.04x — typescript simply reads a lot of properties.

**glibc heap trim — refuted.** `strace -c` shows zjs spending 6.08x the time in
`brk` (19 vs 4 usec/call) on splay, which looks like a zjs-specific allocator
pathology. Disabling trim (`MALLOC_TRIM_THRESHOLD_`) helps **both** engines
(zjs −7.2%, qjs −5.6%) and moves the ratio only 1.397 → 1.374. It is generic
glibc behaviour, and qjs sets no `mallopt`, so matching it would not be faithful.

**`argumentsPropertyTemplate`'s context re-lookup — refuted.**
`createArgumentsObject` takes `ctx` as its first parameter, then calls
`argumentsPropertyTemplate(ctx.runtime, global, …)`, which opens with
`rt.contextForGlobal(global)` — a linear walk of the realm list to recover the
context the caller already held. Passing `ctx` through changed nothing
(+1.7 insn, inside noise): the realm list holds one entry, so the walk hits on
the first iteration and the added identity test costs what it saves.

### The engine-level baseline

Lining up every measured benchmark's instruction ratio:

| benchmark | insn ratio | |
|---|---|---|
| pdfjs (post-fix) | 1.229 | typed-array heavy, a zjs strength |
| boyer | 1.357 | |
| **splay** | **1.378** | |
| **typescript** | **1.378** | |
| earley | 1.602 | arguments-heavy |
| raytrace | 1.767 | arguments/apply-heaviest |

splay and typescript land on the *same* ratio. That is the engine's uniform
per-opcode baseline; everything above it is arguments/apply density and the one
below it is typed-array density. **The residual gap belongs to no mechanism** —
which is why no further single point exists to find.

### Differential-build pricing (the method that did work)

Deleting a step, rebuilding, and differencing instruction counts is the only
technique in this campaign that located cost reliably. Applied to
`createArgumentsObject`:

- Replacing `arrayPrototypeValuesFromGlobal(...)` with `undefined` (safe for E0,
  which reads only `.length`): **43 insn per materialization, 6.9% of the 627
  insn gap**. Mechanism: it goes through `cachedRealmValue` →
  `contextForGlobalIncludingConstructing`, which walks *two* realm lists, then
  `.dup()`s, while the call site `defer`s a `free` and `createFromShape` dups
  again — **2 dups + 1 free where qjs does one `JS_DupValue(ctx,
  ctx->array_proto_values)`**. Worth ~40 insn, i.e. 0.74% of raytrace. Not cut.

The same run re-confirmed that **stub/shim pricing is unsound**: stubbing
`createArgumentsObject` to return a plain object made E0 26% *slower*, because
`arguments.length` then fell into the property-miss path. A diagnostic must not
perturb what the benchmark does downstream.

**Conclusion of the sweep: the arguments cluster's 627 insn/op is spread across
a dozen items whose largest is 6.9%.** There is nothing left worth a knife at
this granularity; lowering the 1.378x baseline means trimming individual opcode
handlers, one at a time, the way the dense-write pair did.

## The frame boundary: why `op_get_array_el` cannot take the dense-write cure

Applying the dense-write treatment to `op_get_array_el` **worked technically and
was still rejected**. Recording it in full, because the reason generalizes.

### It worked

`op_get_field` is the template, and its comment explains the trick that matters:

```zig
_ = value.dup();   // discard the result
```
> "discarding the result keeps the pushed value a single SSA scalar instead of a
> two-arm join that LLVM would park in a stack slot"

`op_get_array_el` was using `fastArrayElementDup`, which returns `?JSValue` *and*
returns the duped value — precisely that two-arm join. Rewriting the hot arm in
`op_get_field`'s shape (integer-pair slot read, discarded `dup()`, receiver
destroy routed to a tail) and moving every other leg to a cold twin gave:

- handler **191 → 50 instructions, prologue gone**
- dense read **67.14 → 62.12 insn (−7.5%)**, **1.133x → 1.048x** vs qjs
- all gates green; semantics fixture (holes, prototype getters, typed arrays,
  `arguments`, sparse, rc==1 receiver) matches qjs item for item

### And zoo rejected it

8 samples, pinned:

| | baseline | after |
|---|---|---|
| navier-stokes | 0.807 | **0.845** (+4.7%) |
| mandreel | 0.840 | 0.809 (−3.7%) |
| zlib | 0.858 | 0.831 (−3.1%) |
| gbemu | 0.855 | 0.835 (−2.3%) |

Geomean −0.25%. Rejected on the same rule that killed the −0.199% write arm.

### A refuted intermediate hypothesis

The cold twin initially repeated the dense probe (`fastDenseArrayElementValue`),
whose test is *identical* to the one the hot arm just failed — so every typed
read paid a guaranteed second miss. Removing it recovered only 0.3–0.6%; the
regressions stayed. **That was not the cause.**

### The structural finding

The cause is the indirect tail itself. Typed-array reads now go through
`vm.property_tail_tbl` (table load + `br x`) where they used to be sequential
compares inside one function; qjs reaches its own out-of-line leg with a direct
`bl` and no table.

And that indirection **is the precondition for the frame disappearing**:

- direct `always_tail` to the twin → LLVM inlines it back (measured: 338
  instructions, the 144-byte frame returns)
- `noinline` on the twin → breaks the `musttail` transfers inside it
- only the `property_tail_tbl` load is a boundary LLVM will not cross

So on this handler, **"no prologue" and "fast typed-array arm" are mutually
exclusive**. The dense-*write* knife escaped the trade because its slow legs
(`setValuePropertyWithThrow`, the typed writer) already lived behind noinline
helpers — moving them out added no hop. The dense-*read* handler had its typed
arm inlined in the hot body, so extracting it necessarily costs a hop.

This is the mechanism under the older observation that "the same correct logic
in three positions gives three results" — it is not a tuning problem but an
artifact of zjs's sequential class chain versus qjs's `switch (p->class_id)`
(quickjs.c:9959). The real fix is that O(1) dispatch, but note it would put a
jump-table indirect on the **dense hit** too, which is the hottest case and the
one currently paying nothing — so it could equally give the navier win back and
take the mandreel loss. Not attempted.

**Practical rule for future handlers: before extracting a hot arm, check where
the slow legs already live. If they are inlined in the hot body, extraction buys
a prologue but sells a hop, and the trade is decided by how hot the extracted
legs are.**

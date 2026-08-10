# Tranche-5 outcome — wall-demolition knives landed on main

Merged: `1cc8d275`. Causal baseline: frozen T3 binary `/tmp/zjs-rt-t3`.
T5 snapshot: `/tmp/zjs-rt-t5`. Diagnosis behind these knives: the four-track
walls campaign (workflow `wf_fb84bf97-d85`) that refuted the
incomplete-tailcall-threading hypothesis and exposed concentrated targets;
see `walls-demolished` memory and the workflow journals.

## Knives

| knife | commit | isolated result |
|---|---|---|
| K1 hot handlers for `OP_lnot` + long-form `OP_if_false` (were cold-routed at 91 insn/20.6 cyc; qjs:19092/18859) | `09f4d457` | lnot 20.6→**1.86 cyc** (qjs 2.77 — now ahead); rt-fixed −1.46%, earley-boyer −1.35% |
| K2 define_field fast leg opened to refcounted values (deletes the `requiresRefCount` gate, qjs:19269 has none) with the three load-bearing fixes: borrow-until-commit append (OOM-safe), duplicate-key replace ref accounting (`({a:o1,a:o2})` leak), assert contract | `8e1f2e18` | **splay-fixed −13.9% cycles**, S1 literal micro at qjs parity (0.99), all 28 other cases flat |
| K3 gc.phase deinit gate mirrored as a Vm-resident byte (kills the vm→ctx→rt→phase 3-load chain hoisted into every releasing handler; qjs `JS_FreeValue` has no phase check) | `643afaec` | rt-fixed neutral (insn −0.18%), splay −0.54% (~2σ); kept on mechanism faithfulness |
| K4 dying return Entry read through `vm.frame` (parallel load) instead of the `vm.frame_stack→machine.top` serial chain; identity vm.frame==machine.top pre-audited with a ReleaseSafe assertion build over full test262 | `f0ab84b7` | A-case 0.99 (−0.8 cyc/call, in predicted band); rt-fixed −0.27% |

Integration conflict note: K1 rewrote the `op_if_false8` tail region that K3
also edited; resolved by keeping K1's structure and routing all of K1's new
hot-arm frees through K3's `freeWithDeinitMirror`.

## Integrated results

| measurement | campaign start | after T3 | after T5 |
|---|---:|---:|---:|
| RayTrace score vs qjs | 0.565 | 0.679 | **0.705** |
| rt-fixed-d64 cycles vs qjs | 1.766x | 1.461x | **1.431x** |
| splay score vs qjs | 0.752 (08-09) | 0.764 | **0.933** |
| earley-boyer score vs qjs | 0.599 (08-09) | 0.603 | **0.636** |

Causal A/B (T5 vs frozen T3, full 15, 8 samples, same session): **geomean
1.0357, zero regressions** — splay **+21.4%**, crypto +6.0%, gbemu +4.6%,
mandreel +4.6%, box2d +4.0%, raytrace +3.8%, pdfjs +3.3%, typescript +1.9%.
The refcounted-literal fast leg pays across the whole suite, exactly as the
splay-bisect predicted (`{k:refcounted}` literals are ubiquitous).

## Gates

- `test-exec` 414, `test-bytecode` 69, unified Debug **2161**/1/0,
  ReleaseSafe **2161**/1/0, `test-oom` 21
- `test262-gate` **0/49,775, 44,581 passed** — fourth consecutive bit-identical run
- K4's identity audit: ReleaseSafe assertion build (vm.frame==machine.top per
  return) over full test262 + async/generator slices, all green before the knife

## Day total (T1+T3+T5, all landed 2026-08-10)

20 knives across five workflows: RayTrace 0.565→**0.705** (+24.8%), splay
0.752→**0.933**, cycles vs qjs 1.766→**1.431x**. Every knife causally A/B'd
against a frozen same-session baseline; three integration rounds each passed
the full gate battery with bit-identical test262 results.

## Next queue

**Superseded by the tranche-6 diagnosis below.** Items 1–4 of the original queue
(read generic route, simple-ctor fixed cost, `op_get_var`, object-create bucket
chains) were all re-measured with counter builds and either dissolved or
re-sized; the corrected queue is:

1. New-property cold write chain — 1.9x, Δ≈5.2G ≈ 25% of the remaining gap.
   zjs pays ~83 cyc per cold write against QuickJS's ~42: a `coldStd` publish
   shell, then `field()` re-decoding the atom and re-probing, then
   `appendPreparedPropertyEntry` at 19.1 cyc against `add_shape_property`'s 5.8.
   QuickJS's `OP_put_field` slow leg is one in-frame `JS_SetPropertyInternal`
   call (qjs:19188) with no shell and no re-decode.
2. Shape clone unit cost — 30.5 vs 10.1 cyc. Bucket-chain length was falsified
   (both engines walk identically, to the probe); the difference is
   `js_clone_shape`'s single FAM memcpy (qjs:5268) against
   `createWithFam` + memsets + per-prop copy + per-prop link.
3. `appendPreparedPropertyEntry`'s internals — the second half of the write gap
   (~26M cyc/run) is unattributed; needs `tryCachedTransition` hit/miss counters
   before it can be priced.
4. `createArgumentsObject` at ~3.1x (Δ≈29M cyc/run), still inside the
   arguments/apply cluster.
5. Call-boundary state coupling (C-track ledger): reduce the ~14 vm.* rewrites
   per call boundary; return-chain probe (K4) validated the chain-depth lever.

## Tranche 7 — started, not landed

A T6 diagnosis round (workflow `wf_ee3e0057-2d2`) re-attributed the residuals and
overturned three earlier numbers; see the `t6-misattribution-corrections` note.
Its headline: the "property-read generic route 4.21x / ~6G" does not exist —
counter builds recorded **69 read exits out of 9.57M reads**, and the symbols
that had been bucketed as read cost (`vm_property_field.field` and its cold
shell) are the shared cold body's **put_field arm**. The real block hiding under
that label is the new-property cold write chain: 1.9x, Δ≈5.2G ≈ 25% of the
remaining gap.

Tranche 7 was launched to act on that (put_field resident add-tail, shape clone
memcpy, get_var base mirror plus riders) but all three implementation agents
halted mid-flight on exhausted credits. Their partial work is preserved as
explicitly-labelled WIP commits — **none of it is gated, measured, or merged**:

| branch | head | state |
|---|---|---|
| `worktree-wf_7d4083ad-cea-1` | `28d19814` | put_field resident add-tail, partial; no build/test/measurement |
| `worktree-wf_7d4083ad-cea-2` | `873ce066` | shape clone memcpy + probe-first rider; reset-ordering hazard unverified |
| `worktree-wf_7d4083ad-cea-3` | `9fc2cdfe` | empty-ctor fast path over an ungated get_var base-mirror commit |

`main` is unaffected and remains the fully gated tranche-5 tree.

### Resuming

Task books for all three live in the workflow script
`.claude/.../workflows/scripts/residual-t7-implement-wf_7d4083ad-cea.js`, with
the adversarial-review conditions already folded in. Priority order by measured
budget: put_field add-tail (pre-registered line 15–30M cyc/run, ceiling 48M) >
shape clone memcpy (splay object-create, −0.06..0.09G, the round's only
unconditional GO) > the get_var/empty-ctor riders (both need zoo-wide
adjudication before they earn a verdict; the get_var prototype showed a
RayTrace +1.04% seam tax that must be treated as mechanism, not layout noise).

**One tranche-7 measurement survives** and it de-risks the largest knife. The
add-tail's stub differential (a resident tail slot that immediately re-tails to
the cold twin, isolating the pure routing change) was built and measured on
rt-fixed-d64, 4 interleaved pairs, before that agent halted:

| | base | stub | delta |
|---|---:|---:|---:|
| cycles | 1,210,585,277 | 1,211,716,100 | **+1,130,823 (+0.093%)** |
| instructions | 5,608,604,402 | 5,613,567,524 | +4,963,122 (+0.088%) |

So the extra dispatch hop costs about +0.58 cyc per cold write — the routing
itself is very nearly free against a 15–30M target. The knife's viability
therefore rests entirely on whether deleting the `coldStd` publish shell, the
atom re-decode and the re-probe delivers the projected saving; the structural
change it needs to make is not itself expensive. Recovered from the agent
transcript in `subagents/workflows/wf_7d4083ad-cea/agent-af9e493d8f*.jsonl`.

## Reproducing the frozen baselines

Every A/B in this campaign was judged against a frozen binary rather than a
path a later build could overwrite. Those copies live in `/tmp` and do not
survive a reboot; rebuild them from their commits when a later tranche needs
the same comparison:

| snapshot | commit | role |
|---|---|---|
| `/tmp/zjs-rt-baseline` | `d050302c` | pre-campaign baseline |
| `/tmp/zjs-rt-integrated` | `07ab9b24` | after tranche 1 |
| `/tmp/zjs-rt-t3` | `104e7811` | after tranche 3 |
| `/tmp/zjs-rt-t5` | `1cc8d275` | after tranche 5 — the numbers in this report |

Rebuild with `git worktree add` at the commit, `zig build zjs --seed 0`, then
copy the artifact out and `chmod -w` it. Note that a rebuild is not byte-identical
(build nondeterminism is established here at ±2.5% layout lottery), so a
reconstructed baseline is only sound for whole-mechanism comparisons, not for
re-deriving a specific sub-1% delta.

Pinned references throughout: QuickJS `04be2460`, javascript-zoo `a17d4e0a`,
CPU 19 (Cortex-X925), PMU `armv8_pmuv3_1`, exclusive `/tmp/zjs-host-heavy.lock`.

### Tranche-7 adjudications completed after the fact

**Shape clone memcpy — NO-GO (measured, not landed).** The tranche-6 round's
only unconditional GO was carried to a full gate pass and then rejected on its
own numbers. Implementation mirrored qjs `js_clone_shape` (qjs:5268) behind
three gates (capacity, bucket geometry, proto), passed `test-exec` 416,
`test-bytecode` 69, unified Debug and ReleaseSafe 2163, and `test262-gate`
0/49,775. Eight-pair ABBA on `splay-fixed-d1`, the workload that performs 4.2M
clones:

| | clone | base | delta |
|---|---:|---:|---:|
| instructions | 29,189.2M (sd 15.2) | 29,238.1M (sd 18.8) | **−0.167%** (≈2.6σ) |
| cycles | 7,898.2M (sd 96.3) | 7,893.0M (sd 124.5) | +0.066% (≈0.04σ) |

That is ≈12 instructions and ≈3 cycles per clone against a predicted 14–21
cycles — the removed memsets and per-prop loops were largely absorbed. An
instruction-only win does not justify a second conditional path through
shape cloning, so the knife is recorded rather than merged.

**`getValueProperty` probe-first rider — NO-GO.** Reviewing the WIP found it
called `findOwnDataValueFast` without the receiver-class guard every other
caller of that primitive runs first (`needsSlowPropertyAccess` /
`hasExoticMethods` / `proxyTarget`), which would let a shape slot answer on
behalf of a proxy or exotic holder. Adding the guard is correct but
self-defeating here: `mapped_arguments` is itself in
`classNeedsSlowPropertyAccess`, and RayTrace's 666k `getValueProperty` entries
are ~100% mapped-arguments `.length` — the exact case the guard excludes. The
guarded rider measured +8M instructions on rt-fixed for no hit. Recovering it
would need per-class reasoning about which named atoms are shape-authoritative
on mapped arguments; not worth ~0.2%.

**put_field resident add-tail — LANDED** (`fb0ee823`). The tranche-6 round's
largest target (new-property cold write chain, 1.9x, Δ≈5.2G ≈ 25% of the
remaining gap) was carried to completion. QuickJS's `OP_put_field` slow leg is
one `JS_SetPropertyInternal` call from the shared interpreter frame
(qjs:19188-19203); zjs routed the same miss through the `coldStd` publish
shell into `field()`, which popped both operands, re-decoded the atom and
probed the shape a second time. The miss now tails to a resident handler that
decodes off the live pc and calls the same single-walk core; forms needing the
full resolver decline with nothing mutated and re-tail to the cold twin.

It is the first throwing resident property tail — the stack boundary is synced
to `sp - 2` before the call so the owned-value contract and the catch delivery
agree, and the error path mirrors the cold arm's value_consumed /
close-iterator / handleCatchableRuntimeError sequence.

Gates: `test-exec` 414, `test-bytecode` 69, `test-oom` 21, unified Debug and
ReleaseSafe 2161, `test262-gate` 0/49,775 — fifth consecutive bit-identical run.

Fixed-work, 6 interleaved pairs each:

| workload | instructions | cycles |
|---|---:|---:|
| rt-fixed-d64 | −2.100% | **−1.907%** (−23.1M/run) |
| splay-fixed-d1 | −0.299% | −0.629% |

−23.1M cycles/run lands inside the 15–30M band pre-registered before
implementation.

**Layout artifact, separated by instruction counts.** The full-15 causal A/B
(vs frozen T5, 8 samples) read geomean 1.0012 with raytrace 1.028,
typescript 1.015, deltablue 1.009, zlib 1.009, splay 1.005 — and regexp 0.973,
gbemu 0.992. Fixed-work PMU on the two apparent losers settles it:

| workload | instructions | cycles |
|---|---:|---:|
| regexp-fixed | **+0.001%** (100,840.2M vs 100,839.0M, sd 0.3–0.7M) | +2.759% |
| gbemu-fixed | **+0.000%** (23,026.2M vs 23,026.0M, sd 0.1–0.3M) | +0.968% |

Bit-identical instruction counts mean neither benchmark reaches the new code at
all, so their cycle deltas are code placement, not mechanism — the ±2.5%
layout lottery this host has produced before. The build is deterministic for a
fixed source, so a second draw was not available to confirm by resampling;
the instruction evidence is stronger anyway, since it shows the code is never
executed. The wins, by contrast, are all on write-heavy benchmarks and are
carried by real instruction reductions.

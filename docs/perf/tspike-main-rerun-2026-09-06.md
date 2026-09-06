# PERF-T-SPIKE re-run on the tracing-GC main (2026-09-06)

Branch: `spike/perf-t-main` (from main `8be2ca7d`; branch-quarantined, never
merged). Policy: `policies/spikes/perf-t-spike-v1.json`. Why a re-run: typed
plan §十一 R11 — the 2026-08-26/27 spike's hit path carried `value.dup()` and a
receiver release; main has no reference counts, so the baseline `op_get_field`
hit and the direct-slot hit both lost the same constant and the old percentage
readings were void. This document is the evidence; the G1-TYPED verdict is the
owner's.

## 1. What was ported (commit `0ba36d13`)

| Piece | On main today | Spike form |
|---|---|---|
| Opcode | ids 0..254 claimed except 16 reclaimed holes; 254 is `object_slots2` | `tspike_get_slot = 253` (reclaimed id), `.atom_u8` form (atom u32 + site u8, size 6). Branch-only ledger pins 244/11/12, decode fingerprint `0x5c462805bfeb1d4f`. |
| Shape identity (u64 arm) | `Shape` 56 B; unshared shapes mutate **in place** (`ShapeOwnership.shared` sticky bit, typed plan R5) | `tspike_identity: u64` after `proto`, 56 → 64 B (R6). Fresh in `link()` (every createShape*/cloneShape), before every in-place mutation (unshared append, `prepareUpdate` in-place legs, `replacePrototypeAssumePrepared`, `markPropertyDeleted`, `updatePropertyFlags`), fresh for `compactProperties` / `restorePropertyLayout` rebuilds, **preserved** across `relocateShape`. Process-wide counter (production = per-Runtime). |
| ptr arm | — | key = shape address. **Not sound on main**: an unshared shape appends/deletes at the same address. Cost floor only; see §3 for the one test that shows it. |
| Handler | `op_get_field` leaf: own probe → one-level proto probe → tails | `op_tspike_get_slot` leaf, `align(32)`, same section: guard(s) → `load prop_values` → index → `loadValueAsIntPair` → `cont(pc + 6)`. Misses re-tail to `cold_table[pc[0]]` (the get_field property tail continues at pc+5). R7 respected: the slot is reached through the `prop_values` load, never `obj + const`. |
| Capture | — | `tspike.capture` `noinline` in the cold `h_field` shell (`vm_property_field.field`, `opc == tspike_get_slot` consumes the site byte); own-slot or one-level proto-slot; poisoned = generic forever. |
| Compiler | `resolve_labels` fuses get_loc0/get_loc2/get_var + get_field and get_field + get_field2 | `ZJS_TSPIKE=1`: suppress those four fusions and rewrite each `get_field` site (first 256) into `tspike_get_slot`; `ZJS_TSPIKE=fuseoff`: suppress only (control arm C). |
| Build | — | `-Dzjs_tspike_guard=off|u64|ptr` (default off, zero trace). |
| Accounting | credit and debit both go through `accountedAllocationSize` (slab payload) | no currency hack needed (the 2026-08-26 spike's `accounted` patch is obsolete). |
| Representation snapshot | `shape size=56 … fam=56` | branch pin `size=64 … fam=64` |

Differences from the 2026-08-26 spike worth knowing: no `dup`/release legs in
the handler; the write opcode (`tspike_put_slot`) was already dropped in the
spike's final form and stays dropped; the site is captured through
`objectFromValueTrustedExpression`; `consumeInstructionAtom` keeps the atom in
the output ledger so `traceFunctionBytecodeAtoms` (R3) still sees it.

## 2. Correctness gates (policy `correctness_gates`)

| Gate | Reading |
|---|---|
| guard=off `zig build test` | 24/24 steps (unified suite green; only the two branch pins changed: decode fingerprint, representation snapshot) |
| guard=u64, `ZJS_TSPIKE=1 zig build test` | 20 failures, all bytecode-shape expectations or scanners that pattern-match the `get_field` byte (§3); no semantic failure |
| guard=u64, `ZJS_TSPIKE=1` full test262 (embedded runner build) | **0/49778 errors, passed 44584** — identical with `ZJS_TSPIKE` unset on the same binary |
| guard=ptr, `ZJS_TSPIKE=1 zig build test` | the same 20 + **`IC-R1: delete then get_field is undefined after a prior hit`** — the predicted in-place-delete unsoundness of the address guard |
| guard=ptr, `ZJS_TSPIKE=1` full test262 | 0/49778 (the suite does not hit the delete-after-capture shape at a rewritten site) |
| `zig build smoke` (guard=u64) | green (build-graph run, `ZJS_TSPIKE` unset; the env-on smoke is covered by the full test262 sweep above) |
| Harness checksum gate | all six workloads print the same checksum on all five arms |

## 3. The 20 `ZJS_TSPIKE=1` unit failures, classified

- 15 bytecode-shape pins (`tests.parser` F4/F6/F7/quick-parser, `compiler.tests` fuse: `get_loc0_field`, `get_loc2_field`, `get_loc2_field2`, `get_var_field`, `get_field_field2`): they assert the exact `get_field` byte or a fusion the rewrite suppresses. Expected under the rewrite; the same tests pass with the env unset on the same binary.
- `small-function-inlining L1: apply-arguments ctor specializes`: the L1 rewrite scans for the `get_field` byte in `this.m.apply(this, arguments)`; a rewritten site is invisible to it. Spike limitation (a production typed op would be registered with the scanner).
- `accessors Proxy traps and primitive coercion stay on the active Machine` (`expected 21, found 24`): a captured site whose receiver later is an accessor/Proxy object misses the guard and goes to the cold `h_field` shell, which resolves accessors on a nested Machine; `op_get_field` routes the same case through its resident `.get_field_cached_getter` / proxy tails. Results are correct; the Machine-count invariant is violated by three. Spike limitation — the production op would share the get_field tail table (needs a pc-width-agnostic continuation).
- `assignment destructuring early errors allow reserved property names`: bytecode expectation (`TestUnexpectedResult` on a decoded stream).

## 4. Five-arm A/B (policy `sample_protocol`)

Binaries (ReleaseFast, big-core build pool): A = main `8be2ca7d` (`git archive main`, md5 `b5ec4bb4…`), D = branch guard u64 (`dbf48de4…`), E = branch guard ptr (`3d13970d…`); B = D with `ZJS_TSPIKE` unset, C = D with `ZJS_TSPIKE=fuseoff`. `run_tspike_ab.py`, 8 paired ABBA samples, CPU 19, host lock held, `instructions,cycles` in the same run as wall; no compile during the run. Artifact: `reports/evidence/PERF-T-SPIKE/tspike-main-ab-2026-09-06.json`.

Readings that matter: **D/C, E/C** = mechanism effect, fusion-neutral; **D/A, E/A** = end-to-end vs production; B/A = binary-layout noise floor; C/B = cost of the suppressed fusions. Ratios are medians, candidate/control, < 1 = candidate faster or fewer.

### wall

| bench | D/C | E/C | D/A | E/A | B/A | C/B | max CV |
|---|---:|---:|---:|---:|---:|---:|---:|
| chain_walk | 0.8179 | 0.8186 | 0.8217 | 0.8224 | 1.0028 | 1.0019 | 0.012 |
| prop_dense | 0.8942 | 0.8866 | 0.8956 | 0.8880 | 1.0014 | 1.0002 | 0.002 |
| own_slot | 0.9258 | 0.9141 | 0.9605 | 0.9485 | 1.0000 | 1.0375 | 0.019 |
| proto_slot | 0.9879 | 0.9820 | 0.9967 | 0.9908 | 1.0049 | 1.0039 | 0.090 (u64 arm; other arms ≤ 0.009) |
| poly_stress | 1.1090 | 1.1047 | 1.0978 | 1.0935 | 0.9829 | 1.0071 | 0.048 |
| untyped_control | 1.0184 | 1.0150 | 0.9891 | 0.9858 | 0.9707 | 1.0006 | 0.034 |

### instructions

| bench | D/C | E/C | D/A | E/A | B/A | C/B |
|---|---:|---:|---:|---:|---:|---:|
| chain_walk | 0.9151 | 0.9029 | 0.9151 | 0.9030 | 1.0001 | 1.0000 |
| prop_dense | 0.9176 | 0.9059 | 0.9176 | 0.9059 | 1.0000 | 1.0000 |
| own_slot | 0.9342 | 0.9248 | 0.9613 | 0.9516 | 1.0000 | 1.0290 |
| proto_slot | 0.9827 | 0.9802 | 0.9901 | 0.9876 | 1.0000 | 1.0075 |
| poly_stress | 1.0929 | 1.0897 | 1.0990 | 1.0959 | 1.0000 | 1.0057 |
| untyped_control | 1.0003 | 1.0005 | 1.0013 | 1.0015 | 1.0013 | 0.9997 |

### cycles

| bench | D/C | E/C | D/A | E/A | B/A | C/B |
|---|---:|---:|---:|---:|---:|---:|
| chain_walk | 0.8019 | 0.8035 | 0.8053 | 0.8069 | 1.0042 | 1.0000 |
| prop_dense | 0.8937 | 0.8860 | 0.8949 | 0.8872 | 1.0015 | 0.9998 |
| own_slot | 0.9245 | 0.9124 | 0.9605 | 0.9478 | 1.0006 | 1.0382 |
| proto_slot | 0.9882 | 0.9816 | 0.9970 | 0.9903 | 1.0055 | 1.0034 |
| poly_stress | 1.1124 | 1.1069 | 1.1007 | 1.0953 | 0.9820 | 1.0077 |
| untyped_control | 0.9985 | 1.0046 | 0.9916 | 0.9977 | 0.9944 | 0.9986 |

Base-arm absolutes (medians): chain_walk 0.086 s / 0.99 G insn; prop_dense 0.925 s / 17.4 G; own_slot 0.477 s / 9.2 G; proto_slot 1.601 s / 28.9 G; poly_stress 0.593 s / 10.2 G; untyped_control 0.040 s / 0.63 G. chain_walk and untyped_control are short runs (< 0.1 s); their wall CVs (1–3 %) are the noise band to read them against. proto_slot's u64 arm has one outlier sample (CV 0.09); its median agrees with the ptr arm (0.988 vs 0.982).

## 5. Against the policy's lines (a reading, not the verdict)

| Policy line | Reading |
|---|---|
| `minimum_effect.own_slot`: ≥ +8 % on the property-dense typed microbench, ≥ 1 guard arm | prop_dense mechanism D/C wall 0.894 (= **+11.8 %** throughput, 1/0.894), E/C 0.887 (+12.8 %); end-to-end D/A 0.896. own_slot workload: D/C 0.926 (**+8.0 %**), E/C 0.914 (+9.4 %); end-to-end D/A 0.961 (+4.1 %) because this workload pays the suppressed fusions (C/B 1.038 — it is the fusion-heaviest of the six). Cleared on prop_dense in both arms; on the own_slot workload cleared mechanism-side, not end-to-end. |
| Polymorphic arm does not collapse the win | poly_stress D/C **1.109** (−9.8 %), insn 1.093. The spike has no polymorphic support: an alternating-subclass site misses its guard every other call and takes the full cold `h_field` shell, which is slower than `op_get_field`'s resident miss. Worse than the 2026-08-27 −6.4 % (there the miss leg was cheaper relative to an rc-taxed hit). What this prices is "monomorphic guard + generic fallback"; the 2-arm site (§20.2a ②) was not prototyped. |
| `maximum_regression.untyped_controls`: geomean ≤ 1.005 | insn D/C 1.0003, cycles 0.9985 — neutral. Wall D/C 1.018 on a 40 ms run with per-arm CV 0.02–0.03 and B/A 0.971 (binary layout alone moves it 3 %): inside noise, but the wall figure alone does not certify ≤ 1.005. |
| u64 vs ptr guard arms | E/C − D/C: 0.000 / −0.008 / −0.012 / −0.006 wall on the four typed workloads; insn −1.2 %. The identity load is measurable at ~1 % and is the whole difference; the ptr arm is unsound on main (§2), so the u64 arm is the only production candidate and its 64 B Shape is the footprint cost to carry (R6). |
| Fusion loss | C/B: own_slot 1.038, others ≤ 1.007. A production typed op would need its own fusions (get_loc0 + typed slot etc.) to reclaim this; the D/C column already excludes it. |

## 6. Versus the 2026-08-27 readings (R11 expectation)

| | 2026-08-27 (rc, spike/perf-t) | 2026-09-06 (tracing main) |
|---|---|---|
| prop_dense mechanism | +8.9 % | +11.8 % wall / insn 0.918 |
| chain_walk mechanism | +15.7 % | +22.3 % wall (0.818) / insn 0.915 |
| instructions | −7 to −8 % | −8.2 to −8.5 % (prop_dense/chain_walk), −6.6 % own_slot |
| poly_stress | −6.4 % | −9.8 % |
| guard arms | indistinguishable | ptr ≈ 1 % better, both arms clear the line |

R11 expected the percentages to shrink once both hits lost the rc constants. They grew instead. The insn reduction is the same as before (the probe chain the direct slot replaces did not change), so the difference is in what a hit costs now: with rc gone, the `op_get_field` hit is a shorter path whose remaining cost is dominated by the probe chain itself (shape → mask → bucket → Property → atom compare) — the exact part the direct slot removes — so the removed fraction is larger, not smaller. The polymorphic regression grew for the mirror reason: the resident miss got cheaper too, while the spike's cold fallback did not.

Not measured here: the Octane-scale reading the registry says is still owed ("the real bench_v8 suite, needs the u8 site index widened") — the 256-site registry covers only microbenchmarks, and bench_v8 programs have thousands of `get_field` sites.

## 7. Reproduce

```
git checkout spike/perf-t-main
zig build zjs -Doptimize=ReleaseFast -Dzjs_tspike_guard=u64   # D (B, C use it with env unset / ZJS_TSPIKE=fuseoff)
zig build zjs -Doptimize=ReleaseFast -Dzjs_tspike_guard=ptr   # E
ZJS_MEASUREMENT_LOCK=/tmp/zjs-host-heavy.lock flock -x /tmp/zjs-host-heavy.lock \
  taskset -c 19 python3 tools/perf/tspike/run_tspike_ab.py \
  --base <main zjs> --spike-u64 <D> --spike-ptr <E> --samples 8 --cpu 19 --output out.json
```

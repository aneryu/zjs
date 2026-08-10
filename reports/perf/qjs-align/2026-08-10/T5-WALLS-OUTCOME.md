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

1. Property-read generic route 4.21x (inline arm is at 1.067 parity; RayTrace
   miss-reason distribution unattributed — biggest remaining RayTrace block).
2. Simple-ctor fast path fixed cost (+106 cyc vs qjs, does not shrink with
   field count; arena churn ~35 + prototype-gate walk ~26).
3. `op_get_var` 2.9–6.1x (5-level chain + local_fast_blocked gate).
4. splay object-create 3.22x (clone-leg unit cost / bucket-chain occupancy —
   counter probes, not disassembly).
5. Call-boundary state coupling (C-track ledger): reduce the ~14 vm.* rewrites
   per call boundary; return-chain probe (K4) validated the chain-depth lever.

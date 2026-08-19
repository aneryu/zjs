# QCP-1 switch decision — close-out record

*Historical decision record (2026-08), condensed to its terminal rulings on
2026-08-19. The full decision packet — the §1–§7 measurement evidence, gate
ledgers, per-benchmark tables, and deletion sequencing — was removed from the
active tree; recover it from this file's git history. The `-Dzjs_compiler`
option described below has been retired; the v2 compiler is the only
compiler, and command lines quoting that option no longer run. Historical
commit SHAs mentioned here are not on the rewritten `main` lineage; they
survive only on side branches and tags.*

Section numbers preserved here (§0.1.6, §8, §8.5, §9) match the original
packet, because code comments, `AGENTS.md`, and the CHANGELOG cite them.

## 0.1.6 `.short` is release configuration, not an optimization

`-Dzjs_compiler_layout=short` (named `-Dzjs_v2_layout` at switch time) is
part of the release configuration and is defaulted
as such. It is not a tuning knob that may drift: the switch was gated on it,
and the `.plain` configuration is REJECTED for production. `.plain` remains
reachable as the A/B diagnostic instrument — it is how the artifact-residency
finding was localised, and that instrument must not be destroyed.

## 8. FINAL VERDICTS

QCP-1 closed as **two** separately adjudicated verdicts:

| | question | verdict |
| --- | --- | --- |
| **QCP-1A** (2026-08-04) | make V2 the production compiler | **ACCEPT** |
| **QCP-1B** (2026-08-04, amended 2026-08-06 — see §9) | physically remove the legacy pipelines | initially **NO-GO, deferred**; amended to **ACCEPT** |

**Production configuration, shipped:**

```
zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off
```

Every engine-bearing artifact attests this configuration signature at compile
time, and `zig build config-signature-check` compares the shipped binary's
self-reported signature against the build graph.

**QCP-1A** was adjudicated on true production defaults against a three-part
gate (code-load ratio vs corrected legacy ≥ 1.2359×; full-zoo geomean not
regressed; no per-benchmark floor breach): all three MET. test262 was
identical in both compilers, legacy emission inside V2 scope was zero with an
empty allowlist, and the dual comparator reported zero mismatches after the
four-defect divergence closure.

**QCP-1B** was first ruled NO-GO because deleting the unreached legacy source
produced a stable, unexplained runtime regression (crypto −3.9%, full-zoo
geomean −0.73%) with a code-placement signature. That ruling did its job: the
deletion did not ship while a repeatable regression had no mechanism. §9
records the bisection that found the mechanism and the amended ACCEPT.

### 8.3 / 8.4 The QCP-1B diagnosis — refuted and established

The full layout-diagnosis corpus was deliberately left on the unmerged
`compiler-v2-qjs` and `diag/*` side branches (not main ancestors), so a
diagnosis of a rejected tree would not enter the record of an accepted one.
What survives is the eliminated hypothesis space:

**Refuted** (each tested, each failed): a simple `.text` layout shift;
address-restoring padding; tail padding; heap padding; compile-time allocation
padding; the dispatch-table page split; the `ld_align_lat` alignment mechanism
and its 64-byte control (a within-cell test showed 44.5M of its events cost
approximately zero, so the mechanism could not be the carrier however well the
correlation read).

**Established**: the cost was real and reproduced across independent layouts
and build lineages; it was carried by the single legacy-deletion commit, not
the deletion programme in general; it was not the declared behavioural change
(a 2×2 factorial separated them); the executed program was unchanged to 6
parts in 100,000; and the residual cycles initially had no identified
mechanism — which is exactly why QCP-1B was deferred rather than argued to a
pass, until §9 named the mechanism.

### 8.5 Process corrections carried forward

These outlast QCP-1 and bind future work regardless of subject.

1. **A single benchmark can never license a compiler, VM-dispatch or
   bytecode-layout default change.** Stated at the level of *blast radius*,
   not of benchmark: code-load was never wrong, it was blind to the axis the
   change moved, and no amount of extra sampling on it would have produced the
   missing information.
2. **A gate must attest the configuration it actually ran.** Green about a
   configuration that was never executed is the defect class, and it is closed
   structurally by the configuration signature plus per-artifact compile-time
   attestation — not instance by instance.
3. **Performance comparisons must be paired within a session.** Identical
   frozen bytes drifted 0.31%–0.56% between sessions — the same size as the
   effects being judged. A number quoted across sessions is not a comparison.
4. **A disclosure about the measurement protocol is a statement about a tree,
   not a standing fact.** "Candidate builds are byte-identical, so there is no
   layout lottery to sample" was true at one gate and false at the deletion
   tip. Protocol disclosures must be re-derived per tree and retracted by name
   when they stop holding.
5. **Zig codegen bistability is a global mode**, and it aliases with any
   cross-mode comparison. Any A/B that straddles it is measuring the mode.
6. **On a throughput fixture, raw cycles is the honest per-fixed-work
   quantity.** `cycles/score` is proportional to time *squared*, and
   `instructions/score` moves even when the instruction count is identical.
   Both normalized forms mislead on a fixture whose score is itself a rate.

## 9. QCP-1B AMENDMENT — deletion bisection and final removal (2026-08-06)

### 9.1 Amended verdict

| question | 2026-08-04 verdict | 2026-08-06 verdict |
| --- | --- | --- |
| physically remove the legacy compiler pipelines | NO-GO, deferred | **ACCEPT** |

The earlier verdict did its job: deletion did not ship while a repeatable
crypto regression had no mechanism. This amendment does not reinterpret that
evidence. It answers the missing question, restores two explicit
compiler-stage boundaries whose accidental inlining carried the cost, and then
removes the legacy Phase 1/2/3 passes, dual comparator, and `-Dzjs_compiler`
option.

### 9.2 Deletion bisection

The deletion was split by subsystem and then by hunk against pre-delete V2.
Removing parser/configuration code was neutral. Removing `src/bytecode.zig`
carried the full step. The minimal reproducer was one otherwise-unused field:

```zig
pub const CompileContext = struct {
    realm: *RealmContext,
    policy: CompilePolicy = .{},
    timing: ?*CompileTiming = null,
    v2_ledger: ?*compare.Ledger = null, // production was always null
};
```

Changing the only call site to literal `null` while retaining this field was
neutral. Deleting the field reduced the context by one native word and made
crypto slow. Replacing it with a same-sized `?*anyopaque` field recovered the
score; the typed and opaque controls produced byte-identical `.text`.
Applying the complete historical deletion while retaining that one
behavior-free word also recovered the loss in the historical tree
(pre-delete median 1606.5; full deletion 1550.0, −3.52%; full deletion plus
reserved word 1604.5, −0.12%).

This established a deletion/layout interaction, not retained compiler
behavior. The replacement field was a diagnostic control only; it is not in
the final tree.

### 9.3 Mechanism boundary

The minimal fast/slow pair produced identical JavaScript artifacts: 10,765
disassembly lines and 334,251 bytes matched in bytecode, functions, constants,
and stack geometry. A fixed-work allocation trace also matched all 17,601
operations by kind, size, phase, and address modulo 64. That refutes both a
crypto semantic change and the earlier heap-alignment hypothesis.

PMU attribution on the historical fixed-work pair found the slow binary at
+4.27% cycles with essentially equal retired instructions, while backend-stall
slots rose about 13% and frontend stalls stayed flat. The field-width change
altered 224 native symbol sizes across the Zig 0.16 whole program. On the
final tree, a fixed compile-throughput run made the carrier visible:
`computeStackSizeForCurrentBytecode` disappeared as an independent symbol and
the V2 lowering path was folded into the already-large
`createFunctionBytecodeAfterChildren` finalizer. The compiler-source deletion
had changed LLVM's cross-stage inlining decisions.

The durable fix is two real phase boundaries:

* `compiler.compileFunctionV2ForPackedFinalize` (the directory was renamed
  from `compiler_v2` to `compiler` on 2026-08-19) is `noinline`, matching the
  architectural boundary between V2 lowering and packed artifact publication;
* `computeStackSizeForCurrentBytecode` is `noinline`, keeping the full final
  bytecode verification walk out of the publication function.

With those boundaries, removing the diagnostic reserved word changes the three
relevant symbol sizes by at most four bytes. No padding, dummy field,
benchmark-specific path, or linker-address restoration remains.

### 9.4 Current-tree A/B and gates

Both fixed binaries stated the production signature and ran pinned to CPU 19
under the exclusive host lock. The no-padding deletion candidate measured
geomean **1.0061** on a balanced four-sample run of all 15 Zoo throughput
benchmarks; the lowest individual ratio was code-load at 0.984 and crypto was
1.044, so neither the original crypto cliff nor the later code-load shift
survives the explicit compiler-stage boundaries. An independent build state
confirmed the same three symbol boundaries and cleared the 0.975
per-benchmark floor as well.

The removal tree passed the switch-era validation ladder in full, including
the compiler-v2 / parser / bytecode suites, configuration-signature checks,
ReleaseSafe, and test262 (`0/49775 errors`, 44,581 passed). Some gate names in
that ladder (`architecture-check`, `config-drift-gate`, `test262-gate`,
`checkpoint-check`) have since been renamed or retired; they are switch-era
evidence, not current commands.

The architecture distinction is intentional: reusable QuickJS binding rules
remain in `bytecode.binding_rules`; the legacy pass structures and selectable
backend do not. The active compiler directory was `src/compiler_v2/` at
close-out; it was renamed to `src/compiler/` on 2026-08-19 (owner ruling).
The attested signature string keeps `compiler=v2` as the compiler's published
identity.

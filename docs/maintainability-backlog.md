# Maintainability Backlog (HOT zone)

Priced queue of hot-path maintainability items deferred from the 2026-08-18
campaign. Each item must pass the [refactor-policy](refactor-policy.md)
rule-2 gate (15-item zoo A/B, pad 0, parallel-cluster protocol, median no
regression) — or, where noted, the cheaper identity gates of rule 4 —
before merging.
Estimated verification cost: about half a day of measurement per A/B item.

Evidence line references were re-verified as of commit `b325d7b1`
(2026-08-19). Line numbers drift; function names are the anchor.

| # | Item | Evidence | Notes / gate |
|---|---|---|---|
| H1 | Rehome overflow content out of `call_runtime.zig` (7793 lines, 219 pub fns) | Atomics `:3544-3781`, Reflect `:3475`, iterator protocol `:3196-3468`, Error.stack `:1694-1781`, dynamic Function construction `:2883-2922` all have dedicated owning files | Move in batches; one zoo A/B per batch |
| ~~H2~~ | **Closed by convention 2026-08-19**: `docs/architecture.md` now rules that `X_builtin_ops.zig` exists only where `X_ops.zig` also exists; single-file domains keep their records in `X_ops.zig`. The mass rename to one suffix was rejected — those files hold value-level runtime too, so `_builtin_ops` would be the wrong name for them. `internal_builtins.zig`'s domain-named aliases are the documented exception to the alias-equals-file-name rule. | — | — |
| ~~H3~~ | **Done 2026-08-19** (naming campaign batches B/C): all misleading exec import aliases unified onto file names (`class_vm`/`collection_vm`/`iter_vm`/`date_vm`/`weak_ref`/`symbol_builtin`/`buffer_builtin`/`function_bytecode`, the nine `X_vm` inversions, `td`), dual imports dropped, `vm_exception_ops.zig` → `exception_ops.zig`. Verified change-free on both build attractors (stripped-image identity). | — | — |
| ~~H4~~ | **Done 2026-08-19**: every call site of the 17 unchecked `objectFromValue` copies was classified — **no live bug**; all value domains are cell-unreachable (expression values under the Trusted argument, or engine-internal object slots). Authority sank to `core.value_semantics` (`objectFromValue` / `objectFromValueTrustedExpression` / `expectObject`); 18 copies became 1 authority + 3 justified mirrors (with `mirror of` comments) + forwards, 12 `expectObject` became 1 authority + 1 named-precondition bootstrap variant + forwards. GUIDE A.7 now bans unmarked helper duplication. | — | — |
| ~~H5~~ | **Done 2026-08-19**: deleted the 15 pure-forwarding `qjsIteratorZip*`/`qjsIteratorHelper*` shells (zero external callers; internal calls retargeted to `iterator_ops`); `call_runtime.zig` 7793 → 7568 lines. `qjsIteratorWrapNext/Return` were native implementations, not shells, and stay. Also merged the `functionPrototypeFromGlobal` and `numberValue` duplicate implementations onto their single owners. | — | — |
| ~~H6~~ | **Done 2026-08-19**: `property_ic.zig` → `property_direct.zig`; the zombie `cachedSetObjectDataPropertyForPutFastPath` had zero callers (its "ABI stability with callers" comment was stale) and was deleted. Verified under the batch identity gate. | — | — |
| H7 | Bring the orphan section `.text.zjs.nmfd_term` under explicit linker-script management | `vm_call.zig:780` emits it; `tail_hot_layout_aarch64.ld` never mentions it, so its placement relies on orphan-section defaults | Linker change: always zoo A/B |
| H8 | Split `core/object.zig` (~13,300-line file; its single `Object` `extern struct` spans ~10,800 lines across ~15 unrelated payload domains) | Six manual `align(16)` pins inside; prior layout-sensitive commits target this file | Large project; revisit after 1.0 |
| H9 | Narrow the public `JSValue` surface (89 leaked internal pub decls, e.g. `freeObjectAssumeObjectDuringActiveBytecode`) via an opaque public value type | Public-api audit A3; `public-api-contract.md` promises the opposite | Design jointly with the fun port |
| H10 | Separate name from role in `src/parser.zig` (hosts `compile_entry` + 875 `v2` references) and `src/bytecode.zig` (hosts `pipeline_*` namespaces) | Architecture doc admits the mismatch | Large project |
| H11 | Fix `core/root.zig` absences (5 modules, incl. `jobs.zig`) and the inverted re-export of `core/jobs` from `exec/root.zig:26` | Import-graph change | Try the .text-identity gate first |
| ~~H12~~ | **Done 2026-08-19**: every same-name/different-meaning pair is resolved — `isConstructErrorObjectName`, `getValuePropertyViaGlobalSlots`, `defineDataPropertyByName`, `checkedInt32*` (renames); `functionPrototypeFromGlobal`, `numberValue`, the `expectObject` family (merges onto single owners). One follow-up parked: `vm_arith.fastInt32*` (widening) vs `vm_property.checkedInt32*` (overflow-intrinsic) are now honestly named but strategically contradictory — A/B one strategy when the zoo gate returns. | — | — |
| ~~H13~~ | **Done 2026-08-19**: the parser's dual emission streams are now named — builder-stream State veneers are `builder*` (`builderEmitOp`, `activeBuilder`, …), the parser-error facade free functions are `emitter*` (`emitterOp`, `emitterBindLabel`, … — the implementation layer of the `Emitter` namespace; the `F` infix meant "parser-error-typed **F**acade"), the ~30 `v2_*` locals/fields dropped the prefix, and the three dual-stream unions tag their arms `temp`/`builder`. Contract F-5/F-6 dead code deleted (−79 lines): first attempt was caught by the identity gate as a QCP-1B-class layout perturbation (`.text` −432 B) and reverted; re-landed under the 2026-08-19 owner suspension of the rule-2 zoo gate, with the layout effect measured and recorded for re-pricing at the next zoo re-baseline. `FunctionDef.v2_builder` (bytecode.zig) keeps its name pending H10's bytecode.zig pass. | — | — |
| ~~H14~~ | **Resolved 2026-08-19 by convention-plus-stragglers**: the two `throw*` patterns and the `*ForFastPath` (ingredient) vs `*Fast` (fast variant) distinction turned out to be real semantics, now documented in `docs/architecture.md`; renamed the true stragglers (`throwTdzReference` → `throwTdzReferenceError`, `throwGlobalTdz` → `throwGlobalTdzReferenceError`). Mass-unifying the ~55 suffix variants was judged churn without information gain. | — | — |

## Ruled out — then reversed

- **Renaming `compiler_v2` to `compiler`**: initially ruled out (2026-08-18)
  for blast radius; **reversed by owner ruling 2026-08-19 and executed**.
  `src/compiler_v2/` → `src/compiler/`, `test-compiler-v2` → `test-compiler`
  (deprecated alias retained), `-Dzjs_v2_layout` → `-Dzjs_compiler_layout`
  (deprecated alias retained). The attested signature string
  `zjs-config-v2:compiler=v2,...` was intentionally kept: "v2" is the
  compiler's published identity, not the directory name.

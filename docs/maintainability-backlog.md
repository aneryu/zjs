# Maintainability Backlog (HOT zone)

Priced queue of hot-path maintainability items deferred from the 2026-08-18
campaign. Each item must pass the [refactor-policy](refactor-policy.md)
rule-2 gate (15-item zoo A/B, ≥3 layout pads, median no regression) — or,
where noted, the cheaper identity gates of rule 4 — before merging.
Estimated verification cost: about half a day of measurement per A/B item.

Evidence line references are as of commit `71bb8637` (2026-08-18).

| # | Item | Evidence | Notes / gate |
|---|---|---|---|
| H1 | Rehome overflow content out of `call_runtime.zig` (7793 lines, 217 pub fns) | Atomics `:3544-3781`, Reflect `:3475`, iterator protocol `:3196-3468`, Error.stack `:1694-1781`, dynamic Function construction `:2883-2922` all have dedicated owning files | Move in batches; one zoo A/B per batch |
| H2 | exec file-name taxonomy: unify the 19 native-record tables under one `*_builtin_ops.zig` family | `internal_builtins.zig:12-31` imports a mix of `*_ops` / `*_builtin_ops` / `builtin_glue` | File renames are HOT; zoo A/B |
| H3 | Fix hot-file import aliases (`class_vm` → `object_ops`, `collection_vm` → `array_ops`, `iter_vm` → `iterator_ops`; drop dual-alias imports) | `tailcall_dispatch.zig:36` and `:45` import the same file under two names | Identifier-only; try the .text-identity gate first, fall back to A/B |
| H4 | Converge the 20+ `objectFromValue` / `expectObject` clones | Six private copies skip the `kind != .object` check that the public `object_ops.zig:2752` version performs — **semantics have forked** | Correctness first: difftest the divergence (may be a live bug, not just duplication), then merge under A/B |
| H5 | Remove the 14 forwarding shells in `call_runtime.zig` | Violates the standing ban in `shared-vm-decomposition.md` ("do not reintroduce forwarding aliases in call_runtime") | zoo A/B |
| H6 | Rename `property_ic.zig` and delete the zombie API (`cachedSetObjectDataPropertyForPutFastPath` always returns `false`) | The inline cache was deleted; the filename is historical. The zombie's comment claims "ABI stability with callers" — verify that claim first | zoo A/B |
| H7 | Bring the orphan section `.text.zjs.nmfd_term` under explicit linker-script management | `vm_call.zig:780` emits it; `tail_hot_layout_aarch64.ld` never mentions it, so its placement relies on orphan-section defaults | Linker change: always zoo A/B |
| H8 | Split `core/object.zig` (10,846-line single `extern struct`, ~15 unrelated payload domains) | Six manual `align(16)` pins inside; prior layout-sensitive commits target this file | Large project; revisit after 1.0 |
| H9 | Narrow the public `JSValue` surface (89 leaked internal pub decls, e.g. `freeObjectAssumeObjectDuringActiveBytecode`) via an opaque public value type | Public-api audit A3; `public-api-contract.md` promises the opposite | Design jointly with the fun port |
| H10 | Separate name from role in `src/parser.zig` (hosts `compile_entry` + 875 `v2` references) and `src/bytecode.zig` (hosts `pipeline_*` namespaces) | Architecture doc admits the mismatch | Large project |
| H11 | Fix `core/root.zig` absences (5 modules, incl. `jobs.zig`) and the inverted re-export of `core/jobs` from `exec/root.zig:26` | Import-graph change | Try the .text-identity gate first |
| H12 | Resolve same-name/different-meaning pairs: `isErrorConstructorName` (`construct.zig:582` vs `vm_exception_ops.zig:517`, different predicates), `functionPrototypeFromGlobal` (`call.zig:783` vs `object_ops.zig:156`, different signatures) | Alias swaps silently change semantics | Correctness review first, then rename under A/B |

## Ruled out

- **Renaming `compiler_v2` to `compiler`**: not worth it. The name is baked
  into the release configuration signature
  (`zjs-config-v2:compiler=v2,...`), the `-Dzjs_v2_layout` build option, and
  the `test-compiler-v2` step. The blast radius is out of proportion to the
  benefit; `architecture.md` notes instead that "v2" is a historical name
  and this is the only compiler.

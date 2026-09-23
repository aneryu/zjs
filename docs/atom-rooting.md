# Atom rooting

Current lifetime rules for dynamic atom IDs. The collector owns liveness;
copying an ID does not retain its entry. The old borrowed-atom audit,
reference-counting rules, and static checker are available in Git history.
General collector rules live in [GC invariants](gc-invariants.md).

## Across a safepoint

A dynamic atom ID that survives a possible collection must be reported by one
of these mechanisms:

- A declared atom root frame or registered root provider.
- An active `CompileAtomScope` that recorded the ID.
- A traced holder edge, such as a shape key, bytecode name/operand, or module field.
- A matching host pin for native storage the tracer cannot visit.

A raw integer, a function name ending in `Owned`, or a comment is not a root.
Predefined and tagged-integer atoms are not recyclable dynamic table entries.

## Compiler scopes

[`CompileAtomScope`](../src/core/atom.zig) records IDs obtained while compilation
is active. [`parser.State`](../src/parser/parse_state.zig) owns its scope.

- Initialize the scope detached; activate it only at its final address because
  the registered provider stores its address.
- Activation installs it as the table's innermost ambient scope. Deinitialization
  restores the previous scope and unregisters its provider in stack order.
- An ID obtained before the scope opened needs `noteExisting` or another root;
  merely opening a scope does not discover arbitrary local IDs.
- If the recorded-ID list cannot grow, `note` pins the ID for the runtime's
  remaining lifetime. This OOM fallback deliberately over-retains rather than
  silently dropping a root.
- When the scope closes, surviving IDs must already have another reported root
  or holder edge. A scope is temporary protection, not publication.

Holder stores use `AtomTable.noteHolderStore`; the holder's trace must still
visit the field. The helper alone does not make an untraced holder a root.

## Diagnostics

`-Dzjs_ownership_audit=true` quarantines the dynamic atom slots retired by the
last sweep so immediate slot reuse does not hide stale IDs. It is disabled by
default and intended for Debug/ReleaseSafe diagnosis, not production.

The existing audit suite can be run when investigating atom lifetime:

```sh
zig build test -Dzjs_ownership_audit=true
```

This is a targeted diagnostic, not an additional mandatory gate. It only
observes executed paths; passing does not prove every atom holder is rooted.
The removed source-shape checker is not a current CI check. Use current source
and focused lifetime tests to verify root windows, error exits, and publication.

# `exec/call_runtime.zig` Decomposition Map

`src/exec/call_runtime.zig` (originally `shared.zig`) is the VM call runtime:
`execCall`, the `callValueOrBytecode*` dispatch chain, construct paths, direct
and indirect eval support, generator resumption, and Atomics waiter
machinery. The compatibility alias layer that `shared.zig` once
carried has been removed; new callers should import the owning domain module
directly. A group of `qjsIteratorZip*` forwarding shells remains in this file
today, re-exporting `iterator_ops.zig`. That violates the move-criteria ban
below; cleanup is registered as
[maintainability-backlog.md](../maintainability-backlog.md) **H5**.
Remaining non-call-runtime code should continue to shrink in small
behavior-preserving moves. This map is a refactor aid, not a status ledger.

## Existing VM Shards

VM-facing shards currently live directly under `src/exec/`. Opcode dispatch
helpers use the `vm_*.zig` prefix; broader domain helpers generally use the
`*_ops.zig` suffix.

- `vm_arith.zig`: arithmetic opcode helpers.
- `vm_call.zig`: call and construct opcode helpers.
- `vm_control.zig`: branches, loops, returns, and control-flow helpers.
- `vm_eval_module.zig`: eval/module execution helpers.
- `exception_ops.zig` (renamed from `vm_exception_ops.zig` 2026-08-19; every
  importer already aliased it as `exception_ops`): named error construction,
  TDZ errors, pending
  exception matching, and related error-object helpers.
- `vm_gen_async.zig`: generator and async function helpers.
- `vm_literal.zig`: literal construction helpers.
- `vm_property.zig` and its splits (`vm_property_field.zig`,
  `vm_property_globals.zig`, `vm_property_locals.zig`,
  `vm_property_private.zig`, `vm_property_ref.zig`): property, reference,
  global read/write/delete, and related property fast-path opcode handlers.
- `property_direct.zig` (renamed from the historical `property_ic.zig`
  2026-08-19; the shape-keyed inline cache is long removed and the
  always-false `cachedSet*` zombie was deleted): non-cached direct
  own/prototype/global data-property lookup/write helpers.
- `vm_regexp.zig`: RegExp VM helpers.
- `vm_value.zig`: value conversion and primitive helper operations.

Domain helper shards such as `array_ops.zig`, `date_ops.zig`,
`iterator_ops.zig`, `json_ops.zig`, `object_ops.zig`, `string_ops.zig`, and
`value_ops.zig` are not pure opcode dispatch modules, but they are still useful
targets when shrinking `call_runtime.zig` around a coherent ECMAScript domain.

## Move Criteria

Move code out of `call_runtime.zig` only when the ownership boundary is clear:

- The target file has one coherent domain.
- Imports do not introduce cycles back through `call_runtime.zig`.
- Moved helpers retain the same ownership, rooting, and exception behavior.
- Callers reference the owning module directly; do not add new forwarding
  aliases in `call_runtime.zig`. The existing `qjsIteratorZip*` shells are
  a known deviation (backlog **H5**), not a license to add more.

Prefer leaf helper groups first. Avoid moving an orchestration function if its
callees would still force broad imports from `call_runtime.zig`.

## Candidate Domains

These domains are still reasonable candidates for future splits when touched:

- global object and global lexical environment operations.
- closure and var-ref operations.
- builtin wrapper glue that does not belong in an existing `builtins/` module
  (Reflect/Iterator-helper native records and similar `qjs*` call glue).

Do not create a new shard for a single unrelated helper. Leave nearby code in
place until there is a stable domain boundary.

## Validation Per Move

Minimum validation for a small move:

```sh
zig build zjs --summary all
git diff --check
```

For multi-domain moves or any observable behavior risk:

```sh
zig build test --summary all
zig build smoke --summary all
```

Run a relevant test262 slice when the moved code handles visible JavaScript
semantics.

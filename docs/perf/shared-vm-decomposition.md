# `vm/shared.zig` Decomposition Map

`src/engine/exec/vm/shared.zig` remains large and should continue to shrink in
small behavior-preserving moves. This map is a refactor aid, not a status
ledger.

## Existing VM Shards

Current files under `src/engine/exec/vm/` include:

- `arith.zig`: arithmetic opcode helpers.
- `call.zig`: call and construct related opcode helpers.
- `class.zig`: class evaluation helpers.
- `collection.zig`: collection-related VM helpers.
- `control.zig`: branches, loops, returns, and control-flow helpers.
- `date.zig`: Date-specific VM helpers.
- `eval_module.zig`: eval/module execution helpers.
- `exception_ops.zig`: named error construction, TDZ errors, pending-exception
  matching, and related error-object helpers.
- `gen_async.zig`: generator and async function helpers.
- `iter.zig`: iterator helpers.
- `json.zig`: JSON VM helpers.
- `literal.zig`: literal construction helpers.
- `property.zig`: property/global read-write-delete helpers and IC plumbing.
- `regexp.zig`: RegExp VM helpers.
- `value.zig`: value conversion and primitive helper operations.

## Move Criteria

Move code out of `shared.zig` only when the ownership boundary is clear:

- The target file has one coherent domain.
- Imports do not introduce cycles back through `shared.zig`.
- Moved helpers retain the same ownership, rooting, and exception behavior.
- Compatibility aliases are temporary and should be removed once callers have
  migrated.

Prefer leaf helper groups first. Avoid moving an orchestration function if its
callees would still force broad imports from `shared.zig`.

## Candidate Domains

These domains are still reasonable candidates for future splits when touched:

- coercion helpers (`toPrimitive`, `toString`, `toNumber`, truthiness, wrapper
  extraction).
- global object and global lexical environment operations.
- closure and var-ref operations.
- builtin wrapper glue that does not belong in an existing `builtins/` module.
- worker and `qjs:os`/`qjs:std` helper paths.

Do not create a new shard for a single unrelated helper. Leave nearby code in
place until there is a stable domain boundary.

## Validation Per Move

Minimum validation for a small move:

```sh
zig build test-exec --summary all
git diff --check
```

For multi-domain moves or any observable behavior risk:

```sh
zig build test --summary all
zig build smoke --summary all
```

Run a relevant test262 slice when the moved code handles visible JavaScript
semantics.

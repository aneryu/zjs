# Retired Property Inline Cache

The shape-keyed property inline cache described by older revisions of this file
is not part of the current engine.

Current facts:

- `src/core/ic.zig` does not exist.
- `src/bytecode.zig` has no IC slots or site tables.
- there is no `zjs_enable_ic` build option.
- QuickJS has no corresponding property IC.
- `src/exec/property_ic.zig` remains only as a historical filename for
  non-cached direct property helpers.
- `cachedDataPropertyValueForFastPath` always returns `null`.
- `cachedSetObjectDataPropertyForPutFastPath` always returns `false`.

Property opcodes still have fast paths, but they inspect current object, shape,
prototype, property flags, and class state on every execution. See
[Object And Shape Implementation](object-shape-design.md) for the active
contract.

Do not:

- report `ic_hit`, mono/poly/mega state, or per-site shape retention as current
  behavior;
- pass `-Dzjs_enable_ic=false`;
- interpret `prop_read_mono_loop` as an IC benchmark;
- restore an inline cache as a performance shortcut without an explicit change
  to the project's QuickJS-faithful optimization policy.

Historical IC commits and design details remain available in git history. They
are intentionally not preserved here as an active design.

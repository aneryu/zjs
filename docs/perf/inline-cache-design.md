# Inline Cache Implementation

This note describes the active shape-keyed inline cache implementation. It is
not a phase plan.

Primary owners:

- `src/engine/bytecode/ic.zig`
- `src/engine/bytecode/function.zig`
- `src/engine/exec/vm/property.zig`
- `src/engine/core/profile.zig`

Inline caches are enabled by default and can be disabled with:

```sh
zig build test -Dzjs_enable_ic=false --summary all
zig build zjs -Dzjs_enable_ic=false --summary all
```

## Cacheable Opcodes

IC slots are allocated for ordinary own-data property access sites in:

- `get_var`
- `get_var_undef`
- `put_var`
- `get_field`
- `get_field2`
- `put_field`

No property IC slots are allocated for bytecode containing `eval`,
`apply_eval`, or any `with_*` opcode. Those functions stay on the slow path
because dynamic scope changes invalidate the assumptions needed by the current
cache.

Private atoms are not installed in property ICs.

## Slot States

`bytecode.ic.Slot` uses these states:

- `empty`: no successful lookup has been cached.
- `mono`: one receiver shape has been cached.
- `poly`: two to four receiver shapes have been cached.
- `mega`: the site exceeded the four-entry polymorphic limit and no longer
  caches.
- `invalid`: reserved invalidation state.

Each entry retains the receiver shape. Prototype hits also retain the holder
shape. Entries store the observed `Shape.version` values and the resolved slot
index.

## Lookup Rules

Own-data lookup hits only when:

- receiver shape pointer matches.
- requested atom matches.
- cached receiver shape version matches the current receiver shape version.
- the cached slot still contains own data for the same atom.

Prototype-data lookup additionally checks:

- the holder shape pointer.
- the holder shape version.
- the holder slot still contains own data for the same atom.

Any miss falls back to the normal property path. Any version mismatch or stale
slot is treated as invalidated and also falls back to the normal path.

## Installation and Promotion

The slow path installs a slot only after it resolves an ordinary data property
that is safe to cache. Re-observing the same receiver shape updates the cached
version and slot index.

Promotion:

- first distinct shape: `empty -> mono`
- second distinct shape: `mono -> poly`
- up to four distinct shapes: remain `poly`
- fifth distinct shape: release retained guard shapes and promote to `mega`

Megamorphic sites do not re-enter mono/poly during the function lifetime.

## Profiling

`core.OpcodeProfile` records:

- `ic_hit`
- `ic_miss`
- `ic_invalidate`
- `ic_promote_poly`
- `ic_promote_mega`

Expose the counters with:

```sh
zig-out/bin/zjs --perf-json tests/zig-smoke/arith.js 2> reports/perf/current/arith-perf.json
```

The JSON is written to stderr.

## Validation

For IC changes, run:

```sh
zig build test --summary all
zig build smoke --summary all
git diff --check
```

Add relevant slices for property semantics:

```sh
./zig-out/bin/run-test262 -t 8 -c test262.conf \
  -d test262/test/language/expressions/property-accessors
./zig-out/bin/run-test262 -t 8 -c test262.conf \
  -d test262/test/language/statements/with
./zig-out/bin/run-test262 -t 8 -c test262.conf \
  -d test262/test/built-ins/Proxy
./zig-out/bin/run-test262 -t 8 -c test262.conf \
  -d test262/test/built-ins/Reflect
```

Performance checks should record a fresh measurement command and environment
with the owning change.

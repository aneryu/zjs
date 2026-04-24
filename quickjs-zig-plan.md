# QuickJS Zig Plan

## Current Focus

The project is converging QuickJS C semantics into the Zig VM while keeping the runnable `zjs` CLI stable.

## Compatibility Priorities

1. `JSON` behavior covered by `tests/zig-smoke/json.js`
2. `Math` behavior covered by `tests/zig-smoke/math.js`
3. `Date` behavior covered by `tests/zig-smoke/date.js`

Each completed compatibility slice should keep these commands green:

```bash
zig build test --summary all
zig build test-vm
zig build smoke
```

## Smoke Policy

`zig build smoke` is driven by `tests/zig-smoke/manifest.txt`. Each listed script must have a matching golden stdout file under `tests/zig-smoke/expected/`.

Dynamic behavior should be asserted through stable output. For example, print `typeof Date.now()` or a range check instead of printing wall-clock values.

## Structural Follow-Ups

- Keep semantic fixes scoped to one compatibility area at a time.
- Prefer moving mature built-in domains out of `src/engine/vm/builtins.zig` only when the extracted module can keep a narrow public helper surface.
- Keep `tools/compare/config.json` pointed at the smoke manifest so build smoke and comparison tooling do not drift.

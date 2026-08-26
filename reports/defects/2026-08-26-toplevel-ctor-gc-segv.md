# SIGSEGV: top-level script + array of >=8 constructor objects + read loop

Found 2026-08-26 while building the PERF-T-SPIKE workloads (driver session).
Reproduces on the frozen BASE-G0 merge-base binary (`14b0618d`, the
all-gates-green vintage) and on freshly built main — a pre-existing defect,
not introduced by any current line.

## Repro (11 lines, production `zjs`, rc build)

```js
function T(i) { this.i = i; }
var xs = [];
for (var i = 0; i < 8; i++) xs.push(new T(i));
var acc = 0;
for (var s = 0; s < 100; s++) {
  for (var i = 0; i < xs.length; i++) {
    acc += xs[i].i;
  }
}
print(acc);
```

`zjs repro.js` → exit 139 (SIGSEGV). Same via `-e`.

## Boundary conditions (all verified on the frozen merge-base binary)

| variant | result |
|---|---|
| 7 constructor objects (same loop) | OK |
| 8 constructor objects | **SIGSEGV** |
| 48 object literals `{i:i}` instead of `new T(i)` | OK |
| whole program wrapped in `function main(){...} main()` | OK |
| single constructor object, no array, 20k reads | OK |

The function-wrapped escape explains why the unit suite, test262 (49,778),
and Octane never hit this: benchmark harnesses and tests run inside
functions. The exposed surface is top-level script code.

## Debug-build evidence

`zjs-dev` (Debug) panics earlier and cleaner than the ReleaseFast SIGSEGV:

```
assert failed: tailcall_dispatch.zig:316
  @intFromPtr(pc) < @intFromPtr(vm.function.byteCode().ptr + len)
```

i.e. the dispatch loop's pc runs PAST the end of the top-level function's
bytecode. In ReleaseFast the corpse executes garbage and dies in
`op_return_slow` with `sp=0x0, pc=0x1`.

The `-T` allocation trace shows the crash lands mid-allocation, after a
long burst of repeating 88/64/48-byte allocation triples during the read
loop (the last trace line is truncated mid-write). Working hypothesis —
NOT yet root-caused: an allocation inside the loop triggers a collection
whose interaction with the active top-level eval frame corrupts VM state
(the same defect class as the 08-24 conservative-root campaign, but on the
production rc build). The n=8 threshold is consistent with an
allocation-count trigger crossing during the loop.

## Status

- Root cause: **not diagnosed** (deliberately stopped — this is a
  standalone correctness investigation, not the T-spike lane's scope).
- Impact on T-spike: none remaining — the four spike workloads are
  function-wrapped (also better measurement isolation).
- Assignment: owner to route (GC-adjacent skills suggest the GC session or
  a dedicated fix pass; the repro above should go into the regression suite
  with the fix).

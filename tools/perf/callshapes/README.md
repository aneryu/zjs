# Call-shape microbenchmarks

Prices the call / property / construction shapes that dominate Octane's
allocation-heavy benchmarks (RayTrace, EarleyBoyer, DeltaBlue) one shape at a
time, against `qjs` as the yardstick.

Each case is one JS file: a loop skeleton plus exactly one shape. Everything the
loop touches is a local of an enclosing `main`, so no case measures global-lookup
noise on top of the shape. `ctrl.js` is the loop skeleton alone and `empty.js` is
process startup alone; the reporter subtracts `empty` from every case, so what it
prints is per-operation cost, not per-process.

## Running

```bash
zig build zjs                                 # never measure a stale binary
tools/perf/callshapes/sample.sh 8 \
    zjs=./zig-out/bin/zjs qjs=/path/to/qjs > /tmp/cs.csv
python3 tools/perf/callshapes/report.py /tmp/cs.csv
```

`sample.sh` follows the same discipline as `tools/perf/property/sample.sh`: even
sample count, binary and case order reversed on even samples (ABBA), pinned to
CPU 19 because this host is big.LITTLE with two PMUs. It accepts any number of
binaries; `report.py` takes exactly two, so filter the CSV by label when you
sampled three (A/B a candidate against both the baseline and `qjs` in one run —
that keeps them interleaved instead of comparing across two sessions).

The reported ratio is always first-label / second-label in CSV appearance order.
`spread%` is the max (over both binaries) of the per-case cycle range as a
percentage of the median: treat any ratio delta smaller than the spread as noise.

## Cases

| id | shape | why |
| --- | --- | --- |
| `ctrl` | empty loop | the skeleton every other case adds to |
| `A` / `A2` | `f(1,2)` / `s += f(1,2)` | direct call, result discarded vs consumed |
| `B` | `o.f(1,2)` | method call (lookup fused into the call) |
| `C` / `C2` | `f.apply(o,[1,2])` / `f.apply(o,args)` | apply with and without the per-iteration array literal, so allocation separates from `build_arg_list` |
| `D` | `f.apply(o,arguments)` | the forwarding-wrapper shape |
| `E0` / `E1` / `E2` / `E4` | `arguments` with 0, 2 (`.length`), 2 (`[0]`), 4 args | `E0` is the fixed cost of materializing the object; `(E4-E0)/4` vs `(E1-E0)/2` is the per-argument var-ref cost |
| `F` | `new Pair(1,2)` | simple constructor, two own data properties |
| `G` | `this.initialize.apply(this, arguments)` | the RayTrace constructor; composes E, D, F and I |
| `H1` / `H2` | `o.x` / `o.x = v` | own data property read and write |
| `I` | `o.method()` | method resolved on the prototype |
| `J` | `o instanceof Pair` | `Symbol.hasInstance` lookup, native call, prototype walk |
| `K1` / `K2` | `array.length` / `plainobj.length` | control for `E1`: proves a `.length` read is not itself slow |
| `L0` | `new Empty()` | generic construct route with an empty body: prices the frame/instance machinery alone |
| `L3` / `L3p` | `new Three(1,2,3)`, default / shadowing prototype | `L3` matches zjs's simple-field construct fast path; `L3p`'s prototype `{x,y,z}` disqualifies it, so the pair measures the fast path, not shadowing |
| `L4` / `L4p` | same stores, pattern broken by a local | both halves on the generic route; `L4p - L4` is the true prototype-shadowing cost (≈0 in both engines) |
| `M1` / `M2` / `M3` | prototype data read / 4-deep chain / one site, two shapes | read-shape controls: all at or ahead of parity, so a slow read bucket cannot be blamed on these shapes |

Iteration counts are per case (tuned so each run is ~0.4s on `qjs`) and live in
two places that must agree: `var N` in the case file and `ITERS` in `report.py`.

## Interpreting

Two controls exist specifically to catch measurement mistakes, and both have
already earned their keep:

- `ctrl`, `H1`, `H2`, `K1` are shapes where zjs is at or ahead of parity. If one
  of them moves while you are changing an unrelated arm, you are looking at code
  layout, not at your change.
- `K1`/`K2` exist because a profile attributed 13% of `E0` to `op_get_length`.
  Pricing `.length` directly showed it at 0.96x/1.07x — the percentage was
  proportional attribution of a small absolute cost, not a finding.

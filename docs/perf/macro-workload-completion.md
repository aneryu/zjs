# Macro-workload completion under each collector

A record of which real workloads the engine can finish, per collector, and why
that question needed its own gate.

## Why this exists

On 2026-08-25 the tracing collector reached `test262 0/49778` with both unit
suites green — 2369/0 refcounting, 2397/0 tracing. Running the vendored Octane
suite against the same binary, twelve of twenty-six benchmarks failed.

That is not a small gap, and it is not bad luck. test262 cases are small and
short-lived: almost none of them allocate enough to trigger a minor collection,
and fewer still keep an object alive across one, so the generational write
barrier is barely exercised. A macro benchmark does the opposite — it builds a
large, long-lived object graph and then mutates it for seconds. Every failure
below was a live object reclaimed by a minor because some store into an old
owner did not remember it.

So a passing test262 says nothing about generational correctness, and the two
gates are not substitutes.

## The gate

```sh
zig build macro-check                      # refcounting
zig build macro-check -Dzjs_gc=trace_stw   # tracing
```

`tools/perf/bench_v8/check_completes.py` runs each vendored bench-v8 benchmark
on its own, then the combined suite, and fails if any of them does not print a
result. It asserts completion, not a score: it is a correctness gate, which is
why it lives in `build/gates.zig` and not under `perf-*`.

Per-benchmark rather than combined-only, because a failure that names itself is
worth far more than one that says "the suite died"; and combined last, because
some defects only appear once the heap is large enough.

## Octane 2.0, refcounting vs tracing (2026-08-25, at `d1c5a60e`)

Vendored at `/home/aneryu/javascript-zoo/bench`. ReleaseFast, unpinned, one run
each — this is a completion record, not a measurement, so run-to-run score
variation does not matter here.

| benchmark | refcounting | tracing |
|---|---|---|
| box2d | 7049 | **SEGV** |
| code-load | 35563 | 30229 |
| crypto | 2358 | 2310 |
| deltablue | 1450 | **InvalidBuiltinRegistry** |
| earley-boyer | 3879 | **InvalidBuiltinRegistry** |
| gbemu | 13909 | 14591 |
| mandreel | 16030 | 16842 |
| navier-stokes | 4873 | 4716 |
| pdfjs | 8224 | **InvalidBuiltinRegistry** |
| raytrace | 3631 | **SEGV** |
| regexp | 924 | 808 |
| richards | 1670 | **InvalidBuiltinRegistry** |
| richards.es1 | 1692 | **InvalidBuiltinRegistry** |
| richards.js1 | 1772 | 1855 |
| richards.porffor | 1696 | **InvalidBuiltinRegistry** |
| richards.quad-wheel | completes | completes |
| richards.rapidus | completes | **InvalidBuiltinRegistry** |
| splay | 16087 | **SEGV** |
| typescript | 22156 | **TypeError: not a function** |
| v8-v7 | 2630 | **InvalidBuiltinRegistry** |
| v8-v7.espruino | 2720 | **InvalidBuiltinRegistry** |
| zlib | 4380 | 4354 |

Failing under both collectors, so not attributable to the collector:
`richards.ngs`, `richards.tiny-js`, `richards.ucode` (ReferenceError — missing
language surface) and `richards.quanta` (prints `NaN` in both).

### Reading the table

Twelve failures are collector-attributable, in three shapes:

- **`InvalidBuiltinRegistry`** (nine): raised by `Object.materializeAutoInit`
  when a lazily-installed builtin's auto-init slot can no longer resolve its
  realm or its descriptor.
- **SEGV** (three): `box2d`, `raytrace`, `splay`.
- **`TypeError: not a function`** (one): `typescript`.

All of them are minor-specific. `ZJS_GC_STRESS=off` and `ZJS_GC_NO_MINOR=1`
both make them complete, which localises every one to the young-generation
path rather than to the tracer as a whole.

Where the tracer does complete, throughput is close to refcounting — 0.85x to
1.05x across code-load, crypto, gbemu, mandreel, navier-stokes, regexp and
zlib. The collector's problem today is correctness, not speed.

## What the gate cannot tell you

Completion is a floor, not a proof. A workload that finishes may still be
retaining garbage, and this gate would not notice; `--gc-stats` and the
baseline in `gc-baseline.md` are for that. And the Octane table above is
recorded here rather than gated, because those benchmarks live outside the
repository; the gate covers the vendored bench-v8 subset, which is the part
that travels with the source.

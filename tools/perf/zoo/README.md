# zoo (Octane) macro comparison

`run_zoo_compare.py` is the fixed entry point for comparing zjs against pinned
QuickJS on the [javascript-zoo](https://github.com/) vendored Octane 2.0 suite.
It exists so this comparison is reproducible rather than re-improvised, and so
it carries the same discipline as the whole-process microbench contract
(`reports/perf/qjs-align/measurement-contracts.md`).

## Direction of the number

zoo benchmarks are **self-scoring and higher-is-better**. This tool therefore
reports `ratio = zjs / qjs`, so **below 1.0 means zjs is slower** — the opposite
direction from the time-based tools in `tools/perf/`. That inversion is
deliberate: it keeps each benchmark in the units it publishes. Every emitted
field names its direction, and the artifact carries `scoreDirection`.

`MandreelLatency` and `SplayLatency` are reported but kept **out** of the
headline geomean: they are a different quantity from the throughput scores and
averaging them together would make the aggregate uninterpretable.

## Usage

The tool refuses to run unless it is already pinned, so invoke it under both
`taskset` and the exclusive host lock:

```bash
flock -x /tmp/zjs-host-heavy.lock taskset -c 19 \
  python3 tools/perf/zoo/run_zoo_compare.py \
    --zjs zig-out/bin/zjs \
    --qjs /home/aneryu/quickjs/qjs \
    --samples 4 \
    --cpu 19 \
    --output reports/perf/qjs-align/<date>/zoo-compare.json
```

Build `zjs` first — a stale binary has produced wrong campaign conclusions
before.

### Parallel cluster-swapped comparison

For a faster macro-score comparison, two equal CPU lists can be used as paired
lanes. Each benchmark runs zjs and QuickJS simultaneously on matching lane
positions, then the engines swap clusters on the next sample. For example,
five lanes use ten CPUs and run five benchmarks per batch:

```bash
flock -x /tmp/zjs-host-heavy.lock taskset -c 5-9,15-19 \
  python3 tools/perf/zoo/run_zoo_compare.py \
    --zjs zig-out/bin/zjs \
    --qjs /home/aneryu/quickjs/qjs \
    --samples 4 \
    --parallel-clusters 5-9 15-19 \
    --output reports/perf/qjs-align/<date>/zoo-compare-parallel.json
```

The lists must be disjoint and the same width. Their order defines paired
lanes: CPU 5 is paired with CPU 15, CPU 6 with CPU 16, and so on. The runner
requires its effective affinity to equal the union of both lists, records every
engine/CPU assignment, and verifies that neither binary changed during the
measurement.

Parallel execution can expose shared-cache or memory contention that serial
execution does not. Calibrate a host and lane count against the default serial
runner before using parallel results as an acceptance gate. A one-lane form,
such as `--parallel-clusters 9 19` under `taskset -c 9,19`, keeps the paired
engine overlap while avoiding cross-benchmark contention. Fixed-work PMU
attribution remains serial; `run_zoo_fixed_pmu.py` does not use this mode.

## Fixed-work PMU attribution

The normal Octane protocol runs each benchmark for roughly one second. Faster
engines therefore execute more iterations, so whole-process instructions and
cycles from that protocol do not describe equal work. Use the deterministic
runner when attributing a score gap:

```bash
flock -x /tmp/zjs-host-heavy.lock taskset -c 19 \
  python3 tools/perf/zoo/run_zoo_fixed_pmu.py \
    --zjs zig-out/bin/zjs \
    --qjs /home/aneryu/quickjs/qjs \
    --benches raytrace earley-boyer splay typescript pdfjs \
    --samples 4 \
    --cpu 19 \
    --pmu armv8_pmuv3_1 \
    --iteration-divisor 4 \
    --output reports/perf/qjs-align/<date>/zoo-fixed-pmu.json
```

The runner makes temporary benchmark copies that set Octane's
`doWarmup=false` and `doDeterministic=true`. Both engines therefore execute the
same declared `deterministicIterations` batches. It refuses odd sample counts,
un-pinned execution, missing explicit-PMU counters, or non-canonical benchmark
harness markers. Ratios are `zjs / qjs`; instructions are the primary
work-removal signal, while cycles, IPC, branches, and cache events support
attribution. `--iteration-divisor` divides both `deterministicIterations` and
`minIterations` by the same factor for both engines, rounding each result up;
use it to shorten exploratory sweeps, and keep the unscaled workload for final
attribution. The ordinary throughput runner remains the macro acceptance gate.

## What it fails closed on

- **Odd `--samples`.** Refused, not rounded up. The order alternates on sample
  parity, so an odd count leaves one engine leading more often; measurement
  contract #3 exists because that has voided headline numbers twice. Silently
  adjusting the count would change the measurement design behind the caller.
- **Affinity that is not exactly the requested CPU set.** Serial mode requires
  exactly `{--cpu}`. Parallel mode requires exactly the union of both clusters;
  a wider allowed-list is refused.
- **A benchmark that exits nonzero, times out, or prints no parseable score**,
  or where the two engines report different score keys — any of these means the
  comparison is not like-for-like.
- **A binary that changes during the run.** Both full-file SHA-256 values are
  captured before the first sample and verified again after the last sample.

## Artifact

The JSON records both binaries' SHA-256 and repository commit and dirty state,
the zoo checkout's commit, kernel, CPU model, effective affinity, the sample
count, total measurement wall time, the full execution order log, every raw
score, and per-benchmark median / min / max. Provenance is the point: a score
without the binary identity that produced it cannot be compared against a later
run.

Parallel artifacts additionally name `executionMode`, the ordered CPU lists,
lane count, simultaneous batch groups, and the per-sample engine/CPU mapping.
The serial artifact shape remains backward compatible; the added mode fields
are additive.

Schema 2 uses `statistics.median`; with the required even sample count this
averages the two middle values. Historical schema-1 artifacts selected the
upper middle value, so their stored summaries must not be compared directly
with schema-2 summaries. Their raw samples can be reaggregated with the schema-2
definition when a historical comparison is needed.

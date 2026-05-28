# Performance Workflow

This directory contains performance notes and historical reports for `zjs`.
The previous local QuickJS comparison scripts were removed with the vendored
`quickjs/` checkout, so checked-in microbench reports are retained as
historical context rather than active gates.

Current design notes:

- [Object and shape implementation](object-shape-design.md)
- [Inline cache implementation](inline-cache-design.md)
- [`vm/shared.zig` decomposition map](shared-vm-decomposition.md)

## Current Benchmark Entry

Run the current repeatable diagnostic benchmark with:

```sh
zig build perf-benchmark --summary all
```

This builds the ReleaseFast `zjs-test262` CLI and runs
`tests/perf/microbench.js` with `--perf-json`. The fixture checks deterministic
results for arithmetic, dense array, object property, and string loops before
emitting timing JSON. Use the JSON as a local diagnostic signal, not as a
release gate.

## Checked-In Report

The checked-in report is `reports/perf/current/microbench.json`.
Its summary is:

- 73 selected cases.
- 72 compatible cases.
- 1 unsupported case in the tracked report.
- 0 skipped cases.
- Geometric mean `zjs/qjs`: `1.0157757404632615`.

Generate the top-10 slowest ratio summary from a JSON report:

```sh
node tools/perf/top10_report.js \
  --output reports/perf/current/top10.md \
  reports/perf/current/microbench.json
```

Do not use this file as proof that the current working tree has the same
timings. A fresh performance workflow should add its own measurement command
and record the environment with the owning change.

## Baselines

Baseline reports live under `reports/perf/baseline/`.

Record the environment:

```sh
node tools/perf/write_env.js \
  --iters 30 \
  --warmup 5 \
  --output reports/perf/baseline/env.md
```

Generate the baseline top-10 summary:

```sh
node tools/perf/top10_report.js \
  --output reports/perf/baseline/top10.md \
  reports/perf/baseline/microbench-releasefast.json
```

## Diff Reports

Compare two JSON reports:

```sh
node tools/perf/diff_report.js \
  reports/perf/baseline/microbench-releasefast.json \
  reports/perf/current/microbench.json
```

By default, the diff fails when sample settings differ, compatible case count
drops, unsupported/skipped count increases, geometric mean regresses by more
than 5%, or a case regresses by more than 10% and more than 0.05 ms.

Useful options:

```sh
node tools/perf/diff_report.js --json OLD.json NEW.json
node tools/perf/diff_report.js --warn-case-regressions OLD.json NEW.json
node tools/perf/diff_report.js --ignore-geomean-regression OLD.json NEW.json
node tools/perf/diff_report.js --allow-sample-config-drift OLD.json NEW.json
```

Use `--allow-sample-config-drift` only for retrospective diagnostics; gate-like
comparisons should use matching `iters` and `warmup`.

## Runtime Profiling

For coarse internal stage timing:

```sh
zig-out/bin/zjs --perf-json tests/zig-smoke/arith.js 2> reports/perf/current/arith-perf.json
```

The JSON is written to stderr so script stdout remains comparable.

Linux sampling:

```sh
perf record -F 999 -g -- zig-out/bin/zjs /tmp/case.js
perf report
```

macOS sampling:

```sh
xcrun xctrace record \
  --template "Time Profiler" \
  --output reports/perf/current/zjs.trace \
  --launch -- zig-out/bin/zjs /tmp/case.js
```

## Functional Gates

Run semantic checks before accepting performance-sensitive changes:

```sh
zig build test --summary all
zig build smoke --summary all
```

Run a relevant test262 subset when the optimization touches observable
JavaScript semantics.

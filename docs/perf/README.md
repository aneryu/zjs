# Performance Workflow

This directory contains performance notes and historical reports for `zjs`.
The previous local C QuickJS comparison reports are retained as historical
context. The active performance gate is now a ZJS self-baseline regression
check, so it does not require a local C QuickJS binary.

Current design notes:

- [Object and shape implementation](object-shape-design.md)
- [Inline cache implementation](inline-cache-design.md)
- [`vm/shared.zig` decomposition map](shared-vm-decomposition.md)

## Current Benchmark Entries

Run the active multi-case self-baseline gate with:

```sh
zig build perf-self-check --summary all
```

This builds the ReleaseFast `zjs` CLI, records a fresh multi-case report under
`.zig-cache/perf/current/`, and compares it with
`reports/perf/baseline/microbench-zjs-releasefast.json`.

Refresh the checked-in self baseline explicitly with:

```sh
zig build perf-self-update-baseline --summary all
```

Only refresh the baseline when an intentional performance change has separate
semantic validation evidence.

Run the current repeatable diagnostic benchmark with:

```sh
zig build perf-benchmark --summary all
```

This builds the ReleaseFast `zjs` CLI and runs
`tests/perf/microbench.js` with `--perf-json`. The fixture checks deterministic
results for arithmetic, dense array, object property, and string loops before
emitting timing JSON. Use the JSON as a local diagnostic signal, not as a
release gate.

## Checked-In Reports

The active checked-in baseline is
`reports/perf/baseline/microbench-zjs-releasefast.json`.

The historical C QuickJS comparison report is
`reports/perf/current/microbench.json`. Its summary is:

- 73 selected cases.
- 73 compatible cases in the tracked report.
- 0 unsupported cases in the tracked report.
- 0 skipped cases.
- Historical geometric mean `zjs/qjs`: `0.8414527007796604`.

Generate the top-10 slowest ratio summary from a JSON report:

```sh
node tools/perf/top10_report.js \
  --output reports/perf/current/top10.md \
  reports/perf/current/microbench.json
```

Do not use the historical C QuickJS file as proof that the current working tree
has the same relative timings.

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

For the checked-in historical reports, refresh the local summary bundle with:

```sh
zig build perf-compare --summary all
```

This records `reports/perf/current/env.md`, refreshes
`reports/perf/current/top10.md`, and writes `reports/perf/current/diff.md` from
the checked-in `zjs-microbench` JSON reports. It does not refresh
`reports/perf/current/microbench.json`; `zig build perf-benchmark` is a separate
single-script runtime smoke that emits CLI `--perf-json`, not the multi-case
comparison format consumed by `top10_report.js` and `diff_report.js`.

The build step allows the checked-in baseline/current sample-count drift and
reports per-case regressions without failing. Performance-sensitive PRs should
still run `zig build perf-self-check --summary all`, and may also run a strict
C QuickJS comparison when an external `qjs` binary is available.

## Runtime Profiling

For coarse internal stage timing:

```sh
zig-out/bin/zjs --perf-json tests/zig-smoke/arith.js 2> reports/perf/current/arith-perf.json
```

The JSON is written to stderr so script stdout remains comparable. Use the
checked runtime-profile helper below when you need opcode rows in the artifact.

For a checked runtime-profile artifact that keeps script stdout separate and is
not confused with `zjs-microbench` multi-case reports:

```sh
node tools/perf/run_runtime_profile.js \
  --output reports/perf/current/runtime/uri_decode_4byte.json \
  --stdout reports/perf/current/runtime/uri_decode_4byte.stdout \
  --expect-stdout $'65536\n' \
  --expect-opcode-max get_var=67626 \
  --expect-opcode-max get_var_ref0=0 \
  --expect-opcode-max put_var=1042 \
  --expect-opcode-max push_i16=1040 \
  --expect-opcode-max goto16=0 \
  --expect-opcode-max add=0 \
  --expect-opcode-max if_false8=1 \
  reports/perf/current/scripts/uri_decode_4byte.js
```

The helper runs `--perf-json --profile-opcodes`, strips the textual opcode dump
from stdout, and stores stage timings, memory counters, IC counters, and sorted
opcode rows in one JSON artifact. Opcode-count expectations are deterministic
guards for focused hot-path regressions; use max thresholds so later reductions
continue to pass.

Focused runtime-profile shortcuts are also available:

```sh
zig build perf-uri-profile --summary all
zig build perf-uri-component-profile --summary all
zig build perf-prop-global-profile --summary all
zig build perf-proto-global-profile --summary all
zig build perf-prop-poly3-profile --summary all
zig build perf-call2-global-profile --summary all
zig build perf-closure-call-global-profile --summary all
zig build perf-string-loop-profile --summary all
zig build perf-empty-loop-profile --summary all
zig build perf-runtime-profiles --summary all
```

Compare two runtime-profile artifacts:

```sh
node tools/perf/diff_runtime_profile.js \
  --require-improvement vm_run_ns:0.95 \
  OLD-runtime-profile.json \
  NEW-runtime-profile.json
```

Opcode-specific improvement gates are also supported:

```sh
node tools/perf/diff_runtime_profile.js \
  --require-improvement opcode_count:get_var_ref0:0.1 \
  OLD-runtime-profile.json \
  NEW-runtime-profile.json
```

Use `--warn-regressions` for noisy exploratory runs and keep strict thresholds
for evidence attached to a performance-sensitive change.

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
zig build perf-self-check --summary all
```

Run a relevant test262 subset when the optimization touches observable
JavaScript semantics.

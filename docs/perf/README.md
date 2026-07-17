# Performance Workflow

This directory contains performance notes and checked performance artifacts for
`zjs`. The active performance gate is a ZJS self-baseline regression check, so
it does not require a local C QuickJS binary.

Current design notes:

- [Object and shape implementation](object-shape-design.md)
- [Inline cache implementation](inline-cache-design.md)
- [`exec/call_runtime.zig` decomposition map](shared-vm-decomposition.md)

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

## Checked-In Artifacts

The active checked-in self baseline is
`reports/perf/baseline/microbench-zjs-releasefast.json`.

Its environment note is `reports/perf/baseline/env-zjs-self.md`. Refresh it
with:

```sh
node tools/perf/write_env.js \
  --iters 30 \
  --warmup 5 \
  --output reports/perf/baseline/env-zjs-self.md \
  --notes "ZJS self-baseline report; qjs is intentionally not configured for this gate. This 64-bit build uses the default 16-byte JSValue representation."
```

Runtime-profile artifacts are checked under `reports/perf/current/runtime/`,
with their source scripts in `reports/perf/current/scripts/`.

## Self-Baseline Diffs

Compare two `zjs-microbench` JSON reports:

```sh
node tools/perf/diff_report.js \
  reports/perf/baseline/microbench-zjs-releasefast.json \
  .zig-cache/perf/current/microbench-zjs-releasefast.json
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
zig-out/bin/zjs --perf-json -e "for(var i=0; i<100000; i++) {}" 2> .zig-cache/perf/current/perf.json
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

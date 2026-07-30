# Performance Workflow

This directory contains performance notes and checked performance artifacts for
`zjs`. The active performance gate is a ZJS self-baseline regression check, so
it does not require a local C QuickJS binary.

Current design notes:

- [Object and shape implementation](object-shape-design.md)
- [Retired inline-cache note](inline-cache-design.md)
- [`exec/call_runtime.zig` decomposition map](shared-vm-decomposition.md)
- [Current zjs / pinned QuickJS subsystem baseline](../qjs-align/SUBSYSTEM-DIFFERENCE-BASELINE-2026-07-27.md)

## Current Benchmark Entries

Run the active multi-case self-baseline gate with:

```sh
zig build perf-self-check --seed 0 --summary all
```

This builds the ReleaseFast `zjs` CLI, records a fresh multi-case report under
`.zig-cache/perf/current/`, and compares it with
`reports/perf/baseline/microbench-zjs-releasefast.json`.

Refresh the checked-in self baseline explicitly with:

```sh
zig build perf-self-update-baseline --seed 0 --summary all
```

Only refresh the baseline when an intentional performance change has separate
semantic validation evidence.

Run the current repeatable diagnostic benchmark with:

```sh
zig build perf-benchmark --seed 0 --summary all
```

This builds the ReleaseFast `zjs` CLI and runs
`tests/perf/microbench.js` with `--perf-json`. The fixture checks deterministic
results for arithmetic, dense array, object property, and string loops before
emitting timing JSON. Use the JSON as a local diagnostic signal, not as a
release gate.

### Whole-process measurement contract

`tools/compare/run_microbench.js` is governed by
`tools/compare/measurement_policy.json`, the authoritative policy. Nothing reads
thresholds from the artifact under test.

`--formal` turns on formal sampling. It fails closed -- non-zero exit,
`complete=false`, `headline=null`, `pairedGeomean=null` -- when the sampling
design cannot be balanced (odd sample count, odd warmup, an artifact-declared
order that does not match the recorded execution, a treatment missing from a
round), when the collector or a measured child is not pinned to exactly the
requested CPU, when affinity moves during the run, when the PMU serving the CPU
cannot be identified, or when required provenance is missing.

```sh
ZJS_MEASUREMENT_LOCK=/tmp/zjs-host-heavy.lock ZJS_MEASUREMENT_LOCK_MODE=exclusive \
flock -x /tmp/zjs-host-heavy.lock taskset -c 19 bun tools/compare/run_microbench.js \
  --formal --cpu 19 --iters 8 --warmup 4 \
  --zjs path/to/zjs --qjs path/to/qjs --output /tmp/microbench.json

bun tools/compare/validate_measurement_artifact.js --formal /tmp/microbench.json
```

The validator additionally refuses a snapshot taken from a dirty worktree, a
case whose recorded source hash disagrees with the suite table, a startup
baseline from a different measurement generation, and any artifact carrying its
own policy body.

`startupAdjustedGeometricMean` is permanently `null`: it is diagnostic-only and
not headline eligible. Per-case adjusted ratios exist only for cases whose
startup residual clears the startup IQR, the case's own IQR and the minimum time
resolution; everything else is `unresolved`.

Contract and red-team suites:

```sh
zig build perf-measurement-contract
bun tools/compare/test_measurement_redteam.js --zjs path/to/zjs --qjs path/to/qjs --cpu 19
```

The red-team suite requires a clean worktree: the reference artifact it tampers
with must record `dirty=false`, otherwise every attack is adjudicated by the
dirty-worktree rule instead of its own.

### Session mode

`--sessions N` (or `BENCH_SESSIONS`) groups ABBA rounds into independent timing
sessions, each with its own warmup; `--interleaved` requires it. Session mode is
**off by default** and session results are never headline eligible: the artifact
carries a versioned `meta.sessions` block (`schemaVersion: 2`) and session
samples live in their own pool, never merged into the legacy
one-process-per-case pool. With `--sessions 1` and no `--interleaved` the legacy
path is used unchanged.

### Native callback and execution-root suite

`native-callback` is the mechanism-focused suite for synchronous
native-to-bytecode re-entry. It covers direct, `.call`, `.apply`,
`Reflect.apply`, and spread calls at argument counts 0/1/2/8/9/16/64; dense,
holey, generic array-like, and Proxy argument sources; bytecode, native, bound,
and Proxy targets; Array, Map, JSON, and Promise callbacks; callback-to-helper
chains; and Promise-job, generator-resume, and async-resume negative controls.
Every runnable case prints a deterministic checksum before it is timed.
Cross-Realm construction is listed explicitly as unsupported by the common
qjs/zjs CLI surface and remains covered by `src/tests/exec.zig`.

Record the full current ReleaseFast diagnostic with:

```sh
taskset -c 19 zig build perf-native-callback --seed 0 --summary all
```

The step uses five warmups, 30 timed samples, three independent sessions, and
ABBA interleaving. It writes
`.zig-cache/perf/current/native-callback-zjs-releasefast.json`. Pin an isolated
CPU externally on Linux; the runner deliberately does not choose a machine-
specific CPU.

For an old/new stage comparison, keep the old binary in the reference column
of both reports so stdout remains checked and the new report directly
interleaves old/new:

```sh
taskset -c 19 bun tools/compare/run_microbench.js \
  --suite native-callback \
  --qjs /path/to/old-zjs --zjs /path/to/old-zjs \
  --interleaved --sessions 3 --warmup 5 --iters 30 \
  --output /tmp/native-callback-old.json

taskset -c 19 bun tools/compare/run_microbench.js \
  --suite native-callback \
  --qjs /path/to/old-zjs --zjs /path/to/new-zjs \
  --interleaved --sessions 3 --warmup 5 --iters 30 \
  --output /tmp/native-callback-new.json
```

Then apply strict stage thresholds, including each named completion target:

```sh
node tools/perf/diff_report.js \
  --require-case-improvement apply_argc0:0.60 \
  --require-case-improvement apply_argc1:0.65 \
  --require-case-improvement reflect_apply_argc1:0.65 \
  --require-case-improvement apply_argc64:0.70 \
  --require-case-improvement array_foreach_bytecode:0.60 \
  --require-case-improvement map_foreach_bytecode:0.60 \
  --require-case-improvement array_callback_helper:0.45 \
  --require-case-improvement map_callback_helper:0.45 \
  --case-regression-ratio 1.05 \
  --geomean-regression-ratio 1.02 \
  /tmp/native-callback-old.json \
  /tmp/native-callback-new.json
```

Do not use the full-suite geomean as the callback-cohort acceptance number:
the full suite intentionally contains direct-call and execution-root controls.
Capture matching old/new reports with these category selectors:

```sh
--category apply \
--category arg-shape \
--category target-bytecode \
--category callback-bytecode \
--category callback-helper
```

Apply `--geomean-improvement-ratio 0.70` to those two cohort-only reports.
Separately capture the control report with:

```sh
--category call-control \
--category target-control \
--category callback-native-control \
--category hotpath-control \
--category root-control
```

The control diff uses `--case-regression-ratio 1.05` and
`--geomean-regression-ratio 1.02`, without an improvement requirement. Spread
has its own category because it enters the VM directly rather than crossing a
native fence.

Each JSON timing row records samples, standard deviation, CV, and per-session
statistics. If either engine's CV exceeds 5%, lengthen that case's useful
workload and rerun; do not accept a noisy ratio. For a pinned QuickJS
comparison, the normalized re-entry cost for any bytecode/native pair is
`(bytecode row zjs/qjs) / (native row zjs/qjs)`, which separates callback
re-entry cost from the surrounding builtin implementation.

## Checked-In Artifacts

The active checked-in self baseline is
`reports/perf/baseline/microbench-zjs-releasefast.json`.

The checked `microbench-vs-quickjs.json`, `hotpath-vs-quickjs.json`, and
`env-vs-quickjs.md` are historical: they were captured on 2026-06-13 against
QuickJS-ng 0.15 with a then-default 8-byte zjs value representation and
mechanisms that have since been removed. Do not use them as the current
Bellard-QuickJS comparison. Regenerate a pinned comparison with binary hashes,
CPU affinity, output validation, and the current 16-byte default before making
cross-engine claims.

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
comparisons should use matching iterations, warmups, sessions, and interleaving
mode.

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
zig build perf-uri-profile --seed 0 --summary all
zig build perf-uri-component-profile --seed 0 --summary all
zig build perf-prop-global-profile --seed 0 --summary all
zig build perf-proto-global-profile --seed 0 --summary all
zig build perf-prop-poly3-profile --seed 0 --summary all
zig build perf-call2-global-profile --seed 0 --summary all
zig build perf-closure-call-global-profile --seed 0 --summary all
zig build perf-string-loop-profile --seed 0 --summary all
zig build perf-empty-loop-profile --seed 0 --summary all
zig build perf-runtime-profiles --seed 0 --summary all
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
zig build test --seed 0 --summary all
zig build smoke --seed 0 --summary all
zig build perf-self-check --seed 0 --summary all
```

Run a relevant test262 subset when the optimization touches observable
JavaScript semantics.

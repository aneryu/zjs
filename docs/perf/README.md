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

The JSON is written to stderr so script stdout remains comparable. Its stage
timings and memory counters remain usable.

Per-opcode profiling is temporarily unavailable. The build option
`-Dzjs_enable_opcode_profile=true`, CLI `--profile-opcodes`,
`tools/perf/run_runtime_profile.js`, and the `perf-*-profile` build shortcuts
still exist, but the dispatcher no longer imports the profiling scope. A real
script therefore reports zero executed opcodes. Do not refresh checked runtime
profile artifacts or use opcode rows for attribution until the scope is
restored and an end-to-end non-zero-count test is part of the gate.

Existing files under `reports/perf/current/runtime/` are historical evidence
from builds where opcode instrumentation was connected. They are not a
description of the current binary.

Compare two runtime-profile artifacts:

```sh
node tools/perf/diff_runtime_profile.js \
  --require-improvement vm_run_ns:0.95 \
  OLD-runtime-profile.json \
  NEW-runtime-profile.json
```

`diff_runtime_profile.js` can still compare non-opcode fields in existing
artifacts. Its opcode-specific gates are historical-only until profiling is
restored. Use `--warn-regressions` for noisy exploratory runs and keep strict
thresholds for evidence attached to a performance-sensitive change.

### Linux sampling and PMU counters

Measured on this host on 2026-08-07 (aarch64 big.LITTLE, Cortex-X925 +
Cortex-A725, Zig 0.16.0, perf 6.17.9). The generic advice found in most Zig
profiling write-ups needs four corrections here; each one below is backed by a
measurement, not by extrapolation.

**Build: use `zig build zjs` as-is. Do not add profiling flags.**

The shipped `zjs` is already `ReleaseFast` with full symbols
(`file` reports `with debug_info, not stripped`; `nm` finds 6199 symbols), so
`-fno-strip` is a no-op here.

`-fno-omit-frame-pointer` is actively harmful. `internal_fast_mod` in
`build.zig` sets `.omit_frame_pointer = true` deliberately, because the
tail-call threaded dispatcher has one handler per opcode and a frame pointer
adds a prologue/epilogue to every one of them. Rebuilding with
`.omit_frame_pointer = false` and comparing interleaved A/B/B/A on pinned CPU
19:

| workload | instructions | cycles |
|---|---|---|
| VM dispatch loop (`s += i`, 60M iters) | 12.173G → 13.614G (**+11.8%**) | 2.272G → 2.831G (**+24.6%**) |
| code-load payload (parse-only) | 12.19M → 12.72M (**+4.4%**) | within noise |

A profile taken on such a build describes a program that is 24.6% slower in the
loop you care about, and the added cost lands *uniformly on every handler*,
which systematically flattens the relative weights you are trying to read.

The premise behind the flag does not hold either: fp unwinding already works
with `omit_frame_pointer = true`, because handlers never touch `x29`, so the
unwinder walks out through the enclosing `runWithCallEnv` frame. A `--call-graph
fp` record against the shipped binary returns complete stacks
(`op_dup;runWithCallEnvAfterInterruptPoll;runWithCallEnv;eval;...`).

**Pin to one CPU cluster — there are two PMUs.**

Unpinned `perf stat` splits every event across both PMUs at roughly half
coverage each and reports two unrelated IPC figures (measured: 3.75 and 5.70);
neither is the program's IPC, and summing them is meaningless because the
clusters differ in frequency and width.

```text
armv8_pmuv3_0 -> CPU 0-4,10-14
armv8_pmuv3_1 -> CPU 5-9,15-19
```

```sh
taskset -c 19 perf stat -e cycles,instructions,branches,branch-misses \
  zig-out/bin/zjs /tmp/case.js
```

Pinned, the counters collapse onto a single PMU and IPC becomes real. The rows
for the other PMU correctly read `<not counted>`.

**Prefer a flat profile; `-g` adds little for the dispatch loop.**

Under tail-call threading the handler-to-handler `musttail` transfer leaves no
stack record, so every opcode appears flat under `runWithCallEnv` and the
op-to-op sequence is unrecoverable. `-g` also double-counts;
`tools/perf/closure_alloc/profile_stages.py` already records flat for this
reason. Use `-g` when the question is about the call path *into* the VM, not
about the VM loop itself.

```sh
taskset -c 19 perf record -F 4999 -o /tmp/case.data zig-out/bin/zjs /tmp/case.js
perf report -i /tmp/case.data --stdio --no-children -q
```

Raise `-F` for short cases: `-F 999` on a 47ms case yielded 16 samples total.

**Resolve inlining before trusting any symbol row.**

`ReleaseFast` inlines aggressively, so a hot symbol name is usually the
*outermost* frame of an inline stack and attributing cost to it is wrong. A
measured example: `perf report` credits 31.32% to
`parser.lexer.LexerImpl.nextInto`, but the sampled address resolves to

```text
parser.lexer.LexerImpl.bump      src/parser.zig:604
parser.lexer.LexerImpl.lexString src/parser.zig:1141
parser.lexer.LexerImpl.nextInto  src/parser.zig:499
```

Always expand the address before reading the assembly. `perf report --inline`
does *not* expand these in flat mode, so use `addr2line`:

```sh
perf script -i /tmp/case.data -F ip,sym | grep <symbol> | awk '{print $1}' | sort -u
addr2line -f -i -e zig-out/bin/zjs 0x<ip>
```

**Known limits on this host.** `perf_event_paranoid` is `1`, so
`/proc/kallsyms` is unreadable and kernel samples appear as bare
`[unknown] [k] 0x…` addresses — in the code-load profile above that was 43% of
all samples, i.e. the single largest row was unattributable. Account for it
before concluding that the visible user-space rows are the whole picture.

**Before drawing a conclusion from any two builds**, apply the existing
discipline: interleaved A/B on fixed binaries (build layout alone moves results
by up to ±2.8%), and read
[Zig build bistability](ZIG-BUILD-BISTABILITY-2026-07.md) — independently
produced binaries alternate between two distinct code states, which contaminates
any cross-build comparison.

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

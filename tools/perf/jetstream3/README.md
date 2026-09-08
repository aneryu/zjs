# JetStream 3 JS subset: diagnostic integration

The shell uses the production ReleaseFast engine and existing embedding APIs.
It implements file/script loading and JSC-style realm creation without adding
public CLI globals. Callback timers use the existing event loop, support arguments,
intervals and cancellation, and clamp invalid/out-of-range delays to 1 ms. String
timer handlers are not supported. This is a compatibility survey, not a replacement performance
gate or an official JetStream score.

Pinned upstream: https://github.com/WebKit/JetStream/tree/06785cf861ac44855f168cbbe829278c2802e6de

`inventory.mjs` evaluates upstream registration code under Node (no workloads) and
selects default + JS, excluding WorkerTests and audited required Wasm dependencies.
Candidate profile v2 has 62 top-level entries, including the 12-child Sunspider
group. The initial 63-entry census found that JS-tagged source-map-wtb actually
calls WebAssembly.instantiate with mappings.wasm; v2 excludes it with evidence.
The original failed record is retained, not reclassified as an engine failure.
The 12 default non-JS and 2 Worker entries are outside this shell subset; 17 other
upstream entries are disabled by upstream. Language failures remain in scope.
Resource dependencies still require runtime auditing; tags alone are not proof.

Build under the repository's normal build lock and CPU policy:

```sh
zig build perf-jetstream-shell check
python3 tools/perf/jetstream3/test_shell.py zig-out/bin/zjs-jetstream
```

Acquire an upstream checkout in a worktree-local scratch directory, detach at the
pin, and prepare compressed assets before any measurement. No npm install needed:

```sh
python3 tools/perf/jetstream3/prepare.py .scratch/jetstream3/release > .scratch/jetstream3/decompressed.json
python3 tools/perf/measure_fields.py run --field b --layer single -- \
  python3 tools/perf/jetstream3/survey.py \
  --shell zig-out/bin/zjs-jetstream --upstream .scratch/jetstream3/release \
  --output .scratch/jetstream3/survey --timeout 60
```

Use `--tests hash-map,doxbee-promise,Sunspider,prismjs-startup-es6` for a pilot.
Output directories must be new. Every workload runs in a fresh process with a
bounded timeout and unmodified upstream iterations. Timeout observations are
censored, not completed measurements. The collector saves raw stdout/stderr,
upstream JSON, process elapsed/maxRSS, hashes, and all failures. Completion requires
zero exit and a single final upstream JSON containing precisely the selected entry
and a finite positive score. This checks completion, not an independent correctness
oracle beyond upstream assertions. Pending asynchronous work that exits without
results is incomplete, never a pass.

This initial route uses upstream `--no-prefetch`, including its timed on-demand
file loads. Results are diagnostic-only, cannot compare with default-prefetch
scores, and never produce an aggregate headline. Offline decompression removes the
runner's default Wasm zlib dependency. A formally comparable prefetch adapter and
cross-engine checks remain required before changing the primary metric. Full
measurements follow `docs/perf/measurement-contracts.md`; this collector does not
attest locks or confer verdict authority merely by recording affinity.

## Representative cross-engine snapshot

`compare.py` fixes the user-selected 11 entries: Air, first-inspector-code-load,
JSON parse/stringify inspector, FlightPlanner, splay, doxbee-async, proxy-vue,
bigint-noble-ed25519, jsdom-d3-startup, and threejs. Four fresh-process runs use
forward/reverse/forward/reverse engine order within each entry. First failures
remain visible and stop repeated launches for that engine/entry; incomplete sets
must not be ranked. The script records raw data, not an aggregate score. Use `--tests` with a comma-separated
selection from these 11 for explicit reruns, always writing to a new output directory.
When a workload overlaps external compilation, rerun its entire engine/sample set;
preserve the original observations and identify the selected batch in the report.

Build the QuickJS host shim under the normal build lock with
`bash tools/perf/jetstream3/build_qjs_shell.sh`; `QUICKJS_DIR` and `QJS_SHELL_OUT`
select an existing QuickJS static library and output path. Run `test_shell.py`
against the resulting binary. It uses genuine QuickJS contexts and global script
evaluation, the upstream file/module loader and event-loop timers. It does not
polyfill missing JavaScript language semantics.
The shim build targets Linux with GNU ld or lld: `--wrap=JS_ExecutePendingJob`
preserves QuickJS's event loop while converting uncaught job exceptions into a
nonzero process exit. Upstream `js_std_loop` otherwise logs those exceptions and
returns normally. Shell contracts exercise initial, timer-enqueued and cross-realm
job failures, as well as synchronous exceptions and unhandled rejections.

Validate the collector boundary with `python3 tools/perf/jetstream3/test_survey.py`
and `python3 tools/perf/jetstream3/test_runners.py PATH_TO_PINNED_UPSTREAM`.
The latter uses explicit process fixtures to verify real CLI success, nonzero
exit, timeout censorship and process-group termination; it does not measure engines.

For `compare.py --engines engines.json --upstream PATH --output NEW_PATH`, the JSON
is a list of engine records with `name`, absolute `binary`, `sha256`, and
`separator` (usually `[]` for the custom shells, `["--"]` for d8 and jsc).
Optional `flags` is a list of engine options inserted before `cli.js` (for example,
V8 `["--jitless"]` or JSC `["--useJIT=false"]`). Verify the effective options using
the installed engine before collecting a new mode. Additional provenance fields are preserved. An explicit `blockedReason` plus
actual preflight evidence represents an unavailable adapter, not failed workloads.
Use the host-exclusive single-core launcher for a serial snapshot and save host
CPU/process diagnostics. Default V8/JSC JIT results must be labelled as such.
All results remain specific to `--no-prefetch`, the local binaries and resource
configuration; this is not a calibrated sub-percent performance gate.

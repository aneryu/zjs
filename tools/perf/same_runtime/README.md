# Same-runtime benchmark collector

`run_same_runtime.js` compares the retained zjs and pinned QuickJS harnesses.
Each harness compiles a case once and calls its exported `run()` repeatedly.
Timing samples are ABBA-interleaved. The collector never changes its own or a
child's CPU affinity.

On Linux, formal comparable runs must pin the collector externally, for
example:

```sh
taskset -c 19 node tools/perf/same_runtime/run_same_runtime.js --cpu 19 --no-pmu
```

The collector reads its own `/proc/self/status`, launches an unwrapped Node
probe, and verifies that both processes inherited the same single-CPU
affinity. `--cpu` is only an assertion about that external pin; it does not
invoke `taskset`.

macOS has no supported affinity query in this collector. It runs the harnesses
directly and records `environment.affinity` as explicitly
`unavailable`/`unpinned`; it does not pretend the run has strict pinned
provenance. CPU metadata is platform-specific: Linux uses `lscpu` plus
`/proc/cpuinfo`, macOS uses `os.cpus()` plus optional read-only `sysctl`
metadata, and other platforms use an explicit generic fallback.

## Case and phase declarations

`policy.json` is the single checked-in policy authority shared directly by this
Node collector and the Python verifier. Each sentinel entry owns its name,
checksum requirement, case shape, and provenance in one object; the exit-line
limits live in the same static policy. The collector resolves the file relative
to its own script, validates the complete schema, and fails closed if the file
is absent or damaged. It has no built-in fallback list.

Every current P0 sentinel explicitly declares `checksum_required: true`.
Unregistered/custom cases default to requiring a checksum, but cannot become
source- or provenance-comparable. `--case-source` changes the recorded
provenance to `canonical_source: false`; it cannot make a replacement workload
count as the named P0 sentinel.

Required checksums must be non-empty strings in preflight and every timed
sample, and must match across engines. Only an explicit
`checksum_required: false` registry declaration can permit an absent checksum;
there is no command-line override for this declaration.

Cross-engine phase ratios use the explicit `phaseComparability` table. The
reviewed whitelist is:

| Phase | Ratio published | Boundary |
|---|---:|---|
| `runtime_create_ns` | yes | Engine runtime allocation before Realm creation |
| `realm_raw_create_ns` | no | Raw context setup differs |
| `realm_bootstrap_ns` | no | Intrinsic work and global surfaces differ |
| `realm_ready_ns` | no | Outer boundary aligns, but installed surfaces differ |
| `compile_frontend_ns` | no | Engine-internal parser boundaries differ |
| `parse_ns` | no | zjs compatibility alias of its complete `compile_ns`; QuickJS emits no peer field |
| `compile_finalize_ns` | no | Finalize/packing boundaries differ |
| `compile_ns` | yes | Complete ordinary-global-script compile-only boundary through function bytecode |
| `root_function_publish_ns` | no | Closure/publication work is split differently |
| `vm_run_ns` | no | Inner VM boundary excludes different work |
| `first_execute_ns` | diagnostic | Publication/closure through first top-level result |
| `promise_jobs_ns` | no | Immediate post-top-level drain |
| `final_job_drain_ns` | no | Drain after all retained `run()` calls |
| `job_drain_ns` | no | Sum of immediate and final drains |
| `eval_total_ns` | diagnostic | Compile through completion release and immediate drain |
| `engine_cold_to_first_result_ns` | no | Different immediate-drain endpoints and Realm surfaces |

The two aligned-but-surface-different cold measurements are diagnostics, not
formal parity-gate ratios. An unregistered phase preserves raw zjs/QuickJS
timing statistics but records `comparable: false`, a human-readable reason, and
`stats: null`. A future harness field therefore fails closed until its two
boundaries have been reviewed.

`first_execute_ns` publishes a boundary-level diagnostic for ordinary global
scripts, but is not a hard parity gate: QuickJS `JS_CallFree` releases the root
closure (and may free its bytecode) before returning, whereas zjs stops timing
at the VM result and releases `root_function_value` afterward through `defer`.
Module compilation/execution requires a separate boundary audit.

For ordinary global scripts, `eval_total_ns` stops only after the immediate
post-top-level drain finishes and the first completion value is then released.
It is still a boundary-level diagnostic rather than a hard parity gate:
QuickJS drains its ECMAScript pending-job queue, while zjs
`drainPendingPromiseJobs` additionally polls host signal, I/O, timer, and
Atomics-completion queues.

Both harnesses expose the immediate drain as `promise_jobs_ns` and the drain
after all retained `run()` invocations as `final_job_drain_ns`.
`job_drain_ns` remains the backward-compatible aggregate and must equal their
sum. All three drain fields are attribution-only and explicitly
`comparable: false`.

Resource ratios likewise iterate only the explicit definitions inside
`resourceStatistics`; there is no fallback that publishes an unknown resource
as comparable.

## Four-part case comparability

Every case records explicit `source`, `checksum`, `metric`, and `provenance`
objects plus compatible top-level `*_comparable` booleans and `*_reason`
fields. The final value is exactly:

```text
source_comparable &&
checksum_comparable &&
metric_comparable &&
provenance_comparable
```

- Source covers registry membership, canonical checked-in source, matching
  source hashes/layer/case, and successful preflight/timed harness validation.
- Checksum covers the declared requirement and every preflight/timed
  cross-engine comparison.
- Metric covers the complete paired steady-execute ratio distribution.
- Provenance covers pinned QuickJS HEAD/VERSION/tree cleanliness, binary hashes,
  verified inherited single-CPU affinity, the complete ABBA order and loop
  metadata, and reliable PMU binding when PMU collection is requested. An
  explicitly unpinned macOS artifact remains useful for diagnostics but does
  not satisfy strict provenance comparability.

Missing or unchecked evidence is false. Existing status values remain
compatible: `mismatch` and `invalid` stay unchanged; an otherwise `ok` case
whose four-part conjunction is false becomes `invalid`, so existing aggregate
selection cannot publish it.

## PMU and exit semantics

PMU collection is disabled by default and is available only through explicit
`--pmu`. It is a separate whole-process Linux `perf stat` invocation which
inherits the collector's externally established affinity. Enabling it requires
all of: Linux, verified single-CPU inherited affinity, an available `perf`
tool, and exactly one discovered `armv8_pmuv3_*` sysfs device containing that
CPU. A requested but unavailable PMU is recorded explicitly and cannot satisfy
strict provenance; the runner never silently substitutes fabricated counters.

PMU collection has no baseline subtraction, so it cannot create the direct
collector's negative baseline-derived values. Counts remain raw non-negative
process counts. The runner requests the selected PMU explicitly, retains the
raw event row, and refuses to sum multiple counted PMU rows.

`--no-pmu` explicitly disables this ancillary collection and is also the
default behavior; the wall-time primary metric remains valid. Collector exit
status is based on validity,
completeness, and comparability. `aggregate.exit_line.geomean_pass` and
`per_case_pass` are recorded results only: either may be false while a complete,
valid run exits zero. Enforcing performance targets belongs to the opt-in
verifier (`tools/perf/verify_same_runtime`, documented in
[VERIFIER.md](VERIFIER.md)), not this collector.

Artifacts declare only `policy_id` and `policy_version`, alongside the cases
actually requested/run and the computed results. They do not copy the policy
sentinel set or use artifact-provided limits as authority.

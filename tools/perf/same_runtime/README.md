# Same-runtime benchmark collector

`run_same_runtime.js` compares the retained zjs and pinned QuickJS harnesses.
Each harness compiles a case once and calls its exported `run()` repeatedly.
Timing samples are ABBA-interleaved and pinned with `taskset`.

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

Cross-engine phase ratios use the explicit `phaseComparability` table. An
unregistered phase preserves its raw zjs/QuickJS timing statistics but records
`comparable: false`, a human-readable reason, and `stats: null`. It is never
treated as comparable merely because no definition was found.

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
  taskset affinity, the complete ABBA order and loop metadata, and reliable PMU
  binding when PMU collection is requested.

Missing or unchecked evidence is false. Existing status values remain
compatible: `mismatch` and `invalid` stay unchanged; an otherwise `ok` case
whose four-part conjunction is false becomes `invalid`, so existing aggregate
selection cannot publish it.

## PMU and exit semantics

PMU collection is a separate whole-process `perf stat` invocation. It has no
baseline subtraction, so it cannot create the direct collector's negative
baseline-derived values. Counts remain raw non-negative process counts. The
runner discovers the one `armv8_pmuv3_*` sysfs device containing the pinned CPU,
requests it explicitly, retains the raw event row, and refuses to sum multiple
counted PMU rows.

`--no-pmu` explicitly disables this ancillary collection; the wall-time primary
metric remains valid. Collector exit status is based on validity,
completeness, and comparability. `aggregate.exit_line.geomean_pass` and
`per_case_pass` are recorded results only: either may be false while a complete,
valid run exits zero. Enforcing performance targets belongs to an opt-in
verifier, not this collector.

Artifacts declare only `policy_id` and `policy_version`, alongside the cases
actually requested/run and the computed results. They do not copy the policy
sentinel set or use artifact-provided limits as authority.

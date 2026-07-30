# Same-runtime artifact verifier

`verify_same_runtime` is the policy half of the same-runtime performance
workflow. It reads an already generated JSON artifact. It does not run a
benchmark, invoke either engine, or change collector exit semantics.

## Language choice

The verifier is implemented in Python even though the same-runtime collector is
implemented in Node. This program is artifact-only and shares no live state
with the collector, while Python's `argparse`, `json`, and `unittest` modules
provide the complete implementation and test surface without third-party
packages. Python is also already used by `tools/perf/direct/run_direct.py`.
Keeping the verifier in a separate standard-library-only runtime preserves the
collector/verifier boundary and lets the phase-close policy run even on a host
where `node` is not on `PATH`.

`tools/perf/same_runtime/policy.json` is the single checked-in policy authority.
Both runtimes load that exact file directly; there is no generated copy, drift
check, built-in fallback list, or second hand-maintained sentinel tuple. The
verifier resolves the policy relative to its own installed path, validates its
complete schema, and exits `2` if it is absent or damaged.

Reading a checked-in policy is distinct from trusting the artifact under test.
Changing the policy requires a reviewed code change. The verifier never derives
sentinels or limits from `requested_cases`, `policy`, or any other artifact
field, so a one-case artifact cannot declare itself complete and forged limits
cannot relax the gate. An artifact's `policy` object is an identity declaration
only: `policy_id` and `policy_version`.

## Usage

```sh
tools/perf/verify_same_runtime \
  --require-policy-declaration \
  --require-complete \
  --require-canonical-provenance \
  --require-output-match \
  --require-exit-line \
  reports/perf/.../same-runtime.json
```

All policy switches are opt-in:

- `--require-policy-declaration` requires an artifact's `policy_id` and
  `policy_version` to match the checked-in policy. Without this option, an old
  artifact with no `policy` field takes an explicitly reported legacy
  compatibility path; it is never silently described as having declared the
  policy. A declaration that is present is always compared and reported in the
  advisory check.
- `--require-complete` requires `aggregate.complete` to be the JSON boolean
  `true`, an empty `aggregate.missing_cases`, and every policy sentinel in both
  the case set and aggregate participants. Current collector artifacts do not
  publish top-level `aggregate.participants`; for those artifacts, empty
  `missing_cases` plus complete `cases` coverage is the specified fallback.
- `--require-canonical-provenance` checks each aggregate participant for
  `canonical_source: true`, rejects `overridden` and `custom` case shapes,
  requires provenance comparability when that nested field is present, and
  rejects sentinel paths in `case_sources` that are outside the checked-in
  `tools/perf/same_runtime/cases/` directory.
- `--require-output-match` requires every case status to be `ok`, zero
  `mismatch` and `invalid` counts, and explicit cross-engine checksum
  agreement. A checksum exemption is accepted only when
  `checksum_required` is the JSON boolean `false` and
  `checksum_requirement_declared` is the JSON boolean `true`. Missing, `null`,
  or unchecked requirements fail closed.
- `--require-exit-line` requires both exit-line booleans to be `true`, locks
  the policy limits to geomean `1.10` and per-case `1.20`, and checks the
  recorded geomean, limits, and `over_limit_cases` for internal consistency.
  An artifact cannot relax the policy by changing its recorded limits.
  Failures include the concrete recorded ratios.

With no `--require-*` options, valid JSON-object parsing is the only enforced
condition. The command prints an advisory PASS/FAIL summary for all policy
checks but exits zero regardless of those advisory results. Invalid JSON,
duplicate JSON fields, a non-object root, CLI errors, unreadable artifacts, and
an unreadable or invalid checked-in policy exit `2`.

Use `--json` to make stdout contain one JSON verdict and no human-readable
text:

```sh
tools/perf/verify_same_runtime --require-exit-line artifact.json --json |
  python3 -m json.tool
```

Exit codes are:

- `0`: the artifact parsed and every requested policy check passed;
- `1`: at least one requested policy check failed;
- `2`: CLI, I/O, or structural JSON parsing failed.

## Tests

```sh
python3 tools/perf/verify/test_verify_same_runtime.py
```

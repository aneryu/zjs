# CodeLoad compile-throughput micro

Fixed paired A/B harness for the code-load optimization campaign
(reports/perf/qjs-align/2026-07-31/). The macro arbiter remains
`tools/perf/zoo/run_zoo_compare.py --benches code-load`; this micro exists so
each cut can be adjudicated on a deterministic fixed workload with
instructions as the primary (layout-immune) metric.

## Two modes, deliberately separated

The macro benchmark entangles three things: parser/lowering work, atom-table
churn, and top-level execution. A cut's verdict must not be laundered through
the wrong one, so:

- **compile** — identical source bytes every iteration, compiled as a global
  program via indirect eval behind a leading `throw 0;` (execution stops right
  after GlobalDeclarationInstantiation; nothing of the library runs, and the
  compiled FunctionBytecode is released immediately). Atom state is steady
  after iteration 1. Use for cuts A, C1–C4.
- **atom** — same runtime throughout; every iteration renames the
  goog/jQuery identifier families with a zero-padded 8-digit salt (source
  length invariant), adding intern miss + free-slot recycling on top of the
  compile work. Renaming is precomputed split/join — RegExp.replace is a
  large zjs advantage and must stay out of an atom measurement. Use for cut B.

The payload is extracted VERBATIM from the zoo's Octane CodeLoad
(`payload_octane_codeload.js`, BASE_JS 8348 + JQUERY_JS 94841 chars); both
engines were verified to see identical lengths. `ITERS` is fixed by
calibration — do not parameterize it; a fixed workload is the point.

Known, accepted divergence from the macro: the `throw 0;` gate adds one
compile+catch of a trivial statement, and no library execution ever happens
(the macro executes the library definition once per iteration; that execution
measured <1% on both engines in the 2026-07-31 attribution).

## Usage

```bash
flock -x /tmp/zjs-host-heavy.lock taskset -c 19 \
  python3 tools/perf/codeload/run_codeload_micro.py \
    --a /path/to/zjs-baseline --b zig-out/bin/zjs \
    --mode compile --samples 8 --cpu 19 \
    --output reports/perf/qjs-align/<date>/<cut>/micro-compile.json
```

Ratio is `b/a`: below 1.0 means the candidate does less work. Instructions
decide work-removal cuts; cycles must not contradict (the runner prints a
same-direction verdict); the zoo macro arbitrates the final merge.

## Fail-closed contracts (same lineage as run_zoo_compare.py)

- odd `--samples` refused, not rounded (paired ABBA order must balance);
- effective affinity attested to be exactly `{--cpu}`;
- dual-PMU `<not counted>` rows filtered; missing counters are fatal;
- the harness `CHECKSUM` must be identical across every run of both
  binaries, otherwise the two sides did different work and the run is void.

## Merge-verdict protocol

A single build per side cannot support a merge verdict: build layout alone is
worth ±2% cycles on this host. The formal protocol is **two cold-cache builds
per side**, running the micro on all four A/B build combinations, plus the zoo
macro on one combination — instructions must move the same way in all four.
Whole-process richards/deltablue stay as gross-regression sentinels only
(they include compile time, so small shifts are expected when compile cuts
land; execution-only claims need a compile-once-execute-many harness).

Atom-table live/capacity/free-slot telemetry is not JS-visible; the B2
prototype contract collects it with a scratch probe build.

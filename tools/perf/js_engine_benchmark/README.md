# js-engine-benchmark (v8-v7) scoring

This runner scores `zjs` with the same protocol as
[ahaoboy/js-engine-benchmark](https://github.com/ahaoboy/js-engine-benchmark):
one invocation of the bundled v8-v7 `run.js`, then parse the suite's own
`Name: <int>` lines. Higher is better. The headline `Score` is the geometric
mean of Richards, DeltaBlue, Crypto, RayTrace, EarleyBoyer, RegExp, Splay, and
NavierStokes.

This is a different suite from the Octane 2.0 zoo in `tools/perf/zoo/`. Do not
mix the two geomeans.

## Usage

Build ReleaseFast `zjs` first. A stale binary has produced wrong campaign
conclusions before.

```bash
zig build zjs --seed 0 --summary all

python3 tools/perf/js_engine_benchmark/run.py \
  --zjs zig-out/bin/zjs \
  --engine qjs=/path/to/qjs \
  --output /tmp/js-engine-benchmark.json
```

`--suite` points at an existing `js-engine-benchmark` checkout. When omitted,
the runner clones the pinned commit into `.zig-cache/js-engine-benchmark`.

Parser and bundler contract:

```bash
python3 tools/perf/verify/test_run_js_engine_benchmark.py
```

Checked-in scores live in [docs/perf/js-engine-benchmark.md](../../../docs/perf/js-engine-benchmark.md).
Dated JSON dumps stay local.

To appear on the published table, publish the CLI archives from
`.github/workflows/release-cli.yml`. The listing PRs are
[js-engine-setup#3](https://github.com/ahaoboy/js-engine-setup/pull/3) and
[js-engine-benchmark#40](https://github.com/ahaoboy/js-engine-benchmark/pull/40).
Patches live under
[`contrib/js-engine-benchmark/`](../../../contrib/js-engine-benchmark/README.md).

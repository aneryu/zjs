# Compile / first-run scaling anchors

This directory is a diagnostic-only M0/M2 baseline for ordinary global
scripts. It reuses the existing `qjs-same-runtime` and `zjs-same-runtime`
harness binaries without modifying either harness. Every timing point launches
a fresh harness process, compiles one source exactly once, executes its global
root exactly once, and then calls `run()` once to validate the checksum.

## Anchor design

`generate_anchors.py` deterministically creates four saved ASCII/LF sources and
`manifest.json`. Each script defines:

- one `compilePayload()` function containing zero or linearly many local
  `const` declarations; the function is deliberately never called;
- one constant-work global `run()` function returning an anchor-specific
  checksum.

The scalable bytes are therefore parser/compiler input and nested-function
bytecode work, not comment padding. First top-level execution only publishes
the two function declarations; it does not execute the declaration corpus.

| anchor | exact bytes | payload declarations | SHA-256 |
|---|---:|---:|---|
| `minimal` | 98 | 0 | `275481588f5ad12dc5cd55a27fa465c60c2e83a9e9b758151175ed854496585c` |
| `tiny` | 421 | 16 | `2826a8cc9140fc70bda32f74b8e155bc0bee45e42c4c4dc5f50ca13197f4df84` |
| `linear-10k` | 10,243 | 466 | `2f2d1d290f03a270267a6a99032359c53cb7dd5c06c23e389be13222e97207a6` |
| `linear-100k` | 102,400 | 4,496 | `661287f231b9f9a3096c495beeabd9ac7c06a01d814e7e20642ed0006408d180` |

Regenerate or verify the checked-in bytes with:

```bash
python3 tools/perf/compile_first/generate_anchors.py
python3 tools/perf/compile_first/generate_anchors.py --check
```

## Collector contract

`run_compile_first.py` treats harnesses and anchor sources as read-only inputs.
It writes only the requested output artifact. For every source it runs an ABBA
block (`qjs`, `zjs`, `zjs`, `qjs`), rotates anchor order between blocks, and
reverses that order on odd blocks.

The collector fails closed on:

- manifest, exact source-byte, source-hash, declaration-count, or `run()`
  contract drift;
- missing or changed harness executables;
- malformed harness JSON or the wrong engine/layer/case/source schema;
- anything other than exactly one compile and one first top-level execution;
- missing `compile_ns` / `first_execute_ns`;
- a checksum different from the shared manifest value.

The artifact contains every raw point, per-anchor samples and medians, exact
binary/source hashes, repository commits and dirty state, harness schema
evidence, and a minimal four-point OLS model:

```text
median_ns = intercept_ns + slope_ns_per_source_byte * source_bytes
```

The intercept is descriptive fixed work and the slope is descriptive
nanoseconds per source byte. Four anchors, heterogeneous token widths, and
uncontrolled machine state are not enough to claim algorithmic complexity.

Example:

```bash
python3 tools/perf/compile_first/run_compile_first.py \
  --samples-per-engine 20 \
  --zjs-harness zig-out/bin/zjs-same-runtime \
  --qjs-harness .zig-cache/perf/qjs-align/same-runtime/qjs-same-runtime \
  --output .zig-cache/perf/compile-first/macos-m1pro.json
```

Run the collector contract tests with:

```bash
python3 tools/perf/compile_first/test_run_compile_first.py -v
```

## Comparability boundary

`compile_ns` is suitable only for cross-engine diagnostic scaling: both
harnesses stop at the ordinary-script compile-only FunctionBytecode boundary,
but their internal parser/finalization instrumentation is not identical.

`first_execute_ns` is weaker. QuickJS times `JS_EvalFunction`; zjs times root
publication through its first top-level VM result. Cleanup and Realm/global
surfaces differ, so this phase is a boundary-level diagnostic, not a strict
engine-equivalence metric.

Keep generated timing artifacts under `.zig-cache/perf/`. They are
machine-, binary-, and worktree-specific evidence, not source-controlled
baselines or formal performance gates.

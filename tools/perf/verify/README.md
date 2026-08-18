# Measurement-pipeline contract tests

Unit tests for the live perf tooling (`classify_build_state`,
`compare_symbol_disassembly`, `run_zjs_cold_ab`, `run_zoo_compare`,
`run_zoo_fixed_pmu`, `verify_same_runtime`). They are not wired into any
build step or CI; run them directly:

```sh
for t in tools/perf/verify/test_*.py; do python3 "$t"; done
```

Run them after editing the corresponding tool.

# zjs microbench top 10

- Source report: `reports/perf/current/microbench.json`
- Report timestamp: 2026-06-02T05:12:43.272Z
- Generated: 2026-06-02T05:12:46.242Z
- Sort: zjs/qjs ratio
- Compatible cases: 73
- Unsupported cases: 0
- Skipped cases: 0
- Geometric mean: 0.8415

| Rank | Case | Category | qjs avg ms | zjs avg ms | zjs/qjs | Winner |
|---:|---|---|---:|---:|---:|---|
| 1 | `string_slice1` | string | 0.653 | 1.431 | 2.19 | qjs |
| 2 | `bigint64_arith` | bigint | 0.690 | 1.464 | 2.12 | qjs |
| 3 | `weak_map_set` | collection | 0.766 | 1.614 | 2.11 | qjs |
| 4 | `global_destruct` | destructuring | 0.815 | 1.584 | 1.95 | qjs |
| 5 | `float_to_string` | conversion | 0.657 | 1.253 | 1.91 | qjs |
| 6 | `date_now` | date | 0.761 | 1.400 | 1.84 | qjs |
| 7 | `prop_write` | object | 0.938 | 1.619 | 1.73 | qjs |
| 8 | `prop_create` | object | 0.903 | 1.548 | 1.71 | qjs |
| 9 | `string_concat3` | string | 0.826 | 1.401 | 1.70 | qjs |
| 10 | `closure_var` | function | 1.074 | 1.784 | 1.66 | qjs |

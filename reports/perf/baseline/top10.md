# zjs microbench top 10

- Source report: `reports/perf/baseline/microbench-releasefast.json`
- Generated: 2026-05-19T21:06:47.742Z
- Sort: zjs/qjs ratio
- Compatible cases: 72
- Unsupported cases: 1
- Skipped cases: 0
- Geometric mean: 2.0627

| Rank | Case | Category | qjs avg ms | zjs avg ms | zjs/qjs | Winner |
|---:|---|---|---:|---:|---:|---|
| 1 | `string_concat_loop` | string | 1.844 | 159.406 | 86.46 | qjs |
| 2 | `global_read_loop` | global | 12.954 | 85.092 | 6.57 | qjs |
| 3 | `prop_read` | object | 2.189 | 11.237 | 5.13 | qjs |
| 4 | `dense_array_write_read` | array | 6.020 | 30.286 | 5.03 | qjs |
| 5 | `proto_read` | object | 20.456 | 99.125 | 4.85 | qjs |
| 6 | `prop_read_poly3` | object | 31.485 | 149.469 | 4.75 | qjs |
| 7 | `array_read` | array | 2.753 | 12.881 | 4.68 | qjs |
| 8 | `prop_read_mono` | object | 19.661 | 89.779 | 4.57 | qjs |
| 9 | `array_for` | array | 2.983 | 12.870 | 4.31 | qjs |
| 10 | `vm_int_sum_large` | control | 18.542 | 78.646 | 4.24 | qjs |

# zjs microbench top 10

- Source report: `reports/perf/current/microbench.json`
- Report timestamp: 2026-05-20T07:42:53.939Z
- Generated: 2026-06-02T03:00:01.659Z
- Sort: zjs/qjs ratio
- Compatible cases: 72
- Unsupported cases: 1
- Skipped cases: 0
- Geometric mean: 1.0158

| Rank | Case | Category | qjs avg ms | zjs avg ms | zjs/qjs | Winner |
|---:|---|---|---:|---:|---:|---|
| 1 | `dense_array_write_read` | array | 6.197 | 21.887 | 3.53 | qjs |
| 2 | `int_sum` | arithmetic | 1.512 | 4.395 | 2.91 | qjs |
| 3 | `prop_read_mono` | object | 19.879 | 45.428 | 2.29 | qjs |
| 4 | `proto_read` | object | 20.748 | 44.497 | 2.14 | qjs |
| 5 | `math_min` | math | 4.421 | 9.048 | 2.05 | qjs |
| 6 | `uri_decode_4byte` | uri | 19.421 | 38.029 | 1.96 | qjs |
| 7 | `uri_component_decode_4byte` | uri | 19.497 | 38.115 | 1.95 | qjs |
| 8 | `array_read` | array | 1.634 | 3.093 | 1.89 | qjs |
| 9 | `closure_call_loop` | function | 17.608 | 32.953 | 1.87 | qjs |
| 10 | `call2_loop` | function | 18.347 | 32.178 | 1.75 | qjs |

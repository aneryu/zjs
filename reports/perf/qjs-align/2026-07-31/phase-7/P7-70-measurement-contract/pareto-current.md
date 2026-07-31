# P7-70 当前权威 Pareto（`042e4962`，绑核 CPU 19，8 样本平衡）

- 引擎二进制：`zjs-A` sha256 `c5625b9977ebd1c2…`，commit `1fb79bc3`
- 对照：pinned qjs `04be2460` VERSION 2026-06-04，sha256 `b76d154265e829e6…`
- 测量代次：`2026-07-30T17:59:14.142Z#2057153`；启动基线在同一代次重采
- 启动基线：qjs 0.431 ms / zjs 0.560 ms，比值 1.298，差额 128.7 µs

## C1 兼容口径

`all_75_paired_geomean = 1.2871`（`compatibility_metric = true`，`route_priority_metric = false`）。
该数字只用于与 Phase 0 / Phase 6 对齐，不得用来给下一条线排序。

## C2 按当前实测启动占比分档

| 档位 | case 数 | paired geomean | 绝对差合计 | 启动占比中位数 | stable | unstable | 有验证轮 |
|------|---------|----------------|------------|----------------|--------|----------|----------|
| execution-dominant | 15 | 1.1548 | 23.884 ms | 3.2% | 15 | 0 | 14 |
| partially-resolvable | 8 | 1.2143 | 2.396 ms | 31.1% | 5 | 3 | 2 |
| startup-dominated | 52 | 1.3399 | 8.605 ms | 92.5% | 30 | 22 | 0 |

## C3-A 绝对时间贡献（工程优先级）

| # | case | 子系统 | zjs−qjs | qjs → zjs | paired | 分档 |
|---|------|--------|---------|-----------|--------|------|
| 1 | `uri_component_decode_4byte` | string/URI | +4.129 ms | 14.06 → 18.19 | 1.295 | execution-dominant |
| 2 | `uri_decode_4byte` | string/URI | +4.047 ms | 14.08 → 18.13 | 1.285 | execution-dominant |
| 3 | `arrow_call_loop` | call | +3.388 ms | 13.56 → 16.95 | 1.251 | execution-dominant |
| 4 | `call2_loop` | call | +3.362 ms | 13.56 → 16.92 | 1.247 | execution-dominant |
| 5 | `closure_call_loop` | closure/function-creation | +3.148 ms | 13.70 → 16.84 | 1.229 | execution-dominant |
| 6 | `array_map_callback` | array | +1.835 ms | 5.49 → 7.32 | 1.337 | execution-dominant |
| 7 | `vm_int_sum_large` | call | +1.518 ms | 12.13 → 13.65 | 1.121 | execution-dominant |
| 8 | `dense_array_write_read` | array | +1.139 ms | 4.56 → 5.70 | 1.255 | execution-dominant |
| 9 | `proto_read` | binding/property | +1.083 ms | 17.32 → 18.41 | 1.063 | execution-dominant |
| 10 | `global_read_loop` | binding/property | +0.960 ms | 12.14 → 13.10 | 1.079 | execution-dominant |
| 11 | `math_min` | number/dtoa | +0.715 ms | 2.18 → 2.90 | 1.329 | execution-dominant |
| 12 | `prop_read_mono` | binding/property | +0.655 ms | 16.02 → 16.68 | 1.041 | execution-dominant |
| 13 | `map_string_keys` | binding/property | +0.508 ms | 2.69 → 3.20 | 1.200 | execution-dominant |
| 14 | `func_call` | call | +0.485 ms | 2.03 → 2.52 | 1.243 | partially-resolvable |
| 15 | `string_concat_loop` | string/URI | +0.453 ms | 1.55 → 2.00 | 1.280 | partially-resolvable |
| 16 | `array_for` | array | +0.299 ms | 1.35 → 1.65 | 1.214 | partially-resolvable |
| 17 | `arrow_tail_recursion` | call | +0.285 ms | 1.52 → 1.81 | 1.185 | partially-resolvable |
| 18 | `bigint_short_sum` | BigInt | +0.263 ms | 0.78 → 1.04 | 1.340 | startup-dominated |
| 19 | `array_read` | array | +0.246 ms | 1.32 → 1.57 | 1.192 | partially-resolvable |
| 20 | `global_read` | binding/property | +0.242 ms | 1.19 → 1.43 | 1.217 | partially-resolvable |

## C3-B 分档 log 贡献（仅 execution-dominant + partially-resolvable）

| # | case | 子系统 | paired | log 份额 | 分档 |
|---|------|--------|--------|----------|------|
| 1 | `array_map_callback` | array | 1.337 | 6.81% | execution-dominant |
| 2 | `math_min` | number/dtoa | 1.329 | 6.70% | execution-dominant |
| 3 | `array_for` | array | 1.214 | 6.32% | partially-resolvable |
| 4 | `uri_component_decode_4byte` | string/URI | 1.295 | 6.10% | execution-dominant |
| 5 | `uri_decode_4byte` | string/URI | 1.285 | 5.92% | execution-dominant |
| 6 | `regexp_test_cached` | regexp | 0.797 | 5.76% | execution-dominant |
| 7 | `string_concat_loop` | string/URI | 1.280 | 5.67% | partially-resolvable |
| 8 | `dense_array_write_read` | array | 1.255 | 5.27% | execution-dominant |
| 9 | `arrow_call_loop` | call | 1.251 | 5.26% | execution-dominant |
| 10 | `call2_loop` | call | 1.247 | 5.23% | execution-dominant |
| 11 | `func_call` | call | 1.243 | 4.97% | partially-resolvable |
| 12 | `global_read` | binding/property | 1.217 | 4.79% | partially-resolvable |
| 13 | `closure_call_loop` | closure/function-creation | 1.229 | 4.79% | execution-dominant |
| 14 | `map_string_keys` | binding/property | 1.200 | 4.32% | execution-dominant |
| 15 | `array_read` | array | 1.192 | 4.04% | partially-resolvable |

## C3-C 子系统聚类

| 子系统 | case 数 | geomean(全部) | 可分辨数 | geomean(可分辨) | 绝对差合计 |
|--------|---------|---------------|----------|------------------|------------|
| string/URI | 13 | 1.3146 | 3 | 1.2846 | 10.267 ms |
| startup/bootstrap | 0 | 1.2983 | 0 | — | 9.653 ms |
| call | 5 | 1.2041 | 5 | 1.2041 | 9.038 ms |
| binding/property | 20 | 1.2604 | 7 | 1.1068 | 5.412 ms |
| array | 13 | 1.3169 | 4 | 1.2690 | 5.058 ms |
| closure/function-creation | 2 | 1.3135 | 1 | 1.2257 | 3.313 ms |
| number/dtoa | 12 | 1.3277 | 2 | 1.2284 | 2.383 ms |
| BigInt | 3 | 1.2922 | 0 | — | 0.577 ms |
| typed-array/ArrayBuffer | 2 | 1.4149 | 0 | — | 0.363 ms |
| date | 1 | 1.4422 | 0 | — | 0.196 ms |
| control | 1 | 1.1540 | 0 | — | 0.129 ms |
| regexp | 3 | 1.1114 | 1 | 0.7829 | -1.849 ms |

## 当前 top 10（执行可分辨，按绝对差）

| # | case | paired | 绝对差 | 启动占比 | 分档 | paired IQR | 主轮 vs 验证轮 | 已有归因 |
|---|------|--------|--------|----------|------|------------|----------------|----------|
| 1 | `uri_component_decode_4byte` | 1.295 | +4.129 ms | 3.1% | execution-dominant | 0.0061 | 1.289，同向=是，IQR 重叠=否 | 否 |
| 2 | `uri_decode_4byte` | 1.285 | +4.047 ms | 3.1% | execution-dominant | 0.0055 | 1.287，同向=是，IQR 重叠=是 | 否 |
| 3 | `arrow_call_loop` | 1.251 | +3.388 ms | 3.2% | execution-dominant | 0.0013 | 1.253，同向=是，IQR 重叠=否 | 否 |
| 4 | `call2_loop` | 1.247 | +3.362 ms | 3.2% | execution-dominant | 0.0045 | 1.250，同向=是，IQR 重叠=是 | 否 |
| 5 | `closure_call_loop` | 1.229 | +3.148 ms | 3.2% | execution-dominant | 0.0033 | 1.236，同向=是，IQR 重叠=否 | 否 |
| 6 | `array_map_callback` | 1.337 | +1.835 ms | 7.9% | execution-dominant | 0.0126 | 1.334，同向=是，IQR 重叠=是 | 是 |
| 7 | `vm_int_sum_large` | 1.121 | +1.518 ms | 3.6% | execution-dominant | 0.0190 | 1.119，同向=是，IQR 重叠=是 | 是 |
| 8 | `dense_array_write_read` | 1.255 | +1.139 ms | 9.5% | execution-dominant | 0.0169 | 1.252，同向=是，IQR 重叠=是 | 否 |
| 9 | `proto_read` | 1.063 | +1.083 ms | 2.5% | execution-dominant | 0.0028 | 1.060，同向=是，IQR 重叠=否 | 是 |
| 10 | `global_read_loop` | 1.079 | +0.960 ms | 3.6% | execution-dominant | 0.0041 | 1.083，同向=是，IQR 重叠=是 | 是 |


# Phase 6 收口全局快照

- **日期**：2026-07-30
- **性质**：**只测量，未改代码。不刷新 policy baseline。**
  目的是**按当前而非历史差距重新排序**剩余工作
- **原始数据**：本目录下 `process-microbench.json` / `process-hotpath.json` /
  `same-runtime.json` / `direct.json` / `bigint-size-matrix.json` / `binaries.sha256`

---

## 0. 溯源

| | Phase 0 冻结基线（2026-07-27） | **本快照** |
|---|---|---|
| zjs commit | `c84a58fa` | **`0f726fc0`** |
| zjs binary sha256 | `6ad056d7039f4166…` | **`df03ae4919b571f2…`** |
| pinned qjs commit | — | `04be2460` |
| pinned qjs sha256 | `b76d154265e829e6…` | `b76d154265e829e6…`（**未变**） |
| 主机 / CPU / pin | Cortex-X925 + A725，pin CPU 19 | 同 |

⚠️ Phase 0 的 `direct` 用 6 timed samples；本快照首轮用 5 导致 ABBA 不平衡、headline 被作废，
已用 **6 samples 重跑**。其余套件沿用 Phase 0 参数（microbench/hotpath: iters 30 / warmup 5）。

---

## 1. same-runtime P0 sentinel：**首次通过 exit line**

`steady execute median`，zjs/qjs：

| case | Phase 0 | **本快照** | Δ |
|---|---:|---:|---:|
| `global_write_loop` | 1.7150 | **1.0390** | **0.6059** |
| `prop_read_mono_loop` | 0.8668 | 0.8741 | 1.0084 |
| **`fib_rec`** | 1.3361 | **1.3000** | 0.9730 |
| `call_body_loop` | 1.1592 | 1.1354 | 0.9794 |
| `method_call_loop` | 1.1536 | 1.1394 | 0.9877 |
| `typed_array_read` | 0.9659 | 0.9725 | 1.0069 |
| `typed_array_write` | 1.0238 | 1.0085 | 0.9851 |

```text
p0_sentinel_geomean   1.1479  ->  1.0594      门槛 1.10
geomean_pass          false   ->  TRUE   ★
per_case_pass         false   ->  false
over_limit_cases      global_write_loop 1.7150   ->   （已退出）
                      fib_rec           1.3361   ->   fib_rec 1.3000
```

**geomean 首次通过 1.10 的 exit line。**唯一仍越 1.20 per-case 上限的是 **`fib_rec` 1.3000** ——
与 Phase 3 的收口结论一致（六次证伪后判定为 Frame/Stack 状态模型本身，需结构级重设计）。

## 2. whole-process 套件

| 套件 | 指标 | Phase 0 | **本快照** |
|---|---|---:|---:|
| **microbench**（75 case） | pairedGeomean | 1.3609 | **1.3340** |
| | startup-adjusted geomean | 2.2441 | **1.5298** |
| | zjs 更快 / qjs 更快 / 近平 | 1 / 74 / 0 | 1 / 72 / **2** |
| **hotpath**（12 case） | pairedGeomean | 1.3039 | **1.2190** |
| | startup-adjusted geomean | 1.3118 | **1.2333** |
| | zjs 更快 / qjs 更快 | 1 / 11 | **2** / 10 |

⚠️ `startupAdjusted` 从 2.2441 掉到 1.5298 是**最大的单项变化**，
但 microbench 的 `pairedGeomean` 只从 1.3609 动到 1.3340 ——
说明这一大块改善集中在**进程启动/首次执行**而不是稳态执行。
两者都不是仲裁指标（PRD 5.2），仅作排序输入。

## 3. direct-core

`headline` = loop-only 指令比；`wall` = `ns/op` 比。

| case | insn P0 | **insn now** | wall P0 | **wall now** |
|---|---:|---:|---:|---:|
| `dtoa/mixed-free` | 0.8937 | 0.8904 | 1.0242 | 1.0205 |
| `regexp/exec-latin1` | 0.9725 | 0.9727 | 0.8420 | **0.8271** |
| `property_lookup/own-data` | 0.8601 | 0.8608 | 1.3719 | 1.3789 |
| `typed_array/int32-get` | —（不可比） | —（不可比） | 1.1168 | 1.0988 |
| **`bigint/mul-multilimb`** | 1.7728 | **1.5319** | 2.0284 | **1.3165** |

- **`bigint/mul-multilimb` 是唯一显著移动的**：wall 2.03 → **1.32**（P6-01/01c 的写入拓扑两刀）；
- `property_lookup/own-data` 的 **wall 1.38 而 insn 0.86** —— 三个 direction-conflict 警告之一，
  且 dossier 已记录该 case 带 zjs-only 的 `recordPropLookup` 偏置；
- `typed_array/int32-get` 在两个快照中都因 harness 不可比而无 headline（`public-api-proxy`）。

## 4. JS BigInt 尺寸矩阵

| case | zjs/qjs |
|---|---:|
| `bigint_mul_1x8` | **0.8956** |
| `bigint_mul_16x16` | **0.9410** |
| `bigint_mul_8x8` | **0.9859** |
| `bigint_mul_28x28` | 1.0229 |
| `bigint_mul_29x29` | 1.0425 |
| `bigint_mul_28x29` | 1.0477 |
| `bigint_mul_8x1` | 1.0928 |
| `bigint_mul_2x2` | 1.1652 |
| `bigint_div_16x8` | **1.2034** |
| `bigint_mod_8x4` | 1.5261 |
| `bigint_div_8x1` | 1.8834 |
| **`bigint_div_8x4`** | **2.5921** |

乘法**三个形态反超**、其余在 1.02–1.17；除法四个形态 1.20–2.59。

## 5. 按**当前**差距重新排序

| 排序 | 项 | 当前差距 | 归属 / 状态 |
|---|---|---:|---|
| 1 | **`fib_rec`** | **1.3000** | 唯一仍越 P0 per-case 1.20 上限的哨兵。Phase 3 已六次证伪，判为 **Frame/Stack 状态模型本身**，需结构级重设计（`P5-01` 关闭时的表述） |
| 2 | `property_lookup/own-data` wall | **1.3789** | direct-core 最大 wall 差；insn 0.86 反向。**带已记录的 zjs-only `recordPropLookup` 偏置**，需先剥离偏置再判 |
| 3 | `bigint_div_8x4` | **2.5921** | **已换归属** → `SmallObjectSlab` arena churn（`P6-04d2c` §11、`P6-04-closeout` §3）。不再在 BigInt 内处理 |
| 4 | `bigint_div_8x1` | 1.8834 | 单 limb 已线性；剩余是固定分配 + JS publication，与第 3 项同源 |
| 5 | microbench `pairedGeomean` | **1.3340** | 75 个 case 的整体；72 个仍慢。**未逐 case 重排** —— 见 §7 限制 |
| 6 | `call_body_loop` / `method_call_loop` | 1.1354 / 1.1394 | 已在 1.20 内，Phase 3 收口后未再动 |
| 7 | `bigint_mul_2x2` | 1.1652 | 小尺寸乘法固定税，与第 3 项同源（P6-02 已定位 wrapper ≈ 9–10 ns 恒定） |

### 结论

**下一步不应回到 BigInt。**排序前两位（`fib_rec`、`property_lookup`）都不是 BigInt，
第 3/4/7 位虽然是 BigInt case，但其剩余成本已经由 d2.5/d2c 确认落在
**allocator 的 empty-arena churn** 上 —— 那是跨类型的通用行为。

## 6. 与既定路线的衔接

```text
1. 合入并关闭 P6-04d3 dossier        ✅ bdbd617d / 5fdb3fc3
2. 生成 Phase 6 全局性能快照          ✅ 本文
3. 根据当前而非历史差距重新排序        ✅ §5
4. 若 allocator churn 跨类型成立 → P7-00
5. 否则转向快照中最大的下一项 → fib_rec / property_lookup
```

`P7-00` 的前置条件与硬门槛已固定在 `P6-04-closeout.md` §7，此处不重复。
⚠️ 关键约束：**只有在多个无关类型和多个 size class 上都确认 churn**，
才实验 empty-arena retention；**不得为 `div_8x4` 单独调 class**。

## 7. 限制

- **本快照不是 policy baseline 刷新**：`policy.json` 与 Phase 0 冻结基线均未改动；
- microbench 的 75 个 case **只汇总未逐 case 重排** —— §5 第 5 项因此只是一个聚合信号，
  真正排序需要逐 case diff，本轮未做；
- `typed_array/int32-get` 在两侧都无 headline（harness 不可比），只有 wall 可读；
- `direct` 首轮 5 samples 的产物已被 6 samples 覆盖，
  但 `dtoa` / `property_lookup` / `int32-get` 的 **direction conflict 警告仍在**
  （insn 与 wall 反向 >2%），本快照未做 cycles/cache 归因；
- `startupAdjusted` 2.2441 → 1.5298 的归因（启动 vs 稳态）**未拆分**，只是从两个指标的
  相对移动推断；
- BigInt 尺寸矩阵的 12 个 case 不在 `policy.json` 内，
  harness 会把它们标为 `invalid`（非 policy sentinel），这是预期的，
  比值本身有效但不参与 exit line。

# 1A — simple-field constructor：memo 与 body bypass 的归因 dossier

- **裁决日期**：2026-07-28
- **引擎实验 commit**：`5bbf3d49`（A/B/C 归因开关；默认等价原 HEAD）
- **工具 HEAD**：`45c2629a`
- **pinned QuickJS**：`04be2460`，VERSION 2026-06-04
- **绑核**：CPU 19（aarch64 big.LITTLE：Cortex-X925 + Cortex-A725）
- **原始数据**：`1A-binaries.json`（12 个固定二进制）、`1A-results.json`

---

## 结论摘要

| 机制 | 裁决 | 分类 |
|---|---|---|
| constructor body bypass | **保留** | `approved-specialization` |
| runtime single-entry `simple_ctor_memo` | **保留为当前生产默认**，但**不是最终 carrier** | 待 M2/M3 重设计 |
| 默认路径 | **A 不变** | — |

---

## 1. 三个候选

```text
A  body bypass = on   memo = on     （当前生产默认）
B  body bypass = on   memo = off    （每次重新扫描 immutable bytecode pattern）
C  body bypass = off  无 pattern scan（走通用 construct → frame → bytecode body）
```

`C` **未**回退两项 QJS-aligned 修复 —— lazy `.prototype` materialization
（`core/object.zig` 的 `getOwnConstructorPrototypeObject`，被内联进
`createBytecodeConstructorInstance`，gdb 断点计数确认 5 次构造命中 5 次）与
bytecode-constructor class dispatch（`call_runtime.zig:1830-1840`，在所有 hunk 之外）。
`src/exec/tailcall_dispatch.zig` 一个字节未改。

A/B/C 的语义输出在 21 个 constructor probe 与完整 test262（49775）上逐字节一致。

## 2. 实验设计与其边界

每个 variant 有**两个独立 codegen 实例**（`pad=0`），共 12 个固定二进制。

⚠️ **这些不是配对的 X/Y compiler state。** 跨 variant 的态匹配尝试过并失败：
排除编译器匿名编号（`__anon_N` 平移，跨 variant 有 471/471 个符号重命名，
曾占距离的 81%）后，**intra-variant build distance ≈ 2392**，
而 **cross-variant distance ≈ 3512** —— 两者同量级、不可分离。

因此采用 **build-instance replicates nested within each variant**：
每个 binary 独立汇总（15 样本），机制比较取**四个跨实例组合**
（`A1/B1`、`A1/B2`、`A2/B1`、`A2/B2`），报告 geomean、min-max 与方向一致性。
**不把两个实例的 30 个 raw sample 混为一组** —— 那会把 build-instance variance
当成运行噪声并高估置信度。

三个 variant 的 intra-variant distance 高度一致（zjs 层 2392/2386/2395，
same-runtime 层 2394/2394/2395，且 `added=removed=0`），支持"两态差异来自共同的
compiler 现象、与 constructor 开关无关"，但**不足以**证明 `A1` 与 `B1` 属于同一隐含状态。

ratio 一律为 `candidate/reference` elapsed-time 口径，`< 1` 表示 candidate 更快。
Octane score（越高越好）先转成 cost ratio = `ref_score / cand_score`，与 elapsed 同向。

## 3. Body bypass（B/C）：保留

### same-runtime

| workload | geomean | min–max | 方向 |
|---|---:|---|---|
| `eight-field` | **0.488** | 0.485–0.491 | 4/4 |
| `three-field` | **0.544** | 0.537–0.551 | 4/4 |
| `two-ctor-alt` | 0.577 | 0.568–0.587 | 4/4 |
| `one-field` | 0.601 | 0.599–0.603 | 4/4 |
| `eight-ctor-rr` | 0.643 | 0.639–0.647 | 4/4 |
| `pos-neg-alt` | 0.859 | 0.844–0.875 | 4/4 |
| `neg-only` | 1.048 | 1.039–1.057 | 4/4 |
| `proto-blocked` | *(1.061)* | — | **non-arbitrating** |

### whole-process

| workload | metric | geomean | 方向 |
|---|---|---:|---|
| `vector-kernel` | elapsed | **0.621** | 4/4 |
| `earley-boyer` | score→cost | **0.843** | 4/4 |
| `richards` | score→cost | 0.997 | 2/4 |
| `raytrace` | score→cost | 1.008 | 4/4 |

**证据**：命中 pattern 的构造器快 **36%–51%**，四个跨实例组合全部同向，远超 5% 门槛，
也远大于已观测的 build-instance 差异（约 2%）。产品 workload 兑现：
`vector-kernel` 快 38%、`earley-boyer` 快 16%。

**机制边界得到反向验证**：`neg-only` 反向 4.8% —— B 仍付 admission scan 成本，
C 完全不扫描。这证明 one-cut 切中的正是"扫描并绕过 constructor body"，
而非泛化的调用路径差异。

**非目标哨兵**：`raytrace` 反向 0.8%（其 Vector 走 `Class.create` 三元赋值，从不命中 pattern），
在 2% 内，无稳定回退。`richards` 中性（0.997，方向仅 2/4），符合它并非高度命中 simple-field pattern 的预期。

## 4. Memo（A/B）：保留为当前默认，但 carrier 需重设计

### 单态构造器 —— memo 稳定获益

| workload | geomean | 方向 |
|---|---:|---|
| `one-field` | **0.889** | 4/4 |
| `three-field` | **0.891** | 4/4 |
| `eight-field` | **0.911** | 4/4 |

### 多构造器轮转 —— single-entry thrash

| workload | geomean | 方向 |
|---|---:|---|
| `eight-ctor-rr` | **1.020** | 4/4 |
| `pos-neg-alt` | 1.023 | 3/4 |
| `two-ctor-alt` | **1.029** | 4/4 |

### whole-process

| workload | metric | geomean | 方向 |
|---|---|---:|---|
| `vector-kernel` | elapsed | **0.914** | 4/4 |
| `earley-boyer` | score→cost | **0.973** | 4/4 |
| `richards` | score→cost | 1.000 | 4/4 |
| `raytrace` | score→cost | 1.002 | 4/4 |

**证据**：单态构造器快 **9%–11%**（全部 4/4），证明避免重复扫描 immutable bytecode
pattern 是真实收益；产品侧 `vector-kernel` 快 8.6%、`earley-boyer` 快 2.7%（达到 2% 门槛），
`richards`/`raytrace` 无 ≥2% 回退。

但多构造器轮转**稳定慢 2%–3%**，两类 workload 内各自方向一致，不是噪声。这是
single-entry memo 的 thrash：

```text
constructor A 写入 memo → B 覆盖 → A 重新扫描并覆盖 → B 重新扫描并覆盖 → …
```

**裁决**：保持 A 为生产默认 —— 单态收益（9%–11%）明显大于多态损失（2%–3%），
产品 workload 净正，且当前无证据表明多态构造场景占主导。
**但不应把它描述为最终理想实现**（见 §6）。

## 5. `proto-blocked` 不参与定量裁决

B/C 两个 variant 的 IQR 达 **50%–52%**（A 正常），不满足性能仲裁条件。

> Direction is consistent with admission-scan overhead, but the measurement is
> non-arbitrating because B/C exhibit 50%–52% IQR.

raw samples、median、IQR 与 4/4 方向保留在 `1A-results.json`（标记 `arbitrating: false`），
但**不纳入任何 aggregate**，也不用于支撑"admission 固定损失约 6%"这一说法 ——
`neg-only`（1.048，4/4，IQR 正常）提供了更干净的负向 admission 证据。
其双模态根因未诊断，不阻塞 1A。

## 6. 后续（独立 issue，不在本轮实施）

数据给出了比"保留 M1"更有价值的结论：**分类缓存应绑定 FunctionBytecode，
而非 runtime single-entry**。

```zig
const SimpleCtorClassification = union(enum) {
    unknown,
    ineligible,
    eligible: SimpleCtorFacts,
};
```

置于 FunctionBytecode publication/finalization 的 immutable metadata。M2 最小版只存
`eligible/ineligible + field_count + compact decode facts`；M3 存完整
`[(field_atom, argument_index), …]` plan。可同时消除：单态重复扫描、
多构造器 single-entry thrash、negative constructor 的重复失败扫描、
prototype-blocked 等不合格函数的重复分类成本。

⚠️ **prototype chain 是否允许 bypass 仍是动态条件**，不能被 FB classification 取代。
FB metadata 只缓存"函数体结构是否属于 simple-field constructor pattern"；
每次 construct 仍须重新检查 prototype、setter、exotic object 等动态 admission 条件。

## 7. 已知限制

- 只采样 `pad=0`；未做多 pad lineage（绝对地址平移）；
- 未使用外部 PMU 作为裁决门槛。主指标是 same-runtime 内部计时与 whole-process
  wall-time/score，均由已有工具可靠提供；
- 两个 build instance 不构成配对的 compiler state（见 §2）；
- 编译器匿名编号 exclusion（`state_exclusions.json` v2）**只服务 codegen-distance 诊断**，
  不能用于证明两个二进制等价、不能用于证明默认 A 与原 HEAD 完全相同，
  且这些匿名函数的代码仍存在于实际被测二进制与性能运行中；
- `zig build` 在本仓库不可复现（两个确定的 codegen 状态），详见
  `docs/perf/ZIG-BUILD-BISTABILITY-2026-07.md`。本 dossier 不重复该报告。

## 8. 最终裁决

```text
Body bypass
------------
Decision: retain.
Classification: approved specialization.
Evidence:
- Eligible constructors improve by 36%-51%.
- All four cross-build-instance comparisons agree.
- Negative cases expose the expected ~5% admission-scan tax.
- The switch isolates the intended mechanism.

Runtime single-entry memo
-------------------------
Decision: retain as current production default; do not treat as final carrier.
Evidence:
- Monomorphic constructors improve by 9%-11%.
- Multi-constructor workloads regress by 2%-3% because of single-entry thrash.
- Both effects are internally consistent across build instances.

Follow-up:
- Replace runtime-wide M1 with FunctionBytecode-owned M2/M3 classification.
- Preserve dynamic prototype/admission checks.
- Do not remove body bypass.
```

**1A closed. 默认路径 A 不变。**

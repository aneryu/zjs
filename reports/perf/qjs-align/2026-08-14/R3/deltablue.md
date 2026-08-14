# OPT-R3-D deltablue — JS 函数级归因

lane: R3-D / CPU 8（三 pad 的 pad7 在 CPU 5） / **诊断批，非裁决**  
日期：2026-08-14  
config: `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`

| 二进制 | sha256 |
|---|---|
| zjs pad0 `/tmp/r3-bins/prod/bin/zjs` | `12bc8b8a3cb3b3c6feea8a1bea61f254caf6fde32fddc5b808d789170cf3309d` |
| zjs pad3 `/tmp/r3-bins/pad3/bin/zjs` | `542965de865afe973b3d4d7cc64930ba2d1c181a8c36863d9b1077e2e3d95693` |
| zjs pad7 `/tmp/r3-bins/pad7/bin/zjs` | `e9fe8f66450ae5846f0201517f3130c81eba76d8f7840f95cfa905ca6c8a34c9` |
| qjs `/home/aneryu/quickjs/qjs` | `b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d` |

普查：隔离 worktree `/tmp/wt-r3-census` 的 `zjs-profile`（不合 main）。  
禁区遵守：不重启 tail_call，不把结果写成「调用边界弥散」。

## 结论先行

1. **没有 RayTrace 式 `apply(arguments)` 包装体。** 源码里 `.apply(` 只出现 1 次且不热。
2. 热名单是 **OO 短 accessor 链**：前 8 个函数占全部 opcode 的 **71.4%**，几乎全是 1–3 条指令的 `input`/`output`/`at`/`size`/`constraintAt`/`Plan.size` 加上 `Plan.execute` / `EqualityConstraint.execute`。
3. 消融把这条链从 `Plan.execute` + `EqualityConstraint.execute` + `markInputs`/`recalculate` 拿掉后，**两侧都暴涨 ~85%**。超额（z 增益 − q 增益）三 pad：
   - pad0 **+2.443% ~ +0.161pp**
   - pad3 **+2.341% ~ +0.155pp**
   - pad7 **+2.088% ~ +0.138pp**
   符号零翻转，中位 +0.155pp，**最坏 pad +0.138pp 未过 ≥0.15pp 硬门槛**。
4. 因此：**形状已命名，但不是「路径 A 可修 ≥0.15pp」的正式命中。** 登记为边缘候选。
5. 去掉这 71% opcode 的胶水之后 z/q 只从 0.868 → 0.880。deltablue 账本赤字 0.93pp 里大约 **0.14pp** 能钉在短方法单位成本上，剩下 ~0.8pp **不在这些 JS 函数形态里**。
6. 路径 A 含义：编译器给 ≤3 opcode 的 JS 访问器做内联是**新机制**（不是 teardown / tail_call），但它会让 zjs 独享 +85%——那是「超 qjs」不是「追平」。追平空间就是这 0.14pp。

lane 成功判据：诚实扫完，头部形状已命名，正式 ≥0.15pp 未过 → 记 **「JS 级：形状已命名 / 价值未过门槛」**。

## Phase 1 — 逐 JS 函数普查

zjs-only opcode 份额。无 qjs 对照计数器；D11 已证明同类基准两侧总 opcode 几乎相同
（RayTrace 1.0013 / PdfJS 0.9973），按 zjs 绝对 opcode 排序选消融对象，超额由 Phase 2 测。

总 opcode 282,553,910；总调用 23,231,049；93 函数；overflow=false。原始：`census.txt`。

| 函数（源码行） | 调用 | opcode | 份额 | 形态 |
|---|---:|---:|---:|---|
| `Plan.execute` (:1179) | 28,700 | 40.2M | 14.23% | 循环里 `size`/`constraintAt` 再 `c.execute()` |
| `BinaryConstraint.output` (:817) | 2,811,985 | 30.9M | 10.95% | 单三元字段选择 |
| `BinaryConstraint.input` (:810) | 2,399,935 | 26.4M | 9.34% | 同上 |
| `EqualityConstraint.execute` (:929) | 2,091,000 | 23.0M | 8.14% | `this.output().value = this.input().value` |
| `OrderedCollection.size` (:474) | 3,695,535 | 22.2M | 7.85% | `return this.elms.length` |
| `OrderedCollection.at` (:470) | 3,056,960 | 21.4M | 7.57% | `return this.elms[index]` |
| `Plan.constraintAt` (:1175) | 2,492,800 | 19.9M | 7.06% | 转调 `this.v.at` |
| `Plan.size` (:1171) | 2,521,500 | 17.7M | 6.25% | 转调 `this.v.size` |

## Phase 2 — 源码消融（8 samples，ABBA，非裁决）

量 = (zjs_var/zjs_base − 1) − (qjs_var/qjs_base − 1)。高 = 更帮 zjs。

| id | 写法 | z 增益 | q 增益 | 超额 | ~pp | 裁决 |
|---|---|---:|---:|---:|---:|---|
| v1 | `EqualityConstraint.execute` 内联 input/output | +13.325% | +12.334% | +0.991% | +0.065 | 排名用；两侧同向 |
| v2 | `Plan.execute` 直走 `this.v.elms[i].execute()` | +50.926% | +51.852% | −0.926% | −0.061 | qjs 受益更大 |
| v3 | v1+v2 + markInputs/recalculate 内联 | +87.198% | +84.755% | +2.443% | +0.161 | 进三 pad |

v3 三 pad（同一份 JS）：

| pad | z 增益 | q 增益 | 超额 | ~pp | z/q base→var |
|---|---:|---:|---:|---:|---|
| 0 CPU8 | +87.198% | +84.755% | +2.443% | +0.161 | 0.8685→0.8800 |
| 3 CPU8 | +86.887% | +84.545% | +2.341% | +0.155 | 0.8692→0.8803 |
| 7 CPU5 | +86.887% | +84.799% | +2.088% | +0.138 | 0.8708→0.8806 |

中位 +0.155pp / 极差 0.023pp / 效应÷极差 ≈ 6.7x。零翻转，最坏未过 0.15。  
原始 JSON：`ab/v3-tiny-combined.json`、`ab/v3-tiny-combined-pad3.json`、`ab/v3-tiny-combined-pad7.json`。  
用例：`cases/v1-eq-inline.js` `cases/v2-plan-inline.js` `cases/v3-tiny-combined.js`。

## Phase 3 — 机制表

| 机制 | 涉及 JS 函数 | 绝对超出 | 消融证据(三 pad) | 路径A可修? | 预计 pp |
|---|---|---|---|---|---|
| 短 accessor 方法链单位成本（direction 三元 + 字段转发） | `Plan.execute` / `EqualityConstraint.execute` / `input` / `output` / `at` / `size` | 共同成本巨大（两侧 +85%）；超额只 +2.1–2.4% | +0.161 / +0.155 / +0.138，零翻转，最坏 0.138 | 编译期内联 ≤3 opcode 访问器 = **新机制**（会超 qjs，不是追平）。追平只剩 0.14pp。禁止再写成调用边界弥散 / tail_call | **0.14（未过 0.15 门槛）** |

zjs 侧对应：`src/exec/tailcall_dispatch.zig` 短函数进入/返回 + `get_field`（`BinaryConstraint.input/output` 的 `this.direction`/`this.v1`/`this.v2`）。  
qjs 侧对应：`JS_CallInternal` 短函数 + `JS_GetProperty`。  
不改引擎。R4 若立项内联器，必须单独定价「超 qjs」效应，不能把它算进追平。

## [PROGRESS]

```
[PROGRESS] R3-D census done funcs=93 opcodes=282553910
[PROGRESS] R3-D v1 excess=+0.991% ~+0.065pp
[PROGRESS] R3-D v2 excess=-0.926% ~-0.061pp
[PROGRESS] R3-D v3 pad0/3/7 = +0.161/+0.155/+0.138pp zero-flip worst<0.15
[PROGRESS] R3-D DONE shape-named value-below-bar
```

# R7-T typescript 内层 — 提纯 + 二分

lane: R7-T / CPU 6 / **诊断批，src 只读**  
日期：2026-08-14  
目标宏观：内层 `run()` **1.215×**（R4-T；整进程 FW 1.029 是前端摊销，禁止当目标）  
zjs pad0 `12bc8b8a…cf3309d` / pad3 `542965de…` / pad7 `e9fe8f66…`  
qjs `b76d1542…1171364d`

## 结论先行

**case 复现了内层 1.215，但删不下一个「拿掉即塌」的 JS 构造。**

1. case-pure = zoo 源 + 8×`runTypescript`，用脚本内 `Date.now` 报内层 wall。8-sample pad0 **inner 1.2006**（门 1.195–1.235）。
2. 整进程 cyc 1.180：2.5MB 前端仍在摊，所以本 lane 以 **inner_wall** 为比值不变量。
3. 删 emit：inner 1.187，**保持**。
4. 只留 `addUnit`（parse，无 typecheck/emit）：inner **1.228**，**保持且略升**。税在 parse，不在 emit/typecheck。
5. 把 `compiler_input` 截到 80k：inner 1.179 且 wall 0.41s — **漂移 + 不足 1s**。完整输入的 parse mix 才能托住 1.215。
6. 三 pad inner：1.201 / 1.200 / 1.201。零翻转。
7. 与 R3-T「JS 级干净」一致：lexer 胶水两侧同价。机制在引擎跑这个 parse 循环（分派 IPC / 帧 / 禁区 IMPL-TEARDOWN），**没有新的 FAITHFUL 项**。

## 1. 提纯轨迹

| 步 | 文件 | n | 整进程 cyc | inner wall | 门 1.215±0.02 | 注 |
|---|---|---:|---:|---:|---|---|
| 0a 6× 整进程 | `step0.js` | 4 | 1.1675 | — | 前端摊薄 | 教训：不能用整进程比内层 |
| 0b 12× 整进程 | `step0.js` | 4 | 1.1836 | — | 仍偏低 | 摊薄减轻但不够 |
| **0 case-pure** | `case-pure.js` | **8** | 1.1805 | **1.2006** | **PASS** | 8×run，R7_WALL |
| 1 去 emit | `s1-no-emit.js` | 4 | 1.1659 | 1.1871 | 保持 | typecheck 仍在 |
| 2 只 parse | `s2-parse-only.js` | 4 | 1.2052 | **1.2285** | 保持 | 无 typecheck/emit |
| 3 输入 80k | `s3-parse-80k.js` | 4 | 1.1458 | 1.1794 | 漂移；0.41s | 不可用 |

## 2. 二分

| 构造 | 结果 | 判定 |
|---|---|---|
| emit / `Verify` sink | 两侧同比例变快（R3-T v3 +0.003pp；本批去 emit 比值保持） | **不携带** |
| `reTypeCheck` | 去掉后比值升到 1.228 | typecheck 略偏 zjs 友好，**不是赤字源** |
| 完整 `compiler_input` 的 `addUnit`/parse | 截断即漂移 | **工作量本身**，不是可换写法的胶水 |
| `innerScan` / `peekChar` / `nextChar` | R3 已消融 ~0 | JS 级干净 |

≤3 个「拿掉即塌」的构造：**零**。诚实结论：删到 parse 内核仍保持比。

## 3. 三 pad（inner_wall）

| | pad0 n=8 | pad3 n=4 | pad7 n=4 |
|---|---:|---:|---:|
| inner z/q | 1.2006 | 1.1995 | 1.2006 |
| 整进程 cyc | 1.1805 | 1.1814 | 1.1815 |

## 4. 机制连接

R4-C：property 两侧 ~37%，+132M other = RC/GC + `pushExactSimpleFrame`。  
R5-P：`get_field` ZJS-ADVANTAGE，禁止「修 TS property」。  
R5-C / R6-K：leaf-call 帧。  
R6-F：fe_stall / I-cache。  
IMPL-TEARDOWN 仍禁区。

无新的 file:line 修复点。本 lane 把「1.215 是 parse 内层、不是 emit/typecheck/前端」钉死。

## 5. 登记候选

无新增 FAITHFUL。继续吃 R6-K / R6-F 已登记项。不要为 TS 立「修 Verify / charCodeAt / get_field」。

# R7-Z zlib — 提纯 + 前端判决

lane: R7-Z / CPU 8 / **诊断批，src 只读**；并入原 R6-F 的前端假设实验  
日期：2026-08-14  
目标宏观：FW cycles **1.073–1.086**（zoo 0.920；R4-T 1.0862）  
zjs pad0 `12bc8b8a…` / pad3 `542965de…` / pad7 `e9fe8f66…`  
qjs `b76d1542…`

## 结论先行

1. case-pure = zoo 源 + 内层 `Ya(["1"])`。pad0 8-sample inner **1.0930** / cyc 1.0912；pad3 1.076；pad7 **1.074**。都在 1.073±0.02 内，零翻转。
2. emscripten 压缩源**无法再删**而不碎。提纯停在「整段 inflate」。诚实：**机制不在可删的 JS 构造里**。
3. **前端假设判决（计划任务 ②）**：小工作集**可以**让周期比翻到 zjs 优势，但 **IPC 差距不随「变小」单调消失**，opcode mix 同样决定。支持 R6-F「I-cache/工作集是必要非充分」；不能改判成「只是间接跳」或「只是 I-cache」。
4. 无新 FAITHFUL。继续 R6-F 候选 a（`get_arg*` 拉回热段）。

## 1. 提纯轨迹

| 步 | 文件 | n | cyc z/q | inner | 门 | 注 |
|---|---|---:|---:|---:|---|---|
| 0 1×runZlib 整进程 | `step0.js` | 4 | 1.0750 | — | PASS | 含 Module 初始化 |
| **0 case-pure 2×Ya** | `case-pure.js` | **8** | 1.0912 | **1.0930** | PASS | 初始化在计时外 |
| pad3 | 同上 | 4 | 1.0761 | 1.0775 | PASS | |
| pad7 | 同上 | 4 | 1.0738 | 1.0751 | PASS | 最贴 1.073 |

insn 恒 ≈0.934：zjs 指令更少，周期仍多 ⇒ IPC 故事（R5-S / R6-F），不是 handler 体更胖。

## 2. 前端假设实验

计划原话：小 case 若 IPC 差距消失 → I-cache/工作集；若仍在 → 间接跳本身。

| case | 工作集 | cyc z/q | insn z/q | IPC z/q | 读法 |
|---|---|---:|---:|---:|---|
| 纯 `i++/s++` 2e8 次 | 极少 opcode | **0.8815** | 0.805 | 0.913 | 小集 ⇒ zjs **反超**，IPC 差距收窄 |
| `a[i&7] + or/sar` | 小 + `get_array_el` | **0.9663** | 0.801 | 0.829 | 仍反超；IPC 0.83 接近 zlib |
| `or/xor/add/shift` 8e7 | 小、无数组 | **1.0856** | **0.694** | **0.640** | 周期比像 zlib，IPC **更差** |
| case-pure inflate | 大，~27 热 opcode | 1.07–1.09 | 0.934 | 0.86–0.87 | 宏观 |

**判决：**

- 「变小 ⇒ IPC 差距消失」**不成立**（tiny-or IPC 0.64 更差）。
- 「间接跳本身单独决定」**也不成立**（increment 翻成 0.88）。
- 工作集 **和** opcode mix 都要。R6-F 的硬事实仍在：`get_arg0` 钉在 1MB 外 `.text.zjs.tail_hot` → 热 27 op 跨 269 页；去掉后 9.2 vs qjs 5.5。那是 zlib **特有**的 I-cache 伤，不是通用微基准能代替的。

宪法第 4 条：increment / tiny-or / arr **只算灵感**，不当定位证据。定位证据是 case-pure 保持 1.07x + R6-F 跨页计数。

## 3. 三 pad（case-pure）

| | pad0 n=8 | pad3 n=4 | pad7 n=4 |
|---|---:|---:|---:|
| cyc | 1.0912 | 1.0761 | 1.0738 |
| inner | 1.0930 | 1.0775 | 1.0751 |
| insn | 0.9337 | 0.9344 | 0.9344 |
| IPC | 0.8557 | 0.8683 | 0.8702 |

pad0 8-sample 略高（z 侧 32.9–33.7G 抖动），仍在门内，符号不翻。

## 4. 机制连接

R5-S/A：热 `get_loc0`/`add`/`or`/`sar` 是 ZJS-ADVANTAGE；dispatch 重建税 = 0。  
R5-A：R4-U「dispatch+call=111%」是桶伪影。  
R6-F：fe_stall 占 Δcyc 46–85%；`get_arg0` 远段。

## 5. 登记候选

无新增。维持 R6-F **候选 a**：按频次把 `get_arg*` 拉回热段。不实施。

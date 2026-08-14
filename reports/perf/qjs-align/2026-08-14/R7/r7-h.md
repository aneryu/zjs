# R7-H richards — 提纯 + 二分

lane: R7-H / CPU 7 / **诊断批，src 只读**  
日期：2026-08-14  
目标宏观：FW cycles **1.1039**（zoo 0.904）  
zjs pad0 `12bc8b8a…` / pad3 `542965de…` / pad7 `e9fe8f66…`  
qjs `b76d1542…`

## 结论先行

**case 复现 1.11，但 OO 调度器删不下一个塌缩构造。**

1. case-pure = zoo 源 + 500×`runRichards`。8-sample pad0 **cyc 1.1092**（门 1.084–1.124）。
2. 内联 `TCB.run`、内联 `Packet.addTo`、schedule 改自由函数、kind-switch 代替虚 `task.run`：比值 **1.085–1.100**，全部保持（最大漂移 0.024，kind-switch 擦边）。
3. 删 Device B + Handler B：14ms，调度器提前退出，**作废**。
4. 三 pad：1.109 / 1.111 / 1.111。零翻转。
5. 与 R4-U「无单桶 ≥50%」、R3 deltablue「短 accessor 链、JS 级干净」同构：**弥散 OO 字段+虚调用**，没有 splay/raytrace 那种单点构造。
6. 无新增 ≥1.0 FAITHFUL 项。R6-K leaf-call 可能啃一点 `task.run`。

## 1. 提纯轨迹

| 步 | 文件 | n | cyc z/q | 门 | 注 |
|---|---|---:|---:|---|---|
| 0a 250× | `step0.js` 旧 | 4 | 1.1078 | PASS | wall 0.61s 不足 1s |
| **0 case-pure 500×** | `case-pure.js` | **8** | **1.1092** | **PASS** | ≥1s |
| 1 去 B 任务 | `step1-no-B.js` | 4 | 1.1858 | 作废 | 14ms，Idle 释放不存在的 B 后立刻结束 |
| 2 内联 TCB.run | `step2-inline-tcb-run.js` | 4 | 1.0886 | 保持 | |
| 3 内联 Packet.addTo | `s3-inline-addTo.js` | 4 | 1.1000 | 保持 | |
| 4 schedule 自由函数 | `s4-free-schedule.js` | 4 | 1.0911 | 保持 | |
| 5 kind-switch + `.call` | `s5-kind-switch.js` | 4 | 1.0847 | 擦边保持 | 仍是方法体，只换了派发形 |

## 2. 二分

没有「拿掉即塌」的构造。剩下的是：

- `get_field` 16% + `put_field` 5%（R5-P：命中臂 ZJS-ADVANTAGE）
- 四个 `Task.run` 虚调用 + `scheduler.queue/release/hold`
- Packet 链表

换写法保语义量之后比值不动 ⇒ 税在引擎的方法调用/字段，不在某一段 Richards 胶水。

## 3. 三 pad

| | pad0 n=8 | pad3 n=4 | pad7 n=4 |
|---|---:|---:|---:|
| cyc z/q | 1.1092 | 1.1110 | 1.1108 |
| insn z/q | 1.1755 | 1.1775 | 1.1775 |
| IPC z/q | 1.0598 | 1.0598 | 1.0600 |

insn 1.176、IPC 1.06：zjs **指令更多但 IPC 更好**，周期比 1.11。与 raytrace（insn 1.25 + IPC 0.97）不同体制。

## 4. 机制连接

R4-U：richards 无单桶 ≥50%。  
R5-C：调用帧。R6-K 已去 `execCall` 0x220，剩 ~0xa0。  
禁止写成 tail_call（H3 CLOSED）。

## 5. 登记候选

无新增。观察 R6-K 3-pad zoo 的 richards 格子；预期远低于 0.3pp。

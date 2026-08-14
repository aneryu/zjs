# OPT-R5 四 lane 汇总 — 逐 opcode 机器码对照

日期：2026-08-14。执行：grok。计划：`OPT-PLAN-GROK-R5.md`。  
src/ 未改。修复候选只登记。CPU 19 未碰。路径 B PARKED 维持。

zjs pad0 `12bc8b8a3cb3b3c6feea8a1bea61f254caf6fde32fddc5b808d789170cf3309d`  
qjs labels `394d453d5f8a68fe8a1f58c2ce667f7f36ffc9dd55a3821942e220b726381a1f`  
qjs pinned `b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d`  
频次用 `zjs-profile` `b2b612f3…` + `/tmp/qjs-r5-count`（`SWITCH` 逗号自增，不动 pinned 产物）。

## 结果表

| lane | 状态 | 闭合度 | 头部 FAITHFUL-FIXABLE |
|---|---|---|---|
| R5-S loc/栈/dispatch | **热体 ZJS-ADVANTAGE；分派形态 ARCHITECTURAL** | zlib opcode 0.9980；Σ(freq×Δinsn) 负，对准 PMU insn 0.9355 ±15%。周期 1.086 = IPC 0.861，不在 insn 预算 | 无 |
| R5-A arith/位/分支 + zlib | **热体 ZJS-ADVANTAGE；周期残差 ARCHITECTURAL** | 同上。zlib C=0.0%，R4-U dispatch% **改写**为分类伪影 | 无（`get_array_el` 去帧记在 P） |
| R5-P field/array/原型 | **get_field 命中 ZJS-ADVANTAGE** | TS/EB P 预算为负，解释不了 1.215× 内层税 | **get_array_el 快数组去帧**（outline 零 RC；登记，单条 <0.3pp） |
| R5-C call/return/14 write | **14 字段全部对上；6+6 ARCHITECTURAL** | 不能拿 CASE 行对 PMU（7.12× 教训）。qjs 成本在嵌套 `JS_CallInternal` | **leaf/exact call 的 frame-zero 克隆**（登记，待 R6 三 pad） |

## 一条可修机制 / 一条旧归因改写

成功双向都交了：

1. **可修（登记，不实施）：**  
   - C：`op_call*_leaf` / `op_call_method_leaf` 无 96B+0x220 帧，只 resolve+`enterEntry`+`br`。qjs CASE 在 `bl JS_CallInternal` 前就是这个形状（`label_OP_call0` 0x254ec，quickjs.c:18175–18192）。  
   - P：`get_array_el` 快数组 frame-zero（现在为 `bl destroyZeroRef` 无条件开 0x50 帧）。
2. **旧归因改写：**  
   - R4-U zlib「dispatch+call = 净超出 111%」——call 份额 0.0%；dispatch 桶吞掉了全部 `tailcall_dispatch.opLoc/opBinary`。真实故事：insn **更少**、IPC **更差**。  
   - 「每次 dispatch 重建 pc/sp/var_buf」——热路径 **0 次**。反而是 qjs 每次 `get_loc0` 从 `[fp-248]` 取 `var_buf`。

## 不要写进 R6 的东西

- 改 get_loc / add / or / sar / get_field 命中臂去「对齐」更胖的 qjs CASE。  
- 重开 H3、readfwd、String capacity、IMPL-TEARDOWN。  
- 把 14 store 再诊断成无主 stall。  
- 用 profile `avg_ns≈40` 当单位成本。

## 交付

- `/tmp/r5-s/BUDGET.md` `/tmp/r5-a/BUDGET.md` `/tmp/r5-p/BUDGET.md` `/tmp/r5-c/BUDGET.md`
- 频次：`/tmp/r5/census/{bench}-z.json`（15）+ `{bench}-q.hist`（9 锚点）
- 反汇编：`/tmp/r5/asm/{zjs,qjs}-*.s` + `hot-compare.json` + `zjs-dispatch-table.json`  
  ⚠️ `hot-compare.json` 的 z_hot 在 **冷臂 br 在前** 的 handler（add/or/get_field/call）上偏小；BUDGET 用的是跟完 int/object 臂的计数。
- 工装：`/tmp/r5/opcodes.py` `dump_handlers.py` `make_fixed.py` `/tmp/qjs-r5-count/`

# OPT-R6 汇总

日期：2026-08-14。执行：grok。计划：`OPT-PLAN-GROK-R6.md`。  
CPU 19 未碰。未合 main。

## 结果表

| lane | 状态 | 结果 |
|---|---|---|
| **R6-K** 两刀 | **AWAIT-MEASURE** | `9ea7dbb5` get_array_el 热臂 **已零帧**（objdump 无 sub/bl）。`e0874c66` leaf-call clone **去掉 execCall 0x220 帧**，仍留 ~0xa0 constructor spill。test-exec 436、Error.stack IDENTICAL。ReleaseSafe 3 fail：2 个 test262 FileNotFound（空 submodule）+ 1 个 regexp 编译器栈（与两刀路径无关，Debug 通过）。 |
| **R6-F** 前端 | **机制已命名** | 四基准 fe_stall/Δcyc = 46–85%。backend/iTLB 排除。zlib 热集 27 op 跨 **269 页**，只因 `get_arg0` 远 section；去掉后 9.2 页 vs qjs 5.5 页。候选 a：按频次聚簇（含把 `get_arg*` 拉回热段）。不实施。 |

## 交付

- 分支 / worktree：`grok/opt-r6-k` / `/home/aneryu/worktree-grok-r6-k`
- [`/tmp/r6-k/NOTES.md`](/tmp/r6-k/NOTES.md)
- [`/tmp/r6-f/LEDGER.md`](/tmp/r6-f/LEDGER.md)
- PMU 原文：`/tmp/r6-f/{zlib,mandreel,gbemu,box2d}-{zjs,qjs}.stat`

## Driver 下一步

1. worktree 补 `test262/` 后亲跑 test262-gate。  
2. 组包 3-pad zoo（0/3/7 × 8），看 deltablue/richards/raytrace/pdfjs + 四资产。  
3. 通过后再做组件归因。预期 0.2–0.4pp，可能低于 0.278 MDE。

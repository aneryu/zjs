# OPT-ROADMAP 2026-07-18 — 调用战役收官后的优化规划

> 基线：main `e73e8a0c`（调用机制 cycle 战役十一轮 34 刀收官态，29 commit）· qjs 参照：`b76d1542…`（2026-06-04，SHA 恒验）
> 测量协议：CPU19（Cortex-X925）ReleaseFast，`taskset -c 19 perf stat -e cycles,instructions`，armv8_pmuv3_1 行取值，best-of-N min，9 轮交错 A/B。
> 本文自包含：新会话可依此直接开工，方法论附录（§7）是全部 34 刀 A/B 校准的执行铁律。

## 0. 战役终态与新版图（2026-07-18 全部亲验）

**调用机制战役终态**（起点 1.24–1.81x）：

| 形态 | 终态 | 形态 | 终态 |
|---|---:|---|---:|
| function-call | **0.982x** | add-two | 1.104x |
| const 整程序 | 1.007x | method-missing | 1.108x |
| arrow | 1.013x | method-zero/one | 1.132/1.140x |
| strict | 1.020x | fib | 1.146x |
| missing | 1.051x | closure | 1.156x |
| arrow-this | 1.094x | 纯调用税 | 1.154x |

**收官日新测绘（调用以外战场，best-of-3）**：

| 基准 | zjs/qjs | 裁读 |
|---|---:|---|
| for-of-bytecode-next-zero-arg-2m | **1.778x** | 🎯最大前沿（长期当负对照被掩盖） |
| array-push-one-arg-5m | **1.582x** | 🎯 |
| object-literal-var-1m | **1.518x** | 🎯（07-16 记录 1.66x，随调用战役微降） |
| allocation-empty-object-2m | 1.182x | 中目标 |
| property-read-computed-5m | 1.093x | 低优 |
| string-charcode | 1.089x | 低优 |
| property-read-mono / inherited / length-own | 1.007 / 1.022 / **0.995x** | ✅已平 |
| strconcat-accum-1m | **0.570x** | ✅大幅反超 |

## 1. 战场 A：for-of 迭代协议（1.778x，第一优先）

**现状证据**：`for-of-bytecode-next-zero-arg-2m` 全战役只作负对照（判「不回退」从不看绝对差距）——与 method 战役前的处境完全同构（「探针角色掩盖收割对象」模式第二例）。F1 刀曾顺带给它 −1.45%（iterator next 走 enterEntry），证明调用面收益可达。

**机制假设与刀清单**：
- **A1（首刀，先测绘）**：`perf record` 该基准 + 符号分解，热量在 ①next() 调用面（`pushBorrowedIteratorAndEnter`，tailcall_dispatch）②迭代结果对象协议（result {value,done} 构造/解构——历史刀 for-of result-obj-free 曾拿 3.7x，qjs-bottomup-audit 记录）③`op_for_of_next` 专用 op 的检查链。测绘决定主刀。
- **A2（调用面候选）**：borrowed-iterator 帧的 leaf 化——M1 全套（warm carve+resume 记录）对 borrowed 布局的变体。注意 R3 战报教训：borrowed-iterator 帧 action 恒 `.for_of_next`（continuation 非 `.next`），R2 返回臂不适用，需 for_of continuation 的专用薄臂；O1 曾因此把 borrowed 排除在记录写点外（v3 comptime setup_path 跳过法资产在案）。
- **A3（协议面候选）**：`op_for_of_next` 的 result 处理与 qjs OP_for_of_next（quickjs.c）逐段对照——qjs 的 done/value 双栈槽协议 vs zjs 形态。
- 枢轴线：for-of cyc ≤ −15%（1.78x 的空间对标 method 战役 −18%）。

## 2. 战场 B：array-push（1.582x）

**已知历史**（alloc-layer-divergence 2026-07-06 审计）：array 3 props 形态曾 2.82x→经 shape-D5/GC-D3/AL1 落到 1.79x insn；push 路径的专项审计未做过。
- **B1**：`perf record` array-push 基准定位——嫌疑面：①push 的容量增长协议（qjs js_array_push 的 fast 路径 quickjs.c:39xxx，`u.array.count` 直写 vs zjs 的 length/count 同步）②每 push 的 shape/exotic 检查链③元素槽写宽度。
- **B2**：按测绘结果对照 qjs `js_array_push` 逐段镜像（memory 记录 L3 array count/length 拆分已落地，残差在 per-push 检查）。
- 枢轴线：array-push cyc ≤ −15%。

## 3. 战场 C：对象字面量与分配（1.518x / 1.182x）

**已知历史**（大量审计在案，docs/qjs-align/ALLOC-LAYER-DIVERGENCE-2026-07-06.md + IMPL-DIVERGENCE-STATUS-2026-07-11.md）：
- **C1（最大已定位未做）**：shape rc==1 原地演化臂缺失——qjs `add_property`（quickjs.c:9206-9236）三臂中的 in-place 臂，zjs 每 property 走 shape 查找/克隆。pin 实验证 churn 603 vs 52 insn/iter。`object-literal-let` 的 kill-before-create 序致双引擎每 iter shape 建毁（zjs 256 vs qjs 80 insn）。
- **C2**：var-init `make_loc_ref` 毒化残留复查（07-11 记录「缺 optimize_scope_make_ref」——open-binding 表模型 b0b2e4ad 落地后此项状态需重审计）。
- **C3**：allocation-empty 1.182x 残差——07-08 曾打平（0.96x cyc），调用战役后回升，先差分归因（可能是 leaf 家族改动的布局/守卫外溢，也可能 qjs 侧口径）。
- 枢轴线：objlit-var ≤ −20%（对标 churn 差）、alloc-empty 回 1.0x 带。

## 4. 战场 D：调用残差收尾（1.10–1.16x 带内精修）

- **D1**：closure 1.156x——Q2 后 callee 已入 leaf，残差在捕获 cell 读链（`get_var_ref0` 系）与深递归池链；先 record 归因。
- **D2**：fib 1.146x 残差=帧池弹出指针追逐 6.18 cyc/call（第七轮归因，qjs alloca≈0）——池链 warm 化的下一形态（chunk 内 bump 指针驻留 Entry？）。
- **D3**：N2 freight 9-store 簇（动 `pushExactSimpleFrame` 签名，第九轮战报留档）。
- **D4**：strict 带参 method（复用 `_98617` 实例加一冷位，N2 战报方案在案）。
- 预算各 −2~5%；此战场为填隙型，排在 A/B/C 之后。

## 5. 战场 E：发码 / peephole（普惠型）

- **E1**：`inc_loc_check` 熔合——两引擎的 `let` 循环变量 `i++` 均因 TDZ 阻熔展开为栈上 4 op；zjs 补 check 变体熔合可 control/const 双吃并消 TOS 同址污染（inc_dec +2.20 cyc/iter，第七轮污染归因）。⚠️qjs 无此 op：属超集发码，须按「行为等价+ZJS_DISASM 偏离标注」纪律实施，先给 TDZ 语义等价证明。
- **E2**：IMPL-DIVERGENCE §4.9 的 26 条 peephole 规则全集（dup+put→set、&&坍缩、is_null 折叠等）——普惠低风险，适合作为独立小战役批量 A/B。

## 6. 战场 F：正确性 ticket（与性能并行，不占 PMU）

1. **F-1 预存 force-GC 失败**：`-Dzjs_force_gc=true` 的 test-exec 挂 `HeapLiveBytesMismatch`（gc.zig:1662 verifyHeapAccounting），基线 db9625f5 亲证预存。
2. **F-2 尾调用无深度护栏**：`var g=function rec(){return rec();}; g();` qjs 抛 InternalError(stack overflow)，zjs 无限自旋（平坦 Machine 尾调复用恒栈）；非尾调正常。修法=尾调计数或 interrupt 可达性保证。
3. **F-3 generator 函数表达式作默认参数值**：parser 局限（第五轮 Y 刀战报记录）。

## 7. 方法论附录（34 刀 A/B 校准，执行铁律）

**X925 cycle 因果律**——只有四类改动换得到周期：
1. forwarding 罚消除，且错配载入的结果喂关键链（A/O 系实证；喂 rc-dec 等死端汇点则被 OoO 吸收——R1/R4 反证）；
2. 喂间接跳转目标的取数链缩短（B1/R2/F1/F3 实证，−1.4~−4.9/刀）；
3. 检查链双计头删除+联动（F3：单删检查 +0.31，带 lazy 联动 −2.42）；
4. bl 链塌缩（收益主体=callee-saved 往返+freight store+出参往返，M1 −18%/O2 −35%；bl 指令本身在 RAS 阴影下免费——C1 反证）。
**删不到**（11 刀阵亡实证）：纯判定 load（并行扇出+全预测）、死端记账、非热臂展开。

**工程律**：热臂判别绝不共享（含源码模板层——N1/共享模板双反证）；展开臂必须=热臂（M2）；新状态复用退役槽（Zig 热结构加字段会指针桶重排）；packed-struct bitcast 有 alloca spill 硬伤（raw-bits 孪生绕过）；`asm "=r"/"0"` launder 防 LLVM 重融合 16B copy idiom。

**测量律**：stall 采样座标≠关键路径（占用≠承载，选刀先问「这个值喂谁」）；布局吸引子（同源重建掷币多稳定态，tax ±1 固有噪声）——`align(64)` 钉群（op_return+十热 op 簇）已布防；**幻影判别：负对照 cyc 超线但 insn|Δ|<0.1% 判布局幻影，cyc>+1.0% 且 insn>+0.3% 才真回退**；agent 自报 tax 口径必亲验；「探针角色掩盖收割对象」——负对照基准要定期看绝对差距（method/for-of 两例）。

**门禁协议**（每刀）：test-exec/test-core/test-bytecode/checkpoint-check/test-altrepr（repr 敏感必跑——8B 腿曾抓 2 bug）全绿进 PMU；parser/发码/所有权刀加全量 test262（known delta zero 为准，worktree cwd 无 test-root——排除表陷阱）；发码探针（预期不变的基准 ZJS_DISASM 逐字节对比）；红灯先行（先证 FAIL 再证绿）。

**编排协议**：worktree 隔离（绝不写主树）、逐文件 git add（绝不 -A）、基线二进制接力（同 worktree 自产）、PMU 串行互斥、判定线预先声明机械执行、失败刀战报必含反汇编死因归因（失败解剖是因果律的来源）、qjs 对照先行（「反超先查 qjs」——Q1 前提证伪先例）。

## 8. 执行顺序建议

```
第一批（新大陆）：A1 测绘 → A2/A3（for-of 主刀）→ B1 测绘 → B2（array-push）
第二批（旧账）  ：C1 shape 原地臂 → C3 alloc 回归归因 → C2 复查
第三批（填隙）  ：D1-D4 调用残差 + E2 peephole 批量
并行（不占 PMU）：F-1/F-2/F-3 正确性 ticket
等待项          ：preserve-none CC（Zig 工具链）、E1（需超集发码裁决）
```

每批一个 workflow（串行刀+形态枢轴判定），批间人工裁决。预期：A/B/C 三战场按调用战役命中率（34 刀 19 中）折算，可将 for-of/array-push/objlit 压进 1.1–1.2x 带。

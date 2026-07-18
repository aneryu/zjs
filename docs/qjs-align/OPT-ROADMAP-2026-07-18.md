# OPT-ROADMAP 2026-07-18 — 机制层优化规划（调用战役收官后）

> 基线：main `e73e8a0c`（调用机制 cycle 战役十一轮 34 刀收官态）· qjs 参照：`b76d1542…`（2026-06-04）
> 测量协议：CPU19（Cortex-X925）ReleaseFast，`taskset -c 19 perf stat`，armv8_pmuv3_1，best-of-N min，9 轮交错 A/B。
> **组织原则（v2 修订）：按机制层组织，不按基准组织。** 基准是机制的症状探针：一个 1.78x 的基准底下通常叠着 2–3 个机制的成本，同一机制往往同时压着多个基准。刀立在机制上，基准只做三种用途——①机制归因的显影剂②机制刀的直接探针③受益面验证（多点同向）。判定协议相应修正（§8）。

## 0. 现状数据（2026-07-18 亲验）

**调用战役终态**：全形态 0.98–1.16x（起点 1.24–1.81x）；function-call 0.982x / const 1.007x 已平，closure 1.156x / fib 1.146x 为带内残差。

**收官日测绘（症状面）**：for-of 1.778x ｜ array-push 1.582x ｜ object-literal-var 1.518x ｜ alloc-empty 1.182x ｜ property-read 系 0.995–1.093x（已平）｜ strconcat 0.570x（反超）。

## 1. 机制地图 — 症状到机制的归因矩阵

| 症状基准 | 压着它的机制（假设，待 A0 显影确认） |
|---|---|
| for-of 1.778x | M-ITER（迭代 result 协议）+ M-ALLOC（result 对象分配）+ M-FRAME（borrowed 帧构造） |
| array-push 1.582x | M-ARRAY（元素存储协议）+ M-ALLOC（增长再分配） |
| objlit 1.518x | M-SHAPE（shape 演化）+ M-ALLOC |
| alloc-empty 1.182x | M-ALLOC（分配器本体，07-08 曾平 0.96x，回归待归因） |
| closure/fib 残差 | M-FRAME（帧池链）+ M-CELL（捕获 cell 读链） |
| 全部 let 循环基准 | M-EMIT（发码降级层：TDZ 阻熔 4-op 展开、26 条 peephole 缺口） |

**第一步 A0（先于一切刀）**：对 for-of / array-push / objlit / alloc-empty 四个症状基准做 `perf record` 符号+指令级分解，把上表的「假设」变成「每机制 cyc 定量」。调用战役的教训：双侧归因（qjs 同段对照）一次做对，占用≠承载（先问热点的值喂谁）。

## 2. M-ALLOC + M-SHAPE：对象分配与 shape 演化机制

**服务面**：一切对象创建（字面量、构造、iterator result、arguments、正则 match……）与属性添加。是 for-of/objlit/alloc-empty 三个症状的共同底座——**修一处，三处同向**。

- **知识资产**：ALLOC-LAYER-DIVERGENCE-2026-07-06.md（30-agent 审计全文）+ IMPL-DIVERGENCE-STATUS-2026-07-11.md。已落地：GC-D2 页几何惰性、shape-D5、GC-D3、AL1。
- **主刀 M-SHAPE-1（最大已定位未做）**：shape rc==1 原地演化臂——qjs `add_property`（quickjs.c:9206-9236）三臂中 in-place 臂缺失，zjs 每属性添加走查找/克隆。pin 实验实证 churn 603 vs 52 insn/iter；`let` 体 kill-before-create 序使每 iter shape 建毁。机制刀：受益面=objlit + 一切热路径属性添加。
- **M-ALLOC-1**：alloc-empty 从 0.96x 回升 1.18x 的回归归因（差分 07-08 落地态与当前——嫌疑：调用战役的守卫/布局外溢，或 side-table 15% 残余重新暴露）。
- 判定：机制探针 objlit ≤ −20%，受益面 alloc-empty/for-of 同向，全形态扫描无真回退。

## 3. M-ITER：迭代协议机制

**服务面**：for-of、spread、解构、`yield*`、Array.from——所有消费迭代协议的语言面。
- **已知历史**：for-of result-obj-free 刀曾拿 3.7x（qjs-bottomup-audit 2026-06-26）；qjs 对 for-of 有专用 OP_for_of_next + result 免分配路径。
- **M-ITER-1**：zjs `op_for_of_next` 与 qjs 逐段对照——result {value,done} 的构造/解构是否仍付对象分配（若是，与 M-ALLOC 联动：qjs 的免分配协议是机制性对齐点，不是 for-of 特性补丁）。
- **M-ITER-2**：借用帧的 continuation 薄臂（R3 战报的 `.for_of_next` action 教训与 v3 跳过法资产在案）——属 M-FRAME 的延伸。
- 判定：机制探针 for-of ≤ −15%，受益面 spread/解构语料同向（无现成基准则新增，单独 commit）。

## 4. M-ARRAY：数组元素存储协议

**服务面**：push/pop/索引读写/迭代/length——所有数组操作共享 count/length/capacity/exotic 检查协议。
- **M-ARRAY-1**：以 array-push 为显影剂 record 归因，对照 qjs `js_array_push` 的 fast 路径（`u.array.count` 直写协议）。已落地资产：L3 count/length 拆分。嫌疑：per-push 的 exotic/shape 检查链与增长协议。
- 判定：机制探针 array-push ≤ −15%，受益面 array-pop/index-write 同向。

## 5. M-FRAME：帧构造协议（含对调用战役自身的机制性反思）

**债务承认**：调用战役的 leaf 家族是八个特化臂（zero-arg/method/strict/arrow/capture/exact-args/padded/forwarded），每臂一个 flag+一段构造+红灯组。性能达标（0.98–1.16x），但每新形态边际成本恒定（新臂+新 flag+新测试），`op_call` 家族 handler 从 ~630 膨胀到 ~1100 insn。**机制性问题没有被正面回答：qjs 用一条通用 sf 协议（alloca+7 字段）服务所有形态，为什么 zjs 需要八个臂才能逼近它？**

- **M-FRAME-1（spike，先证据后动手）**：「描述符驱动的单一构造器」可行性——发布期把帧几何（args 模式/this 模式/captures/teardown 形态）折成一个描述符字节，运行时一条数据驱动构造路读描述符展开。X925 因果律支持其可行（判定 load 并行+全预测=免费）；风险是失去直线码的调度自由。**先做删除测试**：把两个最相近的臂（如 strict/arrow——N3 已证机器码逐指令等价）合并为参数化实例，PMU 验证零回退，再评估全收敛。若 spike 证明臂collapse 无代价，leaf 家族从「八臂」收敛为「一构造器+描述符」，未来形态零边际成本。
- **M-FRAME-2**：帧池弹出指针追逐（fib 残差 6.18 cyc/call，qjs alloca≈0）——池 bump 指针的驻留形态。
- **M-FRAME-3**：N2 freight 9-store 簇（`pushExactSimpleFrame` 签名重构——本质是 InlineTarget 传参协议，属机制）。
- 判定：M-FRAME-1 以「合并后全形态扫描逐指令/PMU 双中性」为线；2/3 以 fib/closure 探针 + 全扫描。

## 6. M-EMIT：发码降级层机制

**服务面**：所有 JS 代码形态（不分调用/属性/循环）——普惠型，且是唯一能同时改善 zjs 绝对性能与对 qjs 相对差距的层（control 已反超 16% 证明 zjs 的 per-op 质量优势，发码缺口是把这个优势漏掉的地方）。
- **M-EMIT-1**：26 条 peephole 规则全集（IMPL-DIVERGENCE §4.9：dup+put→set、&&坍缩、is_null 折叠……）——批量小刀，每条独立 A/B，低风险。
- **M-EMIT-2**：TDZ 阻熔的 `inc_loc_check` 熔合——消 4-op 展开 + TOS 同址污染（inc_dec +2.20 cyc/iter）。⚠️qjs 无此 op：超集发码，需 TDZ 语义等价证明 + ZJS_DISASM 偏离标注，实施前单独裁决。
- 判定：发码探针（变化预期明确列出）+ 全形态扫描 + test262 全量。

## 7. M-CORRECT：正确性机制（并行，不占 PMU）

1. GC 记账不变式：`-Dzjs_force_gc` 挂 `HeapLiveBytesMismatch`（gc.zig:1662，预存已实证）——记账机制审计。
2. 递归深度护栏：尾调用平坦复用使 `rec(){return rec()}` 自旋（qjs 抛 InternalError）——深度计数或 interrupt 可达性机制。
3. parser：generator 函数表达式作默认参数值的局限。

## 8. 机制刀的判定协议（对形态刀协议的修正）

形态刀用单枢轴基准；**机制刀改用三件套**：
1. **机制直接探针**：针对机制构造的最敏感基准（现有或新增，新增单独 commit）；
2. **受益面多点同向**：该机制服务面上 ≥2 个其他基准 cyc 同向改善（幅度不设线，方向必须一致——机制刀的收益天然弥散）；
3. **全形态扫描零真回退**：调用战役 12 形态 + 本文症状面全扫（真回退=cyc>+1.0% 且 insn>+0.3%；幻影按律容忍）。
其余承袭战役协议：门禁五件套+altrepr、语义刀全量 test262 delta-zero、发码探针逐字节、红灯先行、qjs 对照先行（反超必查 qjs——Q1 前提证伪先例）、失败刀战报必含反汇编死因。

## 9. 执行顺序

```
A0 机制归因显影（四症状基准双侧分解，1 个测量包）  ← 一切刀的前置
第一批：M-SHAPE-1（最大已定位）+ M-ALLOC-1（回归归因）
第二批：M-ITER-1/2 + M-ARRAY-1（按 A0 显影的定量排序，可能并成一批）
第三批：M-FRAME-1 spike → 2/3 + M-EMIT-1 批量
并行：M-CORRECT 三件（不占 PMU）
等待：preserve-none CC（工具链）、M-EMIT-2（超集裁决）
```

每批一个 workflow（串行刀 + §8 判定），批间人工裁决。机制刀的预期不同于形态刀：单刀对单基准的百分比会小于形态刀（−5~20% 而非 −20~40%），但**受益面宽**——判定协议为此重造，勿用形态刀的枢轴思维错杀机制刀。

## 附：X925 执行铁律（34 刀 A/B 校准，全文见战役档案）

**因果律**——换得到 cyc 的只有：①forwarding 罚消除且载入喂关键链②喂间接跳转目标的取数链③检查链双计头+联动④bl 链塌缩（主体=callee-saved 往返+freight+出参）。删不到：纯判定 load（并行+全预测）、死端记账（占用≠承载，先问值喂谁）、非热臂展开。
**工程律**：热臂判别绝不共享（含源码模板层）；展开臂必须=热臂；新状态复用退役槽（Zig 加字段桶重排）；packed bitcast 有 alloca spill 硬伤；asm launder 防 16B copy idiom 重融合；align(64) 钉群防布局翻覆。
**测量律**：stall 座标≠关键路径；布局吸引子 tax ±1 固有；幻影判别（insn|Δ|<0.1% 的 cyc 超线=幻影）；agent 自报口径必亲验；负对照基准定期看绝对差距（「探针角色掩盖收割对象」——method/for-of 两例）。

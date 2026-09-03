> 注：原始二进制证据在临时 worktree，未入库。

# obj64④ 布局普查与 64B 目标提案

日期：2026-09-01
基点：`main@8aba23bd07c49aac1fd4f4e33d81da1a6d7283bf`
范围：S3 `HeaderV2 + obj64④` 最终物理切换片的设计输入；只读源码普查，零实现、零 commit、零性能裁决。

## 0. 结论先行

1. 当前 ReleaseFast Object 的 payload body 是 **40 / 56 / 72 B**（narrow / wide / narrow+slots2）；再加当前分配基址上的 8 B `Metadata` 前缀，物理 cell 请求是 **48 / 64 / 80 B**，恰好落在对应 class。
2. A1v2-r2 不是把 Object header 变成 0 B，而是把当前 `Metadata(8) + TraceHeader.next(8)` 两个物理字压成一个 immutable `HeaderV2(8)`。因此只做批准的 header 切换，slots2 从当前 raw 80 B 降到 raw 72 B，**仍向上落在 80 B class**。`Header.next` 消失只给出净 8 B，距离 64 B class 还差 **恰好 8 B**。
3. 推荐 obj64④ 采用 **方案 A：slots2 专属的 implicit `prop_values`**。slots2 layout 不再常驻存一个可由对象地址推导的属性基址；`HeaderV2 + scalar + shape_ref + payload arm + 2×Entry = 64 B`。尾槽外溢后，用已废弃尾区的首字存外部指针，并用独立可变 side/body bit 判别。这一方案保留 `shape_ref` 与普通 class payload 的本体位置，未把最热 shape 访问搬进 side table。
4. 方案 B（slots2 的 class payload 指针稀疏侧置）只在 fresh census 证明 `slots2 && payload != null` 极稀少且生命周期适配器闭合时保留为备选。方案 C（shape 侧置或压缩）不建议进入 S3：单独压成 32 bit 只到 68 B、仍是 80 class；完全侧置虽可到 64 B，却把最热指针访问变成 side lookup，且侧存 8 B 后总占用并未真正少 8 B。
5. 历史 `20.18M -> 12.14M (-40%)` marking-line 与 `L1D refill -9.2%` 只能保留为方向性假设，不能作为 S3 gate。S1 已替换 frontier 拓扑；按 O5 必须在真实 post-slice2 `H_PRE` 上重建结构计数、硬件计数和阈值，再冻结 `H_S3/H_PRE` 与 `H_S3/H_S2` 两套比较。

## 1. 普查口径与证据

- Shipping 口径是 ReleaseFast/ReleaseSmall。`property.Entry` 的 release 大小是 16 B；Debug/ReleaseSafe 的 tagged union 会使两个尾槽合计 48 B，不参与 64 B production 目标。
- 当前 layout 由源码 comptime 断言与 `src/gc-representation-trace-snapshot.txt` 双重钉住：Object head 32 B、narrow/wide arm 8/24 B、两个尾槽 32 B。
- 所有 offset 以下均以 Object 指针为 0；“raw offset”另显式包括当前 Object 前面的 8 B `Metadata`。
- `src/core/object.zig` 顶部仍有把 Object 称为 “64-byte extern struct” 的旧叙述；当前 `@sizeOf(Object)==32` comptime 断言和 representation snapshot 才是权威，不采用旧注释定价。

### 1.1 当前固定头（Object-relative）

| offset | size | 字段 | 状态/用途 |
|---:|---:|---|---|
| 0 | 8 | `header: GCObjectHeader` | 当前实际为 `TraceHeader { next }`；可变 intrusive successor |
| 8 | 4 | `weakref_count` | 低 31 bit 为 weakref count；高 bit 记录“本 allocation 带 slots2 尾区” |
| 12 | 2 | `class_id` | immutable；也是 arm 宽度的 sizing authority |
| 14 | 2 | `flags` | 包含 class payload kind、fast-array 等对象状态 |
| 16 | 8 | `shape_ref` | 指向 Shape；属性个数/flags 的 authority |
| 24 | 8 | `prop_values` | 空 sentinel、尾区基址或外部 Entry 数组基址 |
| **32** | — | fixed head 结束 | `@sizeOf(Object)==32`, align 8 |

`weakref_count + class_id + flags` 恰好占满一个 8 B scalar word，无现成 alignment hole。payload kind 已在 2 B flags 中编码，也没有额外 8 B discriminator 可直接删除。

### 1.2 class-data arm

arm 基址固定为 Object+32，宽度只由 immutable `class_id` 决定。

| arm | offset | 实际 size | body size | class 集合/说明 |
|---|---:|---:|---:|---|
| narrow payload | 32 | 8 | **40** | 其余 class；一个 `class.Payload` 指针 |
| dense array | 32 | 24 | **56** | values ptr 8 + count/capacity/length/pad 各 4 |
| bytecode function | 32 | 24 | **56** | FB / var_refs / home-or-aux 三个指针 |
| regexp | 32 | 16，有意按 24 分级 | **56** | source / compiled 两指针；尾 8 B 是 wide-class padding |
| 其他 wide | 32 | 24 | **56** | arguments、mapped arguments、string、generator/async callable 等 |

wide class 的完整集合由 `unionArmBytes(class_id)` 明列：array、arguments、mapped_arguments、string、regexp、bytecode_function、generator_function、async_function、async_generator_function；其余 class 都只有 8 B narrow arm。

### 1.3 slots2 尾区

只有 `class.ids.object` 的 compiler-proven Reserved2 form 可带该尾区：

| offset | size | 内容 |
|---:|---:|---|
| 0..32 | 32 | fixed head |
| 32..40 | 8 | narrow class payload arm |
| 40..56 | 16 | `property.Entry[0]` |
| 56..72 | 16 | `property.Entry[1]` |
| **总计** | **72** | Object body + FAM |

源码断言为 `trailing_property_bytes == 32` 及 `objectBodyBytes(ids.object) + trailing_property_bytes == 72`。当属性增长到外部 buffer 时，当前 `prop_values` 改指外部数组，但原 32 B 尾区仍属于同一 allocation；高位 allocation bit 保证 free 仍传回正确大小。

### 1.4 从 raw allocation base 看 v1

| form | raw 0..8 | Object/arm/tail | raw bytes | 16 B class |
|---|---|---:|---:|---:|
| narrow | `Metadata` | `TraceHeader 8 + scalar 8 + shape 8 + prop ptr 8 + arm 8` | **48** | **48** |
| wide | `Metadata` | `TraceHeader 8 + scalar 8 + shape 8 + prop ptr 8 + arm 24` | **64** | **64** |
| slots2 | `Metadata` | narrow 40 + `Entry[2]` 32 | **80** | **80** |

raw offset 展开后：Metadata 0、TraceHeader 8、weak/class/flags 16、shape 24、prop 32、arm 40；slots2 entries 从 raw 48 开始到 raw 80。这里解释了为什么只看 72 B body 会误判当前 class：allocator/cell 还必须容纳 8 B prefix。

### 1.5 class 几何价格

按当前 64 KiB `Block`、112 B header、三张 bitmap 和 64 B 对齐的 `cells_offset` 公式：

| cell class | cells/block | bitmap words/plane | cells offset | block 尾 slack |
|---:|---:|---:|---:|---:|
| 48 B | 1,352 | 22 | 640 | 0 |
| 64 B | 1,016 | 16 | 512 | 0 |
| 80 B | 813 | 13 | 448 | 48 |

slots2 从 80 降到 64 后每 block 多 **203 cells，+24.97%**；且 64 B class 每个 cell 都 cache-line aligned，而 80 B stride 会在 64 B line grid 上轮换相位。这是 obj64④ 的结构 entitlement，不等同于实际 L1D refill entitlement。

## 2. A1v2 后还差哪 8 B

批准的 `HeaderV2` 是 8 B immutable word：`type_tag:u8 + size_class:u8 + static_flags:u8 + trace_class:u8 + layout_extra:u32`。mark、publication、young、remembered、generation、sweep、finalization、queue 等动态状态全部侧置；`layout_extra` 只能存 immutable layout facts。

物理算术是：

```text
v1 slots2 raw = Metadata 8 + TraceHeader.next 8 + scalar 8
                  + shape 8 + prop ptr 8 + payload arm 8 + entries 32 = 80

v2 header-only = HeaderV2 8 + scalar 8
                  + shape 8 + prop ptr 8 + payload arm 8 + entries 32 = 72
                  -> roundUp(class step 16) = 80
```

所以：

- slice2 最终清掉 `Header.next` 的所有 borrower 是切换前置，但不是 obj64 的全部设计。
- v2 并非“删 8 B header”；它删的是当前 16 B header/prefix 组合中的一个字，留下新的 8 B header。
- 72 -> 64 的剩余缺口没有 padding 可吃，必须从四个 8 B 实体之一（shape、prop base、payload arm，或把两项各压 4 B）移走/消除。
- `layout_extra` 不能塞 `shape_ref`、外部 prop pointer 或 mutable spill bit；这些会破坏 r2 immutability contract。

## 3. 64 B 备选布局

### 3.1 方案 A（推荐）：slots2 implicit prop base，spill pointer 复用尾区

slots2 专属 layout：

| offset | size | 字段 |
|---:|---:|---|
| 0 | 8 | immutable `HeaderV2`（含 immutable `slots2_layout`） |
| 8 | 8 | weakref count / class id / flags scalar word |
| 16 | 8 | `shape_ref` |
| 24 | 8 | narrow class payload arm |
| 32 | 16 | inline `Entry[0]` |
| 48 | 16 | inline `Entry[1]` |
| **总计** | **64** | **落 64 B class** |

关键合同：

- inline 状态的 prop base 恒为 `object + 32`，不存指针。
- spill 到外部时，先移动/销毁尾区 entry，再把外部 `[*]Entry` 写入已废弃尾区 32..40；其余尾区保持 allocation 内部 padding。一个独立的可变 `tail_external` bit 决定“推导 base”还是“从 +32 load base”。
- immutable “这个 cell 是 slots2 layout” 放 `HeaderV2.static_flags/layout_extra`；mutable “当前是否已 spill” 必须留在 body/side state。可考虑在 v2 中复用当前 `weakref_count` 高 bit：当前高 bit 的 immutable allocation-layout职责已经移入 HeaderV2，低 31 bit weak count 不变。具体 bit assignment 仍需专门审计/断言，不能凭本报告直接实施。
- non-slots2 保持常驻 `prop_values` 和现有 40/56 B body：narrow raw 40 -> class 48，wide raw 56 -> class 64。
- 所有属性 reader/writer/free/trace 必须走 layout-aware accessor，不能再直接假定 `self.prop_values` 字段存在。当前只读 lexical census 为 `.prop_values` 28 处；这是改造面上界线索，不是语义 call count。

优点：正好消掉 8 B；保留最热 `shape_ref`；保留 rare class payload 与两个 entry 同时存在的能力；inline 热路从一次 pointer load 变为常量地址推导。主要风险是 variant field offset、spill/OOM rollback 与 destruction 的双表示审计。

### 3.2 方案 B（有条件备选）：slots2 payload pointer 稀疏侧置

| offset | size | 字段 |
|---:|---:|---|
| 0 | 8 | `HeaderV2` |
| 8 | 8 | scalar word |
| 16 | 8 | `shape_ref` |
| 24 | 8 | `prop_values` |
| 32 | 32 | inline `Entry[2]` |
| **总计** | **64** | **落 64 B class** |

仅对 slots2 取消 narrow payload arm；当 `class_payload_kind != none`/payload 非空时，把 owning pointer 放稀疏 side record。普通/wide layout 不动。

进入实现前必须取得 fresh census：`slots2_total`、`slots2_payload_nonnull`、各 payload kind、构造失败/附着/替换/销毁次数。若目标负载为零命中，也仍需 targeted fixture 证明 nonzero path。side record 必须在 attach 前 reserve，覆盖 constructing、published、doomed、finalizer_current、weak husk、rollback 与 raw free，并保证 payload 恰好释放一次。

优点是保留 property hot path 与当前 `prop_values` 表示。缺点是 payload API/lifetime 面大：当前 lexical census 约 `payloadArm(` 113 处，而且 API 返回可写 lvalue pointer；简单 wrapper 不能自动保留语义。因此本方案只有在 side population 极低且生命周期 adapter 已在 v1 下闭合时才可与 A 竞争。

### 3.3 方案 C（不推荐）：slots2 shape side authority / 双 32-bit handle

完全把 `shape_ref` 搬到 block/extent side state 时：

```text
HeaderV2 8 + scalar 8 + prop ptr 8 + payload arm 8 + entries 32 = 64
```

表面落 64 class，但每对象新增 8 B side pointer 后总体 storage 未减少，且 property lookup、shape transition、trace 都在最热路径付 side lookup。当前 lexical census 约 `.shape_ref` 291 处；历史 mark census 又显示 shape 是逐 Object 访问的核心成分。这不符合“移动到 side 不等于免费”的 r2 定价原则。

只把 shape pointer 压成 32-bit，72 -> 68，仍落 80 class；只压 `prop_values` 亦然。要靠压缩进入 64 必须再省 4 B（例如 shape 与 prop 都变 32-bit handle），引入 4 GiB cage/稳定 handle table、两条热 lookup 和新的 generation/reuse 合同，显著超出 S3 物理切换片。故 C 在没有独立 side/cage 价格与 owner 新裁决前为 NO-GO。

### 3.4 其他不闭合的刀

- **slots1**：v2 下约 56 B、可落 64，但不能替代 slots2。历史 splay 普通对象的 two-slot eligibility/命中接近全量；改成 slots1 会让第二属性普遍 spill，必须用 post-anchor census 重证，不能作为主案。
- **仅压 class id/flags/payload discriminator**：scalar word 已由 u32+u16+u16 填满；即使挤出 4 B，alignment 后仍是 68/80。payload discriminator 本身已在 flags 内，不存在可独删的 8 B 字段。
- **把动态状态塞入 HeaderV2**：违反 O1 immutability；不列为备选。
- **缩 `JSValue` / `property.Entry`**：这是值 ABI/属性表示的独立系统切换，不是 obj64④。

### 3.5 推荐排序与进入条件

1. **A 首选**：先在 v1 layout 下把 property storage 读写收口为 accessor，并用表示双检证明 direct field 假设归零；然后才进入 O4 最终 switch。
2. **B 备选**：只有 `slots2_payload_nonnull / slots2_total` fresh census 极低、side lifecycle 已有 exact-once 证明，且 A 的 accessor/性能定价失败时采用。
3. **C 拒绝**：除非另立 shape/handle 设计与 owner 裁决。

任何方案的 S3 switch 前均须满足：`Header.next` borrower 为零；allocation/free/accounting/candidate bounds 共用一个 immutable layout descriptor；无 by-value Object；v1/v2 binary 不混合 layout；config signature 与 representation snapshot 逐行对账。

## 4. S1 后判别器重锚

### 4.1 为什么旧绝对端点失效

历史账中的 `20.18M -> 12.14M (-40%)` 与 `L1D refill -9.2%` 来自旧 source/workload/frontier/counter 组合。S1 已用 4096 B、509×8 B entry 的可增长分段 frontier 替换固定队列/overflow 全堆重扫；遍历调度、segment transfer、rescan 行为和每轮 major population 均改变。当前 `--gc-mark-footprint` 又是在 final remark 内做 whole-heap structural walk，计的是最终 marked set 的模型触碰，不等价于硬件 L1D refill 或旧 traversal 次数。

因此旧绝对数只能写入“方向性假设/历史上下文”，不得成为 hard gate、不得直接从旧 20.18M 推候选 12.14M，也不得把 whole-heap footprint 行数当作硬件 miss。

### 4.2 锚点与身份

按 O5 登记：

```text
H_S2   driver 接受的 post-S1/S2 系统锚点
H_PRE  slice1..7 语义迁移全部完成、仍为 v1 physical layout 的最后 commit
H_S3   HeaderV2 + obj64④ comptime 物理切换候选
```

同时冻结 production signature/layout、compiler、二进制路径与 SHA-256、fixed-work SHA/stdout/completed-work、frontier option/segment geometry、预期 representation diff。任何身份变化都使注册作废。

需要两套裁决：`H_S3/H_PRE` 隔离物理表示的增量价值；`H_S3/H_S2` 给出整个 S3 tranche 的组合价值。两套不得互相遮盖 staging cost。

### 4.3 H_PRE 必测结构计数

单独构建 census binary，避免 whole-heap walker 污染 timing binary；至少记录：

- 每个完成 major 的 marked headers、Object 数、by-kind/by-trace-class；只比较 stdout/work/major parity 的 legs。
- Object publication/marked 按 physical layout 与 class 分桶：48/64/80、narrow/wide/slots2；`slots2_direct_inline`、`slots2_tail_grown`、plain external。
- `slots2_payload_nonnull` 及 payload kind、weakref_count 非零、spill 次数、block/extent carrier。
- base/shape/property/dense/payload/backing 的 structural touched lines/bytes；明确重叠规则，避免再次把 inline property line 与 base line重复认领。
- frontier pushed/popped/donated/stolen、segment alloc/peak/cache/failure；S1 后应没有 overflow/rescan 项。对 completed major、marked Object、marked slots2 分别归一。
- allocation/publication 的 class histogram、block cell geometry、committed/live、maxrss、minflt。

在 H_PRE census 上做候选 counterfactual：对每个 qualifying slots2，用 **80 -> 64 的真实 class/stride/line phase** 重算 base demand-line 模型；不是简单从对象数乘一个固定比例。冻结：

```text
qualifying_slots2_count
predicted_H_S3_class64_count == qualifying_slots2_count
predicted_slots2_structural_ratio = candidate_model_lines / H_PRE_model_lines
```

候选实测还必须证明 slots2 不再发布到 80 class，narrow/wide 仍落 48/64，spill 后 allocation class 不变。

### 4.4 硬件与性能重注册

- 在同一 quiet-host measurement contract 下做 balanced paired ABBA、同核、偶数 samples；至少四 legs/arm，保留全部 raw records。
- 同一 `perf stat` 采 cycles `(u+k)`、instructions 与主机可用的 `L1D_CACHE_REFILL`（建议再带 L2D refill）；另采 `/usr/bin/time` 的 maxrss/minflt。
- 若已有可信 GC phase markers，优先冻结 marker-phase L1D；否则只能以 total L1D 配合 work/major/structural parity 判别，不能把 total delta 全部归因给 Object marking。
- driver 在看到 H_PRE repeat variance 与 counterfactual、但在 timing H_S3 前冻结：六负载 cycles geomean、splay cycles、EB/其余 instructions、committed/live、minflt、结构线 ratio 与 L1D ratio。本文不抢先发明数值门槛。
- 旧 `-40%/-9.2%` 只作为方向 sanity check；新 hard line 应是“相对 fresh H_PRE 的预测值 + 由重复噪声冻结的容差”。未命中结构判别器即使 cycles 偶然绿也不算机制兑现。

## 5. ABI、生命周期与候选边界风险

### 5.1 BigInt / Shape / Realm 同切片交互

- **BigInt**：O1 明确它没有 `HeaderV2`。JSValue payload 仍指 `BigIntBody`；payload-4 的 i32 RC 由 8 B physical prefix 高四字节提供，body 目标 40 B，FAM 从 body+40 开始。obj64 Object accessor/layout 不能把 BigInt cast 成 HeaderV2，也不能改变 `raw_base/raw_bytes` 与 `base` 的 8 B 差。
- **Shape**：保留 HeaderV2@0、`ShapeOwnership.trace_ref_count` 的 pinned body offset；list-backlink slot 即使 side topology 已接管也先保留为零，不在这次 cut 回收。Shape size/FAM/proto offset 不因 obj64 改变。方案 A/C 的 Object `shape_ref` 仍必须是强边，count 与 traced root/edge 合同不变。
- **Realm**：保留 HeaderV2@0、tail i32 count 与 list-backlink 保留字节，`JSContext` size/alignment/各 public/core offset 不动。obj64 不得顺手复用 Realm 尾洞。
- 三者的步骤 4/5 carrier adapter、raw ledger、generation/state 是 obj64 switch 前置；不能以 Object 64 B 目标扩大为 ABI 清理。representation snapshot 必须为每一行 diff 给 rationale。

### 5.2 layout/sizing authority

variant slots2 后，当前只依赖 `class_id` 的 `objectBodyBytes(class_id)` 不再足以表达完整 physical layout。必须引入 immutable layout descriptor（HeaderV2 layout fact + class）并让 allocation、free、accounting、candidate logical bounds、trace/destroy 读取同一个 authority；不能从可变 `fast_array`、当前 prop pointer 或 spill 状态反推 allocation size。

方案 A 的 slots2 inline/external 是“同一 64 B allocation 内的可变内容状态”，不是两个 size class；rollback/OOM 不能留下同时拥有尾 entries 与 external pointer 的双 ownership。方案 B/C 的 side record 同样必须先 reserve、后 publish，teardown 恰好一次。

### 5.3 conservative 64 B 边界

64 B class 让每个 cell base 落在 cache-line 边界，也使 `A.one_past == B.base` 成为规则而不是偶然。`forEachTraceCandidateAt(p)` 必须探测 `p` 与 `p-1`、枚举所有 hits，并在相邻已发布 cells 上同时返回 A 与 B；按 `(base,generation)` 去重，而不是 pointer-only。

必须新增/保留的明确 fixture：

1. 同一 64 B block 内两个相邻、均 published 的 slots2 cells，`p=A+64=B` 返回恰好 A、B；换 allocation 顺序与访问顺序重复。
2. A/B 任一 free、constructing、doomed/finalizing 时只返回仍为 published 的 tracing candidate；cell reuse 后旧 generation 不命中。
3. interior、exact base、last-cell one-past、page/block 边界 one-past、跨 page 的相邻 extent；`addr==0` 不下溢。
4. incomplete page/radix index 走完整 authority rebuild/full scan，不得降级成单 winner 或 precise-only；BigInt/String/Rope 可诊断但绝不作为 trace root。
5. carrier kind/class/state/bounds 验证必须发生在 HeaderV2 dereference 之前；block descriptor 固定为 Object subspace，其他五个 tracing kind 仍 extent-only。

需由 owner 明确一个细节：extent 合同使用 `[base, base+payload_bytes+1)`；当前 block interior resolver更接近覆盖整 cell（包括 class slack）。S3 应钉死 block candidate 的“logical payload range”还是“whole-cell conservative range”，并让 oracle/expected hit count采用同一口径。whole-cell false retention 可以保守安全，但不能把测试期望写成另一种语义。

此外，80 -> 64 会令 block geometry 从 813 cells/13 bitmap words/cells_off 448 变为 1016/16/512；cell index、alloc/mark/remember/doomed bitmap、side state arrays、reuse generation、last-cell slack与 block/page mapping 都必须按新 geometry 复测，不能只改 allocator class 常量。

## 6. 建议给 S3 的 go/no-go 边界

**设计 GO：方案 A 进入字段级 prototype/预注册。** 这不是默认切换授权。先完成：

1. post-slice2 `H_PRE` census 与阈值冻结；
2. property storage accessor 收口及 v1 representation dual-check；
3. slots2 inline/spill/OOM/destroy/weakref/class-payload coexistence targeted tests；
4. `Header.next` borrower=0、layout sizing authority 单一化；
5. 64 B adjacency/generation/all-hit conservative fixtures；
6. dual v1/v2 complete binaries、signature/snapshot 与 O5 两套 quiet comparison。

任一项失败即停，不以 B/C 临时补洞。方案 B 只在 census 与 exact-once lifecycle 证据充分后作为 owner review 的第二选项；方案 C 和两个 32-bit hot handles 不进入当前 S3 scope。

## 7. 当前源码证据索引

- `src/core/object.zig:375-415, 417-464, 466-545`：arm 定义、wide 集合、Object offsets/sizes、slots2 32 B 与 72 B 断言。
- `src/core/object.zig:594-651, 1174-1230, 3156-3179, 11301-11358`：arm accessor、Reserved2 构造、尾 allocation/inline 判别与 property storage reader。
- `src/core/gc.zig:1074-1112, 1149-1184`：当前 8 B `TraceHeader.next`、8 B Metadata 与 body RC 分流。
- `src/core/gc_space.zig:19-24, 124-153`：当前 8 B prefix 与 16 B linear size-class 规则。
- `src/core/gc_block_heap.zig:20-25, 73-77, 191-230, 550-589`：64 KiB block、cell alignment、Block/三 bitmap geometry。
- `src/gc-representation-trace-snapshot.txt:5-42`：当前 prefix/kind/body ABI snapshot。
- `src/core/bigint.zig:40-80`、`src/core/shape.zig:132-190`、`src/core/context.zig:370-389`：当前 BigInt/Shape/Realm pins。
- `docs/tracing-gc-header-v2-design.md:55-72, 87-107, 172-208, 421-520, 692-803`：APPROVED r2 header、candidate、per-kind ABI、O5 anchors 与 O4 staged switch。
- `docs/splay-account-2026-08-28.md` 的 marking/inline-slot 账：历史方向证据及 instrumentation 重复计数教训，不作当前 gate。

## 8. 工作区状态

本报告只新增 ignored `.scratch/OBJ64_CENSUS.md`；没有修改 production、tests、docs policy 或 tracked 文件，没有构建、跑 gate、commit 或 merge。符合本 lane “零实现只读 main”的边界。

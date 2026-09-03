> 注：原始二进制证据在临时 worktree，未入库。

# gc/blackalloc-20260831 implementer report

## 结论

**KILLED — 不合并。**

预注册线第 6 条已经硬失败：splay fixed-work 的 block committed 峰值从
262,144,000 B 增到 274,726,912 B，**+4.800%**，超过上限 +3%。此外，第
4 条要求的六负载 PMU 账无法闭合：candidate 在 earley-boyer 的
`perf stat` 运行中稳定得到 SIGSEGV。即使 splay 指令数、调用削减、队列
溢出与 correctness gates 都通过，也不能据此放宽验收线。

本 lane 基于 `main@7c067f01`，分支 `gc/blackalloc-20260831`。改动保持未提交，
未 push、未合入 main，留给 driver 只读审查或丢弃。

## 设计落点

### 1. block black epoch 与空块激活

- `src/core/gc_block_heap.zig:635, 672-687`：`Heap.black_alloc_epoch` 以奇数表示
  当前增量 major 活跃，以偶数表示无 black-allocation 周期；结束只推进 epoch，
  不遍历清戳。
- `src/core/gc_block_heap.zig:243-249, 358`：复用生命周期互斥的
  `Block.free_time_ns`。空闲块用它保存 page-return 时间；从全空状态激活后的
  非空块用它保存当前奇数 epoch。`Block` 仍为 112 B，没有扩大 block header。
- `src/core/gc_block_heap.zig:697-706, 762, 1886`：只有
  `allocated_count == 0` 的激活路径会写当前 epoch；新建/empty-list 两条入口都走
  `activateEmptyBlock`。
- `src/core/gc_block_heap.zig:1927`：populated hot-reuse 重开前把该 word 清零，
  因而混有老 cell 的 block 永不获得当期豁免。
- `src/core/gc_trace_stw.zig:1076, 1149-1155`：根种子完成、正式开放 marking
  时开始 black allocation；finish 用 defer 在 condemnation、remark、sweep 的所有
  退出路径之后自然结束 epoch。`src/core/gc.zig:3884` 的 abort 路径也关闭活跃 epoch。

### 2. publication 与整块 condemnation 豁免

- `src/core/gc.zig:2681-2685, 4552-4615`：Object publication 返回本 cell 是否处于
  当前 black block。活跃 marking 下命中者跳过 per-object mark bitmap RMW 与
  `publishGreyCold` 入队；普通 object 保留原 published-grey 行为。
- `src/core/gc.zig:4623-4632`：published-grey 明确只用于 Object；其它 kind 没有
  construction-time 容器边，不再产生无意义 publication queue call。
- `src/core/runtime.zig:1852-1853` 与 `src/core/object.zig:7434`：black Object 发布后
  同步重放其已经安装的初始强边，使用 Object 的 canonical trace-child visitor，
  避免“对象整块活、孩子仍白”的 construction hole。
- `src/core/gc_block_heap.zig:1109-1140`：`snapshotAllDoomed` 遇到当前 epoch block
  直接整块跳过，不计算 `alloc & ~mark`；同时记录 activated/exempted block/cell。
  `ZJS_GC_BLACKALLOC_INJECT=1` 删除该跳过，随后专属 guard 必须 panic。

### 3. barriers 与统计

- `src/core/gc.zig:3978-4059`：当前 black block 中已经发布的 target 等价于 marked
  target；其初始边已经由 publication replay 处理。black Object 新采用的 RC Shape
  不能进共享队列，故精确 mark Shape 并同步 shade 它的 prototype。
- `src/core/gc.zig:4132-4152`：bulk write 在 marking 臂重入队 owner；
  `src/core/gc.zig:4353-4363` 仍是 exact-target marking barrier。
- `src/core/object.zig:4671-4707, 9538-9722`：dense buffer adoption、append、literal
  memcpy 等逻辑批量安装都补上 owner requeue；调用点相应传入 runtime。
- `src/core/object.zig:8935-8962, 10009-10072, 11496-11510`：补齐三个绕过 typed
  Slot funnel 的 direct replacement exact barrier：JSON duplicate property、普通
  `setProperty` data replacement、known-shape data replacement。
- `src/core/gc_block_heap.zig:101, 138-140`、`src/core/gc_concurrent.zig:42-46`、
  `src/cli/zjs.zig:901, 980, 1036`：加入 committed peak、black block/cell、
  publication skip 与 queue-overflow 面板计数。

## 正确性论证

### 基本不变量

当前 epoch 的 black block 只保证其中已发布对象本身在这次 major 中存活；它不允许
tracer 假设对象孩子已经自动存活。因此孩子必须由下列三条完整覆盖：

1. 单值强引用写入仍走 `generationalBarrierSlow` 的 marking arm
   (`src/core/gc.zig:4353-4363`)。marking 期间 barrier gate 关闭，`O.f = W`
   精确 shade `W`，不要求 `O` 已有 mark bit，也不依赖以后展开 `O`。
2. 无法在写点给出单个 target 的 bulk write 走 `rememberOwnerForBulkWrite`
   (`src/core/gc.zig:4132-4152`)；marking arm 重入队 owner，remark 展开它刚安装的
   全部强边。队列溢出仍使用既有“finish 重扫 marked objects”正确性降级。
3. publication 之前已经存在于新 Object 内的 construction edges 不可能靠写屏障
   处理，因为 owner 尚未发布。`registerObjectWithBytes` 得到 black 命中后同步调用
   `shadeBlackAllocationConstructionEdges`，复用 canonical Object tracer，对 data、
   accessor、var-ref、dense elements、collection payload、prototype 等强边执行同一
   target shading 语义；weak edge 保持 weak，finalization held value 保持原 predicate。

最后，finish 在 condemnation 之前重新 `seedRoots()`，并在 engine-active 模式执行
保守根扫描，然后 drain barrier queue 与 ephemeron fixed point
(`src/core/gc_trace_stw.zig:1145-1173`)。因此栈上未装入 heap owner 的孤儿仍由精确根
与 native-stack 保守根兜底。black epoch 在整个 finish condemnation 阶段保持奇数，
只有 finish defer 才使旧戳自然失效。

### `gc_write_audit.zig` 四类 Slot-API 旁路审计

1. **FAM/slice**：property append 在 store 后、shape commit 前调用
   `barrierPropertySlot`；dense point stores 均在写入后调用 exact
   `generationalBarrier`。construction-time FAM stores 则由发布后的 canonical
   construction-edge replay 覆盖。没有 target 的 dense bulk choke point 使用
   owner requeue。
2. **`@memcpy` bulk**：property/collection/generator storage growth 中仅搬迁同一
   owner 已存在的逻辑边，不创造新 reachability，原边在 copy 前已经受 barrier 或
   trace 约束；新对象 construction templates 由 publication replay 覆盖。把外部
   dense values 逻辑安装进已发布 owner 的 adoption/append/literal 路径则显式调用
   `rememberOwnerForBulkWrite`，不把它误归为无语义变化的 relocation。
3. **union arm**：`property.Slot` 的 `.data/.accessor/.var_ref` 分支经
   `barrierPropertySlot` 分别精确 shade data、getter/setter 与 VarRef；primitive-only
   direct stores 无 GC header；`.auto_init` 的 Realm identity 由该 slot 自身的
   retain/release contract 持有，故现有 funnel 不走 generational barrier，而 black
   Object 的 construction replay 仍按 canonical tracer 访问这条 Realm edge。审计中
   发现的三个 direct data replacement 缺口已经补 exact barrier（见上述行号）。
4. **shape slot**：kind + union slot 同步变更由 `setEntryKindAndSlot` funnel 完成，
   slot store 后立即调用 `barrierPropertySlot`，再提交 shape flags
   (`src/core/object.zig:11590-11607`)；另外 shape transition 自身仍走独立的 Shape
   barrier。这样 slot child 与 Shape/prototype 两条边不会相互替代或漏掉。

### 针对性测试与注入

- `src/tests/core.zig:9329`：证明只有当前 epoch、从全空状态激活的 block 得到豁免，
  populated hot reuse 不打戳，结束 epoch 后旧戳失效。
- `src/tests/core.zig:17063`：在增量 marking 中分配 black Object，把一个没有其它
  owning path 的老对象作为其唯一孩子，跨 `finishIncrementalCycle` 验证孩子仍存活。
- `.scratch/blackalloc-injection-final-full.txt`：
  `ZJS_GC_BLACKALLOC_INJECT=1 zig build test` 在
  `src/core/gc_block_heap.zig:1139` 以 SIGABRT 命中准确消息
  `GC black-allocation invariant violated: current-epoch block reached condemnation`。
  这是故意失败的 deletion-mutant 运行，命中的不是其它 GC guard。

## 预注册验收逐条对账

### 1. `zig build test` — PASS

最终 current-source 运行记录：`.scratch/zig-build-test-final-current.txt`。

```text
Summary: 2492 passed; 6 skipped; 0 failed; 0 filtered.
Build Summary: 9/9 steps succeeded
```

工作树最初的 `test262/` 是空 submodule，第一次构建在 runner fixture 读取处得到
FileNotFound。随后以 `git submodule update --init test262` 填充到与主 checkout 相同的
pinned commit `4249661388e5d3f92a85186213da140a6481490f`，最终全测通过。未运行
test262 suite；这里只是满足统一测试构建输入。

最终 `zig build check` 通过；`git diff --check` 通过。

### 2. 压力测试 + 注入验证 — PASS

压力测试包含在上述 2492 个 pass 内，并在 timing summary 中实际列出。注入以完整
`zig build test` 形态准确触发本 lane guard，证据如上一节。

### 3. splay `publishGreyCold` 调用下降至少 90% — PASS

fixed-work SHA256：
`e9a794cab2e318f7ff4509d079f7172b819e4689c2399188c9e54559e8f36fe7`。

- baseline calls: 1,822,344
- candidate calls: 16,786
- reduction: **99.078879%**
- candidate black-allocation skips: 1,368,388
- candidate activated/exempted blocks: 1,554 / 1,554

原始账：`.scratch/baseline-splay-gc-stats.txt`、
`.scratch/candidate-splay-gc-stats-final.txt`。

### 4. 六负载 PMU 指令数 — FAIL

测量使用 `armv8_pmuv3_1/instructions`、固定 CPU 19、每引擎每负载 2 样本、ABBA，
ratio 定义为 candidate / baseline。二进制：

- baseline `.scratch/zjs-baseline-7c067f01`, SHA256
  `386b9f84a297dad4c6baa52ae53f058cb112addbf451e74eab7ca3f55893e806`
- candidate `.scratch/zjs-candidate-blackalloc`, SHA256
  `867c281250a7f6c425e8a48f22945d7999f8f2ee94f8a0cc8749b639b0884ccb`

已闭合的 instruction ratios：

| workload | candidate / baseline | 预注册边界 | 局部结果 |
|---|---:|---:|---|
| splay | 0.928417984 | <= 1.000 | PASS |
| deltablue | 0.999687435 | <= 1.003 | PASS |
| regexp | 1.000141440 | <= 1.003 | PASS |
| pdfjs | 0.998031659 | <= 1.003 | PASS |
| raytrace | 1.002689788 | <= 1.003 | PASS |
| earley-boyer | 无有效 ratio | <= 1.003 | **FAIL** |

earley-boyer 的两次 `perf-screen` 尝试都在 baseline 首腿之后失去 candidate score。
直接用同一 candidate + fixed-work 在 `perf stat` 下复现为 SIGSEGV；
`.scratch/eb-perf-manual-output.txt` 为：

```text
.scratch/zjs-candidate-blackalloc: Segmentation fault
```

perf CSV 在崩溃前累计了 173,190,716,581 条 instructions，证明不是命令行/解析器
启动失败。相同 candidate 脱离 perf 的一次直接运行能以 `EarleyBoyer:4080`、exit 0
结束，因此目前只可归类为 timing-sensitive ReleaseFast crash，机制尚未归因；不得
用那一次成功运行填补 PMU gate。原始 PMU 账：
`.scratch/blackalloc-fixed-pmu-splay.json`、
`.scratch/blackalloc-fixed-pmu-four.json`。

按 brief，本报告不使用 wall-clock、cycles 或 RSS 作验收证据。

### 5. mark-queue overflow 不升 — PASS

- splay: baseline 8, candidate 0
- earley-boyer direct stats: baseline 0, candidate 0

### 6. splay / EB block committed 峰值涨幅不超过 3% — FAIL

#### splay — 硬失败

baseline stats-only binary SHA256：
`3136b174f537ff95335707895d7f79ff6f1a74268b7778787380df7b561447bc`。
baseline 没有 peak 字段，但此 workload 的 decommitted/recommitted 都为 0，故最终
committed 262,144,000 B 就是精确峰值。candidate 面板直接记录 peak
274,726,912 B：

```text
(274,726,912 / 262,144,000) - 1 = +4.800%
```

超过 +3% 的预注册硬线，故整刀 KILLED。

伴随拓扑（用于归因，不改变判定）：candidate 的 live bytes 反而从 184,271,920
降到 156,728,208，但 partially-full blocks 从 618 增到 1,129，superblocks 从 125
增到 131。这支持“整块豁免扩大分散在 partial blocks 中的 floating garbage / 碎片”
这一机制解释，而不是把增长归给更多 live payload；仍需更窄实验才能把两者严格拆开。

#### earley-boyer — 未独立证明通过

candidate peak 为 41,574,400 B。baseline 旧面板只记录 final committed
23,703,552 B，并且该运行有 decommit/recommit，不能把 final 当 peak。baseline 的
21 个 2 MiB superblock 给出 gross-reservation 上界 44,040,192 B，candidate 比该
上界低 5.599%，但上界不是同一时刻的 committed peak，不能据此宣称满足 +3%。
由于 splay 已经硬失败，未为已 KILLED 的方案追加一次基线重建来补 EB peak。

原始账：`.scratch/baseline-earley-boyer-gc-stats.txt`、
`.scratch/candidate-earley-boyer-gc-stats-final.txt`。

## 遗留风险与负值结论

1. **空间机制不达标**：black block 保住的是该块当期全部 cell，而不是逐对象最小
   live set；splay 的 partial-block 数与 committed peak 同时上升，已越过预注册线。
2. **未归因的 PMU 下崩溃**：earley-boyer candidate 在 perf 环境 SIGSEGV，现有
   证据不足以命名 UAF、barrier omission 或其它 lifecycle 机制。driver 若要研究，
   应把它作为独立 correctness attribution，不应把本 lane 先合入再追。
3. **EB peak 基线缺直接字段**：只能给 gross upper bound，不能伪造同口径 ratio。
4. 未跑 test262 / gate_smoke / arena audit；按 verification policy 它们属于 driver
   merge-batch gate，而且本 lane 已 KILLED。

最终工作树有 11 个受控 source/test 文件被修改，`git diff --check` 通过；没有提交、
没有 push。到此停止，等待 driver review。

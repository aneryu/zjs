# 分配前端逐指令账与两把刀(2026-08-29)

基线 `9dc9994e`,worktree `/home/aneryu/worktrees/opus-allocfront`,分支
`gc/opus-allocfront`。靶子取自 `docs/splay-account-2026-08-28.md`
的 alloc 子族表:`allocAlignedBytesNoTrigger` +0.192G、`allocInternal*` +0.182G,
合计 trace 0.863G、净欠 0.374G。

**结论先行:这 0.374G 里几乎没有一分钱是重复的固定开销。它是 slab arena
自由链表在 trace 下变冷的访存代价——同一份共享代码,rc 命中、trace 未命中。**
按指令口径本靶区只剩两把小刀(合计 splay −0.43% 指令);真正的钱要靠局部性
拿,而那是热块复用那条线的地。

---

## 1. 并排指令账:trace vs rc(ReleaseFast,同一份源码)

采集:`taskset -c 16/17 perf record -e armv8_pmuv3_1/cycles/ -c 262147`,
fixed-work `splay.js`,0 lost samples;`perf annotate` 逐指令。

### 1.1 `allocAlignedBytesNoTrigger`

两个构建走同一条源码路径(该函数在基线上不含任何 collector 分支,
除了 `noteCyclePeak`)。符号体积 trace `0x354` / rc `0x32c`,差 40 字节。

| 分类 | 指令 | trace | rc | 判定 |
|---|---|---:|---:|---|
| **重复固定开销** | `classIndex(byte_count, alignment)` 跑**两次**(记账一次、`rawAlloc` 一次),含 `and/tst/add/and/adds/cset/strb/b.cs/cmp/b.ls` + 三段 `blockSizeIndex` 算术 | ~18 条 | ~18 条 | **可删**(K2) |
| **重复固定开销** | `block_sizes[index]` 表查两次(`adrp/add/ldr` × 2) | 6 条 | 6 条 | **可删**(K2) |
| **cache-line 受限** | `ldrh w10,[x8,#40]` → `madd` → `ldrh w11,[x9,#48]!` → `strh w11,[x8,#40]` = arena 自由链表弹出 | **80.4% 自身周期** | **57.3% 自身周期** | 删指令=零,见 §2 |
| 必要语义(trace-only) | `noteCyclePeak`:`ldr cycle_peak_output` + `cbz`(命中时再 `ldr/cmp/csel/str`) | 2 条热 + 4 条冷 | 0 | 保留(§1.3 仪器) |
| 固定开销(未取) | 128B 栈帧 + 4 × `stp` 保存 + 对称 `ldp`,热路径一个 callee-saved 都没用到 | 16 条 | 16 条 | 见 §4 未做候选 |
| 固定开销(未取) | `strb w8,[sp,#28]` / `strb w9,[sp,#48]` / `strb w8,[sp,#76]` —— optional / error-union 溢出到栈 | 3-5 条 | 3-5 条 | 见 §4 |

热点绝对分布(自身周期占比):

| 指令 | trace | rc |
|---|---:|---:|
| `strh wN,[arena,#first_free_block]`(等自由块头装载) | **66.5%** | **36.7%** |
| `madd`(算块头地址) | 7.3% | 9.3% |
| `ldr allocated_bytes` | 6.6% | 11.1% |
| 其余(全部算术/分类/栈/记账) | 19.6% | 42.9% |

即:trace 4.24% × 80.4% = **3.41%** 落在这条 miss 链上,rc 3.03% × 57.3% =
**1.74%**,比值 **1.96×**——**符号级 +0.192G 的全部**。链外的工作 trace
反而比 rc 便宜(0.83% vs 1.29%)。

### 1.2 `allocInternal`(splay 上最热的实例 `__anon_54254`)

这个函数**不含**重复分类:class 只算一次并直接喂给 `slabPopHot`。逐指令看
trace 相对 rc 唯一的额外项是 `noteCyclePeak` 的两条。它的自身周期:

| 指令 | trace |
|---|---:|
| `strh w14,[x9,#40]`(同一条自由链表头更新) | **78.4%** |
| `madd` | 4.4% |
| 其余 | 17.2% |

**结论:`allocInternal` 的 +0.182G 里没有可删的指令。** 它已经是干净的。

### 1.3 `addInitializedWithSizeNoFail`(登记审计移交的那条)

trace-only(rc 下几乎全部 comptime 消解)。

| 分类 | 指令 | 判定 |
|---|---|---|
| **同一字节写后重读** | `strb [hdr+2]`(heap_accounted)之后 `ldrb [hdr+2]` 供 `isBlockCellHeader`,其后 `bics` 占 **40.1%** 自身周期 | **可删**(K1) |
| **同一字节写后重读** | `strb [hdr+3]`(young 位)之后再 `ldrb [hdr+2]`,其后 `mov/bics` 占 **7.0%** | **可删**(K1) |
| 必要语义 | `orr #0x40` + `strb` 发布位 | 保留(登记审计 §3.1:唯一不可退的逐对象写) |
| 必要语义 | `old_space.recordAlloc` 的 ldr/add/str | 保留 |
| 冷 | `Table.insert` / concurrent 灰化 / large 臂 | 未执行 |

编译器为什么不敢复用寄存器:`old_space.recordAlloc` 与
`recordLargeSpaceAllocCold` 都经 `self` 写内存,可能与 header 别名,所以
store 之后的每一次 `alloc_info` 读都必须重新装载。

### 1.4 硬件证据:trace 的 miss 是真的

`perf record -e armv8_pmuv3_1/l2d_cache_refill/ -c 20011`,同一份 splay:

| 符号 | trace(L2D refill 占比) | rc |
|---|---:|---:|
| `allocAlignedBytesNoTrigger` | **2.02%** | **0.04%** |
| `allocInternal`(两个实例合计) | **1.81%** | 0.06% |
| `freeAlignedBytes` | 2.08% | 2.48% |

配合账里的总量(trace 248.59M / rc 149.24M L2D refill):
alloc 侧 trace ≈ 9.5M 次 refill,rc ≈ 0.15M 次,**六十倍**。

机理很干净:**rc 的 slab 是完美 LIFO 交接**——一个短命 payload 释放后立刻
被下一次分配拿回同一个块,free 侧付 miss(2.48%)、alloc 侧全命中(0.04%)。
tracing 下释放集中发生在 sweep/排水批次里,自由链表被打散成跨 arena 的
随机游走,于是 **alloc 侧也开始 miss**。这正是 splay 账 §「解释修正」说的
JSC 红利(`SweepToFreeList` 让刚扫完的热块立刻回到分配器)我们没拿到的那笔,
只不过这次是在 **slab**(非 GC 载荷)上而不是 block heap 上观察到的。

---

## 2. 刀

### K1 —— publication 的三次 `alloc_info` 装载收成一次

- **分类:重复的固定开销(同一字节写后重读)**,不是 cache-line 受限:
  那个字节刚被本函数写过,一定在 L1;40% 是 store→load 转发/重放停顿。
- **改动**(`src/core/gc.zig`):`addInitializedWithSizeNoFail` 在写
  `heap_accounted` **之前**把 `alloc_info` 读进一个局部,由它派生
  `standalone` 与 `is_block_cell`,再把这两个布尔沿
  `registerLiveAddressClassified` → `markPublishedYoungClassified` 传下去。
  旧的 `registerLiveAddress` / `markPublishedYoung` 保留为薄包装(其余调用点不变)。
- **成立的理由**:置 bit6(heap_accounted)/bit5(large)/写 `size_class`
  (字节 0..1)/写 `flags.young`(字节 3)都不动 `block_size_idx`(低 5 位)
  与 `standalone`(bit7)。三条断言把这一点钉住(§3)。
- **预期**:指令持平(热路径条数几乎不变,prologue 反而多存一对寄存器);
  **cycles 下降**。
- **实测**:指令 −0.025%(在噪声内,见 §5);
  `addInitializedWithSizeNoFail` 的 profile 份额 **1.66% → 0.88%**(−47%),
  与「两次重读合计约 47% 自身周期」吻合。**这是一把只有 cycles 能验收的刀。**
- 符号体积 `0x260 → 0x2d4`(+116B):`alloc_info` 的活跃区间拉长,多存一对
  callee-saved。如实记账。

### K2 —— `allocAlignedBytesInternal` 的重复 slab 分类

- **分类:重复的固定开销**,但**位于那条 miss 的地址依赖链上**——省下的
  ALU 让 miss 提前发起,而不是与 miss 并行的白工。所以指令必降,cycles
  只能算「有希望」,不能当收益卖。
- **改动**(`src/core/memory.zig`):记账已经算出的 class 直接喂给
  `small_slab.allocAtIndex`,`block_sizes[index]` 也只查一次。
- **两个实现教训**:
  1. 第一版把答案写成 `?usize` 传给一个 `rawAllocClassified` 助手:LLVM 把
     optional **沉到栈上**(`str x9,[sp,#40]` / `ldrb w8,[x9]`),函数从
     `0x354` 涨到 `0x364`,比重算还长。改成 **index-or-`class_count` 哨兵**
     后收到 `0x2d4`(−128B),分类只跑一次。
  2. 校验用的 `std.debug.assert(slab_class == classIndex(...))` 在 ReleaseFast
     **没有被消除**——正好把这把刀要删的重算又加了回来。改成
     `if (comptime std.debug.runtime_safety)` 包裹后消失。
     教训:**「assert 会被 DCE 掉」不是可以默认的前提,尤其当 assert 里就是
     你要删的那段计算时,必须反汇编确认。**
- **rc 门控**:整段走 `if (comptime trace_stw_enabled)`,rc 保留原路径,
  `.text` 逐字节相同(§4)。
- **预期**:splay 指令 −0.2~0.5%,非 splay 基本不动(它们很少走这条路)。
- **实测**:splay **−0.43%**,raytrace −0.058%,EB −0.022%。

---

## 3. 检查器与注入验证

新增五个检查器,**全部在目标构建形态下注入验证过会开火**
(`zig build test -Dzjs_experimental_gc=trace_stw`,Debug):

| # | 检查器 | 注入的故障 | 结果 |
|---|---|---|---|
| 1 | `gc.zig` `assert(is_block_cell == isBlockCellHeader(h))` | 把 `is_block_cell` 的比较常量改成 `block_cell_size_class - 1` | 在 `gc.zig` 该行开火 |
| 2 | `gc.zig` `assert(info_at_entry.standalone == …)` | 在断言前写 `alloc_info.standalone = !info_at_entry.standalone` | 在该行开火 |
| 3 | `markPublishedYoungClassified` 的同名断言 | 调用点传 `!is_block_cell`(绕过 #1) | 在 `gc.zig:4233` 开火 |
| 4 | `memory.zig` comptime 哨兵域断言 | 把上界改成 `class_count - 8` | 编译期 `reached unreachable code` |
| 5 | 新单测 `aligned byte allocations charge their slab class` | (a) 记账用 `slab_class + 1`;(b) 路由 class 取反 | 两种都 `expected 16, found 24` 等失败 |

⚠️ **#5 必须单独跑才算证明**:两次注入在全量跑时都先被**别的**既有守卫
拦下(`freeAlignedBytes` 的 class 断言、`JSRuntime.deinit` 的账本断言)。
按「注入触发了别的守卫 ≠ 你要测的守卫有效」,用
`./.zig-cache/o/*/unified-tests "charge their slab class"` 单独复跑才确认。

---

## 4. 门禁

| 门 | 命令 | 结果 |
|---|---|---|
| rc 单测 | `taskset -c 0-14 zig build test` | **2381 passed / 93 skipped / 0 failed**,exit 0 |
| trace 单测 | `taskset -c 0-14 zig build test -Dzjs_experimental_gc=trace_stw` | **2456 passed / 19 skipped / 0 failed**,exit 0 |
| fixed-work 冒烟 | `tools/perf/gate_smoke.sh <候选 trace 二进制> /tmp/gcgap-fixed 18 3` | **all clean**(6 负载 × (3 ordinary + 1 arena-audit/stats)),exit 0 |
| rc `.text` 逐字节 | `objcopy --only-section=.text` + sha256 | **相同**:base 与候选都出过 `4ae2685705e87002d96c40fa024686a16e1078e5269bec2b6fee01f7b7f63bde`(见 §4.1 的重要限定) |

rc `.text` 四向核过:只带 gc.zig 改动、只带 memory.zig 改动、两者一起(两次),
都出现过与 base 逐字节相同的 3,352,660 字节 `.text`。

冻结二进制 SHA-256:
- base trace `e9cca200dd1a3ac04f2823a6e6d2efc6844d53de9823ac7f5dd0bf08790a132b`
- 候选 trace `9842d81c83a6aebc3507af7c2abf57833fa6894d0e68cee65e3be18fc4a03443`
  (删掉一次 `.zig-cache` 输出目录后重建复现同一哈希)

### 4.1 ⚠️ 本仓库的 rc ReleaseFast 构建**不是确定性的**——`.text` 哈希门须改写

核实过程中候选的 rc `.text` 时而等于 base、时而不等。二分之后确认**与我的
改动无关**:

```
同一份源码(未改动)、连续两次 ReleaseFast rc 构建:
  .scratch/cand-rc.text  = 3babaeee7e05c33905abbeaf75987d32dade9304f2a3a29484977c6948250ecd
  .scratch/cand-rc2.text = 4ae2685705e87002d96c40fa024686a16e1078e5269bec2b6fee01f7b7f63bde
符号尺寸表差 723 行,全在 binding.context / bytecode.binding_rules /
compiler.resolve_variables 等与本改动无关的模块。
```

这与记忆里「Zig 对固定源码确定性」的既有假设冲突,**该假设在本构建配置下
(整程序单模块 + `-fllvm` + `tail_hot_layout_aarch64.ld`,且同机有 6 个并发
`zig` 进程共享 global cache)不成立**。

因此:

- **`.text` 哈希相同只能作为存在性证明**(若改动真的动了 rc 代码,
  三千多 KB 的逐字节相同不可能偶然出现),不能作为每次可复现的门。
- **可复现的替代口径 = 逐函数指令流比对**(地址与 `<sym>` 归一化后):

| 函数 | base vs 候选(两个 rc 构建) | 说明 |
|---|---|---|
| `Registry.addInitializedWithSizeNoFail`(46 insn) | 指令流相同 | — |
| `Registry.addInitializedShape` | 相同 | — |
| `MemoryAccount.allocAlignedBytesNoTrigger`(203 insn) | 指令流相同 | 不确定性构建里只差两条 `add x9,x9,#imm` 的 **rodata 偏移**(0x4d0/0x478),即全局布局位移,不是代码变化 |
| `MemoryAccount.freeAlignedBytes`(74 insn) | 指令流相同 | — |

**这条建议提给 driver 作为测量合同修订**:凡要求 `.text` 逐字节的验收,
必须先确认该构建配置可复现,否则改用「逐函数指令流 + 归一化」口径。

### 4.2 两条必须记下的环境教训

1. **`rawAlloc` 改成调用一个共享的 `rawSlabClass` 助手会破坏 rc `.text` 门。**
   语义完全相同,但 LLVM 把 **26 条 `tbz wN,#0,L` 重新编码成 `cbz wN,L`**
   (bool 保证 0/1,两者等价)。为了保住这个门,`rawAlloc` 保留原样,
   `rawSlabClass` 只服务 tracing 臂,两者的一致性改由新单测钉住
   (账本 delta 是「选错 class」唯一外部可见的后果)。
2. **不要把源码备份或测量脚本写进 `/tmp`。** 本轮把 `src/core/gc.zig` 备份成
   `/tmp/gc.zig.orig`,被同机另一个 agent 用同名路径覆盖,恢复时把对方
   (lane-a 屏障 bit7)的工作拷进了我的树;因为它引用了本树不存在的
   `gc_generation` 方法,ReleaseFast 当场编译失败才暴露。已改用
   worktree 内 `.scratch/`。**这类污染可以静默——如果对方的改动恰好能编译,
   我就会把它当成自己的改动一起测量和提交。**
   护栏:恢复后 `diff` 一次,提交前 `git diff` 逐块读。

---

## 5. 指令数 A/B(筛选口径)

`taskset -c 17 perf stat -e armv8_pmuv3_1/instructions/`,交错 A B B A,
三轮共每臂 6 次;冻结二进制。

| 负载 | base 均值 | 候选均值 | Δ | base 臂内极差 | 候选臂内极差 |
|---|---:|---:|---:|---:|---:|
| splay | 33.798G | 33.652G | **−0.432%** | 0.198% | 0.267% |
| raytrace | 243.251G | 243.109G | −0.058% | 0.196% | 0.236% |
| earley-boyer | 478.463G | 478.358G | −0.022% | 0.302% | 0.325% |

分刀归因(同法,早一轮的等价二进制):**K1 单独 −0.025%(噪声内),
K2 提供了全部 −0.43%。**

⚠️ 采集时 `pgrep -c -x zig = 6`(其它 lane 在编译)。按 §4n 指令数在同等
负载下 spread 只有 0.06-0.19%,实测臂内极差 0.20-0.33%,与该结论一致;
但 **cycles/wall 在本窗口不可用,裁决归 driver 安静窗口**。

**K1 的验收不能用这张表。** 它的证据是 profile 份额
`addInitializedWithSizeNoFail` **1.66% → 0.88%**(同一次运行内的份额,
对主机噪声稳健),以及被删掉的两条重读在反汇编里确实消失。

---

## 6. 未做的候选与理由

| 候选 | 分类 | 不做的理由 |
|---|---|---|
| `allocAlignedBytesNoTrigger` 的 128B 栈帧 + 4 对 callee-saved(每次调用 16 条固定指令) | 省指令,栈是 L1 热 | 结构上要把 `addArena` / backing-allocator 调用外提成 noinline 冷孪生。**同一形态已经存在于 `allocInternal`**:它的冷孪生早就是 noinline,prologue 照样保存 5 个寄存器且热路径一个都不用——LLVM 在这里不做 shrink-wrap。先例也不利:lane-c 对 `allocCellFixedPtr` 做过 slow-continuation 孪生,`l1i refill −5.91%` 而 wall 只 +0.14%,判 NO-GO。**预期 cycles 零**,不值这个改动量。 |
| optional / error-union 溢出到栈的 3-5 条 `strb [sp,#N]` | 省指令,栈是 L1 热 | 同上,且要重写 `std.math.add` 的用法,收益在噪声地板附近。 |
| `noteCyclePeak` 的两条热指令 | trace-only 固定开销 | 是 §1.3 same-domain cycle peak 的**精确仪器**,删掉边界采样就失真。占该符号 0.6%,不值。 |
| `freeAlignedBytes` / `MemoryAccount.free` 的 `block_sizes[index]` 双查 | 重复固定开销 | 与本任务的 alloc 靶区相邻但在释放侧;`freeAlignedBytes` 只有 1.26%,且它在 rc 下也 miss(L2 refill 2.08% vs 2.48%),量级不够单独立项。留作后续候选。 |
| slab 自由链表的块粒度复用(让 trace 也拿到 rc 的 LIFO 热交接) | **局部性**,不是指令 | 这才是 0.374G 的真身(§1.4)。但它改的是块/自由链表生命周期与复用顺序,属热块复用那条线的地,且本任务明令不动块生命周期/热发布。**移交**。 |
| 减少 `allocAlignedBytesNoTrigger` 的调用次数(splay 一次运行约 7M 次) | 频次侧 | 调用点是对象属性存储布局(`object.zig:1502`)与字符串字节;改它属对象布局工作,不属分配前端。 |

---

## 7. 给 driver 的三句话

1. **alloc 前端按指令口径基本无肉。** 净欠 0.374G 里,`allocInternal` 一分
   没有可删的指令;`allocAlignedBytesNoTrigger` 只有一处重复分类(已取,
   splay −0.43% 指令)。剩下的全是 miss。
2. **靶子的性质要改写**:它不是「trace 的分配带钩子/带登记」,而是
   **「trace 的 slab 自由链表是冷的,rc 的是热的」**——L2D refill 占比
   2.02% vs 0.04%,六十倍。**账本里这两行应当从「机械」重新归类到
   「足迹/局部性」**,并与热块复用设计合并考虑。
3. **K1 是一把 cycles-only 的刀**,指令口径读不出来(−0.025%);
   它的兑现证据是符号份额 1.66%→0.88%。请在安静窗口给它单独定价——
   若成立,约合 splay 的 0.78%(≈0.08G)。

# slab 自由链表在 tracing 下变冷:实测归因与那把刀(2026-08-29)

基线 `f4ea32f1`,worktree `/home/aneryu/worktrees/opus-slabreuse`,分支
`gc/opus-slabreuse`。靶取自 `docs/alloc-front-2026-08-29.md` §1.4 移交的
0.374G:alloc 侧 L2D refill trace ≈9.5M vs rc ≈0.15M(**六十倍**),自身周期
80.4% 落在 `arena.first_free_block` 弹出链上。

**结论先行:移交时的机理描述(「批量释放把自由链打散成跨 arena 游走」)被本轮
实测推翻了两次,而第三次量出的真机理给出一把 2 条指令的刀。**

- 打散程度:**trace 比 rc 更有序**(arena 内漂移均值 124B vs 354B,升序相邻
  33.3% vs 21.5%),**不是**打散。
- 每次 arena 访问的连贯度:**trace 是 rc 的两倍**(每次进入一个 arena 连弹
  47.1 块 vs 25.6 块),**不是**碎片化。
- 真机理:**alloc 侧走的 arena 集合大了两个数量级**。rc 在一个 4.8 个 arena 的
  热池里循环(16.6% 的切换回到最近 8 个之一);trace 在 2,733 个 arena
  (10.7 MiB)里单向扫过,**0.04% 回访**。同一份链表代码,rc 每次弹出的那个
  block header 命中 L1/L2,trace 落在冷页上——**于是 qjs 的自由链变成一串
  串行的冷相关载入**。

刀:**把下一次弹出的 block header 提前一次分配发起**(trace 门控,2 条指令)。
splay **cycles −2.47%**、六基准 cycles geomean **0.99394**、rc 指令直方图逐条
相同。

---

## 1. 仪表:`src/core/slab_locality_audit.zig`

`memory.slab_locality_audit` 翻成 `true` 重建即可,报告在 slab 拆除时打到
stderr(CLI 快路径不销毁 runtime,所以 `src/cli/zjs.zig` 显式调一次)。
计数器分三组:

| 组 | 量 | 回答的问题 |
|---|---|---|
| alloc 侧 | 逐类 arena 切换率、切换时该 arena 的空闲块数、**最近 8 个 arena 的回访率**、每类自由 arena 链表长度 | 分配走的是热池还是长队 |
| arena 内 | 连续弹出的 `|Δ 地址|` 均值、升序相邻比例、同 arena 连弹长度直方图 | 页内顺序是升序流还是随机跳 |
| free 侧 + 生命周期 | 同 arena 连续释放长度、full→partial 比例、**最近 32 次释放的 LIFO 命中深度**、活 arena 数与峰值、结束时占用率直方图 | 交接是否 LIFO、足迹多大 |

### 1.1 仪表自校验

计数器与一个**独立维护的量**对账:`pops − frees` 必须等于结束时全部 arena 的
`used_blocks` 之和。两个收集器都逐个匹配:

```
rc     : 35,287,407 − 35,286,069 = 1,338    ;  Σ used_blocks = 1,338
trace  : 23,189,957 − 22,388,877 = 801,080  ;  Σ used_blocks = 801,080
```

这是双向的:少记一次 pop 或多记一次 free 都会破坏它。**没有这条对账,下面所有
结论都只是「我写了脚本」。**

### 1.2 一个采集口径陷阱

全局 pop 流里「与上一次弹出同 arena」在两个收集器上都是 0.01%–10%,读起来像
「谁都没有局部性」。**这个数字与局部性无关**:自由链表是**逐类**的,而热类有
6 个(40/64/72/96/112/176 字节),分配流在它们之间轮转,所以相邻两次弹出几乎
必然不同类、因而不同 arena。**唯一有意义的是逐类口径**,本文所有 alloc 侧数字
都是逐类的。

---

## 2. 实测(fixed-work 负载,ReleaseFast)

### 2.1 splay:rc vs trace

| 量 | rc | trace | 判读 |
|---|---:|---:|---|
| slab 弹出次数 | 35.29 M | 23.19 M | trace 少(对象已进 block heap) |
| **每类 arena 切换** | 1.379 M(3.91%) | 0.492 M(2.12%) | trace **每次进入连弹 47.1 块**(rc 25.6) |
| **切换时自由 arena 链表长** | **4.84** | **2,733.20** | ⭐ 差 **565 倍** |
| **回访最近 8 个 arena** | **16.63%** | **0.04%** | ⭐ rc 循环热池,trace 单向扫过 |
| arena 内 `|Δ 地址|` 均值 | 354 B | **124 B** | trace 更有序 |
| arena 内升序相邻 | 21.5% | **33.3%** | trace 更有序 |
| 最近 32 次释放的 LIFO 命中 | 33.31%(depth0 12.22%) | **46.78%**(depth0 18.53%) | trace 反而更 LIFO |
| 活 arena 峰值 | 36,108 | 32,283 | 峰值相当 |
| 结束时活 arena | **57** | **28,062** | ⭐ 稳态足迹差 500 倍 |
| 结束时占用率 | 50.3% | 64.1% | — |

**读法**:峰值 arena 数几乎一样(rc 36k / trace 32k),所以「trace 足迹更大」
不是解释。区别在**稳态**:rc 立刻回收,任何时刻只有几个 arena 处于「有空位」
状态,分配就在这几个页上循环;trace 直到 GC 才回收,一次清扫让**几千个 arena
同时变成部分空闲**,分配侧此后逐个把它们扫空,每个只去一次。

### 2.2 三个基准的 slab 形态完全不同——这是刀的选择依据

| | splay | earley-boyer | raytrace |
|---|---:|---:|---:|
| 弹出次数 | 23.2 M | 281.5 M | 128.0 M |
| **自由 arena 链表长** | **2,733** | **89.5** | **1.28** |
| **回访最近 8 个** | **0.04%** | **1.95%** | **20.28%** |
| LIFO depth0 | 18.53% | 25.87% | 30.04% |
| 活 arena 峰值 | 32,283(126 MiB) | 1,480(5.8 MiB) | **291(1.14 MiB)** |

**raytrace 在 tracing 下的 slab 形态与 rc 完全一致**:1.28 个候选 arena、20%
回访、1.14 MiB 工作集——整个装在 L2 里,链表追逐是免费的。earley-boyer 居中。
**只有 splay 病了。** 任何改动都必须在不动 raytrace 的前提下治 splay,这直接
淘汰了下面的方案一。

---

## 3. 三个方案与它们的实测

三个都实现并在 ReleaseFast/trace 上量过(`perf stat -e
armv8_pmuv3_1/{instructions,cycles,l2d_cache_refill}`,ABBA 交错,每臂 4 次)。

### 3.1 方案一(否决):arena 头里的自由位图

把自由集从「穿在自由块里的链」改成「arena 头里的 4×u64 位图」,弹出用
`ctz` 定位、升序取块。**alloc 路径上的冷相关载入被彻底删除**,块行只被 store
触及(索引戳 + 调用者随后写的载荷),而 store 不像相关载入那样串行化;顺带把
页内顺序变成升序,硬件跨步预取器能覆盖。

补充版还在 arena 头里加了 `hot: u16`(最近释放的块,取过即清),用来把
raytrace 依赖的 depth-0 LIFO 交接找回来——**它是 set 位的副本而不是独立状态**,
位图扫描只在 `hot` 为空时运行,两者永不发出同一个块。

实测:

| | splay | raytrace | earley-boyer |
|---|---:|---:|---:|
| 纯位图 cycles | −3.33% | +1.21% | +0.61% |
| 位图 + `hot` 提示 cycles | **−3.66%** | **+1.10%** | — |
| 位图 + `hot` 指令 | +1.51% | +1.05% | — |

**否决理由**:反汇编数出弹出路径 ~13 条指令(base ~5 条)。在 raytrace/EB 这种
arena 常驻缓存的形态里,被删掉的那条载入只值 ~4 周期,而多出来的 8 条 ALU 要
付全价——`hot` 提示只把 raytrace 从 +1.21% 拉到 +1.10%,却自己又加了 0.5% 指令。
**六基准 geomean 上它输给方案三。** 位图本身没有错,错在它的固定成本落在一条
「大多数基准根本不需要它」的路径上。

附带量出的一件事:位图让 arena 头从 48 涨到 80 字节(每 arena 少一块)。
用「只加 32 字节 padding、不加位图」的消融臂单独定价,raytrace cycles
**+0.01%**——**头部增长本身是免费的**,上面的回归全部来自指令。

### 3.2 方案二(未实现):per-class magazine

把最近释放的块停在一个逐类的小 LIFO 栈里,分配先从栈上取,栈满才真正还给
arena。它能让 44%–56% 的分配/释放对**完全不碰 arena 与 block 元数据**。
未实现的原因:§2.2 显示 raytrace/EB 的 LIFO 交接**已经由现有链表拿到了**
(它们的候选 arena 只有 1.28/89 个,链表天然就是 LIFO),magazine 只能让这部分
更便宜、不能让它更多;而 splay 的释放是清扫期的批量突发,深度 8 的栈只兜得住
最后 8 个。**收益集中在已经不痛的地方。** 留档不做。

### 3.3 方案三(采纳):把下一次弹出的 block header 提前一次分配发起

链表的成本是「每次弹出一次载入,而它的结果是**下一次**弹出要用的块地址」。
基线里这次载入只能在调用者初始化完上一个对象之后才开始。把它变成一次预取,
就把调用者整段对象初始化挪到 miss 前面去了。

```zig
const next_free = header.index_or_next;
arena.first_free_block = next_free;
if (comptime slab_alloc_prefetch) {
    const prefetch_idx: u16 = if (next_free == free_nil) 0 else next_free;
    std.debug.assert(prefetch_idx < arena.block_count);
    const prefetch_addr = @intFromPtr(arenaBlocks(arena)) + @as(usize, prefetch_idx) * block_size;
    std.debug.assert(prefetch_addr - @intFromPtr(arena) < arena_size);
    @prefetch(@as(*const u8, @ptrFromInt(prefetch_addr)), .{ .rw = .write, .locality = 3, .cache = .data });
}
```

生成码正好 **2 条**(`mul` + `prfm`),加上 `free_nil` 折叠的 `cmp`+`csel` 共 4 条:

```
ldrh  w12, [x9]              ; next_free（原本就有的那条冷载入）
strh  w12, [x8, #40]
mov   w13, #0xffff
cmp   w12, w13
csel  w12, wzr, w12, eq
mul   x12, x23, x12
prfm  pstl1keep, [x12, x11]
```

预取深度只有 1,而深度 1 恰好够:它把一次内存延迟藏进调用者的对象初始化里。
更深的预取做不到——链表下一跳的地址就是这次载入的结果。

#### ⭐⭐⭐ 无守卫的预取让 earley-boyer 慢 12.6%

第一版把 `free_nil` 判断省了,理由是「预取到未映射页在架构上是 no-op,一个
`cmp`/`b.ne` 比它省下的那一次还贵」。**这个理由是错的,而且错得很贵:**

| | 指令 | cycles | L2D refill |
|---|---:|---:|---:|
| earley-boyer,无守卫预取 vs base | +0.18% | **+12.6%** | +1.1% |

`free_nil = 65535` 让地址落在 arena 之后 6.8 MB 处。**预取本身被丢弃,但它触发的
页表遍历不会被丢弃**——本核上一次 TLB miss 的 walk 要付全价。EB 一次运行里
arena 变满约 50 万次(每次都是一次 `free_nil`),12G 周期就是这么来的。
折叠成块 0(同一个 4 KiB arena 页,必然已映射且在 TLB 里)后,EB 变成 **−0.43%**。

**教训:预取的代价不在填充,在翻译。** 「预取一个坏地址是免费的」只对
*已映射* 的坏地址成立。任何计算出来的预取地址都必须能证明落在一个已知映射的
页里——上面两条断言就是把这个证明写进代码。

---

## 4. 采纳版的六基准实测

安静窗口(六个大核 idle ≥99%,`pgrep -c -x zig = 0`),`taskset -c 17`,
ABBA 交错、每臂 4 次,取中位数。冻结二进制
base `a84503cbc500f8467594c3866974476ce19952968d010e911bc4200b4960ef5f`、
候选 `d483c78084e7a142a1ca94be2d00f22771c8339ad252b8f5b6f0e9cc8b4436f8`
(最终树多两条 `std.debug.assert`,ReleaseFast 下 alloc 路径反汇编逐条相同,
只差一个 rodata 偏移立即数)。

| 负载 | 指令 Δ | **cycles Δ** | L2D refill Δ | base cycles 臂内极差 | 候选极差 |
|---|---:|---:|---:|---:|---:|
| **splay** | +0.41% | **−2.47%** | −2.36% | 0.50% | 0.45% |
| raytrace | +0.36% | +0.43% | **−7.69%** | 0.77% | 0.56% |
| earley-boyer | +0.26% | −0.12% | −0.88% | 0.48% | 1.28% |
| deltablue | +0.04% | −0.24% | −1.49% | 10.27%※ | 0.17% |
| regexp | +0.08% | −0.97% | +0.62% | 0.95% | 0.72% |
| pdfjs | +0.21% | −0.23% | +0.58% | 0.45% | 0.20% |
| **cycles geomean** | | **0.99394** | | | |

※ deltablue base 有一个 82.7G 的离群样本(其余三个 74.8–75.2G),故全表取中位数。

- **splay −2.47%** ⇒ 1.339 → 约 **1.306**(达标线 ≤1.256,仍差 3.9%)。
- 唯一为正的是 **raytrace +0.43%**,而它的 refill 掉了 7.69% —— 这 0.43% 是
  +0.36% 指令的价钱,落在一个 slab 本来就全热的基准上。早一轮等价二进制在
  同法测量下给 +0.03%,所以真值在 0–0.4%,与臂内极差同量级。
- **指令口径读不出这把刀**(+0.04%~+0.41% 全为正)。这是布局/延迟刀,按 §4n
  只能用 cycles + refill 验收。

---

## 5. rc 中立性

预取整段在 `if (comptime slab_alloc_prefetch)` 里,`slab_alloc_prefetch =
trace_stw_enabled`,rc 下不存在。证据分两层:

1. **逐函数归一化指令流**(地址归一化后)base vs 候选 rc ReleaseFast:

| 函数 | 指令数 | 结果 |
|---|---:|---|
| `MemoryAccount.allocAlignedBytesNoTrigger` | 203 | 逐条相同 |
| `MemoryAccount.freeAlignedBytes` | 74 | 逐条相同 |
| `MemoryAccount.allocInternal` | 153 | 逐条相同 |
| `SmallObjectSlab.addArena` | 82 | 逐条相同 |

2. **全二进制指令助记符直方图**:880,049 条,**逐类完全相同**;
   `text/data/bss` 三段字节数也完全相同(3944891 / 122784 / 265805)。

`.text` 的 sha 仍不同,但这只反映符号编号位移(见 §5.1)。

### 5.1 ⭐⭐ 关于 `.text` 逐字节条款的一条修订(比 alloc-front §4.1 更精确)

alloc-front §4.1 把 rc `.text` 的不可复现归因于「同机 6 个并发 `zig` 共享
global cache」。本轮在**没有任何并发 zig**、机器空闲的窗口重做:

- 同一份未改源码连续两次 rc 构建:`.text` **完全相同**。
- 在 `memory.zig` 顶部加一行**纯注释**后重建:`.text` **仍然与 base 完全相同**。
- 只加那 25 行、在 rc 下 comptime 全消的预取代码后重建:`.text` **不同**,
  但指令直方图与三段尺寸逐条相同。

⇒ **构建对固定源码是确定性的;不确定的是「加一个容器级声明」这件事本身。**
新增声明改变匿名符号编号 → 改变符号顺序 → 改变链接布局 → 改变 rodata 偏移
(`adrp`/`add` 的立即数),连带触发不同的指令调度和寄存器分配,而这些散落在
`compiler.resolve_variables`、`compiler_rt.memmove` 这类**与改动毫无关系的
模块**里。

**因此 rc 验收口径应当写成:**
> `.text` 相同 ⇒ 零改动(仍成立);`.text` 不同 ⇒ **不构成任何证据**,必须再看
> ①全二进制指令助记符直方图 + 三段尺寸,②被改模块的逐函数归一化指令流。
> 只有这两条都相同才算中立。

### 5.2 ⭐⭐ 仪表本身会动 rc,所以它不住在 `memory.zig` 里

第一版把 300 行(comptime 全死的)计数器放进 `memory.zig`。rc 的代价:
**+171 条指令、`.bss` 少 688 字节**——直方图不再相同。改成
`src/core/slab_locality_audit.zig`,由

```zig
const slab_audit = if (slab_locality_audit) @import("slab_locality_audit.zig") else struct {};
```

在 comptime 分支的**被取用侧**导入(关闭时该文件根本不被解析)之后,rc 直方图
回到逐条相同。

同一条教训的第二例在 CLI 里:`engine.core.memory.slabLocalityReport();`
**不加 `if (comptime …)` 直接调**,即使函数体在关闭时是空的,也会移动 rc 的
`.text`。**「它编译出来是空的」不等于「它不存在」。**

---

## 6. 检查器与注入验证

新增两条断言(都在 `slab_alloc_prefetch` 臂内,ReleaseFast 下消解):

| # | 断言 | 注入的故障 | 结果 |
|---|---|---|---|
| 1 | `prefetch_idx < arena.block_count` | 去掉 `free_nil` 折叠(`const prefetch_idx: u16 = next_free;`) | `zig build test -Dzjs_experimental_gc=trace_stw` 下 `panic: reached unreachable code`,栈顶正是该行 |
| 2 | `prefetch_addr - @intFromPtr(arena) < arena_size` | 同上(#1 先开火) | 由 #1 覆盖 |

⚠️ **`zig build zjs`(默认 artifact)里这条注入不开火。** 该产物的 safety 是关的
(`strings` 里没有 `reached unreachable code`),同一份注入源码跑 splay 正常
退出。**按「注入触发了别的守卫 ≠ 你要测的守卫有效」的同族纪律:注入必须在
`zig build test` 形态下做,`zig build zjs` 跑通什么都不证明。**

仪表侧的验证见 §1.1 的自校验(两个收集器都逐个匹配)。

---

## 7. 门禁

| 门 | 命令 | 结果 |
|---|---|---|
| rc 单测 | `taskset -c 0-14 zig build test` | **2381 passed / 96 skipped / 0 failed** |
| trace 单测 | `taskset -c 0-14 zig build test -Dzjs_experimental_gc=trace_stw` | **2459 passed / 19 skipped / 0 failed** |
| fixed-work 冒烟 | `tools/perf/gate_smoke.sh <候选 trace 二进制> /tmp/gcgap-fixed 18 3` | **all clean**(6 负载 ×(3 ordinary + 1 arena-audit/stats)) |
| arena 审计 | `ZJS_GC_ARENA_AUDIT=1 <bin> --gc-stats splay.js` / `earley-boyer.js` | exit 0,stderr 空(零违规) |
| rc 中立 | §5 两层 | 直方图逐条相同 + 四个 slab 函数指令流逐条相同 |

---

## 8. 未做的候选

| 候选 | 不做的理由 |
|---|---|
| per-class magazine(§3.2) | 收益集中在 raytrace/EB,而它们的 LIFO 交接现有链表已经拿到;splay 的批量释放突发兜不住。 |
| 自由位图(§3.1) | splay 多赚 1.2pp,但 raytrace +1.10%/EB +0.61%,六基准 geomean 输给预取。代码不保留,设计与实测全在 §3.1,重建成本一小时。 |
| 位图 + 升序预取的组合 | 位图下地址无需载入即可算出,可以预取任意深度——但前提是先接受位图在 raytrace/EB 上的指令成本。等 §3.1 的准入条件变了再说。 |
| free 侧预取 | `freeAlignedBytes` 的 refill 在 rc 下也有 2.48%(trace 2.08%),不是 trace 专属欠账,量级不够单独立项。 |
| 增大 arena(4 KiB → 16/64 KiB) | 触碰保守指针解析的掩码常量与 `releaseEmptyArena` 的回收粒度;更大的 arena 更难被清空,足迹风险直接对冲收益。 |
| 减少活 arena 数(§2.1 以为的病根) | 第二轮把它当靶查了:**猜错了两层**,见 §9。种群本身不是差异(rc 全程 36,100 个活 arena,比 trace 的 28,030 **更多**),而剩下的那个量确实属包络线的地。 |

---

## 9. 种群治理(第二轮):三个被授权的形态全部落空,靶交回包络

基线 `952e16be`,worktree `/home/aneryu/worktrees/opus-slabpop`,分支
`gc/opus-slabpop`。第一轮把「28,062 个活 arena」列为剩余差距的同根靶(§8 末行),
本轮按仪表去查它,**两层都查反了**。

**结论先行:**

1. **种群不是差异。** rc 全程稳定持有 **36,100** 个活 arena,比 trace 的
   28,030 **更多**。差的是**占用率**:rc 的 arena 基本全满,trace 只有 64%。
2. **三个被授权的形态没有一个能落地**:arena 级 LIFO **已经实现**且影子模拟
   测出扩展它只影响 splay **0.01%** 的 pop;空 arena 释放**已经是即刻的**;
   「收缩候选集」是**空操作**——分配侧根本不扫描,它只读链头。
3. 真正的量是**复用距离**,实测**它 ≈ GC 头空间的一半**;而头空间的定价曲线
   往**反方向**走:放松到 growth 200% 时 splay cycles **−7.25%**、L2D
   **−16.0%**、其余五基准全在噪声内。**splay 停线在这条轴上一把就能越过**,
   代价是 §1.3 的 1.8 上限。

### 9.1 仪表扩充与自校验

`src/core/slab_locality_audit.zig` 新增五组计数器(全部 comptime 门控,rc 不
存在):arena 生命周期与逐类创建/释放、**释放页是否被换回**(最近 8/64/曾经)、
**arena 在自由链里等了多久才被分配侧取走**、活 arena 数的时间序列、
**free burst 结构**(连续多少次 free 之间没有 pop),外加**逐类活块普查**。

⭐ 新增一条**打印式自校验**(§1.1 的口径,但这次写进代码):
`pops − frees` 必须等于结束时全部 arena 的 `used_blocks` 之和。三个负载全对:

```
splay        : 23,189,957 − 22,389,589 = 800,368  == Σ used_blocks
earley-boyer : 281,539,824 − 281,455,073 = 84,751 == Σ used_blocks
raytrace     : 128,038,873 − 128,029,853 = 9,020  == Σ used_blocks
```

写成打印而非 `assert`,因为审计只在 ReleaseFast 下跑,断言在那里不存在。
注入验证(漏记 class 17 的 pop)当场报 `VIOLATION`,见 §9.10。

> ⚠️ splay 用 `Math.random`,逐次运行计数会漂 ~0.1%。下面每张表里的一行行数字
> 都取自**同一个二进制的同一轮会话**,跨表的绝对值不要互相相减。

### 9.2 Q1:28,062 个活 arena 从哪来?

**不是从「空 arena 没被回收」来的。** 读实现:`releaseEmptyArena`
(`src/core/memory.zig:411`)在 `used_blocks` 归零的**当次 free** 里就把 4 KiB
归还 backing,没有 aging、没有 per-class 保留。实测 splay 创建 114,232 个
arena、**释放了 86,156 个(75.5%)**;结束时占用率分桶里 `empty=7`(即时回收
的残留窗口)。

**它是活数据。** 结束时活块高度集中在三个尺寸类,而且是 **1:1:1**:

| 类 | 块大小 | 活块 | 占用 arena |
|---|---:|---:|---:|
| 3 | 40 B | 263,816 | 4,298 |
| 7 | 72 B | 264,460 | 7,899 |
| 17 | 176 B | 263,588 | 15,533 |

合计 **75.9 MiB**,与 §9.6 里 growth=105% 时量到的活 arena 地板
(19,400 arena = 75.78 MiB)**闭合**。Octane splay 的 `kSplayTreeSize=8000`
× `kSplayTreePayloadDepth=5` ⇒ 2⁵×8000 = **256,000 个叶子载荷**,每个叶子
恰好三笔 slab 分配(§9.9 给了三个分配点)。

**⭐⭐⭐ 但「种群」这个框架本身是错的。** 同一套计数器在 rc 上跑:

| 量 | rc | trace |
|---|---:|---:|
| **全程活 arena**(时间序列平台) | **36,100** | 28,030 |
| 活 arena 峰值 | 36,108 | 32,283 |
| **每类自由 arena 链长** | **4.84** | **2,728** |
| 创建 / 释放 | 47,783 / 47,726 | 114,232 / 86,156 |
| 平均 arena 寿命 | 25.8 M pops(82% 活过 2²² pops) | 4.24 M pops |

rc 的活 arena 数**比 trace 多 29%**,而且是全程平台(时间序列从第 2 个采样点
起就钉在 36,100)。⇒ **足迹(以 arena 计)不是差异**,第一轮从「结束时 57 vs
28,062」读出的 500 倍是**拆除时刻的假象**:rc 在 CLI 退出时把整棵树析构掉了,
tracer 不会。

真正的差异是**占用率**:rc 只有 ~4.84×31 ≈ 150 个 arena 处于「有空位」状态,
其余 36,000 个全满(≈99.8% 占用);trace 是 64%。**清扫一次把每个 arena 的
36% 变成空位,分配侧此后要走遍它们。**

### 9.3 Q2:回访率为什么是 0.04%?

**读实现就够,而且它推翻了移交里的一个词。** 分配侧是
`self.free_arenas[index] orelse addArena(...)`(`src/core/memory.zig:322`)——
**只读链头,没有任何扫描**。所以:

> ⭐⭐ 「有效扫描长度」**恒为 1**。2,733 是**种群统计量,不是每次分配的成本**。
> 移交里「分配侧逐个扫」这个描述在代码里没有对应物。

链的维护是:`addFreeArena` **头插**(`memory.zig:639`),
`removeFreeArena` 只在 arena **变满**时发生(`memory.zig:361`)。于是每个
arena 的一生是「进链一次 → 被抽干 ~47 块 → 变满出链」,**回访 0.04% 是这个
结构的直接推论**,不是病。

而头插只发生在 **full→partial** 那一次:

| | splay | EB | raytrace |
|---|---:|---:|---:|
| free 落进**已经是 partial** 的 arena(什么都不移动) | **97.78%** | 72.79% | 98.63% |
| free 造成 full→partial(头插) | 2.22% | 27.21% | 1.37% |

**新增的「等待时长」计数器**给出分配侧取到某个 arena 时它在链里已经躺了多久:
splay trace 均值 **297,819 pops**(众数 2¹⁸–2¹⁹)。看起来像病根——直到量 rc:
**rc 是 691,449 pops,比 trace 更久。** ⇒ **陈旧程度也不是差异**,差的是
**有多少个陈旧的 arena**。

### 9.4 三个被授权的形态,逐个落空

| 形态 | 判决 | 证据 |
|---|---|---|
| ① 自由 arena 链「获得空闲时移到链头」(arena 级 LIFO) | **已实现 + 扩展它没有 headroom** | `addFreeArena` 就是头插。把它扩到那 97.78% 的 partial free 上,用**影子模拟**(在审计里维护一个「该类最近被 free 的 arena」并逐 pop 比对基线实际选中的 arena)测得会改变选择的 pop:**splay 0.01%**、EB 1.05%、raytrace 0.73%。基线**已经**在 **58.75%** 的 pop 上选中了那个最近被释放的 arena(rc 61.23%)。 |
| ② 完全空 arena 释放/退役(+aging) | **已实现,且即刻;加 aging 只会变差** | `releaseEmptyArena` 在归零那次 free 里就归还。75.5% 的 arena 走过这条路。这里没有「还了立刻 re-fault」的问题要治——**block heap 的 aged decommit 教训不适用于 slab arena**,因为归还的对象是 backing 分配器而不是内核。 |
| ③ 收缩候选集(只看链前 K 个) | **空操作** | 分配侧不扫描(§9.3)。K 无论取多少都不改变任何一条指令。 |

⭐ 顺带否掉一个自己冒出来的候选:**backing 页回收 LIFO 化**。审计显示
splay 创建 arena 时命中「最近 64 个被释放的页」只有 **1.87%**,看起来像可捡的
钱。但 `addArena` 的初始化循环(`memory.zig:454-467`)**把整页的块头全写一遍**,
而新 arena 紧接着就被抽干 ⇒ 那些行在 pop 时是刚写过的。审计的
`base reuse unknown(从未被 free 过)= 8.62%` 正是这批,它们**本来就是热的**。

### 9.5 真正的量是复用距离,而且它是双峰的

新增计数器:每次 pop,该块**上一次被 free** 距今多少次 free。

| 复用距离 | rc | trace |
|---|---:|---:|
| ≤ 3 次 free(L1 级交接) | 31.6% | **48.9%** |
| ≤ 512 次 free | **97.0%** | 51.2% |
| 2¹⁷–2²⁰(13 万–100 万次 free) | 0.03% | **43.6%** |
| 众数 | **2⁷(≈128)** | **2¹⁹(≈52 万)** |

⭐⭐⭐ **trace 的 slab 不是「整体更差」,是双峰的:一半比 rc 还热(48.9% vs
31.6% 落在 ≤3),另一半彻底没救(众数差 4,000 倍)。** 冷的那一半就是清扫的
产物——块在第 k 次清扫被释放,要等一整个 GC 周期的分配量才轮到它。

这也解释了为什么第一轮的 LIFO 环读数(trace 46.78% vs rc 33.31%)看起来
「trace 更 LIFO」却仍然慢:**热的那一半确实更热,账全在冷的那一半。**

### 9.6 实测定律:复用距离 ≈ GC 头空间的一半

为了把「它是 GC 频率的函数」从推断变成读数,加了一个诊断旋钮
`ZJS_GC_GROWTH_PERCENT`(trace-only,`gc.growth_percent_override`,与既有的
`ZJS_GC_MIN_THRESHOLD`/`ZJS_GC_HEADROOM` 同一形态;`readStressFromEnv` 首行
就是 `if (comptime !trace_stw_enabled) return;`,rc 下整段 comptime 消失)。
同一个审计二进制扫一遍 splay:

| growth | 活 arena 峰值 | 结束占用率 | **复用距离众数** | 自由链均长 | 等待时长均值 |
|---:|---:|---:|---:|---:|---:|
| 300% | 55,560 | 76.98% | **2²⁰** | 1,679 | 208,959 |
| **175%(现行)** | 32,283 | 64.11% | **2¹⁹** | 2,741 | 297,819 |
| 150% | 27,672 | 76.16% | **2¹⁸** | 2,727 | 251,772 |
| 120% | 22,156 | 85.37% | **2¹⁷** | 1,991 | 129,623 |
| 110% | 20,324 | 96.55% | **2¹⁶** | 1,402 | 69,376 |
| 105% | 19,400 | 98.74% | **2¹⁵** | 953 | 36,059 |

**头空间每减半,复用距离就减半,占用率单调逼近 rc 的 ~100%。** 这条定律说的是:
自由块池 = 「总容量 − 活块」= 清扫一次放出来的量 ≈ 头空间,而分配侧必须走遍它。
⇒ **任何分配策略都动不了它;它是收集器批量回收的时间常数,不是分配器的空间
布局。**(要让它进 L2,头空间得压到 ~1 MiB,即 growth ≈ 101%。)

### 9.7 定价:收紧是灾难,放松反而全面变好

同一个旋钮,审计关闭的 ReleaseFast 二进制,`taskset -c 17`,每点 3 次取中位数:

| growth | 峰值 RSS | 指令 | **cycles** | Δcyc vs 现行 | L2D refill |
|---:|---:|---:|---:|---:|---:|
| 105% | 163 MiB | 78.57 G | 36.34 G | **+288.9%** | 1,508 M |
| 110% | 169 MiB | 54.13 G | 22.27 G | +138.2% | 830 M |
| 120% | 181 MiB | 41.93 G | 15.09 G | +61.5% | 483 M |
| 150% | 219 MiB | 34.55 G | 10.42 G | +11.5% | 261 M |
| **175%(现行)** | **251 MiB** | **32.96 G** | **9.35 G** | — | **214 M** |
| 200% | 283 MiB | 31.89 G | 9.06 G | −3.1% | 184 M |
| 300% | 417 MiB | 31.10 G | 8.39 G | −10.2% | 146 M |
| 500% | 687 MiB | 30.44 G | 8.11 G | −13.2% | 112 M |
| *rc 参照* | *146 MiB* | | | | |

⭐⭐⭐ **这张表关掉了整条轨。** 在 growth 300% 上 slab 的复用距离**变差**
(2¹⁹→2²⁰),而**全机 L2D refill 掉了 32%**。两者同时成立只有一个读法:

> **slab 自由链根本不是 splay 的主导项。** alloc 侧那 9.5M refill 只占 splay
> 全部 214M 的 **4.4%**;主导项是收集器自己遍历活集的访存,它随收集次数走。

第一轮的预取刀(−2.47%)已经把这 4.4% 里能藏的部分藏掉了;**剩下的上限不足
以支撑另一把刀**,而两个重方案(位图 +1.10% raytrace、magazine)在 §3 里已经
用 geomean 否掉过一次。

### 9.8 靶交回包络:growth 200% 单独就越过 splay 停线

既然唯一有效的轴是头空间,就把它按验收仪器定价。**六基准并行、核内 ABBA×4**
(deltablue:15 regexp:16 pdfjs:17 raytrace:18 EB:19 splay:9),零 zig 进程,
六核 idle ≥98%:

| | deltablue | regexp | pdfjs | raytrace | EB | **splay** |
|---|---:|---:|---:|---:|---:|---:|
| **cycles Δ** | −0.07% | +0.11% | −0.04% | −0.23% | −0.15% | **−7.36%** |
| 指令 Δ | −0.01% | +0.01% | −0.05% | −0.01% | −0.03% | −3.31% |
| L2D Δ | −2.97% | +2.30% | −0.80% | −1.38% | −7.58% | −15.74% |
| 臂内极差 | 0.6/0.4% | 3.6/4.4% | 0.6/0.6% | 1.3/0.4% | 1.4/0.8% | 3.1/2.0% |
| **峰值 RSS Δ** | +2.1% | +11.5% | +12.1% | −0.7% | +10.2% | **+12.7%**(251→283 MiB) |

cycles geomean **0.98672**。splay 单独复测 **ABBA×8(n=16)**:
cycles **−7.25%**(臂内极差 2.73%/1.82%)、指令 −3.28%、L2D **−16.02%**——
效应是极差的 2.7 倍。

**兑现量:splay 1.2987 × 0.9275 ≈ 1.205,停线 1.2675,越线 5.4pp**(需求是
−2.4%,这里是 −7.25%)。其余五基准全部落在各自臂内极差里。

**但这不是我的刀,是 owner 的牌**,原因写在现行代码的注释里:growth 175% 被
选中的理由正是「**留在 §1.3 的 cycle peak/live < 1.8 预算内**」
(`src/core/runtime.zig` `resetGCThreshold` 注释)。200% = 2.0x **越过该上限**。
⚠️ 同一段注释同时记着 **JSC 的 `smallHeapGrowthFactor` 就是 2.0**——所以这是
一次「把上限从 1.8 抬到 JSC 的 2.0」的修宪请求,不是一次调参。账本里
every-2 那条「阈值杠杆(+37MB/−4.72% **指令**)」现在有了**验收仪器口径的
读数**:+32 MiB / **−7.25% cycles**。

### 9.9 移交:splay 的 slab 活集是每个数组三笔分配,其中一笔恒为空

§9.2 的 1:1:1 查到了分配点(读实现核对过,不是从尺寸猜的):

| 类 | 来源 | 坐标 |
|---|---|---|
| 3(40 B) | 每个数组的 `property.Entry[2]` 值缓冲——`prop_count == 0` 时**依然分配**,`property.Slot` 16 B × 2 = 32 B | `src/core/object.zig:866`,容量来自 `shape.zig:492` 的 `initial_prop_size = 2` |
| 7(72 B) | 叶子字符串(~46 字符);字符串是 rc 前缀的裸分配,**在 trace 下仍住 slab** | `src/core/string.zig:859` |
| 17(176 B) | 稠密数组元素缓冲,10 × `JSValue` = 160 B(装进 176 B 块,浪费 8 B) | `src/core/object.zig:4655` |

⭐ **class 3 的 263,816 个活块(10.5 MiB)全程是空的**,并且它是 splay
**19.6% 的 slab pop**(4,536,278 / 23,189,957)。删掉它同时砍足迹和 pop 数——
比任何局部性调优都直接。**但本轮不做**,三条理由都要 owner 表态:

1. **不是 arena 粒度**,超出本 lane 授权范围;
2. **`shape.prop_size` 就是缓冲尺寸的合同**(`object.zig` 的注释明说后续具名
   属性追加会信任这 `prop_size` 个槽),所以不能只是「不分配」——要么给数组根
   shape 一个 `prop_size = 0` 的变体,要么把容量与 `prop_size` 解耦;
3. ⚠️ **qjs 付同样的钱**(`JS_NewObjectFromShape` 按 `shape->prop_size` 分配,
   `JS_PROP_INITIAL_SIZE = 2`)⇒ 这是**主动偏离 qjs**,不是补一个 qjs 有我们
   没有的东西;而且**它对 rc 和 trace 一样有效**,不缩小收集器差距,只是因为
   官方读数的参照臂是**冻结二进制**才会让比值变好。这条要不要走,是记分口径
   问题,不该在 GC lane 里悄悄发生。

### 9.10 检查器、注入验证、门禁

新增两条断言 + 一条自校验,**全部在 `zig build test -Dzjs_experimental_gc=trace_stw`
形态下注入验证**(默认 `zig build zjs` 产物 safety 关闭,注入会假通过):

| # | 检查 | 注入的故障 | 结果 |
|---|---|---|---|
| 1 | `growth_percent_override >= 100`(`runtime.zig:3825`) | 新测试里把 300 改成 50 | `panic: reached unreachable code`,栈顶正是该行 |
| 2 | `malloc_gc_threshold >= allocated_bytes`(`runtime.zig:3849`) | `@max(grown, floored) / 2` | 同上,栈顶正是该行 |
| 3 | 审计自校验 `pops − frees == Σ used_blocks` | `if (class != 17) pops += 1;` | 报 `VIOLATION pops-frees=18446744073706512167 != 800574` |

⭐⭐ **第一次注入是失败的,而且是「注入触发了别的守卫」的又一例**:最初拿
`@min(grown, floored) -| 1` 去打断言 2,套件红了 4 个——但红的是既有的
`gc threshold API resets…` 等**值比对测试**,断言本身**没开火**,因为
`floored = allocated + headroom` 恒大于 `allocated`,减 1 后仍然满足断言。
**注入必须真的违反被测命题**,「测试变红了」不是证据。

⭐ 断言 1 所在的 override 臂**套件原本一次都不会执行**(环境变量在测试里不设),
所以补了 `gc growth percent override replaces the compiled tracer growth factor`
(`src/tests/core.zig`)——它同时是旋钮的回归测试和断言 1 的活路径。
写它时踩到一次:`finishGcCycles` 在没有待决周期时不重算阈值,必须先
`forceGC(null)`,否则读到的是初始 `default_gc_threshold = 262144`。

| 门 | 命令 | 结果 |
|---|---|---|
| rc 单测 | `taskset -c 0-14 zig build test` | **2381 passed / 100 skipped / 0 failed** |
| trace 单测 | `taskset -c 0-14 zig build test -Dzjs_experimental_gc=trace_stw` | **2461 passed / 21 skipped / 0 failed** |
| fixed-work 冒烟 | `tools/perf/gate_smoke.sh <cand trace> /tmp/gcgap-fixed 18 3` | **all clean**(6 负载 ×(3 ordinary + 1 arena-audit/stats)) |
| arena 审计 | `ZJS_GC_ARENA_AUDIT=1 <bin> --gc-stats splay.js` / `earley-boyer.js` | exit 0,stderr **零行** |
| trace 性能中立 | 六基准 ABBA×4 | 指令 −0.05%~+0.04%,cycles geomean **1.00031**,全部落在臂内极差内 |

**rc 中立性**(按 §5.1 的三层口径):

- `.text` / `.data` / `.bss` **三段字节数完全相同**(3352660 / 19360 / 80);
- 全二进制指令助记符**总数完全相同**(880,040);逐函数直方图只有两处差异,
  且都在**与改动无关的模块**(`tryRunObjectCycleRemovalWithValueRoots` −1
  `csinv`、`String.destroyFromHeader` +1 `nop`)——§5.1 描述的布局彩票;
- 被改动 call site 所在的三个 slab 函数,地址归一化后**指令流逐条相同**
  (`allocAlignedBytesNoTrigger` 203、`freeAlignedBytes` 74、`addArena` 82);
- 新增的 `pub var growth_percent_override` 与 env 解析都在
  `readStressFromEnv()` 内,该函数首行 `if (comptime !trace_stw_enabled) return;`
  ⇒ rc 下整段被 comptime 消除(`.bss` 未增长即证)。

## 10. 给 driver 的三句话(第一轮:预取刀)

1. **移交时的机理描述错了两次**:trace 的 arena 内顺序比 rc **更**有序,每次
   arena 访问也比 rc **更**长。真病根是 alloc 侧的 **arena 候选集大 565 倍**
   (2,733 vs 4.8)且**几乎不回访**(0.04% vs 16.63%),于是同一条链表在 rc 上
   命中缓存、在 trace 上变成串行冷追逐。
2. **刀是 2 条指令**,splay cycles −2.47%(1.339 → ~1.306)、六基准 cycles
   geomean 0.99394、唯一为正的 raytrace +0.43% 与噪声同量级。**指令口径读不出
   它**(全为正),验收只能用 cycles + refill。
3. **两条口径建议**:①`.text` 逐字节条款要按 §5.1 改写——不确定的不是构建,是
   「新增一个容器级声明」这件事,rc 中立性应改用「指令直方图 + 三段尺寸 +
   逐函数指令流」;②注入验证必须在 `zig build test` 形态下做,默认
   `zig build zjs` 产物的 safety 是关的(§6)。

## 11. 给 driver 的三句话(第二轮:种群治理)

1. **两个「为什么」的答案都否定了移交时的框架。** 种群不是差异——rc 全程持有
   **36,100** 个活 arena,比 trace 的 28,030 **更多**;第一轮读到的「57 vs
   28,062」是 rc 在退出时析构整棵树造成的**拆除时刻假象**。回访率 0.04% 也不是
   病,是「头插 + 只读链头 + 满了才出链」的**直接推论**,而且**分配侧根本不
   扫描**,「有效扫描长度」恒为 1。真正的量是**复用距离**,它是**双峰**的:
   trace 有 48.9% 的 pop 落在 ≤3 次 free 内(比 rc 的 31.6% 还热),另外 43.6%
   落在 13 万–100 万次 free 外(rc 是 0.03%)。
2. **三个被授权的形态全部落空,并且是可证的**:arena 级 LIFO 已经实现,影子
   模拟测出扩展它只改变 splay **0.01%** 的 pop(基线已在 58.75% 的 pop 上选中
   最近被释放的 arena);空 arena 释放已经是**即刻**的(75.5% 的 arena 走过);
   「收缩候选集」是空操作。冷的那一半复用距离**实测 ≈ GC 头空间的一半**
   (头空间每减半,复用距离众数就减半,占用率单调逼近 rc 的 ~100%),
   ⇒ **它是收集器批量回收的时间常数,任何分配策略都动不了。**
   决定性反证:growth 300% 让 slab 复用距离**变差**一档,全机 L2D refill 却
   **掉 32%** ⇒ alloc 侧那 9.5M refill 只占 splay 全部 214M 的 **4.4%**,
   **slab 从来不是主导项**。这条轨到此关闭。
3. **靶交回包络,而且它一把就够。** 唯一有效的轴是 GC 头空间,按验收仪器定价:
   **growth 175%→200%,splay cycles −7.25%(ABBA×8,n=16,极差 2.7 倍)**、
   L2D −16.0%,其余五基准 −0.23%~+0.11% 全在噪声内,cycles geomean 0.9867;
   代价是 splay 峰值 RSS +12.7%(251→283 MiB)。**splay 1.2987 → ≈1.205,
   停线 1.2675,越线 5.4pp**(需求 −2.4%)。⚠️ **这是 owner 的牌不是我的刀**:
   现行 175% 被选中的理由就是「留在 §1.3 的 cycle peak/live < 1.8 内」,200%
   越过该上限——但**同一段注释记着 JSC 的 `smallHeapGrowthFactor` 就是 2.0**。
   这是一次「把上限抬到 JSC 值」的修宪请求。
4. **另一条移交(不在本 lane 授权内)**:splay 的 slab 活集就是每个数组三笔
   分配,其中 **class 3 那 263,816 个块(10.5 MiB、19.6% 的 slab pop)全程是
   空的**——`prop_count == 0` 的数组仍按 `shape.prop_size = 2` 分配值缓冲
   (`object.zig:866`)。⚠️ 但 **qjs 付同样的钱**,且它**对 rc 和 trace 一样
   有效**、不缩小收集器差距,只因官方读数的参照臂是冻结二进制才会让比值变好。
   走不走是记分口径问题,见 §9.9。

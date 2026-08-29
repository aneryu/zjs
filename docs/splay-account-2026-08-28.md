# splay 差距全账(2026-08-28)

## 刷新账(lane-d,主线 c9c66de3 vs frozen-rc bf624dea)

本节取代下面 f660 时代的原账。ReleaseFast trace 二进制来自
`c9c66de3b876d5831ff4bfafef20a211cc9e929b`,与冻结 RC
`/home/aneryu/zjs-frozen/base-g0-2026-08-26/zjs-rc-branchtip-bf624dea`
跑同一份 fixed-work `splay.js`。绝对量为 trace **10.216G cycles /
34.357G insn**,RC **7.267G / 27.480G**；cycles 比 **1.4058**、差
**+2.949G**,IPC 3.363 vs 3.782。相对 f660 原账的 +3.53G,缺口已缩
0.58G,所以旧分项占比不能继续用于排刀。

### 测量合同与负载状态

- CPU 16,PMU `armv8_pmuv3_1`。开录前 `pgrep -c -x zig = 0`、无其他
  `zjs`;两秒 `mpstat` idle=97.00%/98.99%。采集器内 before/after 两次
  CPU 16 平均 idle=96.48%/97.99%。主机只有常驻 moshi/herdr/agent,
  **没有编译或其他基准**。
- 三个固定互质 prime period:200003/262147/330017;每档均按
  trace/RC/RC/trace,共每侧 6 份 flat record。没有 `-F`、没有 call graph、
  0 lost samples。另取一组 ABBA `perf stat`;trace/RC cycles 两次 run spread
  分别 0.356%/0.200%。
- 1710 个规范化符号全量闭合:Zig `__anon_N`/`__struct_N` 去编号、两个 zjs
  DSO 名对齐。`perf_event_paranoid=1` 下未解析但地址落在 AArch64 kernel
  range 的 IP 归入足迹；vDSO offset 依据本机 6.17 `vdso.so` 符号表归一。
  表中绝对周期 = 每符号六份 record 的平均 share × 对应 stat cycles。
- 旁证:trace/RC L2D refill=248.59M/149.24M,backend-memory stall=
  2.655G/1.440G,minor faults=100,936.5/37,430(均 0 major)。编译争用没有
  进入这组 stall/miss 数。

### 分解(互斥分类,绝对周期闭合)

| 成分 | trace | frozen-RC | Δ | 缺口占比 | 攻击方式 |
|---|---:|---:|---:|---:|---|
| 标记 | 1.654G | 0.382G | **+1.272G** | 43.1% | 布局/减少标记对象 |
| 分配/注册/释放机械(shape 路由并入此项) | 2.877G | 1.636G | **+1.240G** | 42.1% | lane-c/e |
| 足迹(kernel-space IP/页错误) | 0.522G | 0.195G | **+0.327G** | 11.1% | lane-f 块粒度热复用 |
| 解释器/写屏障 | 3.734G | 3.448G | **+0.286G** | 9.7% | 宪法成本,只接受机制级削减 |
| 销毁 | 1.231G | 1.405G | **−0.174G** | −5.9% | 已反超 RC,守住 |
| 长尾 | 0.198G | 0.201G | **−0.003G** | −0.1% | 无独立预算 |
| **总计** | **10.216G** | **7.267G** | **+2.949G** | **100%** | 闭合 |

三档 period 的 Δ 范围:标记 1.245--1.317G、机械 1.220--1.253G、足迹
0.312--0.341G、解释器 0.278--0.291G、销毁 −0.181--−0.169G。结论不依赖
单个采样 period。与旧账对照时必须把旧的机械 1.08G + shape 0.16G 合并:
合计同为约 **1.24G,几乎未动**；旧“内核/页错误+极长尾”0.67G 则收到了
足迹 0.327G + 净长尾约零,是本轮 0.58G 缩差的主体。

标记细目:trace 的 `shadeExact` **0.947G**、`traceHeader` **0.641G**;
其余 seed/queue/weak/minor 共约 0.066G。冻结 RC 环收集标记共 0.382G。
因此布局刀兑现后,标记仍是第一大块,且两个指针追逐主符号的绝对量基本仍在。

### lane-e 排水与 lane-c alloc 靶

`drainCycleDeferredFreesBudgeted` 当前为 **0.314G cycles = trace 的 3.07% =
总缺口的 10.64%**;三档 period 为 0.312/0.313/0.316G。冻结 RC 的对应
`drainCycleDeferredFrees` 低于本轮 fixed-period profile 的分辨率。销毁总项仍
净赢 0.174G,但排水本身依然是第三大 trace-only 单符号。

alloc 族按可复查口径拆为:

| alloc 子族 | trace | frozen-RC | Δ |
|---|---:|---:|---:|
| `allocAlignedBytesNoTrigger` | 0.401G | 0.208G | +0.192G |
| `allocInternal*`(含 slow) | 0.462G | 0.280G | +0.182G |
| `createInternal*`(含 slow) | 0.017G | 0.097G | −0.080G |
| `createWithFamInternal*`(含 slow) | 0.075G | 0.088G | −0.013G |
| **纯 allocation front-end 合计** | **0.956G** | **0.674G** | **+0.282G** |

所以 lane-c 的真靶不是泛化的全部 create,而是前两行:**当前 trace 0.863G、
净欠 0.374G**。若沿用旧账“alloc/create/free/destroy 全族”的可比口径,现值为
trace 1.470G、RC 1.036G、Δ **+0.435G**(旧账 +0.61G)。此外仍有纯 trace
登记机械:`serveObjectCells` 0.163G、`addInitialized*` 0.167G、
`removeGcObjectAfter+unlinkObjectWithBytes` 0.161G;它们解释了为什么机械总块
仍有 1.240G。

> ⚠️**上句已被 2026-08-29 职责审计更正**(`docs/registry-role-audit-2026-08-29.md`,
> 分支 `gc/opus-registry-audit`):三项在 c9c66de3 二进制上的实测合计 **0.368G**
> 而非 0.49G,且**其中零元是登记簿成本**。`serveObjectCells` 的 0.163G 是 perf
> 把内联匿名闭包 `gc_cell_alloc_fn`/`gc_cell_free_fn` 的样本记在外层符号名下,
> 该笔已由 `03c73f47`(devirtualize)兑现,当前二进制无此符号——**在案靶子里
> 应划掉**。block-cell 的逐对象登记(占用表 + `gc_obj_list`)在结构上早已退役
> (`alloc_info.standalone` 恒 0 / `!isBlockCellHeader` 门),唯一不可退的逐对象
> 写是 `heap_accounted` 发布位(防半构造对象,即 free-cell impersonation 缺陷类)。
> `removeGcObjectAfter` 的 ~55% 实为分代 remembered-owner 哈希删除(连同 Wyhash
> 等 ≈0.11G,为最终仅 590 项的集合),`forget` 侧未用 `trace_remembered_mask`
> 缓存位——归 lane-a/b 屏障 bit 契约领地。`addInitializedWithSizeNoFail` 40.76%
> 自身周期在 `heap_accounted` 写回后的重读(编译器别名保守),已定位待安静窗口
> cycles 定价。

### 长尾前 12 名(按 |Δ|,M cycles)

长尾净值接近零,因为正负抵消;不能只列正向样本。这里的 clock vDSO offset 已按
本机符号表合并。

| # | 符号 | trace | frozen-RC | Δ |
|---:|---|---:|---:|---:|
| 1 | `compiler_rt.memcpy.memcpyFast` | 64.813 | 106.533 | −41.719 |
| 2 | `[vdso] clock_gettime` | 36.104 | 0.251 | +35.853 |
| 3 | `compiler_rt.memset` | 6.308 | 1.062 | +5.246 |
| 4 | `libs.number_format.mpbShrRound` | 18.170 | 20.991 | −2.821 |
| 5 | `libs.number_format.outputDigits` | 7.611 | 8.543 | −0.931 |
| 6 | `zjs_cmp_neq_mixed` | 1.330 | 0.535 | +0.795 |
| 7 | `libs.number_format.jsDtoaImpl` | 16.879 | 16.312 | +0.567 |
| 8 | `FunctionBytecodeImpl.realmContextSlow` | 6.221 | 6.737 | −0.516 |
| 9 | `zjs_cmp_eq_mixed` | 2.640 | 2.220 | +0.420 |
| 10 | `clock_gettime@plt` | 0.446 | 0.043 | +0.403 |
| 11 | `libc clock_gettime` | 0.631 | 0.338 | +0.293 |
| 12 | `heap.c_allocator_impl.alloc` | 0.000 | 0.274 | −0.274 |

## 历史原账(driver 实测,主线 f660c2a5;仅供变化对照)

当时官方口径:splay trace/rc = 1.537(同源 rc 口径 1.567)。绝对量:trace
10.65G cycles / 34.62G insn,rc 7.12G / 27.13G,差距 +3.53G cycles。
旧分类为:标记 +1.34G、机械 +1.08G、内核/页错误/极长尾 +0.67G、解释器
+0.27G、shape +0.16G、销毁 −0.14G。**这些占比已经作废**,只保留作纵向对照。

## 本轮已证死的方向(不要再走)

- 自适应 minor:ZJS_GC_NO_MINOR 验活后两臂持平,历史 21% 已消失。
- 阈值下限臂:splay 58 次重置仅 4 次走下限。
- 「少收集就快」:major 29→16 省 7%,29→3 反而恶化(live 71→143MB,RSS 1.69GB)。
  调度调优上限 ≈ −7%。
- 保守扫描:splay 上仅 0.02G。
- 预取(批量真弹出/窥探 top-k 双路)。

## 有用的既有测量

- 标记触碰 1.08 亿 cache line/run:对象本体 38.6M、**shape 33.2M(31%)**、
  属性槽 16.6M(15%)、元素 19.4M。
- 内联槽 census:splay 普通对象 98.4% 两槽即够,但节点是**构造器分配**,
  已落地的 object_slots2 只覆盖字面量。
- 页错误差 ≈ committed 318MB(152 个 superblock)首触;rc RSS 154MB。
- 到 1.18 需 −2.25G:机械 −0.8、足迹 −0.4、标记 −1.0、杂项 −0.05。

## lane-f:152 个 superblock 的拓扑实账

`--gc-stats` 的冷路径 census 在 fixed-work splay 上把 304 MiB 拆成:

| 项 | 实测 |
|---|---:|
| classed superblocks | 152 |
| 历史打开的 64 KiB blocks | 4,843 |
| 当前非空 / 其中 partially-full | 4,013 / 3,817 |
| 当前完全空 blocks | 830 |
| cell live | 84,444,528 B |
| 非空 block cell capacity | 261,382,368 B |
| 非空 block 内未用 | 176,937,840 B (168.7 MiB) |
| 完全空 block capacity | 54,064,848 B (51.6 MiB) |

结束前的 final-tree 复测在保守根差异下轻微漂到 4,841 initialized /
4,009 nonempty / 3,813 partially-full / 832 empty，但仍是 152 个
superblock；下面的密排分解与结论不变。

两个活跃 class 是 80 B 与 112 B。按各自 block geometry 把当前 live cells
理想密排只需 357 + 940 = 1,297 blocks,即 41 个 superblock。实际 152 可近似
写成 **41 dense + 85 partially-full 空洞 + 26 wholly-empty 高水位**。因此主体
不是 superblock 获取器一次多拿 2 MiB,而是已经知道的顺序 bump 策略:它拒绝
回到仍非空 block 的洞里。历史 partially-free 复用把这块压掉但全基准变慢,
所以这 85 个 superblock 等价量是经裁决保留的局部性成本,不能再次当普通碎片
修复。

完全空 block 跨 class 重置也做过可证伪实现:同 class 仍优先,只在目标 class
无空块时借另一个 class 的 wholly-empty block。splay 有 230 次跨 class 命中,
但历史打开 block 仍约 4,839、superblock 仍为 152;80/112 两类只是来回借块,
没有降低同时高水位。实现已撤回。

aging 不应加强。splay 22 次 100ms 周期检查只释放并重新 fault 13--16 个 block,
结束时约 830 个空 block 尚未满 1 秒或已复用;结束后 decommit 不能撤销本轮已经
发生的首触。EB 在现有 1 秒规则下仍是 124 次 decommit / 119 次 recommit,
最终只留下 5 个 decommitted block,正是缩短 aging 会放大 refault 的护栏证据。

THP 原型只对 classed heap 已超过 32 个 superblock(64 MiB)后的新 mapping 做
2 MiB 对齐与 `MADV_HUGEPAGE`,所以 EB 的 13 个 superblock 不进入该路径。主机
是 THP=`madvise`,defrag=`madvise`。内存连续时它确实形成约 228 MiB THP,
把 splay minor faults 从 143.0--143.3K 降到 82.2--87.9K,wall 从
2.86--2.97s 降到 2.74--2.81s。但同一主机稍后碎片化时只形成 38 MiB THP:
19 次 huge fault 成功、101 次 fallback、328 次 compaction stall;faults 只能降到
105--107K,sys time 上升且 wall 无收益。仅做 2 MiB 对齐、不 advice 时 faults
回到 143.6--143.8K。收益依赖瞬时物理连续性,而 `madvise` 模式会同步 compact,
不能作为默认引擎策略。THP 原型已撤回;若部署方能保证显式 huge-page pool,
可作为 host allocator policy 另行评估,不应混进通用 block heap。

结论:本轮没有满足“稳定降低 faults 且 EB 不回归”的默认优化。保留的代码只有
`--gc-stats` 冷路径拓扑 census;它把 152 的责任归到已裁决的 partial-block
局部性策略,并把 THP 的条件性收益/compaction 风险量清楚。

## 纪律

- 编译 `taskset -c 0-14`;测量找空闲大核(先 `mpstat -P 15,16,17,18,19 1 2` 挑 idle>95%)。
- 持续筛选用指令数(perf 匹配 `pmuv3_1/instructions`);cycles 裁决等 driver 安静窗口。
- 取舍:splay 收益显著时,其余五基准容忍到 −0.3%。
- **完成或有阶段性结论时,执行 `herdr agent prompt driver "<lane-x> <结论摘要>"` 回传。**
- 改共享代码(rc 也会跑到的)必须显式说明并默认 trace 门控——review R1 的教训。

## 裁决更新:sticky major 定价完成,旗舰杠杆降级(lane-a,2026-08-28)

lane-a 实测 28 个 major 间隔:sticky(根+全脏)仍需展开 full 的 68.9%(稳态
72.9%)。**我原先「静止树被重复标记 29 次」的前提错了**——拓扑稳定,但 payload
身份换血:每间隔约 553K **新可达** header 顶替旧 payload,这是首次标记、不可免。
浮动垃圾定价:跳一次 full 留任 ~105MB 全账字节;every-2 = +105MB peak 换 ~0.25G;
无限 sticky 理论上限也只有 0.50G。**P/T < 36/35 管不住它**(浮动垃圾进入下一轮 S
同步抬高 T,棘轮效应)——阈值必须基于上次 full 的 S 独立计算。

**裁决**:
- 通用 sticky major **NO-GO 批准**,「拿掉 1.0G+」的旗舰定位作废。
- **full-every-2 实验臂 conditional GO**:trace 门控 + 独立 full-pressure 阈值 +
  fresh-trace shadow oracle 三前提齐备才准写码;产出是定价(splay/EB wall、
  peak、committed),**是否采纳 +105MB 换 0.25G 归 owner 裁**。
- 战役算术诚实更新:标记块的现实回收量从 −1.0G 下调为 **−0.5~0.66G**(布局 ×
  every-2 复合)。四块合计落点 splay ≈ **1.23~1.28**,geomean ≈ **1.06**——
  **按当前手牌差 1pp 达不到 margin 1.05**,缺口须由机械/足迹超额交付或新发现补上。

## 裁决更新:足迹块(19%)以否定结果关闭(lane-f,b4f048b7)

152 个 splay superblock 冷 census 拆解:~41 密排 live、~85 等价量是 3,813 个
半满 block 的**顺序 bump 局部性成本**(结构性取舍——破坏 bump 顺序历史 3/3 全亏,
不可动)、26 个空块高水位。三个原型全部按验收线撤回:跨 class 空块复用命中 230
次但 SB 数不降;缩 aging 会放大 EB(现规则已 124 decommit/119 recommit);
**THP 物理连续时 faults 143K→82-88K、wall +4~5%,但碎片态 101 次 fallback +
328 次 compaction stall 且 wall 零收益**——依赖系统碎片状态的收益不能做默认。
唯一合入物:--gc-stats 冷拓扑 census。

**足迹块从预算中移除(原 −0.3~0.4G → 0)。** THP 的 4-5% 记为「环境依赖机会」
存档,不计入路径。

## 战役算术第二次下调

三次定价两次落空(sticky 1.0→0.25G、足迹 0.35→0):当前手牌落点
splay ≈ **1.29~1.33**,geomean ≈ **1.065~1.07,距 margin 1.05 约 1.5~2pp**。
剩余希望集中在:机械块 −0.8(lane-c/e 在途,纯刀工)、标记布局(lane-b shape
摘要在途;lane-d 内联槽 splay 上零命中退回调试中)、every-2 实验臂 0.25G(待价)。

## 裁决更新:内联槽杠杆在 splay 上已耗尽,15% 预算是仪器幻影(lane-d 分类账)

lane-d 的 splay 分类账严格闭合(16,561,404 次 object trace):payload 叶
{array,string} 551.8 万 + payload 枝 {left,right} 534.5 万 = **98.42% 的普通对象,
且全部已经 direct-inline**——字面量 object_slots2 实际命中率 **99.996%**。
Node 终态 4 槽但只占 17.2 万次 trace。真正的外挂属性存储只剩 **13,920 字节/667 条线**。

**三个纠正**:
1. **driver 误判认账**:上一轮我依据旧 census 判「机制未生效、字面量刀可能也没生效」
   ——census 是坏的(把所有 ≤N 候选含 direct-tail 一律打成 external;property_slots
   统计的是值槽触碰,内联后本来就不降)。**仪器说谎,不是机制没生效。**
2. **标记预算修正**:我此前把 property_slots 的 16.6M 触碰线当作「可认领的 15%」
   ——幻影。该行与 base 行在内联后重叠,108M 线的分项存在重复计数。
3. **构造器刀撤回正确**:splay 主导路径 small_inline.tryFusedConstructor 绕过
   profiled allocator,旧刀只命中 74 个且随后长到 4 槽;硬塞 Reserved2 会留 32B
   尾巴再另开 64B 外挂——净亏,撤回成立。

**结论:内联槽这条线在 splay 上到顶了(早已由字面量刀兑现)。** 标记块剩余杠杆
只有:every-2 实验臂(0.25G,lane-a)、per-object 基础成本(lane-b 系列)。

## 流程教训:合并 commit = 合并其全部祖先(2026-08-28)

合 c9081cde(shape 摘要刀)时,其祖先——整个 compact-header 系列(901b1dc8..daba664d,
72→64 字节 + repricing,即我此前裁「再来一轮」的那把刀)——一并进入主线。
测量是二进制级的所以裁决数字有效(+1.36/+1.82/−0.84 是**复合**效应),但归因
记账错把它全记给了摘要刀。**此后合并前必须 `git log trunk..candidate` 审清全部载荷。**

## 官方读数更新(主线 31f5460b,四门全绿,rc-spread 0.2-2.8%)

| | deltablue | regexp | pdfjs | raytrace | EB | splay | geomean |
|---|---:|---:|---:|---:|---:|---:|---:|
| 前次(d036cd7d) | 0.967 | 1.026 | 1.019 | 1.056 | 1.064 | 1.537 | 1.0973 |
| **本次** | 0.967 | **0.999** | **1.004** | 1.065 | **1.028** | **1.453** | **1.0751** |

历史轨迹:1.206 → 1.190 → 1.153 → 1.142 → 1.131 → 1.112 → 1.0973 → **1.0751**。
margin 1.05 还差 **2.5pp**。本批贡献:机械刀(lane-e 释放侧)+ shape 摘要/compact
header 复合(lane-b)+ census 修复(lane-d)。regexp/pdfjs 已实质持平,EB 只剩
2.8pp,**五个非 splay 基准 geomean 降到 1.0121 ⇒ splay 的达标线从 1.18 放宽到
1.262**(现 1.453,还需 −13.2%)。

raytrace 1.056→1.065:shape 刀复合成本 −0.9pp 未被 cbe1d944 完全收回,债保留。

在途杠杆:屏障 bit7(lane-a/b 直连协作中,已互抓两个 soundness 洞并收敛到
「marker 恒 &0x7f」的最小契约 + bit⇒map coherence 检查器)、every-2 臂定价、
**lane-c 分配侧机械(最大未收项)**、raytrace 债。

## 解释修正 + 足迹块重开(owner 质询驱动,2026-08-28)

owner 质询「你的劣化解释不对,V8/JSC/Hermes 为什么反而快」成立。修正:
**「tracing 本质税」框架作废**。三大引擎全是 tracing;tracing 对 rc 有两笔结构性
红利——①分配近零且落在热内存(V8/Hermes copying nursery 原地复用;JSC 非移动但
`MarkedBlock::sweep(FreeList*)` SweepToFreeList + LocalAllocator interval bump,
**刚扫完的热块立刻回到分配器**);②死对象免费(copying 不触碰尸体;rc 必须逐尸
dec+析构)。我们收全了 tracing 的账单(冷图标记/冷足迹/屏障),红利一笔没拿:
每分配带钩子+登记、一直 bump 进全新块、doomed 逐尸排水。

**据此重开足迹块**:此前以「破坏 bump 顺序 3/3 全亏」关闭——误伤。那三败是
逐 cell 混回 bump 流;JSC 是**块粒度**复用,块内仍顺序 bump。该模型与非移动+
保守栈扫描完全兼容(JSC 同样不移动;copying 被保守扫描+FNABI 钉住排除)。
新方向:**sweep-to-freelist 热块复用**,同时攻击足迹(0.67G)与分配机械残余。

## 记账:offset6 租约 34d93b8f 已合入(175016b5),独立成本挂账 lane-a

租约中性筛:splay −0.22%/EB −0.16%/raytrace −0.07%(marker 每对象一次 &0x7f,
与预期吻合)。**这笔小额指令成本是给 lane-a 屏障 bit 的预付款**:验收口径为
「租约+屏障 bit」合并后净收益,若屏障 bit 不成,租约单独回退。

## 战役算术第三版(lane-d 新符号账 1a219208,采样零丢失)

splay 现状:trace 10.216G / rc 7.267G,Δ2.949G,cycle ratio 1.4058。
分类:**标记 +1.272G(43.1%)与机械 +1.240G(42.1%)并驾**、足迹 +0.327G、
解释器 +0.286G、销毁 −0.174G(反超扩大)、长尾 ≈0(账已闭合)。

**达标算术**:splay 达标线 1.262 ⇒ trace 需 ≤9.171G ⇒ 还需 **−1.045G**。
在案靶子:alloc 族净欠 0.374G(lane-c,cycles 待裁)+ drainCycle 0.314G(结构性
指针追逐,部分可与热块复用协同)+ 足迹 0.327G(lane-f 代谢环)+ every-2 0.25G
(lane-a,待价)+ 屏障 bit ~0.1G(lane-a)≈ **1.37G 靶量对 1.045G 缺口**——
需兑现约 76%。紧,但第一次出现靶量明确大于缺口的局面。

## 裁决:代谢环 K=64 版合入(73e17bba → b2aa8dfc)

三轮定价史:全开版(10% 准入)机制全胜但 cycles 负(splay −0.96/EB −1.61,病根
=冷复用+碎 interval);K=64+10% 粗滤后 **splay +0.62/raytrace +0.82/EB −0.47**,
净 geomean ≈+0.16%,足迹保留 94-95%(faults 100.9K→63.5K,committed 275.7→125.8MB,
committed/live 1.88x)。**EB −0.47% 挂账给 d+f 联合设计**(排水按块聚簇+排完即热
发布+openBlock 惰性重建——lane-d 已发现现有全局 LIFO 天然保持 block run,
Pass A 按块升序 push、reverse 后同块仍连续,故无需 per-entry block 指针,
边界触发发布即可,设计成本再降)。

## 诊断:官方读数 1.0751→1.084 的回归拆解(串行模式首轮,2026-08-28)

三臂同会话配对(prev=31f5460b 的记录值当日复现,**场未漂,回归为真**):
regexp now/prev 1.0318、EB 1.0185、splay 0.9855(改善)、其余 ≈平。

**指令阶梯全平**(regexp ±0.05%、EB 终点 +0.04%)⇒ 回归全在 stall 侧。
cycles/L1I/iTLB 阶梯拆出两种性质:

1. **regexp = 布局彩票**:cycles 沿阶梯非单调(+1.5→+4.7→+2.6→+4.1%),
   iTLB refill 摆动 +5354%→−46%,与合并内容无关——纯代码布局/iTLB 伪影,
   会随任何改动再洗牌。**记为 regexp 的测量带(±3~4%),不是机制债。**
   后续若要治本:审查新 GC 代码的 linksection,冷代码不得插进热解释器文本段。
2. **EB = K=64 冷复用的真实成本**:该步 l2d refill +8.2% 且此后稳定;
   定价窗当时读到的 −0.47% 偏乐观。K=128 试探(EB +0.15%)证明债不在
   interval 大小而在「复用即冷」——修复归 lane-d 在途的排完即热排水。

**测量方法更新**:官方读数改为跨基准并行(各基准独占一颗空闲大核、核内 ABBA),
单轮 ~7 分钟(原 ~18);配对语义不变,rc-spread 护栏保留(本轮即拦下两行污染)。

## 裁决:尸体 census 定价(2026-08-29,`docs/corpse-census-2026-08-29.md`)

排水独立复现 0.310G/3.00%(设计账 0.314G);**L2D refill 1.13 次/尸体**——
hot-reuse 设计 §2.3 的两情景未决项闭合,现实落在「每尸一条冷线」之上。

- **stage-2(免 per-cell link)单独立项 NO-GO**:≤0.04G——free link 写
  `cell[0..4]` 与排水读 `h.next`(`cell[8..]`)同一条 64B line,零 refill 收益;
  splay 上 95.6% 的 link 写是死存储(写进 interval 块,`rebuildFreeIntervals`
  直接丢弃),应作为 stage-3 的内含结果消失。
- **stage-3(尸体跳过 park)GO,可认领 0.25–0.31G**(缺口的 8.5–10.5%),但须
  改述为**「Pass A 分类、只 park 例外」**——判定要读 class_id/weak 状态,Pass A
  刚跑完 `destroyFromHeader` 线是热的,Pass B 再判正好抵消要省的 miss。
  三负载 weak husk/weak id/inline payload 全 0;`runs_mixed_fam` 全 0(观测非
  不变量,实现须加检查器);复用 remember 位图当结算掩码会改 `hasPendingDoomed`
  语义,需独立位图字。
- **前置小刀:trace 快臂从 `class_id==1` 放宽到「标准 class 且无 inline
  payload」**——自身收益≈0 但它是 stage-3 的分母:raytrace 96.8% 尸体 trivial
  却 0 段整 run 干净(3.1% mapped_arguments 每 32 条夹一条),放宽后
  可位图结算 run 升到 98.48%/99.93%(splay)/97.25%(EB)。
- **EB 硬上限**:42.9% parked 全是 var_ref(generic prefix),两个 stage 都
  碰不到;EB 的 Pass-B 全族只占 1.59% cyc——EB 的靶不在这条线。
- 登记机械 0.49G 靶子作废(见上方更正注记);`forget` 侧 remembered-owner
  哈希 ≈0.11G 移交 lane-a/b 屏障 bit 契约。
- 设计文档滞后已记:§3.1 block-suffix 模式在 4c621491 已实现
  (`object_gc.zig` 的 `onBlockPassBComplete` 调用点,census 合并后位于 :720;
  第二发布点 `publishCompletedHotBlocks` 在 `gc_trace_stw.zig:1472/2282`)。

### stage-3 已落地(合并 3d0bf071;机制详录 corpse-census §9)

- **形状偏离经审同意**:Pass A 分类**并就地结算**(非「Pass B 按块位图」)——
  结算走的是 Pass A 已热的块头 cache line;发布次序不破(两个发布点一字未动,
  K=64 代谢环实测未退化,EB hot published 反 +2.1%);FAM 前提整条消解
  (逐尸读自己的 trailing,块内混 FAM 不进入正确性,原「第 11 条 checker」不需要)。
- **排水几乎消失**:splay 排水调用 2,780→37、预算截断 2,743→**0**;
  指令数 splay **−1.314%** / EB −0.584% / raytrace −0.403%(交错三轮,远超臂内
  极差)。stage-2 的 95.6% 死存储作为内含结果不再发生。cycles 待安静窗口。
- ⭐**连带效应待裁**:Pass B 近乎消失 ⇒ lane-d「排完即热排水」设计的前提可能
  已消解;EB 冷复用债(K=64 那 −0.47%)须在安静窗口重测后再决定是否还立项。
- 剩余否决(按量排序):allocator-current 块(EB 1.3%,前置=lane-f 的私有块
  活空闲表示)、会清空块的那一具尸体留 park(前置=事务感知的空块转换)、
  注入 4 覆盖缺口(套件无「动态 id block-cell 尸体死于 tracer_destroy」用例)。
- rc `.text`:**指令等价+尺寸相同,非逐字节**(`.rodata` 619 字节差全在
  `__anon_N` 类型名字符串,与 census §1.2 同类;首版曾把计数器挂错
  `gc_concurrent.Stats` 造成 rc 真实位移,已改挂 `block_heap.Stats`——
  「trace-only 的判据是谁**分析**它,不是谁用它」)。

### 分配前端结案:0.374G 重新归类(合并自 gc/opus-allocfront;详录 docs/alloc-front-2026-08-29.md)

- ⭐⭐⭐**靶的性质判错了**:trace 与 rc 在 `allocAlignedBytesNoTrigger`/
  `allocInternal` 走**同一份代码**,逐指令差只有两条 `noteCyclePeak` 和一处重复
  分类。差距在访存:alloc 侧 L2D refill trace ≈9.5M vs rc ≈0.15M(**六十倍**),
  自身周期 80.4% 落在 slab 自由链表弹出链上。机理=rc 的 slab 是完美 LIFO 交接
  (free 付 miss、alloc 全命中),tracing 的批量释放把自由链打散跨 arena 游走。
  **这是 SweepToFreeList 红利在 slab(非 GC 载荷)上的缺口。**
- **账本动作**:「机械」块的这 0.374G 移入「足迹/局部性」,与热块复用线合并;
  真刀=slab 自由链表的块粒度复用(lane-f 线,未立项)。
- 两把小刀已合入:K1(`addInitialized` 写后重读收敛,profile 份额 1.66%→0.88%,
  指令持平 ⇒ **cycles-only 验收,待安静窗口**)、K2(slab 分类去重,splay 指令
  −0.43%)。未做候选清单(栈帧/溢出类=预期 cycles 零)在 alloc-front 文档。
- ⭐⭐⭐**测量合同修订:rc `.text` 逐字节条款在本机并发构建下不成立**——同一份
  未改动源码连续两次 rc ReleaseFast 构建给出不同 `.text`(符号尺寸表差 723 行,
  全在无关模块;6 个并发 zig 共享 global cache)。**「相同」仍证明零改动;
  「不同」不再证明有改动**。替代口径=逐函数地址归一化指令流比对。
  (forget 刀独立复现:差 680 字节,全在 compiler.resolve_variables.* 等无关
  符号;其判据改为「候选构建两次都复现 base 的 sha」并成功。)

### forget 侧 bit7 跳过:授权的刀打空,天花板重定价(合并自 gc/opus-forgetskip;详录 registry-role-audit §9)

- ⭐⭐⭐**`.object` 门是死代码**:block cell 对象由位图清扫回收**不走**
  `removeGcObjectAfter`;走 forget 的全是 list 载体 `.shape`(splay 100%)/
  `.var_ref`(EB 7,358 万),它们按 I1 从不置位 ⇒ 跳过执行 0 次,指令 A/B
  三负载全在极差内。§5.1 的 0.11G 没有一分是 `.object` 付的——**审计把 I1
  当约束,实际它是让刀落空的那个可改选择**。
- **天花板定价成立**(不 sound 实验构建,forget 完全不删表):splay 指令
  **−1.11%**/EB −0.57%/raytrace −0.32%,效应是极差的 5–11 倍。线还在,门开错。
- **开对门的四处硬阻塞已查明**(未实现):①`.big_int` 必须排除——trace_stw 下
  唯有它仍用 LifetimeWord.rc,byte6 与 i32 第 3 字节**灾难性别名**,置 bit7 =
  rc += 0x800000;门须写 `!= .big_int`;②三处「非 object ⇒ byte6==0」现役
  检查器;③两个双向审计器的 kind 门须同步扩;④`clearGenerationalRememberedBits`
  的 kind 门。**前置=一份 byte6 所有权重划分的新 soundness 审计**(§8 授权限定
  `.object`,不覆盖此扩展)。
- **已合入的地基**:融合一步(读位/删表/清位同函数体,§8.1 陷阱在实现层不可写出)、
  I3 升格为 `retirement_window_open` 机器闩、I4 husk 前断言、每次 detach 的 I0
  断言、新回归测试。四条注入全开火;**套件原本没有任何用例会 detach 一个被记住
  的 owner**(旧顺序注入在改测试前 2457/0 全绿)——新测试补上了这个盲区。

## 官方读数(2026-08-29 安静窗口,主线 4cbb5431)

命令:`.scratch/official_paired.sh /tmp/final-trace-bin(4cbb5431 trace ReleaseFast)
/home/aneryu/zjs-frozen/base-g0-2026-08-26/zjs-rc-branchtip-bf624dea /tmp/gcgap-fixed 5
15:deltablue 16:regexp 17:pdfjs 18:raytrace 19:earley-boyer 9:splay`;
跨基准并行、核内 ABBA×5 对、零 zig 进程、六核 idle≥99%。

| | deltablue | regexp | pdfjs | raytrace | EB | splay | geomean |
|---|---:|---:|---:|---:|---:|---:|---:|
| 前次(31f5460b) | 0.967 | 0.999 | 1.004 | 1.065 | 1.028 | 1.453 | 1.0751 |
| **本次** | 0.960 | 1.028 | 1.000 | 1.045 | 1.035 | **1.339** | **1.0614** |
| rc-spread | 1.1% | 3.6% | 0.6% | 1.1% | 1.3% | 1.0% | — |

轨迹:1.206→1.190→1.153→1.142→1.131→1.112→1.0973→1.0751→**1.0614**。
**splay 单轮 −7.8% = stage-3 兑现**(排水消失 + K1/K2 复合)。regexp 1.028 在其
±3~4% 布局彩票带内。非 splay 五基准 geomean **1.0131** ⇒ splay 达标线收紧为
**≤1.256**,现距 **−6.2%**;margin 1.05 距 **1.1pp**。

在案剩余靶(按量):slab 自由链表块粒度复用(重归类的 0.374G+足迹协同)、
every-2 实验臂(0.25G,conditional GO 待定价)、forget 天花板(splay 指令
−1.11%,前置 byte6 所有权审计)、EB 冷复用债重测。

### byte6 修正门已落地(合并自 gc/opus-byte6;审计=registry-role-audit §10)

- **门的正确形态不是 `!= .big_int`**:审计发现 `.string` 是第二颗地雷(无 Metadata
  前缀,`meta().lifetime` 越界)。放行集=RefKind 0..5 六个 list 载体
  (= cycle_candidate 集 = gc_obj_list 载体集 = 能到达 remember/forget 两端的
  全集),`traceRememberedCacheEligible` 一次无符号比较,comptime 断言钉死三重
  重合 ⇒ 两个排除项**不可达**而非「禁止」。落刀全量六 kind 无收缩。
- 阻塞实为**五处**(第五处 `forgetUnremembered` 自身断言靠测试炸出);
  §8.4 的整字节写实为**五处**非三处(grep 字段名会漏结构体整存/TLS 字面量——
  「证明没有别的写者不能搜字段名,必须搜每种表达式形态」)。
- 指令数:splay **−0.98%**(同基线天花板 −1.18% 的 83%,余 17%=读位成本)、
  EB −0.72%、raytrace −0.66%。⭐⭐**天花板必须同基线重测**:raytrace 这条线在
  23c65ef8 上 −0.32%、f4ea32f1 上 −0.67%——跨基线对比会读出 206% 的不可能值,
  「跨会话对比不可做刀级归因」的换装重现。
- rc `.text` 候选两次构建均复现 base sha(base 自身两次构建不同=非确定性再证)。
- 移交项:`module.Registry.prepareFreshTarget` 先 remember 后 publish 的既有
  异常(young==false 被判 old owner 入表),放开门后被断言抓到,本轮不动 module。

### every-2 实验臂:定价完成,**臂被阈值调整严格支配,建议不采纳**(gc/opus-every2;详录 every2-arm 文档)

- 三前提齐备后定价(splay 六样本 ABBA,spread 0.16–0.38%):臂开 **−3.60% 指令
  / peak +161MB**;而**纯阈值**在同 +161MB 拿 **−6.37%**,在仅 +37MB 拿 −4.72%。
  splay 上臂无存在理由;EB 上臂未被支配但效应无裁决力(spread 3 倍)。
- 正确性彻底:6,739 sticky 轮 precise 违例 0;注入(跳 1 remembered owner)
  503 例开火;⭐**加「关臂全 full」对照才把绿臂那 1 例 conservative-only 定为
  仪器噪声**(全 full 反而报更多)——没有零机制对照,「1」读不出是缺陷还是噪声。
- 独立 full-pressure 阈值被证实承力:12 次 full 里 10 次由它强制(棘轮是真的)。
- **算术更新**:0.25G 线划掉,替换为「阈值杠杆」——内存换速度、与 §1.3 包络
  冲突,**是否动用归 owner**(+37MB/−4.72% 的低配点是最有性价比的档)。
- ⭐方法学:zsh 未加引号的参数展开不分词,`env $ev cmd` 会把「对照臂」跑成
  开臂——对照臂读数反了一轮,Python dict 传 env 重跑后定案。

### slab 冷链结案:机理是种群不是打散;预取刀落地(gc/opus-slabreuse;详录 slab-reuse 文档)

- ⭐⭐⭐**移交假设被仪表推翻两次**:trace 的 slab 自由链比 rc **更**有序
  (漂移 124B vs 354B)、**更** LIFO(46.8% vs 33.3%)、连弹更长(47 vs 26)。
  真机理=**候选 arena 集大 565 倍**(每类自由链长 2,733 vs 4.84;活 arena
  28,062 vs 57)且回访率 0.04% vs 16.6%——串行冷相关载入,不是碎片化。
  raytrace 在 trace 下形态与 rc 一致(没病),分型决定形态选择。
- **落地=弹出时预取自由链下一跳 block header**(trace 门控,4 条生成码);
  两个重方案(arena 位图/per-class magazine)实现并量过,geomean 输,否决。
  ⭐**预取未映射哨兵地址让 EB 慢 12.6%**——预取被丢弃但页表遍历不被丢弃。
- **安静窗口 cycles**:splay **−2.47%** / geomean **0.994**,L2D refill splay
  −2.36%、raytrace −7.69%;**指令口径全为正(+0.3%)读不出这把刀**=
  「布局刀增指令不等于变坏」的又一实证。splay 预计 1.339→≈1.306。
- ⭐⭐**真正的结构项浮出**:28,062 个活 arena 是 GC 频率/增长因子的函数,
  属包络线(§1.3/lane-f)的地——**slab 种群治理是剩余 splay 差距与足迹的
  同根靶**,未立项。
- ⭐⭐**口径修正**:.text 非确定的成因是「新增容器级声明改匿名符号编号」,
  无并发 zig 时纯注释改动可复现 sha ⇒ rc 中立性以「指令直方图+三段尺寸+
  逐函数指令流」为准;**注入验证必须在 `zig build test` 形态**(默认 zjs
  产物 safety 关闭,注入会假「通过」)。

## 官方读数第二轮(2026-08-29 安静窗口,主线 8f7934ea 同码二进制)

同协议同命令(binary=/tmp/srmerge-trace-bin)。

| | deltablue | regexp | pdfjs | raytrace | EB | splay | geomean |
|---|---:|---:|---:|---:|---:|---:|---:|
| 第一轮 | 0.960 | 1.028 | 1.000 | 1.045 | 1.035 | 1.339 | 1.0614 |
| **第二轮** | 0.967 | 1.013 | 1.003 | 1.044 | 1.031 | **1.2987** | **1.0543** |
| rc-spread | 2.4% | 4.1% | 0.7% | 1.7% | 0.8% | 0.9% | — |

轨迹:…→1.0751→1.0614→**1.0543**,距 margin 1.05 **0.43pp**。splay −3.0% =
slab 预取(−2.47% 实测)+byte6 兑现的复合。非 splay 五基准 geomean 1.0112 ⇒
**splay 达标线 1.2675,现 1.2987,还差 −2.4%**。

收官选项:①**slab 种群治理**(28,062 活 arena=冷链与 brk 足迹同根,最后一把
有机刀,已派);②**阈值杠杆**(+37MB/splay −4.72% insn,与 §1.3 冲突,owner 牌);
③regexp 在 ±3~4% 彩票带内,读数波动可能单独造成 ±0.3pp geomean。

## 官方读数第三轮:growth 2.0 采纳后,**margin 1.05 达成**(2026-08-29)

slab 种群刀证伪关闭有机轴后(28k vs 57 是拆除时刻假象、rc 实持 36k;复用
距离=GC 头空间的一半=收集器时间常数;growth 300% 反证 slab 仅占 refill 4.4%),
owner 裁决**采纳 growth 2.0**(§1.3 上限 1.8→2.0 重新谈判完成,JSC
smallHeapGrowthFactor 同值;此前否决的 2.5x 经济学不同——当时买 1/3 差距
付 RSS 4.6x,现在一步收全部剩余缺口付 +10~13%)。

同协议(binary=/tmp/g2-trace-bin,raytrace 移核 5):

| | deltablue | regexp | pdfjs | raytrace | EB | splay | geomean |
|---|---:|---:|---:|---:|---:|---:|---:|
| 第二轮 | 0.967 | 1.013 | 1.003 | 1.044 | 1.031 | 1.2987 | 1.0543 |
| **第三轮** | 0.962 | 1.020 | 1.005 | 1.043 | 1.037 | **1.1994** | **1.0419** |
| rc-spread | 0.9% | 4.2% | 1.0% | 0.8% | 1.3% | 1.1% | — |

**全程轨迹:1.206 → 1.190 → 1.153 → 1.142 → 1.131 → 1.112 → 1.0973 →
1.0751 → 1.0614 → 1.0543 → 1.0419。margin 1.05 达成,余量 0.8pp;
splay 1.1994 越停线 6.8pp。** 内存代价按定价兑现(peak RSS +10~13%),
gate_smoke 的 committed/live 列全绿(splay 反降为 1.18x——阈值抬高减少
major 后拆除态更干净)。

最终正确性盖章(growth-2.0 tip):**test262 trace 构建 0/49778 errors,
passed 44584**(与历史干净基线逐数相同);rc 单测 2381/0、trace 单测 2461/0、
gate_smoke all clean、arena audit 零诊断。

吞吐线至此闭合。合并 main 前的非吞吐清单(owner 侧):G2 正式统计流程与
re-freeze、Stage 4/5 包络行(§1.3 committed/live<1.3 行的自洽性仍归 lane-f
问题域)、object_slots2 声明源注册、LANE_RULES 移除、module
prepareFreshTarget 移交项、splay class-3 空块记分口径项。

### slab 种群治理:三个形态全部落空,轨道关闭;阈值杠杆拿到 cycles 口径读数(gc/opus-slabpop;详录 slab-reuse §9-§11)

- ⭐⭐⭐**移交框架被仪表推翻两层**:①**种群不是差异**——rc 全程持有 **36,100**
  个活 arena,比 trace 的 28,030 **更多**;上轮「57 vs 28,062」是 rc 退出时
  析构整棵树的**拆除时刻假象**。②**回访率 0.04% 不是病**,是「头插+只读链头+
  满了才出链」的直接推论,而且**分配侧根本不扫描**(`free_arenas[index]` 直取),
  「有效扫描长度」恒为 1——2,733 是**种群统计量不是每次分配的成本**。
- **三个被授权形态逐个落空**:arena 级 LIFO **已实现**,影子模拟测得扩展它只
  改变 splay **0.01%** 的 pop(基线已在 **58.75%** 的 pop 上选中该类最近被
  释放的 arena);空 arena 释放**已是即刻**(75.5% 的 arena 走过,无 aging
  可加);「收缩候选集」是**空操作**。
- ⭐⭐**真正的量是复用距离,而且双峰**:trace 48.9% 的 pop 落在 ≤3 次 free 内
  (**比 rc 的 31.6% 还热**),另 43.6% 落在 2¹⁷–2²⁰(rc 0.03%)。差的是
  **占用率**(rc ≈99.8% / trace 64%),不是足迹也不是陈旧度(rc 的自由链等待
  时长 691k pops **比 trace 的 298k 更久**)。
- ⭐⭐⭐**实测定律 + 决定性反证,轨道关闭**:复用距离 **≈ GC 头空间的一半**
  (新旋钮 `ZJS_GC_GROWTH_PERCENT` 扫 105→300%,头空间每减半复用距离众数减半,
  占用率单调逼近 100%)⇒ 它是收集器批量回收的时间常数,**分配策略动不了**。
  反证:growth 300% 让 slab 复用距离**变差**一档而**全机 L2D refill 掉 32%**
  ⇒ alloc 侧 9.5M refill 只占 splay 全部 214M 的 **4.4%**,**slab 从来不是
  主导项**。§3 的位图/magazine 两个重方案不必重开。
- ⭐⭐⭐**阈值杠杆首次拿到验收仪器口径的读数**:growth 175%→**200%**,
  splay cycles **−7.25%**(ABBA×8,n=16,效应=极差 2.7 倍)、指令 −3.28%、
  L2D −16.0%;其余五基准 **−0.23%~+0.11% 全在噪声内**,cycles geomean
  **0.9867**;代价 splay 峰值 RSS **+12.7%(251→283 MiB)**。
  **splay 1.2987 → ≈1.205,停线 1.2675,越线 5.4pp**(需求仅 −2.4%)。
  ⚠️**owner 牌**:现行 175% 的选定理由就是「留在 §1.3 的 cycle peak/live < 1.8
  内」,200% 越限——但同一段注释记着 **JSC `smallHeapGrowthFactor` = 2.0**,
  故这是「把上限抬到 JSC 值」的修宪请求。原 every-2 条目里那条只有指令口径的
  「+37MB/−4.72% 指令」由此升级为 **+32MiB/−7.25% cycles**。
- **移交(不在本 lane 授权内)**:splay 的 slab 活集 = 每个数组三笔分配
  (40/72/176 B,1:1:1,256k 叶子),其中 **class 3 的 263,816 个块(10.5 MiB、
  **19.6% 的 slab pop**)全程是空的**——`prop_count == 0` 仍按
  `shape.prop_size = 2` 分配(`object.zig:866`)。⚠️ **qjs 付同样的钱**,且它
  **对 rc/trace 一样有效、不缩小收集器差距**,只因参照臂是冻结二进制才让比值
  变好 ⇒ **记分口径问题,不该在 GC lane 内悄悄发生**。
- ⭐⭐**方法学:第一次注入是失败的,且是「注入触发了别的守卫」的又一例**——
  拿 `@min(grown,floored) -| 1` 打「阈值 ≥ 活集」断言,套件红了 4 个但**断言
  没开火**(floored 恒大于 allocated,减 1 仍满足)。**「测试变红」不是证据,
  注入必须真的违反被测命题。** 三条检查(两断言+审计自校验)最终全部注入开火。
- rc 中立:`.text`/`.data`/`.bss` **三段字节数完全相同**,全二进制指令总数相同
  (880,040),逐函数直方图仅两处差异且都在无关模块(§5.1 布局彩票);
  trace 侧六基准 ABBA×4 指令 ±0.05%、cycles geomean **1.00031**。

## main@b329a9cc 三维性能快照(2026-08-29,rc 退役后首测)

**吞吐**(官方配对协议,ABBA×5 vs 冻结 rc,rc-spread 0.8–2.4%):
deltablue 0.965 / regexp 1.047* / pdfjs 1.012 / raytrace 1.040 / EB 1.034 /
splay **1.195** → geomean **1.0466**(margin 1.05 达标;*regexp 在其 ±3~4%
布局彩票带内,rc 退役 −3170 行不可避免重洗了布局)。

**内存**(fixed-work maxrss,n=1 指示性):splay 284/150MB=**1.89x**、
regexp 1.71x、EB 1.61x、deltablue 1.61x、pdfjs 1.57x、raytrace 1.51x——
与 growth 2.0 定步的 peak/live≈2 构造一致。

> 🧭**指路(2026-08-29 重锚)**:下面这一段停顿数字**全部作废**——它采自
> `dd768214..7e233ccb` 区间的构建,`--gc-stats` 的全堆普查落在增量路径的计时
> 窗内且未扣除。**现行停顿基值(六基准双臂,修正后仪器)= `docs/pause-baseline-2026-08-29.md`**;
> 本文件末尾「停顿重锚」小节是它的摘要。原文保留,不抹历史。

**停顿**(--gc-stats STW 分段):deltablue 最大段 0.43ms / regexp 0.61ms /
raytrace 0.45ms / pdfjs 单片 cycle 3.8ms / EB 最大段 1.47ms(cycle 累计 max
4.1ms)/ **splay 最大段 18.5ms(finish 段,22 cycle 均值 12.5ms)**,minor
p99 0.99ms。

⚠️**如实修正**:采纳时引用的「splay major pause p99 ~1ms」出自 GC-GAP 时代
lazy-sweep 测量;当前 tip 上 growth 2.0(堆更大、22 个 major)+ finish 段
未切片使 splay 的 finish 段到 18.5ms——仍优于 rc 同负载的 42.4ms max,但
~1ms 已不描述现状。**follow-up:finish 段切片化**(增量/销毁段都已 ≤1.05ms,
finish 是唯一未预算化的段)。

> ⚠️⚠️**上段的 follow-up 于 2026-08-29 通盘 review 被撤回——「finish 18.5ms」
> 是仪器造出来的数字**。两路独立发现+ABBA 实测(n=6/臂):`--gc-stats` 的全堆
> 普查 `recordFinalMarkFootprint`(gc_trace_stw.zig:1116)跑在 `t_remark..t_weak`
> 计时窗口**内**,整体 STW 路径会扣 `last_census_ns` 而增量路径忘了扣;开
> `--gc-stats` 让 Splay 评分 −9.75%、SplayLatency **−23.7%**。finish 三段分解:
> remark(含普查)99.4%、condemn 64µs、weak 257ns。生产构建不跑普查,真实
> finish 估计 ~3ms 量级。**先修仪器(把普查移出计时窗/减掉 last_census_ns)
> 再重测,在此之前 finish 切片不立项**;pause 基值届时整体下移,门禁阈值须
> 同步重定。详录 review 三报告(fresh-splay-account / finish-anatomy / JSC 全景)。
>
> ✅**已结账(仪器修正合入)**:普查自立开关 `--gc-mark-footprint`(`--gc-stats`
> 回归便宜),增量路径补扣;开/关 SplayLatency 差从 −24.7% 收敛到 −0.56%。
> **splay 真实读数:finish 段 82µs 均值 / 262µs max,major pause p99 1.014ms /
> max 1.079ms**——比预估的 ~3ms 还小一个量级,finish 切片议题永久关闭。
> ⭐连带发现:GC-GAP 时代 trace 臂的全部停顿数字都含未扣普查 ⇒ **trace 的
> 停顿优势历史上被系统性低估**(splay 官方 6.87ms 实为 ~1ms 量级)。
> 待办:三维快照的另五个基准停顿数字待安静窗口用修正后仪器重采;
> gc_merge_policy 预注册行、roadmap:270、GC-GAP manifest 的 trace 停顿列
> 须重新锚定(方向全部下移);tools/perf/gc_stats_snapshot.py 的 inline 行
> 正则在 main 上已错列(4 列 vs 7 列),tail_grown_external 单调性契约待裁。
>
> ⛔**上面那条「⭐连带发现」的后半句被 2026-08-29 重锚轮回源推翻,勿再引用。**
> 「GC-GAP 时代 trace 臂的全部停顿数字都含未扣普查」不成立:把普查带进计时窗
> 的 `recordFinalMarkFootprint` 由 `dd768214`(08-28)引入,而 GC-GAP 的候选臂
> 是 `62061f94`(08-26),`merge-base --is-ancestor` 为假;读 `62061f94` 的
> `finishIncrementalCycle` 全函数无 census,六处 `censusStart` 全在整体 STW
> 路径且那条路径明确减掉了 `last_census_ns`。**GC-GAP 的 6.87ms 尾巴是 final-remark
> 切片里的 condemn 走查(面板自证 `sweep+destroy 5.08ms`),是真 STW 工作。**
> ⇒ 6.87→1.01ms 是**收集器工作挣来的**,不是仪器修正让出来的;作废区间仅限
> `dd768214..7e233ccb`。核查全文 `reports/evidence/GC-GAP/ERRATA-2026-08-29.md`。
> (前半句「finish 18.5ms 是仪器造的」不受影响,仍然成立。)
>
> ✅**待办已清**(2026-08-29 重锚轮):另五个基准已在安静窗口用修正后仪器重采
> 并收编为 `docs/pause-baseline-2026-08-29.md`;`gc_merge_policy.json` 预注册行
> 与 canary 条款、`roadmap.md` G1-GC 行、GC-GAP manifest(加勘误注记,数字不改)
> 均已重锚;`gc_stats_snapshot.py` 的 7 列已补齐,新三列按 driver 裁决**不进
> 单调性契约**。

## 官方读数第四轮 + 本波五刀终账(2026-08-29 安静窗口,main@6374ba73)

| | deltablue | regexp | pdfjs | raytrace | EB | splay | geomean |
|---|---:|---:|---:|---:|---:|---:|---:|
| 第三轮 | 0.962 | 1.020 | 1.005 | 1.043 | 1.037 | 1.1994 | 1.0419* |
| **第四轮** | 0.957 | 1.034 | **1.000** | 1.018 | **1.0008** | **1.1724** | **1.0281** |

*第三轮与本轮之间隔 rc 退役与三维快照的 1.0466 读数;本波五刀(仪器/delist/
屏障折叠/EB K1/K3)兑现 **−1.84pp,六基准无一劣化**;**EB 与 rc 实质打平**,
达标 5/6。bench_v8 composite 0.9554→**0.9615**(Splay 0.767 在其 7–11% 双臂
离散带内,非退步)。EB 兑现 −3.32pp 远超其指令刀之和=省掉的是带 stall 的工作。

### dense 数组刀:预注册验收失败,关轨(勿重试)

五条线只过一条:splay cycles −0.57%(线 −1%)、raytrace **+0.81% 真回归**
(八对八分布分离,insn/L2D/cycles 三项同向)、splay **L2D +1.47% 与机理预期
相反**(指令省了被 footprint/cache 行为吃掉)、maxrss +2.86%。分支
gc/dense-array-align 留档。教训:标记线口径的「结构机会」≠refill 兑现,
adjacent-line prefetch 把 96B 两条相邻线的账早已摊掉大半。

### 停顿重锚(修正后仪器,双臂;替换上方旧停顿表)

- **splay:tip p99 1.01ms vs rc p99 44.7ms(44 倍)**——tracing 停顿优势的
  全部来源;pdfjs/EB 亦胜;regexp/raytrace/deltablue 输但绝对值 0.14–0.46ms
  且 rc 侧几乎不真收集。
- **destroy 仍是六基准最大 STW 相位(50–85%)**——仪器修正没有推翻这条。
- ⭐**EB minor 总停顿 3.15s(7,701×0.39ms)= 全表最大单项 STW 支出**,是其
  major destroy 的 4 倍 ⇒ **EB 停顿问题=minor 频次问题**,新观察项。
- 口径:deltablue/raytrace/EB 的分位数是 1024 蓄水池保留,跨基准比较须带此列。
  完整三表在 .scratch/quiet-verdict.md(driver 收编前的原始件)。

## 96B→64B 主刀设计过审(2026-08-29;设计文=opus-64b worktree .scratch/obj64-design.md)

- **范围修订**:②Metadata 前缀出线**删出本刀**——16B 尺寸梯下 ①③④ 已到 64B,
  ②零收益(仍落 64 类)且让 fast-array 48 类→1.5 线/对象(33% trace 人口净负),
  还要拆屏障折叠+给 363 个 .meta() 点加分支。JSC 自己也留 8B 在 cell 里。
- **收益下修**:−23% 冷线 → **splay −2.3~3.5% cycles / geomean −0.4~0.6pp**
  (96B 从 128 对齐基址排,offset mod 128 循环 0/96/64/32,恰 50% 跨 buddy 对
  ⇒ 7.92M 结构线只有 ~3.96M 可兑现 refill)。**排刀算术已按此更新。**
- ⭐**分母定义入册**:冷标记线池 = base 19.97M + dense 14.13M = **34.10M**
  (shape 24.16M 是热的——1,942 个 distinct;property_slots 8.15M 与 base 物理
  重叠双记)。**拿 66.42M 当分母会把 23% 算成 11.9%。**
- 阶段:**S0 引擎外 stride 微基准**(预注册 kill line:带 prefetch 臂 cycles<1.5%
  且 refill<8% ⇒ 线轴判死,④不建,80B 是终点)→ S1(①+③→80B 足迹单变量)
  → S2(④→64B 线轴)→ S3(②三准入另议)。
- 材料勘误:「next 是 padding」只对 gc_obj_list 成立(块 cell 的 next 有四个写者,
  但停车路径实测 0.0066%,替换便宜);保守扫描旧描述已过时;WebKit 现树无
  MarkedBlock::Footer(已改名 Header 且在块偏移 0)。

### S0 预实验判定:线轴活,S1/S2 立项(s0-stride worktree 报告)

- kill line 未触发:引擎忠实臂(随机 frontier 形态)64 vs 96 步长 cycles
  **−30.66%**、l2d refill −58.82%;THP on/强预取/纯线轴对照三种加严下稳定。
- ⭐⭐设计文「50% 被 adjacent-line prefetch 免费摊掉」**判负**:l1d refill 在
  50% 跨 buddy 与 0% 跨 buddy 臂间差 0.05%——**随机序下 7.92M 结构线全是真
  demand miss**。⭐dense 刀败因得到量化解释:预取覆盖率线性序 51.5% → 随机序
  **0%**,dense 刀死于线性形态、标记刀活在随机形态。
- ⭐设计文两路线「独立同中值」是巧合(线数少算一半 × 单价高估 2.6 倍抵消);
  实测边际线价 **13.4 cyc(下界,微基准 MLP 打满)**,重推导 S2 = 0.11~0.14G
  = **splay −1.2~−1.6%**(上沿维持下沿放宽)。
- 裁决:**S2 立项**,附加门禁「落地后 l1d refill 须掉到 ≈7.92M×major 量级」
  (S0 证明随机序下结构线数=demand refill 数,偏差 +0.1~0.4%,判别器有分辨率);
  **S1 改口径立项**:≤−1% cycles、主要买 maxrss(足迹轴 S0 故意中和,无信息)。
- 外推限制入册:真 frontier 是线性/随机混合(未测的高影响变量)。

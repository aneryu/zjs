> 注：原始二进制证据在临时 worktree，未入库。

# Phase A report: EB SIGSEGV 归因与修复 (gc/blackalloc-20260831)

结论先行:**根因已命名、已修复、回归测试落地、门禁全绿。**

- 根因名:**black-allocation 块级豁免的浮动垃圾悬空边洞**
  (publication skip 撤走了 baseline published-grey 队列 trace 这张安全网;
  js_closure2 型 "先发布、后填 capture、无 barrier" 的构造路径把未 shade 的
  var_ref 边留在黑块 cell 里;闭包在 finish 前死亡 → cell 被块豁免保留、
  其未标记子对象(young var_ref 及其 payload)同周期被 condemn 释放 →
  仍-allocated 的尸体内出现悬空边 → 之后任意一次保守根扫描(minor 或下个
  major 的 seed)把尸体复活进 trace → 踩悬空边 SIGSEGV)。
- 修复:`shadeBlackAllocationSurvivors`(gc_trace_stw.zig,finish 停顿内、
  根重播 drain 之后、weak/ephemeron 之前,把当前 epoch 黑块中
  已发布且未标记的 cell 全部 shade+trace)。commit `0894f072`。
- 门禁:`zig build test` 2493/0;注入守卫按名触发;EB 直跑 20/20 与
  perf 下 20/20 零崩溃;dangle audit 修复后全程 0。

---

## 0. 起点与现场保护

- 基线树(上一轮未提交实现)先落盘:commit `3402e538`
  "wip: blackalloc candidate checkpoint before Phase A debugging"。
- 崩溃二进制 `.scratch/zjs-candidate-blackalloc`
  (sha256 `867c2812…`)原样保留,先用它复现。

上一轮接手者(14:14-14:44 的 `.scratch/phasea-*`)其实留下了远超
"10 连跑未复现" 的证据,全部纳入并亲自复验:

| previous artifact | 内容 | 本轮处置 |
|---|---|---|
| `phasea-repro` | 原二进制 + perf 循环 20 次全 0 | 与本轮矛盾→其循环条件恰好避开了时序窗口;不采信"需要 perf"前提 |
| `phasea-direct` | 某配置 20 次中 12 次 139/135 | 本轮独立复现(下节) |
| `phasea-isolation` | no-replay 4/10 崩;snapshot-only(禁 publication skip) 0/10 | 本轮用 oracle 二进制独立复验 no-skip 0/8(§4) |
| `phasea-debug-eb.txt` | Debug 构建 panic:`collectMinor` drain 中 `isCycleCandidate` 断言 | 与 ReleaseFast core 栈同址,均为下游踩尸现场 |
| `phasea-audit-eb.txt` | VERIFY-MINOR 全部 conservative_only、0 precise | 按 verifier 文档属噪声类;本轮 major oracle 同样 0 precise(§4) |

## 1. 复现矩阵(全部本轮亲测)

| 配置 | 二进制 | 结果 |
|---|---|---|
| 直跑(taskset -c 19,无 perf)×20 | 原 candidate | **8/20 SIGSEGV**(`phasea2-repro/`)——perf 非必要条件,"perf 下才崩"为伪前提 |
| perf oracle 构建(sticky comptime + VERIFY_MAJOR_ALL)×12 | zjs-oracle | 3/12 SIGSEGV,**0 precise violation**(`phasea2-oracle/`) |
| 同上 + `ZJS_GC_BLACKALLOC_DIAG_DISABLE_PUBLICATION_SKIP=1` ×8 | zjs-oracle | **0/8**(`phasea2-oracle-noskip/`)——publication skip 是崩溃必要条件(独立复验前轮 isolation) |
| dangle audit(`ZJS_GC_BLACKALLOC_DANGLE_AUDIT=1`)×4 | zjs-dangle | 每次 finish 报 **20,486–26,963 条悬空边**;1 次仍崩(`phasea2-dangle/`) |
| **修复后**直跑 ×20 | zjs-candidate-blackalloc-fixed (`a46f10f0…`) | **20/20 exit 0**(`phasea2-fixed-direct/`) |
| **修复后** perf stat(原始事件+CPU19+host lock)×20 | 同上 | **20/20 exit 0**(`phasea2-fixed-perf/`) |
| **修复后** dangle audit ×2 | 同上 | **0 悬空边、0 exempt-unmarked**(`phasea2-fixed-dangle/`) |

Core dump 栈(apport 保留 5 枚 + 本轮新增,gdb 全部解出):三种表现,
同一类现场——**trace 队列/minor drain 弹出的 header 或其 value 边指向已释放
再利用的内存**(kind 字节呈 module/realm 等 EB 不可能的值):

1. `collectMinor` → drain → `traceHeader` → `visitShape(shape_ref=0x0)`(core 99365)
2. `finishIncrementalCycle` → drain → 垃圾 kind 被 dispatch 成 `ModuleRecord.traceChildEdges`(core 114270)
3. `collectMinor` → `visitValue` → `shadeExact` → 读垃圾 header(core 114289;Debug 构建则在同路径 `isCycleCandidate` 断言,phasea-debug-eb.txt)

## 2. 排查线与否证记录

按序检验、逐条否证的假设:

1. **perf 必要条件** — 否证:直跑 8/20 崩(§1)。
2. **hot-reuse 清戳丢豁免**(gc_block_heap.zig:1930 `free_time_ns=0`)—
   否证:黑块中周期内不可能上 hot 列表(publishHotBlock 仅由
   condemnation/Pass-B 调,且 flag_young 拒收;黑块 cell 周期内无 free 路径,
   minors 在 marking 期间被 `shouldTryMinor`+`minorsAllowed` 双重关死)。
3. **epoch 撞号/时钟混叠**(`free_time_ns` 双用途)— 否证:epoch 单调小奇数,
   wall clock 巨数,状态机三值(0/clock/当前奇 epoch)互斥成立。
4. **sticky major 保 mark 前提破坏** — 否证:sticky 是 comptime opt-in
   (build.zig:83 default off),崩溃二进制未编入。
5. **minor 误扫 ex-black 老 cell** — 否证:minor sweep 走 `young_only`
   迭代器(per-cell young 头位过滤),finish 的 `clearYoungState` 确实清掉
   黑 cell 的 young 位(逐路径核对)。
6. **major 误 condemn 精确可达对象** — 否证:sticky-oracle
   (`verifyStickyCondemnation` 打补丁跳过豁免黑 cell 后,对每个 full-scope
   incremental finish 用 fresh full trace 对账)12 轮 ×270 majors 全部
   **0 precise**;conservative_only 命中为文档已载的双扫描残差噪声类
   (禁 skip 的对照臂同样有 3898 条却 0 崩溃)。
7. **queue 悬空(rc kind 入队被 mutator 释放)** — 降级:入队 kind 集合与
   baseline barrier 相同,且 shape 臂经核对(Shape 唯一 GC 边=proto,
   `shadeShapePrototypeCold` 忠实);最终被根因统一解释(踩到的是悬空边
   目标,不是队列条目本身)。

定位性证据链(正向):

- oracle 0 precise + 仍崩 ⇒ 第一因不在"finish 错杀可达对象"。
- 崩溃全部呈"活结构里有指向已释放 cell 的边" ⇒ 有人在保留 P 的同时释放了
  P 的孩子 C。
- 块豁免保留的是 **cell**,不是 **可达性**:浮动黑垃圾 P 被整块保留,但
  P 的孩子只有被 shade 过才活。
- 于是审查"谁能往黑 P 里塞未 shade 的边":replay 只盖发布前;发布后写由
  barrier 盖——除非该写路径**没有 barrier**。
- `attachFunctionCaptures`(src/exec/object_ops.zig:477-511,qjs js_closure2)
  注释自证:"capture 数组先挂到已发布对象上,再裸填——对象是唯一 GC root"。
  这个前提在 baseline 成立(published-grey 入队 ⇒ finish 前必被整体 trace),
  被 publication skip 精确废除。
- **dangle audit 实证**(决定性):每个 EB finish,豁免保留 ~9.7k cell
  (其中 ~7.5k 未标记=浮动垃圾),悬空边 20k-27k 条,形态与预测完全一致:
  `owner class=13 payload=function edge=value child_kind=var_ref child_young=true`
  (黑闭包 → 被 condemn 的 young var_ref)。

## 3. 根因(命名与机制全链)

**black-allocation 浮动垃圾悬空边洞:**

1. 增量 major 开启,epoch 奇,新空块激活为黑块;
2. mutator 创建闭包:函数对象 P 落入黑块,publication skip ⇒ P 无 mark 位、
   不入灰队列;replay 只重放发布时刻已存在的边(此刻 capture 尚未挂);
3. js_closure2 路径**发布后**裸填 `captures[i] = var_ref`(无 barrier——
   baseline 靠 P 的队列 trace 兜底,故历史上无需 barrier);
4. P 在 finish 前死亡(EB 大量短命闭包)⇒ finish 根重播不会到达 P;
   P 的 var_ref 孩子(及 var_ref 的 payload)无 mark ⇒ 被 finish 的
   list-walk condemnation 释放;
5. P 的 cell 却被 `snapshotAllDoomed` 的整块豁免保留 ⇒ 仍-allocated 的
   P 内部持悬空指针;
6. 下一次 minor / 下个 major 的**保守根扫描**把栈残值命中的 P 当候选
   shade 进 trace(P 已发布、未 doomed,保守 resolver 无法拒绝)⇒
   `traceHeader(P)` 走到悬空边 ⇒ 释放内存被再分配后 kind 字节随机 ⇒
   dispatch 到 module/realm/shape 各种 trace ⇒ SIGSEGV / Debug 断言。

时序敏感性来源:需要"闭包死亡 + 该 finish 前未被再引用 + 之后栈残值恰好
复活尸体"三者相遇,故 ~40% 波动、且对循环 harness 的栈形态敏感
(前轮 perf 循环 0/20 与 direct 12/20 的差异即栈残差差异)。

## 4. 修复

`src/core/gc_trace_stw.zig` — 新增 `shadeBlackAllocationSurvivors`
(finish 停顿内,`seedRoots/conservative/drain` 之后、`drainBarrierQueue/
ephemeronFixedPoint/processWeak/condemnation` 之前):

- 遍历当前 epoch 黑块(superblock nonempty word → block →
  alloc bitmap word-skip),对每个 cell 调 `collector.shadeExact`
  (其现有过滤恰为所需:marked 已被根重播盖过→跳过;
  unpublished 构造中→跳过),随后 `drain()`。
- 语义:**豁免保留 cell ⇒ 同时保留其孩子** ——把 baseline 队列 trace
  的安全网在 finish 一次性整批补回,不依赖 barrier 覆盖完备性
  (对 attachFunctionCaptures 这类历史合法的 publish-then-fill 路径免疫)。
- 附带修复两个同根潜在缺陷:
  (a) 可达黑对象在 `processWeak`/ephemeron 中因无 mark 被当死物
  (weak ref 误清);(b) ex-black 老 cell 违反 §8.3 "老对象带 sticky mark"
  不变量(minor 的 remembered-owner 逻辑以其为前提)。
- 成本:每 finish 一次黑块位图走查 + 仅 trace 浮动残部
  (可达者已被根重播标记,shadeExact O(1) 跳过);严格少于被删除的
  per-publication 队列往返。splay insn 门归 Phase B 重测。

不动的部分:块豁免本身、publication skip、replay、
`ZJS_GC_BLACKALLOC_INJECT` 删除突变守卫(仍按名触发,见 §6)。

诊断留存(env 门控、默认零成本):
- `ZJS_GC_BLACKALLOC_DANGLE_AUDIT=1`:finish 内对豁免 cell 的全部强边
  做 condemn 预检,`auditBlackAllocationDangles`。
- `verifyStickyCondemnation`(sticky comptime 构建)跳过豁免黑 cell、
  打印 addr/young,消除 oracle 假阳性。
- `gc.headerIsBlackAllocated` 转 pub 供二者使用。

## 5. 回归测试(无 perf、确定性)

`src/tests/core.zig`:
**"black-allocated floating closure keeps its post-publication capture graph across finish"**

复刻生产形态:预周期建 sentinel 对象 T(唯一引用来自 capture cell C)与
闭合 var_ref C;填满旧块;开增量周期;黑块中建 bytecode_function P;
fixture FB + `setFunctionCaptures`(生产同款 publish-then-fill 无 barrier
路径)装入 C;释放 P 唯一引用(P 成浮动黑垃圾);跑完 mark step +
`finishIncrementalCycle` + `finishPendingDestruction`;断言
`ownsObject(P)`(豁免保留)、`ownsObject(target)`、`headerMarked(target)`。

**删除突变验证**:注释掉 `shadeBlackAllocationSurvivors` 调用后,该测试
在 `ownsObject(target)` 处准确失败(TestUnexpectedResult,
tests/core.zig:17208),461/1 fail;恢复后全绿。

## 6. 门禁记录

| 门 | 结果 |
|---|---|
| `zig build check` | PASS |
| `zig build test` | **2493 passed; 6 skipped; 0 failed**(新增 1 测试) |
| `ZJS_GC_BLACKALLOC_INJECT=1 zig build test` | 按名 SIGABRT:`GC black-allocation invariant violated: current-epoch block reached condemnation`;输出与前轮参考 `blackalloc-injection-final-full.txt` 同形(含同样 2 条既有 REPRESENTATION 噪声行) |
| EB 直跑 ×20(taskset -c 19) | **20/20 exit 0** |
| EB `perf stat -e armv8_pmuv3_1/instructions/` ×20(CPU19 + `/tmp/zjs-host-heavy.lock` flock) | **20/20 exit 0**(`phasea2-fixed-perf/`) |
| dangle audit ×2(修复后) | 0 悬空边、0 exempt-unmarked |

二进制:修复后 candidate = `.scratch/zjs-candidate-blackalloc-fixed`
(sha256 `a46f10f0a85e4f2524e43771cbb9a63920beb73186543f1ebef84050a6e68b6b`)。

Commits(未 push):
- `3402e538` wip checkpoint(现场保护)
- `0894f072` Phase A 修复 + 诊断 + 回归测试

## 7. 交给 Phase B 的注记

1. splay insn(≤0.96 线)与 committed 峰值门需用**含本修复**的二进制重测:
   finish 新增黑块走查会付一点 STW/insn,同时浮动黑垃圾的孩子也被保留一个
   周期(committed 峰值可能轻微上移)——两者都是 Phase B 验收线的对象。
2. `attachFunctionCaptures` 若未来想改为 per-slot barrier(去掉 finish 走查
   的那部分依赖),须先普查所有 publish-then-fill 路径;当前 wholesale
   方案对未知路径免疫,建议保留为正确性地基、把 barrier 化仅当性能优化做。
3. sticky-major 实验若要与 black-allocation 组合,注意本修复已使黑 cell 在
   finish 获得 mark(与 sticky "老对象皆 marked" 前提相容);修复前二者组合
   会直接违反该前提。

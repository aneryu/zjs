# pdfjs 优化方案 — 基于 2026-08-07 归因（zjs b15ae407 vs qjs 04be2460）

目标：pdfjs zoo 分数 0.464 → 预测 ~0.62-0.66（cycles 795.5 → ~620-660 Mcyc/run）。
待解释总量 388.3 Mcyc/run；本方案覆盖已命名的 ~216 Mcyc 机制超额。
设计来源：6-agent 设计 workflow（wf_30f5bdfc），每把刀均已对照真实代码与
quickjs.c 行号落实；完整结构化输出在 design-results.json。

---

## 刀序总览

| 阶段 | 刀 | 机制超额 | 预期兑现 | 复杂度 | 跨基准 |
|---|---|---|---|---|---|
| 1 | **A+E** splice dense 快臂 + generic 写 dense 就地覆写 | 165.4 Mcyc | 100-135 Mcyc | medium | pdfjs 专属（但补全 shift/unshift/slice 家族唯一的洞） |
| 2 | **B1+B2** 字符串相等快臂 + accumulator 平坦策略 | 32 Mcyc | 20-26 Mcyc | medium | **引擎级**：earley-boyer 最受益 |
| 3 | **C** String builtin 接收器边界线性化 | 9.8 Mcyc | 6-8 Mcyc | small | 部分引擎级 |
| 4 | **微刀**：findProperty 三守卫删除；op_put_array_el q-spill 冷孪生 | ~5 + 5.4 Mcyc | 低但引擎级 | small | **每次 shape 查找**；navier（dense 写受害者） |
| — | **D** native dispatch 外壳 → **DEFER**（方案已归档防重推导） | 24.7 Mcyc | 0-3 Mcyc | — | — |

刀间 cycles **不可加**（本项目实测求和只兑现 ~73%），合并效果只能以联测汇报。

---

## 刀 A+E：splice dense 快臂（头号刀，43% 的差距）

### 活性已预证明（决定性）
gdb 回溯（现有二进制，runN.js）：N=1 时 588 次 dense→sparse 转换 / 19,762 次
splice。**572 次运行期转换中 466 次源自 qjsArraySpliceCall 内部**（281 次
shift-loop `setValuePropertyOrThrow` @ array_ops.zig:2784/2808；185 次 shrink-tail
`deleteValuePropertyOrThrow` @ :2794）。接收数组在 splice 时是 dense 的，是 splice
自己的第一笔 generic 写打散它们 → **快臂是自维持的**：第一次 splice 走 memmove
就不再退化，后续全部命中。

E 单独落地对 pdfjs 无效（grow-splice 经 out-of-range 首写退化，E 只覆盖
in-range）——A 是 165.4 Mcyc 的必要条件；E 是引擎级表示正确性伴刀。

### A 的实现（array_ops.zig，紧邻 :3312/:3340 的兄弟函数）
新函数 `qjsFastDenseArraySplice`，在 qjsArraySpliceCall 于 new_length 算出后
（:2753）、arraySpeciesCreate 前（:2755）插入。镜像 quickjs.c:43040-43082：

1. **Gate**（全部术语已映射到 zjs API）：`isArray && !isProxy && !hasExoticMethods
   && arrayElementStorageMode()==.dense && actual_start+actual_delete_count <=
   fastArrayCount()【所有参数强转完成后新读，镜像 qjs:43033 的 stale-len 纪律】
   && flags.length_writable && canExtendFastArray()【object.zig:10233 已是
   qjs:9935-9944 的精确镜像】&& cast(u32,new_count) 成立 &&
   arrayHasDefaultSpecies()【= JS_IsUndefined(ctor)，slice 先例 :2509】`
2. **removed 数组**：js_create_array 镜像（qjs:9601），slice 惯用法 :2510-2532；
   ValueRootFrame 根住跨两个分配点。
3. **shrink 臂**：先 free [start+ins, start+del)（纯 rc 减，全部已 dup 进 removed），
   `copyForwards` 原始位移（所有权随位移走，shift 惯用法 :3322-3326），再
   setFastArrayCountAssumeCapacity。
4. **grow 臂**：`fastArrayEnsureCapacity` 后**必须重取 values 窗口**（realloc 会
   移动；qjs 在 43069 重取 arrp），count-first 序（unshift 已验证惯用法
   :3366-3378），copyBackwards 上移 + undefined 填充。
5. **insert 循环**：qjs:43080-43081 set_value 镜像。
6. `setArrayLength(new_len)` + `markIndexedProperties`，返回 removed。

**不镜像**（记为后续忠实性条目）：qjs 慢路径的 JS_CopySubArray 批量
（qjs:41599-41652）——快臂落地后其覆盖面在 pdfjs 实测 ~0；qjs deleteProperty
的末元素臂（qjs ~9372-9390：idx==count-1 → count-- 保持 dense；zjs
object.zig:10964 一律转换，是 185/572 转换的根因）。

### E 的实现（object_ops.zig:3242-3245 + object.zig:10221）
把**死代码** `writeDenseArrayIndex`（object.zig:10221，今日零调用者）接入
setValuePropertyWithThrow 的 array 分支，镜像 qjs:9740-9748 + 9961-9973。
接入前修正：删 `!length_writable` bail（qjs 该位点只查 class/fast_array/
idx<count——就地覆写不触 length；保留则 length-frozen 的 dense 数组仍会经
generic 尾巴退化）；保留 fail-closed findProperty 探针（同 :10258 house style）；
补 `markIndexedProperties`。

### 风险表（摘要）
- GC 在 alloc/ensureCapacity 中回收 removed → ValueRootFrame 根住（slice 先例）
- realloc 移动 values → 强制重取；单测覆盖跨容量增长
- 参数 valueOf 重入收缩接收器 → gate 在全部强转后用新 count 评估（qjs 同纪律）
- 快臂 dead-code 上线 → **强制 gdb 命中数证明 ≥19,000/run**（见测量协议）

预期：−800-830 Minsn/run；兑现类=分配/指针追逐移除（0.6-0.82）→ pdfjs
1.954x → ~1.55-1.62x。

---

## 刀 B1+B2：字符串相等 + accumulator 平坦

### B1 — opCompare eq 族 flat×flat 臂
- **string.zig ~:878**：新增 outlined `flatStringBodiesEq`（qjs js_string_eq
  4605-4613 镜像：len→ptr→memcmp；qjs 自己也是出线函数 js_string_eq.isra.0）。
- **tailcall_dispatch.zig :3667** opCompare 模板：int32×int32 miss 之后加
  `eq/neq/strict_eq/strict_neq` prong，`hasTag(Tag.string)` 双检——
  Tag.string_rope(-6) 与 Tag.string(-7) NaN-box 前缀不同，rope 自然落 cold，
  **精确镜像 qjs JS_TAG_STRING vs JS_TAG_STRING_ROPE 的分裂**（qjs:20321-20325 /
  20382-20386）。
- **string.zig :891-894** compareSameWidth 单扫修复：memcmp 符号即序
  （qjs:4586-4603），杀掉 mem.eql 后 mem.order 的二次扫描。
- 若 C 已落地：臂内加一条 `node.flatString()` 检查捕捉
  「rope-tag 但已线性化」的操作数（53% 流量是 rope-LHS）。

### B2 — startAccumulatorRope 长度门槛（真分歧）
病根确认：**startAccumulatorRope（value_ops.zig:1256-1263）对第一笔 `+=` 无条件
建 rope、无长度门槛**；qjs OP_add_loc 在 8192/512 门槛下保持 local 平坦
（qjs:19767-19772 → JS_ConcatString 5070-5075）。单一咽喉点：两个调用方
（vm_arith.zig:679/:791）都过它。修复=补 qjs 同款双长度 gate，小字符串走平坦
concat，超阈值才 rope。

覆盖率：B1 单独 ~47% 流量（~124 Minsn）；B1+B2 → ~96%（~250-280 Minsn）。
兑现：32 Mcyc 中的 ~20-26（含 5.3 Mcyc 的 store-to-load-forwarding stall，
stall 移除必兑现）。**engine 级**：earley-boyer 符号比较密集。

待裁决（落地时）：u8 序腿用 extern glibc memcmp（字面 qjs 镜像）还是
无依赖单趟标量——风格裁决，请在 review 时定。

---

## 刀 C：接收器边界线性化

关键事实：**zjs 已拥有忠实适配**——`StringRope.flatten`（string.zig:148-176）
原地改写节点（left=flat/right=undefined/depth=0）、O(1) 幂等，与
js_linearize_string_rope（qjs:4838-4857）同构。问题只是三个接收器强转边界
**都没接**，而 qjs 在 JS_ToStringInternal 里线性化（qjs:13597-13598），所有
String.prototype builtin 经 JS_ToStringCheckObject 免费受益。

四处编辑：
1. string.zig ~:1010 新增 `linearizedStringDup`（JS_ToStringInternal string 双
   case 的镜像）
2. **热路径**：string_builtin_ops.zig:190-201 `stringPrimitiveIndexRead`
   （charCodeAt/at/codePointAt 共用）——isString gate 后 rope 即 flatten 借读
3. string_ops.zig:355/:362 `toStringForAnnexB` 的两个 rope 直通改走
   linearizedStringDup（此函数注释本就引 qjs:13670/45453）
4. stringPrimitiveValue 家族（:1868/:1778/:1491/:1499/:1524/:632）同改

风险：交错 `s+=x; s.charCodeAt(k)` 每轮重物化 O(n²)——qjs 同行为（忠实）；
借读指针跨分配存活——按现有 borrow 纪律处理。B2 落地后 rope 群体缩小但
大 content-stream rope（600-24000 字符）仍在，C 独立成立。
~50 Minsn/run，兑现 6-8 Mcyc（该簇 cycle 份额 2.5% > insn 份额 0.8%，
低局部 IPC=历史上会兑现的形态）。

---

## 刀 4（微刀，引擎级）

### findProperty 三守卫删除 — 已定价，REMOVE
worktree 差分构建：静态预测 4 insn/probe，动态四个独立估计 5.00±0.1%
（对账通过）。pdfjs 仅 18.33 Minsn/run（~2-4 Mcyc），但税在**每次 shape 查找**。
忠实性：qjs find_own_property 是零守卫裸 while(h)（qjs:6135-6152）；zjs 自己的
trusted-probe 家族在最热路径已是同款裸循环且注释引同一 qjs 行——带守卫的公共
findProperty 是**内部不一致**而非防线（get_field 热层每次都在裸奔同一腐败类）。
替换=裸循环 + Debug/ReleaseSafe `std.debug.assert`（镜像
findPropertyProbeTrusted :11584-11598）。⚠️ **必须在刀 A 落地后重定价残差**——
99.7% 的 existsOwnProperty 流量经 splice 而来，A 会重塑整个残差版图。

### op_put_array_el q-spill 冷孪生 — 主张核验存活（5.4 Mcyc/run）
病根比归因记录的更锐利：`ldp q1,q0` + `stp q0,q1,[sp]` + 标量回读
**无条件跑在每次 put_array_el**（dense 命中也付），因为慢腿要 by-pointer 操作数，
LLVM 把操作数对的帧物化提升到所有分支之上。修复=项目已验证的冷孪生模式
（「LLVM csel 计算存储地址只 noinline 冷孪生能破」）：热体只留 dense 臂、操作数
以标量字加载（绝不 16 字节聚合拷贝），慢腿 noinline 出线 by-value 交接，镜像
qjs:19546-19585 的 OP_put_array_el 内联 dense 臂。跨基准：navier-stokes
（已确认 dense 写受害者 1.366x）同受益。

---

## 刀 D：native dispatch 外壳 — DEFER（裁决记录防重推导）

反汇编逐段预算：热路径 ~155-160 insn vs qjs 外壳 ~75-80，超额分散在 ≥6 个
≤27 insn 切片（双栈帧发布 ~27、outlined prologue+0x180 帧 spill ~10、三重
class_id 重查+realm 视图重导 ~10、error-union 管道 ~8……），**无单一 qjs 镜像
切口**——qjs 侧的缺席是 JS_CallInternal 结构性内联，不是可镜像机制。最佳切口
（双发布合一，镜像 qjs 单 sf_s 链 17583-17589+17687）仅 18-20 Minsn/run，兑现类
0.0-0.15 → 0-3 Mcyc，低于 ±2.8% 构建噪声地板。已核实
callTypedInternalRecordDirect 实测平价（8.19 vs 8.05 cyc/call）**禁动**；
栈溢出预检是忠实的（qjs:17579-17581）保留。
重启触发条件：post-splice 重基线显示 native 外壳份额增大，且该切口计时 A/B >0。

---

## 测量协议与门禁（每把刀）

1. **活性证明先于收益声明**：临时计数器或 gdb ignore-count 断点证明新臂在
   runN.js 上命中（A：≥19,000/run；B1：~0.45M（B2 后 ~0.97M）/run；C：rope
   接收器计数）。「fast path 没真跑」是本项目已知事故模式。
2. **四重门禁**：test262 全量 0/49775、ReleaseSafe 构建、force-GC 二进制、OOM
   harness、parser suite。触帧/GC 的刀（A 的所有权手术）另跑 leak-check。
3. **计时纪律**：insn 是主要计数证据；cycles 必须固定二进制同会话交错
   A/B/B/A、绑核 19、独占 host lock。指令赢≠时间赢，报数前必须给 cycles。
4. **zoo 全套回归**：每把刀落地后 4-sample 全套（单基准永不足以裁决），守住
   已有反超（code-load 1.084 / regexp 1.121）与领先项。
5. **重基线序**：刀 A 落地并确认后**必须重跑归因基线**再决定阶段 4 规模——
   A 消除 existsOwnProperty/getDenseArrayElementValue/setOwnWritableDataProperty
   的 splice 流量，残差版图会整体改变。

## 预期终态（诚实边界）

机制超额合计 ~216 Mcyc/run；按兑现类打折并计非可加性（~73%），预测 pdfjs
cycles 795.5 → ~620-660，分数 0.464 → **~0.62-0.66**。其后剩余 ~1.27x 弥漫
per-opcode 税（~100-158 Mcyc）无单一属主，需在 post-A 重基线上重新开挖。

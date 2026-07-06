<!-- 生成:2026-07-06 workflow alloc-layer-divergence(30 agents / 2.09M tok / 29min)。基线:zjs HEAD e617fdd(未重建) vs qjs /home/aneryu/quickjs/qjs。方法:源码逐行 + 反汇编地址区间归因 + 对抗证伪 + taskset 绑核 perf。 -->

# zjs vs qjs 分配层忠实对齐审计 — 综合报告

**范围**:object 字面量 / array 字面量 / string 拼接 / GC 记账 / shape 装配五维度。
**基线二进制**:zjs = HEAD `e617fdd`(未重建),qjs = `/home/aneryu/quickjs/qjs`。
**方法**:源码逐行核对 + 反汇编精确地址区间归因 + 对抗性证伪 + `taskset -c` 绑核 perf(insn 计数 <0.03% 抖动,cross-engine 固定二进制不受 ±2.8% 构建非确定性影响)。

---

## 1. 执行摘要

分配层对 qjs 全面偏重,四个基准的 insn_ratio 与 time_ratio 在 5% 内一致 —— **差距是"做的工作量(指令数)",不是停顿/误预测**:

| 基准 | zjs ns/op | qjs ns/op | time ratio | zjs insn | qjs insn | insn ratio |
|---|---|---|---|---|---|---|
| objalloc `{a,b,c}` | 186.24 | 77.05 | **2.42x** | 4763.6 | 1952.2 | **2.44x** |
| array3 `[i,i+1,i+2]` | 113.38 | 38.79 | **2.92x** | 2669.1 | 945.0 | **2.82x** |
| emptyobj `{}` | 65.69 | 24.11 | **2.72x** | 1587.5 | 568.8 | **2.79x** |
| strconcat `"x"+i` | 78.03 | 40.62 | **1.92x** | 1758.6 | 964.2 | **1.82x** |

**核心结论一句话**:分配层这 2.4–2.9x 的绝大部分**不是结构性地板,而是 zjs 独有的、qjs 用一条指令或零指令就绕过的水平记账/分派税** —— 每次分配的 GC 阈值双查(D3)、`recordHeapAlloc` 的 9 字段字节账本 + 页几何子模型(GC-D1/D2)、每属性一次 out-of-line `arrayIndexFromAtom` 调用(而 qjs 是 1 条 `tbnz`)、`createInternal` 把 88B class.Record 按值 SIMD 拷回栈(AL1)、shape 哈希容量与属性容量解耦造成的每-append 复查(shape-D5)——这些在反汇编下逐一坍塌为"F1/refreshSpacePageState 同型误判"。

**但有三处经证伪坐实为真忠实地板/zjs 已净胜**(必须停手):`strconcat` 的 int→string 融合 zjs 用 1 次堆分配 vs qjs 2 次分配 + 2 次 free(str-D2,zjs 净胜近 2x);array `.length` 语义 zjs 一条合并 store vs qjs 两次写 + 引用计数税(AL5);shape 去重扫描内循环 zjs 10 insn/iter vs qjs 13 insn/iter(shape-D6,zjs 已优于 qjs);`defineField` 快路径 zjs ~47 前导 insn vs qjs ~138(obj-D5)。

**ground-truth 最大意外**:四个基准的 **#1 self% 全是 `exec.vm_property_locals.checkedLocVm`**(14.86 / 24.61 / 27.61 / 25.90%),它**根本不在分配审计里**——这是 VM 每-op 的 checked-local-slot 分派税(`noinline` 巨型 handler,vm_property_locals.zig:176),比任何单个分配函数占的墙钟份额都大。**分配层确实 ~2x 更重,但这些微循环墙钟差的一大块是解释器 per-op 分派/局部槽开销,不是分配器本身。**

---

## 2. 分维度偏离目录

> 说明:每行的"证伪判定"是对抗性复核对审计原判的结论。`REDUCIBLE`=可完全对齐 qjs;`PARTIAL`=部分可约、部分真地板;`FLOOR_CONFIRMED`=真忠实地板(附 qjs 指令数);跨维度重复的 `arrayIndexFromAtom` / `recordHeapAlloc` / GC 阈值检查已在 GC 记账维度合并主叙述,其他维度仅引用。

### 2.1 Object 字面量 `{a:i, b:i, c:i}`

| 位置 | zjs 做什么 | qjs 做什么 | 指令差 | 证伪判定 | 忠实修法 |
|---|---|---|---|---|---|
| **obj-D1** gc.zig:1071 addWithSize / 1138 recordHeapAlloc | per-alloc 记账风暴:9 字段字节账本 + 页几何 + 加权 debt,161-insn 独立函数(99.89% 权重),object+shape **各触发一次** | add_gc_object 内联 3 store(mark/type/list_add_tail)+ js_trigger_gc 5 条只读比较;字节计数器分摊到 arena carve ≈0/对象 | zjs 131(风暴区)vs qjs ~13 | **REDUCIBLE** | 收窄到 qjs 量级:仅 `live_bytes += ` + 一次阈值比较 + list_add_tail(~13);peak/debt/page-state 移到 GC 消费点惰性重算(同 F1) |
| **obj-D2** object.zig:1766 destroyFromHeader | plain-object free 走 20 个顺序 `destroy*Payload()` 互斥门控调用,~40 执行 insn 分派 | `class_array[class_id].finalizer` 一次查表 + NULL 判空 ~6 insn | plain-obj 执行 ~199,其中分派 ~40 可约到 ~3 | **PARTIAL** | payload-kind 链改单个 `switch(class_payload_kind)`/查表(~40→~3,省 ~37);其余 ~160 是 zjs weakref/记账模型真成本(borrowed-ref 守卫 + recordHeapFreeWithBytes ~40 vs qjs remove_gc_object ~4) |
| **obj-D3** memory.zig:559 createWithFamInternal | shape 分配走 457-insn 函数,其中 316 是**全展开线性 size-class cmp 阶梯**(62 桶);热路径扫到匹配桶前缀 ~26 | `__js_malloc` 自带 size-class 阶梯但用**算术**算桶(add/lsr)~10 insn + freelist pop | 热路径扫描 zjs ~26 vs qjs ~10 | **PARTIAL** | slab size-class 从线性 cmp 改算术 bucket(仿 `__js_malloc` add/lsr),扫描 26→~10;addWithSize 计数器级联趋近 qjs 3-store。⚠️审计"全套记账 allocation_count++/traceAlloc"在 ReleaseFast 已编译掉(`diagnostic_accounting_enabled=false`),真 zjs-only 开销在 addWithSize 的 recordHeapAlloc |
| **obj-D4** object.zig:9632 arrayIndexFromAtom | 每属性无条件 `bl arrayIndexFromAtom`,named 键跑满原子表查找 + name 检视 ~26 insn + 函数调用;adoptShape 内又重复一次原子表索引 | 单条 `tbnz w2,#31`(`__JS_AtomIsTaggedInt`),named 键 fall-through 进 shape 路径 | zjs ~26 vs qjs **1** | **REDUCIBLE** | call-site 内联 `atom.isTaggedInt()` 分支(镜像 qjs tbnz),仅 tagged-int 才走 markIndexedProperties;named 完全跳过 digit-scan。named 支可完全消除到 1–2 条 |
| **obj-D5** vm_literal.zig:171 defineField | 快路径守卫命中 → definePlainDataPropertyKnownFast,~47 taken 前导 insn,跨 1 个真实调用边界(findProperty)后尾跳叶子 | 每 define 走 JS_DefinePropertyValue→JS_DefineProperty→JS_CreateProperty **3 层非内联**,~138 taken insn + 2 次完整栈帧 + 2 对栈金丝雀 + 全参数 reload | zjs 47 vs qjs **138** | **FLOOR_CONFIRMED** | 无需改。zjs 已 2.9x 领先且无冗余(守卫是忠实必需)。这是 qjs 唯一 define 入口的结构性成本 |
| obj-D3'(与 shape-D6 同) shape.zig:297 findHashedShapeProperty | 去重扫描内循环 10 insn/iter | 同算法 13 insn/iter | 见 shape-D6 | **FLOOR_CONFIRMED** | 见 shape 维度 |

### 2.2 Array 字面量 `[i, i+1, i+2]`

| 位置 | zjs 做什么 | qjs 做什么 | 指令差 | 证伪判定 | 忠实修法 |
|---|---|---|---|---|---|
| **AL1** object.zig:1268 createInternal | 顶部 `record(class_id)` 返回 88B class.Record **按值 materialize 到栈**(6 条 SIMD `ldp/stp q` + 尾标量 ~22)+ inlineClassPayloadLayout 派生(~23)+ 从栈读 payload_kind 走跳表 | `JS_NewObjectFromShape` 收 class_id 作纯 int:1 条 `strh` 存 class_id + 6 条 int 跳表直跳 ARRAY case;SIMD 块拷贝 **0** | zjs ~45 vs qjs **7** | **REDUCIBLE** | record() 热路径改经 `*const Record` 指针只读标量(消 6 SIMD + 尾标量 ~13);按 class_id switch 决定 payload/exotic,array/object 跳过 layout 派生与 payload_kind 跳表(消 ~23) |
| **AL2** shape.zig:215 createObjectRoot | 稳态每次 `firstShapeWithHash(initialHash(proto))`:hash 乘法 + 桶索引 + 链比对 + retain ~14-20 | `js_dup_shape(ctx->array_shape)` 缓存单例指针,`ldr [x0,#48]` + refcount++ = **4 条**,零 hash/分支/乘法 | zjs ~14-20 vs qjs **4** | **REDUCIBLE** | runtime 缓存空数组根 shape 指针(镜像 `ctx->array_shape`),init 建一次驻留,createArray 直接 `arrayShape.retain()`。⚠️审计原指认的 createInternal 顶部 `ldr[x20,#7320]+umaddl` 序列**实为 record() 类记录查找(88B stride)不是 shape hash-walk**——两引擎都做,真 shape 走链在 createInternal+0xf50 |
| **AL3** object.zig:3558 ensureArrayBufferCapacity | `old_capacity==0` → 硬编码 `next_capacity=16`,allocRuntime 256B;3 元素浪费 13 槽 | `expand_fast_array(p,3)`:`new_size=max(3, size*3/2)=3`,精确 48B;批量与增量路径对空数组首分配一律 exact-fit | 字节 256B vs 48B(5.3x);指令次要 | **REDUCIBLE**(完全可约,非 partial) | 单-token 修法:`if(old_capacity==0) needed_len`(与 qjs `size==0` 支同构);1.5x 增长分支已匹配 qjs。⚠️git blame 证 min-16 由 `16d7826e`(2026-06-20)引入,非任何 qjs 锚点 |
| **AL4** array.zig:135 valuesRequireNoRoots | 逐值 `requiresRefCount` 预扫描选 root/no-root 分支,3 元素 ~32 insn | 原位在 sp 上搬运,值天然被帧扫描当 root,零预扫描 | zjs ~32 vs qjs **0** | **REDUCIBLE** | 根因 vm_literal.zig:37-46 把值 pop 进裸 Zig 局部(非 GC root)。修法:用单个 `ValueRootFrame{.slices=&.{.{.mutable=&values}}}` 注册这段 slice(runtime.zig:1266 证 GC 会扫),预扫描 32 条全删,两情形都归零逐元素开销 |
| **AL5** object.zig:8709 array_length | `.length` 一条合并 `stp w11,w8,[x22,#48]`(与相邻 flags 共享),只写一次,init-0 并入 memset | 对 prop[0] **写两次**:init-0 的 `stp xzr,xzr` + set_value 改 N(load-old + tag-check + branch ~5)占 16B prop 槽 | zjs ~1 vs qjs **~6** | **FLOOR_CONFIRMED** | 无需改,zjs **严格优于** qjs(1 合并指令/1 写 vs 6 指令/2 写)。审计"平价"措辞偏保守,实为 zjs 已在/低于 qjs 地板 |

### 2.3 String 分配 `"x" + i`

| 位置 | zjs 做什么 | qjs 做什么 | 指令差 | 证伪判定 | 忠实修法 |
|---|---|---|---|---|---|
| **str-D1** runtime.zig:1112 requestGCForAllocation(内联进 string.zig:647) | 每次 string 分配跑 gc_running 检查 + 阈值饱和加比较 ~10 always-run insn + 冷 requestGC 体 | string 路径 js_alloc_string→__js_malloc **零 GC 触发**;js_trigger_gc 全库唯一调用点 quickjs.c:5619 仅对象分配 | zjs 10 vs qjs **0** | **REDUCIBLE** | 病理同 F1:per-alloc 钩子被错放进**通用字节漏斗** allocRuntimeAlignedBytes(blame `99c9c95` L2 slab)。String 纯引用计数不参与环收集(zjs 4B StringHeader / qjs str->link 仅 DUMP_LEAKS)→分配永不需触发 GC。修法:从漏斗移除或按类型门控排除 string;对象侧已另有独立触发(registerObject) |
| **str-D2** value_ops.zig:920 stringAddStringInt | i<256 用 smallIntString 缓存串(0 分配)+ createLatin1Concat 单次;i≥256 dtoa 写栈缓冲(0 分配)+ 单次。**总 1 次堆分配** | JS_ConcatString 对 INT op2 先 ToStringFree → js_new_string8_len **分配临时 digits 串**(alloc#1),再 ConcatString1 分配结果(alloc#2),末尾 2 free。**总 2 分配 + 2 free** | concat 机制 zjs ~334 vs qjs ~637 insn/op | **FLOOR_CONFIRMED** | 无需改,zjs 净胜近 2x 且已在 1-alloc 理论下限。qjs 无 small-int 缓存,临时 digits 分配对所有 i 不可避免(perf 证:qjs __js_malloc 16.41% + __js_free 7.68% + ConcatString 系列共 65.43%) |
| **str-D3** runtime.zig:2145 smallIntString | i<256 out-of-line cache-hit 19 静态 insn(真逻辑 ~4),digit 串已堆常驻 | **审计误判**:qjs 并未内联 i32toa。实际 `bl i32toa`(41 insn,umull div-by-10 每位循环)+ `bl js_new_string8_len`(每次分配 digit 串)+ i32toa 内 `bl memcpy` | zjs ~4 逻辑 vs qjs 40+ 每次格式化 + 1 分配 | **REDUCIBLE**(方向反转:zjs 已更省) | 审计"qjs 内联 i32toa 无调用"前提反汇编证伪(3 个 out-of-line 调用)。zjs cache-hit 把 qjs 的"每次逐位格式化 + 分配 digit 串"塌成"cache-probe load + 借用堆串"。无 zjs 侧可约地板,审计 partial 基于错误前提 |
| **str-D4** memory.zig:647 rawAlloc + string.zig:637 createUninitialized init | 核心 4 组件:SmallObjectSlab arena pop + 12B JSString + 3-store init + out-of-line memcpy | `__js_malloc` arena free-list pop + 12B JSString(逐字节等同)+ 3-store init + memcpy@plt | 核心 4 组件同量级 | **PARTIAL** | 4 组件**逐一是真忠实地板**(反汇编逐字节核对)。但审计漏掉 zjs 每次携带、qjs 在 string 上可证不做的 rider:(A) requestGCForAllocation ~10-30 内联(同 str-D1,可约)(B) checkAllocation + allocated_bytes 饱和加记账。核心 4 组件是地板,GC-check rider 可约 |
| **str-D5** value_ops.zig:920 stringAddStringInt(单体) | 407-insn 单体函数,368B 栈帧 + 6 组 callee-save save/restore,热路径只走一小片仍付整帧 | string+int 走 **5 层委派帧**(js_add_slow 0x90 + JS_ConcatString + JS_ToStringInternal + js_new_string8_len + JS_ConcatString2),累计 ~528B 帧 + ~19 组 save/restore + 临时串 malloc | zjs 单帧 368B vs qjs 5 帧累计 528B | **PARTIAL** | 审计"qjs 帧更小"仅孤立看 js_add_slow 一帧成立;整链 qjs 足迹更大。但 D5 子断言(单体强制建 368B 帧 + 6 组 save/restore)真且可约:把冷臂(rope/dtoa/error)拆 noinline(正是 qjs 分散结构),热路径帧收缩。算法层 zjs 已少 1 分配(不可约);单体帧膨胀可约 |

### 2.4 GC 记账 / MemoryAccount(per-alloc 水平开销)

| 位置 | zjs 做什么 | qjs 做什么 | 指令差 | 证伪判定 | 忠实修法 |
|---|---|---|---|---|---|
| **GC-D1** gc.zig:1138 recordHeapAlloc + 1196 addLiveHeapBytes | 9 个饱和-add 字节账本字段 store(allocated/peak/heap_live/old_live/old_allocated/old_alloc_count/large 镜像) | per-object **0 字节账本写**(js_trigger_gc 只 READ);malloc_count++/malloc_size+= 仅 arena carve 时(js_def_malloc:2167),分摊 ~0/对象 | zjs ~35-50 vs qjs **0** | **REDUCIBLE** | F1 同型:9 字段中**仅 allocation_debt(#1800)承重**(externalMemoryRequestReason gc.zig:830 唯一热读,对齐 qjs malloc_size,1:1 平价)。其余 8 字段无热读者(仅 statsSnapshot cold + 一个 debug assert)。修法:热路径仅留 allocation_debt/单 live 计数器;peak/count/large-old 分桶惰性经 gc-object-list walk 重算(镜像 JS_ComputeMemoryUsage) |
| **GC-D2** gc.zig:216 SpaceAccount.recordAlloc(经 1218 recordSpaceAlloc) | 每 alloc 跑 free-page/committed-page rounding 子模型:`alignForwardSaturating(needed,16384)` + free/committed re-split ~25 insn(新页支,is_large 复制 x2) | **无 per-alloc 页记账**。arena 占用隐含在 free-list(n_used_blocks++ 是分配器本身,非平行账本) | zjs ~10-35 vs qjs **0** | **REDUCIBLE** | 三证:①不在 GC-trigger 关键路径(externalMemoryRequestReason 只读 debt/external,从不读 committed/free)②仅消费者 refreshPageState(gc.zig:254)在 GC-sweep/snapshot 重算③qjs 结构性证明只需 flat malloc_size 无 rounding。⚠️committed/free/decommit 语义被测试契约断言(core.zig:3021 heap_committed==16384 页舍入 / :3078 decommitted==page)→不可删除,但整个页几何**可从热路径归零**到惰性派生(REDUCIBLE 非 partial:per-alloc 几何全可移,仅惰性派生契约须保留 off-path) |
| **GC-D3** runtime.zig:1122 registerObject 尾 + 2042 requestGCForAllocation | GC 阈值**每对象查 ≥2 次**:createInternal 每 sub-alloc 一次(21 个内联 #14672 比较点)+ registerObject 尾再重算 allocated_bytes>threshold ~11 insn(entry 检查的严格重复) | js_trigger_gc **恰一次**在 JS_NewObjectFromShape 顶部(malloc 前),5 只读 insn;sub-alloc(p->prop)不重触发,无 post-alloc 重查 | zjs registerObject 重查 ~11 + N×~8 sub-alloc vs qjs **5 一次** | **REDUCIBLE** | 每对象查一次(镜像 qjs 单 js_trigger_gc)。删 registerObject:1122 冗余 hasPendingMajorRequest/threshold 重查;更佳:提一个阈值检查到 createInternal 顶部,所有 sub-alloc 传 NoTrigger 分配器 |
| **GC-D4** gc.zig:1144 weighted mul + allocation_debt add | `weighted = bytes*kind_weight` + umulh 溢出守卫 + allocation_debt 饱和加,~13 insn/alloc(第二 GC 信号) | 单一信号 malloc_size vs threshold;**无加权乘、无 debt 累加器、无 per-kind 权重** | zjs ~13 vs qjs **0** | **REDUCIBLE** | 丢掉 per-alloc 加权乘。qjs 纯靠 malloc_size 越过阈值;加权-debt 是 zjs-only 启发式无 qjs 对应。若需 debt 信号,累加未加权字节(即 allocated_bytes),权重只在决策点 externalMemoryRequestReason 施加。⚠️但 GC-D1 判定 allocation_debt 是唯一承重字段——两处需协调:保留 debt 但去掉 per-alloc 加权,权重后移 |
| **GC-D5** gc.zig:756 reportExternalAlloc + 1289 ensureExternalTokenCapacity | per-token 线性数组 append + 5 字段饱和账本 + 加权 debt,~43 热路径 insn(7 store 字段)+ ~504 insn 容量增长尾(数组翻倍) | **无 external-token 注册表**(grep 0 命中)。外部/大分配走 js_malloc_large→js_def_malloc,仅 2 标量;js_malloc_large 的 list_add_tail 被 `JS_MALLOC_USE_ITER`(已注释)门控编译掉 | zjs ~43 + 500 尾 vs qjs **~5(2 字段)** | **REDUCIBLE** | ⚠️**不在对象热路径**(仅 string/bytecode/buffer 外部缓冲命中),优先级低。树内已有 registry-free 变体 reportExternalAllocUntracked(gc.zig:777)证明可机械削减:删 token 数组 + id,5 字段塌为单 external_bytes(镜像 malloc_size),函数变 leaf 去掉帧 prologue |

### 2.5 Shape 装配 / hash 查找 / transition

| 位置 | zjs 做什么 | qjs 做什么 | 指令差 | 证伪判定 | 忠实修法 |
|---|---|---|---|---|---|
| **shape-D1** object.zig:9588 appendPreparedPropertyEntry(atom guard) | 每 define(含稳态去重命中)对属性 atom 的 backing String 做 dup+free 往返:prologue rc++ + hit 返回 `bl String.releaseFromHeader` | dedup-hit 路径从不 dup atom;JS_DupAtom 仅在 add_shape_property(miss 路径),hit 从不到达 | zjs ~24 + 1 out-of-line bl vs qjs **0** | **REDUCIBLE** | hit 路径 atom 读到 transition commit 之间**无分配**,guard 无收益。删 guard-dup/defer-free 或提到仅 miss 路径(镜像 qjs 仅 add_shape_property dup)。guard 只为存活 cloneShape GC 点,hit 从不触碰 |
| **shape-D2**(与 obj-D4 同) object.zig:9632 arrayIndexFromAtom | 每属性 out-of-line ~22 insn,结果对 named 键丢弃 | 单 `tbnz w2,#31` | zjs ~22 vs qjs **1** | **REDUCIBLE** | 见 obj-D4。追加铁证:zjs internString 把所有 array-index 形式 ≤2147483647 tag 成 tagged-int,故非-tagged string 只有 10 位 `(2147483647, 4294967294]` 值才是索引(如 `obj["3000000000"]`,现实不存在)→bit31 对 100% 真实键完全定案;且两消费者只需 NULLNESS 布尔不需 u32 值 |
| **shape-D3** object.zig:9578 findProperty | own-property 探测是独立 68-insn out-of-line 帧(sub sp/ret + 栈 spill),经 `bl` 20+ 站点调用;含 zjs-only `steps<prop_count` 循环计数守卫(7 ccmp/b.cs) | find_own_property 是 `force_inline`(binary 零独立符号),~13-15 寄存器驻留 insn,无调用/帧/spill,与 define 逻辑共享寄存器 | zjs **68** vs qjs ~13-15 | **REDUCIBLE** | 树内已有精益等价 findPropertyProbeTrusted(object.zig:9845,用 assert 替运行时守卫,release 消除)+ findOwnDataValueFast(9875 `pub inline fn`)。把 definePlainDataPropertyKnownFast 路由到 inline trusted-probe 变体,`bl`+68-insn 塌为 qjs 的 ~13 内联 |
| **shape-D4** 4-帧调用树 | 稳态 hit 跨 ~4 嵌套帧 + ~5 real bl;appendPreparedPropertyEntry 单独 622-insn/0xd0 帧(save x19-x30 = 6 stp) | JS_DefinePropertyValue→DefineProperty→CreateProperty→add_property→add_shape_property,~4 帧但 qjs 把 transition-scan + slot-init + hash-insert **融进 1 个 116-insn add_shape_property leaf** | **实测 zjs 1453 vs qjs 692 insn/prop = 2.10x** | **REDUCIBLE**(非 partial) | 实测坍塌审计"深帧树不可避免":两引擎同模型(mutate ref_count==1 shape in place + shape-hash 重注册,该重注册是真地板)。可约:①arrayIndexFromAtom 内联(见 obj-D4)②把 definePlain→addProperty→appendPrepared→Registry.addProperty→appendProperty 链融成单帧快路径(镜像 add_shape_property)。地板下界 qjs ~692,目标 ~1.0-1.3x。⚠️大重构,appendPrepared 还服务 refcount>1 clone + array-exotic 路径须保留 |
| **shape-D5** shape.zig:649 ensurePropertyHash | 每 append 无条件跑 hash-容量复查 8 insn(shape.zig:627 relocate 翻倍 prop_size 但 bucketCount 不变→hash 滞后须每-append 复查) | resize_properties(quickjs.c:5354)在同一 realloc 里 new_hash_size 与 new_size **锁步增长**,故 add_shape_property 无每-append 复查,按现存 mask 无条件链接 | zjs **8** vs qjs **0** | **REDUCIBLE**(完全消除非 partial) | 镜像 qjs:shape.zig:627 relocate 时 bucket_count 锁步 `while(new_hash_size<new_size) *=2`,恢复不变量后 line 649 复查成死代码可删,−8 insn/append。⚠️仅静态反汇编 + 不变量分析,须复核无其他 caller 依赖延迟-hash-growth(reservePropertyHash/restorePropertyLayout 已显式增桶,appendProperty 是唯一解耦者) |
| **shape-D6** shape.zig:297 findHashedShapeProperty | 去重扫描内循环 **10 insn/iter**(融合 64-bit `ldr x,[x],#8` + eor + lsr#32/lsr#26),scan-only 对称区 59 insn,7-insn hash prologue | 同算法 **13 insn/iter**(两 32-bit load + eor/mask + 显式指针 bump),scan-only 60 insn,7-insn prologue | zjs **59** vs qjs **60** | **FLOOR_CONFIRMED** | 无需改,zjs **反而少 1 insn**。审计"69 vs 60"是**非对称范围选择伪影**:zjs 侧多算了 9 条 post-match 记账(retain rc-inc + callsite slot-swap,属对象-mutation 契约非扫描),qjs 侧截断在其自身 rc-inc 前一条。对称计数 zjs 59 vs qjs 60,真对称地板 |

---

## 3. 前沿排序(ROI)

### 3.1 REDUCIBLE / PARTIAL — 真赢机会(按 指令差 × 热路径 self% 排序)

> 热路径 self% 取 objalloc profile(分配主战场)。"综合 ROI"= 指令差幅度 × 该函数/路径 self%,并对"是否落在四基准共同热路径"加权。

| 排名 | 偏离 | 位置 | self%(bench) | 指令差(zjs→qjs 目标) | 判定 | 备注 |
|---|---|---|---|---|---|---|
| **1** | shape-D5 ensurePropertyHash 死代码 | shape.zig:649 | **9.68%**(objalloc,#2 全函数) | 8 → 0 /append | REDUCIBLE 完全 | **最高 ROI**:appendProperty 是 objalloc #2 热函数;单点锁步增桶即删 8 insn/append。首建路径(miss)热 |
| **2** | shape-D4 融合深帧树 | object.zig:9587 appendPreparedPropertyEntry + 链 | **6.62%**(objalloc)+ addProperty 2.69% + findProperty 1.88% | 1453 → ~692 /prop(2.10x→~1.0-1.3x) | REDUCIBLE 大重构 | 实测最大结构杠杆,但重构面广(须保 clone/exotic 路径),绝对赢是 objprop 一部分(defineField ~21% self-time) |
| **3** | GC-D3 阈值双查 | runtime.zig:1122 + 2042 | addWithSize 2.02% + createInternal 4.46%(嵌入) | 11 + N×8 → 5 一次 | REDUCIBLE | 删 registerObject 尾重查 + sub-alloc 传 NoTrigger;四基准共有(每对象分配都付) |
| **4** | GC-D1 记账风暴收窄 | gc.zig:1138 | addWithSize 2.02% + recordHeapFreeWithBytes 1.76%(内联) | 35-50 → ~6 /alloc | REDUCIBLE | 8/9 字段惰性化;object+shape 各触发一次故实际 ×2。⚠️须与 GC-D4 协调(保 debt 去 per-alloc 加权) |
| **5** | obj-D4 / shape-D2 arrayIndexFromAtom | object.zig:9632 | 0.54%(objalloc,偏小)| 22-26 → 1-2 /prop | REDUCIBLE 完全 | ×3/字面量、每属性;self% 比审计暗示的小,但 named 支可完全消除,低风险单点内联 |
| **6** | AL1 createInternal 按值 Record | object.zig:1268 | **6.23%**(emptyobj)/4.46%(objalloc) | 45 → 7 | REDUCIBLE | record() 改指针只读 + class_id switch 跳 layout 派生;emptyobj/objalloc 共热 |
| **7** | str-D1 string GC-check rider | runtime.zig:1112(内联 string.zig:647) | allocAlignedBytesNoTrigger 3.24%(strconcat)| 10 → 0 /string-alloc | REDUCIBLE | 从通用漏斗按类型门控排除 string;strconcat 专属 |
| **8** | AL4 valuesRequireNoRoots 预扫描 | array.zig:135 | arrayFrom 8.60%(array3,嵌入)| 32 → 0 | REDUCIBLE 完全 | 单个 ValueRootFrame slice 注册替预扫描;array3 专属 |
| **9** | AL2 数组根 shape 缓存 | shape.zig:215 | createInternal 内嵌 | 14-20 → 4 | REDUCIBLE | 缓存 array_shape 指针;array3 专属 |
| **10** | AL3 min-16 过分配 | object.zig:3558 | ensureArrayBufferCapacity 5.05%(array3)| 字节 256→48B(指令次要)| REDUCIBLE 完全 | 单-token `16→needed_len`;省内存/size-class 压力,指令收益小 |
| **11** | shape-D3 findProperty 内联 | object.zig:9578 | findProperty 1.88%(objalloc)| 68 → ~13 | REDUCIBLE | 路由到树内已存 findPropertyProbeTrusted;去调用+帧+spill |
| **12** | obj-D3 slab 线性阶梯→算术 | memory.zig:559 | createWithFamInternal 2.96%(objalloc)| 扫描 26 → 10 | PARTIAL | size-class 算术索引;shape 分配每次付 |
| **13** | obj-D2 destroyFromHeader payload 链 | object.zig:1766 | 2.15%(objalloc)/7.04-7.12%(array3/emptyobj)| 分派 40 → 3(全 199 仅 20% 可约)| PARTIAL | payload-kind 链 switch 化;free 侧四基准共热(array3/emptyobj destroyFromHeader ~7%) |
| **14** | GC-D2 页几何归零 | gc.zig:216 | 内联 addWithSize | 10-35 → 6 /alloc | REDUCIBLE(契约 off-path 保留)| 惰性派生 committed/free;须保测试断言契约 |
| **15** | shape-D1 atom guard 往返 | object.zig:9588 | appendPreparedPropertyEntry 6.62% 内 | 24 + 1 bl → 0 /define | REDUCIBLE | 删 hit 路径 guard-dup/free;与 shape-D4 同函数,可一并处理 |
| — | GC-D4 加权 debt | gc.zig:1144 | 内联 | 13 → 0 /alloc | REDUCIBLE | 与 GC-D1 协调 |
| — | GC-D5 external-token | gc.zig:756 | **不在对象热路径** | 43 + 500 尾 → 5 | REDUCIBLE 低优 | 仅 string/buffer 外部缓冲命中 |
| — | str-D5 单体帧膨胀 | value_ops.zig:920 | stringAddStringInt 8.01%(strconcat)| 368B 帧 6 组 save/restore 可约 | PARTIAL | 拆冷臂 noinline;算法层 zjs 已净胜(str-D2) |
| — | str-D4 GC-check rider | memory.zig:647 | createUninitialized 1.32%(strconcat)| 核心 4 组件地板,rider 可约 | PARTIAL | 与 str-D1 同 rider |

### 3.2 FLOOR_CONFIRMED — 已证实忠实地板(附 qjs 指令数,勿碰)

| 偏离 | 位置 | zjs | **qjs 指令数(证)** | 结论 |
|---|---|---|---|---|
| **obj-D5** defineField 快路径 | vm_literal.zig:171 | ~47 taken 前导 | **~138 taken 前导** + 2 完整栈帧 + 2 对栈金丝雀 + 全参数 reload(JS_DefinePropertyValue ~28 + JS_DefineProperty miss 76 + JS_CreateProperty miss 34) | zjs 2.9x 领先,qjs 唯一 define 入口的结构成本;zjs 无冗余、守卫忠实必需 |
| **str-D2** int→string 融合 | value_ops.zig:920 | concat 机制 ~334 insn/op,**1 次堆分配** | concat 机制 **~637 insn/op,2 分配 + 2 free**;qjs 无 small-int 缓存,临时 digits 分配对所有 i 不可避免(perf:__js_malloc 16.41% + __js_free 7.68% + ConcatString 系列 65.43%) | zjs 净胜近 2x 且已在 1-alloc 理论下限,方向与常规 REDUCIBLE 相反 |
| **AL5** array .length 语义 | object.zig:8709 | ~1 合并 store(与 flags 共享),1 次写 | **~6 insn,2 次写**(init-0 `stp xzr,xzr` + set_value 改 N 含 load-old + tag-check + branch),占 16B prop[0] 槽 | zjs 严格优于 qjs;审计"平价"偏保守,zjs 已在/低于 qjs 地板 |
| **shape-D6** 去重扫描内循环 | shape.zig:297 | scan-only **59 insn**,内循环 10 insn/iter | scan-only **60 insn**,内循环 13 insn/iter(两 32-bit load + 显式指针 bump);hash prologue 7=7 | zjs 反而少 1 insn;审计"69 vs 60"是非对称范围伪影(zjs 多算 9 条 post-match 记账)。真对称地板 |
| **str-D3** int digits(方向反转) | runtime.zig:2145 | cache-hit ~4 逻辑 insn,digit 串堆常驻 | **40+ insn 每次格式化**(i32toa umull div-by-10 循环)+ **每次 1 次 js_new_string8_len 分配** + i32toa 内 memcpy | 审计"qjs 内联 i32toa"前提反汇编证伪(3 out-of-line 调用);zjs 已更省,无可约地板 |
| **str-D4 核心 4 组件** | memory.zig:647 / string.zig:637 | slab pop + 12B JSString + 3-store init + out-of-line memcpy | **~50 insn**(js_alloc_string ~14 + __js_malloc arena-pop ~36);init 3-store 逐字节等同,JSString 12B 逐字节等同 | 4 组件真地板;仅外挂的 GC-check rider 可约(str-D1) |

---

## 4. 与已知历史的关系

### 4.1 确认了旧结论
- **F1(refreshSpacePageState 从"地板"证伪成 zjs 独有分布式开销)模式全面复现**:本轮 REDUCIBLE 判定几乎全是同一病理——被框成"共享地板/qjs 也做"的成本,反汇编后是 zjs 独有的、qjs 用 1 条指令或 0 条绕过的水平税(GC-D1/D2/D3/D4/D5、obj-D1/D4、AL1/AL2/AL4、str-D1、shape-D1/D2/D3/D5)。**memory 里"结构性地板=不可碰"框架被 demo/charcode 双双推翻的直觉,本轮在分配层再次被证实**。
- **构建非确定性 ±2.8% 陷阱被正确规避**:ground-truth 明确 cross-engine 固定二进制比率不受 same-source before/after 布局噪声影响,且 insn 计数 <0.03% 抖动 → 无需 A/B 交错。所有证伪结论基于精确地址区间归因 + 源码,非全函数计数,不受函数体量干扰。
- **"qjs 是唯一 perf 尺"纪律遵守**:全程只对 qjs 比,FLOOR_CONFIRMED 全附 qjs 指令数。
- **"地板断言先实测/反汇编"纪律**:审计员多处原判(str-D3 qjs 内联 i32toa、shape-D6 69 vs 60、AL2 hash-walk 归因、GC-D5"qjs 也做记账")被反汇编逐一纠正。

### 4.2 F1/G2/H1 之后的**新发现**
- **shape-D5 hash-容量与 prop-容量解耦(全新结构杠杆)**:shape.zig:627 relocate 翻倍 prop_size 却不动 bucketCount,造成每-append 死代码复查 8 insn。这是 objalloc **#2 热函数(9.68%)** 上的可完全消除项,**本轮最高 ROI 且此前 memory 未记录**。qjs resize_properties 锁步增长的对比是全新对齐锚点。
- **GC-D3 阈值双查(全新)**:registerObject 尾(runtime.zig:1122)重复 createInternal 入口已做的阈值检查,+ 21 个 sub-alloc 各查一次。qjs 恰一次的对比此前未量化。
- **GC 记账"仅 allocation_debt 承重、其余 8 字段冷"的精确判定(深化 F1)**:此前 memory 提过 F1 lazy-page-state,本轮把字节账本的 9 字段逐一追到读者,证明 8/9 可惰性化 + 1 承重字段与 qjs malloc_size 1:1 平价——比历史"trim-counters 刀"更精确。
- **AL1 按值 Record materialize 的 SIMD 税(全新)**:createInternal 顶部 6 条 `ldp/stp q` 把 88B class.Record 拷回栈,qjs 是 1 条 strh + 6 条 int 跳表。这是 emptyobj **6.23%** 上的可约项。⚠️修正了审计把此序列误认为 shape hash-walk 的归因错误。
- **ground-truth #1 意外:checkedLocVm 不在分配审计**(vm_property_locals.zig:176):四基准 #1 self%(14.86-27.61%)是 VM per-op checked-local 分派税,**比任何单个分配函数占的墙钟份额都大**。这是分配审计的**盲区**——微循环墙钟差的一大块是解释器 per-op 开销(checkedLocVm + coldStd 分派 handler 7% + Stack.pushOwned + setSlotValueRefCounted),不是分配器。**下一轮前沿应把 VM 局部槽/dispatch 纳入,与"call-align"谱系接轨**。
- **strconcat 的 toStringValue(6.44%)+ memcpyFast(6.36%)只被审计部分覆盖**:审计的 smallIntString/createUninitialized 注记(各 1.32%)远小于实际 int→string + payload copy 的合计份额。

### 4.3 与 objalloc 历史带一致
本轮 objalloc 2.42x / 2.44x insn 落在 memory 记录的历史带(2.24-2.63x)内,确认前几轮(F1 lazy-page-state / G2 length-prefilter / H1 defineField 放宽 / findOwnDataValueFast lean probe)的落地效果稳定,未回退。

---

## 5. 方法学与置信度

### 5.1 证据强度分级
- **最强(反汇编逐地址 + 源码 + 实测三重)**:shape-D4(实测 1453 vs 692 insn/prop,delta 法隔离,确定性 ±0.2%)、str-D2(perf 逐符号 + 源码逐行 + 绑核 pmuv3_1 稳定)、obj-D5(逐指令 taken-path 核对)。这三处结论可直接采信。
- **强(反汇编逐地址 + 源码不变量)**:GC-D1/D2/D3/D4、obj-D4、AL1/AL2/AL3/AL4、str-D1/D3、shape-D1/D2/D3/D5/D6。指令数是源码级事实,不受布局噪声影响。
- **需回归验证(静态分析未跑基准)**:
  - **shape-D5**:仅静态反汇编 + 不变量,**须复核无其他 caller 依赖延迟-hash-growth**(已初判 appendProperty 是唯一解耦者,reserve/restore 已显式增桶)。
  - **GC-D1 + GC-D4 协调**:GC-D1 判 allocation_debt 唯一承重、GC-D4 判 debt 加权可去——两者**必须一起改**(保 debt 累加、去 per-alloc 加权、权重后移到决策点),单独动任一个会破坏 GC pacing。
  - **GC-D2**:committed/free/decommit 被测试契约断言(core.zig:3021/3071/3072/3078),**惰性派生实现必须保留这些断言通过**——不可删除模型,只能移出热路径。
  - **AL4 / str-D1**:须确认 zjs GC 确实扫描操作数栈窗口 slice(runtime.zig:1266 已初证)/ String 确不参与环收集(已初证 4B StringHeader 非堆图节点)后方可删预扫描/GC-check。

### 5.2 构建非确定性对结论的影响
- **本轮结论几乎不受 ±2.8% 布局噪声影响**:cross-engine 固定二进制比率(zjs `e617fdd` vs qjs)不是 same-source before/after,布局非确定性不进入比率;insn 计数 <0.03% 抖动。
- **但任何"落地修改"必须遵守 memory 纪律**:改源后 zjs 前后对比属 same-source,**必用交错 A/B best-of-N(before→改→建 after→10 轮交替取 min)**,单建 best-of-N 不足以区分 <300M insn 的差(本基准 ±1.5-2.8% ≈ ±160M-300M insn)。AL3 这类"字节收益、指令收益小"的改动尤其易落在噪声带内不可区分。

### 5.3 还需哪些验证(落地前 checklist)
1. **全量 test262 双 repr 门禁**(单/双 String repr):所有 shape/GC/alloc 改动是 all-or-nothing,门禁绿 exit0 known-13 是唯一 oracle;shape-D5 增桶不变量、GC-D1/D2/D4 惰性重算尤其要过。
2. **交错 A/B insn + cycles 同测**:memory 教训③"指令赢≠时间赢"(M1 −120M 但 wall-clock 中性=不在关键串行 load 链)——必同测 insn(work)+ cycles(是否在关键路径)。GC-D3/D4 这类分摊小项尤其可能藏 backend-stall 阴影。
3. **复现 ground-truth**:采信任何"赢点"前,先复现 objalloc 2.44x / strconcat 1.82x 的基线(measure_ab.sh,taskset 绑核,pmuv3_1 提取),再叠改动。
4. **优先级建议**:先做 **shape-D5(最高 ROI、单点、完全可消除、objalloc #2 热函数)**,再做 **GC-D3 + GC-D1/D4 协调(四基准共有、每对象付)**,shape-D4 大重构留到单点刀收割后(风险面最大、绝对赢是 objprop 一部分)。**VM checkedLocVm 分派税(四基准 #1)虽不在分配审计,是墙钟层更大杠杆,应另开前沿与 call-align 谱系接轨**。

### 5.4 诚实边界声明
- **不夸大**:所有 REDUCIBLE 均标注是"指令数结构性可约"(源码级事实),未声称必然转化为墙钟赢——须 cycles + 交错 A/B 坐实。shape-D4 的"目标 ~1.0-1.3x"是投影非承诺。
- **FLOOR_CONFIRMED 全附 qjs 指令数**:obj-D5(138)、str-D2(637)、AL5(6)、shape-D6(60)、str-D3(40+)、str-D4(50)——这些是"已达忠实最优/zjs 已净胜"的证据,勿在其上浪费迭代。
- **审计原判被证伪的方向已忠实呈现**:str-D3/shape-D6 是"zjs 已优于 qjs、审计基于错误 qjs 前提误标"的反转;AL2/AL1 的 shape-hash 归因错误已纠正为 record() 类记录查找;GC-D5"qjs 也做记账"被证伪为 zjs-only 注册表。

---

**关键文件索引(全绝对路径)**:
- `/home/aneryu/zjs/src/core/gc.zig:1138`(recordHeapAlloc 9 字段账本 + 1144 加权 debt)、`:216`(SpaceAccount.recordAlloc 页几何)、`:756`(reportExternalAlloc)、`:1071`(addWithSize)
- `/home/aneryu/zjs/src/core/shape.zig:649`(ensurePropertyHash 死代码,**最高 ROI**)、`:627`(relocate 桶不锁步根因)、`:297`(去重扫描,地板)、`:215`(createObjectRoot)
- `/home/aneryu/zjs/src/core/object.zig:1268`(createInternal 按值 Record)、`:1766`(destroyFromHeader payload 链)、`:3558`(min-16 过分配)、`:9578`(findProperty out-of-line)、`:9588`(atom guard)、`:9632`(arrayIndexFromAtom)、`:8709`(array_length 地板)
- `/home/aneryu/zjs/src/core/runtime.zig:1112`(requestGCForAllocation 通用漏斗 str-D1 根因)、`:1122`(registerObject 阈值双查 GC-D3)
- `/home/aneryu/zjs/src/exec/value_ops.zig:920`(stringAddStringInt,str-D2 地板 + str-D5 单体帧)、`/home/aneryu/zjs/src/exec/vm_literal.zig:171`(defineField,obj-D5 地板)、`:37`(pop 进裸局部,AL4 根因)
- `/home/aneryu/zjs/src/exec/vm_property_locals.zig:176`(checkedLocVm,**ground-truth #1 意外、分配审计盲区**)
- `/home/aneryu/zjs/src/core/array.zig:135`(valuesRequireNoRoots 预扫描 AL4)

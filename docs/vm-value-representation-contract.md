# VM 值表示契约(engine plan × tracing GC 同步点)

Version: 3
Date: 2026-09-06
Status: normative — 本契约是
[engine-evolution-plan.md](engine-evolution-plan.md)(§3.1 裁决 A 的
"表示定型"里程碑)、[type-directed-optimization-plan.md](type-directed-optimization-plan.md)
(§4/§5 的 GC 集成条款)与 [tracing-gc-design.md](tracing-gc-design.md)
的共同约束面。**修改本页所述协议 = 先改本契约并递增版本号,再动任一线
代码。**

来源:v3 全部条款自 **main 实物导出**(`8be2ca7d`,2026-09-06,
tracing GC 完成计划 S0–S5 合入之后),非设计意向。每条给出代码锚
(文件:符号;行号仅作历史参考,函数/常量名才是锚)。机器可读的表示
基线是 `src/gc-representation-trace-snapshot.txt`(`zig build
gc-representation-snapshot` 生成,`build/tests.zig`),本页与它不一致时
以快照与代码为准并修订本页。

## v3 changelog(v2 → v3,逐条)

v3 是**事实入册**,不含新设计。变化来源:TGC S0–S5(`e972c4b5` →
`f005aee7`,`docs/tracing-gc-completion-account.md`)、M 终态 Object 64B
(`docs/gc-v2-m-cut-object-layout.md`)、S3 atom 弱化。

| # | v2 条款 | v3 |
|---|---|---|
| C1 | 页首 Errata 块(4 条) | 删除;第 2/3 条(地址注册表机制、`conservative_on` 定义)按现物并入 §4,第 1 条(导出锚过期)由本次导出消解,第 4 条已在 v2 执行 |
| C2 | §1.1 `JSValue` 16B / `property.Slot` 布局不变 | 保留;`property.Slot` 从 `extern union` 变为 Zig 裸 `union`(16B 只在 ReleaseFast/ReleaseSmall 断言,Debug 带安全 tag),补 tag 表 |
| C3 | §1.1 `layout_epoch = 1` | **递增为 2**。真实表示事件:① heap BigInt tag 由 qjs 的 −9 迁到 −4(`value.zig:Tag.big_int`,tracer-owned tag 连成 `[−8, −1]` 一个区间);② 引用计数从所有 kind 退出,`JSValue.dup/free` 删除,host 持有改为 pin 账本(§4.3)——对直接处理 `JSValue` 的 managed 插件是所有权语义变化。`JSValue.abi_encoding_revision` 仍为 1(字段布局与 payload/tag 编码规则未变,只是 tag 值空间与生命周期语义变了,按 FNABI §11.3 归 layout_epoch 而非 encoding revision) |
| C4 | §1.2 非搬移 | 保留;补 sticky 标记位与 Object 手柄=体指针的锚 |
| C5 | §1.3「默认 rc 构建零痕迹,tracing 仅经实验门可达」 | **退役**。tracing 是树中唯一收集器,`-Dzjs_experimental_gc` 选项不存在,`gc_slot.zig` 已删。新 §1.3 = 全 kind 无引用计数 |
| C6 | 新增 §1.4 元数据前缀与 kind 字节 | S4-a/S4-h 终态 `BlockFlags` |
| C7 | 新增 §1.5 Object 终态布局 M | 64B 块 cell,`prop_values`@16,无 intrusive link |
| C8 | 新增 §1.6 载体家族 | 13 个 `RefKind`、prefix-carrier 与 block cell 家族、存储 cell 的单 owner 边 |
| C9 | §2 Slot 突变协议(retain→publish→release,`HeapValueSlot`,写审计) | **退役**(rc 序与 `gc_slot`/`gc_write_audit` 均已删)。新 §2 = 发布 + 屏障协议与存储 cell 三规则 |
| C10 | §3 屏障(`postWriteBarrier` + `BarrierCriticalScope`) | 按现物改写:`generationalBarrier`/`generationalBarrierValue`/`rememberOwnerForBulkWrite` + `barrierOwnerSkips` 门;`BarrierCriticalScope` 在 main 无对应物(标记在 owner 线程单线程推进,增量之间 mutator 运行,屏障同步染色) |
| C11 | §4 根模型 | 按现物改写:生产链接 container/window 帧、conservative 为生产设计、支持 ABI 扩至 x86_64、地址验证=块几何/arena 几何/页 radix 三层、`conservative_on` 现行定义、pin 账本、atom `host_pins` |
| C12 | §5 各阶段约束落点 | rc 期表述全部删除;§5.2/§5.3 改为屏障序 |
| C13 | §6 未决项 | 重列(R1 精确根、并行标记、typed/AOT 六契约、契约 v3 的 owner 评审) |

v2(2026-08-26)= FNABI ABI tuple 过渡 + layout_epoch 定义;v1
(2026-08-24)初版。两版均自 `gc/tracing` 分支导出,该分支已退役
(roadmap v2.0)。

---

## 1. 硬承诺(引擎线可以直接依赖)

### 1.1 `JSValue` 与 `property.Slot`

- **`JSValue` 16 字节 extern tagged 布局不变**:`{ payload: u64, tag: i64 }`,
  align 8(`src/core/value.zig:JSValue.Repr`,comptime 断言
  `@sizeOf == 16`/`@alignOf == 8`;`src/tests/abi_layout.zig` 把
  `ZjsJSValue` 绑到同一现实)。
- tag 值空间(`value.zig:Tag`):

  ```text
  symbol -8 | string -7 | string_rope -6 | (-5 空) | big_int -4 |
  module -3 | function_bytecode -2 | object -1 |
  int 0 | boolean 1 | null 2 | undefined 3 | uninitialized 4 |
  catch_offset 5 | exception 6 | short_big_int 7 | float64 8
  ```

  **tracer-owned tag = 一个连续区间 `[symbol, object]` = `[−8, −1]`**
  (`value.zig:tracer_owned_first_tag`,`cycleMarkHeader`/`isTracerOwned`
  用一次区间比较);heap BigInt 坐在 qjs 的 −4 空位而非 −9,这是与
  qjs 的**刻意偏离**。`cycleMarkHeader` 是「哪些 tag 带可追踪 header」的
  唯一定义;kind 加入 tracer 的时刻就是它被加宽的时刻。
- 对插件的表示承诺以 **FNABI ABI tuple** 表达:`FUN_VALUE_ABI` =
  (`layout_epoch`, `JSValue.abi_encoding_revision`)。**layout_epoch 现值
  2**(v3,理由见 changelog C3);`abi_encoding_revision` 现值 1
  (`value.zig:JSValue.abi_encoding_revision`,`abi_layout.zig` 钉住)。
  layout_epoch 只在真实表示变化(布局 / tag 语义 / 地址稳定性 / 所有权
  语义)时递增,与本文档版号解耦;见
  [fun-native-plugin-design.md](fun-native-plugin-design.md) §11.3。
- **`property.Slot` 16 字节不变**:`union { data: JSValue, accessor,
  auto_init, var_ref: *VarRef }`(`src/core/property.zig:Slot`)。它现在是
  Zig 裸 `union`(非 `extern`):16B 不变量只在 ReleaseFast/ReleaseSmall
  由 comptime 断言钉住,Debug/ReleaseSafe 带隐藏安全 tag。每对象属性
  存储只有值侧(`property.Entry = { slot }`),key atom 与 flags 在 Shape。

### 1.2 非搬移(non-moving)

- sticky-mark-bit 分代、增量标记、STW、无 copy/compaction,地址稳定性是
  设计保证(`src/core/gc_trace_stw.zig`;`docs/gc-invariants.md`
  「Ownership is all-tracing」)。缓存的对象 / shape 指针**永不因 GC 失效于
  地址**——但生命周期不在承诺内(见 §5.2)。
- **Object 手柄 = 体指针**:`gc.bodyOffsetFromHeader(.object) == 0`
  (comptime 断言,`gc.zig:bodyOffsetFromHeader`),其余所有 kind 体在
  手柄 +8(一个 `TraceHeader` 链接字)。Object **没有** intrusive 链接
  字(块位图枚举它),`TraceHeader.next_non_object` 只对非 Object kind
  有意义(`gc.zig:TraceHeader.nextNonObject` 有 kind 断言)。

### 1.3 全 kind 无引用计数

- tracing 收集器是树中**唯一**收集器:`build.zig` 无 GC 选择选项(仅
  `-Dzjs_force_gc`、`-Dzjs_gc_roots_diag`、`-Dzjs_ownership_audit`),
  构建指纹 `gc_layout=obj64_m`(`build/config.zig`)。
- `RefCountHeader`/`StringHeader`、`gc.retain`/`release`、
  `JSValue.dup`/`free`、`AtomTable.dup`/`free`、`DynamicAtom.ref_count`、
  `weakref_count`(对象侧)全部删除(`docs/gc-invariants.md`
  「Ownership is all-tracing」;完成对账 §1「rc 归零」行)。**任何
  形式的引用计数回归 = 契约违规**。唯一保留的非堆计数:atom 表条目的
  `weakref_count`(WeakRef 观察 atom 死亡的壳计数,`atom.zig`)。
- Shape 无计数:`ShapeOwnership.shared: u32` 是 sticky 的
  copy-on-write 位(第二个持有者采纳时 `Shape.markShared`,永不清零);
  未共享 shape 由唯一持有者的放弃立即释放,共享 shape 交给 sweep
  (`shape.zig:markShared`/`isShared`)。

### 1.4 元数据前缀与 kind 字节

每个 GC 分配前有 **8 字节 `Metadata` 前缀**(`gc.zig:Metadata`,
`metadata_prefix_size == 8`,align 8;字节偏移由
`gc_representation_constants.zig` 与 `memory.zig` 的裸字节写入共同钉住):

```text
offset 0  size_class : u16   块 cell = cell index;slab = allocator block idx;standalone = 编码堆字节数
offset 2  alloc_info : u8    block_size_idx:u5 | reserved | heap_accounted(0x40) | standalone(0x80)
offset 3  flags      : u8    kind:u4 | young(0x10) | finalizing(0x20) | needs_finalizer(0x40) | reserved(0x80)
offset 4  lifetime   : 4B    mark_epoch:u16 | object_shape_summary:u7+remembered:u1 | reserved:u8
```

- `kind` 占低 nibble(`kind_mask = 0x0f`,S4-a 从 3 位扩到 4 位);
  `young` 是 sticky 代位(发布时置,存活一次收集后清);
  `needs_finalizer` **只置不清**(D-S4-4):sweep 只访问
  `doomed & needs_finalizer`,其余尸体由位图回收,header 不被读。
- `mark_epoch == 0xffff` = **condemned**(`gc.zig:condemned_mark_epoch`,
  永不作为活 epoch);0 = 新生/未标记。「marked」与「condemned」按构造互斥。
- `alloc_info.block_size_idx == 0x1f` 唯一标识**块 cell**
  (`gc_representation_constants.zig:block_cell_size_class`;
  `Registry.isBlockCellHeader`)。空闲块 cell 的字为 `0x8600_0000 | next`
  毒值,拒绝它被当作 header 读的是 `heap_accounted == 0` 加 condemn 戳,
  不是 kind nibble。
- `heap_accounted` = **发布位**:未发布的 owner 不得被屏障记忆或排队
  (§2)。

### 1.5 Object 终态布局 M(64B)

`src/core/object.zig:Object` comptime 断言(全部 ReleaseFast 生效):

```text
Object 头 24B:flags(u32)@0 | class_id@4 | shape_ref@8 | prop_values@16
+ class arm(窄 8B / 宽 24B,unionArmBytes(class_id))
+ 可选 trailing 2 个 property.Entry(仅 ids.object,slots2 形态,@24)
Metadata 8B + 普通对象 slots2 体 56B = 64B 块 cell(objectBodyBytes(ids.object,true)==56)
宽臂类(array/arguments/mapped_arguments/string/regexp/四种 bytecode 函数)体 48B → ≤64B cell
```

- `prop_values` 是 qjs `JSObject.prop` 的常驻指针:指向空哨兵
  (`emptyPropertyStorageBase`)、slots2 内联 tail(`Object+24`)或一个
  **`.property_storage` 块 cell 的体**(`Object.createPropertyStorageCell`
  是唯一漏斗)。cell 体就是 `prop_values` 指向处,所以偏移 16、空哨兵与
  内联 tail 全部不变,`propertyEntry()` 只重载一个指针。
- **重排 `Object` 字段或 `ObjectStorage` = 表示变更**,须独立测量与
  本契约递增(`docs/gc-invariants.md`「Representation」)。typed 计划
  R7:slot 访问必须 `load [obj+16]` 再索引,禁止折叠为 `obj+const`。

### 1.6 载体家族

`gc.RefKind = enum(u4)`,13 个值(`gc.zig:RefKind`):

| tag | kind | 载体 | 体偏移 | 边 |
|---|---|---|---|---|
| 0 | object | 块 cell(或 standalone) | 0 | `Object.traceChildEdgesFallible` |
| 1 | function_bytecode | slab/standalone | 8 | realm、cpool、atom 操作数 |
| 2 | var_ref | slab/standalone | 8 | value |
| 3 | realm_context | slab/standalone | 8 | `JSContext.traceChildEdgesNoFail` |
| 4 | module | slab/standalone | 8 | `ModuleRecord.traceChildEdgesFallible` |
| 5 | shape | slab/standalone | 8 | `Shape.traceChildEdgesFallible`(proto、atom) |
| 6 | string(flat) | 块 cell / extent | 8 | 叶 |
| 7 | big_int | slab/standalone | 8 | 叶(`gc_obj_list` 上) |
| 8 | property_storage | 块 cell / extent | 8 | 叶,owner 边 |
| 9 | array_storage | 块 cell / extent | 8 | 叶,owner 边 |
| 10 | payload | 块 cell / extent | 8 | 叶(体内容由 owner 的 payload trace 走) |
| 11 | rope | 块 cell / extent | 8 | `string.traceRopeEdges`(left/right/tail buffer) |
| 12 | string_buffer | 块 cell / extent | 8 | 叶,rope 边 |

- **prefix carrier**(`gc.kindIsPrefixCarrier`:6/8/9/10/11/12):体紧跟
  8B 前缀、无 `TraceHeader` 链接字、不上 `lists.objects`、standalone 形态
  是块堆 **extent** 而非 slab 分配。
- **存储 cell**(8/9/10/12)的生命由**唯一 owner 边**决定:无根命名它、
  无第二持有者、无析构、叶。owner 边的权威:
  - 属性缓冲:`tracePropertyEdgesFallible` 顶部的 `storageCell(prop_values)`
    (仅当 `propertyStoragePointerIsExternal`);
  - 元素缓冲:`Object.denseArmNamesStorageCell`(2026-09-06,backlog Q21)
    ——class ∈ {array, mapped_arguments, arguments 且
    `class_payload_kind == .none`} 且 `capacity != 0`,**由类与臂推导,
    不由 `flags.fast_array` 语义位决定**;trace、footprint 记录器与
    `verifyObjectPropertyStorageLayouts` 审计三处共用同一谓词;
  - a 类 payload:`hasTracerOwnedPayloadCell` 后的 `callVisitStorageCell`;
  - rope tail:`traceRopeEdges`。
- 块堆几何:64 KiB 块、2 MiB superblock、一块一个 size class、只整
  superblock 释放(`gc_block_heap.zig` 头注)。

## 2. 堆边突变协议(发布 + 屏障)

v2 的 retain→publish→release Slot 序随 rc 一起退役。现行协议:

1. **先初始化,后发布**:`heap_accounted` 置位(发布)时 tracer 走一次
   初始边(`markPublishedYoungClassified`);发布前的字段写不需要屏障,
   发布后的每次强引用写需要(§3)。对未发布 owner 调屏障 = 调用方 bug。
2. **强引用写 = 存储 + 屏障**,屏障在存储**之后**、同一函数内同步调用
   (`Object.setFastArrayElementDup`:`slot.* = v;
   rt.gc.generationalBarrier(owner, v.cycleMarkHeader())`;
   `barrierPropertySlot` 同形)。bulk 写(memcpy、采纳整块缓冲、shape
   compaction)在写**之前**调 `rememberOwnerForBulkWrite(owner)`。
3. **存储 cell 三规则**(`docs/gc-invariants.md`):
   - **铸造与安装相邻**:裸 cell 在精确扫描下无根,中间任何分配都可能
     回收它;分配压力请求(`requestGCForAllocation`)在铸造**之前**。
   - **增长不释放旧 cell**,旧 cell 留给 sweep;安装提前到可分配的
     reserve 之前。
   - **bulk 写记忆 owner**。
4. 绕过这些入口直写堆引用字段(无屏障)= 契约违规;检出机制是
   `ZJS_MINOR_AUDIT`(`UNBARRIERED-STORE` 报告,`gc.zig`)与
   `ZJS_GC_VERIFY_MINOR`。

## 3. 屏障形状

入口(`gc.zig:Registry`):

```text
generationalBarrier(owner: *Header, child: ?*Header)
generationalBarrierValue(owner: *Header, child: JSValue)   // child 经 cycleMarkHeader 解码
rememberOwnerForBulkWrite(owner: *Header)
```

- **快路径 = 一次 8 字节 owner 元数据加载 AND `hot.barrier_gate`**
  (`barrierOwnerSkips`,JSC 两步门形状)。只有 `young` 与 `remembered`
  两位可以买到退出;门值由阶段决定(`expectedBarrierGate`):标记进行中
  或 `--gc-stats` 详细报告时门为 0(每次写都进慢路径)。安全构建在每次
  屏障调用重算门值断言不陈旧(C1)。
- **慢路径两臂互斥、不叠加**:
  - 标记进行中(`incremental.markingActive()`):**incremental-update,
    染色精确新目标**(`shadeForIncrementalMark`;`gc_incremental.zig`
    头注)。不读 owner 颜色、无 owner-rescan 位,代价=可能保活一轮
    floating garbage。Shape / Realm 目标走 owner-requeue 臂(只对已黑
    owner 重排队)。
  - 否则:分代 remember-owner——目标 young 且 owner old 未记忆时把 owner
    记入 remembered set(`rememberGenerationalOwner`,header 字节 6 bit7
    `trace_remembered_mask`)。
- bulk 屏障在标记中**重排队 owner**(而非染目标),黑数组的中周期 append
  因此可见(`rememberOwnerForBulkWrite` 注释)。
- **线程模型**:增量 major 在 runtime owner 线程上推进,没有 marker
  worker,`major_marking_active` 是普通 `bool`(`gc_incremental.zig`
  「Single-threaded, deliberately」);增量之间 mutator 运行,屏障同步
  完成染色,因此 v2 的 `BarrierCriticalScope`(store 与 shading 之间禁
  safepoint)在 main **没有对应物**——同一条件由「屏障在存储所在函数内
  同步调用」满足。S4-b 并行标记**已撤回**(同一注释;若重新引入,
  §8.4 的撕裂前提使 owner-only 记录不 sound,须回到本节修订)。
- JIT/asm 侧预留的 patchable 位对应上述三个签名(§5.3)。

## 4. 根模型

### 4.1 精确根

`JSRuntime.traceActiveRoots`(`runtime.zig`):`ValueRootFrame` 链
(`active_value_roots`)、活动 job 根、`ActiveInvocationTrace`(解释器帧与
操作数栈)、Atomics.waitAsync 等待者、`runtime.traceRoots` 的 root
provider、pin 账本(§4.3);minor 另加 `atoms.traceYoungSymbolBodies`。

`ValueRootFrame`(`runtime.zig:ValueRootFrame`)= `{ previous, slices,
values, objects, headers, atoms }`;**生产只链接 container/window 帧**
(`value_root_link_containers_only = !is_test and !zjs_gc_roots_diag`),
标量 `rootValues`/`rootObjects` 作用域在生产被编译掉;测试与
`-Dzjs_gc_roots_diag=true` 构建链接每一个 activate。`atoms` 槽
(`AtomRootSlot`)是 S3 的 class B 根:跨可 GC 点持有裸 atom id 的原生帧
必须在此声明。

### 4.2 保守扫描(生产设计)

- `gc_conservative.zig`:寄存器溢出 + 原生栈按机器字扫描,候选**永不
  解引用**。**已实现 ABI**:aarch64-linux/macos、x86_64-linux/macos/
  windows;其它目标 `@compileError`(`target_supported`)——tracing
  收集器不允许在无扫描器的目标上退化为精确-only。
- 候选验证三层(`gc_address_registry.zig` 头注,取代 v2 的「页 radix
  注册表」描述):块 cell 按**块几何**、slab 对象按 **arena 几何**、
  只有 standalone-prefix 分配走 4 KiB **页 radix** 占位表。
  header / metadata 前缀 / interior / one-past-end 才算根。加入 tracer
  的新 kind 必须在同一 commit 可经此路径解析。
- **`conservative_on` 现行定义**(`gc_trace_stw.zig:Collector.init`):

  ```zig
  if (!builtin.is_test) !rt.gc.scheduler.host_quiescent
  else (rt.test_root_scan_override orelse scan) == .engine_active
  ```

  生产:host-quiescent 触发(显式 forceGC、事件循环 idle)精确-only,
  其余(分配阈值、safepoint、回调边界)加保守趟。测试:按触发的
  `GCPollMode.rootScan()`——`engine_active` 触发开保守(mutator 原生帧
  在栈上,精确模式在该场景被证不 sound),`declared_only` 触发保持精确
  以让活性测试确定、漏根仍以 SEGV 暴露。v2「`conservative_on =
  !is_test`」的表述作废。
- 推论:**新增「原生代码持堆引用跨可 GC 点」的路径,必须挂
  container/window `ValueRootFrame` 或等价 rooted 传递**;标量本地目前
  由保守扫描兜底,R1(§6)未落地前删除或收窄保守扫描是正确性变更。

### 4.3 pin 账本与 host 根

- **pin 账本是权威**(`gc_registry_pins.zig`):host pin 是绑定层取得的
  正计数(`JS_DupValue` 形所有权,住在 JS 堆之外),构造根是保留的
  `construction_pin_count`;header 上**没有** pin 位(S4-e 删除)。
- atom 表条目的 `host_pins`(`PropNameID.internStatic`/`release`)是
  tracer 看不见的 ABI 侧根;atom 活性 = `visitAtom` 边 ∨ body 已标记 ∨
  `host_pins != 0` ∨ 本周期黑分配(`tracing-gc-s3-spec.md` §2.2/§2.4)。
  **每个裸 atom id 的持有者必须由拥有它的权威 trace 报告 `visitAtom`**
  (shape 属性 atom、FunctionBytecode 名与 var-ref 名经
  `atomOperandIterator`、module 记录、`CompileAtomScope`)。
- 成员列表不是根(`context_head` 等回答「谁拥有」不是「是否存活」);
  realm 只在 host create-ref 未消费时是根。

## 5. 对 engine plan 各阶段的约束落点

### 5.1 Phase 0(VmExecState / HelperDescriptor)

ABI 只含指针与出口协议,不编码值内部;`can_gc` helper 边界 = 发布 seam
= §4 的可观察点。无冲突,可并行。

### 5.2 Phase 0.5(反馈槽)与 typed guard —— 高危约束

- 槽内缓存的 shape 指针 / callee identity 是**非持有引用**:§1.2 保地址
  不保生命周期;tracing 延迟回收下同址重分配的 ABA 仍存在(在册前科:
  M2 资格链缓存)。**槽命中必须经版本 / 纪元验证后才可解引用或比较**;
  typed 计划 R5:F1 的判据是 `ShapeOwnership.shared` sticky 位与 FAM
  增长换址(`relocateShape` 释放并重建结构),不是 rc==1。
- 反馈槽 side table **登记为「非 GC 边」**:边审计须知道它存在且刻意
  不追踪。
- 失效钩子(shape transition / free)与版本号的选择,须与 GC 线同桌
  评审一次成文。

### 5.3 Phase 2(baseline JIT)与 AOT 发射

- **值移动经抽象层发射**,发射的是 §3 的屏障序:每条堆引用存储后发
  `generationalBarrierValue(owner.gcHeader(), v)`(owner 是 Object,不是
  cell);快门 `barrierOwnerSkips` 可内联,safety 构建带门断言;连续写用
  `rememberOwnerForBulkWrite`(typed 计划 R9)。emitter 硬编码任何计数序
  = 契约违规。
- JIT / AOT native 帧的 GC 正确性由 §4.2 保守扫描覆盖(不需精确 stack
  map 才正确),但 AOT 帧同样贡献残渣 / floating garbage(typed 计划
  R17);safepoint metadata 从 v0 记录(优化项)。
- 增量之间 mutator 运行:生成代码里的屏障必须与存储在同一不可被
  safepoint 打断的序列内(与解释器同规则;§3 线程模型)。

### 5.4 Phase 1-Z / 1A(解释器骨架,条件项)

值移动生成宏(engine plan §7.4)对接 §2 同一协议:宏只产出「存储 +
屏障」序,handler 文本不变。

## 6. 未决项(本契约不覆盖,谁先碰谁立项)

- **R1 全精确根**:R1-a 实证六个可归因窗口中只有 regexp 匹配数组是真
  缺根,其余是 LLVM 栈槽残渣与调用方 callee-saved 溢出;正路 = 缩帧 /
  擦栈 + cold 出口 publish(完成对账 §6 第 6 条)。落地前 §4.2 保守
  扫描是生产设计。
- **并行标记**:S4-b 已撤回(`gc_incremental.zig`);重新引入须先修订
  §3(屏障撕裂前提)并过 `docs/gc-v2-s4b-parallel-marking-gate.md`。
- **typed / AOT 六契约**(typed 计划 v1.3 R8):根、窗口、安全点/
  publish、屏障、artifact 不携带 Runtime-local 身份(atom 落盘为字符串)、
  lowering 禁止 `obj+const` 折叠——在 PERF-TYPED-IR 开工前并入本契约
  正文。
- 弱引用 / finalizer 与反馈槽失效钩子的统一注册表(Phase 3 dependency
  registry 的 GC 侧对应物)。
- **本页 v3 为 driver 导出的草案,待 owner 评审**(roadmap v2.0
  VM-CONTRACT-GC);评审通过前 layout_epoch=2 只在本页与
  fun-native-plugin-design.md 登记,尚无代码常量承载它。

**已知的旁注(不属本契约,记录以免误引)**:`docs/gc-invariants.md`
「Heap BigInt」段仍写 tag −9,代码是 −4(`value.zig:Tag.big_int`);
`gc-representation-trace-snapshot.txt` 的 `heap_accounted ... false for
string/big_int` 一行早于 S2/S1-c,是否仍成立**未验证**;
`atom.zig:DynamicAtom.str` 的注释仍提及 ref count。

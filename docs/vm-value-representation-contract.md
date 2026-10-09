# VM 值表示契约

Version: 4
Date: 2026-09-23
Status: normative — 本契约定义 VM 值表示与 GC 的共同约束面，
收集器规则见 [gc-invariants.md](gc-invariants.md)。**修改本页所述协议 = 先改本契约并递增版本号,再动任一线
代码。**

来源:v3 全部条款自 **main 实物导出**(`8be2ca7d`,2026-09-06,
tracing GC 完成计划 S0–S5 合入之后),非设计意向。每条给出代码锚
(文件:符号;行号仅作历史参考,函数/常量名才是锚)。机器可读的表示
基线是各载体 struct 旁的 comptime 断言(`gc.zig`、`object.zig`、
`gc_representation_constants.zig`),本页与代码不一致时以代码为准并修订本页。

## v4 changelog

增加独立于物理 Header 的 opaque `HeapRef` 编码边界：堆地址必须非零、
8 字节对齐且完整落在 48-bit payload 中，装箱不得先掩码再验证。
`heapReference`／`isHeapReference` 表达表示类别，不证明堆成员资格或 Runtime 归属。
重定位适配归堆布局层，保留原 tag，并校验载体 kind；旧 Header API 保留兼容入口。
JSValue 仍为 8 字节，tag 编码和 `abi_encoding_revision = 2` 不变。
本次递增的是文档契约版本，不是二进制编码版本。

## v3 changelog(v2 → v3,逐条)

v3 是**事实入册**,不含新设计。变化来源:TGC S0–S5(`e972c4b5` →
`f005aee7`)、M 终态 Object 64B、S3 atom 弱化。

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

- **`JSValue` 8 字节 NaN-boxed**:`{ bits: u64 }`, align 8
  (`src/core/value.zig:JSValue`; float64 为 IEEE 位，NaN 规范化；其余 kind
  为 16-bit 前缀 `0xFFF0 + index` + 48-bit payload。`index` 把 Kind 稠密
  编进 1..15，跳过 −5 空位：symbol→0xFFF1，object→0xFFF7，int→0xFFF8，
  short_big_int→0xFFFF。`tagOf` 是算术，无查找表。tracer-owned 是 raw
  word 区间 `[0xFFF1_0000_0000_0000, 0xFFF8_0000_0000_0000)`)。
  语义 tag 编号仍见 `Kind`/`Tag`。`value.zig` 的 comptime assert 钉
  8 字节布局与 `abi_encoding_revision`。
- tag 值空间(`value.zig:Tag`):

  ```text
  symbol -8 | string -7 | string_rope -6 | (-5 空) | big_int -4 |
  module -3 | function_bytecode -2 | object -1 |
  int 0 | boolean 1 | null 2 | undefined 3 | uninitialized 4 |
  catch_offset 5 | exception 6 | short_big_int 7 | float64 8
  ```

  **tracer-owned tag = 一个连续区间 `[symbol, object]` = `[−8, −1]`**
  (`value.zig:Tag.symbol`,`heapReference`/`isHeapReference`
  用一次区间比较);heap BigInt 坐在 qjs 的 −4 空位而非 −9,这是与
  qjs 的**刻意偏离**。分类由 `value_encoding.isHeapReference` 定义，
  `cycleMarkHeader`／`isTracerOwned` 保留转发兼容；kind 加入 tracer 的时刻就是分类加宽的时刻。
- 表示修订以 `JSValue.abi_encoding_revision` 记录（现值 2，由
  `value.zig` comptime assert 钉住）。历史 FNABI 的 `FUN_VALUE_ABI` =
  (`layout_epoch`, revision) 已随公开 ABI 撤回；**layout_epoch 现值
  3**(8-byte NaN-box)。
  layout_epoch 只在真实表示变化(布局 / tag 语义 / 地址稳定性 / 所有权
  语义)时递增,与本文档版号解耦。历史 FNABI §11.3 的编号规则已随
  该草案撤出树。
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

- tracing 收集器是树中**唯一**收集器:`build/config.zig` 的引擎选项里与
  GC 相关的只有 `-Dzjs_force_gc` 和 `-Dzjs_ownership_audit`。
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
`gc_representation_constants.zig` 与 `gc_alloc.zig` 的裸字节写入共同钉住):

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

`gc.RefKind = enum(u4)`,14 个值(`gc.zig:RefKind`):

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
| 13 | symbol | 块 cell / extent | 0(handle 即 body) | 叶,描述内联 |

- **prefix carrier**(`gc.kindIsPrefixCarrier`:6/8/9/10/11/12/13):体紧跟
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
  - a 类 payload:`hasTracerOwnedPayloadCell` 后的 `gc_visit.storageCell(...)`;
  - rope tail:`traceRopeEdges`。
- 块堆几何:64 KiB 块、2 MiB superblock、一块一个 size class、只整
  superblock 释放(`gc_block_heap.zig` 头注)。

## 2. 堆边突变协议(发布 + 屏障)

v2 的 retain→publish→release Slot 序随 rc 一起退役。现行协议:

1. **先初始化,后发布**:`heap_accounted` 置位(发布)时 tracer 走一次
   初始边(`markPublishedYoungClassified`);发布前的字段写不需要屏障,
   发布后的每次强引用写需要(§3)。对未发布 owner 调屏障 = 调用方 bug。
2. **强引用写 = 存储 + 屏障**,屏障在存储**之后**、同一函数内同步调用
   (`Object.setFastArrayElement`:`slot.* = new_value;
   rt.gc.generationalBarrier(self.gcHeader(), new_value.cycleMarkHeader())`;
   `barrierPropertySlot` 同形)。bulk 写(memcpy、采纳整块缓冲、shape
   compaction)在写**之前**调 `rememberOwnerForBulkWrite(owner)`。
3. **存储 cell 三规则**(`docs/gc-invariants.md`):
   - **铸造与安装相邻**:裸 cell 在精确扫描下无根,中间任何分配都可能
     回收它;分配压力请求(`requestGCForAllocation`)在铸造**之前**。
   - **增长不释放旧 cell**,旧 cell 留给 sweep;安装提前到可分配的
     reserve 之前。
   - **bulk 写记忆 owner**。
4. 绕过这些入口直写堆引用字段(无屏障)= 契约违规;检出机制是
   `ZJS_GC_AUDIT`(`UNBARRIERED-STORE` 报告,`gc.zig`)与
   `ZJS_GC_VERIFY`(每次 minor 用全量 trace 对账即将谴责的集合,`gc.zig`)。

## 3. 屏障形状

入口(`gc.zig:Registry`):

```text
generationalBarrier(owner: *Header, child: ?*Header)
generationalBarrierValue(owner: *Header, child: JSValue)   // child 经 cycleMarkHeader 解码
rememberOwnerForBulkWrite(owner: *Header)
```

- **快路径 = 一次 8 字节 owner 元数据加载 AND `hot.barrier_gate`**
  (`barrierOwnerSkips`,JSC 两步门形状)。只有 `young` 与 `remembered`
  两位可以买到退出。`expectedBarrierGate` 只在 `detailed_reports`
  (`--gc-stats` 会打开它)时返回 0,否则返回 `barrier_skip_bits`。安全构建
  在每次屏障调用重算门值,并断言已发布的门与它相等(C1)。
- **慢路径是分代 remember-owner**。增量 major 及其目标染色已经退役,
  收集是 stop-the-world(`gc_mark_epoch.zig` 头注)。
  - `detailed_reports` 打开时走 `generationalBarrierDetailed`:先计数,
    young owner 或 `!flags.young` 的目标直接返回,否则 `rememberGenerationalOwner`。
  - 其余情况下,开着的门已经说明 owner 是 old 且尚未 remembered。未发布的
    目标算 young,只有 `!young && heap_accounted` 才跳过,其余调用
    `rememberGenerationalOwner`。remembered 位是 header 元数据字节 6 的
    bit7(`trace_remembered_mask`)。
- bulk 屏障 `rememberOwnerForBulkWrite` 对非 young 的 owner 调用
  `rememberGenerationalOwner`。
- **线程模型**:收集在 runtime owner 线程上 stop-the-world 完成,没有
  marker worker。store 与屏障在同一函数内同步调用,这就是屏障相对存储的
  同步条件。S4-b 并行标记**已撤回**(`gc_mark_epoch.zig`;若重新引入,
  §8.4 的撕裂前提使 owner-only 记录不 sound,须回到本节修订)。
- JIT/asm 侧预留的 patchable 位对应上述三个签名(§5.3)。

## 4. 根模型

### 4.1 精确根

`JSRuntime.traceActiveRoots`(`runtime.zig`):`ValueRootFrame` 链
(`active_value_roots`)、活动 job 根、`execution.active_invocation`(经
`engine_services.traceActiveInvocations` 遍历解释器帧与操作数栈)、Atomics.waitAsync 等待者、`traceActiveRoots` 中的 root
provider、pin 账本(§4.3);minor 另加 `atoms.traceYoungSymbolBodies`。

`ValueRootFrame`(`runtime.zig:ValueRootFrame`)= `{ previous, slices,
values, objects, headers, atoms }`;**生产只链接 container/window 帧**
(`value_root_link_containers_only = !builtin.is_test`,`src/core/roots.zig`),
标量 `rootValues`/`rootObjects` 作用域在生产被编译掉
(`value_root_scalar_scopes_enabled = !value_root_link_containers_only`);
测试构建因 `builtin.is_test` 链接每一个 activate。`atoms` 槽
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
  `gc.PollMode.rootScan()`——`engine_active` 触发开保守(mutator 原生帧
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
- atom 表条目的 `host_pins`(`AtomTable.pinForHost` / `unpinForHost`)是
  tracer 看不见的 ABI 侧根;atom 活性 = `visitAtom` 边 ∨ body 已标记 ∨
  `host_pins != 0` ∨ 本周期黑分配。
  **每个裸 atom id 的持有者必须由拥有它的权威 trace 报告 `visitAtom`**
  (shape 属性 atom、FunctionBytecode 名与 var-ref 名经
  `atomOperandIterator`、module 记录、`CompileAtomScope`)。
- 成员列表不是根(`contexts.live_head` 等回答「谁拥有」不是「是否存活」);
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

#### 5.2.1 W1 属性站点缓存的落地形态(2026-09-07,已实现)

上面三条的具体兑现,`bytecode.PropSiteCache` + `Shape.identity`
（PERF-SHAPE-ID；实现见 [`PropSiteCache`](../src/bytecode/function_bytecode.zig)
与 [`Shape`](../src/core/shape.zig)）：

- **版本号 = `Shape.identity: u64`**,per-Registry(即 per-Runtime)单调
  计数器,**永不复用**。取新值的时机:创建(`link`)、以及**每次原地变异
  之前**——属性追加(`appendProperty`,是 `addProperty` 与
  `transitionPropertyUncached` 非共享臂共同的唯一收口)、删除
  (`markPropertyDeleted`)、flags 更新(`updatePropertyFlags`)、原型替换
  (`replacePrototypeAssumePrepared`)、以及变异总闸 `prepareUpdate` 的两条
  腿。`relocateShape`(增长换址,同一逻辑布局)**保留**旧值;
  `compactProperties` / `restorePropertyLayout`(重排布局)取新值。
- **因此不需要显式失效钩子**:守卫比较的是 identity 不是指针,Shape 被
  回收后地址复用无害(这正是本节 ABA 前科的正解);未共享的 Shape 会
  在原地址上变异,所以**指针守卫不可用**(spike/perf-t-main
  `tspike.zig` 头注 R12 已实测)。
- **Shape 不锁定 class**:shape 会跨 class 复用(`createRegExpFromShape`、
  realm 模板),而 exotic 自有属性行为(Array `length`、typed array /
  string 下标、Proxy、module namespace)是 class 的性质。所以凡是越过
  receiver 自身布局的臂(一级原型、原生访问器)条目里另存 `class_id`
  并在命中时重比;own 臂不需要(identity 命中即证明该属性就在这个布局里)。
- **缓存的原生访问器只存槽位,不存 `NativeEntry`**:`defineProperty` 可以
  在不改动任何 shape flag 的情况下换掉 getter 函数对象,所以命中臂每次
  从被守卫的槽里重读访问器再解析 entry。
- 站点数组(`FunctionBytecode.prop_sites` FAM 尾)
  **登记为「非 GC 边」**:槽内没有任何堆指针(`PropSiteCache`)。
- 站点索引的**唯一性是命中臂的前提**(命中臂不重比 atom):一个
  `cache_idx` 只能属于一个函数的一条指令。`small_inline` 的特化副本因此
  在内联进来的 callee 体上把 `cache_idx` 全部清成 `no_cache_idx`。

### 5.3 Phase 2(baseline JIT)与 AOT 发射

- **值移动经抽象层发射**,发射的是 §3 的屏障序:每条堆引用存储后发
  `generationalBarrierValue(owner.gcHeader(), v)`(owner 是 Object,不是
  cell);快门 `barrierOwnerSkips` 可内联,safety 构建带门断言;连续写用
  `rememberOwnerForBulkWrite`(typed 计划 R9)。emitter 硬编码任何计数序
  = 契约违规。
- JIT / AOT native 帧的 GC 正确性由 §4.2 保守扫描覆盖(不需精确 stack
  map 才正确),但 AOT 帧同样贡献残渣 / floating garbage(typed 计划
  R17);safepoint metadata 从 v0 记录(优化项)。
- 生成代码里的屏障必须与存储在同一不可被 safepoint 打断的序列内
  (与解释器同规则;§3 线程模型)。

### 5.4 Phase 1-Z / 1A(解释器骨架,条件项)

值移动生成宏(engine plan §7.4)对接 §2 同一协议:宏只产出「存储 +
屏障」序,handler 文本不变。

## 6. 未决项(本契约不覆盖,谁先碰谁立项)

- **R1 全精确根**:R1-a 实证六个可归因窗口中只有 regexp 匹配数组是真
  缺根,其余是 LLVM 栈槽残渣与调用方 callee-saved 溢出;正路 = 缩帧 /
  擦栈 + cold 出口 publish(完成对账 §6 第 6 条)。落地前 §4.2 保守
  扫描是生产设计。
- **并行标记**:S4-b 已撤回(`gc_mark_epoch.zig`);重新引入须先修订
  §3(屏障撕裂前提)并重建 live-size 门。
- **typed / AOT 六契约**(typed 计划 v1.3 R8):根、窗口、安全点/
  publish、屏障、artifact 不携带 Runtime-local 身份(atom 落盘为字符串)、
  lowering 禁止 `obj+const` 折叠——在 PERF-TYPED-IR 开工前并入本契约
  正文。
- 弱引用 / finalizer 与反馈槽失效钩子的统一注册表(Phase 3 dependency
  registry 的 GC 侧对应物)。
- **本页 v3 为 driver 导出的草案,待 owner 评审**(roadmap v2.0
  VM-CONTRACT-GC);评审通过前 layout_epoch=2 只在本页登记,尚无代码常量承载它。

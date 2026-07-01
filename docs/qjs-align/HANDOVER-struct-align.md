# HANDOVER — 运行时结构体 + GC 忠实对齐 qjs

> 分支 `qjs-faithful-struct-align`（未推送、未碰 main）。本文档供下一会话接手剩余 keystone。
>
> **验证状态（2026-06-30 收口，逐项实测，非凭印象）**：
> - ✅ `zig build zjs`（ReleaseFast）0 errors；`zig build test` **编译** 0 errors。
> - ✅ **test262 全量 `0/49775` errors, passed 44601**（`zig build test262-gate`，真实可复现）。
> - ✅ **force-GC stress 全绿**：Proxy 0/311 · WeakMap 0/141 · WeakSet 0/85 · WeakRef 0/29 · FinalizationRegistry 0/47 · Reflect 0/153 · **Object 0/3411** · **Array 0/3081**。
> - ⚠️ `zig build test`（Debug 全套件 **运行**）有**预存失败**（与干净 HEAD 相同失败集，非本分支回归）：0:50 区间 hang + transition-cache/OOM-注入的陈旧单测 + cycle/reclaim 计数常量失败 + 隔离跑的 InvalidBuiltinRegistry panic。**判 regression 用「与干净 HEAD 相同失败集」，不能用「Debug 绝对 0」**。详见 memory `zjs-head-adbc688-preexisting-broken`。

## 0. 基准 qjs（务必先读）

**benchmark 用的 qjs = `/home/aneryu/quickjs/`（built `/home/aneryu/quickjs/qjs`，源 `/home/aneryu/quickjs/quickjs.c` commit 04be246）是 NEW DESIGN**，与旧 quickjs-ng 不同：
- `JSGCObjectHeader` = 仅 `{ struct list_head link; }` = **16B**；ref_count/gc_obj_type/mark 在 **8B `JSMallocBlockHeader`**（每次分配前缀，quickjs.c:270）。即对象头拆分:8B block-header(refcount) + 16B in-object link。
- JSShape 用 **flexible array member**:单 alloc = 56B struct + 内联 hash_table[]+prop[]。
- JSObject 单 union `u`(24B,按 class_id 选,零浪费)；`prop` 是裸 `JSProperty*`，count/size 在 JSShape。
- aarch64 `JS_PTR64` → **NaN-boxing 关 → JSValue 16B**。
- ⚠️**别用 `/tmp/zjs-stable/quickjs`**(旧设计,refcount 内联);只用 `/home/aneryu/quickjs`。

qjs 关键结构(aarch64): JSValue 16 · JSGCObjectHeader 16 · JSMallocBlockHeader 8 · JSObject 64 · JSShape 56 · JSShapeProperty 8 · JSProperty 16 · JSVarRef 48 · JSString 12 · JSFunctionBytecode 128。

## 1. 当前尺寸（编译实测 `@sizeOf`，aarch64）

| 结构体 | qjs | **zjs** | 状态 |
|---|---|---|---|
| JSValue | 16 | **16** | ✅ 精确 |
| BlockHeader 链 + Metadata 前缀 | 16 + 8 | **16 + 8** | ✅ 精确（rc@4 忠实；前缀字节 0-3 是 zjs 自有分配器，justified） |
| property.Entry | 16 | **16** | ✅ 精确 |
| ShapeProperty | 8 | **8** | ✅ 精确（位布局 bit-for-bit） |
| VarRef | 48 | **48** | ✅ 尺寸对齐（内部 6 bool vs qjs 位域，justified） |
| **Object** | 64 | **64** | ✅ 精确（union-in-place 已落地，见 §2.7） |
| **Shape** | 56 | **56** | ✅ 精确（真 FAM 已落地，见 §2.6） |
| **String** | 12 | **12** | ✅ 精确（FAM+rope-tag+位打包+rc前缀，见 §5.1） |
| **FunctionBytecode** | 128 | **128** | ✅ 精确（528→128,删 zjs 功能对齐,见 §5.4） |

**累计窄化**：Shape 152→**56** · Object 96→**64** · String 64→**12** · FunctionBytecode 576→**128** · VarRef 64→48 · ShapeProperty 12→8 · header 24→16（**🏁 全部 10 项精确对齐 qjs，对齐程序完成**）。

## 2. 本分支已落地（cumulative，file 锚点）

### 2.1 结构体窄化（早期会话，见 §0-1）
- **ShapeProperty 12→8**（`core/shape.zig:Property`）：`packed struct(u64){ hash_next:u26, flags:u6, atom_id:u32 }`=qjs JSShapeProperty。坑:`atom_id` 是 packed bit32→`&prop.atom_id` 取地址失败,传局部拷贝。
- **Shape FAM-slices**：删 `hash_buckets`/`props` 冗余视图 slice 头,保 `property_storage:[]u8`,加 `props()`/`hashBuckets()`/`bucketCount()` 现算。Shape 结构体不移动(只 realloc storage)→无指针失稳。
- **Shape transition 簇移除**（-8B）：删 `is_transition_cacheable`/`parent`/`transition_atom`/`transition_flags`。`findHashedShapeProperty` 改 qjs 式逐属性比较。in-place addProperty 经 rehashShape 重归档→hashed 形状原地变更安全。
- **String 64→48**：`Data.slice.{start,len}`/`capacity` usize→u32、`atom_id` ?u32→u32 sentinel。
- **VarRef 64→48**：删 `next_open` 死代码。
- **header 24→16 keystone**：见 §4（坑最多）。
- **IC 完全移除**（qjs 无 inline cache）+ 基础属性路径修复（`qjsGetFieldFast`/`qjsPutFieldFast`，vm_property_field.zig）→ Richards 471→610。

### 2.2 registry_index 移除（Shape 80→72）
删 zjs 独有 `Registry.shapes:[]*Shape` 数组 + 每 shape 的 `registry_index`（qjs 无 shapes 数组,纯靠 gc_obj_list=add_gc_object 追踪）。`link`/`unlink` 去数组逻辑只维护 hash 链 + 新增 `live_shape_count`（供 memoryUsage）；`ensureShapeHashCapacity` rehash 改**遍历旧 shape_hash 桶**（=qjs js_resize_shape_hash）；`gc.Registry.deinit` 改 Phase1 收集 shape 到 holding stack（复用 header.next）+ Phase2 经 GC 链表销毁。**🩸坑**：`shape.Registry.release` 缺 deinit guard→teardown double-free→修=`shapes.release` 加 `if (phase==.deinit) return`。

### 2.3 cycle-collector 忠实重构 + bug B 修复（见 §3）
### 2.4 Object properties slice→裸指针（Object 80→72，见 §3.3）
### 2.5 GC 死代码清理（见 §3.4）

### 2.6 Shape 72→56 真 FAM（本会话 keystone，`@sizeOf(Shape)==56` comptime 实测）
删 `property_storage: []u8`（16B slice，独立 alloc），换 `prop_size: u32`（已分配 prop 容量，=qjs `JSShape.prop_size`），把 hash 表 + prop[] **内联进 Shape 的 GC 分配**作 FAM（正偏移，紧跟 struct）。Shape 改 **`extern struct`** 锁字段序逐字镜像 qjs JSShape（quickjs.c:974）：`header / is_hashed / hash / prop_hash_mask / prop_size / prop_count / deleted_prop_count / registry_hash_next / proto` → 53B 字段 + pad = **56B**，FAM 起于 `@sizeOf(Shape)`。
- **关键纠正**：qjs 04be246（基准）的 JSShape **已是正偏移 FAM**（`uint32_t hash_table[]` 在 struct 后），负偏移 helper（`get_alloc_from_shape`/`prop_hash_end`）**根本不存在**（旧设计才有）；qjs 自己的 ref_count 也在 `-8`（`js_rc`/JSMallocBlockHeader）= **完全等同 zjs `meta()=ptr-8`**。所以 zjs 直接镜像 qjs 正偏移 FAM，**无需反转布局**，`meta()=ptr-8` 与 FAM 正交无冲突。
- **访问器**（`shape.zig` Shape）：`famBase()=@ptrCast(self)+@sizeOf(Shape)`（=qjs `(uint32_t*)(sh+1)`），`hashBuckets()`/`props()` 从 famBase + `prop_hash_mask`/`prop_size` 现算（`props()` 切 `[0..prop_size]`，所以 `props().len==prop_size`，旧站点零语义改动）。`famByteSize()`/`allocationSize()` = qjs get_shape_size。
- **变长 GC 分配**（`memory.zig` 新增）：`createWithFam(T, fam_bytes)` / `destroyWithFam(T, ptr, fam_bytes)` 逐字镜像 `createInternal`，复用 `gcPrefixSize`/`gcAlignment`/`initGcPrefix`，单 alloc=`prefix(8)+@sizeOf(Shape)+fam`，Metadata 仍在 obj-8。**坑**：`traceAlloc` 首参 `comptime element_size`——FAM 的 `bytes`（含 runtime `fam_bytes`）非 comptime → 用 `traceAlloc(1, bytes, addr)`（element_size=1 comptime，count=bytes runtime，=`allocAlignedBytesInternal` 写法）。Debug 编译（非 ReleaseFast）才抓到（diagnostic_accounting 仅 Debug 开）。
- **指针失稳处理（核心难点）**：FAM 后 grow=realloc 整个 shape→shape **移动**。新增 `relocateShape(shape_ptr: **Shape, new_prop_size, new_bucket_count)` 逐字镜像 qjs `resize_properties`（quickjs.c:5334）：**alloc-new（非 realloc，因 GC 可能在 alloc 时触发）** → 拷 struct 字段 + props（atom/proto 所有权**移动**不 re-dup）+ hash（bucket 变则重建、不变则 memcpy） → GC 侵入链表 `unlinkObjectWithBytes(old)+addWithSize(new)` → shape_hash 链 `removeShapeHash(old)+insertShapeHash(new)` → `destroyWithFam(old)` 仅释放裸块（不清 atom/proto，已移动） → `shape_ptr.* = new`。**唯一 fallible 步=createWithFam（首），失败则 old 不动（正确回退）；其后纯指针操作无分配→GC 安全（双拷贝窗口内不会触发 GC）**。
- **持有者更新链（穷尽 4 类，verifier 确认）**：① `object.shape_ref`（单 owner，rc==1 不变式由 `ensureUniqueShapeForMutation`/`prepareUpdate` 保证）→ 经 `**Shape` 穿线回写；② `registry_hash_next` 链 + ③ `shape_hash_buckets` 桶根 → relocate 内 remove/insert；④ GC 侵入链表 → unlink/add。**无 IC、无 transition cache、无 realm/context 缓存**额外持有 `*Shape`。
- **grow API 改 `**Shape`**：`addProperty`/`reserveProperties`/`reservePropertyHash`/`restorePropertyLayout`/`appendProperty`/`ensurePropertyHash`/`rebuildPropertyHash`（内部经 relocate）；`transitionProperty` 内 `&child`；调用方 `object.zig` `adoptShapeForNewProperty`/`ensurePropertyCapacity`/`reserveOwnPropertyCapacityAssumingPlain` 传 `&self.shape_ref`。`createShape`/`createShapeWithPropertyCapacity`/`cloneShape` 折叠为单 `createWithFam`；`destroyShape` 单 `destroyWithFam`。
- **坑：按值 `Shape` 副本读 FAM = 栈垃圾**。FAM 后 `props()`/`hashBuckets()` 从 `@ptrCast(self)+56` 取址；按值副本的 self 是栈地址→读垃圾。`sameTransition`/`hasPropertyHash`/`firstPropertyIndex` 改 `*const Shape`（测试 `second.*`→`second`）。
- **GC 计账**：`gc.zig` `defaultHeapBytes`/`heapByteSizeFromHeader` 的 `.shape` 臂改 `sh.allocationSize()`（=struct+FAM，含 prop_size+bucket）；shape.zig 4 处 `addWithSize`/`unlinkObjectWithBytes` 全传 `shape.allocationSize()`（alloc/free 对称，否则 verifyHeapAccounting 触发）。
- **验证全绿**：`@sizeOf(Shape)==56`+`@offsetOf(header)==0`（comptime assert + compileLog 实测）· **test262 0/49775（passed 44601，=干净 HEAD）** · **force-GC：Object 0/3411 · Array 0/3081 · Proxy 0/311 · Reflect 0/153 · WeakMap/Set/Ref/FinReg 全 0 · object 0/1170 · class 0/4367**（GC-every-alloc 下 relocate 双拷贝窗口最大化压测）· Debug 编译干净 · Debug 单测：2 核心 shape + 新增 `restorePropertyLayout rebuilds a baseline layout after FAM relocation`（加 6 prop 触发 relocate→restore，leak 检测 + @alignCast 全过）· zjs 二进制 shape-heavy 冒烟正确。`restorePropertyLayout` 仅 unified 测试 harness 用（非生产路径），force-GC test262 不覆盖→新单测决定性补验。

### 2.7 Object 72→64 union-in-place（本会话 keystone，`@sizeOf(Object)==64` comptime 实测）
把 `class_payload`（8B 指针）与 `array_values`（8B 指针）overlay 进单 `u: ObjectStorage extern union { payload, array_values }`（8B，省 8B → 64B）；`array_count`/`array_capacity`/`array_length` **保留独立字段**（churn 最小、不动那些站点；`array_length` 不像 qjs 移到 prop[0].u.value——union 单独已达 64B，移除需 ~30 站点改属性槽，风险高且非必需）。
- **安全性（agent 决定性验证）**：只有 `array` 类用 array_values（`flags.is_array`，`class_payload_kind=.none`，从不分配 class_payload）；所有 class_payload 类（TypedArray 用 TypedArrayPayload、Map/Proxy/function、**Arguments 位置元素走普通索引属性 + MappedArguments var_refs 在 payload**）都非 array。**物理互斥，按 class_id/is_array 分派**（= qjs untagged union by class_id）。
- **坑：Zig 裸 `union {}` 在 safe build 有隐藏 safety-tag**（加字节 + 错臂访问 panic）→必须 `extern union`（C 式无 tag、无检查，靠外部判别符，=qjs）。
- **实现**：sed `self.class_payload`→`self.u.payload`（95）、`self.array_values`→`self.u.array_values`（31，`\b` 保护 `class_payload_kind`）；struct-literal 1 处手改 `.u=.{.payload=...}`；GC mark/finalizer 的 `&self.class_payload`→`&self.u.payload`（array 类 markPayload 是 no-op 故传了不用、安全）；core.zig 测试 23 处 sed。**零生产文件外部读 array_values/class_payload 裸字段**（仅 3 处 `class_payload_kind` 比较保留）。
- **验证全绿**：`@sizeOf(Object)==64`（comptime assert）· test262 0/49775 · **force-GC：Object/Array/TypedArray 0/1446/TypedArrayConstructors 0/738/Proxy/Reflect/Map/Set/ArrayBuffer/Function/arguments-object 0/263/class 全 0** · Debug 编译干净 · zjs 二进制冒烟（array fast-path 3000+TypedArray+Map+Proxy+arguments）。⚠️Debug 隔离跑「cycle removal follows class payload mark」panic（`live_shape_count` 下溢）**经 git stash 在干净 HEAD 96049e4 确认是预存隔离失败**（非回归，同 InvalidBuiltinRegistry 类）。

## 3. cycle-collector / GC（本会话重点）

### 3.1 忠实重构（REMOVE_CYCLES 门 + 延迟-struct Pass B）
zjs cycle collector 现忠实镜像 qjs `gc_decref`/`gc_scan`/`gc_free_cycles`：
- **3 个 visitor** `DecrefVisitor`/`ScanIncrefVisitor`/`ScanRestoreVisitor`（object.zig ~5360-5460）镜像 qjs gc_decref_child/gc_scan_incref_child/gc_scan_incref_child2。
- **REMOVE_CYCLES 门**（`gc.zig releaseAndDestroy` ~1534）：cycle 期间 child decref 到 0 **只减不 destroy**（无条件 no-op，对 {object,var_ref,function_bytecode}）= qjs `__JS_FreeValueRT`:6476。把「漏边=double-free」变「漏边=no-op」。
- **延迟-struct Pass B**（`gc.Registry.cycle_deferred_frees` + `reserveCycleDeferred`/`deferCycleStructFree`/`drainCycleDeferredFrees`）：object/var_ref/fb 的 destroyFromHeader 在 .remove_cycles 释放资源后**延迟 struct-free**,driver 在 garbage_shapes 循环后排空 = qjs free_object:6376 + Pass B:6797。
- **break=false**（call_runtime.zig `constructDynamicFunctionFromSource`）：嵌套 dynamic-function 编译不跑全堆 cycle removal（qjs 不在 eval 退出 GC）。

### 3.2 🏁 bug B 根因 + 修复（arena-window 孤立槽 over-free）
**最小复现** `Reflect.construct(Function/Gen/Async/AsyncGen, [], revokedProxy)` 紧密循环 ~9-10 次崩（中间 GC 回收累积的多个 proxy 循环时段错误）。**真根因 = 栈 arena 别名 over-free，不是 marking 一致性缺陷**（旧文档的「traceChildEdges vs rc 不一致」假设是错的）：
- `constructDynamicFunctionFromSource` 的 `nested_stack` 是 `ctx.runtime.vm_stack` arena 的 **window**（`arena_window=true`，carved-frame 快路径）。`runWithArgs` 把动态函数闭包**同时留在 nested_stack slot[0]** 作第二个 owned ref（正常路径 `return result`+`deinit` 两处都 release，证 rc=2），但该槽在 frame-exit 恢复的 arena watermark **之上** = **孤立槽**。
- 接着读 `new_target.prototype` → revoked-proxy 的 `r.revoke()` trap，trap 的 bytecode 帧从同一 arena carve **覆写孤立槽**（变成 revoke 函数）；抛 TypeError 后 `nested_stack.deinit` 释放被覆写的槽 = **over-release 借用的 revoke 函数**（rc 1→0，wrapper.revoke 仍引用它）→ wrapper 带悬空引用泄漏，累积后中间 GC 读悬空对象段错误。force-GC 每迭代回收单循环故不触发（x100 过）。
- **修复**（call_runtime.zig）：`result = runWithArgs(...)` 后、`dynamicFunctionNewTargetPrototype` 前，**排空 nested_stack 的 owned 副本**（`for (nested_stack.values) |*slot| free` + `values = ptr[0..0]`），使 arena window 为空,后续重用 arena 的 trap 不再覆写活槽。
- **诊断方法论（决定性）**：全局 `dbg_track=<addr>` 在 `BlockHeader.retain`/`gc.release` 打印目标对象每次 rc 变化（配对找**无 RC+ 配对的 RC-**=借用却释放）+ 全局 `dbg_phase` breadcrumb 在各 defer 更新（over-release 时打印定位到 `nested_stack.deinit`）+ dump nested_stack 内容证 window 别名 vm_stack arena。**教训：over-free 用「单对象 rc 史配对 + breadcrumb 阶段」远比 marking 审计高效；别被「累积才崩」误导成 marking 问题——可能只是 per-iteration 确定性 over-free 累积**。

### 3.3 Object properties slice→裸指针（Object 80→72，-8B）
`properties: []property.Entry`（16B slice）→ `prop_values: [*]property.Entry`（8B 裸指针，沿用 `array_values` 已验证的 `[*]+undefined+独立count` 模式）。**忠实 qjs**（`JSObject.prop` 是裸 `JSProperty*`，count/size 在共享 JSShape）。
- **关键事实**：容量已在 shape（`propertyStorageCapacity()=shape_ref.props().len`），`properties.len`=已填计数=`shape_ref.prop_count`（可由 shape 推出，非独立信息）。加访问器 `propertyEntries()=prop_values[0..prop_count]`（has_property_storage 守卫）。
- **唯一 wrinkle = append over-hang**：`appendPreparedPropertyEntry` 把 value 写在 `prop_values[prop_count]`、**先于** shape transition 提交 `prop_count+1`；GC 期间用 prop_count 跳过该 over-hang entry 是安全的（fresh 非循环值，不会被过早回收）。errdefer 只需 destroy `prop_values[old_len]`（prop_count 未递增，无需 slice-shrink）。
- **填充窗口不存在**：`createShapeWithPropertyCapacity` 只预留容量、prop_count=0，属性经 appendPreparedPropertyEntry 原子添加（prop_count 与已填同步）。所以 `properties.len ∈ {prop_count, prop_count+1}`（仅 over-hang），`@min(len, prop_count)` 恒=prop_count。
- ~100 站点编译器引导跨 12 文件 + 测试：`.properties[`→`.prop_values[`、`.properties.len`→`.shape_ref.prop_count`、迭代→`.propertyEntries()`、**open-ended slice（`[base..]`）必须 `.propertyEntries()[base..]`**（裸指针不能无端切片）。坑:exec.zig 测试 baseline-reset 的 `global.properties=ptr[0..baseline]` 删除（count 现由 restorePropertyLayout 经 shape 重置）。
- **验证**：test262 0/49775 + force-GC **Object 0/3411、Array 0/3081**（属性存储最密集套件，force-GC 最大化压 over-hang + 裸指针 GC tracing）。

### 3.4 GC 死代码清理
- `cycle_preserved` flag 是 vestigial（从未置 true，resurrection 由 `mark` 位承载：ScanIncrefVisitor 清 reachable 对象的 mark → 它们不会被置 cycle_visited）→ 删除（保留为 `_reserved` 位，packed 布局不变）+ 简化 3 处 `cycle_visited and !cycle_preserved`→`cycle_visited`（gc.zig BlockFlags、property.zig:296、object.zig objectIsCycleGarbage/headerIsCycleGarbage）。
- REMOVE_CYCLES 门加注释：shape 故意不在 kind 集（qjs 门是 {OBJECT,FUNCTION_BYTECODE,MODULE}）——zjs garbage shape 由 `garbage_shapes` 循环释放一次 + owner 经 `headerIsCycleGarbage` 守卫跳过释放；live/shared shape 的 eager release 在 cycle 期间永不到 0，故不需门。zjs 无 `.module` GC-kind 在流。

## 4. header keystone（24→16）深挖 —— 坑最多，改 GC/分配器前必读

**模型**:rc/kind/flags/size_class 从对象内头移到 **8B `Metadata` 前缀（objectPtr-8 = qjs JSMallocBlockHeader）**,对象内 `BlockHeader` 只剩 `{prev,next}`（16B = qjs JSGCObjectHeader）。`BlockHeader.meta()` = `@ptrFromInt(@intFromPtr(self) - 8)`。
**统一钩子**:`memory.createInternal`/`destroy`/`allocInternal`/`free` 是所有 typed 分配的单一汇聚点。comptime `isGcObject(T)`（header@offset 0 + `gc_kind_tag` + BlockHeader 形状）→统一加前缀。allocator 用 `T.gc_kind_tag` 字节写初始化前缀（kind@2, rc=1@4）。
**🩸🩸 最深坑:Zig 重排非 extern 结构体字段**。FunctionBytecode 的 `header` 被 Zig 排到 offset 440 非 0→`meta()=header-8` 算到对象内部=GC 损坏。**salvage**:FunctionBytecode `header: gc.GCObjectHeader align(16)` 强制排到 offset 0 + 分配器可变前缀 `alignForward(8, alignOf(T))`（FB→16B 前缀,其余→8B,Metadata 恒在 obj-8）+ 4 处 FB 的 `@fieldParentPtr("header",header)` 加 `@alignCast`（**只对 FB 加,Object align 8 不能加**——曾误加到 Object.expect,Debug @alignCast panic）。**防御**:5 个 GC 类型加 `comptime assert(@offsetOf(header)==0)`。String 用独立 `StringHeader`(4B)→isGcObject=false→无前缀。

## 5. 剩余对齐（全是多天/多周 keystone，低垂果实已尽）

### 5.1 ✅✅ String 48→12（-36B）**已精确对齐 qjs（`@sizeOf==12` 实测）**
**🏁 全部落地(2026-07-01,4 个 agent 阶段 + 我每步 @sizeOf/test262 独立验证 + force-GC)**:① 存储 FAM(删 24B Data union→内联字符 FAM)② 位打包头(LenMeta/HashMeta packed u32)③ **rope-to-tag**(rope→独立 `Tag.string_rope` 对象 `StringRope`,`asStringBody` 边界集中 flatten=qjs `js_flatten_string`;String 变纯 flat)④ **rc-移 4B 前缀**(String 4 对齐→rc 在 `stringPtr-4`,struct 12B,`header()`=ptr-4;StringRope 同款但 8 对齐前缀 padding 到 8,rc 仍在 nodePtr-4)。**48→24→16→12B**。test262 0/49775 全程 + force-GC String/RegExp/JSON/Symbol/Map/Array/template/addition 全 0 + Debug JSString/rope 单测过。**🩸2 坑(Debug/force-GC 组合抓)**:①位打包时 flat/rope hash 位宽不一致(30 vs 32)→`foldHash30` 统一;②FAM 访问器从 self 算指针→按值 String 副本读栈垃圾→11 个方法改 `*const String`。**内存中性**(12B struct + 4B 前缀 = 16B 总量,与内联 rc 前同,但达 qjs 精确 struct)。

### 5.1-old String 48→12（-36B）— **存储 FAM + 位打包头（历史备注）**
**🏁 存储重构 + 位打包头（2026-07-01,2 agent + 我独立验证 @sizeOf 24 + test262 全绿）**:删 24B `Data` union → `len_units:u32 + is_wide:bool` + 内联字符 FAM（复用 `createInlineUninitialized`,字符在 `@ptrCast(self)+payload_offset`）+ 位打包头(`LenMeta packed{len:u30,is_wide,rope_child}` + `HashMeta packed{hash:u30,atom_type:u2}`,删 hash_ready(hash==0 sentinel)/is_rope(rope!=null))。test262 0/49775,force-GC String/RegExp/JSON/template/addition/Array/Map/Symbol 全 0。
- **🩸bug（Debug 单测抓到,test262+force-GC 都漏!）**:flat 字符串 hash 截 30 位但 rope 路径(`StringRope.hash:u32`)返 32 位 → rope 与内容相等的 flat 串 hash 不同。修=`foldHash30()`(截 30 位 + 0→1 sentinel)两路统一。**教训:hash 一致性 test262 覆盖不到,Debug 单测是唯一 oracle**。
- **🧱 剩 24→12 被 rope 身份阻塞**:zjs rope **本身就是 String**(`rope:?*StringRope`(8B) + rope-of-rope 链 `createRope(inner,suffix)` 传 rope `*String` 回、`rope_child` snapshot 位、`chain_next:?*String` 迭代析构链、`copyRopeContent` 走 `leaf.rope`、weak-atom 反指针、97 个 `asStringBody`/`resolveData` 靠透明 flatten=qjs `js_flatten_string`)。**改成 qjs 式独立 `Tag.string_rope` 对象 = 全生命周期重写最常用类型 + force-GC rope-lifetime 险**。**rc-移前缀(-4B)无 rope-to-tag 则零价值**(8B rope 指针撑 8 对齐,删 rc 只变 padding)。到 12B 须两者同做 = 深/险多天。
- ① **rope 拆分**:`Rope` → 独立 `StringRope` struct(mirror qjs JSStringRope);rope-backed = `String{is_rope=true, rope:?*StringRope}`（**务实偏离**:用 `rope` 指针 + `is_rope` 判别符,非 `Tag.string_rope` JSValue tag——保 97 个 asStringBody/resolveData consumer 不变;full tag-dispatch 太险,推迟）。② **slice 删**:substring/slice/substr 急切拷贝新 String（qjs js_sub_string,4 站点）。③ **Data→FAM**:所有 string 内联,删 `capacity` + 5 个 appendXInPlace（`s+=x` 回退 copy-into-fresh,rope-tail 增长保留）。
- **🩸坑（已抓修）**:FAM 字符访问器从 `self` 算指针 → **按值 `String` 副本读栈垃圾**。`codeUnitAt`/`compare`/`eqlBytes`/`eqlString` + 7 helper 改 `*const String`（表现为 charCodeAt 返 0 + Final-Sigma 失败）。
- **剩 32→12B**:`rope:?*StringRope`(8B) + `is_rope` → **Tag.string_rope dispatch**(ropes 非 String,-9B,触 97 consumer)· rc 移 8B 前缀(String 变前缀式,-4B)· 位打包头(`len:31/is_wide:1`+`hash:30/atom:2`+hash_next=12B,删 hash_ready/atom_id 独立字段)。**都是深/险改动(最常用类型)**。

### 5.1-old String 48→12 原始备注 — **未做（多周，触及整个字符串模型）**
**scope workflow 实测（2026-07-01）**：qjs JSString=12B 头（`len:31+is_wide_char:1` / `hash:30+atom_type:2` / `hash_next:u32`）+ 字符 FAM（`u.str8[]/str16[]`），rc 在 8B 前缀（js_rc）。zjs String(48B,string.zig:99)=`gc.StringHeader`(4B 裸 rc,**非前缀**,isGcObject=false) + `data:Data union(24B,主驱动)` + `layout`/`capacity`/`hash`/`hash_ready`/`atom_id`/`rope_child`。
- **关键纠正**：**qjs 也有 rope**（`JSStringRope` quickjs.c:601,独立 struct{len,is_wide,depth,left:JSValue,right:JSValue} + 独立 `JS_TAG_STRING_ROPE`,用 23 处）。zjs **已声明 `Tag.string_rope=-6`（value.zig:16）但从未产出**。所以 rope 是 **拆分**（移出 Data union → 独立 `StringRope` struct + 用已有 tag）非删除——忠实。
- **纯去优化（删）**：① `slice` Data 变体（零拷贝 substring view{parent,start,len}=16B,union 最宽,**4 真站点**:builtins/string.zig:491/874/1291、exec/string_ops.zig:3541;qjs `js_sub_string` 急切拷贝）；② `capacity` + 5 个 in-place flat append（appendLatin1InPlace 等,powers rc==1 `s+=x` 快路径,qjs 无 capacity 字段、靠 malloc-usable-size 原地 append）；③ `appendRopeTail` rope-tail 原地增长（qjs 每 concat 链新 rope 节点）。
- **build_pattern=MUTATED AFTER ALLOC**（capacity flat 增长 + rope-tail 增长）→ 到 12B 内联 FAM 必须 build-once-frozen,即删掉两种原地增长,`s+=x`/`s=s+i` 回退 qjs 行为(copy-into-fresh 或链 rope 节点;两路已有 `return false` fallback,只丢累积循环的 per-iter 分配优化)。
- **header 12B**：rc 必须移到 8B 前缀（=其它 GC 对象,isGcObject=true）腾出结构字节给 len/is_wide/hash/atom_type/hash_next;`atom_id` 改 atom_type:2+hash_next 编码（涟漪到 atom.zig）。
- **blast radius**：72 个 resolveData/borrowLatin1 consumer(拆 rope 后改按 JSValue tag 派发 rope-vs-string,多数仍工作)。**多周 keystone。**

### 5.2 ~~Shape 72→56（-16B，真 FAM）~~ ✅ 已落地（见 §2.6）
~~当前 property_storage 是独立 alloc...高复杂度。~~ 已完成：变长 GC 分配（`createWithFam`/`destroyWithFam`）+ `relocateShape` 镜像 qjs `resize_properties`（alloc-new+memcpy+free-old+`*psh=new`）+ `**Shape` 穿线回写单 owner（`object.shape_ref`）+ GC 链表/shape_hash 链 unlink-old/insert-new。`@sizeOf(Shape)==56` comptime 实测；test262 0/49775 + force-GC 全绿。

### 5.3 ~~Object 72→64（-8B，union-in-place）~~ ✅ 已落地（见 §2.7）
`class_payload` 与 `array_values` overlay 进单 `extern union`（省 8B → 64B），互斥由 class_id/is_array 保证。`array_length` 保留为字段（union 单独已达 64B）。test262 0/49775 + force-GC 全绿。

### 5.4 ✅✅ FunctionBytecode 528→128 **已精确对齐 qjs（`@sizeOf==128` 实测,用户授权删功能）**
**🏁 全部落地（2026-07-01,~10 个 agent 阶段 + 我每阶段 @sizeOf/test262 独立复核 + force-GC,禁区文件严守）**。528→368→288→240→224→208→192→176→**128**。test262 0/49775 全程 + force-GC(含 Object/Error/try backtrace/class/eval/generators)全 0。**关键洞察:`header align(16)`→@sizeOf 是 16 的倍数,小删除被 padding 圆回,须批量跨 16B 边界**。落地清单:
- 22 slice→裸自指针(-128)· var_* 平行数组合并进 vardefs(-32)· bitfield 16 flag+memory/atoms 删(rt 提供)+block 裸指针(-32)· **execution_view 缓存删**(VM 每调用重建 view,-25)+source 裸指针 · var_ref bool 3 数组删(closure_var 派生)+class_* 三数组→单 `?*ClassMeta`(-48)· **atom_operands 删**(仅 refcount 保留→析构走字节码 `freeBytecodeAtoms`,dup==free)· generator_body_pc 删(按需扫描)+global_var_names mirror 删 · **var_ref_names 删**(finalized 时=closure_var[i].var_name;eval overlay 仍装全量,view accessor 派生)+dead call_sites 删 · **class_fields_init `?JSValue`→`?*JSValue` box**(-16,改 object.zig 7 个 GC tracer 站点)· **source/debug 6 字段→`?*DebugInfo` box**(-20)+block_len 删(marker 移 Flags bit)+arg_names 折进 DebugInfo box(-12)+dead var_ref_count/closure_var_count 删(-8)→**128**。
- **删的 zjs 功能/优化(用户授权)**:execution_view per-call 缓存(→每调用重建)、in-struct 大字段(→out-of-line box:DebugInfo/ClassMeta/class_fields_init)。**未删语义**(arg_names split-frame 模型保留,只是折进 box;global_vars 承重保留;var_ref_names eval overlay 保留)。冷路径(每函数定义一次)故 per-call 重建 view 的 perf 回退可接受。

### 5.4-old FunctionBytecode 528→128（历史备注）— **Stage 1+var_*合并（528→368B）**
**🏁 Stage 1（裸指针）+ var_* 平行数组合并（2026-07-01,2 个 agent 执行 + 我独立验证 @sizeOf+test262）**:`@sizeOf 528→400→**368**`,test262 0/49775,force-GC Function/class/function/eval-code/for 全 0。
- **Stage 1（裸指针,-128B）**:22 个 read-only `[]T` slice 头（16B）→ `[*]T` 裸自指针（8B）+ 显式长度字段。
- **var_* 合并（-32B）**:`var_names`/`var_is_lexical`/`var_is_const`/`var_scope_level` 从 FB+view 删除,读者改 `vardefs[i].{var_name,is_lexical,is_const,scope_level}`（qjs 用打包 vardefs）。view 加 `vardefs`,makeBytecodeView 物化。
- **🚧 var_ref_* 合并被 eval 架构性阻塞**（agent 实证）:`var_ref_names` 不是纯静态——`inline_calls.zig mergeEvalBindings`(~740)和 `call_runtime.zig callFunctionBytecodeModeState`(~5224)**动态合成 eval var-ref 名字,`var_ref_names.len > closure_var.len`**;消费者 `eval_ops.zig:158`/`module.zig:216`/`frame.zig:199` 有 `idx < closure_var.len ? : var_ref_names[idx]` 两级回退。从 closure_var 派生会丢动态 eval 名 → **要合并须先重做 eval var-ref 机制（多天）**。
- **坑（已避）count-mismatch**:`var_count`/`arg_count`/`var_ref_count`/`closure_var_count` 来自 `fd.var_count` 等,**≠ slice 长度**(`fd.vars.len`/`fd.args.len`/`fd.closure_var.len`,FunctionDefImpl 分开存)→ 不复用,按 finalize 实际 slice 长度加显式长度字段。共享长度:`vars_len`(var_names/var_is_lexical/var_is_const/var_scope_level/vardefs)、`var_refs_len`(var_ref_*/closure_var)、`global_vars_len`;复用已验证的 byte_code_len/cpool_count/pc2line_len;新增 atom_operands_len/arg_names_len/class_instance_fields_len/private_bound_names_len/class_private_names_len/call_sites_len。
- **contained 关键**:VIEW(`BytecodeImpl` ~7000)字段保持 slice,`makeBytecodeView` 把 `fb.X[0..fb.X_len]` 物化给 view → **VM 读者/eval/generator 机器不变**。只改 FB struct + finalize + view + deinit(`owned` 双模保留)+ heapByteSize + ~49 fixture(`fb.X=alloc`→`fb.X=s.ptr;fb.X_len=len`)+ 少数 FB-receiver 读者改 accessor。坑:误把 `*const Bytecode` view 参数(`function`/`caller_function`)和 FunctionDefImpl(`child.byte_code`)当 FB,已纠正(只改 FB-typed receiver)。
- **剩余到 128B（多天,纠缠）**:Stage 2 bitfield 16 flag(-14B,但 flag 名在 fd/fb/view 共享 308 站点)· Stage 3 平行数组**物理合并**(var_names→vardefs[i].var_name 等,-64B,但 var_ref_names 织进 eval 动态 merge `inline_calls.zig`/generator nested view `call_runtime.zig:5324`)· 删 zjs 专属(execution_view 缓存 ~25B/memory-atoms 指针 16B/global-lexical 数组)= 去功能 · Stage 4 block→FAM(Shape 式 createWithFam,-16B)。冷路径 ROI 最低。

### 5.4-old FunctionBytecode 528→128 原始备注（保留）— **未做（多天，触及编译器/VM 变量解析接口 + 需删 zjs 专属字段）**
**scope workflow 实测（2026-07-01）决定性发现**：**builder/finalize 拆分已存在且成熟**——`FunctionDefImpl`（bytecode.zig:1792,= qjs JSFunctionDef）是可变 builder（parser/codegen 经 `growSliceBy` 增量 append），`createFunctionBytecode`（5888,= js_create_function）finalize 时经 `BlockBuilder` 把所有 read-only slice 打包进单 `fb.block`（5957-5985）。**FB finalize 后真不可变**（~49 个手建 `fb.X=alloc` 全在 test 块,零生产代码 mutate finalized FB slice）→ **不是 builder/finalize 拆分问题(已解决),是机械 struct 缩减**。
- **gap 来源**：~23 个 16B slice 头(368B) + execution_view 4 字段(~25B,zjs perf 缓存) + memory/atoms 指针(16B,qjs 用 realm) + zjs 专属 global_var_names/global_vars(global-lexical-sync) + block(16B)。
- **Stage 1（最大单一缩减,机械,低风险）**：23 slice 头 → 8B 裸自指针,len 用已有 count（7 个缺 count 的加 u16/u32）。blast radius **限于 finalize + makeBytecodeView(7308,SOLE 热 consumer,改成 ptr[0..count]) + deinit + heapByteSize + ~49 test fixture**（VM 读的是 execution view 非 FB 本身）。坑:deinit `owned` 双模(block.len==0 走逐 slice free)——49 fixture 半迁移会 double-free/leak,Debug+force-GC 抓。
- **Stage 2**：16 bool flag → packed bitfield(u16/u32,省 ~14B)。
- **Stage 3（较高风险）**：**平行数组与 vardefs 冗余已确认**（finalize:6028 从同一 `fd.vars` 同时填 `vardefs:[]VarDef`(打包,含 var_name/scope_level/is_lexical/is_const) 和 `var_names`/`var_is_lexical`/`var_is_const`/`var_scope_level`,故 `vardefs[i].var_name==var_names[i]`)→ 删 4-7 个平行 slice、读者改 `vardefs[i].field`(~100 站点触及 resolve_variables + VM 变量位读)。
- **Stage 4（可选,= Shape 式)**：FB struct + flex 折叠进单 `createWithFam`（消 block 独立 alloc,= qjs 单 js_malloc(function_size)）。
- **到精确 128B 须删 zjs 专属**（execution_view 缓存 / global-lexical 数组 / memory-atoms 指针）= 去功能非纯对齐,多天。冷路径(每函数定义一次) ROI 最低、绝对差最大。

## 6. 对齐审计结论（2026-06-30，7 维度 workflow + 对抗 verifier，全 confidence=high）
- **结构体**:3 项字段精确(JSValue/property.Entry/ShapeProperty) + 2 项尺寸达 qjs(BlockHeader/Metadata、VarRef,内部 justified 分歧) + 4 项未对齐(Object/Shape/String/FunctionBytecode,见 §5)。
- **GC**:cycle-collector **算法忠实对齐 + 正确**(3 visitor 镜像 + REMOVE_CYCLES 门无条件 + 延迟 Pass B + bug 全修),但是忠实**再实现**非逐字移植(zjs 单 registry+flag 位+数组快照 vs qjs 物理链表剪接 gc_obj_list/tmp_obj_list + free_mark 字节)。STEP6(shape 即时 free)/STEP7(free_mark 哨兵)经 verifier 确认「不需要」**安全**（无读半释放兄弟字段的路径）。

## 7. 验证/门禁（每项）
- `zig build zjs`（ReleaseFast,快,但**惰性分析**:只编译可达代码,test-only 站点窄化不报）。
- `zig build test262-gate` 或 `./zig-out/bin/run-test262 -t8 -c test262.conf -d test262/test 0 100000`（权威 oracle,~3min,红线 0/49775）。
- `zig build test`（Debug 全套件,~30min,**捕获惰性分析窄化 + RLS 溢出 + @alignCast 检查 + gc_stress**,结构改动必跑编译;运行有预存失败,判 regression 用「与干净 HEAD 同失败集」）。
- **force-GC**:`zig build zjs -Dzjs_force_gc=true` 后跑 Object/Array/Proxy/Weak* 子集（GC-布局改动针对性查 use-after-free,比全套件快;Object 0/3411 + Array 0/3081 是属性存储最强证据）。⚠️force-GC binary 覆写 zig-out/bin/zjs,测完重建普通 binary。
- 量结构体尺寸:append `comptime { @compileLog("X", @sizeOf(T)); }` → `zig build zjs 2>&1 | grep X` → **Edit 删探针（绝不 git checkout，会丢未暂存工作）**。

## 8. 红线纪律（承接 QJS-FAITHFUL-ALIGN.md）
- test262 0/49775 唯一硬门;结构/GC 改动 force-GC + Debug 后置门禁。
- zjs 超 qjs 的分歧(O(1) transition 匹配、IC)= 用户判「换赛道/作弊」,默认回退到 qjs 结构。
- 改 GC/分配器/refcount(最热最关键)= 原子改动 + 硬门禁,勿半成品;Zig 字段重排是 GC-前缀模型隐患,GC 类型必 `comptime assert(@offsetOf(header)==0)`。
- over-free 类 bug:单对象 rc-史配对（dbg_track）+ breadcrumb 阶段（dbg_phase）定位,胜过 marking 审计（§3.2 教训）。

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
| **Object** | 64 | **72** | 部分（+8，剩 union-in-place keystone） |
| **Shape** | 56 | **72** | 分歧（+16，剩真 FAM keystone） |
| **String** | 12 | **48** | 分歧（+36，FAM+rope keystone） |
| **FunctionBytecode** | 128 | **528** | 分歧（+400，冷路径，flex-alloc keystone） |

**累计窄化**：Shape 152→72 · Object 96→72 · String 64→48 · VarRef 64→48 · ShapeProperty 12→8 · header 24→16（6 项已精确对齐 qjs）。

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

### 5.1 String 48→12（-36B，最大相对差 4×）
qjs JSString = 12B 头（len:31+is_wide:1 / hash:30+atom:2 / hash_next）+ **FAM 内联字符**。zjs 是固定结构 + `Data union(latin1/utf16/slice/rope)` + 独立字符 buffer + capacity（zjs in-place 增长，qjs 无）。需:① 位打包头到 ~8B;② 字符 FAM 内联;③ rope 拆独立结构。注:`asStringBody`/`@fieldParentPtr` 假设布局;slice-view 是 zjs 零拷贝优化(qjs substring 急切拷贝),移除是去优化非对齐,单独决策。**多周。**

### 5.2 Shape 72→56（-16B，真 FAM）
当前 property_storage 是独立 alloc;qjs 内联（get_shape_prop 从 shape 基址算 = 56B struct + 内联 hash_table[]+prop[] 单 alloc）。需变长 GC 分配 + **shape 指针失稳**:grow 重分配整 Shape→更新所有持有者（self.shape_ref（refcount==1 单 owner）+ shape_hash 链），grow 函数返回新指针。高复杂度。

### 5.3 Object 72→64（-8B，union-in-place）
剩 +8 主因 = zjs `class_payload:?*`(8) + `class_payload_kind`(1) + `array_values/count/capacity/length`(20) 全恒驻,vs qjs 把所有 class payload + fast-array 重叠进单 24B union `u`(按 class_id 派发)。19-agent 审计判:zjs payload 远超 24B,内联会膨胀 payload-less 对象——是 justified 架构分歧。**但若要到 64,须采 qjs inline-union-in-place 模型**（把 class_payload 指针 + array 三件套塌缩进一个按 class_id 解释的 union）。另:`array_length`(4B) qjs 无（存在 prop[0].u.value）——可移除但需 array length 改走属性槽（62 站点，perf 风险）。

### 5.4 FunctionBytecode 528→128（-400，冷路径）
qjs JSFunctionBytecode 是单 `function_size` flex 分配的头(byte_code/vardefs/closure_var/cpool/pc2line/source 都是 8B 自指针)+ per-var 位域。zjs 用 23 个 []T slice（+184B len 冗余）+ 15 个独立 bool flag + zjs 专属 global_var_names/global_vars 数组。冷路径(每函数定义一次),ROI 低但绝对差最大。

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

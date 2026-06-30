# HANDOVER — 运行时结构体忠实对齐 qjs（header keystone + IC 移除）

> 2026-06-30 收口。提交 `adbc688`，分支 `qjs-faithful-struct-align`（未推送、未碰 main）。
> 全程 **test262 0/49775 + force-GC stress 干净**。本文档供下一会话接手剩余 keystone。

## 0. 基准 qjs（务必先读）

**benchmark 用的 qjs = `/home/aneryu/quickjs/`（built `/home/aneryu/quickjs/qjs`，源 commit 04be246）是 NEW DESIGN**，与旧 quickjs-ng 不同：
- `JSGCObjectHeader` = 仅 `{ struct list_head link; }` = **16B**；ref_count/gc_obj_type/mark 在 **8B `JSMallocBlockHeader`**（每次分配前缀，quickjs.c:270）。即对象头拆分:8B block-header(refcount) + 16B in-object link。
- JSShape 用 **flexible array member**:单 alloc = 56B struct + 内联 hash_table[]+prop[]。
- JSObject 单 union `u`(24B,按 class_id 选,零浪费)。
- aarch64 `JS_PTR64` → **NaN-boxing 关 → JSValue 16B**。
- ⚠️**别用 `/tmp/zjs-stable/quickjs`**(旧设计);只用 `/home/aneryu/quickjs`。
- 精确尺寸探针:`/tmp/zjs_probe_qjs.c`(include 真 quickjs.c,链 `.obj/*.o`,`-DCONFIG_VERSION='"x"'`)。

qjs 关键结构(aarch64): JSValue 16 · JSGCObjectHeader 16 · JSObject 64 · JSShape 56 · JSShapeProperty 8 · JSProperty 16 · JSVarRef 48 · JSStackFrame 72 · JSString 12 · JSMallocBlockHeader 8。

## 1. 本会话落地(尺寸 aarch64)

| 结构体 | 会话起始 | **现在** | qjs | 状态 |
|---|---|---|---|---|
| BlockHeader | 24 | **16** | 16 | ✅ 精确 |
| VarRef | 64 | **48** | 48 | ✅ 精确 |
| ShapeProperty | 12 | **8** | 8 | ✅ 精确 |
| Shape | 152 | **80** | 56 | -72 |
| String | 64 | **48** | 12 | -16 |
| Object | 96 | **80** | 64 | -16 |

工作链(全 test262 0/49775):6 项结构窄化 → Shape FAM-slices → IC 完全移除 → 基础属性路径修复 → **header 24→16 keystone** → Shape transition 簇移除 → String 三字段窄化。

### 1.1 已落地明细(file 锚点)
- **ShapeProperty 12→8**(`core/shape.zig:Property`):`packed struct(u64){ hash_next:u26, flags:u6, atom_id }`=qjs JSShapeProperty 位布局。sentinel `no_property_index` = maxInt(u26)(0-based,非 qjs 1-based 但等价)。坑:`atom_id` 是 packed 字段 bit32,`&prop.atom_id`(object.zig GC symbol visit)取地址失败→传局部拷贝。
- **Shape FAM-slices**(`core/shape.zig:Shape`):删 `hash_buckets`/`props` 两个冗余视图 slice 头,保 `property_storage:[]u8`,加 `props()`/`hashBuckets()`/`bucketCount()` 从 property_storage+prop_hash_mask **现算**。bucketCount 无歧义(0 或 mask+1)。**Shape 结构体不移动**(只 realloc storage)→无指针失稳。
- **Shape 窄化**:prop_count/deleted_prop_count usize→u32(坑:`restorePropertyLayout` 只测试可达,Zig 惰性分析掩盖 `=baseline_props.len` 窄化→显式 @intCast);删 `registry_hash_prev` 改单链 bucket 重walk(=qjs `shape_hash_next` 单链)。
- **Shape transition 簇移除**(-8B):删 `is_transition_cacheable`/`parent`/`transition_atom`/`transition_flags`。`findHashedShapeProperty` 改 qjs 式**逐属性比较**(proto+prop_count+1+props,=find_hashed_shape_prop);`shapeNeedsMutationCopy`(object.zig)→`rc!=1`;prepareUpdate/createObjectRoot/cloneShape(删参数)/destroyShape/clearReferencesToVisited/traceChildEdges 同步。**正确性关键**:in-place `addProperty` 经 `rehashShape` 正确重归档→hashed 形状原地变更安全(transition cache 只是 perf 优化非正确性必需)。octane 中性。
- **String 64→48**(`core/string.zig`):`Data.slice.{start,len}` usize→u32(slice 是 union 最大成员)、`capacity` usize→u32、`atom_id` ?u32→u32 sentinel `no_atom_id=maxInt(u32)`。坑:跨文件区分 String `.atom_id`(`*String` receiver)vs shape-property `prop.atom_id`;capacity 计算保 usize,赋 self.capacity 时 @intCast(惰性分析坑:`appendLatin1RepeatedInPlace` 仅测试可达,`zig build zjs` 不报、`zig build test` 报)。
- **VarRef 64→48**:删 `next_open` 死代码(frame.open_var_refs[] 才是真机制=qjs JSStackFrame.var_refs[])。
- **Object 96→80**:weakref_count usize→u32 + header keystone。
- **IC 完全移除**:见 §3。

## 2. header keystone(24→16)深挖 —— 必读,坑最多

**模型**:rc/kind/flags/size_class 从对象内头移到 **8B `Metadata` 前缀(objectPtr-8 = qjs JSMallocBlockHeader)**,对象内 `BlockHeader` 只剩 `{prev,next}`(16B = qjs JSGCObjectHeader)。`BlockHeader.meta()` = `@ptrFromInt(@intFromPtr(self) - 8)`。

**统一钩子**:`memory.createInternal`/`destroy`/`allocInternal`/`free`(`core/memory.zig`)是所有 typed 分配的**单一汇聚点**。comptime `isGcObject(T)`(`@typeInfo==struct` + `@hasDecl(gc_kind_tag)` + `header@offset 0` + BlockHeader 形状)检测→统一加前缀。**零漏路径**:覆盖 Object create-path + FunctionBytecode `alloc(FB,1)`-path 等所有分配。allocator 用 `T.gc_kind_tag`(每 GC 类型的 `pub const gc_kind_tag:u8`)字节写初始化前缀(kind@2, rc=1@4;offset 在 gc.zig comptime 断言)。

**🩸🩸 最深坑:Zig 重排非 extern 结构体字段**。FunctionBytecode 的 `header` 被 Zig 排到 offset **440** 非 0(Object/Shape/VarRef 恰好 0)→`meta()=header-8` 算到对象内部=GC 损坏(arrow/closure 段错误,gdb 见前缀 kind=0/rc=0=initGcPrefix 没跑因 isGcObject 要求 header@0)。
- **salvage**:FunctionBytecode `header: gc.GCObjectHeader align(16)` 强制 Zig 排到 offset 0(按对齐降序)→FB 变 align 16。
- 分配器**可变前缀** `gcPrefixSize(T)=alignForward(8, alignOf(T))`(FB→16B,其余→8B),obj=raw+prefix,Metadata 恒在 obj-8(meta()=obj-8 对两者都命中)。
- FB align 16 → 5 处 `@fieldParentPtr("header", header)`(都是 functionBytecodeFromValue/Mutable/forceStrict)报「increases pointer alignment」→加 `const aligned: *align(16) @TypeOf(header.*) = @alignCast(header); @fieldParentPtr("header", aligned)`(对象实际 16 对齐)。**注意:这只对 FunctionBytecode 函数加,Object 函数(align 8)不能加**——我曾误加到 `Object.expect`,ReleaseFast 不检查 @alignCast(UB 但碰巧对、test262 过),Debug 检查→panic incorrect alignment。
- **防御**:5 个 GC 类型(Object/Shape/VarRef/BigInt/FunctionBytecode)都加 `comptime assert(@offsetOf(@This(),"header")==0)` 防未来静默损坏。

**String 不受影响**:String 用独立 `gc.StringHeader`(4B,仅 rc,无 prev/next)→isGcObject=false→无前缀。

## 3. IC 完全移除(qjs 无 inline cache)

先中央禁用(`icSlotForPc`→null)实测:**IC 开 Richards 579,IC 关 442,但即便开 IC zjs 也仅 0.35× qjs**→IC 是掩盖「基础属性路径慢于 qjs C」的拐杖。删除(ic.zig、property_ic IC 函数保留直接快路径、bytecode ic_slots/序列化、Shape.version、VM IC 分发)。**关键续作:基础路径修复**——删 IC 后 `op_get_field`/`op_put_field`(tailcall_dispatch.zig)还调死的 `cachedDataPropertyValueForFastPath`(恒null)+绕 cold 慢路径;改内联 `qjsGetFieldFast`/`qjsPutFieldFast`(vm_property_field.zig,qjs find_own_property 式)→**Richards 471→610 超 IC-on,prop_get 3.3×→2.5×**。证:去 IC 拐杖+忠实内联查找 比 IC 更快。

## 4. 剩余对齐(全是多天 GC-架构 keystone,低垂果实已尽)

### 4.1 String 48→12(-36B,最大但最难)
qjs JSString = 12B 头(len:31 + is_wide:1 + hash:30 + atom_type:2 + hash_next u32)+ **FAM 内联字符**。zjs String 是固定结构 + `Data union(latin1:[]u8 / utf16:[]u16 / slice / rope:*Rope)` + 独立字符 buffer。需:① len+is_wide+hash+atom 位打包进 ~8B;② 字符 FAM 内联(String alloc = 头 + 字符,小串内联);③ rope 拆成独立 `JSStringRope`-keyed 结构(qjs JS_TAG_STRING_ROPE,value.zig:16 tag 已存)。**多周。** 注意:`asStringBody`/`@fieldParentPtr` 假设 String 布局;slice-view 是 zjs 零拷贝优化(qjs substring 急切拷贝),移除是去优化非对齐,单独决策。

### 4.2 Shape 80→56(-24B)
- **registry_index(-8B)**:zjs `Registry.shapes:[]*Shape` + 每 shape 的 registry_index 做 O(1) swap-remove。qjs 无 shapes 数组,经 gc_obj_list 追踪。**blocker:GC deinit 顺序**——`gc.zig:1482` GC deinit **跳过** shape(让 `Registry.deinit` 经 shapes 数组释放,因 destroyShape 在 deinit phase 守卫跳过 proto/parent release 避免双free);normal 路径 shape 经 GC dispatch `gc.zig:1492 .shape => rt.shapes.destroyFromHeader` 释放。移除需:① ensureShapeHashCapacity rehash 改遍历旧 shape_hash 桶(=qjs js_resize_shape_hash)非 self.shapes;② deinit 改让 GC 释放 shape(去 1482 skip)——但**对象释放时 release shape_ref,若 shape 先于对象释放=use-after-free**,需保证对象先于 shape 释放或守卫。中风险。
- **真 FAM(property_storage 内联,-12B + 消一次 alloc)**:当前 property_storage 是独立 alloc;qjs 内联(get_shape_prop 从 shape 基址算)。需变长 GC 分配(Shape 固定 + storage 一块)+ **shape 指针失稳**:grow 重分配整 Shape→更新持有者(self.shape_ref(refcount==1 单 owner)+ shapes[registry_index] + shape_hash 链)。grow 函数返回新指针。rank5 keystone,高复杂度。

### 4.3 Object 80→64(-16B,多是 justified 分歧)
workflow(19-agent 对抗审计)判定:`class_payload:?*`(8)是 qjs union 持指针重状态的忠实模拟(zjs payload 200B 远超 24B union,内联会膨胀 payload-less 对象);`properties:[]Entry` fat slice(16B)decouple 自 shape.prop_count 是 GC 安全的 justified 分歧(6 热点 `@min(properties.len, prop_count)`);`array_*` 专用字段 vs union 同理(去会膨胀)。`class_payload_kind`(1B)删=净零(在 padding)+不安全(载运行时 state)。**结论:Object 剩余 gap 难忠实收窄。**

## 5. 验证/门禁(每项)
- `zig build zjs`(ReleaseFast,快,但**惰性分析**:只编译可达代码,test-only 站点窄化不报)
- `./zig-out/bin/run-test262 -t 8 -c test262.conf -d test262/test 0 100000`(权威 oracle,~3min,红线 0/49775)
- `zig build test`(Debug 全套件,~30min,慢但**捕获惰性分析窄化 + RLS 溢出 + @alignCast 检查 + gc_stress**——结构改动**必跑**,本会话多次靠它抓到 zjs build 漏掉的 test-only 窄化 + Object.expect 误 align)
- **force-GC**:`zig build zjs -Dzjs_force_gc=true` 后跑属性/字符串 stress(GC-布局改动针对性查 use-after-free,比全套件快)。⚠️force-GC binary 覆写 zig-out/bin/zjs,测完重建普通 binary。
- 量结构体尺寸:append `comptime { @compileLog("X", @sizeOf(T)); }` 到 object.zig 末→`zig build zjs 2>&1 | grep X`→Edit 删探针(**绝不 git checkout**,会丢未暂存工作——本会话开头踩过)。

## 6. 红线纪律(承接 QJS-FAITHFUL-ALIGN.md)
- test262 0/49775 唯一硬门;结构/GC 改动 force-GC + Debug test262 后置门禁。
- zjs 超 qjs 的分歧(O(1) transition 匹配、IC)= 用户判「换赛道/作弊」,默认回退到 qjs 结构(本会话已删 IC + transition 簇)。
- 改 GC/分配器/refcount(最热最关键)= 原子改动 + 硬门禁,勿半成品;Zig 字段重排是 GC-前缀模型的隐患,GC 类型必 `comptime assert(@offsetOf(header)==0)`。

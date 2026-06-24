# S4 — object-shape-header（忠实 header punning）

> Phase 1 第四个 commit。依赖 S1、S3。**设计/实现规格，非代码。** 单大 commit，仅 header punning（proto 结构在 S4b）。

## 目标与边界

- 让 JSObject/JSShape 头经 qjs 忠实方式被环收集器看见，**仅 header punning**——proto 移到 shape 是 **S4b**（独立 slice）。
- 不碰两循环属性枚举、不碰 proto 结构。

## 改动清单（带 file:line 锚点）

### header punning 只用 @fieldParentPtr
- `@fieldParentPtr("header", h)` 在 `*Object`/`*Shape` 与 `*GCObjectHeader` 间转——**不**直接 `@ptrCast *Shape<->*GCObjectHeader`
  （非 extern struct 是 UB；Zig 自动排字段，header-first **不保证** offset 0）。
- Shape 设 `extern` **或**限定只用 `@fieldParentPtr`。

### free_object reroute 保 weak-identity
- free_object 走 qjs 忠实 header 路径，同时**复制 zjs weak-identity 语义**：在新 free 边界用 `peekWeakObjectIdentity` 作
  weakref_count!=0 源（husk-keep），保 `takeWeakObjectIdentity`/`clearWeakPersistentIdentity` 通知，保 `sweepDeadWeakEntries` 二遍检查（object.zig:5677）。

### 保两循环 GC 子追溯（codex 厘清：限 GC 追溯，非 Object.keys 枚举）
- 保 zjs **GC 子追溯的两循环**（shape.props 取 atom + Object.properties 取 value，object.zig:5966-5967/6050-6073），保 arm
  dispatch（data→value、accessor→getter+setter、var_ref→cell-by-value）**不塌成假单循环**。zjs 经 `cell.valueRef()` VALUE
  访问 property var_ref 槽（object.zig:6068），由 DecrefVisitor 对 var_ref-tagged value 的 header decref 补偿（object.zig:5227）
  ——这个既有结构差异**保留、非 1:1 转写**。
- **注**：`Object.keys/values/entries` 枚举**不是**这种直接两循环（ownKeys 先从 shape 收 key、value 由 getOwnProperty/getProperty
  后取）——本条只针对 GC 追溯，勿混淆。

## 绿桥

- 仅 header-punning 纪律（机械、行为不变）+ free_object reroute 时保 zjs 既有 weak-identity registry 语义（husk-keep 经
  peekWeakObjectIdentity 镜像 qjs weakref_count!=0）。
- bridge：zjs weak registry（WeakRootSlot/peekWeakObjectIdentity）作 weakref_count!=0 源 → WeakRef.deref/FinalizationRegistry 保持现绿行为。

## 验收

- **结构对照**：object/shape header vs `struct JSObject`/`struct JSShape`（quickjs.c:974,JSGCObjectHeader header 必须首位）；mark_children JS_OBJECT 臂。
- **门**：WeakRef.prototype.deref、FinalizationRegistry、prototype-cycle GC、全 `0/49775` default + nan_boxing。

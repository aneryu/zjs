# S4b — shape-owns-proto（忠实对齐，非偏离；深 refactor）

> Phase 1。依赖 S1、S3、S4。独立于 S5（次序可换）。**设计/实现规格，非代码。**
> **本 slice 的来历**：原 Phase 0 把它当"接受的单一偏离"排除；用户驳回、要真实理由；查证 qjs 源码后**撤回排除**——
> 它是忠实对齐项。下文「为何不是偏离」即查证结论。

## 为何不是偏离（查证 quickjs.c）

```c
struct JSShape {
    JSGCObjectHeader header;   // :975  shape 是 gc 对象
    ...
    JSObject *proto;           // :985  proto 只存在 shape 上
};
struct JSObject { ...; JSShape *shape; ... };   // quickjs.c:1013 (JSObject 布局 990-1077)；object 无独立 proto 字段
```
- `add_gc_object(rt, &sh->header, JS_GC_OBJ_TYPE_SHAPE)`（quickjs.c:5224/5283/5366/5429）——shape 在 `gc_obj_list`。
- mark_children：object 标 shape，shape 标 proto → proto 经 object→shape→proto 标**一次**。
- **zjs 现状**（codex 更正）：proto 重复 = **一个 owning `Object.prototype` 指针 + 一个 non-owning `shape.proto_id` 整数**
  （重复 proto 状态，但**非两个 owning 指针**；即早先审计的「duplicate-prototype-pointer」）。
- agent 的两条"理由"已拆穿：① "double-decref 风险"只在"给 shape 加 proto 却不删 object 重复边"的半截改造时出现；忠实照 qjs
  （proto 只在 shape）根本无两条边 → 无双重 decref。② "环检测等价"恰证 object→proto 那条边**冗余**，是删它的理由。
  ③ "零正确性收益"按忠实原则无关。**唯一真实残留 = 成本（深 refactor），成本只决定放哪个 slice、不是偏离理由。**

## 改动清单

- **SHAPE 入 `gc_obj_list`**：Shape 带 gc header、由环收集器扫（add_gc_object JS_GC_OBJ_TYPE_SHAPE 类比）。
  现状（shape.zig:43-58 已证）：Shape 是 `ref_count: usize` + `proto_id: ?usize`，**非 gc 对象、不在 gc_obj_list**；
  改为内嵌 `gc.Header`（替 ref_count usize）。
- **proto 移到 shape** 成 owning `*Object`（qjs `JSObject *proto`）；**删 Object 的重复 proto 边**——此步本身**消除 double-decref**，
  并回退「duplicate-prototype-pointer」赢。
- **reroute**：所有 proto 读 / 原型链遍历 / instanceof / `__proto__` → `object.shape.proto`；`setPrototype`（codex 更正）→
  照 qjs `js_shape_prepare_update`（clone-or-unhash 使 shape **私有**）后改 `sh->proto`——**不是** find/build interned transition。
  （qjs shape **非普遍 interned**：只有 hashed shape 是 shared，另有 un-hashed/private；改 proto 前先使 shape 安全可改。）
- **GC 标记**：object 标 shape、shape 标 proto（删 object 直接标 proto）。

## 风险与缓解

- shape 是**共享** interned 结构 → setPrototype 改 proto 必须走 transition（建/找新 shape），**不能**就地改共享 shape 的 proto
  （会污染其他对象）。这是深 refactor 的核心，须照 qjs `js_shape_prepare_update`/clone 语义。
- 删 object 重复边后，所有读 proto 的热路径多一次 shape 间接（qjs 也如此、且快）——按忠实原则接受。

## 验收

- **结构对照**：`struct JSShape` proto 字段 + JS_GC_OBJ_TYPE_SHAPE add_gc_object + mark_children SHAPE 臂（quickjs.c:6662）。
- **门**：proto 链遍历、instanceof、`__proto__` get/set、Object.getPrototypeOf/setPrototypeOf、跨 realm proto、
  prototype-cycle GC、全 `0/49775` default + nan_boxing + **force-GC**。

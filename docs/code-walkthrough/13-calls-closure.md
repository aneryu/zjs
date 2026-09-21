# 13 — `c_closure`（已退休）

**现行路径：无。** 本页不再描述 live 执行器。

- PR4 删除生产者 `constructFunctionValue`（曾 `closure.create(.returns_undefined)`）。生产 `new Function` 是 `call_runtime` → `function_ops.constructFunctionFromSource`。
- PR5 删除 `Kind` / `create` / `callCClosure` / `callWithThis`。`call.zig` 不再按 `class_id == c_closure` 分发。
- `ClassId` 16 保留为空位，不重排。
- 集合回调走 `collection_ops.callCallbackWithThis` → `call_runtime.callValueOrBytecodeRoot`（需要 Realm global）。
- 语言闭包仍是 `object_ops.createRootBytecodeFunctionObject` + 帧 `captureLocal` / `captureArg`。

`exec/root.zig` 的 `closure` 别名指向 `call.zig`（host 全局 / Bound 创建等剩余所有者），不是第二套 `c_closure` 执行器。

## 覆盖核对

- 清单函数数: 0（执行器已删）
- 未覆盖: 无

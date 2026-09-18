# 15 — 迭代器协议与 Iterator Helpers（`iterator_ops.zig`）

类型地图与子文档目录。opcode 与协议的分工见 [15-array-string-iterator.md](15-array-string-iterator.md)。

## 文件职责

`iterator_ops.zig` 实现：

- **同步/异步 GetIterator**：`forOfStart`、`createAsyncFromSyncIterator`。
- **for-of / for-await-of / for-in 的 VM 步进**：`forOfNext`、`forInNext`、`iteratorClose`，以及各自把 catchable 错误转成 `Step` 的 `*Vm` 外壳。
- **Array Iterator / Iterator.prototype / helpers**（map/filter/take/drop/flatMap/concat/zip）。
- **协议原语**：`iteratorStepValue` / `createIteratorResult` / `iteratorCallForNativeRecord`。

`iterator_builtin_ops.zig` 只有 id 映射（`staticMethodId` / `prototypeMethodId`）、下标游标助手 `next`、`internal_entries` 和共享 record handler `iteratorCall`。
`forof_ops.zig` 管 for-in 快照、catch-marker 编码、pending-error 时的 IteratorClose。

## 类型

- `for_in_iterator_kind = 251`：for-in 迭代器 payload 的 kind 哨兵。
- `Step`：`done` / `continue_loop`，给 `*Vm` 包装在 catchable 错误后是否继续解释。
- `IteratorFromResult`：`iterator` + 可选 `next_method` + `wrap`。
- `IteratorZipMode`：shortest / longest / strict。
- `IteratorZipRecord`：`{iterator, next}`。
- `IteratorZipCompletion`：保存「原错误 + 已 take 的 JS 异常」，close 完再 restore，避免 close 覆盖 pending。
- `IteratorZipHelperKind`：zip / zip_keyed。
- `IteratorStep` / `IteratorStepResult` / `IteratorValueDone`：`{value, done}` 与带 result 对象的变体（`IteratorStepResult` 只在 done 步填 `value`，见 `iteratorStepResult`）。
- `IteratorPredicateKind`：every / find / for_each / some。
- `IteratorHelperKind`：map=1 … zip_keyed=8，存在 helper 对象的 `iteratorKindSlot`。
- `IteratorWrapKind`：Iterator.from 包装器的 next vs return。

## 子文档

| 文件 | 覆盖 |
| --- | --- |
| [15-iterator-ops-protocol.md](15-iterator-ops-protocol.md) | for-of 启动/步进、for-in、Array Iterator、%IteratorPrototype%、Iterator.from / Iterator.concat |
| [15-iterator-ops-helpers.md](15-iterator-ops-helpers.md) | zip、helpers、step 原语、native-record 分发 |
| [15-iterator-builtin.md](15-iterator-builtin.md) | record 表 |
| [15-forof.md](15-forof.md) | catch-marker、for-in 快照、unwind close |

## 覆盖核对

- 清单函数数: 0（本文件只含类型与目录）
- 本文标题覆盖: 0
- 未覆盖: 无

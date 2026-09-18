# 15 — Array / TypedArray / ArrayBuffer 运行时（`array_ops.zig`）

本文件是 `src/exec/array_ops.zig` 的类型地图与子文档目录。逐函数正文按主题拆到 `15-array-ops-*.md`。

生产语义权威是 ECMA-262；QuickJS 坐标只为读实现。species / 空洞 / TypedArray 重叠见 [15-array-string-iterator.md](15-array-string-iterator.md)。

## 文件职责

`array_ops.zig` 是 Array、TypedArray、ArrayBuffer/SharedArrayBuffer、DataView 相关的 **exec 运行时**：

- 被 VM 热路径 `arrayMethodFastCall` 与 native-record `arrayPrototypeNativeRecord` **同时**到达。
- 管 species、空洞、dense 快路径、TypedArray 重叠、from/fromAsync、sort、join、apply 参数物化。
- `array_builtin_ops.zig` 只保留 record 表、C ABI `exec_direct`、以及过渡字节码用的窄实现。

## 类型

- `RegExpLegacyNoCaptureSlice`：legacy `$&` / `` $` `` / `$'` 切片种类。
- `ArrayIterationMode`：`for_each` / `map` / `filter` / `some` / `every` / `find` / `find_index` / `find_last` / `find_last_index`。
- `TypedSearchMode`：`index_of` / `last_index_of` / `includes`，给 `typedArraySearchScan`。
- `ArrayFromLikeKind`：from 的 array vs typed 臂。
- `ArraySortEntry`：`value` + 稳定序 `order` + 可选 ToString 缓存 `key`（对齐 qjs `ValueSlot.str`）。
- `SortScratch(T)`：优先从 `VmStackArena` 切窗口，否则堆分配；调用方必须 `mark`/`restore`。
- `SortEntryRootWindow`：sort scratch 里的 JSValue 对 conservative 扫描不可见，必须做成精确根。
- `Uint8ArrayBase64Alphabet` / `Uint8ArrayBase64LastChunkHandling` / `Uint8ArrayCodecProgress`：base64/hex。
- `DenseArrayElementFastResult`（`miss` / `handled` / `out_of_memory`）与 `DenseArrayOverwriteFastResult`（`miss` / `handled` / `append_candidate`）：`OP_put_array_el` 的 C ABI 三态，避免 Zig error-union sret。
- `ValueSliceRoot`：把 `[]JSValue` 挂上 `ValueRootFrame`（同族的 `CellSliceRoot` 全树无调用方，已删）。
- `OwnedArrayLikeArgs`：`empty` / `arena` / `heap` 三种 backing；`deinit` 按 LIFO 释放。
- `FastApplyArgs`：`.values` 或 mapped-arguments `.cells`。洞、Proxy、改写 `length` 不能走这条。
- `Base64Chunk`：编解码块。
- `SparseIndexKey`：稀疏 ownKeys 收集到的 `{atom_id, index}`。
- `LengthIndexAtom`：`propertyAtomFromLengthIndex` 的 RAII；`deinit` 释放非 int-atom。

## 子文档

| 文件 | 覆盖 |
| --- | --- |
| [15-array-ops-dispatch.md](15-array-ops-dispatch.md) | 快调用、CallSite、ArrayBuffer/TypedArray 构造与 accessor |
| [15-array-ops-iterate.md](15-array-ops-iterate.md) | 迭代族、reduce、搜索、slice/splice、mutating |
| [15-array-ops-species.md](15-array-ops-species.md) | species、from/fromAsync、of、sort、by-copy、flat |
| [15-array-ops-apply.md](15-array-ops-apply.md) | apply 参数、join、canonical TA、base64/hex |
| [15-array-builtin.md](15-array-builtin.md) | `array_builtin_ops.zig` record 表与过渡实现 |

## 覆盖核对

- 清单函数数: 0（本文件只含类型与目录；函数在子文档）
- 本文标题覆盖: 0
- 未覆盖: 无

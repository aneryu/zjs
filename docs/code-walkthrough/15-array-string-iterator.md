# 15 — Array / String / Iterator / for-of

本册覆盖 exec 里 Array、String、迭代器协议和 for-of/for-in 的实现。权威仍是源码与 ECMA-262；QuickJS 坐标只为对照。

逐函数正文按文件拆开。先读本节的四条横切问题（species、空洞、TypedArray 重叠、迭代器协议 vs for-of opcode），再按要改的函数跳到子文档。

## 覆盖文件

| 源码 | 清单函数 | 文档 |
| --- | --- | --- |
| `src/exec/array_ops.zig` | 224 | [15-array.md](15-array.md) 与 `15-array-ops-*.md` |
| `src/exec/array_builtin_ops.zig` | 58 | [15-array-builtin.md](15-array-builtin.md) |
| `src/exec/string_ops.zig` | 155 | [15-string.md](15-string.md) 与 `15-string-ops-*.md` |
| `src/exec/string_builtin_ops.zig` | 110 | [15-string-builtin.md](15-string-builtin.md) |
| `src/exec/iterator_ops.zig` | 100 | [15-iterator.md](15-iterator.md) 与 `15-iterator-ops-*.md` |
| `src/exec/iterator_builtin_ops.zig` | 5 | [15-iterator-builtin.md](15-iterator-builtin.md) |
| `src/exec/forof_ops.zig` | 24 | [15-forof.md](15-forof.md) |

合计 **705** 个清单函数。`*_ops.zig` 是算法与 VM 入口；`*_builtin_ops.zig` 是 native-record 表（`internal_entries`）和少量 C ABI `exec_direct` 叶子。同一算法经常 **BOTH**：record 分发和 `arrayMethodFastCall` / `call_runtime` 名字级联都会走到。

## 1. Species（`ArraySpeciesCreate` / TypedArray species）

ES 的 `ArraySpeciesCreate(original, length)`：派生方法（`map`/`filter`/`slice`/`concat`/`splice`/`flat`/`to*`）的**输出对象**由 `original.constructor[@@species]` 决定，而不是永远造 `%Array%`。

zjs 的实现在 `arraySpeciesCreate`（`array_ops.zig:3543`）：

1. **默认快路径** `arrayHasDefaultSpecies` / `defaultArraySpeciesCreate`。条件极严：非 Proxy 的 Array、无 own `constructor`、`[[Prototype]]` 是当前 realm 的 `%Array.prototype%`、`Array.prototype.constructor` 仍是带 `.constructor` marker 的 intrinsic、`@@species` 仍是「`.species_getter` + setter `undefined`」的 accessor。任一失败必须走可观察 Get，不能偷懒造普通 Array。
2. **IsArray** 才读 `constructor`。Proxy 递归看 target（`arraySpeciesOriginalIsArray`）。非数组 receiver（`Array.prototype.map.call({length:0}, fn)`）直接造默认 Array。
3. **跨 realm 的 intrinsic `%Array%`**（`arrayBuiltinMarker() == .constructor` 且 FunctionRealm ≠ 当前 ctx）在读 `@@species` **之前**就压回默认——这是 spec 的 legacy-web-compat 臂，品牌用 marker 而不是名字，避免 bound/Proxy 伪造。
4. Get `@@species`；`null` 当成 `undefined`。然后再做**第二次**「是不是当前 realm 的 intrinsic Array」比较（注释写明：普通构造器、bound、Proxy 即使 FunctionRealm 碰巧解析回本 realm，也必须先完成这次 Get）。
5. `undefined` → 当前 realm 默认 Array；否则 `constructValueOrBytecode(species, [length])`。

TypedArray **不走** 这条 Array species 链。`typedArraySpeciesConstructorForObject` 读 TypedArray 自己的 `constructor[@@species]`，再用 `typedArrayCreateWithLength` 构造。`%TypedArray%.map/filter/slice` 的输出是 TypedArray（或用户 species 返回的对象，但随后仍按 TypedArray 校验）。ArrayBuffer 另有 `arrayBufferSpeciesConstructor`（`slice` 用）。

过渡路径 `array_builtin_ops.construct*` / `methodCall` **没有** species：它们给早期字节码和夹具用，输出永远是引擎默认 Array。完整语义以 `array_ops` 为准。

## 2. 空洞（holes）

数组空洞是 `[0, length)` 内没有自身索引属性的位置（包括没有 data 或 accessor 属性）。它不同于自身属性值恰好为 `undefined`。但原型链仍可能提供该索引：因此有洞不等于 `HasProperty` 为 false，`Get` 也不一定得到 undefined。通用数组算法必须保留原型链观察。

本册里的纪律：

| 操作 | 空洞怎么处理 |
| --- | --- |
| `forEach` / `map` / `filter` / `some` / `every` / `reduce` | 先 `hasValueProperty`；缺席 `continue`，**不**调用回调 |
| `find` / `findIndex` / `findLast*` | **不**先做 HasProperty：直接 Get 并调用回调；原型链也没有索引时才得到 `undefined` |
| `slice` / `concat` 展开 | `arrayCopyPresentIndex` / `concatAppendValue`：缺席不定义输出下标，输出里仍是洞 |
| `join` | 先 Get（会观察继承属性）；结果为 `null`/`undefined` 时贡献空串 |
| `sort` | 洞（以及 `undefined`）排到末尾；过渡 `array_builtin_ops.sort` 把 `undefined` 当洞丢掉 |
| `map` 的 dense 输出 | 仅当 `index == fastArrayCount()` 才走无检查 dense 追加；中间有洞则改走 index-define，输出变稀疏以保留洞 |
| `slice` bulk memcpy | 只在切片完全落在 `fastArrayCount()` 内时启用；`count < length` 的空洞尾巴禁止 memcpy |
| `Function.prototype.apply` / `fastApplyArgs` | 有洞的 dense 数组 **不能**走零观察快照，必须 `materializeArgsFromArrayLike` 逐个 `[[Get]]` |

TypedArray **没有空洞**：每个下标都有一个元素（可能是 `NaN`/0）。对 TypedArray 走 `typedArrayGetIndex`，不跑 `HasProperty`。RAB（resizable ArrayBuffer）可能在回调的 `valueOf` 里缩短：`arrayMethodTypedArrayLength` 对非 TypedArray 方法在 OOB 时返回 0 而不是 TypeError；`typedArraySearchScan` 对 `includes(undefined)` 在缩短窗口上有 qjs 兼容的特殊 true。

`OP_put_array_el` 的 dense 快路径（`putDenseArrayElementFast` / `OverwriteOwnedFast` / `AppendOwnedFast`）只覆盖「下标已在 count 内」或「正好追加在 count 上」。往空洞或稀疏尾巴写会 miss，回到通用 `[[Set]]`。

## 3. TypedArray 与 Array 的重叠

同一套 JS 方法名（`map`/`slice`/`join`/`indexOf`/`keys`…）既挂在 `Array.prototype` 上也挂在 `%TypedArray%.prototype` 上。zjs 用 **函数对象上的 marker** 区分，而不是看 receiver 类：

- `isTypedArrayPrototypeMethod`：`typedArrayBuiltinMarker() == .prototype_method`
- `isArrayPrototypeRecord` / `arrayPrototypeRecordId`：Array 域 native id
- `typedArrayStaticMethodId`：`.static_from` / `.static_of`

分发后果：

- TypedArray 方法 + 非 TypedArray this → `TypeError`（即使 this 是普通数组）。
- Array 方法 + TypedArray this → 多数按「有 `length` 和数字下标的 array-like」跑，元素用 `typedArrayGetIndex`；**不**走 TypedArray species。
- `arrayMethodFastCall` 先处理 iterator 域，再 `arrayIterationCall`（内部再看 marker），再 at/reduce/search/…，最后 `typedArraySliceSubarrayCall` 与 `arraySliceCall` 并列：`slice` 这个名字两边都有，靠 marker 和 `isTypedArrayObject` 分流。
- Array Iterator 的 `next` 对 TypedArray target 读 `typedArrayLength`，并检查 detached/OOB；对普通数组读 `arrayLength` 或 `[[Get]] length`。
- `array_builtin_ops.arrayIteratorValue` 的过渡路径也会对 TypedArray 走 `buffer_ops.typedArrayGetIndex`。

构造：`typedArrayConstructVm` 按参数分流 length / buffer / iterable / array-like；array-like 的 own-data 快路径（`typedArrayConstructArrayLikeOwnDataFast`）要求源是 dense 无洞、无 accessor。`arrayFromCall` 按 **callee** 分流：函数对象带 `.static_from` marker（即 `%TypedArray%.from`）时整段转给 `typedArrayFromStaticCall`；`Array.from` 自身则在 `this` 是 TypedArray 构造器且源是数组时走 `arrayFromArrayLike`，输出由该构造器构造。

Uint8Array 的 base64/hex（`uint8ArrayCodecCall`）和 Atomics 校验也住在 `array_ops.zig`，因为它们共享 TypedArray 的 buffer 视图。

## 4. 迭代器协议 vs for-of opcode

两条完全不同的控制面，不要混。

### 4.1 语言级迭代器协议（用户可观察）

ES 7.4：`GetIterator` → 反复 `IteratorStep`/`IteratorValue` → 完成或突然完成时 `IteratorClose`（调 `return()`）。

本册入口：

- `iterator_ops.forOfStart`：弹出 iterable。`for-await-of` 先试 `@@asyncIterator`；没有则 `GetIterator` + `createAsyncFromSyncIterator`。sync `for-of` 只走 `@@iterator`。不可调用则抛「value is not iterable」。
- 栈上压 **三元组** `[iterator, nextMethod, catchMarker]`。marker 由 `forof_ops.iteratorCatchMarker` 编码：借用 catch-offset tag，payload `<= -2`（`-2` = async；更小的编码保存外层 catch target）。这让 unwind 能精确认出迭代器记录，而不靠「旁边是不是 object/callable」猜测。
- `forOfNext`：按 bytecode `depth` 定位记录（`forOfIteratorIndex`）。快路径——未覆写的 Array Iterator / Map·Set Iterator / Generator.next——直接把 `value` 和 `done` 压栈，**不**分配 `{value, done}` 对象。慢路径调 `next()`，再 `finishForOfNextResult` 读 `done`/`value`。
- **next 失败**：`errdefer abandonForOfIteratorAtIndex` 把 iterator 槽写成 `undefined`。对齐 qjs `js_for_of_next`：对刚刚失败的 `next` 不再 `return()`，外层记录仍可被正常 close。
- **IteratorClose**：`forof_ops.closeIteratorFromVmImpl` Get `return`，可调用则调它，结果必须是 Object。pending 异常路径（`closeStackTopForOfIteratorForPendingErrorInternal`）先 take 异常、关掉所有无 catch 边界的 for-of 记录、吞掉 close 错误、再 throw 回原值；不可捕获中断整段跳过；OOM 标志单独恢复。

`for-in` **不是** 这个协议。`createForInIterator` 造 `JS_CLASS_FOR_IN_ITERATOR`，只快照根对象的可枚举字符串键（或 fast array 的元素个数）；原型链由 `forInNext`（noinline 包装已纳入清单）一档一档惰性走。已访问键是迭代器对象上的 null 属性。删除检测是 **own** `[[GetOwnProperty]]` / `existsOwnProperty`，不是会走原型的 `[[HasProperty]]`。

Iterator Helpers（`Iterator.from` / `zip` / `map`/`filter`/`take`/`drop`/`flatMap`/`concat` / `toArray`…）在 `iterator_ops` 里，经 `iteratorCallForNativeRecord` 从 `.iterator` record 进来。它们**自己**跑协议：每步 `iteratorStepWithSyncCall`，失败用 `IteratorZipCompletion` 保存原错误再 close 内层，避免 close 覆盖 pending。

`createIteratorResult` 是 `CreateIterResultObject` 的唯一实现。`global == null` 会造 null-prototype 结果（bare-runtime 偏差，调用方必须写明）。

### 4.2 for-of **opcode**（字节码 / 解释器）

编译器把 `for (x of y)` 收成大致：

```
<iterable>
for_of_start [catch_target]
loop:
  for_of_next depth
  <if done, jump end>
  <store value>
  <body>
  jump loop
end:
  iterator_close
```

- `for_of_start` / `for_of_next` / `iterator_close` 的 handler 在 `vm_*.zig`（12 册），**本册不实现 opcode**。本册提供它们调用的运行时：`forOfStart`、`forOfNext`、`iteratorClose`、`popCatchMarker`。
- `popCatchMarker`（`array_ops.zig:118`）在函数返回/抛错扫栈时：遇到 iterator catch-marker 就弹出整份三元组（相当于隐式 close 记录），普通 catch-offset 则返回保存的 target。
- `*Vm` 包装（`forOfStartVm` 等）把 catchable `HostError` 转成 `Step.continue_loop`，让解释器跳到 catch 而不是把 Zig error 漏出。`*Vm` 的 noinline 包装也纳入清单；源码在 `iterator_ops.zig`，与对应的非 Vm 函数一起讲解。

**对照记忆**：协议是 JS 对象上的 `next`/`return`/`throw`；opcode 是操作数栈上的三元组 + depth。快路径的意义是：协议规定的 `{value,done}` 对象在「未覆写的内建迭代器」上可以不分配，但用户覆写 `next` 或 Proxy 必须回到完整协议。

## 5. 热路径分层（读函数时用）

```
JS 调用 Array.prototype.map
    ├─ native record（array_builtin_ops.arrayCall → builtin_glue.arrayNativeRecord
    │                   → array_ops.arrayPrototypeNativeRecord）
    └─ VM 方法调用快路径 arrayMethodFastCall
            → arrayIterationCall → arrayIterationModeCall
                    ├─ TypedArray 方法 → typedArrayMapFilter（TA species）
                    └─ Array → arraySpeciesCreate + HasProperty 循环
```

String 类似：`prim_self` 叶子（平字符串 + int32 下标）在 `string_builtin_ops`；需要 ToString/ToNumber/RegExp 的回退在 `string_ops.stringPrototypeMethod`。

## 6. 子文档目录

| 文件 | 内容 |
| --- | --- |
| [15-array.md](15-array.md) | `array_ops` 类型与子文档索引 |
| [15-array-ops-dispatch.md](15-array-ops-dispatch.md) | 快调用、CallSite、ArrayBuffer/TA 构造 |
| [15-array-ops-iterate.md](15-array-ops-iterate.md) | 迭代族、reduce、搜索、slice/splice、mutating |
| [15-array-ops-species.md](15-array-ops-species.md) | species、from/fromAsync、of、sort、by-copy、flat |
| [15-array-ops-apply.md](15-array-ops-apply.md) | apply 参数、join、canonical TA、base64/hex |
| [15-array-builtin.md](15-array-builtin.md) | Array record 表与过渡实现 |
| [15-string.md](15-string.md) | `string_ops` 类型与索引 |
| [15-string-ops-core.md](15-string-ops-core.md) | ToString、concat、RegExp 符号方法 |
| [15-string-ops-rest.md](15-string-ops-rest.md) | prototype 分发、array concat/search、pad/html |
| [15-string-builtin.md](15-string-builtin.md) | String record 表与直接叶子 |
| [15-iterator.md](15-iterator.md) | 迭代器类型与索引 |
| [15-iterator-ops-protocol.md](15-iterator-ops-protocol.md) | for-of/for-in、Array Iterator、Iterator.from |
| [15-iterator-ops-helpers.md](15-iterator-ops-helpers.md) | zip、helpers、step 原语 |
| [15-iterator-builtin.md](15-iterator-builtin.md) | Iterator record 表 |
| [15-forof.md](15-forof.md) | catch-marker、for-in 快照、unwind close |

## 覆盖核对

- 清单函数数: 705
- 本文标题覆盖: 0（本文件是横切说明与目录；函数标题在 `15-*.md` 子文档）
- 子文档合计覆盖: 705
- 未覆盖: 无

核对：

```sh
python3 docs/code-walkthrough/_check_coverage.py \
  --docs 'docs/code-walkthrough/15-*.md' \
  src/exec/array_ops.zig src/exec/array_builtin_ops.zig \
  src/exec/string_ops.zig src/exec/string_builtin_ops.zig \
  src/exec/iterator_ops.zig src/exec/iterator_builtin_ops.zig \
  src/exec/forof_ops.zig
```

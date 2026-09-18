# 06 — core 值层：`JSValue`、atom、string、number、bigint、json、uri、error

本册覆盖引擎的 **16 字节 tagged 值** 以及围绕它的 intern / 字符串 / 数字 / 错误叶子。权威仍是源码与 [docs/vm-value-representation-contract.md](../vm-value-representation-contract.md)；本文把契约落到函数。

子文件：

| 文件 | 覆盖 |
| --- | --- |
| [06-core-value-value.md](06-core-value-value.md) | `value.zig` / `value_semantics.zig` / `value_format.zig` / `value_string.zig` |
| [06-core-value-atom.md](06-core-value-atom.md) | `atom.zig` / `symbol.zig` |
| [06-core-value-string.md](06-core-value-string.md) | `string.zig` / `string_view.zig` / `bytes_view.zig` |
| [06-core-value-number-bigint.md](06-core-value-number-bigint.md) | `number.zig` / `bigint.zig` / `json.zig` / `uri.zig` |
| [06-core-value-errors.md](06-core-value-errors.md) | `errors.zig` / `error_names.zig` / `exception.zig` / `descriptor.zig` |

## 1. `JSValue.Repr`：payload + i64 tag

`JSValue` 是 `extern struct { repr: Repr }`，`Repr` 是 `{ payload: u64, tag: i64 }`，comptime 钉 `@sizeOf == 16`、`@alignOf == 8`（`src/core/value.zig:44-81`）。这是 **语义** 上对齐 QuickJS 的 tagged 值，不是 libquickjs C ABI 的 bit 级 drop-in。

tag使用8字节i64，payload也为8字节。源码注释以历史机器码/性能实验解释此选择；SIMD寄存器使用和store forwarding效果取决于目标平台与编译器，不能当作所有构建的固定执行方式。

`abi_encoding_revision = 1` 是插件ABI指纹使用的编码版本。即使字段类型未变，只要payload/tag含义变化，也应更新该版本；它不是仅在字段布局改变时才递增。其他ABI契约字段见对应契约文档。

值按位复制。热路径用 `loadSlotAsIntPair` / `storeSlotAsIntPair` 拆成两个 `u64` 整数 load/store，避免 128-bit SIMD 访问把另一半整数读打成 stall（对照 qjs `ldp`/`stp`）。

## 2. Tag 表与 tracer-owned 区间

`Tag` 是一组 `i32` 常量，不是 Zig enum（`src/core/value.zig:19-42`）。

| 常量 | 值 | 载荷 | tracer? |
| --- | --- | --- | --- |
| `symbol` | −8 | `*GCObjectHeader`（符号体，`String` 形状） | 是 |
| `string` | −7 | `*GCObjectHeader`（flat `String`） | 是 |
| `string_rope` | −6 | `*GCObjectHeader`（`StringRope`） | 是 |
| （空位） | −5 | — | — |
| `big_int` | −4 | `*gc.Header`（堆 BigInt） | 是 |
| `module` | −3 | `*gc.Header` | 是 |
| `function_bytecode` | −2 | `*GCObjectHeader` | 是 |
| `object` | −1 | `*gc.Header`（Object 手柄=体指针） | 是 |
| `int` | 0 | i32 零扩展到 u64 | 否 |
| `boolean` | 1 | 0/1 | 否 |
| `null_value` | 2 | 0 | 否 |
| `undefined_value` | 3 | 0 | 否 |
| `uninitialized` | 4 | 0 | 否 |
| `catch_offset` | 5 | i32 字节码偏移；负值=无 handler | 否 |
| `exception` | 6 | 0（返回哨兵，当前异常值在 `runtime.current_exception`） | 否 |
| `short_big_int` | 7 | i64 立即数 | 否 |
| `float64` | 8 | f64 位型 | 否 |

**tracer-owned tag = 连续区间 `[Tag.symbol, Tag.object] = [−8, −1]`。**

`tracer_owned_first_tag` 钉在 `Tag.symbol`（`value.zig:17`）。`cycleMarkHeader` / `isTracerOwned` 用一次有符号区间比较：

```text
tag >= −8 && tag <= −1
```

当前区间覆盖 symbol、字符串族和堆 BigInt 等负 tag；−5 是保留空位，不是有效值构造器产生的 tag。堆 BigInt 使用 −4，与 pinned QuickJS 的 −9 不同。这里的事实是当前源码中的范围判定，不能将它描述成对早期三种 RC 对象的一档简单扩展。`cycleMarkHeader` 按该区间提取非零载荷，`isTracerOwned` 只检查区间；新增GC kind未必新增tag或改变范围，仍需接入具体追踪逻辑。

`requiresRefCount` 是 **遗留名字**：现在只是「tag 的无符号解释 ≥ `Tag.first`」的廉价堆值分类器，给 store/barrier 快路径用，不再做引用计数。

## 3. `dup` / `free` 是兼容操作，不是生命周期

契约 v3（`docs/vm-value-representation-contract.md` §1.3）：全 kind 无引用计数。`JSValue.dup` / `JSValue.free` **作为方法已删除**。文件头的「`dup`/`free` remain compatibility operations」是过时注释，不能据此使用这些已不存在的方法。当前应遵守：

- 值本身按 16 字节拷贝；拷贝 **不** 改变堆对象寿命。
- 堆对象靠 **堆边、root frame、native pin** 活着。
- 旧代码里「dup 再交给别人、用完 free」现在变成「拷贝 `JSValue`，确保有一条 GC 边或 pin 指向它」。
- atom 侧同理：`AtomTable.dup`/`free` 已删；动态 atom 在 `sweepDead` 中按 mark/born epoch、host pin 和 body 标记判定，符号体销毁回调也可使条目失效；最后一个弱引用释放可回收已死的壳。预定义 id 与 tagged-int 分别由 `isConst` 和 `isTaggedInt` 识别，不需要动态槽保活。
- 宿主跨调用持有走 pin 账本（`AtomTable.pinForHost` / `unpinForHost`，以及 runtime 的 `Persistent` / `Weak`），不是 rc。

`Descriptor.destroy` 是源码兼容空操作，给仍按旧 rc API 写的嵌入方。

## 4. Atom intern

`Atom = u32`。三种身份：

1. **预定义**（1 … `predefined_count=692`）：comptime 表 `predefined_atoms`，永不回收，`isConst` 为真。
2. **tagged-int**（最高位 `tagged_int_bit`）：数组下标 `[0, 2^31-1]` 不进哈希表。
3. **动态**（`first_dynamic_atom` 起）：`DynamicAtom` 槽，拼写拷进表拥有的 `[]u8`。`.string` / `.global_symbol` 走 qjs 风格链式哈希（`atom_hash` + `hash_next`）；unique symbol / private 不入链。

Intern 命中只返回已有 id，不再 bump rc。动态槽由 major 的 `sweepDead`、符号体销毁回调及弱壳清理协同回收，槽编号之后可复用。编译期 plain `u32` 字段通过 `CompileAtomScope` 记录，在配置允许且有 runtime 时注册区间根；列表分配失败会增加未在 scope 结束时撤销的 host pin。

## 5. 字符串 rope

JS 字符串值是两种 tag：

- `Tag.string`：flat `String`，12 字节头 + 内联 FAM（latin1 带尾 NUL；utf16 无）。
- `Tag.string_rope`：`StringRope`（56 字节）。`left`/`right` 是 `JSValue`（可再是 rope），或 TGC S2-i 的 **dependent view**：`buffer` 指向共享 `StringBuffer`，`extensible` 标记谁握着追加权。

调用 `flatten` / `asStringBody` 时物化成 flat（内容hash/比较也可通过迭代器直接读取rope，不是所有内容读都会展开），缓存在 `left`，`depth=0`。深度超 `rope_max_depth=60` 走 Fibonacci bucket 再平衡（Boehm/Atkinson/Plass，对照 qjs `js_rebalancee_string_rope`）。当前 exec 拼接分派在双方flat、RHS≤512且512≤LHS≤8192的对应分支启动tail buffer；并非所有LHS≥512的拼接都走该路径。已有dependent view可按追加权、宽度和容量选择复用或复制buffer，减少连续追加的重复复制。

对外句柄：`JSValue.String` = `JSString(JSValue)`（`string_view.zig`）；字节对象：`JSValue.Bytes` = `JSBytes(JSValue)`（`bytes_view.zig`）。两者都不额外 retain 源值。

## 6. 短 BigInt vs 堆 BigInt

- `Tag.short_big_int`：整个 i64 躺在 payload。`shortBigIntFits` 判断 i128 是否落在 i64。
- `Tag.big_int`：`core/bigint.zig` 的 `BigInt` 载体（48 字节头，header@0）。limb 要么外部 `accountedAllocator`，要么 FAM 内联。`createMulInline` 在乘积必不能压回 short 时一次分配 wrapper+limb。

## 覆盖核对

- 清单函数数: 455（17 个 assigned 文件；`errors.zig` 0 函数，error set 全员在 errors 分册）
- 本文标题覆盖: 455（分册合计）
- 未覆盖: 无

分册清单计数：value 110、atom 105、string 175、number-bigint 52、errors 13。

`python3 docs/code-walkthrough/_check_coverage.py --docs 'docs/code-walkthrough/06-*.md' …` → `docs 6 inventory 455 missing 0`。

```sh
python3 docs/code-walkthrough/_check_coverage.py \
  --docs 'docs/code-walkthrough/06-*.md' \
  src/core/value.zig src/core/value_semantics.zig src/core/value_format.zig \
  src/core/value_string.zig src/core/atom.zig src/core/string.zig \
  src/core/string_view.zig src/core/bigint.zig src/core/number.zig \
  src/core/json.zig src/core/uri.zig src/core/symbol.zig \
  src/core/descriptor.zig src/core/errors.zig src/core/error_names.zig \
  src/core/exception.zig src/core/bytes_view.zig
```

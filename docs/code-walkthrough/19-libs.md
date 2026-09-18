# 19 — `src/libs/`：语言库（regexp / unicode / bigint / dtoa）

本册覆盖 `src/libs/` 全部生产源码。这些模块是**移植/生成代码**：函数名常保留 QuickJS 上游拼写（`lre*`、`mpb*`、`jsDtoa*`、`jsAtod*`），语义权威仍是 ECMA-262。它们不依赖 `exec/` 或 `runtime/`，也不持有 `JSValue`；引擎上层用适配器把堆、字符串宽度、中断检查接进来。

分册：

| 文件 | 覆盖 |
| --- | --- |
| [19-libs.md](19-libs.md)（本文） | `src/libs/root.zig` 再导出图；LRE vs `exec/regexp_ops`；堆 bigint vs short bigint；`/v` 属性查找 |
| [19-regexp.md](19-regexp.md) | `src/libs/regexp.zig`（编译器 + 回溯执行器） |
| [19-unicode.md](19-unicode.md) | `unicode.zig` 与 `unicode_tables.bin` |
| [19-bigint.md](19-bigint.md) | `src/libs/bigint.zig` |
| [19-number-format.md](19-number-format.md) | `src/libs/number_format.zig`（`dtoa.c` 移植） |

## `src/libs/root.zig`：再导出图

零函数文件。职责是给 `src/internal_root.zig` / `src/core/` 一个稳定的库入口，避免调用方直接写四个相对路径。

```
src/libs/root.zig
  subsystem_name = "libs"
  unicode        → unicode.zig
                   └─ unicode_tables.bin            QuickJS RLE 表载体（@embedFile）
  regexp         → regexp.zig                       LRE 编译 + 执行
  number_format  → number_format.zig                dtoa（atod 只做反函数）
  bigint         → bigint.zig                       符号-幅度 64-bit limb 算术
```

`pub const` 含义：

| 符号 | 含义 |
| --- | --- |
| `subsystem_name` | 架构依赖检查用的子系统名 `"libs"` |
| `unicode` | Unicode 分类、大小写、规范化、`CharRange`、属性区间 |
| `regexp` | ECMAScript 正则编译器与 QuickJS `libregexp.c` 风格回溯 VM |
| `number_format` | binary64 十进制/任意 radix **格式化**（`jsDtoa`）。十进制 ToNumber 走 `std.fmt.parseFloat`；`jsAtod` 只是 dtoa 反函数 |
| `bigint` | 分配器拥有的 `BigInt`，上限 `JS_BIGINT_MAX_SIZE`（1M bit） |

本文件没有 `fn`。消费点：`core/bigint.zig`（堆对象借 `libs.bigint.BigInt` 视图）、`exec/regexp_adapter.zig` / `exec/regexp_ops.zig`（编译执行）、`core/number.zig` / `core/value_format.zig`（dtoa）、parser/lexer（标识符与空白）。

## LRE vs `exec/regexp_ops`

zjs 把 QuickJS 的 `libregexp.c` 拆成两层，**不要把它们当成同一份代码**：

```
JS `new RegExp` / `RegExp.prototype.exec`
        │
        ▼
 exec/regexp_ops.zig          JS 对象、flags 访问器、RegExp 内建方法
        │  编译 / 执行经 adapter
        ▼
 exec/regexp_adapter.zig      把 JSString 宽度、runtime 栈溢出、timeout 接到库
        │
        ▼
 libs/regexp.zig              LRE：pattern → 字节码 → 回溯匹配
        │  \p{…} / \P{…} / \q{…}
        ▼
 libs/unicode.zig CharRange / isUnicodePropertyMatches
```

| | `libs/regexp.zig`（LRE） | `exec/regexp_ops.zig` |
| --- | --- | --- |
| 输入 | UTF-8 pattern、flag 位、latin1/utf16 切片 | `JSValue` 接收者、参数、prototype |
| 输出 | `Compiled.bytecode`、capture slot、`Match` | 带 `lastIndex` 的 RegExp 对象、JS 数组/布尔 |
| 所有权 | 调用方 allocator；inline 溢出才堆分配回溯栈 | GC 对象；compiled 缓冲挂在 regexp payload |
| 错误 | `CompileError` / `BytecodeCorrupt` / `Timeout` | `throw*Message` 变成 `SyntaxError` / `TypeError` |
| 不负责 | `lastIndex`、named-groups 对象、`Symbol.match` | 字节码 opcode、回溯、`/v` 集合运算 |

`regexp_ops` 文件头写明：匹配引擎留在 `libs/regexp.zig`；VM/字符串可观察行为走 `regexp_fastpath.zig` 与 `string_ops.zig`。`core/regexp.zig` 只做纯字符类谓词（`classMatchesUtf16Unit`），给字符串 replace/match 快路径用，不跑 LRE。

`exec/regexp_adapter.zig` 是运行时桥：`compileWithRuntime` 把 `JSRuntime.checkNativeStackOverflow` 填进 `CompileOptions.check_stack_overflow`（对应 qjs `lre_check_stack_overflow` → `js_check_stack_overflow`）；执行时把已 flatten 的 latin1/utf16 缓冲交给 `execCaptureSlotsSliceTrustedWithOptions`，避免全局 match/replace 循环里反复解码 `JSValue`。

信任契约：本编译器产出的字节码走 `.trusted` 路径（release 不校验每个 operand，对齐 `lre_exec`）；外来字节码走 `.checked`。

## Unicode 属性查找与 `/v`（`unicodeSets`）

`/u` 与 `/v` 共用同一套 **QuickJS 格式压缩表**，但查找形态不同：

1. **名字解析**（`unicode.zig`）
   `parsePropertyExpression("Script=Greek")` / `"ID_Start"` / `"gc=Lu"`。`Script`/`sc`、`Script_Extensions`/`scx`、`General_Category`/`gc` 是带 `=` 的键；裸名先当 GC 再当 binary property。**裸 script 值（`"Greek"`）被拒绝**——这是 ECMA-262 的 `\p{…}` 语法，不是 UTS#18 宽松别名。

2. **编译期区间**（`unicode.zig` 的 `propertyRangePoints`）
   LRE 编译 `\p{…}` 时把属性展开成 `CharRange`（半开区间点对），再发射 `class8` / `range` / `range32`。`/v` 的 `ClassSet` 还要并/交/差、`\q{…}` 字符串、序列属性（`RGI_Emoji` 等）。

3. **运行期单码点**（同一文件的 `isUnicodePropertyMatches`）
   零分配走同一张表，**不**走 LRE 字节码；目前只有区间自洽测试在用它（`core/regexp.zig` 的字符类快路径只调 `isSupportedUnicodePropertyExpression`）。

4. **支持集**  
   `isSupportedUnicodePropertyExpression`：能解析 **且** 有表或派生表达式。`ID_Compat_Math_Start` / `InCB` 能在 name table 里解析，但 `isSupported` 为 false（没有 QuickJS 区间），编译期当 `InvalidPattern`。

`/v` 特有路径在 `REParseState`：

- `unicode_sets` 时 `[…]` 走 `reParseNestedClass`（ClassUnion / `&&` / `--`，同层不能混算子）。
- `\p{Basic_Emoji}` 等 **property of strings** 走 `parseStringPropertyEscape` → `addSequenceProperty`；`\P` 补集含字符串是 SyntaxError。
- `\q{a|bc}` 走 `parseClassStringDisjunction`；发射时先最长字符串再码点集。
- ignore-case：`/v` 在求补 **之前** canonicalize；`/u` 在求补 **之后**（`parseUnicodePropertyEscapeWithOrdering`）。

## 堆 bigint vs short bigint（`JSValue`）

`libs/bigint.zig` **不知道** `JSValue`。它提供符号-幅度、小端 `u64` limb、allocator 拥有的 `BigInt`。`core/value.zig` / `core/bigint.zig` 决定哪种表示进 tagged value：

| | short bigint | heap bigint |
| --- | --- | --- |
| tag | `Tag.short_big_int = 7`（非负，立即数） | `Tag.big_int = -4`（负 tag，tracer 拥有） |
| payload | 整份 `i64` 位型放进 `payload: u64` | `*gc.Header` |
| 范围 | `i64::MIN ..= i64::MAX`（`short_big_int_bits = 64`） | 最多 `max_bits = 1_048_576` bit |
| GC | 无；按位复制 | `core/bigint.zig` 的 `BigInt`：外部 limb 或 FAM 内联 |
| 库视图 | `JSValue.asInt64` 直接读 payload | `borrowedValue()` 借 `libs.bigint.BigInt`，**禁止** `deinit`/`realloc` |

分叉：QuickJS `JS_TAG_BIG_INT = -9`，zjs 的堆 bigint 使用 -4，位于 `cycleMarkHeader` / `isTracerOwned` 接受的 [-8,-1] 区间。`JSValue.dup` / `free` 方法已删除，堆 BigInt 的存活由 tracing GC 决定。

`core/bigint.zig` 不能把 `libs.bigint.BigInt` 嵌进 GC 对象：库 `deinit` 会 `free(limbs)`，而内联 FAM 的 limb 属于 GC block。所以堆对象只存 `limbs_ptr` / `len` / `capacity` / `flags.inline_storage`，读路径一律借视图。

算术、解析、格式化都在 `libs/bigint.zig` 完成；`core` 只负责：短路径装箱、超范围进堆、GC 记账、把 `BigIntTooLarge` 变成 `RangeError`。

## 覆盖核对

- 清单函数数: 0（`src/libs/root.zig`）
- 本文标题覆盖: 0
- 未覆盖: 无

其余函数见同编号分册。总清单 486 个 `src/libs/**/*.zig` 函数；核对命令：

```sh
python3 docs/code-walkthrough/_check_coverage.py \
  --docs 'docs/code-walkthrough/19-*.md' \
  src/libs/root.zig src/libs/bigint.zig src/libs/number_format.zig \
  src/libs/regexp.zig src/libs/unicode.zig
```

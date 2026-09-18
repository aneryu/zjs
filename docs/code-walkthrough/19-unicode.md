# 19 — Unicode：`unicode.zig` 与生成表

覆盖：

| 文件 | 职责 |
| --- | --- |
| `unicode/data.zig` | 从 `tables.bin` `@embedFile` 出来的不可变表 + 枚举 |
| `unicode/names.zig` | 属性名/别名 → 枚举下标 |
| `unicode/properties.zig` | 派生属性（Assigned、XID_Start…）的 `Op` 表达式 |
| `unicode/regexp_properties.zig` | 零分配「码点是否属于 `\p{…}`」 |
| `unicode.zig` | 分类、大小写、NFC/NFD、`CharRange`、属性区间构造 |

`/v` 查找路径见 [19-libs.md](19-libs.md)。本册讲函数。

---

## `src/libs/unicode/data.zig`：表怎么来、谁消费

文件头说明表来自 QuickJS `libunicode-table.h`，载体是同目录 `tables.bin`（`@embedFile`）。解码与语义在 `unicode.zig` / `regexp_properties.zig`。仓库把 `data.zig` 标成 generated（`tools/maintainability/size_screen.py`）；**不要**手改 `tables.bin` 的表体。

`tables.bin`：`ZJSU` + u32le version=1 + u32le 表个数，随后每表 16 字节 `{name_off, data_off, n_elem, elem_size}`，再是 NUL 名和 4 字节对齐的 payload。`u8` 表是 blob 上的切片；`u16`/`u32` 在 comptime 按小端解成原生整数。编码仍是 QuickJS 的 RLE/索引，查找必须走同一套解码（`isInTable`、`unicodeProp1`、`unicodeGeneralCategory1`、`unicodeScript`）。

主要表（不抄内容）：

| 符号 | 用途 |
| --- | --- |
| `case_conv_table1/2`、`case_conv_ext` | 大小写 run：code/len/type 打包在 u32 |
| `unicode_prop_*_table` + 可选 `*_index` | binary property 的 bit-run；带 index 的给 `isInTable` 跳到附近 |
| `unicode_cc_table` / `unicode_cc_index` | Canonical_Combining_Class |
| `unicode_decomp_table1/2`、`unicode_decomp_data`、`unicode_comp_table` | 分解/组合 |
| `unicode_gc_table` | General_Category RLE（v=31 表示 Lu/Ll 交错） |
| `unicode_script_table` / `unicode_script_ext_table` | Script 与 Script_Extensions |
| `unicode_rgi_emoji_tag_sequence` / `unicode_rgi_emoji_zwj_sequence` | `/v` 字符串属性 |
| `unicode_gc_name_table` 等 | NUL 分隔、逗号别名的名字表 |
| `prop_table_backed_last` | 有独立 `unicode_prop_*_table` 的最后一个 `Prop`（`Case_Ignorable`） |
| `prop_public_first/last` | 对外 `\p{…}` 名字范围 `ASCII_Hex_Digit`…`XID_Start` |
| `unicode_prop_table` | comptime 把 `Hyphen`…`Case_Ignorable` 收成切片数组 |

枚举：`GC`（含组 `LC/L/M/N/S/P/Z/C`）、`Script`、`Prop`（含内部 `*1` 残差与公共名）、`SequenceProp`（Basic_Emoji…RGI_Emoji）。

### `blobU32` (`src/libs/unicode/data.zig:14`)

- **签名**：`fn blobU32(comptime offset: usize) u32`。
- **作用**：从 `tables.bin` 读一个小端 u32。
- **实现**：`std.mem.readInt(..., .little)`。
- **所有权 / 错误 / 调用**：仅 comptime。`table` 读 TOC。

### `tableBytes` (`src/libs/unicode/data.zig:18`)

- **签名**：`fn tableBytes(comptime name: []const u8, comptime elem_size: u32) []const u8`。
- **作用**：按名取出表的原始字节。
- **实现**：校验 magic/version，扫 TOC；宽度不对或缺表 `@compileError`。
- **所有权 / 错误 / 调用**：返回 blob 上的切片。`u8` 表直接用；`tableInts` 再解码。

### `tableInts` (`src/libs/unicode/data.zig:42`)

- **签名**：`fn tableInts(comptime T: type, comptime name: []const u8) []const T`。
- **作用**：把 `u16`/`u32` 表按小端解成原生整数切片。
- **实现**：`tableBytes` 之后逐元素 `readInt`，冻成 comptime 数组。
- **所有权 / 错误 / 调用**：静态数据。只给 case/decomp/comp 那几张多字节表。

### `GC.count` (`src/libs/unicode/data.zig:174`)

- **签名**：`pub fn count() usize`。
- **作用**：GC 标签个数，给 comptime 名字表校验。
- **实现**：`@typeInfo(@This()).@"enum".fields.len`。
- **所有权 / 错误 / 调用**：`names.zig` 的 `countNameGroupsComptime` 比较。

### `Script.count` (`src/libs/unicode/data.zig:357`)

- **签名**：`pub fn count() usize`。
- **作用**：Script 个数。
- **实现**：枚举字段数。
- **所有权 / 错误 / 调用**：名字表 comptime 断言。

### `SequenceProp.count` (`src/libs/unicode/data.zig:454`)

- **签名**：`pub fn count() usize`。
- **作用**：序列属性个数。
- **实现**：枚举字段数。
- **所有权 / 错误 / 调用**：`names.zig` 文件级 comptime 块拿它比 `unicode_sequence_prop_name_table` 的组数，并传给 `validateNameTable` 作越界上界。

### `propTable` (`src/libs/unicode/data.zig:473`)

- **签名**：`pub fn propTable(prop: Prop) ?[]const u8`。
- **作用**：有独立 RLE 表则返回切片，否则 null（派生属性或无表名）。
- **实现**：`idx >= unicode_prop_table.len` → null；否则 `unicode_prop_table[idx]`。数组由 comptime 拼 `unicode_prop_Hyphen_table`…。
- **所有权 / 错误 / 调用**：`unicodeProp1`、`properties.isSupported`。borrowed 静态数据。

---

## `src/libs/unicode/names.zig`

名字表格式：每组 `Alias,Alias2\0`，表尾多一个 `0`。comptime 解析成 `(alias, group_index)`。`propIndex` 把表内下标加上 `prop_public_first`。文件尾 comptime 断言组数、无空别名、无冲突、首个别名等于枚举字段名。

### `parseNameTableComptime` (`src/libs/unicode/names.zig:6`)

- **签名**：`fn parseNameTableComptime(comptime table: []const u8) []const MapEntry`。
- **作用**：把名字表打成 `(alias, pos)` 切片。
- **实现**：`@setEvalBranchQuota(200000)`。按 NUL 切组，组内按逗号切 alias。
- **所有权 / 错误 / 调用**：仅 comptime。`validateNameTable`。

### `countNameGroupsComptime` (`src/libs/unicode/names.zig:35`)

- **签名**：`fn countNameGroupsComptime(comptime table: []const u8) usize`。
- **作用**：数 NUL 分组。
- **实现**：跳过每组直到双 NUL。
- **所有权 / 错误 / 调用**：与 `GC.count()` 等比较。

### `validateNameTable` (`src/libs/unicode/names.zig:50`)

- **签名**：`fn validateNameTable(comptime label: []const u8, comptime table: []const u8, comptime group_count: usize) void`。
- **作用**：空表、空别名、越界、同名不同值 → `@compileError`。
- **实现**：扫 `parseNameTableComptime` 的条目两两比。
- **所有权 / 错误 / 调用**：文件级 comptime 块。

### `firstAliasMatchesEnumField` (`src/libs/unicode/names.zig:68`)

- **签名**：`fn firstAliasMatchesEnumField(comptime table: []const u8, comptime enum_type: type, comptime enum_offset: usize) bool`。
- **作用**：每组第一个 alias 必须等于对应枚举字段名。
- **实现**：读到逗号或 NUL；`enum_offset` 让 Prop 从表的公共段对齐 `ASCII_Hex_Digit`。
- **所有权 / 错误 / 调用**：顺序错了编译失败。

### `findName` (`src/libs/unicode/names.zig:89`)

- **签名**：`fn findName(table: []const u8, name: []const u8) ?usize`。
- **作用**：运行时线性搜 alias → 组下标。
- **实现**：逐组逐逗号 `mem.eql`。
- **所有权 / 错误 / 调用**：无分配。名字很短。

### `isScriptPropertyName` (`src/libs/unicode/names.zig:107`)

- **签名**：`pub fn isScriptPropertyName(name: []const u8) bool`。
- **作用**：是否 `Script`/`sc`。
- **实现**：两次 `eql`。
- **所有权 / 错误 / 调用**：`parsePropertyExpression`。

### `isScriptExtensionsPropertyName` (`src/libs/unicode/names.zig:111`)

- **签名**：`pub fn isScriptExtensionsPropertyName(name: []const u8) bool`。
- **作用**：是否 `Script_Extensions`/`scx`。
- **实现**：两次 `eql`。
- **所有权 / 错误 / 调用**：`is_ext` 标志。

### `isGeneralCategoryPropertyName` (`src/libs/unicode/names.zig:115`)

- **签名**：`pub fn isGeneralCategoryPropertyName(name: []const u8) bool`。
- **作用**：是否 `General_Category`/`gc`。
- **实现**：两次 `eql`。
- **所有权 / 错误 / 调用**：带值的 GC 表达式。

### `scriptIndex` (`src/libs/unicode/names.zig:119`)

- **签名**：`pub fn scriptIndex(script_name: []const u8) ?data.Script`。
- **作用**：`Greek`/`Grek`/`Zzzz` → 枚举。
- **实现**：`findName(unicode_script_name_table)` 再 `@enumFromInt`。
- **所有权 / 错误 / 调用**：未知 null。

### `gcIndex` (`src/libs/unicode/names.zig:124`)

- **签名**：`pub fn gcIndex(gc_name: []const u8) ?data.GC`。
- **作用**：`Lu`/`Uppercase_Letter` → GC。
- **实现**：`unicode_gc_name_table`。
- **所有权 / 错误 / 调用**：组名 `L` 也在表里。

### `propIndex` (`src/libs/unicode/names.zig:129`)

- **签名**：`pub fn propIndex(prop_name: []const u8) ?data.Prop`。
- **作用**：公共属性名 → `Prop`。
- **实现**：表下标 **加上** `prop_public_first`（跳过内部 Hyphen…）。
- **所有权 / 错误 / 调用**：`ID_Compat_Math_Start` 能解析但未必 `isSupported`。

### `sequencePropIndex` (`src/libs/unicode/names.zig:134`)

- **签名**：`pub fn sequencePropIndex(prop_name: []const u8) ?data.SequenceProp`。
- **作用**：`Basic_Emoji` / `RGI_Emoji` 等。
- **实现**：`unicode_sequence_prop_name_table`。
- **所有权 / 错误 / 调用**：`addSequenceProperty`、LRE `\p` of strings。

### `gcBit` (`src/libs/unicode/names.zig:139`)

- **签名**：`pub fn gcBit(comptime name: []const u8) u32`。
- **作用**：`1 << GC.name`。
- **实现**：comptime `@field(data.GC, name)`。
- **所有权 / 错误 / 调用**：派生 `Op` 与 `gc_mask_table`。

### `gcMaskByIndex` (`src/libs/unicode/names.zig:154`)

- **签名**：`pub fn gcMaskByIndex(gc: data.GC) u32`。
- **作用**：单类一位；组类（`LC` 起）用 `gc_mask_table` 或起来。
- **实现**：`gc_idx < LC` 则单 bit，否则表 `[gc_idx - LC]`。
- **所有权 / 错误 / 调用**：`\p{L}` 要匹配所有 Letter。

### `parsePropertyExpression` (`src/libs/unicode/names.zig:171`)

- **签名**：`pub fn parsePropertyExpression(property_expr: []const u8) ?PropertyExpression`。
- **作用**：把 `\p{…}` 正文收成 `script` / `gc_mask` / `prop_idx`。
- **实现**：有 `=`：只认 Script/scx/gc 键，值再查表。无 `=`：先 `gcIndex` 再 `propIndex`。**不**把裸 `Greek` 当 script。
- **所有权 / 错误 / 调用**：失败 null。`regexp_properties` 与测试。

`PropertyExpression` / `ScriptExpression` 是本文件的 union/struct，无方法。

---

## `src/libs/unicode/properties.zig`

`Op`：`gc` 掩码、`prop`、`case_mask`、并/交/xor/invert。`Derived`：`.ascii` / `.any` / `.ops`。`CASE_U/L/F` 对应大小写 run 的三类。

派生式与 UCD 一致：例如 `Assigned = ¬Cn`，`XID_Start = (Letter∪Nl∪Other_ID_Start) ∩ ¬(Pattern_Syntax∪Pattern_White_Space∪XID_Start1)`。`ID_Continue = ID_Start xor ID_Continue1`。

### `derived` (`src/libs/unicode/properties.zig:142`)

- **签名**：`pub fn derived(prop: data.Prop) ?Derived`。
- **作用**：若属性由其它集合算出来，返回表达式。
- **实现**：switch：ASCII/Any 特殊；其余返回静态 `ops` 切片；else null（走 `propTable`）。
- **所有权 / 错误 / 调用**：切片是 `const`，无分配。`unicodeProp` / `regexp_properties.unicodeProp`。

### `isSupported` (`src/libs/unicode/properties.zig:167`)

- **签名**：`pub fn isSupported(prop: data.Prop) bool`。
- **作用**：LRE 能否实现该 `\p` 名。
- **实现**：`propTable != null or derived != null`。
- **所有权 / 错误 / 调用**：`ID_Compat_Math_Start`/`InCB` 两者皆空 → 不支持。

---

## `src/libs/unicode/regexp_properties.zig`

与 `unicode.zig` 的区间构造**同一套解码**，但目标是 `bool` 而不是 `CharRange`。栈上最多 4 个 bool。`isSupportedUnicodePropertyExpression` 给 `\p{…}` 校验器用；per-code-point 的 `isUnicodePropertyMatches` 目前只有 `unicode.zig` 的测试夹具调用；编译 `\p` 仍走 `propertyRangePoints`。

### `unicodeGeneralCategory1` (`src/libs/unicode/regexp_properties.zig:28`)

- **签名**：`fn unicodeGeneralCategory1(code_point: u21, gc_mask: u32) bool`。
- **作用**：码点是否落在 GC 掩码里。
- **实现**：扫 `unicode_gc_table`：高 3 位长度（7 则变长扩展），低 5 位类别。命中区间：`v==31` 表示 Lu/Ll 交错，按掩码奇偶；否则测 bit。
- **所有权 / 错误 / 调用**：无分配。未命中 false。

### `unicodeProp1` (`src/libs/unicode/regexp_properties.zig:81`)

- **签名**：`fn unicodeProp1(code_point: u21, prop: data.Prop) bool`。
- **作用**：binary property 成员。
- **实现**：`propTable` null → false。RLE：`b<64` 两段短 run 并翻转 bit；`>=0x80` 长 skip；`0x40/0x60` 多字节长度。
- **所有权 / 错误 / 调用**：与 `unicode.zig` 的 `unicodeProp1` 编码器对偶。

### `unicodeCase1` (`src/libs/unicode/regexp_properties.zig:111`)

- **签名**：`fn unicodeCase1(code_point: u21, case_mask: u32) bool`。
- **作用**：码点是否属于 CASE_U/L/F 对应的 case-conversion run。
- **实现**：把 case_mask 映射到 `RUN_TYPE_*` 位图，扫 `case_conv_table1`。`UL`/`LSU` 交错特殊处理。
- **所有权 / 错误 / 调用**：`Changes_When_*` 派生。

### `unicodePropOps` (`src/libs/unicode/regexp_properties.zig:156`)

- **签名**：`fn unicodePropOps(code_point: u21, ops: []const properties.Op) bool`。
- **作用**：在 bool 栈上执行派生 `Op`。
- **实现**：`[4]bool`；union/inter/xor/invert 弹栈。末尾 `assert(stack_len==1)`。
- **所有权 / 错误 / 调用**：ops 来自 `derived`。

### `unicodeProp` (`src/libs/unicode/regexp_properties.zig:194`)

- **签名**：`fn unicodeProp(code_point: u21, prop: data.Prop) bool`。
- **作用**：派生或表驱动的属性测试。
- **实现**：`.ascii` → `<0x80`；`.any` → `<0x110000`；`.ops` → `unicodePropOps`；否则 `unicodeProp1`。
- **所有权 / 错误 / 调用**：`isUnicodePropertyMatches`。

### `isSupportedProperty` (`src/libs/unicode/regexp_properties.zig:206`)

- **签名**：`fn isSupportedProperty(prop: data.Prop) bool`。
- **作用**：转 `properties.isSupported`。
- **实现**：一行。
- **所有权 / 错误 / 调用**：公共入口过滤。

### `unicodeScript` (`src/libs/unicode/regexp_properties.zig:210`)

- **签名**：`fn unicodeScript(code_point: u21, script_idx: data.Script, is_ext: bool) bool`。
- **作用**：`Script=` 或 `Script_Extensions=`。
- **实现**：扫 `unicode_script_table` 变长 run。表外且 `Unknown` → 主脚本命中。非 ext 返回主脚本。ext：再扫 `unicode_script_ext_table`。Common/Inherited 的 scx 是「主脚本命中且 **没有** 任何扩展列表」（显式 Inherited 扩展被排除）。其它脚本：主脚本 **或** 扩展列表含该 idx。
- **所有权 / 错误 / 调用**：U+0300：`Script=Inherited` 真，`Script_Extensions=Inherited` 假。

### `isSupportedUnicodePropertyExpression` (`src/libs/unicode/regexp_properties.zig:317`)

- **签名**：`pub fn isSupportedUnicodePropertyExpression(name: []const u8) bool`。
- **作用**：编译器/校验器：这个 `\p{name}` 能否实现。
- **实现**：`parsePropertyExpression` 失败 false；script/gc 真；prop 再 `isSupportedProperty`。
- **所有权 / 错误 / 调用**：`libs/regexp.zig` 同名函数再导出；`core/regexp.zig` 的 `consumeUnicodePropertyEscape` 直接调用。

### `isUnicodePropertyMatches` (`src/libs/unicode/regexp_properties.zig:324`)

- **签名**：`pub fn isUnicodePropertyMatches(code_point: u21, name: []const u8) bool`。
- **作用**：单码点是否匹配属性表达式。
- **实现**：script → `unicodeScript`；gc → `unicodeGeneralCategory1`；prop → 支持且 `unicodeProp`。
- **所有权 / 错误 / 调用**：零分配。当前只有 `unicode.zig` 的测试夹具调用，对照 `propertyRangePoints` 建出的区间。

---

## `src/libs/unicode.zig`

类型：`Category`、`CaseMapping`（最多 3 个码点）、`NormalizationForm`、`CodePointRange`、`SurrogatePair`、`CharRange`（点对 `lo,hi,lo,hi,…` 半开）、`CharRangePointRange`。`char_range_sentinel = u32::MAX` 当宇宙上界。`UnicodeError = Allocator.Error || InvalidProperty`。

ASCII 谓词给 lexer/parser/regexp；非 ASCII 标识符走 `ID_Start`/`ID_Continue1` 表。规范化走 QuickJS 分解表 + 韩文算法。

### `asciiCategory` (`src/libs/unicode.zig:19`)

- **签名**：`pub fn asciiCategory(c: u21) Category`。
- **作用**：粗分 ASCII 字母/数字/`_$`。
- **实现**：A–Z、a–z、0–9、`_`/`$`，否则 `.other`。
- **所有权 / 错误 / 调用**：`isIdentifierStart/Continue` 快路径。

### `isIdentifierStart` (`src/libs/unicode.zig:73`)

- **签名**：`pub fn isIdentifierStart(c: u21) bool`。
- **作用**：JS IdentifierStart（含 `$` `_`，不含 ZWJ/ZWNJ）。
- **实现**：`200c/200d` false。ASCII 用 `asciiCategory`；否则 `isInTable(ID_Start)`。
- **所有权 / 错误 / 调用**：lexer。

### `isIdentifierContinue` (`src/libs/unicode.zig:81`)

- **签名**：`pub fn isIdentifierContinue(c: u21) bool`。
- **作用**：IdentifierPart。
- **实现**：ASCII 字母数字 `_$`；否则 Start 或 `ID_Continue1` 或 ZWJ/ZWNJ。
- **所有权 / 错误 / 调用**：lexer。

### `caseConvert` (`src/libs/unicode.zig:90`)

- **签名**：`pub fn caseConvert(c: u21, to_lower: bool) CaseMapping`。
- **作用**：简单/特殊大小写，最多 3 码点。
- **实现**：`caseConv(c, 1 or 0)` 再收窄到 u21。
- **所有权 / 错误 / 调用**：String.toLowerCase 等。

### `regexpCanonicalize` (`src/libs/unicode.zig:97`)

- **签名**：`pub fn regexpCanonicalize(c: u21, is_unicode: bool) u21`。
- **作用**：RegExp ignore-case 的 Unicode 折叠。`/u` 大写→小写；非 unicode 小写→大写（且多码点折叠拒绝）。
- **实现**：`<128` 手写；否则 `findCaseEntry` + `caseFoldingEntry`。
- **所有权 / 错误 / 调用**：LRE `lreCanonicalize` 对 ≥256 转这里。`CharRange.regexpCanonicalize` 是另一函数。

### `isCased` (`src/libs/unicode.zig:113`)

- **签名**：`pub fn isCased(c: u21) bool`。
- **作用**：是否 cased。
- **实现**：case 表命中或 `Cased1` 表。
- **所有权 / 错误 / 调用**：不分配、无 error：只读 comptime 生成的 `data.unicode_prop_Cased1_*` 表与 case 表。调用方仅 `src/exec/string_builtin_ops.zig:1646,1655`（`String.prototype.toLocaleLowerCase` 的 Final_Sigma 上下文判定）。

### `isCaseIgnorable` (`src/libs/unicode.zig:118`)

- **签名**：`pub fn isCaseIgnorable(c: u21) bool`。
- **作用**：Case_Ignorable。
- **实现**：`isInTable`。
- **所有权 / 错误 / 调用**：大小写映射上下文。

### `isEcmaLineTerminatorCodePoint` (`src/libs/unicode.zig:122`)

- **签名**：`pub fn isEcmaLineTerminatorCodePoint(cp: u21) bool`。
- **作用**：LS/PS/`\n`/`\r`。
- **实现**：四值 or。
- **所有权 / 错误 / 调用**：lexer、LRE `isLineTerminator` 有一份平行实现。

### `isEcmaLineTerminatorUnit` (`src/libs/unicode.zig:126`)

- **签名**：`pub fn isEcmaLineTerminatorUnit(unit: u16) bool`。
- **作用**：UTF-16 代码单元版。
- **实现**：提升为 u21 再测。
- **所有权 / 错误 / 调用**：字符串扫描。

### `isEcmaWhitespaceOrLineTerminatorCodePoint` (`src/libs/unicode.zig:130`)

- **签名**：`pub fn isEcmaWhitespaceOrLineTerminatorCodePoint(cp: u21) bool`。
- **作用**：WhiteSpace ∪ LineTerminator。
- **实现**：扫 `ecmaWhitespaceOrLineTerminatorRanges`（半开）。
- **所有权 / 错误 / 调用**：`lreIsSpace` 对 ≥256。

### `isEcmaWhitespaceOrLineTerminatorUnit` (`src/libs/unicode.zig:137`)

- **签名**：`pub fn isEcmaWhitespaceOrLineTerminatorUnit(unit: u16) bool`。
- **作用**：代码单元版。
- **实现**：转码点。
- **所有权 / 错误 / 调用**：不分配、无 error：纯范围比较。调用方 `src/core/regexp.zig:222,223`（`\s`/`\S` 类）、`src/exec/regexp_ops.zig:905`、`src/exec/string_builtin_ops.zig:2273`（trim）。

### `isAsciiWhitespaceByte` (`src/libs/unicode.zig:141`)

- **签名**：`pub fn isAsciiWhitespaceByte(byte: u8) bool`。
- **作用**：SP/TAB/LF/CR/VT/FF。不含 NBSP。
- **实现**：六值。
- **所有权 / 错误 / 调用**：lexer ASCII 快路径。

### `isAsciiDigitUnit` (`src/libs/unicode.zig:145`)

- **签名**：`pub fn isAsciiDigitUnit(unit: u16) bool`。
- **作用**：UTF-16 的 ASCII 数字。
- **实现**：`isAsciiDigitCodePoint`。
- **所有权 / 错误 / 调用**：不分配、无 error。调用方 `src/core/regexp.zig:220,221`（`\d`/`\D`）与 `src/exec/string_ops.zig:3524` 的同名转发（replace 模板里的 `$1`/`$12` 解析经由它）。

### `isAsciiWordUnit` (`src/libs/unicode.zig:149`)

- **签名**：`pub fn isAsciiWordUnit(unit: u16) bool`。
- **作用**：`\w` ASCII。
- **实现**：`isAsciiWordCodePoint`。
- **所有权 / 错误 / 调用**：regexp 快路径。

### `isAsciiIdentifierStartByte` (`src/libs/unicode.zig:153`)

- **签名**：`pub fn isAsciiIdentifierStartByte(byte: u8) bool`。
- **作用**：ASCII IdentifierStart。
- **实现**：字母或 `_` `$`。
- **所有权 / 错误 / 调用**：不分配、无 error。调用方 `src/simple_token.zig:91,258`（快速分词器的标识符起点）、`src/exec/call_runtime.zig:3428`，以及本文件 `isAsciiIdentifierPartByte`（:158）。

### `isAsciiIdentifierPartByte` (`src/libs/unicode.zig:157`)

- **签名**：`pub fn isAsciiIdentifierPartByte(byte: u8) bool`。
- **作用**：ASCII IdentifierPart。
- **实现**：Start 或数字。
- **所有权 / 错误 / 调用**：不分配、无 error。调用方 `src/simple_token.zig:260,369,507,522,634` 与 `src/exec/call_runtime.zig:3430`。

### `asciiRadixDigitValueByte` (`src/libs/unicode.zig:161`)

- **签名**：`pub fn asciiRadixDigitValueByte(byte: u8) ?u8`。
- **作用**：0–35 的 digit；`g-z` 也给值（调用方再比 radix）。
- **实现**：0-9、a-z、A-Z。
- **所有权 / 错误 / 调用**：`parseInt`。

### `isAsciiBinaryDigitByte` (`src/libs/unicode.zig:170`)

- **签名**：`pub fn isAsciiBinaryDigitByte(byte: u8) bool`。
- **作用**：`0`/`1`。
- **实现**：两值。
- **所有权 / 错误 / 调用**：`0b` 字面量。

### `isAsciiOctalDigitByte` (`src/libs/unicode.zig:174`)

- **签名**：`pub fn isAsciiOctalDigitByte(byte: u8) bool`。
- **作用**：`0-7`。
- **实现**：范围。
- **所有权 / 错误 / 调用**：八进制。

### `isAsciiDigitByte` (`src/libs/unicode.zig:178`)

- **签名**：`pub fn isAsciiDigitByte(byte: u8) bool`。
- **作用**：`0-9`。
- **实现**：`isAsciiDigitCodePoint(byte)`。
- **所有权 / 错误 / 调用**：不分配、无 error。调用方 `src/lexer.zig:1566,3310`、`src/exec/json_ops.zig:1213,1216` 等，另经 `src/exec/string_ops.zig:3528` 转发。

### `isAsciiUpperByte` (`src/libs/unicode.zig:182`)

- **签名**：`pub fn isAsciiUpperByte(byte: u8) bool`。
- **作用**：A–Z。
- **实现**：转码点谓词。
- **所有权 / 错误 / 调用**：不分配、无 error。树内唯一调用方是同文件 `isAsciiAlphaByte`（`src/libs/unicode.zig:191`），其余为单测。

### `isAsciiLowerByte` (`src/libs/unicode.zig:186`)

- **签名**：`pub fn isAsciiLowerByte(byte: u8) bool`。
- **作用**：a–z。
- **实现**：转码点谓词。
- **所有权 / 错误 / 调用**：不分配、无 error。树内唯一调用方是同文件 `isAsciiAlphaByte`（`src/libs/unicode.zig:191`），其余为单测。

### `isAsciiAlphaByte` (`src/libs/unicode.zig:190`)

- **签名**：`pub fn isAsciiAlphaByte(byte: u8) bool`。
- **作用**：大小写字母。
- **实现**：upper or lower。
- **所有权 / 错误 / 调用**：不分配、无 error。调用方都在本文件：`isAsciiIdentifierStartByte`（:154）与 `isAsciiAlphanumericByte`（:195）。

### `isAsciiAlphanumericByte` (`src/libs/unicode.zig:194`)

- **签名**：`pub fn isAsciiAlphanumericByte(byte: u8) bool`。
- **作用**：字母或数字。
- **实现**：alpha or digit。
- **所有权 / 错误 / 调用**：不分配、无 error。调用方 `src/exec/uri_ops.zig:754,766`（`escape`/`encodeURI` 的 unreserved 集）、`src/exec/regexp_ops.zig:840`、本文件 `isAsciiWordByte`（:199）。

### `isAsciiWordByte` (`src/libs/unicode.zig:198`)

- **签名**：`pub fn isAsciiWordByte(byte: u8) bool`。
- **作用**：`[A-Za-z0-9_]`。
- **实现**：alnum or `_`。
- **所有权 / 错误 / 调用**：调用方 `src/lexer.zig:2081`；与 LRE `lreIsWordByte`（`src/libs/regexp.zig:4056`）平行（LRE 还用 ctype 表）。

### `asciiHexDigitValueByte` (`src/libs/unicode.zig:202`)

- **签名**：`pub fn asciiHexDigitValueByte(byte: u8) ?u8`。
- **作用**：十六进制 digit。
- **实现**：`asciiRadixDigitValueByte` 后 `>=16` 丢掉。
- **所有权 / 错误 / 调用**：`\x` `\u`。

### `asciiUpperHexDigitValueByte` (`src/libs/unicode.zig:208`)

- **签名**：`pub fn asciiUpperHexDigitValueByte(byte: u8) ?u8`。
- **作用**：只认大写 A–F。
- **实现**：0-9 / A-F。
- **所有权 / 错误 / 调用**：不分配，非法位返回 null。调用方 `src/exec/value_ops.zig:1080` 的 `upperHexValue`——把 `"%" ++ hi` 与 `lo` 的拼接识别成 `%XX` 后走 `rt.percentHexString` 缓存。

### `asciiLowerHexDigitChar` (`src/libs/unicode.zig:214`)

- **签名**：`pub fn asciiLowerHexDigitChar(nibble: usize) u8`。
- **作用**：nibble → `0-9a-f`。
- **实现**：查表；`assert(nibble<16)`。
- **所有权 / 错误 / 调用**：调用方 `src/exec/regexp_ops.zig:875,876`（RegExp source 的 `\xNN` 转义）与 `src/exec/array_ops.zig:6999,7000`（`encodeHexBytes`）。

### `asciiUpperHexDigitChar` (`src/libs/unicode.zig:219`)

- **签名**：`pub fn asciiUpperHexDigitChar(nibble: usize) u8`。
- **作用**：nibble → `0-9A-F`。
- **实现**：查表。
- **所有权 / 错误 / 调用**：调用方 `src/exec/uri_ops.zig:565,572-575`（`%XX` / `%uXXXX` 百分号编码）与 `src/core/runtime.zig:4202,4203`（`percentHexString` 缓存）。

### `isAsciiHexDigitByte` (`src/libs/unicode.zig:224`)

- **签名**：`pub fn isAsciiHexDigitByte(byte: u8) bool`。
- **作用**：是否 hex digit。
- **实现**：`asciiHexDigitValueByte != null`。
- **所有权 / 错误 / 调用**：不分配、无 error（转发的 `asciiHexDigitValueByte` 用 `?u8` 而非 error 报告非法位）。调用方 `src/lexer.zig:920,997,1044` 等转义序列校验处。

### `asciiHexDigitValueUnit` (`src/libs/unicode.zig:228`)

- **签名**：`pub fn asciiHexDigitValueUnit(unit: u16) ?u8`。
- **作用**：UTF-16 单元的 hex。
- **实现**：`>255` null。
- **所有权 / 错误 / 调用**：不分配；非 hex 用 `null` 返回而不是 error。调用方 `src/exec/uri_ops.zig:762`（已先验过合法性，直接 `orelse unreachable`）与本文件 `isAsciiHexDigitUnit`（:234）。

### `isAsciiHexDigitUnit` (`src/libs/unicode.zig:233`)

- **签名**：`pub fn isAsciiHexDigitUnit(unit: u16) bool`。
- **作用**：单元是否 hex。
- **实现**：value != null。
- **所有权 / 错误 / 调用**：不分配、无 error。树内唯一调用方 `src/exec/uri_ops.zig:758`（`decodeURI` 的 `%XX` 校验）。

### `isAsciiDigitCodePoint` (`src/libs/unicode.zig:237`)

- **签名**：`pub fn isAsciiDigitCodePoint(cp: u21) bool`。
- **作用**：码点 `0-9`。
- **实现**：范围。
- **所有权 / 错误 / 调用**：byte/unit 包装的底层。

### `isAsciiUpperCodePoint` (`src/libs/unicode.zig:241`)

- **签名**：`pub fn isAsciiUpperCodePoint(cp: u21) bool`。
- **作用**：A–Z。
- **实现**：范围。
- **所有权 / 错误 / 调用**：不分配、无 error。树内只被本文件的 `isAsciiUpperByte`（:183）与 `isAsciiAlphaCodePoint`（:250）使用。

### `isAsciiLowerCodePoint` (`src/libs/unicode.zig:245`)

- **签名**：`pub fn isAsciiLowerCodePoint(cp: u21) bool`。
- **作用**：a–z。
- **实现**：范围。
- **所有权 / 错误 / 调用**：不分配、无 error。树内只被本文件的 `isAsciiLowerByte`（:187）与 `isAsciiAlphaCodePoint`（:250）使用。

### `isAsciiAlphaCodePoint` (`src/libs/unicode.zig:249`)

- **签名**：`pub fn isAsciiAlphaCodePoint(cp: u21) bool`。
- **作用**：ASCII 字母。
- **实现**：upper or lower。
- **所有权 / 错误 / 调用**：不分配、无 error。调用方 `src/libs/regexp.zig:2045`（`isRegExpGroupNameStart`）与本文件 `isAsciiAlphanumericCodePoint`（:254）。

### `isAsciiAlphanumericCodePoint` (`src/libs/unicode.zig:253`)

- **签名**：`pub fn isAsciiAlphanumericCodePoint(cp: u21) bool`。
- **作用**：字母或数字。
- **实现**：alpha or digit。
- **所有权 / 错误 / 调用**：不分配、无 error。树内唯一调用方是本文件 `isAsciiWordCodePoint`（:258）。

### `isAsciiWordCodePoint` (`src/libs/unicode.zig:257`)

- **签名**：`pub fn isAsciiWordCodePoint(cp: u21) bool`。
- **作用**：`\w` ASCII。
- **实现**：alnum or `_`。
- **所有权 / 错误 / 调用**：不分配、无 error。树内唯一调用方是本文件 `isAsciiWordUnit`（:150），后者再供 regexp 的 `\w` 类使用。

### `isHighSurrogateUnit` (`src/libs/unicode.zig:261`)

- **签名**：`pub fn isHighSurrogateUnit(unit: u16) bool`。
- **作用**：高代理。
- **实现**：转 `isHighSurrogateCodePoint`。
- **所有权 / 错误 / 调用**：不分配、无 error。调用方遍布 UTF-16 走查：`src/core/string_view.zig:136,164`、`src/core/json.zig:110`、`src/exec/uri_ops.zig:510`、`src/exec/json_ops.zig:2280,2284,2292`、`src/exec/string_ops.zig:3536` 转发，以及本文件 `appendUtf16UnitsAsUtf8`（:325）。

### `isLowSurrogateUnit` (`src/libs/unicode.zig:265`)

- **签名**：`pub fn isLowSurrogateUnit(unit: u16) bool`。
- **作用**：低代理。
- **实现**：转码点谓词。
- **所有权 / 错误 / 调用**：不分配、无 error。调用方 `src/core/json.zig:113,120`、`src/core/string_view.zig:136,164`、`src/exec/uri_ops.zig:508,515` 等处（另有 `src/exec/string_ops.zig:1193,1201,1935,2067` 与同名转发 :3540、本文件 :327），都是配对代理时的前瞻判定。

### `isHighSurrogateCodePoint` (`src/libs/unicode.zig:269`)

- **签名**：`pub fn isHighSurrogateCodePoint(cp: u21) bool`。
- **作用**：U+D800–DBFF。
- **实现**：范围。
- **所有权 / 错误 / 调用**：不分配、无 error。调用方本文件 `isHighSurrogateUnit`（:262）、`isSurrogateCodePoint`（:278），以及经 `src/exec/string_ops.zig:2690` 转发给 `src/exec/regexp_fastpath.zig:863`。

### `isLowSurrogateCodePoint` (`src/libs/unicode.zig:273`)

- **签名**：`pub fn isLowSurrogateCodePoint(cp: u21) bool`。
- **作用**：U+DC00–DFFF。
- **实现**：范围。
- **所有权 / 错误 / 调用**：不分配、无 error。调用方本文件 `isLowSurrogateUnit`（:266）、`isSurrogateCodePoint`（:278），以及经 `src/exec/string_ops.zig:2694` 转发给 `src/exec/regexp_fastpath.zig:866`。

### `isSurrogateCodePoint` (`src/libs/unicode.zig:277`)

- **签名**：`pub fn isSurrogateCodePoint(cp: u21) bool`。
- **作用**：任意代理。
- **实现**：hi or lo。
- **所有权 / 错误 / 调用**：不分配、无 error。调用方 `src/exec/uri_ops.zig:723`（`isSurrogate`，`encodeURI` 遇孤立代理报 URIError）与 `src/libs/regexp.zig:2060,2068`（具名组名的非法起始/后续码点）。

### `codePointFromSurrogatePair` (`src/libs/unicode.zig:281`)

- **签名**：`pub fn codePointFromSurrogatePair(high: u16, low: u16) u21`。
- **作用**：代理对 → 码点。
- **实现**：`0x10000 + ((hi-0xD800)<<10) + (lo-0xDC00)`。调用方保证成对。
- **所有权 / 错误 / 调用**：LRE `fromSurrogate` 是平行实现。

### `surrogatePairFromCodePoint` (`src/libs/unicode.zig:285`)

- **签名**：`pub fn surrogatePairFromCodePoint(code_point: u21) SurrogatePair`。
- **作用**：非 BMP → 代理对。
- **实现**：减 0x10000 拆 10+10。调用方保证 `>0xFFFF`。
- **所有权 / 错误 / 调用**：非 unicode 正则把码点拆成两个 atom。

### `appendUtf16CodePoint` (`src/libs/unicode.zig:293`)

- **签名**：`pub fn appendUtf16CodePoint(allocator: std.mem.Allocator, units: *std.ArrayList(u16), code_point: u21) std.mem.Allocator.Error!void`。
- **作用**：追加一个码点的 UTF-16。
- **实现**：BMP 一单元，否则两代理。
- **所有权 / 错误 / 调用**：OOM。列表调用方拥有。

### `appendUtf8CodePoint` (`src/libs/unicode.zig:303`)

- **签名**：`pub fn appendUtf8CodePoint(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), cp: u32) std.mem.Allocator.Error!void`。
- **作用**：UTF-8 编码（1–4 字节）。
- **实现**：标准前缀。不拒绝代理。
- **所有权 / 错误 / 调用**：`appendUtf16UnitsAsUtf8`。

### `appendUtf16UnitsAsUtf8` (`src/libs/unicode.zig:321`)

- **签名**：`pub fn appendUtf16UnitsAsUtf8(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), units: []const u16) std.mem.Allocator.Error!void`。
- **作用**：UTF-16（含未配对代理）转 UTF-8。
- **实现**：成对代理合成；孤立代理当码点写 3 字节。
- **所有权 / 错误 / 调用**：WTF-16 → WTF-8。

### `normalizeAlloc` (`src/libs/unicode.zig:338`)

- **签名**：`pub fn normalizeAlloc(allocator: std.mem.Allocator, src: []const u32, form: NormalizationForm) std.mem.Allocator.Error![]u32`。
- **作用**：NFC/NFD/NFKC/NFKD。返回 owned UTF-32。
- **实现**：NFC 且全 latin1 直接拷贝。否则 `toNfdRec`（compat 看 KC/KD）+ CCC 排序。NFD/NFKD 到此结束。NFC/NFKC：从左组合，blocked 若中间 CCC ≥ 当前。
- **所有权 / 错误 / 调用**：调用方 `free`。韩文音节在 `toNfdRec`/`composePair` 特判。

### `propertyRangePoints` (`src/libs/unicode.zig:396`)

- **签名**：`pub fn propertyRangePoints( allocator: std.mem.Allocator, expr: []const u8, inverted: bool, ) UnicodeError!CharRange`。
- **作用**：把属性表达式建成区间，供 LRE 发射。
- **实现**：`propertyRangeSet`；可选 invert；`compress`。
- **所有权 / 错误 / 调用**：`InvalidProperty`。`addUnicodeProperty` 用。

### `propertyRangeSet` (`src/libs/unicode.zig:409`)

- **签名**：`fn propertyRangeSet(allocator: std.mem.Allocator, expr: []const u8) UnicodeError!RangeSet`。
- **作用**：解析 `Name` 或 `Name=Value` 并建区间。
- **实现**：名字/值长度 ≥64 非法。Script/scx/gc 分流；无值先当 GC，失败再 `unicodeProp`。带未知键 → `InvalidProperty`。
- **所有权 / 错误 / 调用**：与 `parsePropertyExpression` 平行但不走 names union。

### `toUpperAscii` (`src/libs/unicode.zig:429`)

- **签名**：`pub fn toUpperAscii(c: u8) u8`。
- **作用**：ASCII 大写。
- **实现**：a–z 减 32。
- **所有权 / 错误 / 调用**：`core/string.zig` 的 latin1 大小写转换、`string_builtin_ops.toUpperAscii`。

### `toLowerAscii` (`src/libs/unicode.zig:434`)

- **签名**：`pub fn toLowerAscii(c: u8) u8`。
- **作用**：ASCII 小写。
- **实现**：A–Z 加 32。
- **所有权 / 错误 / 调用**：`equalsIgnoreAsciiCase`。

### `equalsIgnoreAsciiCase` (`src/libs/unicode.zig:439`)

- **签名**：`pub fn equalsIgnoreAsciiCase(a: []const u8, b: []const u8) bool`。
- **作用**：等长且逐字节 ASCII 忽略大小写。
- **实现**：长度先比。
- **所有权 / 错误 / 调用**：不处理非 ASCII。

### `caseConv1` (`src/libs/unicode.zig:472`)

- **签名**：`fn caseConv1(c: u32, conv_type: u32) u32`。
- **作用**：只要映射的第一个码点。
- **实现**：`caseConv(...).codepoints[0]`。
- **所有权 / 错误 / 调用**：多码点折叠后再 lower。

### `caseConv` (`src/libs/unicode.zig:476`)

- **签名**：`fn caseConv(c_in: u21, conv_type: u32) RawCaseMapping`。
- **作用**：conv_type 0 大写、1 小写、2 折叠。
- **实现**：ASCII 手写；否则 `findCaseEntry` → `caseConvEntry`。
- **所有权 / 错误 / 调用**：`caseConvert`。

### `caseConvEntry` (`src/libs/unicode.zig:490`)

- **签名**：`fn caseConvEntry(c_in: u32, conv_type: u32, idx: usize, v: u32) RawCaseMapping`。
- **作用**：按 `RUN_TYPE_*` 解码一次映射（可能 1–3 码点）。
- **实现**：从 `v` 取 typ/code，`data1 = ((v & 0xf) << 8) | case_conv_table2[idx]` 再索引 `case_conv_ext`。`UL` 奇偶对换，`LSU` 三元，`EXT2/3` 多码点；conv_type=2（折叠）时对多码点结果逐个再 `caseConv1(...,1)`。
- **所有权 / 错误 / 调用**：`caseFoldingEntry` 复用。

### `caseFoldingEntry` (`src/libs/unicode.zig:568`)

- **签名**：`fn caseFoldingEntry(c_in: u21, idx: usize, v: u32, is_unicode: bool) u32`。
- **作用**：RegExp canonicalize 的单码点结果。
- **实现**：unicode：`caseConvEntry(...,2)`；多码点只特判 `fb06/01fd3/01fe3`。非 unicode：ASCII 小写→大写；否则取 `caseConvEntry(...,0)` 的 upper mapping，且必须单码点且结果 ≥128 才接受（`ſ` 的大写是 ASCII `S`，非 `/u` 模式下被这条挡掉、保持 U+017F；U+212A KELVIN SIGN 的 run 是 `LF_EXT`，只在 to-lower 方向生效，本来就不会落到 ASCII）。
- **所有权 / 错误 / 调用**：`regexpCanonicalize`、`CharRange.regexpCanonicalize`。

### `findCaseEntry` (`src/libs/unicode.zig:590`)

- **签名**：`fn findCaseEntry(c: u21) ?CaseEntry`。
- **作用**：二分 `case_conv_table1`。
- **实现**：`code = v>>15`，`len = (v>>8)&0x7f`。
- **所有权 / 错误 / 调用**：未命中 null。

### `getLe24` (`src/libs/unicode.zig:609`)

- **签名**：`fn getLe24(bytes: []const u8, offset: usize) u32`。
- **作用**：小端 24-bit。
- **实现**：三字节或。
- **所有权 / 错误 / 调用**：index 表。

### `getIndexPosition` (`src/libs/unicode.zig:618`)

- **签名**：`fn getIndexPosition(c: u21, index_table: []const u8) ?IndexPosition`。
- **作用**：从 3 字节索引跳到 RLE 附近。
- **实现**：每项 21-bit 码点 + 高位块偏移（`pos = (idx_min+1)*32 + v>>21`）。`c` 小于首项 → `{0,0}`；`c` ≥ 末项码点 → null。
- **所有权 / 错误 / 调用**：`isInTable`、`combiningClass`。

### `isInTable` (`src/libs/unicode.zig:647`)

- **签名**：`fn isInTable(c: u21, table: []const u8, index_table: []const u8) bool`。
- **作用**：带索引的 binary property。
- **实现**：从 `getIndexPosition` 起解码与 `unicodeProp1` 相同的 RLE，看当前 bit。
- **所有权 / 错误 / 调用**：ID_Start、Case_Ignorable。

### `shortCode` (`src/libs/unicode.zig:713`)

- **签名**：`fn shortCode(c: u32) u32`。
- **作用**：分解表短码 → 码点。
- **实现**：`<0x80` 原样；接着映射到 U+0300 段；两个分数斜杠特例。
- **所有权 / 错误 / 调用**：`decompEntry` S* 类型。

### `lowerSimple` (`src/libs/unicode.zig:725`)

- **签名**：`fn lowerSimple(c_in: u32) u32`。
- **作用**：分解表里的简单 lower。
- **实现**：latin1 或 Cyrillic A–Ya +0x20，否则 +1。
- **所有权 / 错误 / 调用**：`S2_UL` / `LS2_UL`。

### `get16` (`src/libs/unicode.zig:735`)

- **签名**：`fn get16(bytes: []const u8, offset: usize) u32`。
- **作用**：小端 u16。
- **实现**：两字节。
- **所有权 / 错误 / 调用**：分解数据。

### `decompEntry` (`src/libs/unicode.zig:739`)

- **签名**：`fn decompEntry(res: *[unicode_decomp_len_max]u32, c_in: u32, idx: usize, code: u32, len: u32, typ: u32) usize`。
- **作用**：按分解类型解开一个字符，返回长度（0=无）。
- **实现**：大 switch：`C1` 单码点，`L*` 定长 u16，`LL*` 带 2-bit 高位，`S*` shortCode，`I*` 增量，`B*` 基址+字节，`PAT3` 三明治，`UL` 大小写对。
- **所有权 / 错误 / 调用**：`decompChar`、组合二分。

### `decompTypeI` (`src/libs/unicode.zig:825`)

- **签名**：`fn decompTypeI(res: *[unicode_decomp_len_max]u32, c: u32, code: u32, d: []const u8, l: usize, p: usize) usize`。
- **作用**：增量分解：第 `p` 个分量加 `c-code`。
- **实现**：其余分量原样 u16。
- **所有权 / 错误 / 调用**：`I1`–`I4_*`。

### `decompTypeB` (`src/libs/unicode.zig:834`)

- **签名**：`fn decompTypeB(res: *[unicode_decomp_len_max]u32, c: u32, code: u32, d: []const u8, l: usize) usize`。
- **作用**：基址 + 每字节偏移；`0xff` → U+0020。
- **实现**：`c_min = get16(d,0)`。
- **所有权 / 错误 / 调用**：`B1`–`B18`。

### `decompChar` (`src/libs/unicode.zig:849`)

- **签名**：`fn decompChar(res: *[unicode_decomp_len_max]u32, c: u32, is_compat1: bool) usize`。
- **作用**：二分分解表；`is_compat1=false` 时跳过兼容分解。
- **实现**：`unicode_decomp_table1` 打包 code/len/type/compat bit。
- **所有权 / 错误 / 调用**：`toNfdRec`。

### `unicodeComposePair` (`src/libs/unicode.zig:871`)

- **签名**：`fn unicodeComposePair(c0: u32, c1: u32) u32`。
- **作用**：在组合表里找能分解成 `(c0,c1)` 的字符。
- **实现**：二分 `unicode_comp_table`（指向 decomp 项+偏移），比较 pair。
- **所有权 / 错误 / 调用**：0 表示不能组合。韩文不走这里。

### `combiningClass` (`src/libs/unicode.zig:899`)

- **签名**：`fn combiningClass(c: u32) u32`。
- **作用**：CCC；默认 0。
- **实现**：index + 变长 run；typ 0 固定、1 递增、2 为零、else 230。
- **所有权 / 错误 / 调用**：排序与 blocked。

### `sortCanonicalCombiningClass` (`src/libs/unicode.zig:932`)

- **签名**：`fn sortCanonicalCombiningClass(buf: []u32) void`。
- **作用**：starter 之间按 CCC 稳定插入排序。
- **实现**：跳过 CCC=0；对 combining 段插入。
- **所有权 / 错误 / 调用**：NFD 后。

### `toNfdRec` (`src/libs/unicode.zig:957`)

- **签名**：`fn toNfdRec(allocator: std.mem.Allocator, out: *std.ArrayList(u32), src: []const u32, is_compat: bool) std.mem.Allocator.Error!void`。
- **作用**：递归分解。
- **实现**：韩文音节拆 L+V(+T)；否则 `decompChar` 再递归，叶子 append。
- **所有权 / 错误 / 调用**：OOM。`normalizeAlloc`。

### `composePair` (`src/libs/unicode.zig:978`)

- **签名**：`fn composePair(c0: u32, c1: u32) u32`。
- **作用**：一次组合，含韩文 LV / LVT。
- **实现**：L+V → 音节；LV+T → LVT；否则 `unicodeComposePair`。
- **所有权 / 错误 / 调用**：NFC 循环。

### `CharRange.init` (`src/libs/unicode.zig:997`)

- **签名**：`pub fn init(allocator: std.mem.Allocator) CharRange`。
- **作用**：空区间。
- **实现**：`points = .empty`。
- **所有权 / 错误 / 调用**：必须 `deinit`。

### `CharRange.deinit` (`src/libs/unicode.zig:1001`)

- **签名**：`pub fn deinit(self: *CharRange) void`。
- **作用**：释放点对缓冲。
- **实现**：`points.deinit`。
- **所有权 / 错误 / 调用**：LRE defer。

### `CharRange.items` (`src/libs/unicode.zig:1005`)

- **签名**：`pub fn items(self: *const CharRange) []const u32`。
- **作用**：借出 `lo,hi,...`。
- **实现**：`points.items`。
- **所有权 / 错误 / 调用**：测试 `pointsContain`。

### `CharRange.addInterval` (`src/libs/unicode.zig:1009`)

- **签名**：`pub fn addInterval(self: *CharRange, lo: u32, hi: u32) std.mem.Allocator.Error!void`。
- **作用**：追加半开区间，不立即合并。
- **实现**：`hi<=lo` 忽略。
- **所有权 / 错误 / 调用**：不取所有权：区间写进 `self.points`，内存由 `CharRange` 自己的 `allocator` 持有、`deinit` 释放。error set 只有 `std.mem.Allocator.Error`（`ensureUnusedCapacity` 一次扩两格后 `appendAssumeCapacity`），OOM 沿 `try` 上抛给 regexp 编译器，再由其转成 JS 异常。调用方是本文件的字符类构造（:1215,1304,1374 等 19 处）与 `src/libs/regexp.zig:3832,3834,3847` 等 9 处。

### `CharRange.appendPoints` (`src/libs/unicode.zig:1016`)

- **签名**：`pub fn appendPoints(self: *CharRange, points: []const u32) std.mem.Allocator.Error!void`。
- **作用**：追加已有点对。
- **实现**：`appendSlice`。
- **所有权 / 错误 / 调用**：`addSet`。

### `CharRange.addSet` (`src/libs/unicode.zig:1020`)

- **签名**：`pub fn addSet(self: *CharRange, other: *const CharRange) std.mem.Allocator.Error!void`。
- **作用**：并上 other's 点（未规范化）。
- **实现**：`appendPoints`。
- **所有权 / 错误 / 调用**：随后要 `normalize`。

### `CharRange.normalize` (`src/libs/unicode.zig:1024`)

- **签名**：`pub fn normalize(self: *CharRange) void`。
- **作用**：排序并合并重叠。
- **实现**：`sortAndRemoveOverlap`。
- **所有权 / 错误 / 调用**：发射前。

### `CharRange.compress` (`src/libs/unicode.zig:1028`)

- **签名**：`pub fn compress(self: *CharRange) void`。
- **作用**：合并相邻相等端点（已排序假设）。
- **实现**：`compressAdjacent`。
- **所有权 / 错误 / 调用**：`invert` / `makeOp` 后。

### `CharRange.compressAdjacent` (`src/libs/unicode.zig:1032`)

- **签名**：`fn compressAdjacent(self: *CharRange) void`。
- **作用**：丢掉空区间，拼接 `hi==next.lo`。
- **实现**：读写指针。
- **所有权 / 错误 / 调用**：原地。

### `CharRange.sortAndRemoveOverlap` (`src/libs/unicode.zig:1053`)

- **签名**：`pub fn sortAndRemoveOverlap(self: *CharRange) void`。
- **作用**：按 lo 插排再合并重叠。
- **实现**：`insertionSortPointPairs` + `compressOverlapping`。
- **所有权 / 错误 / 调用**：canonicalize 结果。

### `CharRange.compressOverlapping` (`src/libs/unicode.zig:1058`)

- **签名**：`fn compressOverlapping(self: *CharRange) void`。
- **作用**：合并 `next.lo <= hi` 的区间。
- **实现**：扩展 hi。
- **所有权 / 错误 / 调用**：要求已按 lo 排序。

### `CharRange.unionWith` (`src/libs/unicode.zig:1081`)

- **签名**：`pub fn unionWith(self: *CharRange, other: *const CharRange) std.mem.Allocator.Error!void`。
- **作用**：原地并。
- **实现**：`opWith(.op_union)`。
- **所有权 / 错误 / 调用**：OOM；self 缓冲被替换。

### `CharRange.intersectWith` (`src/libs/unicode.zig:1085`)

- **签名**：`pub fn intersectWith(self: *CharRange, other: *const CharRange) std.mem.Allocator.Error!void`。
- **作用**：原地交。
- **实现**：`.op_inter`。
- **所有权 / 错误 / 调用**：`/v` `&&`。

### `CharRange.xorWith` (`src/libs/unicode.zig:1089`)

- **签名**：`pub fn xorWith(self: *CharRange, other: *const CharRange) std.mem.Allocator.Error!void`。
- **作用**：对称差。
- **实现**：`.op_xor`。
- **所有权 / 错误 / 调用**：派生 Changes_When_Titlecased。

### `CharRange.subWith` (`src/libs/unicode.zig:1093`)

- **签名**：`pub fn subWith(self: *CharRange, other: *const CharRange) std.mem.Allocator.Error!void`。
- **作用**：差集。
- **实现**：`.op_sub`。
- **所有权 / 错误 / 调用**：`/v` `--`。

### `CharRange.opWith` (`src/libs/unicode.zig:1104`)

- **签名**：`fn opWith(self: *CharRange, other: *const CharRange, op: BinaryOp) std.mem.Allocator.Error!void`。
- **作用**：替换 self 为二元运算结果。
- **实现**：`makeOp` 后 deinit 旧 points。
- **所有权 / 错误 / 调用**：`out.points` 所有权移交。

### `CharRange.makeOp` (`src/libs/unicode.zig:1111`)

- **签名**：`fn makeOp( allocator: std.mem.Allocator, a: *const CharRange, b: *const CharRange, op: BinaryOp, ) std.mem.Allocator.Error!CharRange`。
- **作用**：扫描线：点对的奇偶表示「在集合内」。
- **实现**：归并 a/b 的端点；`is_in` 按 union/inter/xor/sub；状态翻转才输出点。最后 `compress`。
- **所有权 / 错误 / 调用**：要求输入已压缩。OOM `errdefer`。

### `CharRange.invert` (`src/libs/unicode.zig:1163`)

- **签名**：`pub fn invert(self: *CharRange) std.mem.Allocator.Error!void`。
- **作用**：相对 `[0, sentinel)` 求补。
- **实现**：头插 0、尾插 sentinel，`compress` 丢掉空段。
- **所有权 / 错误 / 调用**：`\P`、`[^…]`、Unknown script。

### `CharRange.regexpCanonicalize` (`src/libs/unicode.zig:1172`)

- **签名**：`pub fn regexpCanonicalize(self: *CharRange, is_unicode: bool) std.mem.Allocator.Error!void`。
- **作用**：ignore-case 下把集合闭包到折叠类。
- **实现**：与大小写 run 相交得「会变的」点，逐点 `caseFoldingEntry` 攒映射区间；不变的点留下；并起来。
- **所有权 / 错误 / 调用**：`/u` 与 `/v` 调用时机不同（求补前/后）。

### `CharRange.rangeCount` (`src/libs/unicode.zig:1230`)

- **签名**：`pub fn rangeCount(self: *const CharRange) usize`。
- **作用**：区间个数。
- **实现**：`len/2`。
- **所有权 / 错误 / 调用**：发射 `range` 的 n。

### `CharRange.rangeAt` (`src/libs/unicode.zig:1234`)

- **签名**：`pub fn rangeAt(self: *const CharRange, index: usize) CharRangePointRange`。
- **作用**：第 index 个 `[lo,hi)`。
- **实现**：`points[2i], points[2i+1]`。
- **所有权 / 错误 / 调用**：调用方保证 index 合法。

### `CharRange.isEmpty` (`src/libs/unicode.zig:1242`)

- **签名**：`pub fn isEmpty(self: *const CharRange) bool`。
- **作用**：无点。
- **实现**：`len==0`。
- **所有权 / 错误 / 调用**：空 class 发射不可能的 `char32 0xffffffff`。

### `CharRange.lastHi` (`src/libs/unicode.zig:1246`)

- **签名**：`pub fn lastHi(self: *const CharRange) u32`。
- **作用**：最后一个 hi（可能是 sentinel）。
- **实现**：`items[len-1]`。空则越界——调用方先查 empty。
- **所有权 / 错误 / 调用**：决定 range vs range32。

### `insertionSortPointPairs` (`src/libs/unicode.zig:1253`)

- **签名**：`fn insertionSortPointPairs(points: []u32) void`。
- **作用**：按 lo 对点对插入排序。
- **实现**：步长 2。
- **所有权 / 错误 / 调用**：区间通常很少。

### `generalCategory` (`src/libs/unicode.zig:1268`)

- **签名**：`fn generalCategory(allocator: std.mem.Allocator, name: []const u8) UnicodeError!RangeSet`。
- **作用**：GC 名 → 区间。
- **实现**：`gcIndex` 失败 `InvalidProperty`；再 `unicodeGeneralCategory1(mask)`。
- **所有权 / 错误 / 调用**：`propertyRangeSet`。

### `unicodeGeneralCategory1` (`src/libs/unicode.zig:1273`)

- **签名**：`fn unicodeGeneralCategory1(allocator: std.mem.Allocator, gc_mask: u32) std.mem.Allocator.Error!RangeSet`。
- **作用**：从 GC 表**建区间**（对照 regexp_properties 的 bool 版）。
- **实现**：同一 RLE；命中则 `addInterval`；v=31 交错按 2 步加点。
- **所有权 / 错误 / 调用**：OOM `errdefer`。

### `unicodeProp1` (`src/libs/unicode.zig:1317`)

- **签名**：`fn unicodeProp1(allocator: std.mem.Allocator, prop: data.Prop) UnicodeError!RangeSet`。
- **作用**：binary property → 区间。
- **实现**：无表 `InvalidProperty`。同一 RLE，bit 真时 `addInterval`。
- **所有权 / 错误 / 调用**：`ensureTotalCapacity(table.len)` 预估。

### `unicodeCase1` (`src/libs/unicode.zig:1351`)

- **签名**：`fn unicodeCase1(allocator: std.mem.Allocator, case_mask: u32) std.mem.Allocator.Error!RangeSet`。
- **作用**：case run → 区间。
- **实现**：与 regexp_properties 同掩码；UL/LSU 展开。
- **所有权 / 错误 / 调用**：`CharRange.regexpCanonicalize` 的 mask。

### `unicodePropOps` (`src/libs/unicode.zig:1396`)

- **签名**：`fn unicodePropOps(allocator: std.mem.Allocator, ops: []const properties.Op) UnicodeError!RangeSet`。
- **作用**：在 `RangeSet` 栈上跑派生 ops。
- **实现**：最多 4 层；失败 deinit 已压栈。
- **所有权 / 错误 / 调用**：返回 stack[0] 所有权。

### `unicodeProp` (`src/libs/unicode.zig:1450`)

- **签名**：`fn unicodeProp(allocator: std.mem.Allocator, name: []const u8) UnicodeError!RangeSet`。
- **作用**：属性名 → 区间。
- **实现**：`propIndex`；ASCII `[0,0x80)`；Any `[0,0x110000)`；ops；否则表。
- **所有权 / 错误 / 调用**：`propertyRangeSet` 无值分支。

### `scriptRanges` (`src/libs/unicode.zig:1474`)

- **签名**：`fn scriptRanges(allocator: std.mem.Allocator, script_name: []const u8, is_ext: bool) UnicodeError!RangeSet`。
- **作用**：Script / Script_Extensions 区间。
- **实现**：主表：typ≠0 且 v 匹配（或 Unknown 先收集再 invert）。ext：Common/Inherited 与扩展非空区间交补；其它并上扩展命中。
- **所有权 / 错误 / 调用**：与 `unicodeScript` 谓词同一语义。

### `addSequenceProperty` (`src/libs/unicode.zig:1553`)

- **签名**：`pub fn addSequenceProperty( allocator: std.mem.Allocator, comptime Context: type, ctx: *Context, prop_name: []const u8, comptime callback: fn (*Context, []const u21) std.mem.Allocator.Error!void, ) UnicodeError!bool`。
- **作用**：展开 property of strings，每条序列回调。
- **实现**：未知名 false；否则 `sequenceProp1`。
- **所有权 / 错误 / 调用**：LRE `buildStringPropertyStringList`。callback 签名 `fn(*Context, []const u21) !void`。

### `isSequencePropertyName` (`src/libs/unicode.zig:1565`)

- **签名**：`pub fn isSequencePropertyName(prop_name: []const u8) bool`。
- **作用**：是否 `/v` 字符串属性。
- **实现**：`sequencePropIndex != null`。
- **所有权 / 错误 / 调用**：`parseStringPropertyEscape` 先看这个再消费 `\p`。

### `sequenceProp1` (`src/libs/unicode.zig:1571`)

- **签名**：`fn sequenceProp1( allocator: std.mem.Allocator, comptime Context: type, ctx: *Context, prop: data.SequenceProp, comptime callback: fn (*Context, []const u21) std.mem.Allocator.Error!void, ) UnicodeError!void`。
- **作用**：按 SequenceProp 枚举展开。
- **实现**：Basic_Emoji = Emoji1 ∪ (Emoji2+FE0F)；Modifier = 每基 + 5 肤色；Flag = 表值拆成两个 regional indicator；ZWJ/Tag 走专用表；Keycap 加 FE0F+20E3；RGI_Emoji 递归前面所有。
- **所有权 / 错误 / 调用**：临时 CharRange defer。

### `emitPropertySequences` (`src/libs/unicode.zig:1654`)

- **签名**：`fn emitPropertySequences( allocator: std.mem.Allocator, comptime Context: type, ctx: *Context, prop: data.Prop, comptime suffix: []const u21, comptime callback: fn (*Context, []const u21) std.mem.Allocator.Error!void, ) UnicodeError!void`。
- **作用**：属性区间每个码点加上 suffix 回调。
- **实现**：`unicodeProp1` + normalize。
- **所有权 / 错误 / 调用**：Basic_Emoji / Keycap。

### `emitZwjSequences` (`src/libs/unicode.zig:1679`)

- **签名**：`fn emitZwjSequences( comptime Context: type, ctx: *Context, comptime callback: fn (*Context, []const u21) std.mem.Allocator.Error!void, ) std.mem.Allocator.Error!void`。
- **作用**：解码 `unicode_rgi_emoji_zwj_sequence` 并展开肤色/发型。
- **实现**：每条：len、然后 packed u16（pres/mod/code）。code <0x1000 → U+2000 段，否则 U+1F000。mod=1/2/3 展开 5/25/20 肤色组合；hc_pos 展开 4 发型。组件之间插 U+200D。
- **所有权 / 错误 / 调用**：无分配 besides callback。

### `rangesContain` (`src/libs/unicode.zig:2127`)

- **签名**：`fn rangesContain(ranges: []const CodePointRange, code_point: u21) bool`。
- **作用**：测试夹具：半开 `CodePointRange` 是否含点。
- **实现**：线性。
- **所有权 / 错误 / 调用**：仅 test。

### `pointsContain` (`src/libs/unicode.zig:2134`)

- **签名**：`fn pointsContain(points: []const u32, code_point: u21) bool`。
- **作用**：CharRange 点对是否含点。
- **实现**：步长 2。
- **所有权 / 错误 / 调用**：测试 + shortcut 对照。

### `expectRegexpShortcutMatchesRangeBuilder` (`src/libs/unicode.zig:2142`)

- **签名**：`fn expectRegexpShortcutMatchesRangeBuilder(expr: []const u8) !void`。
- **作用**：断言零分配谓词与 `propertyRangePoints` 在边界点一致。
- **实现**：测 0、U+2E2F、10FFFF 以及每个区间端点±1。
- **所有权 / 错误 / 调用**：test。失败 `TestUnexpectedResult`。

### `expectRegexpShortcutPointMatchesRanges` (`src/libs/unicode.zig:2162`)

- **签名**：`fn expectRegexpShortcutPointMatchesRanges(expr: []const u8, points: []const u32, code_point: u21) !void`。
- **作用**：单点对照 `isUnicodePropertyMatches` vs `pointsContain`。
- **实现**：不一致 print 后 error。
- **所有权 / 错误 / 调用**：上一函数。

## 覆盖核对

- 清单函数数: 147（`src/libs/unicode.zig` 114 + `src/libs/unicode/data.zig` 7 + `src/libs/unicode/names.zig` 15 + `src/libs/unicode/properties.zig` 2 + `src/libs/unicode/regexp_properties.zig` 9）
- 本文标题覆盖: 147
- 未覆盖: 无

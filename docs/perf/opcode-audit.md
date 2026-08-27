# zjs opcode 逐条设计审计

日期：2026-08-27。PERF-OPCODE-SPACE 的设计输入之二（之一是
[opcode-space-survey.md](opcode-space-survey.md)，讲扩容与回收机制）。
本文讲**我们的 251 个 opcode 各自该不该存在**。

逐条数据在附录 [opcode-audit-table.md](opcode-audit-table.md)。
跨引擎事实全部读自本地源码：V8 15.4（`/home/aneryu/v8`）、
JSC（`/home/aneryu/WebKit`）、Hermes（`/home/aneryu/hermes`）、
QuickJS 2026-06-04（`/home/aneryu/quickjs`）。

## 1. 方法

三个数据源，缺一不可：

1. **动态频次**：15 个 zoo 基准的全量 opcode 剖析，41,888,384,774 次执行。
2. **发射路径**：逐条确认谁产生这个字节。分类器改了三次才对——
   短指令是 `op.push_0 + val` 算术生成的、私有字段族由 `bytecode.zig`
   自己的下降代码写入、`and`/`or`/`catch` 因是 Zig 关键字要写成
   `op.@"and"`。**三次假阳性都由读代码消除，不是由更好的正则。**
3. **跨引擎对照**：同一语义在另外三家是几个 opcode，以及它们用什么替代。

## 2. 我们与 QuickJS 的差集

```
zjs = QuickJS(244) − 15 个已回收 + 22 个自加融合 = 251
```

**我们比 QuickJS 多的 22 个，全部是融合指令**（`push_0_or`、
`get_var_ref0_get_loc8`、`get_loc0_field`…），加上冷平面载体 `using`。
每一个都在挣钱，只有 `put_loc0_get_loc0` 例外——419 亿次里跑了 8 次。

**QuickJS 有而我们没有的 15 个**，正是历次回收的战果：
`dup1/2/3`、`insert4`、`is_undefined`、`perm5`、`rot3r/4l/5l`、`swap2`、
`typeof_is_*`（并入 `using` 平面），以及今天退役的 `nip1`、降级的
`check_ctor_return`/`set_proto`。

## 3. 关于融合指令的一条对照证据（必须回应）

V8 在 2016 年 5 月加了 5 个 `Ldr*` 融合 opcode（`25b3fe7961f`），
**半年后又全部删掉**（`f633218b624`），commit 原文：

> "We seem to get some small wins from avoiding the Ldr bytecodes,
> probably due to **reduced icache pressure since there are less bytecode
> handlers**."

替代方案是解码期的 `Star` lookahead——不新增 opcode，在 handler 内部
偷看下一条指令。我们有 22 个融合 opcode，其中 16 个确实在跑（`push_0_or`
占全部执行的 9.0%），所以不能直接照搬这个结论；但**「融合 op 的收益可能
被 handler 数量增加抵消」是有实测反例的**，将来再加融合前应当先量 I-cache。

另一条配套证据在 JSC：融合 op 无法中途 deopt 这个老问题，JSC 用
**checkpoints** 解决——`iterator_open`/`iterator_next`/`instanceof`/
`*_varargs` 在 `BytecodeList.rb` 里声明 `checkpoints:`，一条 bytecode
内部有多个可恢复点。这是「语义多步、编码一步」同时保住 OSR 的通用解法。

## 4. 按族审计：我们花 43 个编号买的东西，别人花 0–4 个

这是本次审计最重的发现。七个族，我们 43 个编号，其中**四个族的执行次数
是精确的 0**：

| 族 | zjs 编号数 | 15 基准执行次数 | V8 | JSC | Hermes | 他们用什么 |
|---|---|---|---|---|---|---|
| **TDZ 检查变体** | **9** | **0** | 4 | 2 | 3 | **检查与访问分离**（见 §4.1 修订） |
| **Reference 具体化** | **6** | **0** | 0 | 0 | 0 | 不具体化（寄存器机基址可复用） |
| **`with` 专用访问** | **5** | **120** | 0 | 0 | 0（不支持 with） | 只留「建 with 作用域」，访问退化到通用动态查找 |
| **super** | **4** | **0** | 1 | 0 | 0 | 复用通用 `*_with_this` / `WithReceiver` 形式 |
| 类定义/命名 | 6 | 1,662,159 | 0 | 1 | 4 | flag 操作数挂在通用 define 上 |
| 栈洗牌 | 9 | 128,992,268 | 0 | 0 | 0 | 寄存器机不需要 |
| 一元 `+` / `pow` / `to_object` / `to_propkey` | 4 | 602 | 3 | 4 | 2 | ~~`plus` 三家都没有~~ **作废：`plus` 就是我们的 ToNumber**（§10） |

逐族说明：

### 4.1 TDZ 检查变体（9 个编号，0 次执行）

`get_loc_check`、`get_loc_checkthis`、`put_loc_check`、`put_loc_check_init`、
`set_loc_check`、`set_loc_uninitialized`、`get_var_ref_check`、
`put_var_ref_check`、`put_var_ref_check_init`。

**修订（2026-08-27，逐条读实现后）：三家不是「只有一条检查 op」，而是
「检查与访问分离」。** 各自的检查型 opcode 数量：

- V8 **4 条**：`ThrowReferenceErrorIfHole`、`ThrowSuperNotCalledIfHole`、
  `ThrowSuperAlreadyCalledIfNotHole`、`ThrowIfNotSuperConstructor`
  （`bytecodes.h:484-488`），配 `LdaTheHole` 哨兵。
- JSC **2 条**：`check_tdz` + `is_empty` 谓词。
- Hermes **3 条**：`ThrowIfEmpty`、`ThrowIfUndefined`、
  `ThrowIfThisInitialized`。

真正的结构差异不是数量，是**组合方式**：我们的 9 条是
「检查 × 访问」的笛卡尔积（3 种检查语义 × get/put/set 三种访问形式），
它们的 2~4 条是**纯检查**，对任何访问形式复用。

因此省编号的估计要下修：**9 → 约 3，净省约 6**（不是 7~8）。

**并且对栈机要换一种分解方式。** 寄存器机的 `ThrowIfHole <reg>` 直接读
寄存器、不动栈，所以「load + check + store」是自然的。我们是栈机，照抄
会让写侧从 `put_loc_check idx`（3 字节）膨胀成
`get_loc; throw_if_uninit; drop; put_loc`（4 条指令 10 字节）。适合栈机
的形态是**不碰栈的原地检查**：

```
check_tdz_loc <idx>        // size 3, pop 0, push 0：局部槽为哨兵则抛
check_tdz_var_ref <idx>    // 闭包变量版
```

于是 `get_loc_check idx` → `check_tdz_loc idx; get_loc idx`（2 条 6 字节），
写侧同理，扩张是 3→6 字节而不是 3→10。这些路径在 15 个基准里执行 0 次。

### 4.2 Reference 具体化（6 个编号，0 次执行）——**估计已下修，见 §11**

`make_loc_ref`、`make_arg_ref`、`make_var_ref`、`make_var_ref_ref`、
`get_ref_value`、`put_ref_value`。三家确实一个都没有，但**「所以我们能
省 6 个」是错的**，理由与 §10 的 `plus` 同型。

读实现（`parser.zig:4879` `needs_reference`、`bytecode.zig:6640-6710`
`scope_make_ref` 的下降）后的事实：这一族只在**静态解析不出的作用域
变量**上触发——`with` 块和直接 `eval` 里的复合赋值/自增。规范要求引用
只求值一次，所以必须把「已解析到的基址」保存下来。

**寄存器机把它留在寄存器里，我们是栈机、只能把 (scope, name) 对压到
栈上——`make_*_ref` 做的正是这件事。** 它不是一个可以删掉的多余概念，
而是同一件事在栈机上的形态。

真正可省的是**变体数**：四个 `make_*_ref` 只在「引用的是 arg / local /
var_ref / var_ref_ref 哪一种槽」上不同，正是 §5 第 1 条「flag 操作数吃掉
变体」的标准场景。**4 → 1，净省 3**（不是 6）。

### 4.3 `with` 专用访问（5 个编号，120 次执行）

`with_get_var`/`with_put_var`/`with_delete_var`/`with_make_ref`/
`with_get_ref`，全是 size 10 的 `atom_label_u8`。

三家的一致做法：**只保留一条「建 with 作用域」的指令**（V8
`CreateWithContext`、JSC `push_with_scope`），之后 with 块内的变量访问
一律走通用动态查找路径，用操作数上的枚举值区分（JSC 的 `ResolveType`
有 13 个值，把变量访问的所有变体压进一个操作数）。Hermes 更彻底——
**`with` 语句直接不支持**，`SemanticResolver.cpp:757` 编译期报错。

### 4.4 super（4 个编号，0 次执行）

`get_super`、`get_super_value`、`put_super_value`、`set_home_object`。

- **写侧三家零个**：JSC 用 `put_by_id_with_this`/`put_by_val_with_this`，
  Hermes 用 `PutByValWithReceiver`，V8 走 runtime 调用。
- `set_home_object` **三家零个**：V8 存成普通 context slot；JSC 存成
  callee 上的私有属性 `@homeObject` 用普通 `get_by_id` 读；Hermes 折进
  `CreateBaseClass` 的输出寄存器。

### 4.5 栈洗牌（9 个编号，0.31%）

`nip`、`dup`、`insert2`、`insert3`、`perm3`、`perm4`、`swap`、`rot3l`、
`nip_catch`。三家 **0/0/0**——它们存在的唯一原因是我们是栈机，不是 JS
语义需要。这一族**不能靠对照删掉**：真要省，得换执行模型，那是另一个
量级的决定。但其中 `nip`、`perm4`、`swap`、`rot3l` 四个是 **0 次执行**，
可以进冷平面。（`using` 平面已经吸收过 `insert4`/`rot5l`/`perm5`/`dup2`/
`swap2`/`rot3r`/`rot4l`/`dup3`/`dup1` 九个同类。）

### 4.6 类定义/命名（6 个编号）

`set_name` 独占 166 万次，其余五个合计 39 次。三家的做法是**把命名做成
flag 位挂在已有的 define 指令上**（V8 的
`DefineKeyedOwnPropertyFlag::kSetFunctionName`），或干脆编译期决定写进
函数表（Hermes）。

### 4.7 一元 `+`（602 次）——**本条已作废，见 §10**

初稿写的是「三家零个，一律用 `ToNumber`/`ToNumeric`，我们可以并入」。
读实现后作废：**我们根本没有 `to_number`/`to_numeric` opcode——`plus`
就是我们的 ToNumber**（`value_ops.zig:255,263`：数值直通、BigInt 抛
TypeError，正是 ToNumber 语义）。三家管它叫 `ToNumber`，我们叫 `plus`，
是同一条指令的不同名字。删掉它等于没有 ToNumber。

## 5. 省编号的三种正统手法（各有源码或 commit 证据）

1. **flag 操作数吃掉变体。** V8 把 `StaGlobalSloppy`+`StaGlobalStrict`
   合成 `StaGlobal`（commit `e8a0a3717c3`，理由：feedback vector 已经是
   language mode 的权威来源）；JSC 的 `ECMAMode`、`ResolveType`(13 值)、
   `GetPutInfo`、`PutByIdFlags`、`PrivateFieldPutKind` 全是这个模式。
2. **哨兵值吃掉检查型 opcode。** TDZ 三家一致；V8 更把 `ForOfNext` 的
   done 输出也用 hole 表示，省掉一个输出寄存器（commit `02a725e2a07`）。
3. **折进相邻指令的操作数。** Hermes 把 `set_proto` 折进
   `NewObjectWithParent`、把 home object 折进 `CreateBaseClass` 的输出、
   把 strict 折进 `DelByVal`；V8 把 `StackCheck` 折进 `JumpLoop`
   （commit `6c1e09aebe9`：*"Now that it is implicit in function entry and
   loop iteration, there is no need for an explicit bytecode"*）、把
   `OsrPoll` 折进 `Jump`。

第三条尤其值得注意：**Hermes 的 `set_proto` 处理方式，正是我们今天用
降级解决的同一个问题的另一种解法**——它根本不让这条指令存在。

## 6. 反向借鉴：他们有而我们没有的

不属于省编号，但属于「逐条审计」应当记录的设计差距：

| 来源 | 机制 | 为什么值得看 |
|---|---|---|
| JSC | **checkpoints** | 融合 opcode 无法中途 deopt 的通用解法 |
| JSC | `call_ignore_result` | 语句位置的调用不需要 dst 寄存器和 value profile |
| JSC | `get_length` 从 `get_by_id` 拆出 | 我们的 `get_length` 已经有了（peephole 产生） |
| Hermes | `AddN`/`SubN`/`JLessN`… | 类型推断证明是数字后的免检版本——**这正是 typed 路线在字节码层的形态** |
| Hermes | `GetOwnBySlotIdx` | 编译期已知槽号的直接读写，**T-spike 想做的事的终局形态** |
| Hermes | `StoreNPToEnvironment` | 存非指针值免写屏障——我们有 GC 屏障，直接可借鉴 |
| Hermes | `TypeOfIs` 位集 + `JmpTypeOfIs` | 一条指令表达 `typeof x === "object" \|\| typeof x === "function"` |
| V8 | `Star0..Star15`（16 个编号共用 1 个 handler） | 用真实网站字节码体积 −8~9% 论证的编号投资 |
| V8 | Smi 立即数二元族（12 条） | `x + 3` 不必先 push 常量 |

Hermes 那条 `JLessN` 的注释还提供了一个我们做 `cmp_if_false8` 类融合时
必须回应的论证（`BytecodeList.def:977-981`）：
*"Since NaN comparisons always return false, 'not less' != 'greater or
equal'"* ——取反跳转不能靠 `not` + `JmpTrue` 合成，必须成对存在。

## 7. 处置汇总

机械初判（频次+发射方式，见附录表）：

```
keep（热/温）                    146
keep（短指令族，算术生成）          6
demote（冷，普通发射路径）          86
demote（冷，走尺寸预言机/下降路径）  13
```

叠加本文 §4 的按族审计后，**除降级之外还有约 26 个编号可以靠语义重设计
省下来**，且每一项都有三家里至少两家的先例：

| 动作 | 涉及 | 净省 | 先例强度 |
|---|---|---|---|
| TDZ 改哨兵 + 单检查 op | 9 → 1~2 | ~7 | 3/3 家 |
| ~~去掉 Reference 具体化~~ **改为：四个 `make_*_ref` 合并为一条带 kind 操作数** | 4 → 1 | 3 | flag-操作数手法 |
| `with` 只留建作用域 | 5 → 1 | 4 | 3/3 家 |
| super 复用 `*_with_this` 形式 | 4 → 0~1 | ~4 | 2/3 家（写侧 3/3） |
| 类命名改 flag 操作数 | 6 → 2 | 4 | 2/3 家 |
| ~~`plus` 并入 `to_number`~~ **作废**（§10：`plus` 就是 ToNumber，已改名） | — | 0 | — |

这些是**语义重设计**，比降级贵，但省下来的是一等编号且永久生效；而且
其中 TDZ、Reference、super 三族在 15 个基准里**执行次数精确为 0**，
意味着改动的风险面主要在正确性（test262），不在性能。

## 8. 本次审计确认的三件事

1. **引擎里已经没有死 opcode 了。** 分类器修正三次后，251 个全部有发射
   路径。`nip1` 是最后一个真正的死代码，今天退役。
2. **「冷」和「该删」是两回事。** TDZ 族 0 次执行但绝不能删——它是
   `let` 的正确性基础，只能换实现方式。反过来 `dup` 跑了 8964 万次却在
   三家里一个对应都没有，因为那是执行模型差异而非语义需要。
3. **频次表加 grep 只能产候选，不能产判决。** 这条在本次审计里被证实了
   四次：`call_constructor`（组级数字掩盖单点）、短指令算术生成、
   `bytecode.zig` 内部下降发射、Zig 关键字引号形式。每一次都是读代码
   才纠正过来的。


## 9. 降级的第三个成本因子：身份匹配的扫描器（2026-08-27 实测）

前两个成本因子记在
[opcode-space-survey.md](opcode-space-survey.md) §8.4（尺寸预言机、字节
偏移 pin）。第三个是在降级 `put_super_value` 时撞到的：

`bytecode.zig` 的 `scanSmallInlineEligible` 走一遍字节码，**按 opcode 身份**
拒绝含有某些指令的函数参与小函数内联。`put_super_value` 在那张拒绝表里。
一旦它被降级成 `{using, sub}`，身份匹配就看不见它了——含 `super.x = v`
的函数会**悄悄变得可内联**，而这不是任何人想要的语义变化，也不会有测试
报错（行为差异只在优化覆盖面上）。

**规则：把一条 opcode 降级进冷平面，会让每一个按 opcode 身份做模式匹配的
扫描器失明，除非同步教会它看子字节。** 修法是在扫描器里给载体 opcode 加
一个分支去查 `code[pc + 1]`，而不是把整个载体加进拒绝表——后者会顺带把
含有无害栈洗牌（`dup1`/`insert4`/`rot5l` 等已在平面里的 14 个）的函数一起
排除掉。

降级前的检查清单，现在是三条：

1. 它是否经过预计算尺寸的写入器？（尺寸与编码必须同改）
2. 它是否出现在钉字节偏移的测试里？（pin 必须从实际发射流重算）
3. **它是否出现在任何按 opcode 身份匹配的扫描器/拒绝表里？**（扫描器必须
   同步学会看子字节）

第三条最隐蔽，因为它不会让测试变红。


## 10. 审计自身的修订记录（第五次「名字不等于设计」）

初稿的 §4.7 把 `plus`（一元 `+`）列为「三家都没有、可零风险并入
`to_number`」的合并候选。**动手前读实现，作废了这一条**：我们根本没有
`to_number`/`to_numeric` opcode，`plus` 就是我们的 ToNumber
（`src/exec/value_ops.zig:255` 数值直通、`:263` BigInt 抛 TypeError）。
三家叫它 `ToNumber`，我们叫 `plus`，是同一条指令的两个名字。

同一轮复核还下修了 TDZ 一行：三家不是「0~1 条检查 op」，而是 2~4 条
（V8 有 4 条 throw-check）；真正的差异是**我们把检查和访问做成笛卡尔积，
它们把检查独立出来复用**。

这是本次工作里第五次出现同一个错误形态：

| # | 错误 | 纠正方式 |
|---|---|---|
| 1 | `call_constructor` 被组级 0.063% 掩盖 | 逐条看频次 |
| 2 | 短指令「无发射点」 | 读到 `op.push_0 + val` 的算术生成 |
| 3 | 私有字段族「无发射点」 | 读到 `bytecode.zig` 内部的下降写入 |
| 4 | `and`/`or`/`catch`「无发射点」 | Zig 关键字要写成 `op.@"and"` |
| 5 | **`plus`「三家都没有」** | **读实现：那是 ToNumber 的别名** |

前四次是**分类器**的问题，第五次是**跨引擎对照**的问题——而且它更危险，
因为它会把一条「删掉这个 opcode」的建议送进执行队列。

**结论写进方法论：跨引擎对照必须按语义读实现，不能按名字匹配。** 本文
§4 的每一行在执行前都要重做一次这个检查；§7 的节省估计因此应视为上界。


## 11. 第六次核对，以及一次改名

owner 令「转做语义重设计」后，按 §10 立的规矩逐族重读实现。**Reference
族是第六次同型错误**：三家没有这些 opcode 是真的，但原因是它们把已解析
的基址留在寄存器里，而我们是栈机、只能压栈——`make_*_ref` 是同一件事的
栈机形态，不是多余概念。可省的是变体数（4 → 1，用 kind 操作数），不是
整族。

### 改名：`plus` → `to_number`

§10 那次误判的根源是名字。QuickJS 叫它 `OP_plus`，我们照抄；按名字做跨
引擎对照时「三家都没有 plus」成立，按语义读实现才发现三家的 `ToNumber`
就是它。**改名不是美化，是把导致误判的信息缺陷修掉**：现在任何人做同类
对照，一眼就能把 `to_number` 和 V8 的 `ToNumber`、JSC 的 `to_number`、
Hermes 的 `ToNumber` 对上。opcode 常量处保留了 QuickJS 原名的说明。

同类候选（尚未改，供后续一并处理）：

| 现名 | 问题 | 建议 |
|---|---|---|
| `make_var_ref_ref` | 两个 ref 叠词，无法从名字看出语义 | 随 4→1 合并一起消失 |
| `get_field2` | `2` 实为「保留 receiver」 | `get_field_keep_recv` |
| `fclosure` | qjs 缩写 | `create_closure` |
| `special_object` | 语义是「按种类加载特殊对象」 | `load_special` |

**方法论补充**：跨引擎对照按名字匹配会出错（§10 第五次、本节第六次），
而**我们自己的名字如果不表达语义，就是在给这种错误提供燃料**。逐条审计
时发现名不副实的，应当就地改掉。

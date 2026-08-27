# 四引擎指令集设计参考

**PERF-OPCODE-SPACE 的对照资料。**正文（现状、方案、裁决）在
[`opcode-design.md`](opcode-design.md)；本文只做一件事——**把 V8、JSC、
Hermes、QuickJS 各自的指令集设计记录下来，并给出逐语义域的完整对照**。

全部读自本地源码检出，日期 2026-08-27：

| 引擎 | 检出 | 指令集真源文件 |
|---|---|---|
| V8 15.4 | `/home/aneryu/v8` | `src/interpreter/bytecodes.h` |
| JSC | `/home/aneryu/WebKit` | `Source/JavaScriptCore/bytecode/BytecodeList.rb` |
| Hermes | `/home/aneryu/hermes` | `include/hermes/BCGen/HBC/BytecodeList.def` |
| QuickJS 2026-06-04 | `/home/aneryu/quickjs` | `quickjs-opcode.h` |
| zjs | 本仓 | `src/bytecode.zig` `opcode_info` |

**口径声明**（数字可复算，方法见 §8）：

- V8 = `BYTECODE_LIST_WITH_UNIQUE_HANDLERS_IMPL` 的 `V(`（193）+ `V_TSA(`（1，
  `BitwiseNot`）+ `SHORT_STAR_BYTECODE_LIST`（16）= **210**，不含 `Illegal`。
  ⚠️ 漏掉 `V_TSA(` 会少数 1 条。
- JSC = `begin_section :Bytecode` 内 `op :`（125）+ `op_group` 展开成员
  （69）= **194**；另有 CLoopHelpers 3 / NativeHelpers 85 /
  CLoopReturnHelpers 38 三个非 bytecode section，合计 279 个 OpcodeID。
- Hermes = `DEFINE_OPCODE_n`（180）+ `DEFINE_JUMP_n` 的宏展开（20 次调用 ×
  2 = 40，每次展开出 `name` 与 `nameLong`）= **220**。
  ⚠️ **只数 `DEFINE_OPCODE_n` 会漏掉全部跳转指令**——这是本文修订史里
  最严重的一次口径错误，见 §8。
- QuickJS = `quickjs-opcode.h` 的 `DEF(...)` = **244**（另有 19 个小写
  `def(...)`，即不进终流的 temp opcode，与 zjs 的相位复用区对应）。
- zjs = `opcode_info` 去掉 `unused_*` 与 19 个 `(temp)` 相位行 = **244**
  条终流指令，占用 **245** 个编号（差值来自 `invalid` 行）。

---

## 1. 一览

| | 机器模型 | 指令数 | opcode 宽度 | 操作数宽度机制 | 指令集怎么声明 | 每指令可变元数据 |
|---|---|---|---|---|---|---|
| **V8 Ignition** | 累加器 + 寄存器文件 | 210 | 1 字节 | **前缀平面** `Wide`/`ExtraWide`（×2/×4），按操作数类型决定是否缩放 | C 宏列表 `BYTECODE_LIST` | **FeedbackSlot 是一种操作数类型**，槽在 FeedbackVector 里 |
| **JSC** | 纯寄存器（三地址） | 194 | 1 字节（wide 平面预留 2 字节但未启用） | **生成器自动三档** Narrow / Wide16 / Wide32 | **Ruby DSL** `BytecodeList.rb` → 全量生成 | **`metadata:` 块**，49 条指令带，独立于指令流分配 |
| **Hermes HBC** | 纯寄存器（三地址） | 220 | 1 字节 | **手写 `Long` 变体**（18 个） | C 宏 `.def` 文件 | 无（AOT 编译，无解释器内联缓存） |
| **QuickJS** | 栈机 | 244 | 1 字节 | 手写短/宽形式 | C 宏 `.h` 双次包含（相位复用） | 无 |
| **zjs** | 栈机（继承 QuickJS） | 244 | 1 字节 | 手写短/宽形式 + 22 条融合 | **手写 Zig 结构体表**（六处同步） | 无（PERF-SIDECAR 未开工） |

---

## 2. V8 Ignition

### 2.1 机器模型：累加器 + 寄存器文件

结果隐式流入**累加器**，显式寄存器用 `Ldar r` / `Star r` 搬运
（`bytecodes.h:87,110`）。每条指令用 `ImplicitRegisterUse` 声明它对累加器
的读写：

```cpp
V(Ldar,  ImplicitRegisterUse::kWriteAccumulator, OperandType::kReg)
V(Star,  ImplicitRegisterUse::kReadAccumulator,  OperandType::kRegOut)
V(Mov,   ImplicitRegisterUse::kNone, OperandType::kReg, OperandType::kRegOut)
```

**这是一个为编码密度而做的取舍**：累加器让最常见的「上一条的结果喂给
下一条」不必编码任何操作数，代价是要显式的 `Ldar`/`Star` 搬运指令——
也就是说 **V8 用派发次数换字节数**。JSC 和 Hermes 选了相反的一边。

### 2.2 编码：操作数类型决定是否随前缀缩放

`bytecode-operands.h:15-59` 把操作数类型按**可缩放性**分类：

| 类别 | 成员 |
|---|---|
| 可缩放（有符号） | `Reg`, `RegList`, `RegPair`, `RegOut`, `RegOutList`, `RegOutPair`, `RegOutTriple`, `RegInOut`, `Imm` |
| 可缩放（无符号） | `ConstantPoolIndex`, **`FeedbackSlot`**, `ContextSlot`, `CoverageSlot`, `UImm`, `RegCount` |
| **固定宽度** | `Flag8`, `Flag16`, `IntrinsicId`, `RuntimeId`, `NativeContextIndex`, `AbortReason`, `EmbeddedFeedback` |

`Wide` / `ExtraWide`（id 0、1）把**紧随其后那条指令的全部可缩放操作数**
放大 2× / 4×（`bytecodes.h:678-719`）；固定宽度的不动。派发是一张连续的
768 项表，索引 `256 * scale + opcode`（`interpreter-assembler.cc:1433-1461`）。

**两条值得记的设计细节**：

1. **操作数类型编码了数据流方向**（`Reg` 读 / `RegOut` 写 / `RegInOut`
   读写）。从操作数类型就能派生每条指令的读写集，不必另写一张表。
2. **`FeedbackSlot` 是一种一等操作数类型**。反馈不是外挂的侧表查找，是
   指令自己带的槽号。

### 2.3 `Star0..Star15`：用体积数据论证的编号投资

16 个编号（`SHORT_STAR_BYTECODE_LIST`），源码注释写明理由：

> `/* Special-case Star for common register numbers, to save space */`

**它们共用一个 handler**（`kReadAccumulatorWriteShortStar`），换来真实网站
字节码体积 −8~9%。这是「为什么值得花 16 个编号」的教科书式论证——
**有量化收益，且成本只有编号而非 handler 数量。**

### 2.4 反复退役冷指令

从 git history 核实：

| commit | 内容 |
|---|---|
| `3b6773ba3d1` | 删 `ToBoolean`，并入 `JumpIfToBoolean*` |
| `e06d57b05de` | 删 `TestNotEqualsStrict`（parser 发 `TestEqualsStrict` + not） |
| `f633218b624` | 删**全部** `Ldr*` 融合，改用 Star lookahead |
| `a8176a530c3` | 删 `Nop` |
| `e8a0a3717c3` | `StaGlobalSloppy` + `StaGlobalStrict` → `StaGlobal`（feedback vector 已是 language mode 的权威来源） |
| `6c1e09aebe9` | `StackCheck` 折进 `JumpLoop`（*"Now that it is implicit in function entry and loop iteration, there is no need for an explicit bytecode"*） |
| `02a725e2a07` | `ForOfNext` 的 done 输出改用 hole 表示，省掉一个输出寄存器 |

`f633218b624` 的原文对我们尤其重要：

> *"We seem to get some small wins from avoiding the Ldr bytecodes, probably
> due to **reduced icache pressure since there are less bytecode handlers**."*

**V8 加了 5 条融合指令，半年后全删。我们有 22 条同类。**

### 2.5 逃生阀写在注释里

`interpreter-generator.cc:2679`：

> `// TODO(neis): Turn this into an intrinsic when we're running out of bytecodes.`

即：编号不够时，把指令降级进 `InvokeIntrinsic`（u8 子命名空间）或
`CallRuntime`（u16）。**与 zjs 的 `using` 冷平面是同一个机制。**

---

## 3. JSC（LLInt / Baseline）

### 3.1 机器模型：纯寄存器，三地址

```ruby
op_group :BinaryOp,
    [ :eq, :neq, :stricteq, :nstricteq, :less, :lesseq, :greater,
      :greatereq, :below, :beloweq, :mod, :pow, :urshift ],
    args: { dst: VirtualRegister, lhs: VirtualRegister, rhs: VirtualRegister }
```

局部变量**就是**虚拟寄存器，指令直接寻址。**整个指令集里与「搬运局部
变量」有关的只有一条 `mov`。**（对照：V8 19 条，我们 33 条。）

### 3.2 指令集在一个 DSL 里声明一次，其余全部生成

`BytecodeList.rb` 是唯一真源，`generator/main.rb` 生成 `Bytecodes.h`、
`BytecodeStructs.h`、LLInt 偏移、metadata 布局、三档宽度的发射器。

**194 个 opcode id 只有 135 个声明点**（125 个 `op :` + 10 个 `op_group`）。
`op_group` 的语义是：变体**各自保留独立 opcode id**（派发仍然直接，无二次
间接跳转），但只声明一次，共享 struct 布局、metadata 形状、生成出来的
访问器类。

**JSC 的答案是「变体不必合并，但必须只声明一次」。**

### 3.3 宽度：生成器自动三档

`generator/Opcode.rb:234-238`——发射时先试 `Narrow`，装不下退 `Wide16`，
再退 `Wide32`，一次声明生成三套路径。

配套的还有 `Fits.h:117-155`：**`Fits<VirtualRegister, Narrow>` 把
locals/args/constants 重映射进 −128..127**，让多数指令自然装进 narrow。
⇒ **JSC 完全没有「烧进操作数的短指令形式」**（没有 `get_loc0`）——它用
重映射操作数值来买 narrow 编码，而不是靠铸造 opcode。

`OpcodeSize.h:76-97` 还预留了「wide 平面用 2 字节 opcode id」的能力
（`Traits::maxOpcodeIDWidth = Wide16`，emit 侧的 `Fits` 已允许 id 到
65535），但 `JSOpcodeTraits::maxOpcodeIDWidth = Narrow`，**处于休眠**。
这是唯一一个真正扩展*编号*的工业级设计，而连 JSC 自己都没打开。

### 3.4 `metadata:`：每指令可变侧数据

49 条指令带 `metadata:` 块，与指令流分开分配：

```ruby
op :get_by_id,
    args: { dst: VirtualRegister, base: VirtualRegister,
            property: unsigned, valueProfile: unsigned },
    metadata: { modeMetadata: GetByIdModeMetadata }
```

这就是内联缓存与 profile 的载体。**zjs 的 PERF-SIDECAR 工作项要建的正是
这个东西**——值得注意的是 JSC 把它做成了**指令声明的一部分**，而不是一个
独立的侧表机制。

### 3.5 `checkpoints:`：融合指令的中途 deopt 解法

```ruby
op :iterator_next,
    ...
    tmps: { nextResult: JSValue },
    checkpoints: { computeNext: nil, getDone: nil, getValue: nil }
```

一条 bytecode 内部声明**多个可恢复点**和跨点存活的**临时值**。这是
「语义多步、编码一步」同时保住 OSR 的通用解法——`iterator_open`、
`iterator_next`、`instanceof`、`*_varargs` 都用它。

**对我们的意义**：融合 opcode 无法中途 deopt 是我们做 typed / JIT 时会
撞上的同一个问题，JSC 已经给出了通用解。

### 3.6 作用域访问：三条指令 + flag 操作数 + metadata

```ruby
op :resolve_scope,   args: { dst, scope, var, resolveType: ResolveType, localScopeDepth }
op :get_from_scope,  args: { dst, scope, var, getPutInfo: GetPutInfo, localScopeDepth, offset, valueProfile }
op :put_to_scope,    args: { scope, var, value, getPutInfo: GetPutInfo, symbolTableOrScopeDepth, offset }
```

**`ResolveType` 有 13 个值**，`GetPutInfo` 打包了更多。所有作用域访问的
变体都在操作数和 metadata 里，不在 opcode 里。整个作用域族 **7 个编号**
（对照：我们 30 个）。

---

## 4. Hermes HBC

### 4.1 机器模型：纯寄存器，三地址，且有真正的寄存器分配器

```
DEFINE_OPCODE_3(Add,  Reg8, Reg8, Reg8)   // :210
DEFINE_OPCODE_3(AddN, Reg8, Reg8, Reg8)   // :213  数字免检版
DEFINE_OPCODE_2(Mov,     Reg8,  Reg8)     // :168
DEFINE_OPCODE_2(MovLong, Reg32, Reg32)    // :171
```

操作数直方图（220 条指令）：**`Reg8` 446 个**，`UInt8` 52，`UInt32` 40，
`UInt16` 29，`Addr32` 25，`Addr8` 22，`Reg32` 2，`Imm32` 1，`Double` 1。
**它的指令绝大多数在寻址寄存器。**

`include/hermes/BCGen/HBC/HVMRegisterAllocator.h` —— 有独立的寄存器分配
pass。**这是方案 B 成本的一个直接参照物：寄存器机需要这一整块。**

### 4.2 宽度：手写 `Long` 变体，不用前缀

**38 个 `*Long`**（其中 20 个由 `DEFINE_JUMP_n` 宏自动配对生成）+ 1 个
`*Short`，占全表 **39/220 = 17.7%**。例：`MovLong`、`GetByIdLong`、`PutByIdLooseLong`、
`NewObjectWithBufferLong`… 官方设计文档自承取舍：

> *"we are trading off with an increasing number of opcodes to handle
> different operand widths … We believe that we are able to avoid opcode
> explosion by generating the code smartly."*

**三家三种宽度答案**：V8 前缀平面 / JSC 生成三档 / Hermes 手写 Long。
没有唯一正解，但都不是「每个宽度一个手写编号且不成体系」。

### 4.3 `ASSERT_EQUAL_LAYOUT`：类型化变体是同布局兄弟

15 对编译期断言，钉住两条指令**逐字段同布局**：

```
ASSERT_EQUAL_LAYOUT3(Add, AddN)
ASSERT_EQUAL_LAYOUT3(Sub, SubN)
ASSERT_EQUAL_LAYOUT2(GetById, TryGetById)
ASSERT_EQUAL_LAYOUT1(PutByIdLoose, PutByIdStrict)   // 及其 Long 变体共 4 对
```

换来的是：**解释器可以把类型化变体当作通用变体的原地替换，反优化只是改
一个字节。**

**Hermes 只有 8 个类型化变体**：算术四个 `AddN`/`SubN`/`MulN`/`DivN`，
跳转四个 `JLessN`/`JNotLessN`/`JLessEqualN`/`JNotLessEqualN`。
因为 `Add r,r,r` 本来就带着操作数，类型特化只需省掉检查，**不需要重新
解决寻址**。

### 4.4 环境（闭包变量）：物化进寄存器再索引

```
GetEnvironment        r_env, r_?, depth
GetParentEnvironment  r_env, depth
GetClosureEnvironment r_env, r_closure
LoadFromEnvironment   r_dst, r_env, idx      (+ L 变体 UInt16 idx)
StoreToEnvironment    r_env, idx, r_val      (+ L 变体)
StoreNPToEnvironment  r_env, idx, r_val      (+ L 变体)   // 非指针，免写屏障
CreateEnvironment / CreateFunctionEnvironment / CreateTopLevelEnvironment
```

**`StoreNPToEnvironment`（存非指针值免写屏障）是可以直接借鉴的**——我们
有 GC 写屏障，而且 tracing GC 线正在推进。

### 4.5 字节码是分发产物

Hermes 是四家里唯一把字节码当作**发布 artifact** 的（`BytecodeVersion.h`
里 `BYTECODE_VERSION = 99`，单调整数，格式一变就 +1；另有
`BytecodeFileFormat.h` / `BytecodeFormConverter.h`）。

**这给 SER-ARTIFACT 一个现成的对照**：一个单调版本号 + 严格的格式转换器，
而不是试图让指令集永不变化。

### 4.6 `with` 直接不支持

`SemanticResolver.cpp:757` 编译期报错。⇒ Hermes 在这一族的编号数是 0，
但那是**砍功能**，不是更好的设计。做对照时必须区分这两者。

### 4.7 NaN 与取反跳转（做融合前必须回应的论证）

`BytecodeList.def:977-981`：

> *"Since NaN comparisons always return false, 'not less' != 'greater or
> equal'"*

⇒ 取反跳转不能靠 `not` + `JmpTrue` 合成，**必须成对存在**。我们做
`cmp_if_false8` 这类融合时受同一约束。

---

## 5. QuickJS（我们的上游）

- 栈机，1 字节 opcode，244 条。
- **相位作用域的编号复用**：`quickjs-opcode.h` 用互补的宏定义被包含两次，
  19 个临时 opcode 与前 19 个短 opcode 占用**相同编号**（178–196），
  哪个含义生效由编译相位决定；运行时痕迹只有
  `short_opcode_info(op)` 里的索引偏移（`quickjs.c:22176-22186`）。
- **66 个短 opcode**（`push_0`、`get_loc0`…）：操作数烧进 opcode，取指时
  不必再读一个字节。
- 二级命名空间：`OP_special_object`（u8，7 种）、`OP_define_method`
  （atom + u8 flags，6 种组合）。

zjs 继承了全部这些结构（`op_temp_start = 178`, `op_temp_count = 19`），
并在其上加了 22 条融合指令和 `using` 冷平面。

---

## 6. zjs 现状（对照基线）

- 栈机，1 字节，244 条终流指令 / 245 个编号在用 / 11 空闲。
- **`using` 冷平面**（id 244，u8 子操作数）已吸收 16 个降级 opcode。
- **22 条融合指令**是我们比 QuickJS 多出来的部分。
- **指令集是手写的 Zig 结构体表**，每加一条要在**六处**同步：id 常量、
  `opcode_info` 行、栈效应 switch、handler 表、若干扫描器名单、测试。
- **没有每指令元数据机制**（PERF-SIDECAR 未开工）。

---

## 7. 逐语义域对照矩阵

按语义域把五家的指令逐条归类（方法与可复算脚本见 §8）。

| 语义域 | V8 | JSC | Hermes | QuickJS | **zjs** |
|---|---:|---:|---:|---:|---:|
| **局部/参数搬运** | 19 | **1** | 4 | 33 | **33** |
| **闭包/作用域变量** | 22 | **7** | 12 | 28 | **30** |
| **栈洗牌** | 0 | 0 | 0 | 19 | **9** |
| 命名属性 | 8 | 17 | 19 | 11 | 13 |
| 下标属性 | 5 | 12 | 13 | 3 | 4 |
| **跳转** | 25 | 23 | **45** | 7 | **7** |
| 调用/构造 | 13 | 10 | 11 | 14 | 15 |
| class / super | 5 | 4 | 5 | 17 | 14 |
| TDZ / hole 检查 | 5 | 2 | 3 | 10 | 10 |
| iterator / for-in/of | 5 | 10 | 5 | 11 | 11 |
| generator / async | 3 | 14 | 3 | 6 | 6 |
| 异常 | 7 | 3 | 5 | 6 | 6 |
| *已归类小计* | *105* | *95* | *122* | *160* | *153* |
| **总数** | **210** | **194** | **220** | **244** | **245** |

### 7.1 三条结论

**结论一：差距集中在三行，而且是同一件事。**

「局部搬运 + 作用域变量 + 栈洗牌」三行合计：

| | V8 | JSC | Hermes | QuickJS | zjs |
|---|---:|---:|---:|---:|---:|
| 寻址相关合计 | 41 | **8** | 16 | 85 | **72** |

**JSC 花 8 个编号，我们花 72。**

> **口径对齐**：本表的「局部/参数搬运 33」把 `var_ref` 归在「闭包/作用域
> 变量」行，而 [`opcode-design.md`](opcode-design.md) §2.2 的「槽位搬运
> 48」是 `get/put/set × loc/arg/var_ref` 的合并口径（48 = loc 18 + arg 15
> + var_ref 13 + 2 个宽形式）。两处切法不同但可互相还原，**不是矛盾**。
> §2.2 的「栈机专属开销」总计是 **58 个编号 / 34.08% 动态指令**。

**结论二：他们不是「普遍更省」，而是把编号花在别处。**

看属性访问与跳转两组：

| | V8 | JSC | Hermes | QuickJS | zjs |
|---|---:|---:|---:|---:|---:|
| 属性访问（命名+下标） | 13 | **29** | **32** | 14 | 17 |
| 跳转 | 25 | 23 | **45** | 7 | 7 |
| generator/async | 3 | **14** | 3 | 6 | 6 |

**三行我们都花得比他们少。**JSC 的 17 条命名属性指令里有 `get_by_id` /
`get_by_id_direct` / `get_by_id_with_this` / `try_get_by_id` / `get_length` /
私有字段族，每条都带内联缓存 metadata；Hermes 的 45 条跳转是「20 个逻辑
跳转 × 短/长两种地址宽度」加 5 条特殊形式，是拿编号换编码密度。

> **他们把编号花在优化上，我们把编号花在寻址上。**这比「我们臃肿」是一个
> 精确得多、也更有行动指向的说法。

**结论三：「他们零个」有三种完全不同的原因，不能混为一谈。**

| 我们有而他们零个 | 真实原因 | 可否照搬 |
|---|---|---|
| 栈洗牌（9） | **执行模型差异** | ❌ 换掉它得先换机器模型 |
| `with` 专用访问（Hermes 0） | **Hermes 砍了这个语法** | ❌ 我们不能不支持 `with` |
| Reference 具体化（三家 0） | 三家把基址留寄存器，**我们只能压栈** | ⚠️ 只能合并变体，不能整族删 |

这张表是 [`opcode-design.md`](opcode-design.md) §8「六次名字≠设计」的
浓缩版：**「三家都没有 X」这句话本身不含任何结论。**

---

## 8. 复算方法

矩阵不是手数的。提取五家 opcode 名单并按语义域归类的脚本口径：

```
V8      src/interpreter/bytecodes.h
        BYTECODE_LIST_WITH_UNIQUE_HANDLERS_IMPL 的 V(Name,..)  → 193
      +                                    的 V_TSA(Name,..)   →   1
      + SHORT_STAR_BYTECODE_LIST 的 V(Name,...)               →  16   = 210
JSC     bytecode/BytecodeList.rb，begin_section :Bytecode 段内
        ^op :name                                             → 125
      + op_group 的成员展开                                    →  69   = 194
Hermes  BCGen/HBC/BytecodeList.def
        ^DEFINE_OPCODE_n(Name                                 → 180
      + ^DEFINE_JUMP_n(Name) × 2（name 与 nameLong）           →  40   = 220
QuickJS quickjs-opcode.h 的 ^DEF( name                        → 244
        （另有 19 个小写 def( = temp，不进终流）
zjs     src/bytecode.zig opcode_info，去掉 unused_* 与
        注释含 "(temp)" 的 19 个相位行                         → 244
        （+ id 0 的 invalid 陷阱行 = 占用 245 个编号）
```

**四条必须遵守的口径纪律，每一条都是实际踩过的**：

1. **Hermes 的跳转指令不由 `DEFINE_OPCODE_n` 定义。** `DEFINE_JUMP_1/2/3(name)`
   各展开成**两条** opcode（`name` 用 `Addr8`、`nameLong` 用 `Addr32`）。
   20 次调用 = 40 条指令。只数 `DEFINE_OPCODE_n` 得 180，**漏掉全部跳转**，
   正确是 **220**。这是本工作里最严重的一次口径错误：它一度让「Hermes 只有
   4 个类型化变体」「Long 变体 18 个」两个结论都错（正确是 8 和 38）。
2. **V8 的列表里混用 `V(` 与 `V_TSA(`。**`V_TSA(BitwiseNot)` 只有一条，
   漏掉它得 209，正确是 **210**。
3. **V8 的 `Star0..Star15` 不在 `BYTECODE_LIST_WITH_UNIQUE_HANDLERS` 里**
   ——它们在单独的 `SHORT_STAR_BYTECODE_LIST`（因为共用一个 handler）。
   只数前者会漏掉 16 条，并得出「V8 的局部搬运只有 3 条」这种错误对照。
4. **zjs 的 178–196 是相位复用区**，同一个 id 有两行（temp / short）。
   按 id 去重而不看 `(temp)` 标记，会把 `get_loc0`/`get_loc1` 这些热指令
   判丢。

**方法论**：这四条的共同形态是——**指令集真源文件里的宏，会生成正则看不见
的指令**。任何一次「数 opcode」，都必须先回答「这个文件里有几种定义指令的
宏」，而不是直接对最显眼的那一种做正则。核对方式：拿总数与引擎自己的
`static_assert` 或已知发布数字对一次。

**同一陷阱的第五个实例**（不在指令表里，但形态相同）：Hermes 的 builtin
数量。`Builtins.def` 里 `BUILTIN_METHOD(` 有 54 条，但枚举还吃
`NORMAL_METHOD(`（2，**它被 `#define` 成 `BUILTIN_METHOD`**）、
`PRIVATE_BUILTIN(`（23）与 `JS_BUILTIN(`（3）——合计 **82**，与
`static_assert(BuiltinMethod::_count <= 256)` 同源。只数最显眼的那个宏得
80。⇒ **宏别名比宏本身更隐蔽。**

归类正则对 QuickJS 和 zjs **必须使用同一套**——它们是同一种 ISA 形态，
用两套正则会造出假的差异。

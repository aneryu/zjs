# V2 前端 CodeLoad 对齐优化复盘（2026-08-06）

## 1. 结论

本轮已把生产 V2 前端在固定 Closure 实际负载上的指令数从本轮开始时的
`36.716B` 降到 `21.347B`，减少 **41.86%**；cycles 和 wall time 分别减少
**46.86%**、**46.63%**。最终候选相对 pinned QuickJS 仍慢约
**21.34% instructions / 21.40% cycles / 21.14% wall**。

剩余最大差异不是 Lexer、atom、regexp-aware lookahead 或 resolve_labels：

1. **Parser core 是第一残差**，平坦 profile 的显式符号差约 `+2.90B`
   instructions；其中 binary-expression precedence recursion 只解释约
   `+0.12B`，不能把“改成迭代表达式 Parser”当成当前最大刀。
2. **resolve_variables 是第二残差**。考虑 QuickJS 内联和 inclusive callgraph
   后，zjs 仍大约多 `0.5B–1.0B` instructions。
3. zjs 的 Lexer、atom、resolve_labels、allocator/memory 在该负载上已经各自
   少于 QuickJS；没有新证据前，不应继续从这些路径盲砍。

这是本次变更所在提交的冻结收口记录，不是持续更新的状态台账。

## 2. 范围与测量对象

本报告只比较：

- 本次提交中的生产 V2 候选；
- pinned QuickJS 语义参考。

**不比较 legacy，也不把两个 V2 构建当成“当前实现对比”。** 下文的
candidate/main-start 数据只用于回答“本轮变更实际移除了多少工作”，不能替代
candidate/QuickJS 的当前差距结论。

| 项目 | 冻结值 |
| --- | --- |
| zjs 起点 | `25881dd3ba39d6204485bfb577652be2948e4974` |
| zjs 候选 | 本文件所在提交 |
| zjs 配置 | `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off` |
| zjs 起点二进制 SHA-256 | `419c97a732f41a6325ee57e89df77ceef3d085d20a116de560ff793ad71cc8ff` |
| zjs 候选二进制 SHA-256 | `dfff01d5ebc6e36087864c642b6d379bc7236d548aae2f81567b7306500aaa09` |
| QuickJS | `04be246001599f5995fa2f2d8c91a0f198d3f34c`，VERSION `2026-06-04` |
| QuickJS 二进制 SHA-256 | `b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d` |
| Zig | `0.16.0` |
| 主机 | Linux `6.17.0-1014-nvidia`，aarch64，固定 CPU 19（Cortex-X925） |
| workload | Closure 实际 CodeLoad，固定 `ITERS=4800` |
| workload SHA-256 | `3b5d467425c374da37444116d3c1bd6befc5da8e708bb19c6b3ab35139406383` |
| 采样 | 8 组平衡 ABBA；`perf stat` instructions/cycles；进程 wall clock |
| 工作校验 | 所有运行均为 `CHECKSUM: 4800/4800`、`ITERS: 4800` |

比值均为 `candidate/reference` 的逐配对 ratio median。主结论使用 instructions；
cycles 和 wall 不能反向。完整原始 JSON 在收口工作区中生成，其 SHA-256 为：

- candidate/main-start：
  `5def9f6d8366857ebc0f57476d33d938412f23b399aba326e53c0d14838a4346`
- candidate/QuickJS：
  `c0a9466f80b6641ce7485e6a18534bf24a06a417dcffdd66e06034d340f2b8b6`

## 3. 最新实际结果

### 3.1 生产 V2 候选与 pinned QuickJS

| 指标 | QuickJS median | zjs candidate median | candidate/QuickJS | 当前差距 |
| --- | ---: | ---: | ---: | ---: |
| instructions | `17.593B` | `21.347B` | `1.213393` | **+21.34%** |
| cycles | `3.623B` | `4.397B` | `1.213982` | **+21.40%** |
| wall | `0.9389s` | `1.1370s` | `1.211403` | **+21.14%** |

这是本报告的当前实现结论。

### 3.2 本轮变更相对 main 起点

| 指标 | main-start median | zjs candidate median | candidate/main-start | 移除工作 |
| --- | ---: | ---: | ---: | ---: |
| instructions | `36.716B` | `21.347B` | `0.581425` | **−41.86%** |
| cycles | `8.274B` | `4.397B` | `0.531379` | **−46.86%** |
| wall | `2.1314s` | `1.1379s` | `0.533704` | **−46.63%** |

最后一组保留切片（P88 → P96）又减少了 `7.09%` instructions、`4.79%`
cycles 和 `4.76%` wall；最终重建结果与 P96 的 candidate/QuickJS 数字一致到
约千分之二以内。

## 4. 本次保留的实现

### 4.1 Lexer、token 与 regexp-aware lookahead

- `Lexer.nextInto` 直接写入复用 token，去掉返回值复制，同时保留 token payload
  的原有所有权释放点。
- 新增非 owning 的 `simple_token` 扫描器，对齐 QuickJS
  `simple_next_token` / `js_parse_skip_parens_token` 的用途：模块首 token、单参数
  arrow、括号/方括号/花括号平衡扫描和后继 token 分类。
- balanced scanner 显式维护 regexp context、delimiter stack、top-level
  semicolon/ellipsis/assignment 三个 topology bit；template、identifier escape、
  非 ASCII mode-dependent 情况保守回退完整 Lexer，不猜语义。
- 后继 token 分类保留 plain `=` 与 `==` / `===` 的区别；pattern topology 只能
  把前者视为 initializer，不能把 equality 后的 object/array literal 改送到
  destructuring-assignment 分支。
- keyword dispatch 先按长度、首字节收窄；`of` 继续只在 parser lookahead 中作为
  contextual token，普通 Lexer 不把合法标识符 `of` 变成关键字。
- CLI 的 module detection 复用同一 non-owning scanner，删除另一套重复 Lexer。

这条路径没有建立 token 数组，也没有为 lookahead atomize。实测 borrowed
regexp-aware lookahead 的成本约 `0.50B` instructions，低于 QuickJS 对应
skip-parens inclusive 路径的约 `0.64B`；它不是当前差距来源。

### 4.2 Atom

- 数字 spelling 先走 array-index gate；普通字符串只计算一次 Wyhash。
- predefined string atom 使用静态开放寻址表，动态 atom map 用 adapted lookup
  复用同一 hash，避免“predefined miss 后再 hash 一次”。这是 zjs 分离
  predefined/dynamic 表示下对 QuickJS 单一 atom hash/probe 机制的承载，不是
  新的语言 fast path。
- parser 的 `async`、`eval`、`of`、`target` 等高频 contextual 判断使用已知
  predefined AtomId；未改变 token occurrence 的 retain/release 合同。

Atom 平坦成本约为 zjs `1.05B`、QuickJS `1.32B` instructions；继续改 atom
不能解释剩余总差距。

### 4.3 Parser 与 emit

- 普通 emit API 恢复 QuickJS 形状：`emit_op` 只写 opcode；真正拥有源码位置的
  grammar production 显式写 source event，连续相同 source 被去重。
- function/method/arrow/class child 的 source start 在进入 production 时捕获，
  避免后续 token 状态反推。
- `async` contextual keyword 先做 AtomId identity 检查；arrow/cover grammar
  lookahead 优先走 borrowed scanner，只有不确定时才事务式恢复完整 Lexer。
- parser emit 时同步写一个稀疏 control index，只记录 relocation 不能表达的
  terminal/direct-eval 事件；常见四项以内内联在 Builder 中。
- script 始终像 QuickJS 一样物化隐藏 `<ret>` completion slot，embedding 是否
  返回结果移到执行后的 host policy，避免 Parser/CFG 因调用选项产生两种形状。

没有回退到 AST，也没有增加通用 per-instruction IR。表达式 parser 仍是手写
recursive descent；本轮没有为了形式上的“迭代化”重写它。

### 4.4 resolve_variables 与 CFG

- phase-1 bytecode 使用紧凑 opcode metadata 和单一 decoder；atom-bearing temp
  opcode 不再通过多套 size/format switch 重复分类。
- CFG 从 label/reloc 加稀疏 control index 构造；生产 parser 输入会校验 index
  与真实 opcode 一致，合成测试输入保留自验证 decode fallback。
- binding topology、最终 binding/action 和 dynamic-environment probe 拆成
  QuickJS `resolve_scope_var` 形状的线性 walk；热结果压成 register-sized plan，
  不物化通用 resolution object。
- bind/source/control side event 使用单调 frontier cursor；output code、atom、
  source streams 一次估算容量并连续写入，增长留在 outlined slow path。
- parser 已提供 direct-eval census 后，不再为每条普通 instruction 重扫整份
  code 发现相同事实。

### 4.5 resolve_labels、stack size 与 finalize

- resolve_labels 预分配连续 output/source scratch，常见 append 只做一次容量判断；
  source attachment 的多 source 慢路被单独 outlined。
- final opcode 使用四字节 compact metadata；stack-size walk 直接读取相同表，
  不再重复构造或解码 name-bearing metadata。
- packed FunctionBytecode finalize 把 final code owner、atom operand、var-ref 的
  验证合并到最终 choke point；普通独立调用仍保留 resolve_labels 自验证。
- compiler 临时大块初始化使用明确的 bulk fill，使 Zig 生成与 QuickJS `memset`
  对应的循环/库调用形状；没有把任意源码强制复制到 SIMD buffer。

### 4.6 编译 churn 中的 GC 工作

cycle collector 在对象移入/移出 trial garbage list 时同步维护临时 membership
bit，删除 sweep 前对 runtime object list 和 garbage list 的再次全量扫描。这与
QuickJS 用链表归属表达相同状态的机制一致，且不改变 GC 判定或错误处理。

## 5. 剩余差距归因

下表使用最终候选同一保留源码状态的 P96 instructions profile。分类是近似归因，
不能机械相加：QuickJS C 编译器会把一部分 parser 工作内联到
`js_create_function`，inclusive callgraph 与平坦符号的边界不同。

| 机制 | zjs | QuickJS | 判断 |
| --- | ---: | ---: | --- |
| Lexer | `12.09% ≈ 2.58B` | `19.94% ≈ 3.51B` | zjs 约少 `0.93B`，不是差距 |
| Parser core（显式平坦符号） | `23.26% ≈ 4.97B` | `11.77% ≈ 2.07B` | **最大残差，约 +2.90B**；需用 inclusive source attribution 继续拆 |
| regexp-aware lookahead | `≈0.50B` | `≈0.64B` inclusive | zjs 更少，不应回退到完整 Lexer prescan |
| resolve_variables | `10.79% ≈ 2.31B` | direct inclusive segment `≈1.25B` | **第二残差，保守估计 +0.5B–1.0B** |
| resolve_labels + pc2line | `12.57% ≈ 2.69B` | `18.74% ≈ 3.30B` | zjs 约少 `0.62B` |
| atom | `4.90% ≈ 1.05B` | `7.51% ≈ 1.32B` | zjs 约少 `0.28B` |
| allocation / memory | `9.36% ≈ 2.00B` | `16.60% ≈ 2.92B` | zjs 约少 `0.92B` |

Parser core 内部目前可明确解释的部分：

- `parseExprBinary` 对 QuickJS binary parser 只多约 `0.12B`；
- primary/LHS/postfix 一组约多 `0.30B–0.45B`；
- function params/body 约多 `0.24B`；
- 其余主要分散在 token/state、scope/control、source 和 function construction
  bookkeeping，必须按 production 做 inclusive attribution，不能继续按单个最大
  flat symbol 猜。

声明冲突索引只在 declaration-heavy synthetic corpus 热；实际 Closure 中低于
`0.1%`。它不是下一轮优先级。

## 6. 被否决并已撤销的实验

| 实验 | instructions | cycles | wall | 裁决 |
| --- | ---: | ---: | ---: | --- |
| P97：统一 runtime atom map | `−0.25%` | `+0.09%` | `+0.09%` | **REJECT**：周期反向；已撤销 |
| P98：private-in cold outlining | `−0.005%` | `−0.25%` | `−0.37%` | **REJECT**：没有工作量下降，只有布局效应；已撤销 |
| P99/P100：compile-time 单 backend emitter 特化 | `−0.30%` | `+0.18%` | `+0.17%` | **REJECT**：周期反向；已撤销 |

P99 的第一版还暴露了一个重要生命周期事实：root function 在
`beginV2ProgramEmission` 之前会先发出 legacy-compatible scope marker；提前把
`emit_v2` 当成编译期常量会在 Builder 尚未挂载时调用 V2 emitter。修正崩溃后
虽然少了约 `0.30%` instructions，但 cycles/wall 仍回归。结论是：

- `emit_v2` 是生命周期状态，不是可随意删除的冗余分支；
- instructions 减少不自动等于可合入，I-cache/布局反向时必须拒绝；
- P21/P22 早期同类特化已有相同结果，没有新的 profile 证据不再重开。

## 7. 反思

1. **最大收益来自删除重复工作，而不是先上 SIMD。** 本轮真正有效的是复用
   token storage、borrowed lookahead、单次 atom hash、稀疏 CFG 事件、紧凑
   metadata、单调 cursor 和连续 output。全局 SIMD token index、完整 token
   array、AST 或通用 IR 都没有必要。
2. **QuickJS 源码必须和指令归因一起看。** 只按函数名比较会严重低估 QuickJS
   内联到 `js_create_function` 的工作；只看 inclusive callgraph 又会重复计入。
   正确方法是先确定机制边界，再用 flat + inclusive 两个视角夹住成本。
3. **不要由“最显眼的函数”推断最大差距。** binary-expression recursion 很醒目，
   但只解释约 `0.12B`；真正的大头是 parser production 间分散的 bookkeeping。
4. **实际 bundle 优先于合成 corpus。** declaration conflict 在合成输入很热，
   在 Closure 几乎不可见；若按 synthetic 排序会再次优化错对象。
5. **性能裁决仍需 A/B。** 语义修复可以直接按 QuickJS 机制落地，但合入性能
   结论必须由固定二进制、固定 CPU、校验输出的交错 PMU 数据支持。P97/P100
   都证明“看起来更少代码”不足以合入。
6. **保守 fallback 是正确的热路设计。** borrowed scanner 对确定 ASCII 形状直接
   回答；template、Unicode escape、mode-dependent regexp context 交给完整 Lexer。
   这比复制完整 Lexer 或冒险猜 `/` 的语义更快也更可靠。
7. **压缩 token payload 不等于压缩语义类别。** 第一次完整 test262 gate 用
   4 个 equality case 抓到 scanner 把 `==` / `===` 归为 plain `=`；main 起点和
   QuickJS 均通过。修复只收紧后继 token 分类，并补 scanner 与 production parser
   回归测试；随后目标 4 项和完整 gate 都通过。这个门禁阻止了一个仅靠既有
   481 项 parser suite 看不见的真实回归进入 main。

## 8. 后续优先级与 stop rule

1. 先给 Parser core 建立按 production 的 instructions/source attribution，优先
   拆 primary/LHS、function params/body、scope/control/source bookkeeping。
2. 再对 `resolve_variables` 做 QuickJS `resolve_scope_var` inclusive 对照，检查
   closure/dynamic-env walk 是否仍重复发布同一 identity/action。
3. 没有新 profile 证据时，不再动 Lexer、atom、regexp-aware lookahead、
   resolve_labels 或 emitter backend 特化。
4. 单个候选若在固定实际 Closure 上 instructions 改善不足 `0.2%`，只作为布局
   探针，不进入合入候选；cycles 反向则直接拒绝。
5. 正式性能合入继续遵守仓库 CodeLoad 协议：两次冷构建/side、四个交叉配对中
   instructions 同方向，cycles 不矛盾，再由 zoo code-load 宏基准仲裁。
6. correctness gate 任一回归、checksum 不同、配置签名漂移或 production route
   未被证明，性能数字全部作废。

## 9. 收口验证

| 门禁 | 结果 |
| --- | --- |
| `git diff --check` | PASS |
| `zig build test-core --seed 0 --summary all` | PASS：320 passed，1 skipped |
| `zig build test-bytecode --seed 0 --summary all` | PASS：211 passed |
| `zig build test-parser --seed 0 --summary all` | PASS：481 passed；包含 equality scanner 回归 |
| 原 4 个失败 test262 targeted rerun | PASS：4/4 |
| `mise run quick-check` | PASS：2 passed，1 skipped |
| `mise run checkpoint-check` | PASS：统一 Debug 2291 passed / 1 skipped；architecture、15/15 smoke、config drift 全通过 |
| `zig build test-oom --seed 0 --summary all` | PASS：21 passed |
| `zig build test262-gate --seed 0 --summary all` | PASS：0/49,775 errors，44,581 passed |
| `zig build test -Doptimize=ReleaseSafe --seed 0 --summary all` | PASS：2291 passed，1 skipped |

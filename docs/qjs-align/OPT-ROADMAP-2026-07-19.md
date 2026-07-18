# OPT-ROADMAP 2026-07-19 — QuickJS 机制忠实对齐计划

> 当前 main 审计基线：`0c7a46f88ea9fe3e7c4a1bd2e8dd4b6f2c7124d1`；
> 其中当前代码机制基线（compiler fix merge point）为
> `c034597c604f0b3f7e884d0f83554eaee7e95180`。
>
> 本轮原始源码/性能冻结点：`5a2dad4fce9c95e0e868d5f00415275f2f024ce1`。compiler-correctness
> 前置 `dbe50d7ddc78dff4affa35556db7909b4a0fe359` 已由 `c034597c` 合入；它不计作后续
> plain-put 收益，页首旧 M-CELL binary 只保留历史证据用途，下一步必须从当前 main 重冻。
>
> M-CELL 冻结 ReleaseFast zjs：完整 SHA-256
> `5da80d18ca74466513be780c31df3662358c184c3508904aacd3f7463c9894fc`；`.text`
> SHA-256 `453aea787671a22c90eceb43131dacf33357ad03791d8b8faca63321e17fa07c`
>（4,035,588 bytes）
>
> 性能参照 qjs：完整 SHA-256
> `b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d`；`.text`
> SHA-256 `f2d32f392089673065d7984b61c3ca30d818df54b9816152cd40d5d11e29b5bb`
>（725,228 bytes）
>
> QuickJS 源码 checkout：`/home/aneryu/quickjs-zjs-ref` @
> `04be246001599f5995fa2f2d8c91a0f198d3f34c`；该 checkout 新建 qjs 的完整 SHA-256 为
> `5e331bf92e236c8e2c3bd88032b3c1ec2c2e9e0cfe2e1bd40b4ce2bbeaacd365`，与性能 qjs 的
> `.text` 逐字节相同。完整 hash 差异来自非 `.text` 构建产物，性能仍固定使用前一个二进制。
>
> 本文取代 2026-07-18 版本；基于 2026-07-19 对当前代码、QuickJS 源码、历史战报和 PMU 的重新审计。

## 0. 目标、优先级与边界

本计划优化的是**引擎机制**，不是某个语言特性或 benchmark：

1. **第一优先：忠实采用 QuickJS 的通用机制。** 先逐段确认 QuickJS 的数据流、
   所有权、异常顺序、栈形态和热汇编，再讨论 zjs 改动。
2. **第二优先：因 Zig/LLVM/ABI/所有权模型限制而做的等价变体。** 这类偏离必须先写明
   无法直接镜像的具体限制，并保留语义等价证明和反汇编证据。
3. **最低优先：QuickJS 没有的 zjs 超集优化。** 只有当 QuickJS 机制已对齐、残差仍被
   定量证明，且偏离不是 benchmark 特化时才进入裁决。

“Zig 限制”必须是可复核的编译器、calling convention、布局、错误传播或内存安全约束；
代码写起来不方便、现有结构难改、或某个 benchmark 需要更快，都不算限制。resident Machine、
internal-record table、lazy property storage 和 parser 提前发 short opcode 是需要逐项审计的 zjs
架构选择，不自动等于 Zig 限制。tail-call dispatch 需要更精确地分类：历史
comptime-delete 二分已证明单体 Zig dispatcher 会引入约 3,504 bytes 的加性 spill，而 224-arm
tailcall 与 labeled-switch 的实测基本等价，两者的 next-dispatch 也已与 qjs computed-goto 处在同一量级。
这些数据的 owning 事实文档是 [CALL-MACHINERY-FAITHFUL-FRONTIER.md](CALL-MACHINERY-FAITHFUL-FRONTIER.md)。
因此当前 tailcall 形态是有代码生成证据的 Zig/LLVM 等价适配，整体 dispatch 战役冻结；
Zig 0.16 缺少 `preserve_none` 既不是这个结论的唯一理由，也不能用来免于逐 opcode 对照。
冷 handler 中单个 opcode family 的 pc/sp 发布与 residency 仍是可审计的执行差异，但不延伸成
“重写整个 dispatcher”。

禁止：

- 按脚本名、输入、pattern、literal、循环次数或 Zoo case 分支；
- 只为验收脚本融合函数体、硬编码输出或缩窄语义；
- 在 QuickJS 通用路径尚未对齐前新增 zjs-only fast path；
- 把“少了 instructions”直接等同于“更快”；
- 把已失败的历史刀换名后原样重跑；
- 一个候选同时修改两个机制，再用总结果反推各自收益；
- 新增仅为阻止 LLVM 重写或塑造单一热布局的 inline asm、opaque/volatile barrier、padding 或空逻辑；
  真实 ABI/硬件边界必须有独立机制理由、可观察契约和跨消费者证据。

QuickJS 自身存在的 invariant-based fast path 可以忠实镜像；它必须服务同一类运行时不变量，
而不是服务某个 benchmark。已有且正确、同时证明优于 qjs 的 zjs 机制也不为“代码长得一样”
而主动退化；此时要记录为什么它仍满足语义和机制边界。

## 1. 当前事实基线

### 1.1 已完成，不再列为未来工作

以下项目在旧路线图创建前或最新 regexp 战役中已经落地：

- shape transition 已有 cache hit / shared clone / `rc==1` in-place 三臂的拓扑；但 cache key 和
  property-storage reconciliation 尚未完全对齐，不再重做三臂，只继续审计其命中资格；
- Array.push 已在 `ToObject` 前走 qjs 式 direct dense-array arm，并直接维护 count/length；
- `resolve_labels` 及相关 finalize 已实现 dup+put→set、逻辑链、nullish/typeof、constant branch、
  push-neg、return-undef、dead code、inc/add-loc 等 matcher/fuse；完整 coverage 仍由 M-EMIT
  的最终字节码矩阵封账；
- 内建 Array/Map/Set/generator iterator 已有与 `JS_IteratorNext2` 对应的 result-object-free
  路径；
- 默认 64 位 16-byte JSValue、inline dup/free、zero-ref queue，以及 `[]*VarRef` + `pvalue`
  open/closed cell 表示已经按 qjs 落地；
- 普通对象的 `get_field/get_field2` 已有 qjs `GET_FIELD_INLINE` 式 shape-hash + prototype data walk；
  这不等于后续 method call 或 zjs fallback transport 已经对齐；
- regexp literal 编译、RegExp payload、result template、native cproto dispatch，以及
  split/match 的 realm/species/ownership 路径已在 `cb41f7fe` 对齐。

后续 profile 可以证明这些机制仍有残差，但不得再以“缺少该机制”为前提开刀。

### 1.2 2026-07-19 当前 zjs/qjs 基线测量

环境：Cortex-X925 CPU19、ReleaseFast、`taskset -c 19`、`armv8_pmuv3_1`，9 轮交错；
下表用 paired 样本的中位比，不使用 best-of-min 作为主结论。

| 症状探针 | zjs/qjs cycles | zjs/qjs instructions | 结论边界 |
|---|---:|---:|---|
| `for-of-bytecode-next-zero-arg-2m` | 1.771x | 1.560x | 复合了 iterator、cell、属性写和算术 |
| `array-push-one-arg-5m` | 1.541x | 1.467x | 不能直接归因为元素增长 |
| `object-literal-var-1m` | 1.440x | 1.619x | allocation + property publish 复合 |
| `allocation-empty-object-2m` | 1.149x | 1.356x | object lifecycle 的直接症状 |

M-CELL 的独立 direct probes 已进一步把读、写、set 和复合更新拆开；同样使用 CPU19、paired
median，baseline 为页首冻结 zjs：

| cell direct probe | zjs/qjs cycles | zjs/qjs instructions | 当前结论 |
|---|---:|---:|---|
| short plain read | 0.897x | 0.874x | zjs 已快于 qjs；不是当前收益面 |
| generic plain read | 0.899x | 0.884x | 同上，不能仅因源码多一个分支就开刀 |
| short plain put | 1.787x | 1.661x | 旧 baseline 的最大 direct 写差距；P1a 构造对齐后重测，才裁决 P1b |
| short set | 1.349x | 1.293x | 与 put 分开，作为第二候选 |
| short post-inc | 2.276x | 1.953x | 混入 read/number/update/lowering，只作后续 consumer |

已做过一次“plain read 与 checked read 分 handler”的干净候选，并在独立重建后跑 15 轮 paired
复核。它删除了 plain read 的 TDZ compare，instructions 如预期下降约 1.26%，但没有 cycles 收益，
同时无关 put/set controls 超过 +1%：

| 既有失败候选 | candidate/baseline cycles | candidate/baseline instructions |
|---|---:|---:|
| short read | 0.99998x | 0.98728x |
| generic read | 0.99939x | 0.98740x |
| short put control | 1.01219x | 0.99993x |
| short set control | 1.01191x | 1.00004x |
| post-inc control | 0.99792x | 0.99498x |

按 §8 该候选已回退，保留最终 opcode 契约测试。结论不是“分流机制错误”，而是这次 read-only
布局变化没有转化为 cycles，且污染了更重要的 write controls；没有新的源码事实、handler-cluster
策略或工具链变化，不得换名重跑。当前先完成 P1a 构造对齐，重冻后 P1b 直接转向
plain put，再单独做 set。

这些数字只是本计划的最新快照。正式候选开始前，M0 必须把原始逐轮数据、二进制 hash、
命令和环境固化到当前工作项；计划文本不代替可审计的原始证据。

注意：上面 M-CELL 的机制排序和失败刀结论仍有效，但 `c034597c` 已改变 compiler construction，
旧 zjs binary 不得继续充当 plain-put 候选的因果 baseline。

### 1.3 已确认的归因修正

1. `for-of-bytecode-next-zero-arg-2m.js` 在循环外创建并反复复用同一个 result 对象，
   因而不存在每轮 result 分配。zjs self-time 主要落在：
   `finishForOfNextResult` 17.15%、捕获 cell get/put 17.72%、post-update 11.47%、
   `op_for_of_next` 8.33%、result 属性写 7.12%、borrowed setup 6.67%。
2. for-of 差分结果为 zero-arg 1.772x、constant-result 1.423x、self-result 1.476x；
   普通零参 method control 仅 1.095x。generic continuation 与用户 `next()` 的 cell/property
   成本必须分开。
3. Array.push profile 中 field/method lookup、property helpers、call glue 和 length 远大于真正的
   append body；空数组 `pop()` 不增长元素却仍为 1.604x。当前要分别审计 shared property lookup
   与 native-call 机制，不能继续合成一个“push 成本”，也不是先改 capacity 算法。
4. object literal 当前热点仍包含 `adoptShapeForNewProperty`、object/shape create/destroy、
   root-shape lookup 和 MemoryAccount。因为 `rc==1` 臂已完成，必须先扣除空对象 lifecycle，
   再解释 property publish 残差。
5. “alloc-empty 在 07-08 曾为 0.96x”尚无同一入库脚本和原始数据可复核；该脚本到
   07-14 才入库。复现前只称“当前残差”，不称“已知回归”。

### 1.4 对 pinned QuickJS 实现的逐段复核

当前 checkout 在 Linux/aarch64 使用 `OPTIMIZE=1`、`SHORT_OPCODES=1`、`DIRECT_DISPATCH=1`
和 `CONFIG_STACK_CHECK`。这些编译期机制属于 reference 身份；只钉源码 commit 和 binary hash
还不够，M0 还要钉编译器、flags 和这些宏的有效值。

| 机制面 | QuickJS 实际实现 | 当前 zjs 结论 | 路线图动作 |
|---|---|---|---|
| call/dispatch | 单体 `JS_CallInternal`，computed-goto；bytecode call 递归进入新的 C frame，locals/stack 用 `alloca` | resident Machine + tail handlers + inline Entry 与 qjs 外形不同；但 3,504B spill 二分、224-arm A/B 和 next-dispatch 指令数已证明当前 dispatch 是 Zig/LLVM 下的等价适配 | 整体 dispatch 标记 DONE，不再全盘重开；只审计 qjs CASE-inline opcode 在 zjs 的冷/常驻位置，以及非 `.next` post-call continuation |
| generic iterator | `js_for_of_next → JS_IteratorNext → JS_IteratorNext2 → JS_Call`；generic result 依次读 `done`、ToBool、仅在 false 时读 `value`，最后 free result | `finishForOfNextResult` 的可观察顺序已基本相同；for-of 这类需要返回后继续作业的非 `.next` action 额外经 `return_action/payload` 和 cold continuation，普通 call 不经该路径 | 只将 post-call work 列入 M-RETURN-CONT；iterator 只是 direct consumer，不再成立 feature 刀 |
| captured cell | `js_closure2` 先检查声明、再只创建/别名 `JSVarRef*`；`instantiate_hoisted_definitions` 把函数值发布留给最终 `fclosure + put_var_ref`；plain get/put/set 直接访问 `pvalue`，只有 `*_check` 做 TDZ | `VarRef.pvalue`/slot type 已对齐，module 的 short-cpool 链接前缀等价；但 module wide `fclosure` 未被 link-time scanner 执行，部分 script/direct-eval 非 lexical 函数值又由实例化 helper 提前创建，compiler 反向抑制了前缀 | 先做 M-FCLOSURE-WIDTH correctness，再做 M-HOIST-CONSTRUCTION 对齐，重冻后才做 M-CELL-EXEC resident plain put、set；不重做 read split |
| binding resolution | `add_func_var` 用 `add_var` 建特殊 fallback，不挂 scope 链；const 取决于**定义函数** strict；sloppy `scope_put`→drop、`scope_make_ref`→临时对象引用；`with_make_ref` 在 RHS 前快照引用 | 历史 lazy self-binding 只搬了 materialization/prologue，保留了 scope-linked/unconditional const 和 runtime function-name workaround；`dbe50d7d` 已补 exact `add_var`、strict metadata、parameter-env fallback、drop/dummy-ref；zjs `with_get_ref + selected_reference with_put_var` 已证明是快照等价机制 | 该正确性前置已由 `c034597c` 合入；钉最终 bytecode snapshot 后封账，不把等价 `with` transport 改成源码外形相同 |
| named property read | `GET_FIELD_INLINE` 直接 `find_own_property`，沿 prototype walk；data hit dup，accessor/exotic/primitive 才进 `JS_GetPropertyInternal`；没有 IC | zjs ordinary data walk 已近似镜像，但 slow-object 顺序、null-prototype class fallback 和 tail transport 不同 | 从 native call 中拆出 M-PROPERTY-LOOKUP，独立测 lookup 与 fallback |
| native call | c-function object 直接保存 function union、cproto、magic、realm；`js_call_c_function` 建 native `JSStackFrame`、补可读缺参，再按 cproto switch | zjs function object 缓存 `InternalRecord*`，经 table/host-call transport；直接指针是等价候选，但不是 qjs 原布局 | M-NATIVE-CALL 只审计 callable→frame→record，不再混入 property lookup |
| empty object | `OP_object → JS_NewObject → JS_NewObjectFromShape`：GC trigger、Object alloc、按 shape `prop_size` 分配 property array、rc=1、挂 GC list | zjs 使用 shared root，但空对象 lazy-skip property array，并承担 MemoryAccount/Registry；这是已有 zjs 优化，不是 Zig 限制 | 按事件和关键链比较，不以分配次数机械求同 |
| shape transition | `find_hashed_shape_prop` 不比较 `prop_size`；cache hit 后若容量不同就 realloc 对象 property array，再采用目标 shape | zjs 三臂已存在，但 `findHashedShapeProperty` 要求 candidate `prop_size == property_capacity` | M-SHAPE-PUBLISH 的第一项改为验证并对齐 cache-hit 资格/容量协调 |
| RC/free | inline `JS_DupValue/JS_FreeValue`；对象到 0 后入 `gc_zero_ref_count_list`，由最外层 drain 调 `free_object/free_gc_object` | 默认 value representation 和 zero-ref queue 已同构 | 不重开抽象；只在 allocation direct profile 证明重复记账或关键链差异时动 |
| compiler | `resolve_variables → resolve_labels → compute_stack_size`；`OP_fclosure` 先保留宽 cpool index，`resolve_labels` 仅在 index≤255 时缩成 `fclosure8` | pipeline 顺序已同构，但 parser 有 4 个生产 call site 绕过 `emitFClosure` 直接 `@intCast` 后发 `fclosure8`；第 257 个 arrow/function expression 在 Debug 下 panic | 先修 M-FCLOSURE-WIDTH 并审计所有 cpool emitter/consumer；其余仍以 final-bytecode 等价为准，不按 pass 所在文件判断缺失 |
| stack/interrupt | stack overflow 是 native SP + planned `alloca_size` 检查；interrupt counter 在 call entry 和 jump/backedge poll | jump/call interrupt poll 已有；无限 tail recursion 来自 frame reuse 未消耗等价 stack budget | 正确性项只修 tail-chain stack budget；interrupt 作为既有门禁，不混成一项 |

## 2. 正确性前置依赖

正确性任务可以在独立 worktree 开发，但不能在 PMU 基线冻结后无条件并行合入。它们会改变
相关机制的成本或可验证边界；合入后必须重建基线。

| 正确性项 | 当前复现 | 阻塞的性能机制 |
|---|---|---|
| force-GC heap accounting | 已在 `0c7a46f8` 重验：`zig build test-exec -Dzjs_force_gc=true --summary all` 仍在 `gc.zig:1662` 抛 `HeapLiveBytesMismatch`，栈经 collection destroy/deferred weak-value free | M-ALLOC-LIFECYCLE、M-SHAPE-PUBLISH |
| tail-call reuse 的等价 stack budget | 已在 `0c7a46f8` 重验：`function f(){"use strict";return f()} f()` 的 zjs 1s 超时，qjs 由 `js_check_stack_overflow` 抛 `InternalError: stack overflow` | M-RETURN-CONT、M-FRAME-CONT |
| generator 函数表达式作默认参数 | 已在 `0c7a46f8` 重验：`function f(x=function*(){yield 1}){...}` 在 zjs 为 `UnexpectedToken`，qjs 返回 `1` | M-EMIT 的 parser/发码面 |
| named function-expression self-binding construction | 原冻结点的 lazy materialization 沿用旧 scope-linked/unconditional-const metadata，且参数默认值 `function f(x=f)` 被错发为 global read。`dbe50d7d` 已按 qjs 修复并由 `c034597c` 合入；checkpoint 1507/1507、相关 test262 30/30、full gate 0/49775 errors | 已解除 correctness 阻塞并废弃旧 M-CELL A/B；这一项本身不授权删 runtime publication，后者仍受 M-HOIST-CONSTRUCTION 阻塞 |
| `fclosure` cpool 宽度 | 已在 `0c7a46f8` 复现：同一 function 中 260 个 arrow expression 使 zjs-dev 在 `parser.zig:16646` 的 `@intCast(child_cpool_idx)` panic，qjs 正常编译/执行；parser 还有 3 个同类 direct-`emitFClosure8` 生产点 | M-FCLOSURE-WIDTH，阻塞 M-HOIST-CONSTRUCTION 和相关 M-EMIT |
| module link-time wide-function hoist | 已在 `0c7a46f8` 复现：260 个 exported module function 的循环依赖中，zjs 对所选 cpool 0/1/127/254/255 观察为 `function`，256/258/259 为 `ReferenceError`；pinned qjs 所选项全部为 `function`。`module.zig` 的链接扫描与 body-start 跳过都只识别 `fclosure8` | M-FCLOSURE-WIDTH，直接阻塞“module hoist 已等价”结论 |
| script/direct-eval 函数声明的创建阶段 | qjs `js_closure2` 只建/别名 cell，最终字节码仍是 `fclosure8; put_var_ref0`；zjs 的部分 nonlexical `global_vars.cpool_idx` 在 `instantiateGlobalVarDeclarations` 路径提前创建/发布函数值，`functionHasGlobalFunctionVarCpool` 再抑制字节码前缀 | M-HOIST-CONSTRUCTION，并是 M-CELL-EXEC baseline 的前置 |
| direct eval 下 function-name 与同名 body `var` | 已裁决：zjs 返回 `11`，pinned qjs 返回 `undefined`。test262 的 named-function-expression 规范测试明确要求独立 immutable function-name environment，body var environment 在其内层并可遮蔽；因此保留 zjs `11` | 已解除；记为有规范测试证据的 pinned-qjs 例外，不是 Zig 限制，不为清理 hot path 而改语义 |

依赖规则：

- M-ALLOC-LIFECYCLE/M-SHAPE-PUBLISH 的生产改动前先修 force-GC，恢复该门禁；
- 再动 M-RETURN-CONT/M-FRAME-CONT 前，先为复用 frame 的 tail chain 实现并验证与 qjs stack guard
  等价的可观察终止；现有 call/jump interrupt polling 单独保留并回归，不把两种机制揉成一个计数器；
- parser 正确性修复可独立进行，但若合入，M-EMIT 的 bytecode 基线必须重冻；
- M-FCLOSURE-WIDTH 必须在构造阶段优化前修复：所有 producer 统一保留宽 index/安全选 short，
  所有扫描 hoist prefix 的 consumer 统一 decode `fclosure8/fclosure`；修复后废弃 construction bytecode baseline；
- named function-expression 修复已独立 review/合入；当前 M-CELL 性能 baseline 已作废，新的
  plain-put 候选不得跨这个 compiler invariant 状态比较；并且必须先完成
  M-HOIST-CONSTRUCTION 的对齐/裁决，不能把构造阶段改变的性能算给 resident put；
- pinned QuickJS 默认是实现参照；若其可观察行为与明确的 test262/规范测试矛盾，
  必须用最小复现和规范证据建立单项 reference exception，不能把“qjs 也这样”用作引入已知错误的理由；
- 不把正确性修复的性能变化计入随后某把优化刀的收益。

这些项不是全局串行屏障：不依赖它们的 source recon 和机制可以先推进；但某机制的最终
baseline/candidate PMU 必须在自己的正确性前置合入后冻结，禁止跨前置状态拼 A/B。

## 3. 机制地图与当前优先级

优先级按“当前可约绝对 cycles × 服务面 × QuickJS 对齐确定性”排列，不按 benchmark ratio
排列。M0 完成后可以重新排序，但必须用定量证据更新，而不是凭名称调整。

| 顺序 | 机制 | QuickJS 锚点 | 当前判断 |
|---:|---|---|---|
| P0 | M-FCLOSURE-WIDTH correctness：cpool 宽/短编码与 hoist consumer | parser 先发宽 `OP_fclosure`，`resolve_labels` 只在 index≤255 时缩短；module linker 执行两种形态 | 已有 parser panic 和 module-cycle TDZ 双复现；这是正确性前置，不计性能收益 |
| P1a | M-HOIST-CONSTRUCTION：声明 cell 与函数值的创建/发布阶段 | `add_global_variables`、`js_closure2`、`instantiate_hoisted_definitions` | local/arg 已近似对齐，module short form 等价但 wide form 受 P0 阻塞；script/部分 direct eval 仍有 helper 提前创建函数值 + compiler 抑制前缀的双向补偿，默认对齐 qjs |
| P1b | M-CELL-EXEC：plain put/set 执行与 opcode residency | `JSVarRef.pvalue`、plain/short/checked var-ref CASE labels、`set_value` | 表示已对齐；read direct 已约 0.90x qjs 且 split 候选失败；P1a 合入重冻后，依次只做 resident plain put、resident set |
| P1c recon | M-DYNAMIC-VAR：`.global/.global_ref` 的 `get_var/put_var` 两腿 | qjs `OP_get_var/OP_put_var` CASE 内先直接 cell，只在 uninitialized/const 时进 global-object slow leg | zjs get 侧已有对齐历史，`put_var` 目前整体仍在 `h_put_var/coldStd`。但 P0/P1a 会改变可达 lowering；只在它们合入后建 direct probe/重排，不混入 plain-var-ref 收益 |
| P2 | M-RETURN-CONT：bytecode callee 返回后的 non-`.next` continuation transport | `JS_CallInternal` 的嵌套 call/return、`JS_IteratorNext` | `return_action/payload → op_post_call_continuation` 是所有返回后需要 post-work 形态的共同成本；普通 call/return 已排除，iterator/Proxy 只是消费者 |
| P3 | M-PROPERTY-LOOKUP：named property shape/prototype walk | `GET_FIELD_INLINE`、`find_own_property`、`JS_GetPropertyInternal` | push/pop 最大前置面之一；已部分对齐，先找 fallback/transport 残差 |
| P4 | M-NATIVE-CALL：callable→native frame→cproto/record | `JS_CallInternal`、`js_call_c_function`、各 cproto | 与 lookup 分离；push/pop/regexp/Math 等共享 |
| P5 | M-ALLOC-LIFECYCLE：object create/free/accounting | `JS_NewObjectFromShape`、`js_malloc/free`、`__JS_FreeValueRT`、`free_gc_object` | 当前 1.149x；force-GC 修复后执行 |
| P6 | M-SHAPE-PUBLISH：root/transition/property publish | `find_hashed_shape_prop`、`add_property`、`add_shape_property` | 三臂已有，但 capacity-independent cache hit 尚未对齐；扣除 allocation 后执行 |
| P7 | M-EMIT：当前仍缺的 qjs lowering/peephole | `resolve_variables`、`resolve_labels` | 先按最终 bytecode 重建规则清单，不按 pass 位置猜测 |
| P8 | M-FRAME-CONT：通用 frame/prologue/epilogue | `JSStackFrame`、`JS_CallInternal` | 调用已在 0.98–1.16x；tail guard 修复且新 profile 证明共同杠杆才重开 |

M-ARRAY-STORAGE 暂停：qjs 式 fast push/count/length 已存在，当前 profile 不支持它是主杠杆。
RegExp、Array、for-of、spread、objlit 等只作为机制消费者和语义验证面，不各自成立性能战役。

**Opcode residency 规则：** 不新建宽泛 M-DISPATCH。只有当 qjs 对应 opcode 是 CASE-inline、zjs 因冷 helper
额外发布/恢复 pc/sp，且 direct profile 证明该段在关键链上时，才能把**一个完整语义 family**
迁入 resident handler。这是逐 opcode 对齐，不是 benchmark fast path，也不允许顺手改 next-dispatch 架构。

P1c 是本次查漏补上的**强制 recon 项**，不是已批准的生产刀。它的 direct probe 必须分开
initialized-cell hit、uninitialized global-object hit/miss、strict miss、lexical TDZ/const 和 Proxy/exotic global；只有
cell-hit 差距与实际 consumer 同时成立，才按 opcode-residency 规则排到 P2 之前。

## 4. M0：每个生产改动的统一证据包

M0 是**按当前机制增量完成**的前置，不是要求 P1–P7 全部 recon 完才能产出第一把刀。
每个机制先完成一个只读 recon 包，内容必须齐全。源码/字节码 recon 可以早于正确性修复；
最终 PMU freeze 必须晚于该机制在 §2 中的前置门禁：

1. **QuickJS 事实链**：源码函数、关键结构字段、调用者、异常/所有权顺序，以及对应热汇编；
   同时记录 `OPTIMIZE/SHORT_OPCODES/DIRECT_DISPATCH/CONFIG_STACK_CHECK` 的有效值。
2. **zjs 当前链**：对应模块、调用者、结构字段和热汇编；标出已经对齐的部分，避免重复工作。
3. **差异分类**：
   - QJS 机制缺失；
   - 同一机制但 Zig 表示/ABI 不同；
   - 纯代码生成差异；
   - benchmark 自身混入的其他机制。
4. **最小探针矩阵**：每个脚本标为 symptom、direct、consumer 或 control。一个脚本不能同时
   充当直接归因和受益面证明。
5. **收益上限**：按 self cycles、调用次数和关键链估计可约上限；未算上限前不写 −15%/−20%
   之类目标。
6. **三方冻结**：recon 先冻结 baseline zjs / pinned qjs 的完整 binary SHA 与 `.text` SHA/size、
   stdout、原始逐轮计数、环境和命令；生产候选完成后再追加 candidate zjs 的同类证据，形成
   可比较的三方包。完整 hash 用于钉具体文件，`.text` hash 用于识别同源码重建中的代码身份；
   两者不能互相替代。

性能 qjs 二进制与 QuickJS 源码 checkout 必须可追溯到同一构建。若不能证明二者对应，或
checkout 发生变化，M0 先从该源码重建 qjs 并同时重钉源码 commit、构建命令和 binary SHA；
不得保留旧二进制却用新源码解释机制。

本轮已完成这项核验：性能 qjs 与 clean checkout 新建 qjs 的完整 hash 不同，但 `.text` 的
725,228 bytes 完全相同。差异来自构建路径/调试等非 `.text` 产物；因此继续用页首性能二进制
跑 PMU，同时以 clean checkout 解释源码。未来任何 `.text` 变化都必须重冻，不能用“同 commit”
带过。

compiler/bytecode recon 另建一个同 commit 的 diagnostic qjs（当前源码明确使用
`DUMP_BYTECODE=7` 导出 pass1/pass2/final，或使用经证明等价的导出），只用于字节码对照，不作为
性能参照。diagnostic 与 performance qjs 的 hash、flags 和用途分开记录，禁止把带诊断宏的二进制
混入 PMU。

当前 diagnostic qjs 已存在：`/home/aneryu/quickjs-zjs-dump` @
`04be246001599f5995fa2f2d8c91a0f198d3f34c`，唯一源码差异是启用 `DUMP_BYTECODE=7`；其 `qjs`
完整 SHA-256 为 `c8785a6e40e0c570f23d19f1b91db8e4202d66d3959980af88bb03e352cc534f`。

测量约定：

- 每个生产候选从冻结 baseline 建独立 worktree/branch，diff 只含一个机制；期间若合入相关
  正确性或共享 runtime 改动，就废弃旧 A/B、重建候选并重新冻结，不跨基线拼数据；
- 主结论使用交错 paired median，并报告范围或 MAD；best/min 只作辅助；
- `cycles,instructions` 一组采集；branch、branch-miss、L1I、frontend/backend stall 分组采集，
  避免事件 multiplexing 扭曲主计数；
- 至少 9 轮。候选效应低于 1.5%，或改动 `.text`/热结构布局时，再做独立 ReleaseFast 重建
  和至少 15 轮复核；
- 两侧都做 symbol + instruction-level profile。热点占用不是关键链证明，必须追踪值的消费者；
- 候选前冻结一组不受益 sentinel（至少覆盖既有 call shape、property read、string/loop 和 allocation
  control）；看到结果后不得替换 control、重分类 consumer 或删去回退形态；
- raw 数据放在当前 `.scratch/<mechanism>/` 工作项或等价临时证据包，结论写进 owning commit/
  issue；不新增全局历史账本。

## 5. 第一阶段：解释执行共同热机制

### 5.1 M-HOIST-CONSTRUCTION → M-CELL-EXEC

这里有两个必须分开的机制：**cell/函数值在什么阶段被创建与发布**，以及最终
`put_var_ref/set_var_ref` **如何执行一次已授权的 cell 写入**。前者改变可达字节码和 runtime
补偿分支，必须先独立对齐；不得把它的收益算给后者。当前 `[]*VarRef`、open cell 的
`pvalue → frame slot`、close 后 `pvalue → self.value` 已能表达 qjs，没有已知 Zig 限制。

#### QuickJS 的完整构造链

1. compiler 用 `add_global_variables` 生成 closure/global metadata，并由
   `instantiate_hoisted_definitions` 把初始化序列编入最终 bytecode；
2. `js_closure2` pass 1 只做 eval/global declaration 合法性检查；
3. `js_closure2` pass 2 为 local/arg/ref/global/module 创建或别名**精确的 `JSVarRef*`**，不创建
   hoisted function value；global object 的普通 var/function property 也优先与 `JS_PROP_VARREF` 共享 cell；
4. 最终 bytecode 再执行 `fclosure + put_var_ref`。diagnostic qjs 中 script/global function 的 final
   前缀就是 `fclosure8 0; put_var_ref0 0:f`。module 额外带
   `push_this; if_false; ...; return_undef` 链接前缀，linker 用 `this=true` 只执行这段，正常求值再从
   body 入口继续。cpool index 0..255 最终为 `fclosure8`，256 起保留宽 `fclosure`；两者只是
   operand 编码不同，构造/链接语义完全相同。

执行端的契约同样窄：

- `get_var_ref{0..3}`/plain get 只做 `*pvalue → JS_DupValue → *sp++`；
- plain put 消费 TOS，plain set 写入 dup 并保留 TOS；`set_value` 先保存 old，再把 new
  写入 slot，最后 free old，避免 old 的释放重入后破坏目标 slot；
- 只有 `*_check`/`*_check_init` 做 TDZ/初始化检查，0..3 short forms 是独立 CASE labels。

#### 当前 zjs 对照矩阵

| binding 形态 | 当前对齐状态 | 裁决 |
|---|---|---|
| local/arg hoisted function | compiler 已生成 `fclosure + put_loc/put_arg` 等价前缀 | 补 final-bytecode/所有权 snapshot 后封账，不重写 |
| module declaration | `initializeModuleFunctionDeclarations` 与 `moduleFunctionDeclarationBodyStart` 目前只识别 `fclosure8`；short form 等价，wide form 错过 link-time hoist，到 normal evaluation 才执行 | 先修 M-FCLOSURE-WIDTH，同一 decoder 覆盖宽/短 form；修复后才可将 module transport 封账为等价 |
| script/global function | cell 先建，但 `global_vars.cpool_idx` 路径在 `instantiateGlobalVarDeclarations` 过程中提前创建/发布函数值；`functionHasGlobalFunctionVarCpool` 同时抑制 final-bytecode 前缀 | 无已知 Zig 阻塞；默认对齐 qjs 的 cells-first + bytecode-value-publication |
| direct eval declaration | `.closure/.var_object/.global` 已表达声明目标，但函数 cpool 的创建阶段与 script 共享部分 eager helper 路径 | 分别对照 qjs closure `put_var_ref` 与 dynamic var-object `define_field`，不把两者强行合并 |
| `.global/.global_ref` closure metadata | zjs 中是携 atom 的动态环境 carrier，`closureVarIsRuntimeVarRef` 明确排除；最终走 `get_var/put_var` 的动态两腿 | 不纳入 plain-var-ref 契约，不宣称所有 closure metadata 外形与 qjs 相同 |

当前 `ensureGlobalObjectVarRefCell` 等路径已让新建 global var/function 常态共享 cell；不得复活
“zjs global 仍为普通 data slot”这个过期前提。既有 non-varref property、auto-init 和动态全局仍是
独立 slow/correctness 形态。

#### Recon/候选顺序

1. **先修 M-FCLOSURE-WIDTH 正确性。** 审计 parser 所有 `emitFClosure8/emitFClosure` producer，
   禁止把未证明≤255 的 cpool index 直接 cast 成 `u8`；审计 module/diagnostic/snapshot 等所有扫描
   function-hoist prefix 的 consumer，对 `fclosure8(u8)` 和 `fclosure(u32)` 使用同一安全 decoder。
   固化两条红灯：同 function 的 >255 函数表达式不 panic/不截断，module cycle 在 evaluation
   前对 index 255/256 两边都观察到正确 function identity。
2. **再冻结 construction matrix，不冻结 put PMU。** 用 diagnostic qjs final bytecode 与 zjs snapshot
   覆盖 local、arg、script global、global lexical、module decl/import、direct eval closure/var-object/global、
   parameter environment、nested closure，同时记录 instantiation 与 OOM rollback 顺序。
3. **第一生产候选只对齐构造阶段。** 让 script 与可静态选定 cell 的 direct-eval function
   declaration 恢复 qjs 的 final `fclosure + put_var_ref`；helper 仍只做 declaration validation、cell
   creation/aliasing 和属性旗标。dynamic var-object 保留它对应的 `define_field` 语义。这一刀不同时
   改 put handler。
4. **用构造证明删除 runtime 补偿，不是用 benchmark 证明“没触发”。** 逐个证明
   global property 与 frame slot 别名同一 cell，函数值只由 hoist bytecode 写一次，再判断
   `publishTopLevelFunctionVarRef`、runtime function-name/const 分支是否全部不可达。只能删除已被
   final-bytecode + construction invariant 封闭的腿。
5. **封闭 operand-stack VarRef handle 的生产者集合。** 正常 reference-object 生产者是
   `make_loc_ref/make_arg_ref/make_var_ref_ref`，由 `get_ref_value/put_ref_value` 消费；普通
   expression read 必须只把 plain JSValue 交给 plain put/set。在 parser/eval/module/generator 最终字节码上
   证明闭包后，才能删 `varRefCellFromValue/adapterValueDup`；synthetic malformed bytecode 要么明确
   拒绝，要么保留冷验证，不能污染正常 hot opcode。
6. **构造候选合入后重冻 M-CELL baseline。** 不再使用页首旧 binary 做因果 A/B；重跑
   short/generic read、plain put、set、post-inc 与 sentinels，重算收益上限。
7. **第二生产候选只做 resident plain put。** short/generic plain put 镜像 qjs
   decode→pop→`set_value(pvalue)`；当前 `VarRef.setVarRefValue` 已与 qjs 一样先发布 new、后 free old。
   checked/init forms 保留 cold，不同时动 set/read/post-inc 或 next-dispatch。
8. **第三生产候选只做 resident set。** 单独证明 TOS 保留、dup/free 和异常顺序；
   post-inc 只是 consumer，不把 arithmetic/lowering 收益记给 set。
9. read split 已按 §1.2 止损，不重做。正常 compiled frame 的 `var_refs` 按 closure count 精确定容；
   bounds check 只有在 finalized bytecode 与 synthetic policy 共同证明后才可移出 hot arm。证明不足就保留并记为
   zjs validation policy，而不是 Zig 限制。

closure 逃逸/close、generator suspend、module cycle、direct-eval abrupt completion、GC/OOM 只用来验证同一套 cell
和构造契约；不借本战役引入 pointer cache、第二套 cell layout 或 benchmark-local slot typing。

### 5.2 M-RETURN-CONT — 通用 post-call continuation transport

QuickJS 在 `JS_IteratorNext2` 中递归 `JS_Call`；callee 返回后，C 控制流直接继续读取 result。
zjs 不递归第二个 VM；普通 `.next` call/return 已在专用 handler 内完成 teardown/resume，不经过
通用 `op_post_call_continuation`。只有 `for_of_next`、Proxy 等需要 callee 返回后继续作业的
**非 `.next` action** 才发布 `return_action/payload`，经 `popAndResume` 和
`op_post_call_continuation` 回到 `finishForOfNextResult` 等消费者。因此这里只审计 post-call work
的 continuation transport，不把普通 call/return 或整体 dispatch 重新归因给它。

Recon 顺序：

1. 用普通 zero-arg method 证明 `.next` control 不进通用 continuation；再用 self-result iterator、
   constant-result iterator 和 bytecode Proxy `get` 分别隔离 post-work return 与 result-property work。
2. 逐项计数 action/payload publish、frame pop、resume pc/sp 恢复、post-call indirect dispatch、
   `done/value` lookup 与 ownership；`finishForOfNextResult` self% 不能全部算作 continuation。
3. 对照 qjs 的 receiver/method/argv 所有权、异常回到 caller 的位置、`sf->cur_pc`、result free 和
   done 时 iterator 清理；先确认现有语义相同，再找重复 transport。
4. 候选必须简化所有同类**非 `.next`** post-call action 的 continuation 表示，或把 continuation 直接并入既有
   return 协议；不得按 iterator result shape、固定 `next`、Proxy trap 名称或 benchmark 建分支。

生产修改受 §2 tail-chain stack budget 阻塞。若剩余差异只是 resident Machine 的架构成本，记录为
“zjs architecture divergence”；只有真实编译器/ABI 证据才能进一步归为 Zig 限制。

### 5.3 M-PROPERTY-LOOKUP — named property shape/prototype walk

QuickJS 的 `OP_get_field/get_field2/get_length` 共用 `GET_FIELD_INLINE`：直接查当前 shape hash chain，
data hit dup，miss 沿 `shape->proto` 继续；property kind 或 exotic/primitive 才进入
`JS_GetPropertyInternal`。这一步发生在 `OP_call_method` 之前，且 reference 没有 site IC。

zjs 的 `qjsGetFieldFast/findOwnDataValueFast` 已镜像普通 data walk，因此本战役不是新增 property
fast path，而是核对当前链为何仍比 qjs 贵：

1. 建 ordinary object 的 own-data、prototype-data、true-miss、getter、primitive 和 exotic 六个
   direct/control，另用 Array.push/pop、regexp method、普通 bytecode method 作 consumers。global object 的
   `JS_PROP_VARREF`/zjs var-ref property 另建 probe，不混进 ordinary-data direct attribution；否则样本同时测了
   M-CELL 别名与 property lookup。
2. 对照 atom→bucket、hash-chain load、kind flags、prototype load、receiver dup/free 和 slow-path
   publication；把 callable 后续 dispatch 从样本和 profile 中扣除。
3. 单独审计 zjs 的 `needsSlowPropertyAccess`、private-atom probe、null-prototype class-global fallback
   与 qjs `p->is_exotic` 顺序。它们是表示/语义差异，不得笼统写成“IC 成本”。
4. 只有证明当前 qjs-style walk 仍承担 qjs 没有的通用工作才改生产代码。新 site IC 属 zjs 超集，
   不在本阶段提出；已有正确 IC 也只作为 control，不拿模块名替代实际调用链。

### 5.4 M-NATIVE-CALL — callable 到 native frame/cproto record

property lookup 完成后，QuickJS `OP_call_method → JS_CallInternal → js_call_c_function`：从 c-function
object 直接读取 realm、function union、cproto、magic，建立 `JSStackFrame`，保证至少 formal length
个 argv 可读，再按 cproto switch 调用。zjs 已把 `InternalRecord*` 缓存在 function object 上，但
table/HostCall/native-frame 的等价性仍需独立审计。

Recon 顺序：

1. direct probes 预先缓存 callable，分别覆盖 exact argc、missing argc、plain call、method call、
   两个不同 builtin domain；Array.push/pop 只作 consumer，不再把 lookup 算进 native call。
2. 分解 class/callable discrimination、record pointer、realm、argv padding、native stack guard、
   native frame/backtrace、cproto/tag dispatch、builtin body 和返回值所有权。
3. 核对 getter/setter、generic_magic、iterator_next、constructor、cross-realm、Function.call/apply 和
   异常 backtrace；其中 `iterator_next` 在 `JS_IteratorNext2` 可直接调用 function union、绕过常规
   `js_call_c_function`，必须单列为 control。缺失的 native frame 可观察语义先作为 correctness
   修复，不能用性能理由跳过。
4. 只删除所有 native domains 共同承担且 qjs 不承担的 transport。收益至少在两个 builtin domain
   复现；regexp Zoo 是 breadth/semantic consumer，不是 direct attribution probe。

在 direct storage 探针证明前，不改 Array capacity/count 算法；不得把 push/pop 名称或 builtin id
本身当成新的生产分支依据。

## 6. 第二阶段：对象生命周期与属性发布

### 6.1 M-ALLOC-LIFECYCLE — create/free/accounting

前置：先修复当前 `test-exec -Dzjs_force_gc=true` 在 `gc.zig:1662` 的
`HeapLiveBytesMismatch`；否则 allocation/ownership 候选没有可靠门禁。

QuickJS 空对象链是 `OP_object → JS_NewObject → JS_NewObjectProtoClass →
JS_NewObjectFromShape`：先找/retain empty prototype shape，再 `js_trigger_gc`，分配 `JSObject` 和
`shape->prop_size` 个 `JSProperty`，初始化 rc/list；释放则是 inline rc-- → `__JS_FreeValueRT` queue
→ outermost `free_zero_refcount` → `free_object`。当前 zjs 已镜像 RC queue，但空对象 lazy-skip
property array，且初始 shape capacity 为 4（qjs `JS_PROP_INITIAL_SIZE` 为 2）。这是事件数不同的
既有优化，不能为了“忠实”恢复一次无收益分配。

两个历史 allocation 差异在当前代码已经 **CLOSED**，不得重列为未来刀：

- `SpaceAccount.recordAlloc/recordFree` 热路现在只更新 `live_bytes`，committed/free page geometry
  已改为 `refreshPageState` 在 stats/debug verify 时惰性派生；
- `Object.createInternal` 现在用 `recordPtr(class_id)` 的 `class_record` 指针视图，不再把整个
  class Record 按值复制到热栈。

历史文档可以用来说明这两项为何曾经昂贵，不能用来证明它们在当前 HEAD 仍存活。
这只封闭“per-allocation page geometry”和“整个 class Record 按值复制”两把旧刀；如果当前 profile
另外证明 pointer view 的必需标量读、allocator limit 或其他记账在关键链上，必须以新的
QuickJS 对照事实单独立项，不从已关闭收益外推。

Recon 顺序：

1. 用当前同一 `allocation-empty-object-2m.js` 跨 07-08 候选提交复现 0.96x；无法复现就删除
   “回归”叙事，从当前 1.149x 残差重新开始；
2. 将 root-shape lookup/retain、object alloc、property-storage alloc、GC trigger/list link、
   MemoryAccount、zero-ref enqueue/drain、property/shape release 和 raw free 分开计数；
3. 对照 qjs `JSMallocState`/`js_malloc` 记账、`JS_NewObjectFromShape` 和 `free_object` 的关键链；
   比较“同一语义工作是否重复”，不要求两侧 malloc 次数相同；
4. 先验证已对齐的 zero-ref queue 没有额外 per-object policy，再依次裁决 construct、accounting、
   destroy、allocator geometry；一次只动一个子机制。

必须保留公开 `gcStats()`、live=0、OOM 恢复、weak/finalizer、deferred cleanup 和 GC pacing
契约。若要把累计统计移出热路，必须先决定兼容实现，不能静默降低公共统计语义。

### 6.2 M-SHAPE-PUBLISH — 扣除 allocation 后的 shape/property 残差

旧计划的 `rc==1` 主刀已完成，不再重做；但源码复核确认三臂的 cache-hit 资格仍不完全相同：
qjs `find_hashed_shape_prop` 只比较 hash/proto/property sequence，不比较 `prop_size`，命中后若
容量不同就 realloc 对象 property array；zjs `findHashedShapeProperty` 当前要求 candidate
`prop_size == property_capacity`。新 recon 以 `{}` 为 lifecycle control，以 `{value}`、
let/var/pinned 和不同预留容量对象为 property-publish 差分：

1. 先记录 cache/shared/unique 三臂的命中分布，并用同 property sequence、不同 initial capacity
   直接验证 capacity 是否造成 qjs-hit/zjs-miss；不再以“三臂函数存在”代替机制等价；
2. 分解 root shape lookup、transition lookup、object property-buffer reconciliation、transition
   hash、FAM relocation、atom retain、property publication 和 destroy；
3. 第一个生产候选只能对齐 cache-hit eligibility + OOM-safe storage reconciliation；后续才分别
   研究 hash lookup 或 FAM relocation，不能一刀合并；
4. pin probe 只用于区别 shared shape 与 churn，不把 pin 本身当生产假设；
5. qjs object literal 仍是 `OP_object + OP_define_field/add_property`，没有普通 literal template。
   因此候选必须适用于普通 property addition，不得新增 object-literal-only template。

RegExp result、iterator result、arguments 等对象只能作为同机制消费者；如果它们使用预制
shape/template，则不得用其收益证明普通 shape publish 已改善。

## 7. 第三阶段：发码与帧协议

### 7.1 M-EMIT — 只做当前仍缺的 QuickJS 规则

先从当前 QuickJS `resolve_variables/resolve_labels` 和当前 zjs pipeline 自动或人工生成一份
规则映射：`qjs rule → zjs final-bytecode equivalent → tests → status`。pass 位置无需相同：zjs
在 parser 直接发 `get_length/push_empty_string` 或提前改写 tail call，只要最终 bytecode、atom
ownership 和控制流与 qjs 等价，就不应为了源码形状搬到 `resolve_labels`。

本次静态源码复核得到的初始清单如下；“待 diff”不是已确认缺失，必须先由 diagnostic qjs 的
final bytecode 与 zjs snapshot 证明：

| QJS rule family | 当前 zjs 状态 | 动作 |
|---|---|---|
| binding resolution 与 hoist construction：scope/arg/function-name/eval-object/with/closure/global 优先级，以及 cell/value 的创建阶段 | function-name 的 `add_var`、定义侧 strict metadata、dummy ref 和 parameter-env fallback 已由 `c034597c` 对齐；`with_get_ref + selected_reference with_put_var` 是 reference snapshot 的等价 transport。但 script/部分 eval 函数值仍 eager-instantiated 并抑制 hoist bytecode | 前一部分钉 snapshot 后封账；后一部分作为 M-HOIST-CONSTRUCTION 先于 M-CELL 独立对齐。它们都不是 peephole，不进行“只缩短序列”的 PMU 归因 |
| pipeline order、short loc/arg/var-ref、const8/fclosure8 | 普通 pipeline/encoding 已有，但 `fclosure` cpool >255 的 producer/consumer 不完整，已有 parser panic 与 module-cycle TDZ 复现 | 先以 M-FCLOSURE-WIDTH correctness 修复宽/短边界；其他 short family 只补矩阵证据，不重做 |
| tail call、`get_field(length)`、empty string short form | zjs 多在 parser 提前输出 | 用复杂 short-circuit/finally case 验证最终等价，不搬 pass |
| logical chain、null/undefined/typeof、constant branch、push-neg、dup-put/set、return-undef、dead code、inc/add-loc | 已有 matcher 或独立 fuse | 逐条钉 snapshot 后封账；不能再用旧的粗粒度族数代替 coverage |
| `insert3 + put_array_el/put_ref_value + drop` | 待 final-bytecode diff | 若 zjs 最终仍保留该序列，一条规则一刀 |
| redundant `to_propkey` before simple producer + `put_array_el` | 待 final-bytecode diff | 先覆盖 symbol/object coercion 反例，再裁决 |
| `insert2 + put_field + drop` | 待 final-bytecode diff | 先证明 stack effect/atom ownership，再裁决 |
| post-inc/dec store rewrites（loc/arg/var-ref/field/array） | loc 已有部分 fuse，其余待 diff | 按 destination family 分刀，不合批 |
| `put_x(n); get_x(n) → set_x(n)` 与 bigint-i32 neg | 待 coverage/diff | 只有最终差异且有可达脚本才进入 PMU |

执行纪律：

- binding resolution/hoist construction 与 peephole 分账：前者决定 cell 和函数值的创建阶段、
  属性别名及哪些 runtime opcode 可达，必须先于 M-CELL baseline；后者才只在同一语义动作上
  缩短最终序列；
- 一条独立 qjs rule 一个候选和一组 bytecode snapshot；
- 先证明最终 bytecode 差异，再测执行性能；没有 bytecode 差异就不进入 PMU；
- atom ownership、jump target、finally/rethrow、generator、eval/with、TDZ 和 dead-code
  可达性先有红灯；
- 全量 test262 delta-zero 后才保留发码刀。

`inc_loc_check` 是 qjs 没有的 zjs 超集 opcode，继续暂停。只有证明 Zig 当前 checked-local
表示无法获得 qjs 同等 lowering，且现有 qjs 规则已全部对齐，才单独裁决。

### 7.2 M-FRAME-CONT — 最后才重开通用帧战役

调用战役已把主形态压到 0.98–1.16x，并积累大量反证：共享 source/setup、scalar transport、
descriptor/interface 包装、额外长期活跃参数、raw resume、target 字段删除等都曾因寄存器压力、
`.text`、L1I 或其他形态 cycles 回退而撤销。

因此：

- 不执行旧计划的“八臂收敛为描述符单构造器”；性能中性只证明它可能是架构重构，不能占用
  性能战役；
- 先修 tail-call reuse 的等价 stack budget，再重新 profile fib/closure/borrowed continuation；
  qjs 的 native-SP guard 与 interrupt counter 是两个机制，zjs 不得用一个廉价计数器冒充两者；
- 只有同一个 qjs 对齐缺口在至少两个 frame shape 的关键链上出现，才重开生产候选；
- resident Machine、Entry slab 和 frame reuse 仍要按各自契约审计；但 tailcall dispatch 本身已由
  单体 dispatcher 3,504B spill 二分、224-arm A/B 和 next-dispatch 指令数封账，不得从 frame
  战役侧面重开。`preserve_none` 是明确工具链缺口，但不是当前结论的唯一证据；
- 架构可维护性重构另立工作项，不把“代码更少”记成性能收益。

## 8. 候选判定与止损协议

候选只有同时满足以下五项才保留：

1. **语义正确**：QuickJS 可观察顺序、异常、realm、Proxy/accessor、所有权和 OOM 不变。
2. **机制忠实**：有明确 qjs 锚点；若偏离，Zig 限制与等价证明完整。
3. **直接收益**：direct probe 的 paired median 改善超过该探针噪声；只有“方向同向”不算。
4. **受益面成立**：广域机制在至少两个真实消费者上复现；窄而忠实的机制允许一个直接
   消费者，但必须说明服务面为何天然狭窄。
5. **零未解释回退**：control 或无关热形态的 cycles 回退必须解释并复核；不能因 instructions
   未增就标为布局幻影。

回退规则：

- paired median cycles > +1.0% 先按真实回退处理，不与 instructions 条件做 `AND`；
- `|cycles| <= 1.0%` 的结果不宣称收益，除非独立重建、更多轮次和关键链证据一致；
- instructions、branch、L1I、stall 用于解释 cycles，不替代 cycles；
- 如果独立重建显示布局吸引子，允许通过通用 handler-cluster/layout 策略解决；禁止 padding、
  空逻辑或 benchmark-specific alignment 粉饰单个结果；
- 同一 qjs 对齐假设连续两个干净候选都失败，就停止该方向，写清反汇编死因；除非出现新的
  源码事实或工具链能力，不换名重试。

QJS ratio 用于确认差距是否收敛；baseline zjs → candidate zjs 才是因果 A/B。反超 qjs 时仍要
核对双方是否执行同一语义，但不为了 ratio=1 主动退化正确且通用的 zjs 机制。

## 9. 验证档位

每把刀按最小充分证据推进：

1. **迭代档**：ReleaseFast 编译、direct/control stdout、反汇编、最窄 changed-area 测试、
   `quick-check`。
2. **保留档**：对应 subsystem 测试、语义 slice、`checkpoint-check`、三方 PMU 包、
   `perf-self-check`；广域机制补 Zoo deterministic 检查。
3. **阶段收口**：
   - parser/exec/可观察语义改动：完整 `test262-gate`；
   - value representation：`test-altrepr`，并按项目规则跑 nan-boxing test262；
   - allocation/GC/ownership：恢复后的 force-GC、相关 OOM，阶段关闭时 `test-oom`；
   - final pre-commit：唯一一次 ReleaseSafe 全套；
   - `git diff --check`、干净工作树、无临时 profile/log。

不要每个小改动都跑全套；也不要用测试成本为理由跳过变更面必需的门禁。测试、exclude、
known-error、benchmark iteration 和 stdout oracle 均不得为候选让路。

## 10. 执行顺序与交付物

| 阶段 | 工作 | 出口 |
|---|---|---|
| M0 | 维持可追溯 performance/diagnostic qjs；按**当前机制**逐个做 source/final-bytecode recon | 当前候选的 qjs/zjs 差异、direct/control、收益上限齐全；不等待 P1–P7 全部完成，也不把早期 PMU 当最终 baseline |
| W1 | M-FCLOSURE-WIDTH parser/module correctness → 重冻 diagnostic construction matrix → M-HOIST-CONSTRUCTION script/eval 阶段对齐 → 语义/OOM 收口 → 重冻 M-CELL → resident plain put → resident set → P1c M-DYNAMIC-VAR recon/重排 | cpool-width 与构造收益都不计入 put；module 255/256 cycle 红灯先过；publication/adapter/capacity 只在 invariant 封闭后删；read split 不重试；put/set 各一刀；dynamic carrier 不越过证据直接上生产 |
| W2 | tail-chain stack correctness → 重冻 → 只审计非 `.next` 的 M-RETURN-CONT | 观察终止与 qjs 对齐；continuation 候选不跨 stack-guard 状态，不重开整体 dispatch |
| W3 | M-PROPERTY-LOOKUP → M-NATIVE-CALL | ordinary/global-varref lookup probe 分开；lookup 与 callable dispatch 分开保留/回退 |
| W4 | force-GC correctness → 重冻 → M-ALLOC-LIFECYCLE → M-SHAPE-PUBLISH | 门禁恢复后先空对象 lifecycle，后 transition/capacity 差分；不重做已关闭的 per-alloc page-geometry/按值 class-record 刀 |
| W5 | parser 默认参数 correctness → 重冻 diagnostic/PMU → M-EMIT | hoist construction 不算 peephole；只做 final bytecode 确认仍缺的 qjs rule |
| W6 | 条件性重开 M-FRAME-CONT | tail stack guard + 新共同热点证明同时满足 |

每个机制工作项只交付四类内容：最小代码改动、红灯/语义测试、三方性能证据、简短机制结论。
失败候选删除代码但保留结论；完成后更新本计划的当前优先级，不追加逐日流水账。

## 11. 历史教训转成的永久约束

- **先读 qjs，再形成假设。** Q1、for-of result allocation、Array storage 都证明名称相似不等于
  热机制相同。
- **源码宏和构建配置属于 reference。** `DIRECT_DISPATCH/SHORT_OPCODES/CONFIG_STACK_CHECK` 不同，
  即使同一 commit 也不是同一机制基线；diagnostic qjs 不能拿来跑性能。
- **zjs 架构选择不自动是 Zig 限制。** record table、lazy property storage、提前发码都必须
  按 deliberate divergence 审计。tail dispatch 则已有单体 spill 与 224-arm A/B 证据，当前作为
  Zig/LLVM 等价适配封账；这个结论来自数据，不是来自“Zig 写法不同”。
- **runtime 补偿分支往往是构造阶段不同的信号。** `publishTopLevelFunctionVarRef` 不能凭
  benchmark 没触发就删；先对照 qjs 的 metadata→cell→value-publication 阶段，再用 final
  bytecode 和别名 invariant 证明补偿不可达。
- **short opcode 是最终编码选择，不是数据模型。** qjs 先保留宽 `fclosure` index，只在
  index≤255 时缩短。zjs 直接把 cpool index cast 成 `u8` 不仅会 panic/截断，还使只识别
  `fclosure8` 的 module hoist consumer 在 255/256 边界出现可观察 TDZ。producer 与 consumer 必须成对审计。
- **QuickJS 例外需要比普通对齐更强的证据。** direct-eval same-name body `var` 的 pinned-qjs
  `undefined` 与 test262 明确的 function-name environment 要求冲突，所以保留 zjs `11`。没有
  最小复现 + 规范测试证据，不允许自行宣布 qjs bug。
- **复合 benchmark 必须最小化。** for-of 同时混入 cell/property/arith；push/pop 混入
  lookup/call/length。症状比值不能直接给机制排功劳。
- **占用不等于承载。** profile self% 只是入口；要追值是否进入间接跳转、依赖 load、allocator
  或关键 store/load 链。
- **cycles 可以在 instructions 下降时回退。** branch miss、L1I、前端布局和寄存器压力是真实
  成本，不称“幻影”。
- **热源码共享可能改变 codegen。** 历史 shared template/scalar ABI/extra state 多次导致其他
  shape 回退；抽象更整洁不自动等于热路径更好。
- **失败刀是边界证据。** 没有新事实就不重跑；负结果用于缩小搜索空间。
- **少 instructions 不自动形成 cycles 收益。** M-CELL read split 在 plain read 上少约 1.26%
  instructions，cycles 仍为 1.000x，并把 put/set controls 推到约 +1.2%；以后先看关键链和布局，
  不把静态分支删除当成果。
- **状态先审计。** shape unique arm、Array.push fast arm、多族 peephole 已完成却被旧计划重列，
  此后每个计划项必须先经 `git blame/log + 当前源码` 双确认。
- **已关闭的 allocation 差异不用历史 profile 复活。** page geometry 已移到惰性 refresh，
  class metadata 已是 pointer-only view；只有当前 HEAD 的调用链/汇编再次证明它们存活才可重开。
- **迁移一个机制要同时迁移 metadata、resolution action 与初始化。** `6fdaf1be` 正确对齐了 qjs
  lazy named-function self-binding 的 materialization/prologue，获得了真实调用收益，但保留了旧 zjs
  的 scope-linked、unconditional-const 形状和 runtime function-name write workaround；因此漏掉定义侧
  strict、sloppy drop/dummy-ref、参数环境 fallback。今后不能以“分配时机已相同”宣告机制完成。
- **QuickJS 的特殊 binding 不是普通 scope var。** `add_func_var` 明确调用 `add_var`，解析优先级在
  ordinary scope/var/arg 之后；zjs 若因内部表示采用等价 helper，必须用参数默认值、shadow、eval、
  with 和 nested closure 证明相同优先级，不能把 scope 0 当作近似替代。
- **拓扑相同不等于机制相同。** shape 三臂虽都存在，cache key 的 `prop_size` 条件和命中后的
  storage reconciliation 仍可不同；必须比较 eligibility、动作和失败回滚。
- **最终 bytecode 优先于 pass 位置。** parser 提前发同一 short opcode 不算缺失；反之 opcode
  名字存在也不证明对应 peephole 可达。
- **所有权、异常和恢复不是冷得可以忽略。** OOM、GC、Proxy、getter、realm、backtrace、
  interrupt 和 abrupt teardown 是机制的一部分，不能在性能路径里伪装成 unreachable。

计划的最终完成标准不是所有 ratio 强行到 1.0，而是：每个高占用残差要么被一个忠实的
QuickJS 机制消除，要么有可复核的 Zig/ABI/布局地板证明，并且没有通过特性 fast path、
测试弱化或不可审计的最小值制造“完成”。

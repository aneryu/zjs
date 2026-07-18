# OPT-ROADMAP 2026-07-19 — QuickJS 机制忠实对齐计划

> 当前代码机制基线（compiler fix merge point）：
> `c034597c604f0b3f7e884d0f83554eaee7e95180`
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
tail-call dispatch、internal-record table、lazy property storage 和 parser 提前发 short opcode 都是
zjs 的架构选择，不是 Zig 限制。已知的 Zig 0.16 `preserve_none` 缺失只说明不能请求该 handler
calling convention；它不证明整套 tail-dispatch 架构不可替换，也不能替代 QuickJS 调用协议的
逐段对照。

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
| short plain put | 1.787x | 1.661x | P1 的第一执行候选 |
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
策略或工具链变化，不得换名重跑。P1 直接转向 plain put，再单独做 set。

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
| call/dispatch | 单体 `JS_CallInternal`，computed-goto；bytecode call 递归进入新的 C frame，locals/stack 用 `alloca` | resident Machine + tail handlers + inline Entry；属于架构偏离，不是 Zig 限制 | 不全盘重开；先隔离 return-continuation transport，frame 只条件性重开 |
| generic iterator | `js_for_of_next → JS_IteratorNext → JS_IteratorNext2 → JS_Call`；generic result 依次读 `done`、ToBool、仅在 false 时读 `value`，最后 free result | `finishForOfNextResult` 的可观察顺序已基本相同；主要差异是 bytecode `next()` 返回后还要走 `return_action/payload` 和 cold continuation | 改列 M-RETURN-CONT；iterator 只是 direct consumer，不再成立 feature 刀 |
| captured cell | `JSVarRef **var_refs` 直接取 `pvalue`；plain get/put/set 无 TDZ 检查，只有 `*_check` opcode 检查；0..3 有独立 short handler | `VarRef.pvalue`/slot type 已对齐；plain read 虽多分支但 direct cycles 已优于 qjs，read split 也已证伪；put/set 仍主要进入宽 cold funnel | M-CELL-EXEC 先修编译 construction invariant，再依次做 resident plain put、resident set；不再改 cell 表示或重做 read split |
| binding resolution | `add_func_var` 用 `add_var` 建特殊 fallback，不挂 scope 链；const 取决于**定义函数** strict；sloppy `scope_put`→drop、`scope_make_ref`→临时对象引用；`with_make_ref` 在 RHS 前快照引用 | 历史 lazy self-binding 只搬了 materialization/prologue，保留了 scope-linked/unconditional const 和 runtime function-name workaround；`dbe50d7d` 已补 exact `add_var`、strict metadata、parameter-env fallback、drop/dummy-ref；zjs `with_get_ref + selected_reference with_put_var` 已证明是快照等价机制 | 作为 M-CELL 的 compiler construction 前置合入并重冻；最终字节码等价即可，不把 zjs `with` transport 改成源码外形相同 |
| named property read | `GET_FIELD_INLINE` 直接 `find_own_property`，沿 prototype walk；data hit dup，accessor/exotic/primitive 才进 `JS_GetPropertyInternal`；没有 IC | zjs ordinary data walk 已近似镜像，但 slow-object 顺序、null-prototype class fallback 和 tail transport 不同 | 从 native call 中拆出 M-PROPERTY-LOOKUP，独立测 lookup 与 fallback |
| native call | c-function object 直接保存 function union、cproto、magic、realm；`js_call_c_function` 建 native `JSStackFrame`、补可读缺参，再按 cproto switch | zjs function object 缓存 `InternalRecord*`，经 table/host-call transport；直接指针是等价候选，但不是 qjs 原布局 | M-NATIVE-CALL 只审计 callable→frame→record，不再混入 property lookup |
| empty object | `OP_object → JS_NewObject → JS_NewObjectFromShape`：GC trigger、Object alloc、按 shape `prop_size` 分配 property array、rc=1、挂 GC list | zjs 使用 shared root，但空对象 lazy-skip property array，并承担 MemoryAccount/Registry；这是已有 zjs 优化，不是 Zig 限制 | 按事件和关键链比较，不以分配次数机械求同 |
| shape transition | `find_hashed_shape_prop` 不比较 `prop_size`；cache hit 后若容量不同就 realloc 对象 property array，再采用目标 shape | zjs 三臂已存在，但 `findHashedShapeProperty` 要求 candidate `prop_size == property_capacity` | M-SHAPE-PUBLISH 的第一项改为验证并对齐 cache-hit 资格/容量协调 |
| RC/free | inline `JS_DupValue/JS_FreeValue`；对象到 0 后入 `gc_zero_ref_count_list`，由最外层 drain 调 `free_object/free_gc_object` | 默认 value representation 和 zero-ref queue 已同构 | 不重开抽象；只在 allocation direct profile 证明重复记账或关键链差异时动 |
| compiler | `resolve_variables → resolve_labels → compute_stack_size`；short opcode、tail rewrite 和 peephole 在最终字节码上生效 | pipeline 顺序已同构，但部分规则在 parser 提前完成，另有规则尚无明确 matcher | 以最终 bytecode 等价为准，建立规则矩阵，不按 pass 所在文件判断缺失 |
| stack/interrupt | stack overflow 是 native SP + planned `alloca_size` 检查；interrupt counter 在 call entry 和 jump/backedge poll | jump/call interrupt poll 已有；无限 tail recursion 来自 frame reuse 未消耗等价 stack budget | 正确性项只修 tail-chain stack budget；interrupt 作为既有门禁，不混成一项 |

## 2. 正确性前置依赖

正确性任务可以在独立 worktree 开发，但不能在 PMU 基线冻结后无条件并行合入。它们会改变
相关机制的成本或可验证边界；合入后必须重建基线。

| 正确性项 | 当前复现 | 阻塞的性能机制 |
|---|---|---|
| force-GC heap accounting | `test-exec -Dzjs_force_gc=true` 在 `gc.zig:1662` 报 `HeapLiveBytesMismatch` | M-ALLOC-LIFECYCLE、M-SHAPE-PUBLISH |
| tail-call reuse 的等价 stack budget | zjs 无限运行；qjs 由 `js_check_stack_overflow` 抛 `InternalError: stack overflow` | M-RETURN-CONT、M-FRAME-CONT |
| generator 函数表达式作默认参数 | zjs `UnexpectedToken`；qjs 正常 | M-EMIT 的 parser/发码面 |
| named function-expression self-binding construction | 原冻结点的 lazy materialization 沿用旧 scope-linked/unconditional-const metadata，且参数默认值 `function f(x=f)` 被错发为 global read。`dbe50d7d` 已按 qjs 修复并由 `c034597c` 合入；checkpoint 1507/1507、相关 test262 30/30、full gate 0/49775 errors | 已解除 correctness 阻塞；立即废弃旧 M-CELL A/B 并从当前 main 重冻，随后才能移除 runtime const/function-name/publication 分支 |
| direct eval 下 function-name 与同名 body `var` | 既有 zjs 测试锁定 `(function rec(){var rec=11; return eval('rec')})()` 为 `11`；pinned qjs 会建立两个 `rec` local，把 `var rec=11` 降为 drop，eval 捕获未初始化为 `undefined` 的 loc0。这是已知、非 Zig 限制的 observable divergence，不是本轮 worktree 新增 | 完整 binding-construction 宣称前单独最小化并按当前“优先 qjs”原则裁决；未裁决前不得用“所有 direct-eval binding 已等价”删除 runtime 兼容腿 |

依赖规则：

- M-ALLOC-LIFECYCLE/M-SHAPE-PUBLISH 的生产改动前先修 force-GC，恢复该门禁；
- 再动 M-RETURN-CONT/M-FRAME-CONT 前，先为复用 frame 的 tail chain 实现并验证与 qjs stack guard
  等价的可观察终止；现有 call/jump interrupt polling 单独保留并回归，不把两种机制揉成一个计数器；
- parser 正确性修复可独立进行，但若合入，M-EMIT 的 bytecode 基线必须重冻；
- named function-expression 修复已独立 review/合入；当前 M-CELL 性能 baseline 已作废，新的
  plain-put 候选不得跨这个 compiler invariant 状态比较；
- 不把正确性修复的性能变化计入随后某把优化刀的收益。

这些项不是全局串行屏障：不依赖它们的 source recon 和机制可以先推进；但某机制的最终
baseline/candidate PMU 必须在自己的正确性前置合入后冻结，禁止跨前置状态拼 A/B。

## 3. 机制地图与当前优先级

优先级按“当前可约绝对 cycles × 服务面 × QuickJS 对齐确定性”排列，不按 benchmark ratio
排列。M0 完成后可以重新排序，但必须用定量证据更新，而不是凭名称调整。

| 顺序 | 机制 | QuickJS 锚点 | 当前判断 |
|---:|---|---|---|
| P1 | M-CELL-EXEC：captured-cell construction contract + plain put/set 执行 | `add_func_var/resolve_scope_var`、`JSVarRef.pvalue`、plain/short/checked var-ref opcodes | 表示已对齐；read direct 已约 0.90x qjs 且 split 候选失败，真实剩余差距集中在 put/set cold funnel；先封闭 compiler/instantiation invariant |
| P2 | M-RETURN-CONT：bytecode callee 返回后的 continuation transport | `JS_CallInternal` 的嵌套 call/return、`JS_IteratorNext` | zjs `return_action/payload → op_post_call_continuation` 是共同架构成本；iterator/Proxy 只是消费者 |
| P3 | M-PROPERTY-LOOKUP：named property shape/prototype walk | `GET_FIELD_INLINE`、`find_own_property`、`JS_GetPropertyInternal` | push/pop 最大前置面之一；已部分对齐，先找 fallback/transport 残差 |
| P4 | M-NATIVE-CALL：callable→native frame→cproto/record | `JS_CallInternal`、`js_call_c_function`、各 cproto | 与 lookup 分离；push/pop/regexp/Math 等共享 |
| P5 | M-ALLOC-LIFECYCLE：object create/free/accounting | `JS_NewObjectFromShape`、`js_malloc/free`、`__JS_FreeValueRT`、`free_gc_object` | 当前 1.149x；force-GC 修复后执行 |
| P6 | M-SHAPE-PUBLISH：root/transition/property publish | `find_hashed_shape_prop`、`add_property`、`add_shape_property` | 三臂已有，但 capacity-independent cache hit 尚未对齐；扣除 allocation 后执行 |
| P7 | M-EMIT：当前仍缺的 qjs lowering/peephole | `resolve_variables`、`resolve_labels` | 先按最终 bytecode 重建规则清单，不按 pass 位置猜测 |
| P8 | M-FRAME-CONT：通用 frame/prologue/epilogue | `JSStackFrame`、`JS_CallInternal` | 调用已在 0.98–1.16x；tail guard 修复且新 profile 证明共同杠杆才重开 |

M-ARRAY-STORAGE 暂停：qjs 式 fast push/count/length 已存在，当前 profile 不支持它是主杠杆。
RegExp、Array、for-of、spread、objlit 等只作为机制消费者和语义验证面，不各自成立性能战役。

## 4. M0：所有生产改动的统一证据包

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

### 5.1 M-CELL-EXEC — construction invariant 与 plain put/set

这不是重新设计 `VarRef`。当前 `[]*VarRef`、open cell 的 `pvalue → frame slot`、close 后
`pvalue → self.value` 已能直接表达 qjs；没有已知 Zig 限制。

QuickJS 的热契约更窄：

- `get_var_ref{0..3}`/plain `get_var_ref` 只做 `*pvalue → JS_DupValue → *sp++`；
- `put_var_ref` 消费 TOS，用 `set_value` 写 `pvalue`；`set_var_ref` 写入 dup 后保留 TOS；
- 只有 `get_var_ref_check`、`put_var_ref_check`、`put_var_ref_check_init` 承担 TDZ/初始化检查；
- 0..3 short opcode 是独立 labels，不经过通用 operand decode。

当前 zjs 的具体差异是：resident `opGetVarRef` 同时服务 plain/check，所有形态都付
`idx < frame.var_refs.len` 和 `isUninitialized`；put 形态仍进入 `h_varref → execPutVarRef`，与
ensure-capacity、const/function-name、global publication 等冷语义共用 funnel；set 形态则进入
`h_varref → execSetVarRef`，仍承担 capacity/stack 检查和通用 replace/dup/free 包装。两类不能在
profile 或候选中合并归因。direct 证据又补了一条重要边界：plain read 当前约 0.90x qjs，拆掉
TDZ compare 只减少 instructions、没有减少 cycles，并使 put/set controls 回退。因此这里不再把
“源码里还有分支”自动当作可约成本。

Recon/候选顺序：

1. **先封闭 compiler construction contract。** 合入并 review §2 的 named function-expression
   修复；再用最终 bytecode snapshot 证明 mutable var、lexical TDZ、const、module import、function
   name、direct eval、parameter environment、closure chain 各自落入 plain/check/throw/drop/dummy-ref
   的正确 family。QuickJS 的关键不是 runtime cell 带更多 flag，而是 `resolve_scope_var` 已把
   const/function-name 动作提前决定。§2 的 direct-eval same-name-`var` divergence 必须在本步
   单独裁决，不能被 broad test pass 掩盖。这里的 invariant 是“每个 plain put/set 都已获准做
   unconditional `set_value`”，不等于“目标必为 mutable”：qjs 也用 plain `put_var_ref` 完成某些
   module/eval const 初始化，const 的非法**重写**才由 resolution 阶段排除。
2. **把动态环境的等价 transport 写进契约。** qjs `with_make_ref` 在 RHS 前选中 object reference，
   miss 时建立静态 dummy reference；zjs 当前 `with_get_ref` 留下 selected object/value，随后
   `with_put_var(selected_reference)` 消费同一快照，RHS 改增删属性也不会重做 HasProperty/
   unscopables。该最终控制流已由 hit/miss 与 RHS mutation probes 证明等价，不为源码外形改写。
3. **证明 publication 不属于 plain store。** 逐个验证 script/global function declaration 已由
   `instantiateGlobalVarDeclarations → defineGlobalVarDeclaration/defineGlobalFunctionBindingValue`
   发布；direct eval 的 `.closure/.var_object` binding 在实例化时选定；module/top-level closure
   store 不走 global-object publication。证明完才允许从 `execPutVarRef` plain arm 删除
   `publishTopLevelFunctionVarRef`，不能凭当前 benchmark 没触发就删。
4. **证明 TOS 不是 VarRef adapter。** 在 finalized parser bytecode、direct eval、module linking、
   generator resume 和 synthetic test construction 中追踪所有 plain put/set producer；只有确认
   stack value 不会暴露内部 VarRef handle，才删除 `varRefCellFromValue/adapterValueDup` 兼容腿。
5. **第一生产候选只做 resident plain put。** short/generic plain put 共用 qjs 的 decode→pop→
   `set_value(pvalue)` 契约，checked/init forms 留在 cold handler；不同时动 set、read、post-inc、
   publication 或 adapter 表示。
6. **第二生产候选只做 resident set。** 单独保留 TOS/dup/free 所有权证明和 direct set/control
   PMU；post-inc 只是 consumer，不能把 arithmetic/lowering 收益记给 set handler。
7. read split 已按 §1.2 止损，不重做。bounds check 是否可删取决于 finalized/synthetic bytecode、
   eval/module construction 和 alternate repr 的统一 invariant；证明不足就保留，并明确记作 zjs
   validation policy，而不是 Zig 限制。

closure 逃逸、close、generator suspend、GC/OOM 只验证既有 cell 表示，不借本战役引入 pointer
cache、第二套 cell layout 或 benchmark-local slot typing。

### 5.2 M-RETURN-CONT — 通用 post-call continuation transport

QuickJS 在 `JS_IteratorNext2` 中递归 `JS_Call`；callee 返回后，C 控制流直接继续读取 result。
zjs 不递归第二个 VM，而是发布 `return_action/payload`，经 `popAndResume` 与
`op_post_call_continuation` 再进入 `finishForOfNextResult`。这是 call/return 机制差异，不是 iterator
feature，也不是已证明的 Zig 限制。

Recon 顺序：

1. 用普通 zero-arg method、self-result iterator、constant-result iterator 和 bytecode Proxy `get`
   分别隔离普通 return、带 post-work return 和 result-property work。
2. 逐项计数 action/payload publish、frame pop、resume pc/sp 恢复、post-call indirect dispatch、
   `done/value` lookup 与 ownership；`finishForOfNextResult` self% 不能全部算作 continuation。
3. 对照 qjs 的 receiver/method/argv 所有权、异常回到 caller 的位置、`sf->cur_pc`、result free 和
   done 时 iterator 清理；先确认现有语义相同，再找重复 transport。
4. 候选必须简化所有同类 post-call action 的 continuation 表示，或把 continuation 直接并入既有
   return 协议；不得按 iterator result shape、固定 `next`、Proxy trap 名称或 benchmark 建分支。

生产修改受 §2 tail-chain stack budget 阻塞。若剩余差异只是 resident Machine 的架构成本，记录为
“zjs architecture divergence”；只有真实编译器/ABI 证据才能进一步归为 Zig 限制。

### 5.3 M-PROPERTY-LOOKUP — named property shape/prototype walk

QuickJS 的 `OP_get_field/get_field2/get_length` 共用 `GET_FIELD_INLINE`：直接查当前 shape hash chain，
data hit dup，miss 沿 `shape->proto` 继续；property kind 或 exotic/primitive 才进入
`JS_GetPropertyInternal`。这一步发生在 `OP_call_method` 之前，且 reference 没有 site IC。

zjs 的 `qjsGetFieldFast/findOwnDataValueFast` 已镜像普通 data walk，因此本战役不是新增 property
fast path，而是核对当前链为何仍比 qjs 贵：

1. 建 own-data、prototype-data、true-miss、getter、primitive 和 exotic 六个 direct/control，
   另用 Array.push/pop、regexp method、普通 bytecode method 作 consumers。
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

前置：force-GC accounting 恢复；否则 allocation/ownership 候选没有可靠门禁。

QuickJS 空对象链是 `OP_object → JS_NewObject → JS_NewObjectProtoClass →
JS_NewObjectFromShape`：先找/retain empty prototype shape，再 `js_trigger_gc`，分配 `JSObject` 和
`shape->prop_size` 个 `JSProperty`，初始化 rc/list；释放则是 inline rc-- → `__JS_FreeValueRT` queue
→ outermost `free_zero_refcount` → `free_object`。当前 zjs 已镜像 RC queue，但空对象 lazy-skip
property array，且初始 shape capacity 为 4（qjs `JS_PROP_INITIAL_SIZE` 为 2）。这是事件数不同的
既有优化，不能为了“忠实”恢复一次无收益分配。

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
| binding resolution：scope/arg/function-name/eval-object/with/closure/global 优先级；const/import/function-name 的 put/make-ref/delete 动作 | 历史 lazy function-name 只对齐 materialization，遗漏 `add_var`、定义侧 strict metadata、dummy ref 和 parameter-env fallback；worktree 已补。zjs `with_get_ref + selected_reference with_put_var` 是 qjs reference snapshot 的最终字节码等价物 | 先把它作为 construction correctness 合入并钉 local/closure/default/eval/with snapshots；不把它误列为 peephole，也不把等价 `with` transport 改成同名 opcode |
| pipeline order、short loc/arg/var-ref、const8/fclosure8 | 已有对应 pipeline/encoding | 只补矩阵证据，不重做 |
| tail call、`get_field(length)`、empty string short form | zjs 多在 parser 提前输出 | 用复杂 short-circuit/finally case 验证最终等价，不搬 pass |
| logical chain、null/undefined/typeof、constant branch、push-neg、dup-put/set、return-undef、dead code、inc/add-loc | 已有 matcher 或独立 fuse | 逐条钉 snapshot 后封账；不能再用旧的粗粒度族数代替 coverage |
| `insert3 + put_array_el/put_ref_value + drop` | 待 final-bytecode diff | 若 zjs 最终仍保留该序列，一条规则一刀 |
| redundant `to_propkey` before simple producer + `put_array_el` | 待 final-bytecode diff | 先覆盖 symbol/object coercion 反例，再裁决 |
| `insert2 + put_field + drop` | 待 final-bytecode diff | 先证明 stack effect/atom ownership，再裁决 |
| post-inc/dec store rewrites（loc/arg/var-ref/field/array） | loc 已有部分 fuse，其余待 diff | 按 destination family 分刀，不合批 |
| `put_x(n); get_x(n) → set_x(n)` 与 bigint-i32 neg | 待 coverage/diff | 只有最终差异且有可达脚本才进入 PMU |

执行纪律：

- binding construction 与 peephole 分账：前者改变哪些 runtime opcode 可达，必须先于 M-CELL
  baseline；后者只在同一语义动作上缩短最终序列；
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
- resident Machine、Entry slab 和 frame reuse 都是 zjs 架构选择；只有 `preserve_none` calling
  convention 本身是明确工具链等待项，普通 C ABI 多传状态已经被历史实验证伪；
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
| M0 | 重建可追溯 performance/diagnostic qjs；为 P1–P7 做只读 source recon | qjs/zjs 差异、最终 bytecode、直接探针、收益上限齐全；不把早期 PMU 当最终 baseline |
| W1 | ~~review/合入 function-name construction 修复~~ → **重冻 M-CELL** → resident plain put → resident set → tail-chain stack correctness → 重冻 → M-RETURN-CONT | correctness 前置已在 `c034597c` 完成；read split 已失败且不重试；put/set 各自一刀，先证明 publication/adapter/capacity invariant；continuation 候选不跨 stack-guard 状态 |
| W2 | M-PROPERTY-LOOKUP → M-NATIVE-CALL | lookup 与 callable dispatch 分开保留/回退 |
| W3 | force-GC correctness → 重冻 → M-ALLOC-LIFECYCLE → M-SHAPE-PUBLISH | 门禁恢复后先空对象 lifecycle，后 transition/capacity 差分 |
| W4 | parser 默认参数 correctness → 重冻 diagnostic/PMU → M-EMIT | 只做 final bytecode 确认仍缺的 qjs rule |
| W5 | 条件性重开 M-FRAME-CONT | tail stack guard + 新共同热点证明同时满足 |

每个机制工作项只交付四类内容：最小代码改动、红灯/语义测试、三方性能证据、简短机制结论。
失败候选删除代码但保留结论；完成后更新本计划的当前优先级，不追加逐日流水账。

## 11. 历史教训转成的永久约束

- **先读 qjs，再形成假设。** Q1、for-of result allocation、Array storage 都证明名称相似不等于
  热机制相同。
- **源码宏和构建配置属于 reference。** `DIRECT_DISPATCH/SHORT_OPCODES/CONFIG_STACK_CHECK` 不同，
  即使同一 commit 也不是同一机制基线；diagnostic qjs 不能拿来跑性能。
- **zjs 架构选择不是 Zig 限制。** tail dispatch、record table、lazy property storage、提前发码
  都必须按 deliberate divergence 审计，不能用“Zig 写法不同”自动免责。
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
